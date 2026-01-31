// =============================================================================
// TMDS Encoder - Verilog Implementation
// =============================================================================
// Based on DVI 1.0 specification and Mike Field's VHDL implementation
// Ported to Verilog by: Jelena Horvat, REGOC tim
// Datum: 2026-01-31
//
// 8 bits color, 2 control bits, 1 blanking bit in
// 10 bits TMDS encoded data out
// Clocked at pixel clock
// =============================================================================

module tmds_encoder
(
    input  wire        clk,
    input  wire [7:0]  data,
    input  wire [1:0]  c,
    input  wire        blank,
    output reg  [9:0]  encoded
);

    // Work out the two different encodings for the byte
    wire [8:0] xored;
    wire [8:0] xnored;

    assign xored[0] = data[0];
    assign xored[1] = data[1] ^ xored[0];
    assign xored[2] = data[2] ^ xored[1];
    assign xored[3] = data[3] ^ xored[2];
    assign xored[4] = data[4] ^ xored[3];
    assign xored[5] = data[5] ^ xored[4];
    assign xored[6] = data[6] ^ xored[5];
    assign xored[7] = data[7] ^ xored[6];
    assign xored[8] = 1'b1;

    assign xnored[0] = data[0];
    assign xnored[1] = ~(data[1] ^ xnored[0]);
    assign xnored[2] = ~(data[2] ^ xnored[1]);
    assign xnored[3] = ~(data[3] ^ xnored[2]);
    assign xnored[4] = ~(data[4] ^ xnored[3]);
    assign xnored[5] = ~(data[5] ^ xnored[4]);
    assign xnored[6] = ~(data[6] ^ xnored[5]);
    assign xnored[7] = ~(data[7] ^ xnored[6]);
    assign xnored[8] = 1'b0;

    // Count ones in data
    wire [3:0] ones;
    assign ones = data[0] + data[1] + data[2] + data[3] +
                  data[4] + data[5] + data[6] + data[7];

    // Decide which encoding to use
    wire [8:0] data_word;
    wire [8:0] data_word_inv;

    assign data_word     = (ones > 4 || (ones == 4 && data[0] == 1'b0)) ? xnored : xored;
    assign data_word_inv = ~data_word;

    // Work out the DC bias of the data word
    wire [3:0] data_word_disparity;
    assign data_word_disparity = 4'b1100 +  // -4 in 4-bit signed
                                 data_word[0] + data_word[1] + data_word[2] + data_word[3] +
                                 data_word[4] + data_word[5] + data_word[6] + data_word[7];

    // DC bias tracking
    reg [3:0] dc_bias = 4'b0000;

    always @(posedge clk) begin
        if (blank) begin
            // Control period - output balanced control tokens
            case (c)
                2'b00:   encoded <= 10'b1101010100;
                2'b01:   encoded <= 10'b0010101011;
                2'b10:   encoded <= 10'b0101010100;
                default: encoded <= 10'b1010101011;
            endcase
            dc_bias <= 4'b0000;
        end
        else begin
            if (dc_bias == 4'b0000 || data_word_disparity == 4'b0000) begin
                // No DC bias or data word has no disparity
                if (data_word[8]) begin
                    encoded <= {2'b01, data_word[7:0]};
                    dc_bias <= dc_bias + data_word_disparity;
                end
                else begin
                    encoded <= {2'b10, data_word_inv[7:0]};
                    dc_bias <= dc_bias - data_word_disparity;
                end
            end
            else if ((dc_bias[3] == 1'b0 && data_word_disparity[3] == 1'b0) ||
                     (dc_bias[3] == 1'b1 && data_word_disparity[3] == 1'b1)) begin
                encoded <= {1'b1, data_word[8], data_word_inv[7:0]};
                dc_bias <= dc_bias + data_word[8] - data_word_disparity;
            end
            else begin
                encoded <= {1'b0, data_word[8:0]};
                dc_bias <= dc_bias - data_word_inv[8] + data_word_disparity;
            end
        end
    end

endmodule
