# FPG-1 Arhitektura Portiranja: Altera Cyclone V -> Lattice ECP5

**Autor:** Kosjenka Vukovic, REGOC arhitektica
**Datum:** 2026-01-31
**Task:** TASK-122

---

## 1. Struktura Projekata

### 1.1 Usporedba Direktorija

| Lokacija | Original (fpg1) | Emard Partial Port |
|----------|-----------------|-------------------|
| Platforma | Altera Cyclone V (MiSTer/DE10-Nano) | Lattice ECP5 (ULX3S) |
| Toolchain | Quartus | Diamond/Trellis |
| Input Clock | 50 MHz | 25 MHz |

### 1.2 Datoteke - Usporedba

#### Identicne datoteke (prenesene bez izmjena):
- `cpu.v` - PDP-1 CPU implementacija
- `keyboard.v` - Tipkovnica mapping
- `pdp1_vga_console.v` - Console prikaz
- `pdp1_vga_typewriter.v` - Teletype emulacija

#### Modificirane datoteke:
| Datoteka | Originalna | Emard verzija | Status |
|----------|------------|---------------|--------|
| `pdp1_vga_crt.v` | Altera altsyncram/altshift_taps | Placeholder s intentional syntax error | **NEDOVRSENO** |
| `memory.v` | Altera altsyncram/altshift_taps/lpm_divide | Razdvojeno u vise modula | **DJELOMICNO** |
| `definitions.v` | 1280x1024@60Hz | Symlink -> definitions-1280x1024-50Hz.v | Prilagodeno |

#### Nove datoteke u Emard verziji:
```
src/emard/
  ├── emu.v                      # Pojednostavljena top-level emu instanca
  ├── top_pdp1.v                 # ULX3S top modul
  ├── pixel_ring_buffer.v        # PLACEHOLDER - intentional syntax error!
  ├── line_shift_register.v      # PLACEHOLDER - intentional syntax error!
  ├── pdp1_vga_rowbuffer.v       # Portirana genericka BRAM verzija
  ├── pdp1_vga_crt.v             # Kopija originala (potrebna adaptacija)
  ├── pdp1_cpu_alu_div.v         # PLACEHOLDER za hardware divider
  ├── pdp1_terminal_charset.v    # PLACEHOLDER
  ├── pdp1_terminal_fb.v         # PLACEHOLDER
  ├── shift_register_generator.c # Helper za generiranje VHDL shift registara
  └── video/
      ├── vga.vhd                # Genericka VGA timing generacija
      ├── vga2dvid.vhd           # VGA to DVI/HDMI encoder
      ├── tmds_encoder.vhd       # TMDS encoding za HDMI
      └── fake_differential.v    # Pseudo-diferencijalni izlaz za ECP5
```

---

## 2. Altera-Specific Komponente

### 2.1 Katalog Svih Altera Primitiva

| Primitiv | Lokacija | Namjena | Kriticnost |
|----------|----------|---------|------------|
| `altera_pll` | apll.vhd, pll.v, sys/pll*.v | Clock generacija | **VISOKA** |
| `altsyncram` | memory.v (6x instanci) | Block RAM | **VISOKA** |
| `altshift_taps` | memory.v (2x instanci) | Shift register s tapovima | **KRITICNA** |
| `lpm_divide` | memory.v | Hardware divider | SREDNJA |
| `altera_pll_reconfig` | sys/pll_hdmi_cfg/ | Dinamicka PLL rekonfiguracija | NISKA* |

*Nije potrebno za basic port

### 2.2 Detaljna Analiza po Komponenti

#### 2.2.1 `altsyncram` - Block RAM

**Originalne instance:**

| Modul | Velicina | Tip | Init File |
|-------|----------|-----|-----------|
| `pdp1_terminal_charset` | 4096 x 16 bit | ROM | fiodec_charset.mif |
| `pdp1_vga_rowbuffer` | 8192 x 8 bit | Dual-port RAM | - |
| `pdp1_terminal_fb` | 2000 x 8 bit | Dual-port RAM | - |
| `console_bg_image` | 45056 x 32 bit | ROM | console_bg.mif |
| `pdp1_main_ram` | 4096 x 18 bit | True dual-port | spacewar.mif |

**Ukupna BRAM potrosnja:** ~1.5 Mbit

#### 2.2.2 `altshift_taps` - **KRITICNA KOMPONENTA**

Ovo je najzahtjevnija komponenta za port!

**Instance:**

| Modul | Width | Taps | Tap Distance | Ukupna Memorija |
|-------|-------|------|--------------|-----------------|
| `line_shift_register` | 8 bit | 1 | 1685 | 13.5 Kbit (x3) |
| `pixel_ring_buffer` | 32 bit | 8 | 1024 | 262 Kbit (x4) |

**Ukupno za shift registre:** ~1.1 Mbit

---

## 3. ECP5 Mapiranje

### 3.1 Tablica Ekvivalenata

