# PDP-1 v2 Cleanup & Investigation Plan

**Document:** PDP1_V2.md
**Created:** 2026-02-06
**Authors:** REGOC Team
- **Kosjenka** (Architect) - Architecture review, clock analysis
- **Jelena** (Engineer) - FPGA implementation, clock paths
- **Manda** (Researcher) - Verilog vs SystemVerilog research
- **Potjeh** (QA) - File audit, cleanup checklist

---

## 1. EXECUTIVE SUMMARY

This document provides a comprehensive audit of the PDP-1 Spacewar! FPGA port for ULX3S. The project successfully runs on ECP5-45F but requires cleanup to remove Altera leftovers, consolidate duplicate files, and address potential timing issues.

### Key Findings:
1. **Clock Configuration:** 25 MHz crystal -> PLL -> 255 MHz shift, 51 MHz pixel, 51 MHz CPU (not 6.25 MHz as documented!)
2. **Reset Strategy:** Proper async assert/sync deassert with PLL lock gating
3. **Altera Leftovers:** Multiple VHDL/Verilog files from original MiSTer port need removal
4. **SystemVerilog Required:** Only for `ecp5pll.sv` (uses $error, functions) - wrapper can be pure Verilog
5. **Potential Timing Issues:** Blur kernel blocking/non-blocking assignment mixing identified

---

## 2. FILE INVENTORY

### 2.1 Active Source Files (src/)

| File | Format | Status | Notes |
|------|--------|--------|-------|
| `top_pdp1.v` | Verilog | ACTIVE | Top-level module, 1290 lines |
| `ecp5pll.sv` | SystemVerilog | ACTIVE | Emard's parametric PLL (REQUIRED SV) |
| `clk_25_shift_pixel_cpu.sv` | SystemVerilog | ACTIVE | PLL wrapper (could be .v) |
| `clock_domain.v` | Verilog | ACTIVE | Clock prescaler, CDC, reset sequencing |
| `definitions.v` | Verilog | ACTIVE | Timing constants for 1024x768@50Hz |
| `ulx3s_input.v` | Verilog | ACTIVE | Button debounce, joystick mapping |
| `pdp1_cpu.v` | Verilog | ACTIVE | PDP-1 CPU core (920 lines) |
| `pdp1_main_ram.v` | Verilog | ACTIVE | 4K x 18-bit RAM with initialization |
| `pdp1_cpu_alu_div.v` | Verilog | ACTIVE | Division unit |
| `pdp1_vga_crt.v` | Verilog | ACTIVE | CRT phosphor decay emulation (608 lines) |
| `pdp1_vga_rowbuffer.v` | Verilog | ACTIVE | 8-line lookahead buffer |
| `pixel_ring_buffer.v` | Verilog | ACTIVE | 8-tap circular buffer for decay |
| `line_shift_register.v` | Verilog | ACTIVE | 1264-pixel delay line |
| `vga2dvid.v` | Verilog | ACTIVE | VGA to TMDS converter |
| `tmds_encoder.v` | Verilog | ACTIVE | TMDS 8b/10b encoder |
| `serial_debug.v` | Verilog | ACTIVE | UART debug output |
| `test_animation.v` | Verilog | ACTIVE | "Orbital Spark" test pattern |
| `pdp1_terminal_fb.v` | Verilog | ACTIVE | Terminal framebuffer (stub) |
| `pdp1_terminal_charset.v` | Verilog | ACTIVE | Terminal charset (stub) |

### 2.2 Supporting Files (src/)

| File | Format | Status | Notes |
|------|--------|--------|-------|
| `ulx3s_v317_pdp1.lpf` | LPF | ACTIVE | Pin constraints for PDP-1 |
| `ulx3s_v31_esp32.lpf` | LPF | OPTIONAL | ESP32 pin constraints |
| `rom/minskytron_init.vh` | Verilog Header | ACTIVE | Memory initialization |

### 2.3 Altera Leftovers (TO BE REMOVED)

| File | Reason for Removal |
|------|-------------------|
| `apll.vhd` | Altera PLL wrapper (not used) |
| `apll.qip` | Quartus IP file |
| `apll/apll_0002.v` | Altera-generated PLL internals |
| `PDP1.qpf` | Quartus project file |
| `PDP1.qsf` | Quartus settings file |
| `PDP1.srf` | Quartus source file |
| `pdp1.sv` | Original MiSTer top (replaced by top_pdp1.v) |
| `cpu.v` | Original CPU (replaced by pdp1_cpu.v) |
| `memory.v` | Original memory (replaced by pdp1_main_ram.v) |
| `keyboard.v` | MiSTer keyboard (not used on ULX3S) |
| `pll_config.v` | Old PLL config (using ecp5pll now) |
| `PLL_CONFIG.md` | Outdated documentation |

### 2.4 sys/ Directory (Altera MiSTer Infrastructure)

**RECOMMENDATION:** Entire `src/sys/` directory should be removed or archived.

| File | Status | Notes |
|------|--------|-------|
| `ascal.vhd` | NOT USED | Altera scaler |
| `hdmi_config.sv` | NOT USED | MiSTer HDMI config |
| `hq2x.sv` | NOT USED | HQ2X scaler |
| `hps_io.v` | NOT USED | HPS (ARM) interface |
| `lpf48k.sv` | NOT USED | Audio LPF |
| `osd.v` | NOT USED | MiSTer OSD |
| `pll*.v, pll*.qip` | NOT USED | Altera PLLs |
| `scandoubler.v` | NOT USED | VGA scandoubler |
| `sd_card.v` | NOT USED | SD card interface |
| `sigma_delta_dac.v` | NOT USED | Audio DAC |
| `spdif.v` | NOT USED | S/PDIF audio |
| `sysmem.sv` | NOT USED | System memory |
| `sys_top.v` | NOT USED | MiSTer sys top |
| `video_mixer.sv` | NOT USED | Video mixer |

### 2.5 ESP32 OSD Modules (Optional Feature)

