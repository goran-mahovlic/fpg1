// =============================================================================
// ESP32 OSD Renderer - Character-based OSD with embedded 8x8 font
// =============================================================================
// Author: Kosjenka Vukovic, FPGA Architect
// Task:   TASK-203
// Spec:   256x128 pixel OSD (32 chars x 16 lines with 8x8 font)
//         Embedded ASCII font for characters 0x20-0x7F (96 characters)
//         Configurable position offset
// =============================================================================

module esp32_osd_renderer (
    input         clk_video,     // 25 MHz pixel clock
    input         rst_n,
    input  [11:0] pixel_x,       // Current pixel X (0-639)
    input  [11:0] pixel_y,       // Current pixel Y (0-479)
    input         osd_enable,    // OSD enable signal
    input  [11:0] osd_x_offset,  // OSD X position offset
    input  [11:0] osd_y_offset,  // OSD Y position offset

    // Buffer interface
    output [11:0] buf_addr,      // Character buffer address
    input   [7:0] buf_data,      // Character code from buffer

    // Output signals
    output        osd_pixel,     // 1 = OSD pixel active (foreground)
    output        osd_visible    // 1 = inside OSD area
);

    // =========================================================================
    // OSD Parameters
    // =========================================================================
    localparam OSD_WIDTH  = 256;  // 32 chars * 8 pixels
    localparam OSD_HEIGHT = 128;  // 16 lines * 8 pixels
    localparam CHARS_PER_LINE = 32;
    localparam LINES = 16;
    localparam CHAR_WIDTH = 8;
    localparam CHAR_HEIGHT = 8;

    // =========================================================================
    // Position Calculation
    // =========================================================================
    // Calculate relative position within OSD area
    wire [11:0] rel_x = pixel_x - osd_x_offset;
    wire [11:0] rel_y = pixel_y - osd_y_offset;

    // Check if current pixel is inside OSD area
    wire inside_osd = osd_enable &&
                      (pixel_x >= osd_x_offset) &&
                      (pixel_x < osd_x_offset + OSD_WIDTH) &&
                      (pixel_y >= osd_y_offset) &&
                      (pixel_y < osd_y_offset + OSD_HEIGHT);

    // Character position (which character in the grid)
    wire [4:0] char_col = rel_x[7:3];  // rel_x / 8 (0-31)
    wire [3:0] char_row = rel_y[6:3];  // rel_y / 8 (0-15)

    // Pixel position within character cell
    wire [2:0] pixel_col = rel_x[2:0]; // rel_x % 8 (0-7)
    wire [2:0] pixel_row = rel_y[2:0]; // rel_y % 8 (0-7)

    // =========================================================================
    // Buffer Address Generation
    // =========================================================================
    // Linear address = row * 32 + col
    assign buf_addr = {char_row, char_col};  // 9 bits needed (0-511)

    // =========================================================================
    // Pipeline Registers for Timing
    // =========================================================================
    // Stage 1: Capture position info (1 cycle delay for RAM read)
    reg [2:0] pixel_col_d1, pixel_col_d2;
    reg [2:0] pixel_row_d1, pixel_row_d2;
    reg       inside_osd_d1, inside_osd_d2;

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            pixel_col_d1  <= 3'd0;
            pixel_col_d2  <= 3'd0;
            pixel_row_d1  <= 3'd0;
            pixel_row_d2  <= 3'd0;
            inside_osd_d1 <= 1'b0;
            inside_osd_d2 <= 1'b0;
        end else begin
            // Pipeline stage 1
            pixel_col_d1  <= pixel_col;
            pixel_row_d1  <= pixel_row;
            inside_osd_d1 <= inside_osd;
            // Pipeline stage 2 (for font ROM delay)
            pixel_col_d2  <= pixel_col_d1;
            pixel_row_d2  <= pixel_row_d1;
            inside_osd_d2 <= inside_osd_d1;
        end
    end

    // =========================================================================
    // Character ROM Address
    // =========================================================================
    // buf_data contains ASCII code (0x20-0x7F supported)
    // Font ROM address = (char_code - 0x20) * 8 + row
    wire [6:0] char_code = buf_data[6:0];  // Mask to 7-bit ASCII
    wire [6:0] char_index = (char_code >= 7'h20) ? (char_code - 7'h20) : 7'd0;
    wire [9:0] font_addr = {char_index, pixel_row_d1};  // 96 chars * 8 rows = 768 entries

    // =========================================================================
    // Embedded 8x8 ASCII Font ROM (Characters 0x20-0x7F)
    // =========================================================================
    // Classic 8x8 bitmap font, MSB is leftmost pixel
    reg [7:0] font_rom [0:767];  // 96 characters * 8 rows

    initial begin
        // Initialize all to zero
        integer i;
        for (i = 0; i < 768; i = i + 1) font_rom[i] = 8'h00;

        // Character 0x20: SPACE
        font_rom[0]   = 8'b00000000; font_rom[1]   = 8'b00000000;
        font_rom[2]   = 8'b00000000; font_rom[3]   = 8'b00000000;
        font_rom[4]   = 8'b00000000; font_rom[5]   = 8'b00000000;
        font_rom[6]   = 8'b00000000; font_rom[7]   = 8'b00000000;

        // Character 0x21: !
        font_rom[8]   = 8'b00011000; font_rom[9]   = 8'b00011000;
        font_rom[10]  = 8'b00011000; font_rom[11]  = 8'b00011000;
        font_rom[12]  = 8'b00011000; font_rom[13]  = 8'b00000000;
        font_rom[14]  = 8'b00011000; font_rom[15]  = 8'b00000000;

        // Character 0x22: "
        font_rom[16]  = 8'b01100110; font_rom[17]  = 8'b01100110;
        font_rom[18]  = 8'b01100110; font_rom[19]  = 8'b00000000;
        font_rom[20]  = 8'b00000000; font_rom[21]  = 8'b00000000;
        font_rom[22]  = 8'b00000000; font_rom[23]  = 8'b00000000;

        // Character 0x23: #
        font_rom[24]  = 8'b01100110; font_rom[25]  = 8'b01100110;
        font_rom[26]  = 8'b11111111; font_rom[27]  = 8'b01100110;
        font_rom[28]  = 8'b11111111; font_rom[29]  = 8'b01100110;
        font_rom[30]  = 8'b01100110; font_rom[31]  = 8'b00000000;

        // Character 0x24: $
        font_rom[32]  = 8'b00011000; font_rom[33]  = 8'b00111110;
        font_rom[34]  = 8'b01100000; font_rom[35]  = 8'b00111100;
        font_rom[36]  = 8'b00000110; font_rom[37]  = 8'b01111100;
        font_rom[38]  = 8'b00011000; font_rom[39]  = 8'b00000000;

        // Character 0x25: %
        font_rom[40]  = 8'b01100010; font_rom[41]  = 8'b01100110;
        font_rom[42]  = 8'b00001100; font_rom[43]  = 8'b00011000;
        font_rom[44]  = 8'b00110000; font_rom[45]  = 8'b01100110;
        font_rom[46]  = 8'b01000110; font_rom[47]  = 8'b00000000;

        // Character 0x26: &
        font_rom[48]  = 8'b00111100; font_rom[49]  = 8'b01100110;
        font_rom[50]  = 8'b00111100; font_rom[51]  = 8'b00111000;
        font_rom[52]  = 8'b01100111; font_rom[53]  = 8'b01100110;
        font_rom[54]  = 8'b00111111; font_rom[55]  = 8'b00000000;

        // Character 0x27: '
        font_rom[56]  = 8'b00011000; font_rom[57]  = 8'b00011000;
        font_rom[58]  = 8'b00011000; font_rom[59]  = 8'b00000000;
        font_rom[60]  = 8'b00000000; font_rom[61]  = 8'b00000000;
        font_rom[62]  = 8'b00000000; font_rom[63]  = 8'b00000000;

        // Character 0x28: (
        font_rom[64]  = 8'b00001100; font_rom[65]  = 8'b00011000;
        font_rom[66]  = 8'b00110000; font_rom[67]  = 8'b00110000;
        font_rom[68]  = 8'b00110000; font_rom[69]  = 8'b00011000;
        font_rom[70]  = 8'b00001100; font_rom[71]  = 8'b00000000;

        // Character 0x29: )
        font_rom[72]  = 8'b00110000; font_rom[73]  = 8'b00011000;
        font_rom[74]  = 8'b00001100; font_rom[75]  = 8'b00001100;
        font_rom[76]  = 8'b00001100; font_rom[77]  = 8'b00011000;
        font_rom[78]  = 8'b00110000; font_rom[79]  = 8'b00000000;

        // Character 0x2A: *
        font_rom[80]  = 8'b00000000; font_rom[81]  = 8'b01100110;
        font_rom[82]  = 8'b00111100; font_rom[83]  = 8'b11111111;
        font_rom[84]  = 8'b00111100; font_rom[85]  = 8'b01100110;
        font_rom[86]  = 8'b00000000; font_rom[87]  = 8'b00000000;

        // Character 0x2B: +
        font_rom[88]  = 8'b00000000; font_rom[89]  = 8'b00011000;
        font_rom[90]  = 8'b00011000; font_rom[91]  = 8'b01111110;
        font_rom[92]  = 8'b00011000; font_rom[93]  = 8'b00011000;
        font_rom[94]  = 8'b00000000; font_rom[95]  = 8'b00000000;

        // Character 0x2C: ,
        font_rom[96]  = 8'b00000000; font_rom[97]  = 8'b00000000;
        font_rom[98]  = 8'b00000000; font_rom[99]  = 8'b00000000;
        font_rom[100] = 8'b00000000; font_rom[101] = 8'b00011000;
        font_rom[102] = 8'b00011000; font_rom[103] = 8'b00110000;

        // Character 0x2D: -
        font_rom[104] = 8'b00000000; font_rom[105] = 8'b00000000;
        font_rom[106] = 8'b00000000; font_rom[107] = 8'b01111110;
        font_rom[108] = 8'b00000000; font_rom[109] = 8'b00000000;
        font_rom[110] = 8'b00000000; font_rom[111] = 8'b00000000;

        // Character 0x2E: .
        font_rom[112] = 8'b00000000; font_rom[113] = 8'b00000000;
        font_rom[114] = 8'b00000000; font_rom[115] = 8'b00000000;
        font_rom[116] = 8'b00000000; font_rom[117] = 8'b00011000;
        font_rom[118] = 8'b00011000; font_rom[119] = 8'b00000000;

        // Character 0x2F: /
        font_rom[120] = 8'b00000110; font_rom[121] = 8'b00001100;
        font_rom[122] = 8'b00011000; font_rom[123] = 8'b00110000;
        font_rom[124] = 8'b01100000; font_rom[125] = 8'b11000000;
        font_rom[126] = 8'b10000000; font_rom[127] = 8'b00000000;

        // Character 0x30: 0
        font_rom[128] = 8'b00111100; font_rom[129] = 8'b01100110;
        font_rom[130] = 8'b01101110; font_rom[131] = 8'b01110110;
        font_rom[132] = 8'b01100110; font_rom[133] = 8'b01100110;
        font_rom[134] = 8'b00111100; font_rom[135] = 8'b00000000;

        // Character 0x31: 1
        font_rom[136] = 8'b00011000; font_rom[137] = 8'b00111000;
        font_rom[138] = 8'b00011000; font_rom[139] = 8'b00011000;
        font_rom[140] = 8'b00011000; font_rom[141] = 8'b00011000;
        font_rom[142] = 8'b01111110; font_rom[143] = 8'b00000000;

        // Character 0x32: 2
        font_rom[144] = 8'b00111100; font_rom[145] = 8'b01100110;
        font_rom[146] = 8'b00000110; font_rom[147] = 8'b00001100;
        font_rom[148] = 8'b00110000; font_rom[149] = 8'b01100000;
        font_rom[150] = 8'b01111110; font_rom[151] = 8'b00000000;

        // Character 0x33: 3
        font_rom[152] = 8'b00111100; font_rom[153] = 8'b01100110;
        font_rom[154] = 8'b00000110; font_rom[155] = 8'b00011100;
        font_rom[156] = 8'b00000110; font_rom[157] = 8'b01100110;
        font_rom[158] = 8'b00111100; font_rom[159] = 8'b00000000;

        // Character 0x34: 4
        font_rom[160] = 8'b00001100; font_rom[161] = 8'b00011100;
        font_rom[162] = 8'b00111100; font_rom[163] = 8'b01101100;
        font_rom[164] = 8'b01111110; font_rom[165] = 8'b00001100;
        font_rom[166] = 8'b00001100; font_rom[167] = 8'b00000000;

        // Character 0x35: 5
        font_rom[168] = 8'b01111110; font_rom[169] = 8'b01100000;
        font_rom[170] = 8'b01111100; font_rom[171] = 8'b00000110;
        font_rom[172] = 8'b00000110; font_rom[173] = 8'b01100110;
        font_rom[174] = 8'b00111100; font_rom[175] = 8'b00000000;

        // Character 0x36: 6
        font_rom[176] = 8'b00111100; font_rom[177] = 8'b01100110;
        font_rom[178] = 8'b01100000; font_rom[179] = 8'b01111100;
        font_rom[180] = 8'b01100110; font_rom[181] = 8'b01100110;
        font_rom[182] = 8'b00111100; font_rom[183] = 8'b00000000;

        // Character 0x37: 7
        font_rom[184] = 8'b01111110; font_rom[185] = 8'b01100110;
        font_rom[186] = 8'b00001100; font_rom[187] = 8'b00011000;
        font_rom[188] = 8'b00011000; font_rom[189] = 8'b00011000;
        font_rom[190] = 8'b00011000; font_rom[191] = 8'b00000000;

        // Character 0x38: 8
        font_rom[192] = 8'b00111100; font_rom[193] = 8'b01100110;
        font_rom[194] = 8'b01100110; font_rom[195] = 8'b00111100;
        font_rom[196] = 8'b01100110; font_rom[197] = 8'b01100110;
        font_rom[198] = 8'b00111100; font_rom[199] = 8'b00000000;

        // Character 0x39: 9
        font_rom[200] = 8'b00111100; font_rom[201] = 8'b01100110;
        font_rom[202] = 8'b01100110; font_rom[203] = 8'b00111110;
        font_rom[204] = 8'b00000110; font_rom[205] = 8'b01100110;
        font_rom[206] = 8'b00111100; font_rom[207] = 8'b00000000;

        // Character 0x3A: :
        font_rom[208] = 8'b00000000; font_rom[209] = 8'b00000000;
        font_rom[210] = 8'b00011000; font_rom[211] = 8'b00011000;
        font_rom[212] = 8'b00000000; font_rom[213] = 8'b00011000;
        font_rom[214] = 8'b00011000; font_rom[215] = 8'b00000000;

        // Character 0x3B: ;
        font_rom[216] = 8'b00000000; font_rom[217] = 8'b00000000;
        font_rom[218] = 8'b00011000; font_rom[219] = 8'b00011000;
        font_rom[220] = 8'b00000000; font_rom[221] = 8'b00011000;
        font_rom[222] = 8'b00011000; font_rom[223] = 8'b00110000;

        // Character 0x3C: <
        font_rom[224] = 8'b00001100; font_rom[225] = 8'b00011000;
        font_rom[226] = 8'b00110000; font_rom[227] = 8'b01100000;
        font_rom[228] = 8'b00110000; font_rom[229] = 8'b00011000;
        font_rom[230] = 8'b00001100; font_rom[231] = 8'b00000000;

        // Character 0x3D: =
        font_rom[232] = 8'b00000000; font_rom[233] = 8'b00000000;
        font_rom[234] = 8'b01111110; font_rom[235] = 8'b00000000;
        font_rom[236] = 8'b01111110; font_rom[237] = 8'b00000000;
        font_rom[238] = 8'b00000000; font_rom[239] = 8'b00000000;

        // Character 0x3E: >
        font_rom[240] = 8'b00110000; font_rom[241] = 8'b00011000;
        font_rom[242] = 8'b00001100; font_rom[243] = 8'b00000110;
        font_rom[244] = 8'b00001100; font_rom[245] = 8'b00011000;
        font_rom[246] = 8'b00110000; font_rom[247] = 8'b00000000;

        // Character 0x3F: ?
        font_rom[248] = 8'b00111100; font_rom[249] = 8'b01100110;
        font_rom[250] = 8'b00000110; font_rom[251] = 8'b00001100;
        font_rom[252] = 8'b00011000; font_rom[253] = 8'b00000000;
        font_rom[254] = 8'b00011000; font_rom[255] = 8'b00000000;

        // Character 0x40: @
        font_rom[256] = 8'b00111100; font_rom[257] = 8'b01100110;
        font_rom[258] = 8'b01101110; font_rom[259] = 8'b01101110;
        font_rom[260] = 8'b01100000; font_rom[261] = 8'b01100010;
        font_rom[262] = 8'b00111100; font_rom[263] = 8'b00000000;

        // Character 0x41: A
        font_rom[264] = 8'b00011000; font_rom[265] = 8'b00111100;
        font_rom[266] = 8'b01100110; font_rom[267] = 8'b01111110;
        font_rom[268] = 8'b01100110; font_rom[269] = 8'b01100110;
        font_rom[270] = 8'b01100110; font_rom[271] = 8'b00000000;

        // Character 0x42: B
        font_rom[272] = 8'b01111100; font_rom[273] = 8'b01100110;
        font_rom[274] = 8'b01100110; font_rom[275] = 8'b01111100;
        font_rom[276] = 8'b01100110; font_rom[277] = 8'b01100110;
        font_rom[278] = 8'b01111100; font_rom[279] = 8'b00000000;

        // Character 0x43: C
        font_rom[280] = 8'b00111100; font_rom[281] = 8'b01100110;
        font_rom[282] = 8'b01100000; font_rom[283] = 8'b01100000;
        font_rom[284] = 8'b01100000; font_rom[285] = 8'b01100110;
        font_rom[286] = 8'b00111100; font_rom[287] = 8'b00000000;

        // Character 0x44: D
        font_rom[288] = 8'b01111000; font_rom[289] = 8'b01101100;
        font_rom[290] = 8'b01100110; font_rom[291] = 8'b01100110;
        font_rom[292] = 8'b01100110; font_rom[293] = 8'b01101100;
        font_rom[294] = 8'b01111000; font_rom[295] = 8'b00000000;

        // Character 0x45: E
        font_rom[296] = 8'b01111110; font_rom[297] = 8'b01100000;
        font_rom[298] = 8'b01100000; font_rom[299] = 8'b01111000;
        font_rom[300] = 8'b01100000; font_rom[301] = 8'b01100000;
        font_rom[302] = 8'b01111110; font_rom[303] = 8'b00000000;

        // Character 0x46: F
        font_rom[304] = 8'b01111110; font_rom[305] = 8'b01100000;
        font_rom[306] = 8'b01100000; font_rom[307] = 8'b01111000;
        font_rom[308] = 8'b01100000; font_rom[309] = 8'b01100000;
        font_rom[310] = 8'b01100000; font_rom[311] = 8'b00000000;

        // Character 0x47: G
        font_rom[312] = 8'b00111100; font_rom[313] = 8'b01100110;
        font_rom[314] = 8'b01100000; font_rom[315] = 8'b01101110;
        font_rom[316] = 8'b01100110; font_rom[317] = 8'b01100110;
        font_rom[318] = 8'b00111100; font_rom[319] = 8'b00000000;

        // Character 0x48: H
        font_rom[320] = 8'b01100110; font_rom[321] = 8'b01100110;
        font_rom[322] = 8'b01100110; font_rom[323] = 8'b01111110;
        font_rom[324] = 8'b01100110; font_rom[325] = 8'b01100110;
        font_rom[326] = 8'b01100110; font_rom[327] = 8'b00000000;

        // Character 0x49: I
        font_rom[328] = 8'b00111100; font_rom[329] = 8'b00011000;
        font_rom[330] = 8'b00011000; font_rom[331] = 8'b00011000;
        font_rom[332] = 8'b00011000; font_rom[333] = 8'b00011000;
        font_rom[334] = 8'b00111100; font_rom[335] = 8'b00000000;

        // Character 0x4A: J
        font_rom[336] = 8'b00011110; font_rom[337] = 8'b00001100;
        font_rom[338] = 8'b00001100; font_rom[339] = 8'b00001100;
        font_rom[340] = 8'b01101100; font_rom[341] = 8'b01101100;
        font_rom[342] = 8'b00111000; font_rom[343] = 8'b00000000;

        // Character 0x4B: K
        font_rom[344] = 8'b01100110; font_rom[345] = 8'b01101100;
        font_rom[346] = 8'b01111000; font_rom[347] = 8'b01110000;
        font_rom[348] = 8'b01111000; font_rom[349] = 8'b01101100;
        font_rom[350] = 8'b01100110; font_rom[351] = 8'b00000000;

        // Character 0x4C: L
        font_rom[352] = 8'b01100000; font_rom[353] = 8'b01100000;
        font_rom[354] = 8'b01100000; font_rom[355] = 8'b01100000;
        font_rom[356] = 8'b01100000; font_rom[357] = 8'b01100000;
        font_rom[358] = 8'b01111110; font_rom[359] = 8'b00000000;

        // Character 0x4D: M
        font_rom[360] = 8'b01100011; font_rom[361] = 8'b01110111;
        font_rom[362] = 8'b01111111; font_rom[363] = 8'b01101011;
        font_rom[364] = 8'b01100011; font_rom[365] = 8'b01100011;
        font_rom[366] = 8'b01100011; font_rom[367] = 8'b00000000;

        // Character 0x4E: N
        font_rom[368] = 8'b01100110; font_rom[369] = 8'b01110110;
        font_rom[370] = 8'b01111110; font_rom[371] = 8'b01111110;
        font_rom[372] = 8'b01101110; font_rom[373] = 8'b01100110;
        font_rom[374] = 8'b01100110; font_rom[375] = 8'b00000000;

        // Character 0x4F: O
        font_rom[376] = 8'b00111100; font_rom[377] = 8'b01100110;
        font_rom[378] = 8'b01100110; font_rom[379] = 8'b01100110;
        font_rom[380] = 8'b01100110; font_rom[381] = 8'b01100110;
        font_rom[382] = 8'b00111100; font_rom[383] = 8'b00000000;

        // Character 0x50: P
        font_rom[384] = 8'b01111100; font_rom[385] = 8'b01100110;
        font_rom[386] = 8'b01100110; font_rom[387] = 8'b01111100;
        font_rom[388] = 8'b01100000; font_rom[389] = 8'b01100000;
        font_rom[390] = 8'b01100000; font_rom[391] = 8'b00000000;

        // Character 0x51: Q
        font_rom[392] = 8'b00111100; font_rom[393] = 8'b01100110;
        font_rom[394] = 8'b01100110; font_rom[395] = 8'b01100110;
        font_rom[396] = 8'b01100110; font_rom[397] = 8'b00111100;
        font_rom[398] = 8'b00001110; font_rom[399] = 8'b00000000;

        // Character 0x52: R
        font_rom[400] = 8'b01111100; font_rom[401] = 8'b01100110;
        font_rom[402] = 8'b01100110; font_rom[403] = 8'b01111100;
        font_rom[404] = 8'b01111000; font_rom[405] = 8'b01101100;
        font_rom[406] = 8'b01100110; font_rom[407] = 8'b00000000;

        // Character 0x53: S
        font_rom[408] = 8'b00111100; font_rom[409] = 8'b01100110;
        font_rom[410] = 8'b01100000; font_rom[411] = 8'b00111100;
        font_rom[412] = 8'b00000110; font_rom[413] = 8'b01100110;
        font_rom[414] = 8'b00111100; font_rom[415] = 8'b00000000;

        // Character 0x54: T
        font_rom[416] = 8'b01111110; font_rom[417] = 8'b00011000;
        font_rom[418] = 8'b00011000; font_rom[419] = 8'b00011000;
        font_rom[420] = 8'b00011000; font_rom[421] = 8'b00011000;
        font_rom[422] = 8'b00011000; font_rom[423] = 8'b00000000;

        // Character 0x55: U
        font_rom[424] = 8'b01100110; font_rom[425] = 8'b01100110;
        font_rom[426] = 8'b01100110; font_rom[427] = 8'b01100110;
        font_rom[428] = 8'b01100110; font_rom[429] = 8'b01100110;
        font_rom[430] = 8'b00111100; font_rom[431] = 8'b00000000;

        // Character 0x56: V
        font_rom[432] = 8'b01100110; font_rom[433] = 8'b01100110;
        font_rom[434] = 8'b01100110; font_rom[435] = 8'b01100110;
        font_rom[436] = 8'b01100110; font_rom[437] = 8'b00111100;
        font_rom[438] = 8'b00011000; font_rom[439] = 8'b00000000;

        // Character 0x57: W
        font_rom[440] = 8'b01100011; font_rom[441] = 8'b01100011;
        font_rom[442] = 8'b01100011; font_rom[443] = 8'b01101011;
        font_rom[444] = 8'b01111111; font_rom[445] = 8'b01110111;
        font_rom[446] = 8'b01100011; font_rom[447] = 8'b00000000;

        // Character 0x58: X
        font_rom[448] = 8'b01100110; font_rom[449] = 8'b01100110;
        font_rom[450] = 8'b00111100; font_rom[451] = 8'b00011000;
        font_rom[452] = 8'b00111100; font_rom[453] = 8'b01100110;
        font_rom[454] = 8'b01100110; font_rom[455] = 8'b00000000;

        // Character 0x59: Y
        font_rom[456] = 8'b01100110; font_rom[457] = 8'b01100110;
        font_rom[458] = 8'b01100110; font_rom[459] = 8'b00111100;
        font_rom[460] = 8'b00011000; font_rom[461] = 8'b00011000;
        font_rom[462] = 8'b00011000; font_rom[463] = 8'b00000000;

        // Character 0x5A: Z
        font_rom[464] = 8'b01111110; font_rom[465] = 8'b00000110;
        font_rom[466] = 8'b00001100; font_rom[467] = 8'b00011000;
        font_rom[468] = 8'b00110000; font_rom[469] = 8'b01100000;
        font_rom[470] = 8'b01111110; font_rom[471] = 8'b00000000;

        // Character 0x5B: [
        font_rom[472] = 8'b00111100; font_rom[473] = 8'b00110000;
        font_rom[474] = 8'b00110000; font_rom[475] = 8'b00110000;
        font_rom[476] = 8'b00110000; font_rom[477] = 8'b00110000;
        font_rom[478] = 8'b00111100; font_rom[479] = 8'b00000000;

        // Character 0x5C: backslash
        font_rom[480] = 8'b11000000; font_rom[481] = 8'b01100000;
        font_rom[482] = 8'b00110000; font_rom[483] = 8'b00011000;
        font_rom[484] = 8'b00001100; font_rom[485] = 8'b00000110;
        font_rom[486] = 8'b00000010; font_rom[487] = 8'b00000000;

        // Character 0x5D: ]
        font_rom[488] = 8'b00111100; font_rom[489] = 8'b00001100;
        font_rom[490] = 8'b00001100; font_rom[491] = 8'b00001100;
        font_rom[492] = 8'b00001100; font_rom[493] = 8'b00001100;
        font_rom[494] = 8'b00111100; font_rom[495] = 8'b00000000;

        // Character 0x5E: ^
        font_rom[496] = 8'b00011000; font_rom[497] = 8'b00111100;
        font_rom[498] = 8'b01100110; font_rom[499] = 8'b00000000;
        font_rom[500] = 8'b00000000; font_rom[501] = 8'b00000000;
        font_rom[502] = 8'b00000000; font_rom[503] = 8'b00000000;

        // Character 0x5F: _
        font_rom[504] = 8'b00000000; font_rom[505] = 8'b00000000;
        font_rom[506] = 8'b00000000; font_rom[507] = 8'b00000000;
        font_rom[508] = 8'b00000000; font_rom[509] = 8'b00000000;
        font_rom[510] = 8'b11111111; font_rom[511] = 8'b00000000;

        // Character 0x60: `
        font_rom[512] = 8'b00110000; font_rom[513] = 8'b00011000;
        font_rom[514] = 8'b00001100; font_rom[515] = 8'b00000000;
        font_rom[516] = 8'b00000000; font_rom[517] = 8'b00000000;
        font_rom[518] = 8'b00000000; font_rom[519] = 8'b00000000;

        // Character 0x61: a
        font_rom[520] = 8'b00000000; font_rom[521] = 8'b00000000;
        font_rom[522] = 8'b00111100; font_rom[523] = 8'b00000110;
        font_rom[524] = 8'b00111110; font_rom[525] = 8'b01100110;
        font_rom[526] = 8'b00111110; font_rom[527] = 8'b00000000;

        // Character 0x62: b
        font_rom[528] = 8'b01100000; font_rom[529] = 8'b01100000;
        font_rom[530] = 8'b01111100; font_rom[531] = 8'b01100110;
        font_rom[532] = 8'b01100110; font_rom[533] = 8'b01100110;
        font_rom[534] = 8'b01111100; font_rom[535] = 8'b00000000;

        // Character 0x63: c
        font_rom[536] = 8'b00000000; font_rom[537] = 8'b00000000;
        font_rom[538] = 8'b00111100; font_rom[539] = 8'b01100000;
        font_rom[540] = 8'b01100000; font_rom[541] = 8'b01100000;
        font_rom[542] = 8'b00111100; font_rom[543] = 8'b00000000;

        // Character 0x64: d
        font_rom[544] = 8'b00000110; font_rom[545] = 8'b00000110;
        font_rom[546] = 8'b00111110; font_rom[547] = 8'b01100110;
        font_rom[548] = 8'b01100110; font_rom[549] = 8'b01100110;
        font_rom[550] = 8'b00111110; font_rom[551] = 8'b00000000;

        // Character 0x65: e
        font_rom[552] = 8'b00000000; font_rom[553] = 8'b00000000;
        font_rom[554] = 8'b00111100; font_rom[555] = 8'b01100110;
        font_rom[556] = 8'b01111110; font_rom[557] = 8'b01100000;
        font_rom[558] = 8'b00111100; font_rom[559] = 8'b00000000;

        // Character 0x66: f
        font_rom[560] = 8'b00011100; font_rom[561] = 8'b00110110;
        font_rom[562] = 8'b00110000; font_rom[563] = 8'b01111000;
        font_rom[564] = 8'b00110000; font_rom[565] = 8'b00110000;
        font_rom[566] = 8'b00110000; font_rom[567] = 8'b00000000;

        // Character 0x67: g
        font_rom[568] = 8'b00000000; font_rom[569] = 8'b00000000;
        font_rom[570] = 8'b00111110; font_rom[571] = 8'b01100110;
        font_rom[572] = 8'b01100110; font_rom[573] = 8'b00111110;
        font_rom[574] = 8'b00000110; font_rom[575] = 8'b00111100;

        // Character 0x68: h
        font_rom[576] = 8'b01100000; font_rom[577] = 8'b01100000;
        font_rom[578] = 8'b01111100; font_rom[579] = 8'b01100110;
        font_rom[580] = 8'b01100110; font_rom[581] = 8'b01100110;
        font_rom[582] = 8'b01100110; font_rom[583] = 8'b00000000;

        // Character 0x69: i
        font_rom[584] = 8'b00011000; font_rom[585] = 8'b00000000;
        font_rom[586] = 8'b00111000; font_rom[587] = 8'b00011000;
        font_rom[588] = 8'b00011000; font_rom[589] = 8'b00011000;
        font_rom[590] = 8'b00111100; font_rom[591] = 8'b00000000;

        // Character 0x6A: j
        font_rom[592] = 8'b00000110; font_rom[593] = 8'b00000000;
        font_rom[594] = 8'b00000110; font_rom[595] = 8'b00000110;
        font_rom[596] = 8'b00000110; font_rom[597] = 8'b01100110;
        font_rom[598] = 8'b01100110; font_rom[599] = 8'b00111100;

        // Character 0x6B: k
        font_rom[600] = 8'b01100000; font_rom[601] = 8'b01100000;
        font_rom[602] = 8'b01100110; font_rom[603] = 8'b01101100;
        font_rom[604] = 8'b01111000; font_rom[605] = 8'b01101100;
        font_rom[606] = 8'b01100110; font_rom[607] = 8'b00000000;

        // Character 0x6C: l
        font_rom[608] = 8'b00111000; font_rom[609] = 8'b00011000;
        font_rom[610] = 8'b00011000; font_rom[611] = 8'b00011000;
        font_rom[612] = 8'b00011000; font_rom[613] = 8'b00011000;
        font_rom[614] = 8'b00111100; font_rom[615] = 8'b00000000;

        // Character 0x6D: m
        font_rom[616] = 8'b00000000; font_rom[617] = 8'b00000000;
        font_rom[618] = 8'b01100110; font_rom[619] = 8'b01111111;
        font_rom[620] = 8'b01111111; font_rom[621] = 8'b01101011;
        font_rom[622] = 8'b01100011; font_rom[623] = 8'b00000000;

        // Character 0x6E: n
        font_rom[624] = 8'b00000000; font_rom[625] = 8'b00000000;
        font_rom[626] = 8'b01111100; font_rom[627] = 8'b01100110;
        font_rom[628] = 8'b01100110; font_rom[629] = 8'b01100110;
        font_rom[630] = 8'b01100110; font_rom[631] = 8'b00000000;

        // Character 0x6F: o
        font_rom[632] = 8'b00000000; font_rom[633] = 8'b00000000;
        font_rom[634] = 8'b00111100; font_rom[635] = 8'b01100110;
        font_rom[636] = 8'b01100110; font_rom[637] = 8'b01100110;
        font_rom[638] = 8'b00111100; font_rom[639] = 8'b00000000;

        // Character 0x70: p
        font_rom[640] = 8'b00000000; font_rom[641] = 8'b00000000;
        font_rom[642] = 8'b01111100; font_rom[643] = 8'b01100110;
        font_rom[644] = 8'b01100110; font_rom[645] = 8'b01111100;
        font_rom[646] = 8'b01100000; font_rom[647] = 8'b01100000;

        // Character 0x71: q
        font_rom[648] = 8'b00000000; font_rom[649] = 8'b00000000;
        font_rom[650] = 8'b00111110; font_rom[651] = 8'b01100110;
        font_rom[652] = 8'b01100110; font_rom[653] = 8'b00111110;
        font_rom[654] = 8'b00000110; font_rom[655] = 8'b00000110;

        // Character 0x72: r
        font_rom[656] = 8'b00000000; font_rom[657] = 8'b00000000;
        font_rom[658] = 8'b01111100; font_rom[659] = 8'b01100110;
        font_rom[660] = 8'b01100000; font_rom[661] = 8'b01100000;
        font_rom[662] = 8'b01100000; font_rom[663] = 8'b00000000;

        // Character 0x73: s
        font_rom[664] = 8'b00000000; font_rom[665] = 8'b00000000;
        font_rom[666] = 8'b00111110; font_rom[667] = 8'b01100000;
        font_rom[668] = 8'b00111100; font_rom[669] = 8'b00000110;
        font_rom[670] = 8'b01111100; font_rom[671] = 8'b00000000;

        // Character 0x74: t
        font_rom[672] = 8'b00011000; font_rom[673] = 8'b00011000;
        font_rom[674] = 8'b01111110; font_rom[675] = 8'b00011000;
        font_rom[676] = 8'b00011000; font_rom[677] = 8'b00011000;
        font_rom[678] = 8'b00001110; font_rom[679] = 8'b00000000;

        // Character 0x75: u
        font_rom[680] = 8'b00000000; font_rom[681] = 8'b00000000;
        font_rom[682] = 8'b01100110; font_rom[683] = 8'b01100110;
        font_rom[684] = 8'b01100110; font_rom[685] = 8'b01100110;
        font_rom[686] = 8'b00111110; font_rom[687] = 8'b00000000;

        // Character 0x76: v
        font_rom[688] = 8'b00000000; font_rom[689] = 8'b00000000;
        font_rom[690] = 8'b01100110; font_rom[691] = 8'b01100110;
        font_rom[692] = 8'b01100110; font_rom[693] = 8'b00111100;
        font_rom[694] = 8'b00011000; font_rom[695] = 8'b00000000;

        // Character 0x77: w
        font_rom[696] = 8'b00000000; font_rom[697] = 8'b00000000;
        font_rom[698] = 8'b01100011; font_rom[699] = 8'b01101011;
        font_rom[700] = 8'b01111111; font_rom[701] = 8'b00111110;
        font_rom[702] = 8'b00110110; font_rom[703] = 8'b00000000;

        // Character 0x78: x
        font_rom[704] = 8'b00000000; font_rom[705] = 8'b00000000;
        font_rom[706] = 8'b01100110; font_rom[707] = 8'b00111100;
        font_rom[708] = 8'b00011000; font_rom[709] = 8'b00111100;
        font_rom[710] = 8'b01100110; font_rom[711] = 8'b00000000;

        // Character 0x79: y
        font_rom[712] = 8'b00000000; font_rom[713] = 8'b00000000;
        font_rom[714] = 8'b01100110; font_rom[715] = 8'b01100110;
        font_rom[716] = 8'b01100110; font_rom[717] = 8'b00111110;
        font_rom[718] = 8'b00000110; font_rom[719] = 8'b00111100;

        // Character 0x7A: z
        font_rom[720] = 8'b00000000; font_rom[721] = 8'b00000000;
        font_rom[722] = 8'b01111110; font_rom[723] = 8'b00001100;
        font_rom[724] = 8'b00011000; font_rom[725] = 8'b00110000;
        font_rom[726] = 8'b01111110; font_rom[727] = 8'b00000000;

        // Character 0x7B: {
        font_rom[728] = 8'b00001110; font_rom[729] = 8'b00011000;
        font_rom[730] = 8'b00011000; font_rom[731] = 8'b01110000;
        font_rom[732] = 8'b00011000; font_rom[733] = 8'b00011000;
        font_rom[734] = 8'b00001110; font_rom[735] = 8'b00000000;

        // Character 0x7C: |
        font_rom[736] = 8'b00011000; font_rom[737] = 8'b00011000;
        font_rom[738] = 8'b00011000; font_rom[739] = 8'b00011000;
        font_rom[740] = 8'b00011000; font_rom[741] = 8'b00011000;
        font_rom[742] = 8'b00011000; font_rom[743] = 8'b00000000;

        // Character 0x7D: }
        font_rom[744] = 8'b01110000; font_rom[745] = 8'b00011000;
        font_rom[746] = 8'b00011000; font_rom[747] = 8'b00001110;
        font_rom[748] = 8'b00011000; font_rom[749] = 8'b00011000;
        font_rom[750] = 8'b01110000; font_rom[751] = 8'b00000000;

        // Character 0x7E: ~
        font_rom[752] = 8'b00110011; font_rom[753] = 8'b01100110;
        font_rom[754] = 8'b11001100; font_rom[755] = 8'b00000000;
        font_rom[756] = 8'b00000000; font_rom[757] = 8'b00000000;
        font_rom[758] = 8'b00000000; font_rom[759] = 8'b00000000;

        // Character 0x7F: DEL (block character for visibility)
        font_rom[760] = 8'b11111111; font_rom[761] = 8'b11111111;
        font_rom[762] = 8'b11111111; font_rom[763] = 8'b11111111;
        font_rom[764] = 8'b11111111; font_rom[765] = 8'b11111111;
        font_rom[766] = 8'b11111111; font_rom[767] = 8'b11111111;
    end

    // =========================================================================
    // Font ROM Read
    // =========================================================================
    reg [7:0] font_row_data;

    always @(posedge clk_video) begin
        font_row_data <= font_rom[font_addr];
    end

    // =========================================================================
    // Pixel Selection
    // =========================================================================
    // Select the correct bit from the font row (MSB = leftmost pixel)
    wire pixel_bit = font_row_data[7 - pixel_col_d2];

    // =========================================================================
    // Output Assignment
    // =========================================================================
    assign osd_visible = inside_osd_d2;
    assign osd_pixel = inside_osd_d2 & pixel_bit;

endmodule
