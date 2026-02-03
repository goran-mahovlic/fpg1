//==============================================================================
// Module:      top_pdp1
// Description: Top-level module for PDP-1 Spacewar! emulator on ULX3S
//==============================================================================
// Author:      Kosjenka Vukovic, FPGA Architect, REGOC team
// Reviewer:    Jelena Horvat (best practices), REGOC team
// Created:     2026-01-31
// Modified:    2026-02-02 (HDL Guidelines compliance)
//
// Hardware Target: ULX3S v3.1.7 (Lattice ECP5-85F)
//   - 25 MHz onboard oscillator
//   - HDMI output via GPDI differential pairs
//   - 7 pushbuttons (active-low) + 4 DIP switches
//   - 8 LED indicators
//
// Clock Domains:
//   - clk_shift  : 125 MHz  - HDMI DDR serializer (5x pixel clock)
//   - clk_pixel  :  51 MHz  - VGA timing (1024x768@50Hz)
//   - clk_cpu    : 6.25 MHz - PDP-1 CPU emulation
//
// Reset Strategy:
//   - Asynchronous assert, synchronous deassert per clock domain
//   - rst_pixel_n: Synchronized to clk_pixel domain
//   - rst_cpu_n:   Synchronized to clk_cpu domain
//   - Reset source: btn[0] active-low, gated by pll_locked
//
// CDC Crossings:
//   1. CPU -> Pixel: Pixel coordinates (23 bits) via HOLD registers + sync
//   2. Pixel -> CPU: VBlank signal via 2FF synchronizer
//   3. External -> CPU: DIP switches via 2FF synchronizer
//   4. External -> Pixel: Buttons via ulx3s_input debouncer
//
// Module Integration:
//   - clk_25_shift_pixel_cpu.sv : PLL (25MHz -> 125/51/6.25 MHz)
//   - clock_domain.v           : Prescaler, CDC, Reset Sequencing
//   - pdp1_vga_crt.v           : CRT phosphor decay emulation
//   - ulx3s_input.v            : Button debounce, joystick mapping
//   - pdp1_cpu.v               : PDP-1 CPU core
//   - pdp1_main_ram.v          : 4K x 18-bit main memory
//   - vga2dvid.v               : VGA to DVI/HDMI conversion
//   - fake_differential.v      : ECP5 DDR output primitives
//
// Test Mode:
//   - Define TEST_ANIMATION for "Orbital Spark" phosphor decay test
//   - Animated point traces elliptical orbit with phosphor trail
//
//==============================================================================

// Uncomment to enable test animation mode
// `define TEST_ANIMATION

`include "definitions.v"

module top_pdp1
(
    // =========================================================================
    // PORT NAMING CONVENTION (HDL Guidelines 01_NAMING_CONVENTIONS):
    //   i_  = Input port
    //   o_  = Output port
    //   _n  = Active-low signal
    //
    // NOTE: Port names kept as hardware pinout names for PCF compatibility.
    // Internal signals follow naming conventions with prefixes.
    // =========================================================================

    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    input  wire [3:0]  sw,             // SW[3:0] active-high

    // ==== LED Indicators ====
    output wire [7:0]  led,            // LED[7:0] active-high

    // ==== HDMI Output (GPDI differential pairs) ====
    output wire [3:0]  gpdi_dp,        // TMDS positive (active)
    output wire [3:0]  gpdi_dn,        // TMDS negative (active)

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0,     // HIGH prevents ESP32 reboot

    // ==== FTDI UART (Debug Serial Output) ====
    output wire        ftdi_rxd,       // FPGA TX -> PC RX (active-high)

    // ==== GPDI Control Pins (HDMI Hot Plug Detect) ====
    output wire        gpdi_scl,       // I2C SCL - drive HIGH for DDC wake-up
    input  wire        gpdi_hpd        // HDMI HPD from monitor (active-high)

`ifdef ESP32_OSD
    // ==== ESP32 SPI Interface (OSD overlay) ====
    ,
    input  wire        esp32_spi_clk,  // SPI clock from ESP32
    input  wire        esp32_spi_mosi, // SPI data from ESP32
    output wire        esp32_spi_miso, // SPI data to ESP32
    input  wire        esp32_spi_cs_n, // SPI chip select (active-low)
    output wire        esp32_osd_irq,  // Interrupt to ESP32
    input  wire        esp32_ready     // ESP32 ready signal
`endif
);

    // =========================================================================
    // PARAMETERS (HDL Guidelines: UPPER_CASE for constants)
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)

    // Local parameters (computed, do not override)
    localparam C_PIXEL_CLK_FREQ = 51_000_000;  // 51 MHz pixel clock
    localparam C_CPU_CLK_FREQ   = 6_250_000;   // 6.25 MHz CPU clock

    // =========================================================================
    // ACTIVE-LOW -> ACTIVE-HIGH BUTTON CONVERSION
    // =========================================================================
    // Note: btn[0] is special (BTN_PWR), used for ESP32 keep-alive.
    // wifi_gpio0=HIGH prevents ESP32 reboot when button pressed.
    assign wifi_gpio0 = btn[0];

    // -------------------------------------------------------------------------
    // Internal signal naming convention (HDL Guidelines 01_NAMING_CONVENTIONS):
    //   r_  = Register (clocked, sequential logic)
    //   w_  = Wire (combinational logic)
    //   clk_ = Clock signal
    //   rst_ = Reset signal
    //   _n   = Active-low signal suffix
    // -------------------------------------------------------------------------

    // =========================================================================
    // HDMI HPD (Hot Plug Detect) - ACTIVE-HIGH
    // =========================================================================
    // HPD is INPUT - monitor drives HIGH when connected and ready.
    // gpdi_scl driven HIGH constantly for DDC wake-up (I2C pull-up emulation).
    assign gpdi_scl = 1'b1;

    // Monitor connection status (active-high)
    wire w_monitor_connected = gpdi_hpd;

    // =========================================================================
    // CLOCK GENERATION (PLL) - 1024x768@50Hz Video Mode
    // =========================================================================
    // Clock tree:
    //   clk_25mhz (input) -> PLL -> clk_shift (125 MHz, HDMI serializer)
    //                           -> clk_pixel (51 MHz, VGA timing)
    //                           -> clk_cpu (6.25 MHz, PDP-1 emulation)
    // -------------------------------------------------------------------------
    wire clk_shift;     // 125 MHz HDMI shift clock (5x pixel for DDR)
    wire clk_pixel;     // 51 MHz pixel clock (1024x768@50Hz timing)
    wire clk_cpu;       // 6.25 MHz CPU base clock
    wire w_pll_locked;  // PLL lock indicator (active-high)

    clk_25_shift_pixel_cpu u_pll
    (
        .clki   (clk_25mhz),
        .clko   (clk_shift),
        .clks1  (clk_pixel),
        .clks2  (clk_cpu),
        .locked (w_pll_locked)
    );

    // =========================================================================
    // CLOCK DOMAIN MANAGEMENT & RESET SEQUENCING
    // =========================================================================
    // Reset strategy: Asynchronous assert, synchronous deassert.
    // Each clock domain has its own synchronized reset signal.
    // Reset source: btn[0] (active-low) AND pll_locked
    // -------------------------------------------------------------------------
    wire w_clk_cpu_slow;    // 1.79 MHz PDP-1 clock (unused, legacy interface)
    wire w_clk_cpu_en;      // Clock enable pulse
    wire rst_pixel_n;       // Synchronized reset for pixel domain (active-low)
    wire rst_cpu_n;         // Synchronized reset for CPU domain (active-low)

    // CDC framebuffer signals (placeholders for future CPU integration)
    wire [11:0] w_cpu_fb_addr = 12'b0;
    wire [11:0] w_cpu_fb_data = 12'b0;
    wire        w_cpu_fb_we   = 1'b0;
    wire [11:0] w_vid_fb_addr;
    wire [11:0] w_vid_fb_data;
    wire        w_vid_fb_we;
    wire        w_vid_vblank;
    wire        w_cpu_vblank;

    clock_domain u_clock_domain
    (
        .clk_pixel      (clk_pixel),
        .clk_cpu_fast   (clk_cpu),
        .pll_locked     (w_pll_locked),
        .rst_n          (btn[0]),           // BTN[0] active-low = reset

        .clk_cpu        (w_clk_cpu_slow),
        .clk_cpu_en     (w_clk_cpu_en),
        .rst_pixel_n    (rst_pixel_n),
        .rst_cpu_n      (rst_cpu_n),

        // CDC interface (for future framebuffer CPU integration)
        .cpu_fb_addr    (w_cpu_fb_addr),
        .cpu_fb_data    (w_cpu_fb_data),
        .cpu_fb_we      (w_cpu_fb_we),
        .vid_fb_addr    (w_vid_fb_addr),
        .vid_fb_data    (w_vid_fb_data),
        .vid_fb_we      (w_vid_fb_we),
        .vid_vblank     (w_vid_vblank),
        .cpu_vblank     (w_cpu_vblank)
    );

    // =========================================================================
    // INPUT HANDLING (ULX3S BUTTONS & SWITCHES)
    // =========================================================================
    // Input synchronization and debouncing handled by ulx3s_input module.
    // Buttons are active-low from hardware, active-high internally.
    // -------------------------------------------------------------------------
    wire [7:0] w_joystick_emu;
    wire [7:0] w_led_input_feedback;
    wire       w_p2_mode_active;
    wire       w_single_player;

    ulx3s_input #(
        .CLK_FREQ    (C_PIXEL_CLK_FREQ),  // 51 MHz pixel clock
        .DEBOUNCE_MS (10)
    ) u_input (
        .i_clk            (clk_pixel),
        .i_rst_n          (rst_pixel_n),
        .i_btn_n          (btn),              // Active-low from board
        .i_sw             (sw),
        .o_joystick_emu   (w_joystick_emu),
        .o_led_feedback   (w_led_input_feedback),
        .o_p2_mode_active (w_p2_mode_active),
        .o_single_player  (w_single_player)
    );

    // =========================================================================
    // VIDEO TIMING GENERATION (clk_pixel domain)
    // =========================================================================
    // Horizontal and vertical counters for VGA timing.
    // Uses non-blocking assignments for sequential logic (HDL Guidelines).
    // -------------------------------------------------------------------------
    reg [10:0] r_h_counter;
    reg [10:0] r_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_h_counter <= 11'b0;
            r_v_counter <= 11'b0;
        end else begin
            r_h_counter <= r_h_counter + 1'b1;

            if (r_h_counter >= `h_line_timing - 1) begin
                r_h_counter <= 11'b0;
                r_v_counter <= r_v_counter + 1'b1;

                if (r_v_counter >= `v_line_timing - 1) begin
                    r_v_counter <= 11'b0;
                end
            end
        end
    end

    // VBlank signal for CPU synchronization (active during vertical blanking)
    assign w_vid_vblank = (r_v_counter < `v_visible_offset);

    // =========================================================================
    // CRT PHOSPHOR DISPLAY EMULATION (clk_pixel domain)
    // =========================================================================
    wire [7:0] w_crt_r, w_crt_g, w_crt_b;

    // CRT debug signals (active in clk_pixel domain)
    wire [5:0]  w_crt_debug_write_ptr;
    wire [5:0]  w_crt_debug_read_ptr;
    wire        w_crt_debug_wren;
    wire [10:0] w_crt_debug_search_counter;
    wire [11:0] w_crt_debug_luma1;
    wire        w_crt_debug_rowbuff_wren;
    wire        w_crt_debug_inside_visible;
    wire        w_crt_debug_pixel_to_rowbuff;
    wire [15:0] w_crt_debug_rowbuff_write_count;
    wire [9:0]  w_crt_debug_ring_buffer_wrptr;

