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
//   - clk_cpu:   6.25 MHz (PDP-1 base clock, TASK-216 reduced for timing)
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
    output wire        ftdi_rxd,      // FPGA TX -> PC RX (pin L4)

    // ==== GPDI Control Pins (HDMI HPD) ====
    output wire        gpdi_scl,      // I2C SCL - drive HIGH for HPD workaround
    input  wire        gpdi_hpd       // HDMI Hot Plug Detect from monitor (TASK-216)

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
    // HDMI HPD (TASK-216 FIX)
    // =========================================================================
    // HPD (Hot Plug Detect) je INPUT - monitor ga drzi HIGH kad je spojen.
    // FPGA cita HPD da zna je li monitor spojen i spreman.
    // gpdi_scl = HIGH konstantno za DDC wake-up.
    assign gpdi_scl = 1'b1;

    // TASK-216: HPD je sada INPUT - monitor pulls HIGH when connected
    wire monitor_connected = gpdi_hpd;

    // =========================================================================
    // CLOCK GENERATION (PLL) - TASK-200: 640x480@60Hz
    // =========================================================================
    wire clk_shift;     // 125 MHz HDMI shift clock (5x pixel)
    wire clk_pixel;     // 25 MHz pixel clock (640x480@60Hz)
    wire clk_cpu;       // 6.25 MHz CPU base clock (TASK-216)
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

    // CRT debug signals
    wire [5:0] crt_debug_write_ptr;
    wire [5:0] crt_debug_read_ptr;
    wire       crt_debug_wren;
    wire [10:0] crt_debug_search_counter;
    wire [11:0] crt_debug_luma1;
    wire       crt_debug_rowbuff_wren;
    wire       crt_debug_inside_visible;
    wire       crt_debug_pixel_to_rowbuff;
    wire [15:0] crt_debug_rowbuff_write_count;
    wire [9:0] crt_debug_ring_buffer_wrptr;  // Ring buffer write pointer for pixel debug

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
    // PDP-1 CPU INTEGRATION (TASK-213)
    // =========================================================================
    // Full CPU with RAM and Spacewar! program
    // Author: Jelena Horvat, REGOC team

    // CPU <-> Memory interface signals
    wire [11:0] cpu_mem_addr;
    wire [17:0] cpu_mem_data_out;
    wire [17:0] cpu_mem_data_in;
    wire        cpu_mem_we;

    // CPU output signals
    wire [17:0] cpu_ac;           // Accumulator
    wire [17:0] cpu_io;           // IO register
    wire [11:0] cpu_pc;           // Program counter
    wire [31:0] cpu_bus_out;      // Console blinkenlights

    // CPU debug outputs (TASK-DEBUG)
    wire [15:0] cpu_debug_instr_count;  // Total instructions executed
    wire [15:0] cpu_debug_iot_count;    // IOT instructions executed
    wire        cpu_debug_running;       // CPU is running

    // Pixel debug outputs (TASK-PIXEL-DEBUG)
    wire [31:0] cpu_debug_pixel_count;  // Total pixels sent
    wire [9:0]  cpu_debug_pixel_x;      // Last pixel X coordinate
    wire [9:0]  cpu_debug_pixel_y;      // Last pixel Y coordinate
    wire [2:0]  cpu_debug_pixel_brightness; // Last pixel brightness

    // CRT output signals from CPU
    wire [9:0]  cpu_pixel_x;
    wire [9:0]  cpu_pixel_y;
    wire [2:0]  cpu_pixel_brightness;
    wire        cpu_pixel_shift;

    // Typewriter signals (directly active low, directly active high - directly active low directly active high directly active low - directly active high - directly active low
    wire [6:0]  typewriter_char_out;
    wire        typewriter_strobe_out;
    wire        typewriter_strobe_ack;

    // Paper tape signals (directly active low, directly active high - directly active low directly active high - directly active low
    wire        send_next_tape_char;

    // Gamepad input mapping for Spacewar!
    // PDP-1 gamepad format: bits 17-14 and 3-0 are used
    // Player 1: bits 17-14 (left, right, thrust, fire)
    // Player 2: bits 3-0 (left, right, thrust, fire)
    wire [17:0] gamepad_in;

    // FIX #2 (Emard): Ispravan bit mapping prema fpg1 originalu
    // Map ULX3S buttons/switches to PDP-1 gamepad input
    // joystick_emu[7:0] from ulx3s_input module (ISPRAVLJENO):
    // [0]=P1 fire, [1]=P1 CCW(left), [2]=P1 thrust, [3]=P1 CW(right)
    // [4]=P2 fire, [5]=P2 CCW(left), [6]=P2 thrust, [7]=P2 CW(right)
    // PDP-1 gamepad format: bit 17=CW(right), 16=CCW(left), 15=thrust, 14=fire
    assign gamepad_in = {
        joystick_emu[3],   // bit 17 - P1 CW (rotate right) - BTN[4]
        joystick_emu[1],   // bit 16 - P1 CCW (rotate left) - BTN[3]
        joystick_emu[2],   // bit 15 - P1 thrust - BTN[1]
        joystick_emu[0],   // bit 14 - P1 fire - BTN[0]
        10'b0,             // bits 13-4 unused
        joystick_emu[7],   // bit 3 - P2 CW (rotate right)
        joystick_emu[5],   // bit 2 - P2 CCW (rotate left)
        joystick_emu[6],   // bit 1 - P2 thrust
        joystick_emu[4]    // bit 0 - P2 fire
    };

    // Console switches for CPU control
    // FIX #3 (Emard): Start pulse produžen na 200+ ciklusa da CPU ne propusti signal
    // Start button generates extended pulse on reset release to auto-start execution
    reg [7:0] start_pulse_counter;
    wire start_button_pulse;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            start_pulse_counter <= 8'd200;  // 200 cycles at startup
        end else if (start_pulse_counter > 0) begin
            start_pulse_counter <= start_pulse_counter - 1'b1;
        end
    end

    // Generate start pulse while counter > 0 (full 200 cycle duration)
    assign start_button_pulse = (start_pulse_counter > 0);

    wire [10:0] console_switches;
    assign console_switches = {
        1'b0,              // bit 10 - power switch (0=on)
        1'b0,              // bit 9 - single step
        1'b0,              // bit 8 - single inst
        1'b0,              // bit 7 - tape feed
        1'b0,              // bit 6 - reader
        1'b0,              // bit 5 - read in
        1'b0,              // bit 4 - deposit
        1'b0,              // bit 3 - examine
        1'b0,              // bit 2 - continue
        1'b0,              // bit 1 - stop
        start_button_pulse // bit 0 - start (pulse on reset release)
    };

    // Test word and address switches (directly active low)
    wire [17:0] test_word = 18'b0;
    wire [17:0] test_address = 18'o4;   // Start address: octal 4 (Spacewar! entry point)
    // FIX #1 (Emard): sense_switches spojeni na DIP switcheve za Spacewar opcije
    // sw[3:0] = DIP switches, btn[5:4] dopunjuju do 6 bita (active low -> invert)
    wire [5:0]  sense_switches = {~btn[5], ~btn[4], sw[3:0]};

    // =========================================================================
    // PDP-1 MAIN RAM (4096 x 18-bit)
    // =========================================================================
    pdp1_main_ram main_ram_inst (
        // Port A - CPU interface
        .address_a  (cpu_mem_addr),
        .clock_a    (clk_cpu),
        .data_a     (cpu_mem_data_out),
        .wren_a     (cpu_mem_we),
        .q_a        (cpu_mem_data_in),

        // Port B - unused for now
        .address_b  (12'b0),
        .clock_b    (clk_cpu),
        .data_b     (18'b0),
        .wren_b     (1'b0),
        .q_b        ()
    );

    // =========================================================================
    // PDP-1 CPU
    // =========================================================================
    pdp1_cpu cpu_inst (
        .clk                    (clk_cpu),
        .rst                    (~rst_cpu_n),       // CPU uses active-high reset

        // Memory interface
        .MEM_ADDR               (cpu_mem_addr),
        .DI                     (cpu_mem_data_in),
        .MEM_BUFF               (cpu_mem_data_out),
        .WRITE_ENABLE           (cpu_mem_we),

        // Register outputs (directly active low for debug)
        .AC                     (cpu_ac),
        .IO                     (cpu_io),
        .PC                     (cpu_pc),
        .BUS_out                (cpu_bus_out),

        // Gamepad input
        .gamepad_in             (gamepad_in),

        // CRT output
        .pixel_x_out            (cpu_pixel_x),
        .pixel_y_out            (cpu_pixel_y),
        .pixel_brightness       (cpu_pixel_brightness),
        .pixel_shift_out        (cpu_pixel_shift),

        // Typewriter (directly active low directly active high - directly active low)
        .typewriter_char_out    (typewriter_char_out),
        .typewriter_strobe_out  (typewriter_strobe_out),
        .typewriter_char_in     (6'b0),
        .typewriter_strobe_in   (1'b0),
        .typewriter_strobe_ack  (typewriter_strobe_ack),

        // Paper tape (directly active low directly active high - directly active low)
        .send_next_tape_char    (send_next_tape_char),
        .is_char_available      (1'b0),
        .tape_rcv_word          (18'b0),

        // Start address
        .start_address          (12'o4),     // Spacewar! starts at octal 4

        // Configuration
        .hw_mul_enabled         (1'b1),      // Enable hardware multiply/divide
        .crt_wait               (1'b1),      // Enable CRT wait for proper display timing

        // Console switches
        .console_switches       (console_switches),
        .test_word              (test_word),
        .test_address           (test_address),
        .sense_switches         (sense_switches),

        // Debug outputs (TASK-DEBUG)
        .debug_instr_count      (cpu_debug_instr_count),
        .debug_iot_count        (cpu_debug_iot_count),
        .debug_cpu_running      (cpu_debug_running),

        // Pixel debug outputs (TASK-PIXEL-DEBUG)
        .debug_pixel_count      (cpu_debug_pixel_count),
        .debug_pixel_x          (cpu_debug_pixel_x),
        .debug_pixel_y          (cpu_debug_pixel_y),
        .debug_pixel_brightness (cpu_debug_pixel_brightness)
    );

    // Map CPU outputs to test pattern signals (for CRT display)
    wire [9:0] test_pixel_x = cpu_pixel_x;
    wire [9:0] test_pixel_y = cpu_pixel_y;
    wire [2:0] test_brightness = cpu_pixel_brightness;
    wire       test_pixel_avail = cpu_pixel_shift;
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
        .pixel_available    (pixel_avail_synced),

        // Debug outputs
        .debug_write_ptr    (crt_debug_write_ptr),
        .debug_read_ptr     (crt_debug_read_ptr),
        .debug_wren         (crt_debug_wren),
        .debug_search_counter (crt_debug_search_counter),
        .debug_luma1        (crt_debug_luma1),
        .debug_rowbuff_wren (crt_debug_rowbuff_wren),
        .debug_inside_visible (crt_debug_inside_visible),
        .debug_pixel_to_rowbuff (crt_debug_pixel_to_rowbuff),
        .debug_rowbuff_write_count (crt_debug_rowbuff_write_count),
        .debug_ring_buffer_wrptr (crt_debug_ring_buffer_wrptr)
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

    // Latch pixel_valid, frame_tick, rowbuff_write na usporeni clock za vidljivost
    reg pixel_valid_seen;
    reg frame_tick_seen;
    reg rowbuff_write_seen;
    reg inside_visible_seen;
    reg pixel_to_rowbuff_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            pixel_valid_seen <= 1'b0;
            frame_tick_seen  <= 1'b0;
            rowbuff_write_seen <= 1'b0;
            inside_visible_seen <= 1'b0;
            pixel_to_rowbuff_seen <= 1'b0;
        end else begin
            // Reset na svaki slow clock tick (~0.5s period)
            if (led_divider[24]) begin
                pixel_valid_seen <= 1'b0;
                frame_tick_seen  <= 1'b0;
                rowbuff_write_seen <= 1'b0;
                inside_visible_seen <= 1'b0;
                pixel_to_rowbuff_seen <= 1'b0;
            end else begin
                // Latch ako se dogodilo
                if (pixel_avail_synced)
                    pixel_valid_seen <= 1'b1;
`ifdef TEST_ANIMATION
                if (frame_tick)
                    frame_tick_seen <= 1'b1;
`endif
                // DEBUG: Latch rowbuffer write activity
                if (crt_debug_rowbuff_wren)
                    rowbuff_write_seen <= 1'b1;
                // DEBUG: Latch inside_visible_area activity
                if (crt_debug_inside_visible)
                    inside_visible_seen <= 1'b1;
                // DEBUG: Latch pixel written to rowbuffer (non-zero data)
                if (crt_debug_pixel_to_rowbuff)
                    pixel_to_rowbuff_seen <= 1'b1;
            end
        end
    end

    // =========================================================================
    // COMPREHENSIVE LED DEBUG (TASK-215)
    // =========================================================================
    // LED[0] = heartbeat (clk_pixel radi) - blink na ~1.5Hz
    // LED[1] = cpu_clk_seen - CPU clock activity detected
    // LED[2] = pixel_valid_seen - Pixel valid signal seen
    // LED[3] = frame_tick_seen - Frame tick detected
    // LED[4] = h_counter[9] - H counter MSB (toggles during line)
    // LED[5] = v_counter[9] - V counter MSB (toggles during frame)
    // LED[6] = pll_locked - PLL lock indicator
    // LED[7] = rst_pixel_n - Reset released

    // CPU clock activity detector - latch if CPU clock enable was seen
    reg cpu_clk_seen;
    reg [1:0] cpu_clk_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            cpu_clk_seen <= 1'b0;
            cpu_clk_sync <= 2'b0;
        end else begin
            // Synchronize clk_cpu_en to pixel domain
            cpu_clk_sync <= {cpu_clk_sync[0], clk_cpu_en};
            // Reset on slow clock tick, latch if cpu clock seen
            if (led_divider[24])
                cpu_clk_seen <= 1'b0;
            else if (cpu_clk_sync[1])
                cpu_clk_seen <= 1'b1;
        end
    end

    // Frame tick detector for non-TEST_ANIMATION mode
`ifndef TEST_ANIMATION
    reg frame_tick_seen_cpu;
    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            frame_tick_seen_cpu <= 1'b0;
        else if (led_divider[24])
            frame_tick_seen_cpu <= 1'b0;
        else if (cpu_frame_tick)
            frame_tick_seen_cpu <= 1'b1;
    end
`endif

    // Unified LED assignments for comprehensive debug
    assign led[0] = led_divider[24];           // Heartbeat ~1.5Hz (clk_pixel radi)
    assign led[1] = cpu_clk_seen;              // CPU clock activity (NOVO!)
    assign led[2] = pixel_valid_seen;          // Pixel valid detected
`ifdef TEST_ANIMATION
    assign led[3] = frame_tick_seen;           // Frame tick detected
`else
    assign led[3] = frame_tick_seen_cpu;       // Frame tick detected (CPU mode)
`endif
    assign led[4] = h_counter[9];              // H counter MSB (toggles during line)
    assign led[5] = v_counter[9];              // V counter MSB (toggles during frame)
    assign led[6] = pll_locked;                // PLL locked
    assign led[7] = rst_pixel_n;               // Reset released

    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
`ifdef TEST_ANIMATION
    // Pass actual LED values to serial debug for real-time monitoring
    // LED assignments (from lines 579-587):
    //   LED[0] = heartbeat ~1.5Hz
    //   LED[1] = pixel_valid_seen
    //   LED[2] = frame_tick_seen
    //   LED[3] = pixel_to_rowbuff_seen (non-zero pixel written)
    //   LED[4] = inside_visible_seen
    //   LED[5] = luma1 != 0 (ring buffer has pixels)
    //   LED[6] = pll_locked
    //   LED[7] = rst_pixel_n (reset released)

    serial_debug serial_debug_inst (
        .clk          (clk_pixel),
        .rst_n        (rst_pixel_n),
        .frame_tick   (frame_tick),
        .angle        (anim_debug_angle),
        .pixel_x      (anim_pixel_x),
        .pixel_y      (anim_pixel_y),
        .pixel_valid  (anim_pixel_valid),
        .led_status   (led),  // Use actual LED values
        // Additional debug signals
        .pixel_avail_synced (pixel_avail_synced),
        .crt_wren           (crt_debug_wren),
        .crt_write_ptr      (crt_debug_write_ptr),
        .crt_read_ptr       (crt_debug_read_ptr),
        .search_counter_msb (crt_debug_search_counter),
        .luma1              (crt_debug_luma1),
        .rowbuff_write_count (crt_debug_rowbuff_write_count),
        // CPU debug signals (not used in TEST_ANIMATION mode)
        .cpu_pc             (12'd0),
        .cpu_instr_count    (16'd0),
        .cpu_iot_count      (16'd0),
        .cpu_running        (1'b0),
        // Pixel debug signals (not used in TEST_ANIMATION mode - use animation signals)
        .pixel_count        (32'd0),
        .pixel_debug_x      (anim_pixel_x),
        .pixel_debug_y      (anim_pixel_y),
        .pixel_brightness   (anim_brightness),
        .pixel_shift_out    (anim_pixel_valid),
        .ring_buffer_wrptr  (crt_debug_ring_buffer_wrptr),
        .uart_tx_pin  (ftdi_rxd)
    );
`else
    // =========================================================================
    // CPU MODE: Serial Debug Output (TASK-214)
    // =========================================================================
    // Frame tick generator za CPU mode (isti kao u TEST_ANIMATION)
    reg cpu_frame_tick;
    reg [10:0] cpu_prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            cpu_frame_tick <= 1'b0;
            cpu_prev_v_counter <= 11'd0;
        end else begin
            cpu_prev_v_counter <= v_counter;
            // Detect start of new frame (vblank start)
            cpu_frame_tick <= (v_counter == 11'd0) && (cpu_prev_v_counter != 11'd0);
        end
    end

    // Serial debug za CPU mode - koristi CPU signale
    serial_debug serial_debug_cpu_inst (
        .clk          (clk_pixel),
        .rst_n        (rst_pixel_n),
        .frame_tick   (cpu_frame_tick),
        .angle        (cpu_pc[7:0]),           // PC low byte umjesto angle
        .pixel_x      (cpu_pixel_x),           // CPU pixel X
        .pixel_y      (cpu_pixel_y),           // CPU pixel Y
        .pixel_valid  (cpu_pixel_shift),       // CPU pixel shift
        .led_status   (led),                   // LED status
        // Additional debug signals
        .pixel_avail_synced (pixel_avail_synced),
        .crt_wren           (crt_debug_wren),
        .crt_write_ptr      (crt_debug_write_ptr),
        .crt_read_ptr       (crt_debug_read_ptr),
        .search_counter_msb (crt_debug_search_counter),
        .luma1              (crt_debug_luma1),
        .rowbuff_write_count (crt_debug_rowbuff_write_count),
        // CPU debug signals (TASK-DEBUG)
        .cpu_pc             (cpu_pc),
        .cpu_instr_count    (cpu_debug_instr_count),
        .cpu_iot_count      (cpu_debug_iot_count),
        .cpu_running        (cpu_debug_running),
        // Pixel debug signals (TASK-PIXEL-DEBUG)
        .pixel_count        (cpu_debug_pixel_count),
        .pixel_debug_x      (cpu_debug_pixel_x),
        .pixel_debug_y      (cpu_debug_pixel_y),
        .pixel_brightness   (cpu_debug_pixel_brightness),
        .pixel_shift_out    (cpu_pixel_shift),
        .ring_buffer_wrptr  (crt_debug_ring_buffer_wrptr),
        .uart_tx_pin  (ftdi_rxd)
    );
`endif

endmodule
