# PDP-1 Spacewar! - Lattice ECP5 Port

Port of the classic PDP-1 Spacewar! emulator from Intel Cyclone V (MiSTer) to Lattice ECP5 (ULX3S board).

## Current Status (2026-02-09)

| Feature | Status | Notes |
|---------|--------|-------|
| Ships visible | ✅ Working | Brightness fix applied (B=0-6 expansion) |
| Central star | ✅ Working | Rotates correctly, centered on screen |
| Stars background | ✅ Working | Visible with phosphor decay |
| Explosions | ✅ Working | Particle effects render correctly |
| Controls | ❌ Not working | Buttons not responding |
| Player 2 | ❌ Not working | One ship flies autonomously (AI?) |
| Display artifacts | ⚠️ Timing issues | "Snow" artifacts due to CDC timing |

### Known Issues

1. **Controls not responding** - Button inputs not reaching CPU properly
2. **Single ship AI mode** - Only one ship controllable, other follows AI pattern
3. **Snow artifacts** - Random pixels ("snow") due to clock domain crossing timing issues
4. **Phosphor persistence** - Decay rate may need tuning for 50Hz refresh

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
    │                     │                    │                     │
    │   pdp1_cpu.v        │    CDC PATH        │   pdp1_vga_crt.v    │
    │                     │                    │                     │
    │   pixel_x[9:0] ─────┼───▶ 2FF SYNC ─────▶│   i_pixel_x         │
    │   pixel_y[9:0] ─────┼───▶ 2FF SYNC ─────▶│   i_pixel_y         │
    │   brightness[2:0] ──┼───▶ 2FF SYNC ─────▶│   i_brightness      │
    │   pixel_valid ──────┼───▶ 2FF SYNC ─────▶│   i_pixel_valid     │
    │                     │                    │                     │
    │                     │◀── 2FF SYNC ◀──────┼── vblank            │
    │                     │                    │                     │
    └─────────────────────┘                    └─────────────────────┘

    ⚠️  KNOWN ISSUE: CDC timing causing "snow" artifacts
        - pixel_valid strobe may be missed or duplicated
        - Coordinates may be sampled during transition
```

## Module List

| Module | Clock | Function |
|--------|-------|----------|
| `top_pdp1.v` | - | Top-level integration |
| `clk_25_shift_pixel_cpu.v` | 25MHz in | PLL: generates 255/51/51 MHz |
| `ecp5pll.sv` | - | Emard's ECP5 PLL wrapper |
| `clock_domain.v` | 51MHz | Prescaler (÷28), reset sync, CDC |
| `pdp1_cpu.v` | 1.82MHz | PDP-1 CPU core emulation |
| `pdp1_cpu_alu_div.v` | 1.82MHz | ALU division unit |
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
make clean && make

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

Debug output format:
- `F:xxxx PC:xxx I:xxxx D:xxxx V:xxxx X:xxx Y:xxx R` - Frame info
- `P:xxxxx X:xxx Y:xxx B:x R:xxxx` - Pixel info

## TODO

- [ ] Fix button input handling (controls not responding)
- [ ] Investigate CDC timing issues (snow artifacts)
- [ ] Tune phosphor decay rate for 50Hz
- [ ] Test Player 2 controls
- [ ] Verify sense switch mapping
- [ ] Consider async FIFO for CDC path

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
