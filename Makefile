# =============================================================================
# Makefile za FPG1 port na ULX3S (ECP5)
# =============================================================================
# TASK-116: OSS CAD Suite Setup
# TASK-125: HDMI Test Pattern support
# Autor: Jelena Horvat, REGOC tim
# Datum: 2026-01-31
#
# Koristi OSS CAD Suite toolchain:
#   - yosys (sinteza) s ghdl plugin za VHDL
#   - nextpnr-ecp5 (place & route)
#   - ecppack (bitstream generacija)
#   - openFPGALoader/fujprog (upload)
# =============================================================================

# ==== Projekt konfiguracija ====
PROJECT      := fpg1
TOP_MODULE   := top
BOARD        := ulx3s

# ==== FPGA specifikacije (ULX3S 45F) ====
# LFE5U-45F-6BG381C
FPGA_DEVICE  := LFE5U-45F
FPGA_SIZE    := 45k
FPGA_PACKAGE := CABGA381
FPGA_SPEED   := 6
FPGA_IDCODE  := 0x41112043

# ==== Toolchain putanje ====
# OSS CAD Suite lokacija - prilagoditi ako je drugacije instalirano
OSS_CAD_SUITE := /home/klaudio/Programs/oss-cad-suite

# Alati (pretpostavlja aktivirani environment ili punu putanju)
YOSYS        := yosys
NEXTPNR      := nextpnr-ecp5
ECPPACK      := ecppack
PROGRAMMER   := openFPGALoader
FUJPROG      := fujprog
GHDL         := ghdl

# ==== Direktoriji ====
SRC_DIR      := src
BUILD_DIR    := build
CONSTRAINTS_DIR := fpg1_partial_emard/src/proj/lattice/ulx3s/constraints
EMARD_SRC    := fpg1_partial_emard/src
EMARD_VIDEO  := fpg1_partial_emard/src/emard/video

# ==== Source datoteke ====
# SystemVerilog source (PLL moduli od Kosjenke)
SV_FILES     := $(SRC_DIR)/ecp5pll.sv \
                $(SRC_DIR)/clk_25_shift_pixel_cpu.sv

# Verilog source (Emard port - dodati po potrebi)
V_FILES      :=

# Sve source datoteke
SOURCES      := $(SV_FILES) $(V_FILES)

# ==== Constraints ====
LPF_FILE     := $(CONSTRAINTS_DIR)/ulx3s_v20_segpdi.lpf

# ==== Output datoteke ====
JSON_FILE    := $(BUILD_DIR)/$(PROJECT).json
CONFIG_FILE  := $(BUILD_DIR)/$(PROJECT).config
BIT_FILE     := $(BUILD_DIR)/$(PROJECT).bit
SVF_FILE     := $(BUILD_DIR)/$(PROJECT).svf

# ==== Yosys opcije ====
# -noccu2: iskljuci CCU2 aritmeticke celije
# -nomux: iskljuci MUX celije
# -nodram: iskljuci distribuiranu RAM
# Ukloniti opcije po potrebi za optimizaciju
YOSYS_FLAGS  :=

# ==== nextpnr opcije ====
# --timing-allow-fail: nastavi unatoc timing greškama (za debug)
# --seed: za ponovljivost rezultata
NEXTPNR_FLAGS := --timing-allow-fail

# ==== ecppack opcije ====
# --compress: komprimiraj bitstream
# --freq: SPI clock frekvencija za FLASH (MHz)
ECPPACK_FLAGS := --compress --freq 62.0

# =============================================================================
# PDP-1 KONFIGURACIJA (TASK-196)
# =============================================================================
PDP1_PROJECT     := pdp1
PDP1_TOP_MODULE  := top_pdp1
PDP1_JSON_FILE   := $(BUILD_DIR)/$(PDP1_PROJECT).json
PDP1_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_PROJECT).config
PDP1_BIT_FILE    := $(BUILD_DIR)/$(PDP1_PROJECT).bit
PDP1_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# PDP-1 SystemVerilog source files
PDP1_SV_FILES    := $(SRC_DIR)/ecp5pll.sv \
                    $(SRC_DIR)/clk_25_shift_pixel_cpu.sv

