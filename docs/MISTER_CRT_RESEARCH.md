# MiSTer FPGA i CRT/Vector Display Emulacija - Istrazivanje

**Autorica:** Kosjenka Vukovic, FPGA arhitektica
**Datum:** 2026-01-31

## 1. SAZETAK

Ovaj dokument sadrzi istrazivanje implementacija CRT/vector display emulacije u MiSTer FPGA projektima i drugim relevantnim ULX3S/ECP5 primjerima. Fokus je na:
- Coordinate mapping za prikaz manjeg framebuffera na vecem ekranu
- Ispravne formule za h_visible_offset
- Rowbuffer vs framebuffer pristupi
- Jednostavni radni primjeri za referencu

---

## 2. VGA 640x480 TIMING - REFERENTNI PARAMETRI

### 2.1 Standardni VGA 640x480p60 Timing

```
Pixel Clock: 25.175 MHz (ili 25.2 MHz)

HORIZONTAL:
  h_visible     = 640 piksela
  h_front_porch = 16 piksela
  h_sync        = 96 piksela
  h_back_porch  = 48 piksela
  h_total       = 800 piksela

VERTICAL:
  v_visible     = 480 linija
  v_front_porch = 10 linija
  v_sync        = 2 linije
  v_back_porch  = 33 linije
  v_total       = 525 linija

Sync Polarity: NEGATIVAN (obje osi)
```

### 2.2 Modeline Format
```
"640x480_60" 25.175 640 656 752 800 480 490 492 525 -HSync -VSync
```

---

## 3. COORDINATE MAPPING: 512x512 NA 640x480

### 3.1 Problem

Nas framebuffer je 512x512, ali VGA output je 640x480:
- Horizontalno: 512 < 640 (imamo prostora za centriranje)
- Vertikalno: 512 > 480 (moramo cropati ili skalirati)

### 3.2 Opcije

#### OPCIJA A: Centriranje 512x480 (crop vertikalno)
```verilog
// Horizontalni offset za centriranje 512px u 640px
localparam H_OFFSET = (640 - 512) / 2;  // = 64 piksela

// Vertikalno: prikazujemo samo 480 od 512 linija
localparam V_OFFSET = (512 - 480) / 2;  // = 16 linija croppamo gore/dolje

// Vidljivo podrucje (relativno na VGA koordinate)
wire in_content_area = (h_counter >= H_OFFSET) &&
                       (h_counter < H_OFFSET + 512) &&
                       (v_counter < 480);

// Adresa u framebufferu
wire [8:0] fb_x = h_counter - H_OFFSET;  // 0-511
wire [8:0] fb_y = v_counter + V_OFFSET;  // 16-495 (crop)
```

#### OPCIJA B: Prikaz 480x480 centrirano
```verilog
// Centriranje 480x480 u 640x480
localparam H_OFFSET = (640 - 480) / 2;  // = 80 piksela

wire in_content_area = (h_counter >= H_OFFSET) &&
                       (h_counter < H_OFFSET + 480) &&
                       (v_counter < 480);

wire [8:0] fb_x = h_counter - H_OFFSET;  // 0-479
wire [8:0] fb_y = v_counter;             // 0-479
```

### 3.3 ISPRAVNA Formula za h_visible_offset

Iz istrazivanja Wayne Johnson bloga:
```verilog
// Umjesto prikaza na pozicijama 0-639, mozemo offsetati
// Primjer: boje aktivne od 50-689 horizontalno, 33-512 vertikalno

// To efektivno stvara:
// - Back porch (lijevo): 50 piksela
// - Front porch (desno): 110 piksela
// - Back porch (gore): 33 linije
// - Front porch (dolje): 12 linija

// Uvjet za prikaz:
if ((r_HPos >= 50) && (r_HPos < 690) &&
    (r_VPos >= 33) && (r_VPos < 513))
begin
    // Aktivni piksel
end
```

**KLJUCNA FORMULA:**
```verilog
// Za centriranje sadrzaja sirine W unutar 640px ekrana:
localparam H_VISIBLE_OFFSET = (640 - W) / 2;

// Za nas slucaj 512x480:
localparam H_VISIBLE_OFFSET = (640 - 512) / 2;  // = 64
localparam V_VISIBLE_OFFSET = 0;                 // vec 480 linija

// Provjera vidljivog podrucja:
wire in_visible = (h_cnt >= H_VISIBLE_OFFSET) &&
                  (h_cnt < H_VISIBLE_OFFSET + 512) &&
                  (v_cnt < 480);

// Koordinate za framebuffer pristup:
wire [8:0] content_x = h_cnt - H_VISIBLE_OFFSET;
wire [8:0] content_y = v_cnt;
```