| File | Status | Notes |
|------|--------|-------|
| `esp32_osd.v` | OPTIONAL | ESP32 OSD top module |
| `esp32_osd_buffer.v` | OPTIONAL | OSD buffer memory |
| `esp32_osd_renderer.v` | OPTIONAL | OSD rendering |
| `esp32_spi_slave.v` | OPTIONAL | SPI slave interface |

### 2.6 Backup Files (TO BE REMOVED)

| File | Reason |
|------|--------|
| `pdp1_main_ram_snowflake.v` | Duplicate of pdp1_main_ram.v |
| `pdp1_main_ram_snowflake.v.bak` | Backup file |

---

## 3. CLOCK ANALYSIS

### 3.1 ULX3S Crystal Frequency

**ANSWER:** The ULX3S board has a **25 MHz** onboard oscillator.

Source: ULX3S schematic and `top_pdp1.v` line 67:
```verilog
input  wire        clk_25mhz,      // 25 MHz onboard oscillator
```

### 3.2 Complete Clock Path Diagram

```
CLOCK PATH:
===========

Crystal (25 MHz)
    |
    v
+-------------------+
| ecp5pll.sv        |  Emard's parametric PLL
| (in_hz=25000000)  |
+-------------------+
    |
    +-----> clk_shift  = 255 MHz (HDMI DDR serializer, 5x pixel)
    |       out0_hz = 255000000
    |
    +-----> clk_pixel  = 51 MHz  (VGA timing, 1024x768@50Hz)
    |       out1_hz = 51000000
    |
    +-----> clk_cpu    = 51 MHz  (CPU base clock - NOT 6.25 MHz!)
            out2_hz = 51000000
```

### 3.3 Clock Configuration Discrepancy (CRITICAL!)

**PROBLEM IDENTIFIED:**

The `clk_25_shift_pixel_cpu.sv` wrapper sets:
```systemverilog
.out2_hz    (51000000),     // 51 MHz CPU clock
```

But the `clock_domain.v` comment says:
```verilog
// - clk_cpu (1.79 MHz)  : PDP-1 originalna frekvencija
```

And `top_pdp1.v` header says:
```verilog
//   - clk_cpu    : 6.25 MHz - PDP-1 CPU emulation
```

**ACTUAL BEHAVIOR:**
- PLL outputs 51 MHz on clk_cpu
- `clock_domain.v` has a prescaler that divides by 28:
  ```verilog
  localparam PRESCALER_DIV = 28;
  ```
- 51 MHz / 28 = **1.82 MHz** (close to original PDP-1 1.79 MHz)

**CONCLUSION:** The clk_cpu clock enable runs at ~1.82 MHz, not 6.25 MHz.

### 3.4 Clock Domain Summary

| Domain | Frequency | Purpose |
|--------|-----------|---------|
| clk_shift | 255 MHz | HDMI DDR serialization (5x pixel) |
| clk_pixel | 51 MHz | VGA timing generation, CRT emulation |
| clk_cpu | 51 MHz base, 1.82 MHz effective | PDP-1 CPU execution |

### 3.5 CDC (Clock Domain Crossing) Paths

1. **CPU -> Pixel:** Pixel coordinates (23 bits) via HOLD registers + 3FF sync
2. **Pixel -> CPU:** VBlank signal via 2FF synchronizer
3. **External -> CPU:** DIP switches via 2FF synchronizer
4. **External -> Pixel:** Buttons via ulx3s_input debouncer

All CDC crossings use proper synchronization with `(* ASYNC_REG = "TRUE" *)` attributes.

---

## 4. RESET ANALYSIS

### 4.1 Reset Signal Flow

```
RESET PATH:
===========

btn[0] (Active-LOW from PCB)
    |
    v
+-------------------+
| top_pdp1.v        |  Inverted, combined with PLL lock
| rst_n = btn[0]    |
+-------------------+
    |
    v
+-------------------+
| clock_domain.v    |  Reset sequencing
| - 3FF sync        |
| - 16 cycle delay  |
+-------------------+
    |
    +-----> rst_pixel_n  (synced to clk_pixel)
    |
    +-----> rst_cpu_n    (synced to clk_cpu_fast)
```

### 4.2 Reset Strategy Details

From `clock_domain.v`:

```verilog
// Reset sequencing: wait 16 cycles after PLL lock
localparam RESET_DELAY = 16;

// 3-stage synchronizer for PLL lock signal
pixel_rst_sync <= {pixel_rst_sync[1:0], pll_locked};
```

**Best Practices Compliance:**
- Asynchronous assert (immediately on reset button)
- Synchronous deassert (after PLL lock + 16 cycles)
- Separate reset per clock domain

### 4.3 Reset in ulx3s_input Module

The `ulx3s_input` module receives `i_rst_n` (already synchronized to clk_pixel) and uses it for:
- Button synchronizer reset
- Debounce counter reset
- Output register reset

**No reset inversion issue found** - the module correctly uses active-low reset.

---

## 5. LANGUAGE AUDIT (Verilog vs SystemVerilog vs VHDL)

### 5.1 SystemVerilog Features Usage

| File | SV Feature Used | Can Be Pure Verilog? | Reason |
|------|-----------------|---------------------|--------|
| `ecp5pll.sv` | `function`, `$error()`, for-loop in function | NO | Parametric calculations require SV functions |
| `clk_25_shift_pixel_cpu.sv` | None (just instantiation) | YES | Simple wrapper, no SV features |
| `pdp1.sv` | Logic arrays, interfaces | YES | Not used in current design |

### 5.2 VHDL Files Analysis

| File | Required? | Reason |
|------|-----------|--------|
| `apll.vhd` | NO | Altera PLL - replaced by ecp5pll.sv |
| `ascal.vhd` | NO | Altera scaler - not used |
| `vga2dvid.vhd` (Emard) | NO | Have Verilog replacement |
| `tmds_encoder.vhd` (Emard) | NO | Have Verilog replacement |

### 5.3 Conversion Recommendations

| Current | Recommended | Action |
|---------|-------------|--------|
| `clk_25_shift_pixel_cpu.sv` | `clk_25_shift_pixel_cpu.v` | Rename, no code changes needed |
| `ecp5pll.sv` | Keep as `.sv` | Required for SV functions |
| `fake_differential.v` | Keep as `.v` | Already pure Verilog |

