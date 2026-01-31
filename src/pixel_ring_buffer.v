// pixel_ring_buffer.v
// TASK-123/196: CRT phosphor decay emulation - MINIMAL VERSION
// Author: Kosjenka Vukovic, REGOC Team
// Date: 2026-01-31
//
// MINIMALNA VERZIJA ZA VERIFICACIJU SINTEZE:
// - Jedna memorija s jednim tapom
// - 1024 x 32-bit = 32 Kbit (~2 DP16KD)
// - Ostali tapovi su registri (sample & hold)
//
// NAPOMENA: Ovo je privremena verzija za provjeru integracije.
// Potpuna CRT emulacija ce zahtijevati vise memorije ili
// drugaciji pristup (npr. sparse pixel storage).

module pixel_ring_buffer
(
    input wire clock,
    input wire [31:0] shiftin,
    output wire [31:0] shiftout,
    output wire [255:0] taps
);

    // Minimal Parameters
    localparam DEPTH = 1024;        // Single buffer depth
    localparam WIDTH = 32;          // Data width
    localparam ADDR_WIDTH = 10;     // log2(1024) = 10 bits

    // Pointers
    reg [ADDR_WIDTH-1:0] wrptr = 0;
    reg [ADDR_WIDTH-1:0] rdptr = 0;

    // Single BRAM
    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Read data
    reg [WIDTH-1:0] rd_data = 0;

    // Tap registers - sample at different intervals
    reg [WIDTH-1:0] tap_reg0 = 0;
    reg [WIDTH-1:0] tap_reg1 = 0;
    reg [WIDTH-1:0] tap_reg2 = 0;
    reg [WIDTH-1:0] tap_reg3 = 0;
    reg [WIDTH-1:0] tap_reg4 = 0;
    reg [WIDTH-1:0] tap_reg5 = 0;
    reg [WIDTH-1:0] tap_reg6 = 0;
    reg [WIDTH-1:0] tap_reg7 = 0;

    // Sample counter for tap updates
    reg [6:0] sample_cnt = 0;

    always @(posedge clock) begin
        // Write new data
        mem[wrptr] <= shiftin;

        // Read oldest data
        rdptr <= wrptr + 1'b1;  // Next location is oldest
        rd_data <= mem[rdptr];

        // Update write pointer
        wrptr <= wrptr + 1'b1;

        // Sample taps at different rates
        sample_cnt <= sample_cnt + 1'b1;

        // Stagger tap updates to simulate different delays
        if (sample_cnt[2:0] == 3'd0) tap_reg0 <= shiftin;
        if (sample_cnt[2:0] == 3'd1) tap_reg1 <= tap_reg0;
        if (sample_cnt[2:0] == 3'd2) tap_reg2 <= tap_reg1;
        if (sample_cnt[2:0] == 3'd3) tap_reg3 <= tap_reg2;
        if (sample_cnt[2:0] == 3'd4) tap_reg4 <= tap_reg3;
        if (sample_cnt[2:0] == 3'd5) tap_reg5 <= tap_reg4;
        if (sample_cnt[2:0] == 3'd6) tap_reg6 <= tap_reg5;
        if (sample_cnt[2:0] == 3'd7) tap_reg7 <= rd_data;
    end

    // Output assignments
    assign taps[31:0]    = tap_reg0;
    assign taps[63:32]   = tap_reg1;
    assign taps[95:64]   = tap_reg2;
    assign taps[127:96]  = tap_reg3;
    assign taps[159:128] = tap_reg4;
    assign taps[191:160] = tap_reg5;
    assign taps[223:192] = tap_reg6;
    assign taps[255:224] = tap_reg7;

    // shiftout is oldest data from BRAM
    assign shiftout = rd_data;

endmodule
