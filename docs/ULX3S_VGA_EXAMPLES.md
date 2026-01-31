# ULX3S VGA/HDMI Primjeri i Timing Analiza

**Autor:** Grga Kovacevic, RTL dizajner
**Datum:** 2026-01-31
**Svrha:** Analiza radnih VGA primjera za ULX3S i usporedba s nasim definitions.v

---

## 1. Pronazeni Radni Primjeri

### 1.1 Emardovi Repozitoriji (Autor ULX3S ploce)

| Repozitorij | Opis | Link |
|-------------|------|------|
| **ulx3s-misc** | Glavni repozitorij s naprednim primjerima | https://github.com/emard/ulx3s-misc |
| **fpga_snake_game** | VHDL-Verilog mix s VGA-to-HDMI | https://github.com/emard/fpga_snake_game |
| **prjtrellis-dvi** | DVI implementacija za Project Trellis | https://github.com/emard/prjtrellis-dvi |
| **hdmi-audio** | HDMI s audio podrskom | https://github.com/emard/hdmi-audio |

### 1.2 Ostali Testirani Projekti

| Projekt | Autor | Opis |
|---------|-------|------|
| **my_hdmi_device** | splinedrive | Cista HDMI implementacija za ULX3S, icestick, arty7 |
| **ulx3s_zx_spectrum** | lawrie | ZX Spectrum core s HDMI/VGA |
| **ulx3s_sms** | lawrie | Sega Master System s VGA-to-HDMI |
| **learn-fpga** | BrunoLevy | FemtoRV tutorial s HDMI za ULX3S |

---

## 2. VESA DMT Standard za 640x480@60Hz

**Sluzbeni VESA Display Monitor Timing (DMT) v1.13:**

### Horizontalni Timing (u pikselima)
| Parametar | Vrijednost | Trajanje |
|-----------|------------|----------|
| Active Pixels | 640 | 25.422 us |
| Front Porch | 16 | 0.636 us |
| Sync Width | 96 | 3.813 us |
| Back Porch | 48 | 1.907 us |
| **Blanking Total** | **160** | 6.356 us |
| **Total Pixels** | **800** | 31.778 us |
| Sync Polarity | **NEGATIVE** | - |

### Vertikalni Timing (u linijama)
| Parametar | Vrijednost |
|-----------|------------|
| Active Lines | 480 |
| Front Porch | 10 |
| Sync Width | 2 |
| Back Porch | 33 |
| **Blanking Total** | **45** |
| **Total Lines** | **525** |
| Sync Polarity | **NEGATIVE** |

### Pixel Clock
- **Standard:** 25.175 MHz
- **Prakticno:** 25 MHz (radi na vecini monitora)
- **Preporuceno:** 25.2 MHz (unutar VESA tolerancije od 0.5%)
- **Refresh Rate:** 25.175M / (800 * 525) = **59.94 Hz**

---

## 3. Emardov Pristup Racunanju VGA Timinga

Emard koristi **dinamicko racunanje** umjesto fiksnih tablica:

```verilog
// Iz ulx3s-misc/examples/dvi/top/top_vgatest.v

parameter x = 640,      // horizontal resolution
parameter y = 480,      // vertical resolution
parameter f = 60,       // refresh frequency

// Automatsko racunanje blanking intervala
localparam xminblank = x/64;           // = 10 za 640
localparam yminblank = y/64;           // = 7 za 480

// Pronalazak odgovarajuce frekvencije piksela
localparam min_pixel_f = f*(x+xminblank)*(y+yminblank);
localparam pixel_f = F_find_next_f(min_pixel_f);  // 25 MHz

// Ukupni frame
localparam yframe = y + yminblank;     // = 487
localparam xframe = pixel_f/(f*yframe); // racuna se

// Blanking
localparam xblank = xframe - x;
localparam yblank = yframe - y;

// Sync timing - podjela blanking intervala na 3 dijela
localparam hsync_front_porch = xblank/3;
localparam hsync_pulse_width = xblank/3;
localparam hsync_back_porch  = xblank - pulse_width - front_porch + xadjustf;

localparam vsync_front_porch = yblank/3;
localparam vsync_pulse_width = yblank/3;
localparam vsync_back_porch  = yblank - pulse_width - front_porch + yadjustf;
```

### Emardov vga.vhd - Konkretne Vrijednosti za 640x480

Iz datoteke `ulx3s-misc/examples/dvi/hdl/vga.vhd`:

```
Horizontal (u pikselima):
- Visible:     640
- Front Porch: 16
- Sync Pulse:  96
- Back Porch:  44   <-- RAZLIKA! Standard kaze 48

Timing Points:
- Blank ON:    639
- Sync ON:     655
- Sync OFF:    751
- Blank OFF:   799

Vertical (u linijama):
- Visible:     480
- Front Porch: 10
- Sync Pulse:  2
- Back Porch:  31   <-- RAZLIKA! Standard kaze 33

Timing Points:
- Blank ON:    479
- Sync ON:     489
- Sync OFF:    491
- Blank OFF:   524
```

**Napomena:** Emardove vrijednosti za back porch su malo manje (44 vs 48 i 31 vs 33), ali ukupni frame je isti (800x525).

---

## 4. Usporedba s Nasom Implementacijom

### Nasa definitions.v (/home/klaudio/port_fpg1/src/definitions.v)

