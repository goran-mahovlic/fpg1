// =============================================================================
// Serial Debug Module: UART TX for Debug Output
// =============================================================================
// TASK-DEBUG: Debug infrastruktura za crni ekran problem
// Autor: Debug Team, REGOC
// Datum: 2026-01-31
//
// OPIS:
//   Jednostavan UART TX modul za slanje debug informacija na PC.
//   Na svaki frame_tick salje ASCII string s debug podacima.
//
// FORMAT:
//   "F:xxxx A:yy X:zzz Y:www\r\n"
//   F = frame counter (hex)
//   A = animation angle (hex)
//   X = pixel X coordinate (decimal)
//   Y = pixel Y coordinate (decimal)
//
// SPECIFIKACIJA:
//   - Baud: 115200
//   - Clock: 25 MHz
//   - Pin: ftdi_rxd (L4) - FPGA TX prema PC-u
//
// =============================================================================

// =============================================================================
// UART TX Module
// =============================================================================
module uart_tx #(
    parameter CLK_FREQ = 25000000,
    parameter BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       send,
    output reg        tx,
    output reg        busy
);
    // Clocks per bit: 25000000 / 115200 = 217
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;

    // State machine
    localparam IDLE      = 3'd0;
    localparam START_BIT = 3'd1;
    localparam DATA_BITS = 3'd2;
    localparam STOP_BIT  = 3'd3;

    reg [2:0]  state;
    reg [7:0]  shift_reg;
    reg [2:0]  bit_index;
    reg [15:0] clk_count;

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= IDLE;
            tx        <= 1'b1;  // Idle high
            busy      <= 1'b0;
            shift_reg <= 8'd0;
            bit_index <= 3'd0;
            clk_count <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    if (send) begin
                        shift_reg <= data;
                        state     <= START_BIT;
                        busy      <= 1'b1;
                        clk_count <= 16'd0;
                    end
                end

                START_BIT: begin
                    tx <= 1'b0;  // Start bit is low
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        bit_index <= 3'd0;
                        state     <= DATA_BITS;
                    end
                end

                DATA_BITS: begin
                    tx <= shift_reg[bit_index];
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        clk_count <= 16'd0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1'b1;
                        end else begin
                            state <= STOP_BIT;
                        end
                    end
                end

                STOP_BIT: begin
                    tx <= 1'b1;  // Stop bit is high
                    if (clk_count < CLKS_PER_BIT - 1) begin
                        clk_count <= clk_count + 1'b1;
                    end else begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule

