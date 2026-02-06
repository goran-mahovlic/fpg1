//==============================================================================
// Module: pdp1_vga_crt
// Project: PDP-1 FPGA Port
// Description: VGA CRT emulation with phosphor decay for PDP-1 Type 30 display
//
// Author: REGOC Team (Kosjenka Babic - Architecture Review)
// Created: 2026-01-31
// Modified: 2026-02-02 - Best practices implementation
// Modified: 2026-02-03 - Team fix for CRT display bugs (ghost lines, coordinate wrap, phosphor decay)
//
// TASK-194: CRT phosphor decay emulation for PDP-1 vector display
// TASK-200: Adapted for 1024x768@50Hz
//
//------------------------------------------------------------------------------
// Architecture Overview:
//------------------------------------------------------------------------------
//
//  +------------------+     +-------------------+     +------------------+
//  | PDP-1 CPU        |---->| Input FIFO        |---->| Ring Buffer      |
//  | (pixel_x/y,      |     | (64 entry buffer) |     | "Hadron Collider"|
//  |  brightness)     |     | for incoming      |     | 4 buffers linked |
//  +------------------+     | pixels            |     | 1->2->3->4->1    |
//                           +-------------------+     +--------+---------+
//                                                              |
//                           +-------------------+              |
//                           | Row Buffer        |<-------------+
//                           | (8 lines ahead)   |    (pixels written when
//                           | 64 Kbit BRAM      |     within 8 lines of
//                           +--------+----------+     current scanline)
//                                    |
//                           +--------v----------+
//                           | Line Shift Regs   |
//                           | (3x 1024 pixels)  |
//                           | for 3x3 blur      |
//                           +--------+----------+
//                                    |
//                           +--------v----------+
//                           | Blur Kernel       |---->  VGA Output
//                           | 3x3 averaging     |       (RGB 8-bit)
//                           +-------------------+
//
//------------------------------------------------------------------------------
// Ring Buffer "Hadron Collider" Architecture:
//------------------------------------------------------------------------------
//
// Four pixel_ring_buffer instances connected in a circular chain.
// Each buffer stores 1024 pixels with 8 taps for parallel access.
//
//     +---------+     +---------+     +---------+     +---------+
//     | Ring 1  |---->| Ring 2  |---->| Ring 3  |---->| Ring 4  |---+
//     | (taps1) |     | (taps2) |     | (taps3) |     | (taps4) |   |
//     +----^----+     +---------+     +---------+     +---------+   |
//          |                                                        |
//          +--------------------------------------------------------+
//          (shiftout_4 -> dim -> shiftout_1)
//
// At each connection point, pixel luma is decremented (phosphor decay).
// Decay rate: luma - 1 every 8 passes (pass_counter[2:0] == 0)
//
//------------------------------------------------------------------------------
// Phosphor Decay Algorithm:
//------------------------------------------------------------------------------
//
// 1. New pixel enters with luma = 4095 (maximum brightness)
// 2. Every 8 vertical passes, luma decrements by 1
// 3. Special step-down: luma 3864-3936 -> 2576 (afterglow simulation)
// 4. Pixel removed when luma[11:4] == 0 (visible threshold)
//
// This simulates P7 phosphor characteristics of original Type 30 display.
//
//------------------------------------------------------------------------------
// Coordinate Transformation (PDP-1 Mode):
//------------------------------------------------------------------------------
//
// PDP-1 has origin in UPPER RIGHT corner with axes:
//   - X increases LEFT
//   - Y increases DOWN
//
// Transformation: { buffer_Y, buffer_X } = { ~pixel_x_i, pixel_y_i }
//   - ~pixel_x_i inverts X axis (1023->0, 0->1023)
//   - X/Y swap rotates coordinate system
//
//------------------------------------------------------------------------------
// Clock Domain: clk_pixel (51 MHz for 1024x768@50Hz)
//------------------------------------------------------------------------------
//
// Dependencies:
// - pdp1_vga_rowbuffer.v : 8-line lookahead buffer (64 Kbit BRAM)
// - line_shift_register.v : 1024-pixel delay lines for blur
// - pixel_ring_buffer.v : Circular buffer with 8 taps
//
//==============================================================================

