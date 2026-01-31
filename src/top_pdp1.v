// =============================================================================
// Top Level Module: PDP-1 for ULX3S v3.1.7
// =============================================================================
// TASK-196: Top Level Integration
// Autorica: Kosjenka Vukovic, FPGA Arhitektica, REGOC tim
// Datum: 2026-01-31
//
// INTEGRACIJA MODULA:
//   1. clk_25_shift_pixel_cpu.sv - PLL (25MHz -> 375/75/50 MHz)
//   2. clock_domain.v           - Prescaler, CDC, Reset Sequencing
//   3. pdp1_vga_crt.v           - CRT phosphor emulacija
//   4. ulx3s_input.v            - Kontrole (tipke, DIP switches)
//   5. pdp1_cpu_alu_div.v       - Divider za CPU
//   6. pdp1_terminal_*.v        - Terminal (typewriter) emulacija
//   7. vga2dvid.v, tmds_encoder.v, fake_differential.v - HDMI output
//
// HARDWARE: ULX3S v3.1.7 (ECP5-85F)
//   - 25 MHz oscilator na plocki
//   - HDMI output preko GPDI
//   - 7 tipki + 4 DIP prekidaca
//   - 8 LED indikatora
//
// CLOCK DOMENE (TASK-200: smanjena rezolucija za timing fix):
//   - clk_shift: 125 MHz (HDMI DDR serializer, 5x pixel)
//   - clk_pixel: 25 MHz  (640x480 @ 60Hz)
//   - clk_cpu:   50 MHz  (PDP-1 base clock, prescaled interno)
//
// =============================================================================

