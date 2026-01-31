# FPGA Learnings - VGA i Row Buffer

Dokument s naučenim lekcijama tijekom razvoja FPGA projekta.

---

## VGA 640x480@60Hz Timing Parametri

### Osnovni parametri (Industry Standard)

| Parametar | Vrijednost |
|-----------|------------|
| **Pixel Clock** | 25.175 MHz (25.2 MHz prihvatljivo, 25 MHz radi na vecini monitora) |
| **Refresh Rate** | 59.940 Hz |
| **Horizontal Frequency** | 31.469 kHz |

### Horizontalni timing (piksel)

| Regija | Pikseli | Vrijeme |
|--------|---------|---------|
| Active Display | 640 | 25.42 us |
| Front Porch | 16 | 0.64 us |
| Sync Pulse | 96 | 3.81 us |
| Back Porch | 48 | 1.91 us |
| **TOTAL** | **800** | **31.78 us** |

**Sync Polarity: NEGATIVNA**

### Vertikalni timing (linije)

| Regija | Linije | Vrijeme |
|--------|--------|---------|
| Active Display | 480 | 15.25 ms |
| Front Porch | 10 | 0.32 ms |
| Sync Pulse | 2 | 0.06 ms |
| Back Porch | 33 | 1.05 ms |
| **TOTAL** | **525** | **16.68 ms** |

**Sync Polarity: NEGATIVNA**

### Kljucne formule

```
Total piksela po frameu = 800 x 525 = 420,000
Frame vrijeme = 420,000 / 25.175 MHz = 16.68 ms
Frame rate = 1 / 16.68 ms = 59.94 Hz
```

