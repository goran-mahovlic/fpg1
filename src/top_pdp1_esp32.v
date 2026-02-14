//==============================================================================
// Module:      top_pdp1_esp32
// Description: Top-level module for PDP-1 Spacewar! emulator on ULX3S
//              WITH ESP32 OSD INTEGRATION for RIM file loading
//==============================================================================
// Author:      Kosjenka Vukovic, FPGA Architect, REGOC team
// Reviewer:    Jelena Horvat (best practices), REGOC team
// ESP32 OSD:   Jelena Kovacevic, REGOC team (2026-02-13)
// Created:     2026-01-31
// Modified:    2026-02-13 (ESP32 OSD integration, RIM loader)
//
// Hardware Target: ULX3S v3.1.7 (Lattice ECP5-85F)
//   - 25 MHz onboard oscillator
//   - HDMI output via GPDI differential pairs
//   - 7 pushbuttons (active-low) + 4 DIP switches
//   - 8 LED indicators
//
// Clock Domains:
//   - clk_shift  : 125 MHz  - HDMI DDR serializer (5x pixel clock)
//   - clk_pixel  :  51 MHz  - VGA timing (1024x768@50Hz)
//   - clk_cpu    :  51 MHz  - PDP-1 CPU emulation base clock
//
// Reset Strategy:
//   - Asynchronous assert, synchronous deassert per clock domain
//   - rst_pixel_n: Synchronized to clk_pixel domain
//   - rst_cpu_n:   Synchronized to clk_cpu domain
//   - Reset source: ~btn[0] (PWR inverted) - reset when NOT pressed
//   - NOTE: Changed from btn[6] to ~btn[0] for user convenience
//
// CDC Crossings:
//   1. CPU -> Pixel: Pixel coordinates (23 bits) via HOLD registers + sync
//   2. Pixel -> CPU: VBlank signal via 2FF synchronizer
//   3. External -> CPU: DIP switches via 2FF synchronizer
//   4. External -> Pixel: Buttons via ulx3s_input debouncer
//
// Module Integration:
//   - clk_25_shift_pixel_cpu.sv : PLL (25MHz -> 125/51/6.25 MHz)
//   - clock_domain.v           : Prescaler, CDC, Reset Sequencing
//   - pdp1_vga_crt.v           : CRT phosphor decay emulation
//   - ulx3s_input.v            : Button debounce, joystick mapping
//   - pdp1_cpu.v               : PDP-1 CPU core
//   - pdp1_main_ram.v          : 4K x 18-bit main memory
//   - vga2dvid.v               : VGA to DVI/HDMI conversion
//   - fake_differential.v      : ECP5 DDR output primitives
//
//==============================================================================

// Force ESP32_OSD to be always defined in this module
`define ESP32_OSD

`include "definitions.v"

