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
    // Additional debug signals
    input  wire        pixel_avail_synced,  // Synced signal going to CRT
    input  wire        crt_wren,            // CRT internal write enable
    input  wire [5:0]  crt_write_ptr,       // CRT FIFO write pointer
    input  wire [5:0]  crt_read_ptr,        // CRT FIFO read pointer
    input  wire [10:0] search_counter_msb,  // Search counter MSBs
    input  wire [11:0] luma1,               // Luma from ring buffer output
    input  wire [15:0] rowbuff_write_count, // Non-zero pixels written to rowbuffer per frame
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
    reg [5:0]  latched_write_ptr;
    reg [5:0]  latched_read_ptr;
    reg [10:0] latched_search_cnt;
    reg [11:0] latched_luma1;

    // Count pixel_valid and crt_wren events per frame
    reg [15:0] pv_count;      // pixel_valid count this frame
    reg [15:0] wren_count;    // crt_wren count this frame
    reg [15:0] latched_pv_count;
    reg [15:0] latched_wren_count;
    reg [15:0] latched_rowbuff_count;

    always @(posedge clk) begin
        if (!rst_n) begin
            latched_angle <= 8'd0;
            latched_x     <= 10'd0;
            latched_y     <= 10'd0;
            latched_frame <= 16'd0;
            latched_led   <= 8'd0;
            latched_write_ptr <= 6'd0;
            latched_read_ptr  <= 6'd0;
            latched_search_cnt <= 11'd0;
            latched_luma1 <= 12'd0;
            pv_count <= 16'd0;
            wren_count <= 16'd0;
            latched_pv_count <= 16'd0;
            latched_wren_count <= 16'd0;
            latched_rowbuff_count <= 16'd0;
        end else begin
            // Count events
            if (pixel_avail_synced)
                pv_count <= pv_count + 1'b1;
            if (crt_wren)
                wren_count <= wren_count + 1'b1;

            if (frame_tick) begin
                latched_angle <= angle;
                latched_x     <= pixel_x;
                latched_y     <= pixel_y;
                latched_frame <= frame_counter;
                latched_led   <= led_status;
                latched_write_ptr <= crt_write_ptr;
                latched_read_ptr  <= crt_read_ptr;
                latched_search_cnt <= search_counter_msb;
                latched_luma1 <= luma1;
                // Latch and reset counters
                latched_pv_count <= pv_count;
                latched_wren_count <= wren_count;
                latched_rowbuff_count <= rowbuff_write_count;
                pv_count <= 16'd0;
                wren_count <= 16'd0;
            end
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
    // Message buffer - "F:xxxx X:zzz Y:www V:vvvv W:wwww L:lll PP LED:bbbbbbbb\n"
    // =========================================================================
    // Format: Frame, X, Y, Valid count, Rowbuff Write count, Luma1 MSB, LED status
    // W:xxxx je 6 znakova umjesto S:xxx (5 znakova) = 1 znak vise
    // Total 56 characters

    localparam MSG_LEN = 56;

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

    // Decimal conversion for pv_count and wren_count (0-9999 range)
    wire [3:0] pv_thousands = latched_pv_count / 1000;
    wire [3:0] pv_hundreds  = (latched_pv_count / 100) % 10;
    wire [3:0] pv_tens      = (latched_pv_count / 10) % 10;
    wire [3:0] pv_units     = latched_pv_count % 10;

    wire [3:0] wr_thousands = latched_wren_count / 1000;
    wire [3:0] wr_hundreds  = (latched_wren_count / 100) % 10;
    wire [3:0] wr_tens      = (latched_wren_count / 10) % 10;
    wire [3:0] wr_units     = latched_wren_count % 10;

    // Decimal conversion for rowbuff_write_count (0-9999 range)
    wire [3:0] rb_thousands = latched_rowbuff_count / 1000;
    wire [3:0] rb_hundreds  = (latched_rowbuff_count / 100) % 10;
    wire [3:0] rb_tens      = (latched_rowbuff_count / 10) % 10;
    wire [3:0] rb_units     = latched_rowbuff_count % 10;

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
            msg_index          <= 6'd0;
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
                        // Format: "F:xxxx X:zzz Y:www V:vvvv S:sss L:lll\n"
                        msg_buffer[0]  <= "F";
                        msg_buffer[1]  <= ":";
                        msg_buffer[2]  <= hex_to_ascii(latched_frame[15:12]);
                        msg_buffer[3]  <= hex_to_ascii(latched_frame[11:8]);
                        msg_buffer[4]  <= hex_to_ascii(latched_frame[7:4]);
                        msg_buffer[5]  <= hex_to_ascii(latched_frame[3:0]);
                        msg_buffer[6]  <= " ";
                        msg_buffer[7]  <= "X";
                        msg_buffer[8]  <= ":";
                        msg_buffer[9]  <= digit_to_ascii(x_hundreds);
                        msg_buffer[10] <= digit_to_ascii(x_tens);
                        msg_buffer[11] <= digit_to_ascii(x_units);
                        msg_buffer[12] <= " ";
                        msg_buffer[13] <= "Y";
                        msg_buffer[14] <= ":";
                        msg_buffer[15] <= digit_to_ascii(y_hundreds);
                        msg_buffer[16] <= digit_to_ascii(y_tens);
                        msg_buffer[17] <= digit_to_ascii(y_units);
                        msg_buffer[18] <= " ";
                        // V: pixel_valid count per frame
                        msg_buffer[19] <= "V";
                        msg_buffer[20] <= ":";
                        msg_buffer[21] <= digit_to_ascii(pv_thousands);
                        msg_buffer[22] <= digit_to_ascii(pv_hundreds);
                        msg_buffer[23] <= digit_to_ascii(pv_tens);
                        msg_buffer[24] <= digit_to_ascii(pv_units);
                        msg_buffer[25] <= " ";
                        // W: rowbuffer non-zero write count per frame (decimal, 4 digits)
                        msg_buffer[26] <= "W";
                        msg_buffer[27] <= ":";
                        msg_buffer[28] <= digit_to_ascii(rb_thousands);
                        msg_buffer[29] <= digit_to_ascii(rb_hundreds);
                        msg_buffer[30] <= digit_to_ascii(rb_tens);
                        msg_buffer[31] <= digit_to_ascii(rb_units);
                        msg_buffer[32] <= " ";
                        // L: luma1 (hex, 3 digits for 12 bits)
                        msg_buffer[33] <= "L";
                        msg_buffer[34] <= ":";
                        msg_buffer[35] <= hex_to_ascii(latched_luma1[11:8]);
                        msg_buffer[36] <= hex_to_ascii(latched_luma1[7:4]);
                        msg_buffer[37] <= hex_to_ascii(latched_luma1[3:0]);
                        msg_buffer[38] <= " ";
                        // P: write_ptr (hex)
                        msg_buffer[39] <= hex_to_ascii(latched_write_ptr[5:4]);
                        msg_buffer[40] <= hex_to_ascii(latched_write_ptr[3:0]);
                        msg_buffer[41] <= " ";
                        // LED: binary status (8 bits as ASCII 0/1)
                        msg_buffer[42] <= "L";
                        msg_buffer[43] <= "E";
                        msg_buffer[44] <= "D";
                        msg_buffer[45] <= ":";
                        msg_buffer[46] <= latched_led[7] ? "1" : "0";
                        msg_buffer[47] <= latched_led[6] ? "1" : "0";
                        msg_buffer[48] <= latched_led[5] ? "1" : "0";
                        msg_buffer[49] <= latched_led[4] ? "1" : "0";
                        msg_buffer[50] <= latched_led[3] ? "1" : "0";
                        msg_buffer[51] <= latched_led[2] ? "1" : "0";
                        msg_buffer[52] <= latched_led[1] ? "1" : "0";
                        msg_buffer[53] <= latched_led[0] ? "1" : "0";
                        msg_buffer[54] <= 8'd13;  // '\r' (CR)
                        msg_buffer[55] <= 8'd10;  // '\n' (LF)

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
