// =============================================================================
// Module: serial_loader
// Description: Serial Loader for PDP-1 - Load programs via UART
// =============================================================================
// Author: Jelena Kovacevic, REGOC team
// Date: 2026-02-11
//
// PURPOSE:
//   Enables loading programs (HEX/RIM format) into PDP-1 RAM via UART without
//   rebuilding the FPGA bitstream. Also allows setting test_word and
//   test_address for CPU control.
//
// PROTOCOL:
//   Commands (1 byte):
//     'L' (0x4C) - Load mode: receive addr (2 bytes) + data (3 bytes = 18 bits)
//     'W' (0x57) - Write test_word (3 bytes = 18 bits)
//     'A' (0x41) - Write test_address (2 bytes = 12 bits)
//     'R' (0x52) - Run (start CPU at test_address)
//     'S' (0x53) - Stop (halt CPU)
//     'P' (0x50) - Ping (responds 'K' for OK)
//
//   Load format:
//     'L' + ADDR_HI + ADDR_LO + DATA_2 + DATA_1 + DATA_0
//     ADDR = 12-bit address (big endian, upper 4 bits ignored)
//     DATA = 18-bit word (big endian, 3 bytes, upper 6 bits ignored)
//
// BAUD RATE: 115200 (standard for ULX3S FTDI)
//
// =============================================================================

