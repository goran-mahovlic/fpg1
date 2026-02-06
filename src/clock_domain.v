// =============================================================================
// Clock Domain Manager
// =============================================================================
// TASK-118: PLL/Clock Adaptation
// Author: Kosjenka Vukovic, REGOC team
// Date: 2026-01-31
//
// FUNCTIONALITY:
// 1. CPU clock prescaler: 51 MHz -> 1.82 MHz (original PDP-1 timing)
// 2. Clock Domain Crossing (CDC) between CPU and Video domains
// 3. Reset sequencing with PLL lock wait
//
// CLOCK DOMAINS:
// - clk_pixel (51 MHz)    : Video/HDMI domain (1024x768@50Hz)
// - clk_cpu_fast (51 MHz) : CPU base clock
// - clk_cpu (1.82 MHz)    : PDP-1 original frequency (51 MHz / 28)
// =============================================================================

module clock_domain (
    // PLL inputs
    input  wire clk_pixel,      // 51 MHz pixel clock (1024x768@50Hz)
    input  wire clk_cpu_fast,   // 51 MHz CPU base clock
    input  wire pll_locked,     // PLL lock signal
    input  wire rst_n,          // External async reset (active low)

    // Generated clocks
    output wire clk_cpu,        // 1.82 MHz CPU clock (51 MHz / 28)
    output reg  clk_cpu_en,     // Clock enable for synchronous design

    // Synchronized resets (active low)
    output reg  rst_pixel_n,    // Reset synchronized to pixel clock
    output reg  rst_cpu_n,      // Reset synchronized to CPU clock

    // CDC interface: CPU -> Video
    input  wire [11:0] cpu_fb_addr,     // Frame buffer address from CPU
    input  wire [11:0] cpu_fb_data,     // Frame buffer data from CPU
    input  wire        cpu_fb_we,       // Write enable from CPU
    output reg  [11:0] vid_fb_addr,     // Synchronized to video domain
    output reg  [11:0] vid_fb_data,     // Synchronized to video domain
    output reg         vid_fb_we,       // Synchronized to video domain

    // CDC interface: Video -> CPU (vertical blank signal)
    input  wire        vid_vblank,      // VBlank from video controller
    output reg         cpu_vblank       // Synchronized to CPU domain
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================

    // Prescaler: 51 MHz / 28 = 1.821428 MHz (close to original PDP-1 1.79 MHz)
    // PDP-1 operated at 200 kHz to 1.79 MHz depending on version
    localparam PRESCALER_DIV = 28;
    localparam PRESCALER_BITS = 5;  // ceil(log2(28)) = 5

    // Reset sequencing: wait 16 cycles after PLL lock
    localparam RESET_DELAY = 16;
    localparam RESET_DELAY_BITS = 5;

    // =========================================================================
    // CPU CLOCK PRESCALER
    // =========================================================================
    // Generates 1.82 MHz clock from 51 MHz (51 MHz / 28 = 1.821 MHz)
    // Uses clock enable approach for better FPGA compatibility

    reg [PRESCALER_BITS-1:0] prescaler_cnt;
    reg clk_cpu_reg;

    always @(posedge clk_cpu_fast or negedge rst_n) begin
        if (!rst_n) begin
            prescaler_cnt <= 0;
            clk_cpu_reg   <= 1'b0;
            clk_cpu_en    <= 1'b0;
        end else if (!pll_locked) begin
            prescaler_cnt <= 0;
            clk_cpu_reg   <= 1'b0;
            clk_cpu_en    <= 1'b0;
        end else begin
            clk_cpu_en <= 1'b0;  // Default: disabled

            if (prescaler_cnt == PRESCALER_DIV - 1) begin
                prescaler_cnt <= 0;
                clk_cpu_reg   <= ~clk_cpu_reg;
                clk_cpu_en    <= clk_cpu_reg;  // Enable on falling edge of divided clock
            end else begin
                prescaler_cnt <= prescaler_cnt + 1'b1;
            end
        end
    end

    // BUFG would be used on real FPGA, but for simulation use direct assignment
    assign clk_cpu = clk_cpu_reg;

    // =========================================================================
    // RESET SEQUENCING
    // =========================================================================
    // Sequence:
    // 1. Wait for PLL lock
    // 2. Wait RESET_DELAY cycles for stabilization
    // 3. Release reset synchronized to each clock domain

    // --- Pixel domain reset synchronizer ---
    reg [RESET_DELAY_BITS-1:0] pixel_rst_cnt;
    (* ASYNC_REG = "TRUE" *) reg [2:0] pixel_rst_sync;  // 3-stage synchronizer

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
    reg [RESET_DELAY_BITS-1:0] cpu_rst_cnt;
    (* ASYNC_REG = "TRUE" *) reg [2:0] cpu_rst_sync;  // 3-stage synchronizer

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

endmodule