---

## 6. CLEANUP CHECKLIST

### 6.1 Files to DELETE (Immediate)

```bash
# Altera project files
rm src/PDP1.qpf src/PDP1.qsf src/PDP1.srf
rm src/apll.qip src/apll.vhd
rm -rf src/apll/

# Backup files
rm src/pdp1_main_ram_snowflake.v.bak

# Duplicate files
rm src/pdp1_main_ram_snowflake.v  # Keep pdp1_main_ram.v

# Old/replaced modules
rm src/cpu.v           # Replaced by pdp1_cpu.v
rm src/memory.v        # Replaced by pdp1_main_ram.v
rm src/keyboard.v      # Not used on ULX3S
rm src/pdp1.sv         # Replaced by top_pdp1.v
rm src/pll_config.v    # Using ecp5pll.sv
rm src/PLL_CONFIG.md   # Outdated docs

# MiSTer OSD (if not using ESP32)
# rm src/pdp1_vga_console.v
# rm src/pdp1_vga_typewriter.v
```

### 6.2 Directories to ARCHIVE or DELETE

```bash
# Archive original MiSTer sources (for reference)
mkdir -p archive/mister_original
mv src/sys/ archive/mister_original/

# Keep only needed video modules
cp archive/mister_original/sys/fake_differential.v src/
```

### 6.3 LPF File Consolidation

**Current:**
- `src/ulx3s_v317_pdp1.lpf` - Active
- `src/ulx3s_v31_esp32.lpf` - ESP32 only

**Recommendation:** Keep both, clearly document purpose.

### 6.4 MIF Files Review

| File | Status | Notes |
|------|--------|-------|
| `console_bg.mif` | UNUSED | MiSTer console background |
| `spacewar.mif` | UNUSED | Original Spacewar ROM format |
| `fiodec_charset.mif` | UNUSED | Typewriter charset |
| `rom/minskytron.hex` | ACTIVE | Converted to minskytron_init.vh |

---

## 7. MAKEFILE TEMPLATE

### 7.1 Current Issues
- Multiple target configurations
- Redundant FPGA_SIZE definitions
- Mixed Croatian/English comments

### 7.2 Recommended Clean Makefile

```makefile
# =============================================================================
# PDP-1 Spacewar! for ULX3S
# =============================================================================
PROJECT      = pdp1
BOARD        = ulx3s
FPGA_SIZE    = 45

# FPGA specifications (ULX3S 45F: LFE5U-45F-6BG381C)
FPGA_DEVICE  = LFE5U-$(FPGA_SIZE)F
FPGA_PACKAGE = CABGA381
FPGA_SPEED   = 6
FPGA_IDCODE  = 0x41112043

# Toolchain
YOSYS        = yosys
NEXTPNR      = nextpnr-ecp5
ECPPACK      = ecppack
PROGRAMMER   = openFPGALoader

# Directories
SRC_DIR      = src
BUILD_DIR    = build

# Source files (explicit list - no wildcards)
SV_FILES     = \
    $(SRC_DIR)/ecp5pll.sv \
    $(SRC_DIR)/clk_25_shift_pixel_cpu.sv

V_FILES      = \
    $(SRC_DIR)/top_pdp1.v \
    $(SRC_DIR)/clock_domain.v \
    $(SRC_DIR)/ulx3s_input.v \
    $(SRC_DIR)/pdp1_cpu.v \
    $(SRC_DIR)/pdp1_cpu_alu_div.v \
    $(SRC_DIR)/pdp1_main_ram.v \
    $(SRC_DIR)/pdp1_vga_crt.v \
    $(SRC_DIR)/pdp1_vga_rowbuffer.v \
    $(SRC_DIR)/pixel_ring_buffer.v \
    $(SRC_DIR)/line_shift_register.v \
    $(SRC_DIR)/vga2dvid.v \
    $(SRC_DIR)/tmds_encoder.v \
    $(SRC_DIR)/fake_differential.v \
    $(SRC_DIR)/serial_debug.v \
    $(SRC_DIR)/test_animation.v \
    $(SRC_DIR)/pdp1_terminal_fb.v \
    $(SRC_DIR)/pdp1_terminal_charset.v

# Constraints
LPF_FILE     = $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# Output files
JSON_FILE    = $(BUILD_DIR)/$(PROJECT).json
CONFIG_FILE  = $(BUILD_DIR)/$(PROJECT).config
BIT_FILE     = $(BUILD_DIR)/$(PROJECT).bit

# =============================================================================
# TARGETS
# =============================================================================
.PHONY: all synth pnr bit prog clean

all: bit

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

synth: $(JSON_FILE)
$(JSON_FILE): $(SV_FILES) $(V_FILES) | $(BUILD_DIR)
	$(YOSYS) -p "\
		read_verilog -sv $(SV_FILES); \
		read_verilog -I$(SRC_DIR) $(V_FILES); \
		hierarchy -top top_pdp1; \
		synth_ecp5 -json $@"

pnr: $(CONFIG_FILE)
$(CONFIG_FILE): $(JSON_FILE) $(LPF_FILE)
	$(NEXTPNR) \
		--$(FPGA_SIZE)k \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(JSON_FILE) \
		--lpf $(LPF_FILE) \
		--textcfg $@

bit: $(BIT_FILE)
$(BIT_FILE): $(CONFIG_FILE)
	$(ECPPACK) --idcode $(FPGA_IDCODE) --input $< --bit $@ --compress

prog: $(BIT_FILE)
	$(PROGRAMMER) -b $(BOARD) $<

clean:
	rm -rf $(BUILD_DIR)
```

---

## 8. TIMING ISSUES (Blur/Pipeline)

### 8.1 Emard's Warning

**CRITICAL:** Blur can occur when naively replacing blocking (`=`) with non-blocking (`<=`) assignments without understanding timing.

Problem: Old and new data mix when:
1. Read and write happen in same cycle
2. Pipeline stages aren't properly aligned

### 8.2 Identified Suspicious Sections

#### 8.2.1 pdp1_vga_crt.v - Blur Kernel (Line 529-536)

