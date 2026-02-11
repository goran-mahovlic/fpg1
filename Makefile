# =============================================================================
# Makefile for FPG1 port to ULX3S (ECP5)
# =============================================================================
# TASK-116: OSS CAD Suite Setup
# TASK-125: HDMI Test Pattern support
# Author: Jelena Horvat, REGOC team
# Date: 2026-01-31
#
# Uses OSS CAD Suite toolchain:
#   - yosys (synthesis) with ghdl plugin for VHDL
#   - nextpnr-ecp5 (place & route)
#   - ecppack (bitstream generation)
#   - openFPGALoader/fujprog (upload)
# =============================================================================

# ==== Project configuration ====
PROJECT      := fpg1
TOP_MODULE   := top
BOARD        := ulx3s

# ==== FPGA specifications (ULX3S 45F) ====
# LFE5U-45F-6BG381C
FPGA_DEVICE  := LFE5U-85F
FPGA_SIZE    := 85k
FPGA_PACKAGE := CABGA381
FPGA_SPEED   := 6
FPGA_IDCODE  := 0x41113043

# ==== Toolchain paths ====
# OSS CAD Suite location - adjust if installed differently
# Set OSS_CAD_SUITE environment variable or use default
OSS_CAD_SUITE ?= $(HOME)/Programs/oss-cad-suite

# Tools (assumes activated environment or full path)
YOSYS        := yosys
NEXTPNR      := nextpnr-ecp5
ECPPACK      := ecppack
PROGRAMMER   := openFPGALoader
FUJPROG      := fujprog
GHDL         := ghdl

# ==== Directories ====
SRC_DIR      := src
BUILD_DIR    := build
CONSTRAINTS_DIR := src
EMARD_SRC    := src
EMARD_VIDEO  := src

# ==== Source files ====
# SystemVerilog source (PLL modules from Kosjenko)
SV_FILES     := $(SRC_DIR)/ecp5pll.sv

# Verilog source (Emard port - add as needed)
V_FILES      := $(SRC_DIR)/clk_25_shift_pixel_cpu.v

# All source files
SOURCES      := $(SV_FILES) $(V_FILES)

# ==== Constraints ====
LPF_FILE     := $(CONSTRAINTS_DIR)/ulx3s_v317_pdp1.lpf

# ==== Output files ====
JSON_FILE    := $(BUILD_DIR)/$(PROJECT).json
CONFIG_FILE  := $(BUILD_DIR)/$(PROJECT).config
BIT_FILE     := $(BUILD_DIR)/$(PROJECT).bit
SVF_FILE     := $(BUILD_DIR)/$(PROJECT).svf

# ==== Yosys options ====
# -noccu2: disable CCU2 arithmetic cells
# -nomux: disable MUX cells
# -nodram: disable distributed RAM
# Remove options as needed for optimization
YOSYS_FLAGS  :=

# ==== nextpnr options ====
# --timing-allow-fail: continue despite timing errors (for debug)
# --seed: for reproducible results
# --threads: use multiple CPU threads for faster P&R
NEXTPNR_THREADS := $(shell nproc)
NEXTPNR_FLAGS := --timing-allow-fail --threads $(NEXTPNR_THREADS)

# ==== ecppack options ====
# --compress: compress bitstream
# --freq: SPI clock frequency for FLASH (MHz)
ECPPACK_FLAGS := --compress --freq 62.0

# =============================================================================
# DEBUG OPTIONS (uncomment to enable)
# =============================================================================
# ENABLE_UART_DEBUG: Enables serial debug output via FTDI UART (ftdi_rxd)
#                    Controlled by SW[1] at runtime when enabled
# ENABLE_LED_DEBUG:  Enables LED debug indicators showing CPU state
#                    Without this, LEDs are held at 0 (off)
# SERIAL_LOADER:     Enables serial loader for uploading programs via UART
#                    Uses ftdi_txd (RX) for receiving commands/data
#                    Protocol: 'L'=load, 'W'=write test_word, 'A'=write test_addr,
#                              'R'=run, 'S'=stop, 'P'=ping
# =============================================================================
# Uncomment lines below to enable debug features:
# DEFINES += -DENABLE_UART_DEBUG
# DEFINES += -DENABLE_LED_DEBUG
# DEFINES += -DSERIAL_LOADER
# =============================================================================

