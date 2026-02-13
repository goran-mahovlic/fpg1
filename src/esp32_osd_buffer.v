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

    // Initialize RAM with startup text for testing
    integer i;
    initial begin
        // Fill with spaces first
        for (i = 0; i < 4096; i = i + 1) begin
            ram[i] = 8'h20;  // ASCII space
        end
        // Line 0: "=== PDP-1 OSD TEST ==="
        ram[0]  = 8'h3D; ram[1]  = 8'h3D; ram[2]  = 8'h3D; ram[3]  = 8'h20;
        ram[4]  = 8'h50; ram[5]  = 8'h44; ram[6]  = 8'h50; ram[7]  = 8'h2D;
        ram[8]  = 8'h31; ram[9]  = 8'h20; ram[10] = 8'h4F; ram[11] = 8'h53;
        ram[12] = 8'h44; ram[13] = 8'h20; ram[14] = 8'h54; ram[15] = 8'h45;
        ram[16] = 8'h53; ram[17] = 8'h54; ram[18] = 8'h20; ram[19] = 8'h3D;
        ram[20] = 8'h3D; ram[21] = 8'h3D;
        // Line 2: "SW[2] ON = OSD visible"
        ram[64] = 8'h53; ram[65] = 8'h57; ram[66] = 8'h5B; ram[67] = 8'h32;
        ram[68] = 8'h5D; ram[69] = 8'h20; ram[70] = 8'h4F; ram[71] = 8'h4E;
        ram[72] = 8'h20; ram[73] = 8'h3D; ram[74] = 8'h20; ram[75] = 8'h4F;
        ram[76] = 8'h53; ram[77] = 8'h44; ram[78] = 8'h20; ram[79] = 8'h76;
        ram[80] = 8'h69; ram[81] = 8'h73; ram[82] = 8'h69; ram[83] = 8'h62;
        ram[84] = 8'h6C; ram[85] = 8'h65;
        // Line 4: "SPI cmd 0x41 = enable"
        ram[128]= 8'h53; ram[129]= 8'h50; ram[130]= 8'h49; ram[131]= 8'h20;
        ram[132]= 8'h63; ram[133]= 8'h6D; ram[134]= 8'h64; ram[135]= 8'h20;
        ram[136]= 8'h30; ram[137]= 8'h78; ram[138]= 8'h34; ram[139]= 8'h31;
        ram[140]= 8'h20; ram[141]= 8'h3D; ram[142]= 8'h20; ram[143]= 8'h65;
        ram[144]= 8'h6E; ram[145]= 8'h61; ram[146]= 8'h62; ram[147]= 8'h6C;
        ram[148]= 8'h65;
        // Line 5: "SPI cmd 0x40 = disable"
        ram[160]= 8'h53; ram[161]= 8'h50; ram[162]= 8'h49; ram[163]= 8'h20;
        ram[164]= 8'h63; ram[165]= 8'h6D; ram[166]= 8'h64; ram[167]= 8'h20;
        ram[168]= 8'h30; ram[169]= 8'h78; ram[170]= 8'h34; ram[171]= 8'h30;
        ram[172]= 8'h20; ram[173]= 8'h3D; ram[174]= 8'h20; ram[175]= 8'h64;
        ram[176]= 8'h69; ram[177]= 8'h73; ram[178]= 8'h61; ram[179]= 8'h62;
        ram[180]= 8'h6C; ram[181]= 8'h65;
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
