# FPGA Port Plan v2.0

**Projekt:** FPG-1 (PDP-1 emulator) Altera Cyclone V -> Lattice ECP5
**Datum:** 2026-01-31
**Sastanak:** Kosjenka (Architect), Jelena (Engineer), Dora (Analyst)

---

## Executive Summary

Emardov parcijalni port je u boljem stanju nego sto smo ocekivali. Od 5 placeholder modula, 3 su zapravo **funkcionalna** - samo imaju intentional syntax error na prvoj liniji koji treba ukloniti.

**Stvarno nedovrseni moduli (2):**
- `pixel_ring_buffer.v` - KRITICNO (CRT phosphor decay)
- `line_shift_register.v` - KRITICNO (blur kernel)

**Pseudo-placeholder (1):**
- `pdp1_cpu_alu_div.v` - potrebna behavioral implementacija

**Vec gotovi (3):**
- `pdp1_terminal_charset.v` - funkcionalan, samo ukloniti syntax error
- `pdp1_terminal_fb.v` - funkcionalan, samo ukloniti syntax error
- `pdp1_vga_rowbuffer.v` - potpuno funkcionalan

---

## Milestone 1: Build Infrastructure (2 dana)

**Cilj:** Funkcionalan build flow s test outputom na HDMI

- [ ] **TASK-116** OSS CAD Suite Setup (Jelena, 0.5 dana)
  - Verificirati yosys, nextpnr-ecp5, ecppack
  - Testirati basic blink primjer za ULX3S 85F
  - Dokumentirati environment variables i PATH

- [ ] **TASK-124** PLL Configuration (Kosjenka, 0.5 dana) *NOVO*
  - Generirati ECP5 PLL za 108 MHz pixel clock
  - Alternativno: 75 MHz za 1280x1024@50Hz (sigurnija opcija)
  - Verificirati timing s ecppll tool

- [ ] **TASK-125** HDMI Test Pattern (Jelena, 1 dan) *NOVO*
  - Koristiti Emardove vga.vhd, vga2dvid.vhd, tmds_encoder.vhd
  - Generirati color bars ili checkerboard
  - Verificirati output na monitoru

**Deliverable:** ULX3S prikazuje test pattern na HDMI @ 1280x1024

---

## Milestone 2: Memory Primitives (1.5 dana)

**Cilj:** Svi BRAM moduli funkcionalni i testirani

- [ ] **TASK-126** Fix Pseudo-Placeholders (Jelena, 0.5 dana) *NOVO*
  - Ukloniti `] intentional # syntax # error [` iz:
    - `pdp1_terminal_charset.v`
    - `pdp1_terminal_fb.v`
  - Verificirati sinteza prolazi

- [ ] **TASK-127** Divider Implementation (Potjeh, 0.5 dana) *NOVO*
  - Implementirati behavioral unsigned divider u `pdp1_cpu_alu_div.v`
  - Pipeline nije kritican (DIV je rijetka instrukcija)
  - Opcija: multicycle divider (34 ciklusa kao original)

- [ ] **TASK-128** MIF to HEX Conversion (Dora, 0.5 dana) *NOVO*
  - Konvertirati `fiodec_charset.mif` -> `fiodec_charset.hex`
  - Konvertirati `console_bg.mif` -> `console_bg.hex` (ako postoji)
  - Konvertirati `spacewar.mif` -> `spacewar.hex`
  - Python skripta za automatizaciju

**Deliverable:** Svi memory moduli prolaze sinteza bez gresaka

---

## Milestone 3: CRT Emulation (5-7 dana) *KRITICNO*

**Cilj:** Funkcionalni shift registri za Type 30 CRT emulaciju

### 3.1 Line Shift Register (2 dana)

