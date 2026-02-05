//==============================================================================
// Module: pdp1_vga_crt
// Project: PDP-1 FPGA Port
// Description: VGA CRT emulation with phosphor decay for PDP-1 Type 30 display
//
// Author: REGOC Team (Kosjenka Babic - Architecture Review)
// Created: 2026-01-31
// Modified: 2026-02-02 - Best practices implementation
// Modified: 2026-02-03 - Team fix for CRT display bugs (ghost lines, coordinate wrap, phosphor decay)
// Modified: 2026-02-05 - Jelena fix: Simplified unified erase logic to fix jitter
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
    // Clock
    //--------------------------------------------------------------------------
    input wire              i_clk,                  // Pixel clock (51 MHz for 1024x768@50Hz)

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
wire [10:0]  w_current_x, w_current_y;

// PDP-1 Y coordinate (with CRT offset applied)
wire [10:0]  w_pdp1_y;

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
reg [7:0]   r_p11, r_p12, r_p13;
reg [7:0]   r_p21, r_p22, r_p23;
reg [7:0]   r_p31, r_p32, r_p33;

//------------------------------------------------------------------------------
// Ring Buffer Connection Registers
//------------------------------------------------------------------------------
reg [31:0]  r_shiftout_1, r_shiftout_2, r_shiftout_3, r_shiftout_4;

//------------------------------------------------------------------------------
// Ring Buffer Pixel Coordinates and Luma
//------------------------------------------------------------------------------
reg [9:0]   r_pixel_1_x, r_pixel_1_y;
reg [9:0]   r_pixel_2_x, r_pixel_2_y;
reg [9:0]   r_pixel_3_x, r_pixel_3_y;
reg [9:0]   r_pixel_4_x, r_pixel_4_y;
reg [11:0]  r_luma_1, r_luma_2, r_luma_3, r_luma_4;

//------------------------------------------------------------------------------
// Timing and Control Registers
//------------------------------------------------------------------------------
reg [31:0]  r_pass_counter = 32'd1;     // Vertical refresh cycle counter

reg [31:0]  r_search_counter;           // Cycles since last ring buffer tap match

//------------------------------------------------------------------------------
// Input FIFO Buffer
//------------------------------------------------------------------------------
reg [9:0]   r_fifo_pixel_x [0:63];
reg [9:0]   r_fifo_pixel_y [0:63];
reg [5:0]   r_fifo_rd_ptr;              // FIFO read pointer
reg [5:0]   r_fifo_wr_ptr;              // FIFO write pointer
reg [9:0]   r_next_pixel_x;             // Next pixel X from FIFO (prefetched)
reg [9:0]   r_next_pixel_y;             // Next pixel Y from FIFO (prefetched)
reg [9:0]   r_next_pixel_x_d;           // Registered for tap comparison
reg [9:0]   r_next_pixel_y_d;           // Registered for tap comparison

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
assign o_dbg_search_counter  = r_search_counter[31:21];
assign o_dbg_luma1           = r_luma_1;
assign o_dbg_rowbuff_wren    = r_rowbuff_wren;
assign o_dbg_inside_visible  = r_inside_visible;
assign o_dbg_pixel_to_rowbuff = r_rowbuff_wren && (r_rowbuff_wdata != 8'd0);

//------------------------------------------------------------------------------
// Debug: Non-zero Pixel Counter (per frame)
//------------------------------------------------------------------------------
reg [15:0]  r_dbg_rowbuff_count;
reg [15:0]  r_dbg_rowbuff_count_latched;
reg [10:0]  r_dbg_prev_v_counter;

always @(posedge i_clk) begin
    r_dbg_prev_v_counter <= i_v_counter;
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

assign w_p21 = r_p21;
assign w_p31 = r_p31;

assign w_current_y = (i_v_counter >= `v_visible_offset && i_v_counter < `v_visible_offset_end)
                   ? i_v_counter - `v_visible_offset
                   : 11'b0;

assign w_current_x = (i_h_counter >= `h_visible_offset + `h_center_offset &&
                      i_h_counter <  `h_visible_offset_end + `h_center_offset)
                   ? i_h_counter - (`h_visible_offset + `h_center_offset)
                   : 11'b0;

assign w_pdp1_y = w_current_y + `v_crt_offset;


//==============================================================================
// Module Instantiations
//==============================================================================

pdp1_vga_rowbuffer u_rowbuffer (
    .clock      (i_clk),
    .data       (r_rowbuff_wdata),
    .wraddress  (r_rowbuff_wraddr),
    .wren       (r_rowbuff_wren),
    .rdaddress  (r_rowbuff_rdaddr),
    .q          (w_rowbuff_rdata)
);

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

wire [9:0] w_ring1_wrptr;

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
    .o_dbg_wrptr()
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

assign o_dbg_ring_wrptr = w_ring1_wrptr;


//==============================================================================
// Always Block 1: Ring Buffer Management and Pixel Insertion
//==============================================================================
always @(posedge i_clk) begin
    r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr];
    r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr];

    r_next_pixel_x_d <= r_next_pixel_x;
    r_next_pixel_y_d <= r_next_pixel_y;

    r_search_counter <= r_search_counter + 1'b1;

    {r_pixel_1_y, r_pixel_1_x, r_luma_1} <= w_shiftout_1;
    {r_pixel_2_y, r_pixel_2_x, r_luma_2} <= w_shiftout_2;
    {r_pixel_3_y, r_pixel_3_x, r_luma_3} <= w_shiftout_3;
    {r_pixel_4_y, r_pixel_4_x, r_luma_4} <= w_shiftout_4;

    if (r_pixel_strobe) begin