```verilog
if (r_p22 < BRIGHTNESS) begin
    r_pixel_out <= ({8'b0, r_p11[7:1]} + r_p12 + r_p13 +
                    r_p21 + r_p22 + r_p23 +
                    r_p31 + r_p32 + r_p33[7:1]) >> 3;
    r_p21 <= r_pixel_out;  // SUSPICIOUS: Using r_pixel_out before it's updated
end
```

**Issue:** `r_p21` is assigned `r_pixel_out` from the *current* cycle, but `r_pixel_out` won't have the new value until *next* cycle due to non-blocking assignment.

**Potential Fix:** Add pipeline register or reorder assignments.

#### 8.2.2 pdp1_vga_crt.v - Unified Search/Erase (Line 540-586)

This section was fixed on 2026-02-05 by Jelena to use unified search and erase logic. The fix uses temporary variables (`v_pixel_found`, `v_wraddr`, `v_wdata`) which are blocking assignments within an always block - this is acceptable for combinational logic preceding sequential assignments.

#### 8.2.3 pixel_ring_buffer.v - Write-Read Conflict

```verilog
always @(posedge i_clk) begin
    // Write: Store input data to all 8 memories
    r_mem0[r_wrptr] <= i_shiftin;
    // ...

    // Read: Fetch data from each memory
    r_tap_data0 <= r_mem0[w_rdptr0];  // What if w_rdptr0 == r_wrptr?
    // ...
```

**Status:** This uses BRAM's write-first behavior - reading same address as write will get OLD value. This is intentional for delay line behavior.

### 8.3 Recommended Actions

1. **Add pipeline diagram** to pdp1_vga_crt.v showing data flow timing
2. **Review blur kernel** - the `r_p21 <= r_pixel_out` assignment looks suspicious
3. **Document write-first behavior** in pixel_ring_buffer.v

---

## 9. ACTION ITEMS

### Priority 1 (CRITICAL)

| Task | Owner | Status |
|------|-------|--------|
| Fix clock_domain.v documentation (1.82 MHz not 1.79 MHz) | Kosjenka | TODO |
| Fix top_pdp1.v header (6.25 MHz -> 1.82 MHz) | Kosjenka | TODO |
| Review blur kernel r_p21 assignment | Jelena | TODO |

### Priority 2 (HIGH)

| Task | Owner | Status |
|------|-------|--------|
| Delete Altera leftovers per Section 6.1 | Potjeh | TODO |
| Archive sys/ directory | Potjeh | TODO |
| Rename clk_25_shift_pixel_cpu.sv to .v | Manda | TODO |
| Update Makefile to clean version | Jelena | TODO |

### Priority 3 (MEDIUM)

| Task | Owner | Status |
|------|-------|--------|
| Translate remaining Croatian comments to English | Team | TODO |
| Remove unused MIF files | Potjeh | TODO |
| Add pipeline timing diagram to pdp1_vga_crt.v | Jelena | TODO |
| Document CDC paths in ARCHITECTURE.md | Kosjenka | TODO |

### Priority 4 (LOW)

| Task | Owner | Status |
|------|-------|--------|
| Remove ESP32 OSD modules if not using | Potjeh | OPTIONAL |
| Create test bench for blur kernel | Jelena | NICE-TO-HAVE |
| Consolidate LPF files | Potjeh | NICE-TO-HAVE |

---

## 10. APPENDIX: Croatian to English Comment Translations

### Files Requiring Translation

| File | Line | Croatian | English |
|------|------|----------|---------|
| `clk_25_shift_pixel_cpu.sv` | 4-10 | Multiple | See below |
| `clock_domain.v` | 8-17 | Multiple | See below |
| `definitions.v` | 1-11 | Multiple | See below |
| `Makefile` | Various | Multiple | See below |

### Sample Translations

| Croatian | English |
|----------|---------|
| Autorica | Author |
| Generirao | Generated by |
| Koristi | Uses |
| Izracun | Calculation |
| Zasto | Why |
| Umjesto | Instead of |
| Izmedju | Between |
| Cekaj | Wait |
| Oslobodi | Release |
| Sinkronizirano | Synchronized |

---

## V2.1 COMPLETE REVIEW PLAN

**Review Date:** 2026-02-06
**Review Team:** REGOC Council Meeting
- **Kosjenka** (Architect) - Clock architecture, system design
- **Jelena** (Engineer) - Implementation, best practices compliance
- **Manda** (Researcher) - Documentation, HDL standards research
- **Potjeh** (QA) - File audit, cleanup verification

---

### 1. CLOCK PATH INVESTIGATION - DEFINITIVE ANALYSIS

#### 1.1 Crystal Frequency: CONFIRMED 25 MHz

**Source:** ULX3S schematic and `top_pdp1.v` line 69:
```verilog
input  wire        clk_25mhz,      // 25 MHz onboard oscillator
```

**User Confusion Resolved:** "vidim 25MHz a ulaz je 50MHz" - The ULX3S board uses a 25 MHz crystal, NOT 50 MHz. The user may have been looking at a different board or documentation.

#### 1.2 Complete Clock Path Diagram

```
CLOCK TREE - PDP-1 on ULX3S
============================

                         +-- clk_shift = 255 MHz (HDMI DDR serializer)
                         |   out0_hz = 255000000
                         |   [5x pixel clock for DDR TMDS]
                         |
 Crystal (25 MHz)        +-- clk_pixel = 51 MHz (VGA timing)
       |                 |   out1_hz = 51000000
       v                 |   [1024x768 @ 50Hz]
 +-------------+         |
 | ecp5pll.sv  |---------+-- clk_cpu = 51 MHz (CPU base)
 | (Emard's)   |             out2_hz = 51000000
 +-------------+             [Same as pixel - note: NOT 6.25 MHz!]
                                    |
                                    v
                         +--------------------+
                         | clock_domain.v     |
                         | PRESCALER_DIV = 28 |
                         +--------------------+
                                    |
                                    v
                         clk_cpu_en = 1.82 MHz (effective)
                         [51 MHz / 28 = 1.821 MHz]
                         [Close to original PDP-1 @ 1.79 MHz]
```

