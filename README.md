# PDP-1 Spacewar! - Lattice ECP5 Port

Port of the classic PDP-1 Spacewar! emulator from Intel Cyclone V (MiSTer) to Lattice ECP5 (ULX3S board).

## Current Status (2026-02-09)

| Feature | Status | Notes |
|---------|--------|-------|
| Ships visible | ✅ Working | Brightness fix applied (B=0-6 expansion) |
| Central star | ✅ Working | Rotates correctly, centered at (512,512) |
| Stars background | ✅ Working | Visible with phosphor decay |
| Explosions | ✅ Working | Particle effects render correctly |
| Phosphor decay | ✅ Working | CRT glow effects visible |
| UART Debug | ✅ Working | HEX format output at 115200 baud |
| Timing closure | ✅ **PASS** | clk_pixel 51.04 MHz achieved |
| Controls | ❌ Not working | Buttons not responding |
| Player 2 | ❌ Not working | One ship flies autonomously (AI?) |

### Timing Results (2026-02-09 Optimization)

| Clock | Required | Achieved | Status |
|-------|----------|----------|--------|
| clk_shift | 255 MHz | **322.89 MHz** | ✅ PASS |
| clk_pixel | 51 MHz | **51.04 MHz** | ✅ PASS |
| clk_cpu | 51 MHz | 41.62 MHz | ⚠️ WARN* |

*CPU actually runs at 1.82 MHz (prescaler ÷28), timing constraint can be relaxed.

**See [OPTIMISATIONS.md](OPTIMISATIONS.md) for detailed timing optimization report.**

### Known Issues

1. **Controls not responding** - Button inputs not reaching CPU properly
2. **Single ship AI mode** - Only one ship controllable, other follows AI pattern
3. **Phosphor persistence** - Decay rate may need tuning for 50Hz refresh

## Hardware Target

| Parameter | Value |
|-----------|-------|
| FPGA | Lattice ECP5-45F / ECP5-85F |
| Board | ULX3S v3.1.7 |
| Resolution | 1024x768 @ 50Hz |
| HDMI Output | DVI-compatible via GPDI |

## Module Architecture

