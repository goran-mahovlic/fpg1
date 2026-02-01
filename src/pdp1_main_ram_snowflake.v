/*
 * PDP-1 Main RAM - Snowflake Version
 *
 * 4096 x 18-bit dual-port RAM for PDP-1 CPU
 * Initialized from snowflake.hex at synthesis time
 *
 * This is a simple test program that draws patterns on the CRT display.
 * Used for testing CPU and display functionality.
 *
 * Port A: CPU access (read/write)
 * Port B: Secondary access (unused in basic config, but available)
 *
 * Author: Jelena Kovacevic, REGOC team
 * Task: Snowflake test program for PDP-1 emulator
 */

module pdp1_main_ram (
    // Port A - Primary CPU interface
    input  wire [11:0] address_a,
    input  wire        clock_a,
    input  wire [17:0] data_a,
    input  wire        wren_a,
    output reg  [17:0] q_a,

    // Port B - Secondary interface (optional)
    input  wire [11:0] address_b,
    input  wire        clock_b,
    input  wire [17:0] data_b,
    input  wire        wren_b,
    output reg  [17:0] q_b
);

    // 4096 x 18-bit memory array
    // PDP-1 has 18-bit words, 4K word address space (12-bit address)
    reg [17:0] mem [0:4095];

    // Initialize from HEX file at synthesis time
    // snowflake.hex contains a simple test/demo program
    initial begin
        $readmemh("src/rom/snowflake.hex", mem);
    end

    // Port A - synchronous read/write
    always @(posedge clock_a) begin
        if (wren_a) begin
            mem[address_a] <= data_a;
        end
        q_a <= mem[address_a];
    end

    // Port B - synchronous read/write
    always @(posedge clock_b) begin
        if (wren_b) begin
            mem[address_b] <= data_b;
        end
        q_b <= mem[address_b];
    end

endmodule