# =============================================================================
# PDP-1 CONFIGURATION (TASK-196)
# =============================================================================
PDP1_PROJECT     := pdp1
PDP1_TOP_MODULE  := top_pdp1
PDP1_JSON_FILE   := $(BUILD_DIR)/$(PDP1_PROJECT).json
PDP1_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_PROJECT).config
PDP1_BIT_FILE    := $(BUILD_DIR)/$(PDP1_PROJECT).bit
PDP1_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# PDP-1 SystemVerilog source files
PDP1_SV_FILES    := $(SRC_DIR)/ecp5pll.sv

# PDP-1 Verilog source files (BASIC - without ESP32 OSD, without ADC)
# TASK-213: Added pdp1_cpu.v and pdp1_main_ram.v
# NOTE: ADC removed - use oscilloscope target for ADC support
PDP1_V_FILES     := $(SRC_DIR)/clk_25_shift_pixel_cpu.v \
                    $(SRC_DIR)/top_pdp1.v \
                    $(SRC_DIR)/clock_domain.v \
                    $(SRC_DIR)/ulx3s_input.v \
                    $(SRC_DIR)/pdp1_vga_crt.v \
                    $(SRC_DIR)/pdp1_vga_rowbuffer.v \
                    $(SRC_DIR)/line_shift_register.v \
                    $(SRC_DIR)/pixel_ring_buffer.v \
                    $(SRC_DIR)/pdp1_cpu.v \
                    $(SRC_DIR)/pdp1_main_ram.v \
                    $(SRC_DIR)/pdp1_cpu_alu_div.v \
                    $(SRC_DIR)/pdp1_terminal_fb.v \
                    $(SRC_DIR)/pdp1_terminal_charset.v \
                    $(SRC_DIR)/test_animation.v \
                    $(SRC_DIR)/test_sinus.v \
                    $(SRC_DIR)/serial_debug.v \
                    $(SRC_DIR)/uart_rx.v \
                    $(SRC_DIR)/serial_loader.v \
                    $(SRC_DIR)/vga2dvid.v \
                    $(SRC_DIR)/tmds_encoder.v \
                    $(EMARD_VIDEO)/fake_differential.v

# =============================================================================
# OSCILLOSCOPE CONFIGURATION (with ADC MAX11123)
# =============================================================================
OSC_PROJECT      := oscilloscope
OSC_TOP_MODULE   := top_oscilloscope
OSC_JSON_FILE    := $(BUILD_DIR)/$(OSC_PROJECT).json
OSC_CONFIG_FILE  := $(BUILD_DIR)/$(OSC_PROJECT).config
OSC_BIT_FILE     := $(BUILD_DIR)/$(OSC_PROJECT).bit
OSC_LPF_FILE     := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# Oscilloscope Verilog source files (uses pdp1_cpu_osc.v and pdp1_main_ram_osc.v)
OSC_V_FILES      := $(SRC_DIR)/clk_25_shift_pixel_cpu.v \
                    $(SRC_DIR)/top_oscilloscope.v \
                    $(SRC_DIR)/clock_domain.v \
                    $(SRC_DIR)/ulx3s_input.v \
                    $(SRC_DIR)/pdp1_vga_crt.v \
                    $(SRC_DIR)/pdp1_vga_rowbuffer.v \
                    $(SRC_DIR)/line_shift_register.v \
                    $(SRC_DIR)/pixel_ring_buffer.v \
                    $(SRC_DIR)/pdp1_cpu_osc.v \
                    $(SRC_DIR)/pdp1_main_ram_osc.v \
                    $(SRC_DIR)/pdp1_cpu_alu_div.v \
                    $(SRC_DIR)/pdp1_terminal_fb.v \
                    $(SRC_DIR)/pdp1_terminal_charset.v \
                    $(SRC_DIR)/test_animation.v \
                    $(SRC_DIR)/test_sinus.v \
                    $(SRC_DIR)/serial_debug.v \
                    $(SRC_DIR)/adc_max11123.v \
                    $(SRC_DIR)/vga2dvid.v \
                    $(SRC_DIR)/tmds_encoder.v \
                    $(EMARD_VIDEO)/fake_differential.v