| Altera Primitiv | ECP5 Ekvivalent | Metoda | Kompleksnost |
|-----------------|-----------------|--------|--------------|
| `altera_pll` | `EHXPLLL` | ecppll tool / manual instantiation | Srednja |
| `altsyncram` (SP ROM) | `$readmemh` + reg array ILI `EBR` primitive | Behavioral/Primitive | Niska |
| `altsyncram` (DP RAM) | `DPRAM` ili behavioral | Behavioral | Niska |
| `altsyncram` (TDP RAM) | `PDPW16KD` ili behavioral | Primitive/Behavioral | Srednja |
| `altshift_taps` | **Nema ekvivalenta** - custom implementacija | Vidi sekciju 4 | **VISOKA** |
| `lpm_divide` | Behavioral `/` operator ili pipeline | Behavioral | Srednja |

### 3.2 ECP5 Resursi (ULX3S 85F)

| Resurs | Dostupno | Potrebno (procjena) |
|--------|----------|---------------------|
| LUT4 | 83,640 | ~15,000 |
| EBR (18Kbit blocks) | 208 | ~150 |
| DSP blocks | 156 | 2-4 (divider) |
| PLL | 4 | 2 |

---

## 4. pixel_ring_buffer Analiza - **KRITICNA KOMPONENTA**

### 4.1 Funkcionalnost

`pixel_ring_buffer` je LFSR-based circular buffer koji simulira CRT phosphor decay. Ovo je **srce Type 30 CRT emulacije**.

### 4.2 Specifikacije

```
Parametri (iz memory.v):
  - Width: 32 bita
  - Number of taps: 8
  - Tap distance: 1024
  - Total depth: 8 x 1024 = 8192 lokacija
  - Total memory: 8192 x 32 = 262,144 bita = 256 Kbit

Format 32-bitnog zapisa:
  [31:22] pixel_y (10 bit)
  [21:12] pixel_x (10 bit)
  [11:0]  luma/brightness (12 bit)
```

### 4.3 Kako se koristi (pdp1_vga_crt.v analiza)

```verilog
// 4 ring buffera povezana u petlju ("hadron collider style"):
pixel_ring_buffer ring_buffer_1(.clock(clk), .shiftin(shiftout_1), .shiftout(shiftout_1_w), .taps(taps1));
pixel_ring_buffer ring_buffer_2(.clock(clk), .shiftin(shiftout_2), .shiftout(shiftout_2_w), .taps(taps2));
pixel_ring_buffer ring_buffer_3(.clock(clk), .shiftin(shiftout_3), .shiftout(shiftout_3_w), .taps(taps3));
pixel_ring_buffer ring_buffer_4(.clock(clk), .shiftin(shiftout_4), .shiftout(shiftout_4_w), .taps(taps4));

// Povezivanje: 1->2->3->4->1 (circular)
// Na svakom spoju, pikseli se "stare" (dim_pixel funkcija)
```

### 4.4 Algoritam CRT Fadeout-a

1. **Novi piksel** dolazi od CPU (pixel_x, pixel_y, brightness=4095)
2. **Pretraga tapova** - trazi se postojeci piksel s istim koordinatama
3. **Update ili Insert**:
   - Ako postoji: refresh brightness na 4095
   - Ako ne postoji i pronadje se prazan slot: insert
4. **Aging** - na svakom 8. frame-u, brightness se smanjuje za 1
5. **Row buffer** - 8 linija unaprijed se popunjava iz tapova

### 4.5 Implementacijski Pristup za ECP5

**Opcija A: Behavioral BRAM + Registri za tapove**
```verilog
// Koristiti EBR kao shift registar s eksplicitnim tapovima
reg [31:0] shift_mem [0:8191];
reg [12:0] write_ptr;
wire [12:0] tap_addr[7:0];

// Tapovi na fiksnim razmacima
assign tap_addr[0] = write_ptr - 1024*1;
assign tap_addr[1] = write_ptr - 1024*2;
// ... itd
```

**Opcija B: Emardov shift_register_generator.c**
- Generira VHDL kod za shift register s tapovima
- Podrzava Xilinx i Altera mode
- Moguce prilagoditi za ECP5

**Preporuka:** Opcija A s pazljivim timing analizom

---

## 5. Clock Zahtjevi

### 5.1 Originalna PLL Konfiguracija (Altera)

| PLL | Input | Output | Namjena |
|-----|-------|--------|---------|
| `pll` | 50 MHz | 108 MHz | Pixel clock (1280x1024@60Hz) |
| `apll` | 50 MHz | 1.791044 MHz | CPU clock (PDP-1 timing) |
| `apll` | 50 MHz | 0.895522 MHz | Sekundarni CPU clock |

### 5.2 ECP5 PLL Konfiguracija (ULX3S)

ULX3S ima 25 MHz ulazni clock. Potrebna prilagodba:

