# Changelog - PDP-1 FPGA Port (ULX3S ECP5)

## [2.1.0] - 2026-01-31

### MAJOR: CPU Integration (TASK-213)

**New Files:**
- `src/pdp1_cpu.v` - Full PDP-1 CPU ported from original fpg1 project
- `src/pdp1_main_ram.v` - 4096x18-bit dual-port RAM with Spacewar! preloaded

**Bug Fixes Applied:**

#### Fix #1: RAM Path (Critical)
- **Problem:** `$readmemh("rom/spacewar.hex")` used relative path - Yosys couldn't find file
- **Solution:** Changed to absolute path `/home/klaudio/port_fpg1/src/rom/spacewar.hex`
- **File:** `src/pdp1_main_ram.v` line 40

#### Fix #2: Edge Detection
- **Problem:** CRT module used RISING edge (`~prev_prev & prev`) instead of FALLING
- **Solution:** Changed to FALLING edge detection (`prev_prev & ~prev`)
- **File:** `src/pdp1_vga_crt.v` line 440

#### Fix #3: Coordinate Transformation
- **Problem:** Signed arithmetic used instead of unsigned (original uses unsigned)
- **Solution:** Reverted to unsigned: `IO[17:8] + 10'd256`
- **File:** `src/pdp1_cpu.v` lines 699-702

#### Fix #4: waste_cycles Scaling (Clock Mismatch)
- **Problem:** CPU expects 50 MHz but receives 6.25 MHz - all timing 8x slower
- **Solution:** Scaled all waste_cycles values by ÷8
- **File:** `src/pdp1_cpu.v` lines 805-813
- **Changes:**
  - default: 250 → 31
  - multiply: 1000 → 125
  - divide: 1750 → 219
  - CRT display: 2250 → 281

### Clock Configuration
- **PLL Output:** 6.25 MHz CPU clock (reduced from 50 MHz for timing PASS)
- **File:** `src/clk_25_shift_pixel_cpu.sv`

### HPD (Hot Plug Detect)
- Changed from OUTPUT to INPUT with PULLMODE=DOWN
- Pin B20 configured correctly
- **File:** `src/ulx3s_v317_pdp1.lpf`, `src/top_pdp1.v`

### Serial Debug
- Enhanced debug output: Frame counter, X/Y coordinates, LED status
- Baud rate: 115200
- **File:** `src/serial_debug.v`

### Known Issues (Still Investigating)
- Image remains static (vertical green lines)
- Button inputs not affecting display (except reset)
- Pixel rate may still be too slow
- CPU may be stuck in loop or waiting for input

### Debug Team
- Jelena Horvat (Engineer) - CPU integration
- Kosjenka (Architect) - Code review
- Malik (Debug Specialist) - Serial analysis
- Emard (FPGA Crisis Expert) - Clock/timing analysis

### RAG Documents
- `doc_1769884252723_od6utf` - Debug session report
- `doc_1769884356508_r9esz` - Session summary
- `doc_1769890413330_d56s7` - Root cause: clock mismatch
- `doc_1769891025228_crm0t` - Fix implementation

---

## [2.0.0] - 2026-01-31

### Initial CPU-less Version
- VGA 640x480@60Hz output working
- Test animation functional
- HDMI output via GPDI
- Serial debug infrastructure

---

## References
- Original fpg1: https://github.com/hrvach/fpg1
- ULX3S: https://github.com/emard/ulx3s
- PDP-1 pixel rate: ~20,000 pixels/second