#### 1.3 PLL Configuration Details (from ecp5pll.sv instantiation in top_pdp1.v)

```verilog
ecp5pll
#(
    .in_hz(25*1000000),      // 25 MHz input
    .out0_hz(255*1000000),   // 255 MHz shift clock
    .out1_hz(51*1000000)     // 51 MHz pixel/CPU clock
)
```

**CRITICAL DISCREPANCIES FOUND:**

| Location | Claims | Actual |
|----------|--------|--------|
| `top_pdp1.v` header (line 19) | clk_cpu = 51 MHz | CORRECT |
| `top_pdp1.v` header (old) | clk_cpu = 6.25 MHz | WRONG |
| `clock_domain.v` comment | clk_cpu = 1.79 MHz | CLOSE (actual 1.82 MHz) |
| `test_sinus.v` comment | CPU clock = 6.25 MHz | WRONG |
| `clk_25_shift_pixel_cpu.sv` | out2_hz = 51000000 | CORRECT |

#### 1.4 Clock Enable vs Gated Clock

The design correctly uses clock enable rather than gated clock:
- `clk_cpu_fast` (51 MHz) is the actual clock signal
- `clk_cpu_en` is a single-cycle pulse at 1.82 MHz rate
- CPU logic uses `if (clk_cpu_en)` pattern for timing

This is the recommended FPGA pattern per HDL best practices.

#### 1.5 ECP5PLL Usage Verification

Emard's `ecp5pll.sv` is properly used:
- Parametric design calculates optimal dividers at synthesis time
- Uses functions for VCO/PFD constraint validation
- EHXPLLL primitive correctly instantiated
- Locked signal properly synchronized through 3-FF chain

**VERDICT:** Clock path is correctly implemented. Documentation needs updates.

---

### 2. BTN/RST FLOW ANALYSIS

#### 2.1 Current Signal Flow

```
RESET PATH ANALYSIS
===================

btn[6] (F2 button) ----------------+
  [Active-LOW from PCB]            |
                                   v
                          +----------------+
                          | top_pdp1.v     |
                          | (line 201)     |
                          +----------------+
                                   |
                          .rst_n(btn[6])
                                   |
                                   v
                          +----------------+
                          | clock_domain.v |
                          +----------------+
                             |         |
                             v         v
                    rst_pixel_n    rst_cpu_n
                    [3-FF sync]    [3-FF sync]
                    [16 cycle     [16 cycle
                     delay]        delay]
```

#### 2.2 Button Input Through ulx3s_input

```
BUTTON INPUT PATH
=================

btn[6:0] -------------------------+
  [Active-LOW from PCB]           |
                                  v
                         +------------------+
                         | ulx3s_input.v    |
                         | i_btn_n[6:0]     |
                         +------------------+
                                  |
                         w_btn_raw = ~i_btn_n  (inversion)
                                  |
                         2-FF Synchronizer
                         (* ASYNC_REG = "TRUE" *)
                                  |
                         Debounce Counter
                         (10ms default)
                                  |
                                  v
                         r_btn_debounced[6:0]
                                  |
                         Joystick Mapping
                                  |
                                  v
                         o_joystick_emu[7:0]
```

#### 2.3 Architecture Assessment

**CURRENT DESIGN:**
1. Reset (btn[6]) goes DIRECTLY to clock_domain.v - bypasses debouncing
2. Other buttons (btn[5:0]) go through ulx3s_input.v for debouncing

**IS THIS PROPER SEPARATION?**

**YES, this is correct architecture.** Reasoning:

1. **Reset should be fast**: Reset needs immediate response, debouncing adds 10ms delay
2. **Reset has hardware protection**: PLL lock gating provides hysteresis
3. **Button actions need debouncing**: Game controls would double-fire without debounce
4. **Separate concerns**: Reset logic is safety-critical, game input is not

**BEST PRACTICE COMPLIANCE:**

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Async assert, sync deassert | YES | 3-FF synchronizer in clock_domain.v |
| PLL lock gating | YES | Reset held until `pll_locked` stable |
| Domain-specific resets | YES | Separate rst_pixel_n and rst_cpu_n |
| Button debouncing | YES | ulx3s_input.v handles game buttons |

**MINOR ISSUE:** btn[0] was previously used for both reset AND P1 Fire, causing "fire-on-reset" bug. This is now fixed - btn[6] (F2) is dedicated reset.

---

### 3. SYSTEMVERILOG/VHDL NECESSITY ANALYSIS

#### 3.1 File Language Inventory

| File | Extension | Language | SV Features Used |
|------|-----------|----------|------------------|
| `ecp5pll.sv` | .sv | SystemVerilog | functions, $error, for-in-function |
| `clk_25_shift_pixel_cpu.sv` | .sv | SystemVerilog | NONE (just instantiation) |
| All others | .v | Verilog-2001 | N/A |

#### 3.2 Conversion Analysis

**ecp5pll.sv - CANNOT CONVERT**

Required SystemVerilog features:
1. **Functions in localparam calculation** (lines 46-118):
   ```systemverilog
   function integer F_ecp5pll(input integer x);
       // Complex loop with multiple returns
   endfunction
   localparam params_refclk_div = F_ecp5pll(0);
   ```
2. **$error() compile-time assertions** (lines 186-189):
   ```systemverilog
   if(error_out0_hz) $error("out0_hz tolerance exceeds out0_tol_hz");
   ```

These features have no Verilog-2001 equivalent. The module must remain SystemVerilog.

**clk_25_shift_pixel_cpu.sv - CAN CONVERT**

This file contains only:
- Module declaration
- Parameter passing
- Instance of ecp5pll
- Wire assignments

No SystemVerilog-specific constructs. Can be renamed to `.v` without changes.

#### 3.3 VHDL Files in Project

| File | Location | Required? |
|------|----------|-----------|
| `tmds_encoder.vhd` | fpg1_partial_emard/src/emard/video/ | NO - Verilog version exists |
| `vga2dvid.vhd` | fpg1_partial_emard/src/emard/video/ | NO - Verilog version exists |

All VHDL can be removed - pure Verilog implementations exist.

#### 3.4 Conversion Plan

