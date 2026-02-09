/*
 * 8-Stage Pipelined Restoring Divider for PDP-1 CPU
 *
 * PDP-1 DIV instruction divides 34-bit dividend (AC:IO) by 17-bit divisor
 * producing 34-bit quotient and 17-bit remainder.
 *
 * Uses restoring division algorithm with 8-stage pipeline:
 * - Latency: 8 clock cycles
 * - Throughput: 1 result per clock after pipeline fills
 * - Each stage processes 4-5 bits of the quotient
 *
 * Bit distribution across stages:
 * Stage 0: bits 33-30 (4 bits)  - processed combinationally before reg
 * Stage 1: bits 29-26 (4 bits)
 * Stage 2: bits 25-22 (4 bits)
 * Stage 3: bits 21-17 (5 bits)
 * Stage 4: bits 16-13 (4 bits)
 * Stage 5: bits 12-9  (4 bits)
 * Stage 6: bits 8-5   (4 bits)
 * Stage 7: bits 4-0   (5 bits)
 * Total: 4+4+4+5+4+4+4+5 = 34 bits
 *
 * Original combinational version took ~170ns.
 * Pipelined version: 8 cycles @ target frequency.
 *
 * Author: Potjeh Sabolic, REGOC team
 * Task: TASK-189 Divider Implementation
 * Modified: Jelena Kovacevic - pipelined implementation
 */

