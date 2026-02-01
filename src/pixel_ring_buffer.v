// pixel_ring_buffer.v
// TASK-123/196: CRT phosphor decay emulation - FULL 8-TAP VERSION
// Author: Jelena Kovacevic, FPGA Engineer
// Date: 2026-01-31
//
// REPLICATED MEMORY APPROACH:
// - 8 BRAM instanci (svaka 1024 x 32-bit)
// - Sve memorije se pisu istovremeno s istim podatkom
// - Svaka memorija cita s razlicitog offseta (tap pozicija)
// - Omogucuje istovremeni pristup svim tapovima za phosphor decay
//
// TAP DISTANCES:
// - tap0: 1 piksel delay (najnoviji)
// - tap1: 128 piksela delay
// - tap2: 256 piksela delay
// - tap3: 384 piksela delay
// - tap4: 512 piksela delay
// - tap5: 640 piksela delay
// - tap6: 768 piksela delay
// - tap7: 896 piksela delay (najstariji - shiftout)

module pixel_ring_buffer
(
    input wire clock,
    input wire [31:0] shiftin,
    output wire [31:0] shiftout,
    output wire [255:0] taps,
    // Debug output: current write pointer position (ring buffer fill indicator)
    output wire [9:0] debug_wrptr
);

    // Parameters
    localparam DEPTH = 1024;        // Depth per BRAM instance
    localparam WIDTH = 32;          // Data width: 10-bit Y, 10-bit X, 12-bit luma
    localparam ADDR_WIDTH = 10;     // log2(1024) = 10 bits
    localparam TAP_DISTANCE = 800;  // BILO: 128 (jedna VGA linija)

    // Write pointer - shared across all memories
    reg [ADDR_WIDTH-1:0] wrptr = 0;

    // 8 BRAM instances - all written with same data
    // Initialize to 0 to prevent garbage pixels after power-up
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem0 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem1 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem2 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem3 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem4 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem5 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem6 [0:DEPTH-1];
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem7 [0:DEPTH-1];

    // Initialize all memories to 0 (luma=0 means inactive pixel)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem0[init_i] = 32'd0;
            mem1[init_i] = 32'd0;
            mem2[init_i] = 32'd0;
            mem3[init_i] = 32'd0;
            mem4[init_i] = 32'd0;
            mem5[init_i] = 32'd0;
            mem6[init_i] = 32'd0;
            mem7[init_i] = 32'd0;
        end
    end

    // Read pointers - each reads from different offset
    // Using subtraction for proper circular buffer behavior
    // Note: With 10-bit address space (0-1023), subtraction wraps automatically
    // Tap distances are spaced evenly across the buffer depth
    wire [ADDR_WIDTH-1:0] rdptr0 = wrptr - 10'd1;     // tap[0]: 1 pixel back (most recent)
    wire [ADDR_WIDTH-1:0] rdptr1 = wrptr - 10'd128;   // tap[1]: 128 pixels back
    wire [ADDR_WIDTH-1:0] rdptr2 = wrptr - 10'd256;   // tap[2]: 256 pixels back
    wire [ADDR_WIDTH-1:0] rdptr3 = wrptr - 10'd384;   // tap[3]: 384 pixels back
    wire [ADDR_WIDTH-1:0] rdptr4 = wrptr - 10'd512;   // tap[4]: 512 pixels back
    wire [ADDR_WIDTH-1:0] rdptr5 = wrptr - 10'd640;   // tap[5]: 640 pixels back
    wire [ADDR_WIDTH-1:0] rdptr6 = wrptr - 10'd768;   // tap[6]: 768 pixels back
    wire [ADDR_WIDTH-1:0] rdptr7 = wrptr - 10'd896;   // tap[7]: 896 pixels back (oldest)

    // Read data registers for each tap
    reg [WIDTH-1:0] tap_data0 = 0;
    reg [WIDTH-1:0] tap_data1 = 0;
    reg [WIDTH-1:0] tap_data2 = 0;
    reg [WIDTH-1:0] tap_data3 = 0;
    reg [WIDTH-1:0] tap_data4 = 0;
    reg [WIDTH-1:0] tap_data5 = 0;
    reg [WIDTH-1:0] tap_data6 = 0;
    reg [WIDTH-1:0] tap_data7 = 0;

    // Main clock process
    always @(posedge clock) begin
        // Write shiftin to ALL memories at wrptr
        mem0[wrptr] <= shiftin;
        mem1[wrptr] <= shiftin;
        mem2[wrptr] <= shiftin;
        mem3[wrptr] <= shiftin;
        mem4[wrptr] <= shiftin;
        mem5[wrptr] <= shiftin;
        mem6[wrptr] <= shiftin;
        mem7[wrptr] <= shiftin;

        // Read from each memory at its respective offset
        tap_data0 <= mem0[rdptr0];
        tap_data1 <= mem1[rdptr1];
        tap_data2 <= mem2[rdptr2];
        tap_data3 <= mem3[rdptr3];
        tap_data4 <= mem4[rdptr4];
        tap_data5 <= mem5[rdptr5];
        tap_data6 <= mem6[rdptr6];
        tap_data7 <= mem7[rdptr7];

        // Increment write pointer (wraps automatically at 1024)
        wrptr <= wrptr + 1'b1;
    end

    // Output assignments - concatenate all taps
    assign taps[31:0]    = tap_data0;   // Newest tap (1 pixel back)
    assign taps[63:32]   = tap_data1;   // 128 pixels back
    assign taps[95:64]   = tap_data2;   // 256 pixels back
    assign taps[127:96]  = tap_data3;   // 384 pixels back
    assign taps[159:128] = tap_data4;   // 512 pixels back
    assign taps[191:160] = tap_data5;   // 640 pixels back
    assign taps[223:192] = tap_data6;   // 768 pixels back
    assign taps[255:224] = tap_data7;   // Oldest tap (896 pixels back)

    // shiftout is the oldest data (same as tap7)
    assign shiftout = tap_data7;

    // Debug: expose write pointer for monitoring ring buffer position
    assign debug_wrptr = wrptr;

endmodule
