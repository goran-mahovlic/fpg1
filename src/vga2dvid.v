// =============================================================================
// VGA to DVID (DVI/HDMI) Converter - Verilog Implementation
// =============================================================================
// Based on Mike Field's VHDL implementation and Emard's unified SDR/DDR version
// Ported to Verilog by: Jelena Horvat, REGOC tim
// Datum: 2026-01-31
//
// Takes VGA input and converts to TMDS for DVI/HDMI output
// Supports both SDR (10x pixel clock) and DDR (5x pixel clock) modes
// =============================================================================

module vga2dvid
#(
    parameter C_ddr   = 1'b1,   // 0: SDR mode (10x clock), 1: DDR mode (5x clock)
    parameter C_depth = 8       // Color depth (1-8 bits)
)
(
    input  wire                   clk_pixel,  // Pixel clock (51 MHz for 1024x768@50Hz)
    input  wire                   clk_shift,  // Shift clock: DDR=5x, SDR=10x pixel clock
    input  wire [C_depth-1:0]     in_red,
    input  wire [C_depth-1:0]     in_green,
    input  wire [C_depth-1:0]     in_blue,
    input  wire                   in_blank,
    input  wire                   in_hsync,
    input  wire                   in_vsync,
    output wire [1:0]             out_red,
    output wire [1:0]             out_green,
    output wire [1:0]             out_blue,
    output wire [1:0]             out_clock
);

    // Expand color to 8 bits (if not already)
    wire [7:0] red_8;
    wire [7:0] green_8;
    wire [7:0] blue_8;

    generate
        if (C_depth == 8) begin : gen_8bit
            assign red_8   = in_red;
            assign green_8 = in_green;
            assign blue_8  = in_blue;
        end
        else begin : gen_expand
            // Replicate MSBs to fill LSBs
            assign red_8   = {in_red,   {(8-C_depth){in_red[C_depth-1]}}};
            assign green_8 = {in_green, {(8-C_depth){in_green[C_depth-1]}}};
            assign blue_8  = {in_blue,  {(8-C_depth){in_blue[C_depth-1]}}};
        end
    endgenerate

    // Control signals
    wire [1:0] c_red   = 2'b00;
    wire [1:0] c_green = 2'b00;
    wire [1:0] c_blue  = {in_vsync, in_hsync};

    // TMDS encoded data
    wire [9:0] encoded_red;
    wire [9:0] encoded_green;
    wire [9:0] encoded_blue;

    // Instantiate TMDS encoders
    tmds_encoder enc_red (
        .clk     (clk_pixel),
        .data    (red_8),
        .c       (c_red),
        .blank   (in_blank),
        .encoded (encoded_red)
    );

    tmds_encoder enc_green (
        .clk     (clk_pixel),
        .data    (green_8),
        .c       (c_green),
        .blank   (in_blank),
        .encoded (encoded_green)
    );

    tmds_encoder enc_blue (
        .clk     (clk_pixel),
        .data    (blue_8),
        .c       (c_blue),
        .blank   (in_blank),
        .encoded (encoded_blue)
    );

    // Latched encoded data (synced to pixel clock)
    reg [9:0] latched_red;
    reg [9:0] latched_green;
    reg [9:0] latched_blue;

    always @(posedge clk_pixel) begin
        latched_red   <= encoded_red;
        latched_green <= encoded_green;
        latched_blue  <= encoded_blue;
    end

    // Shift clock pattern: 0000011111 for 10-bit TMDS
    localparam [9:0] SHIFT_CLOCK_INIT = 10'b0000011111;

    // Shift registers for serialization
    reg [9:0] shift_red   = 10'b0;
    reg [9:0] shift_green = 10'b0;
    reg [9:0] shift_blue  = 10'b0;
    reg [9:0] shift_clock = SHIFT_CLOCK_INIT;

    // Clock synchronization
    reg shift_clock_sync = 1'b0;
    reg [7:0] sync_counter = 8'b0;
    reg [6:0] sync_fail = 7'b0;

    // Check if shift_clock is synchronized with pixel clock
    always @(posedge clk_pixel) begin
        if (shift_clock[5:4] == SHIFT_CLOCK_INIT[5:4])
            shift_clock_sync <= 1'b0;
        else
            shift_clock_sync <= 1'b1;
    end

    // Synchronization adjustment
    always @(posedge clk_shift) begin
        if (shift_clock_sync) begin
            if (sync_counter[7])
                sync_counter <= 8'b0;
            else
                sync_counter <= sync_counter + 1'b1;
        end
        else begin
            sync_counter <= 8'b0;
        end
    end

    generate
        if (C_ddr == 1'b0) begin : gen_sdr
            // =================================================================
            // SDR Mode: 10x pixel clock, output 1 bit per clock
            // =================================================================
            always @(posedge clk_shift) begin
                if (shift_clock[5:4] == SHIFT_CLOCK_INIT[5:4]) begin
                    shift_red   <= latched_red;
                    shift_green <= latched_green;
                    shift_blue  <= latched_blue;
                end
                else begin
                    shift_red   <= {1'b0, shift_red[9:1]};
                    shift_green <= {1'b0, shift_green[9:1]};
                    shift_blue  <= {1'b0, shift_blue[9:1]};
                end

                if (!sync_counter[7]) begin
                    shift_clock <= {shift_clock[0], shift_clock[9:1]};
                end
                else begin
                    if (sync_fail[6]) begin
                        shift_clock <= SHIFT_CLOCK_INIT;
                        sync_fail <= 7'b0;
                    end
                    else begin
                        sync_fail <= sync_fail + 1'b1;
                    end
                end
            end

            // SDR output: bit 0 only
            assign out_red   = {1'b0, shift_red[0]};
            assign out_green = {1'b0, shift_green[0]};
            assign out_blue  = {1'b0, shift_blue[0]};
            assign out_clock = {1'b0, shift_clock[0]};
        end
        else begin : gen_ddr
            // =================================================================
            // DDR Mode: 5x pixel clock, output 2 bits per clock
            // =================================================================
            always @(posedge clk_shift) begin
                if (shift_clock[5:4] == SHIFT_CLOCK_INIT[5:4]) begin
                    shift_red   <= latched_red;
                    shift_green <= latched_green;
                    shift_blue  <= latched_blue;
                end
                else begin
                    shift_red   <= {2'b00, shift_red[9:2]};
                    shift_green <= {2'b00, shift_green[9:2]};
                    shift_blue  <= {2'b00, shift_blue[9:2]};
                end

                if (!sync_counter[7]) begin
                    shift_clock <= {shift_clock[1:0], shift_clock[9:2]};
                end
                else begin
                    if (sync_fail[6]) begin
                        shift_clock <= SHIFT_CLOCK_INIT;
                        sync_fail <= 7'b0;
                    end
                    else begin
                        sync_fail <= sync_fail + 1'b1;
                    end
                end
            end

            // DDR output: bits 1:0
            assign out_red   = shift_red[1:0];
            assign out_green = shift_green[1:0];
            assign out_blue  = shift_blue[1:0];
            assign out_clock = shift_clock[1:0];
        end
    endgenerate

endmodule
