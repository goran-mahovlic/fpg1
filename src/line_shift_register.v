// line_shift_register.v
// BRAM-based circular buffer shift register for CRT phosphor blur
// TASK-191: Implements delayed tap at distance 800
// Author: Jelena Horvat (REGOC tim)
//
// This module replaces Altera's altshift_taps megafunction with
// a portable BRAM-inferred circular buffer for ECP5/Yosys synthesis.
//
// Tap distance 800 + 3 external registers = 803 total delay
// (matches 640x480@60Hz row timing)

module line_shift_register
(
    input wire clock,
    input wire [7:0] shiftin,
    output wire [7:0] shiftout,
    output wire [7:0] taps
);

    // Parameters
    localparam TAP_DISTANCE = 800;
    localparam ADDR_WIDTH = 10;          // 2^10 = 1024 > 800
    localparam MEM_DEPTH = 1 << ADDR_WIDTH;

    // BRAM inference - registered outputs for proper BRAM mapping
    // Using (* ram_style = "block" *) attribute for Yosys/ECP5
    (* ram_style = "block" *)
    reg [7:0] mem [0:MEM_DEPTH-1];

    // Write pointer (circular)
    reg [ADDR_WIDTH-1:0] wrptr = 0;

    // Read pointer: wrptr - TAP_DISTANCE (handles wrap automatically with modular arithmetic)
    wire [ADDR_WIDTH-1:0] rdptr = wrptr - TAP_DISTANCE[ADDR_WIDTH-1:0];

    // Output register for BRAM read (synchronous read)
    reg [7:0] rd_data = 8'b0;

    // Write process - write-first semantics
    // BRAM inference pattern: synchronous write
    always @(posedge clock) begin
        mem[wrptr] <= shiftin;
        wrptr <= wrptr + 1'b1;
    end

    // Read process - synchronous read for proper BRAM inference
    // Read from previous cycle's read address for correct delay
    always @(posedge clock) begin
        rd_data <= mem[rdptr];
    end

    // Output assignments
    // shiftout and taps are the same for single-tap configuration
    assign shiftout = rd_data;
    assign taps = rd_data;

endmodule