# PDP-1 Verilog source files (BASIC - bez ESP32 OSD)
PDP1_V_FILES     := $(SRC_DIR)/top_pdp1.v \
                    $(SRC_DIR)/clock_domain.v \
                    $(SRC_DIR)/ulx3s_input.v \
                    $(SRC_DIR)/pdp1_vga_crt.v \
                    $(SRC_DIR)/pdp1_vga_rowbuffer.v \
                    $(SRC_DIR)/line_shift_register.v \
                    $(SRC_DIR)/pixel_ring_buffer.v \
                    $(SRC_DIR)/pdp1_cpu_alu_div.v \
                    $(SRC_DIR)/pdp1_terminal_fb.v \
                    $(SRC_DIR)/pdp1_terminal_charset.v \
                    $(SRC_DIR)/test_animation.v \
                    $(SRC_DIR)/serial_debug.v \
                    $(SRC_DIR)/vga2dvid.v \
                    $(SRC_DIR)/tmds_encoder.v \
                    $(EMARD_VIDEO)/fake_differential.v

# =============================================================================
# PDP-1 TEST ANIMATION KONFIGURACIJA ("Orbital Spark")
# =============================================================================
PDP1_ANIM_PROJECT     := pdp1_anim
PDP1_ANIM_TOP_MODULE  := top_pdp1
PDP1_ANIM_JSON_FILE   := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).json
PDP1_ANIM_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).config
PDP1_ANIM_BIT_FILE    := $(BUILD_DIR)/$(PDP1_ANIM_PROJECT).bit
PDP1_ANIM_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# =============================================================================
# PDP-1 + ESP32 OSD KONFIGURACIJA
# =============================================================================
PDP1_ESP32_PROJECT     := pdp1_esp32
PDP1_ESP32_TOP_MODULE  := top_pdp1
PDP1_ESP32_JSON_FILE   := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).json
PDP1_ESP32_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).config
PDP1_ESP32_BIT_FILE    := $(BUILD_DIR)/$(PDP1_ESP32_PROJECT).bit
PDP1_ESP32_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# ESP32 OSD moduli
ESP32_OSD_FILES  := $(SRC_DIR)/esp32_spi_slave.v \
                    $(SRC_DIR)/esp32_osd_buffer.v \
                    $(SRC_DIR)/esp32_osd_renderer.v \
                    $(SRC_DIR)/esp32_osd.v

# PDP-1 + ESP32 - svi Verilog source files
PDP1_ESP32_V_FILES := $(PDP1_V_FILES) $(ESP32_OSD_FILES)

# =============================================================================
# TEST PATTERN KONFIGURACIJA (TASK-125)
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

# Emard VHDL moduli (za reference - ne koriste se u test patternu)
VHDL_FILES       := $(EMARD_VIDEO)/tmds_encoder.vhd \
                    $(EMARD_VIDEO)/vga2dvid.vhd

# =============================================================================
# TARGETS
# =============================================================================

.PHONY: all synth pnr bit prog prog_flash clean info help
.PHONY: test test_synth test_pnr test_bit test_prog
.PHONY: pdp1 pdp1_synth pdp1_pnr pdp1_bit pdp1_prog pdp1_prog_flash

# Default target
all: bit

# ==== Kreiranje build direktorija ====
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ==== SINTEZA (Yosys) ====
# Konvertira Verilog/SystemVerilog u JSON netlist
synth: $(JSON_FILE)

