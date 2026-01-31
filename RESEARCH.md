# Deep Research: FPGA Porting Altera Cyclone V -> Lattice ECP5

**Istrazivac:** Manda Peric, REGOC
**Datum:** 2026-01-31
**Task:** TASK-115

---

## 1. Emard GitHub Projekti

### 1.1 Relevantni Repozitoriji

| Repozitorij | Zvjezdice | Relevantnost | Link |
|------------|-----------|--------------|------|
| **ulx3s** | 418 | PCB dizajn za ULX3S | https://github.com/emard/ulx3s |
| **ulx3s-misc** | 82 | Napredni primjeri za ULX3S | https://github.com/emard/ulx3s-misc |
| **esp32ecp5** | 74 | ESP32 JTAG programer za ECP5 | https://github.com/emard/esp32ecp5 |
| **fpga_snake_game** | - | VGA/HDMI primjer (VHDL/Verilog mix) | https://github.com/emard/fpga_snake_game |

### 1.2 Kljucni Lessons Learned iz Emardovih Projekata

**Video Output Pattern:**
```
VGA timing generacija (vga.vhd)
        |
        v
VGA to DVI konverzija (vga2dvid.vhd)
        |
        v
TMDS encoding (tmds_encoder.vhd)
        |
        v
DDR output (fake_differential.v za ECP5)
```

**Build System:**
- Podrzava i Diamond i Trellis toolchaine
- Koristi prjtrellis, nextpnr, yosys, vhd2vl
- Makefile-driven build proces

**BRAM Inference:**
- Emard koristi behavioral Verilog/VHDL za BRAM
- Yosys automatski inferira EBR blokove za memorije > 2Kbit
- Primjer generickog dual-port RAM-a vec postoji u `pdp1_vga_rowbuffer.v`

### 1.3 Emardov Parcijalni Port FPG-1

Lokacija: `/home/klaudio/port_fpg1/fpg1_partial_emard/`

**Sto je vec napravljeno:**
- Top-level ULX3S wrapper (`top_pdp1.v`)
- Video pipeline (vga.vhd, vga2dvid.vhd, tmds_encoder.vhd)
- Genericki `pdp1_vga_rowbuffer.v` - **FUNKCIONALNO**
- Constraint file za ULX3S v20
- Build scripts za Diamond i Trellis

**Sto NIJE zavrseno (placeholder s intentional syntax error):**
- `pixel_ring_buffer.v` - **KRITICNO**
- `line_shift_register.v` - **KRITICNO**
- `pdp1_cpu_alu_div.v`
- `pdp1_terminal_charset.v`
- `pdp1_terminal_fb.v`

---

## 2. Lawrie GitHub Projekti

### 2.1 Relevantni Repozitoriji

| Repozitorij | Opis | Relevantnost |
|------------|------|--------------|
| **ulx3s_examples** | Verilog primjeri za ULX3S | Visoka |
| **ulx3s_sms** | Sega Master System za ULX3S | Visoka |
| **ulx3s_zx_spectrum** | ZX Spectrum 48k za ULX3S | Srednja |
| **fpga_pio** | RP2040 PIO rekreacija | Niska |

### 2.2 Porting Patterns iz ulx3s_sms

Link: https://github.com/lawrie/ulx3s_sms

**Arhitekturalni pristup:**
- Console memory (8KB) - BRAM
- Video RAM (16KB) - BRAM
- BIOS ROM (32KB) - BRAM
- Cartridge - SDRAM (za vece igre)

**Video Pattern:**
- Custom VDP generira VGA timing (640x480@60Hz)
- VGA-to-HDMI konverzija
- Parametrizirani top-level za razlicite ECP5 varijante (12F, 25F, 85F)

**Kljucni Insight:**
> Modularni Verilog pristup prioritizira reusability nad cycle-accuracy

### 2.3 ulx3s_examples Video Direktorij

