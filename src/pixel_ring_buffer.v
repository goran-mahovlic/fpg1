//==============================================================================
// Module: pixel_ring_buffer
// Project: PDP-1 FPGA Port
// Description: Multi-tap circular buffer for CRT phosphor decay emulation
//
// Author: Jelena Kovacevic, FPGA Engineer (Kosjenka Babic - Architecture Review)
// Created: 2026-01-31
// Modified: 2026-02-02 - Best practices implementation
//
// TASK-123/196: CRT phosphor decay emulation - FULL 8-TAP VERSION
//
//------------------------------------------------------------------------------
// Architecture: Replicated Memory Approach
//------------------------------------------------------------------------------
//
// To achieve simultaneous read access at 8 different positions (taps), we use
// 8 parallel BRAM instances. All memories receive the same write data, but
// each reads from a different offset position.
//
//     Write Data (shiftin)
//          |
//          v
//     +----+----+----+----+----+----+----+----+
//     |mem0|mem1|mem2|mem3|mem4|mem5|mem6|mem7|  (8 x 1024 x 32-bit BRAMs)
//     +--+-+--+-+--+-+--+-+--+-+--+-+--+-+--+-+
//        |    |    |    |    |    |    |    |
//        v    v    v    v    v    v    v    v
//      tap0 tap1 tap2 tap3 tap4 tap5 tap6 tap7   (Read at different offsets)
//
// Memory: 8 x 1024 x 32-bit = 256 Kbit total
//
//------------------------------------------------------------------------------
// Tap Distances (pixel delays from write position)
//------------------------------------------------------------------------------
//
//   Tap   | Offset | Description
//   ------|--------|----------------------------------
//   tap0  |     1  | Most recent pixel (1 pixel back)
//   tap1  |   128  | 128 pixels back
//   tap2  |   256  | 256 pixels back
//   tap3  |   384  | 384 pixels back
//   tap4  |   512  | 512 pixels back
//   tap5  |   640  | 640 pixels back
//   tap6  |   768  | 768 pixels back
//   tap7  |   896  | Oldest pixel (896 pixels back) = shiftout
//
// These offsets are chosen to provide good coverage across the buffer depth
// for efficient pixel lookup during ring buffer search operations.
//
//------------------------------------------------------------------------------
// Data Format (32 bits per entry)
//------------------------------------------------------------------------------
//
//   [31:22] | [21:12] | [11:0]
//   Y coord | X coord | Luma value
//   10 bits | 10 bits | 12 bits
//
//==============================================================================