```
                                    ULX3S Board
    ┌─────────────────────────────────────────────────────────────────────────────┐
    │                                                                             │
    │   ┌─────────┐         ┌──────────────────────────────────────────────────┐  │
    │   │ 25 MHz  │         │              clk_25_shift_pixel_cpu              │  │
    │   │  XTAL   │────────▶│                    (PLL)                         │  │
    │   └─────────┘         │  ┌─────────────────────────────────────────────┐ │  │
    │                       │  │  25 MHz ──▶ VCO 510 MHz                     │ │  │
    │                       │  │         ├──▶ clk_shift  255 MHz (÷2)        │ │  │
    │                       │  │         ├──▶ clk_pixel   51 MHz (÷10)       │ │  │
    │                       │  │         └──▶ clk_cpu     51 MHz (÷10)       │ │  │
    │                       │  └─────────────────────────────────────────────┘ │  │
    │                       └────────┬───────────────┬───────────────┬─────────┘  │
    │                                │               │               │            │
    │                          clk_shift        clk_pixel        clk_cpu         │
    │                          255 MHz          51 MHz           51 MHz          │
    │                                │               │               │            │
    │   ┌────────────────────────────┼───────────────┼───────────────┼──────────┐ │
    │   │                            │               │               │          │ │
    │   │                            ▼               │               ▼          │ │
    │   │                    ┌──────────────┐        │      ┌──────────────┐    │ │
    │   │                    │  vga2dvid    │        │      │clock_domain  │    │ │
    │   │                    │  (HDMI enc)  │        │      │  (prescaler) │    │ │
    │   │                    └──────┬───────┘        │      │              │    │ │
    │   │                           │               │      │ 51MHz ÷ 28   │    │ │
    │   │                           ▼               │      │    ▼         │    │ │
    │   │                    ┌──────────────┐        │      │ clk_cpu_en  │    │ │
    │   │                    │fake_differen-│        │      │ 1.82 MHz    │    │ │
    │   │                    │    tial      │        │      └──────┬───────┘    │ │
    │   │                    │  (DDR out)   │        │             │            │ │
    │   │                    └──────┬───────┘        │             │            │ │
    │   │                           │               │             │            │ │
    │   │                           ▼               ▼             ▼            │ │
    │   │  ACTIVE           ┌───────────────────────────────────────────────┐  │ │
    │   │  VIDEO            │                  top_pdp1                     │  │ │
    │   │  PATH             │  ┌─────────────────────────────────────────┐  │  │ │
    │   │                   │  │                                         │  │  │ │
    │   │   ┌───────────────┼──┼────────────┐     ┌────────────────────┐ │  │  │ │
    │   │   │ pdp1_vga_crt  │  │            │     │    pdp1_cpu        │ │  │  │ │
    │   │   │ (CRT display) │◀─┼── CDC ────▶│     │   (PDP-1 core)     │ │  │  │ │
    │   │   │               │  │ pixel_valid│     │                    │ │  │  │ │
    │   │   │ clk_pixel     │  │ pixel_x/y  │     │ clk_cpu (1.82MHz)  │ │  │  │ │
    │   │   │ 51 MHz        │  │ brightness │     │ via clk_cpu_en     │ │  │  │ │
    │   │   │               │  │            │     │                    │ │  │  │ │
    │   │   │ Ring Buffer   │  │            │     │  ┌──────────────┐  │ │  │  │ │
    │   │   │ (256 Kbit)    │  │            │     │  │pdp1_main_ram │  │ │  │  │ │
    │   │   │               │  │            │     │  │ 4K x 18-bit  │  │ │  │  │ │
    │   │   │ Phosphor      │  │            │     │  │ (spacewar.hex│  │ │  │  │ │
    │   │   │ Decay Logic   │  │            │     │  │   ROM)       │  │ │  │  │ │
    │   │   │               │  │            │     │  └──────────────┘  │ │  │  │ │
    │   │   └───────┬───────┘  │            │     └─────────┬──────────┘ │  │  │ │
    │   │           │          │            │               │            │  │  │ │
    │   │           │          └────────────┼───────────────┘            │  │  │ │
    │   │           │                       │                            │  │  │ │
    │   │           ▼                       │                            │  │  │ │
    │   │   ┌───────────────┐               │                            │  │  │ │
    │   │   │  VGA Timing   │               │                            │  │  │ │
    │   │   │  1024x768     │               │                            │  │  │ │
    │   │   │  @50Hz        │               │                            │  │  │ │
    │   │   └───────┬───────┘               │                            │  │  │ │
    │   │           │                       │                            │  │  │ │
    │   └───────────┼───────────────────────┼────────────────────────────┘  │ │
    │               │                       │                               │ │
    │               ▼                       ▼                               │ │
    │   ┌────────────────────────────────────────────────────────────────┐  │ │
    │   │                         ACTIVE VIDEO                           │  │ │
    │   │   R[7:0], G[7:0], B[7:0], HSync, VSync ──▶ vga2dvid ──▶ HDMI   │  │ │
    │   └────────────────────────────────────────────────────────────────┘  │ │
    │                                                                       │ │
    └───────────────────────────────────────────────────────────────────────┘ │
                                                                              │
    ┌─────────────────────────────────────────────────────────────────────────┘
    │
    │   ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE
    │
    └──▶ HDMI Output (GPDI differential pairs)
```

## Clock Tree Detail

```
    25 MHz (XTAL)
        │
        ▼
    ┌────────────────────────────────────────────────────────┐
    │                    ecp5pll (PLL)                       │
    │                                                        │
    │   VCO = 510 MHz                                        │
    │     │                                                  │
    │     ├───÷2────▶ clk_shift  = 255 MHz  (HDMI DDR 5x)    │
    │     │                                                  │
    │     ├───÷10───▶ clk_pixel  =  51 MHz  (VGA timing)     │
    │     │                                                  │
    │     └───÷10───▶ clk_cpu    =  51 MHz  (CPU base)       │
    │                                                        │
    └────────────────────────────────────────────────────────┘
                          │
                          ▼
    ┌────────────────────────────────────────────────────────┐
    │                 clock_domain.v                         │
    │                                                        │
    │   clk_cpu (51 MHz)                                     │
    │     │                                                  │
    │     └───÷28───▶ clk_cpu_en = 1.82 MHz  (PDP-1 speed)   │
    │                                                        │
    │   Original PDP-1: 200 kHz - 1.79 MHz                   │
    │   Our implementation: 51 MHz / 28 = 1.821 MHz          │
    │                                                        │
    └────────────────────────────────────────────────────────┘
```