Struktura:
```
video/
  ├── buffer/      # Video buffering mehanizmi
  ├── checkers/    # Test pattern
  ├── color/       # Color palette
  ├── sprite/      # Sprite rendering
  ├── terminal/    # Text terminal
  ├── text/        # Text rendering
  └── tricolor/    # Three-color display
```

---

## 3. Circular Buffer / altshift_taps Zamjena

### 3.1 Sto je altshift_taps?

Altera/Intel `altshift_taps` je RAM-based shift register s vise izlaznih tapova:

```
Parametri:
- WIDTH: sirina podataka (npr. 32 bita)
- NUMBER_OF_TAPS: broj izlaznih tocaka (npr. 8)
- TAP_DISTANCE: razmak izmedju tapova u clock ciklusima (npr. 1024)

Ukupna memorija = WIDTH x NUMBER_OF_TAPS x TAP_DISTANCE
Za pixel_ring_buffer: 32 x 8 x 1024 = 262,144 bita = 256 Kbit
```

**Implementira se koristeci dual-port BRAM kao circular buffer.**

### 3.2 David Shah (dshaha) Shift Register Generator

**PRONADENO!** U `/home/klaudio/port_fpg1/fpg1_partial_emard/src/emard/shift_register_generator.c`

Autor: David Shah (jedan od glavnih developera prjtrellis/nextpnr-ecp5)

**Kljucne funkcije:**
- `Platform_GetShiftTapSignals()` - generira VHDL signale
- `Platform_InstantiateShiftTapComponent()` - generira VHDL process

**Xilinx Mode (portabilan) algoritam:**
```vhdl
-- RAM tip za pohranu svih tapova odjednom
type ram_t is array(2^adsize-1 downto 0) of std_logic_vector(ram_width-1 downto 0);
signal ram : ram_t;
signal rdptr, wrptr : unsigned(adsize-1 downto 0);

-- Na svaki clock:
process(clock)
begin
  if rising_edge(clock) then
    if enable = '1' then
      wrptr <= wrptr + 1;
      -- Write: concatenacija novog podatka i svih ostalih tapova
      ram(to_integer(wrptr)) <= din & tap0 & tap1 & ... & tap(n-2);
      -- Read: procitaj iz (wrptr - line_width + 1)
      q <= ram(to_integer(rdptr));
    end if;
  end if;
end process;

-- Read pointer je uvijek iza write pointera za line_width
rdptr <= wrptr - (line_width - 1);

-- Tapovi se izvlace iz procitane vrijednosti
tap0 <= q(WIDTH-1 downto 0);
tap1 <= q(2*WIDTH-1 downto WIDTH);
-- itd.
```

### 3.3 Genericka BRAM-based Implementacija (Surf-VHDL Pattern)

Izvor: https://surf-vhdl.com/how-to-implement-a-digital-delay-using-a-dual-port-ram/

**Koncept circular buffera:**
```
+-----------+
|   BRAM    |
|  [0..N-1] |
+-----------+
     ^  |
     |  v
  wrptr rdptr

Delay = wrptr - rdptr (modulo N)
```

**Prednosti:**
- Resource efficient - jedan BRAM blok umjesto tisuca flip-flopova
- Skalabilno - delay postaje generickim parametrom
- Technology independent - RTL kod automatski inferira dual-port RAM

### 3.4 Pronandene Open Source Implementacije

| Projekt | Link | Napomena |
|---------|------|----------|
| Hardware Circular Buffer Controller | https://github.com/wtiandong/Hardware_circular_buffer_controller | Verilog, FPGA-ready |
| Circular Queue Verilog | https://github.com/aniketnk/circular-queue-verilog | Icarus Verilog testiran |
| Open FPGA Verilog Tutorial | https://github.com/Obijuan/open-fpga-verilog-tutorial | Edukativni primjeri |
| ZipCPU FIFO Tutorial | https://zipcpu.com/blog/2017/07/29/fifo.html | Detaljno objasnjenje |

### 3.5 Preporucena Implementacija za ECP5

**Za `line_shift_register` (8 bit, 1 tap, distance 1685):**