| Current File | Action | Effort |
|--------------|--------|--------|
| `ecp5pll.sv` | KEEP AS .sv | N/A |
| `clk_25_shift_pixel_cpu.sv` | RENAME to .v | Trivial |
| `*.vhd` files | DELETE | N/A |

**Result:** Project will have exactly ONE SystemVerilog file (ecp5pll.sv from Emard, which is vendor-provided IP).

---

### 4. COMPLETE FILE AUDIT

#### 4.1 src/ Directory Contents (41 files)

**REQUIRED - Core Modules:**
| File | Lines | Purpose | Status |
|------|-------|---------|--------|
| `top_pdp1.v` | 1127 | Top-level integration | KEEP |
| `ecp5pll.sv` | 270 | Emard PLL IP | KEEP (.sv required) |
| `clk_25_shift_pixel_cpu.sv` | 67 | PLL wrapper | RENAME to .v |
| `clock_domain.v` | 226 | Clock management, CDC | KEEP |
| `definitions.v` | 87 | Timing constants | KEEP |
| `ulx3s_input.v` | 214 | Button handling | KEEP |
| `pdp1_cpu.v` | ~920 | PDP-1 CPU core | KEEP |
| `pdp1_cpu_alu_div.v` | ~200 | Division ALU | KEEP |
| `pdp1_main_ram.v` | ~300 | 4K x 18-bit RAM | KEEP |
| `pdp1_vga_crt.v` | 806 | CRT phosphor display | KEEP |
| `pdp1_vga_rowbuffer.v` | ~50 | Row buffer BRAM | KEEP |
| `pixel_ring_buffer.v` | ~100 | Ring buffer | KEEP |
| `line_shift_register.v` | ~30 | Shift register | KEEP |
| `vga2dvid.v` | ~200 | VGA to TMDS | KEEP |
| `tmds_encoder.v` | ~100 | TMDS encoding | KEEP |
| `serial_debug.v` | ~300 | UART debug | KEEP |
| `test_animation.v` | ~200 | Orbital Spark test | KEEP |
| `test_sinus.v` | 268 | Sine test pattern | KEEP |

**REQUIRED - Constraints:**
| File | Purpose | Status |
|------|---------|--------|
| `ulx3s_v317_pdp1.lpf` | Pin constraints | KEEP |
| `ulx3s_v31_esp32.lpf` | ESP32 variant | OPTIONAL |

**OPTIONAL - ESP32 OSD:**
| File | Purpose | Status |
|------|---------|--------|
| `esp32_osd.v` | OSD top | KEEP if using ESP32 |
| `esp32_osd_buffer.v` | OSD buffer | KEEP if using ESP32 |
| `esp32_osd_renderer.v` | OSD render | KEEP if using ESP32 |
| `esp32_spi_slave.v` | SPI slave | KEEP if using ESP32 |

**OPTIONAL - Terminal (stub modules):**
| File | Purpose | Status |
|------|---------|--------|
| `pdp1_terminal_fb.v` | Terminal FB stub | KEEP (referenced) |
| `pdp1_terminal_charset.v` | Charset stub | KEEP (referenced) |
| `pdp1_vga_console.v` | Console output | OPTIONAL |
| `pdp1_vga_typewriter.v` | Typewriter | OPTIONAL |

**DELETE - Unused/Duplicate:**
| File | Reason |
|------|--------|
| `test_pattern_top.v` | Separate test project |
| `clean.sh` | Build script (use Makefile) |

**DELETE - MIF Files (Altera format, unused):**
| File | Reason |
|------|--------|
| `console_bg.mif` | MiSTer leftover |
| `spacewar.mif` | Using .hex instead |
| `fiodec_charset.mif` | MiSTer leftover |

#### 4.2 LPF File Analysis

| File | Location | Purpose | Duplicate? |
|------|----------|---------|------------|
| `ulx3s_v317_pdp1.lpf` | src/ | Main PDP-1 constraints | NO |
| `ulx3s_v31_esp32.lpf` | src/ | ESP32 variant | NO |
| `ulx3s_v20_segpdi.lpf` | fpg1_partial_emard/.../constraints/ | Emard original | DIFFERENT |

**VERDICT:** No duplicate LPFs. Keep all three for different configurations.

#### 4.3 ROM Files (src/rom/)

| File | Purpose | Status |
|------|---------|--------|
| `minskytron.hex` | Game ROM | KEEP |
| `minskytron_init.vh` | RAM initialization | KEEP |
| `spacewar.hex` | Alternative ROM | KEEP |
| `spacewar_init.vh` | RAM initialization | KEEP |
| `snowflake.hex` | Demo ROM | OPTIONAL |
| `display_test.hex` | Test ROM | OPTIONAL |
| `fiodec_charset.hex` | Charset data | KEEP |
| `console_bg.hex` | Console background | OPTIONAL |

---

### 5. MAKEFILE ANALYSIS

#### 5.1 Current Issues

1. **Multiple FPGA_SIZE definitions:** 85k default, 45k variant, no 12/25 options
2. **Hardcoded IDCODE:** Different for each FPGA size
3. **Complex structure:** 802 lines, many redundant targets
4. **Mixed concerns:** Test pattern, PDP-1, ESP32 all in one file

#### 5.2 Recommended Simplified Makefile

