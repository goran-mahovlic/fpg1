// =============================================================================
// Test Animation Module: "Orbital Spark" - Phosphor Decay Test
// =============================================================================
// Dizajn: Git
// Implementacija: Jelena Horvat, REGOC tim
// Datum: 2026-01-31
//
// OPIS:
//   Svijetla tocka koja kruzi po elipticnoj orbiti oko centra ekrana.
//   Phosphor decay u CRT modulu stvara "rep" iza tocke.
//
// MATEMATIKA:
//   X(t) = Cx + A * cos(theta)
//   Y(t) = Cy + B * sin(theta)
//
//   Za CRT 512x512:
//   - Cx = 256, Cy = 256 (centar)
//   - A = 100 (polu-os X)
//   - B = 80 (polu-os Y)
//   - theta se povecava svakih 1024 clockova za kontinuiranu animaciju
//
// INTERFACE:
//   - Kompatibilan s pdp1_vga_crt.v pixel interface
//   - Output: pixel_x, pixel_y, pixel_brightness, pixel_valid
//
// NAPOMENA:
//   Kontinuirano emitiranje piksela (ne ceka frame_tick).
//   Pri 25MHz, svakih 1024 clockova = ~24414 pozicija/sec = glatko kretanje
//
// TAGS: PHOSPHOR, ANIMATION, IMPLEMENTATION, VERILOG
// =============================================================================