`ifdef TEST_ANIMATION
    // =========================================================================
    // TEST ANIMATION MODE: "Orbital Spark" (clk_pixel domain only)
    // =========================================================================
    // Point traces elliptical orbit, phosphor decay creates trailing effect.
    // No CDC required - entire animation runs in clk_pixel domain.
    // -------------------------------------------------------------------------

    // Frame tick generator - single-cycle pulse at start of each frame
    reg        r_frame_tick;
    reg [10:0] r_prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_frame_tick      <= 1'b0;
            r_prev_v_counter  <= 11'd0;
        end else begin
            r_prev_v_counter <= r_v_counter;
            // Detect start of new frame (transition into vblank)
            r_frame_tick <= (r_v_counter == 11'd0) && (r_prev_v_counter != 11'd0);
        end
    end

    // Test animation outputs (all in clk_pixel domain)
    wire [9:0] w_anim_pixel_x;
    wire [9:0] w_anim_pixel_y;
    wire [2:0] w_anim_brightness;
    wire       w_anim_pixel_valid;
    wire [7:0] w_anim_debug_angle;

    test_animation u_test_anim (
        .clk              (clk_pixel),
        .rst_n            (rst_pixel_n),
        .frame_tick       (r_frame_tick),
        .pixel_x          (w_anim_pixel_x),
        .pixel_y          (w_anim_pixel_y),
        .pixel_brightness (w_anim_brightness),
        .pixel_valid      (w_anim_pixel_valid),
        .debug_angle      (w_anim_debug_angle)
    );

    // Map animation outputs to generic pixel signals
    wire [9:0] w_test_pixel_x     = w_anim_pixel_x;
    wire [9:0] w_test_pixel_y     = w_anim_pixel_y;
    wire [2:0] w_test_brightness  = w_anim_brightness;
    wire       w_test_pixel_avail = w_anim_pixel_valid;

`else
    // =========================================================================
    // PDP-1 CPU INTEGRATION (clk_cpu domain)
    // =========================================================================
    // Full CPU with RAM and Spacewar! program execution.
    // -------------------------------------------------------------------------

    // CPU <-> Memory interface signals (clk_cpu domain)
    wire [11:0] w_cpu_mem_addr;
    wire [17:0] w_cpu_mem_data_out;
    wire [17:0] w_cpu_mem_data_in;
    wire        w_cpu_mem_we;

    // CPU output signals (clk_cpu domain)
    wire [17:0] w_cpu_ac;           // Accumulator
    wire [17:0] w_cpu_io;           // IO register
    wire [11:0] w_cpu_pc;           // Program counter
    wire [31:0] w_cpu_bus_out;      // Console blinkenlights

    // CPU debug outputs (clk_cpu domain)
    wire [15:0] w_cpu_debug_instr_count;  // Total instructions executed
    wire [15:0] w_cpu_debug_iot_count;    // IOT instructions executed
    wire        w_cpu_debug_running;       // CPU is running

    // Pixel debug outputs (clk_cpu domain)
    wire [31:0] w_cpu_debug_pixel_count;      // Total pixels sent
    wire [9:0]  w_cpu_debug_pixel_x;          // Last pixel X coordinate
    wire [9:0]  w_cpu_debug_pixel_y;          // Last pixel Y coordinate
    wire [2:0]  w_cpu_debug_pixel_brightness; // Last pixel brightness

    // CRT output signals from CPU (clk_cpu domain - requires CDC!)
    wire [9:0]  w_cpu_pixel_x;
    wire [9:0]  w_cpu_pixel_y;
    wire [2:0]  w_cpu_pixel_brightness;
    wire        w_cpu_pixel_shift;

    // Typewriter signals (active-high, active when character available)
    wire [6:0]  w_typewriter_char_out;
    wire        w_typewriter_strobe_out;
    wire        w_typewriter_strobe_ack;

    // Paper tape signals
    wire        w_send_next_tape_char;

    // -------------------------------------------------------------------------
    // Gamepad input mapping for Spacewar! (active-high signals)
    // -------------------------------------------------------------------------
    // PDP-1 gamepad format: bits 17-14 and 3-0 are used
    // Player 1: bits 17-14 (CW, CCW, thrust, fire)
    // Player 2: bits 3-0 (CW, CCW, thrust, fire)
    //
    // w_joystick_emu[7:0] from ulx3s_input module:
    //   [0]=P1 fire, [1]=P1 CCW(left), [2]=P1 thrust, [3]=P1 CW(right)
    //   [4]=P2 fire, [5]=P2 CCW(left), [6]=P2 thrust, [7]=P2 CW(right)
    // -------------------------------------------------------------------------
    wire [17:0] w_gamepad_in;
    assign w_gamepad_in = {
        w_joystick_emu[3],   // bit 17 - P1 CW (rotate right)
        w_joystick_emu[1],   // bit 16 - P1 CCW (rotate left)
        w_joystick_emu[2],   // bit 15 - P1 thrust
        w_joystick_emu[0],   // bit 14 - P1 fire
        10'b0,               // bits 13-4 unused
        w_joystick_emu[7],   // bit 3 - P2 CW (rotate right)
        w_joystick_emu[5],   // bit 2 - P2 CCW (rotate left)
        w_joystick_emu[6],   // bit 1 - P2 thrust
        w_joystick_emu[4]    // bit 0 - P2 fire
    };

    // -------------------------------------------------------------------------
    // Console switches for CPU control (clk_cpu domain)
    // -------------------------------------------------------------------------
    // Start button generates extended pulse on reset release to auto-start
    // execution. Extended to 200+ cycles to ensure CPU captures the signal.
    // -------------------------------------------------------------------------
    reg [7:0] r_start_pulse_counter;
    wire w_start_button_pulse;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_start_pulse_counter <= 8'd200;  // 200 cycles at startup
        end else if (r_start_pulse_counter > 0) begin
            r_start_pulse_counter <= r_start_pulse_counter - 1'b1;
        end
    end

    // Generate start pulse while counter > 0 (full 200 cycle duration)
    assign w_start_button_pulse = (r_start_pulse_counter > 0);

    wire [10:0] w_console_switches;
    assign w_console_switches = {
        1'b0,                  // bit 10 - power switch (0=on)
        1'b0,                  // bit 9 - single step
        1'b0,                  // bit 8 - single inst
        1'b0,                  // bit 7 - tape feed
        1'b0,                  // bit 6 - reader
        1'b0,                  // bit 5 - read in
        1'b0,                  // bit 4 - deposit
        1'b0,                  // bit 3 - examine
        1'b0,                  // bit 2 - continue
        1'b0,                  // bit 1 - stop
        w_start_button_pulse   // bit 0 - start (pulse on reset release)
    };

    // Test word and address switches (active-high)
    wire [17:0] w_test_word    = 18'b0;
    wire [17:0] w_test_address = 18'o4;    // Start address: octal 4 (Spacewar 4.1 entry point)

    // =========================================================================
    // CDC: DIP SWITCH SYNCHRONIZATION (External -> clk_cpu domain)
    // =========================================================================
    // PROBLEM: sw[3:0] and btn[5:4] are external inputs (asynchronous to clk_cpu)
    // SOLUTION: 2-stage synchronizer with ASYNC_REG attribute for proper
    //           metastability handling (HDL Guidelines 07_CDC_GUIDELINES).
    //
    // CDC Path: External pins -> 2FF sync -> sense_switches
    // ASYNC_REG ensures synthesis places FFs close together for best MTBF.
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_sync_meta, r_sw_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_btn_sync_meta, r_btn_sync;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sw_sync_meta  <= 4'b0;
            r_sw_sync       <= 4'b0;
            r_btn_sync_meta <= 2'b0;
            r_btn_sync      <= 2'b0;
        end else begin
            // 2-stage synchronizer for sw[3:0]
            r_sw_sync_meta <= sw;
            r_sw_sync      <= r_sw_sync_meta;
            // 2-stage synchronizer for btn[5:4] (inverted: active-low -> active-high)
            r_btn_sync_meta <= ~btn[5:4];
            r_btn_sync      <= r_btn_sync_meta;
        end
    end

    // -------------------------------------------------------------------------
    // Sense switches mapping (active-high, clk_cpu domain):
    //   [5:4] = r_btn_sync (BTN[5:4] for additional options)
    //   [3]   = r_sw_sync[3] (SW[3])
    //   [2]   = r_sw_sync[2] (SW[2])
    //   [1]   = 1'b1 (HARDCODED - starfield ALWAYS ON for explosions visibility)
    //   [0]   = r_sw_sync[0] (SW[0])
    //
    // NOTE: SW[1] controls ONLY serial debug (via w_single_player signal),
    //       NOT starfield. This separation fixes the explosion visibility bug.
    // -------------------------------------------------------------------------
    wire [5:0] w_sense_switches = {r_btn_sync, r_sw_sync[3:0]};

    // =========================================================================
    // PDP-1 MAIN RAM (4096 x 18-bit, clk_cpu domain)
    // =========================================================================
    pdp1_main_ram u_main_ram (
        // Port A - CPU interface (clk_cpu domain)
        .address_a  (w_cpu_mem_addr),
        .clock_a    (clk_cpu),
        .data_a     (w_cpu_mem_data_out),
        .wren_a     (w_cpu_mem_we),
        .q_a        (w_cpu_mem_data_in),

        // Port B - unused (explicitly tied off)
        .address_b  (12'b0),
        .clock_b    (clk_cpu),
        .data_b     (18'b0),
        .wren_b     (1'b0),
        .q_b        ()              // Unconnected output (intentional)
    );

    // =========================================================================
    // PDP-1 CPU (clk_cpu domain)
    // =========================================================================
    pdp1_cpu u_cpu (
        .clk                    (clk_cpu),
        .rst                    (~rst_cpu_n),       // CPU uses active-high reset

        // Memory interface (clk_cpu domain)
        .MEM_ADDR               (w_cpu_mem_addr),
        .DI                     (w_cpu_mem_data_in),
        .MEM_BUFF               (w_cpu_mem_data_out),
        .WRITE_ENABLE           (w_cpu_mem_we),

        // Register outputs for debug
        .AC                     (w_cpu_ac),
        .IO                     (w_cpu_io),
        .PC                     (w_cpu_pc),
        .BUS_out                (w_cpu_bus_out),

        // Gamepad input (active-high)
        .gamepad_in             (w_gamepad_in),

        // CRT output (clk_cpu domain - requires CDC to clk_pixel!)
        .pixel_x_out            (w_cpu_pixel_x),
        .pixel_y_out            (w_cpu_pixel_y),
        .pixel_brightness       (w_cpu_pixel_brightness),
        .pixel_shift_out        (w_cpu_pixel_shift),

        // Typewriter interface (active-high)
        .typewriter_char_out    (w_typewriter_char_out),
        .typewriter_strobe_out  (w_typewriter_strobe_out),
        .typewriter_char_in     (6'b0),             // Not connected
        .typewriter_strobe_in   (1'b0),             // Not connected
        .typewriter_strobe_ack  (w_typewriter_strobe_ack),

        // Paper tape interface (not connected)
        .send_next_tape_char    (w_send_next_tape_char),
        .is_char_available      (1'b0),
        .tape_rcv_word          (18'b0),

        // Start address
        .start_address          (12'o4),            // Spacewar 4.1 entry point

        // Configuration
        .hw_mul_enabled         (1'b1),             // Enable hardware multiply/divide
        .crt_wait               (1'b1),             // Enable CRT wait for timing

        // Console switches (clk_cpu domain, synchronized)
        .console_switches       (w_console_switches),
        .test_word              (w_test_word),
        .test_address           (w_test_address),
        .sense_switches         (w_sense_switches),

        // Debug outputs
        .debug_instr_count      (w_cpu_debug_instr_count),
        .debug_iot_count        (w_cpu_debug_iot_count),
        .debug_cpu_running      (w_cpu_debug_running),

        // Pixel debug outputs
        .debug_pixel_count      (w_cpu_debug_pixel_count),
        .debug_pixel_x          (w_cpu_debug_pixel_x),
        .debug_pixel_y          (w_cpu_debug_pixel_y),
        .debug_pixel_brightness (w_cpu_debug_pixel_brightness)
    );

    // =========================================================================
    // SINE TEST PATTERN GENERATOR (SW[2] = 1 activates test mode)
    // =========================================================================
    // When SW[2]=1, replace CPU pixel coordinates with sine wave pattern.
    // Uses CPU DPY timing (pixel_shift) to maintain proper pipeline flow.
    // Sine wave sweeps horizontally with vertical displacement from sine LUT.
    //
    // Author: Jelena Horvat, REGOC team
    // Date: 2026-02-02
    // =========================================================================

    // Test mode flag from synchronized DIP switch (clk_cpu domain)
    wire w_sine_test_mode = r_sw_sync[2];

    // Sine LUT: 256 entries, values 0-255 (128 = zero crossing)
    // Same format as test_animation.v for consistency
    reg [7:0] r_sine_lut [0:255];

    // Initialize sine lookup table
    initial begin
        // Quadrant 0: 0-63 (0 to pi/2)
        r_sine_lut[  0] = 8'd128; r_sine_lut[  1] = 8'd131; r_sine_lut[  2] = 8'd134; r_sine_lut[  3] = 8'd137;
        r_sine_lut[  4] = 8'd140; r_sine_lut[  5] = 8'd143; r_sine_lut[  6] = 8'd146; r_sine_lut[  7] = 8'd149;
        r_sine_lut[  8] = 8'd152; r_sine_lut[  9] = 8'd156; r_sine_lut[ 10] = 8'd159; r_sine_lut[ 11] = 8'd162;
        r_sine_lut[ 12] = 8'd165; r_sine_lut[ 13] = 8'd168; r_sine_lut[ 14] = 8'd171; r_sine_lut[ 15] = 8'd174;
        r_sine_lut[ 16] = 8'd177; r_sine_lut[ 17] = 8'd179; r_sine_lut[ 18] = 8'd182; r_sine_lut[ 19] = 8'd185;
        r_sine_lut[ 20] = 8'd188; r_sine_lut[ 21] = 8'd191; r_sine_lut[ 22] = 8'd193; r_sine_lut[ 23] = 8'd196;
        r_sine_lut[ 24] = 8'd199; r_sine_lut[ 25] = 8'd201; r_sine_lut[ 26] = 8'd204; r_sine_lut[ 27] = 8'd206;
        r_sine_lut[ 28] = 8'd209; r_sine_lut[ 29] = 8'd211; r_sine_lut[ 30] = 8'd213; r_sine_lut[ 31] = 8'd216;
        r_sine_lut[ 32] = 8'd218; r_sine_lut[ 33] = 8'd220; r_sine_lut[ 34] = 8'd222; r_sine_lut[ 35] = 8'd224;
        r_sine_lut[ 36] = 8'd226; r_sine_lut[ 37] = 8'd228; r_sine_lut[ 38] = 8'd230; r_sine_lut[ 39] = 8'd232;
        r_sine_lut[ 40] = 8'd234; r_sine_lut[ 41] = 8'd235; r_sine_lut[ 42] = 8'd237; r_sine_lut[ 43] = 8'd238;
        r_sine_lut[ 44] = 8'd240; r_sine_lut[ 45] = 8'd241; r_sine_lut[ 46] = 8'd243; r_sine_lut[ 47] = 8'd244;
        r_sine_lut[ 48] = 8'd245; r_sine_lut[ 49] = 8'd246; r_sine_lut[ 50] = 8'd247; r_sine_lut[ 51] = 8'd248;
        r_sine_lut[ 52] = 8'd249; r_sine_lut[ 53] = 8'd250; r_sine_lut[ 54] = 8'd251; r_sine_lut[ 55] = 8'd252;
        r_sine_lut[ 56] = 8'd252; r_sine_lut[ 57] = 8'd253; r_sine_lut[ 58] = 8'd253; r_sine_lut[ 59] = 8'd254;
        r_sine_lut[ 60] = 8'd254; r_sine_lut[ 61] = 8'd254; r_sine_lut[ 62] = 8'd255; r_sine_lut[ 63] = 8'd255;
        // Quadrant 1: 64-127 (pi/2 to pi)
        r_sine_lut[ 64] = 8'd255; r_sine_lut[ 65] = 8'd255; r_sine_lut[ 66] = 8'd255; r_sine_lut[ 67] = 8'd254;
        r_sine_lut[ 68] = 8'd254; r_sine_lut[ 69] = 8'd254; r_sine_lut[ 70] = 8'd253; r_sine_lut[ 71] = 8'd253;
        r_sine_lut[ 72] = 8'd252; r_sine_lut[ 73] = 8'd252; r_sine_lut[ 74] = 8'd251; r_sine_lut[ 75] = 8'd250;
        r_sine_lut[ 76] = 8'd249; r_sine_lut[ 77] = 8'd248; r_sine_lut[ 78] = 8'd247; r_sine_lut[ 79] = 8'd246;
        r_sine_lut[ 80] = 8'd245; r_sine_lut[ 81] = 8'd244; r_sine_lut[ 82] = 8'd243; r_sine_lut[ 83] = 8'd241;
        r_sine_lut[ 84] = 8'd240; r_sine_lut[ 85] = 8'd238; r_sine_lut[ 86] = 8'd237; r_sine_lut[ 87] = 8'd235;
        r_sine_lut[ 88] = 8'd234; r_sine_lut[ 89] = 8'd232; r_sine_lut[ 90] = 8'd230; r_sine_lut[ 91] = 8'd228;
        r_sine_lut[ 92] = 8'd226; r_sine_lut[ 93] = 8'd224; r_sine_lut[ 94] = 8'd222; r_sine_lut[ 95] = 8'd220;
        r_sine_lut[ 96] = 8'd218; r_sine_lut[ 97] = 8'd216; r_sine_lut[ 98] = 8'd213; r_sine_lut[ 99] = 8'd211;
        r_sine_lut[100] = 8'd209; r_sine_lut[101] = 8'd206; r_sine_lut[102] = 8'd204; r_sine_lut[103] = 8'd201;
        r_sine_lut[104] = 8'd199; r_sine_lut[105] = 8'd196; r_sine_lut[106] = 8'd193; r_sine_lut[107] = 8'd191;
        r_sine_lut[108] = 8'd188; r_sine_lut[109] = 8'd185; r_sine_lut[110] = 8'd182; r_sine_lut[111] = 8'd179;
        r_sine_lut[112] = 8'd177; r_sine_lut[113] = 8'd174; r_sine_lut[114] = 8'd171; r_sine_lut[115] = 8'd168;
        r_sine_lut[116] = 8'd165; r_sine_lut[117] = 8'd162; r_sine_lut[118] = 8'd159; r_sine_lut[119] = 8'd156;
        r_sine_lut[120] = 8'd152; r_sine_lut[121] = 8'd149; r_sine_lut[122] = 8'd146; r_sine_lut[123] = 8'd143;
        r_sine_lut[124] = 8'd140; r_sine_lut[125] = 8'd137; r_sine_lut[126] = 8'd134; r_sine_lut[127] = 8'd131;
        // Quadrant 2: 128-191 (pi to 3*pi/2)
        r_sine_lut[128] = 8'd128; r_sine_lut[129] = 8'd125; r_sine_lut[130] = 8'd122; r_sine_lut[131] = 8'd119;
        r_sine_lut[132] = 8'd116; r_sine_lut[133] = 8'd113; r_sine_lut[134] = 8'd110; r_sine_lut[135] = 8'd107;
        r_sine_lut[136] = 8'd104; r_sine_lut[137] = 8'd100; r_sine_lut[138] = 8'd97;  r_sine_lut[139] = 8'd94;
        r_sine_lut[140] = 8'd91;  r_sine_lut[141] = 8'd88;  r_sine_lut[142] = 8'd85;  r_sine_lut[143] = 8'd82;
        r_sine_lut[144] = 8'd79;  r_sine_lut[145] = 8'd77;  r_sine_lut[146] = 8'd74;  r_sine_lut[147] = 8'd71;
        r_sine_lut[148] = 8'd68;  r_sine_lut[149] = 8'd65;  r_sine_lut[150] = 8'd63;  r_sine_lut[151] = 8'd60;
        r_sine_lut[152] = 8'd57;  r_sine_lut[153] = 8'd55;  r_sine_lut[154] = 8'd52;  r_sine_lut[155] = 8'd50;
        r_sine_lut[156] = 8'd47;  r_sine_lut[157] = 8'd45;  r_sine_lut[158] = 8'd43;  r_sine_lut[159] = 8'd40;
        r_sine_lut[160] = 8'd38;  r_sine_lut[161] = 8'd36;  r_sine_lut[162] = 8'd34;  r_sine_lut[163] = 8'd32;
        r_sine_lut[164] = 8'd30;  r_sine_lut[165] = 8'd28;  r_sine_lut[166] = 8'd26;  r_sine_lut[167] = 8'd24;
        r_sine_lut[168] = 8'd22;  r_sine_lut[169] = 8'd21;  r_sine_lut[170] = 8'd19;  r_sine_lut[171] = 8'd18;
        r_sine_lut[172] = 8'd16;  r_sine_lut[173] = 8'd15;  r_sine_lut[174] = 8'd13;  r_sine_lut[175] = 8'd12;
        r_sine_lut[176] = 8'd11;  r_sine_lut[177] = 8'd10;  r_sine_lut[178] = 8'd9;   r_sine_lut[179] = 8'd8;
        r_sine_lut[180] = 8'd7;   r_sine_lut[181] = 8'd6;   r_sine_lut[182] = 8'd5;   r_sine_lut[183] = 8'd4;
        r_sine_lut[184] = 8'd4;   r_sine_lut[185] = 8'd3;   r_sine_lut[186] = 8'd3;   r_sine_lut[187] = 8'd2;
        r_sine_lut[188] = 8'd2;   r_sine_lut[189] = 8'd2;   r_sine_lut[190] = 8'd1;   r_sine_lut[191] = 8'd1;
        // Quadrant 3: 192-255 (3*pi/2 to 2*pi)
        r_sine_lut[192] = 8'd1;   r_sine_lut[193] = 8'd1;   r_sine_lut[194] = 8'd1;   r_sine_lut[195] = 8'd2;
        r_sine_lut[196] = 8'd2;   r_sine_lut[197] = 8'd2;   r_sine_lut[198] = 8'd3;   r_sine_lut[199] = 8'd3;
        r_sine_lut[200] = 8'd4;   r_sine_lut[201] = 8'd4;   r_sine_lut[202] = 8'd5;   r_sine_lut[203] = 8'd6;
        r_sine_lut[204] = 8'd7;   r_sine_lut[205] = 8'd8;   r_sine_lut[206] = 8'd9;   r_sine_lut[207] = 8'd10;
        r_sine_lut[208] = 8'd11;  r_sine_lut[209] = 8'd12;  r_sine_lut[210] = 8'd13;  r_sine_lut[211] = 8'd15;
        r_sine_lut[212] = 8'd16;  r_sine_lut[213] = 8'd18;  r_sine_lut[214] = 8'd19;  r_sine_lut[215] = 8'd21;
        r_sine_lut[216] = 8'd22;  r_sine_lut[217] = 8'd24;  r_sine_lut[218] = 8'd26;  r_sine_lut[219] = 8'd28;
        r_sine_lut[220] = 8'd30;  r_sine_lut[221] = 8'd32;  r_sine_lut[222] = 8'd34;  r_sine_lut[223] = 8'd36;
        r_sine_lut[224] = 8'd38;  r_sine_lut[225] = 8'd40;  r_sine_lut[226] = 8'd43;  r_sine_lut[227] = 8'd45;
        r_sine_lut[228] = 8'd47;  r_sine_lut[229] = 8'd50;  r_sine_lut[230] = 8'd52;  r_sine_lut[231] = 8'd55;
        r_sine_lut[232] = 8'd57;  r_sine_lut[233] = 8'd60;  r_sine_lut[234] = 8'd63;  r_sine_lut[235] = 8'd65;
        r_sine_lut[236] = 8'd68;  r_sine_lut[237] = 8'd71;  r_sine_lut[238] = 8'd74;  r_sine_lut[239] = 8'd77;
        r_sine_lut[240] = 8'd79;  r_sine_lut[241] = 8'd82;  r_sine_lut[242] = 8'd85;  r_sine_lut[243] = 8'd88;
        r_sine_lut[244] = 8'd91;  r_sine_lut[245] = 8'd94;  r_sine_lut[246] = 8'd97;  r_sine_lut[247] = 8'd100;
        r_sine_lut[248] = 8'd104; r_sine_lut[249] = 8'd107; r_sine_lut[250] = 8'd110; r_sine_lut[251] = 8'd113;
        r_sine_lut[252] = 8'd116; r_sine_lut[253] = 8'd119; r_sine_lut[254] = 8'd122; r_sine_lut[255] = 8'd125;
    end

    // Sine test pattern state (clk_cpu domain)
    // X sweeps 0-511 (10 bits), Y = 256 + sine_offset
    reg [9:0]  r_sine_t;           // Time/phase counter (X coordinate)
    reg [9:0]  r_sine_x;           // Calculated X coordinate
    reg [9:0]  r_sine_y;           // Calculated Y coordinate
    reg [7:0]  r_sine_phase;       // Phase for sine lookup (wraps at 256)

    // Sine wave parameters
    // NOTE: In PDP-1 mode, CRT does coordinate swap: {buffer_Y, buffer_X} = {~i_pixel_x, i_pixel_y}
    // So our sine_x becomes vertical (buffer_Y) and sine_y becomes horizontal (buffer_X)
    // To get a HORIZONTAL sine wave on screen, we must:
    //   - Put SWEEP in sine_y (becomes horizontal buffer_X)
    //   - Put SINE OFFSET in sine_x (becomes vertical buffer_Y after inversion)
    localparam SINE_CENTER_X = 10'd512;  // Center X for vertical sine position (becomes ~buffer_Y)
    localparam SINE_AMPLITUDE = 8'd100;  // Amplitude in pixels

    // SINE2 parameters: higher on screen, slower, stronger phosphor
    // Author: Jelena Kovacevic, REGOC team
    // Date: 2026-02-02
    localparam SINE2_CENTER_X = 10'd612;  // 100 pixels higher (higher X = lower on screen after inversion)

    // Intermediate calculation registers for pipelining
    reg signed [9:0] r_sine_offset;  // Signed offset from center

    // Update sine coordinates on each CPU pixel_shift
    // NOTE: Always update even when not in test mode to avoid glitches on mode switch
    //
    // COORDINATE SWAP FIX (Jelena Horvat, 2026-02-02):
    // PDP-1 CRT transformation: {buffer_Y, buffer_X} = {~pixel_x, pixel_y}
    // This means:
    //   - pixel_x -> inverted -> vertical position on screen (buffer_Y)
    //   - pixel_y -> unchanged -> horizontal position on screen (buffer_X)
    //
    // For HORIZONTAL sine wave:
    //   - r_sine_y = SWEEP (0->1023) -> becomes buffer_X (horizontal sweep on screen)
    //   - r_sine_x = CENTER + offset -> becomes ~buffer_Y (vertical sine displacement)
    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sine_t      <= 10'd0;
            r_sine_x      <= SINE_CENTER_X;
            r_sine_y      <= 10'd0;
            r_sine_phase  <= 8'd0;
            r_sine_offset <= 10'sd0;
        end else if (w_cpu_pixel_shift) begin
            // Advance time counter (wraps at 1024)
            r_sine_t <= r_sine_t + 1'b1;

            // r_sine_y = SWEEP: becomes horizontal position on screen (buffer_X)
            r_sine_y <= r_sine_t[9:0];

            // Phase advances 4x faster than sweep for visible oscillation
            r_sine_phase <= r_sine_phase + 8'd4;

            // Calculate signed offset: (sine_lut - 128)
            // sine_lut is 0-255, subtract 128 to get -128 to +127 range
            r_sine_offset <= $signed({2'b0, r_sine_lut[r_sine_phase]}) - 10'sd128;

            // r_sine_x = CENTER + offset: becomes vertical position on screen (~buffer_Y)
            // Since CRT inverts X, higher values here = lower on screen
            r_sine_x <= SINE_CENTER_X + r_sine_offset[9:0];
        end
    end

    // =========================================================================
    // SINE2: Second sine wave - higher position, slower, stronger phosphor
    // Author: Jelena Kovacevic, REGOC team
    // Date: 2026-02-02
    // Uses same pixel pipeline as spaceship DPY instructions
    // =========================================================================
    reg [9:0]  r_sine2_t;           // Time/phase counter
    reg [9:0]  r_sine2_x;           // Calculated X coordinate
    reg [9:0]  r_sine2_y;           // Calculated Y coordinate
    reg [7:0]  r_sine2_phase;       // Phase for sine lookup
    reg signed [9:0] r_sine2_offset;  // Signed offset from center
    reg [1:0]  r_sine2_slowdown;    // Counter for 4x slower update

    // Multiplexer state: alternates between sine1 and sine2
    reg        r_sine_select;       // 0 = sine1, 1 = sine2

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sine2_t        <= 10'd0;
            r_sine2_x        <= SINE2_CENTER_X;
            r_sine2_y        <= 10'd0;
            r_sine2_phase    <= 8'd0;
            r_sine2_offset   <= 10'sd0;
            r_sine2_slowdown <= 2'd0;
            r_sine_select    <= 1'b0;
        end else if (w_cpu_pixel_shift) begin
            // Toggle between sine1 and sine2 each pixel_shift
            r_sine_select <= ~r_sine_select;

            // Sine2 updates every 4th pixel_shift (slower)
            r_sine2_slowdown <= r_sine2_slowdown + 1'b1;
            if (r_sine2_slowdown == 2'd3) begin
                // Advance time counter (wraps at 1024)
                r_sine2_t <= r_sine2_t + 1'b1;

                // r_sine2_y = SWEEP: horizontal position on screen
                r_sine2_y <= r_sine2_t[9:0];

                // Phase advances 2x (slower oscillation than sine1 which uses 4x)
                r_sine2_phase <= r_sine2_phase + 8'd2;

                // Calculate signed offset
                r_sine2_offset <= $signed({2'b0, r_sine_lut[r_sine2_phase]}) - 10'sd128;

                // r_sine2_x = CENTER + offset: vertical position
                r_sine2_x <= SINE2_CENTER_X + r_sine2_offset[9:0];
            end
        end
    end

    // Multiplexed sine coordinates (alternates sine1/sine2)
    wire [9:0] w_sine_mux_x = r_sine_select ? r_sine2_x : r_sine_x;
    wire [9:0] w_sine_mux_y = r_sine_select ? r_sine2_y : r_sine_y;
    // Sine2 has stronger phosphor: 3'b110, sine1 keeps 3'd7
    wire [2:0] w_sine_mux_brightness = r_sine_select ? 3'b110 : 3'd7;

    // =========================================================================
    // CDC: MULTI-BIT PIXEL DATA (clk_cpu -> clk_pixel)
    // =========================================================================
    // PROBLEM: 23 bits (10+10+3) transferred across CDC without handshake.
    //          Each bit may have different latency through 2FF sync, causing
    //          inconsistent coordinates (e.g., X=old value, Y=new value).
    //
    // SOLUTION: HOLD registers in CPU domain keep data stable for 8 CPU cycles
    //           (~1.28us at 6.25 MHz), which is long enough for pixel clock
    //           (51 MHz) to sample stable data.
    //
    //           Timing analysis:
    //           - 8 CPU cycles = 8 * 160ns = 1.28us
    //           - At 51 MHz: 1.28us = ~65 pixel clock cycles
    //           - 3-stage sync needs only 3 pixel cycles -> plenty of margin!
    //
    // CDC Path: w_cpu_pixel_* -> r_pixel_*_hold -> [stable] -> 3FF sync -> CRT
    //
    // SINE TEST MODE (SW[2]=1):
    //   When test mode active, sine wave coordinates replace CPU coordinates.
    //   Still uses CPU DPY timing for proper pipeline synchronization.
    // =========================================================================
    reg [9:0]  r_pixel_x_hold;
    reg [9:0]  r_pixel_y_hold;
    reg [2:0]  r_pixel_brightness_hold;
    reg [3:0]  r_pixel_hold_counter;
    reg        r_pixel_hold_valid;

    // Select between CPU coordinates and sine test pattern
    // Uses multiplexed sine (sine1/sine2 alternating) when in test mode
    wire [9:0] w_selected_pixel_x = w_sine_test_mode ? w_sine_mux_x : w_cpu_pixel_x;
    wire [9:0] w_selected_pixel_y = w_sine_test_mode ? w_sine_mux_y : w_cpu_pixel_y;
    wire [2:0] w_selected_brightness = w_sine_test_mode ? w_sine_mux_brightness : w_cpu_pixel_brightness;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_pixel_x_hold          <= 10'd0;
            r_pixel_y_hold          <= 10'd0;
            r_pixel_brightness_hold <= 3'd0;
            r_pixel_hold_counter    <= 4'd0;
            r_pixel_hold_valid      <= 1'b0;
        end else begin
            if (w_cpu_pixel_shift && r_pixel_hold_counter == 0) begin
                // Latch new pixel and hold stable for CDC
                // Use selected coordinates (CPU or sine depending on SW[2])
                r_pixel_x_hold          <= w_selected_pixel_x;
                r_pixel_y_hold          <= w_selected_pixel_y;
                r_pixel_brightness_hold <= w_selected_brightness;
                r_pixel_hold_counter    <= 4'd8;    // Hold 8 CPU cycles (~1.28us)
                r_pixel_hold_valid      <= 1'b1;
            end else if (r_pixel_hold_counter > 0) begin
                r_pixel_hold_counter <= r_pixel_hold_counter - 1'b1;
                if (r_pixel_hold_counter == 1)
                    r_pixel_hold_valid <= 1'b0;
            end
        end
    end

    // Map HOLD outputs to generic pixel signals (for CRT display)
    // HOLD registers guarantee stable data during CDC transfer
    wire [9:0] w_test_pixel_x     = r_pixel_x_hold;
    wire [9:0] w_test_pixel_y     = r_pixel_y_hold;
    wire [2:0] w_test_brightness  = r_pixel_brightness_hold;
    wire       w_test_pixel_avail = r_pixel_hold_valid;
`endif

`ifdef TEST_ANIMATION
    // =========================================================================
    // TEST ANIMATION: No CDC needed (already in clk_pixel domain)
    // =========================================================================
    // Animation module runs entirely in clk_pixel domain, no CDC required.
    // Direct wire mapping (no synchronization needed).
    // -------------------------------------------------------------------------
    wire [9:0] w_pixel_x_sync       = w_test_pixel_x;
    wire [9:0] w_pixel_y_sync       = w_test_pixel_y;
    wire [2:0] w_brightness_sync    = w_test_brightness;
    wire       w_pixel_avail_synced = w_test_pixel_avail;

`else
    // =========================================================================
    // CDC: PIXEL VALID SYNCHRONIZATION (clk_cpu -> clk_pixel)
    // =========================================================================
    // Architecture (HDL Guidelines 07_CDC_GUIDELINES):
    //
    // CPU Domain (6.25 MHz)          |  Pixel Domain (51 MHz)
    // --------------------------------|--------------------------------
    // w_cpu_pixel_shift --+          |
    //                     |          |
    // w_cpu_pixel_x/y ----+-> HOLD --|--> w_test_pixel_x/y (STABLE!)
    //                     |  (8 cyc) |
    // r_pixel_hold_valid -+----------|--> [3-stage sync] --> w_pixel_avail_synced
    //                                |          |
    //                                |    [Latch on rising edge]
    //                                |          |
    //                                |    r_pixel_x_sync/y_sync
    //
    // HOLD registers keep data stable for 8 CPU cycles (~1.28us).
    // 3-stage sync for valid signal ensures metastability protection.
    // Coordinates latched when valid is stable - data guaranteed stable too!
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_pixel_avail_sync;  // 3-stage synchronizer
    reg [9:0] r_pixel_x_sync;
    reg [9:0] r_pixel_y_sync;
    reg [2:0] r_brightness_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_avail_sync <= 3'b0;
            r_pixel_x_sync     <= 10'd240;  // Center of screen default
            r_pixel_y_sync     <= 10'd240;
            r_brightness_sync  <= 3'b0;
        end else begin
            // 3-stage sync for metastability protection on valid signal
            r_pixel_avail_sync <= {r_pixel_avail_sync[1:0], w_test_pixel_avail};

            // Latch coordinates on rising edge detection
            // SAFE: coordinates come from HOLD registers and are stable!
            if (r_pixel_avail_sync[1] && !r_pixel_avail_sync[2]) begin
                r_pixel_x_sync    <= w_test_pixel_x;
                r_pixel_y_sync    <= w_test_pixel_y;
                r_brightness_sync <= w_test_brightness;
            end
        end
    end

    // Synchronized pixel_available signal (single-cycle pulse in clk_pixel domain)
    wire w_pixel_avail_synced = r_pixel_avail_sync[1] && !r_pixel_avail_sync[2];
    wire [9:0] w_pixel_x_sync    = r_pixel_x_sync;
    wire [9:0] w_pixel_y_sync    = r_pixel_y_sync;
    wire [2:0] w_brightness_sync = r_brightness_sync;
`endif

    pdp1_vga_crt u_crt_display
    (
        .i_clk              (clk_pixel),

        .i_h_counter        (r_h_counter),
        .i_v_counter        (r_v_counter),

        .o_red              (w_crt_r),
        .o_green            (w_crt_g),
        .o_blue             (w_crt_b),

        // Pixel input from CPU (CDC synchronized!)
        .i_pixel_x          (w_pixel_x_sync),
        .i_pixel_y          (w_pixel_y_sync),
        .i_pixel_brightness (w_brightness_sync),
        .i_variable_brightness(1'b1),
        .i_pixel_valid      (w_pixel_avail_synced),

        // Debug outputs
        .o_dbg_fifo_wr_ptr       (w_crt_debug_write_ptr),
        .o_dbg_fifo_rd_ptr       (w_crt_debug_read_ptr),
        .o_dbg_pixel_strobe      (w_crt_debug_wren),
        .o_dbg_search_counter    (w_crt_debug_search_counter),
        .o_dbg_luma1             (w_crt_debug_luma1),
        .o_dbg_rowbuff_wren      (w_crt_debug_rowbuff_wren),
        .o_dbg_inside_visible    (w_crt_debug_inside_visible),
        .o_dbg_pixel_to_rowbuff  (w_crt_debug_pixel_to_rowbuff),
        .o_dbg_rowbuff_count     (w_crt_debug_rowbuff_write_count),
        .o_dbg_ring_wrptr        (w_crt_debug_ring_buffer_wrptr)
    );

    // =========================================================================
    // VGA SYNC SIGNAL GENERATION (clk_pixel domain)
    // =========================================================================
    // NOTE: HSYNC and VSYNC active-low per VGA standard.
    // DE (Data Enable) active-high during visible region.
    // -------------------------------------------------------------------------
    wire w_vga_hsync, w_vga_vsync, w_vga_de, w_vga_blank;

    assign w_vga_hsync = (r_h_counter >= `h_front_porch) &&
                         (r_h_counter <  `h_front_porch + `h_sync_pulse) ? 1'b0 : 1'b1;
    assign w_vga_vsync = (r_v_counter >= `v_front_porch) &&
                         (r_v_counter <  `v_front_porch + `v_sync_pulse) ? 1'b0 : 1'b1;
    assign w_vga_de    = (r_h_counter >= `h_visible_offset) &&
                         (r_v_counter >= `v_visible_offset);
    assign w_vga_blank = ~w_vga_de;

    // =========================================================================
    // ESP32 OSD INTEGRATION (Optional, dual clock domain)
    // =========================================================================
`ifdef ESP32_OSD
    wire [23:0] w_osd_video_out;
    wire        w_osd_de_out, w_osd_hs_out, w_osd_vs_out;
    wire [31:0] w_osd_status;
    wire [15:0] w_osd_joystick_0, w_osd_joystick_1;

    // Video input to OSD (CRT RGB packed)
    wire [23:0] w_crt_video_in = {w_crt_r, w_crt_g, w_crt_b};

    // Pixel coordinates for OSD positioning
    wire [11:0] w_osd_pixel_x = (r_h_counter >= `h_visible_offset) ?
                                (r_h_counter - `h_visible_offset) : 12'd0;
    wire [11:0] w_osd_pixel_y = (r_v_counter >= `v_visible_offset) ?
                                (r_v_counter - `v_visible_offset) : 12'd0;

    esp32_osd #(
        .OSD_COLOR    (3'd4),       // Blue OSD color
        .OSD_X_OFFSET (12'd384),    // Centered for 1024x768
        .OSD_Y_OFFSET (12'd320)     // Centered for 1024x768
    ) u_esp32_osd (
        .clk_sys      (clk_cpu),
        .clk_video    (clk_pixel),
        .rst_n        (rst_pixel_n),
        // ESP32 SPI interface (asynchronous to FPGA clocks)
        .spi_clk      (esp32_spi_clk),
        .spi_mosi     (esp32_spi_mosi),
        .spi_miso     (esp32_spi_miso),
        .spi_cs_n     (esp32_spi_cs_n),
        .osd_irq      (esp32_osd_irq),
        .esp32_ready  (esp32_ready),
        // Video input (clk_pixel domain)
        .video_in     (w_crt_video_in),
        .de_in        (w_vga_de),
        .hs_in        (w_vga_hsync),
        .vs_in        (w_vga_vsync),
        .pixel_x      (w_osd_pixel_x),
        .pixel_y      (w_osd_pixel_y),
        // Video output (clk_pixel domain)
        .video_out    (w_osd_video_out),
        .de_out       (w_osd_de_out),
        .hs_out       (w_osd_hs_out),
        .vs_out       (w_osd_vs_out),
        // Status outputs
        .status       (w_osd_status),
        .joystick_0   (w_osd_joystick_0),
        .joystick_1   (w_osd_joystick_1)
    );
`endif

    // =========================================================================
    // VGA RGB OUTPUT SELECTION (clk_pixel domain)
    // =========================================================================
    // SW[3] = 0: CRT output (with OSD if enabled)
    // SW[3] = 1: Test pattern (debugging color bars)
    // -------------------------------------------------------------------------
    wire [7:0] w_vga_r, w_vga_g, w_vga_b;

    // Test pattern for debug: simple gradient color bars
    wire [7:0] w_test_r = r_h_counter[7:0];
    wire [7:0] w_test_g = r_v_counter[7:0];
    wire [7:0] w_test_b = {r_h_counter[3:0], r_v_counter[3:0]};

`ifdef ESP32_OSD
    // OSD overlay output (when ESP32 OSD is enabled)
    wire [7:0] w_final_r = w_osd_video_out[23:16];
    wire [7:0] w_final_g = w_osd_video_out[15:8];
    wire [7:0] w_final_b = w_osd_video_out[7:0];
`else
    // Direct CRT output (no OSD)
    wire [7:0] w_final_r = w_crt_r;
    wire [7:0] w_final_g = w_crt_g;
    wire [7:0] w_final_b = w_crt_b;
`endif

    assign w_vga_r = sw[3] ? w_test_r : w_final_r;
    assign w_vga_g = sw[3] ? w_test_g : w_final_g;
    assign w_vga_b = sw[3] ? w_test_b : w_final_b;

    // =========================================================================
    // HDMI OUTPUT (VGA -> DVID/TMDS CONVERSION)
    // =========================================================================
    // Dual clock domain: clk_pixel for encoding, clk_shift for serialization
    // -------------------------------------------------------------------------
    wire [1:0] w_tmds_clock, w_tmds_red, w_tmds_green, w_tmds_blue;

    vga2dvid #(
        .C_ddr   (C_DDR),
        .C_depth (8)
    ) u_vga2dvid (
        .clk_pixel  (clk_pixel),
        .clk_shift  (clk_shift),

        .in_red     (w_vga_r),
        .in_green   (w_vga_g),
        .in_blue    (w_vga_b),
        .in_hsync   (w_vga_hsync),
        .in_vsync   (w_vga_vsync),
        .in_blank   (w_vga_blank),

        .out_clock  (w_tmds_clock),
        .out_red    (w_tmds_red),
        .out_green  (w_tmds_green),
        .out_blue   (w_tmds_blue)
    );

    // =========================================================================
    // FAKE DIFFERENTIAL OUTPUT (ECP5 DDR primitives, clk_shift domain)
    // =========================================================================
    fake_differential #(
        .C_ddr (C_DDR)
    ) u_fake_diff (
        .clk_shift (clk_shift),

        .in_clock  (w_tmds_clock),
        .in_red    (w_tmds_red),
        .in_green  (w_tmds_green),
        .in_blue   (w_tmds_blue),

        .out_p     (gpdi_dp),
        .out_n     (gpdi_dn)
    );

    // =========================================================================
    // DEBUG: LED INDICATORS (clk_pixel domain, human-visible rate)
    // =========================================================================
    // LED divider creates ~1.5Hz blink rate for human observation.
    // 51MHz / 2^25 = ~1.52 Hz
    // -------------------------------------------------------------------------
    reg [24:0] r_led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_led_divider <= 25'd0;
        else
            r_led_divider <= r_led_divider + 1'b1;
    end

    // Latch activity signals on slow clock for human visibility
    reg r_pixel_valid_seen;
    reg r_frame_tick_seen;
    reg r_rowbuff_write_seen;
    reg r_inside_visible_seen;
    reg r_pixel_to_rowbuff_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_valid_seen    <= 1'b0;
            r_frame_tick_seen     <= 1'b0;
            r_rowbuff_write_seen  <= 1'b0;
            r_inside_visible_seen <= 1'b0;
            r_pixel_to_rowbuff_seen <= 1'b0;
        end else begin
            // Reset on each slow clock tick (~0.5s period)
            if (r_led_divider[24]) begin
                r_pixel_valid_seen    <= 1'b0;
                r_frame_tick_seen     <= 1'b0;
                r_rowbuff_write_seen  <= 1'b0;
                r_inside_visible_seen <= 1'b0;
                r_pixel_to_rowbuff_seen <= 1'b0;
            end else begin
                // Latch if event occurred
                if (w_pixel_avail_synced)
                    r_pixel_valid_seen <= 1'b1;
`ifdef TEST_ANIMATION
                if (r_frame_tick)
                    r_frame_tick_seen <= 1'b1;
`endif
                // DEBUG: Latch rowbuffer write activity
                if (w_crt_debug_rowbuff_wren)
                    r_rowbuff_write_seen <= 1'b1;
                // DEBUG: Latch inside_visible_area activity
                if (w_crt_debug_inside_visible)
                    r_inside_visible_seen <= 1'b1;
                // DEBUG: Latch pixel written to rowbuffer (non-zero data)
                if (w_crt_debug_pixel_to_rowbuff)
                    r_pixel_to_rowbuff_seen <= 1'b1;
            end
        end
    end

    // =========================================================================
    // COMPREHENSIVE LED DEBUG (clk_pixel domain)
    // =========================================================================
    // LED[0] = heartbeat (clk_pixel running) - blink at ~1.5Hz
    // LED[1] = r_cpu_clk_seen - CPU clock activity detected
    // LED[2] = r_pixel_valid_seen - Pixel valid signal seen
    // LED[3] = r_frame_tick_seen - Frame tick detected
    // LED[4] = r_h_counter[9] - H counter MSB (toggles during line)
    // LED[5] = r_v_counter[9] - V counter MSB (toggles during frame)
    // LED[6] = w_pll_locked - PLL lock indicator
    // LED[7] = rst_pixel_n - Reset released
    // -------------------------------------------------------------------------

    // CDC: CPU clock enable synchronization (clk_cpu -> clk_pixel)
    reg r_cpu_clk_seen;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_cpu_clk_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_clk_seen <= 1'b0;
            r_cpu_clk_sync <= 2'b0;
        end else begin
            // 2-stage synchronizer for clk_cpu_en
            r_cpu_clk_sync <= {r_cpu_clk_sync[0], w_clk_cpu_en};
            // Reset on slow clock tick, latch if cpu clock seen
            if (r_led_divider[24])
                r_cpu_clk_seen <= 1'b0;
            else if (r_cpu_clk_sync[1])
                r_cpu_clk_seen <= 1'b1;
        end
    end

    // Frame tick detector for non-TEST_ANIMATION mode
`ifndef TEST_ANIMATION
    reg r_frame_tick_seen_cpu;
    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_frame_tick_seen_cpu <= 1'b0;
        else if (r_led_divider[24])
            r_frame_tick_seen_cpu <= 1'b0;
        else if (r_cpu_frame_tick)
            r_frame_tick_seen_cpu <= 1'b1;
    end
`endif

    // Unified LED assignments for comprehensive debug
    assign led[0] = r_led_divider[24];         // Heartbeat ~1.5Hz
    assign led[1] = r_cpu_clk_seen;            // CPU clock activity
    assign led[2] = r_pixel_valid_seen;        // Pixel valid detected
`ifdef TEST_ANIMATION
    assign led[3] = r_frame_tick_seen;         // Frame tick detected
`else
    assign led[3] = r_frame_tick_seen_cpu;     // Frame tick detected (CPU mode)
`endif
    assign led[4] = r_h_counter[9];            // H counter MSB
    assign led[5] = r_v_counter[9];            // V counter MSB
    assign led[6] = w_pll_locked;              // PLL locked
    assign led[7] = rst_pixel_n;               // Reset released

    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
`ifdef TEST_ANIMATION
    // Serial debug for TEST_ANIMATION mode - uses animation signals
    serial_debug u_serial_debug (
        .i_clk                (clk_pixel),
        .i_rst_n              (rst_pixel_n),
        .i_enable             (w_single_player),  // SW[1] synchronized signal
        .i_frame_tick         (r_frame_tick),
        .i_angle              (w_anim_debug_angle),
        .i_pixel_x            (w_anim_pixel_x),
        .i_pixel_y            (w_anim_pixel_y),
        .i_pixel_valid        (w_anim_pixel_valid),
        .i_led_status         (led),
        // CRT Pipeline Debug
        .i_pixel_avail_synced (w_pixel_avail_synced),
        .i_crt_wren           (w_crt_debug_wren),
        .i_crt_write_ptr      (w_crt_debug_write_ptr),
        .i_crt_read_ptr       (w_crt_debug_read_ptr),
        .i_search_counter_msb (w_crt_debug_search_counter),
        .i_luma1              (w_crt_debug_luma1),
        .i_rowbuff_write_count(w_crt_debug_rowbuff_write_count),
        // CPU Debug (not used in TEST_ANIMATION mode)
        .i_cpu_pc             (12'd0),
        .i_cpu_instr_count    (16'd0),
        .i_cpu_iot_count      (16'd0),
        .i_cpu_running        (1'b0),
        // Pixel Debug (animation signals)
        .i_pixel_count        (32'd0),
        .i_pixel_debug_x      (w_anim_pixel_x),
        .i_pixel_debug_y      (w_anim_pixel_y),
        .i_pixel_brightness   (w_anim_brightness),
        .i_pixel_shift_out    (w_anim_pixel_valid),
        .i_ring_buffer_wrptr  (w_crt_debug_ring_buffer_wrptr),
        .o_uart_tx            (ftdi_rxd)
    );
`else
    // =========================================================================
    // CPU MODE: Serial Debug Output
    // =========================================================================
    // Frame tick generator for CPU mode
    reg        r_cpu_frame_tick;
    reg [10:0] r_cpu_prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_frame_tick      <= 1'b0;
            r_cpu_prev_v_counter  <= 11'd0;
        end else begin
            r_cpu_prev_v_counter <= r_v_counter;
            // Detect start of new frame (transition into vblank)
            r_cpu_frame_tick <= (r_v_counter == 11'd0) && (r_cpu_prev_v_counter != 11'd0);
        end
    end

    // -------------------------------------------------------------------------
    // CDC NOTE: Debug signal crossing (clk_cpu -> clk_pixel)
    // -------------------------------------------------------------------------
    // w_cpu_pixel_x/y, w_cpu_pc, w_cpu_debug_* signals come from clk_cpu domain
    // without explicit synchronization. This is INTENTIONALLY acceptable because:
    //   1) These are debug signals - occasional metastability causes only
    //      incorrect debug output, does not affect functionality
    //   2) Signals are sampled on frame_tick which is rare (~50Hz)
    //   3) Adding CDC would add latency without real benefit
    // -------------------------------------------------------------------------
    serial_debug u_serial_debug_cpu (
        .i_clk                (clk_pixel),
        .i_rst_n              (rst_pixel_n),
        .i_enable             (w_single_player),  // SW[1] synchronized signal
        .i_frame_tick         (r_cpu_frame_tick),
        .i_angle              (w_cpu_pc[7:0]),     // PC low byte
        .i_pixel_x            (w_cpu_pixel_x),
        .i_pixel_y            (w_cpu_pixel_y),
        .i_pixel_valid        (w_cpu_pixel_shift),
        .i_led_status         (led),
        // CRT Pipeline Debug
        .i_pixel_avail_synced (w_pixel_avail_synced),
        .i_crt_wren           (w_crt_debug_wren),
        .i_crt_write_ptr      (w_crt_debug_write_ptr),
        .i_crt_read_ptr       (w_crt_debug_read_ptr),
        .i_search_counter_msb (w_crt_debug_search_counter),
        .i_luma1              (w_crt_debug_luma1),
        .i_rowbuff_write_count(w_crt_debug_rowbuff_write_count),
        // CPU Debug
        .i_cpu_pc             (w_cpu_pc),
        .i_cpu_instr_count    (w_cpu_debug_instr_count),
        .i_cpu_iot_count      (w_cpu_debug_iot_count),
        .i_cpu_running        (w_cpu_debug_running),
        // Pixel Debug
        .i_pixel_count        (w_cpu_debug_pixel_count),
        .i_pixel_debug_x      (w_cpu_debug_pixel_x),
        .i_pixel_debug_y      (w_cpu_debug_pixel_y),
        .i_pixel_brightness   (w_cpu_debug_pixel_brightness),
        .i_pixel_shift_out    (w_cpu_pixel_shift),
        .i_ring_buffer_wrptr  (w_crt_debug_ring_buffer_wrptr),
        .o_uart_tx            (ftdi_rxd)
    );
`endif

endmodule
