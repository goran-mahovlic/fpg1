# OSS CAD Suite - Toolchain Setup za ULX3S

**TASK-116**: OSS CAD Suite Setup
**Autor**: Jelena Horvat, REGOC tim
**Datum**: 2026-01-31

## Pregled

Ovaj dokument opisuje instalaciju i konfiguraciju OSS CAD Suite toolchaina
za razvoj na ULX3S FPGA ploci s ECP5 cipom.

## Potrebni alati

| Alat | Namjena | Status |
|------|---------|--------|
| `yosys` | RTL sinteza (Verilog/SystemVerilog) | Potreban |
| `nextpnr-ecp5` | Place & Route za ECP5 | Potreban |
| `ecppack` | Generacija bitstreama (.bit) | Potreban |
| `openFPGALoader` | Upload na FPGA (univerzalni) | Preporucen |
| `fujprog` | Upload na ULX3S (specijalizirani) | Alternativa |

## Instalacija OSS CAD Suite

### 1. Preuzimanje

Preuzeti najnoviji release s GitHub-a:
```bash
# Za Linux x64
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-linux-x64-YYYYMMDD.tgz

# Otpakirati u /home/klaudio/Programs/
cd /home/klaudio/Programs/
tar -xzf oss-cad-suite-linux-x64-YYYYMMDD.tgz
```

Releases: https://github.com/YosysHQ/oss-cad-suite-build/releases/latest

### 2. Struktura direktorija

Nakon instalacije, struktura bi trebala biti:
```
/home/klaudio/Programs/oss-cad-suite/
├── bin/                    # Izvrsne datoteke
│   ├── yosys
│   ├── nextpnr-ecp5
│   ├── ecppack
│   ├── openFPGALoader
│   └── fujprog
├── lib/                    # Biblioteke
├── share/                  # Baze podataka (prjtrellis, etc.)
└── environment             # Aktivacijska skripta
```

## Aktivacija okruzenja

### Metoda 1: Source environment (preporuceno)

```bash
source /home/klaudio/Programs/oss-cad-suite/environment
```

Ova skripta postavlja:
- `PATH` - dodaje bin/ direktorij
- `LD_LIBRARY_PATH` - za dijeljene biblioteke
- `PYTHONPATH` - za Python module

### Metoda 2: Direktno dodavanje u PATH

```bash
export PATH="/home/klaudio/Programs/oss-cad-suite/bin:$PATH"
```

### Metoda 3: Alias u .bashrc

Dodati u `~/.bashrc`:
```bash
alias fpga-env='source /home/klaudio/Programs/oss-cad-suite/environment'
```

Zatim aktivirati s:
```bash
fpga-env
```

## Verifikacija instalacije

### Yosys (sinteza)

```bash
yosys --version
# Ocekivani output: Yosys 0.xx (git sha1 xxxxxxx, ...)

# Provjera ECP5 podrske
yosys -p "help synth_ecp5"
```

### nextpnr-ecp5 (Place & Route)

```bash
nextpnr-ecp5 --version
# Ocekivani output: nextpnr-ecp5 -- Next Generation Place and Route (version ...)

# Provjera podrzanih cipova
nextpnr-ecp5 --help | grep -E "25k|45k|85k"
```

### ecppack (Bitstream)

```bash
ecppack --help
# Trebao bi pokazati opcije za generiranje .bit datoteka
```

### openFPGALoader (Upload)

```bash
openFPGALoader --version
# Provjera detektiranih uredaja
openFPGALoader --detect
```

### fujprog (ULX3S specificno)

```bash
fujprog --version
# ili
fujprog -h
```

## Ciljni hardware

### ULX3S 85F specifikacije

| Parametar | Vrijednost |
|-----------|------------|
| FPGA | LFE5U-85F-6BG381C |
| Package | BG381 |
| Speed grade | -6 |
| LUTs | 84k |
| BRAM | 3.7 Mbit |
| DSP blokovi | 156 |
| PLLs | 4 |
| SERDES | 4 |

### Chip ID za ecppack

```
LFE5U-85F: 0x41113043
LFE5U-45F: 0x41112043
LFE5U-25F: 0x41111043
LFE5U-12F: 0x21111043
```

### nextpnr oznake

```
85F -> --85k
45F -> --45k
25F -> --25k
12F -> --25k (koristi 25k s posebnim IDCODE)
```

## Constraints file (LPF)

Koristimo ULX3S v2.0 constraints file:
```
fpg1_partial_emard/src/proj/lattice/ulx3s/constraints/ulx3s_v20_segpdi.lpf
```

Kljucni pinovi:
- `clk_25mhz` - G2 (25 MHz oscilator)
- `led[0:7]` - B2, C2, C1, D2, D1, E2, E1, H3
- `btn[0:6]` - D6, R1, T1, R18, V1, U1, H16
- GPDI (HDMI) pinovi za video output

## Build proces

### Flow dijagram

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  .sv/.v     │───▶│   Yosys     │───▶│ nextpnr-ecp5│───▶│  ecppack    │
│  source     │    │  (synth)    │    │   (P&R)     │    │ (bitstream) │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                         │                  │                  │
                         ▼                  ▼                  ▼
                   project.json      project.config      project.bit
                                                              │
                                                              ▼
                                                    ┌─────────────────┐
                                                    │ openFPGALoader  │
                                                    │ ili fujprog     │
                                                    └─────────────────┘
```

### Primjer naredbi

```bash
# 1. Sinteza
yosys -p "read_verilog -sv top.sv; synth_ecp5 -json project.json"

# 2. Place & Route
nextpnr-ecp5 --85k --json project.json --lpf ulx3s.lpf --textcfg project.config

# 3. Bitstream generacija
ecppack --input project.config --bit project.bit

# 4. Upload na FPGA (SRAM - privremeno)
openFPGALoader -b ulx3s project.bit

# ili s fujprog
fujprog project.bit

# 5. Upload na FLASH (trajno)
openFPGALoader -b ulx3s -f project.bit
# ili
fujprog -j flash project.bit
```

## Troubleshooting

### "yosys: command not found"

Environment nije aktiviran:
```bash
source /home/klaudio/Programs/oss-cad-suite/environment
```

### "ERROR: Unable to find device database"

Prjtrellis baza nije pronadena. Provjeriti da je OSS CAD Suite ispravno raspakirano
i da `share/trellis/` direktorij postoji.

### USB permission denied

Dodati korisnika u dialout grupu:
```bash
sudo usermod -a -G dialout $USER
# Logout/login potreban
```

Ili kreirati udev pravilo:
```bash
# /etc/udev/rules.d/99-ulx3s.rules
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", MODE="0666", GROUP="plugdev"
```

### nextpnr-ecp5 "No timing data for cell"

Dodati timing constraints u LPF:
```
FREQUENCY PORT "clk_25mhz" 25 MHZ;
```

## Resursi

- [OSS CAD Suite GitHub](https://github.com/YosysHQ/oss-cad-suite-build)
- [Yosys dokumentacija](https://yosyshq.readthedocs.io/)
- [nextpnr dokumentacija](https://github.com/YosysHQ/nextpnr)
- [Project Trellis (ECP5)](https://github.com/YosysHQ/prjtrellis)
- [ULX3S GitHub](https://github.com/emard/ulx3s)
- [Emard's ulx3s-misc](https://github.com/emard/ulx3s-misc)