`default_nettype none

module serial_loader #(
    parameter CLK_FREQ = 51000000  // Clock frequency in Hz
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART interface (directly use existing FTDI pins)
    input  wire        uart_rx,      // FPGA receives from FTDI TX
    output wire        uart_tx,      // FPGA transmits to FTDI RX

    // RAM write interface
    output reg  [11:0] loader_addr,
    output reg  [17:0] loader_data,
    output reg         loader_we,

    // CPU control outputs
    output reg  [17:0] test_word,
    output reg  [11:0] test_address,
    output reg         cpu_run,
    output reg         cpu_halt,

    // Status
    output wire        loader_active,
    output wire [7:0]  debug_state
);

    // =========================================================================
    // Command Codes
    // =========================================================================
    localparam [7:0] CMD_LOAD      = 8'h4C;  // 'L' - Load word to RAM
    localparam [7:0] CMD_WRITE_TW  = 8'h57;  // 'W' - Write test_word
    localparam [7:0] CMD_WRITE_TA  = 8'h41;  // 'A' - Write test_address
    localparam [7:0] CMD_RUN       = 8'h52;  // 'R' - Run CPU
    localparam [7:0] CMD_STOP      = 8'h53;  // 'S' - Stop CPU
    localparam [7:0] CMD_PING      = 8'h50;  // 'P' - Ping (respond 'K')

    localparam [7:0] RSP_OK        = 8'h4B;  // 'K' - OK response

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_LOAD_ADDR1 = 4'd1;  // Receive address high byte
    localparam [3:0] ST_LOAD_ADDR2 = 4'd2;  // Receive address low byte
    localparam [3:0] ST_LOAD_DATA1 = 4'd3;  // Receive data byte 2 (MSB)
    localparam [3:0] ST_LOAD_DATA2 = 4'd4;  // Receive data byte 1
    localparam [3:0] ST_LOAD_DATA3 = 4'd5;  // Receive data byte 0 (LSB)
    localparam [3:0] ST_LOAD_WRITE = 4'd6;  // Write to RAM
    localparam [3:0] ST_TW_DATA1   = 4'd7;  // Receive test_word byte 2
    localparam [3:0] ST_TW_DATA2   = 4'd8;  // Receive test_word byte 1
    localparam [3:0] ST_TW_DATA3   = 4'd9;  // Receive test_word byte 0
    localparam [3:0] ST_TA_DATA1   = 4'd10; // Receive test_address byte 1
    localparam [3:0] ST_TA_DATA2   = 4'd11; // Receive test_address byte 0
    localparam [3:0] ST_RESPOND    = 4'd12; // Send response byte

    reg [3:0] r_state;

    // =========================================================================
    // UART RX Instance
    // =========================================================================
    wire [7:0] w_rx_data;
    wire       w_rx_valid;
    wire       w_rx_busy;

    uart_rx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (115200)
    ) u_uart_rx (
        .i_clk    (clk),
        .i_rst_n  (rst_n),
        .i_rx     (uart_rx),
        .o_data   (w_rx_data),
        .o_valid  (w_rx_valid),
        .o_busy   (w_rx_busy)
    );

    // =========================================================================
    // UART TX Instance
    // =========================================================================
    reg  [7:0] r_tx_data;
    reg        r_tx_send;
    wire       w_tx_busy;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (115200)
    ) u_uart_tx (
        .i_clk    (clk),
        .i_rst_n  (rst_n),
        .i_data   (r_tx_data),
        .i_send   (r_tx_send),
        .o_tx     (uart_tx),
        .o_busy   (w_tx_busy)
    );

    // =========================================================================
    // Data Registers
    // =========================================================================
    reg [7:0] r_addr_hi;
    reg [7:0] r_addr_lo;
    reg [7:0] r_data_2;
    reg [7:0] r_data_1;
    reg [7:0] r_data_0;

    // Status outputs
    assign loader_active = (r_state != ST_IDLE);
    assign debug_state   = {4'b0, r_state};

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            r_state       <= ST_IDLE;
            loader_addr   <= 12'd0;
            loader_data   <= 18'd0;
            loader_we     <= 1'b0;
            test_word     <= 18'd0;
            test_address  <= 12'o4;  // Default start address (Spacewar)
            cpu_run       <= 1'b0;
            cpu_halt      <= 1'b0;
            r_tx_data     <= 8'd0;
            r_tx_send     <= 1'b0;
            r_addr_hi     <= 8'd0;
            r_addr_lo     <= 8'd0;
            r_data_2      <= 8'd0;
            r_data_1      <= 8'd0;
            r_data_0      <= 8'd0;
        end else begin
            // Default: clear one-cycle signals
            loader_we <= 1'b0;
            cpu_run   <= 1'b0;
            cpu_halt  <= 1'b0;
            r_tx_send <= 1'b0;

            case (r_state)
                // ---------------------------------------------------------
                // IDLE: Wait for command byte
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (w_rx_valid) begin
                        case (w_rx_data)
                            CMD_LOAD: begin
                                r_state <= ST_LOAD_ADDR1;
                            end

                            CMD_WRITE_TW: begin
                                r_state <= ST_TW_DATA1;
                            end

                            CMD_WRITE_TA: begin
                                r_state <= ST_TA_DATA1;
                            end

                            CMD_RUN: begin
                                cpu_run <= 1'b1;
                                r_state <= ST_IDLE;
                            end

                            CMD_STOP: begin
                                cpu_halt <= 1'b1;
                                r_state  <= ST_IDLE;
                            end

                            CMD_PING: begin
                                r_tx_data <= RSP_OK;
                                r_state   <= ST_RESPOND;
                            end

                            default: begin
                                // Unknown command, ignore
                                r_state <= ST_IDLE;
                            end
                        endcase
                    end
                end

                // ---------------------------------------------------------
                // LOAD: Receive address and data, then write to RAM
                // ---------------------------------------------------------
                ST_LOAD_ADDR1: begin
                    if (w_rx_valid) begin
                        r_addr_hi <= w_rx_data;
                        r_state   <= ST_LOAD_ADDR2;
                    end
                end

                ST_LOAD_ADDR2: begin
                    if (w_rx_valid) begin
                        r_addr_lo <= w_rx_data;
                        r_state   <= ST_LOAD_DATA1;
                    end
                end

                ST_LOAD_DATA1: begin
                    if (w_rx_valid) begin
                        r_data_2 <= w_rx_data;
                        r_state  <= ST_LOAD_DATA2;
                    end
                end

                ST_LOAD_DATA2: begin
                    if (w_rx_valid) begin
                        r_data_1 <= w_rx_data;
                        r_state  <= ST_LOAD_DATA3;
                    end
                end

                ST_LOAD_DATA3: begin
                    if (w_rx_valid) begin
                        r_data_0 <= w_rx_data;
                        r_state  <= ST_LOAD_WRITE;
                    end
                end

                ST_LOAD_WRITE: begin
                    // Assemble address and data, write to RAM
                    loader_addr <= {r_addr_hi[3:0], r_addr_lo};  // 12-bit address
                    loader_data <= {r_data_2[1:0], r_data_1, r_data_0};  // 18-bit data
                    loader_we   <= 1'b1;
                    r_state     <= ST_IDLE;
                end

                // ---------------------------------------------------------
                // WRITE TEST_WORD: Receive 3 bytes (18 bits)
                // ---------------------------------------------------------
                ST_TW_DATA1: begin
                    if (w_rx_valid) begin
                        r_data_2 <= w_rx_data;
                        r_state  <= ST_TW_DATA2;
                    end
                end

                ST_TW_DATA2: begin
                    if (w_rx_valid) begin
                        r_data_1 <= w_rx_data;
                        r_state  <= ST_TW_DATA3;
                    end
                end

                ST_TW_DATA3: begin
                    if (w_rx_valid) begin
                        test_word <= {r_data_2[1:0], r_data_1, w_rx_data};
                        r_state   <= ST_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // WRITE TEST_ADDRESS: Receive 2 bytes (12 bits)
                // ---------------------------------------------------------
                ST_TA_DATA1: begin
                    if (w_rx_valid) begin
                        r_addr_hi <= w_rx_data;
                        r_state   <= ST_TA_DATA2;
                    end
                end

                ST_TA_DATA2: begin
                    if (w_rx_valid) begin
                        test_address <= {r_addr_hi[3:0], w_rx_data};
                        r_state      <= ST_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // RESPOND: Send response byte via UART TX
                // ---------------------------------------------------------
                ST_RESPOND: begin
                    if (!w_tx_busy) begin
                        r_tx_send <= 1'b1;
                        r_state   <= ST_IDLE;
                    end
                end

                default: r_state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire  // Restore default for other modules
