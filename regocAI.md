# PDP-1 Spacewar! Port to Lattice ECP5 (ULX3S)

**Repository:** [regocAI/fpg1](https://github.com/regocAI/fpg1)
**Original Project:** [hrvach/fpg1](https://github.com/hrvach/fpg1)
**Port By:** REGOC AI Team (Kosjenka, Jelena, Malik, and team)
**Date:** February 2026

---

## Current Status

| Parameter | Value |
|-----------|-------|
| **Resolution** | 1024x768 @ 50Hz |
| **Pixel Clock** | 51 MHz |
| **Shift Clock** | 255 MHz (DDR TMDS) |
| **Horizontal Freq** | 40.35 kHz |
| **Target FPGA** | Lattice ECP5-45F / ECP5-85F |
| **Board** | ULX3S v3.1.7 |
| **Image Status** | Stable, central star visible |
| **Ships Status** | NOT VISIBLE (known issue) |

### Resource Utilization (ECP5-85F)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| BRAM (DP16KD) | 72 | 108 | 66% |
| LUTs | ~25,000 | 43,848 | 58% |
| Flip-Flops | ~2,900 | 43,848 | 6% |
| MULT18X18D | 1 | 72 | 1% |

**Note:** Design fits on ECP5-45F (108 BRAM blocks available).

---

## Project Origin and Sources

This port combines three sources:

### 1. Original hrvach/fpg1 (Intel Cyclone V / MiSTer)
- **Author:** Hrvoje Cavrak (hrvach)
- **Target:** Intel/Altera Cyclone V SoC (MiSTer FPGA)
- **Resolution:** 1280x1024 @ 60Hz
- **Pixel Clock:** 108 MHz (via Altera PLL)
- **License:** MIT

### 2. Emard's Partial Port (ULX3S)
- **Author:** Emard
- **Location:** `fpg1_partial_emard/src/emard/`
- **Contribution:** ECP5-specific video infrastructure
- **Key Files:**
  - `ecp5pll.sv` - PLL wrapper for automatic frequency calculation
  - `vga2dvid.v` - VGA to DVI-D/HDMI converter
  - `tmds_encoder.v` - TMDS encoding for HDMI
  - `fake_differential.v` - DDR output using ODDRX1F primitives
  - `pixel_ring_buffer.v` - 8-tap phosphor decay emulation
  - `line_shift_register.v` - Line buffer for CRT emulation

### 3. REGOC AI Port (This Repository)
- **Team:** REGOC AI (Kosjenka, Jelena, Malik, Potjeh, Dora)
- **Target:** Lattice ECP5-45F/85F (ULX3S board)
- **Resolution:** 1024x768 @ 50Hz
- **Key Contributions:**
  - Complete build system (Makefile for yosys/nextpnr)
  - Clock domain crossing fixes
  - Resolution adaptation
  - Serial debug infrastructure
  - Gamepad/joystick mapping

---

## Detailed Changes from Original

### 1. Clock System (Complete Rewrite)

**Original (Altera):**
```verilog
// Altera PLL IP core
apll apll_inst (
    .inclk0(clk_50),      // 50 MHz input
    .c0(clk_108),         // 108 MHz pixel
    .c1(clk_54),          // 54 MHz CPU
    .locked(pll_locked)
);
```

**REGOC Port (ECP5):**
```verilog
// Emard's ecp5pll wrapper with automatic calculation
ecp5pll #(
    .in_hz(25000000),      // 25 MHz input (ULX3S oscillator)
    .out0_hz(255000000),   // 255 MHz shift clock (5x pixel for DDR)
    .out1_hz(51000000),    // 51 MHz pixel clock
    .out2_hz(51000000)     // 51 MHz CPU clock
) pll_inst (...);
```

**Why Changed:**
- ECP5 uses different PLL architecture than Altera
- ULX3S has 25 MHz oscillator (not 50 MHz)
- HDMI DDR requires 5x pixel clock for TMDS encoding
- 50Hz chosen over 60Hz to keep shift clock under 400 MHz safe limit

### 2. Video Output (Complete Rewrite)

**Original:** Direct VGA output with analog DAC
**REGOC Port:** HDMI via TMDS encoding with DDR output

| Component | Original | REGOC Port |
|-----------|----------|------------|
| Output | VGA (analog) | HDMI (digital) |
| Resolution | 1280x1024@60Hz | 1024x768@50Hz |
| Pixel Clock | 108 MHz | 51 MHz |
| Encoding | None | TMDS DDR |
| Primitives | Altera I/O | ODDRX1F |

**New Files Added:**
- `vga2dvid.v` - Converts VGA signals to DVI-D
- `tmds_encoder.v` - TMDS 8b/10b encoding
- `fake_differential.v` - DDR output driver

### 3. Timing Parameters (definitions.v)

| Parameter | Original | REGOC Port | Reason |
|-----------|----------|------------|--------|
| h_front_porch | 48 | 24 | Different standard |
| h_back_porch | 248 | 80 | Different standard |
| h_sync_pulse | 112 | 136 | Different standard |
| v_front_porch | 1 | 3 | Different standard |
| v_back_porch | 38 | 31 | Different standard |
| h_line_timing | 1688 | 1264 | 1024x768 vs 1280x1024 |
| v_line_timing | 1066 | 808 | 1024x768 vs 1280x1024 |
| h_center_offset | 128 | 0 | No centering needed |

**Added in REGOC Port:**
- `v_crt_offset` (128) - Vertical offset to center the star field

### 4. Memory Architecture

**Original:** Altera M10K BRAM with `.mif` initialization
**REGOC Port:** ECP5 DP16KD BRAM with `$readmemh` initialization

```verilog
// Original (Altera)
altsyncram #(.init_file("spacewar.mif")) ram_inst (...);

// REGOC Port (ECP5)
reg [17:0] mem [0:4095];
initial $readmemh("rom/spacewar.hex", mem);
```

**ROM Files:**
- `src/rom/spacewar.hex` - Main Spacewar! program (identical content to original)
- `src/rom/snowflake.hex` - Test pattern (optional)

### 5. Phosphor Decay Emulation

**Source:** Emard's implementation
**Key Component:** `pixel_ring_buffer.v`

- 8-tap delay line per color channel
- Simulates P31 phosphor afterglow
- Uses 8 BRAM blocks per instance (4 instances = 32 BRAM total)
- Major BRAM consumer in the design

**Potential Optimization:** Reduce to 4 taps = 50% BRAM savings

### 6. Input Handling

**Original:** MiSTer framework (directly integrated)
**REGOC Port:** Custom `ulx3s_input.v` module

Gamepad mapping (directly on FPGA GPIO):
| Button | PDP-1 Function |
|--------|----------------|
| BTN4 | Left |
| BTN5 | Right |
| BTN6 | Thrust |
| BTN7 | Fire |
| BTN8 | Hyperspace |

### 7. Serial Debug (New Feature)

**File:** `serial_debug.v`
**Purpose:** Runtime debugging via UART

Features:
- Can be enabled/disabled via SW[1]
- Outputs CPU state, pixel coordinates, frame timing
- 115200 baud UART
- Useful for development but can be disabled for production

---

## Build System

**Toolchain:** Open source (yosys + nextpnr-ecp5 + ecppack)

```bash
# Prerequisites - install oss-cad-suite from https://github.com/YosysHQ/oss-cad-suite-build
source <path-to-oss-cad-suite>/environment

# Build
make clean && make pdp1

# Output
build/pdp1.bit  # Compressed bitstream (~660 KB)
```

**Makefile Features:**
- Automatic synthesis with yosys
- Place & route with nextpnr-ecp5
- Timing analysis with `--timing-allow-fail`
- Compressed bitstream generation

---

## Known Issues

### 1. Ships Not Visible
- Central star and stars are visible
- Spacewar! ships do not appear
- Likely cause: coordinate system mismatch or pixel brightness threshold
- Status: Under investigation

### 2. 60Hz Not Working
- Monitor rejects 60Hz timing with current parameters
- 50Hz works reliably
- 60Hz requires 65 MHz pixel clock = 325 MHz shift clock
- Should work on ECP5-85F speed grade -6 (up to 400 MHz)
- Status: Needs timing parameter adjustment

### 3. BRAM Usage
- Design uses 72 BRAM blocks
- Fits on 45F (108 available) and 85F (208 available)
- Does NOT fit on 25F (56 available)
- Phosphor decay (pixel_ring_buffer) is main consumer

---

## File Structure

```
port_fpg1/
├── src/                      # Main source files
│   ├── top_pdp1.v           # Top-level module
│   ├── pdp1_cpu.v           # PDP-1 CPU (modified from original)
│   ├── pdp1_vga_crt.v       # CRT emulation (heavily modified)
│   ├── definitions.v         # Timing parameters (modified)
│   ├── clk_25_shift_pixel_cpu.sv  # PLL configuration (new)
│   ├── ecp5pll.sv           # Emard's PLL wrapper
│   ├── vga2dvid.v           # VGA to HDMI converter
│   ├── pixel_ring_buffer.v  # Phosphor decay
│   ├── serial_debug.v       # Debug output (new)
│   └── rom/
│       └── spacewar.hex     # Spacewar! program
├── fpg1/                     # Original hrvach repository (reference)
├── fpg1_partial_emard/       # Emard's partial port (reference)
├── Makefile                  # Build system
└── regocAI.md               # This file
```

---

## Credits

- **Hrvoje Cavrak (hrvach)** - Original PDP-1 FPGA implementation
- **Emard** - ECP5 video infrastructure and PLL wrapper
- **REGOC AI Team** - ECP5/ULX3S port and integration
  - Kosjenka Vuković - System architecture
  - Jelena Kovačević - FPGA engineering, timing
  - Malik Hodžić - Security review
  - Potjeh - QA and testing
  - Dora - Analysis

---

## License

MIT License (inherited from original project)

---

## Links

- [Original MiSTer Core](https://github.com/hrvach/fpg1)
- [ULX3S Board](https://ulx3s.github.io/)
- [Emard's ULX3S Examples](https://github.com/emard/ulx3s-misc)
- [PDP-1 Wikipedia](https://en.wikipedia.org/wiki/PDP-1)
- [Spacewar! History](https://en.wikipedia.org/wiki/Spacewar!)