```makefile
# =============================================================================
# PDP-1 Spacewar! for ULX3S - Simplified Makefile
# =============================================================================
PROJECT      = pdp1
BOARD        = ulx3s

# FPGA Size: 12, 25, 45, or 85
FPGA_SIZE    = 85

# Derived values (DO NOT EDIT)
ifeq ($(FPGA_SIZE),12)
    FPGA_IDCODE = 0x21111043
    NEXTPNR_SIZE = 12k
else ifeq ($(FPGA_SIZE),25)
    FPGA_IDCODE = 0x41111043
    NEXTPNR_SIZE = 25k
else ifeq ($(FPGA_SIZE),45)
    FPGA_IDCODE = 0x41112043
    NEXTPNR_SIZE = 45k
else ifeq ($(FPGA_SIZE),85)
    FPGA_IDCODE = 0x41113043
    NEXTPNR_SIZE = 85k
endif

FPGA_PACKAGE = CABGA381
TOP_MODULE   = top_pdp1

# Directories
SRC_DIR      = src
BUILD_DIR    = build

# Source files
SV_FILES     = $(SRC_DIR)/ecp5pll.sv
V_FILES      = $(wildcard $(SRC_DIR)/*.v)
LPF_FILE     = $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# Output files
JSON         = $(BUILD_DIR)/$(PROJECT).json
CONFIG       = $(BUILD_DIR)/$(PROJECT).config
BIT          = $(BUILD_DIR)/$(PROJECT).bit

# Tools
YOSYS        = yosys
NEXTPNR      = nextpnr-ecp5
ECPPACK      = ecppack
PROG         = openFPGALoader

.PHONY: all synth pnr bit prog clean

all: bit

$(BUILD_DIR):
	mkdir -p $@

synth: $(JSON)
$(JSON): $(SV_FILES) $(V_FILES) | $(BUILD_DIR)
	$(YOSYS) -p "read_verilog -sv $(SV_FILES); \
	             read_verilog -I$(SRC_DIR) $(V_FILES); \
	             hierarchy -top $(TOP_MODULE); \
	             synth_ecp5 -json $@"

pnr: $(CONFIG)
$(CONFIG): $(JSON) $(LPF_FILE)
	$(NEXTPNR) --$(NEXTPNR_SIZE) --package $(FPGA_PACKAGE) \
	           --json $< --lpf $(LPF_FILE) --textcfg $@

bit: $(BIT)
$(BIT): $(CONFIG)
	$(ECPPACK) --idcode $(FPGA_IDCODE) --compress $< --bit $@

prog: $(BIT)
	$(PROG) -b $(BOARD) $<

prog_flash: $(BIT)
	$(PROG) -b $(BOARD) -f $<

clean:
	rm -rf $(BUILD_DIR)
```

**Benefits:**
- Single FPGA_SIZE variable controls everything
- 80 lines vs 800 lines
- Clear, maintainable structure
- Automatic IDCODE selection

---

### 6. BLUR ISSUE INVESTIGATION

#### 6.1 Emard's Warning Analysis

> "mozda se onaj blur pojavio nakon sto si proslijedio moje primjedbe da treba odvojit registarsku/memorijsku od kombinacijske logike pa su nakon ciscenja dobili mjesavinu novih i starih podataka"

Translation: The blur may have appeared after register/combinational separation caused old/new data mixing.

#### 6.2 Suspicious Code in pdp1_vga_crt.v

**ISSUE 1: r_p21 Feedback Loop (lines 681-688)**

```verilog
if (r_p22 < BRIGHTNESS) begin
    r_pixel_out <= ({8'b0, r_p11[7:1]} + r_p12 + r_p13 +
                    r_p21 + r_p22 + r_p23 +
                    r_p31 + r_p32 + r_p33[7:1]) >> 3;
    r_p21 <= r_pixel_out;  // <-- USES OLD r_pixel_out VALUE!
end
```

**Problem:** Non-blocking assignment means `r_pixel_out` won't have new value until NEXT clock cycle. But `r_p21` is being set to the OLD value of `r_pixel_out`.

**Question:** Is this intentional feedback for blur effect, or a bug?

**Analysis:** Looking at the comment "Feedback for smoother decay", this appears intentional. The blur kernel uses the previous frame's output to smooth transitions. However, this creates a 1-cycle delay in the feedback path that could cause visual artifacts.

**ISSUE 2: Blocking/Non-blocking Mix (line 701)**

```verilog
r_pixel_found = 1'b0;  // Blocking assignment

for (i = 8; i > 0; i = i - 1'b1) begin
    if (!r_pixel_found && ...) begin
        r_rowbuff_wraddr <= ...;  // Non-blocking
        r_pixel_found = 1'b1;     // Blocking
    end
end
```

**Assessment:** This is ACCEPTABLE. The blocking assignments are for loop control variables, not stored values. The actual register updates use non-blocking. This follows Cummings' guideline for procedural variables.

#### 6.3 Blur Pipeline Timing Diagram

```
BLUR KERNEL PIPELINE
====================

Cycle N:
  rowbuffer[addr] -> w_rowbuff_rdata

Cycle N+1:
  w_line3_out <- shift_reg(w_rowbuff_rdata)
  r_p33 <- w_line3_out
  r_p32 <- r_p33 (old)
  r_p31 <- r_p32 (old)

Cycle N+2:
  w_line2_out <- shift_reg(r_p31)
  r_p23 <- w_line2_out
  ...

Cycle N+3:
  w_line1_out <- shift_reg(r_p21)
  r_p13 <- w_line1_out
  ...

Cycle N+4:
  r_pixel_out <- blur_kernel(p11..p33)
  r_p21 <- r_pixel_out (FEEDBACK FROM CYCLE N+3!)

Total pipeline latency: 4-5 cycles
```

**RECOMMENDATION:** Add explicit pipeline stage comments and verify feedback is intentional.

---

### 7. MODULE-BY-MODULE BEST PRACTICE CHECK

#### 7.1 Checklist Results

| Module | English Comments | Reg/Comb Sep | Block/Non-block | CDC | Reset | BRAM | FSM |
|--------|-----------------|--------------|-----------------|-----|-------|------|-----|
| top_pdp1.v | YES | YES | YES | YES | YES | N/A | N/A |
| clock_domain.v | PARTIAL | YES | YES | YES | YES | N/A | N/A |
| ulx3s_input.v | YES | YES | YES | YES | YES | N/A | N/A |
| pdp1_vga_crt.v | YES | PARTIAL* | PARTIAL* | YES | PARTIAL | N/A | N/A |
| pdp1_cpu.v | PARTIAL | YES | YES | N/A | YES | N/A | YES |
| pdp1_main_ram.v | PARTIAL | YES | YES | N/A | N/A | YES | N/A |
| vga2dvid.v | PARTIAL | YES | YES | N/A | N/A | N/A | N/A |
| test_sinus.v | YES | YES | YES | N/A | YES | N/A | N/A |

*See blur issue analysis in Section 6.

