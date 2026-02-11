//==============================================================================
// Module:      top_oscilloscope
// Description: Top-level module for PDP-1 Oscilloscope on ULX3S
//==============================================================================
// Author:      Jelena Kovacevic, REGOC team
// Created:     2026-02-11
//
// This is the OSCILLOSCOPE version with ADC MAX11123 support.
// For original PDP-1 Spacewar!, use top_pdp1.v
//
// Hardware Target: ULX3S v3.1.7 (Lattice ECP5-85F)
//   - 25 MHz onboard oscillator
//   - HDMI output via GPDI differential pairs
//   - 7 pushbuttons (active-low) + 4 DIP switches
//   - 8 LED indicators
//   - GPIO pins for ADC MAX11123 SPI interface
//
// Clock Domains:
//   - clk_shift  : 125 MHz  - HDMI DDR serializer (5x pixel clock)
//   - clk_pixel  :  51 MHz  - VGA timing (1024x768@50Hz)
//   - clk_cpu    :  51 MHz  - PDP-1 CPU emulation base clock
//
// ADC Interface (GPIO pins):
//   - gp14: ADC CSN (chip select, active low)
//   - gp15: ADC SCLK (SPI clock)
//   - gn14: ADC MOSI (master out)
//   - gn15: ADC MISO (master in)
//
//==============================================================================

