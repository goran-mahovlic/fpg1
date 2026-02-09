// =============================================================================
// Clock Domain Manager
// =============================================================================
// TASK-118: PLL/Clock Adaptation
// Author: Kosjenka Vukovic, REGOC team
// Date: 2026-01-31
//
// FUNCTIONALITY:
// 1. CPU clock passthrough: 5 MHz directly from PLL (no prescaler needed)
// 2. Clock Domain Crossing (CDC) between CPU and Video domains
// 3. Reset sequencing with PLL lock wait
//
// CLOCK DOMAINS:
// - clk_pixel (51 MHz)   : Video/HDMI domain (1024x768@50Hz)
// - clk_cpu_fast (5 MHz) : CPU clock from PLL (direct passthrough)
// - clk_cpu (5 MHz)      : CPU clock output (same as input, within P&R max 5.87 MHz)
// =============================================================================

module clock_domain (
    // PLL inputs
    input  wire clk_pixel,      // 51 MHz pixel clock (1024x768@50Hz)
    input  wire clk_cpu_fast,   // 5 MHz CPU clock from PLL (direct passthrough)
    input  wire pll_locked,     // PLL lock signal
    input  wire rst_n,          // External async reset (active low)

    // Generated clocks
    output wire clk_cpu,        // 5 MHz CPU clock (direct from PLL, no division)
    output reg  clk_cpu_en,     // Clock enable for synchronous design

    // Synchronized resets (active low)
    output reg  rst_pixel_n,    // Reset synchronized to pixel clock
    output reg  rst_cpu_n = 1'b0,      // Reset synchronized to CPU clock (initialized to active reset)

    // CDC interface: CPU -> Video
    input  wire [11:0] cpu_fb_addr,     // Frame buffer address from CPU
    input  wire [11:0] cpu_fb_data,     // Frame buffer data from CPU
    input  wire        cpu_fb_we,       // Write enable from CPU
    output reg  [11:0] vid_fb_addr,     // Synchronized to video domain
    output reg  [11:0] vid_fb_data,     // Synchronized to video domain
    output reg         vid_fb_we,       // Synchronized to video domain

    // CDC interface: Video -> CPU (vertical blank signal)
    input  wire        vid_vblank,      // VBlank from video controller
    output reg         cpu_vblank,      // Synchronized to CPU domain

    // CDC interface: CPU pixel coordinates and control -> Video
    input  wire [9:0]  cpu_pixel_x,     // Pixel X coordinate from CPU (clk_cpu domain)
    input  wire [9:0]  cpu_pixel_y,     // Pixel Y coordinate from CPU (clk_cpu domain)
    input  wire [2:0]  cpu_pixel_brightness, // Pixel brightness from CPU (clk_cpu domain)
    input  wire        cpu_pixel_shift,  // Pixel strobe/shift signal from CPU (clk_cpu domain)
    output reg  [9:0]  vid_pixel_x,     // Synchronized to video domain
    output reg  [9:0]  vid_pixel_y,     // Synchronized to video domain
    output reg  [2:0]  vid_pixel_brightness, // Synchronized to video domain
    output reg         vid_pixel_shift   // Synchronized to video domain
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================

    // Prescaler bypassed: 5 MHz clock directly from PLL (no division needed)
    // Max safe frequency per P&R: 5.87 MHz (current config = 85% utilization)
    localparam PRESCALER_DIV = 1;   // Passthrough mode (no division)
    localparam PRESCALER_BITS = 1;  // Minimum width for counter

    // Reset sequencing: wait 128 cycles after PLL lock
    // 128 cycles @ 5 MHz = 25.6 us - ample time for stabilization
    localparam RESET_DELAY = 128;
    localparam RESET_DELAY_BITS = 8;  // ceil(log2(128)) = 7, use 8 for safety

    // =========================================================================
    // CPU CLOCK PASSTHROUGH (No prescaler - 5 MHz directly from PLL)
    // =========================================================================
    // PLL now generates 5 MHz directly, no division needed.
    // Clock enable pulses every cycle for synchronous design compatibility.

    // Clock enable generation - pulses every cycle when PLL locked
    always @(posedge clk_cpu_fast or negedge rst_n) begin
        if (!rst_n) begin
            clk_cpu_en <= 1'b0;
        end else if (!pll_locked) begin
            clk_cpu_en <= 1'b0;
        end else begin
            clk_cpu_en <= 1'b1;  // Always enabled when PLL locked (5 MHz direct)
        end
    end

    // Direct passthrough - no division, cleaner timing from PLL
    assign clk_cpu = clk_cpu_fast;

    // =========================================================================
    // RESET SEQUENCING
    // =========================================================================
    // Sequence:
    // 1. Wait for PLL lock
    // 2. Wait RESET_DELAY cycles for stabilization
    // 3. Release reset synchronized to each clock domain

    // --- Pixel domain reset synchronizer ---
    // FIX BUG 13: Initialize registers to ensure reset is active on power-up
    reg [RESET_DELAY_BITS-1:0] pixel_rst_cnt = 0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pixel_rst_sync = 3'b000;  // 3-stage synchronizer

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            pixel_rst_sync <= 3'b000;
            pixel_rst_cnt  <= 0;
            rst_pixel_n    <= 1'b0;
        end else begin
            // Synchronize PLL lock signal
            pixel_rst_sync <= {pixel_rst_sync[1:0], pll_locked};

            if (!pixel_rst_sync[2]) begin
                // PLL not locked - hold reset
                pixel_rst_cnt <= 0;
                rst_pixel_n   <= 1'b0;
            end else if (pixel_rst_cnt < RESET_DELAY - 1) begin
                // Wait for stabilization
                pixel_rst_cnt <= pixel_rst_cnt + 1'b1;
                rst_pixel_n   <= 1'b0;
            end else begin
                // Release reset
                rst_pixel_n <= 1'b1;
            end
        end
    end

    // --- CPU domain reset synchronizer ---
    // FIX BUG 13: Initialize registers to ensure reset is active on power-up
    // ECP5 may not honor Verilog initial values, but GSR should help
    reg [RESET_DELAY_BITS-1:0] cpu_rst_cnt = 0;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cpu_rst_sync = 3'b000;  // 3-stage synchronizer

    always @(posedge clk_cpu_fast or negedge rst_n) begin
        if (!rst_n) begin
            cpu_rst_sync <= 3'b000;
            cpu_rst_cnt  <= 0;
            rst_cpu_n    <= 1'b0;
        end else begin
            // Synchronize PLL lock signal
            cpu_rst_sync <= {cpu_rst_sync[1:0], pll_locked};

            if (!cpu_rst_sync[2]) begin
                // PLL not locked - hold reset
                cpu_rst_cnt <= 0;
                rst_cpu_n   <= 1'b0;
            end else if (cpu_rst_cnt < RESET_DELAY - 1) begin
                // Wait for stabilization
                cpu_rst_cnt <= cpu_rst_cnt + 1'b1;
                rst_cpu_n   <= 1'b0;
            end else begin
                // Release reset
                rst_cpu_n <= 1'b1;
            end
        end
    end

    // =========================================================================
    // CLOCK DOMAIN CROSSING: CPU -> VIDEO
    // =========================================================================
    // Uses 2-stage synchronizer for control signals
    // and handshake protocol for data
    //
    // Frame buffer access is relatively slow (CPU @ 1.82 MHz),
    // so simple synchronizer works well

    // Stage 1: Registers in CPU domain (already there from CPU)
    // Stage 2 & 3: Synchronizer in video domain

    // CDC synchronizer registers with ASYNC_REG for proper placement - Kosjenka/REGOC team
    (* ASYNC_REG = "TRUE" *) reg [11:0] fb_addr_sync1, fb_addr_sync2;
    (* ASYNC_REG = "TRUE" *) reg [11:0] fb_data_sync1, fb_data_sync2;
    (* ASYNC_REG = "TRUE" *) reg        fb_we_sync1, fb_we_sync2, fb_we_sync3;

    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if (!rst_pixel_n) begin
            fb_addr_sync1 <= 12'b0;
            fb_addr_sync2 <= 12'b0;
            fb_data_sync1 <= 12'b0;
            fb_data_sync2 <= 12'b0;
            fb_we_sync1   <= 1'b0;
            fb_we_sync2   <= 1'b0;
            fb_we_sync3   <= 1'b0;
            vid_fb_addr   <= 12'b0;
            vid_fb_data   <= 12'b0;
            vid_fb_we     <= 1'b0;
        end else begin
            // 2-stage synchronizer for address and data
            // (data is stable while we is active)
            fb_addr_sync1 <= cpu_fb_addr;
            fb_addr_sync2 <= fb_addr_sync1;
            fb_data_sync1 <= cpu_fb_data;
            fb_data_sync2 <= fb_data_sync1;

            // 3-stage synchronizer for write enable (control signal)
            fb_we_sync1 <= cpu_fb_we;
            fb_we_sync2 <= fb_we_sync1;
            fb_we_sync3 <= fb_we_sync2;

            // Output registers
            vid_fb_addr <= fb_addr_sync2;
            vid_fb_data <= fb_data_sync2;
            // Detect rising edge for single-cycle write pulse
            vid_fb_we   <= fb_we_sync2 & ~fb_we_sync3;
        end
    end

    // =========================================================================
    // CLOCK DOMAIN CROSSING: VIDEO -> CPU
    // =========================================================================
    // VBlank signal for CPU (used for frame sync)

    // CDC synchronizer for VBlank signal - ASYNC_REG added - Kosjenka/REGOC team
    (* ASYNC_REG = "TRUE" *) reg vblank_sync1, vblank_sync2;

    always @(posedge clk_cpu_fast or negedge rst_cpu_n) begin
        if (!rst_cpu_n) begin
            vblank_sync1 <= 1'b0;
            vblank_sync2 <= 1'b0;
            cpu_vblank   <= 1'b0;
        end else begin
            vblank_sync1 <= vid_vblank;
            vblank_sync2 <= vblank_sync1;
            cpu_vblank   <= vblank_sync2;
        end
    end

    // =========================================================================
    // CLOCK DOMAIN CROSSING: CPU PIXEL COORDINATES -> VIDEO
    // =========================================================================
    // CDC: Pixel coordinates (X, Y, brightness) and strobe signal from CPU domain
    // to pixel domain. Uses 2-stage synchronizers to prevent metastability issues.
    //
    // Signal timing: CPU updates these signals infrequently (on DPY instruction),
    // so simple 2-FF synchronizers are sufficient.

    // CDC synchronizer for pixel X coordinate (10-bit)
    (* ASYNC_REG = "TRUE" *) reg [9:0] pixel_x_sync1, pixel_x_sync2;

    // CDC synchronizer for pixel Y coordinate (10-bit)
    (* ASYNC_REG = "TRUE" *) reg [9:0] pixel_y_sync1, pixel_y_sync2;

    // CDC synchronizer for pixel brightness (3-bit)
    (* ASYNC_REG = "TRUE" *) reg [2:0] pixel_brightness_sync1, pixel_brightness_sync2;

    // CDC synchronizer for pixel shift/strobe signal (1-bit control signal)
    (* ASYNC_REG = "TRUE" *) reg pixel_shift_sync1, pixel_shift_sync2;

    always @(posedge clk_pixel or negedge rst_pixel_n) begin
        if (!rst_pixel_n) begin
            // Reset all pixel coordinate synchronizers
            pixel_x_sync1           <= 10'b0;
            pixel_x_sync2           <= 10'b0;
            pixel_y_sync1           <= 10'b0;
            pixel_y_sync2           <= 10'b0;
            pixel_brightness_sync1  <= 3'b0;
            pixel_brightness_sync2  <= 3'b0;
            pixel_shift_sync1       <= 1'b0;
            pixel_shift_sync2       <= 1'b0;

            // Output registers
            vid_pixel_x             <= 10'b0;
            vid_pixel_y             <= 10'b0;
            vid_pixel_brightness    <= 3'b0;
            vid_pixel_shift         <= 1'b0;
        end else begin
            // Stage 1: Capture asynchronous input (may go metastable)
            pixel_x_sync1           <= cpu_pixel_x;
            pixel_y_sync1           <= cpu_pixel_y;
            pixel_brightness_sync1  <= cpu_pixel_brightness;
            pixel_shift_sync1       <= cpu_pixel_shift;

            // Stage 2: Stable output (metastability resolved by here)
            pixel_x_sync2           <= pixel_x_sync1;
            pixel_y_sync2           <= pixel_y_sync1;
            pixel_brightness_sync2  <= pixel_brightness_sync1;
            pixel_shift_sync2       <= pixel_shift_sync1;

            // Final output registers
            vid_pixel_x             <= pixel_x_sync2;
            vid_pixel_y             <= pixel_y_sync2;
            vid_pixel_brightness    <= pixel_brightness_sync2;
            vid_pixel_shift         <= pixel_shift_sync2;
        end
    end

endmodule