---

## 4. MISTER VECTOR CORE IMPLEMENTACIJE

### 4.1 Asteroids/Tempest Pristup

MiSTer vector core-ovi koriste **double buffering**:
- Jedan buffer se renderira dok se drugi prikazuje
- Originalni beam control signali plotaju piksele u framebuffer
- Output je 480p (ne 15kHz CRT kompatibilno)

**Iz MiSTer foruma:**
> "All the rendering on the vector cores uses the original beam control
> signals to plot pixels on a frame buffer, usually double buffered so
> a completed image is being output to VGA while the next one is drawn."

### 4.2 PDP-1 Phosphor Decay Simulacija

PDP-1 MiSTer core koristi **ring buffer pristup** umjesto punog framebuffera:

```
Arhitektura:
- 4 ulancana shift registra (ring buffer)
- Svaki piksel: 32 bita = X(10b) + Y(10b) + brightness(12b)
- Pri svakom splice pointu, brightness se smanjuje
- Samo 8 redova se bufferira istovremeno (row buffer)

Prednosti:
- Stednja memorije (5.5 Mbit Cyclone V nema dovoljno za 1024x1024x8b)
- Realisticna simulacija P7 phosphor decay
```

**Blur efekt:**
```
3 dodatna shift registra u seriji (3 reda)
+ 3 registra po shift registru (3 piksela)
= 3x3 matrica za konvoluciju s blur kernelom
```

### 4.3 Kljucni zakljucci iz MiSTer projekata

1. **Double buffering je standard** - jedan buffer za renderiranje, jedan za prikaz
2. **Rowbuffer pristup** koristi se za phosphor simulaciju (PDP-1)
3. **Linebuffer** je koristan za skaliranje i clock domain crossing
4. **480p je standardna rezolucija** za vector core output

---

## 5. ULX3S/ECP5 VGA PRIMJERI

### 5.1 emard/ulx3s-misc - top_vgatest.v

Parametrizirani VGA modul koji podrzava vise rezolucija:

```verilog
module top_vgatest #(
    parameter x = 800,      // horizontalni pikseli
    parameter y = 600,      // vertikalni pikseli
    parameter f = 60,       // refresh rate Hz
    parameter xadjustf = 0, // fine-tune horizontal
    parameter yadjustf = 0  // fine-tune vertical
)

// Timing izracun:
localparam xminblank = x/64;  // minimalni blanking
localparam yminblank = y/64;

// Sync pulse generacija:
// - Front porch = xblank/3
// - Pulse width = xblank/3
// - Back porch = remaining
```

**URL:** https://github.com/emard/ulx3s-misc/blob/master/examples/dvi/top/top_vgatest.v

### 5.2 BrunoLevy/learn-fpga - HDMI Tutorial

Jednostavan pristup za framebuffer na ULX3S:

```verilog
// 640x480 RGB 24bpp 60Hz
// Pixel clock: 25MHz

// Opcije:
// 1. FGA (Femto Graphic Adapter) - HDMI output
// 2. Mali OLED display na OLED1 konektor

// Primjer API:
FGA_setpixel(X, Y, R, G, B);  // X,Y koordinate, R,G,B 0-255
```

**URL:** https://github.com/BrunoLevy/learn-fpga/blob/master/FemtoRV/TUTORIALS/HDMI.md

### 5.3 lawrie/ulx3s_sms - Sega Master System

Kompletan retro konzolni port u Verilogu:
- HDMI i VGA output na 640x480 @ 60MHz
- Potpuno u Verilogu

**URL:** https://github.com/lawrie/ulx3s_sms

---

## 6. LINEBUFFER/ROWBUFFER TEHNIKE

### 6.1 Zasto koristiti Linebuffer?

Iz Project F tutoriala:

```
Prednosti linebuffera:
1. Svaki piksel se cita iz framebuffera samo jednom po frameu
2. Dual-port BRAM omogucava dva clocka (system i pixel)
3. Citanje podataka na system clocku (125 MHz)
4. Output na pixel clocku (25.2 MHz)
5. Odvojeni clock domeni poboljsavaju performanse
```

### 6.2 Implementacija Linebuffera za Skaliranje

