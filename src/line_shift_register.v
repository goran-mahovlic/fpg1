// line_shift_register.v
// BRAM-based circular buffer shift register for CRT phosphor blur
// TASK-191: Implements delayed tap at distance 800
// TASK-XXX: Updated to 1264 for 1024x768@50Hz (Jelena Horvat)
// Author: Jelena Horvat (REGOC team)
// HDL Best Practices Audit: Kosjenka/REGOC team
//
// This module replaces Altera's altshift_taps megafunction with
// a portable BRAM-inferred circular buffer for ECP5/Yosys synthesis.
//
// Tap distance 1264 + 3 external registers = 1267 total delay
// (matches 1024x768@50Hz row timing, h_line_timing = 1264)

module line_shift_register
(
    input wire clock,
    input wire [7:0] shiftin,
    output wire [7:0] shiftout,
    output wire [7:0] taps
);

    // Parameters
    // TAP_DISTANCE = h_line_timing - 1 for BRAM read latency = exactly one VGA line
    // For 1024x768@50Hz: h_line_timing = 1264, so TAP_DISTANCE = 1263
    localparam TAP_DISTANCE = 1263;  // 1264 - 1 for BRAM read latency
    localparam ADDR_WIDTH = 11;          // 2^11 = 2048 > 1264 (increased from 10 to 11!)
    localparam MEM_DEPTH = 1 << ADDR_WIDTH;

    // Distributed RAM inference - uses LUTs instead of BRAM for better timing
    // TASK-OPT: Changed from "block" to "distributed" for timing improvement
    (* ram_style = "distributed" *)
    reg [7:0] mem [0:MEM_DEPTH-1];

    // Initialize to 0 to prevent garbage on power-up
    integer init_i;
    initial begin
        for (init_i = 0; init_i < MEM_DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 8'd0;
        end
    end

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