module test_animation (
    input  wire        clk,              // Pixel clock (25 MHz)
    input  wire        rst_n,            // Active low reset
    input  wire        frame_tick,       // Pulse at start of each frame (vblank)

    output reg  [9:0]  pixel_x,          // X coordinate (0-639)
    output reg  [9:0]  pixel_y,          // Y coordinate (0-479)
    output reg  [2:0]  pixel_brightness, // Brightness (0-7, 7=max)
    output reg         pixel_valid,      // Pixel data valid strobe
    output wire [7:0]  debug_angle       // Current angle for debug output
);

    // =========================================================================
    // PARAMETERS - Ellipse Configuration (za PDP-1 512x512 koordinatni sustav)
    // =========================================================================
    // NAPOMENA: CRT modul mapira koordinate u PDP-1 prostor (0-511 x 0-511)
    // koji se prikazuje centriran u 640x480 VGA frameu.
    // Centar treba biti 256,240 za pravilno centriranje:
    // - X=256 je centar PDP-1 prostora (512/2)
    // - Y=240 je centar VGA prostora (480/2)
    localparam [9:0] CENTER_X = 10'd256;   // Centar X (PDP-1 512/2)
    localparam [9:0] CENTER_Y = 10'd240;   // Centar Y (VGA 480/2)
    localparam [7:0] SEMI_A   = 8'd100;    // Polu-os X (horizontal)
    localparam [7:0] SEMI_B   = 8'd80;     // Polu-os Y (vertical)

    // =========================================================================
    // SIN/COS LOOKUP TABLE
    // =========================================================================
    // 256 entries, 8-bit signed values stored as unsigned with offset 128
    // sin[i] = 128 + 127 * sin(2*pi*i/256)
    // cos[i] = 128 + 127 * cos(2*pi*i/256)
    //
    // Vrijednosti:
    //   0   -> sin = 0   -> stored as 128
    //   64  -> sin = 1   -> stored as 255
    //   128 -> sin = 0   -> stored as 128
    //   192 -> sin = -1  -> stored as 1

    reg [7:0] sin_table [0:255];
    reg [7:0] cos_table [0:255];

    // Inicijalizacija lookup tablica (generirano)
    initial begin
        // Quadrant 0: 0-63 (0 to pi/2)
        sin_table[  0] = 8'd128; cos_table[  0] = 8'd255;
        sin_table[  1] = 8'd131; cos_table[  1] = 8'd255;
        sin_table[  2] = 8'd134; cos_table[  2] = 8'd255;
        sin_table[  3] = 8'd137; cos_table[  3] = 8'd254;
        sin_table[  4] = 8'd140; cos_table[  4] = 8'd254;
        sin_table[  5] = 8'd143; cos_table[  5] = 8'd253;
        sin_table[  6] = 8'd146; cos_table[  6] = 8'd253;
        sin_table[  7] = 8'd149; cos_table[  7] = 8'd252;
        sin_table[  8] = 8'd152; cos_table[  8] = 8'd251;
        sin_table[  9] = 8'd156; cos_table[  9] = 8'd250;
        sin_table[ 10] = 8'd159; cos_table[ 10] = 8'd249;
        sin_table[ 11] = 8'd162; cos_table[ 11] = 8'd248;
        sin_table[ 12] = 8'd165; cos_table[ 12] = 8'd247;
        sin_table[ 13] = 8'd168; cos_table[ 13] = 8'd245;
        sin_table[ 14] = 8'd171; cos_table[ 14] = 8'd244;
        sin_table[ 15] = 8'd174; cos_table[ 15] = 8'd242;
        sin_table[ 16] = 8'd177; cos_table[ 16] = 8'd241;
        sin_table[ 17] = 8'd179; cos_table[ 17] = 8'd239;
        sin_table[ 18] = 8'd182; cos_table[ 18] = 8'd237;
        sin_table[ 19] = 8'd185; cos_table[ 19] = 8'd235;
        sin_table[ 20] = 8'd188; cos_table[ 20] = 8'd233;
        sin_table[ 21] = 8'd191; cos_table[ 21] = 8'd231;
        sin_table[ 22] = 8'd193; cos_table[ 22] = 8'd229;
        sin_table[ 23] = 8'd196; cos_table[ 23] = 8'd226;
        sin_table[ 24] = 8'd199; cos_table[ 24] = 8'd224;
        sin_table[ 25] = 8'd201; cos_table[ 25] = 8'd221;
        sin_table[ 26] = 8'd204; cos_table[ 26] = 8'd219;
        sin_table[ 27] = 8'd206; cos_table[ 27] = 8'd216;
        sin_table[ 28] = 8'd209; cos_table[ 28] = 8'd213;
        sin_table[ 29] = 8'd211; cos_table[ 29] = 8'd210;
        sin_table[ 30] = 8'd213; cos_table[ 30] = 8'd207;
        sin_table[ 31] = 8'd216; cos_table[ 31] = 8'd204;
        sin_table[ 32] = 8'd218; cos_table[ 32] = 8'd201;
        sin_table[ 33] = 8'd220; cos_table[ 33] = 8'd198;
        sin_table[ 34] = 8'd222; cos_table[ 34] = 8'd195;
        sin_table[ 35] = 8'd224; cos_table[ 35] = 8'd192;
        sin_table[ 36] = 8'd226; cos_table[ 36] = 8'd188;
        sin_table[ 37] = 8'd228; cos_table[ 37] = 8'd185;
        sin_table[ 38] = 8'd230; cos_table[ 38] = 8'd181;
        sin_table[ 39] = 8'd232; cos_table[ 39] = 8'd178;
        sin_table[ 40] = 8'd234; cos_table[ 40] = 8'd174;
        sin_table[ 41] = 8'd235; cos_table[ 41] = 8'd170;
        sin_table[ 42] = 8'd237; cos_table[ 42] = 8'd167;
        sin_table[ 43] = 8'd238; cos_table[ 43] = 8'd163;
        sin_table[ 44] = 8'd240; cos_table[ 44] = 8'd159;
        sin_table[ 45] = 8'd241; cos_table[ 45] = 8'd155;
        sin_table[ 46] = 8'd243; cos_table[ 46] = 8'd151;
        sin_table[ 47] = 8'd244; cos_table[ 47] = 8'd147;
        sin_table[ 48] = 8'd245; cos_table[ 48] = 8'd143;
        sin_table[ 49] = 8'd246; cos_table[ 49] = 8'd139;
        sin_table[ 50] = 8'd247; cos_table[ 50] = 8'd135;
        sin_table[ 51] = 8'd248; cos_table[ 51] = 8'd131;
        sin_table[ 52] = 8'd249; cos_table[ 52] = 8'd126;
        sin_table[ 53] = 8'd250; cos_table[ 53] = 8'd122;
        sin_table[ 54] = 8'd251; cos_table[ 54] = 8'd118;
        sin_table[ 55] = 8'd252; cos_table[ 55] = 8'd114;
        sin_table[ 56] = 8'd252; cos_table[ 56] = 8'd109;
        sin_table[ 57] = 8'd253; cos_table[ 57] = 8'd105;
        sin_table[ 58] = 8'd253; cos_table[ 58] = 8'd100;
        sin_table[ 59] = 8'd254; cos_table[ 59] = 8'd96;
        sin_table[ 60] = 8'd254; cos_table[ 60] = 8'd91;
        sin_table[ 61] = 8'd254; cos_table[ 61] = 8'd87;
        sin_table[ 62] = 8'd255; cos_table[ 62] = 8'd82;
        sin_table[ 63] = 8'd255; cos_table[ 63] = 8'd78;

        // Quadrant 1: 64-127 (pi/2 to pi)
        sin_table[ 64] = 8'd255; cos_table[ 64] = 8'd128;
        sin_table[ 65] = 8'd255; cos_table[ 65] = 8'd124;
        sin_table[ 66] = 8'd255; cos_table[ 66] = 8'd119;
        sin_table[ 67] = 8'd254; cos_table[ 67] = 8'd115;
        sin_table[ 68] = 8'd254; cos_table[ 68] = 8'd110;
        sin_table[ 69] = 8'd254; cos_table[ 69] = 8'd106;
        sin_table[ 70] = 8'd253; cos_table[ 70] = 8'd101;
        sin_table[ 71] = 8'd253; cos_table[ 71] = 8'd97;
        sin_table[ 72] = 8'd252; cos_table[ 72] = 8'd92;
        sin_table[ 73] = 8'd252; cos_table[ 73] = 8'd88;
        sin_table[ 74] = 8'd251; cos_table[ 74] = 8'd83;
        sin_table[ 75] = 8'd250; cos_table[ 75] = 8'd79;
        sin_table[ 76] = 8'd249; cos_table[ 76] = 8'd75;
        sin_table[ 77] = 8'd248; cos_table[ 77] = 8'd70;
        sin_table[ 78] = 8'd247; cos_table[ 78] = 8'd66;
        sin_table[ 79] = 8'd246; cos_table[ 79] = 8'd62;
        sin_table[ 80] = 8'd245; cos_table[ 80] = 8'd57;
        sin_table[ 81] = 8'd244; cos_table[ 81] = 8'd53;
        sin_table[ 82] = 8'd243; cos_table[ 82] = 8'd49;
        sin_table[ 83] = 8'd241; cos_table[ 83] = 8'd45;
        sin_table[ 84] = 8'd240; cos_table[ 84] = 8'd41;
        sin_table[ 85] = 8'd238; cos_table[ 85] = 8'd37;
        sin_table[ 86] = 8'd237; cos_table[ 86] = 8'd33;
        sin_table[ 87] = 8'd235; cos_table[ 87] = 8'd30;
        sin_table[ 88] = 8'd234; cos_table[ 88] = 8'd26;
        sin_table[ 89] = 8'd232; cos_table[ 89] = 8'd22;
        sin_table[ 90] = 8'd230; cos_table[ 90] = 8'd19;
        sin_table[ 91] = 8'd228; cos_table[ 91] = 8'd16;
        sin_table[ 92] = 8'd226; cos_table[ 92] = 8'd12;
        sin_table[ 93] = 8'd224; cos_table[ 93] = 8'd9;
        sin_table[ 94] = 8'd222; cos_table[ 94] = 8'd6;
        sin_table[ 95] = 8'd220; cos_table[ 95] = 8'd4;
        sin_table[ 96] = 8'd218; cos_table[ 96] = 8'd1;
        sin_table[ 97] = 8'd216; cos_table[ 97] = 8'd0;
        sin_table[ 98] = 8'd213; cos_table[ 98] = 8'd0;
        sin_table[ 99] = 8'd211; cos_table[ 99] = 8'd0;
        sin_table[100] = 8'd209; cos_table[100] = 8'd0;
        sin_table[101] = 8'd206; cos_table[101] = 8'd0;
        sin_table[102] = 8'd204; cos_table[102] = 8'd0;
        sin_table[103] = 8'd201; cos_table[103] = 8'd0;
        sin_table[104] = 8'd199; cos_table[104] = 8'd0;
        sin_table[105] = 8'd196; cos_table[105] = 8'd1;
        sin_table[106] = 8'd193; cos_table[106] = 8'd1;
        sin_table[107] = 8'd191; cos_table[107] = 8'd2;
        sin_table[108] = 8'd188; cos_table[108] = 8'd3;
        sin_table[109] = 8'd185; cos_table[109] = 8'd4;
        sin_table[110] = 8'd182; cos_table[110] = 8'd5;
        sin_table[111] = 8'd179; cos_table[111] = 8'd6;
        sin_table[112] = 8'd177; cos_table[112] = 8'd8;
        sin_table[113] = 8'd174; cos_table[113] = 8'd10;
        sin_table[114] = 8'd171; cos_table[114] = 8'd11;
        sin_table[115] = 8'd168; cos_table[115] = 8'd13;
        sin_table[116] = 8'd165; cos_table[116] = 8'd16;
        sin_table[117] = 8'd162; cos_table[117] = 8'd18;
        sin_table[118] = 8'd159; cos_table[118] = 8'd20;
        sin_table[119] = 8'd156; cos_table[119] = 8'd23;
        sin_table[120] = 8'd152; cos_table[120] = 8'd26;
        sin_table[121] = 8'd149; cos_table[121] = 8'd29;
        sin_table[122] = 8'd146; cos_table[122] = 8'd32;
        sin_table[123] = 8'd143; cos_table[123] = 8'd35;
        sin_table[124] = 8'd140; cos_table[124] = 8'd38;
        sin_table[125] = 8'd137; cos_table[125] = 8'd42;
        sin_table[126] = 8'd134; cos_table[126] = 8'd45;
        sin_table[127] = 8'd131; cos_table[127] = 8'd49;

        // Quadrant 2: 128-191 (pi to 3*pi/2)
        sin_table[128] = 8'd128; cos_table[128] = 8'd1;
        sin_table[129] = 8'd125; cos_table[129] = 8'd1;
        sin_table[130] = 8'd122; cos_table[130] = 8'd1;
        sin_table[131] = 8'd119; cos_table[131] = 8'd2;
        sin_table[132] = 8'd116; cos_table[132] = 8'd2;
        sin_table[133] = 8'd113; cos_table[133] = 8'd3;
        sin_table[134] = 8'd110; cos_table[134] = 8'd3;
        sin_table[135] = 8'd107; cos_table[135] = 8'd4;
        sin_table[136] = 8'd104; cos_table[136] = 8'd5;
        sin_table[137] = 8'd100; cos_table[137] = 8'd6;
        sin_table[138] = 8'd97;  cos_table[138] = 8'd7;
        sin_table[139] = 8'd94;  cos_table[139] = 8'd8;
        sin_table[140] = 8'd91;  cos_table[140] = 8'd9;
        sin_table[141] = 8'd88;  cos_table[141] = 8'd11;
        sin_table[142] = 8'd85;  cos_table[142] = 8'd12;
        sin_table[143] = 8'd82;  cos_table[143] = 8'd14;
        sin_table[144] = 8'd79;  cos_table[144] = 8'd15;
        sin_table[145] = 8'd77;  cos_table[145] = 8'd17;
        sin_table[146] = 8'd74;  cos_table[146] = 8'd19;
        sin_table[147] = 8'd71;  cos_table[147] = 8'd21;
        sin_table[148] = 8'd68;  cos_table[148] = 8'd23;
        sin_table[149] = 8'd65;  cos_table[149] = 8'd25;
        sin_table[150] = 8'd63;  cos_table[150] = 8'd27;
        sin_table[151] = 8'd60;  cos_table[151] = 8'd30;
        sin_table[152] = 8'd57;  cos_table[152] = 8'd32;
        sin_table[153] = 8'd55;  cos_table[153] = 8'd35;
        sin_table[154] = 8'd52;  cos_table[154] = 8'd37;
        sin_table[155] = 8'd50;  cos_table[155] = 8'd40;
        sin_table[156] = 8'd47;  cos_table[156] = 8'd43;
        sin_table[157] = 8'd45;  cos_table[157] = 8'd46;
        sin_table[158] = 8'd43;  cos_table[158] = 8'd49;
        sin_table[159] = 8'd40;  cos_table[159] = 8'd52;
        sin_table[160] = 8'd38;  cos_table[160] = 8'd55;
        sin_table[161] = 8'd36;  cos_table[161] = 8'd58;
        sin_table[162] = 8'd34;  cos_table[162] = 8'd61;
        sin_table[163] = 8'd32;  cos_table[163] = 8'd64;
        sin_table[164] = 8'd30;  cos_table[164] = 8'd68;
        sin_table[165] = 8'd28;  cos_table[165] = 8'd71;
        sin_table[166] = 8'd26;  cos_table[166] = 8'd75;
        sin_table[167] = 8'd24;  cos_table[167] = 8'd78;
        sin_table[168] = 8'd22;  cos_table[168] = 8'd82;
        sin_table[169] = 8'd21;  cos_table[169] = 8'd86;
        sin_table[170] = 8'd19;  cos_table[170] = 8'd89;
        sin_table[171] = 8'd18;  cos_table[171] = 8'd93;
        sin_table[172] = 8'd16;  cos_table[172] = 8'd97;
        sin_table[173] = 8'd15;  cos_table[173] = 8'd101;
        sin_table[174] = 8'd13;  cos_table[174] = 8'd105;
        sin_table[175] = 8'd12;  cos_table[175] = 8'd109;
        sin_table[176] = 8'd11;  cos_table[176] = 8'd113;
        sin_table[177] = 8'd10;  cos_table[177] = 8'd117;
        sin_table[178] = 8'd9;   cos_table[178] = 8'd121;
        sin_table[179] = 8'd8;   cos_table[179] = 8'd125;
        sin_table[180] = 8'd7;   cos_table[180] = 8'd130;
        sin_table[181] = 8'd6;   cos_table[181] = 8'd134;
        sin_table[182] = 8'd5;   cos_table[182] = 8'd138;
        sin_table[183] = 8'd4;   cos_table[183] = 8'd142;
        sin_table[184] = 8'd4;   cos_table[184] = 8'd147;
        sin_table[185] = 8'd3;   cos_table[185] = 8'd151;
        sin_table[186] = 8'd3;   cos_table[186] = 8'd156;
        sin_table[187] = 8'd2;   cos_table[187] = 8'd160;
        sin_table[188] = 8'd2;   cos_table[188] = 8'd165;
        sin_table[189] = 8'd2;   cos_table[189] = 8'd169;
        sin_table[190] = 8'd1;   cos_table[190] = 8'd174;
        sin_table[191] = 8'd1;   cos_table[191] = 8'd178;

        // Quadrant 3: 192-255 (3*pi/2 to 2*pi)
        sin_table[192] = 8'd1;   cos_table[192] = 8'd128;
        sin_table[193] = 8'd1;   cos_table[193] = 8'd132;
        sin_table[194] = 8'd1;   cos_table[194] = 8'd137;
        sin_table[195] = 8'd2;   cos_table[195] = 8'd141;
        sin_table[196] = 8'd2;   cos_table[196] = 8'd146;
        sin_table[197] = 8'd2;   cos_table[197] = 8'd150;
        sin_table[198] = 8'd3;   cos_table[198] = 8'd155;
        sin_table[199] = 8'd3;   cos_table[199] = 8'd159;
        sin_table[200] = 8'd4;   cos_table[200] = 8'd164;
        sin_table[201] = 8'd4;   cos_table[201] = 8'd168;
        sin_table[202] = 8'd5;   cos_table[202] = 8'd173;
        sin_table[203] = 8'd6;   cos_table[203] = 8'd177;
        sin_table[204] = 8'd7;   cos_table[204] = 8'd181;
        sin_table[205] = 8'd8;   cos_table[205] = 8'd186;
        sin_table[206] = 8'd9;   cos_table[206] = 8'd190;
        sin_table[207] = 8'd10;  cos_table[207] = 8'd194;
        sin_table[208] = 8'd11;  cos_table[208] = 8'd199;
        sin_table[209] = 8'd12;  cos_table[209] = 8'd203;
        sin_table[210] = 8'd13;  cos_table[210] = 8'd207;
        sin_table[211] = 8'd15;  cos_table[211] = 8'd211;
        sin_table[212] = 8'd16;  cos_table[212] = 8'd215;
        sin_table[213] = 8'd18;  cos_table[213] = 8'd219;
        sin_table[214] = 8'd19;  cos_table[214] = 8'd223;
        sin_table[215] = 8'd21;  cos_table[215] = 8'd226;
        sin_table[216] = 8'd22;  cos_table[216] = 8'd230;
        sin_table[217] = 8'd24;  cos_table[217] = 8'd234;
        sin_table[218] = 8'd26;  cos_table[218] = 8'd237;
        sin_table[219] = 8'd28;  cos_table[219] = 8'd240;
        sin_table[220] = 8'd30;  cos_table[220] = 8'd244;
        sin_table[221] = 8'd32;  cos_table[221] = 8'd247;
        sin_table[222] = 8'd34;  cos_table[222] = 8'd250;
        sin_table[223] = 8'd36;  cos_table[223] = 8'd252;
        sin_table[224] = 8'd38;  cos_table[224] = 8'd255;
        sin_table[225] = 8'd40;  cos_table[225] = 8'd255;
        sin_table[226] = 8'd43;  cos_table[226] = 8'd255;
        sin_table[227] = 8'd45;  cos_table[227] = 8'd255;
        sin_table[228] = 8'd47;  cos_table[228] = 8'd255;
        sin_table[229] = 8'd50;  cos_table[229] = 8'd255;
        sin_table[230] = 8'd52;  cos_table[230] = 8'd255;
        sin_table[231] = 8'd55;  cos_table[231] = 8'd255;
        sin_table[232] = 8'd57;  cos_table[232] = 8'd255;
        sin_table[233] = 8'd60;  cos_table[233] = 8'd254;
        sin_table[234] = 8'd63;  cos_table[234] = 8'd254;
        sin_table[235] = 8'd65;  cos_table[235] = 8'd253;
        sin_table[236] = 8'd68;  cos_table[236] = 8'd252;
        sin_table[237] = 8'd71;  cos_table[237] = 8'd251;
        sin_table[238] = 8'd74;  cos_table[238] = 8'd250;
        sin_table[239] = 8'd77;  cos_table[239] = 8'd249;
        sin_table[240] = 8'd79;  cos_table[240] = 8'd247;
        sin_table[241] = 8'd82;  cos_table[241] = 8'd245;
        sin_table[242] = 8'd85;  cos_table[242] = 8'd244;
        sin_table[243] = 8'd88;  cos_table[243] = 8'd242;
        sin_table[244] = 8'd91;  cos_table[244] = 8'd240;
        sin_table[245] = 8'd94;  cos_table[245] = 8'd238;
        sin_table[246] = 8'd97;  cos_table[246] = 8'd235;
        sin_table[247] = 8'd100; cos_table[247] = 8'd233;
        sin_table[248] = 8'd104; cos_table[248] = 8'd231;
        sin_table[249] = 8'd107; cos_table[249] = 8'd228;
        sin_table[250] = 8'd110; cos_table[250] = 8'd225;
        sin_table[251] = 8'd113; cos_table[251] = 8'd222;
        sin_table[252] = 8'd116; cos_table[252] = 8'd220;
        sin_table[253] = 8'd119; cos_table[253] = 8'd217;
        sin_table[254] = 8'd122; cos_table[254] = 8'd213;
        sin_table[255] = 8'd125; cos_table[255] = 8'd210;
    end

    // =========================================================================
    // ANGLE COUNTER & EMIT COUNTER
    // =========================================================================
    // Kontinuirano emitiranje: svakih 1024 clockova nova pozicija
    // Pri 25MHz: 25000000/1024 = ~24414 pozicija/sec
    // 256 pozicija za puni krug = ~10.5 krugova/sec (brza animacija)

    reg [7:0] angle;
    reg [15:0] emit_counter;  // Broji clockove izmedju emitiranja

    // Export angle for debug
    assign debug_angle = angle;

    // =========================================================================
    // COORDINATE CALCULATION
    // =========================================================================
    // Pipeline registers for coordinate calculation
    reg [7:0] sin_val, cos_val;
    reg signed [16:0] x_offset, y_offset;
    reg [9:0] calc_x, calc_y;

    // State machine za pipelined izracun koordinata
    reg [2:0] state;
    localparam STATE_IDLE     = 3'd0;
    localparam STATE_LOOKUP   = 3'd1;
    localparam STATE_MULTIPLY = 3'd2;
    localparam STATE_OUTPUT   = 3'd3;

    always @(posedge clk) begin
        if (!rst_n) begin
            angle <= 8'd0;
            emit_counter <= 16'd0;
            state <= STATE_IDLE;
            pixel_valid <= 1'b0;
            pixel_x <= 10'd0;
            pixel_y <= 10'd0;
            pixel_brightness <= 3'd7;
            sin_val <= 8'd128;
            cos_val <= 8'd255;
            x_offset <= 17'd0;
            y_offset <= 17'd0;
            calc_x <= 10'd0;
            calc_y <= 10'd0;
        end else begin
            pixel_valid <= 1'b0;  // Default: no valid pixel
            emit_counter <= emit_counter + 1'b1;

            case (state)
                STATE_IDLE: begin
                    // Kontinuirano emitiranje: svakih 1024 clockova
                    if (emit_counter[9:0] == 10'd0) begin
                        // Nova pozicija na orbiti
                        angle <= angle + 1'b1;
                        state <= STATE_LOOKUP;
                    end
                end

                STATE_LOOKUP: begin
                    // Lookup sin/cos values
                    sin_val <= sin_table[angle];
                    cos_val <= cos_table[angle];
                    state <= STATE_MULTIPLY;
                end

                STATE_MULTIPLY: begin
                    // Calculate offsets:
                    // x_offset = (cos_val - 128) * SEMI_A / 127
                    // y_offset = (sin_val - 128) * SEMI_B / 127
                    // Simplified: multiply by semi-axis, then divide by 127 (shift right by 7)

                    // cos_val and sin_val are 0-255, offset 128 represents 0
                    // (val - 128) gives -127 to +127
                    x_offset <= ($signed({1'b0, cos_val}) - 17'sd128) * $signed({1'b0, SEMI_A});
                    y_offset <= ($signed({1'b0, sin_val}) - 17'sd128) * $signed({1'b0, SEMI_B});
                    state <= STATE_OUTPUT;
                end

                STATE_OUTPUT: begin
                    // Calculate final coordinates
                    // Divide by 128 using arithmetic shift (preserves sign)
                    // x_offset >>> 7 gives signed division by 128
                    calc_x <= CENTER_X + (x_offset >>> 7);
                    calc_y <= CENTER_Y + (y_offset >>> 7);

                    // Output pixel
                    pixel_x <= CENTER_X + (x_offset >>> 7);
                    pixel_y <= CENTER_Y + (y_offset >>> 7);
                    pixel_brightness <= 3'd7;  // Maximum brightness
                    pixel_valid <= 1'b1;

                    state <= STATE_IDLE;  // Odmah natrag u IDLE za sljedeci emit
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
