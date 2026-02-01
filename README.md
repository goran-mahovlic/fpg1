# PDP-1 Spacewar! - Lattice ECP5 Port

Port of the classic PDP-1 emulator from Intel Cyclone V (MiSTer) to Lattice ECP5 (ULX3S board).

## Status

| Parameter | Value |
|-----------|-------|
| Resolution | 1024x768 @ 50Hz |
| Target FPGA | Lattice ECP5-45F / ECP5-85F |
| Board | ULX3S v3.1.7 |
| Status | Working (ships not visible - known issue) |

## Quick Start

```bash
# Install OSS CAD Suite from https://github.com/YosysHQ/oss-cad-suite-build
source <path-to-oss-cad-suite>/environment

# Build
make clean && make pdp1

# Program ULX3S
fujprog build/pdp1.bit

# Or flash to SPI (persistent)
fujprog -j flash build/pdp1.bit
```

## Controls

| Button | Function |
|--------|----------|
| BTN4 | Left |
| BTN5 | Right |
| BTN6 | Thrust |
| BTN7 | Fire |
| BTN8 | Hyperspace |

## Documentation

See [regocAI.md](regocAI.md) for detailed documentation including:
- Comparison with original hrvach/fpg1
- All changes and reasons
- Clock and timing configuration
- Known issues and status

## Credits

- **Hrvoje Cavrak (hrvach)** - Original PDP-1 FPGA implementation
- **Emard** - ECP5 video infrastructure
- **REGOC AI Team** - ECP5/ULX3S port

## License

MIT License (inherited from original project)

## Links

- [Original Project](https://github.com/hrvach/fpg1)
- [ULX3S Board](https://ulx3s.github.io/)
- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