# =============================================================================
# PDP-1 TEST ANIMATION CONFIGURATION ("Orbital Spark")
# =============================================================================
PDP1_ANIM_PROJECT     := pdp1_anim
PDP1_ANIM_TOP_MODULE  := top_pdp1
PDP1_ANIM_JSON_FILE   := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).json
PDP1_ANIM_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).config
PDP1_ANIM_BIT_FILE    := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).bit
PDP1_ANIM_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# =============================================================================
# PDP-1 + ESP32 OSD CONFIGURATION
# =============================================================================
PDP1_ESP32_PROJECT     := pdp1_esp32
PDP1_ESP32_TOP_MODULE  := top_pdp1
PDP1_ESP32_JSON_FILE   := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).json
PDP1_ESP32_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).config
PDP1_ESP32_BIT_FILE    := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).bit
PDP1_ESP32_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# ESP32 OSD modules
ESP32_OSD_FILES  := $(SRC_DIR)/esp32_spi_slave.v \
                    $(SRC_DIR)/esp32_osd_buffer.v \
                    $(SRC_DIR)/esp32_osd_renderer.v \
                    $(SRC_DIR)/esp32_osd.v

# PDP-1 + ESP32 - all Verilog source files
PDP1_ESP32_V_FILES := $(PDP1_V_FILES) $(ESP32_OSD_FILES)

# =============================================================================
# TEST PATTERN CONFIGURATION (TASK-125)
# =============================================================================
TEST_PROJECT     := test_pattern
TEST_TOP_MODULE  := test_pattern_top
TEST_JSON_FILE   := $(BUILD_DIR)/$(TEST_PROJECT).json
TEST_CONFIG_FILE := $(BUILD_DIR)/$(TEST_PROJECT).config
TEST_BIT_FILE    := $(BUILD_DIR)/$(TEST_PROJECT).bit

# Test pattern source files (all Verilog - no VHDL dependencies)
TEST_SV_FILES    := $(SRC_DIR)/ecp5pll.sv
TEST_V_FILES     := $(SRC_DIR)/test_pattern_top.v \
                    $(SRC_DIR)/vga2dvid.v \
                    $(SRC_DIR)/tmds_encoder.v \
                    $(EMARD_VIDEO)/fake_differential.v

# Emard VHDL modules (for reference - not used in test pattern)
VHDL_FILES       := $(EMARD_VIDEO)/tmds_encoder.vhd \
                    $(EMARD_VIDEO)/vga2dvid.vhd

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: all synth pnr bit prog prog_flash clean info help
.PHONY: test test_synth test_pnr test_bit test_prog
.PHONY: pdp1 pdp1_synth pdp1_pnr pdp1_bit pdp1_prog pdp1_prog_flash
.PHONY: oscilloscope osc_synth osc_pnr osc_bit osc_prog osc_prog_flash

# Default target
all: bit

# ==== Creating build directory ====
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ==== SYNTHESIS (Yosys) ====
# Converts Verilog/SystemVerilog to JSON netlist
synth: $(JSON_FILE)

