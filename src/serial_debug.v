// =============================================================================
// Serial Debug Module: UART TX for Debug Output
// =============================================================================
// TASK-DEBUG: Debug infrastructure for black screen problem - Kosjenka/REGOC team
// Author: Debug Team, REGOC
// Date: 2026-01-31
// Updated: 2026-02-02 (Best practices applied)
//
// DESCRIPTION:
//   Simple UART TX module for sending debug information to PC.
//   Sends ASCII string with debug data on each frame_tick.
//
// DEBUG OUTPUT FORMAT:
//   Frame Message: "F:xxxx PC:xxx I:xxxx D:xxxx V:vvvv X:zzz Y:www S:xx R\r\n"
//     F  = Frame counter (hex, 4 digits)
//     PC = CPU Program Counter (hex, 3 digits for 12-bit)
//     I  = Instruction count (hex, 4 digits)
//     D  = Display/IOT count (hex, 4 digits)
//     V  = pixel_valid count per frame (decimal, 4 digits)
//     X  = Pixel X coordinate (decimal, 3 digits)
//     Y  = Pixel Y coordinate (decimal, 3 digits)
//     S  = CPU state machine state (hex, 2 digits)
//     R  = Running indicator (R=running, .=halted)
//
//   Pixel Message: "P:xxxxx X:xxx Y:xxx B:x R:xxxx\r\n"
//     P  = Pixel count (decimal, 5 digits, wraps at 100000)
//     X  = Pixel X coordinate (decimal, 3 digits)
//     Y  = Pixel Y coordinate (decimal, 3 digits)
//     B  = Pixel brightness (0-7)
//     R  = Ring buffer write pointer (decimal, 4 digits)
//
// SPECIFICATIONS:
//   - Baud Rate: 115200
//   - Data Bits: 8
//   - Stop Bits: 1
//   - Parity: None
//   - Clock: 51 MHz (1024x768@50Hz pixel clock)
//   - Pin: ftdi_rxd (L4) - FPGA TX to PC
//
// SECURITY NOTE:
//   Debug output can be disabled via SW[1] (enable input).
//   When disabled, no serial data is transmitted.
//
// =============================================================================

