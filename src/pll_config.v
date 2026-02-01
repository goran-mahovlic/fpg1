// =============================================================================
// PLL Configuration for ECP5 - ULX3S HDMI Video Output
// =============================================================================
// TASK-124: PLL konfiguracija za pixel clock
// Generirao: Kosjenka Vukovic, REGOC tim
// Datum: 2026-01-31
//
// VAZNO: Ovaj file sadrzi MANUALNU EHXPLLL instancijaciju.
//        Za jednostavniju upotrebu koristi clk_25_shift_pixel_cpu.sv
//        koji koristi Emardov ecp5pll wrapper s automatskim izracunom.
//
// PREPORUCENI PRISTUP:
//   1. clk_25_shift_pixel_cpu.sv - koristi ecp5pll (jednostavno, parametarsko)
//   2. pll_config.v (ovaj file) - manualna konfiguracija (ako treba precizna kontrola)
//
// Referenca: Emardov ecppll modul i ULX3S primjeri
// Izvor:     https://github.com/emard/ulx3s-misc/blob/master/examples/ecp5pll/hdl/sv/ecp5pll.sv
// Makefile:  fpg1_partial_emard/src/proj/lattice/ulx3s/universal_make/makefile.trellis
//
// SPECIFIKACIJE:
// - Ulazni clock: 25 MHz (ULX3S onboard oscillator)
// - Pixel clock: 75 MHz (za 1280x1024 @ 50Hz)
// - HDMI shift clock: 375 MHz (5x pixel clock za DDR TMDS)
// - CPU clock: 50 MHz (opcionalno)
//
// TIMING PARAMETRI (1280x1024 @ 50Hz):
// - H total: 1434 pixela (1280 visible + 154 blanking)
// - V total: 1042 linija (1024 visible + 18 blanking)
// - Pixel clock: 75 MHz -> frame rate = 75M / (1434*1042) = 50.2 Hz
//
// ALTERNATIVNA KONFIGURACIJA (1280x1024 @ 60Hz):
// - Pixel clock: 108 MHz
// - Shift clock: 540 MHz (NAPOMENA: blizu ECP5 limita!)
//
// ECP5 PLL SPECIFIKACIJE:
// - VCO raspon: 400-800 MHz (LFE5U-85F)
// - Maximum output: ~550 MHz za speed grade -6
// - Preporuceni VCO: 600-750 MHz za stabilnost
// =============================================================================

