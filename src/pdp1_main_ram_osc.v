/*
 * PDP-1 Main RAM - Oscilloscope Version
 *
 * 4096 x 18-bit dual-port RAM for PDP-1 CPU
 * Initialized from oscilloscope.hex at synthesis time
 *
 * This is the oscilloscope-specific version of pdp1_main_ram.v
 * Used by: oscilloscope target (make oscilloscope)
 *
 * Original version: pdp1_main_ram.v (loads snowflake.hex)
 *
 * Port A: CPU access (read/write)
 * Port B: Secondary access (unused in basic config, but available)
 *
 * Author: Jelena Horvat, REGOC team
 * Task: RAM separation for oscilloscope build
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

    // Initialize memory at synthesis time
    // oscilloscope.hex contains the oscilloscope program for ADC display
    initial begin
        $readmemh("rom/oscilloscope.hex", mem);
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