- [ ] **TASK-129** line_shift_register Implementation (Jelena, 1.5 dana) *NOVO*
  - Specifikacije: 8-bit, 1 tap, distance 1685
  - Implementacija: BRAM circular buffer
  - Dual-port nije potreban (samo 1 tap)

  ```
  Pristup:
  - reg [7:0] mem [0:2047]  // 2^11 dovoljno za 1685
  - wrptr, rdptr = wrptr - 1685
  - Standardni BRAM inference pattern
  ```

- [ ] **TASK-130** line_shift_register Testbench (Potjeh, 0.5 dana) *NOVO*
  - Verilator ili Icarus testbench
  - Verificirati delay = 1685 ciklusa
  - Verificirati shift behavior

### 3.2 Pixel Ring Buffer (3-5 dana) *NAJTEZE*

- [ ] **TASK-123** pixel_ring_buffer Implementation (Jelena, 3-4 dana)
  - Specifikacije: 32-bit, 8 tapova, distance 1024
  - Total memory: 8192 x 32 = 256 Kbit

  **Problem:** ECP5 EBR ima samo 2 porta, ali trebamo 8 simultanih citanja (tapovi)

  **Rjesenje A - Time Multiplexed (preporuceno):**
  ```
  - Citati tapove sekvencijalno (8 clockova)
  - Dodaje 8 ciklusa latencije
  - Potrebna analiza: da li pdp1_vga_crt.v tolerira latenciju?
  ```

  **Rjesenje B - Replicated Memory:**
  ```
  - 8 kopija memorije, svaka s jednim tap izlazom
  - 8x vise BRAM resursa (2 Mbit vs 256 Kbit)
  - ECP5-85F ima 3.7 Mbit EBR - moze stati
  ```

  **Rjesenje C - Reduced Taps:**
  ```
  - Smanjiti na 4 tapa, povecati tap_distance na 2048
  - Potrebna modifikacija pdp1_vga_crt.v
  - Rizicno - moze utjecati na vizualnu kvalitetu
  ```

  **Preporuka:** Poceti s Rjesenjem B (replicated), optimizirati kasnije ako treba

- [ ] **TASK-131** pixel_ring_buffer Testbench (Potjeh, 1 dan) *NOVO*
  - Verificirati svih 8 tapova
  - Verificirati shiftout = shiftin nakon 8192 ciklusa
  - VCD dump za vizualnu inspekciju

### 3.3 CRT Integration

- [ ] **TASK-132** pdp1_vga_crt.v Adaptation (Kosjenka, 1 dan) *NOVO*
  - Integrirati nove shift registre
  - Verificirati timing compatibility
  - Provjeriti pixel_available signalizaciju

**Deliverable:** CRT modul prolazi sinteza, simulacija pokazuje phosphor decay

---

## Milestone 4: CPU & Peripherals (2 dana)

**Cilj:** CPU i periferija integrirani

- [ ] **TASK-118** PLL/Clock Adaptation (Kosjenka, 1 dan)
  - CPU clock prescaler (~1.79 MHz iz pixel clocka)
  - Clock domain crossing sync registri
  - Reset sequencing

- [ ] **TASK-133** Keyboard/Joystick Mapping (Grga, 0.5 dana) *NOVO*
  - ULX3S buttons -> PDP-1 sense switches
  - USB keyboard (preko ESP32) -> opcija za V2

- [ ] **TASK-134** Top Level Integration (Kosjenka, 0.5 dana) *NOVO*
  - Integrirati sve module u top_pdp1.v
  - Pin assignment za ULX3S v3.1.7
  - Constraint file update

**Deliverable:** Kompletna sinteza bez gresaka

---

## Milestone 5: System Test (2-3 dana)

**Cilj:** Spacewar! radi na ULX3S

- [ ] **TASK-119** Full System Integration (Jelena, 1 dan)
  - Place & route
  - Timing closure (target: 108 MHz ili 75 MHz)
  - Bitstream generacija

- [ ] **TASK-117** Simulacija Modula (Potjeh, 1 dan)
  - Full system Verilator simulacija (ako moguce)
  - Alternativno: Icarus s VCD
  - Verificirati CPU fetch/execute cycle

