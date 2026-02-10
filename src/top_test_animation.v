//==============================================================================
// Module:      top_test_animation
// Description: Standalone top-level for "Orbital Spark" test animation on ULX3S
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
//   - clk_shift  : 255 MHz - HDMI DDR serializer (5x pixel clock)
//   - clk_pixel  :  51 MHz - VGA timing (1024x768@50Hz) + all logic
//
// NOTE: This is a simplified version of top_pdp1.v for testing purposes.
//       Runs entirely in clk_pixel domain - NO CDC REQUIRED!
//       No CPU, no RAM, no CDC logic - just animation + CRT display.
//
//==============================================================================

`include "definitions.v"

module top_test_animation
(
    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    // SW[0] = unused
    // SW[1] = Serial debug enable (ON=enabled, OFF=disabled)
    // SW[2] = unused
    // SW[3] = Test pattern output (ON=color bars, OFF=CRT)
    input  wire [3:0]  sw,

    // ==== LED Indicators ====
    output wire [7:0]  led,

    // ==== HDMI Output (GPDI differential pairs) ====
    output wire [3:0]  gpdi_dp,        // TMDS positive (active)
    output wire [3:0]  gpdi_dn,        // TMDS negative (active)

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0,

    // ==== FTDI UART (Debug Serial Output) ====
    output wire        ftdi_rxd,       // FPGA TX -> PC RX

    // ==== GPDI Control Pins (HDMI Hot Plug Detect) ====
    output wire        gpdi_scl,       // I2C SCL - drive HIGH for DDC wake-up
    input  wire        gpdi_hpd        // HDMI HPD from monitor (active-high)
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)
    localparam C_PIXEL_CLK_FREQ = 51_000_000;  // 51 MHz pixel clock

    // =========================================================================
    // ESP32 KEEP-ALIVE & HDMI DDC
    // =========================================================================
    assign wifi_gpio0 = btn[0];  // HIGH prevents ESP32 reboot
    assign gpdi_scl = 1'b1;      // DDC wake-up

    // =========================================================================
    // CLOCK GENERATION (PLL) - 1024x768@50Hz Video Mode
    // =========================================================================
    wire clk_shift;     // 255 MHz HDMI shift clock
    wire clk_pixel;     // 51 MHz pixel clock
    wire clk_cpu;       // 51 MHz (unused, but PLL provides it)
    wire w_pll_locked;

    clk_25_shift_pixel_cpu u_pll
    (
        .clki   (clk_25mhz),
        .clko   (clk_shift),
        .clks1  (clk_pixel),
        .clks2  (clk_cpu),       // Unused but generated
        .locked (w_pll_locked)
    );

    // =========================================================================
    // RESET SYNCHRONIZATION (clk_pixel domain only)
    // =========================================================================
    // Simple 2-stage synchronizer with async assert, sync deassert
    reg [1:0] r_rst_sync;
    wire rst_pixel_n;

    always @(posedge clk_pixel or negedge btn[0]) begin
        if (!btn[0]) begin
            r_rst_sync <= 2'b00;
        end else begin
            r_rst_sync <= {r_rst_sync[0], w_pll_locked};
        end
    end

    assign rst_pixel_n = r_rst_sync[1];

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

    // =========================================================================
    // FRAME TICK GENERATOR
    // =========================================================================
    // Single-cycle pulse at start of each frame (vblank transition)
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

    // =========================================================================
    // TEST ANIMATION: "Orbital Spark" (clk_pixel domain)
    // =========================================================================
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

    // =========================================================================
    // CRT PHOSPHOR DISPLAY EMULATION (clk_pixel domain)
    // =========================================================================
    // No CDC needed - animation outputs directly to CRT module
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

        // Pixel input from animation (NO CDC - same clock domain!)
        .i_pixel_x          (w_anim_pixel_x),
        .i_pixel_y          (w_anim_pixel_y),
        .i_pixel_brightness (w_anim_brightness),
        .i_variable_brightness(1'b1),
        .i_pixel_valid      (w_anim_pixel_valid),

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
    // VGA RGB OUTPUT SELECTION
    // =========================================================================
    // SW[3] = 0: CRT output
    // SW[3] = 1: Test pattern (color bars)
    wire [7:0] w_vga_r, w_vga_g, w_vga_b;

    // Test pattern for debug: simple gradient color bars
    wire [7:0] w_test_r = r_h_counter[7:0];
    wire [7:0] w_test_g = r_v_counter[7:0];
    wire [7:0] w_test_b = {r_h_counter[3:0], r_v_counter[3:0]};

    assign w_vga_r = sw[3] ? w_test_r : w_crt_r;
    assign w_vga_g = sw[3] ? w_test_g : w_crt_g;
    assign w_vga_b = sw[3] ? w_test_b : w_crt_b;

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
    // LED INDICATORS
    // =========================================================================
    reg [24:0] r_led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_led_divider <= 25'd0;
        else
            r_led_divider <= r_led_divider + 1'b1;
    end

    // Latch activity signals
    reg r_pixel_valid_seen;
    reg r_frame_tick_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_valid_seen <= 1'b0;
            r_frame_tick_seen  <= 1'b0;
        end else begin
            if (r_led_divider[24]) begin
                r_pixel_valid_seen <= 1'b0;
                r_frame_tick_seen  <= 1'b0;
            end else begin
                if (w_anim_pixel_valid)
                    r_pixel_valid_seen <= 1'b1;
                if (r_frame_tick)
                    r_frame_tick_seen <= 1'b1;
            end
        end
    end

    // LED assignments:
    // LED[0] = heartbeat (clk_pixel running)
    // LED[1] = frame tick seen
    // LED[2] = pixel valid seen
    // LED[3] = animation angle bit (movement indicator)
    // LED[4] = VGA hsync (rapid blink)
    // LED[5] = VGA vsync (~50Hz blink)
    // LED[6] = PLL locked
    // LED[7] = reset released
    assign led[0] = r_led_divider[24];
    assign led[1] = r_frame_tick_seen;
    assign led[2] = r_pixel_valid_seen;
    assign led[3] = w_anim_debug_angle[4];
    assign led[4] = w_vga_hsync;
    assign led[5] = w_vga_vsync;
    assign led[6] = w_pll_locked;
    assign led[7] = rst_pixel_n;

    // =========================================================================
    // SERIAL DEBUG OUTPUT
    // =========================================================================
    serial_debug #(
        .CLK_FREQ(C_PIXEL_CLK_FREQ)
    ) u_serial_debug (
        .i_clk                (clk_pixel),
        .i_rst_n              (rst_pixel_n),
        .i_enable             (sw[1]),              // SW[1] enables serial debug
        .i_frame_tick         (r_frame_tick),
        .i_angle              (w_anim_debug_angle),
        .i_pixel_x            (w_anim_pixel_x),
        .i_pixel_y            (w_anim_pixel_y),
        .i_pixel_valid        (w_anim_pixel_valid),
        .i_led_status         (led),
        // CRT Pipeline Debug
        .i_pixel_avail_synced (w_anim_pixel_valid),
        .i_crt_wren           (w_crt_debug_wren),
        .i_crt_write_ptr      (w_crt_debug_write_ptr),
        .i_crt_read_ptr       (w_crt_debug_read_ptr),
        .i_search_counter_msb (w_crt_debug_search_counter),
        .i_luma1              (w_crt_debug_luma1),
        .i_rowbuff_write_count(w_crt_debug_rowbuff_write_count),
        // CPU Debug (unused in animation mode)
        .i_cpu_pc             (12'd0),
        .i_cpu_instr_count    (16'd0),
        .i_cpu_iot_count      (16'd0),
        .i_cpu_running        (1'b0),
        .i_cpu_state          (8'd0),
        // Pixel Debug
        .i_pixel_count        (32'd0),
        .i_pixel_debug_x      (w_anim_pixel_x),
        .i_pixel_debug_y      (w_anim_pixel_y),
        .i_pixel_brightness   (w_anim_brightness),
        .i_pixel_shift_out    (w_anim_pixel_valid),
        .i_ring_buffer_wrptr  (w_crt_debug_ring_buffer_wrptr),
        .o_uart_tx            (ftdi_rxd)
    );

endmodule