`default_nettype none

module pixel_ring_buffer (
    //--------------------------------------------------------------------------
    // Clock
    //--------------------------------------------------------------------------
    input wire              i_clk,

    //--------------------------------------------------------------------------
    // Data Interface
    //--------------------------------------------------------------------------
    input wire [31:0]       i_shiftin,      // Data to write (Y[9:0], X[9:0], luma[11:0])
    output wire [31:0]      o_shiftout,     // Oldest data (tap7 = 896 pixels back)
    output wire [255:0]     o_taps,         // All 8 tap values concatenated

    //--------------------------------------------------------------------------
    // Debug
    //--------------------------------------------------------------------------
    output wire [9:0]       o_dbg_wrptr     // Current write pointer position
);

//==============================================================================
// Local Parameters
//==============================================================================

localparam DEPTH      = 1024;           // Entries per BRAM instance
localparam WIDTH      = 32;             // Data width: 10-bit Y + 10-bit X + 12-bit luma
localparam ADDR_WIDTH = 10;             // Address bits: log2(1024) = 10

// Tap offset distances (in pixels from write position)
localparam TAP0_OFFSET = 10'd1;         // Most recent
localparam TAP1_OFFSET = 10'd128;
localparam TAP2_OFFSET = 10'd256;
localparam TAP3_OFFSET = 10'd384;
localparam TAP4_OFFSET = 10'd512;
localparam TAP5_OFFSET = 10'd640;
localparam TAP6_OFFSET = 10'd768;
localparam TAP7_OFFSET = 10'd896;       // Oldest (shiftout)

//==============================================================================
// Internal Registers
//==============================================================================

//------------------------------------------------------------------------------
// Write Pointer (shared across all BRAM instances)
//------------------------------------------------------------------------------
reg [ADDR_WIDTH-1:0] r_wrptr = 0;

//------------------------------------------------------------------------------
// BRAM Instances (8 x 1024 x 32-bit)
//------------------------------------------------------------------------------
// All memories written with same data at same address (r_wrptr).
// Each memory reads from different offset for parallel tap access.
// Initialized to 0 to prevent garbage pixels after power-up.
//
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem0 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem1 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem2 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem3 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem4 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem5 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem6 [0:DEPTH-1];
(* ram_style = "block" *) reg [WIDTH-1:0] r_mem7 [0:DEPTH-1];

//------------------------------------------------------------------------------
// Memory Initialization
//------------------------------------------------------------------------------
// Initialize all entries to 0 (luma=0 indicates inactive/empty pixel slot)
integer init_i;
initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
        r_mem0[init_i] = 32'd0;
        r_mem1[init_i] = 32'd0;
        r_mem2[init_i] = 32'd0;
        r_mem3[init_i] = 32'd0;
        r_mem4[init_i] = 32'd0;
        r_mem5[init_i] = 32'd0;
        r_mem6[init_i] = 32'd0;
        r_mem7[init_i] = 32'd0;
    end
end

//------------------------------------------------------------------------------
// Tap Read Data Registers
//------------------------------------------------------------------------------
reg [WIDTH-1:0] r_tap_data0 = 0;
reg [WIDTH-1:0] r_tap_data1 = 0;
reg [WIDTH-1:0] r_tap_data2 = 0;
reg [WIDTH-1:0] r_tap_data3 = 0;
reg [WIDTH-1:0] r_tap_data4 = 0;
reg [WIDTH-1:0] r_tap_data5 = 0;
reg [WIDTH-1:0] r_tap_data6 = 0;
reg [WIDTH-1:0] r_tap_data7 = 0;

//==============================================================================
// Internal Wires
//==============================================================================

//------------------------------------------------------------------------------
// Read Pointers (one per tap, calculated from write pointer)
//------------------------------------------------------------------------------
// Subtraction wraps automatically in 10-bit address space (0-1023)
//
wire [ADDR_WIDTH-1:0] w_rdptr0 = r_wrptr - TAP0_OFFSET;   // 1 pixel back
wire [ADDR_WIDTH-1:0] w_rdptr1 = r_wrptr - TAP1_OFFSET;   // 128 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr2 = r_wrptr - TAP2_OFFSET;   // 256 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr3 = r_wrptr - TAP3_OFFSET;   // 384 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr4 = r_wrptr - TAP4_OFFSET;   // 512 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr5 = r_wrptr - TAP5_OFFSET;   // 640 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr6 = r_wrptr - TAP6_OFFSET;   // 768 pixels back
wire [ADDR_WIDTH-1:0] w_rdptr7 = r_wrptr - TAP7_OFFSET;   // 896 pixels back (oldest)

//==============================================================================
// Sequential Logic: Memory Write and Read
//==============================================================================
// Single always block handles:
// - Parallel write to all 8 BRAM instances
// - Parallel read from 8 different offsets
// - Write pointer increment
//
always @(posedge i_clk) begin
    //--------------------------------------------------------------------------
    // Write: Store input data to all 8 memories at current write position
    //--------------------------------------------------------------------------
    r_mem0[r_wrptr] <= i_shiftin;
    r_mem1[r_wrptr] <= i_shiftin;
    r_mem2[r_wrptr] <= i_shiftin;
    r_mem3[r_wrptr] <= i_shiftin;
    r_mem4[r_wrptr] <= i_shiftin;
    r_mem5[r_wrptr] <= i_shiftin;
    r_mem6[r_wrptr] <= i_shiftin;
    r_mem7[r_wrptr] <= i_shiftin;

    //--------------------------------------------------------------------------
    // Read: Fetch data from each memory at its respective tap offset
    //--------------------------------------------------------------------------
    r_tap_data0 <= r_mem0[w_rdptr0];
    r_tap_data1 <= r_mem1[w_rdptr1];
    r_tap_data2 <= r_mem2[w_rdptr2];
    r_tap_data3 <= r_mem3[w_rdptr3];
    r_tap_data4 <= r_mem4[w_rdptr4];
    r_tap_data5 <= r_mem5[w_rdptr5];
    r_tap_data6 <= r_mem6[w_rdptr6];
    r_tap_data7 <= r_mem7[w_rdptr7];

    //--------------------------------------------------------------------------
    // Increment write pointer (wraps automatically due to 10-bit width)
    //--------------------------------------------------------------------------
    r_wrptr <= r_wrptr + 1'b1;
end

//==============================================================================
// Output Assignments
//==============================================================================

//------------------------------------------------------------------------------
// Tap Bus: Concatenate all 8 tap values into 256-bit output
//------------------------------------------------------------------------------
// Format: o_taps[255:0] = {tap7, tap6, tap5, tap4, tap3, tap2, tap1, tap0}
//         where tap0 is newest (1 pixel back) and tap7 is oldest (896 pixels back)
//
assign o_taps[31:0]    = r_tap_data0;   // Tap 0: 1 pixel back (newest)
assign o_taps[63:32]   = r_tap_data1;   // Tap 1: 128 pixels back
assign o_taps[95:64]   = r_tap_data2;   // Tap 2: 256 pixels back
assign o_taps[127:96]  = r_tap_data3;   // Tap 3: 384 pixels back
assign o_taps[159:128] = r_tap_data4;   // Tap 4: 512 pixels back
assign o_taps[191:160] = r_tap_data5;   // Tap 5: 640 pixels back
assign o_taps[223:192] = r_tap_data6;   // Tap 6: 768 pixels back
assign o_taps[255:224] = r_tap_data7;   // Tap 7: 896 pixels back (oldest)

//------------------------------------------------------------------------------
// Shift Output: Oldest data from buffer (same as tap7)
//------------------------------------------------------------------------------
assign o_shiftout = r_tap_data7;

//------------------------------------------------------------------------------
// Debug: Write pointer position for monitoring buffer fill level
//------------------------------------------------------------------------------
assign o_dbg_wrptr = r_wrptr;

endmodule

`default_nettype wire