| Clock | Frekvencija | Izracun | Napomena |
|-------|-------------|---------|----------|
| clk_shift | 540 MHz | 25 * 108/5 | Za HDMI TMDS encoding |
| clk_pixel | 108 MHz | 25 * 108/25 | 1280x1024@60Hz ILI 75 MHz za 1280x1024@50Hz |
| clk_cpu | ~1.79 MHz | Divider od pixel clock | PDP-1 instruction timing |

**ECP5 PLL ogranicenja:**
- VCO: 400-800 MHz
- Output divider: 1-128
- Feedback divider: 1-80

### 5.3 Preporucena Clock Arhitektura

```
                    +-> clk_pixel (108 MHz) --> VGA/Video
                    |
clk_25mhz --> PLL1 -+-> clk_shift (540 MHz) --> HDMI TMDS
                    |
                    +-> clk_cpu_base (50 MHz)
                              |
                              v
                        Prescaler --> clk_cpu (~1.79 MHz)
```

---

## 6. Preporuceni Pristup Portiranju

### Faza 1: Infrastruktura (1-2 dana)
1. [ ] ECP5 PLL instantiation za clk_pixel i clk_shift
2. [ ] HDMI/DVI output testiranje (koristiti Emardove vga2dvid komponente)
3. [ ] Bazni video timing (1280x1024@60Hz ili prilagoditi na @50Hz)

### Faza 2: Memorijski Primitivi (2-3 dana)
1. [ ] Portirati `pdp1_main_ram` - true dual-port BRAM
2. [ ] Portirati `pdp1_terminal_charset` - ROM s .mif inicijalizacijom
3. [ ] Portirati `pdp1_vga_rowbuffer` - dual-port RAM (vec postoji Emardova verzija!)
4. [ ] Portirati `pdp1_terminal_fb` - dual-port RAM
5. [ ] Portirati `console_bg_image` - ROM

### Faza 3: Kriticni Shift Registri (3-5 dana)
1. [ ] Implementirati `line_shift_register` za ECP5
2. [ ] **Implementirati `pixel_ring_buffer`** - najslozeniji dio!
3. [ ] Integrirati u pdp1_vga_crt.v
4. [ ] Testirati CRT phosphor decay vizualno

### Faza 4: CPU i Periferija (1-2 dana)
1. [ ] Portirati/zamijeniti `lpm_divide` s behavioral implementacijom
2. [ ] Integrirati CPU (cpu.v je vec portabilan)
3. [ ] Keyboard i joystick mapping za ULX3S

### Faza 5: Integracija i Testiranje (2-3 dana)
1. [ ] Full system integration
2. [ ] Testiranje sa Spacewar!
3. [ ] Timing closure i optimizacije

**Ukupna procjena:** 10-15 radnih dana

---

## 7. Rizici i Mitigacije

### 7.1 Visoki Rizici

| Rizik | Vjerojatnost | Utjecaj | Mitigacija |
|-------|--------------|---------|------------|
| `pixel_ring_buffer` timing failure | Visoka | Kriticno | Pipelinirati pristup tapovima, mozda smanjiti broj tapova |
| BRAM nedostatak | Srednja | Visoko | Koristiti SDRAM za manje kriticne buffere |
| Clock domain crossing problemi | Srednja | Visoko | Pazljivo sinkronizirati cpu_clk <-> pixel_clk |

### 7.2 Srednji Rizici

| Rizik | Vjerojatnost | Utjecaj | Mitigacija |
|-------|--------------|---------|------------|
| .mif format nekompatibilnost | Visoka | Srednje | Konvertirati u $readmemh format |
| Video timing razlike | Srednja | Srednje | Testirati s vise monitora, prilagoditi timinge |
| PLL lock problemi | Niska | Visoko | Dodati proper reset sequencing |

### 7.3 Otvorena Pitanja

1. **Da li zadrzati 1280x1024@60Hz?**
   - Pro: Originalna rezolucija
   - Con: 108 MHz je na granici za neke ECP5 HDMI enkodere
   - Alternativa: 1280x1024@50Hz (75 MHz pixel clock)

2. **pixel_ring_buffer - koliko je tapova minimalno potrebno?**
   - Original: 8 tapova
   - Mozda dovoljno 4 tapa s manjim tap_distance?
   - Potrebno eksperimentiranje

3. **Treba li hardware divider?**
   - Original koristi `lpm_divide` s 34-stage pipeline
   - Alternativa: software emulacija (PDP-1 DIV je rijedak)

---

## 8. Reference

- Original fpg1: `/home/klaudio/port_fpg1/fpg1/`
- Emard partial port: `/home/klaudio/port_fpg1/fpg1_partial_emard/`
- Emard ULX3S dokumentacija: https://github.com/emard/ulx3s
- ECP5 Primitives User Guide: FPGA-TN-02032
- Altera altshift_taps: ug_altshift_taps.pdf

---

*Arhitektura sugerira postepeni pristup - prvo stabilna video infrastruktura, zatim memorijski primitivi, i na kraju kriticni CRT emulacijski pipeline.*
