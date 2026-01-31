//////////////////////////////////////////////////////////////////////////////
// ESP32 SPI Slave Module
// Author: Jelena Kovacevic
// Date: 2026-01-31
//
// Description:
//   SPI slave module for ESP32 <-> FPGA communication
//   - SPI Mode 0 (CPOL=0, CPHA=0)
//   - Clock: 10 MHz max (SPI), 50 MHz system clock
//   - 8-bit words, MSB first
//   - CS active low
//   - Clock Domain Crossing (CDC) to 50 MHz system clock
//
//////////////////////////////////////////////////////////////////////////////

module esp32_spi_slave (
    input         clk_sys,        // 50 MHz system clock
    input         rst_n,
    // SPI pins
    input         spi_clk,
    input         spi_mosi,
    output reg    spi_miso,
    input         spi_cs_n,
    // Internal interface
    output reg [7:0] rx_data,
    output reg       rx_valid,
    input      [7:0] tx_data,
    input            tx_load,
    output reg       busy
);

    //=========================================================================
    // Clock Domain Crossing (CDC) - Triple synchronizers
    //=========================================================================

    // SPI clock synchronizer (3-stage for edge detection)
    reg [2:0] spi_clk_sync;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            spi_clk_sync <= 3'b000;
        else
            spi_clk_sync <= {spi_clk_sync[1:0], spi_clk};
    end

    // Edge detection for SPI clock
    wire spi_clk_rising  = (spi_clk_sync[2:1] == 2'b01);
    wire spi_clk_falling = (spi_clk_sync[2:1] == 2'b10);

    // SPI CS synchronizer (3-stage)
    reg [2:0] spi_cs_sync;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            spi_cs_sync <= 3'b111;  // CS inactive (high) on reset
        else
            spi_cs_sync <= {spi_cs_sync[1:0], spi_cs_n};
    end

    wire cs_active = ~spi_cs_sync[2];  // CS is active low

    // CS edge detection for frame boundaries
    reg cs_active_d;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            cs_active_d <= 1'b0;
        else
            cs_active_d <= cs_active;
    end

    wire cs_rising_edge  = cs_active & ~cs_active_d;   // Start of transaction
    wire cs_falling_edge = ~cs_active & cs_active_d;   // End of transaction

    // MOSI synchronizer (2-stage)
    reg [1:0] spi_mosi_sync;
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            spi_mosi_sync <= 2'b00;
        else
            spi_mosi_sync <= {spi_mosi_sync[0], spi_mosi};
    end

    wire mosi_synced = spi_mosi_sync[1];

    //=========================================================================
    // Bit Counter
    //=========================================================================

    reg [2:0] bit_cnt;  // 0-7 for 8 bits

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            bit_cnt <= 3'd0;
        else if (!cs_active)
            bit_cnt <= 3'd0;  // Reset on CS inactive
        else if (spi_clk_rising)
            bit_cnt <= bit_cnt + 3'd1;  // Wraps automatically
    end

    // Detect when byte is complete (after 8th bit received)
    wire byte_complete = spi_clk_rising && (bit_cnt == 3'd7);

    //=========================================================================
    // RX Shift Register - Sample MOSI on rising edge (Mode 0)
    //=========================================================================

    reg [7:0] rx_shift;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            rx_shift <= 8'h00;
        else if (!cs_active)
            rx_shift <= 8'h00;
        else if (spi_clk_rising)
            rx_shift <= {rx_shift[6:0], mosi_synced};  // MSB first
    end

    //=========================================================================
    // RX Data Output & Valid
    //=========================================================================

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= 8'h00;
            rx_valid <= 1'b0;
        end
        else begin
            rx_valid <= 1'b0;  // Default: deassert after one clock

            if (byte_complete) begin
                rx_data  <= {rx_shift[6:0], mosi_synced};  // Capture complete byte
                rx_valid <= 1'b1;
            end
        end
    end

    //=========================================================================
    // TX Shift Register - Output MISO on falling edge (Mode 0)
    //=========================================================================

    reg [7:0] tx_shift;
    reg       tx_loaded;  // Flag to track if TX data was loaded

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift  <= 8'h00;
            tx_loaded <= 1'b0;
        end
        else if (!cs_active) begin
            // Load TX data when CS goes inactive (prepare for next transaction)
            tx_shift  <= 8'h00;
            tx_loaded <= 1'b0;
        end
        else if (tx_load && !busy) begin
            // Load new TX data when requested and not busy
            tx_shift  <= tx_data;
            tx_loaded <= 1'b1;
        end
        else if (cs_rising_edge && tx_loaded) begin
            // TX data already loaded, keep it
            tx_shift <= tx_shift;
        end
        else if (cs_rising_edge && !tx_loaded) begin
            // Load TX data at start of transaction if not already loaded
            tx_shift <= tx_data;
        end
        else if (spi_clk_falling && cs_active) begin
            // Shift out on falling edge (Mode 0: data changes on falling edge)
            tx_shift <= {tx_shift[6:0], 1'b0};
        end
    end

    //=========================================================================
    // MISO Output - MSB first, update on falling edge
    //=========================================================================

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            spi_miso <= 1'b0;
        else if (!cs_active)
            spi_miso <= 1'b0;  // Tri-state equivalent (drive low when inactive)
        else if (cs_rising_edge)
            spi_miso <= tx_shift[7];  // Output MSB at start
        else if (spi_clk_falling)
            spi_miso <= tx_shift[7];  // Output next bit on falling edge
    end

    //=========================================================================
    // Busy Signal
    //=========================================================================

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n)
            busy <= 1'b0;
        else
            busy <= cs_active;  // Busy while CS is active
    end

endmodule
