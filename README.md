# PDP-1 FPGA Emulator - ULX3S Port

Port of the PDP-1 emulator from Altera Cyclone V to Lattice ECP5 (ULX3S board).

## Status: v1.0.0 ✅ WORKING!

**Resolution:** 640x480@60Hz
**Timing:** PASS
**Hardware:** ULX3S (ECP5-85F)

## Quick Start

```bash
# Build bitstream
make all

# Program ULX3S
make program

# Or manually:
fujprog bit/pdp1_640x480_v1.bit
```

## Directory Structure

```
port_fpg1/
├── bit/                    # Bitstreams
│   └── pdp1_640x480_v1.bit # Current production bitstream
├── build/                  # Build artifacts
├── docs/                   # Design documentation
│   └── ESP32_OSD_DESIGN.md # OSD system design (V2)
├── regoc/                  # REGOČ session reports
│   ├── SESSION_2026-01-31.md
│   ├── AGENTS.md
│   └── CHANGELOG.md
├── src/                    # Verilog source
├── tb/                     # Testbenches
├── tools/                  # Build tools
├── ARCHITECTURE.md         # System architecture
├── HARDWARE_TEST.md        # Hardware test procedures
├── RESEARCH.md             # Research notes
└── Makefile                # Build system
```

## Clock Configuration

| Clock | Frequency | Purpose |
|-------|-----------|---------|
| clk_shift | 125 MHz | HDMI serialization (5x pixel) |
| clk_pixel | 25 MHz | 640x480@60Hz video |
| clk_cpu | 50 MHz | PDP-1 emulation |

## Controls

### Keyboard
- **Space:** Fire
- **W/A/S/D:** Thrust/Rotate
- **H:** Hyperspace

### ULX3S Buttons
- **BTN1-4:** Player 2 controls
- **BTN5:** Menu toggle
- **BTN6:** Hyperspace

## Requirements

- OSS CAD Suite (Yosys, nextpnr-ecp5, ecppack)
- ULX3S board (ECP5-85F recommended)
- fujprog for programming

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Hardware Testing](HARDWARE_TEST.md)
- [Research Notes](RESEARCH.md)
- [ESP32 OSD Design](docs/ESP32_OSD_DESIGN.md)

---

## Original Project Notes

> emard ti poručuje: fpg1 se nije držao good practicea u kojoj se mora odvojit registarska logika od kombinacijske

> fpg1 je koristio i neki altera specific circularni buffer sa nekoliko tap-ova pomoću kojeg je odradio vector CRT fadeout

### References
- `/home/klaudio/Programs/oss-cad-suite-build/` - OSS CAD Suite
- `/home/klaudio/port_fpg1/fpg1_partial_emard/` - Emard's partial port
- https://github.com/emard - ULX3S creator
- https://github.com/lawrie - FPGA contributor

---

## REGOČ

This project was developed using the REGOČ multi-agent orchestration system.

See `regoc/` for session reports and agent contributions.

## License

Based on original PDP-1 emulator.
ULX3S port by REGOČ Team (2026).