`default_nettype none

// =============================================================================
// Module: uart_tx
// Description: UART transmitter with configurable baud rate
// FSM: 4-state Moore machine (IDLE -> START_BIT -> DATA_BITS -> STOP_BIT)
// =============================================================================
module uart_tx #(
    parameter CLK_FREQ = 25000000,  // Input clock frequency in Hz
    parameter BAUD     = 115200     // Desired baud rate
)(
    input  wire       i_clk,        // System clock
    input  wire       i_rst_n,      // Active-low synchronous reset
    input  wire [7:0] i_data,       // Data byte to transmit
    input  wire       i_send,       // Send strobe (pulse to start transmission)
    output reg        o_tx,         // UART TX output (directly to pin)
    output reg        o_busy        // Busy flag (high during transmission)
);
    // =========================================================================
    // Local Parameters
    // =========================================================================
    // Clocks per bit calculation: CLK_FREQ / BAUD
    // Example: 51000000 / 115200 = 443 clocks per bit
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;

    // FSM State Encoding (binary for 4 states)
    localparam [2:0] ST_IDLE      = 3'd0;  // Waiting for send command
    localparam [2:0] ST_START_BIT = 3'd1;  // Transmitting start bit (low)
    localparam [2:0] ST_DATA_BITS = 3'd2;  // Transmitting 8 data bits LSB first
    localparam [2:0] ST_STOP_BIT  = 3'd3;  // Transmitting stop bit (high)

    // =========================================================================
    // Signal Declarations
    // =========================================================================
    reg [2:0]  r_state;      // FSM current state
    reg [7:0]  r_shift_reg;  // Shift register for data bits
    reg [2:0]  r_bit_index;  // Current bit being transmitted (0-7)
    reg [15:0] r_clk_count;  // Baud rate clock divider counter

    // =========================================================================
    // Sequential Logic: UART TX FSM (Single-block style for compact FSM)
    // =========================================================================
    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_state     <= ST_IDLE;
            o_tx        <= 1'b1;  // UART idle state is high
            o_busy      <= 1'b0;
            r_shift_reg <= 8'd0;
            r_bit_index <= 3'd0;
            r_clk_count <= 16'd0;
        end else begin
            case (r_state)
                ST_IDLE: begin
                    o_tx   <= 1'b1;  // Maintain idle high
                    o_busy <= 1'b0;
                    if (i_send) begin
                        r_shift_reg <= i_data;
                        r_state     <= ST_START_BIT;
                        o_busy      <= 1'b1;
                        r_clk_count <= 16'd0;
                    end
                end

                ST_START_BIT: begin
                    o_tx <= 1'b0;  // Start bit is always low
                    if (r_clk_count < CLKS_PER_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        r_clk_count <= 16'd0;
                        r_bit_index <= 3'd0;
                        r_state     <= ST_DATA_BITS;
                    end
                end

                ST_DATA_BITS: begin
                    o_tx <= r_shift_reg[r_bit_index];  // LSB first
                    if (r_clk_count < CLKS_PER_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        r_clk_count <= 16'd0;
                        if (r_bit_index < 7) begin
                            r_bit_index <= r_bit_index + 1'b1;
                        end else begin
                            r_state <= ST_STOP_BIT;
                        end
                    end
                end

                ST_STOP_BIT: begin
                    o_tx <= 1'b1;  // Stop bit is always high
                    if (r_clk_count < CLKS_PER_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        r_state <= ST_IDLE;
                    end
                end

                default: r_state <= ST_IDLE;  // Safe state recovery
            endcase
        end
    end

endmodule

// =============================================================================
// Module: serial_debug
// Description: Debug wrapper that formats and sends diagnostic data via UART
// =============================================================================
module serial_debug #(
    parameter CLK_FREQ = 51_000_000  // Clock frequency in Hz (default: 51 MHz)
) (
    // Clock and Reset
    input  wire        i_clk,               // System clock (51 MHz)
    input  wire        i_rst_n,             // Active-low synchronous reset

    // Control
    input  wire        i_enable,            // Enable debug output (SW[1]: 0=disabled, 1=enabled)

    // Frame Timing
    input  wire        i_frame_tick,        // Pulse at start of each frame

    // Display Debug Inputs
    input  wire [7:0]  i_angle,             // Animation angle (legacy, unused)
    input  wire [9:0]  i_pixel_x,           // Current pixel X coordinate
    input  wire [9:0]  i_pixel_y,           // Current pixel Y coordinate
    input  wire        i_pixel_valid,       // Pixel valid strobe (unused)
    input  wire [7:0]  i_led_status,        // LED status for debug display

    // CRT Pipeline Debug
    input  wire        i_pixel_avail_synced,// Synced pixel available signal to CRT
    input  wire        i_crt_wren,          // CRT internal write enable
    input  wire [5:0]  i_crt_write_ptr,     // CRT FIFO write pointer
    input  wire [5:0]  i_crt_read_ptr,      // CRT FIFO read pointer
    input  wire [10:0] i_search_counter_msb,// Search counter MSBs
    input  wire [11:0] i_luma1,             // Luma from ring buffer output
    input  wire [15:0] i_rowbuff_write_count, // Non-zero pixels written per frame

    // CPU Debug Inputs
    input  wire [11:0] i_cpu_pc,            // CPU Program Counter (12-bit)
    input  wire [15:0] i_cpu_instr_count,   // CPU instructions executed
    input  wire [15:0] i_cpu_iot_count,     // CPU IOT (display) instructions
    input  wire        i_cpu_running,       // CPU running flag
    input  wire [7:0]  i_cpu_state,         // CPU state machine state (8-bit)

    // Pixel Debug Inputs (per-pixel tracking)
    input  wire [31:0] i_pixel_count,       // Total pixel count from CPU
    input  wire [9:0]  i_pixel_debug_x,     // Pixel X coordinate
    input  wire [9:0]  i_pixel_debug_y,     // Pixel Y coordinate
    input  wire [2:0]  i_pixel_brightness,  // Pixel brightness (0-7)
    input  wire        i_pixel_shift_out,   // Pixel output strobe
    input  wire [9:0]  i_ring_buffer_wrptr, // Ring buffer write pointer

    // UART Output
    output wire        o_uart_tx            // UART TX pin (directly to FTDI)
);

    // =========================================================================
    // UART TX Instance
    // =========================================================================
    reg  [7:0] r_tx_data;   // Data byte to send
    reg        r_tx_send;   // Send strobe
    wire       w_tx_busy;   // UART busy flag

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),  // Use module parameter
        .BAUD     (115200)     // Standard baud rate
    ) u_uart_tx (
        .i_clk    (i_clk),
        .i_rst_n  (i_rst_n),
        .i_data   (r_tx_data),
        .i_send   (r_tx_send),
        .o_tx     (o_uart_tx),
        .o_busy   (w_tx_busy)
    );

    // =========================================================================
    // Frame Counter
    // =========================================================================
    reg [15:0] r_frame_counter;

    always @(posedge i_clk) begin
        if (!i_rst_n)
            r_frame_counter <= 16'd0;
        else if (i_frame_tick)
            r_frame_counter <= r_frame_counter + 1'b1;
    end

    // =========================================================================
    // Latched Values (captured on frame_tick)
    // =========================================================================
    reg [7:0]  r_latched_angle;
    reg [9:0]  r_latched_x;
    reg [9:0]  r_latched_y;
    reg [15:0] r_latched_frame;
    reg [7:0]  r_latched_led;
    reg [5:0]  r_latched_write_ptr;
    reg [5:0]  r_latched_read_ptr;
    reg [10:0] r_latched_search_cnt;
    reg [11:0] r_latched_luma1;

    // Event counters (pixel_valid and crt_wren per frame)
    reg [15:0] r_pv_count;           // pixel_valid count this frame
    reg [15:0] r_wren_count;         // crt_wren count this frame
    reg [15:0] r_latched_pv_count;   // Latched pixel_valid count
    reg [15:0] r_latched_wren_count; // Latched crt_wren count
    reg [15:0] r_latched_rowbuff_count;

    // CPU debug latches
    reg [11:0] r_latched_pc;
    reg [15:0] r_latched_instr_count;
    reg [15:0] r_latched_iot_count;
    reg        r_latched_running;
    reg [7:0]  r_latched_cpu_state;

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_latched_angle     <= 8'd0;
            r_latched_x         <= 10'd0;
            r_latched_y         <= 10'd0;
            r_latched_frame     <= 16'd0;
            r_latched_led       <= 8'd0;
            r_latched_write_ptr <= 6'd0;
            r_latched_read_ptr  <= 6'd0;
            r_latched_search_cnt <= 11'd0;
            r_latched_luma1     <= 12'd0;
            r_pv_count          <= 16'd0;
            r_wren_count        <= 16'd0;
            r_latched_pv_count  <= 16'd0;
            r_latched_wren_count <= 16'd0;
            r_latched_rowbuff_count <= 16'd0;
            // CPU debug init
            r_latched_pc          <= 12'd0;
            r_latched_instr_count <= 16'd0;
            r_latched_iot_count   <= 16'd0;
            r_latched_running     <= 1'b0;
            r_latched_cpu_state   <= 8'd0;
        end else begin
            // Count events during frame
            if (i_pixel_avail_synced)
                r_pv_count <= r_pv_count + 1'b1;
            if (i_crt_wren)
                r_wren_count <= r_wren_count + 1'b1;

            // Latch all values on frame_tick
            if (i_frame_tick) begin
                r_latched_angle     <= i_angle;
                r_latched_x         <= i_pixel_x;
                r_latched_y         <= i_pixel_y;
                r_latched_frame     <= r_frame_counter;
                r_latched_led       <= i_led_status;
                r_latched_write_ptr <= i_crt_write_ptr;
                r_latched_read_ptr  <= i_crt_read_ptr;
                r_latched_search_cnt <= i_search_counter_msb;
                r_latched_luma1     <= i_luma1;
                // Latch and reset per-frame counters
                r_latched_pv_count  <= r_pv_count;
                r_latched_wren_count <= r_wren_count;
                r_latched_rowbuff_count <= i_rowbuff_write_count;
                r_pv_count          <= 16'd0;
                r_wren_count        <= 16'd0;
                // Latch CPU debug values
                r_latched_pc          <= i_cpu_pc;
                r_latched_instr_count <= i_cpu_instr_count;
                r_latched_iot_count   <= i_cpu_iot_count;
                r_latched_running     <= i_cpu_running;
                r_latched_cpu_state   <= i_cpu_state;
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
    // Message Buffer and FSM State
    // =========================================================================
    // Frame Message Length: 57 characters (was 52, +5 for " S:xx")
    // Pixel Message Length: 32 characters (28 + CR/LF + padding)
    localparam MSG_LEN       = 57;
    localparam PIXEL_MSG_LEN = 28;

    reg [7:0] r_msg_buffer [0:MSG_LEN-1];  // Message character buffer
    reg [5:0] r_msg_index;                 // Current character index
    reg       r_sending;                   // Unused - kept for compatibility
    reg       r_frame_tick_d;              // Delayed frame_tick for edge detection

    // Pixel debug state registers
    reg        r_pixel_shift_d;            // Delayed pixel_shift for edge detection
    reg        r_pixel_msg_pending;        // Pixel message waiting to be sent
    reg [31:0] r_latched_pixel_count;      // Latched pixel count
    reg [9:0]  r_latched_pixel_x;          // Latched pixel X
    reg [9:0]  r_latched_pixel_y;          // Latched pixel Y
    reg [2:0]  r_latched_pixel_brightness; // Latched pixel brightness
    reg [9:0]  r_latched_ring_wrptr;       // Latched ring buffer write pointer
    reg        r_sending_pixel_msg;        // Currently sending pixel (not frame) msg

    // =========================================================================
    // Decimal Conversion Wires (Combinational)
    // =========================================================================
    // Frame X/Y coordinates (0-639 range)
    wire [3:0] w_x_hundreds = r_latched_x / 100;
    wire [3:0] w_x_tens     = (r_latched_x / 10) % 10;
    wire [3:0] w_x_units    = r_latched_x % 10;

    wire [3:0] w_y_hundreds = r_latched_y / 100;
    wire [3:0] w_y_tens     = (r_latched_y / 10) % 10;
    wire [3:0] w_y_units    = r_latched_y % 10;

    // Per-frame counters (0-9999 range)
    wire [3:0] w_pv_thousands = r_latched_pv_count / 1000;
    wire [3:0] w_pv_hundreds  = (r_latched_pv_count / 100) % 10;
    wire [3:0] w_pv_tens      = (r_latched_pv_count / 10) % 10;
    wire [3:0] w_pv_units     = r_latched_pv_count % 10;

    wire [3:0] w_wr_thousands = r_latched_wren_count / 1000;
    wire [3:0] w_wr_hundreds  = (r_latched_wren_count / 100) % 10;
    wire [3:0] w_wr_tens      = (r_latched_wren_count / 10) % 10;
    wire [3:0] w_wr_units     = r_latched_wren_count % 10;

    // Rowbuffer write count (0-9999 range)
    wire [3:0] w_rb_thousands = r_latched_rowbuff_count / 1000;
    wire [3:0] w_rb_hundreds  = (r_latched_rowbuff_count / 100) % 10;
    wire [3:0] w_rb_tens      = (r_latched_rowbuff_count / 10) % 10;
    wire [3:0] w_rb_units     = r_latched_rowbuff_count % 10;

    // =========================================================================
    // Pixel Debug: Decimal Conversion (5 digits, wraps at 100000)
    // =========================================================================
    wire [16:0] w_pixel_count_mod = r_latched_pixel_count % 100000;
    wire [3:0] w_pc_ten_thousands = w_pixel_count_mod / 10000;
    wire [3:0] w_pc_thousands     = (w_pixel_count_mod / 1000) % 10;
    wire [3:0] w_pc_hundreds      = (w_pixel_count_mod / 100) % 10;
    wire [3:0] w_pc_tens          = (w_pixel_count_mod / 10) % 10;
    wire [3:0] w_pc_units         = w_pixel_count_mod % 10;

    // Pixel X coordinate (3 digits, 0-999)
    wire [3:0] w_px_hundreds = r_latched_pixel_x / 100;
    wire [3:0] w_px_tens     = (r_latched_pixel_x / 10) % 10;
    wire [3:0] w_px_units    = r_latched_pixel_x % 10;

    // Pixel Y coordinate (3 digits, 0-999)
    wire [3:0] w_py_hundreds = r_latched_pixel_y / 100;
    wire [3:0] w_py_tens     = (r_latched_pixel_y / 10) % 10;
    wire [3:0] w_py_units    = r_latched_pixel_y % 10;

    // Ring buffer write pointer (4 digits, 0-1023)
    wire [3:0] w_rw_thousands = r_latched_ring_wrptr / 1000;
    wire [3:0] w_rw_hundreds  = (r_latched_ring_wrptr / 100) % 10;
    wire [3:0] w_rw_tens      = (r_latched_ring_wrptr / 10) % 10;
    wire [3:0] w_rw_units     = r_latched_ring_wrptr % 10;

    // =========================================================================
    // Message Sending FSM
    // FSM: 3-state machine (IDLE -> SEND -> WAIT)
    // =========================================================================
    localparam [1:0] ST_MSG_IDLE = 2'd0;  // Waiting for trigger
    localparam [1:0] ST_MSG_SEND = 2'd2;  // Loading byte to UART
    localparam [1:0] ST_MSG_WAIT = 2'd3;  // Waiting for UART busy

    reg [1:0] r_msg_state;

    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_msg_state              <= ST_MSG_IDLE;
            r_msg_index              <= 6'd0;
            r_sending                <= 1'b0;
            r_tx_send                <= 1'b0;
            r_tx_data                <= 8'd0;
            r_frame_tick_d           <= 1'b0;
            r_pixel_shift_d          <= 1'b0;
            r_pixel_msg_pending      <= 1'b0;
            r_sending_pixel_msg      <= 1'b0;
            r_latched_pixel_count    <= 32'd0;
            r_latched_pixel_x        <= 10'd0;
            r_latched_pixel_y        <= 10'd0;
            r_latched_pixel_brightness <= 3'd0;
            r_latched_ring_wrptr     <= 10'd0;
        end else begin
            // Edge detection for triggers
            r_frame_tick_d  <= i_frame_tick;
            r_pixel_shift_d <= i_pixel_shift_out;
            r_tx_send       <= 1'b0;  // Default: no send

            // Latch pixel data on pixel_shift_out rising edge
            if (i_pixel_shift_out && !r_pixel_shift_d) begin
                r_latched_pixel_count    <= i_pixel_count;
                r_latched_pixel_x        <= i_pixel_debug_x;
                r_latched_pixel_y        <= i_pixel_debug_y;
                r_latched_pixel_brightness <= i_pixel_brightness;
                r_latched_ring_wrptr     <= i_ring_buffer_wrptr;
                r_pixel_msg_pending      <= 1'b1;
            end

            case (r_msg_state)
                ST_MSG_IDLE: begin
                    // Skip processing when disabled (saves power/timing)
                    if (!i_enable) begin
                        r_pixel_msg_pending <= 1'b0;
                    end
                    // Priority 1: Pixel debug message
                    else if (r_pixel_msg_pending) begin
                        // Format: "P:xxxxx X:xxx Y:xxx B:x R:xxxx\r\n"
                        r_msg_buffer[0]  <= "P";
                        r_msg_buffer[1]  <= ":";
                        r_msg_buffer[2]  <= digit_to_ascii(w_pc_ten_thousands);
                        r_msg_buffer[3]  <= digit_to_ascii(w_pc_thousands);
                        r_msg_buffer[4]  <= digit_to_ascii(w_pc_hundreds);
                        r_msg_buffer[5]  <= digit_to_ascii(w_pc_tens);
                        r_msg_buffer[6]  <= digit_to_ascii(w_pc_units);
                        r_msg_buffer[7]  <= " ";
                        r_msg_buffer[8]  <= "X";
                        r_msg_buffer[9]  <= ":";
                        r_msg_buffer[10] <= digit_to_ascii(w_px_hundreds);
                        r_msg_buffer[11] <= digit_to_ascii(w_px_tens);
                        r_msg_buffer[12] <= digit_to_ascii(w_px_units);
                        r_msg_buffer[13] <= " ";
                        r_msg_buffer[14] <= "Y";
                        r_msg_buffer[15] <= ":";
                        r_msg_buffer[16] <= digit_to_ascii(w_py_hundreds);
                        r_msg_buffer[17] <= digit_to_ascii(w_py_tens);
                        r_msg_buffer[18] <= digit_to_ascii(w_py_units);
                        r_msg_buffer[19] <= " ";
                        r_msg_buffer[20] <= "B";
                        r_msg_buffer[21] <= ":";
                        r_msg_buffer[22] <= digit_to_ascii({1'b0, r_latched_pixel_brightness});
                        r_msg_buffer[23] <= " ";
                        r_msg_buffer[24] <= "R";
                        r_msg_buffer[25] <= ":";
                        r_msg_buffer[26] <= digit_to_ascii(w_rw_thousands);
                        r_msg_buffer[27] <= digit_to_ascii(w_rw_hundreds);
                        r_msg_buffer[28] <= digit_to_ascii(w_rw_tens);
                        r_msg_buffer[29] <= digit_to_ascii(w_rw_units);
                        r_msg_buffer[30] <= 8'd13;  // CR
                        r_msg_buffer[31] <= 8'd10;  // LF

                        r_msg_index         <= 6'd0;
                        r_sending_pixel_msg <= 1'b1;
                        r_pixel_msg_pending <= 1'b0;
                        r_msg_state         <= ST_MSG_SEND;
                    end
                    // Priority 2: Frame info message on rising edge
                    else if (i_frame_tick && !r_frame_tick_d) begin
                        // Format: "F:xxxx PC:xxx I:xxxx D:xxxx V:vvvv X:zzz Y:www S:xx R\r\n"
                        r_msg_buffer[0]  <= "F";
                        r_msg_buffer[1]  <= ":";
                        r_msg_buffer[2]  <= hex_to_ascii(r_latched_frame[15:12]);
                        r_msg_buffer[3]  <= hex_to_ascii(r_latched_frame[11:8]);
                        r_msg_buffer[4]  <= hex_to_ascii(r_latched_frame[7:4]);
                        r_msg_buffer[5]  <= hex_to_ascii(r_latched_frame[3:0]);
                        r_msg_buffer[6]  <= " ";
                        r_msg_buffer[7]  <= "P";
                        r_msg_buffer[8]  <= "C";
                        r_msg_buffer[9]  <= ":";
                        r_msg_buffer[10] <= hex_to_ascii(r_latched_pc[11:8]);
                        r_msg_buffer[11] <= hex_to_ascii(r_latched_pc[7:4]);
                        r_msg_buffer[12] <= hex_to_ascii(r_latched_pc[3:0]);
                        r_msg_buffer[13] <= " ";
                        r_msg_buffer[14] <= "I";
                        r_msg_buffer[15] <= ":";
                        r_msg_buffer[16] <= hex_to_ascii(r_latched_instr_count[15:12]);
                        r_msg_buffer[17] <= hex_to_ascii(r_latched_instr_count[11:8]);
                        r_msg_buffer[18] <= hex_to_ascii(r_latched_instr_count[7:4]);
                        r_msg_buffer[19] <= hex_to_ascii(r_latched_instr_count[3:0]);
                        r_msg_buffer[20] <= " ";
                        r_msg_buffer[21] <= "D";
                        r_msg_buffer[22] <= ":";
                        r_msg_buffer[23] <= hex_to_ascii(r_latched_iot_count[15:12]);
                        r_msg_buffer[24] <= hex_to_ascii(r_latched_iot_count[11:8]);
                        r_msg_buffer[25] <= hex_to_ascii(r_latched_iot_count[7:4]);
                        r_msg_buffer[26] <= hex_to_ascii(r_latched_iot_count[3:0]);
                        r_msg_buffer[27] <= " ";
                        r_msg_buffer[28] <= "V";
                        r_msg_buffer[29] <= ":";
                        r_msg_buffer[30] <= digit_to_ascii(w_pv_thousands);
                        r_msg_buffer[31] <= digit_to_ascii(w_pv_hundreds);
                        r_msg_buffer[32] <= digit_to_ascii(w_pv_tens);
                        r_msg_buffer[33] <= digit_to_ascii(w_pv_units);
                        r_msg_buffer[34] <= " ";
                        r_msg_buffer[35] <= "X";
                        r_msg_buffer[36] <= ":";
                        r_msg_buffer[37] <= digit_to_ascii(w_x_hundreds);
                        r_msg_buffer[38] <= digit_to_ascii(w_x_tens);
                        r_msg_buffer[39] <= digit_to_ascii(w_x_units);
                        r_msg_buffer[40] <= " ";
                        r_msg_buffer[41] <= "Y";
                        r_msg_buffer[42] <= ":";
                        r_msg_buffer[43] <= digit_to_ascii(w_y_hundreds);
                        r_msg_buffer[44] <= digit_to_ascii(w_y_tens);
                        r_msg_buffer[45] <= digit_to_ascii(w_y_units);
                        r_msg_buffer[46] <= " ";
                        r_msg_buffer[47] <= "S";
                        r_msg_buffer[48] <= ":";
                        r_msg_buffer[49] <= hex_to_ascii(r_latched_cpu_state[7:4]);
                        r_msg_buffer[50] <= hex_to_ascii(r_latched_cpu_state[3:0]);
                        r_msg_buffer[51] <= " ";
                        r_msg_buffer[52] <= r_latched_running ? "R" : ".";
                        r_msg_buffer[53] <= " ";
                        r_msg_buffer[54] <= 8'd13;  // CR
                        r_msg_buffer[55] <= 8'd10;  // LF
                        r_msg_buffer[56] <= 8'd0;   // Padding

                        r_msg_index         <= 6'd0;
                        r_sending_pixel_msg <= 1'b0;
                        r_msg_state         <= ST_MSG_SEND;
                    end
                end

                ST_MSG_SEND: begin
                    if (!w_tx_busy) begin
                        r_tx_data   <= r_msg_buffer[r_msg_index];
                        r_tx_send   <= 1'b1;
                        r_msg_state <= ST_MSG_WAIT;
                    end
                end

                ST_MSG_WAIT: begin
                    if (w_tx_busy) begin
                        // Check message length based on type
                        if (r_sending_pixel_msg) begin
                            if (r_msg_index < PIXEL_MSG_LEN + 3) begin
                                r_msg_index <= r_msg_index + 1'b1;
                                r_msg_state <= ST_MSG_SEND;
                            end else begin
                                r_msg_state <= ST_MSG_IDLE;
                            end
                        end else begin
                            if (r_msg_index < MSG_LEN - 1) begin
                                r_msg_index <= r_msg_index + 1'b1;
                                r_msg_state <= ST_MSG_SEND;
                            end else begin
                                r_msg_state <= ST_MSG_IDLE;
                            end
                        end
                    end
                end

                default: r_msg_state <= ST_MSG_IDLE;  // Safe state recovery
            endcase
        end
    end

endmodule

`default_nettype wire  // Restore default for other modules