```verilog
// Za skaliranje 160x120 framebuffer na 640x480:
// Scale factor = 4x

module linebuffer #(
    parameter WIDTH = 160,
    parameter SCALE = 4
)(
    input  clk_sys,          // System clock (125 MHz)
    input  clk_pixel,        // Pixel clock (25.2 MHz)
    input  [7:0] data_in,    // Piksel iz framebuffera
    input  line_start,       // Pocetak linije
    output [7:0] data_out    // Piksel za VGA
);

// Dual-port BRAM
reg [7:0] buffer [0:WIDTH-1];

// Write side (system clock)
reg [7:0] write_addr;
always @(posedge clk_sys) begin
    if (line_start) write_addr <= 0;
    else begin
        buffer[write_addr] <= data_in;
        write_addr <= write_addr + 1;
    end
end

// Read side (pixel clock) - s ponavljanjem
reg [9:0] read_addr;
reg [1:0] scale_cnt;
always @(posedge clk_pixel) begin
    if (line_start) begin
        read_addr <= 0;
        scale_cnt <= 0;
    end else begin
        if (scale_cnt == SCALE-1) begin
            scale_cnt <= 0;
            read_addr <= read_addr + 1;
        end else begin
            scale_cnt <= scale_cnt + 1;
        end
    end
end

assign data_out = buffer[read_addr];

endmodule
```

### 6.3 Clock Domain Crossing

```verilog
// Za prijenos signala izmedju clock domena:
// - Frame sync
// - Line sync
// - Line-zero indikator

// Koristiti specijalizirani 'xd' modul za:
// - Izbjegavanje metastabilnosti
// - Siguran prijenos pulse signala
```

---

## 7. JEDNOSTAVAN RADNI PRIMJER

### 7.1 Minimalni VGA Controller za 512x480 sadrzaj

```verilog
module vga_512x480 (
    input  clk_25mhz,        // 25.175 MHz pixel clock
    input  rst_n,

    // VGA outputs
    output reg hsync,
    output reg vsync,
    output reg [3:0] r,
    output reg [3:0] g,
    output reg [3:0] b,

    // Framebuffer interface
    output [8:0] fb_x,       // 0-511
    output [8:0] fb_y,       // 0-479
    output fb_read_en,       // Aktivan kad citamo iz FB
    input  [11:0] fb_data    // RGB444 iz framebuffera
);

// VGA 640x480 @ 60Hz timing
localparam H_VISIBLE    = 640;
localparam H_FRONT      = 16;
localparam H_SYNC       = 96;
localparam H_BACK       = 48;
localparam H_TOTAL      = 800;

localparam V_VISIBLE    = 480;
localparam V_FRONT      = 10;
localparam V_SYNC       = 2;
localparam V_BACK       = 33;
localparam V_TOTAL      = 525;

// Offset za centriranje 512px u 640px
localparam H_OFFSET     = (H_VISIBLE - 512) / 2;  // = 64

// Counters
reg [9:0] h_cnt;
reg [9:0] v_cnt;

// Horizontal counter
always @(posedge clk_25mhz or negedge rst_n) begin
    if (!rst_n)
        h_cnt <= 0;
    else if (h_cnt == H_TOTAL - 1)
        h_cnt <= 0;
    else
        h_cnt <= h_cnt + 1;
end

// Vertical counter
always @(posedge clk_25mhz or negedge rst_n) begin
    if (!rst_n)
        v_cnt <= 0;
    else if (h_cnt == H_TOTAL - 1) begin
        if (v_cnt == V_TOTAL - 1)
            v_cnt <= 0;
        else
            v_cnt <= v_cnt + 1;
    end
end

// Sync signals (active low)
always @(posedge clk_25mhz) begin
    hsync <= !((h_cnt >= H_VISIBLE + H_FRONT) &&
               (h_cnt < H_VISIBLE + H_FRONT + H_SYNC));
    vsync <= !((v_cnt >= V_VISIBLE + V_FRONT) &&
               (v_cnt < V_VISIBLE + V_FRONT + V_SYNC));
end

// Content area detection
wire in_visible = (h_cnt < H_VISIBLE) && (v_cnt < V_VISIBLE);
wire in_content = (h_cnt >= H_OFFSET) &&
                  (h_cnt < H_OFFSET + 512) &&
                  (v_cnt < 480);

// Framebuffer coordinates
assign fb_x = h_cnt - H_OFFSET;
assign fb_y = v_cnt;
assign fb_read_en = in_content;

// RGB output (s latency kompenzacijom za BRAM)
always @(posedge clk_25mhz) begin
    if (in_content) begin
        r <= fb_data[11:8];
        g <= fb_data[7:4];
        b <= fb_data[3:0];
    end else if (in_visible) begin
        // Border boja (crna ili tamno plava)
        r <= 4'h0;
        g <= 4'h0;
        b <= 4'h1;
    end else begin
        // Blanking
        r <= 4'h0;
        g <= 4'h0;
        b <= 4'h0;
    end
end

endmodule
```

### 7.2 Latency Kompenzacija

**VAZNO:** BRAM ima 1-2 ciklusa latencije!

