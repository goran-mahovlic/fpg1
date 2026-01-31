# ORIGINALNI FPG1 ANALIZA - Usporedba s ULX3S Portom

**Autor:** Jelena Horvat, FPGA Verification Engineer
**Datum:** 2026-01-31
**Status:** KRITIČNI BUGOVI PRONAĐENI

---

## 1. IZVORI ANALIZE

### Originalni repozitoriji:
- **hrvach/fpg1**: https://github.com/hrvach/fpg1 (originalna MiSTer implementacija)
- **MiSTer-devel/PDP1_MiSTer**: https://github.com/MiSTer-devel/PDP1_MiSTer (službeni MiSTer core)
- **spacemen3/PDP-1**: https://github.com/spacemen3/PDP-1 (Analogue Pocket port)

### Relevantne datoteke:
- Originalna: `fpg1/src/pdp1_vga_crt.v`
- Originalna: `fpg1/src/definitions.v`
- Naša verzija: `/home/klaudio/port_fpg1/src/pdp1_vga_crt.v`
- Naša verzija: `/home/klaudio/port_fpg1/src/definitions.v`

---

## 2. KRITIČNA RAZLIKA #1: COORDINATE INVERSION

### ORIGINAL (1280x1024):
```verilog
// Linija 174, 183, 187 u originalnom fpg1/src/pdp1_vga_crt.v
{ buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };
```

**ORIGINAL KORISTI INVERZIJU `~pixel_x_i` za Y koordinatu!**

Ovo je kritično: U originalnom kodu, **X koordinata iz PDP-1 se invertira i sprema kao Y**, dok se **Y koordinata sprema kao X**.

### NAŠA VERZIJA (640x480):
```verilog
// Linija 198, 211 u /home/klaudio/port_fpg1/src/pdp1_vga_crt.v
{ buffer_pixel_x[buffer_write_ptr], buffer_pixel_y[buffer_write_ptr] } <= { pixel_x_i, pixel_y_i };
```

**MI NE KORISTIMO INVERZIJU I REDOSLIJED JE DRUGAČIJI!**

### ANALIZA:
PDP-1 Type 30 CRT ima koordinatni sustav gdje je:
- Origin (0,0) u GORNJEM DESNOM kutu
- X raste LIJEVO
- Y raste DOLJE

Za pretvorbu u standardni VGA koordinatni sustav (origin gornji lijevi kut):
- `~pixel_x_i` invertira X os (0-1023 postaje 1023-0)
- Swap X<->Y rotira koordinate za 90 stupnjeva

---

## 3. KRITIČNA RAZLIKA #2: VGA TIMING PARAMETRI

### ORIGINAL (1280x1024 @ 60Hz, 108 MHz pixel clock):
```verilog
`define   h_visible_offset       11'd408
`define   h_center_offset        11'd128
`define   h_visible_offset_end   11'd1432

`define   v_visible_offset       11'd42
`define   v_visible_offset_end   11'd1066

`define   h_line_timing          11'd1688
`define   v_line_timing          11'd1066
```

**Vidljivo područje:** 1024 x 1024 piksela (unutar 1280x1024 framea)
**Center offset:** 128 piksela (za centriranje 1024 unutar 1280)

### NAŠA VERZIJA (640x480 @ 60Hz, 25 MHz pixel clock):
```verilog
`define   h_visible_offset       11'd160
`define   h_center_offset        11'd64
`define   h_visible_offset_end   11'd704

`define   v_visible_offset       11'd45
`define   v_visible_offset_end   11'd525

`define   h_line_timing          11'd800
`define   v_line_timing          11'd525
```

### PROBLEM:
Naša formula za `h_visible_offset_end` je POGREŠNA:
```
h_visible_offset_end = h_visible_offset + visible_width - h_center_offset
                     = 160 + 640 - 64 - 32 = 704 (prema komentaru)
```

Ali to daje samo **544 piksela** vidljive širine (704 - 160 = 544), ne 512!

**ISPRAVNO BI TREBALO BITI:**
```
h_visible_offset_end = h_visible_offset + 512 + h_center_offset
                     = 160 + 512 + 64 = 736
```

---

## 4. KRITIČNA RAZLIKA #3: ROWBUFFER ADDRESS MAPPING

### ORIGINAL:
```verilog
rowbuff_rdaddress <= {current_y[2:0], current_x};
// Za 1024x1024: current_x je 10-bitni, dakle adresa je 13-bitna
// Adresa = Y[2:0] (3 bita) + X (10 bita) = 13 bita
// Podržava 8 linija * 1024 piksela = 8192 lokacija
```

### NAŠA VERZIJA:
```verilog
rowbuff_rdaddress <= {current_y[2:0], current_x};
// Za 640x480: current_x je 10-bitni (ali koristi samo 512 vrijednosti)
// Adresa = Y[2:0] (3 bita) + X (10 bita) = 13 bita
```