```verilog
/* 640 x 480 @ 60 Hz constants */

`define   h_front_porch          11'd16
`define   h_back_porch           11'd48
`define   h_sync_pulse           11'd96

`define   v_sync_pulse           11'd2
`define   v_front_porch          11'd10
`define   v_back_porch           11'd33

`define   h_line_timing          11'd800
`define   v_line_timing          11'd525

`define   h_visible_offset       11'd160    // h_fp + h_sync + h_bp = 16+96+48 = 160
`define   v_visible_offset       11'd45     // v_fp + v_sync + v_bp = 10+2+33 = 45
```

### Analiza Offset Vrijednosti

| Parametar | Nasa Vrijednost | Izracun | VESA Standard | Status |
|-----------|-----------------|---------|---------------|--------|
| h_visible_offset | 160 | 16+96+48 = 160 | 16+96+48 = 160 | **ISPRAVNO** |
| v_visible_offset | 45 | 10+2+33 = 45 | 10+2+33 = 45 | **ISPRAVNO** |
| h_line_timing | 800 | 640+160 = 800 | 800 | **ISPRAVNO** |
| v_line_timing | 525 | 480+45 = 525 | 525 | **ISPRAVNO** |

### Detaljna Usporedba

| Parametar | Nase | VESA DMT | Emard | Status |
|-----------|------|----------|-------|--------|
| h_front_porch | 16 | 16 | 16 | OK |
| h_sync_pulse | 96 | 96 | 96 | OK |
| h_back_porch | 48 | 48 | 44 | Mi = VESA |
| v_front_porch | 10 | 10 | 10 | OK |
| v_sync_pulse | 2 | 2 | 2 | OK |
| v_back_porch | 33 | 33 | 31 | Mi = VESA |
| **Blanking H** | **160** | **160** | **156** | - |
| **Blanking V** | **45** | **45** | **43** | - |

---

## 5. Zakljucak

### Nase Vrijednosti su ISPRAVNE

- `h_visible_offset = 160` - **TOCNO** prema VESA DMT standardu
- `v_visible_offset = 45` - **TOCNO** prema VESA DMT standardu

### Razlike od Emarda

Emard koristi malo manje back porch vrijednosti (44 vs 48 horizontal, 31 vs 33 vertical), ali to je prihvatljivo jer:
1. Ukupni frame ostaje 800x525
2. Emard ima fine-tune parametre (`xadjustf`, `yadjustf`) za korekciju
3. Oba pristupa rade na vecini monitora

### Varijacije u Izvorima

Postoje varijacije u razlicitim izvorima:

| Izvor | H Back Porch | V Back Porch | V Front Porch |
|-------|--------------|--------------|---------------|
| VESA DMT | 48 | 33 | 10 |
| Project F | 48 | 33 | 10 |
| MIT 6.111 | 48 | 31 | 11 |
| Martin Hinner | 40 | 25 | 2 |
| Emard | 44 | 31 | 10 |

**Preporuka:** Koristiti VESA DMT vrijednosti (koje mi vec koristimo) jer su to sluzbene specifikacije.

---

## 6. Testirane Rezolucije u Emardovim Primjerima

Emardov `top_vgatest.v` podrzava:
- 640x400
- **640x480** (default)
- 720x576
- 800x480
- 800x600
- 1024x768
- 1280x768
- 1366x768
- 1280x1024
- 1920x1080
- 1920x1200

---

## 7. Kljucne HDL Datoteke u Emardovim Primjerima

```
ulx3s-misc/examples/dvi/
├── hdl/
│   ├── vga.vhd          # VGA timing generator
│   ├── vga2dvid.vhd     # VGA to DVI/HDMI encoder
│   ├── tmds_encoder.vhd # TMDS encoding
│   └── fake_differential.v
├── top/
│   ├── top_vgatest.v    # Verilog top modul
│   └── vhdl/
│       └── top_vgatest.vhd
├── Makefile
└── makefile.trellis
```

---

## 8. Reference

- VESA DMT v1.13: https://glenwing.github.io/docs/VESA-DMT-1.13.pdf
- Project F Timing: https://projectf.io/posts/video-timings-vga-720p-1080p/
- Emard ulx3s-misc: https://github.com/emard/ulx3s-misc
- splinedrive my_hdmi_device: https://github.com/splinedrive/my_hdmi_device
- MIT VGA Lab: https://web.mit.edu/6.111/www/s2004/NEWKIT/vga.shtml
- ULX3S Community: https://ulx3s.github.io/

---

## 9. Preporuke za Debugiranje

Ako VGA ne radi:

1. **Provjeri pixel clock** - Mora biti 25 MHz (ili 25.175 MHz)
2. **Provjeri sync polaritet** - Mora biti NEGATIVE za oba
3. **Provjeri redoslijed blanking perioda:**
   ```
   Horizontal: [Active 640] [Front 16] [Sync 96] [Back 48] = 800
   Vertical:   [Active 480] [Front 10] [Sync 2] [Back 33] = 525
   ```
4. **Ako je slika pomaknuta:**
   - Lijevo/Desno: Podesi h_front_porch / h_back_porch
   - Gore/Dolje: Podesi v_front_porch / v_back_porch

---

**ZAKLJUCAK: Nase VGA timing vrijednosti u definitions.v su TOCNE prema VESA DMT standardu i trebale bi raditi na ULX3S.**