$(JSON_FILE): $(SOURCES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(PROJECT)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(SV_FILES); \
		$(if $(V_FILES),read_verilog $(V_FILES);) \
		hierarchy -top $(TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/synth.log
	@echo "Sinteza zavrsena: $@"

# ==== PLACE & ROUTE (nextpnr-ecp5) ====
# Smjesta logiku na FPGA i ruta signale
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
	@echo "Place & Route zavrseno: $@"

# ==== BITSTREAM GENERACIJA (ecppack) ====
# Generira binarnu datoteku za FPGA
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
	@echo "Bitstream generiran: $@"
	@ls -lh $@

# ==== SVF GENERACIJA (za JTAG debuggere) ====
svf: $(SVF_FILE)

$(SVF_FILE): $(CONFIG_FILE)
	$(ECPPACK) \
		--idcode $(FPGA_IDCODE) \
		--input $< \
		--svf $@ \
		--svf-rowsize 8000 \
		--freq 62.0

# ==== PROGRAMIRANJE ====

# Upload na SRAM (privremeno - gubi se pri power off)
prog: $(BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD NA FPGA (SRAM)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) $<

# Upload na FLASH (trajno)
prog_flash: $(BIT_FILE)
	@echo "========================================"
	@echo "UPLOAD NA FLASH (trajno)"
	@echo "========================================"
	$(PROGRAMMER) -b $(BOARD) -f $<

# Alternativni upload s fujprog
prog_fujprog: $(BIT_FILE)
	$(FUJPROG) $<

prog_fujprog_flash: $(BIT_FILE)
	$(FUJPROG) -j flash $<

# Detekcija spojenog FPGA
detect:
	$(PROGRAMMER) --detect

# =============================================================================
# PDP-1 TARGETS (TASK-196)
# =============================================================================
# Build flow za PDP-1 emulator s CRT displayem

# Kompletni PDP-1 build
pdp1: pdp1_bit
	@echo "========================================"
	@echo "PDP-1 Emulator build zavrsen!"
	@echo "Bitstream: $(PDP1_BIT_FILE)"
	@echo "Za upload: make pdp1_prog"
	@echo "========================================"

# PDP-1 sinteza
pdp1_synth: $(PDP1_JSON_FILE)

$(PDP1_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(PDP1_PROJECT)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_V_FILES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog -I$(SRC_DIR) $(PDP1_V_FILES); \
		hierarchy -top $(PDP1_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_synth.log
	@echo "Sinteza zavrsena: $@"

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
	@echo "Place & Route zavrseno: $@"

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
	@echo "Bitstream generiran: $@"
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
# PDP-1 ZA 45F KONFIGURACIJA (bez ESP32)
# =============================================================================
PDP1_45F_PROJECT     := pdp1_45f
PDP1_45F_TOP_MODULE  := top_pdp1
PDP1_45F_JSON_FILE   := $(BUILD_DIR)/$(PDP1_45F_PROJECT).json
PDP1_45F_CONFIG_FILE := $(BUILD_DIR)/$(PDP1_45F_PROJECT).config
PDP1_45F_BIT_FILE    := $(BUILD_DIR)/$(PDP1_45F_PROJECT).bit
PDP1_45F_LPF_FILE    := $(SRC_DIR)/ulx3s_v317_pdp1.lpf

# 45F FPGA specifikacije
FPGA_SIZE_45F        := 45k
FPGA_IDCODE_45F      := 0x41112043

# =============================================================================
# PDP-1 + ESP32 OSD TARGETS
# =============================================================================
# Build flow za PDP-1 emulator s ESP32 OSD sustavom

.PHONY: pdp1_anim pdp1_anim_synth pdp1_anim_pnr pdp1_anim_bit pdp1_anim_prog
.PHONY: pdp1_esp32 pdp1_esp32_synth pdp1_esp32_pnr pdp1_esp32_bit pdp1_esp32_prog

# =============================================================================
# PDP-1 TEST ANIMATION TARGETS ("Orbital Spark")
# =============================================================================
# Build flow za phosphor decay test animaciju
# Dizajn: Git, Implementacija: Jelena Horvat

# Kompletni PDP-1 test animation build
pdp1_anim: pdp1_anim_bit
	@echo "========================================"
	@echo "PDP-1 Test Animation build zavrsen!"
	@echo "Bitstream: $(PDP1_ANIM_BIT_FILE)"
	@echo "Za upload: make pdp1_anim_prog"
	@echo "========================================"

# PDP-1 test animation sinteza
pdp1_anim_synth: $(PDP1_ANIM_JSON_FILE)

$(PDP1_ANIM_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(PDP1_ANIM_PROJECT) (Orbital Spark)"
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
	@echo "Sinteza zavrsena: $@"

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
	@echo "Place & Route zavrseno: $@"

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
	@echo "Bitstream generiran: $@"
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

# Kompletni PDP-1 + ESP32 build
pdp1_esp32: pdp1_esp32_bit
	@echo "========================================"
	@echo "PDP-1 + ESP32 OSD build zavrsen!"
	@echo "Bitstream: $(PDP1_ESP32_BIT_FILE)"
	@echo "Za upload: make pdp1_esp32_prog"
	@echo "========================================"

# PDP-1 + ESP32 sinteza
pdp1_esp32_synth: $(PDP1_ESP32_JSON_FILE)

$(PDP1_ESP32_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_ESP32_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(PDP1_ESP32_PROJECT) (s ESP32 OSD)"
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
	@echo "Sinteza zavrsena: $@"

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
	@echo "Place & Route zavrseno: $@"

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
	@echo "Bitstream generiran: $@"
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
# PDP-1 ZA 45F TARGETS (bez ESP32)
# =============================================================================
# Build flow za PDP-1 emulator na manjem ECP5-45F čipu

.PHONY: pdp1_45f pdp1_45f_synth pdp1_45f_pnr pdp1_45f_bit pdp1_45f_prog

# Kompletni PDP-1 45F build
pdp1_45f: pdp1_45f_bit
	@echo "========================================"
	@echo "PDP-1 za 45F build zavrsen!"
	@echo "Bitstream: $(PDP1_45F_BIT_FILE)"
	@echo "Za upload: make pdp1_45f_prog"
	@echo "========================================"

# PDP-1 45F sinteza
pdp1_45f_synth: $(PDP1_45F_JSON_FILE)

$(PDP1_45F_JSON_FILE): $(PDP1_SV_FILES) $(PDP1_V_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(PDP1_45F_PROJECT) (za ECP5-45F)"
	@echo "========================================"
	@echo "SystemVerilog: $(PDP1_SV_FILES)"
	@echo "Verilog: $(PDP1_V_FILES)"
	@echo "========================================"
	$(YOSYS) -p "\
		read_verilog -sv $(PDP1_SV_FILES); \
		read_verilog -I$(SRC_DIR) $(PDP1_V_FILES); \
		hierarchy -top $(PDP1_45F_TOP_MODULE); \
		synth_ecp5 $(YOSYS_FLAGS) -json $@" \
		2>&1 | tee $(BUILD_DIR)/pdp1_45f_synth.log
	@echo "Sinteza zavrsena: $@"

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
	@echo "Place & Route zavrseno: $@"

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
	@echo "Bitstream generiran: $@"
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
# Build flow za HDMI test pattern s VHDL modulima

# Kompletni test pattern build
test: test_bit
	@echo "========================================"
	@echo "Test pattern build zavrsen!"
	@echo "Bitstream: $(TEST_BIT_FILE)"
	@echo "Za upload: make test_prog"
	@echo "========================================"

# Test pattern sinteza (s VHDL podrskom)
test_synth: $(TEST_JSON_FILE)

$(TEST_JSON_FILE): $(TEST_SV_FILES) $(TEST_V_FILES) $(VHDL_FILES) | $(BUILD_DIR)
	@echo "========================================"
	@echo "SINTEZA: $(TEST_PROJECT) (s VHDL)"
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
	@echo "Sinteza zavrsena: $@"

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
	@echo "Place & Route zavrseno: $@"

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
	@echo "Bitstream generiran: $@"
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

# ==== POMOCNE NAREDBE ====

# Provjera toolchaina (ukljucujuci GHDL)
check:
	@echo "Provjera toolchaina..."
	@which $(YOSYS) && $(YOSYS) --version || echo "GRESKA: yosys nije pronaden"
	@which $(NEXTPNR) && $(NEXTPNR) --version || echo "GRESKA: nextpnr-ecp5 nije pronaden"
	@which $(ECPPACK) && $(ECPPACK) --help | head -1 || echo "GRESKA: ecppack nije pronaden"
	@which $(GHDL) && $(GHDL) --version | head -1 || echo "GRESKA: ghdl nije pronaden"
	@echo "Provjera GHDL yosys plugin..."
	@$(YOSYS) -m ghdl -p "ghdl --version" 2>/dev/null && echo "GHDL plugin OK" || echo "UPOZORENJE: ghdl yosys plugin problem"
	@which $(PROGRAMMER) && $(PROGRAMMER) --version || echo "UPOZORENJE: openFPGALoader nije pronaden"
	@echo "Provjera zavrsena."

# Informacije o projektu
info:
	@echo "========================================"
	@echo "FPG1 ULX3S Build System"
	@echo "========================================"
	@echo "Projekt:      $(PROJECT)"
	@echo "Top modul:    $(TOP_MODULE)"
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
	@echo "  Top modul:  $(TEST_TOP_MODULE)"
	@echo "  VHDL files: $(VHDL_FILES)"
	@echo "  V files:    $(TEST_V_FILES)"
	@echo "  Output:     $(TEST_BIT_FILE)"
	@echo "========================================"

# Ciscenje build artefakata
clean:
	@echo "Brisanje build direktorija..."
	rm -rf $(BUILD_DIR)
	@echo "Gotovo."

# Deep clean - brise sve generirane datoteke
distclean: clean
	rm -f *.json *.config *.bit *.svf
	rm -f *.log

# Help
help:
	@echo "FPG1 ULX3S Makefile - dostupni targeti:"
	@echo ""
	@echo "  GLAVNI PROJEKT:"
	@echo "  make all          - Pokreni cijeli build (synth + pnr + bit)"
	@echo "  make synth        - Samo sinteza (yosys)"
	@echo "  make pnr          - Samo place & route (nextpnr)"
	@echo "  make bit          - Generiraj bitstream (ecppack)"
	@echo "  make svf          - Generiraj SVF za JTAG"
	@echo ""
	@echo "  TEST PATTERN (TASK-125):"
	@echo "  make test         - Kompletni build test patterna"
	@echo "  make test_synth   - Sinteza test patterna (s VHDL)"
	@echo "  make test_pnr     - Place & route test patterna"
	@echo "  make test_bit     - Bitstream test patterna"
	@echo "  make test_prog    - Upload test pattern (SRAM)"
	@echo ""
	@echo "  PROGRAMIRANJE:"
	@echo "  make prog         - Upload na FPGA (SRAM, privremeno)"
	@echo "  make prog_flash   - Upload na FLASH (trajno)"
	@echo "  make detect       - Detektiraj spojeni FPGA"
	@echo ""
	@echo "  POMOCNO:"
	@echo "  make check        - Provjeri toolchain instalaciju"
	@echo "  make info         - Prikazi informacije o projektu"
	@echo "  make clean        - Obrisi build artefakte"
	@echo "  make help         - Prikazi ovu pomoc"
	@echo ""
	@echo "Primjer za test pattern:"
	@echo "  source $(OSS_CAD_SUITE)/environment"
	@echo "  make clean test test_prog"

# =============================================================================
# NAPREDNE OPCIJE
# =============================================================================

# Za debugiranje timing problema
timing: $(CONFIG_FILE)
	$(NEXTPNR) \
		--$(FPGA_SIZE) \
		--package $(FPGA_PACKAGE) \
		--json $(JSON_FILE) \
		--lpf $(LPF_FILE) \
		--textcfg /dev/null \
		--report $(BUILD_DIR)/timing.json

# Generiranje PLL konfiguracije s ecppll (ako treba)
pll:
	ecppll \
		--input 25 \
		--output 375 \
		--s1 75 \
		--s2 50 \
		--file $(SRC_DIR)/generated_pll.v
	@echo "PLL konfiguracija generirana u $(SRC_DIR)/generated_pll.v"
	@echo "NAPOMENA: Koristimo Emardov ecp5pll.sv koji automatski racuna parametre"

# =============================================================================
# OVISNOSTI
# =============================================================================

# Osiguraj da LPF postoji
$(LPF_FILE):
	@echo "GRESKA: Constraints file ne postoji: $(LPF_FILE)"
	@echo "Provjerite putanju ili kopirajte odgovarajuci .lpf file."
	@exit 1