```verilog
module line_shift_register (
  input clock,
  input [7:0] shiftin,
  output reg [7:0] shiftout,
  output [7:0] taps  // Samo 1 tap
);
  // 2048 lokacija (2^11) je dovoljno za 1685
  reg [7:0] mem [0:2047];
  reg [10:0] wrptr = 0;

  wire [10:0] rdptr = wrptr - 11'd1685;
  wire [10:0] tapptr = wrptr - 11'd1684;  // 1 clock iza shiftout

  always @(posedge clock) begin
    mem[wrptr] <= shiftin;
    shiftout <= mem[rdptr];
    wrptr <= wrptr + 1;
  end

  assign taps = mem[tapptr];  // Ili registrirano ako timing zahtijeva
endmodule
```

**Za `pixel_ring_buffer` (32 bit, 8 tapova, distance 1024):**

```verilog
module pixel_ring_buffer (
  input clock,
  input [31:0] shiftin,
  output reg [31:0] shiftout,
  output [255:0] taps  // 8 tapova x 32 bita
);
  // Total depth: 8 x 1024 = 8192 lokacija
  reg [31:0] mem [0:8191];
  reg [12:0] wrptr = 0;

  // Tapovi na razmacima od 1024
  wire [12:0] tap_addr [0:7];
  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : tap_gen
      assign tap_addr[i] = wrptr - 13'd1024 * (i + 1);
    end
  endgenerate

  // Registrirani tapovi (potrebno za timing)
  reg [31:0] tap_reg [0:7];

  always @(posedge clock) begin
    mem[wrptr] <= shiftin;
    shiftout <= mem[wrptr - 13'd8192 + 13'd1];  // Najstariji element
    wrptr <= wrptr + 1;

    // Update tapova
    tap_reg[0] <= mem[tap_addr[0]];
    tap_reg[1] <= mem[tap_addr[1]];
    tap_reg[2] <= mem[tap_addr[2]];
    tap_reg[3] <= mem[tap_addr[3]];
    tap_reg[4] <= mem[tap_addr[4]];
    tap_reg[5] <= mem[tap_addr[5]];
    tap_reg[6] <= mem[tap_addr[6]];
    tap_reg[7] <= mem[tap_addr[7]];
  end

  // Concatenacija tapova
  assign taps = {tap_reg[7], tap_reg[6], tap_reg[5], tap_reg[4],
                 tap_reg[3], tap_reg[2], tap_reg[1], tap_reg[0]};
endmodule
```

**NAPOMENA:** Ova implementacija zahtijeva 8 simultanih read portova, sto ECP5 EBR ne podrzava nativno. Moguca rjesenja:
1. Replicirati memoriju 8 puta (memorijski intenzivno)
2. Koristiti time-multiplexed pristup (dodaje latenciju)
3. Smanjiti broj tapova na 2 i koristiti true dual-port (najjednostavnije)

---

## 4. Toolchain Analiza: oss-cad-suite

Lokacija: `/home/klaudio/Programs/oss-cad-suite-build/`

### 4.1 Dostupni Alati

**RTL Synthesis:**
- **Yosys** - RTL sinteza, Verilog 2005 podrska
- **GHDL** - VHDL 2008/93/87 simulator i sinteza
- **GHDL-yosys-plugin** - VHDL sinteza kroz Yosys

**Place & Route:**
- **nextpnr-ecp5** - P&R za Lattice ECP5
- **Project Trellis (prjtrellis)** - ECP5 bitstream dokumentacija

**Programming:**
- **openFPGALoader** - Univerzalni FPGA programer
- **fujprog** - ULX3S JTAG programer
- **ecpprog** - FTDI-based ECP5 programer

**Simulation:**
- **Verilator** - Verilog/SystemVerilog simulator
- **Icarus Verilog (iverilog)** - Verilog kompilator/simulator
- **GTKWave** - Waveform viewer
- **cocotb** - Python testbench framework

### 4.2 Tipicni Build Flow