module top_pdp1_esp32
(
    // =========================================================================
    // PORT NAMING CONVENTION (HDL Guidelines 01_NAMING_CONVENTIONS):
    //   i_  = Input port
    //   o_  = Output port
    //   _n  = Active-low signal
    //
    // NOTE: Port names kept as hardware pinout names for PCF compatibility.
    // Internal signals follow naming conventions with prefixes.
    // =========================================================================

    // ==== System Clock ====
    input  wire        clk_25mhz,      // 25 MHz onboard oscillator

    // ==== Buttons (directly active-low from hardware) ====
    input  wire [6:0]  btn,            // BTN[6:0] active-low on PCB

    // ==== DIP Switches ====
    // DIP SWITCH MAPPING (ACTIVE-HIGH):
    //   SW[0] = P2 mode modifier (hold for Player 2 controls)
    //   SW[1] = Serial debug enable (ON=enabled, OFF=disabled) <<< FOR DEBUG!
    //   SW[2] = Sine test pattern (ON=sine wave, OFF=CPU display)
    //   SW[3] = Test pattern output (ON=color bars, OFF=CRT)
    input  wire [3:0]  sw,             // SW[3:0] active-high

    // ==== LED Indicators ====
    output reg [7:0]  led,             // LED[7:0] active-high (reg for debug in always block)

    // ==== HDMI Output (GPDI differential pairs) ====
    output wire [3:0]  gpdi_dp,        // TMDS positive (active)
    output wire [3:0]  gpdi_dn,        // TMDS negative (active)

    // ==== WiFi GPIO0 (ESP32 keep-alive) ====
    output wire        wifi_gpio0,     // HIGH prevents ESP32 reboot

    // ==== WiFi Serial (ESP32 UART passthrough) ====
    input  wire        wifi_txd,       // ESP32 TX -> FPGA (K4)
    output wire        wifi_rxd,       // FPGA -> ESP32 RX (K3)

    // ==== FTDI UART (Debug Serial Output + Serial Loader Input) ====
    output wire        ftdi_rxd,       // FPGA TX -> PC RX (active-high)
    input  wire        ftdi_txd,       // FPGA RX <- PC TX (serial loader / passthrough)

    // ==== GPDI Control Pins (HDMI Hot Plug Detect) ====
    output wire        gpdi_scl,       // I2C SCL - drive HIGH for DDC wake-up
    input  wire        gpdi_hpd        // HDMI HPD from monitor (active-high)

    // NOTE: ADC GPIO pins (gp14, gp15, gn14, gn15) moved to top_oscilloscope.v

`ifdef ESP32_OSD
    // ==== ESP32 SPI Interface (OSD overlay) ====
    ,
    input  wire        esp32_spi_clk,  // SPI clock from ESP32
    input  wire        esp32_spi_mosi, // SPI data from ESP32
    inout  wire        esp32_spi_miso, // SPI data to ESP32 (tristate!)
    input  wire        esp32_spi_cs_n, // SPI chip select (active-low)
    output wire        esp32_osd_irq,  // Interrupt to ESP32
    input  wire        esp32_ready     // ESP32 ready signal
`endif
);

    // =========================================================================
    // PARAMETERS (HDL Guidelines: UPPER_CASE for constants)
    // =========================================================================
    parameter C_DDR = 1'b1;   // DDR mode for HDMI (5x pixel clock)

    // Local parameters (computed, do not override)
    localparam C_PIXEL_CLK_FREQ = 51_000_000;  // 51 MHz pixel clock
    localparam C_CPU_CLK_FREQ   = 51_000_000;   // 6.25 MHz CPU clock

    // =========================================================================
    // ACTIVE-LOW -> ACTIVE-HIGH BUTTON CONVERSION
    // =========================================================================
    // Note: btn[0] is special (BTN_PWR), used for ESP32 keep-alive.
    // wifi_gpio0=HIGH prevents ESP32 reboot when button pressed.
    assign wifi_gpio0 = btn[0];

    // =========================================================================
    // WIFI SERIAL PASSTHROUGH (FTDI <-> ESP32)
    // =========================================================================
    // Enables WebREPL/serial access to ESP32 via USB FTDI.
    // ftdi_txd (PC TX) -> wifi_rxd (ESP32 RX)
    // wifi_txd (ESP32 TX) -> ftdi_rxd (PC RX)
    //
    // NOTE: ftdi_rxd driver priority:
    //   1. ENABLE_UART_DEBUG defined: serial_debug drives ftdi_rxd
    //   2. Otherwise: wifi_txd passthrough (for ESP32 WebREPL)
    // The assignment is at the end of this file to avoid duplicate drivers.
    // -------------------------------------------------------------------------
    assign wifi_rxd = ftdi_txd;   // PC TX -> ESP32 RX (always active)

    // -------------------------------------------------------------------------
    // Internal signal naming convention (HDL Guidelines 01_NAMING_CONVENTIONS):
    //   r_  = Register (clocked, sequential logic)
    //   w_  = Wire (combinational logic)
    //   clk_ = Clock signal
    //   rst_ = Reset signal
    //   _n   = Active-low signal suffix
    // -------------------------------------------------------------------------

    // =========================================================================
    // HDMI HPD (Hot Plug Detect) - ACTIVE-HIGH
    // =========================================================================
    // HPD is INPUT - monitor drives HIGH when connected and ready.
    // gpdi_scl driven HIGH constantly for DDC wake-up (I2C pull-up emulation).
    assign gpdi_scl = 1'b1;

    // Monitor connection status (active-high)
    wire w_monitor_connected = gpdi_hpd;

    // =========================================================================
    // CLOCK GENERATION (PLL) - 1024x768@50Hz Video Mode
    // =========================================================================
    // Clock tree:
    //   clk_25mhz (input) -> PLL -> clk_shift (255 MHz, HDMI DDR serializer)
    //                           -> clk_pixel (51 MHz, VGA timing)
    //                           -> clk_cpu (51 MHz, PDP-1 emulation base clock)
    // -------------------------------------------------------------------------
    wire clk_shift;     // 255 MHz HDMI shift clock (5x pixel for DDR)
    wire clk_pixel;     // 51 MHz pixel clock (1024x768@50Hz timing)
    wire clk_cpu;       // 51 MHz CPU base clock (same as pixel)
    wire w_pll_locked;  // PLL lock indicator (active-high)

    assign clk_cpu = clk_pixel;

    clk_25_shift_pixel_cpu u_pll
    (
        .clki   (clk_25mhz),
        .clko   (clk_shift),
        .clks1  (clk_pixel),
        //.clks2  (clk_cpu),
        .locked (w_pll_locked)
    );

    // =========================================================================
    // CLOCK DOMAIN MANAGEMENT & RESET SEQUENCING
    // =========================================================================
    // Reset strategy: Asynchronous assert, synchronous deassert.
    // Each clock domain has its own synchronized reset signal.
    // Reset source: ~btn[0] (PWR inverted) AND pll_locked
    // NOTE: btn[0] inverted - system reset when PWR button is NOT pressed
    // -------------------------------------------------------------------------
    wire w_clk_cpu_slow;    // 1.82 MHz PDP-1 clock (51 MHz / 28, legacy interface)
    wire w_clk_cpu_en;      // Clock enable pulse
    wire rst_pixel_n;       // Synchronized reset for pixel domain (active-low)
    wire rst_cpu_n;         // Synchronized reset for CPU domain (active-low)

    // CDC framebuffer signals (placeholders for future CPU integration)
    wire [11:0] w_cpu_fb_addr = 12'b0;
    wire [11:0] w_cpu_fb_data = 12'b0;
    wire        w_cpu_fb_we   = 1'b0;
    wire [11:0] w_vid_fb_addr;
    wire [11:0] w_vid_fb_data;
    wire        w_vid_fb_we;
    wire        w_vid_vblank;
    wire        w_cpu_vblank;

    // RESTORED: Direct btn[0] reset (as in working version f1cc163)
    // Power-on reset generator removed - it was causing the black screen bug.
    // clock_domain.v has its own internal reset synchronizer with 128 cycle delay.

    clock_domain u_clock_domain
    (
        .clk_pixel      (clk_pixel),
        .clk_cpu_fast   (clk_cpu),
        .pll_locked     (w_pll_locked),
        .rst_n          (btn[0]),           // BTN[0] active-low = reset (direct, as in working version)

        .clk_cpu        (w_clk_cpu_slow),
        .clk_cpu_en     (w_clk_cpu_en),
        .rst_pixel_n    (rst_pixel_n),
        .rst_cpu_n      (rst_cpu_n),

        // CDC interface (for future framebuffer CPU integration)
        .cpu_fb_addr    (w_cpu_fb_addr),
        .cpu_fb_data    (w_cpu_fb_data),
        .cpu_fb_we      (w_cpu_fb_we),
        .vid_fb_addr    (w_vid_fb_addr),
        .vid_fb_data    (w_vid_fb_data),
        .vid_fb_we      (w_vid_fb_we),
        .vid_vblank     (w_vid_vblank),
        .cpu_vblank     (w_cpu_vblank),

        // CDC interface: CPU pixel coordinates and control -> Video
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
    // INPUT HANDLING (ULX3S BUTTONS & SWITCHES)
    // =========================================================================
    // Input synchronization and debouncing handled by ulx3s_input module.
    // Buttons are active-low from hardware, active-high internally.
    // -------------------------------------------------------------------------
    wire [7:0] w_joystick_emu;
    wire [7:0] w_led_input_feedback;
    wire       w_p2_mode_active;
    wire       w_single_player;
    wire [6:0] w_btn_direct;          // Direct debounced buttons for Pong

    ulx3s_input #(
        .CLK_FREQ    (C_PIXEL_CLK_FREQ),  // 51 MHz pixel clock
        .DEBOUNCE_MS (10)
    ) u_input (
        .i_clk            (clk_pixel),
        .i_rst_n          (rst_pixel_n),
        .i_btn_n          (btn),              // Active-low from board (BTN[6:0], btn[6] is reset, btn[0] is P1 Fire)
        .i_sw             (sw),
        .o_joystick_emu   (w_joystick_emu),
        .o_led_feedback   (w_led_input_feedback),
        .o_p2_mode_active (w_p2_mode_active),
        .o_single_player  (w_single_player),
        .o_btn_direct     (w_btn_direct)      // Direct buttons for Pong (no SW[0] mode)
    );

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

    // VBlank signal for CPU synchronization (active during vertical blanking)
    assign w_vid_vblank = (r_v_counter < `v_visible_offset);

    // =========================================================================
    // CRT PHOSPHOR DISPLAY EMULATION (clk_pixel domain)
    // =========================================================================
    wire [7:0] w_crt_r, w_crt_g, w_crt_b;

    // CRT debug signals (active in clk_pixel domain)
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
    // PDP-1 CPU INTEGRATION (clk_cpu domain)
    // =========================================================================
    // Full CPU with RAM and Spacewar! program execution.
    // -------------------------------------------------------------------------

    // CPU <-> Memory interface signals (clk_cpu domain)
    wire [11:0] w_cpu_mem_addr;
    wire [17:0] w_cpu_mem_data_out;
    wire [17:0] w_cpu_mem_data_in;
    wire        w_cpu_mem_we;

    // CPU output signals (clk_cpu domain)
    wire [17:0] w_cpu_ac;           // Accumulator
    wire [17:0] w_cpu_io;           // IO register
    wire [11:0] w_cpu_pc;           // Program counter
    wire [31:0] w_cpu_bus_out;      // Console blinkenlights

    // CPU debug outputs (clk_cpu domain)
    wire [15:0] w_cpu_debug_instr_count;  // Total instructions executed
    wire [15:0] w_cpu_debug_iot_count;    // IOT instructions executed
    wire        w_cpu_debug_running;       // CPU is running
    wire [7:0]  w_cpu_debug_state;         // CPU state machine state

    // Pixel debug outputs (clk_cpu domain)
    wire [31:0] w_cpu_debug_pixel_count;      // Total pixels sent
    wire [9:0]  w_cpu_debug_pixel_x;          // Last pixel X coordinate
    wire [9:0]  w_cpu_debug_pixel_y;          // Last pixel Y coordinate
    wire [2:0]  w_cpu_debug_pixel_brightness; // Last pixel brightness

    // CRT output signals from CPU (clk_cpu domain - requires CDC!)
    wire [9:0]  w_cpu_pixel_x;
    wire [9:0]  w_cpu_pixel_y;
    wire [2:0]  w_cpu_pixel_brightness;
    wire        w_cpu_pixel_shift;

    // CRT output signals synchronized to pixel clock domain (via CDC in clock_domain module)
    wire [9:0]  w_vid_pixel_x;
    wire [9:0]  w_vid_pixel_y;
    wire [2:0]  w_vid_pixel_brightness;
    wire        w_vid_pixel_shift;

    // Typewriter signals (active-high, active when character available)
    wire [6:0]  w_typewriter_char_out;
    wire        w_typewriter_strobe_out;
    wire        w_typewriter_strobe_ack;

    // Paper tape signals
    wire        w_send_next_tape_char;

    // NOTE: ADC MAX11123 Interface moved to top_oscilloscope.v

    // -------------------------------------------------------------------------
    // Gamepad input mapping for Spacewar! AND Pong (active-high signals)
    // -------------------------------------------------------------------------
    // PDP-1 gamepad format: bits 17-14 and 3-0 are used for Spacewar!
    // Player 1: bits 17-14 (CW, CCW, thrust, fire)
    // Player 2: bits 3-0 (CW, CCW, thrust, fire)
    //
    // Pong uses DIFFERENT bits (via IOT 11):
    //   bit 14 = P1 UP (rghtup = 100000 octal)
    //   bit 13 = P1 DOWN (rghtdown = 040000 octal) <-- WAS HARDCODED 0!
    //   bit 1  = P2 UP (leftup = 000002 octal)
    //   bit 0  = P2 DOWN (leftdown = 000001 octal)
    //
    // w_joystick_emu[7:0] from ulx3s_input (Spacewar mode with SW[0]):
    //   [0]=P1 fire, [1]=P1 CCW, [2]=P1 thrust, [3]=P1 CW
    //   [4]=P2 fire, [5]=P2 CCW, [6]=P2 thrust, [7]=P2 CW
    //
    // w_btn_direct[6:0] = direct debounced buttons (no SW[0] mode):
    //   [1]=UP, [2]=DOWN, [3]=LEFT, [4]=RIGHT, [5]=F1, [6]=F2
    //
    // Combined mapping: Spacewar via joystick_emu, Pong via btn_direct
    // -------------------------------------------------------------------------
    wire [17:0] w_gamepad_in;
    assign w_gamepad_in = {
        w_joystick_emu[3],                        // bit 17 - P1 CW (Spacewar)
        w_joystick_emu[1],                        // bit 16 - P1 CCW (Spacewar)
        w_joystick_emu[2],                        // bit 15 - P1 thrust (Spacewar)
        w_joystick_emu[0] | w_btn_direct[2],      // bit 14 - P1 fire (Spacewar) | DOWN (Pong P1 DOWN)
        w_btn_direct[1],                          // bit 13 - UP (backup) - Pong ne koristi bit 13
        9'b0,                                     // bits 12-4 unused
        w_joystick_emu[7],                        // bit 3 - P2 CW (Spacewar)
        w_joystick_emu[5],                        // bit 2 - P2 CCW (Spacewar)
        w_joystick_emu[6] | w_btn_direct[5],      // bit 1 - P2 thrust (Spacewar) | F1 (Pong P2 UP)
        w_joystick_emu[4] | w_btn_direct[6]       // bit 0 - P2 fire (Spacewar) | F2 (Pong P2 DOWN)
    };

    // -------------------------------------------------------------------------
    // Console switches for CPU control (clk_cpu domain)
    // -------------------------------------------------------------------------
    // Start button generates extended pulse on reset release to auto-start
    // execution. Extended to 200+ cycles to ensure CPU captures the signal.
    //
    // ESP32 OSD Status Control (when ESP32_OSD defined):
    //   status[0] = CPU RUN request (rising edge triggers start)
    //   status[1] = CPU HALT request (1=halt, 0=run)
    //   status[2] = CPU RESET request (rising edge triggers reset)
    // -------------------------------------------------------------------------
    reg [7:0] r_start_pulse_counter;
    wire w_start_button_pulse;

`ifdef ESP32_OSD
    // -------------------------------------------------------------------------
    // ESP32 Status CDC: clk_pixel -> clk_cpu domain
    // -------------------------------------------------------------------------
    // w_osd_status comes from esp32_osd which runs on clk_sys (=clk_cpu here)
    // BUT status changes are triggered by SPI which is async, so we need CDC
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_osd_status_sync_meta, r_osd_status_sync;
    reg [2:0] r_osd_status_prev;  // For edge detection

    // -------------------------------------------------------------------------
    // LED Debug: Sticky signals for visual debugging
    // -------------------------------------------------------------------------
    // Fast SPI signals are latched so they stay ON long enough to see.
    // Clear on button press (btn[6]) for manual reset.
    // NOTE: w_debug_* signals are connected later in esp32_osd instance
    // -------------------------------------------------------------------------
    reg r_spi_cs_seen;        // CS# went LOW at least once
    reg r_spi_activity_seen;  // SPI clock toggled while CS active
    reg r_osd_enable_seen;    // OSD enable command received (sticky)
    reg r_osd_write_seen;     // OSD buffer write occurred (sticky)
    reg r_spi_rx_seen;        // SPI RX valid seen (sticky)
    reg [23:0] r_led_blink;   // Blink counter for heartbeat

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_osd_status_sync_meta <= 3'b0;
            r_osd_status_sync      <= 3'b0;
            r_osd_status_prev      <= 3'b0;
            r_spi_cs_seen          <= 1'b0;
            r_spi_activity_seen    <= 1'b0;
            r_osd_enable_seen      <= 1'b0;
            r_osd_write_seen       <= 1'b0;
            r_spi_rx_seen          <= 1'b0;
            r_led_blink            <= 24'd0;
            led                    <= 8'b0;
        end else begin
            // 2-stage synchronizer for status bits [2:0]
            r_osd_status_sync_meta <= w_osd_status[2:0];
            r_osd_status_sync      <= r_osd_status_sync_meta;
            r_osd_status_prev      <= r_osd_status_sync;

            // Blink counter for heartbeat (shows FPGA is running)
            r_led_blink <= r_led_blink + 1'b1;

            // Sticky debug signals - latch when event occurs
            // NOTE: These check RAW pins before synchronizers
            if (~esp32_spi_cs_n)
                r_spi_cs_seen <= 1'b1;
            if (~esp32_spi_cs_n && esp32_spi_clk)
                r_spi_activity_seen <= 1'b1;
            // Check synchronized signals from SPI slave module
            if (w_debug_spi_rx_valid)
                r_spi_rx_seen <= 1'b1;
            if (w_debug_osd_enable)
                r_osd_enable_seen <= 1'b1;
            if (w_debug_osd_wr_en)
                r_osd_write_seen <= 1'b1;

            // Clear sticky flags on btn[6] press (active-low, directly from hardware)
            if (~btn[6]) begin
                r_spi_cs_seen       <= 1'b0;
                r_spi_activity_seen <= 1'b0;
                r_osd_enable_seen   <= 1'b0;
                r_osd_write_seen    <= 1'b0;
                r_spi_rx_seen       <= 1'b0;
            end

            // LED mapping for BUTTON DEBUG (temporary):
            // LED[0] = Heartbeat (blink ~3Hz shows FPGA is running)
            // LED[1-6] = w_btn_direct[1-6] directly (button state)
            // LED mapping for Button Debug:
            // LED[0] = Heartbeat (shows FPGA running)
            // LED[1-6] = Button state (BTN UP/DOWN/LEFT/RIGHT/F1/F2)
            // LED[7] = OSD IRQ pending
            led[0] <= r_led_blink[23];   // Heartbeat ~3Hz
            led[1] <= w_btn_direct[1];   // BTN UP
            led[2] <= w_btn_direct[2];   // BTN DOWN
            led[3] <= w_btn_direct[3];   // BTN LEFT
            led[4] <= w_btn_direct[4];   // BTN RIGHT
            led[5] <= w_btn_direct[5];   // BTN F1
            led[6] <= w_btn_direct[6];   // BTN F2
            led[7] <= esp32_osd_irq;     // OSD IRQ to ESP32
        end
    end

    // Edge detection for status control
    wire w_esp32_run_edge   = r_osd_status_sync[0] & ~r_osd_status_prev[0];  // Rising edge = start
    wire w_esp32_halt       = r_osd_status_sync[1];                           // Level = halt
    wire w_esp32_reset_edge = r_osd_status_sync[2] & ~r_osd_status_prev[2];  // Rising edge = reset

    // NOTE: RIM load completion detection is handled later in the file
    // after r_rim_done is declared. w_rim_load_complete wire is declared here
    // but assigned later.

    // Forward declaration of wire - assigned after RIM FSM is declared
    wire w_rim_load_complete;

    // CPU start pulse generation - triggered by:
    // 1. Initial reset release (auto-start)
    // 2. ESP32 RUN command (status[0] rising edge)
    // 3. RIM load completion (auto-start with new address)
    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_start_pulse_counter <= 8'd5;  // Initial auto-start
        end else if (w_esp32_run_edge | w_rim_load_complete) begin
            r_start_pulse_counter <= 8'd5;  // Trigger start pulse
        end else if (r_start_pulse_counter > 0) begin
            r_start_pulse_counter <= r_start_pulse_counter - 1'b1;
        end
    end

    // Generate start pulse while counter > 0 (short pulse only)
    // CRITICAL: Long pulse blocks CPU state machine from executing!
    assign w_start_button_pulse = (r_start_pulse_counter > 0) & ~w_esp32_halt;
`else
    // Non-ESP32 build: simple auto-start on reset
    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_start_pulse_counter <= 8'd5;  // SHORT pulse - only 5 cycles!
        end else if (r_start_pulse_counter > 0) begin
            r_start_pulse_counter <= r_start_pulse_counter - 1'b1;
        end
    end

    // Generate start pulse while counter > 0 (short pulse only)
    // CRITICAL: Long pulse blocks CPU state machine from executing!
    assign w_start_button_pulse = (r_start_pulse_counter > 0);
`endif

    wire [10:0] w_console_switches;
    assign w_console_switches = {
        1'b0,                  // bit 10 - power switch (0=on)
        1'b0,                  // bit 9 - single step
        1'b0,                  // bit 8 - single inst
        1'b0,                  // bit 7 - tape feed
        1'b0,                  // bit 6 - reader
        1'b0,                  // bit 5 - read in
        1'b0,                  // bit 4 - deposit
        1'b0,                  // bit 3 - examine
        1'b0,                  // bit 2 - continue
`ifdef ESP32_OSD
        w_esp32_halt,          // bit 1 - stop (ESP32 halt request)
`else
        1'b0,                  // bit 1 - stop
`endif
        w_start_button_pulse   // bit 0 - start (pulse on reset release)
    };

    // Test word and address switches (active-high)
    // When SERIAL_LOADER is enabled, these can be set via serial commands
`ifdef SERIAL_LOADER
    wire [17:0] w_test_word;       // Set by serial loader
    wire [11:0] w_test_address_12; // Set by serial loader (12-bit)
    wire [17:0] w_test_address = {6'b0, w_test_address_12};  // Extend to 18-bit
`else
    //wire [17:0] w_test_word    = 18'b0;
    wire [17:0] w_test_word = 18'b011_011_111_111_010_010;  // Binarno
    wire [17:0] w_test_address = 18'o4;     // Start address: octal 4 (Spacewar entry point)
    //wire [17:0] w_test_address = 18'o100;   // snowflake
`endif 

    // =========================================================================
    // CDC: DIP SWITCH SYNCHRONIZATION (External -> clk_cpu domain)
    // =========================================================================
    // PROBLEM: sw[3:0] and btn[5:4] are external inputs (asynchronous to clk_cpu)
    // SOLUTION: 2-stage synchronizer with ASYNC_REG attribute for proper
    //           metastability handling (HDL Guidelines 07_CDC_GUIDELINES).
    //
    // CDC Path: External pins -> 2FF sync -> sense_switches
    // ASYNC_REG ensures synthesis places FFs close together for best MTBF.
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_sync_meta, r_sw_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_btn_sync_meta, r_btn_sync;

    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            r_sw_sync_meta  <= 4'b0;
            r_sw_sync       <= 4'b0;
            r_btn_sync_meta <= 2'b0;
            r_btn_sync      <= 2'b0;
        end else begin
            // 2-stage synchronizer for sw[3:0]
            r_sw_sync_meta <= sw;
            r_sw_sync      <= r_sw_sync_meta;
            // 2-stage synchronizer for btn[5:4] (inverted: active-low -> active-high)
            r_btn_sync_meta <= ~btn[5:4];
            r_btn_sync      <= r_btn_sync_meta;
        end
    end

    // -------------------------------------------------------------------------
    // Sense switches mapping (active-high, clk_cpu domain):
    //   [5:4] = r_btn_sync (BTN[5:4] for additional options)
    //   [3]   = r_sw_sync[3] (SW[3])
    //   [2]   = r_sw_sync[2] (SW[2])
    //   [1]   = 1'b1 (HARDCODED - starfield ALWAYS ON for explosions visibility)
    //   [0]   = r_sw_sync[0] (SW[0])
    //
    // NOTE: SW[1] controls ONLY serial debug (via w_single_player signal),
    //       NOT starfield. This separation fixes the explosion visibility bug.
    // FIX: Jelena - sense_switches[1] was passing SW[1] instead of hardcoded 1'b1
    // -------------------------------------------------------------------------
    wire [5:0] w_sense_switches = {r_btn_sync, r_sw_sync[3:2], 1'b1, r_sw_sync[0]};

    // NOTE: ADC MAX11123 moved to top_oscilloscope.v

    // =========================================================================
    // SERIAL LOADER (Optional - enabled with -DSERIAL_LOADER)
    // =========================================================================
    // Allows loading programs via UART without rebuilding FPGA bitstream.
    // Protocol: 'L'=load, 'W'=test_word, 'A'=test_address, 'R'=run, 'S'=stop, 'P'=ping
    // -------------------------------------------------------------------------
`ifdef SERIAL_LOADER
    wire [11:0] w_loader_addr;
    wire [17:0] w_loader_data;
    wire        w_loader_we;
    wire        w_loader_active;
    wire        w_loader_cpu_run;
    wire        w_loader_cpu_halt;
    wire [7:0]  w_loader_debug_state;

    serial_loader #(
        .CLK_FREQ (C_CPU_CLK_FREQ)
    ) u_serial_loader (
        .clk          (clk_cpu),
        .rst_n        (rst_cpu_n),
        .uart_rx      (ftdi_txd),      // FPGA receives from FTDI TX
        .uart_tx      (),              // TX handled by serial_debug or directly
        .loader_addr  (w_loader_addr),
        .loader_data  (w_loader_data),
        .loader_we    (w_loader_we),
        .test_word    (w_test_word),
        .test_address (w_test_address_12),
        .cpu_run      (w_loader_cpu_run),
        .cpu_halt     (w_loader_cpu_halt),
        .loader_active(w_loader_active),
        .debug_state  (w_loader_debug_state)
    );

    // RAM interface MUX: Loader vs CPU
    // When loader is writing, it takes priority over CPU
`ifdef ESP32_OSD
    // With ESP32 OSD: RIM loader has highest priority, then serial loader, then CPU
    wire [11:0] w_ram_addr = r_rim_write_en ? r_rim_write_addr :
                             w_loader_we    ? w_loader_addr    : w_cpu_mem_addr;
    wire [17:0] w_ram_data = r_rim_write_en ? r_rim_write_data :
                             w_loader_we    ? w_loader_data    : w_cpu_mem_data_out;
    wire        w_ram_we   = r_rim_write_en ? 1'b1 :
                             w_loader_we    ? 1'b1             : w_cpu_mem_we;
`else
    wire [11:0] w_ram_addr = w_loader_we ? w_loader_addr : w_cpu_mem_addr;
    wire [17:0] w_ram_data = w_loader_we ? w_loader_data : w_cpu_mem_data_out;
    wire        w_ram_we   = w_loader_we ? 1'b1 : w_cpu_mem_we;
`endif
`else
    // Normal operation - direct CPU connection to RAM (may include RIM loader)
`ifdef ESP32_OSD
    // With ESP32 OSD: RIM loader has priority over CPU
    wire [11:0] w_ram_addr = r_rim_write_en ? r_rim_write_addr : w_cpu_mem_addr;
    wire [17:0] w_ram_data = r_rim_write_en ? r_rim_write_data : w_cpu_mem_data_out;
    wire        w_ram_we   = r_rim_write_en ? 1'b1             : w_cpu_mem_we;
`else
    wire [11:0] w_ram_addr = w_cpu_mem_addr;
    wire [17:0] w_ram_data = w_cpu_mem_data_out;
    wire        w_ram_we   = w_cpu_mem_we;
`endif
`endif

    // =========================================================================
    // PDP-1 MAIN RAM (4096 x 18-bit, clk_cpu domain)
    // =========================================================================
    pdp1_main_ram u_main_ram (
        // Port A - CPU/Loader interface (clk_cpu domain)
        .address_a  (w_ram_addr),
        .clock_a    (clk_cpu),
        .data_a     (w_ram_data),
        .wren_a     (w_ram_we),
        .q_a        (w_cpu_mem_data_in),

        // Port B - unused (explicitly tied off)
        .address_b  (12'b0),
        .clock_b    (clk_cpu),
        .data_b     (18'b0),
        .wren_b     (1'b0),
        .q_b        ()              // Unconnected output (intentional)
    );

    // =========================================================================
    // PDP-1 CPU (clk_cpu domain)
    // =========================================================================
    pdp1_cpu u_cpu (
        .clk                    (clk_cpu),
        .rst                    (~rst_cpu_n),       // CPU uses active-high reset

        // Memory interface (clk_cpu domain)
        .MEM_ADDR               (w_cpu_mem_addr),
        .DI                     (w_cpu_mem_data_in),
        .MEM_BUFF               (w_cpu_mem_data_out),
        .WRITE_ENABLE           (w_cpu_mem_we),

        // Register outputs for debug
        .AC                     (w_cpu_ac),
        .IO                     (w_cpu_io),
        .PC                     (w_cpu_pc),
        .BUS_out                (w_cpu_bus_out),

        // Gamepad input (active-high)
        .gamepad_in             (w_gamepad_in),

        // CRT output (clk_cpu domain - requires CDC to clk_pixel!)
        .pixel_x_out            (w_cpu_pixel_x),
        .pixel_y_out            (w_cpu_pixel_y),
        .pixel_brightness       (w_cpu_pixel_brightness),
        .pixel_shift_out        (w_cpu_pixel_shift),

        // Typewriter interface (active-high)
        .typewriter_char_out    (w_typewriter_char_out),
        .typewriter_strobe_out  (w_typewriter_strobe_out),
        .typewriter_char_in     (6'b0),             // Not connected
        .typewriter_strobe_in   (1'b0),             // Not connected
        .typewriter_strobe_ack  (w_typewriter_strobe_ack),

        // Paper tape interface
        .send_next_tape_char    (w_send_next_tape_char),
`ifdef ESP32_OSD
        .is_char_available      (w_rim_char_available),
        .tape_rcv_word          (w_rim_tape_word),
`else
        .is_char_available      (1'b0),
        .tape_rcv_word          (18'b0),
`endif

        // Start address
`ifdef ESP32_OSD
        .start_address          (r_rim_start_addr), // From RIM loader or default
`else
        .start_address          (12'o4),            // Spacewar entry point
`endif

        // Configuration
        .hw_mul_enabled         (1'b1),             // Enable hardware multiply/divide
        .crt_wait               (1'b1),             // Enable CRT wait for timing

        // Console switches (clk_cpu domain, synchronized)
        .console_switches       (w_console_switches),
        .test_word              (w_test_word),
        .test_address           (w_test_address),
        .sense_switches         (w_sense_switches),

        // Debug outputs
        .debug_instr_count      (w_cpu_debug_instr_count),
        .debug_iot_count        (w_cpu_debug_iot_count),
        .debug_cpu_running      (w_cpu_debug_running),
        .debug_cpu_state        (w_cpu_debug_state),

        // Pixel debug outputs
        .debug_pixel_count      (w_cpu_debug_pixel_count),
        .debug_pixel_x          (w_cpu_debug_pixel_x),
        .debug_pixel_y          (w_cpu_debug_pixel_y),
        .debug_pixel_brightness (w_cpu_debug_pixel_brightness)
        // NOTE: External IO interface (ADC) moved to top_oscilloscope.v
    );

    // =========================================================================
    // CDC: MULTI-BIT PIXEL DATA (clk_cpu -> clk_pixel)
    // =========================================================================
    // PROBLEM: 23 bits (10+10+3) transferred across CDC without handshake.
    //          Each bit may have different latency through 2FF sync, causing
    //          inconsistent coordinates (e.g., X=old value, Y=new value).
    //
    // SOLUTION: HOLD registers in CPU domain keep data stable for 8 CPU cycles
    //           (~1.28us at 6.25 MHz), which is long enough for pixel clock
    //           (51 MHz) to sample stable data.
    //
    //           Timing analysis:
    //           - 8 CPU cycles = 8 * 160ns = 1.28us
    //           - At 51 MHz: 1.28us = ~65 pixel clock cycles
    //           - 3-stage sync needs only 3 pixel cycles -> plenty of margin!
    //
    // CDC Path: w_cpu_pixel_* -> r_pixel_*_hold -> [stable] -> 3FF sync -> CRT
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
                // Latch new pixel and hold stable for CDC
                // Direct CPU coordinates (no test pattern MUX)
                r_pixel_x_hold          <= w_cpu_pixel_x;
                r_pixel_y_hold          <= w_cpu_pixel_y;
                r_pixel_brightness_hold <= w_cpu_pixel_brightness;
                r_pixel_hold_counter    <= 4'd8;    // Hold 8 CPU cycles (~1.28us)
                r_pixel_hold_valid      <= 1'b1;
            end else if (r_pixel_hold_counter > 0) begin
                r_pixel_hold_counter <= r_pixel_hold_counter - 1'b1;
                if (r_pixel_hold_counter == 1)
                    r_pixel_hold_valid <= 1'b0;
            end
        end
    end

    // Map HOLD outputs to generic pixel signals (for CRT display)
    // HOLD registers guarantee stable data during CDC transfer
    wire [9:0] w_test_pixel_x     = r_pixel_x_hold;
    wire [9:0] w_test_pixel_y     = r_pixel_y_hold;
    wire [2:0] w_test_brightness  = r_pixel_brightness_hold;
    wire       w_test_pixel_avail = r_pixel_hold_valid;

    // =========================================================================
    // CDC: PIXEL VALID SYNCHRONIZATION (clk_cpu -> clk_pixel)
    // =========================================================================
    // Architecture (HDL Guidelines 07_CDC_GUIDELINES):
    //
    // CPU Domain (6.25 MHz)          |  Pixel Domain (51 MHz)
    // --------------------------------|--------------------------------
    // w_cpu_pixel_shift --+          |
    //                     |          |
    // w_cpu_pixel_x/y ----+-> HOLD --|--> w_test_pixel_x/y (STABLE!)
    //                     |  (8 cyc) |
    // r_pixel_hold_valid -+----------|--> [3-stage sync] --> w_pixel_avail_synced
    //                                |          |
    //                                |    [Latch on rising edge]
    //                                |          |
    //                                |    r_pixel_x_sync/y_sync
    //
    // HOLD registers keep data stable for 8 CPU cycles (~1.28us).
    // 3-stage sync for valid signal ensures metastability protection.
    // Coordinates latched when valid is stable - data guaranteed stable too!
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] r_pixel_avail_sync;  // 3-stage synchronizer
    reg [9:0] r_pixel_x_sync;
    reg [9:0] r_pixel_y_sync;
    reg [2:0] r_brightness_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_avail_sync <= 3'b0;
            r_pixel_x_sync     <= 10'd240;  // Center of screen default
            r_pixel_y_sync     <= 10'd240;
            r_brightness_sync  <= 3'b0;
        end else begin
            // 3-stage sync for metastability protection on valid signal
            r_pixel_avail_sync <= {r_pixel_avail_sync[1:0], w_test_pixel_avail};

            // Latch coordinates on rising edge detection
            // SAFE: coordinates come from HOLD registers and are stable!
            if (r_pixel_avail_sync[1] && !r_pixel_avail_sync[2]) begin
                r_pixel_x_sync    <= w_test_pixel_x;
                r_pixel_y_sync    <= w_test_pixel_y;
                r_brightness_sync <= w_test_brightness;
            end
        end
    end

    // Synchronized pixel_available signal (single-cycle pulse in clk_pixel domain)
    wire w_pixel_avail_synced = r_pixel_avail_sync[1] && !r_pixel_avail_sync[2];
    wire [9:0] w_pixel_x_sync    = r_pixel_x_sync;
    wire [9:0] w_pixel_y_sync    = r_pixel_y_sync;
    wire [2:0] w_brightness_sync = r_brightness_sync;

    pdp1_vga_crt u_crt_display
    (
        .i_clk              (clk_pixel),
        .i_rst_n            (rst_pixel_n),          // Reset added by Jelena for r_pass_counter

        .i_h_counter        (r_h_counter),
        .i_v_counter        (r_v_counter),

        .o_red              (w_crt_r),
        .o_green            (w_crt_g),
        .o_blue             (w_crt_b),

        // Pixel input from CPU (CDC synchronized!)
        .i_pixel_x          (w_pixel_x_sync),
        .i_pixel_y          (w_pixel_y_sync),
        .i_pixel_brightness (w_brightness_sync),
        .i_variable_brightness(1'b1),
        .i_pixel_valid      (w_pixel_avail_synced),

        // Debug outputs
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
    // ESP32 OSD INTEGRATION (Optional, dual clock domain)
    // =========================================================================
`ifdef ESP32_OSD
    wire [23:0] w_osd_video_out;
    wire        w_osd_de_out, w_osd_hs_out, w_osd_vs_out;
    wire [31:0] w_osd_status;
    wire [15:0] w_osd_joystick_0, w_osd_joystick_1;

    // Video input to OSD (CRT RGB packed)
    wire [23:0] w_crt_video_in = {w_crt_r, w_crt_g, w_crt_b};

    // Pixel coordinates for OSD positioning
    wire [11:0] w_osd_pixel_x = (r_h_counter >= `h_visible_offset) ?
                                (r_h_counter - `h_visible_offset) : 12'd0;
    wire [11:0] w_osd_pixel_y = (r_v_counter >= `v_visible_offset) ?
                                (r_v_counter - `v_visible_offset) : 12'd0;

    // ioctl interface signals from ESP32 OSD
    wire        w_ioctl_download;
    wire  [7:0] w_ioctl_index;
    wire        w_ioctl_wr;
    wire [24:0] w_ioctl_addr;
    wire  [7:0] w_ioctl_dout;
    wire        w_ioctl_wait;

    // RIM loader signals back to CPU
    wire        w_rim_char_available;
    wire [17:0] w_rim_tape_word;

    // Debug signals from ESP32 OSD module
    wire        w_debug_osd_enable;
    wire        w_debug_osd_wr_en;
    wire        w_debug_spi_rx_valid;

    // Internal MISO signals for tristate control
    wire w_spi_miso_data;
    wire w_spi_miso_oe;

    // Tristate driver for MISO (GPIO12 is ESP32 strapping pin!)
    // CRITICAL: Must be HIGH-Z when CS is inactive to allow ESP32 to boot properly
    assign esp32_spi_miso = w_spi_miso_oe ? w_spi_miso_data : 1'bz;

    esp32_osd #(
        .OSD_COLOR    (3'd4),       // Blue OSD color
        .OSD_X_OFFSET (12'd384),    // Centered for 1024x768
        .OSD_Y_OFFSET (12'd320)     // Centered for 1024x768
    ) u_esp32_osd (
        .clk_sys      (clk_cpu),
        .clk_video    (clk_pixel),
        .rst_n        (rst_pixel_n),
        // ESP32 SPI interface (asynchronous to FPGA clocks)
        .spi_clk      (esp32_spi_clk),
        .spi_mosi     (esp32_spi_mosi),
        .spi_miso     (w_spi_miso_data),
        .spi_miso_oe  (w_spi_miso_oe),
        .spi_cs_n     (esp32_spi_cs_n),
        .osd_irq      (esp32_osd_irq),
        .esp32_ready  (esp32_ready),
        // Button inputs for IRQ generation (debounced, active-high)
        .btn_state    (w_btn_direct),
        // Video input (clk_pixel domain)
        .video_in     (w_crt_video_in),
        .de_in        (w_vga_de),
        .hs_in        (w_vga_hsync),
        .vs_in        (w_vga_vsync),
        .pixel_x      (w_osd_pixel_x),
        .pixel_y      (w_osd_pixel_y),
        // Video output (clk_pixel domain)
        .video_out    (w_osd_video_out),
        .de_out       (w_osd_de_out),
        .hs_out       (w_osd_hs_out),
        .vs_out       (w_osd_vs_out),
        // Status outputs
        .status       (w_osd_status),
        .joystick_0   (w_osd_joystick_0),
        .joystick_1   (w_osd_joystick_1),
        // File I/O (ioctl) interface for RIM loading
        .ioctl_download (w_ioctl_download),
        .ioctl_index    (w_ioctl_index),
        .ioctl_wr       (w_ioctl_wr),
        .ioctl_addr     (w_ioctl_addr),
        .ioctl_dout     (w_ioctl_dout),
        .ioctl_wait     (w_ioctl_wait),
        // Debug outputs
        .debug_osd_enable   (w_debug_osd_enable),
        .debug_osd_wr_en    (w_debug_osd_wr_en),
        .debug_spi_rx_valid (w_debug_spi_rx_valid),
        // Fallback OSD enable via DIP switch SW[2]
        // When SW[2]=ON, OSD is always visible (for testing without SPI)
        .ext_osd_enable     (sw[2])
    );

    // -------------------------------------------------------------------------
    // LED Debug: Sticky OSD signals (clk_cpu domain)
    // -------------------------------------------------------------------------
    // Update sticky signals based on debug outputs from esp32_osd.
    // This block runs in clk_cpu domain, same as esp32_osd.clk_sys.
    // -------------------------------------------------------------------------
    always @(posedge clk_cpu) begin
        if (~rst_cpu_n) begin
            // Reset handled in main LED always block above
        end else begin
            // Latch OSD debug signals (sticky)
            if (w_debug_osd_enable)
                r_osd_enable_seen <= 1'b1;
            if (w_debug_osd_wr_en)
                r_osd_write_seen <= 1'b1;
            if (w_debug_spi_rx_valid)
                r_spi_rx_seen <= 1'b1;
        end
    end

    // =========================================================================
    // RIM PAPER TAPE LOADER FSM (clk_cpu domain)
    // =========================================================================
    // Decodes RIM format paper tape data from ESP32 ioctl interface.
    // RIM format: 6 bytes per instruction, bit 7 set = valid data byte.
    // Extracts 6 bits from each byte, assembles 36-bit word:
    //   [35:30] = opcode (DIO=32o, JMP=60o)
    //   [29:18] = address
    //   [17:0]  = data
    //
    // DIO instruction: Writes data to specified address
    // JMP instruction: Sets start address and ends loading
    // -------------------------------------------------------------------------

    // RIM opcodes (octal)
    localparam [5:0] RIM_DIO_OPCODE = 6'o32;  // Deposit I/O
    localparam [5:0] RIM_JMP_OPCODE = 6'o60;  // Jump

    // RIM state registers
    reg [35:0] r_rim_buffer;        // 6 bytes = 36 bits assembled
    reg [2:0]  r_rim_byte_cnt;      // 0-5 counter
    reg        r_rim_word_ready;    // Word assembled flag
    reg        r_rim_active;        // RIM mode active
    reg [11:0] r_rim_write_addr;    // DIO target address
    reg [17:0] r_rim_write_data;    // DIO data word
    reg        r_rim_write_en;      // Write strobe to RAM
    reg [11:0] r_rim_start_addr;    // JMP target (start address)
    reg        r_rim_done;          // Loading complete flag
    reg        r_rim_char_avail;    // Character available for CPU tape interface
    reg [17:0] r_rim_tape_word;     // Word for CPU tape interface

    // Synchronize ioctl signals to clk_cpu domain (they come from clk_sys=clk_cpu, same domain)
    // Since clk_sys == clk_cpu in this design, no CDC needed for ioctl signals

    // RIM FSM
    always @(posedge clk_cpu or negedge rst_cpu_n) begin
        if (!rst_cpu_n) begin
            r_rim_buffer      <= 36'b0;
            r_rim_byte_cnt    <= 3'b0;
            r_rim_word_ready  <= 1'b0;
            r_rim_active      <= 1'b0;
            r_rim_write_addr  <= 12'b0;
            r_rim_write_data  <= 18'b0;
            r_rim_write_en    <= 1'b0;
            r_rim_start_addr  <= 12'o4;  // Default start address
            r_rim_done        <= 1'b0;
            r_rim_char_avail  <= 1'b0;
            r_rim_tape_word   <= 18'b0;
        end else begin
            // Default: clear single-cycle strobes
            r_rim_write_en   <= 1'b0;
            r_rim_word_ready <= 1'b0;

            if (w_ioctl_download && w_ioctl_wr) begin
                // Only process bytes with bit 7 set (RIM marker)
                if (w_ioctl_dout[7]) begin
                    r_rim_active <= 1'b1;
                    // Shift in 6 data bits (bits 5:0)
                    r_rim_buffer <= {r_rim_buffer[29:0], w_ioctl_dout[5:0]};
                    r_rim_byte_cnt <= r_rim_byte_cnt + 1'b1;

                    if (r_rim_byte_cnt == 3'd5) begin
                        // 6 bytes received, word complete
                        r_rim_byte_cnt   <= 3'b0;
                        r_rim_word_ready <= 1'b1;
                    end
                end
            end

            // Decode assembled instruction
            if (r_rim_word_ready) begin
                // r_rim_buffer layout after shift:
                //   [35:30] = opcode (first 6 bits received)
                //   [29:18] = address (next 12 bits)
                //   [17:0]  = data (last 18 bits)

                if (r_rim_buffer[35:30] == RIM_DIO_OPCODE) begin
                    // DIO: Store data at address via direct RAM write
                    r_rim_write_addr <= r_rim_buffer[29:18];
                    r_rim_write_data <= r_rim_buffer[17:0];
                    r_rim_write_en   <= 1'b1;
                end

                if (r_rim_buffer[35:30] == RIM_JMP_OPCODE) begin
                    // JMP: End of tape, set start address
                    r_rim_start_addr <= r_rim_buffer[29:18];
                    r_rim_done       <= 1'b1;
                    r_rim_active     <= 1'b0;
                end

                // Also provide word to CPU tape interface (for compatibility)
                r_rim_tape_word  <= r_rim_buffer[17:0];
                r_rim_char_avail <= 1'b1;
            end else begin
                r_rim_char_avail <= 1'b0;
            end

            // Clear done flag when download ends
            if (!w_ioctl_download && r_rim_done) begin
                r_rim_done <= 1'b0;
            end
        end
    end

    // ioctl_wait: Signal ESP32 to pause if we're busy processing
    // For now, never wait (fast enough to keep up with SPI)
    assign w_ioctl_wait = 1'b0;

    // Export RIM loader signals for CPU tape interface
    assign w_rim_char_available = r_rim_char_avail;
    assign w_rim_tape_word      = r_rim_tape_word;

    // -------------------------------------------------------------------------
    // RIM Load Completion -> CPU Start Trigger
    // -------------------------------------------------------------------------
    // When RIM load completes (JMP instruction received), generate a pulse
    // to trigger CPU restart with the new start address (r_rim_start_addr).
    // w_rim_load_complete is a wire declared earlier (forward declaration).
    // -------------------------------------------------------------------------
    reg r_rim_done_prev;

    always @(posedge clk_cpu or negedge rst_cpu_n) begin
        if (!rst_cpu_n)
            r_rim_done_prev <= 1'b0;
        else
            r_rim_done_prev <= r_rim_done;
    end

    // Rising edge detection - this is assigned to the forward-declared wire
    assign w_rim_load_complete = r_rim_done & ~r_rim_done_prev;
`endif

    // =========================================================================
    // VGA RGB OUTPUT SELECTION (clk_pixel domain)
    // =========================================================================
    // SW[3] = 0: CRT output (with OSD if enabled)
    // SW[3] = 1: Test pattern (debugging color bars)
    // -------------------------------------------------------------------------
    wire [7:0] w_vga_r, w_vga_g, w_vga_b;

`ifdef ESP32_OSD
    // OSD overlay output (when ESP32 OSD is enabled)
    assign w_vga_r = w_osd_video_out[23:16];
    assign w_vga_g = w_osd_video_out[15:8];
    assign w_vga_b = w_osd_video_out[7:0];
`else
    // Direct CRT output (no OSD, no test pattern switching)
    assign w_vga_r = w_crt_r;
    assign w_vga_g = w_crt_g;
    assign w_vga_b = w_crt_b;
`endif

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
    // DEBUG: LED INDICATORS (clk_pixel domain, human-visible rate)
    // =========================================================================
    // Compile-time option: -DENABLE_LED_DEBUG to enable LED debug indicators
    // Without this define, LEDs are driven to constant 0 (off)
    // -------------------------------------------------------------------------
`ifdef ENABLE_LED_DEBUG
    // LED divider creates ~1.5Hz blink rate for human observation.
    // 51MHz / 2^25 = ~1.52 Hz
    reg [24:0] r_led_divider;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_led_divider <= 25'd0;
        else
            r_led_divider <= r_led_divider + 1'b1;
    end

    // Latch activity signals on slow clock for human visibility
    reg r_pixel_valid_seen;
    reg r_rowbuff_write_seen;
    reg r_inside_visible_seen;
    reg r_pixel_to_rowbuff_seen;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_pixel_valid_seen    <= 1'b0;
            r_rowbuff_write_seen  <= 1'b0;
            r_inside_visible_seen <= 1'b0;
            r_pixel_to_rowbuff_seen <= 1'b0;
        end else begin
            // Reset on each slow clock tick (~0.5s period)
            if (r_led_divider[24]) begin
                r_pixel_valid_seen    <= 1'b0;
                r_rowbuff_write_seen  <= 1'b0;
                r_inside_visible_seen <= 1'b0;
                r_pixel_to_rowbuff_seen <= 1'b0;
            end else begin
                // Latch if event occurred
                if (w_pixel_avail_synced)
                    r_pixel_valid_seen <= 1'b1;
                // DEBUG: Latch rowbuffer write activity
                if (w_crt_debug_rowbuff_wren)
                    r_rowbuff_write_seen <= 1'b1;
                // DEBUG: Latch inside_visible_area activity
                if (w_crt_debug_inside_visible)
                    r_inside_visible_seen <= 1'b1;
                // DEBUG: Latch pixel written to rowbuffer (non-zero data)
                if (w_crt_debug_pixel_to_rowbuff)
                    r_pixel_to_rowbuff_seen <= 1'b1;
            end
        end
    end

    // =========================================================================
    // COMPREHENSIVE LED DEBUG (clk_pixel domain)
    // =========================================================================
    // Note: LED assignments now show CPU debug state directly
    // -------------------------------------------------------------------------

    // CDC: CPU clock enable synchronization (clk_cpu -> clk_pixel)
    reg r_cpu_clk_seen;
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_cpu_clk_sync;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_clk_seen <= 1'b0;
            r_cpu_clk_sync <= 2'b0;
        end else begin
            // 2-stage synchronizer for clk_cpu_en
            r_cpu_clk_sync <= {r_cpu_clk_sync[0], w_clk_cpu_en};
            // Reset on slow clock tick, latch if cpu clock seen
            if (r_led_divider[24])
                r_cpu_clk_seen <= 1'b0;
            else if (r_cpu_clk_sync[1])
                r_cpu_clk_seen <= 1'b1;
        end
    end

    // Frame tick detector for CPU mode (requires UART DEBUG for r_cpu_frame_tick signal)
`ifdef ENABLE_UART_DEBUG
    reg r_frame_tick_seen_cpu;
    always @(posedge clk_pixel) begin
        if (!rst_pixel_n)
            r_frame_tick_seen_cpu <= 1'b0;
        else if (r_led_divider[24])
            r_frame_tick_seen_cpu <= 1'b0;
        else if (r_cpu_frame_tick)
            r_frame_tick_seen_cpu <= 1'b1;
    end
`endif

    // DEBUG: Show CPU state and reset status on LEDs
    // LED[4:0] = CPU state low bits (0-31)
    // LED[5] = CPU reset active (should be 0 during normal operation)
    // LED[6] = cpu_running from CPU debug
    // LED[7] = PLL locked
    //
    // NOTE: When ESP32_OSD is defined, LEDs are driven by the ESP32 debug
    // always block above. These assigns are only active when ESP32_OSD
    // is NOT defined but ENABLE_LED_DEBUG IS defined.
`ifndef ESP32_OSD
    assign led[4:0] = w_cpu_debug_state[4:0];
    assign led[5] = ~rst_cpu_n;  // 1 = reset active
    assign led[6] = w_cpu_debug_running;
    assign led[7] = w_pll_locked;
`endif
//`else
    // LED DEBUG disabled - all LEDs off
    //assign led = 8'b0;
`endif

    // =========================================================================
    // DEBUG: SERIAL OUTPUT (UART TX)
    // =========================================================================
    // Compile-time option: -DENABLE_UART_DEBUG to enable serial debug output
    // Without this define, ftdi_rxd is driven HIGH (idle state for UART)
    // -------------------------------------------------------------------------
`ifdef ENABLE_UART_DEBUG
    // Frame tick generator for CPU mode
    reg        r_cpu_frame_tick;
    reg [10:0] r_cpu_prev_v_counter;

    always @(posedge clk_pixel) begin
        if (!rst_pixel_n) begin
            r_cpu_frame_tick      <= 1'b0;
            r_cpu_prev_v_counter  <= 11'd0;
        end else begin
            r_cpu_prev_v_counter <= r_v_counter;
            // Detect start of new frame (transition into vblank)
            r_cpu_frame_tick <= (r_v_counter == 11'd0) && (r_cpu_prev_v_counter != 11'd0);
        end
    end

    // -------------------------------------------------------------------------
    // CDC NOTE: Debug signal crossing (clk_cpu -> clk_pixel)
    // -------------------------------------------------------------------------
    // w_cpu_pixel_x/y, w_cpu_pc, w_cpu_debug_* signals come from clk_cpu domain
    // without explicit synchronization. This is INTENTIONALLY acceptable because:
    //   1) These are debug signals - occasional metastability causes only
    //      incorrect debug output, does not affect functionality
    //   2) Signals are sampled on frame_tick which is rare (~50Hz)
    //   3) Adding CDC would add latency without real benefit
    // -------------------------------------------------------------------------
    serial_debug #(
        .CLK_FREQ(C_PIXEL_CLK_FREQ)
    ) u_serial_debug_cpu (
        .i_clk                (clk_pixel),
        .i_rst_n              (rst_pixel_n),
        .i_enable             (w_single_player),  // SW[1] synchronized signal
        .i_frame_tick         (r_cpu_frame_tick),
        .i_angle              (w_cpu_pc[7:0]),     // PC low byte
        .i_pixel_x            (w_cpu_pixel_x),
        .i_pixel_y            (w_cpu_pixel_y),
        .i_pixel_valid        (w_cpu_pixel_shift),
        .i_led_status         (led),
        // CRT Pipeline Debug
        .i_pixel_avail_synced (w_pixel_avail_synced),
        .i_crt_wren           (w_crt_debug_wren),
        .i_crt_write_ptr      (w_crt_debug_write_ptr),
        .i_crt_read_ptr       (w_crt_debug_read_ptr),
        .i_search_counter_msb (w_crt_debug_search_counter),
        .i_luma1              (w_crt_debug_luma1),
        .i_rowbuff_write_count(w_crt_debug_rowbuff_write_count),
        // CPU Debug
        .i_cpu_pc             (w_cpu_pc),
        .i_cpu_instr_count    (w_cpu_debug_instr_count),
        .i_cpu_iot_count      (w_cpu_debug_iot_count),
        .i_cpu_running        (w_cpu_debug_running),
        .i_cpu_state          (w_cpu_debug_state),
        // Pixel Debug
        .i_pixel_count        (w_cpu_debug_pixel_count),
        .i_pixel_debug_x      (w_cpu_debug_pixel_x),
        .i_pixel_debug_y      (w_cpu_debug_pixel_y),
        .i_pixel_brightness   (w_cpu_debug_pixel_brightness),
        .i_pixel_shift_out    (w_cpu_pixel_shift),
        .i_ring_buffer_wrptr  (w_crt_debug_ring_buffer_wrptr),
        .o_uart_tx            (ftdi_rxd)
    );
`else
    // UART DEBUG disabled - passthrough ESP32 TX to PC RX for WebREPL
    assign ftdi_rxd = wifi_txd;
`endif

endmodule