`ifdef TEST_ANIMATION
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

        if (r_fifo_wr_ptr == r_fifo_rd_ptr)
            r_search_counter <= 0;
    end

    begin
        r_shiftout_1 <= r_luma_4[11:4] ? {r_pixel_4_y, r_pixel_4_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_4) : r_luma_4} : 32'd0;
        r_shiftout_2 <= r_luma_1[11:4] ? {r_pixel_1_y, r_pixel_1_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_1) : r_luma_1} : 32'd0;
        r_shiftout_3 <= r_luma_2[11:4] ? {r_pixel_2_y, r_pixel_2_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_2) : r_luma_2} : 32'd0;
        r_shiftout_4 <= r_luma_3[11:4] ? {r_pixel_3_y, r_pixel_3_x, r_pass_counter[2:0] == 3'b0 ? dim_pixel(r_luma_3) : r_luma_3} : 32'd0;

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

            r_fifo_rd_ptr <= r_fifo_rd_ptr + 1'b1;
            r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr + 1'b1];
            r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr + 1'b1];
            r_search_counter <= 0;
        end
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

            r_fifo_rd_ptr <= r_fifo_rd_ptr + 1'b1;
            r_next_pixel_x <= r_fifo_pixel_x[r_fifo_rd_ptr + 1'b1];
            r_next_pixel_y <= r_fifo_pixel_y[r_fifo_rd_ptr + 1'b1];
            r_search_counter <= 0;
        end
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
// Temporary variables for search (local to always block)
reg [12:0] v_wraddr;
reg [7:0]  v_wdata;
reg        v_pixel_found;

always @(posedge i_clk) begin
    r_rowbuff_rdaddr <= {w_current_y[2:0], w_current_x[9:0]};
    r_rowbuff_wren   <= 1'b1; 

    r_p11 <= r_p12; r_p12 <= r_p13; r_p13 <= w_line1_out;
    r_p21 <= r_p22; r_p22 <= r_p23; r_p23 <= w_line2_out;
    r_p31 <= r_p32; r_p32 <= r_p33; r_p33 <= w_line3_out;

    if (r_p22 < BRIGHTNESS) begin
        r_pixel_out <= ({8'b0, r_p11[7:1]} + r_p12 + r_p13 +
                        r_p21 + r_p22 + r_p23 +
                        r_p31 + r_p32 + r_p33[7:1]) >> 3;
        r_p21 <= r_pixel_out;
    end else begin
        r_pixel_out <= r_p22;
    end

    output_pixel(r_pixel_out);

    // FIX 2026-02-05 (Jelena): Unified search and erase to fix jitter.
    v_pixel_found = 1'b0;
    v_wraddr = {w_current_y[2:0], w_current_x[9:0]}; 
    v_wdata  = 8'd0;

    for (i = 8; i > 0; i = i - 1'b1) begin
            if (!v_pixel_found &&
                w_taps1[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                w_taps1[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 11'd8 &&
                w_taps1[i*DATA_WIDTH-21 -: 8] > 0) begin
                v_wraddr = {(w_taps1[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                             w_taps1[i*DATA_WIDTH-11 -: 10]};
                v_wdata  = w_taps1[i*DATA_WIDTH-21 -: 8];
                v_pixel_found = 1'b1;
            end
            else if (!v_pixel_found &&
                     w_taps2[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps2[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 11'd8 &&
                     w_taps2[i*DATA_WIDTH-21 -: 8] > 0) begin
                v_wraddr = {(w_taps2[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                             w_taps2[i*DATA_WIDTH-11 -: 10]};
                v_wdata  = w_taps2[i*DATA_WIDTH-21 -: 8];
                v_pixel_found = 1'b1;
            end
            else if (!v_pixel_found &&
                     w_taps3[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps3[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 11'd8 &&
                     w_taps3[i*DATA_WIDTH-21 -: 8] > 0) begin
                v_wraddr = {(w_taps3[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                             w_taps3[i*DATA_WIDTH-11 -: 10]};
                v_wdata  = w_taps3[i*DATA_WIDTH-21 -: 8];
                v_pixel_found = 1'b1;
            end
            else if (!v_pixel_found &&
                     w_taps4[i*DATA_WIDTH-1 -: 10] >= w_pdp1_y &&
                     w_taps4[i*DATA_WIDTH-1 -: 10] < w_pdp1_y + 11'd8 &&
                     w_taps4[i*DATA_WIDTH-21 -: 8] > 0) begin
                v_wraddr = {(w_taps4[i*DATA_WIDTH-1 -: 10] - w_pdp1_y),
                             w_taps4[i*DATA_WIDTH-11 -: 10]};
                v_wdata  = w_taps4[i*DATA_WIDTH-21 -: 8];
                v_pixel_found = 1'b1;
            end
    end
    
    r_rowbuff_wraddr <= v_wraddr;
    r_rowbuff_wdata  <= v_wdata;
end


//==============================================================================
// Always Block 3: Timing Control and Pixel Valid Edge Detection
//==============================================================================
always @(posedge i_clk) begin
    r_inside_visible <= (i_h_counter >= `h_visible_offset + `h_center_offset &&
                         i_h_counter <  `h_visible_offset_end + `h_center_offset);

    if (i_h_counter == `h_line_timing - 1)
        r_pass_counter <= r_pass_counter + 1'b1;

    r_pixel_valid_meta <= i_pixel_valid;
    r_pixel_valid_sync <= r_pixel_valid_meta;

    r_pixel_valid_sync_d <= r_pixel_valid_sync;
    r_pixel_strobe <= r_pixel_valid_sync & ~r_pixel_valid_sync_d;
end

endmodule

`default_nettype wire