module pdp1_cpu_alu_div (
    input         in_clock,      // Clock input
    input         i_start,       // Start division (loads operands)
    input  [16:0] denom,         // Divisor (17-bit)
    input  [33:0] numer,         // Dividend (34-bit, AC:IO concatenated)
    output [33:0] quotient,      // Quotient (34-bit)
    output [16:0] remain,        // Remainder (17-bit)
    output        o_valid        // Result valid flag
);

    // =========================================================================
    // Pipeline registers
    // =========================================================================

    // Partial remainder through pipeline (35 bits for sign detection)
    reg [34:0] r_remainder [0:7];

    // Quotient accumulating through pipeline
    reg [33:0] r_quotient [0:7];

    // Divisor propagated through pipeline
    reg [16:0] r_divisor [0:7];

    // Valid pipeline
    reg [7:0] r_valid;

    // Divide-by-zero flag pipeline
    reg [7:0] r_div_by_zero;

    // =========================================================================
    // Helper function: Process N bits of restoring division
    // =========================================================================

    // Divisor extended for comparison
    wire [34:0] w_div_ext = {18'b0, denom};

    // Detect divide by zero
    wire w_dbz = (denom == 17'b0);

    // =========================================================================
    // Stage 0: Load operands and process bits 33-30
    // =========================================================================

    // Combinational logic for stage 0 (bits 33-30)
    wire [34:0] s0_rem_b33 = {34'b0, numer[33]};
    wire [34:0] s0_sub_b33 = s0_rem_b33 - w_div_ext;
    wire        s0_q33 = ~s0_sub_b33[34];
    wire [34:0] s0_rem_after33 = s0_q33 ? s0_sub_b33 : s0_rem_b33;

    wire [34:0] s0_rem_b32 = {s0_rem_after33[33:0], numer[32]};
    wire [34:0] s0_sub_b32 = s0_rem_b32 - w_div_ext;
    wire        s0_q32 = ~s0_sub_b32[34];
    wire [34:0] s0_rem_after32 = s0_q32 ? s0_sub_b32 : s0_rem_b32;

    wire [34:0] s0_rem_b31 = {s0_rem_after32[33:0], numer[31]};
    wire [34:0] s0_sub_b31 = s0_rem_b31 - w_div_ext;
    wire        s0_q31 = ~s0_sub_b31[34];
    wire [34:0] s0_rem_after31 = s0_q31 ? s0_sub_b31 : s0_rem_b31;

    wire [34:0] s0_rem_b30 = {s0_rem_after31[33:0], numer[30]};
    wire [34:0] s0_sub_b30 = s0_rem_b30 - w_div_ext;
    wire        s0_q30 = ~s0_sub_b30[34];
    wire [34:0] s0_rem_final = s0_q30 ? s0_sub_b30 : s0_rem_b30;

    always @(posedge in_clock) begin
        r_valid[0] <= i_start;
        r_div_by_zero[0] <= w_dbz;
        r_divisor[0] <= denom;
        r_remainder[0] <= s0_rem_final;
        r_quotient[0] <= {s0_q33, s0_q32, s0_q31, s0_q30, numer[29:0]};
    end

    // =========================================================================
    // Stage 1: Process bits 29-26
    // =========================================================================

    wire [34:0] s1_div = {18'b0, r_divisor[0]};

    wire [34:0] s1_rem_b29 = {r_remainder[0][33:0], r_quotient[0][29]};
    wire [34:0] s1_sub_b29 = s1_rem_b29 - s1_div;
    wire        s1_q29 = ~s1_sub_b29[34];
    wire [34:0] s1_rem_after29 = s1_q29 ? s1_sub_b29 : s1_rem_b29;

    wire [34:0] s1_rem_b28 = {s1_rem_after29[33:0], r_quotient[0][28]};
    wire [34:0] s1_sub_b28 = s1_rem_b28 - s1_div;
    wire        s1_q28 = ~s1_sub_b28[34];
    wire [34:0] s1_rem_after28 = s1_q28 ? s1_sub_b28 : s1_rem_b28;

    wire [34:0] s1_rem_b27 = {s1_rem_after28[33:0], r_quotient[0][27]};
    wire [34:0] s1_sub_b27 = s1_rem_b27 - s1_div;
    wire        s1_q27 = ~s1_sub_b27[34];
    wire [34:0] s1_rem_after27 = s1_q27 ? s1_sub_b27 : s1_rem_b27;

    wire [34:0] s1_rem_b26 = {s1_rem_after27[33:0], r_quotient[0][26]};
    wire [34:0] s1_sub_b26 = s1_rem_b26 - s1_div;
    wire        s1_q26 = ~s1_sub_b26[34];
    wire [34:0] s1_rem_final = s1_q26 ? s1_sub_b26 : s1_rem_b26;

    always @(posedge in_clock) begin
        r_valid[1] <= r_valid[0];
        r_div_by_zero[1] <= r_div_by_zero[0];
        r_divisor[1] <= r_divisor[0];
        r_remainder[1] <= s1_rem_final;
        r_quotient[1] <= {r_quotient[0][33:30], s1_q29, s1_q28, s1_q27, s1_q26, r_quotient[0][25:0]};
    end

    // =========================================================================
    // Stage 2: Process bits 25-22
    // =========================================================================

    wire [34:0] s2_div = {18'b0, r_divisor[1]};

    wire [34:0] s2_rem_b25 = {r_remainder[1][33:0], r_quotient[1][25]};
    wire [34:0] s2_sub_b25 = s2_rem_b25 - s2_div;
    wire        s2_q25 = ~s2_sub_b25[34];
    wire [34:0] s2_rem_after25 = s2_q25 ? s2_sub_b25 : s2_rem_b25;

    wire [34:0] s2_rem_b24 = {s2_rem_after25[33:0], r_quotient[1][24]};
    wire [34:0] s2_sub_b24 = s2_rem_b24 - s2_div;
    wire        s2_q24 = ~s2_sub_b24[34];
    wire [34:0] s2_rem_after24 = s2_q24 ? s2_sub_b24 : s2_rem_b24;

    wire [34:0] s2_rem_b23 = {s2_rem_after24[33:0], r_quotient[1][23]};
    wire [34:0] s2_sub_b23 = s2_rem_b23 - s2_div;
    wire        s2_q23 = ~s2_sub_b23[34];
    wire [34:0] s2_rem_after23 = s2_q23 ? s2_sub_b23 : s2_rem_b23;

    wire [34:0] s2_rem_b22 = {s2_rem_after23[33:0], r_quotient[1][22]};
    wire [34:0] s2_sub_b22 = s2_rem_b22 - s2_div;
    wire        s2_q22 = ~s2_sub_b22[34];
    wire [34:0] s2_rem_final = s2_q22 ? s2_sub_b22 : s2_rem_b22;

    always @(posedge in_clock) begin
        r_valid[2] <= r_valid[1];
        r_div_by_zero[2] <= r_div_by_zero[1];
        r_divisor[2] <= r_divisor[1];
        r_remainder[2] <= s2_rem_final;
        r_quotient[2] <= {r_quotient[1][33:26], s2_q25, s2_q24, s2_q23, s2_q22, r_quotient[1][21:0]};
    end

    // =========================================================================
    // Stage 3: Process bits 21-17 (5 bits)
    // =========================================================================

    wire [34:0] s3_div = {18'b0, r_divisor[2]};

    wire [34:0] s3_rem_b21 = {r_remainder[2][33:0], r_quotient[2][21]};
    wire [34:0] s3_sub_b21 = s3_rem_b21 - s3_div;
    wire        s3_q21 = ~s3_sub_b21[34];
    wire [34:0] s3_rem_after21 = s3_q21 ? s3_sub_b21 : s3_rem_b21;

    wire [34:0] s3_rem_b20 = {s3_rem_after21[33:0], r_quotient[2][20]};
    wire [34:0] s3_sub_b20 = s3_rem_b20 - s3_div;
    wire        s3_q20 = ~s3_sub_b20[34];
    wire [34:0] s3_rem_after20 = s3_q20 ? s3_sub_b20 : s3_rem_b20;

    wire [34:0] s3_rem_b19 = {s3_rem_after20[33:0], r_quotient[2][19]};
    wire [34:0] s3_sub_b19 = s3_rem_b19 - s3_div;
    wire        s3_q19 = ~s3_sub_b19[34];
    wire [34:0] s3_rem_after19 = s3_q19 ? s3_sub_b19 : s3_rem_b19;

    wire [34:0] s3_rem_b18 = {s3_rem_after19[33:0], r_quotient[2][18]};
    wire [34:0] s3_sub_b18 = s3_rem_b18 - s3_div;
    wire        s3_q18 = ~s3_sub_b18[34];
    wire [34:0] s3_rem_after18 = s3_q18 ? s3_sub_b18 : s3_rem_b18;

    wire [34:0] s3_rem_b17 = {s3_rem_after18[33:0], r_quotient[2][17]};
    wire [34:0] s3_sub_b17 = s3_rem_b17 - s3_div;
    wire        s3_q17 = ~s3_sub_b17[34];
    wire [34:0] s3_rem_final = s3_q17 ? s3_sub_b17 : s3_rem_b17;

    always @(posedge in_clock) begin
        r_valid[3] <= r_valid[2];
        r_div_by_zero[3] <= r_div_by_zero[2];
        r_divisor[3] <= r_divisor[2];
        r_remainder[3] <= s3_rem_final;
        r_quotient[3] <= {r_quotient[2][33:22], s3_q21, s3_q20, s3_q19, s3_q18, s3_q17, r_quotient[2][16:0]};
    end

    // =========================================================================
    // Stage 4: Process bits 16-13
    // =========================================================================

    wire [34:0] s4_div = {18'b0, r_divisor[3]};

    wire [34:0] s4_rem_b16 = {r_remainder[3][33:0], r_quotient[3][16]};
    wire [34:0] s4_sub_b16 = s4_rem_b16 - s4_div;
    wire        s4_q16 = ~s4_sub_b16[34];
    wire [34:0] s4_rem_after16 = s4_q16 ? s4_sub_b16 : s4_rem_b16;

    wire [34:0] s4_rem_b15 = {s4_rem_after16[33:0], r_quotient[3][15]};
    wire [34:0] s4_sub_b15 = s4_rem_b15 - s4_div;
    wire        s4_q15 = ~s4_sub_b15[34];
    wire [34:0] s4_rem_after15 = s4_q15 ? s4_sub_b15 : s4_rem_b15;

    wire [34:0] s4_rem_b14 = {s4_rem_after15[33:0], r_quotient[3][14]};
    wire [34:0] s4_sub_b14 = s4_rem_b14 - s4_div;
    wire        s4_q14 = ~s4_sub_b14[34];
    wire [34:0] s4_rem_after14 = s4_q14 ? s4_sub_b14 : s4_rem_b14;

    wire [34:0] s4_rem_b13 = {s4_rem_after14[33:0], r_quotient[3][13]};
    wire [34:0] s4_sub_b13 = s4_rem_b13 - s4_div;
    wire        s4_q13 = ~s4_sub_b13[34];
    wire [34:0] s4_rem_final = s4_q13 ? s4_sub_b13 : s4_rem_b13;

    always @(posedge in_clock) begin
        r_valid[4] <= r_valid[3];
        r_div_by_zero[4] <= r_div_by_zero[3];
        r_divisor[4] <= r_divisor[3];
        r_remainder[4] <= s4_rem_final;
        r_quotient[4] <= {r_quotient[3][33:17], s4_q16, s4_q15, s4_q14, s4_q13, r_quotient[3][12:0]};
    end

    // =========================================================================
    // Stage 5: Process bits 12-9
    // =========================================================================

    wire [34:0] s5_div = {18'b0, r_divisor[4]};

    wire [34:0] s5_rem_b12 = {r_remainder[4][33:0], r_quotient[4][12]};
    wire [34:0] s5_sub_b12 = s5_rem_b12 - s5_div;
    wire        s5_q12 = ~s5_sub_b12[34];
    wire [34:0] s5_rem_after12 = s5_q12 ? s5_sub_b12 : s5_rem_b12;

    wire [34:0] s5_rem_b11 = {s5_rem_after12[33:0], r_quotient[4][11]};
    wire [34:0] s5_sub_b11 = s5_rem_b11 - s5_div;
    wire        s5_q11 = ~s5_sub_b11[34];
    wire [34:0] s5_rem_after11 = s5_q11 ? s5_sub_b11 : s5_rem_b11;

    wire [34:0] s5_rem_b10 = {s5_rem_after11[33:0], r_quotient[4][10]};
    wire [34:0] s5_sub_b10 = s5_rem_b10 - s5_div;
    wire        s5_q10 = ~s5_sub_b10[34];
    wire [34:0] s5_rem_after10 = s5_q10 ? s5_sub_b10 : s5_rem_b10;

    wire [34:0] s5_rem_b9 = {s5_rem_after10[33:0], r_quotient[4][9]};
    wire [34:0] s5_sub_b9 = s5_rem_b9 - s5_div;
    wire        s5_q9 = ~s5_sub_b9[34];
    wire [34:0] s5_rem_final = s5_q9 ? s5_sub_b9 : s5_rem_b9;

    always @(posedge in_clock) begin
        r_valid[5] <= r_valid[4];
        r_div_by_zero[5] <= r_div_by_zero[4];
        r_divisor[5] <= r_divisor[4];
        r_remainder[5] <= s5_rem_final;
        r_quotient[5] <= {r_quotient[4][33:13], s5_q12, s5_q11, s5_q10, s5_q9, r_quotient[4][8:0]};
    end

    // =========================================================================
    // Stage 6: Process bits 8-5
    // =========================================================================

    wire [34:0] s6_div = {18'b0, r_divisor[5]};

    wire [34:0] s6_rem_b8 = {r_remainder[5][33:0], r_quotient[5][8]};
    wire [34:0] s6_sub_b8 = s6_rem_b8 - s6_div;
    wire        s6_q8 = ~s6_sub_b8[34];
    wire [34:0] s6_rem_after8 = s6_q8 ? s6_sub_b8 : s6_rem_b8;

    wire [34:0] s6_rem_b7 = {s6_rem_after8[33:0], r_quotient[5][7]};
    wire [34:0] s6_sub_b7 = s6_rem_b7 - s6_div;
    wire        s6_q7 = ~s6_sub_b7[34];
    wire [34:0] s6_rem_after7 = s6_q7 ? s6_sub_b7 : s6_rem_b7;

    wire [34:0] s6_rem_b6 = {s6_rem_after7[33:0], r_quotient[5][6]};
    wire [34:0] s6_sub_b6 = s6_rem_b6 - s6_div;
    wire        s6_q6 = ~s6_sub_b6[34];
    wire [34:0] s6_rem_after6 = s6_q6 ? s6_sub_b6 : s6_rem_b6;

    wire [34:0] s6_rem_b5 = {s6_rem_after6[33:0], r_quotient[5][5]};
    wire [34:0] s6_sub_b5 = s6_rem_b5 - s6_div;
    wire        s6_q5 = ~s6_sub_b5[34];
    wire [34:0] s6_rem_final = s6_q5 ? s6_sub_b5 : s6_rem_b5;

    always @(posedge in_clock) begin
        r_valid[6] <= r_valid[5];
        r_div_by_zero[6] <= r_div_by_zero[5];
        r_divisor[6] <= r_divisor[5];
        r_remainder[6] <= s6_rem_final;
        r_quotient[6] <= {r_quotient[5][33:9], s6_q8, s6_q7, s6_q6, s6_q5, r_quotient[5][4:0]};
    end

    // =========================================================================
    // Stage 7: Process bits 4-0 (5 bits)
    // =========================================================================

    wire [34:0] s7_div = {18'b0, r_divisor[6]};

    wire [34:0] s7_rem_b4 = {r_remainder[6][33:0], r_quotient[6][4]};
    wire [34:0] s7_sub_b4 = s7_rem_b4 - s7_div;
    wire        s7_q4 = ~s7_sub_b4[34];
    wire [34:0] s7_rem_after4 = s7_q4 ? s7_sub_b4 : s7_rem_b4;

    wire [34:0] s7_rem_b3 = {s7_rem_after4[33:0], r_quotient[6][3]};
    wire [34:0] s7_sub_b3 = s7_rem_b3 - s7_div;
    wire        s7_q3 = ~s7_sub_b3[34];
    wire [34:0] s7_rem_after3 = s7_q3 ? s7_sub_b3 : s7_rem_b3;

    wire [34:0] s7_rem_b2 = {s7_rem_after3[33:0], r_quotient[6][2]};
    wire [34:0] s7_sub_b2 = s7_rem_b2 - s7_div;
    wire        s7_q2 = ~s7_sub_b2[34];
    wire [34:0] s7_rem_after2 = s7_q2 ? s7_sub_b2 : s7_rem_b2;

    wire [34:0] s7_rem_b1 = {s7_rem_after2[33:0], r_quotient[6][1]};
    wire [34:0] s7_sub_b1 = s7_rem_b1 - s7_div;
    wire        s7_q1 = ~s7_sub_b1[34];
    wire [34:0] s7_rem_after1 = s7_q1 ? s7_sub_b1 : s7_rem_b1;

    wire [34:0] s7_rem_b0 = {s7_rem_after1[33:0], r_quotient[6][0]};
    wire [34:0] s7_sub_b0 = s7_rem_b0 - s7_div;
    wire        s7_q0 = ~s7_sub_b0[34];
    wire [34:0] s7_rem_final = s7_q0 ? s7_sub_b0 : s7_rem_b0;

    always @(posedge in_clock) begin
        r_valid[7] <= r_valid[6];
        r_div_by_zero[7] <= r_div_by_zero[6];
        r_divisor[7] <= r_divisor[6];
        r_remainder[7] <= s7_rem_final;
        r_quotient[7] <= {r_quotient[6][33:5], s7_q4, s7_q3, s7_q2, s7_q1, s7_q0};
    end

    // =========================================================================
    // Output assignments
    // =========================================================================

    assign o_valid = r_valid[7];

    // Handle divide-by-zero: output all 1s (matches original behavior)
    assign quotient = r_div_by_zero[7] ? 34'h3_FFFF_FFFF : r_quotient[7];
    assign remain = r_div_by_zero[7] ? 17'h1FFFF : r_remainder[7][16:0];

endmodule