## Clock Domain Crossing (CDC)

```
    ┌─────────────────────┐                    ┌─────────────────────┐
    │    CPU DOMAIN       │                    │   PIXEL DOMAIN      │
    │    (1.82 MHz)       │                    │   (51 MHz)          │
    │                     │    clock_domain.v  │                     │
    │   pdp1_cpu.v        │    (CDC module)    │   pdp1_vga_crt.v    │
    │                     │                    │                     │
    │   pixel_x[9:0] ─────┼───▶ 2FF SYNC ─────▶│   vid_pixel_x       │
    │   pixel_y[9:0] ─────┼───▶ 2FF SYNC ─────▶│   vid_pixel_y       │
    │   brightness[2:0] ──┼───▶ 2FF SYNC ─────▶│   vid_brightness    │
    │   pixel_shift ──────┼───▶ 2FF SYNC ─────▶│   vid_pixel_shift   │
    │                     │                    │                     │
    │                     │◀── 2FF SYNC ◀──────┼── vblank            │
    │                     │                    │                     │
    └─────────────────────┘                    └─────────────────────┘

    ✅ CDC FIXED (2026-02-09): All crossings use 2-FF synchronizers
       with (* ASYNC_REG = "TRUE" *) attributes for proper placement.
```

## Module List

| Module | Clock | Function |
|--------|-------|----------|
| `top_pdp1.v` | - | Top-level integration |
| `clk_25_shift_pixel_cpu.v` | 25MHz in | PLL: generates 255/51/51 MHz |
| `ecp5pll.sv` | - | Emard's ECP5 PLL wrapper |
| `clock_domain.v` | 51MHz | Prescaler (÷28), reset sync, CDC |
| `pdp1_cpu.v` | 1.82MHz | PDP-1 CPU core emulation |
| `pdp1_cpu_alu_div.v` | 1.82MHz | ALU division unit (8-stage pipelined) |
| `pdp1_main_ram.v` | 1.82MHz | 4K x 18-bit main memory |
| `pdp1_vga_crt.v` | 51MHz | CRT phosphor decay emulation |
| `pixel_ring_buffer.v` | 51MHz | 256Kbit ring buffer for phosphor |
| `pdp1_vga_rowbuffer.v` | 51MHz | Line buffer for VGA output |
| `line_shift_register.v` | 51MHz | Shift register (replaces Altera IP) |
| `vga2dvid.v` | 51/255MHz | VGA to DVI/HDMI encoder |
| `tmds_encoder.v` | 51MHz | TMDS 8b/10b encoding |
| `fake_differential.v` | 255MHz | ECP5 DDR output (ODDRX1F) |
| `ulx3s_input.v` | 51MHz | Button debounce, active-low conversion |
| `serial_debug.v` | 51MHz | UART TX for debug output |

## Changes from Original (hrvach/fpg1)

### Clock System
| Original (Cyclone V) | Port (ECP5) | Reason |
|---------------------|-------------|--------|
| 108 MHz single clock | Multi-clock (255/51/51 MHz) | ECP5 PLL constraints |
| No CDC required | CDC everywhere | Different clock domains |
| 60 Hz refresh | 50 Hz refresh | 255 MHz safer than 325 MHz |

### Display System
| Original | Port | Reason |
|----------|------|--------|
| 1688 px/line VGA | 1264 px/line | 50Hz timing |
| Ring buffer TAP=1024 | TAP=800 | Adjusted for timing |
| Altera altshift_taps | Custom shift register | No Altera IP available |

### CRT Emulation Fixes
| Fix | Description |
|-----|-------------|
| Ship visibility | Brightness expansion for B=0-6 (ships use B=4-6) |
| Ghosting reduction | Removed blur kernel feedback loop |
| Centering | v_crt_offset=128 for proper star centering |
| Edge detection | FALLING edge for pixel_valid (not rising) |

## Build Instructions

```bash
# Install OSS CAD Suite
# https://github.com/YosysHQ/oss-cad-suite-build

# Activate toolchain
source <path-to-oss-cad-suite>/environment

# Build bitstream
make clean && make pdp1

# Program ULX3S (SRAM - temporary)
fujprog build/pdp1.bit

# Program ULX3S (FLASH - persistent)
fujprog -j flash build/pdp1.bit
# or
openFPGALoader -b ulx3s -f build/pdp1.bit
```

## Controls (NOT WORKING)

