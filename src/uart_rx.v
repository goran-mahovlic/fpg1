// =============================================================================
// Module: uart_rx
// Description: UART Receiver with configurable baud rate
// =============================================================================
// FSM: 4-state Moore machine (IDLE -> START_BIT -> DATA_BITS -> STOP_BIT)
//
// Author: Jelena Kovacevic, REGOC team
// Date: 2026-02-11
//
// SPECIFICATIONS:
//   - Baud Rate: Configurable via parameter (default 115200)
//   - Data Bits: 8
//   - Stop Bits: 1
//   - Parity: None
//   - Oversampling: Samples at mid-bit (1/2 bit period)
//
// =============================================================================

`default_nettype none

module uart_rx #(
    parameter CLK_FREQ = 51000000,  // Input clock frequency in Hz
    parameter BAUD     = 115200    // Desired baud rate
)(
    input  wire       i_clk,        // System clock
    input  wire       i_rst_n,      // Active-low synchronous reset
    input  wire       i_rx,         // UART RX input (directly from pin)
    output reg  [7:0] o_data,       // Received data byte
    output reg        o_valid,      // Data valid strobe (1 cycle pulse)
    output wire       o_busy        // Receiving in progress
);
    // =========================================================================
    // Local Parameters
    // =========================================================================
    // Clocks per bit calculation: CLK_FREQ / BAUD
    // Example: 51000000 / 115200 = 443 clocks per bit
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD;

    // Half bit period for sampling at mid-bit
    localparam CLKS_HALF_BIT = CLKS_PER_BIT / 2;

    // FSM State Encoding (binary for 4 states)
    localparam [2:0] ST_IDLE      = 3'd0;  // Waiting for start bit
    localparam [2:0] ST_START_BIT = 3'd1;  // Verifying start bit at mid-point
    localparam [2:0] ST_DATA_BITS = 3'd2;  // Receiving 8 data bits LSB first
    localparam [2:0] ST_STOP_BIT  = 3'd3;  // Verifying stop bit

    // =========================================================================
    // Signal Declarations
    // =========================================================================
    reg [2:0]  r_state;      // FSM current state
    reg [7:0]  r_shift_reg;  // Shift register for received data
    reg [2:0]  r_bit_index;  // Current bit being received (0-7)
    reg [15:0] r_clk_count;  // Baud rate clock divider counter

    // Input synchronizer (2FF for metastability)
    (* ASYNC_REG = "TRUE" *) reg [1:0] r_rx_sync;
    wire w_rx = r_rx_sync[1];  // Synchronized RX signal

    // Busy flag
    assign o_busy = (r_state != ST_IDLE);

    // =========================================================================
    // Input Synchronizer (CDC: External pin -> clk domain)
    // =========================================================================
    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_rx_sync <= 2'b11;  // Idle state is high
        end else begin
            r_rx_sync <= {r_rx_sync[0], i_rx};
        end
    end

    // =========================================================================
    // Sequential Logic: UART RX FSM
    // =========================================================================
    always @(posedge i_clk) begin
        if (!i_rst_n) begin
            r_state     <= ST_IDLE;
            r_shift_reg <= 8'd0;
            r_bit_index <= 3'd0;
            r_clk_count <= 16'd0;
            o_data      <= 8'd0;
            o_valid     <= 1'b0;
        end else begin
            // Default: clear valid strobe
            o_valid <= 1'b0;

            case (r_state)
                ST_IDLE: begin
                    r_clk_count <= 16'd0;
                    r_bit_index <= 3'd0;

                    // Detect start bit (falling edge: high -> low)
                    if (w_rx == 1'b0) begin
                        r_state <= ST_START_BIT;
                    end
                end

                ST_START_BIT: begin
                    // Wait until mid-point of start bit to verify
                    if (r_clk_count < CLKS_HALF_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        r_clk_count <= 16'd0;
                        // Verify start bit is still low
                        if (w_rx == 1'b0) begin
                            r_state <= ST_DATA_BITS;
                        end else begin
                            // False start, return to idle
                            r_state <= ST_IDLE;
                        end
                    end
                end

                ST_DATA_BITS: begin
                    // Sample at mid-bit (wait full bit period from last sample)
                    if (r_clk_count < CLKS_PER_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        r_clk_count <= 16'd0;
                        // Shift in data bit LSB first
                        r_shift_reg <= {w_rx, r_shift_reg[7:1]};

                        if (r_bit_index < 7) begin
                            r_bit_index <= r_bit_index + 1'b1;
                        end else begin
                            r_state <= ST_STOP_BIT;
                        end
                    end
                end

                ST_STOP_BIT: begin
                    // Wait for stop bit period
                    if (r_clk_count < CLKS_PER_BIT - 1) begin
                        r_clk_count <= r_clk_count + 1'b1;
                    end else begin
                        // Output received byte (even if stop bit is wrong)
                        o_data  <= r_shift_reg;
                        o_valid <= 1'b1;
                        r_state <= ST_IDLE;
                    end
                end

                default: r_state <= ST_IDLE;  // Safe state recovery
            endcase
        end
    end

endmodule

`default_nettype wire  // Restore default for other modules