#### 7.2 Detailed Findings

**pdp1_vga_crt.v:**
- Uses `output_pixel` task inside always block - acceptable but unusual
- Blocking loop control with non-blocking updates - acceptable per Cummings
- r_p21 feedback may cause artifacts - needs verification
- No explicit reset for some registers (r_pass_counter initialized to 1)

**clock_domain.v:**
- Comments mix English/Croatian
- Proper async reset, sync deassert pattern
- CDC synchronizers correctly attributed

**pdp1_cpu.v:**
- Some comments in Croatian
- FSM uses case statement (tools will choose encoding)
- No one-hot encoding directive - could improve timing

---

### 8. ACTION ITEMS - PRIORITIZED

#### PRIORITY 1 - CRITICAL (Must fix before release)

| ID | Task | Owner | Estimate | Status |
|----|------|-------|----------|--------|
| P1-1 | Fix test_sinus.v clock frequency comment (6.25 -> 1.82 MHz) | Kosjenka | 5 min | TODO |
| P1-2 | Verify r_p21 feedback is intentional, document reasoning | Jelena | 1 hour | TODO |
| P1-3 | Add reset for r_pass_counter in pdp1_vga_crt.v | Jelena | 15 min | TODO |

#### PRIORITY 2 - HIGH (Should fix soon)

| ID | Task | Owner | Estimate | Status |
|----|------|-------|----------|--------|
| P2-1 | Rename clk_25_shift_pixel_cpu.sv to .v | Manda | 5 min | TODO |
| P2-2 | Delete MIF files (console_bg.mif, spacewar.mif, fiodec_charset.mif) | Potjeh | 5 min | TODO |
| P2-3 | Create simplified Makefile (Section 5.2) | Jelena | 30 min | TODO |
| P2-4 | Translate remaining Croatian comments | Team | 2 hours | TODO |

#### PRIORITY 3 - MEDIUM (Improve quality)

| ID | Task | Owner | Estimate | Status |
|----|------|-------|----------|--------|
| P3-1 | Add pipeline timing diagram to pdp1_vga_crt.v header | Jelena | 30 min | TODO |
| P3-2 | Add one-hot FSM directive to pdp1_cpu.v | Kosjenka | 15 min | TODO |
| P3-3 | Document CDC paths in separate ARCHITECTURE.md | Kosjenka | 2 hours | TODO |
| P3-4 | Remove test_pattern_top.v and clean.sh | Potjeh | 5 min | TODO |

#### PRIORITY 4 - LOW (Nice to have)

| ID | Task | Owner | Estimate | Status |
|----|------|-------|----------|--------|
| P4-1 | Create testbench for blur kernel | Jelena | 4 hours | OPTIONAL |
| P4-2 | Consolidate LPF documentation | Potjeh | 1 hour | OPTIONAL |
| P4-3 | Remove ESP32 OSD if not using | Potjeh | 15 min | OPTIONAL |

---

### 9. DECISION RECORD

#### D1: SystemVerilog Usage
**Decision:** Keep ecp5pll.sv as SystemVerilog, convert clk_25_shift_pixel_cpu.sv to Verilog.
**Rationale:** ecp5pll.sv requires SV features; wrapper does not.
**Owner:** Manda

#### D2: Reset Architecture
**Decision:** Current BTN/RST separation is correct - no changes needed.
**Rationale:** Reset needs immediacy; game buttons need debouncing.
**Owner:** Kosjenka

#### D3: Blur Feedback
**Decision:** Document current behavior, verify with visual testing before modifying.
**Rationale:** May be intentional design for smooth phosphor decay effect.
**Owner:** Jelena

#### D4: Makefile Structure
**Decision:** Replace with simplified version supporting FPGA_SIZE variable.
**Rationale:** 80 lines vs 800 lines, single variable control.
**Owner:** Jelena

---

### 10. APPENDIX: FILE CLEANUP SCRIPT

```bash
#!/bin/bash
# PDP-1 Cleanup Script - Run from port_fpg1 directory
# Review before executing!

echo "=== PDP-1 File Cleanup ==="
echo "This will DELETE files. Review first!"
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Delete MIF files (Altera format, unused)
rm -v src/console_bg.mif
rm -v src/spacewar.mif
rm -v src/fiodec_charset.mif

# Delete unused scripts
rm -v src/clean.sh

# Rename SV to V (simple wrapper)
# git mv src/clk_25_shift_pixel_cpu.sv src/clk_25_shift_pixel_cpu.v

echo "=== Cleanup complete ==="
echo "Remember to update Makefile source list!"
```

---

### 11. MEETING NOTES - ADDITIONAL FINDINGS

#### 11.1 fake_differential.v Location

The module is located at:
```
/home/klaudio/port_fpg1/fpg1_partial_emard/src/emard/video/fake_differential.v
```

This is Emard's original, used by the Makefile via `$(EMARD_VIDEO)/fake_differential.v`.

**RECOMMENDATION:** Copy to src/ for simpler build structure, or document dependency clearly.

#### 11.2 Clock Frequency Summary Table

| Clock | Frequency | Purpose | Source |
|-------|-----------|---------|--------|
| clk_25mhz | 25 MHz | Crystal input | ULX3S board |
| clk_shift | 255 MHz | HDMI DDR | PLL out0 |
| clk_pixel | 51 MHz | VGA timing | PLL out1 |
| clk_cpu | 51 MHz | CPU base | PLL out1 (shared) |
| clk_cpu_en | 1.82 MHz | CPU effective | clock_domain.v prescaler /28 |

#### 11.3 Video Mode Specifications

```
1024x768 @ 50Hz
---------------
Pixel clock:  51 MHz
H total:      1264 pixels (1024 + 240 blanking)
V total:      808 lines (768 + 40 blanking)
Frame rate:   51,000,000 / (1264 * 808) = 49.93 Hz

Why 50Hz instead of 60Hz?
- 60Hz requires 65 MHz pixel = 325 MHz shift (marginal for ECP5)
- 50Hz uses 51 MHz pixel = 255 MHz shift (safely under 400 MHz)
```

---

*End of V2.1 Complete Review Plan*

---

*End of Document*