`default_nettype none

module pdp1_vga_crt (
    //--------------------------------------------------------------------------
    // Clock and Reset
    //--------------------------------------------------------------------------
    input wire              i_clk,                  // Pixel clock (51 MHz for 1024x768@50Hz)
    input wire              i_rst_n,                // Active-low synchronous reset - Jelena

    //--------------------------------------------------------------------------
    // VGA Timing Inputs
    //--------------------------------------------------------------------------
    input wire [10:0]       i_h_counter,            // Horizontal position counter
    input wire [10:0]       i_v_counter,            // Vertical position counter

    //--------------------------------------------------------------------------
    // VGA RGB Outputs
    //--------------------------------------------------------------------------
    output reg [7:0]        o_red,                  // Red channel (8-bit)
    output reg [7:0]        o_green,                // Green channel (8-bit)
    output reg [7:0]        o_blue,                 // Blue channel (8-bit)

    //--------------------------------------------------------------------------
    // PDP-1 Pixel Input Interface
    //--------------------------------------------------------------------------
    input wire [9:0]        i_pixel_x,              // X coordinate from PDP-1 (0-1023)
    input wire [9:0]        i_pixel_y,              // Y coordinate from PDP-1 (0-1023)
    input wire [2:0]        i_pixel_brightness,     // Brightness level (0=max, 7=min)
    input wire              i_variable_brightness,  // Enable brightness-based pixel expansion
    input wire              i_pixel_valid,          // Strobe: pixel data valid

    //--------------------------------------------------------------------------
    // Debug Outputs
    //--------------------------------------------------------------------------
    output wire [5:0]       o_dbg_fifo_wr_ptr,      // Input FIFO write pointer
    output wire [5:0]       o_dbg_fifo_rd_ptr,      // Input FIFO read pointer
    output wire             o_dbg_pixel_strobe,     // Detected pixel strobe
    output wire [10:0]      o_dbg_search_counter,   // Search counter MSBs
    output wire [11:0]      o_dbg_luma1,            // Luma from ring buffer 1
    output wire             o_dbg_rowbuff_wren,     // Rowbuffer write enable
    output wire             o_dbg_inside_visible,   // Inside visible area flag
    output wire             o_dbg_pixel_to_rowbuff, // Pixel written to rowbuffer
    output wire [15:0]      o_dbg_rowbuff_count,    // Non-zero pixels per frame
    output wire [9:0]       o_dbg_ring_wrptr        // Ring buffer 1 write pointer
);

//==============================================================================
// Parameters
//==============================================================================

parameter DATA_WIDTH  = 32;             // Ring buffer entry width: 10-bit Y + 10-bit X + 12-bit luma
parameter BRIGHTNESS  = 8'd242;         // Blur kernel threshold (skip blur above this)

//==============================================================================
// Functions
//==============================================================================

// dim_pixel: Phosphor decay function
// Decrements luma value to simulate CRT phosphor fading.
// Special case: Luma in range 3864-3936 jumps to 2576 (afterglow step-down)
// This models the characteristic "two-phase" decay of P7 phosphor.
function automatic [11:0] dim_pixel;
    input [11:0] luma;
    begin
        if (luma > 12'd3864 && luma < 12'd3936)
            dim_pixel = 12'd2576;       // Afterglow step-down
        else
            dim_pixel = luma - 1'b1;    // Standard linear decay
    end
endfunction


//==============================================================================
// Tasks
//==============================================================================

// output_pixel: Convert intensity to RGB color
// High intensity (>=128): Blue-white phosphor glow
// Low intensity (<128): Green phosphor glow
// This simulates the color shift of P7 phosphor as it decays.
task output_pixel;
    input [7:0] intensity;
    begin
        // Default low-intensity output
        o_red   <= r_inside_visible ? {5'b0, intensity[7:5]} : 8'b0;
        o_green <= r_inside_visible ? intensity              : 8'b0;
        o_blue  <= r_inside_visible ? intensity[7]           : 8'b0;

        // High intensity override: shift toward blue-white
        if (intensity >= 8'h80) begin
            o_red   <= r_inside_visible ? intensity[7:6] : 8'b0;
            o_green <= r_inside_visible ? intensity      : 8'b0;
            o_blue  <= r_inside_visible ? intensity      : 8'b0;
        end
    end
endtask


//==============================================================================
// Internal Wires
//==============================================================================

// Row buffer read data
wire [7:0]   w_rowbuff_rdata;

// Line shift register outputs (for 3x3 blur kernel)
wire [7:0]   w_line1_out;               // p13: top-right of 3x3 kernel
wire [7:0]   w_line2_out;               // p23: middle-right of 3x3 kernel
wire [7:0]   w_line3_out;               // p33: bottom-right of 3x3 kernel

// Internal wires for kernel positions (directly from registers)
wire [7:0]   w_p21;                     // Middle-left of kernel
wire [7:0]   w_p31;                     // Bottom-left of kernel

// Ring buffer outputs (256-bit tap bus per buffer, 8 taps x 32 bits each)
wire [255:0] w_taps1, w_taps2, w_taps3, w_taps4;

// Ring buffer shift outputs (oldest entry from each buffer)
wire [31:0]  w_shiftout_1, w_shiftout_2, w_shiftout_3, w_shiftout_4;

// Current visible position on screen (after timing offsets)
wire [9:0]   w_current_x, w_current_y;

// PDP-1 Y coordinate (with CRT offset applied)
wire [9:0]   w_pdp1_y;

//==============================================================================
// Internal Registers
//==============================================================================

//------------------------------------------------------------------------------
// Row Buffer Control Registers
//------------------------------------------------------------------------------
reg [12:0]  r_rowbuff_rdaddr;           // Row buffer read address
reg [12:0]  r_rowbuff_wraddr;           // Row buffer write address
reg [7:0]   r_rowbuff_wdata;            // Row buffer write data
reg         r_rowbuff_wren;             // Row buffer write enable

//------------------------------------------------------------------------------
// 3x3 Blur Kernel Matrix Registers
//------------------------------------------------------------------------------
// Pixel positions in the kernel:
//   p11  p12  p13  <- from line1 shift register (2 lines back)
//   p21  p22  p23  <- from line2 shift register (1 line back)
//   p31  p32  p33  <- from line3 shift register (current line from rowbuffer)
//
reg [7:0]   r_p11, r_p12, r_p13;
reg [7:0]   r_p21, r_p22, r_p23;
reg [7:0]   r_p31, r_p32, r_p33;

//------------------------------------------------------------------------------
// Ring Buffer Connection Registers
//------------------------------------------------------------------------------
// These registers connect ring buffers in a circular chain.
// Data flows: ring1 -> shiftout_1 -> ring2 -> shiftout_2 -> ... -> ring1
reg [31:0]  r_shiftout_1, r_shiftout_2, r_shiftout_3, r_shiftout_4;

//------------------------------------------------------------------------------
// Ring Buffer Pixel Coordinates and Luma
//------------------------------------------------------------------------------
// Unpacked from ring buffer shift outputs: {Y[9:0], X[9:0], luma[11:0]}
reg [9:0]   r_pixel_1_x, r_pixel_1_y;
reg [9:0]   r_pixel_2_x, r_pixel_2_y;
reg [9:0]   r_pixel_3_x, r_pixel_3_y;
reg [9:0]   r_pixel_4_x, r_pixel_4_y;
reg [11:0]  r_luma_1, r_luma_2, r_luma_3, r_luma_4;

//------------------------------------------------------------------------------
// Timing and Control Registers
//------------------------------------------------------------------------------
reg [31:0]  r_pass_counter;              // Vertical refresh cycle counter - reset added by Jelena
reg [9:0]   r_erase_counter;            // Row buffer erase position
reg         r_pixel_found;              // Flag: pixel found for rowbuffer write

reg [31:0]  r_search_counter;           // Cycles since last ring buffer tap match

//------------------------------------------------------------------------------
// Input FIFO Buffer
//------------------------------------------------------------------------------
// 64-entry FIFO for incoming pixels awaiting ring buffer insertion
reg [9:0]   r_fifo_pixel_x [0:63];
reg [9:0]   r_fifo_pixel_y [0:63];
reg [5:0]   r_fifo_rd_ptr;              // FIFO read pointer
reg [5:0]   r_fifo_wr_ptr;              // FIFO write pointer
reg [9:0]   r_next_pixel_x;             // Next pixel X from FIFO (prefetched)
reg [9:0]   r_next_pixel_y;             // Next pixel Y from FIFO (prefetched)
reg [9:0]   r_next_pixel_x_d;           // BUG1 FIX: Registered for tap comparison
reg [9:0]   r_next_pixel_y_d;           // BUG1 FIX: Registered for tap comparison

//------------------------------------------------------------------------------
// Output Pixel Register
//------------------------------------------------------------------------------
reg [15:0]  r_pixel_out;                // Blurred pixel intensity for output

//------------------------------------------------------------------------------
// CDC Synchronization for Pixel Valid Signal
//------------------------------------------------------------------------------
(* ASYNC_REG = "TRUE" *) reg r_pixel_valid_meta;    // Metastability stage
(* ASYNC_REG = "TRUE" *) reg r_pixel_valid_sync;    // Synchronized stage
reg         r_pixel_valid_sync_d;       // Delayed sync for proper edge detection
reg         r_pixel_strobe;             // Detected falling edge (pixel ready)

//------------------------------------------------------------------------------
// Visibility Flag
//------------------------------------------------------------------------------
reg         r_inside_visible;           // Current position is in visible area

//------------------------------------------------------------------------------
// Loop Index (for generate-style loops in always blocks)
//------------------------------------------------------------------------------
integer i;

//==============================================================================
// Debug Signal Assignments
//==============================================================================

assign o_dbg_fifo_wr_ptr     = r_fifo_wr_ptr;
assign o_dbg_fifo_rd_ptr     = r_fifo_rd_ptr;
assign o_dbg_pixel_strobe    = r_pixel_strobe;
assign o_dbg_search_counter  = r_search_counter[31:21];  // MSBs indicate large values
assign o_dbg_luma1           = r_luma_1;
assign o_dbg_rowbuff_wren    = r_rowbuff_wren;
assign o_dbg_inside_visible  = r_inside_visible;
assign o_dbg_pixel_to_rowbuff = r_rowbuff_wren && (r_rowbuff_wdata != 8'd0);

// Debug: Verify coordinates in valid range (0-1023 for full PDP-1 display)
wire [9:0]  w_dbg_px = i_pixel_x;
wire [9:0]  w_dbg_py = i_pixel_y;
wire        w_dbg_coord_valid = (i_pixel_x < 10'd1024) && (i_pixel_y < 10'd1024);

//------------------------------------------------------------------------------
// Debug: Non-zero Pixel Counter (per frame)
//------------------------------------------------------------------------------
reg [15:0]  r_dbg_rowbuff_count;
reg [15:0]  r_dbg_rowbuff_count_latched;
reg [10:0]  r_dbg_prev_v_counter;

always @(posedge i_clk) begin
    r_dbg_prev_v_counter <= i_v_counter;

    // Detect frame start (v_counter wraps to 0)
    if (i_v_counter == 11'd0 && r_dbg_prev_v_counter != 11'd0) begin
        r_dbg_rowbuff_count_latched <= r_dbg_rowbuff_count;
        r_dbg_rowbuff_count <= 16'd0;
    end else if (r_rowbuff_wren && r_rowbuff_wdata != 8'd0) begin
        r_dbg_rowbuff_count <= r_dbg_rowbuff_count + 1'b1;
    end
end

assign o_dbg_rowbuff_count = r_dbg_rowbuff_count_latched;



//==============================================================================
// Continuous Assignments
//==============================================================================

// Wire kernel positions from registers (for line shift register inputs)
assign w_p21 = r_p21;
assign w_p31 = r_p31;

// Calculate current visible position from timing counters
// w_current_y: Vertical position within visible area (0 to 767)
// w_current_x: Horizontal position within visible area (0 to 1023)
assign w_current_y = (i_v_counter >= `v_visible_offset && i_v_counter < `v_visible_offset_end)
                   ? i_v_counter - `v_visible_offset
                   : 11'b0;

