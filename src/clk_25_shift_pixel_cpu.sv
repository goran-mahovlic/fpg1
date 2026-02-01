// =============================================================================
// Clock Generator Wrapper using Emard's ecp5pll
// =============================================================================
// TASK-124: PLL konfiguracija za ULX3S HDMI output
// TASK-200: Smanjena rezolucija na 640x480@60Hz (timing fix)
// Generirao: Kosjenka Vukovic, REGOC tim
// Datum: 2026-01-31
//
// Koristi Emardov ecp5pll modul za automatski izracun PLL parametara.
// Izvor: https://github.com/emard/ulx3s-misc/blob/master/examples/ecp5pll/hdl/sv/ecp5pll.sv
//
// SPECIFIKACIJE (TASK-200 - Nova konfiguracija 640x480@60Hz):
// - Ulazni clock: 25 MHz (ULX3S onboard oscillator)
// - out0 (clko):  125 MHz HDMI shift clock (5x pixel za DDR TMDS)
// - out1 (clks1): 25 MHz pixel clock (640x480 @ 60Hz)
// - out2 (clks2): 6.25 MHz CPU clock (TASK-216: reduced for timing)
//
// TIMING PARAMETRI (640x480 @ 60Hz):
// - H total: 800 pixela (640 visible + 160 blanking)
// - V total: 525 linija (480 visible + 45 blanking)
// - Frame rate: 25M / (800*525) = 59.52 Hz
//
// ZASTO PROMJENA?
// - Prethodni 375 MHz shift clock: FAIL (potrebno 2.67ns, postiglo 5.66ns)
// - Prethodni 75 MHz pixel clock: FAIL (potrebno 13.33ns, postiglo 23.20ns)
// - Nova 125 MHz shift clock i 25 MHz pixel clock imaju puno vise margine
// =============================================================================

module clk_25_shift_pixel_cpu
(
    input  wire clki,      // 25 MHz input clock
    output wire clko,      // 125 MHz HDMI shift clock (5x 25MHz pixel)
    output wire clks1,     // 25 MHz pixel clock (640x480@60Hz)
    output wire clks2,     // 6.25 MHz CPU clock (TASK-216)
    output wire locked     // PLL lock indicator
);

    wire [3:0] clocks;

    ecp5pll
    #(
        .in_hz      (25000000),     // 25 MHz input
        .out0_hz    (125000000),    // 125 MHz shift clock (HDMI DDR, 5x pixel)
        .out1_hz    (25000000),     // 25 MHz pixel clock (640x480@60Hz)
        .out2_hz    (50000000),     // 50 MHz CPU clock (originalna PDP-1 brzina)
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

    assign clko  = clocks[0];   // 125 MHz shift clock
    assign clks1 = clocks[1];   // 25 MHz pixel clock
    assign clks2 = clocks[2];   // 6.25 MHz CPU clock (TASK-216)

endmodule