module pll_config (
    input  wire clki,      // 25 MHz input clock
    output wire clko,      // 375 MHz shift clock (CLKOP)
    output wire clks1,     // 75 MHz pixel clock (CLKOS)
    output wire clks2,     // 50 MHz CPU clock (CLKOS2)
    output wire locked     // PLL lock indicator
);

    // =========================================================================
    // PLL CALCULATION for 75 MHz pixel clock:
    // =========================================================================
    // ECP5 VCO mora biti u rasponu 400-800 MHz!
    //
    // Strategija: Koristiti VCO = 750 MHz, zatim podijeliti na izlazima
    //
    // f_VCO = f_in * CLKFB_DIV / CLKI_DIV
    // 750 MHz = 25 MHz * 30 / 1
    //
    // f_CLKOP = f_VCO / CLKOP_DIV = 750 / 2 = 375 MHz (shift clock for DDR)
    // f_CLKOS = f_VCO / CLKOS_DIV = 750 / 10 = 75 MHz (pixel clock)
    // f_CLKOS2 = f_VCO / CLKOS2_DIV = 750 / 15 = 50 MHz (CPU clock)
    //
    // Svi izlazi su tocni integer dijeljenja!
    // =========================================================================

    wire clkop_o, clkos_o, clkos2_o;

    (* ICP_CURRENT="12" *)
    (* LPF_RESISTOR="8" *)
    (* MFG_ENABLE_FILTEROPAMP="1" *)
    (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA       ("DISABLED"),
        .INTFB_WAKE       ("DISABLED"),
        .STDBY_ENABLE     ("DISABLED"),
        .DPHASE_SOURCE    ("DISABLED"),
        .OUTDIVIDER_MUXA  ("DIVA"),
        .OUTDIVIDER_MUXB  ("DIVB"),
        .OUTDIVIDER_MUXC  ("DIVC"),
        .OUTDIVIDER_MUXD  ("DIVD"),
        .CLKI_DIV         (1),          // Input divider: 25 MHz PFD
        .CLKOP_ENABLE     ("ENABLED"),
        .CLKOP_DIV        (2),          // 750 MHz / 2 = 375 MHz shift clock
        .CLKOP_CPHASE     (1),
        .CLKOP_FPHASE     (0),
        .CLKOS_ENABLE     ("ENABLED"),
        .CLKOS_DIV        (10),         // 750 MHz / 10 = 75 MHz pixel clock
        .CLKOS_CPHASE     (9),
        .CLKOS_FPHASE     (0),
        .CLKOS2_ENABLE    ("ENABLED"),
        .CLKOS2_DIV       (15),         // 750 MHz / 15 = 50 MHz CPU clock
        .CLKOS2_CPHASE    (14),
        .CLKOS2_FPHASE    (0),
        .CLKOS3_ENABLE    ("DISABLED"),
        .CLKOS3_DIV       (1),
        .CLKOS3_CPHASE    (0),
        .CLKOS3_FPHASE    (0),
        .CLKFB_DIV        (30),         // Feedback divider: 25*30=750 MHz VCO
        .FEEDBK_PATH      ("CLKOP")     // Use CLKOP for feedback
    ) pll_inst (
        .RST              (1'b0),
        .STDBY            (1'b0),
        .CLKI             (clki),
        .CLKOP            (clkop_o),
        .CLKOS            (clkos_o),
        .CLKOS2           (clkos2_o),
        .CLKOS3           (),
        .CLKFB            (clkop_o),    // Feedback from CLKOP
        .CLKINTFB         (),
        .PHASESEL0        (1'b0),
        .PHASESEL1        (1'b0),
        .PHASEDIR         (1'b1),
        .PHASESTEP        (1'b1),
        .PHASELOADREG     (1'b1),
        .PLLWAKESYNC      (1'b0),
        .ENCLKOP          (1'b0),
        .ENCLKOS          (1'b0),
        .ENCLKOS2         (1'b0),
        .ENCLKOS3         (1'b0),
        .LOCK             (locked)
    );

    assign clko  = clkop_o;   // 375 MHz shift clock
    assign clks1 = clkos_o;   // 75 MHz pixel clock
    assign clks2 = clkos2_o;  // 50 MHz CPU clock

endmodule


// =============================================================================
// ALTERNATIVE: 108 MHz Configuration for 1280x1024@60Hz
// =============================================================================
// NAPOMENA: 540 MHz shift clock je vrlo blizu ECP5 limita (~550 MHz za -6 speed)
// Preporuka: Koristiti 75 MHz verziju za stabilnost!
//
// Parametri za 108 MHz:
// VCO = 25 * 21.6 = 540 MHz (potreban fractional mode ili drugaciji ratio)
//
// Bolja opcija: VCO = 25 * 22 = 550 MHz (blizu limita!)
// CLKOP = 550 / 1 = 550 MHz shift (PREBLIZU LIMITA - NE PREPORUCUJEM)
// CLKOS = 550 / 5 = 110 MHz pixel (blizu 108 MHz)
//
// Za tocnih 108 MHz trebao bi:
// 108 * 5 = 540 MHz VCO
// 540 / 25 = 21.6 -> nemoguci integer ratio
//
// Alternativa s nižim VCO (dual PLL ili drugacija konfiguracija):
// Input 25 MHz -> 27 MHz intermediate -> 108 MHz pixel
// =============================================================================

module pll_config_108mhz (
    input  wire clki,      // 25 MHz input clock
    output wire clko,      // 540 MHz shift clock (CLKOP) - NEAR LIMIT!
    output wire clks1,     // 108 MHz pixel clock (CLKOS)
    output wire locked     // PLL lock indicator
);

    // =========================================================================
    // UPOZORENJE: Ova konfiguracija je na granici ECP5 specifikacija!
    // VCO = 540 MHz je blizu maksimuma za LFE5U-85F-6
    // Koristiti samo ako 75 MHz konfiguracija ne zadovoljava zahtjeve.
    // =========================================================================
    //
    // Calculation:
    // VCO = 25 * 108 / 5 = 540 MHz  (using CLKFB_DIV=108/5 is not integer!)
    //
    // Better approach: Use close approximation
    // VCO = 25 * 22 = 550 MHz
    // Pixel = 550 / 5 = 110 MHz (2% error from 108 MHz - usually acceptable)
    //
    // For exact 108 MHz, need: 25 * N / M = 540, where 540/5 = 108
    // N=108, M=5 -> but CLKFB_DIV max is typically 128, CLKI_DIV max ~128
    // So: CLKI_DIV=5, CLKFB_DIV=108 -> VCO = 25*108/5 = 540 MHz
    // =========================================================================

    wire clkop_o, clkos_o;

    EHXPLLL #(
        .PLLRST_ENA       ("DISABLED"),
        .INTFB_WAKE       ("DISABLED"),
        .STDBY_ENABLE     ("DISABLED"),
        .DPHASE_SOURCE    ("DISABLED"),
        .OUTDIVIDER_MUXA  ("DIVA"),
        .OUTDIVIDER_MUXB  ("DIVB"),
        .OUTDIVIDER_MUXC  ("DIVC"),
        .OUTDIVIDER_MUXD  ("DIVD"),
        .CLKI_DIV         (5),          // Input divider: 25/5 = 5 MHz PFD
        .CLKOP_ENABLE     ("ENABLED"),
        .CLKOP_DIV        (1),          // 540 MHz / 1 = 540 MHz shift clock
        .CLKOP_CPHASE     (0),
        .CLKOP_FPHASE     (0),
        .CLKOS_ENABLE     ("ENABLED"),
        .CLKOS_DIV        (5),          // 540 MHz / 5 = 108 MHz pixel clock
        .CLKOS_CPHASE     (0),
        .CLKOS_FPHASE     (0),
        .CLKOS2_ENABLE    ("DISABLED"),
        .CLKOS2_DIV       (1),
        .CLKOS2_CPHASE    (0),
        .CLKOS2_FPHASE    (0),
        .CLKOS3_ENABLE    ("DISABLED"),
        .CLKOS3_DIV       (1),
        .CLKOS3_CPHASE    (0),
        .CLKOS3_FPHASE    (0),
        .CLKFB_DIV        (108),        // Feedback div: 5MHz * 108 = 540 MHz VCO
        .FEEDBK_PATH      ("CLKOP")
    ) pll_inst (
        .RST              (1'b0),
        .STDBY            (1'b0),
        .CLKI             (clki),
        .CLKOP            (clkop_o),
        .CLKOS            (clkos_o),
        .CLKOS2           (),
        .CLKOS3           (),
        .CLKFB            (clkop_o),
        .CLKINTFB         (),
        .PHASESEL0        (1'b0),
        .PHASESEL1        (1'b0),
        .PHASEDIR         (1'b1),
        .PHASESTEP        (1'b1),
        .PHASELOADREG     (1'b1),
        .PLLWAKESYNC      (1'b0),
        .ENCLKOP          (1'b0),
        .ENCLKOS          (1'b0),
        .ENCLKOS2         (1'b0),
        .ENCLKOS3         (1'b0),
        .LOCK             (locked)
    );

    assign clko  = clkop_o;   // 540 MHz shift clock
    assign clks1 = clkos_o;   // 108 MHz pixel clock

endmodule
