# ============================================
# FPG1 - PDP-1 Emulator for ULX3S
# ============================================
# Author: Jelena Kovacevic, REGOC team
# Simplified Makefile - only PDP-1 target
# ============================================

# Project settings
PROJECT = pdp1
BOARD = ulx3s
FPGA_SIZE = 85
FPGA_PACKAGE = CABGA381

# Directories
SRC_DIR = src
BUILD_DIR = build

# Top module
TOP_MODULE = top_pdp1

# Constraint file
LPF_FILE = $(SRC_DIR)/ulx3s_v317.lpf

# Source files - SystemVerilog
SV_FILES = \
    $(SRC_DIR)/ecp5pll.sv

# Source files - Verilog
V_FILES = \
    $(SRC_DIR)/top_pdp1.v \
    $(SRC_DIR)/clk_25_shift_pixel_cpu.v \
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
    $(SRC_DIR)/vga2dvid.v \
    $(SRC_DIR)/tmds_encoder.v \
    $(SRC_DIR)/fake_differential.v

# All source files
VERILOG_FILES = $(SV_FILES) $(V_FILES)

# Output files
JSON_FILE = $(BUILD_DIR)/$(PROJECT).json
CONFIG_FILE = $(BUILD_DIR)/$(PROJECT).config
BIT_FILE = $(BUILD_DIR)/$(PROJECT).bit

# Tool options
YOSYS_FLAGS =
NEXTPNR_FLAGS = --timing-allow-fail --threads $(shell nproc)
ECPPACK_FLAGS = --compress

# ============================================
# TARGETS
# ============================================

.PHONY: all clean prog prog_flash info help

all: $(BIT_FILE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Synthesis (Yosys)
$(JSON_FILE): $(VERILOG_FILES) | $(BUILD_DIR)
	yosys -p "read_verilog -sv $(SV_FILES); read_verilog -I$(SRC_DIR) $(V_FILES); synth_ecp5 -top $(TOP_MODULE) -json $@"

# Place & Route (nextpnr-ecp5)
$(CONFIG_FILE): $(JSON_FILE) $(LPF_FILE)
	nextpnr-ecp5 --$(FPGA_SIZE)k --package $(FPGA_PACKAGE) \
		--lpf $(LPF_FILE) --json $(JSON_FILE) --textcfg $@ $(NEXTPNR_FLAGS)

# Bitstream (ecppack)
$(BIT_FILE): $(CONFIG_FILE)
	ecppack $(ECPPACK_FLAGS) $< --bit $@

# Programming with openFPGALoader
prog: $(BIT_FILE)
	openFPGALoader -b $(BOARD) $<

prog_flash: $(BIT_FILE)
	openFPGALoader -b $(BOARD) -f $<

# Utilities
clean:
	rm -rf $(BUILD_DIR)

info:
	@echo "Project:     $(PROJECT)"
	@echo "Top module:  $(TOP_MODULE)"
	@echo "FPGA:        ECP5-$(FPGA_SIZE)k $(FPGA_PACKAGE)"
	@echo "LPF:         $(LPF_FILE)"
	@echo "Output:      $(BIT_FILE)"

help:
	@echo "FPG1 PDP-1 Makefile"
	@echo ""
	@echo "  make           - Build bitstream"
	@echo "  make prog      - Upload to SRAM (temporary)"
	@echo "  make prog_flash - Upload to FLASH (permanent)"
	@echo "  make clean     - Remove build artifacts"
	@echo "  make info      - Show project info"
