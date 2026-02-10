//==============================================================================
// Module:      top_test_sinus
// Description: Standalone top-level module for sine wave test pattern
//==============================================================================
// Author:      Jelena Kovacevic, FPGA Engineer, REGOC team
// Created:     2026-02-10
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
//   - clk_cpu    :  51 MHz  - PDP-1 CPU emulation base clock
//
// Purpose:
//   This is a dedicated test module for sine wave pattern visualization.
//   Unlike top_pdp1.v, sine test is ALWAYS active - no SW switching.
//   CPU is required because test_sinus uses i_pixel_shift from DPY timing.
//
// Key Differences from top_pdp1.v:
//   1. Sine test coordinates are ALWAYS used (no SW[2] MUX)
//   2. No SW[3] color bars switching
//   3. No TEST_ANIMATION ifdef
//   4. Module name: top_test_sinus
//
//==============================================================================

`include "definitions.v"

module top_test_sinus
(
    // =========================================================================
    // PORT NAMING CONVENTION (HDL Guidelines 01_NAMING_CONVENTIONS):
    //   i_  = Input port
    //   o_  = Output port
    //   _n  = Active-low signal
    // =========================================================================

    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    // DIP SWITCH MAPPING (ACTIVE-HIGH):
    //   SW[0] = P2 mode modifier (hold for Player 2 controls)
    //   SW[1] = Serial debug enable (ON=enabled, OFF=disabled)
    //   SW[2] = (unused in this test module)
    //   SW[3] = (unused in this test module)
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
);

    // =========================================================================
    // PARAMETERS (HDL Guidelines: UPPER_CASE for constants)
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)

    // Local parameters (computed, do not override)
    localparam C_PIXEL_CLK_FREQ = 51_000_000;  // 51 MHz pixel clock
    localparam C_CPU_CLK_FREQ   = 51_000_000;  // 51 MHz CPU clock

    // =========================================================================
    // ACTIVE-LOW -> ACTIVE-HIGH BUTTON CONVERSION
    // =========================================================================
    assign wifi_gpio0 = btn[0];

    // =========================================================================
    // HDMI HPD (Hot Plug Detect)
    // =========================================================================
    assign gpdi_scl = 1'b1;
    wire w_monitor_connected = gpdi_hpd;

    // =========================================================================
    // CLOCK GENERATION (PLL) - 1024x768@50Hz Video Mode
    // =========================================================================
    wire clk_shift;     // 255 MHz HDMI shift clock (5x pixel for DDR)
    wire clk_pixel;     // 51 MHz pixel clock (1024x768@50Hz timing)
    wire clk_cpu;       // 51 MHz CPU base clock (same as pixel)
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
    wire w_clk_cpu_slow;    // 1.82 MHz PDP-1 clock (51 MHz / 28, legacy interface)
    wire w_clk_cpu_en;      // Clock enable pulse
    wire rst_pixel_n;       // Synchronized reset for pixel domain (active-low)
    wire rst_cpu_n;         // Synchronized reset for CPU domain (active-low)

    // CDC framebuffer signals (placeholders)
    wire [11:0] w_cpu_fb_addr = 12'b0;
    wire [11:0] w_cpu_fb_data = 12'b0;
    wire        w_cpu_fb_we   = 1'b0;
    wire [11:0] w_vid_fb_addr;
    wire [11:0] w_vid_fb_data;
    wire        w_vid_fb_we;
    wire        w_vid_vblank;
    wire        w_cpu_vblank;

    // CRT output signals from CPU (clk_cpu domain - requires CDC!)
    wire [9:0]  w_cpu_pixel_x;
    wire [9:0]  w_cpu_pixel_y;
    wire [2:0]  w_cpu_pixel_brightness;
    wire        w_cpu_pixel_shift;

    // CRT output signals synchronized to pixel clock domain
    wire [9:0]  w_vid_pixel_x;
    wire [9:0]  w_vid_pixel_y;
    wire [2:0]  w_vid_pixel_brightness;
    wire        w_vid_pixel_shift;

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
        .cpu_vblank     (w_cpu_vblank),

        // CDC interface: CPU pixel coordinates and control -> Video
        .cpu_pixel_x            (w_cpu_pixel_x),
        .cpu_pixel_y            (w_cpu_pixel_y),
        .cpu_pixel_brightness   (w_cpu_pixel_brightness),
        .cpu_pixel_shift        (w_cpu_pixel_shift),
        .vid_pixel_x            (w_vid_pixel_x),
        .vid_pixel_y            (w_vid_pixel_y),
        .vid_pixel_brightness   (w_vid_pixel_brightness),
        .vid_pixel_shift        (w_vid_pixel_shift)
    );

    // =========================================================================
    // INPUT HANDLING (ULX3S BUTTONS & SWITCHES)
    // =========================================================================
    wire [7:0] w_joystick_emu;
    wire [7:0] w_led_input_feedback;
    wire       w_p2_mode_active;
    wire       w_single_player;

    ulx3s_input #(
        .CLK_FREQ    (C_PIXEL_CLK_FREQ),
        .DEBOUNCE_MS (10)
    ) u_input (
        .i_clk            (clk_pixel),
        .i_rst_n          (rst_pixel_n),
        .i_btn_n          (btn),
        .i_sw             (sw),
        .o_joystick_emu   (w_joystick_emu),
        .o_led_feedback   (w_led_input_feedback),
        .o_p2_mode_active (w_p2_mode_active),
        .o_single_player  (w_single_player)
    );

    // =========================================================================
    // VIDEO TIMING GENERATION (clk_pixel domain)
    // =========================================================================
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

    // VBlank signal for CPU synchronization
    assign w_vid_vblank = (r_v_counter < `v_visible_offset);

    // =========================================================================
    // PDP-1 CPU INTEGRATION (clk_cpu domain)
    // =========================================================================
    // CPU provides pixel_shift timing signal needed by test_sinus module.
    // -------------------------------------------------------------------------

    // CPU <-> Memory interface signals (clk_cpu domain)
    wire [11:0] w_cpu_mem_addr;
    wire [17:0] w_cpu_mem_data_out;
    wire [17:0] w_cpu_mem_data_in;
    wire        w_cpu_mem_we;

    // CPU output signals (clk_cpu domain)
    wire [17:0] w_cpu_ac;
    wire [17:0] w_cpu_io;
    wire [11:0] w_cpu_pc;
    wire [31:0] w_cpu_bus_out;

    // CPU debug outputs (clk_cpu domain)
    wire [15:0] w_cpu_debug_instr_count;
    wire [15:0] w_cpu_debug_iot_count;
    wire        w_cpu_debug_running;
    wire [7:0]  w_cpu_debug_state;

    // Pixel debug outputs (clk_cpu domain)
    wire [31:0] w_cpu_debug_pixel_count;
    wire [9:0]  w_cpu_debug_pixel_x;
    wire [9:0]  w_cpu_debug_pixel_y;
    wire [2:0]  w_cpu_debug_pixel_brightness;

    // Typewriter signals
    wire [6:0]  w_typewriter_char_out;
    wire        w_typewriter_strobe_out;
    wire        w_typewriter_strobe_ack;

    // Paper tape signals
    wire        w_send_next_tape_char;

    // Gamepad input mapping
    wire [17:0] w_gamepad_in;
    assign w_gamepad_in = {
        w_joystick_emu[3],   // bit 17 - P1 CW
        w_joystick_emu[1],   // bit 16 - P1 CCW
        w_joystick_emu[2],   // bit 15 - P1 thrust
        w_joystick_emu[0],   // bit 14 - P1 fire
        10'b0,               // bits 13-4 unused
        w_joystick_emu[7],   // bit 3 - P2 CW
        w_joystick_emu[5],   // bit 2 - P2 CCW
        w_joystick_emu[6],   // bit 1 - P2 thrust
        w_joystick_emu[4]    // bit 0 - P2 fire
    };

    // Console switches for CPU control
    reg [7:0] r_start_pulse_counter;
    wire w_start_button_pulse;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_start_pulse_counter <= 8'd5;
        end else if (r_start_pulse_counter > 0) begin
            r_start_pulse_counter <= r_start_pulse_counter - 1'b1;
        end
    end

    assign w_start_button_pulse = (r_start_pulse_counter > 0);

    wire [10:0] w_console_switches;
    assign w_console_switches = {
        1'b0,                  // bit 10 - power switch
        1'b0,                  // bit 9 - single step
        1'b0,                  // bit 8 - single inst
        1'b0,                  // bit 7 - tape feed
        1'b0,                  // bit 6 - reader
        1'b0,                  // bit 5 - read in
        1'b0,                  // bit 4 - deposit
        1'b0,                  // bit 3 - examine
        1'b0,                  // bit 2 - continue
        1'b0,                  // bit 1 - stop
        w_start_button_pulse   // bit 0 - start
    };

    wire [17:0] w_test_word    = 18'b0;
    wire [17:0] w_test_address = 18'o4;

    // =========================================================================
    // CDC: DIP SWITCH SYNCHRONIZATION (External -> clk_cpu domain)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_sync_meta, r_sw_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_btn_sync_meta, r_btn_sync;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sw_sync_meta  <= 4'b0;
            r_sw_sync       <= 4'b0;
            r_btn_sync_meta <= 2'b0;
            r_btn_sync      <= 2'b0;
        end else begin
            r_sw_sync_meta <= sw;
            r_sw_sync      <= r_sw_sync_meta;
            r_btn_sync_meta <= ~btn[5:4];
            r_btn_sync      <= r_btn_sync_meta;
        end
    end

    wire [5:0] w_sense_switches = {r_btn_sync, r_sw_sync[3:2], 1'b1, r_sw_sync[0]};

    // =========================================================================
    // PDP-1 MAIN RAM (4096 x 18-bit, clk_cpu domain)
    // =========================================================================
    pdp1_main_ram u_main_ram (
        .address_a  (w_cpu_mem_addr),
        .clock_a    (clk_cpu),
        .data_a     (w_cpu_mem_data_out),
        .wren_a     (w_cpu_mem_we),
        .q_a        (w_cpu_mem_data_in),

        .address_b  (12'b0),
        .clock_b    (clk_cpu),
        .data_b     (18'b0),
        .wren_b     (1'b0),
        .q_b        ()
    );

    // =========================================================================
    // PDP-1 CPU (clk_cpu domain)
    // =========================================================================
    pdp1_cpu u_cpu (
        .clk                    (clk_cpu),
        .rst                    (~rst_cpu_n),

        .MEM_ADDR               (w_cpu_mem_addr),
        .DI                     (w_cpu_mem_data_in),
        .MEM_BUFF               (w_cpu_mem_data_out),
        .WRITE_ENABLE           (w_cpu_mem_we),

        .AC                     (w_cpu_ac),
        .IO                     (w_cpu_io),
        .PC                     (w_cpu_pc),
        .BUS_out                (w_cpu_bus_out),

        .gamepad_in             (w_gamepad_in),

        .pixel_x_out            (w_cpu_pixel_x),
        .pixel_y_out            (w_cpu_pixel_y),
        .pixel_brightness       (w_cpu_pixel_brightness),
        .pixel_shift_out        (w_cpu_pixel_shift),

        .typewriter_char_out    (w_typewriter_char_out),
        .typewriter_strobe_out  (w_typewriter_strobe_out),
        .typewriter_char_in     (6'b0),
        .typewriter_strobe_in   (1'b0),
        .typewriter_strobe_ack  (w_typewriter_strobe_ack),

        .send_next_tape_char    (w_send_next_tape_char),
        .is_char_available      (1'b0),
        .tape_rcv_word          (18'b0),

        .start_address          (12'o4),

        .hw_mul_enabled         (1'b1),
        .crt_wait               (1'b1),

        .console_switches       (w_console_switches),
        .test_word              (w_test_word),
        .test_address           (w_test_address),
        .sense_switches         (w_sense_switches),

        .debug_instr_count      (w_cpu_debug_instr_count),
        .debug_iot_count        (w_cpu_debug_iot_count),
        .debug_cpu_running      (w_cpu_debug_running),
        .debug_cpu_state        (w_cpu_debug_state),

        .debug_pixel_count      (w_cpu_debug_pixel_count),
        .debug_pixel_x          (w_cpu_debug_pixel_x),
        .debug_pixel_y          (w_cpu_debug_pixel_y),
        .debug_pixel_brightness (w_cpu_debug_pixel_brightness)
    );

    // =========================================================================
    // SINE TEST PATTERN GENERATOR (ALWAYS ACTIVE)
    // =========================================================================
    // Unlike top_pdp1.v, sine test is ALWAYS enabled (no SW[2] check).
    // Uses CPU DPY timing (pixel_shift) to maintain proper pipeline flow.
    // =========================================================================

    wire [9:0] w_sine_mux_x;
    wire [9:0] w_sine_mux_y;
    wire [2:0] w_sine_mux_brightness;
    wire       w_sine_valid;

    test_sinus u_test_sinus (
        .i_clk          (clk_cpu),
        .i_rst_n        (rst_cpu_n),
        .i_enable       (1'b1),             // ALWAYS enabled
        .i_pixel_shift  (w_cpu_pixel_shift),
        .o_x            (w_sine_mux_x),
        .o_y            (w_sine_mux_y),
        .o_brightness   (w_sine_mux_brightness),
        .o_valid        (w_sine_valid)
    );

    // =========================================================================
    // CDC: MULTI-BIT PIXEL DATA (clk_cpu -> clk_pixel)
    // =========================================================================
    // HOLD registers keep data stable for 8 CPU cycles for CDC crossing.
    // ALWAYS uses sine coordinates (no CPU/sine MUX like in top_pdp1.v).
    // =========================================================================
    reg [9:0]  r_pixel_x_hold;
    reg [9:0]  r_pixel_y_hold;
    reg [2:0]  r_pixel_brightness_hold;
    reg [3:0]  r_pixel_hold_counter;
    reg        r_pixel_hold_valid;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_pixel_x_hold          <= 10'd0;
            r_pixel_y_hold          <= 10'd0;
            r_pixel_brightness_hold <= 3'd0;
            r_pixel_hold_counter    <= 4'd0;
            r_pixel_hold_valid      <= 1'b0;
        end else begin
            if (w_cpu_pixel_shift && r_pixel_hold_counter == 0) begin
                // Latch SINE coordinates (always, no CPU coordinates)
                r_pixel_x_hold          <= w_sine_mux_x;
                r_pixel_y_hold          <= w_sine_mux_y;
                r_pixel_brightness_hold <= w_sine_mux_brightness;
                r_pixel_hold_counter    <= 4'd8;    // Hold 8 CPU cycles
                r_pixel_hold_valid      <= 1'b1;
            end else if (r_pixel_hold_counter > 0) begin
                r_pixel_hold_counter <= r_pixel_hold_counter - 1'b1;
                if (r_pixel_hold_counter == 1)
                    r_pixel_hold_valid <= 1'b0;
            end
        end
    end

    // Map HOLD outputs to generic pixel signals
    wire [9:0] w_test_pixel_x     = r_pixel_x_hold;
    wire [9:0] w_test_pixel_y     = r_pixel_y_hold;
    wire [2:0] w_test_brightness  = r_pixel_brightness_hold;
    wire       w_test_pixel_avail = r_pixel_hold_valid;

    // =========================================================================
    // CDC: PIXEL VALID SYNCHRONIZATION (clk_cpu -> clk_pixel)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_pixel_avail_sync;
    reg [9:0] r_pixel_x_sync;
    reg [9:0] r_pixel_y_sync;
    reg [2:0] r_brightness_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_avail_sync <= 3'b0;
            r_pixel_x_sync     <= 10'd240;
            r_pixel_y_sync     <= 10'd240;
            r_brightness_sync  <= 3'b0;
        end else begin
            // 3-stage sync for metastability protection
            r_pixel_avail_sync <= {r_pixel_avail_sync[1:0], w_test_pixel_avail};

            // Latch coordinates on rising edge detection
            if (r_pixel_avail_sync[1] && !r_pixel_avail_sync[2]) begin
                r_pixel_x_sync    <= w_test_pixel_x;
                r_pixel_y_sync    <= w_test_pixel_y;
                r_brightness_sync <= w_test_brightness;
            end
        end
    end

    // Synchronized pixel_available signal
    wire w_pixel_avail_synced = r_pixel_avail_sync[1] && !r_pixel_avail_sync[2];
    wire [9:0] w_pixel_x_sync    = r_pixel_x_sync;
    wire [9:0] w_pixel_y_sync    = r_pixel_y_sync;
    wire [2:0] w_brightness_sync = r_brightness_sync;

    // =========================================================================
    // CRT PHOSPHOR DISPLAY EMULATION (clk_pixel domain)
    // =========================================================================
    wire [7:0] w_crt_r, w_crt_g, w_crt_b;

    // CRT debug signals
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

    pdp1_vga_crt u_crt_display
    (
        .i_clk              (clk_pixel),
        .i_rst_n            (rst_pixel_n),

        .i_h_counter        (r_h_counter),
        .i_v_counter        (r_v_counter),

        .o_red              (w_crt_r),
        .o_green            (w_crt_g),
        .o_blue             (w_crt_b),

        // Pixel input (CDC synchronized)
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
    wire w_vga_hsync, w_vga_vsync, w_vga_de, w_vga_blank;

    assign w_vga_hsync = (r_h_counter >= `h_front_porch) &&
                         (r_h_counter <  `h_front_porch + `h_sync_pulse) ? 1'b0 : 1'b1;
    assign w_vga_vsync = (r_v_counter >= `v_front_porch) &&
                         (r_v_counter <  `v_front_porch + `v_sync_pulse) ? 1'b0 : 1'b1;
    assign w_vga_de    = (r_h_counter >= `h_visible_offset) &&
                         (r_v_counter >= `v_visible_offset);
    assign w_vga_blank = ~w_vga_de;

    // =========================================================================
    // VGA RGB OUTPUT (Direct CRT output, no test pattern switching)
    // =========================================================================
    wire [7:0] w_vga_r = w_crt_r;
    wire [7:0] w_vga_g = w_crt_g;
    wire [7:0] w_vga_b = w_crt_b;

    // =========================================================================
    // HDMI OUTPUT (VGA -> DVID/TMDS CONVERSION)
    // =========================================================================
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
    // FAKE DIFFERENTIAL OUTPUT (ECP5 DDR primitives)
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
    // DEBUG: LED INDICATORS
    // =========================================================================
    reg [24:0] r_led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_led_divider <= 25'd0;
        else
            r_led_divider <= r_led_divider + 1'b1;
    end

    // Latch activity signals for human visibility
    reg r_pixel_valid_seen;
    reg r_rowbuff_write_seen;
    reg r_inside_visible_seen;
    reg r_pixel_to_rowbuff_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_valid_seen      <= 1'b0;
            r_rowbuff_write_seen    <= 1'b0;
            r_inside_visible_seen   <= 1'b0;
            r_pixel_to_rowbuff_seen <= 1'b0;
        end else begin
            if (r_led_divider[24]) begin
                r_pixel_valid_seen      <= 1'b0;
                r_rowbuff_write_seen    <= 1'b0;
                r_inside_visible_seen   <= 1'b0;
                r_pixel_to_rowbuff_seen <= 1'b0;
            end else begin
                if (w_pixel_avail_synced)
                    r_pixel_valid_seen <= 1'b1;
                if (w_crt_debug_rowbuff_wren)
                    r_rowbuff_write_seen <= 1'b1;
                if (w_crt_debug_inside_visible)
                    r_inside_visible_seen <= 1'b1;
                if (w_crt_debug_pixel_to_rowbuff)
                    r_pixel_to_rowbuff_seen <= 1'b1;
            end
        end
    end

    // CPU clock enable synchronization
    reg r_cpu_clk_seen;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_cpu_clk_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_clk_seen <= 1'b0;
            r_cpu_clk_sync <= 2'b0;
        end else begin
            r_cpu_clk_sync <= {r_cpu_clk_sync[0], w_clk_cpu_en};
            if (r_led_divider[24])
                r_cpu_clk_seen <= 1'b0;
            else if (r_cpu_clk_sync[1])
                r_cpu_clk_seen <= 1'b1;
        end
    end

    // LED assignments: CPU state and status
    assign led[4:0] = w_cpu_debug_state[4:0];
    assign led[5] = ~rst_cpu_n;
    assign led[6] = w_cpu_debug_running;
    assign led[7] = w_pll_locked;

    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
    reg        r_cpu_frame_tick;
    reg [10:0] r_cpu_prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_frame_tick      <= 1'b0;
            r_cpu_prev_v_counter  <= 11'd0;
        end else begin
            r_cpu_prev_v_counter <= r_v_counter;
            r_cpu_frame_tick <= (r_v_counter == 11'd0) && (r_cpu_prev_v_counter != 11'd0);
        end
    end

    serial_debug #(
        .CLK_FREQ(C_PIXEL_CLK_FREQ)
    ) u_serial_debug (
        .i_clk                (clk_pixel),
        .i_rst_n              (rst_pixel_n),
        .i_enable             (w_single_player),
        .i_frame_tick         (r_cpu_frame_tick),
        .i_angle              (w_cpu_pc[7:0]),
        .i_pixel_x            (w_sine_mux_x),
        .i_pixel_y            (w_sine_mux_y),
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
        .i_cpu_state          (w_cpu_debug_state),
        // Pixel Debug
        .i_pixel_count        (w_cpu_debug_pixel_count),
        .i_pixel_debug_x      (w_cpu_debug_pixel_x),
        .i_pixel_debug_y      (w_cpu_debug_pixel_y),
        .i_pixel_brightness   (w_cpu_debug_pixel_brightness),
        .i_pixel_shift_out    (w_cpu_pixel_shift),
        .i_ring_buffer_wrptr  (w_crt_debug_ring_buffer_wrptr),
        .o_uart_tx            (ftdi_rxd)
    );

endmodule
