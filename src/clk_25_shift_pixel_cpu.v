// =============================================================================
// Clock Generator Wrapper using Emard's ecp5pll
// =============================================================================
// TASK-124: PLL configuration for ULX3S HDMI output
// TASK-200: Reduced resolution to 640x480@60Hz (timing fix)
// TASK-XXX: Upgrade to 1024x768@50Hz (Jelena Horvat)
// Author: Kosjenka Vukovic, REGOC team
// Date: 2026-02-01
//
// Uses Emard's ecp5pll module for automatic PLL parameter calculation.
// Source: https://github.com/emard/ulx3s-misc/blob/master/examples/ecp5pll/hdl/sv/ecp5pll.sv
//
// SPECIFICATIONS (TASK-XXX - New configuration 1024x768@50Hz):
// - Input clock: 25 MHz (ULX3S onboard oscillator)
// - out0 (clko):  255 MHz HDMI shift clock (5x pixel for DDR TMDS)
// - out1 (clks1): 51 MHz pixel clock (1024x768 @ 50Hz)
// - out2 (clks2): 5 MHz CPU clock directly (VCO 510 MHz / 102 = 5 MHz, within P&R max 5.87 MHz)
//
// TIMING PARAMETERS (1024x768 @ 50Hz):
// - H total: 1264 pixels (1024 visible + 240 blanking)
// - V total: 808 lines (768 visible + 40 blanking)
// - Frame rate: 51M / (1264*808) = 49.93 Hz
//
// WHY 50Hz INSTEAD OF 60Hz?
// - 60Hz requires 65 MHz pixel = 325 MHz shift clock (marginal for ECP5)
// - 50Hz uses 51 MHz pixel = 255 MHz shift clock (safely within 400 MHz limit)
// - ECP5-85F max frequency: ~550 MHz for speed grade -6
// - Safe limit for shift clock: ~400 MHz
// =============================================================================

module clk_25_shift_pixel_cpu
(
    input  wire clki,      // 25 MHz input clock
    output wire clko,      // 255 MHz HDMI shift clock (5x 51MHz pixel)
    output wire clks1,     // 51 MHz pixel clock (1024x768@50Hz)
    output wire clks2,     // 5 MHz CPU clock (direct from PLL)
    output wire locked     // PLL lock indicator
);

    wire [3:0] clocks;

    ecp5pll
    #(
        .in_hz      (25000000),     // 25 MHz input
        .out0_hz    (255000000),    // 255 MHz shift clock (HDMI DDR, 5x pixel)
        .out1_hz    (51000000),     // 51 MHz pixel clock (1024x768@50Hz)
        .out2_hz    (5000000),      // 5 MHz CPU clock directly from PLL (no prescaler needed)
        .out3_hz    (0)             // unused
    )
    pll_inst
    (
        .clk_i          (clki),
        .clk_o          (clocks),
        .reset          (1'b0),
        .standby        (1'b0),
        .phasesel       (2'b00),
        .phasedir       (1'b0),
        .phasestep      (1'b0),
        .phaseloadreg   (1'b0),
        .locked         (locked)
    );

    assign clko  = clocks[0];   // 255 MHz shift clock
    assign clks1 = clocks[1];   // 51 MHz pixel clock
    assign clks2 = clocks[2];   // 5 MHz CPU clock

endmodule