```bash
# 1. Sinteza (Verilog -> JSON netlist)
yosys -p "read_verilog top.v; synth_ecp5 -top top -json top.json"

# 2. Place & Route (JSON -> config)
nextpnr-ecp5 --85k --package CABGA381 --json top.json --lpf ulx3s.lpf --textcfg top.config

# 3. Bitstream generacija
ecppack --svf top.svf top.config top.bit

# 4. Programming
fujprog top.bit
# ili
openFPGALoader -b ulx3s top.bit
```

### 4.3 Yosys ECP5 Sinteza - Specificnosti

**BRAM Inference:**
- Memorije < 2Kbit -> Distributed RAM (LUT-based)
- Memorije >= 2Kbit -> EBR (Block RAM)
- Override s atributom `(* ram_style = "block" *)`

**Poznati Problemi:**
- True dual-port RAM mapping moze failati (Issue #2976, #3205)
- Workaround: koristiti pseudo dual-port ili eksplicitnu DP16KD instancijaciju

**Shift Register Inference:**
- Yosys NE inferira BRAM-based shift registre automatski
- Potrebna eksplicitna behavioral implementacija s dual-port RAM

### 4.4 Verilator za Simulaciju

```bash
# Kompilacija
verilator -Wall --cc --exe --build top.v sim_main.cpp

# Ili za waveform dump
verilator -Wall --cc --exe --build --trace top.v sim_main.cpp
```

---

## 5. Porting Strategija

### 5.1 Preporuceni Pristup (3 faze)

**FAZA 1: Video Infrastructure (3-5 dana)**

Cilj: Dobiti stabilan HDMI output na ULX3S

1. Koristiti Emardove vec gotove komponente:
   - `vga.vhd` - VGA timing
   - `vga2dvid.vhd` - VGA to DVI
   - `tmds_encoder.vhd` - TMDS encoding

2. Konfigurirati PLL za 108 MHz pixel clock (ili 75 MHz za 50Hz)

3. Testirati s jednostavnim test patternom

**FAZA 2: Memory Primitives (3-4 dana)**

Cilj: Portirati sve altsyncram instance

| Modul | Pristup | Kompleksnost |
|-------|---------|--------------|
| pdp1_vga_rowbuffer | VEC GOTOV (emard) | - |
| pdp1_terminal_charset | $readmemh + reg array | Niska |
| pdp1_terminal_fb | Behavioral dual-port | Niska |
| console_bg_image | $readmemh + reg array | Niska |
| pdp1_main_ram | True dual-port BRAM | Srednja |

**FAZA 3: Shift Registers - KRITICNO (5-7 dana)**

Cilj: Implementirati altshift_taps zamjenu

1. `line_shift_register`:
   - Jednostavnija (1 tap)
   - Implementirati kao BRAM-based circular buffer
   - Testirati blur kernel

2. `pixel_ring_buffer`:
   - Kompleksnija (8 tapova)
   - **Opcija A:** Time-multiplexed pristup (sporije ali manje memorije)
   - **Opcija B:** Replicirani BRAM (brze ali 8x memorija)
   - **Opcija C:** Smanjiti na 4 tapa s vecim tap_distance

3. Integracija u pdp1_vga_crt.v

4. Vizualno testiranje CRT phosphor decay efekta

### 5.2 Kriticne Odluke

**Q1: Zadrzati 8 tapova ili smanjiti?**

Analiza koda u `pdp1_vga_crt.v` pokazuje da se svih 8 tapova koristi za:
- Pretragu postojecih piksela (koordinatna usporedba)
- Populiranje row buffera (7 linija unaprijed)

Moguce smanjenje na 4 tapa uz:
- Povecanje tap_distance na 2048
- Prilagodba row buffer logike

**Q2: Hardware divider (lpm_divide)?**

Original koristi 34-stage pipelined divider za DIV instrukciju.

Opcije:
1. Behavioral `/` operator (Yosys ce sintetizirati iterativni divider)
2. Software emulacija (DIV je rijetka instrukcija u PDP-1 softwareu)
3. Restoring divider implementacija

Preporuka: Poceti s behavioral, optimizirati ako je potrebno.

**Q3: Clock domain crossing?**

Original ima odvojene clockove za:
- CPU (~1.79 MHz)
- Video (108 MHz)
- HPS interface (50 MHz) - nije potreban za ULX3S

Za ULX3S:
- CPU clock generirati prescalerom iz pixel clocka
- Pazljivo sinkronizirati pixel_x/y i pixel_available signale

### 5.3 Testiranje

**Faza 1 Test:**
```
1. Color bars na HDMI
2. VGA timing validacija (1280x1024@60Hz ili @50Hz)
```

**Faza 2 Test:**
```
1. ROM content verificacija (font, console background)
2. RAM read/write ciklusi
```

**Faza 3 Test:**
```
1. Jednostavan pixel fadeout test (jedan piksel, promatraj decay)
2. Spacewar! - ako radi, sve radi!
```

---

## 6. Reference

### 6.1 Dokumentacija

| Dokument | Link |
|----------|------|
| ECP5 Memory Usage Guide | https://www.latticesemi.com/-/media/LatticeSemi/Documents/ApplicationNotes/EH/TN1264.ashx |
| FPGA Libraries Reference | https://www.latticesemi.com/-/media/LatticeSemi/Documents/UserManuals/EI/FPGALibrariesReferenceGuide33.ashx |
| altshift_taps User Guide | https://cdrdv2-public.intel.com/654554/ug_shift_register_ram_based.pdf |
| Yosys synth_ecp5 | https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/synth_lattice.html |
| Project Trellis | https://github.com/YosysHQ/prjtrellis |

### 6.2 GitHub Repozitoriji

| Repozitorij | Relevantnost |
|------------|--------------|
| https://github.com/emard/ulx3s | ULX3S hardware |
| https://github.com/emard/ulx3s-misc | ULX3S primjeri |
| https://github.com/lawrie/ulx3s_examples | Verilog primjeri |
| https://github.com/lawrie/ulx3s_sms | SMS emulator (porting pattern) |
| https://github.com/hrvach/fpg1 | Original PDP-1 |
| https://github.com/wtiandong/Hardware_circular_buffer_controller | Circular buffer |
| https://github.com/YosysHQ/oss-cad-suite-build | OSS CAD Suite |

### 6.3 Tutoriali

| Tutorial | Link |
|----------|------|
| Digital Delay with Dual-Port RAM | https://surf-vhdl.com/how-to-implement-a-digital-delay-using-a-dual-port-ram/ |
| ZipCPU FIFO | https://zipcpu.com/blog/2017/07/29/fifo.html |
| 8 Ways to Create Shift Register | https://vhdlwhiz.com/shift-register/ |
| Inferring RAMs in FPGAs | https://danstrother.com/2010/09/11/inferring-rams-in-fpgas/ |
| Project F FPGA Graphics | https://projectf.io/posts/fpga-graphics/ |

---

## 7. Zakljucak

Ako razmotrimo second-order efekte ovog portiranja, vidimo da je **pixel_ring_buffer** kljucna komponenta koja odredjuje uspjeh cijelog projekta. Altera altshift_taps pruza elegantno rjesenje koje ECP5 nema kao nativni primitiv.

**Preporuceni pristup:**

1. Implementirati `line_shift_register` prvo (jednostavniji, 1 tap)
2. Testirati blur kernel u izolaciji
3. Implementirati `pixel_ring_buffer` s time-multiplexed pristupom
4. Ako performanse nisu dovoljne, razmotriti replicirani BRAM
5. Finalno testiranje sa Spacewar!

**Procijenjeno vrijeme:** 12-18 radnih dana za kompletni port

**Najveci rizik:** Timing closure za 8-tap pixel_ring_buffer na 108 MHz

---

*"Vidim pattern koji povezuje ova dva domena - Altera i Lattice pristup memoriji je fundamentalno drugaciji, ali behavioral Verilog premoscuje tu razliku ako smo dovoljno pazljivi s timing constraints."*

-- Manda Peric, REGOC
