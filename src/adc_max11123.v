//-----------------------------------------------------------------------------
// adc_max11123.v
// MAX11123 ADC SPI Interface - Free-run Single Channel Mode
//
// Based on Emard's VHDL implementation for ULX3S
// Simplified Verilog-2001 version for single channel continuous reading
//
// Author: Jelena Kovacevic (REGOC team)
// License: BSD
//-----------------------------------------------------------------------------

`timescale 1ns / 1ps
// MAX11123 is a 12-bit, 8-channel SAR ADC with SPI interface
//
// SPI Protocol (Mode 0: CPOL=0, CPHA=0):
// - CSN low to start transaction
// - Data shifted on SCLK rising edge
// - 16-bit words: 4-bit channel ID + 12-bit data
//
// Initialization sequence:
// 1. Reset (0x0040)
// 2. Config setup - echo on (0x8404)
// 3. Unipolar single-ended mode (0x8800)
// 4. Mode control - standard external clock (0x2386)
// 5. NULL words to read data
//-----------------------------------------------------------------------------

module adc_max11123 (
    input  wire        clk,           // System clock (25 MHz)
    input  wire        rst_n,         // Active low reset

    // SPI interface to MAX11123
    output reg         adc_csn,       // Chip select (active low)
    output reg         adc_sclk,      // SPI clock
    output reg         adc_mosi,      // Master out
    input  wire        adc_miso,      // Master in

    // Data output
    output reg  [11:0] adc_data,      // 12-bit ADC value
    output reg         adc_valid,     // Data valid pulse

    // Channel select (0-7)
    input  wire [2:0]  channel
);

    //-------------------------------------------------------------------------
    // Parameters - initialization commands for MAX11123
    //-------------------------------------------------------------------------
    localparam [15:0] CMD_RESET                = 16'h0040;  // Reset all registers
    localparam [15:0] CMD_CONFIG_SETUP         = 16'h8404;  // Echo on
    localparam [15:0] CMD_UNIPOLAR_SINGLE      = 16'h8800;  // Unipolar single-ended
    localparam [15:0] CMD_MODE_CTRL_STD_EXT    = 16'h2386;  // Standard external clock, 8-ch
    localparam [15:0] CMD_NULL                 = 16'h0000;  // Null word for reading

    // Number of init commands
    localparam INIT_SEQ_LEN = 5;

    //-------------------------------------------------------------------------
    // State machine states
    //-------------------------------------------------------------------------
    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_INIT       = 3'd1;
    localparam [2:0] S_CS_SETUP   = 3'd2;
    localparam [2:0] S_SHIFT      = 3'd3;
    localparam [2:0] S_CS_HOLD    = 3'd4;
    localparam [2:0] S_LATCH      = 3'd5;

    //-------------------------------------------------------------------------
    // Internal registers (r_ prefix per HDL guidelines)
    //-------------------------------------------------------------------------
    reg  [2:0]  r_state;
    reg  [2:0]  r_state_next;

    // SPI clock divider: 25 MHz / 16 = ~1.5 MHz SPI clock
    reg  [3:0]  r_clk_div;
    wire        w_sclk_rising;
    wire        w_sclk_falling;

    // Bit counter for 16-bit transfers
    reg  [4:0]  r_bit_cnt;

    // Init sequence counter
    reg  [2:0]  r_init_cnt;
    reg         r_init_done;

    // Shift register for SPI data
    reg  [15:0] r_tx_shift;
    reg  [15:0] r_rx_shift;

    // CS setup/hold counter
    reg  [3:0]  r_cs_cnt;

    // Channel ID from received data
    wire [3:0]  w_rx_channel;
    wire [11:0] w_rx_data;

    //-------------------------------------------------------------------------
    // Clock divider for SPI clock generation
    // Creates ~1.5 MHz SPI clock from 25 MHz system clock
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_clk_div <= 4'd0;
        end else begin
            r_clk_div <= r_clk_div + 4'd1;
        end
    end

    // SPI clock is bit 3 of divider (divide by 16)
    assign w_sclk_rising  = (r_clk_div == 4'b0111);  // Just before rising edge
    assign w_sclk_falling = (r_clk_div == 4'b1111);  // Just before falling edge

    //-------------------------------------------------------------------------
    // Initialization sequence ROM
    //-------------------------------------------------------------------------
    function [15:0] init_cmd;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: init_cmd = CMD_RESET;
                3'd1: init_cmd = CMD_CONFIG_SETUP;
                3'd2: init_cmd = CMD_UNIPOLAR_SINGLE;
                3'd3: init_cmd = CMD_MODE_CTRL_STD_EXT;
                3'd4: init_cmd = CMD_NULL;
                default: init_cmd = CMD_NULL;
            endcase
        end
    endfunction

    //-------------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_state     <= S_IDLE;
            r_init_cnt  <= 3'd0;
            r_init_done <= 1'b0;
            r_bit_cnt   <= 5'd0;
            r_cs_cnt    <= 4'd0;
            r_tx_shift  <= 16'd0;
            r_rx_shift  <= 16'd0;
            adc_csn     <= 1'b1;
            adc_sclk    <= 1'b0;
            adc_mosi    <= 1'b0;
            adc_data    <= 12'd0;
            adc_valid   <= 1'b0;
        end else begin
            // Default: clear valid pulse
            adc_valid <= 1'b0;

            case (r_state)
                //-------------------------------------------------------------
                // IDLE: Start initialization or continuous conversion
                //-------------------------------------------------------------
                S_IDLE: begin
                    adc_csn  <= 1'b1;
                    adc_sclk <= 1'b0;
                    if (w_sclk_falling) begin
                        r_state <= S_CS_SETUP;
                        r_cs_cnt <= 4'd0;
                        // Load command to transmit
                        if (!r_init_done) begin
                            r_tx_shift <= init_cmd(r_init_cnt);
                        end else begin
                            r_tx_shift <= CMD_NULL;  // Free-run: send NULLs
                        end
                    end
                end

                //-------------------------------------------------------------
                // CS_SETUP: Assert CS and wait setup time
                //-------------------------------------------------------------
                S_CS_SETUP: begin
                    adc_csn <= 1'b0;  // Assert chip select
                    if (w_sclk_falling) begin
                        r_cs_cnt <= r_cs_cnt + 4'd1;
                        if (r_cs_cnt >= 4'd1) begin  // ~1 SPI clock setup time
                            r_state   <= S_SHIFT;
                            r_bit_cnt <= 5'd0;
                            adc_mosi  <= r_tx_shift[15];  // MSB first
                        end
                    end
                end

                //-------------------------------------------------------------
                // SHIFT: Transfer 16 bits (clock in/out on edges)
                //-------------------------------------------------------------
                S_SHIFT: begin
                    if (w_sclk_rising) begin
                        // Rising edge: sample MISO
                        adc_sclk <= 1'b1;
                        r_rx_shift <= {r_rx_shift[14:0], adc_miso};
                    end

                    if (w_sclk_falling) begin
                        // Falling edge: shift out next bit
                        adc_sclk <= 1'b0;
                        r_bit_cnt <= r_bit_cnt + 5'd1;

                        if (r_bit_cnt >= 5'd15) begin
                            // Done with 16 bits
                            r_state  <= S_CS_HOLD;
                            r_cs_cnt <= 4'd0;
                        end else begin
                            // Shift TX data, output next bit
                            r_tx_shift <= {r_tx_shift[14:0], 1'b0};
                            adc_mosi   <= r_tx_shift[14];
                        end
                    end
                end

                //-------------------------------------------------------------
                // CS_HOLD: Deassert CS with hold time
                //-------------------------------------------------------------
                S_CS_HOLD: begin
                    if (w_sclk_falling) begin
                        r_cs_cnt <= r_cs_cnt + 4'd1;
                        if (r_cs_cnt >= 4'd1) begin
                            adc_csn <= 1'b1;  // Deassert CS
                            r_state <= S_LATCH;
                        end
                    end
                end

                //-------------------------------------------------------------
                // LATCH: Process received data, decide next action
                //-------------------------------------------------------------
                S_LATCH: begin
                    if (w_sclk_falling) begin
                        if (!r_init_done) begin
                            // Still in init sequence
                            r_init_cnt <= r_init_cnt + 3'd1;
                            if (r_init_cnt >= (INIT_SEQ_LEN - 1)) begin
                                r_init_done <= 1'b1;
                            end
                        end else begin
                            // Normal operation: latch ADC data
                            // Response format: [15:12]=channel, [11:0]=data
                            adc_data  <= r_rx_shift[11:0];
                            adc_valid <= 1'b1;
                        end
                        r_state <= S_IDLE;
                    end
                end

                default: begin
                    r_state <= S_IDLE;
                end
            endcase
        end
    end

    // Extract channel and data from received word (for debug/future use)
    assign w_rx_channel = r_rx_shift[15:12];
    assign w_rx_data    = r_rx_shift[11:0];

endmodule
