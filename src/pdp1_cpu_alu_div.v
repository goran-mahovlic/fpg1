/*
 * Behavioral Unsigned Divider for PDP-1 CPU
 *
 * PDP-1 DIV instruction divides 34-bit dividend (AC:IO) by 17-bit divisor
 * producing 34-bit quotient and 17-bit remainder.
 *
 * This is a simple combinational implementation using Verilog / and % operators.
 * Synthesizes to LUTs on any FPGA (no vendor-specific IP needed).
 *
 * Original Altera version used lpm_divide with 34-stage pipeline.
 * This behavioral version is combinational - slower but simpler.
 *
 * For PDP-1, DIV is a rare instruction so performance is not critical.
 *
 * Author: Potjeh Sabolic, REGOC team
 * Task: TASK-189 Divider Implementation
 */

module pdp1_cpu_alu_div (
    input         in_clock,      // Clock (unused in combinational version)
    input  [16:0] denom,         // Divisor (17-bit)
    input  [33:0] numer,         // Dividend (34-bit, AC:IO concatenated)
    output [33:0] quotient,      // Quotient (34-bit)
    output [16:0] remain         // Remainder (17-bit)
);

    // Simple behavioral division using Verilog operators
    // Synthesizer will infer divider logic (LUT-based on most FPGAs)

    // Handle divide-by-zero: if denom is 0, output all 1s (max value)
    // This matches typical hardware behavior and prevents simulation X

    wire div_by_zero = (denom == 17'b0);

    assign quotient = div_by_zero ? 34'h3_FFFF_FFFF : (numer / {17'b0, denom});
    assign remain   = div_by_zero ? 17'h1FFFF       : numer % {17'b0, denom};

endmodule