// =============================================================================
// Serial Debug Wrapper
// =============================================================================
module serial_debug (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_tick,
    input  wire [7:0]  angle,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        pixel_valid,
    input  wire [7:0]  led_status,    // LED status za debug
    output wire        uart_tx_pin
);

    // =========================================================================
    // UART TX instance
    // =========================================================================
    reg  [7:0] tx_data;
    reg        tx_send;
    wire       tx_busy;

    uart_tx #(
        .CLK_FREQ (25000000),
        .BAUD     (115200)
    ) uart_inst (
        .clk    (clk),
        .rst_n  (rst_n),
        .data   (tx_data),
        .send   (tx_send),
        .tx     (uart_tx_pin),
        .busy   (tx_busy)
    );

    // =========================================================================
    // Frame counter
    // =========================================================================
    reg [15:0] frame_counter;

    always @(posedge clk) begin
        if (!rst_n)
            frame_counter <= 16'd0;
        else if (frame_tick)
            frame_counter <= frame_counter + 1'b1;
    end

    // =========================================================================
    // Latch values on frame_tick
    // =========================================================================
    reg [7:0]  latched_angle;
    reg [9:0]  latched_x;
    reg [9:0]  latched_y;
    reg [15:0] latched_frame;
    reg [7:0]  latched_led;

    always @(posedge clk) begin
        if (!rst_n) begin
            latched_angle <= 8'd0;
            latched_x     <= 10'd0;
            latched_y     <= 10'd0;
            latched_frame <= 16'd0;
            latched_led   <= 8'd0;
        end else if (frame_tick) begin
            latched_angle <= angle;
            latched_x     <= pixel_x;
            latched_y     <= pixel_y;
            latched_frame <= frame_counter;
            latched_led   <= led_status;
        end
    end

    // =========================================================================
    // Hex to ASCII conversion functions
    // =========================================================================
    function [7:0] hex_to_ascii;
        input [3:0] hex;
        begin
            if (hex < 10)
                hex_to_ascii = 8'd48 + hex;  // '0'-'9'
            else
                hex_to_ascii = 8'd55 + hex;  // 'A'-'F'
        end
    endfunction

    // Decimal digit extraction (hundreds, tens, units)
    function [7:0] digit_to_ascii;
        input [3:0] digit;
        begin
            digit_to_ascii = 8'd48 + digit;  // '0'-'9'
        end
    endfunction

    // =========================================================================
    // Message buffer - "F:xxxx A:yy X:zzz Y:www L:bbbbbbbb\n"
    // =========================================================================
    // Total 35 characters:
    // F : x x x x   A : y y   X : z z z   Y : w w w   L : b b b b b b b b \n
    // 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34

    localparam MSG_LEN = 35;

    reg [7:0] msg_buffer [0:MSG_LEN-1];
    reg [5:0] msg_index;
    reg       sending;
    reg       frame_tick_latched;

    // Decimal conversion for X and Y (0-639 range)
    wire [3:0] x_hundreds = latched_x / 100;
    wire [3:0] x_tens     = (latched_x / 10) % 10;
    wire [3:0] x_units    = latched_x % 10;

    wire [3:0] y_hundreds = latched_y / 100;
    wire [3:0] y_tens     = (latched_y / 10) % 10;
    wire [3:0] y_units    = latched_y % 10;

    // =========================================================================
    // State machine for sending message
    // =========================================================================
    localparam ST_IDLE     = 2'd0;
    localparam ST_PREPARE  = 2'd1;
    localparam ST_SEND     = 2'd2;
    localparam ST_WAIT     = 2'd3;

    reg [1:0] state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            msg_index          <= 5'd0;
            sending            <= 1'b0;
            tx_send            <= 1'b0;
            tx_data            <= 8'd0;
            frame_tick_latched <= 1'b0;
        end else begin
            // Latch frame_tick rising edge
            frame_tick_latched <= frame_tick;
            tx_send <= 1'b0;  // Default

            case (state)
                ST_IDLE: begin
                    // Start sending on frame_tick rising edge
                    if (frame_tick && !frame_tick_latched) begin
                        // Prepare message buffer
                        msg_buffer[0]  <= "F";
                        msg_buffer[1]  <= ":";
                        msg_buffer[2]  <= hex_to_ascii(latched_frame[15:12]);
                        msg_buffer[3]  <= hex_to_ascii(latched_frame[11:8]);
                        msg_buffer[4]  <= hex_to_ascii(latched_frame[7:4]);
                        msg_buffer[5]  <= hex_to_ascii(latched_frame[3:0]);
                        msg_buffer[6]  <= " ";
                        msg_buffer[7]  <= "A";
                        msg_buffer[8]  <= ":";
                        msg_buffer[9]  <= hex_to_ascii(latched_angle[7:4]);
                        msg_buffer[10] <= hex_to_ascii(latched_angle[3:0]);
                        msg_buffer[11] <= " ";
                        msg_buffer[12] <= "X";
                        msg_buffer[13] <= ":";
                        msg_buffer[14] <= digit_to_ascii(x_hundreds);
                        msg_buffer[15] <= digit_to_ascii(x_tens);
                        msg_buffer[16] <= digit_to_ascii(x_units);
                        msg_buffer[17] <= " ";
                        msg_buffer[18] <= "Y";
                        msg_buffer[19] <= ":";
                        msg_buffer[20] <= digit_to_ascii(y_hundreds);
                        msg_buffer[21] <= digit_to_ascii(y_tens);
                        msg_buffer[22] <= digit_to_ascii(y_units);
                        msg_buffer[23] <= " ";
                        msg_buffer[24] <= "L";
                        msg_buffer[25] <= ":";
                        // LED status as 8 binary digits
                        msg_buffer[26] <= latched_led[7] ? "1" : "0";
                        msg_buffer[27] <= latched_led[6] ? "1" : "0";
                        msg_buffer[28] <= latched_led[5] ? "1" : "0";
                        msg_buffer[29] <= latched_led[4] ? "1" : "0";
                        msg_buffer[30] <= latched_led[3] ? "1" : "0";
                        msg_buffer[31] <= latched_led[2] ? "1" : "0";
                        msg_buffer[32] <= latched_led[1] ? "1" : "0";
                        msg_buffer[33] <= latched_led[0] ? "1" : "0";
                        msg_buffer[34] <= 8'd10;  // '\n' (LF)

                        msg_index <= 6'd0;
                        state     <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    if (!tx_busy) begin
                        tx_data <= msg_buffer[msg_index];
                        tx_send <= 1'b1;
                        state   <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (tx_busy) begin
                        // UART started transmission
                        if (msg_index < MSG_LEN - 1) begin
                            msg_index <= msg_index + 1'b1;
                            state     <= ST_SEND;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
