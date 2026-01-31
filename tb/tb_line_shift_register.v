// tb_line_shift_register.v
// Testbench for line_shift_register module
// TASK-192: Verification of BRAM-based circular buffer shift register
// Author: Potjeh Sabolic (REGOC tim)
//
// Test Plan:
// 1. Delay verification - data enters and exits after exactly N cycles
// 2. Shift behavior - continuous data stream verification
// 3. Wrap-around - circular buffer correctly wraps
//
// TIMING ANALYSIS of line_shift_register module:
// - TAP_DISTANCE = 1685
// - wrptr increments AFTER write (non-blocking assignment)
// - rdptr = wrptr - 1685 (combinational, uses pre-increment wrptr)
// - rd_data registered on clock edge
// - Total delay = TAP_DISTANCE = 1685 cycles (verified empirically)
//
// Verification approach:
// Golden model (behavioral shift register) compared cycle-by-cycle with DUT

`timescale 1ns / 1ps

module tb_line_shift_register;

    //=========================================================================
    // Parameters - derived from DUT
    //=========================================================================
    localparam TAP_DISTANCE = 1685;
    // Analysis: wrptr updates AFTER write, rdptr computed from current wrptr
    // BRAM read is registered but rdptr points to data written TAP_DISTANCE ago
    // Net delay = TAP_DISTANCE = 1685 cycles
    localparam DELAY = TAP_DISTANCE;  // 1685

    localparam TEST_LENGTH = 5000;
    localparam CLK_PERIOD = 10;

    //=========================================================================
    // Signals
    //=========================================================================
    reg clk = 0;
    reg [7:0] shiftin;
    wire [7:0] shiftout;
    wire [7:0] taps;

    integer errors, total_errors;
    integer cycle;
    reg [7:0] expected;

    // Golden model: simple shift register
    reg [7:0] golden_sr [0:DELAY];
    integer sr_idx;

    //=========================================================================
    // DUT
    //=========================================================================
    line_shift_register dut (
        .clock(clk),
        .shiftin(shiftin),
        .shiftout(shiftout),
        .taps(taps)
    );

    //=========================================================================
    // Clock
    //=========================================================================
    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================================
    // VCD
    //=========================================================================
    initial begin
        $dumpfile("tb_line_shift_register.vcd");
        $dumpvars(0, tb_line_shift_register);
    end

    //=========================================================================
    // Golden model update task
    //=========================================================================
    task shift_golden;
        input [7:0] data_in;
        integer k;
        begin
            for (k = DELAY; k > 0; k = k - 1) begin
                golden_sr[k] = golden_sr[k-1];
            end
            golden_sr[0] = data_in;
        end
    endtask

    //=========================================================================
    // Test
    //=========================================================================
    initial begin
        $display("================================================================");
        $display(" TASK-192: line_shift_register Testbench");
        $display(" Author: Potjeh Sabolic (REGOC tim)");
        $display("================================================================");
        $display(" TAP_DISTANCE = %0d", TAP_DISTANCE);
        $display(" TOTAL DELAY  = %0d cycles", DELAY);
        $display("================================================================");
        $display("");

        total_errors = 0;
        shiftin = 8'h00;

        // Initialize golden model
        for (sr_idx = 0; sr_idx <= DELAY; sr_idx = sr_idx + 1) begin
            golden_sr[sr_idx] = 8'h00;
        end

        // Wait for clock edge
        @(posedge clk);

        //=====================================================================
        // TEST 1: Sequential Pattern with Golden Model Comparison
        //=====================================================================
        $display("[TEST 1] Sequential Pattern (golden model comparison)");
        $display("         Running %0d cycles...", TEST_LENGTH + DELAY);

        errors = 0;

        for (cycle = 0; cycle < TEST_LENGTH + DELAY + 100; cycle = cycle + 1) begin
            // Apply sequential input
            shiftin = cycle[7:0];

            @(posedge clk);
            #1;

            // Update golden model AFTER clock edge (same as DUT timing)
            shift_golden(cycle[7:0]);

            // After initial fill, compare output with golden model
            if (cycle >= DELAY) begin
                expected = golden_sr[DELAY];

                if (shiftout !== expected) begin
                    if (errors < 20) begin
                        $display("  ERROR cycle %0d: expected 0x%02x got 0x%02x (input was 0x%02x)",
                                 cycle, expected, shiftout, (cycle - DELAY) & 8'hFF);
                    end
                    errors = errors + 1;
                end

                if (taps !== shiftout) begin
                    if (errors < 25) begin
                        $display("  ERROR cycle %0d: taps mismatch", cycle);
                    end
                    errors = errors + 1;
                end
            end

            if (cycle > 0 && cycle % 1000 == 0) begin
                $display("  ... cycle %0d, errors: %0d", cycle, errors);
            end
        end

        if (errors == 0) begin
            $display("[TEST 1] PASSED");
        end else begin
            $display("[TEST 1] FAILED - %0d errors", errors);
            total_errors = total_errors + errors;
        end
        $display("");

        //=====================================================================
        // TEST 2: Pseudo-Random Pattern
        //=====================================================================
        $display("[TEST 2] Pseudo-Random Pattern");

        errors = 0;

        // Reset golden model
        for (sr_idx = 0; sr_idx <= DELAY; sr_idx = sr_idx + 1) begin
            golden_sr[sr_idx] = 8'hXX;  // Unknown initial state
        end

        for (cycle = 0; cycle < TEST_LENGTH + DELAY + 100; cycle = cycle + 1) begin
            // Pseudo-random input
            shiftin = ((cycle * 171 + 53) ^ (cycle >> 3)) & 8'hFF;

            @(posedge clk);
            #1;

            shift_golden(shiftin);

            if (cycle >= DELAY) begin
                expected = golden_sr[DELAY];

                if (shiftout !== expected) begin
                    if (errors < 10) begin
                        $display("  ERROR cycle %0d: expected 0x%02x got 0x%02x",
                                 cycle, expected, shiftout);
                    end
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) begin
            $display("[TEST 2] PASSED");
        end else begin
            $display("[TEST 2] FAILED - %0d errors", errors);
            total_errors = total_errors + errors;
        end
        $display("");

        //=====================================================================
        // TEST 3: Wrap-Around (6000+ cycles)
        //=====================================================================
        $display("[TEST 3] Wrap-Around Test (6000+ cycles)");
        $display("         Buffer wraps at 2048, testing multiple wraps");

        errors = 0;

        for (sr_idx = 0; sr_idx <= DELAY; sr_idx = sr_idx + 1) begin
            golden_sr[sr_idx] = 8'hEE;  // Different pattern from test 1
        end

        for (cycle = 0; cycle < 6000 + DELAY + 100; cycle = cycle + 1) begin
            shiftin = (cycle * 7 + 11) & 8'hFF;

            @(posedge clk);
            #1;

            shift_golden(shiftin);

            if (cycle >= DELAY) begin
                expected = golden_sr[DELAY];

                if (shiftout !== expected) begin
                    if (errors < 10) begin
                        $display("  ERROR cycle %0d: expected 0x%02x got 0x%02x",
                                 cycle, expected, shiftout);
                    end
                    errors = errors + 1;
                end
            end

            if (cycle == 2048 || cycle == 4096 || cycle == 6144) begin
                $display("  ... wrap point cycle %0d, errors: %0d", cycle, errors);
            end
        end

        if (errors == 0) begin
            $display("[TEST 3] PASSED");
        end else begin
            $display("[TEST 3] FAILED - %0d errors", errors);
            total_errors = total_errors + errors;
        end
        $display("");

        //=====================================================================
        // TEST 4: Constant Patterns
        //=====================================================================
        $display("[TEST 4] Constant Pattern Verification");

        errors = 0;

        // Test with 0x00
        $display("         Testing 0x00...");
        for (cycle = 0; cycle < DELAY + 50; cycle = cycle + 1) begin
            shiftin = 8'h00;
            @(posedge clk);
        end
        #1;
        if (shiftout !== 8'h00) begin
            $display("  ERROR: 0x00 test failed, got 0x%02x", shiftout);
            errors = errors + 1;
        end

        // Test with 0xFF
        $display("         Testing 0xFF...");
        for (cycle = 0; cycle < DELAY + 50; cycle = cycle + 1) begin
            shiftin = 8'hFF;
            @(posedge clk);
        end
        #1;
        if (shiftout !== 8'hFF) begin
            $display("  ERROR: 0xFF test failed, got 0x%02x", shiftout);
            errors = errors + 1;
        end

        // Test with 0xAA
        $display("         Testing 0xAA...");
        for (cycle = 0; cycle < DELAY + 50; cycle = cycle + 1) begin
            shiftin = 8'hAA;
            @(posedge clk);
        end
        #1;
        if (shiftout !== 8'hAA) begin
            $display("  ERROR: 0xAA test failed, got 0x%02x", shiftout);
            errors = errors + 1;
        end

        // Test with 0x55
        $display("         Testing 0x55...");
        for (cycle = 0; cycle < DELAY + 50; cycle = cycle + 1) begin
            shiftin = 8'h55;
            @(posedge clk);
        end
        #1;
        if (shiftout !== 8'h55) begin
            $display("  ERROR: 0x55 test failed, got 0x%02x", shiftout);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("[TEST 4] PASSED");
        end else begin
            $display("[TEST 4] FAILED - %0d errors", errors);
            total_errors = total_errors + errors;
        end
        $display("");

        //=====================================================================
        // Summary
        //=====================================================================
        $display("================================================================");
        $display(" SIMULATION COMPLETE");
        $display("================================================================");

        if (total_errors == 0) begin
            $display("");
            $display("  ####    ##     ####    ####  ");
            $display("  #   #  #  #   #       #      ");
            $display("  ####  #    #   ####    ####  ");
            $display("  #     ######       #       # ");
            $display("  #     #    #  #    #  #    # ");
            $display("  #     #    #   ####    ####  ");
            $display("");
            $display("  ALL TESTS PASSED!");
            $display("  Delay verified: %0d cycles", DELAY);
        end else begin
            $display("");
            $display("  #####    ##      #    #      ");
            $display("  #       #  #     #    #      ");
            $display("  #####  #    #    #    #      ");
            $display("  #      ######    #    #      ");
            $display("  #      #    #    #    #      ");
            $display("  #      #    #    #    ###### ");
            $display("");
            $display("  FAILED with %0d total errors", total_errors);
        end
        $display("");
        $display("================================================================");

        $finish;
    end

    //=========================================================================
    // Timeout
    //=========================================================================
    initial begin
        #(CLK_PERIOD * 300000);
        $display("ERROR: Timeout!");
        $finish;
    end

endmodule
