// =============================================================================
// HDMI Test Pattern Top Module
// =============================================================================
// TASK-125: HDMI Test Pattern za ULX3S
// Autor: Jelena Horvat, REGOC tim
// Datum: 2026-01-31
//
// Prikazuje color bars test pattern na HDMI output.
// Koristi Emardove vga2dvid i tmds_encoder VHDL module.
//
// SPECIFIKACIJE:
// - Rezolucija: 640x480 @ 60Hz (25 MHz pixel clock)
// - Shift clock: 125 MHz (5x za DDR TMDS)
// - Pattern: 8 vertikalnih color bars (SMPTE style)
//
// ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE ACTIVE
// WHITE  YELLOW  CYAN  GREEN MAGENTA  RED   BLUE  BLACK
// =============================================================================

module test_pattern_top
(
    input  wire       clk_25mhz,      // 25 MHz input clock
    input  wire [6:0] btn,            // Buttons (active low for btn[0])
    output wire [7:0] led,            // LEDs for status
    output wire [3:0] gpdi_dp,        // HDMI positive diff pairs
    output wire [3:0] gpdi_dn,        // HDMI negative diff pairs
    output wire       wifi_gpio0      // Keep high to prevent ESP32 reset
);

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter C_ddr = 1'b1;           // Use DDR for TMDS (5x clock instead of 10x)

    // VGA 640x480 @ 60Hz timing parameters
    localparam H_VISIBLE    = 640;
    localparam H_FRONT      = 16;
    localparam H_SYNC       = 96;
    localparam H_BACK       = 48;
    localparam H_TOTAL      = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;  // 800

    localparam V_VISIBLE    = 480;
    localparam V_FRONT      = 10;
    localparam V_SYNC       = 2;
    localparam V_BACK       = 33;
    localparam V_TOTAL      = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;  // 525

    // =========================================================================
    // WiFi GPIO0 - keep high to prevent board reset
    // =========================================================================
    assign wifi_gpio0 = btn[0];

    // =========================================================================
    // Clock Generation using Emard's ecp5pll
    // =========================================================================
    // For 640x480@60Hz: pixel clock = 25.175 MHz (we use 25 MHz)
    // DDR TMDS shift clock = 5 * 25 = 125 MHz

    wire clk_shift;     // 125 MHz shift clock
    wire clk_pixel;     // 25 MHz pixel clock
    wire clk_locked;

    wire [3:0] clocks;

    ecp5pll
    #(
        .in_hz      (25000000),     // 25 MHz input
        .out0_hz    (125000000),    // 125 MHz shift clock (5x for DDR)
        .out1_hz    (25000000),     // 25 MHz pixel clock
        .out2_hz    (0),
        .out3_hz    (0)
    )
    pll_inst
    (
        .clk_i          (clk_25mhz),
        .clk_o          (clocks),
        .reset          (1'b0),
        .standby        (1'b0),
        .phasesel       (2'b00),
        .phasedir       (1'b0),
        .phasestep      (1'b0),
        .phaseloadreg   (1'b0),
        .locked         (clk_locked)
    );

    assign clk_shift = clocks[0];   // 125 MHz
    assign clk_pixel = clocks[1];   // 25 MHz

    // =========================================================================
    // LED Status Indicators
    // =========================================================================
    reg [25:0] counter;
    always @(posedge clk_pixel) begin
        counter <= counter + 1;
    end

    assign led[0] = clk_locked;         // PLL locked indicator
    assign led[1] = counter[24];        // Heartbeat (~1.5 Hz blink)
    assign led[7:2] = 6'b0;

    // =========================================================================
    // VGA Timing Generator
    // =========================================================================
    reg [9:0] h_count = 0;
    reg [9:0] v_count = 0;

    wire h_sync;
    wire v_sync;
    wire display_active;

    always @(posedge clk_pixel) begin
        if (h_count == H_TOTAL - 1) begin
            h_count <= 0;
            if (v_count == V_TOTAL - 1)
                v_count <= 0;
            else
                v_count <= v_count + 1;
        end
        else begin
            h_count <= h_count + 1;
        end
    end

    // Sync pulses (active low for VGA, active high for HDMI)
    assign h_sync = (h_count >= H_VISIBLE + H_FRONT) &&
                    (h_count < H_VISIBLE + H_FRONT + H_SYNC);
    assign v_sync = (v_count >= V_VISIBLE + V_FRONT) &&
                    (v_count < V_VISIBLE + V_FRONT + V_SYNC);

    // Display active area
    assign display_active = (h_count < H_VISIBLE) && (v_count < V_VISIBLE);

    // =========================================================================
    // Color Bars Pattern Generator
    // =========================================================================
    // 8 vertical bars: White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
    // Each bar is 80 pixels wide (640/8 = 80)

    reg [7:0] r_out, g_out, b_out;
    wire [2:0] bar_index;

    assign bar_index = h_count[9:7];  // Divide screen into 8 sections (bits 9:7 = 0-7)

    always @(posedge clk_pixel) begin
        if (display_active) begin
            case (bar_index)
                3'd0: begin r_out <= 8'hFF; g_out <= 8'hFF; b_out <= 8'hFF; end  // White
                3'd1: begin r_out <= 8'hFF; g_out <= 8'hFF; b_out <= 8'h00; end  // Yellow
                3'd2: begin r_out <= 8'h00; g_out <= 8'hFF; b_out <= 8'hFF; end  // Cyan
                3'd3: begin r_out <= 8'h00; g_out <= 8'hFF; b_out <= 8'h00; end  // Green
                3'd4: begin r_out <= 8'hFF; g_out <= 8'h00; b_out <= 8'hFF; end  // Magenta
                3'd5: begin r_out <= 8'hFF; g_out <= 8'h00; b_out <= 8'h00; end  // Red
                3'd6: begin r_out <= 8'h00; g_out <= 8'h00; b_out <= 8'hFF; end  // Blue
                3'd7: begin r_out <= 8'h00; g_out <= 8'h00; b_out <= 8'h00; end  // Black
            endcase
        end
        else begin
            r_out <= 8'h00;
            g_out <= 8'h00;
            b_out <= 8'h00;
        end
    end

    // =========================================================================
    // Pipeline sync and blank signals to match color output delay
    // =========================================================================
    reg h_sync_d, v_sync_d, blank_d;

    always @(posedge clk_pixel) begin
        h_sync_d <= h_sync;
        v_sync_d <= v_sync;
        blank_d  <= ~display_active;
    end

    // =========================================================================
    // VGA to DVID (HDMI) Encoder
    // =========================================================================
    // Using Verilog vga2dvid module (ported from Emard's VHDL)
    // - C_ddr = 1 (DDR mode - 5x pixel clock = 125 MHz)
    // - C_depth = 8 (8-bit color)

    wire [1:0] tmds_clock;
    wire [1:0] tmds_red;
    wire [1:0] tmds_green;
    wire [1:0] tmds_blue;

    vga2dvid
    #(
        .C_ddr          (C_ddr),
        .C_depth        (8)
    )
    vga2dvid_inst
    (
        .clk_pixel      (clk_pixel),
        .clk_shift      (clk_shift),
        .in_red         (r_out),
        .in_green       (g_out),
        .in_blue        (b_out),
        .in_hsync       (h_sync_d),
        .in_vsync       (v_sync_d),
        .in_blank       (blank_d),
        .out_clock      (tmds_clock),
        .out_red        (tmds_red),
        .out_green      (tmds_green),
        .out_blue       (tmds_blue)
    );

    // =========================================================================
    // TMDS Output with Fake Differential
    // =========================================================================
    fake_differential
    #(
        .C_ddr          (C_ddr)
    )
    fake_diff_inst
    (
        .clk_shift      (clk_shift),
        .in_clock       (tmds_clock),
        .in_red         (tmds_red),
        .in_green       (tmds_green),
        .in_blue        (tmds_blue),
        .out_p          (gpdi_dp),
        .out_n          (gpdi_dn)
    );

endmodule