assign w_current_x = (i_h_counter >= `h_visible_offset + `h_center_offset &&
                      i_h_counter <  `h_visible_offset_end + `h_center_offset)
                   ? i_h_counter - (`h_visible_offset + `h_center_offset)
                   : 11'b0;

// PDP-1 Y coordinate with CRT offset applied
// This shifts the visible area within PDP-1 coordinate space
assign w_pdp1_y = w_current_y + `v_crt_offset;


//==============================================================================
// Module Instantiations
//==============================================================================

//------------------------------------------------------------------------------
// Row Buffer: 8-Line Lookahead Buffer
//------------------------------------------------------------------------------
// Stores the next 8 lines to be drawn. Pixels are written here from ring
// buffers when they are within 8 lines of the current scanline position.
// This allows time for the 3x3 blur kernel to process them.
//
pdp1_vga_rowbuffer u_rowbuffer (
    .clock      (i_clk),
    .data       (r_rowbuff_wdata),
    .wraddress  (r_rowbuff_wraddr),
    .wren       (r_rowbuff_wren),
    .rdaddress  (r_rowbuff_rdaddr),
    .q          (w_rowbuff_rdata)
);

//------------------------------------------------------------------------------
// Line Shift Registers: 3x3 Blur Kernel Delay Lines
//------------------------------------------------------------------------------
// Three 1024-pixel shift registers create the 3-line delay needed for
// the 3x3 blur kernel. Each line delay is one scanline (1024 pixels).
//
// Data flow:
//   rowbuffer -> line3 -> line2 -> line1
//              (p33)    (p23)    (p13)
//
line_shift_register u_line1 (
    .clock      (i_clk),
    .shiftin    (w_p21),
    .shiftout   (w_line1_out)
);

line_shift_register u_line2 (
    .clock      (i_clk),
    .shiftin    (w_p31),
    .shiftout   (w_line2_out)
);

line_shift_register u_line3 (
    .clock      (i_clk),
    .shiftin    (w_rowbuff_rdata),
    .shiftout   (w_line3_out)
);

//------------------------------------------------------------------------------
// Ring Buffers: "Hadron Collider" Circular Pixel Storage
//------------------------------------------------------------------------------
// Four ring buffers connected in a circular chain store active pixels.
// Each buffer has 1024 entries with 8 taps for parallel read access.
//
// Connection pattern:
//   ring1.shiftout -> process -> ring2.shiftin
//   ring2.shiftout -> process -> ring3.shiftin
//   ring3.shiftout -> process -> ring4.shiftin
//   ring4.shiftout -> process -> ring1.shiftin (completes the circle)
//
// At each connection, phosphor decay is applied to the luma value.
//
wire [9:0] w_ring1_wrptr;               // Debug: ring buffer 1 write pointer

pixel_ring_buffer u_ring_buffer_1 (
    .i_clk      (i_clk),
    .i_shiftin  (r_shiftout_1),
    .o_shiftout (w_shiftout_1),
    .o_taps     (w_taps1),
    .o_dbg_wrptr(w_ring1_wrptr)
);

pixel_ring_buffer u_ring_buffer_2 (
    .i_clk      (i_clk),
    .i_shiftin  (r_shiftout_2),
    .o_shiftout (w_shiftout_2),
    .o_taps     (w_taps2),
    .o_dbg_wrptr()                      // Unused debug output
);

pixel_ring_buffer u_ring_buffer_3 (
    .i_clk      (i_clk),
    .i_shiftin  (r_shiftout_3),
    .o_shiftout (w_shiftout_3),
    .o_taps     (w_taps3),
    .o_dbg_wrptr()
);

pixel_ring_buffer u_ring_buffer_4 (
    .i_clk      (i_clk),
    .i_shiftin  (r_shiftout_4),
    .o_shiftout (w_shiftout_4),
    .o_taps     (w_taps4),
    .o_dbg_wrptr()
);

// Debug: expose ring buffer 1 write pointer
assign o_dbg_ring_wrptr = w_ring1_wrptr;


//==============================================================================
// Always Block 1: Ring Buffer Management and Pixel Insertion
//==============================================================================
// This block handles:
// - FIFO prefetch of next pixel coordinates
// - Search counter for finding empty ring buffer slots
// - Unpacking ring buffer shift outputs to coordinate/luma registers
// - Pixel insertion into ring buffers (new or refresh existing)
// - Phosphor decay application at ring buffer connection points
//
always @(posedge i_clk) begin
    //--------------------------------------------------------------------------
    // Prefetch next pixel from input FIFO
    //--------------------------------------------------------------------------
    r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr];
    r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr];

    // BUG1 FIX: Register prefetched values for stable tap comparison
    // This eliminates timing hazard where comparison uses value before it's settled
    r_next_pixel_x_d <= r_next_pixel_x;
    r_next_pixel_y_d <= r_next_pixel_y;

    //--------------------------------------------------------------------------
    // Increment search counter (reset when pixel found in ring buffer)
    //--------------------------------------------------------------------------
    r_search_counter <= r_search_counter + 1'b1;

    //--------------------------------------------------------------------------
    // Unpack ring buffer shift outputs to coordinate and luma registers
    // Format: {Y[9:0], X[9:0], luma[11:0]} = 32 bits
    //--------------------------------------------------------------------------
    {r_pixel_1_y, r_pixel_1_x, r_luma_1} <= w_shiftout_1;
    {r_pixel_2_y, r_pixel_2_x, r_luma_2} <= w_shiftout_2;
    {r_pixel_3_y, r_pixel_3_x, r_luma_3} <= w_shiftout_3;
    {r_pixel_4_y, r_pixel_4_x, r_luma_4} <= w_shiftout_4;

    //--------------------------------------------------------------------------
    // Handle incoming pixel (on strobe)
    //--------------------------------------------------------------------------
    if (r_pixel_strobe) begin
        // =======================================================================
        // COORDINATE TRANSFORMATION - depends on operating mode
        // =======================================================================
        // TEST_ANIMATION: Direct coordinates (X, Y) - no transformation
        // PDP-1 MODE: Origin in UPPER RIGHT corner
        //   ~i_pixel_x inverts X axis (0->1023, 1023->0)
        //   X/Y swap rotates coordinate system
        //   Result: { buffer_Y, buffer_X } = { ~X, Y }

`ifdef TEST_ANIMATION
        // TEST_ANIMATION: Use coordinates directly without transformation
        // BRIGHTNESS FIX: All except brightness=7 get 5x pixels
        if (i_variable_brightness && i_pixel_brightness != 3'b111) begin
            {r_fifo_pixel_y[r_fifo_wr_ptr], r_fifo_pixel_x[r_fifo_wr_ptr]} <= {i_pixel_y, i_pixel_x};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd1], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd1]} <= {i_pixel_y + 1'b1, i_pixel_x};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd2], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd2]} <= {i_pixel_y, i_pixel_x + 1'b1};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd3], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd3]} <= {i_pixel_y - 1'b1, i_pixel_x};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd4], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd4]} <= {i_pixel_y, i_pixel_x - 1'b1};
            r_fifo_wr_ptr <= r_fifo_wr_ptr + 3'd5;
        end else begin
            {r_fifo_pixel_y[r_fifo_wr_ptr], r_fifo_pixel_x[r_fifo_wr_ptr]} <= {i_pixel_y, i_pixel_x};
            r_fifo_wr_ptr <= r_fifo_wr_ptr + 1'b1;
        end
