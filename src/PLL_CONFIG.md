# PLL Configuration for ECP5 ULX3S

**TASK-124** | Generirao: Kosjenka Vukovic, REGOC tim | 2026-01-31

---

## Pregled

Projekt koristi Lattice ECP5 PLL za generiranje clockova potrebnih za HDMI video output na ULX3S ploci.

### Izabrana konfiguracija: 1280x1024 @ 50Hz

| Clock | Frekvencija | Namjena |
|-------|-------------|---------|
| Input | 25 MHz | ULX3S onboard oscillator |
| Pixel | 75 MHz | Video timing |
| Shift | 375 MHz | HDMI DDR TMDS (5x pixel) |
| CPU | 50 MHz | PDP-1 emulacija |

---

## Dostupni moduli

### 1. `clk_25_shift_pixel_cpu.sv` (PREPORUCENO)

Koristi **Emardov ecp5pll wrapper** za automatski izracun PLL parametara.

```systemverilog
clk_25_shift_pixel_cpu clock_gen (
    .clki   (clk_25mhz),    // 25 MHz input
    .clko   (clk_shift),    // 375 MHz HDMI shift
    .clks1  (clk_pixel),    // 75 MHz pixel
    .clks2  (clk_cpu),      // 50 MHz CPU
    .locked (clk_locked)
);
```

**Prednosti:**
- Parametarski - lako promjena frekvencija
- Automatski izracun VCO, dividera, faza
- Validacija granica (error ako frekvencija nije dostizna)

**Izvor wrappera:**
https://github.com/emard/ulx3s-misc/blob/master/examples/ecp5pll/hdl/sv/ecp5pll.sv

### 2. `pll_config.v` (manualna konfiguracija)

Direktna EHXPLLL instancijacija s precizno izracunatim parametrima.

Koristiti ako treba:
- Precizna kontrola nad fazama
- Specificni VCO operating point
- Debugging PLL problema

---

## Timing izracun

### 1280x1024 @ 50Hz

```
H visible:  1280 pixels
H blanking: 154 pixels (front=30, sync=64, back=60)
H total:    1434 pixels

V visible:  1024 lines
V blanking: 18 lines (front=3, sync=5, back=10)
V total:    1042 lines

Pixel clock = H_total * V_total * refresh_rate
            = 1434 * 1042 * 50.2 Hz
            = 74.99 MHz (zaokruzeno na 75 MHz)
```

### HDMI shift clock

Za DDR TMDS enkodiranje potreban je 5x pixel clock:
```
Shift clock = 75 MHz * 5 = 375 MHz
```

---

## ECP5 PLL specifikacije

| Parametar | Min | Max | Koristeno |
|-----------|-----|-----|-----------|
| VCO | 400 MHz | 800 MHz | 750 MHz |
| PFD | 3.125 MHz | 400 MHz | 25 MHz |
| Output | - | ~550 MHz* | 375 MHz |

*Speed grade -6 limit

### VCO izracun (75 MHz konfiguracija)

```
f_VCO = f_in * CLKFB_DIV / CLKI_DIV
      = 25 MHz * 30 / 1
      = 750 MHz

f_shift = f_VCO / CLKOP_DIV = 750 / 2 = 375 MHz
f_pixel = f_VCO / CLKOS_DIV = 750 / 10 = 75 MHz
f_cpu   = f_VCO / CLKOS2_DIV = 750 / 15 = 50 MHz
```

---

## Zasto NE 108 MHz (60Hz)?

1280x1024 @ 60Hz zahtijeva:
- Pixel clock: 108 MHz
- Shift clock: 540 MHz

**Problem:** 540 MHz je na samoj granici ECP5-85F specifikacija (~550 MHz za speed grade -6).

**Rizici:**
- Nestabilnost na visim temperaturama
- Varijacije izmedju chipova
- Potencijalni timing failures

**Odluka:** Koristimo 75 MHz (50Hz) za pouzdanu rad s marginom.

---

## Alternativne konfiguracije

### 640x480 @ 60Hz (VGA standard)
```systemverilog
ecp5pll #(
    .in_hz   (25000000),
    .out0_hz (125000000),  // 5x pixel za DDR
    .out1_hz (25000000)    // pixel clock
) ...
```

### 720p @ 60Hz (ako potrebno)
```systemverilog
ecp5pll #(
    .in_hz   (25000000),
    .out0_hz (371250000),  // 5x 74.25 MHz
    .out1_hz (74250000)    // pixel clock
) ...
```

---

## Reference

- [Emard ecp5pll](https://github.com/emard/ulx3s-misc/tree/master/examples/ecp5pll)
- [ULX3S dokumentacija](https://github.com/emard/ulx3s)
- [ECP5 sysCLOCK PLL/DLL Design Guide](https://www.latticesemi.com/~/media/LatticeSemi/Documents/ApplicationNotes/EH/TN1263.pdf)
- [VESA timing standardi](http://www.tinyvga.com/vga-timing)