$(JSON_FILE): $(SOURCES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(PROJECT)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(SV_FILES); \
		$(if $(V_FILES),read_verilog $(V_FILES);) \
		hierarchy -top $(TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/synth.log
	@echo "Synthesis completed: $@"

# ==== PLACE & ROUTE (nextpnr-ecp5) ====
# Places logic on FPGA and routes signals
pnr: $(CONFIG_FILE)

$(CONFIG_FILE): $(JSON_FILE) $(LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(JSON_FILE) \
		--lpf $(LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/pnr.log
	@echo "Place & Route completed: $@"

# ==== BITSTREAM GENERATION (ecppack) ====
# Generates binary file for FPGA
bit: $(BIT_FILE)

$(BIT_FILE): $(CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# ==== SVF GENERATION (for JTAG debuggers) ====
svf: $(SVF_FILE)

$(SVF_FILE): $(CONFIG_FILE)
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--svf $@ \
		--svf-rowsize 8000 \
		--freq 62.0

# ==== PROGRAMMING ====

# Upload to SRAM (temporary - lost on power off)
prog: $(BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD TO FPGA (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# Upload to FLASH (permanent)
prog_flash: $(BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD TO FLASH (permanent)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# Alternative upload with fujprog
prog_fujprog: $(BIT_FILE)
	$(FUJPROG) $<

prog_fujprog_flash: $(BIT_FILE)
	$(FUJPROG) -j flash $<

# Detect connected FPGA
detect:
	$(PROGRAMMER) --detect

# =============================================================================
# PDP-1 TARGETS (TASK-196)
# =============================================================================
# Build flow for PDP-1 emulator with CRT display

# Complete PDP-1 build
pdp1: pdp1_bit
	@echo "========================================"
	@echo "PDP-1 Emulator build completed!"
	@echo "Bitstream: $(PDP1_BIT_FILE)"
	@echo "To upload: make pdp1_prog"
	@echo "========================================"

# PDP-1 synthesis
pdp1_synth: $(PDP1_JSON_FILE)

$(PDP1_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(PDP1_PROJECT)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_V_FILES)"
	@echo "Defines: $(DEFINES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog $(DEFINES) -I$(SRC_DIR) $(PDP1_V_FILES); \
		hierarchy -top $(PDP1_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_synth.log
	@echo "Synthesis completed: $@"

# PDP-1 place & route
pdp1_pnr: $(PDP1_CONFIG_FILE)

$(PDP1_CONFIG_FILE): $(PDP1_JSON_FILE) $(PDP1_LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(PDP1_PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(PDP1_JSON_FILE) \
		--lpf $(PDP1_LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/pdp1_pnr.log
	@echo "Place & Route completed: $@"

# PDP-1 bitstream
pdp1_bit: $(PDP1_BIT_FILE)

$(PDP1_BIT_FILE): $(PDP1_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(PDP1_PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# PDP-1 upload (SRAM)
pdp1_prog: $(PDP1_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# PDP-1 upload (FLASH)
pdp1_prog_flash: $(PDP1_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# =============================================================================
# OSCILLOSCOPE TARGETS (with ADC MAX11123)
# =============================================================================
# Build flow for PDP-1 oscilloscope with external ADC input

# Complete oscilloscope build
oscilloscope: osc_bit
	@echo "========================================"
	@echo "Oscilloscope build completed!"
	@echo "Bitstream: $(OSC_BIT_FILE)"
	@echo "To upload: make osc_prog"
	@echo "========================================"

# Oscilloscope synthesis
osc_synth: $(OSC_JSON_FILE)

$(OSC_JSON_FILE): $(PDP1_SV_FILES) $(OSC_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(OSC_PROJECT) (Oscilloscope with ADC)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(OSC_V_FILES)"
	@echo "Defines: $(DEFINES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog $(DEFINES) -I$(SRC_DIR) $(OSC_V_FILES); \
		hierarchy -top $(OSC_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/osc_synth.log
	@echo "Synthesis completed: $@"

# Oscilloscope place & route
osc_pnr: $(OSC_CONFIG_FILE)

$(OSC_CONFIG_FILE): $(OSC_JSON_FILE) $(OSC_LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(OSC_PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(OSC_JSON_FILE) \
		--lpf $(OSC_LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/osc_pnr.log
	@echo "Place & Route completed: $@"

# Oscilloscope bitstream
osc_bit: $(OSC_BIT_FILE)

$(OSC_BIT_FILE): $(OSC_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(OSC_PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# Oscilloscope upload (SRAM)
osc_prog: $(OSC_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD Oscilloscope (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# Oscilloscope upload (FLASH)
osc_prog_flash: $(OSC_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD Oscilloscope (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# =============================================================================
# PDP-1 FOR 45F CONFIGURATION (without ESP32)
# =============================================================================
PDP1_45F_PROJECT     := pdp1_45f
PDP1_45F_TOP_MODULE  := top_pdp1
PDP1_45F_JSON_FILE   := $(BUILD_DIR)/$(PDP1_45F_PROJECT).json
PDP1_45F_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_45F_PROJECT).config
PDP1_45F_BIT_FILE    := $(BUILD_DIR)/$(PDP1_45F_PROJECT).bit
PDP1_45F_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# 45F FPGA specifications
FPGA_SIZE_45F        := 45k
FPGA_IDCODE_45F      := 0x41112043

# =============================================================================
# PDP-1 + ESP32 OSD TARGETS
# =============================================================================
# Build flow for PDP-1 emulator with ESP32 OSD system

.PHONY: pdp1_anim pdp1_anim_synth pdp1_anim_pnr pdp1_anim_bit pdp1_anim_prog
.PHONY: pdp1_esp32 pdp1_esp32_synth pdp1_esp32_pnr pdp1_esp32_bit pdp1_esp32_prog

# =============================================================================
# PDP-1 TEST ANIMATION TARGETS ("Orbital Spark")
# =============================================================================
# Build flow for phosphor decay test animation
# Design: Git, Implementation: Jelena Horvat

# Complete PDP-1 test animation build
pdp1_anim: pdp1_anim_bit
	@echo "========================================"
	@echo "PDP-1 Test Animation build completed!"
	@echo "Bitstream: $(PDP1_ANIM_BIT_FILE)"
	@echo "To upload: make pdp1_anim_prog"
	@echo "========================================"

# PDP-1 test animation synthesis
pdp1_anim_synth: $(PDP1_ANIM_JSON_FILE)

$(PDP1_ANIM_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(PDP1_ANIM_PROJECT) (Orbital Spark)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_V_FILES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog -DTEST_ANIMATION -I$(SRC_DIR) $(PDP1_V_FILES); \
		hierarchy -top $(PDP1_ANIM_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_anim_synth.log
	@echo "Synthesis completed: $@"

# PDP-1 test animation place & route
pdp1_anim_pnr: $(PDP1_ANIM_CONFIG_FILE)

$(PDP1_ANIM_CONFIG_FILE): $(PDP1_ANIM_JSON_FILE) $(PDP1_ANIM_LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(PDP1_ANIM_PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(PDP1_ANIM_JSON_FILE) \
		--lpf $(PDP1_ANIM_LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/pdp1_anim_pnr.log
	@echo "Place & Route completed: $@"

# PDP-1 test animation bitstream
pdp1_anim_bit: $(PDP1_ANIM_BIT_FILE)

$(PDP1_ANIM_BIT_FILE): $(PDP1_ANIM_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(PDP1_ANIM_PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# PDP-1 test animation upload (SRAM)
pdp1_anim_prog: $(PDP1_ANIM_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 Test Animation (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# PDP-1 test animation upload (FLASH)
pdp1_anim_prog_flash: $(PDP1_ANIM_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 Test Animation (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# Complete PDP-1 + ESP32 build
pdp1_esp32: pdp1_esp32_bit
	@echo "========================================"
	@echo "PDP-1 + ESP32 OSD build completed!"
	@echo "Bitstream: $(PDP1_ESP32_BIT_FILE)"
	@echo "To upload: make pdp1_esp32_prog"
	@echo "========================================"

# PDP-1 + ESP32 synthesis
pdp1_esp32_synth: $(PDP1_ESP32_JSON_FILE)

$(PDP1_ESP32_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_ESP32_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(PDP1_ESP32_PROJECT) (with ESP32 OSD)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_ESP32_V_FILES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog -DESP32_OSD -I$(SRC_DIR) $(PDP1_ESP32_V_FILES); \
		hierarchy -top $(PDP1_ESP32_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_esp32_synth.log
	@echo "Synthesis completed: $@"

# PDP-1 + ESP32 place & route
pdp1_esp32_pnr: $(PDP1_ESP32_CONFIG_FILE)

$(PDP1_ESP32_CONFIG_FILE): $(PDP1_ESP32_JSON_FILE) $(PDP1_ESP32_LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(PDP1_ESP32_PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(PDP1_ESP32_JSON_FILE) \
		--lpf $(PDP1_ESP32_LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/pdp1_esp32_pnr.log
	@echo "Place & Route completed: $@"

# PDP-1 + ESP32 bitstream
pdp1_esp32_bit: $(PDP1_ESP32_BIT_FILE)

$(PDP1_ESP32_BIT_FILE): $(PDP1_ESP32_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(PDP1_ESP32_PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# PDP-1 + ESP32 upload (SRAM)
pdp1_esp32_prog: $(PDP1_ESP32_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 + ESP32 (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# PDP-1 + ESP32 upload (FLASH)
pdp1_esp32_prog_flash: $(PDP1_ESP32_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 + ESP32 (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# =============================================================================
# PDP-1 FOR 45F TARGETS (without ESP32)
# =============================================================================
# Build flow for PDP-1 emulator on smaller ECP5-45F chip

.PHONY: pdp1_45f pdp1_45f_synth pdp1_45f_pnr pdp1_45f_bit pdp1_45f_prog

# Complete PDP-1 45F build
pdp1_45f: pdp1_45f_bit
	@echo "========================================"
	@echo "PDP-1 for 45F build completed!"
	@echo "Bitstream: $(PDP1_45F_BIT_FILE)"
	@echo "To upload: make pdp1_45f_prog"
	@echo "========================================"

# PDP-1 45F synthesis
pdp1_45f_synth: $(PDP1_45F_JSON_FILE)

$(PDP1_45F_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(PDP1_45F_PROJECT) (for ECP5-45F)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_V_FILES)"
	@echo "Defines: $(DEFINES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog $(DEFINES) -I$(SRC_DIR) $(PDP1_V_FILES); \
		hierarchy -top $(PDP1_45F_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_45f_synth.log
	@echo "Synthesis completed: $@"

# PDP-1 45F place & route
pdp1_45f_pnr: $(PDP1_45F_CONFIG_FILE)

$(PDP1_45F_CONFIG_FILE): $(PDP1_45F_JSON_FILE) $(PDP1_45F_LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(PDP1_45F_PROJECT) (45F)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE_45F) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(PDP1_45F_JSON_FILE) \
		--lpf $(PDP1_45F_LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/pdp1_45f_pnr.log
	@echo "Place & Route completed: $@"

# PDP-1 45F bitstream
pdp1_45f_bit: $(PDP1_45F_BIT_FILE)

$(PDP1_45F_BIT_FILE): $(PDP1_45F_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(PDP1_45F_PROJECT) (45F)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE_45F) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# PDP-1 45F upload (SRAM)
pdp1_45f_prog: $(PDP1_45F_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 45F (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# PDP-1 45F upload (FLASH)
pdp1_45f_prog_flash: $(PDP1_45F_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD PDP-1 45F (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# =============================================================================
# TEST PATTERN TARGETS (TASK-125)
# =============================================================================
# Build flow for HDMI test pattern with VHDL modules

# Complete test pattern build
test: test_bit
	@echo "========================================"
	@echo "Test pattern build completed!"
	@echo "Bitstream: $(TEST_BIT_FILE)"
	@echo "To upload: make test_prog"
	@echo "========================================"

# Test pattern synthesis (with VHDL support)
test_synth: $(TEST_JSON_FILE)

$(TEST_JSON_FILE): $(TEST_SV_FILES) $(TEST_V_FILES) $(VHDL_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SYNTHESIS: $(TEST_PROJECT) (with VHDL)"
	@echo "========================================"
	@echo "VHDL files: $(VHDL_FILES)"
	@echo "Verilog files: $(TEST_V_FILES)"
	@echo "SystemVerilog files: $(TEST_SV_FILES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(TEST_SV_FILES); \
		read_verilog $(TEST_V_FILES); \
		hierarchy -top $(TEST_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/test_synth.log
	@echo "Synthesis completed: $@"

# Test pattern place & route
test_pnr: $(TEST_CONFIG_FILE)

$(TEST_CONFIG_FILE): $(TEST_JSON_FILE) $(LPF_FILE)
	@echo "========================================"
	@echo "PLACE & ROUTE: $(TEST_PROJECT)"
	@echo "========================================"
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--speed $(FPGA_SPEED) \
		--json $(TEST_JSON_FILE) \
		--lpf $(LPF_FILE) \
		--textcfg $@ \
		$(NEXTPNR_FLAGS) \
		2>&1 | tee $(BUILD_DIR)/test_pnr.log
	@echo "Place & Route completed: $@"

# Test pattern bitstream
test_bit: $(TEST_BIT_FILE)

$(TEST_BIT_FILE): $(TEST_CONFIG_FILE)
	@echo "========================================"
	@echo "BITSTREAM: $(TEST_PROJECT)"
	@echo "========================================"
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--bit $@ \
		$(ECPPACK_FLAGS)
	@echo "Bitstream generated: $@"
	@ls -lh $@

# Test pattern upload (SRAM)
test_prog: $(TEST_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD TEST PATTERN (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# Test pattern upload (FLASH)
test_prog_flash: $(TEST_BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD TEST PATTERN (FLASH)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# ==== HELPER COMMANDS ====

# Check toolchain (including GHDL)
check:
	@echo "Checking toolchain..."
	@which $(YOSYS) && $(YOSYS) --version || echo "ERROR: yosys not found"
	@which $(NEXTPNR) && $(NEXTPNR) --version || echo "ERROR: nextpnr-ecp5 not found"
	@which $(ECPPACK) && $(ECPPACK) --help | head -1 || echo "ERROR: ecppack not found"
	@which $(GHDL) && $(GHDL) --version | head -1 || echo "ERROR: ghdl not found"
	@echo "Checking GHDL yosys plugin..."
	@$(YOSYS) -m ghdl -p "ghdl --version" 2>/dev/null && echo "GHDL plugin OK" || echo "WARNING: ghdl yosys plugin issue"
	@which $(PROGRAMMER) && $(PROGRAMMER) --version || echo "WARNING: openFPGALoader not found"
	@echo "Verification completed."

# Project information
info:
	@echo "========================================"
	@echo "FPG1 ULX3S Build System"
	@echo "========================================"
	@echo "Project:      $(PROJECT)"
	@echo "Top module:   $(TOP_MODULE)"
	@echo "FPGA:         $(FPGA_DEVICE)"
	@echo "Package:      $(FPGA_PACKAGE)"
	@echo "Speed grade:  $(FPGA_SPEED)"
	@echo "IDCODE:       $(FPGA_IDCODE)"
	@echo "========================================"
	@echo "Source:"
	@for f in $(SOURCES); do echo "  $$f"; done
	@echo "Constraints:  $(LPF_FILE)"
	@echo "Output:       $(BIT_FILE)"
	@echo "========================================"
	@echo ""
	@echo "TEST PATTERN (TASK-125):"
	@echo "  Top module: $(TEST_TOP_MODULE)"
	@echo "  VHDL files: $(VHDL_FILES)"
	@echo "  V files:    $(TEST_V_FILES)"
	@echo "  Output:     $(TEST_BIT_FILE)"
	@echo "========================================"

# Cleaning build artifacts
clean:
	@echo "Deleting build directory..."
	rm -rf $(BUILD_DIR)
	@echo "Done."

# Deep clean - deletes all generated files
distclean: clean
	rm -f *.json *.config *.bit *.svf
	rm -f *.log

# Help
help:
	@echo "FPG1 ULX3S Makefile - available targets:"
	@echo ""
	@echo "  MAIN PROJECT:"
	@echo "  make all          - Run full build (synth + pnr + bit)"
	@echo "  make synth        - Synthesis only (yosys)"
	@echo "  make pnr          - Place & route only (nextpnr)"
	@echo "  make bit          - Generate bitstream (ecppack)"
	@echo "  make svf          - Generate SVF for JTAG"
	@echo ""
	@echo "  TEST PATTERN (TASK-125):"
	@echo "  make test         - Complete test pattern build"
	@echo "  make test_synth   - Test pattern synthesis (with VHDL)"
	@echo "  make test_pnr     - Test pattern place & route"
	@echo "  make test_bit     - Test pattern bitstream"
	@echo "  make test_prog    - Upload test pattern (SRAM)"
	@echo ""
	@echo "  PROGRAMMING:"
	@echo "  make prog         - Upload to FPGA (SRAM, temporary)"
	@echo "  make prog_flash   - Upload to FLASH (permanent)"
	@echo "  make detect       - Detect connected FPGA"
	@echo ""
	@echo "  UTILITY:"
	@echo "  make check        - Check toolchain installation"
	@echo "  make info         - Show project information"
	@echo "  make clean        - Delete build artifacts"
	@echo "  make help         - Show this help"
	@echo ""
	@echo "Example for test pattern:"
	@echo "  source $(OSS_CAD_SUITE)/environment"
	@echo "  make clean test test_prog"

# =============================================================================
# ADVANCED OPTIONS
# =============================================================================

# For debugging timing issues
timing: $(CONFIG_FILE)
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--json $(JSON_FILE) \
		--lpf $(LPF_FILE) \
		--textcfg /dev/null \
		--report $(BUILD_DIR)/timing.json

# Generate PLL configuration with ecppll (if needed)
pll:
	ecppll \
		--input 25 \
		--output 375 \
		--s1 75 \
		--s2 50 \
		--file $(SRC_DIR)/generated_pll.v
	@echo "PLL configuration generated in $(SRC_DIR)/generated_pll.v"
	@echo "NOTE: We use Emard's ecp5pll.sv which automatically calculates parameters"

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Ensure that LPF exists
$(LPF_FILE):
	@echo "ERROR: Constraints file does not exist: $(LPF_FILE)"
	@echo "Check path or copy appropriate .lpf file."
	@exit 1