`include "definitions.v"

module top_oscilloscope
(
    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    input  wire [3:0]  sw,             // SW[3:0] active-high

    // ==== LED Indicators ====
    output wire [7:0]  led,            // LED[7:0] active-high

    // ==== HDMI Output (GPDI differential pairs) ====
    output wire [3:0]  gpdi_dp,        // TMDS positive (active)
    output wire [3:0]  gpdi_dn,        // TMDS negative (active)

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0,     // HIGH prevents ESP32 reboot

    // ==== FTDI UART (Debug Serial Output) ====
    output wire        ftdi_rxd,       // FPGA TX -> PC RX (active-high)

    // ==== GPDI Control Pins (HDMI Hot Plug Detect) ====
    output wire        gpdi_scl,       // I2C SCL - drive HIGH for DDC wake-up
    input  wire        gpdi_hpd,       // HDMI HPD from monitor (active-high)

    // ==== GPIO for ADC MAX11123 (Oscilloscope) ====
    output wire        gp14,           // ADC CSN (active low)
    output wire        gp15,           // ADC SCLK
    output wire        gn14,           // ADC MOSI
    input  wire        gn15            // ADC MISO
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)
    localparam C_PIXEL_CLK_FREQ = 51_000_000;  // 51 MHz pixel clock

    // =========================================================================
    // ESP32 / WiFi GPIO
    // =========================================================================
    assign wifi_gpio0 = btn[0];
    assign gpdi_scl = 1'b1;

    // =========================================================================
    // CLOCK GENERATION (PLL)
    // =========================================================================
    wire clk_shift;     // 255 MHz HDMI shift clock
    wire clk_pixel;     // 51 MHz pixel clock
    wire clk_cpu;       // 51 MHz CPU base clock
    wire w_pll_locked;

    assign clk_cpu = clk_pixel;

    clk_25_shift_pixel_cpu u_pll
    (
        .clki   (clk_25mhz),
        .clko   (clk_shift),
        .clks1  (clk_pixel),
        .locked (w_pll_locked)
    );

    // =========================================================================
    // CLOCK DOMAIN MANAGEMENT & RESET
    // =========================================================================
    wire w_clk_cpu_slow;
    wire w_clk_cpu_en;
    wire rst_pixel_n;
    wire rst_cpu_n;

    wire [11:0] w_cpu_fb_addr = 12'b0;
    wire [11:0] w_cpu_fb_data = 12'b0;
    wire        w_cpu_fb_we   = 1'b0;
    wire [11:0] w_vid_fb_addr;
    wire [11:0] w_vid_fb_data;
    wire        w_vid_fb_we;
    wire        w_vid_vblank;
    wire        w_cpu_vblank;

    // CPU pixel signals
    wire [9:0]  w_cpu_pixel_x;
    wire [9:0]  w_cpu_pixel_y;
    wire [2:0]  w_cpu_pixel_brightness;
    wire        w_cpu_pixel_shift;
    wire [9:0]  w_vid_pixel_x;
    wire [9:0]  w_vid_pixel_y;
    wire [2:0]  w_vid_pixel_brightness;
    wire        w_vid_pixel_shift;

    clock_domain u_clock_domain
    (
        .clk_pixel      (clk_pixel),
        .clk_cpu_fast   (clk_cpu),
        .pll_locked     (w_pll_locked),
        .rst_n          (btn[0]),

        .clk_cpu        (w_clk_cpu_slow),
        .clk_cpu_en     (w_clk_cpu_en),
        .rst_pixel_n    (rst_pixel_n),
        .rst_cpu_n      (rst_cpu_n),

        .cpu_fb_addr    (w_cpu_fb_addr),
        .cpu_fb_data    (w_cpu_fb_data),
        .cpu_fb_we      (w_cpu_fb_we),
        .vid_fb_addr    (w_vid_fb_addr),
        .vid_fb_data    (w_vid_fb_data),
        .vid_fb_we      (w_vid_fb_we),
        .vid_vblank     (w_vid_vblank),
        .cpu_vblank     (w_cpu_vblank),

        .cpu_pixel_x            (w_cpu_pixel_x),
        .cpu_pixel_y            (w_cpu_pixel_y),
        .cpu_pixel_brightness   (w_cpu_pixel_brightness),
        .cpu_pixel_shift        (w_cpu_pixel_shift),
        .vid_pixel_x            (w_vid_pixel_x),
        .vid_pixel_y            (w_vid_pixel_y),
        .vid_pixel_brightness   (w_vid_pixel_brightness),
        .vid_pixel_shift        (w_vid_pixel_shift)
    );

    // =========================================================================
    // INPUT HANDLING
    // =========================================================================
    wire [7:0] w_joystick_emu;
    wire [7:0] w_led_input_feedback;
    wire       w_p2_mode_active;
    wire       w_single_player;

    ulx3s_input #(
        .CLK_FREQ    (C_PIXEL_CLK_FREQ),
        .DEBOUNCE_MS (10)
    ) u_input (
        .i_clk            (clk_pixel),
        .i_rst_n          (rst_pixel_n),
        .i_btn_n          (btn),
        .i_sw             (sw),
        .o_joystick_emu   (w_joystick_emu),
        .o_led_feedback   (w_led_input_feedback),
        .o_p2_mode_active (w_p2_mode_active),
        .o_single_player  (w_single_player)
    );

    // =========================================================================
    // VIDEO TIMING GENERATION
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

    assign w_vid_vblank = (r_v_counter < `v_visible_offset);

    // =========================================================================
    // CRT DISPLAY
    // =========================================================================
    wire [7:0] w_crt_r, w_crt_g, w_crt_b;
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

    // =========================================================================
    // PDP-1 CPU (Oscilloscope version with ADC)
    // =========================================================================
    wire [11:0] w_cpu_mem_addr;
    wire [17:0] w_cpu_mem_data_out;
    wire [17:0] w_cpu_mem_data_in;
    wire        w_cpu_mem_we;
    wire [17:0] w_cpu_ac;
    wire [17:0] w_cpu_io;
    wire [11:0] w_cpu_pc;
    wire [31:0] w_cpu_bus_out;
    wire [15:0] w_cpu_debug_instr_count;
    wire [15:0] w_cpu_debug_iot_count;
    wire        w_cpu_debug_running;
    wire [7:0]  w_cpu_debug_state;
    wire [31:0] w_cpu_debug_pixel_count;
    wire [9:0]  w_cpu_debug_pixel_x;
    wire [9:0]  w_cpu_debug_pixel_y;
    wire [2:0]  w_cpu_debug_pixel_brightness;
    wire [6:0]  w_typewriter_char_out;
    wire        w_typewriter_strobe_out;
    wire        w_typewriter_strobe_ack;
    wire        w_send_next_tape_char;

    // =========================================================================
    // ADC MAX11123 Interface
    // =========================================================================
    wire [11:0] w_adc_data;
    wire        w_adc_valid;
    wire [17:0] w_adc_io_data = {6'b0, w_adc_data};

    adc_max11123 u_adc (
        .clk        (clk_pixel),
        .rst_n      (rst_pixel_n),
        .adc_csn    (gp14),
        .adc_sclk   (gp15),
        .adc_mosi   (gn14),
        .adc_miso   (gn15),
        .adc_data   (w_adc_data),
        .adc_valid  (w_adc_valid),
        .channel    (3'b000)
    );

    // =========================================================================
    // Gamepad input
    // =========================================================================
    wire [17:0] w_gamepad_in;
    assign w_gamepad_in = {
        w_joystick_emu[3], w_joystick_emu[1], w_joystick_emu[2], w_joystick_emu[0],
        10'b0,
        w_joystick_emu[7], w_joystick_emu[5], w_joystick_emu[6], w_joystick_emu[4]
    };

    // =========================================================================
    // Console switches
    // =========================================================================
    reg [7:0] r_start_pulse_counter;
    wire w_start_button_pulse;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_start_pulse_counter <= 8'd5;
        end else if (r_start_pulse_counter > 0) begin
            r_start_pulse_counter <= r_start_pulse_counter - 1'b1;
        end
    end

    assign w_start_button_pulse = (r_start_pulse_counter > 0);

    wire [10:0] w_console_switches;
    assign w_console_switches = {
        1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
        w_start_button_pulse
    };

    wire [17:0] w_test_word = 18'b011_011_111_111_010_010;
    wire [17:0] w_test_address = 18'o100;  // snowflake / oscilloscope

    // =========================================================================
    // CDC: DIP SWITCH SYNCHRONIZATION
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_sync_meta, r_sw_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_btn_sync_meta, r_btn_sync;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sw_sync_meta  <= 4'b0;
            r_sw_sync       <= 4'b0;
            r_btn_sync_meta <= 2'b0;
            r_btn_sync      <= 2'b0;
        end else begin
            r_sw_sync_meta <= sw;
            r_sw_sync      <= r_sw_sync_meta;
            r_btn_sync_meta <= ~btn[5:4];
            r_btn_sync      <= r_btn_sync_meta;
        end
    end

    wire [5:0] w_sense_switches = {r_btn_sync, r_sw_sync[3:2], 1'b1, r_sw_sync[0]};

    // =========================================================================
    // PDP-1 MAIN RAM
    // =========================================================================
    pdp1_main_ram u_main_ram (
        .address_a  (w_cpu_mem_addr),
        .clock_a    (clk_cpu),
        .data_a     (w_cpu_mem_data_out),
        .wren_a     (w_cpu_mem_we),
        .q_a        (w_cpu_mem_data_in),
        .address_b  (12'b0),
        .clock_b    (clk_cpu),
        .data_b     (18'b0),
        .wren_b     (1'b0),
        .q_b        ()
    );

    // =========================================================================
    // PDP-1 CPU (Oscilloscope version)
    // =========================================================================
    pdp1_cpu_osc u_cpu (
        .clk                    (clk_cpu),
        .rst                    (~rst_cpu_n),
        .MEM_ADDR               (w_cpu_mem_addr),
        .DI                     (w_cpu_mem_data_in),
        .MEM_BUFF               (w_cpu_mem_data_out),
        .WRITE_ENABLE           (w_cpu_mem_we),
        .AC                     (w_cpu_ac),
        .IO                     (w_cpu_io),
        .PC                     (w_cpu_pc),
        .BUS_out                (w_cpu_bus_out),
        .gamepad_in             (w_gamepad_in),
        .pixel_x_out            (w_cpu_pixel_x),
        .pixel_y_out            (w_cpu_pixel_y),
        .pixel_brightness       (w_cpu_pixel_brightness),
        .pixel_shift_out        (w_cpu_pixel_shift),
        .typewriter_char_out    (w_typewriter_char_out),
        .typewriter_strobe_out  (w_typewriter_strobe_out),
        .typewriter_char_in     (6'b0),
        .typewriter_strobe_in   (1'b0),
        .typewriter_strobe_ack  (w_typewriter_strobe_ack),
        .send_next_tape_char    (w_send_next_tape_char),
        .is_char_available      (1'b0),
        .tape_rcv_word          (18'b0),
        .start_address          (12'o4),
        .hw_mul_enabled         (1'b1),
        .crt_wait               (1'b1),
        .console_switches       (w_console_switches),
        .test_word              (w_test_word),
        .test_address           (w_test_address),
        .sense_switches         (w_sense_switches),
        .debug_instr_count      (w_cpu_debug_instr_count),
        .debug_iot_count        (w_cpu_debug_iot_count),
        .debug_cpu_running      (w_cpu_debug_running),
        .debug_cpu_state        (w_cpu_debug_state),
        .debug_pixel_count      (w_cpu_debug_pixel_count),
        .debug_pixel_x          (w_cpu_debug_pixel_x),
        .debug_pixel_y          (w_cpu_debug_pixel_y),
        .debug_pixel_brightness (w_cpu_debug_pixel_brightness),
        // ADC interface (oscilloscope specific)
        .external_io_data       (w_adc_io_data),
        .external_io_valid      (w_adc_valid)
    );

    // =========================================================================
    // CDC: PIXEL DATA HOLD REGISTERS
    // =========================================================================
    reg [9:0]  r_pixel_x_hold;
    reg [9:0]  r_pixel_y_hold;
    reg [2:0]  r_pixel_brightness_hold;
    reg [3:0]  r_pixel_hold_counter;
    reg        r_pixel_hold_valid;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_pixel_x_hold          <= 10'd0;
            r_pixel_y_hold          <= 10'd0;
            r_pixel_brightness_hold <= 3'd0;
            r_pixel_hold_counter    <= 4'd0;
            r_pixel_hold_valid      <= 1'b0;
        end else begin
            if (w_cpu_pixel_shift && r_pixel_hold_counter == 0) begin
                r_pixel_x_hold          <= w_cpu_pixel_x;
                r_pixel_y_hold          <= w_cpu_pixel_y;
                r_pixel_brightness_hold <= w_cpu_pixel_brightness;
                r_pixel_hold_counter    <= 4'd8;
                r_pixel_hold_valid      <= 1'b1;
            end else if (r_pixel_hold_counter > 0) begin
                r_pixel_hold_counter <= r_pixel_hold_counter - 1'b1;
                if (r_pixel_hold_counter == 1)
                    r_pixel_hold_valid <= 1'b0;
            end
        end
    end

    wire [9:0] w_test_pixel_x     = r_pixel_x_hold;
    wire [9:0] w_test_pixel_y     = r_pixel_y_hold;
    wire [2:0] w_test_brightness  = r_pixel_brightness_hold;
    wire       w_test_pixel_avail = r_pixel_hold_valid;

    // =========================================================================
    // CDC: PIXEL VALID SYNCHRONIZATION
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_pixel_avail_sync;
    reg [9:0] r_pixel_x_sync;
    reg [9:0] r_pixel_y_sync;
    reg [2:0] r_brightness_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_avail_sync <= 3'b0;
            r_pixel_x_sync     <= 10'd240;
            r_pixel_y_sync     <= 10'd240;
            r_brightness_sync  <= 3'b0;
        end else begin
            r_pixel_avail_sync <= {r_pixel_avail_sync[1:0], w_test_pixel_avail};
            if (r_pixel_avail_sync[1] && !r_pixel_avail_sync[2]) begin
                r_pixel_x_sync    <= w_test_pixel_x;
                r_pixel_y_sync    <= w_test_pixel_y;
                r_brightness_sync <= w_test_brightness;
            end
        end
    end

    wire w_pixel_avail_synced = r_pixel_avail_sync[1] && !r_pixel_avail_sync[2];
    wire [9:0] w_pixel_x_sync    = r_pixel_x_sync;
    wire [9:0] w_pixel_y_sync    = r_pixel_y_sync;
    wire [2:0] w_brightness_sync = r_brightness_sync;

    // =========================================================================
    // CRT PHOSPHOR DISPLAY
    // =========================================================================
    pdp1_vga_crt u_crt_display
    (
        .i_clk              (clk_pixel),
        .i_rst_n            (rst_pixel_n),
        .i_h_counter        (r_h_counter),
        .i_v_counter        (r_v_counter),
        .o_red              (w_crt_r),
        .o_green            (w_crt_g),
        .o_blue             (w_crt_b),
        .i_pixel_x          (w_pixel_x_sync),
        .i_pixel_y          (w_pixel_y_sync),
        .i_pixel_brightness (w_brightness_sync),
        .i_variable_brightness(1'b1),
        .i_pixel_valid      (w_pixel_avail_synced),
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
    // VGA SYNC SIGNALS
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
    // VGA RGB OUTPUT
    // =========================================================================
    wire [7:0] w_vga_r = w_crt_r;
    wire [7:0] w_vga_g = w_crt_g;
    wire [7:0] w_vga_b = w_crt_b;

    // =========================================================================
    // HDMI OUTPUT
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
    // LED & DEBUG
    // =========================================================================
    assign led = 8'b0;
    assign ftdi_rxd = 1'b1;

endmodule