`else
        // PDP-1 MODE: X/Y swap + X inversion for full 1024x1024 display
        // Coordinates from CPU are 0-1023 (as original)
        // 1) X inversion: ~i_pixel_x = 1023 - i_pixel_x (10-bit inversion)
        // 2) X/Y swap: inverted X goes to Y buffer, Y goes to X buffer
        //
        // BRIGHTNESS FIX: All except brightness=7 (minimum) get 5x pixels
        if (i_variable_brightness && i_pixel_brightness != 3'b111) begin
            {r_fifo_pixel_y[r_fifo_wr_ptr], r_fifo_pixel_x[r_fifo_wr_ptr]} <= {~i_pixel_x, i_pixel_y};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd1], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd1]} <= {~i_pixel_x + 1'b1, i_pixel_y};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd2], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd2]} <= {~i_pixel_x, i_pixel_y + 1'b1};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd3], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd3]} <= {~i_pixel_x - 1'b1, i_pixel_y};
            {r_fifo_pixel_y[r_fifo_wr_ptr + 3'd4], r_fifo_pixel_x[r_fifo_wr_ptr + 3'd4]} <= {~i_pixel_x, i_pixel_y - 1'b1};
            r_fifo_wr_ptr <= r_fifo_wr_ptr + 3'd5;
        end else begin
            {r_fifo_pixel_y[r_fifo_wr_ptr], r_fifo_pixel_x[r_fifo_wr_ptr]} <= {~i_pixel_x, i_pixel_y};
            r_fifo_wr_ptr <= r_fifo_wr_ptr + 1'b1;
        end
`endif

        // Reset search counter when FIFO was empty
        if (r_fifo_wr_ptr == r_fifo_rd_ptr)
            r_search_counter <= 0;
    end

    //--------------------------------------------------------------------------
    // Ring Buffer Processing: Phosphor Decay and Pixel Insertion
    //--------------------------------------------------------------------------
    begin
        //----------------------------------------------------------------------
        // Apply phosphor decay at ring buffer connection points
        // TEAM FIX (Kosjenka): Restored ORIGINAL decay rate [2:0] (every 8 passes)
        // [3:0] made pixels last 60% longer at 50Hz vs 60Hz, causing ghosts
        // Pixels with luma[11:4] == 0 are considered "dead" and cleared
        //----------------------------------------------------------------------
        r_shiftout_1 <= r_luma_4[11:4] ? {r_pixel_4_y, r_pixel_4_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_4) : r_luma_4} : 32'd0;
        r_shiftout_2 <= r_luma_1[11:4] ? {r_pixel_1_y, r_pixel_1_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_1) : r_luma_1} : 32'd0;
        r_shiftout_3 <= r_luma_2[11:4] ? {r_pixel_2_y, r_pixel_2_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_2) : r_luma_2} : 32'd0;
        r_shiftout_4 <= r_luma_3[11:4] ? {r_pixel_3_y, r_pixel_3_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_3) : r_luma_3} : 32'd0;

        //----------------------------------------------------------------------
        // New Pixel Insertion: Find empty slot after search timeout
        //----------------------------------------------------------------------
        // TEAM FIX (Dora): Aligned search threshold with TAP7_OFFSET (896)
        // Original was 1024, but tap coverage only spans 896 positions
        // Using 1024 ensures we check slightly beyond tap range
        //
        // TEAM FIX (Jelena): Use REGISTERED values consistently for all comparisons
        if (r_fifo_wr_ptr != r_fifo_rd_ptr && r_search_counter > 1024 &&
            (!r_luma_1[11:4] || !r_luma_2[11:4] || !r_luma_3[11:4] || !r_luma_4[11:4])) begin

            if (r_luma_4[11:4] == 0)
                r_shiftout_1 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_luma_1[11:4] == 0)
                r_shiftout_2 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_luma_2[11:4] == 0)
                r_shiftout_3 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_luma_3[11:4] == 0)
                r_shiftout_4 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};

            // Advance FIFO read pointer
            r_fifo_rd_ptr <= r_fifo_rd_ptr + 1'b1;
            r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr + 1'b1];
            r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr + 1'b1];
            r_search_counter <= 0;
        end

        //----------------------------------------------------------------------
        // Existing Pixel Refresh: Update luma if pixel found in shift outputs
        // TEAM FIX (Jelena): Use REGISTERED values for consistent comparison
        //----------------------------------------------------------------------
        else if (r_fifo_wr_ptr != r_fifo_rd_ptr &&
                 ((r_pixel_1_x == r_next_pixel_x_d && r_pixel_1_y == r_next_pixel_y_d) ||
                  (r_pixel_2_x == r_next_pixel_x_d && r_pixel_2_y == r_next_pixel_y_d) ||
                  (r_pixel_3_x == r_next_pixel_x_d && r_pixel_3_y == r_next_pixel_y_d) ||
                  (r_pixel_4_x == r_next_pixel_x_d && r_pixel_4_y == r_next_pixel_y_d))) begin

            if (r_pixel_1_x == r_next_pixel_x_d && r_pixel_1_y == r_next_pixel_y_d)
                r_shiftout_2 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_pixel_2_x == r_next_pixel_x_d && r_pixel_2_y == r_next_pixel_y_d)
                r_shiftout_3 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_pixel_3_x == r_next_pixel_x_d && r_pixel_3_y == r_next_pixel_y_d)
                r_shiftout_4 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};
            else if (r_pixel_4_x == r_next_pixel_x_d && r_pixel_4_y == r_next_pixel_y_d)
                r_shiftout_1 <= {r_next_pixel_y_d, r_next_pixel_x_d, 12'd4095};

            // Advance FIFO read pointer
            r_fifo_rd_ptr <= r_fifo_rd_ptr + 1'b1;
            r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr + 1'b1];
            r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr + 1'b1];
            r_search_counter <= 0;
        end

        //----------------------------------------------------------------------
        // Tap Search: Reset search counter if pixel found in any ring buffer tap
        // BUG1 FIX: Use registered values (r_next_pixel_x_d/y_d) for stable comparison
        //----------------------------------------------------------------------
        else begin
            for (i = 8; i > 0; i = i - 1'b1) begin
                if ((w_taps1[i*DATA_WIDTH-1 -: 10] == r_next_pixel_y_d && w_taps1[i*DATA_WIDTH-11 -: 10] == r_next_pixel_x_d && w_taps1[i*DATA_WIDTH-21 -: 8]) ||
                    (w_taps2[i*DATA_WIDTH-1 -: 10] == r_next_pixel_y_d && w_taps2[i*DATA_WIDTH-11 -: 10] == r_next_pixel_x_d && w_taps2[i*DATA_WIDTH-21 -: 8]) ||
                    (w_taps3[i*DATA_WIDTH-1 -: 10] == r_next_pixel_y_d && w_taps3[i*DATA_WIDTH-11 -: 10] == r_next_pixel_x_d && w_taps3[i*DATA_WIDTH-21 -: 8]) ||
                    (w_taps4[i*DATA_WIDTH-1 -: 10] == r_next_pixel_y_d && w_taps4[i*DATA_WIDTH-11 -: 10] == r_next_pixel_x_d && w_taps4[i*DATA_WIDTH-21 -: 8]))
                    r_search_counter <= 0;
            end
        end
    end
end

//==============================================================================
// Always Block 2: Row Buffer Read/Write and Blur Kernel Processing
//==============================================================================
// This block handles:
// - Row buffer read address generation
// - 3x3 blur kernel shift register updates
// - Blur kernel convolution calculation
// - VGA pixel output
// - Ring buffer to row buffer pixel transfer
// - Row buffer line erasure
//
always @(posedge i_clk) begin
    //--------------------------------------------------------------------------
    // Row Buffer Read: Generate address for current pixel position
    //--------------------------------------------------------------------------
    // Address format: {line[2:0], x[9:0]} - 8 lines x 1024 pixels
    r_rowbuff_rdaddr <= {w_current_y[2:0], w_current_x};
    r_rowbuff_wren   <= 1'b1;

    //--------------------------------------------------------------------------
    // 3x3 Blur Kernel Shift Register Update
    //--------------------------------------------------------------------------
    // Shift pixel values through the 3x3 matrix:
    //   p11 <- p12 <- p13 <- line1_out (oldest line)
    //   p21 <- p22 <- p23 <- line2_out
    //   p31 <- p32 <- p33 <- line3_out <- rowbuffer (newest line)
    //
    r_p11 <= r_p12; r_p12 <= r_p13; r_p13 <= w_line1_out;
    r_p21 <= r_p22; r_p22 <= r_p23; r_p23 <= w_line2_out;
    r_p31 <= r_p32; r_p32 <= r_p33; r_p33 <= w_line3_out;

    //--------------------------------------------------------------------------
    // Blur Kernel Convolution
    //--------------------------------------------------------------------------
    // Apply 3x3 averaging blur when center pixel below threshold.
    // Uses divide-by-8 (shift right 3) instead of divide-by-9 for efficiency.
    // Corner pixels (p11, p33) weighted at 0.5 to prevent overflow.
    //
    if (r_p22 < BRIGHTNESS) begin
        r_pixel_out <= ({8'b0, r_p11[7:1]} + r_p12 + r_p13 +
                        r_p21 + r_p22 + r_p23 +
                        r_p31 + r_p32 + r_p33[7:1]) >> 3;
        r_p21 <= r_pixel_out;           // Feedback for smoother decay
    end else begin
        r_pixel_out <= r_p22;           // No blur for bright pixels
    end

    //--------------------------------------------------------------------------
    // VGA Output: Convert intensity to RGB
    //--------------------------------------------------------------------------
    output_pixel(r_pixel_out);

    //--------------------------------------------------------------------------
    // Row Buffer Write: Transfer pixels from ring buffer taps
    //--------------------------------------------------------------------------
    // FIX 2026-02-04 (Emard): Pixel write has priority over erase
    // Previous fix incorrectly gave erase priority, blocking pixel writes
    //
    r_pixel_found = 1'b0;

    // FIX 2026-02-04: PIXEL WRITE HAS PRIORITY (erase was blocking pixels)
    for (i = 8; i > 0; i = i - 1'b1) begin
            // Check taps1
            if (!r_pixel_found &&
                w_taps1[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                w_taps1[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 10'd8 &&
                w_taps1[i*DATA_WIDTH-21 -: 8] > 0) begin
                // FIX #2: Use RELATIVE Y position (tap_y - w_pdp1_y)[2:0]
                r_rowbuff_wraddr <= {(w_taps1[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                                      w_taps1[i*DATA_WIDTH-11 -: 10]};
                r_rowbuff_wdata  <= w_taps1[i*DATA_WIDTH-21 -: 8];
                r_pixel_found = 1'b1;
            end
            // Check taps2
            else if (!r_pixel_found &&
                     w_taps2[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps2[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 10'd8 &&
                     w_taps2[i*DATA_WIDTH-21 -: 8] > 0) begin
                r_rowbuff_wraddr <= {(w_taps2[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                                      w_taps2[i*DATA_WIDTH-11 -: 10]};
                r_rowbuff_wdata  <= w_taps2[i*DATA_WIDTH-21 -: 8];
                r_pixel_found = 1'b1;
            end
            // Check taps3
            else if (!r_pixel_found &&
                     w_taps3[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps3[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 10'd8 &&
                     w_taps3[i*DATA_WIDTH-21 -: 8] > 0) begin
                r_rowbuff_wraddr <= {(w_taps3[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                                      w_taps3[i*DATA_WIDTH-11 -: 10]};
                r_rowbuff_wdata  <= w_taps3[i*DATA_WIDTH-21 -: 8];
                r_pixel_found = 1'b1;
            end
            // Check taps4
            else if (!r_pixel_found &&
                     w_taps4[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps4[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 10'd8 &&
                     w_taps4[i*DATA_WIDTH-21 -: 8] > 0) begin
                r_rowbuff_wraddr <= {(w_taps4[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                                      w_taps4[i*DATA_WIDTH-11 -: 10]};
                r_rowbuff_wdata  <= w_taps4[i*DATA_WIDTH-21 -: 8];
                r_pixel_found = 1'b1;
            end
    end

    // Erase ONLY if no pixel was written (pixel write has priority)
    if (!r_pixel_found && r_erase_counter < w_current_x) begin
        r_rowbuff_wraddr <= {w_current_y[2:0], r_erase_counter};
        r_rowbuff_wdata  <= 8'd0;
        r_erase_counter  <= r_erase_counter + 1'b1;
    end

    //--------------------------------------------------------------------------
    // Reset erase counter at end of line
    //--------------------------------------------------------------------------
    if (i_h_counter == `h_line_timing - 1)
        r_erase_counter <= 10'd0;
end


//==============================================================================
// Always Block 3: Timing Control and Pixel Valid Edge Detection
//==============================================================================
// This block handles:
// - Visible area flag generation
// - Pass counter for phosphor decay timing
// - CDC synchronization of pixel valid signal
// - Falling edge detection for pixel strobe
//
always @(posedge i_clk) begin
    if (!i_rst_n) begin
        //----------------------------------------------------------------------
        // Reset logic added by Jelena for proper r_pass_counter initialization
        //----------------------------------------------------------------------
        r_inside_visible     <= 1'b0;
        r_pass_counter       <= 32'd1;
        r_pixel_valid_meta   <= 1'b0;
        r_pixel_valid_sync   <= 1'b0;
        r_pixel_valid_sync_d <= 1'b0;
        r_pixel_strobe       <= 1'b0;
    end else begin
        //----------------------------------------------------------------------
        // Visible Area Flag
        //----------------------------------------------------------------------
        r_inside_visible <= (i_h_counter >= `h_visible_offset + `h_center_offset &&
                             i_h_counter <  `h_visible_offset_end + `h_center_offset);

        //----------------------------------------------------------------------
        // Pass Counter: Increments at end of each scanline
        //----------------------------------------------------------------------
        // Used to slow down phosphor decay (decay applied every 8 passes)
        if (i_h_counter == `h_line_timing - 1)
            r_pass_counter <= r_pass_counter + 1'b1;

        //----------------------------------------------------------------------
        // CDC Synchronization for Pixel Valid Signal
        //----------------------------------------------------------------------
        // Two-stage synchronizer to handle asynchronous pixel_valid from PDP-1
        // ASYNC_REG attribute ensures proper placement for metastability handling
        r_pixel_valid_meta <= i_pixel_valid;
        r_pixel_valid_sync <= r_pixel_valid_meta;

        //----------------------------------------------------------------------
        // Falling Edge Detection: Generate strobe when pixel data is ready
        //----------------------------------------------------------------------
        // CDC FIX: Use delayed sync signal for edge detection, NOT metastable!
        // Old (WRONG): r_pixel_valid_sync & ~r_pixel_valid_meta (compares with metastable)
        // New (CORRECT): r_pixel_valid_sync & ~r_pixel_valid_sync_d (both are stable)
        r_pixel_valid_sync_d <= r_pixel_valid_sync;
        r_pixel_strobe <= r_pixel_valid_sync & ~r_pixel_valid_sync_d;
    end
end

endmodule

`default_nettype wire