`include "definitions.v"

module top_pdp1
(
    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active low) ====
    input  wire [6:0]  btn,            // BTN[6:0] active low na plocki

    // ==== DIP Switches ====
    input  wire [3:0]  sw,             // SW[3:0]

    // ==== LED Indicators ====
    output wire [7:0]  led,            // LED[7:0]

    // ==== HDMI Output (GPDI) ====
    output wire [3:0]  gpdi_dp,        // Differential positive
    output wire [3:0]  gpdi_dn,        // Differential negative

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    parameter C_ddr = 1'b1;   // DDR mode za HDMI (5x pixel clock)

    // =========================================================================
    // ACTIVE LOW -> ACTIVE HIGH BUTTON CONVERSION
    // =========================================================================
    // Napomena: btn[0] je poseban (BTN_PWR), treba za ESP32 keep-alive
    // wifi_gpio0=1 sprjecava reboot plockice
    assign wifi_gpio0 = btn[0];

    // =========================================================================
    // CLOCK GENERATION (PLL) - TASK-200: 640x480@60Hz
    // =========================================================================
    wire clk_shift;     // 125 MHz HDMI shift clock (5x pixel)
    wire clk_pixel;     // 25 MHz pixel clock (640x480@60Hz)
    wire clk_cpu;       // 50 MHz CPU base clock
    wire pll_locked;    // PLL lock indicator

    clk_25_shift_pixel_cpu clock_instance
    (
        .clki   (clk_25mhz),
        .clko   (clk_shift),
        .clks1  (clk_pixel),
        .clks2  (clk_cpu),
        .locked (pll_locked)
    );

    // =========================================================================
    // CLOCK DOMAIN MANAGEMENT & RESET SEQUENCING
    // =========================================================================
    wire clk_cpu_slow;      // 1.79 MHz PDP-1 clock (unused for now)
    wire clk_cpu_en;        // Clock enable
    wire rst_pixel_n;       // Synchronized reset for pixel domain
    wire rst_cpu_n;         // Synchronized reset for CPU domain

    // CDC signals (placeholders - povezat cemo kad integriramo CPU)
    wire [11:0] cpu_fb_addr = 12'b0;
    wire [11:0] cpu_fb_data = 12'b0;
    wire        cpu_fb_we = 1'b0;
    wire [11:0] vid_fb_addr;
    wire [11:0] vid_fb_data;
    wire        vid_fb_we;
    wire        vid_vblank;
    wire        cpu_vblank;

    clock_domain clock_domain_inst
    (
        .clk_pixel      (clk_pixel),
        .clk_cpu_fast   (clk_cpu),
        .pll_locked     (pll_locked),
        .rst_n          (btn[0]),           // BTN[0] active low = reset

        .clk_cpu        (clk_cpu_slow),
        .clk_cpu_en     (clk_cpu_en),
        .rst_pixel_n    (rst_pixel_n),
        .rst_cpu_n      (rst_cpu_n),

        // CDC interface (za buducu CPU integraciju)
        .cpu_fb_addr    (cpu_fb_addr),
        .cpu_fb_data    (cpu_fb_data),
        .cpu_fb_we      (cpu_fb_we),
        .vid_fb_addr    (vid_fb_addr),
        .vid_fb_data    (vid_fb_data),
        .vid_fb_we      (vid_fb_we),
        .vid_vblank     (vid_vblank),
        .cpu_vblank     (cpu_vblank)
    );

    // =========================================================================
    // INPUT HANDLING (ULX3S BUTTONS & SWITCHES)
    // =========================================================================
    wire [7:0] joystick_emu;
    wire [7:0] led_input_feedback;
    wire       p2_mode_active;
    wire       single_player;

    ulx3s_input #(
        .CLK_FREQ    (25_000_000),   // Pixel clock frequency (640x480@60Hz)
        .DEBOUNCE_MS (10)
    ) input_inst (
        .clk            (clk_pixel),
        .rst_n          (rst_pixel_n),
        .btn_n          (btn),           // Active low from board
        .sw             (sw),
        .joystick_emu   (joystick_emu),
        .led_feedback   (led_input_feedback),
        .p2_mode_active (p2_mode_active),
        .single_player  (single_player)
    );

    // =========================================================================
    // VIDEO TIMING GENERATION
    // =========================================================================
    reg [10:0] h_counter;
    reg [10:0] v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            h_counter <= 11'b0;
            v_counter <= 11'b0;
        end else begin
            h_counter <= h_counter + 1'b1;

            if (h_counter == `h_line_timing) begin
                h_counter <= 11'b0;
                v_counter <= v_counter + 1'b1;

                if (v_counter == `v_line_timing) begin
                    v_counter <= 11'b0;
                end
            end
        end
    end

    // VSync signalization za vblank (za CPU sync)
    assign vid_vblank = (v_counter < `v_visible_offset);

    // =========================================================================
    // CRT PHOSPHOR DISPLAY EMULATION
    // =========================================================================
    wire [7:0] crt_r, crt_g, crt_b;

    // Test pattern za CRT - placeholder dok nema CPU-a
    // Generira jednostavan koordinatni dot u centru
    reg [9:0] test_pixel_x;
    reg [9:0] test_pixel_y;
    reg [2:0] test_brightness;
    reg       test_pixel_avail;

    // Jednostavan test: crtaj tocku koja se pomice
    reg [23:0] test_counter;
    always @(posedge clk_cpu) begin
        if (!rst_cpu_n) begin
            test_counter <= 24'b0;
            test_pixel_x <= 10'd512;
            test_pixel_y <= 10'd512;
            test_brightness <= 3'b111;
            test_pixel_avail <= 1'b0;
        end else begin
            test_counter <= test_counter + 1'b1;
            test_pixel_avail <= 1'b0;

            // Svaki 256 ciklusa emitira novu tocku u spirali
            if (test_counter[7:0] == 8'b0) begin
                test_pixel_x <= 10'd512 + {4'b0, test_counter[15:10]};
                test_pixel_y <= 10'd512 + {4'b0, test_counter[21:16]};
                test_brightness <= test_counter[10:8];
                test_pixel_avail <= 1'b1;
            end
        end
    end

    pdp1_vga_crt crt_display
    (
        .clk                (clk_pixel),

        .horizontal_counter (h_counter),
        .vertical_counter   (v_counter),

        .red_out            (crt_r),
        .green_out          (crt_g),
        .blue_out           (crt_b),

        // Povezivanje s test patternom (ili CPU u buducnosti)
        .pixel_x_i          (test_pixel_x),
        .pixel_y_i          (test_pixel_y),
        .pixel_brightness   (test_brightness),
        .variable_brightness(1'b1),
        .pixel_available    (test_pixel_avail)
    );

    // =========================================================================
    // VGA SYNC SIGNAL GENERATION
    // =========================================================================
    wire vga_hsync, vga_vsync, vga_de, vga_blank;

    assign vga_hsync = (h_counter >= `h_front_porch) &&
                       (h_counter <  `h_front_porch + `h_sync_pulse) ? 1'b0 : 1'b1;
    assign vga_vsync = (v_counter >= `v_front_porch) &&
                       (v_counter <  `v_front_porch + `v_sync_pulse) ? 1'b0 : 1'b1;
    assign vga_de    = (h_counter >= `h_visible_offset) &&
                       (v_counter >= `v_visible_offset);
    assign vga_blank = ~vga_de;

    // =========================================================================
    // VGA RGB OUTPUT SELECTION
    // =========================================================================
    // SW[3] = 0: CRT output
    // SW[3] = 1: Test pattern (debugging)
    wire [7:0] vga_r, vga_g, vga_b;

    // Test pattern za debug: jednostavni color bars
    wire [7:0] test_r = h_counter[7:0];
    wire [7:0] test_g = v_counter[7:0];
    wire [7:0] test_b = {h_counter[3:0], v_counter[3:0]};

    assign vga_r = sw[3] ? test_r : crt_r;
    assign vga_g = sw[3] ? test_g : crt_g;
    assign vga_b = sw[3] ? test_b : crt_b;

    // =========================================================================
    // HDMI OUTPUT (VGA -> DVID/TMDS CONVERSION)
    // =========================================================================
    wire [1:0] tmds_clock, tmds_red, tmds_green, tmds_blue;

    vga2dvid #(
        .C_ddr   (C_ddr),
        .C_depth (8)
    ) vga2dvid_inst (
        .clk_pixel  (clk_pixel),
        .clk_shift  (clk_shift),

        .in_red     (vga_r),
        .in_green   (vga_g),
        .in_blue    (vga_b),
        .in_hsync   (vga_hsync),
        .in_vsync   (vga_vsync),
        .in_blank   (vga_blank),

        .out_clock  (tmds_clock),
        .out_red    (tmds_red),
        .out_green  (tmds_green),
        .out_blue   (tmds_blue)
    );

    // =========================================================================
    // FAKE DIFFERENTIAL OUTPUT (ECP5 DDR primitives)
    // =========================================================================
    fake_differential #(
        .C_ddr (C_ddr)
    ) fake_diff_inst (
        .clk_shift (clk_shift),

        .in_clock  (tmds_clock),
        .in_red    (tmds_red),
        .in_green  (tmds_green),
        .in_blue   (tmds_blue),

        .out_p     (gpdi_dp),
        .out_n     (gpdi_dn)
    );

    // =========================================================================
    // LED STATUS INDICATORS
    // =========================================================================
    // LED[7]   = PLL locked
    // LED[6]   = Single player mode
    // LED[5]   = P2 mode active
    // LED[4]   = CRT test pattern mode
    // LED[3:0] = Player 1 controls feedback

    assign led[7]   = pll_locked;
    assign led[6]   = single_player;
    assign led[5]   = p2_mode_active;
    assign led[4]   = sw[3];
    assign led[3:0] = joystick_emu[3:0];

endmodule