| Button | Function | Status |
|--------|----------|--------|
| BTN0 | Reset (active-low) | ✅ Works |
| BTN1-6 | Game controls | ❌ Not responding |
| SW[0] | Player 2 mode | ❌ Not tested |
| SW[1] | Serial debug | ⚠️ Untested |
| SW[2] | Sine test pattern | ⚠️ Untested |
| SW[3] | Color bars test | ⚠️ Untested |

## Debug

Enable serial debug output (115200 baud):
```bash
# Set SW[1] = ON
screen /dev/ttyUSB0 115200
```

Debug output format (HEX):
- `F:06FE PC:066 I:9D1E D:12AE V:005F X:200 Y:3FF S:1A R` - Frame info
- `P:1AC85 X:200 Y:200 B:0 R:0111` - Pixel info

| Field | Description | Format |
|-------|-------------|--------|
| F | Frame counter | 16-bit HEX |
| PC | Program Counter | 12-bit HEX |
| I | Instruction Register | 18-bit HEX |
| D | Data Bus | 18-bit HEX |
| V | VBlank counter | 16-bit HEX |
| X | Pixel X coordinate | 10-bit HEX (0-3FF) |
| Y | Pixel Y coordinate | 10-bit HEX (0-3FF) |
| B | Brightness | 3-bit HEX (0-7) |
| R | Ring buffer pointer | 16-bit HEX |

## Serial Loader (Optional)

Load programs via serial without rebuilding the FPGA bitstream.

### Enable Serial Loader

1. Uncomment in Makefile:
```makefile
DEFINES += -DSERIAL_LOADER
```

2. Rebuild:
```bash
make clean && make pdp1
```

### Protocol

| Command | Bytes | Description |
|---------|-------|-------------|
| `L` | 1 + 2 + 3 | Load word: `'L'` + addr(2B) + data(3B) |
| `W` | 1 + 3 | Set test_word (18-bit) |
| `A` | 1 + 2 | Set test_address (12-bit) |
| `R` | 1 | Run CPU |
| `S` | 1 | Stop CPU |
| `P` | 1 | Ping (returns `'K'`) |

### Python Loader

```bash
# Install pyserial
pip install pyserial

# Ping FPGA
python3 tools/serial_loader.py /dev/ttyUSB0 --ping

# Load program and run
python3 tools/serial_loader.py /dev/ttyUSB0 src/rom/snowflake.hex --run

# Load with custom start address
python3 tools/serial_loader.py /dev/ttyUSB0 src/rom/pong.hex --set-address 0o500 --run

# Stop CPU
python3 tools/serial_loader.py /dev/ttyUSB0 --stop
```

### Manual Loading (minicom/screen)

```bash
# Connect
screen /dev/ttyUSB0 115200

# Ping test (type 'P', should see 'K')
P

# Stop CPU
S

# Run CPU
R
```

### Load Format Example

Load word `0o777777` at address `0o500`:
```
'L' 0x01 0x40 0x03 0xFF 0xFF
     ├─ addr ─┤  ├── data ──┤
     (0o500)     (0o777777)
```

---

## TODO

- [ ] Fix button input handling (controls not responding)
- [ ] Test Player 2 controls
- [ ] Verify sense switch mapping
- [ ] Tune phosphor decay rate for 50Hz
- [ ] Consider async FIFO for CDC path (optional improvement)
- [ ] Relax clk_cpu timing constraint to 42 MHz

## Completed Optimizations (2026-02-09)

- [x] ~~Investigate CDC timing issues~~ - Fixed with 2-FF synchronizers
- [x] Pipelined 8-stage divider (170ns → 20ns)
- [x] HEX format serial debug (168ns → 2ns)
- [x] Pipelined 2-stage multiplier (80ns → 30ns)
- [x] Registered pixel outputs
- [x] CDC synchronizers with ASYNC_REG attributes

## Credits

- **Hrvoje Cavrak (hrvach)** - Original PDP-1 FPGA implementation
- **Emard** - ECP5 video infrastructure, ULX3S board design
- **REGOČ AI Team** - ECP5/ULX3S port, CDC fixes, debugging

## License

MIT License (inherited from original project)

## Links

- [Original Project (hrvach/fpg1)](https://github.com/hrvach/fpg1)
- [ULX3S Board](https://ulx3s.github.io/)
- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
- [Spacewar! History](https://www.masswerk.at/spacewar/)
