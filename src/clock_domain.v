// =============================================================================
// Clock Domain Manager
// =============================================================================
// TASK-118: PLL/Clock Adaptation
// Autorica: Kosjenka Vukovic, REGOC tim
// Datum: 2026-01-31
//
// FUNKCIONALNOST:
// 1. CPU clock prescaler: 50 MHz -> 1.785714 MHz (originalni PDP-1 timing)
// 2. Clock Domain Crossing (CDC) izmedju CPU i Video domena
// 3. Reset sequencing s PLL lock cekanjem
//
// CLOCK DOMENE:
// - clk_pixel (75 MHz)  : Video/HDMI domena
// - clk_cpu_fast (50 MHz): CPU base clock
// - clk_cpu (1.79 MHz)  : PDP-1 originalna frekvencija
// =============================================================================

module clock_domain (
    // PLL inputs
    input  wire clk_pixel,      // 75 MHz pixel clock
    input  wire clk_cpu_fast,   // 50 MHz CPU base clock
    input  wire pll_locked,     // PLL lock signal
    input  wire rst_n,          // External async reset (active low)

    // Generated clocks
    output wire clk_cpu,        // 1.79 MHz CPU clock
    output reg  clk_cpu_en,     // Clock enable za sinhroni dizajn

    // Synchronized resets (active low)
    output reg  rst_pixel_n,    // Reset sinkroniziran na pixel clock
    output reg  rst_cpu_n,      // Reset sinkroniziran na CPU clock

    // CDC interface: CPU -> Video
    input  wire [11:0] cpu_fb_addr,     // Frame buffer adresa iz CPU
    input  wire [11:0] cpu_fb_data,     // Frame buffer podaci iz CPU
    input  wire        cpu_fb_we,       // Write enable iz CPU
    output reg  [11:0] vid_fb_addr,     // Sinkronizirano na video domenu
    output reg  [11:0] vid_fb_data,     // Sinkronizirano na video domenu
    output reg         vid_fb_we,       // Sinkronizirano na video domenu

    // CDC interface: Video -> CPU (vertical blank signal)
    input  wire        vid_vblank,      // VBlank iz video kontrolera
    output reg         cpu_vblank       // Sinkronizirano na CPU domenu
);

    // =========================================================================
    // PARAMETRI
    // =========================================================================

    // Prescaler: 50 MHz / 28 = 1.785714 MHz (blizu PDP-1 originalnih 1.79 MHz)
    // PDP-1 je radio na 200 kHz do 1.79 MHz ovisno o verziji
    localparam PRESCALER_DIV = 28;
    localparam PRESCALER_BITS = 5;  // ceil(log2(28)) = 5

    // Reset sequencing: cekaj 16 ciklusa nakon PLL lock
    localparam RESET_DELAY = 16;
    localparam RESET_DELAY_BITS = 5;

    // =========================================================================
    // CPU CLOCK PRESCALER
    // =========================================================================
    // Generira 1.79 MHz clock iz 50 MHz
    // Koristi clock enable pristup za bolju FPGA kompatibilnost

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

    // BUFG bi bio koristen na stvarnom FPGA-u, ali za simulaciju direktno
    assign clk_cpu = clk_cpu_reg;

    // =========================================================================
    // RESET SEQUENCING
    // =========================================================================
    // Sekvenca:
    // 1. Cekaj PLL lock
    // 2. Cekaj RESET_DELAY ciklusa za stabilizaciju
    // 3. Oslobodi reset sinkronizirano za svaku clock domenu

    // --- Pixel domain reset synchronizer ---
    reg [RESET_DELAY_BITS-1:0] pixel_rst_cnt;
    reg [2:0] pixel_rst_sync;  // 3-stage synchronizer

    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            pixel_rst_sync <= 3'b000;
            pixel_rst_cnt  <= 0;
            rst_pixel_n    <= 1'b0;
        end else begin
            // Sinkroniziraj PLL lock signal
            pixel_rst_sync <= {pixel_rst_sync[1:0], pll_locked};

            if (!pixel_rst_sync[2]) begin
                // PLL nije zakljucan - drzi reset
                pixel_rst_cnt <= 0;
                rst_pixel_n   <= 1'b0;
            end else if (pixel_rst_cnt < RESET_DELAY - 1) begin
                // Cekaj stabilizaciju
                pixel_rst_cnt <= pixel_rst_cnt + 1'b1;
                rst_pixel_n   <= 1'b0;
            end else begin
                // Oslobodi reset
                rst_pixel_n <= 1'b1;
            end
        end
    end

    // --- CPU domain reset synchronizer ---
    reg [RESET_DELAY_BITS-1:0] cpu_rst_cnt;
    reg [2:0] cpu_rst_sync;  // 3-stage synchronizer

    always @(posedge clk_cpu_fast or negedge rst_n) begin
        if (!rst_n) begin
            cpu_rst_sync <= 3'b000;
            cpu_rst_cnt  <= 0;
            rst_cpu_n    <= 1'b0;
        end else begin
            // Sinkroniziraj PLL lock signal
            cpu_rst_sync <= {cpu_rst_sync[1:0], pll_locked};

            if (!cpu_rst_sync[2]) begin
                // PLL nije zakljucan - drzi reset
                cpu_rst_cnt <= 0;
                rst_cpu_n   <= 1'b0;
            end else if (cpu_rst_cnt < RESET_DELAY - 1) begin
                // Cekaj stabilizaciju
                cpu_rst_cnt <= cpu_rst_cnt + 1'b1;
                rst_cpu_n   <= 1'b0;
            end else begin
                // Oslobodi reset
                rst_cpu_n <= 1'b1;
            end
        end
    end

    // =========================================================================
    // CLOCK DOMAIN CROSSING: CPU -> VIDEO
    // =========================================================================
    // Koristi 2-stage synchronizer za kontrolne signale
    // i handshake protokol za podatke
    //
    // Frame buffer pristup je relativno spor (CPU @ 1.79 MHz),
    // pa jednostavan synchronizer radi dobro

    // Stage 1: Registri u CPU domeni (vec su tu iz CPU-a)
    // Stage 2 & 3: Synchronizer u video domeni

    reg [11:0] fb_addr_sync1, fb_addr_sync2;
    reg [11:0] fb_data_sync1, fb_data_sync2;
    reg        fb_we_sync1, fb_we_sync2, fb_we_sync3;

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
            // 2-stage synchronizer za adresu i podatke
            // (podaci su stabilni dok je we aktivan)
            fb_addr_sync1 <= cpu_fb_addr;
            fb_addr_sync2 <= fb_addr_sync1;
            fb_data_sync1 <= cpu_fb_data;
            fb_data_sync2 <= fb_data_sync1;

            // 3-stage synchronizer za write enable (kontrolni signal)
            fb_we_sync1 <= cpu_fb_we;
            fb_we_sync2 <= fb_we_sync1;
            fb_we_sync3 <= fb_we_sync2;

            // Output registri
            vid_fb_addr <= fb_addr_sync2;
            vid_fb_data <= fb_data_sync2;
            // Detektiraj rising edge za single-cycle write pulse
            vid_fb_we   <= fb_we_sync2 & ~fb_we_sync3;
        end
    end

    // =========================================================================
    // CLOCK DOMAIN CROSSING: VIDEO -> CPU
    // =========================================================================
    // VBlank signal za CPU (koristi se za frame sync)

    reg vblank_sync1, vblank_sync2;

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