**PROBLEM:** Ako `current_x` nikad ne dosegne vrijednosti izvan 512, ali rowbuffer je dizajniran za 1024 piksela, možda imamo memory addressing mismatch.

---

## 5. KRITIČNA RAZLIKA #4: PIXEL WRITE ADDRESS (DEBUG BYPASS)

### U NAŠEM DEBUG BYPASS MODU:
```verilog
debug_wr_addr <= {pixel_y_i[2:0], pixel_x_i};
```

Ali originalni kod koristi:
```verilog
// Pikseli se spremaju kao {~pixel_x_i, pixel_y_i} u ring buffer
// Zatim se koriste za rowbuffer write kao:
rowbuff_wraddress <= {taps[Y koordinata][2:0], taps[X koordinata]};
```

**Dakle, mi direktno koristimo `pixel_y_i` i `pixel_x_i`, ali originalni kod koristi INVERTIRANE i SWAPPANE koordinate!**

---

## 6. DIJAGNOZA: ZAŠTO JE DIJAGONALA U DESNOM KUTU

### Root Cause:
1. **Nedostaje X inverzija (`~pixel_x_i`)**: Bez ovoga, koordinate su zrcaljene
2. **Pogrešan X/Y swap**: Original sprema {~X, Y} kao {Y_buffer, X_buffer}
3. **Pogrešan h_visible_offset_end**: Vidljivo područje je manje od očekivanog

### Što se događa:
- Spacewar crta dijagonalu od (0,0) do (512,512) u PDP-1 koordinatama
- Bez inverzije, (0,0) završava u GORNJEM DESNOM kutu VGA ekrana
- Dijagonala se crta prema DONJEM LIJEVOM, ali zbog pogrešnih offseta, samo desni dio je vidljiv

---

## 7. PREPORUČENI POPRAVCI

### Popravak 1: Vratiti originalnu koordinatnu transformaciju
```verilog
// U always bloku za wren:
{ buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };
```

### Popravak 2: Ispraviti h_visible_offset_end
```verilog
`define   h_visible_offset_end   11'd736    // 160 + 512 + 64 = 736
```

Ili još bolje, za 640x480 sa centriranim 512x512 displayem:
```verilog
`define   h_visible_offset       11'd160    // sync + back porch
`define   h_center_offset        11'd64     // (640-512)/2 = 64
`define   h_visible_offset_end   11'd736    // 160 + 512 + 64
```

### Popravak 3: Ispraviti debug bypass mode
```verilog
// Trenutno:
debug_wr_addr <= {pixel_y_i[2:0], pixel_x_i};

// Treba biti:
debug_wr_addr <= {(~pixel_x_i)[2:0], pixel_y_i};
```

### Popravak 4: Vertikalni offset
Za 512x512 unutar 480 linija, moramo ili:
- Skalirati na 480 piksela (gubitak rezolucije)
- Koristiti samo gornje 480 linija PDP-1 displeja

---

## 8. DODATNI PROBLEMI ZA ISTRAŽIVANJE

### Problem s ECP5/Yosys:
Neki konstrukti iz originala možda nisu podržani:
- `current_x > 0` uvjet u line3 instantiation
- Altsyncram zamjena s BRAM primitives

### Poznati ULX3S VGA problemi:
- Vertikalna obojena traka na lijevoj strani ekrana (sličan simptom!)
- DVI/HDMI timing zahtijeva precizne parametre

---

## 9. AKCIJSKI PLAN

1. **HITNO:** Dodati `~pixel_x_i` inverziju u coordinate mapping
2. **HITNO:** Ispraviti `h_visible_offset_end` na 736
3. **TESTIRATI:** Provjeriti da li dijagonala sada ide od gornjeg lijevog do donjeg desnog kuta
4. **DOKUMENTIRATI:** Razlike između MiSTer i ULX3S/ECP5 porta

---

## 10. REFERENCE

- [GitHub - hrvach/fpg1](https://github.com/hrvach/fpg1)
- [GitHub - MiSTer-devel/PDP1_MiSTer](https://github.com/MiSTer-devel/PDP1_MiSTer)
- [DEC PDP-1 - MiSTer FPGA Bible](https://boogermann.github.io/Bible_MiSTer/cores/computers/historical/pdp1/)
- [GitHub - emard/ulx3s](https://github.com/emard/ulx3s)
- [hdl-util/hdmi ULX3S Issue #25](https://github.com/hdl-util/hdmi/issues/25)
- [GitHub - spacemen3/PDP-1](https://github.com/spacemen3/PDP-1) (Analogue Pocket port)

---

**ZAKLJUČAK:** Problem je FUNDAMENTALAN - nedostaje coordinate transformation iz originalnog koda. Dijagonala je u desnom kutu jer se X koordinata ne invertira, pa je origin u pogrešnom kutu ekrana.
