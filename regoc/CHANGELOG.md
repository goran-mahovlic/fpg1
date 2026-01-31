# Changelog - PDP-1 FPGA Port

## [1.0.0] - 2026-01-31

### Added
- Initial working port of PDP-1 emulator to ULX3S (ECP5 FPGA)
- 640x480@60Hz video output via HDMI
- Keyboard input mapping (accent keys)
- Joystick support for Spacewar!
- ESP32 OSD design document

### Clock Configuration
- clk_shift: 125 MHz (5x pixel clock for HDMI serialization)
- clk_pixel: 25 MHz (640x480@60Hz)
- clk_cpu: 50 MHz (PDP-1 emulation)

### Verified Modules
- line_shift_register.v - Verilator PASS
- pixel_ring_buffer.v - Verilator PASS
- pdp1_vga_crt.v - Synthesis PASS
- top_pdp1.v - Timing PASS

### Files
- `bit/pdp1_640x480_v1.bit` - Production bitstream

---

## [0.9.0] - 2026-01-30

### Added
- Initial synthesis attempt
- PLL configuration for ECP5

### Issues
- Timing violations at 1280x1024 resolution
- clk_shift 375MHz exceeded ECP5 limits

---

## [0.1.0] - 2026-01-27

### Added
- Project setup
- Research documentation
- Architecture planning
- OSS CAD Suite toolchain setup

---

## Future Plans

### [2.0.0] - Planned
- ESP32 OSD integration
- ROM loading from SD card
- WiFi configuration
- Savestate support
