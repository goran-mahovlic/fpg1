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
// TEST ANIMATION MODE:
//   - Define TEST_ANIMATION za "Orbital Spark" phosphor decay test
//   - Tocka kruzi po elipticnoj orbiti, phosphor decay stvara rep
//
// =============================================================================

// Uncomment to enable test animation mode
// `define TEST_ANIMATION

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
    output wire        wifi_gpio0,

    // ==== FTDI UART (Debug Serial Output) ====
    output wire        ftdi_rxd       // FPGA TX -> PC RX (pin L4)

`ifdef ESP32_OSD
    // ==== ESP32 SPI Interface (OSD) ====
    ,
    input  wire        esp32_spi_clk,
    input  wire        esp32_spi_mosi,
    output wire        esp32_spi_miso,
    input  wire        esp32_spi_cs_n,
    output wire        esp32_osd_irq,
    input  wire        esp32_ready
`endif
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

            if (h_counter >= `h_line_timing - 1) begin
                h_counter <= 11'b0;
                v_counter <= v_counter + 1'b1;

                if (v_counter >= `v_line_timing - 1) begin
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

`ifdef TEST_ANIMATION
    // =========================================================================
    // TEST ANIMATION MODE: "Orbital Spark"
    // =========================================================================
    // Tocka kruzi po elipticnoj orbiti, phosphor decay stvara "rep"
    // Dizajn: Git, Implementacija: Jelena Horvat

    // Frame tick generator - pulse na pocetku svakog frame-a
    reg frame_tick;
    reg [10:0] prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            frame_tick <= 1'b0;
            prev_v_counter <= 11'd0;
        end else begin
            prev_v_counter <= v_counter;
            // Detect start of new frame (vblank start)
            frame_tick <= (v_counter == 11'd0) && (prev_v_counter != 11'd0);
        end
    end

    // Test animation outputs
    wire [9:0] anim_pixel_x;
    wire [9:0] anim_pixel_y;
    wire [2:0] anim_brightness;
    wire       anim_pixel_valid;
    wire [7:0] anim_debug_angle;

    test_animation test_anim_inst (
        .clk              (clk_pixel),
        .rst_n            (rst_pixel_n),
        .frame_tick       (frame_tick),
        .pixel_x          (anim_pixel_x),
        .pixel_y          (anim_pixel_y),
        .pixel_brightness (anim_brightness),
        .pixel_valid      (anim_pixel_valid),
        .debug_angle      (anim_debug_angle)
    );

    // Use animation outputs
    wire [9:0] test_pixel_x = anim_pixel_x;
    wire [9:0] test_pixel_y = anim_pixel_y;
    wire [2:0] test_brightness = anim_brightness;
    wire       test_pixel_avail = anim_pixel_valid;

`else
    // =========================================================================
    // ORIGINAL DIAGONAL LINE TEST PATTERN
    // =========================================================================
    // Test pattern za CRT - placeholder dok nema CPU-a
    // Generira jednostavnu dijagonalnu liniju za debug
    // Koordinate: 0-479 za vidljivo podrucje na 640x480 ekranu
    reg [9:0] test_pixel_x;
    reg [9:0] test_pixel_y;
    reg [2:0] test_brightness;
    reg       test_pixel_avail;

    // Jednostavan test: crtaj dijagonalnu liniju od (0,0) do (479,479)
    // Zatim vertikalne linije na X=100, 200, 300, 400
    reg [19:0] test_counter;
    reg [9:0]  line_pos;      // Pozicija na liniji (0-479)

    always @(posedge clk_cpu) begin
        if (!rst_cpu_n) begin
            test_counter <= 20'b0;
            line_pos <= 10'd0;
            test_pixel_x <= 10'd0;
            test_pixel_y <= 10'd0;
            test_brightness <= 3'b111;  // Maksimalna svjetlina
            test_pixel_avail <= 1'b0;
        end else begin
            test_counter <= test_counter + 1'b1;
            test_pixel_avail <= 1'b0;

            // Svaki 32 ciklusa emitira novi pixel (brzo za vidljiv efekt)
            if (test_counter[4:0] == 5'b0) begin
                // Dijagonalna linija: X = Y = line_pos
                test_pixel_x <= line_pos;
                test_pixel_y <= line_pos;
                test_brightness <= 3'b111;  // Puna svjetlina
                test_pixel_avail <= 1'b1;

                // Inkrementiraj poziciju, wrap na 480
                if (line_pos >= 10'd479)
                    line_pos <= 10'd0;
                else
                    line_pos <= line_pos + 1'b1;
            end
        end
    end
`endif

`ifdef TEST_ANIMATION
    // =========================================================================
    // TEST ANIMATION: No CDC needed (already in clk_pixel domain)
    // =========================================================================
    // test_animation modul vec radi u clk_pixel domeni, nema potrebe za CDC
    wire [9:0] pixel_x_sync = test_pixel_x;
    wire [9:0] pixel_y_sync = test_pixel_y;
    wire [2:0] brightness_sync = test_brightness;
    wire pixel_avail_synced = test_pixel_avail;

`else
    // =========================================================================
    // FIX B: CDC SINKRONIZACIJA ZA pixel_available
    // =========================================================================
    // pixel_available dolazi iz clk_cpu domene, treba sinkronizirati u clk_pixel
    reg [2:0] pixel_avail_sync;  // 3-stage synchronizer
    reg [9:0] pixel_x_sync, pixel_y_sync;
    reg [2:0] brightness_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            pixel_avail_sync <= 3'b0;
            pixel_x_sync <= 10'd240;
            pixel_y_sync <= 10'd240;
            brightness_sync <= 3'b0;
        end else begin
            // 3-stage sync za metastability protection
            pixel_avail_sync <= {pixel_avail_sync[1:0], test_pixel_avail};

            // Latch koordinate kada detektiramo rising edge
            if (pixel_avail_sync[1] && !pixel_avail_sync[2]) begin
                pixel_x_sync <= test_pixel_x;
                pixel_y_sync <= test_pixel_y;
                brightness_sync <= test_brightness;
            end
        end
    end

    // Sinhronizirani pixel_available signal (pulse u pixel clock domeni)
    wire pixel_avail_synced = pixel_avail_sync[1] && !pixel_avail_sync[2];
`endif

    pdp1_vga_crt crt_display
    (
        .clk                (clk_pixel),

        .horizontal_counter (h_counter),
        .vertical_counter   (v_counter),

        .red_out            (crt_r),
        .green_out          (crt_g),
        .blue_out           (crt_b),

        // Povezivanje s test patternom (CDC sinhronizirano!)
        .pixel_x_i          (pixel_x_sync),
        .pixel_y_i          (pixel_y_sync),
        .pixel_brightness   (brightness_sync),
        .variable_brightness(1'b1),
        .pixel_available    (pixel_avail_synced)
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
    // ESP32 OSD INTEGRATION
    // =========================================================================
    // OSD signals
`ifdef ESP32_OSD
    // =========================================================================
    // ESP32 OSD SIGNALS
    // =========================================================================
    wire [23:0] osd_video_out;
    wire        osd_de_out, osd_hs_out, osd_vs_out;
    wire [31:0] osd_status;
    wire [15:0] osd_joystick_0, osd_joystick_1;

    // Video input to OSD (CRT output)
    wire [23:0] crt_video_in = {crt_r, crt_g, crt_b};

    // Pixel coordinates for OSD
    wire [11:0] pixel_x = (h_counter >= `h_visible_offset) ?
                          (h_counter - `h_visible_offset) : 12'd0;
    wire [11:0] pixel_y = (v_counter >= `v_visible_offset) ?
                          (v_counter - `v_visible_offset) : 12'd0;

    esp32_osd #(
        .OSD_COLOR    (3'd4),       // Blue OSD color
        .OSD_X_OFFSET (12'd192),    // Centered for 640x480
        .OSD_Y_OFFSET (12'd176)
    ) esp32_osd_inst (
        .clk_sys      (clk_cpu),
        .clk_video    (clk_pixel),
        .rst_n        (rst_pixel_n),
        // ESP32 SPI interface
        .spi_clk      (esp32_spi_clk),
        .spi_mosi     (esp32_spi_mosi),
        .spi_miso     (esp32_spi_miso),
        .spi_cs_n     (esp32_spi_cs_n),
        .osd_irq      (esp32_osd_irq),
        .esp32_ready  (esp32_ready),
        // Video input
        .video_in     (crt_video_in),
        .de_in        (vga_de),
        .hs_in        (vga_hsync),
        .vs_in        (vga_vsync),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        // Video output
        .video_out    (osd_video_out),
        .de_out       (osd_de_out),
        .hs_out       (osd_hs_out),
        .vs_out       (osd_vs_out),
        // Status
        .status       (osd_status),
        .joystick_0   (osd_joystick_0),
        .joystick_1   (osd_joystick_1)
    );
`endif

    // =========================================================================
    // VGA RGB OUTPUT SELECTION
    // =========================================================================
    // SW[3] = 0: CRT output (with OSD if enabled)
    // SW[3] = 1: Test pattern (debugging)
    wire [7:0] vga_r, vga_g, vga_b;

    // Test pattern za debug: jednostavni color bars
    wire [7:0] test_r = h_counter[7:0];
    wire [7:0] test_g = v_counter[7:0];
    wire [7:0] test_b = {h_counter[3:0], v_counter[3:0]};

`ifdef ESP32_OSD
    // OSD overlay output (when ESP32 OSD is enabled)
    wire [7:0] final_r = osd_video_out[23:16];
    wire [7:0] final_g = osd_video_out[15:8];
    wire [7:0] final_b = osd_video_out[7:0];
`else
    // Direct CRT output (no OSD)
    wire [7:0] final_r = crt_r;
    wire [7:0] final_g = crt_g;
    wire [7:0] final_b = crt_b;
`endif

    assign vga_r = sw[3] ? test_r : final_r;
    assign vga_g = sw[3] ? test_g : final_g;
    assign vga_b = sw[3] ? test_b : final_b;

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
    // DEBUG: LED INDICATORS (USPORENI ZA LJUDSKO OKO)
    // =========================================================================
    // LED debug - usporeni za ljudsko oko (1-2 Hz blink)
    // 25MHz / 2^24 = ~1.49 Hz

    reg [24:0] led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            led_divider <= 25'd0;
        else
            led_divider <= led_divider + 1'b1;
    end

    // Latch pixel_valid, frame_tick na usporeni clock za vidljivost
    reg pixel_valid_seen;
    reg frame_tick_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            pixel_valid_seen <= 1'b0;
            frame_tick_seen  <= 1'b0;
        end else begin
            // Reset na svaki slow clock tick
            if (led_divider == 25'd0) begin
                pixel_valid_seen <= 1'b0;
                frame_tick_seen  <= 1'b0;
            end else begin
                // Latch ako se dogodilo
                if (pixel_avail_synced)
                    pixel_valid_seen <= 1'b1;
`ifdef TEST_ANIMATION
                if (frame_tick)
                    frame_tick_seen <= 1'b1;
`endif
            end
        end
    end

    // LED[0] = heartbeat (clock radi) - blink na ~1.5Hz
    // LED[1] = pixel_valid signal (usporeno) - svijetli ako je bio aktivan
    // LED[2] = frame_tick (usporeno) - svijetli ako je bio frame tick
    // LED[3] = animation angle MSB (da vidimo da se mijenja)
    // LED[4] = h_counter overflow (MSB)
    // LED[5] = v_counter overflow (MSB)
    // LED[6] = PLL locked (konstantno ako je OK)
    // LED[7] = rst_pixel_n (mora biti HIGH ako reset nije aktivan)

`ifdef TEST_ANIMATION
    assign led[0] = led_divider[24];                    // Heartbeat ~1.5Hz
    assign led[1] = pixel_valid_seen;                   // Pixel valid seen
    assign led[2] = frame_tick_seen;                    // Frame tick seen
    assign led[3] = anim_debug_angle[7];                // Animation angle MSB
    assign led[4] = h_counter[10];                      // H counter MSB
    assign led[5] = v_counter[10];                      // V counter MSB
    assign led[6] = pll_locked;                         // PLL locked
    assign led[7] = rst_pixel_n;                        // Reset released
`else
    // Original LED assignments when not in TEST_ANIMATION mode
    assign led[7]   = pll_locked;
    assign led[6]   = single_player;
    assign led[5]   = p2_mode_active;
    assign led[4]   = sw[3];
    assign led[3:0] = joystick_emu[3:0];
`endif

    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
`ifdef TEST_ANIMATION
    // Collect LED status for debug output
    wire [7:0] debug_led_status = {
        rst_pixel_n,           // LED[7]
        pll_locked,            // LED[6]
        v_counter[10],         // LED[5]
        h_counter[10],         // LED[4]
        anim_debug_angle[7],   // LED[3]
        frame_tick_seen,       // LED[2]
        pixel_valid_seen,      // LED[1]
        led_divider[24]        // LED[0]
    };

    serial_debug serial_debug_inst (
        .clk          (clk_pixel),
        .rst_n        (rst_pixel_n),
        .frame_tick   (frame_tick),
        .angle        (anim_debug_angle),
        .pixel_x      (anim_pixel_x),
        .pixel_y      (anim_pixel_y),
        .pixel_valid  (anim_pixel_valid),
        .led_status   (debug_led_status),
        .uart_tx_pin  (ftdi_rxd)
    );
`else
    // Kada nije TEST_ANIMATION, drzi UART TX high (idle)
    assign ftdi_rxd = 1'b1;
`endif

endmodule