- [ ] **TASK-135** Hardware Test (Jelena + Grga, 1 dan) *NOVO*
  - Flash bitstream na ULX3S
  - Boot Spacewar! iz BRAM
  - Verificirati CRT display, controls
  - Dokumentirati poznate probleme

**Deliverable:** Spacewar! igriva na ULX3S

---

## Milestone 6: ESP32 OSD (V2 - Opcionalno)

- [ ] **TASK-120** ESP32 OSD Implementation (Grga, 3-5 dana)
  - OSD overlay za tape load
  - WiFi control interface
  - Ovo je "nice to have", ne blokira osnovnu funkcionalnost

---

## Task Dependency Graph

```
                    TASK-116 (Setup)
                         |
                    +----+----+
                    |         |
              TASK-124    TASK-125
              (PLL)       (HDMI Test)
                    |         |
                    +----+----+
                         |
                    TASK-126 (Fix Placeholders)
                         |
              +----------+----------+
              |          |          |
         TASK-127   TASK-128   TASK-129
         (Divider)  (MIF->HEX) (line_shift)
              |          |          |
              +----------+----+-----+
                              |
                         TASK-130 (line_shift TB)
                              |
                         TASK-123 (pixel_ring) <-- KRITICNI PUT
                              |
                         TASK-131 (pixel_ring TB)
                              |
                         TASK-132 (CRT Integration)
                              |
                    +--------+--------+
                    |        |        |
              TASK-118  TASK-133  TASK-134
              (Clock)   (Input)   (Top Level)
                    |        |        |
                    +--------+--------+
                              |
                         TASK-119 (Integration)
                              |
                         TASK-117 (Simulation)
                              |
                         TASK-135 (HW Test)
                              |
                         TASK-120 (ESP32 - V2)
```

**Kriticni put:** TASK-116 -> TASK-124 -> TASK-129 -> TASK-123 -> TASK-132 -> TASK-119 -> TASK-135

---

## Assignee Matrix

| Osoba | Taskovi | Ukupno Dana | Ekspertiza |
|-------|---------|-------------|------------|
| **Jelena** | 116, 125, 126, 129, 123, 119, 135 | 8-9 | Verilog, Toolchain |
| **Kosjenka** | 124, 132, 118, 134 | 3 | Arhitektura, Timing |
| **Potjeh** | 127, 130, 131, 117 | 3 | Simulacija, Testbench |
| **Dora** | 128 | 0.5 | Skripting, Analiza |
| **Grga** | 133, 120 | 4-5.5 | ESP32, Periferija |
| **Manda** | - | 0 | Research (zavrseno) |

**Paralelizacija:** Jelena i Kosjenka mogu raditi paralelno na Milestone 1. Potjeh moze raditi testbench-e dok Jelena implementira module.

---

## Timeline (Radni Dani)

```
Dan 1-2:   Milestone 1 (Build Infrastructure)
Dan 3-4:   Milestone 2 (Memory Primitives) + pocetak M3
Dan 5-9:   Milestone 3 (CRT Emulation) <-- NAJDUZE
Dan 10-11: Milestone 4 (CPU & Peripherals)
Dan 12-14: Milestone 5 (System Test)
---------------------------------------------------------
           Milestone 6 (ESP32) - nakon osnovnog porta
```

**Ukupna procjena:** 12-14 radnih dana za funkcionalni port
**Worst case:** 18 dana (ako pixel_ring_buffer zahtijeva Rjesenje B + optimizacija)
**Best case:** 10 dana (ako sve radi iz prve)

---

## Risk Mitigation

### R1: pixel_ring_buffer timing failure (VISOKI RIZIK)

**Simptom:** Timing closure failure na 108 MHz ili vizualni artefakti

