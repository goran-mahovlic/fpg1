// =============================================================================
// Clock Generator Wrapper using Emard's ecp5pll
// =============================================================================
// TASK-124: PLL konfiguracija za ULX3S HDMI output
// TASK-200: Smanjena rezolucija na 640x480@60Hz (timing fix)
// TASK-XXX: Upgrade na 1024x768@50Hz (Jelena Horvat)
// Generirao: Kosjenka Vukovic, REGOC tim
// Datum: 2026-02-01
//
// Koristi Emardov ecp5pll modul za automatski izracun PLL parametara.
// Izvor: https://github.com/emard/ulx3s-misc/blob/master/examples/ecp5pll/hdl/sv/ecp5pll.sv
//
// SPECIFIKACIJE (TASK-XXX - Nova konfiguracija 1024x768@50Hz):
// - Ulazni clock: 25 MHz (ULX3S onboard oscillator)
// - out0 (clko):  255 MHz HDMI shift clock (5x pixel za DDR TMDS)
// - out1 (clks1): 51 MHz pixel clock (1024x768 @ 50Hz)
// - out2 (clks2): 50 MHz CPU clock (zadrzi originalnu PDP-1 brzinu)
//
// TIMING PARAMETRI (1024x768 @ 50Hz):
// - H total: 1264 pixela (1024 visible + 240 blanking)
// - V total: 808 linija (768 visible + 40 blanking)
// - Frame rate: 51M / (1264*808) = 49.93 Hz
//
// ZASTO 50Hz UMJESTO 60Hz?
// - 60Hz zahtijeva 65 MHz pixel = 325 MHz shift clock (marginalno za ECP5)
// - 50Hz koristi 51 MHz pixel = 255 MHz shift clock (sigurno unutar 400 MHz limita)
// - ECP5-85F max frekvencija: ~550 MHz za speed grade -6
// - Safe limit za shift clock: ~400 MHz
// =============================================================================

module clk_25_shift_pixel_cpu
(
    input  wire clki,      // 25 MHz input clock
    output wire clko,      // 255 MHz HDMI shift clock (5x 51MHz pixel)
    output wire clks1,     // 51 MHz pixel clock (1024x768@50Hz)
    output wire clks2,     // 50 MHz CPU clock (originalna PDP-1 brzina)
    output wire locked     // PLL lock indicator
);

    wire [3:0] clocks;

    ecp5pll
    #(
        .in_hz      (25000000),     // 25 MHz input
        .out0_hz    (255000000),    // 255 MHz shift clock (HDMI DDR, 5x pixel)
        .out1_hz    (51000000),     // 51 MHz pixel clock (1024x768@50Hz)
        .out2_hz    (51000000),     // 51 MHz CPU clock (isti kao pixel, PLL constraint)
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
    assign clks2 = clocks[2];   // 50 MHz CPU clock

endmodule