**Izvori:**
- [Project F - Video Timings](https://projectf.io/posts/video-timings-vga-720p-1080p/)
- [TinyVGA](http://tinyvga.com/vga-timing/640x480@60Hz)

---

## Dual-Port RAM i Read/Write Konflikti

### Problem: Simultani pristup istoj adresi

Kada VGA kontroler cita iz RAM-a dok drugi proces (CPU, UART, itd.) pise na istu adresu, mogu se dogoditi:

1. **Read-Write konflikt**: Procitana vrijednost moze biti stara, nova, ili nedefinirana
2. **Write-Write konflikt**: Rezultat je nepredvidiv
3. **Metastabilnost**: Pri razlicitim clock domenama, flip-flopovi mogu uci u metastabilno stanje

### Ponasanje ovisno o clocku

- **Isti clock za read/write**: Nova vrijednost pojavljuje se nakon falling edge clocka
- **Read clock > 2x Write clock**: Read pristupa starim podacima jer write jos nije zavrsen
- **Asinkroni clockovi**: Ponasanje nepredvidivo, potrebna sinkronizacija

### Rjesenja

1. **Arhitekturno izbjegavanje**: Osigurati da read i write nikad ne pristupaju istoj adresi istovremeno
2. **Redundantni read ciklusi**: Ponavljati citanje dok write nije zavrsen
3. **Dodjela adresnih raspona**: Svaki port pise samo u svoj dio memorije
4. **Bypass logika**: Neki FPGA imaju ugraden bypass koji detektira dual access
5. **Double-registering**: Dva stupnja sinkronizacijskih flip-flopova za clock domain crossing

**Izvori:**
- [Intel - Simultaneous read/write dual-port RAM](https://www.intel.com/content/www/us/en/programmable/support/support-resources/knowledge-base/solutions/rd09081999_538.html)
- [AMD/Xilinx - True dual port RAM concepts](https://adaptivesupport.amd.com/s/question/0D52E00006hpTmTSAU/)

---

## VGA Line Buffer - Timing i Implementacija

### Zasto koristiti Line Buffer?

Line buffer daje rendererima "buffer vrijeme". Npr. za 640 aktivnih piksela, imamo 800 piksela ukupno - horizontal retrace vrijeme (160 piksela) je "ekstra vrijeme" za pripremu sljedece linije.

### Implementacija s ALTSHIFT_TAPS (Altera)

```verilog
module Line_Buffer (
    input clken,
    input clock,
    input [15:0] shiftin,
    output [15:0] shiftout,
    output [15:0] taps
);
    altshift_taps altshift_taps_component (
        .clken (clken),
        .clock (clock),
        .shiftin (shiftin),
        .taps (sub_wire0),
        .shiftout (sub_wire1)
    );

    defparam
        altshift_taps_component.tap_distance = 640,  // delay za jednu liniju
        altshift_taps_component.width = 16;
endmodule
```

### Kljucni parametri

- **tap_distance = 640**: Delay jednak broju aktivnih piksela po liniji
- **width**: Sirina podataka (obicno 12-16 bita za RGB)

**Izvor:**
- [fpganes Line_Buffer.v](https://github.com/jpwright/fpganes/blob/master/cam_to_vga/Line_Buffer.v)

---

## Ceste Greske s Adresiranjem Row Buffera

### 1. Pipeline delay

**Problem**: Block RAM na FPGA-u je sinkroni - read operacija uvijek traje jedan clock ciklus.

```
hcount signal mijenja se svaki piksel ciklus
Ako hcount direktno dajemo na tileset address generator -> output kasni 1 ciklus
Rezultat: Graficki glitch, slika pomaknuta za 1 piksel
```

**Rjesenje**: Dodati pipeline registar na hcount signal.

### 2. Counter wraparound

**Problem**: Horizontalni brojac mora se resetirati na 799 (ne 800!), vertikalni na 524.

```verilog
// KRIVO - resetira se na 800, jedan piksel viska
if (hcount == 800) hcount <= 0;

// TOCNO - resetira se kada dostigne 799
if (hcount == 799) hcount <= 0;
```

### 3. Adresa za frame buffer

**Ispravna formula**:
```
address = hcount + vcount * 640
```

**Optimizacija mnozenja s 640**:
```
640 = 512 + 128 = 2^9 + 2^7
address = hcount + (vcount << 9) + (vcount << 7)
```

### 4. Clock domain crossing

**Problem**: Koristenje generiranog 25MHz clocka za VGA logiku uzrokuje routing skew i signal jitter.

**Rjesenje**: Koristiti Clock Enable signal na globalnom 100MHz clock networku:

```verilog
// Umjesto generiranog 25MHz clocka
reg [1:0] clk_div;
wire pixel_clk_en = (clk_div == 2'b00);

always @(posedge clk_100MHz)
    clk_div <= clk_div + 1;

always @(posedge clk_100MHz)
    if (pixel_clk_en) begin
        // VGA logika ovdje
    end
```

**Izvori:**
- [ZipCPU - Building a video controller](https://zipcpu.com/blog/2018/11/29/llvga.html)
- [Columbia University - VGA Tile Graphics](https://www.cs.columbia.edu/~sedwards/classes/2025/4840-spring/tiles.pdf)

---

## "Stisnuta" Slika - Uzroci i Rjesenja

### Mogudi uzroci

1. **Krivi timing parametri**
   - Front porch, sync, back porch nisu tocni
   - Total pixels/lines nije 800/525

2. **Pixel clock greska**
   - Clock nije 25.175 MHz (ili blizu)
   - Clock jitter uzrokuje neravnomjerni razmak piksela

3. **Row buffer read/write konflikt**
   - Pisanje u buffer dok VGA cita
   - Rezultat: dio linije pokazuje stare podatke

4. **Counter wraparound greska**
   - Brojac se resetira prerano ili prekasno
   - Rezultat: linije su krace/duze od ocekivanog

5. **Pipeline mismatch**
   - Podaci iz memorije kasne za adresnim signalima
   - Rezultat: slika pomaknuta horizontalno

### Dijagnostika

1. **Bijeli okvir oko slike**: Test pattern s bijelim okvirom otkriva gubitak piksela na rubovima
2. **Verilator simulacija**: Sporija simulacija omoguduje frame-by-frame inspekciju
3. **Signal analyzer**: Provjera hsync/vsync perioda i polariteta

### Double Buffering

**Ping-pong konfiguracija** sprecava flickering:
- Izvor pise u RAM A dok VGA cita iz RAM B
- Na kraju framea, A i B se zamijene
- Swap se radi tijekom VBLANK perioda

```verilog
// Swap buffera na VBLANK
always @(posedge clk)
    if (vsync_falling_edge)
        active_buffer <= ~active_buffer;
```

**Izvori:**
- [ZipCPU - Video controller](https://zipcpu.com/blog/2018/11/29/llvga.html)
- [Project F - Framebuffers](https://projectf.io/posts/framebuffers/)
- [fpgarelated - Double buffering](https://www.fpgarelated.com/showthread/comp.arch.fpga/55681-1.php)

---

## Korisni GitHub Repozitoriji

1. **[projf/display_controller](https://github.com/projf/display_controller)**
   - VGA, DVI, HDMI podrska
   - 640x480, 800x600, 1280x720, 1920x1080
   - Verilog, dobro dokumentirano

2. **[talsania/fpga-image-buffer](https://github.com/talsania/fpga-image-buffer)**
   - Dual-port BRAM framebuffer
   - UART loader
   - 640x480 VGA

3. **[jbp261/VGA-Timing-Controller](https://github.com/jbp261/VGA-Timing-Controller)**
   - Basys3 implementacija
   - Dobar za ucenje

4. **[stgloorious/fpga-vga](https://github.com/stgloorious/fpga-vga)**
   - Lattice iCE40UP5K
   - Open source toolchain

---

## Checklist za VGA Implementaciju

- [ ] Pixel clock je 25.175 MHz (ili 25.0/25.2 MHz)
- [ ] Horizontal total = 800 piksela
- [ ] Vertical total = 525 linija
- [ ] hsync i vsync polaritet je NEGATIVAN
- [ ] Brojaci se resetiraju na 799/524 (ne 800/525)
- [ ] Pipeline delay kompenziran za BRAM read
- [ ] Clock domain crossing pravilno rijesen (double-registering ili FIFO)
- [ ] Nema read/write konflikata u dual-port RAM-u
- [ ] Test pattern s bijelim okvirom pokazuje sve rubove

---

*Datum: 2026-01-31*
*Autor: Grga Kovacevic, RTL dizajner*

---

## PDP-1 KOORDINATNA TRANSFORMACIJA - KRITIČNO!

### ORIGINALNI PDP-1 KOORDINATNI SUSTAV
**PDP-1 Type 30 CRT ima DRUGAČIJI koordinatni sustav od VGA!**

```
PDP-1 CRT (1024x1024):        VGA/LCD (640x480):
  Origin: GORNJI DESNI         Origin: GORNJI LIJEVI
  X raste: LIJEVO              X raste: DESNO
  Y raste: DOLJE               Y raste: DOLJE
```

### ZAŠTO JE `~pixel_x_i` POTREBAN

Originalni FPG1 kod koristi ovu transformaciju:
```verilog
{ buffer_pixel_y, buffer_pixel_x } <= { ~pixel_x_i, pixel_y_i };
```

**Što ovo radi:**
1. `~pixel_x_i` - Bitwise NOT invertira X os (0→1023, 1023→0)
2. Swap X↔Y - Rotira koordinate za ispravnu orijentaciju
3. Rezultat: PDP-1 gornji desni = VGA gornji lijevi

**BEZ ove transformacije:**
- Dijagonala (0,0)→(511,511) završava u DESNOM kutu
- Slika je zrcaljena/rotirana

### ISPRAVNA FORMULA ZA ULX3S PORT

```verilog
// Za PDP-1 512x512 centriran u 640x480:
{ buffer_pixel_y[ptr], buffer_pixel_x[ptr] } <= { ~pixel_x_i, pixel_y_i };

// Debug write (ako se koristi):
debug_wr_addr <= {(~pixel_x_i)[2:0], pixel_y_i};
```

### h_visible_offset_end FIX

```verilog
// POGREŠNO (trenutno):
`define h_visible_offset_end 11'd704  // Daje samo 544px vidljivo!

// ISPRAVNO:
`define h_visible_offset_end 11'd736  // 160 + 512 + 64 = 736
```

---

## PROJEKT KONTEKST - PDP-1 na ULX3S

### Što je ovaj projekt?
Port originalnog FPG1 (PDP-1 FPGA emulator) s MiSTer platforme (Cyclone V) na ULX3S (Lattice ECP5).

### Originalni repozitoriji:
- **hrvach/fpg1** - Originalna MiSTer implementacija
- **MiSTer-devel/PDP1_MiSTer** - Službeni MiSTer core
- **spacemen3/PDP-1** - Analogue Pocket port

### Ključne razlike MiSTer vs ULX3S:
| Aspekt | MiSTer (Cyclone V) | ULX3S (ECP5) |
|--------|-------------------|--------------|
| Rezolucija | 1280x1024 | 640x480 |
| Pixel clock | 108 MHz | 25 MHz |
| BRAM | Altsyncram | ECP5 DP16KD |
| Shift register | ALTSHIFT_TAPS | Manualni |

### Ring Buffer MINIMALNA verzija
`pixel_ring_buffer.v` je MINIMALNA verzija koja NE radi kao pravi shift register!
Tapovi se ažuriraju samo svakih 8 ciklusa - potrebna potpuna reimplementacija.

---

## REFERENCE

- [GitHub - hrvach/fpg1](https://github.com/hrvach/fpg1)
- [GitHub - MiSTer-devel/PDP1_MiSTer](https://github.com/MiSTer-devel/PDP1_MiSTer)
- [GitHub - emard/ulx3s-misc](https://github.com/emard/ulx3s-misc)
- [Project F - Framebuffers](https://projectf.io/posts/framebuffers/)
- [ZipCPU VGA Tutorial](https://zipcpu.com/blog/2018/11/29/llvga.html)
