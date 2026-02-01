# Analiza nevidljivih brodova u Spacewar!

**Datum:** 2026-02-01
**Autor:** Jelena Horvat, FPGA Verification Engineer
**Problem:** Brodovi su NEVIDLJIVI, zvijezde se vide

---

## 1. Analiza originala (fpg1 projekt)

### 1.1 CPU brightness extraction (original cpu.v)

```verilog
// Original: fpg1/src/cpu.v, linija 340
display_crt:
begin
   pixel_shift_out <= 1'b1;
   pixel_brightness <= DI[8:6];   // <-- Bitovi iz DATA BUS-a (memorija)
end
```

**KLJUCNI DETALJ:** Original koristi `DI[8:6]` - brightness se cita iz DATA INPUT (memorija).

### 1.2 Koordinate (original cpu.v)

```verilog
// Original: fpg1/src/cpu.v, linija 546-547
assign pixel_x_out = IO[17:8] + 10'd512;
assign pixel_y_out = AC[17:8] + 10'd512;
```

Koordinate su kombinacijske (assign), ne registrirane.

### 1.3 CRT variable_brightness handling (original pdp1_vga_crt.v)

```verilog
// Original: fpg1/src/pdp1_vga_crt.v, linija 172-189
if (variable_brightness && pixel_brightness > 3'b0 && pixel_brightness < 3'b100)
begin
   // Dodaje 5 piksela za veci brightness (1 centar + 4 susjedna)
   buffer_write_ptr <= buffer_write_ptr + 3'd5;
end
else
begin
   // Standardni brightness - samo 1 piksel
   buffer_write_ptr <= buffer_write_ptr + 1'b1;
end
```

