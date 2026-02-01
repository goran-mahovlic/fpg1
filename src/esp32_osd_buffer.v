// =============================================================================
// ESP32 OSD Buffer - Dual-Port RAM for 256x128 OSD Display
// =============================================================================
// Author: Kosjenka Vukovic, FPGA Architect
// Task:   TASK-203
// Spec:   4KB dual-port RAM (256x16 bytes = 4096 bytes)
//         Port A: Write from SPI domain (clk_sys 50 MHz)
//         Port B: Read from video domain (clk_video 25 MHz)
//         Supports 32 chars per line x 16 lines (8x8 pixel font)
// =============================================================================

module esp32_osd_buffer (
    // Write port (system clock domain - 50 MHz)
    input         clk_sys,
    input  [11:0] wr_addr,      // Byte address 0-4095
    input   [7:0] wr_data,
    input         wr_en,

    // Read port (video clock domain - 25 MHz)
    input         clk_video,
    input  [11:0] rd_addr,
    output  [7:0] rd_data
);

    // =========================================================================
    // Dual-Port RAM Implementation
    // =========================================================================
    // 4KB RAM: 4096 x 8-bit
    // Port A: Write-only (system clock domain)
    // Port B: Read-only (video clock domain)
    // True dual-port for clock domain crossing
    // =========================================================================

    // RAM storage - 4096 bytes
    reg [7:0] ram [0:4095];

    // Read data register (video domain)
    reg [7:0] rd_data_reg;

    // Initialize RAM to spaces (0x20) for clean startup
    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) begin
            ram[i] = 8'h20;  // ASCII space
        end
    end

    // =========================================================================
    // Port A: Write Port (System Clock Domain - 50 MHz)
    // =========================================================================
    always @(posedge clk_sys) begin
        if (wr_en) begin
            ram[wr_addr] <= wr_data;
        end
    end

    // =========================================================================
    // Port B: Read Port (Video Clock Domain - 25 MHz)
    // =========================================================================
    // Synchronous read for proper BRAM inference
    always @(posedge clk_video) begin
        rd_data_reg <= ram[rd_addr];
    end

    assign rd_data = rd_data_reg;

    // =========================================================================
    // Memory Map:
    // =========================================================================
    // Address range: 0x000 - 0xFFF (4096 bytes)
    //
    // Line 0:  0x000 - 0x01F (32 chars)
    // Line 1:  0x020 - 0x03F (32 chars)
    // ...
    // Line 15: 0x1E0 - 0x1FF (32 chars)
    //
    // Total text buffer: 512 bytes (0x000 - 0x1FF)
    // Remaining 3584 bytes available for:
    //   - Custom graphics
    //   - Sprite data
    //   - Extended character sets
    // =========================================================================

endmodule