**Mitigacija:**
1. Prvo probati 75 MHz (1280x1024@50Hz) - manji timing stress
2. Ako ne radi, implementirati Rjesenje B (replicated memory)
3. Ako EBR nije dovoljno, razmotriti SDRAM za ring buffer

**Fallback:** Smanjiti broj tapova na 4 (zahtijeva modifikaciju pdp1_vga_crt.v)

### R2: Clock domain crossing issues (SREDNJI RIZIK)

**Simptom:** Sporadicni vizualni glitchevi, CPU hang

**Mitigacija:**
1. Koristiti proper 2-FF synchronizer za sve CDC signale
2. Verificirati u simulaciji s razlicitim clock fazama
3. Dodati CDC constraints u LPF

### R3: MIF format incompatibility (NISKI RIZIK)

**Simptom:** Krivi fontovi, nema console background

**Mitigacija:**
1. Python skripta za MIF->HEX konverziju (TASK-128)
2. Manulna verifikacija prvih/zadnjih nekoliko bajtova

### R4: BRAM resource exhaustion (NISKI RIZIK)

**Simptom:** nextpnr failure "not enough EBR"

**Mitigacija:**
1. ECP5-85F ima 208 EBR blokova (3.7 Mbit)
2. Procjena potrosnje: ~150 blokova (cak i s Rjesenjem B)
3. Ako treba, koristiti SDRAM za manje kriticne buffere

---

## Decision Log

| Datum | Odluka | Razlog | Odgovoran |
|-------|--------|--------|-----------|
| 2026-01-31 | Koristiti 75 MHz prvo | Sigurniji timing margin | Kosjenka |
| 2026-01-31 | pixel_ring_buffer Rjesenje B | Jednostavnije, EBR dovoljan | Jelena |
| 2026-01-31 | Behavioral divider | DIV rijetka, pipeline nepotreban | Potjeh |
| 2026-01-31 | ESP32 OSD odgodjen za V2 | Fokus na core funkcionalnost | Tim |

---

## Open Questions

1. **Q:** Da li 8 ciklusa latencije za time-multiplexed tapove utjece na CRT kvalitetu?
   **A:** Treba analizirati pdp1_vga_crt.v detaljnije. Za sada pretpostavljamo da replicated memory (Rjesenje B) izbjegava ovaj problem.

2. **Q:** Treba li ESP32 za osnovni port?
   **A:** Ne. ESP32 je za OSD/tape loading. Osnovni port koristi BRAM za Spacewar! ROM.

3. **Q:** Koji ULX3S verzija?
   **A:** v3.1.7 (85F). Constraint file treba verificirati pin assignment.

---

## Next Steps

1. Jelena pocinje s TASK-116 (OSS CAD Suite Setup) - **ODMAH**
2. Kosjenka priprema TASK-124 (PLL Configuration) - **ODMAH**
3. Dora priprema TASK-128 (MIF->HEX skripta) - **PARALELNO**
4. Potjeh ceka na TASK-129 completion za testbench - **DAN 3-4**

---

## Meeting Notes

**Kosjenka (Architect):**
> Kljucna stvar je da shvatimo da Emard nije ostavio prazne placeholder-e - on je ostavio **strukturirane placeholder-e** s komentarima koji tocno objasnjava sto treba napraviti. To drasticno smanjuje complexity.

**Jelena (Engineer):**
> Najveci izazov je pixel_ring_buffer. 8 simultanih BRAM citanja nije trivijalno. Preporucujem da krenemo s repliciranom memorijom - imamo resurse, a mozemo optimizirati kasnije ako treba.

**Dora (Analyst):**
> Vidim tri moguca scenarija: best case (10 dana) ako sve radi, expected case (14 dana) s uobicajenim debugging, worst case (18+ dana) ako moramo restrukturirati CRT pipeline. Preporucujem planirati za expected case ali imati contingency za worst case.

---

*Plan kreiran: 2026-01-31*
*Sljedeci review: Nakon Milestone 1 completion*
