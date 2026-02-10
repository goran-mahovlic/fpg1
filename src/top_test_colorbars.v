//==============================================================================
// Module:      top_test_colorbars
// Description: Minimal standalone test module for HDMI color bars output
//==============================================================================
// Author:      Jelena Kovacevic, FPGA Engineer, REGOC team
// Created:     2026-02-10
//
// Purpose:     Standalone HDMI test pattern generator for hardware validation.
//              Generates gradient color bars without CPU, CRT, or CDC logic.
//
// Hardware Target: ULX3S v3.1.7 (Lattice ECP5-85F)
//   - 25 MHz onboard oscillator
//   - HDMI output via GPDI differential pairs
//   - 8 LED indicators (heartbeat only)
//
// Clock Domains:
//   - clk_shift  : 255 MHz  - HDMI DDR serializer (5x pixel clock)
//   - clk_pixel  :  51 MHz  - VGA timing (1024x768@50Hz)
//
// Test Pattern:
//   - R channel: Horizontal gradient (h_counter[7:0])
//   - G channel: Vertical gradient (v_counter[7:0])
//   - B channel: Combined gradient ({h_counter[3:0], v_counter[3:0]})
//
//==============================================================================

`include "definitions.v"

module top_test_colorbars
(
    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    input  wire [3:0]  sw,             // SW[3:0] active-high (unused)

    // ==== LED Indicators ====
    output wire [7:0]  led,            // LED[7:0] active-high

    // ==== HDMI Output (GPDI differential pairs) ====
    output wire [3:0]  gpdi_dp,        // TMDS positive (active)
    output wire [3:0]  gpdi_dn,        // TMDS negative (active)

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0,     // HIGH prevents ESP32 reboot

    // ==== FTDI UART (unused in test mode) ====
    output wire        ftdi_rxd,       // FPGA TX -> PC RX

    // ==== GPDI Control Pins ====
    output wire        gpdi_scl,       // I2C SCL - drive HIGH for DDC wake-up
    input  wire        gpdi_hpd        // HDMI HPD from monitor (active-high)
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)

    // =========================================================================
    // ACTIVE-LOW -> ACTIVE-HIGH BUTTON CONVERSION
    // =========================================================================
    assign wifi_gpio0 = btn[0];  // Keep ESP32 alive

    // =========================================================================
    // HDMI HPD (Hot Plug Detect)
    // =========================================================================
    assign gpdi_scl = 1'b1;  // DDC wake-up

    // =========================================================================
    // UNUSED OUTPUTS
    // =========================================================================
    assign ftdi_rxd = 1'b1;  // UART idle (high)

    // =========================================================================
    // CLOCK GENERATION (PLL) - 1024x768@50Hz Video Mode
    // =========================================================================
    // Clock tree:
    //   clk_25mhz (input) -> PLL -> clk_shift (255 MHz, HDMI DDR serializer)
    //                           -> clk_pixel (51 MHz, VGA timing)
    // -------------------------------------------------------------------------
    wire clk_shift;     // 255 MHz HDMI shift clock (5x pixel for DDR)
    wire clk_pixel;     // 51 MHz pixel clock (1024x768@50Hz timing)
    wire clk_cpu;       // 51 MHz (unused, but PLL provides it)
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
    // RESET GENERATION (Synchronous Deassert)
    // =========================================================================
    // Simple reset based on PLL lock and button.
    // Uses 2-stage synchronizer for proper metastability handling.
    // -------------------------------------------------------------------------
    reg [1:0] r_rst_sync;
    wire rst_pixel_n;

    always @(posedge clk_pixel or negedge w_pll_locked) begin
        if (!w_pll_locked) begin
            r_rst_sync <= 2'b00;
        end else begin
            r_rst_sync <= {r_rst_sync[0], btn[0]};  // btn[0] active-low reset
        end
    end

    assign rst_pixel_n = r_rst_sync[1];

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
    // COLOR BARS TEST PATTERN (clk_pixel domain)
    // =========================================================================
    // Simple gradient pattern for HDMI output verification:
    //   R = horizontal position (creates vertical gradient bars)
    //   G = vertical position (creates horizontal gradient bars)
    //   B = combined (diagonal gradient effect)
    // -------------------------------------------------------------------------
    wire [7:0] w_test_r = r_h_counter[7:0];
    wire [7:0] w_test_g = r_v_counter[7:0];
    wire [7:0] w_test_b = {r_h_counter[3:0], r_v_counter[3:0]};

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

        .in_red     (w_test_r),
        .in_green   (w_test_g),
        .in_blue    (w_test_b),
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
    // LED HEARTBEAT (clk_pixel domain)
    // =========================================================================
    // Simple heartbeat indicator to confirm clock is running.
    // 51MHz / 2^25 = ~1.52 Hz blink rate
    // -------------------------------------------------------------------------
    reg [24:0] r_led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_led_divider <= 25'd0;
        else
            r_led_divider <= r_led_divider + 1'b1;
    end

    // LED assignment:
    //   LED[0] = heartbeat (blinks at ~1.5Hz)
    //   LED[6] = monitor connected (HPD)
    //   LED[7] = PLL locked
    assign led[0]   = r_led_divider[24];
    assign led[5:1] = 5'b0;
    assign led[6]   = gpdi_hpd;
    assign led[7]   = w_pll_locked;

endmodule