```verilog
// Pristup 1: Pomakni adresu unaprijed
localparam LATENCY = 2;  // BRAM read latency

// Citaj adresu LATENCY ciklusa unaprijed
wire [8:0] fb_x_early = h_cnt - H_OFFSET + LATENCY;

// Ili pristup 2: Delay RGB output
reg [11:0] fb_data_d1, fb_data_d2;
always @(posedge clk_25mhz) begin
    fb_data_d1 <= fb_data;
    fb_data_d2 <= fb_data_d1;
end
// Koristi fb_data_d2 umjesto fb_data
```

---

## 8. USPOREDBA PRISTUPA

| Pristup | Memorija | Kompleksnost | Prednosti | Nedostaci |
|---------|----------|--------------|-----------|-----------|
| Full framebuffer | ~300KB za 640x480 | Srednja | Fleksibilno | Puno BRAM-a |
| Linebuffer | ~1-2KB po liniji | Niska | Efikasno, clock crossing | Jedan red |
| Rowbuffer (PDP-1) | ~8 redova | Visoka | Phosphor decay | Kompleksno |
| Double buffer | 2x FB velicina | Srednja | Smooth rendering | 2x memorija |
| Ring buffer | Varijabilno | Visoka | Efikasno za vektore | Kompleksno |

---

## 9. PREPORUKE ZA NAS PROJEKT

### 9.1 Za 512x512 Vector Display na ULX3S

1. **Koristiti linebuffer pristup** - efikasno za clock domain crossing
2. **H_OFFSET = 64** - centriranje horizontalno
3. **Crop vertikalno na 480** - ili skalirati ako je potrebno
4. **Latency kompenzacija** - obavezno za BRAM pristup
5. **Double buffering** - za smooth animacije

### 9.2 Predlozena arhitektura

```
[Vector Generator] --> [Framebuffer 512x512] --> [Linebuffer]
                              ^                       |
                              |                       v
                       [Swap Logic]            [VGA Controller]
                              |                       |
                       [Framebuffer B]          [VGA Output]
```

---

## 10. REFERENCE

### MiSTer FPGA
- [MiSTer Vector Display Forum](https://misterfpga.org/viewtopic.php?t=9551)
- [PDP1_MiSTer GitHub](https://github.com/MiSTer-devel/PDP1_MiSTer)
- [Arcade-Asteroids_MiSTer GitHub](https://github.com/MiSTer-devel/Arcade-Asteroids_MiSTer)
- [Vectrex_MiSTer GitHub](https://github.com/MiSTer-devel/Vectrex_MiSTer)
- [MiSTer CRT Documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/crt/)

### ULX3S/ECP5
- [emard/ulx3s-misc](https://github.com/emard/ulx3s-misc)
- [BrunoLevy learn-fpga HDMI](https://github.com/BrunoLevy/learn-fpga/blob/master/FemtoRV/TUTORIALS/HDMI.md)
- [lawrie/ulx3s_retro](https://github.com/lawrie/ulx3s_retro)
- [lawrie/ulx3s_sms](https://github.com/lawrie/ulx3s_sms)

### VGA Tutorials
- [Project F - Framebuffers](https://projectf.io/posts/framebuffers/)
- [Project F - Video Timings](https://projectf.io/posts/video-timings-vga-720p-1080p/)
- [ZipCPU VGA Tutorial](https://zipcpu.com/blog/2018/11/29/llvga.html)
- [Wayne Johnson VGA Tutorial](https://blog.waynejohnson.net/doku.php/generating_vga_with_an_fpga)
- [projf/display_controller](https://github.com/projf/display_controller)

### Dodatni resursi
- [fpga-image-buffer](https://github.com/talsania/fpga-image-buffer)
- [VGA Timing Reference](http://www.tinyvga.com/vga-timing)

---

## 11. ZAKLJUCAK

Istrazivanje MiSTer i drugih FPGA projekata pokazuje:

1. **Double buffering je standardni pristup** za vector display emulaciju
2. **Linebuffer je kljucan** za efikasnu memorijsku upotrebu i clock domain crossing
3. **H_OFFSET formula je jednostavna**: `(640 - content_width) / 2`
4. **Latency kompenzacija** je obavezna kod BRAM pristupa (1-2 ciklusa)
5. **PDP-1 ring buffer pristup** je elegantan za phosphor decay simulaciju

Za nas ULX3S projekt, preporucujem kombinaciju:
- **Linebuffer za VGA output** (slicno Project F primjeru)
- **Double buffer za renderiranje** (slicno MiSTer vector cores)
- **Jednostavna H_OFFSET formula** za centriranje

Ovo ce dati stabilan, efikasan i lako razumljiv VGA output za nas vector display emulator.
