//==============================================================================
// Module:      test_sinus
// Description: Sine wave test pattern generator for CRT display testing
//==============================================================================
// Author:      Kosjenka Vukovic, FPGA Architect, REGOC team
// Reviewer:    Jelena Horvat (original implementation in top_pdp1.v), REGOC team
// Created:     2026-02-06
//
// This module generates two sine wave test patterns that alternate each pixel:
//   - Sine1: Primary wave at center position, 4x phase increment
//   - Sine2: Secondary wave 100px higher, 2x phase increment (slower)
//
// The patterns are designed to test CRT phosphor decay and coordinate
// transformation pipeline. When enabled via SW[2], replaces CPU pixel
// coordinates while maintaining CPU DPY timing.
//
// Clock Domain: clk_cpu (1.82 MHz derived from 51 MHz / 28) - Jelena
// Timing: Updates on i_pixel_shift pulse from CPU DPY instruction
//
// Coordinate System (PDP-1 CRT transformation):
//   - i_pixel_shift triggers coordinate update
//   - o_x becomes vertical position after CRT inversion (~buffer_Y)
//   - o_y becomes horizontal position on screen (buffer_X)
//   - Result: horizontal sine wave sweeping across screen
//
//==============================================================================

module test_sinus (
    // =========================================================================
    // Clock and Reset
    // =========================================================================
    input  wire        i_clk,           // CPU clock (1.82 MHz) - Jelena
    input  wire        i_rst_n,         // Active-low synchronous reset

    // =========================================================================
    // Control Interface
    // =========================================================================
    input  wire        i_enable,        // Enable test pattern (SW[2])
    input  wire        i_pixel_shift,   // Pixel timing from CPU DPY

    // =========================================================================
    // Pixel Output
    // =========================================================================
    output wire [9:0]  o_x,             // X coordinate (becomes vertical on CRT)
    output wire [9:0]  o_y,             // Y coordinate (becomes horizontal on CRT)
    output wire [2:0]  o_brightness,    // Pixel brightness (3-bit)
    output wire        o_valid          // Output coordinates valid
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    // Sine wave parameters for coordinate calculation
    // NOTE: In PDP-1 mode, CRT does coordinate swap:
    //   {buffer_Y, buffer_X} = {~i_pixel_x, i_pixel_y}
    // So our o_x becomes vertical (buffer_Y) and o_y becomes horizontal (buffer_X)
    // To get a HORIZONTAL sine wave on screen:
    //   - Put SWEEP in o_y (becomes horizontal buffer_X)
    //   - Put SINE OFFSET in o_x (becomes vertical buffer_Y after inversion)
    // -------------------------------------------------------------------------
    localparam SINE_CENTER_X    = 10'd512;  // Center X for sine1 vertical position
    localparam SINE2_CENTER_X   = 10'd612;  // Sine2: 100 pixels higher on screen
    localparam SINE_AMPLITUDE   = 8'd100;   // Amplitude in pixels (unused, implicit in LUT scaling)

    // =========================================================================
    // SINE LOOKUP TABLE
    // =========================================================================
    // 256 entries, values 0-255 (128 = zero crossing)
    // Same format as test_animation.v for consistency
    // -------------------------------------------------------------------------
    reg [7:0] r_sine_lut [0:255];

    // Initialize sine lookup table
    initial begin
        // Quadrant 0: 0-63 (0 to pi/2)
        r_sine_lut[  0] = 8'd128; r_sine_lut[  1] = 8'd131; r_sine_lut[  2] = 8'd134; r_sine_lut[  3] = 8'd137;
        r_sine_lut[  4] = 8'd140; r_sine_lut[  5] = 8'd143; r_sine_lut[  6] = 8'd146; r_sine_lut[  7] = 8'd149;
        r_sine_lut[  8] = 8'd152; r_sine_lut[  9] = 8'd156; r_sine_lut[ 10] = 8'd159; r_sine_lut[ 11] = 8'd162;
        r_sine_lut[ 12] = 8'd165; r_sine_lut[ 13] = 8'd168; r_sine_lut[ 14] = 8'd171; r_sine_lut[ 15] = 8'd174;
        r_sine_lut[ 16] = 8'd177; r_sine_lut[ 17] = 8'd179; r_sine_lut[ 18] = 8'd182; r_sine_lut[ 19] = 8'd185;
        r_sine_lut[ 20] = 8'd188; r_sine_lut[ 21] = 8'd191; r_sine_lut[ 22] = 8'd193; r_sine_lut[ 23] = 8'd196;
        r_sine_lut[ 24] = 8'd199; r_sine_lut[ 25] = 8'd201; r_sine_lut[ 26] = 8'd204; r_sine_lut[ 27] = 8'd206;
        r_sine_lut[ 28] = 8'd209; r_sine_lut[ 29] = 8'd211; r_sine_lut[ 30] = 8'd213; r_sine_lut[ 31] = 8'd216;
        r_sine_lut[ 32] = 8'd218; r_sine_lut[ 33] = 8'd220; r_sine_lut[ 34] = 8'd222; r_sine_lut[ 35] = 8'd224;
        r_sine_lut[ 36] = 8'd226; r_sine_lut[ 37] = 8'd228; r_sine_lut[ 38] = 8'd230; r_sine_lut[ 39] = 8'd232;
        r_sine_lut[ 40] = 8'd234; r_sine_lut[ 41] = 8'd235; r_sine_lut[ 42] = 8'd237; r_sine_lut[ 43] = 8'd238;
        r_sine_lut[ 44] = 8'd240; r_sine_lut[ 45] = 8'd241; r_sine_lut[ 46] = 8'd243; r_sine_lut[ 47] = 8'd244;
        r_sine_lut[ 48] = 8'd245; r_sine_lut[ 49] = 8'd246; r_sine_lut[ 50] = 8'd247; r_sine_lut[ 51] = 8'd248;
        r_sine_lut[ 52] = 8'd249; r_sine_lut[ 53] = 8'd250; r_sine_lut[ 54] = 8'd251; r_sine_lut[ 55] = 8'd252;
        r_sine_lut[ 56] = 8'd252; r_sine_lut[ 57] = 8'd253; r_sine_lut[ 58] = 8'd253; r_sine_lut[ 59] = 8'd254;
        r_sine_lut[ 60] = 8'd254; r_sine_lut[ 61] = 8'd254; r_sine_lut[ 62] = 8'd255; r_sine_lut[ 63] = 8'd255;
        // Quadrant 1: 64-127 (pi/2 to pi)
        r_sine_lut[ 64] = 8'd255; r_sine_lut[ 65] = 8'd255; r_sine_lut[ 66] = 8'd255; r_sine_lut[ 67] = 8'd254;
        r_sine_lut[ 68] = 8'd254; r_sine_lut[ 69] = 8'd254; r_sine_lut[ 70] = 8'd253; r_sine_lut[ 71] = 8'd253;
        r_sine_lut[ 72] = 8'd252; r_sine_lut[ 73] = 8'd252; r_sine_lut[ 74] = 8'd251; r_sine_lut[ 75] = 8'd250;
        r_sine_lut[ 76] = 8'd249; r_sine_lut[ 77] = 8'd248; r_sine_lut[ 78] = 8'd247; r_sine_lut[ 79] = 8'd246;
        r_sine_lut[ 80] = 8'd245; r_sine_lut[ 81] = 8'd244; r_sine_lut[ 82] = 8'd243; r_sine_lut[ 83] = 8'd241;
        r_sine_lut[ 84] = 8'd240; r_sine_lut[ 85] = 8'd238; r_sine_lut[ 86] = 8'd237; r_sine_lut[ 87] = 8'd235;
        r_sine_lut[ 88] = 8'd234; r_sine_lut[ 89] = 8'd232; r_sine_lut[ 90] = 8'd230; r_sine_lut[ 91] = 8'd228;
        r_sine_lut[ 92] = 8'd226; r_sine_lut[ 93] = 8'd224; r_sine_lut[ 94] = 8'd222; r_sine_lut[ 95] = 8'd220;
        r_sine_lut[ 96] = 8'd218; r_sine_lut[ 97] = 8'd216; r_sine_lut[ 98] = 8'd213; r_sine_lut[ 99] = 8'd211;
        r_sine_lut[100] = 8'd209; r_sine_lut[101] = 8'd206; r_sine_lut[102] = 8'd204; r_sine_lut[103] = 8'd201;
        r_sine_lut[104] = 8'd199; r_sine_lut[105] = 8'd196; r_sine_lut[106] = 8'd193; r_sine_lut[107] = 8'd191;
        r_sine_lut[108] = 8'd188; r_sine_lut[109] = 8'd185; r_sine_lut[110] = 8'd182; r_sine_lut[111] = 8'd179;
        r_sine_lut[112] = 8'd177; r_sine_lut[113] = 8'd174; r_sine_lut[114] = 8'd171; r_sine_lut[115] = 8'd168;
        r_sine_lut[116] = 8'd165; r_sine_lut[117] = 8'd162; r_sine_lut[118] = 8'd159; r_sine_lut[119] = 8'd156;
        r_sine_lut[120] = 8'd152; r_sine_lut[121] = 8'd149; r_sine_lut[122] = 8'd146; r_sine_lut[123] = 8'd143;
        r_sine_lut[124] = 8'd140; r_sine_lut[125] = 8'd137; r_sine_lut[126] = 8'd134; r_sine_lut[127] = 8'd131;
        // Quadrant 2: 128-191 (pi to 3*pi/2)
        r_sine_lut[128] = 8'd128; r_sine_lut[129] = 8'd125; r_sine_lut[130] = 8'd122; r_sine_lut[131] = 8'd119;
        r_sine_lut[132] = 8'd116; r_sine_lut[133] = 8'd113; r_sine_lut[134] = 8'd110; r_sine_lut[135] = 8'd107;
        r_sine_lut[136] = 8'd104; r_sine_lut[137] = 8'd100; r_sine_lut[138] = 8'd97;  r_sine_lut[139] = 8'd94;
        r_sine_lut[140] = 8'd91;  r_sine_lut[141] = 8'd88;  r_sine_lut[142] = 8'd85;  r_sine_lut[143] = 8'd82;
        r_sine_lut[144] = 8'd79;  r_sine_lut[145] = 8'd77;  r_sine_lut[146] = 8'd74;  r_sine_lut[147] = 8'd71;
        r_sine_lut[148] = 8'd68;  r_sine_lut[149] = 8'd65;  r_sine_lut[150] = 8'd63;  r_sine_lut[151] = 8'd60;
        r_sine_lut[152] = 8'd57;  r_sine_lut[153] = 8'd55;  r_sine_lut[154] = 8'd52;  r_sine_lut[155] = 8'd50;
        r_sine_lut[156] = 8'd47;  r_sine_lut[157] = 8'd45;  r_sine_lut[158] = 8'd43;  r_sine_lut[159] = 8'd40;
        r_sine_lut[160] = 8'd38;  r_sine_lut[161] = 8'd36;  r_sine_lut[162] = 8'd34;  r_sine_lut[163] = 8'd32;
        r_sine_lut[164] = 8'd30;  r_sine_lut[165] = 8'd28;  r_sine_lut[166] = 8'd26;  r_sine_lut[167] = 8'd24;
        r_sine_lut[168] = 8'd22;  r_sine_lut[169] = 8'd21;  r_sine_lut[170] = 8'd19;  r_sine_lut[171] = 8'd18;
        r_sine_lut[172] = 8'd16;  r_sine_lut[173] = 8'd15;  r_sine_lut[174] = 8'd13;  r_sine_lut[175] = 8'd12;
        r_sine_lut[176] = 8'd11;  r_sine_lut[177] = 8'd10;  r_sine_lut[178] = 8'd9;   r_sine_lut[179] = 8'd8;
        r_sine_lut[180] = 8'd7;   r_sine_lut[181] = 8'd6;   r_sine_lut[182] = 8'd5;   r_sine_lut[183] = 8'd4;
        r_sine_lut[184] = 8'd4;   r_sine_lut[185] = 8'd3;   r_sine_lut[186] = 8'd3;   r_sine_lut[187] = 8'd2;
        r_sine_lut[188] = 8'd2;   r_sine_lut[189] = 8'd2;   r_sine_lut[190] = 8'd1;   r_sine_lut[191] = 8'd1;
        // Quadrant 3: 192-255 (3*pi/2 to 2*pi)
        r_sine_lut[192] = 8'd1;   r_sine_lut[193] = 8'd1;   r_sine_lut[194] = 8'd1;   r_sine_lut[195] = 8'd2;
        r_sine_lut[196] = 8'd2;   r_sine_lut[197] = 8'd2;   r_sine_lut[198] = 8'd3;   r_sine_lut[199] = 8'd3;
        r_sine_lut[200] = 8'd4;   r_sine_lut[201] = 8'd4;   r_sine_lut[202] = 8'd5;   r_sine_lut[203] = 8'd6;
        r_sine_lut[204] = 8'd7;   r_sine_lut[205] = 8'd8;   r_sine_lut[206] = 8'd9;   r_sine_lut[207] = 8'd10;
        r_sine_lut[208] = 8'd11;  r_sine_lut[209] = 8'd12;  r_sine_lut[210] = 8'd13;  r_sine_lut[211] = 8'd15;
        r_sine_lut[212] = 8'd16;  r_sine_lut[213] = 8'd18;  r_sine_lut[214] = 8'd19;  r_sine_lut[215] = 8'd21;
        r_sine_lut[216] = 8'd22;  r_sine_lut[217] = 8'd24;  r_sine_lut[218] = 8'd26;  r_sine_lut[219] = 8'd28;
        r_sine_lut[220] = 8'd30;  r_sine_lut[221] = 8'd32;  r_sine_lut[222] = 8'd34;  r_sine_lut[223] = 8'd36;
        r_sine_lut[224] = 8'd38;  r_sine_lut[225] = 8'd40;  r_sine_lut[226] = 8'd43;  r_sine_lut[227] = 8'd45;
        r_sine_lut[228] = 8'd47;  r_sine_lut[229] = 8'd50;  r_sine_lut[230] = 8'd52;  r_sine_lut[231] = 8'd55;
        r_sine_lut[232] = 8'd57;  r_sine_lut[233] = 8'd60;  r_sine_lut[234] = 8'd63;  r_sine_lut[235] = 8'd65;
        r_sine_lut[236] = 8'd68;  r_sine_lut[237] = 8'd71;  r_sine_lut[238] = 8'd74;  r_sine_lut[239] = 8'd77;
        r_sine_lut[240] = 8'd79;  r_sine_lut[241] = 8'd82;  r_sine_lut[242] = 8'd85;  r_sine_lut[243] = 8'd88;
        r_sine_lut[244] = 8'd91;  r_sine_lut[245] = 8'd94;  r_sine_lut[246] = 8'd97;  r_sine_lut[247] = 8'd100;
        r_sine_lut[248] = 8'd104; r_sine_lut[249] = 8'd107; r_sine_lut[250] = 8'd110; r_sine_lut[251] = 8'd113;
        r_sine_lut[252] = 8'd116; r_sine_lut[253] = 8'd119; r_sine_lut[254] = 8'd122; r_sine_lut[255] = 8'd125;
    end

    // =========================================================================
    // SINE1: Primary Sine Wave Generator
    // =========================================================================
    // X sweeps 0-1023 (10 bits), Y = CENTER + sine_offset
    // Updates on every i_pixel_shift pulse
    // -------------------------------------------------------------------------
    reg [9:0]  r_sine1_t;              // Time/phase counter (sweep position)
    reg [9:0]  r_sine1_x;              // Calculated X coordinate
    reg [9:0]  r_sine1_y;              // Calculated Y coordinate
    reg [7:0]  r_sine1_phase;          // Phase for sine lookup (wraps at 256)
    reg signed [9:0] r_sine1_offset;   // Signed offset from center

    // COORDINATE SWAP FIX (Jelena Horvat, 2026-02-02):
    // PDP-1 CRT transformation: {buffer_Y, buffer_X} = {~pixel_x, pixel_y}
    // This means:
    //   - pixel_x -> inverted -> vertical position on screen (buffer_Y)
    //   - pixel_y -> unchanged -> horizontal position on screen (buffer_X)
    //
    // For HORIZONTAL sine wave:
    //   - r_sine1_y = SWEEP (0->1023) -> becomes buffer_X (horizontal sweep)
    //   - r_sine1_x = CENTER + offset -> becomes ~buffer_Y (vertical sine)
    always @(posedge i_clk) begin
        if (~i_rst_n) begin
            r_sine1_t      <= 10'd0;
            r_sine1_x      <= SINE_CENTER_X;
            r_sine1_y      <= 10'd0;
            r_sine1_phase  <= 8'd0;
            r_sine1_offset <= 10'sd0;
        end else if (i_pixel_shift) begin
            // Advance time counter (wraps at 1024)
            r_sine1_t <= r_sine1_t + 1'b1;

            // r_sine1_y = SWEEP: becomes horizontal position on screen (buffer_X)
            r_sine1_y <= r_sine1_t[9:0];

            // Phase advances 4x faster than sweep for visible oscillation
            r_sine1_phase <= r_sine1_phase + 8'd4;

            // Calculate signed offset: (sine_lut - 128)
            // sine_lut is 0-255, subtract 128 to get -128 to +127 range
            r_sine1_offset <= $signed({2'b0, r_sine_lut[r_sine1_phase]}) - 10'sd128;

            // r_sine1_x = CENTER + offset: becomes vertical position (~buffer_Y)
            // Since CRT inverts X, higher values here = lower on screen
            r_sine1_x <= SINE_CENTER_X + r_sine1_offset[9:0];
        end
    end

    // =========================================================================
    // SINE2: Secondary Sine Wave Generator
    // =========================================================================
    // Higher position on screen, slower update rate, stronger phosphor
    // Updates every 4th i_pixel_shift pulse for slower movement
    // Author: Jelena Kovacevic, REGOC team (original in top_pdp1.v)
    // -------------------------------------------------------------------------
    reg [9:0]  r_sine2_t;              // Time/phase counter
    reg [9:0]  r_sine2_x;              // Calculated X coordinate
    reg [9:0]  r_sine2_y;              // Calculated Y coordinate
    reg [7:0]  r_sine2_phase;          // Phase for sine lookup
    reg signed [9:0] r_sine2_offset;   // Signed offset from center
    reg [1:0]  r_sine2_slowdown;       // Counter for 4x slower update

    always @(posedge i_clk) begin
        if (~i_rst_n) begin
            r_sine2_t        <= 10'd0;
            r_sine2_x        <= SINE2_CENTER_X;
            r_sine2_y        <= 10'd0;
            r_sine2_phase    <= 8'd0;
            r_sine2_offset   <= 10'sd0;
            r_sine2_slowdown <= 2'd0;
        end else if (i_pixel_shift) begin
            // Sine2 updates every 4th pixel_shift (slower)
            r_sine2_slowdown <= r_sine2_slowdown + 1'b1;
            if (r_sine2_slowdown == 2'd3) begin
                // Advance time counter (wraps at 1024)
                r_sine2_t <= r_sine2_t + 1'b1;

                // r_sine2_y = SWEEP: horizontal position on screen
                r_sine2_y <= r_sine2_t[9:0];

                // Phase advances 2x (slower oscillation than sine1 which uses 4x)
                r_sine2_phase <= r_sine2_phase + 8'd2;

                // Calculate signed offset
                r_sine2_offset <= $signed({2'b0, r_sine_lut[r_sine2_phase]}) - 10'sd128;

                // r_sine2_x = CENTER + offset: vertical position
                r_sine2_x <= SINE2_CENTER_X + r_sine2_offset[9:0];
            end
        end
    end

    // =========================================================================
    // OUTPUT MULTIPLEXER
    // =========================================================================
    // Alternates between sine1 and sine2 on each pixel_shift
    // Provides visual variety and tests multiple coordinate paths
    // -------------------------------------------------------------------------
    reg r_sine_select;  // 0 = sine1, 1 = sine2

    always @(posedge i_clk) begin
        if (~i_rst_n) begin
            r_sine_select <= 1'b0;
        end else if (i_pixel_shift) begin
            // Toggle between sine1 and sine2 each pixel_shift
            r_sine_select <= ~r_sine_select;
        end
    end

    // Multiplexed sine coordinates (alternates sine1/sine2)
    wire [9:0] w_mux_x = r_sine_select ? r_sine2_x : r_sine1_x;
    wire [9:0] w_mux_y = r_sine_select ? r_sine2_y : r_sine1_y;
    // Sine2 has stronger phosphor: 3'b110, sine1 keeps 3'd7
    wire [2:0] w_mux_brightness = r_sine_select ? 3'b110 : 3'd7;

    // =========================================================================
    // OUTPUT ASSIGNMENTS
    // =========================================================================
    assign o_x          = w_mux_x;
    assign o_y          = w_mux_y;
    assign o_brightness = w_mux_brightness;
    assign o_valid      = i_enable;  // Valid whenever test mode is enabled

endmodule