**VAZNO:** Uvjet `pixel_brightness > 3'b0 && pixel_brightness < 3'b100` znaci:
- Brightness mora biti 1, 2, ili 3 (3'b001, 3'b010, 3'b011)
- Brightness 0, 4, 5, 6, 7 - samo 1 piksel

---

## 2. Analiza naseg koda (port)

### 2.1 CPU brightness extraction (pdp1_cpu.v)

```verilog
// Nas kod: pdp1_cpu.v, linija 385
display_crt:
begin
   pixel_shift_out <= 1'b1;
   pixel_brightness <= instruction[8:6];  // BUGFIX komentar - koristi IR
end
```

**PROBLEM IDENTIFICIRAN!**

Nas kod koristi `instruction[8:6]` (IR registar), a original koristi `DI[8:6]` (DATA BUS).

Za IOT instrukciju (DPY) format je:
```
17 16 15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| 1  1  1  0  1| W| C|   subopcode  |      device     | I/O transfer
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

Za DPY instrukciju, brightness bitovi su na poziciji 8:6 (subopcode).

**KLJUCNO RAZLIKOVANJE:**
- `DI` = memorijski operand (podaci ucitani iz memorije na adresi Y)
- `IR` = instrukcija sama (opcode + flags)
- `instruction` = isto sto i IR (parametar funkcije execute_instruction)

**Za IOT instrukciju:**
- DI[8:6] u originalu zapravo cita iz MEM_BUFF koji se postavlja na vrijednost instrukcije
- Oba pristupa bi trebala biti ekvivalentna AKO je MEM_BUFF == IR

### 2.2 Provjera execute_instruction poziva

```verilog
// pdp1_cpu.v, linija 829
execute_instruction(IR[17:13], IR[12], IR, MEM_BUFF);
//                   opcode    indirect instruction operand
```

Tu vidimo:
- `instruction` = IR
- `operand` = MEM_BUFF

A u execute_instruction za display_crt:
```verilog
case (operand[5:0])  // device = MEM_BUFF[5:0]
display_crt:
begin
   pixel_brightness <= instruction[8:6];  // = IR[8:6]
end
```

**ZAKLJUCAK:** Za IOT instrukcije, instrukcija i operand su isti (jer nema memorijske reference).
Ali ORIGINALNI KOD koristi `DI[8:6]` - sto je direktno s DATA BUS-a, ne iz registra!

---

## 3. Spacewar! brightness analiza

### 3.1 Razlike izmedju zvijezda i brodova

U Spacewar! igri:
- **Zvijezde** koriste fiksni brightness (vjerojatno 0 ili 7 - najsjajnije)
- **Brodovi** koriste varijabilni brightness za razlicite dijelove (trup, motor plamen)

Ako brodovi koriste brightness vrijednosti 4, 5, 6, ili 7 (negativni brightness u PDP-1 terminologiji):
```
brightness kodirano: 4= -3, 5= -2, 6= -1, 7= -0, 0= 0, 1= +1, 2= +2, 3= +3
```

Vrijednosti 4-7 imaju bit 2 postavljen (3'b1xx), sto znaci `pixel_brightness >= 3'b100`.

### 3.2 CRT filtriranje

```verilog
// pdp1_vga_crt.v, linija 274
if (variable_brightness && pixel_brightness > 3'b0 && pixel_brightness < 3'b100)
```

Ovaj uvjet propusta SAMO brightness 1, 2, 3.

**AKO** brodovi koriste brightness 0 ili 4-7:
- Samo 1 piksel se upisuje (umjesto 5)
- ALI piksel se i dalje treba vidjeti!

---

## 4. GLAVNI PROBLEM - Hipoteza

### 4.1 Timing problem s brightness

Original koristi `DI[8:6]` direktno s data bus-a u ISTOM clock ciklusu kad je instrukcija izvrsena.

Nas kod koristi `instruction[8:6]` koje je postavljeno PRIJE execute faze (u read_instruction_register fazi).

**MOGUCE:** Za neke instrukcije, DI se mijenja izmedju citanja instrukcije i execute faze!

### 4.2 Provjera toka izvrsavanja

```
read_instruction_register (state 51): IR <= DI
...
read_data_bus (state 65): MEM_BUFF <= DI
...
execute (state 125): execute_instruction(IR[17:13], IR[12], IR, MEM_BUFF)
```

Za IOT instrukcije BEZ indirektnog adresiranja:
- IR = DI iz state 51
- MEM_BUFF = DI iz state 65 (isti DI ako nema memory reference)

Za IOT s indirektnim adresiranjem:
- MEM_BUFF moze biti drugaciji!

### 4.3 Specificno za DPY instrukciju

DPY instrukcija (`IOT 7`) NEMA memorijskog operanda - brightness je dio same instrukcije.

**ALI:** U get_effective_address fazi, i_iot NIJE u listi instrukcija koje procesiraju!

```verilog
case (IR[17:13])
   i_and, i_ior, i_xor, i_xct, i_lac, i_lio, i_dac,
   i_dap, i_dip, i_dio, i_dzm, i_add, i_sub, i_idx,
   i_isp, i_sad, i_sas, i_mu_, i_di_, i_jmp, i_jsp:
      // ... procesira adresu
endcase
```

**i_iot NIJE na listi!** Sto znaci da MEM_BUFF za IOT instrukcije ostaje kakav je bio.

---

## 5. STVARNI PROBLEM - WREN EDGE DETECTION

### 5.1 Original edge detection

```verilog
// Original: pdp1_vga_crt.v, linija 330-332
prev_prev_wren_i <= prev_wren_i;
prev_wren_i <= pixel_available;
wren <= prev_prev_wren_i & ~prev_wren_i;  // FALLING EDGE
```

### 5.2 Nas kod - identican

```verilog
// Nas kod: pdp1_vga_crt.v, linija 453-456
prev_prev_wren_i <= prev_wren_i;
prev_wren_i <= pixel_available;
wren <= prev_prev_wren_i & ~prev_wren_i;  // FALLING EDGE
```

Oba koriste FALLING EDGE detekciju. Ovo je OK.

---

## 6. KOORDINATNI PROBLEM?

### 6.1 Original koordinate (kombinacijske)

```verilog
// Original cpu.v
assign pixel_x_out = IO[17:8] + 10'd512;
assign pixel_y_out = AC[17:8] + 10'd512;
```

### 6.2 Nase koordinate (registrirane s latch)

```verilog
// Nas pdp1_cpu.v
display_crt:
begin
   pixel_shift_out <= 1'b1;
   pixel_brightness <= instruction[8:6];
   pixel_x_latched <= IO[17:8] + 10'd512;
   pixel_y_latched <= AC[17:8] + 10'd512;
end
...
assign pixel_x_out = pixel_x_latched;
assign pixel_y_out = pixel_y_latched;
```

**RAZLIKA:** Nas kod latch-a koordinate u registre, original ih kombinacijski izvodi.

Ovo bi trebalo biti BOLJE (sprjecava glitches), ne losije.

---

## 7. PRAVI UZROK - variable_brightness UVJET

### 7.1 Kriticki uvjet u CRT modulu

```verilog
if (variable_brightness && pixel_brightness > 3'b0 && pixel_brightness < 3'b100)
begin
   // 5 piksela
end
else
begin
   // 1 piksel
end
```

**PROBLEM:** Ovaj else branch i dalje dodaje piksel u buffer!

```verilog
else
begin
   { buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };
   buffer_write_ptr <= buffer_write_ptr + 1'b1;
end
```

Dakle, pikseli bi se TREBALI dodavati bez obzira na brightness vrijednost.

---

## 8. PRONADEN UZROK!

### 8.1 Usporedba dim_pixel funkcija

**ORIGINAL:**
```verilog
function automatic [11:0] dim_pixel;
   input [11:0] luma;
   dim_pixel = (luma > 12'd3864 && luma < 12'd3936) ? 12'd2576 : luma - 1'b1;
endfunction
```

**NAS KOD:**
```verilog
function automatic [11:0] dim_pixel;
   input [11:0] luma;
   // FIX BUG 5: Brzi decay - oduzmi 8 umjesto 1 za vidljiviji phosphor trail
   dim_pixel = (luma > 12'd8) ? luma - 12'd8 : 12'd0;
endfunction
```

**KRITICNA RAZLIKA:**
- Original: decay od 1 po ciklusu, s "step-down" na 2576 za simulaciju afterglow
- Nas kod: decay od 8 po ciklusu, BEZ step-down logike

### 8.2 Phosphor decay matematika

Pocetna luma = 4095 (12'd4095)

**Original decay (svakih 8 frame-ova):**
- 4095 -> 4094 -> ... -> 3936 -> 3935 -> ... -> 3864 -> 2576 (SKOK!) -> 2575 -> ... -> 0
- Ukupno: ~4095 frame-ova do nestajanja

**Nas decay (svakih 8 frame-ova):**
- 4095 -> 4087 -> 4079 -> ... -> 0
- Ukupno: ~512 frame-ova do nestajanja (8x brze!)

### 8.3 Zasto zvijezde prezivljavaju, brodovi ne?

**Zvijezde:** Staticki objekti koji se kontinuirano "refreshaju" - svaki frame se ponovo crtaju na istoj poziciji.

**Brodovi:** Dinamicki objekti koji se pomicu - kad se brod pomakne, stari piksel vise nije refreshan i BRZO nestaje zbog naseg agresivnog decay-a.

Ali to nije cijela prica - brodovi bi se i dalje trebali vidjeti na novoj poziciji!

---

## 9. PRAVA HIPOTEZA - search_counter threshold

### 9.1 Original threshold

```verilog
// Original: pdp1_vga_crt.v, linija 207
if (buffer_write_ptr != buffer_read_ptr && search_counter > 1024 && ...)
```

### 9.2 Nas threshold

```verilog
// Nas kod: pdp1_vga_crt.v, linija 311
if (buffer_write_ptr != buffer_read_ptr && search_counter > 640 && ...)
```

**RAZLIKA:** Mi koristimo 640, original koristi 1024.

**ALI:** 640 bi trebalo biti dovoljno za nas ring buffer TAP_DISTANCE.

---

## 10. ZAKLJUCAK I PLAN POPRAVAKA

### 10.1 Identificirani problemi

| # | Problem | Ozbiljnost | Status |
|---|---------|------------|--------|
| 1 | `dim_pixel` funkcija promijenjena - prebrzi decay | **VISOKA** | POTREBAN POPRAVAK |
| 2 | Step-down phosphor simulacija uklonjena | **VISOKA** | POTREBAN POPRAVAK |
| 3 | search_counter threshold 640 vs 1024 | NISKA | Vjerojatno OK |
| 4 | Brightness source (instruction vs DI) | NISKA | Ekvivalentno za IOT |

### 10.2 Plan popravaka

#### PRIORITET 1: Vrati originalnu dim_pixel funkciju

```verilog
// IZMJENA u pdp1_vga_crt.v, funkcija dim_pixel
function automatic [11:0] dim_pixel;
   input [11:0] luma;
   // VRACENA ORIGINALNA LOGIKA:
   // - Standardni decay: luma - 1
   // - Step-down na 2576 kad luma u rasponu 3864-3936 (afterglow simulacija)
   dim_pixel = (luma > 12'd3864 && luma < 12'd3936) ? 12'd2576 : luma - 1'b1;
endfunction
```

#### PRIORITET 2: Provjeri rezoluciju i timing

- Nas display: 1024x768 @ 50Hz
- Original: 1280x1024 @ 60Hz

Razliciti refresh rate-ovi utjecu na decay brzinu!
- 60 Hz: 60 dimova po sekundi
- 50 Hz: 50 dimova po sekundi

Ali s `pass_counter[2:0] == 3'b0` dimamo svakih 8 frame-ova:
- 60 Hz: 7.5 dimova/sekundi
- 50 Hz: 6.25 dimova/sekundi

Razlika je mala, ali zajedno s decay 8 vs 1 daje ogroman efekt!

#### PRIORITET 3: Test nakon popravka

1. Vrati originalnu dim_pixel funkciju
2. Resyntesize FPGA
3. Provjeri jesu li brodovi vidljivi
4. Ako ne - provjeri search_counter threshold

---

## 11. DODATNA ANALIZA - Koordinatna transformacija

### 11.1 Original (1280x1024 display)

```verilog
// Bez transformacije - direktno ~pixel_x_i
{ buffer_pixel_y, buffer_pixel_x } <= { ~pixel_x_i, pixel_y_i };
```

### 11.2 Nas kod (1024x768 display)

```verilog
// Identican pristup za PDP-1 mode
{ buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };
```

Koordinatna transformacija je IDENTIČNA. Problem nije tu.

---

## 12. AKCIJSKI PLAN

1. **HITNO:** Vrati originalnu `dim_pixel` funkciju u `/home/klaudio/port_fpg1/src/pdp1_vga_crt.v`
2. **TEST:** Rebuild FPGA i test Spacewar!
3. **BACKUP:** Ako ne pomogne, vrati search_counter na 1024
4. **DEBUG:** Dodaj LED indikator za pixel_brightness vrijednost da se vidi sto Spacewar! salje

---

*Dokument generiran: 2026-02-01*
*Jelena Horvat, REGOC Team*
