// tb_pixel_ring_buffer.v
// TASK-193: Testbench for pixel_ring_buffer module
// Author: Potjeh Sabolic, Testbench & Simulation Expert, REGOC Team
// Date: 2026-01-31
//
// Verification targets:
// 1. All 8 taps with correct delays (1024, 2048, 3072, ... 8192 cycles)
// 2. Pixel format: {10-bit X, 10-bit Y, 12-bit brightness}
// 3. shiftout == tap7
//
// The pixel_ring_buffer has a total latency of 2 cycles for each tap point:
// - Cycle N: Data written to memory at wrptr, wrptr increments
// - Cycle N+1: Read pointer computes address, data read from BRAM
// - Cycle N+TAP_DISTANCE+2: Data appears on tap output register
//
// The effective delay from input to tap[n] is: (n+1)*1024 + 2 cycles

`timescale 1ns/1ps

module tb_pixel_ring_buffer;

    //=========================================================================
    // Parameters
    //=========================================================================
    localparam CLK_PERIOD = 10;         // 100 MHz clock
    localparam TAP_DISTANCE = 1024;
    localparam NUM_TAPS = 8;
    localparam TOTAL_DEPTH = 8192;

    // Pipeline latency analysis:
    // - Write happens at posedge when data is present
    // - Read address is computed combinatorially from wrptr
    // - Read data is registered on the NEXT posedge
    // Total latency = TAP_DISTANCE + 2 for steady-state analysis
    // But for marker tracking (Phase 4), we count from after injection, so effective = TAP_DISTANCE + 1
    localparam BRAM_LATENCY = 2;
    localparam MARKER_LATENCY = 1;  // For Phase 4 marker tracking

    //=========================================================================
    // Signals
    //=========================================================================
    reg clock;
    reg [31:0] shiftin;
    wire [31:0] shiftout;
    wire [255:0] taps;

    // Individual tap extraction
    wire [31:0] tap0 = taps[31:0];
    wire [31:0] tap1 = taps[63:32];
    wire [31:0] tap2 = taps[95:64];
    wire [31:0] tap3 = taps[127:96];
    wire [31:0] tap4 = taps[159:128];
    wire [31:0] tap5 = taps[191:160];
    wire [31:0] tap6 = taps[223:192];
    wire [31:0] tap7 = taps[255:224];

    // Test tracking
    integer errors;
    integer tap_errors [0:7];
    integer i, t;

    // Reference model - stores what was written and when
    reg [31:0] history [0:TOTAL_DEPTH*2-1];  // Ring buffer history
    integer history_wr_idx;

    //=========================================================================
    // DUT Instantiation
    //=========================================================================
    pixel_ring_buffer dut (
        .clock(clock),
        .shiftin(shiftin),
        .shiftout(shiftout),
        .taps(taps)
    );

    //=========================================================================
    // Clock Generation
    //=========================================================================
    initial begin
        clock = 0;
        forever #(CLK_PERIOD/2) clock = ~clock;
    end

    //=========================================================================
    // Pixel Format Helper Functions
    //=========================================================================
    function [31:0] make_pixel;
        input [9:0] x;
        input [9:0] y;
        input [11:0] brightness;
        begin
            make_pixel = {x, y, brightness};
        end
    endfunction

    function [9:0] get_x;
        input [31:0] pixel;
        begin
            get_x = pixel[31:22];
        end
    endfunction

    function [9:0] get_y;
        input [31:0] pixel;
        begin
            get_y = pixel[21:12];
        end
    endfunction

    function [11:0] get_brightness;
        input [31:0] pixel;
        begin
            get_brightness = pixel[11:0];
        end
    endfunction

    //=========================================================================
    // Reference Model Task - record input
    //=========================================================================
    task record_input;
        input [31:0] data;
        begin
            history[history_wr_idx] = data;
            history_wr_idx = history_wr_idx + 1;
        end
    endtask

    //=========================================================================
    // Test Stimulus
    //=========================================================================
    initial begin
        $dumpfile("tb_pixel_ring_buffer.vcd");
        $dumpvars(0, tb_pixel_ring_buffer);

        // Initialize
        errors = 0;
        shiftin = 32'h0;
        history_wr_idx = 0;

        for (i = 0; i < 8; i = i + 1) begin
            tap_errors[i] = 0;
        end

        // Initialize history
        for (i = 0; i < TOTAL_DEPTH*2; i = i + 1) begin
            history[i] = 32'hDEADBEEF;
        end

        $display("================================================================================");
        $display("TASK-193: pixel_ring_buffer Testbench");
        $display("Author: Potjeh Sabolic, REGOC Team");
        $display("================================================================================");
        $display("");
        $display("Module specifications:");
        $display("  - Width: 32 bits (10-bit X, 10-bit Y, 12-bit brightness)");
        $display("  - Taps: 8");
        $display("  - Tap distance: 1024 cycles");
        $display("  - Total depth: 8192 locations");
        $display("  - Pipeline latency: %0d cycles", BRAM_LATENCY);
        $display("");
        $display("Expected tap delays:");
        for (t = 0; t < 8; t = t + 1) begin
            $display("  tap%0d: %0d cycles", t, TAP_DISTANCE * (t+1) + BRAM_LATENCY);
        end
        $display("");

        // =====================================================================
        // Phase 1: Fill the buffer with incrementing pattern
        // =====================================================================
        $display("================================================================================");
        $display("[Phase 1] Filling buffer with incrementing pattern...");
        $display("================================================================================");

        // Fill entire depth plus some extra to ensure all taps see valid data
        for (i = 0; i < TOTAL_DEPTH + 100; i = i + 1) begin
            shiftin = i + 1;  // Use i+1 so we never have 0 (easier to spot issues)
            @(posedge clock);
            record_input(shiftin);
        end

        $display("  Filled %0d cycles of data", history_wr_idx);
        $display("");

        // =====================================================================
        // Phase 2: Snapshot test - verify all taps at one moment
        // =====================================================================
        $display("================================================================================");
        $display("[Phase 2] Snapshot verification of all taps...");
        $display("================================================================================");

        // At this point, history_wr_idx = TOTAL_DEPTH + 100
        // The current outputs reflect data that was written BRAM_LATENCY cycles ago
        //
        // tap0 shows data from TAP_DISTANCE*1 + BRAM_LATENCY writes ago
        // tap1 shows data from TAP_DISTANCE*2 + BRAM_LATENCY writes ago
        // etc.

        begin
            reg [31:0] exp [0:7];
            integer ref_idx;
            integer pass_count;
            pass_count = 0;

            for (t = 0; t < 8; t = t + 1) begin
                ref_idx = history_wr_idx - (TAP_DISTANCE * (t+1) + BRAM_LATENCY);
                exp[t] = history[ref_idx];
            end

            $display("  history_wr_idx = %0d", history_wr_idx);
            $display("");

            // Check tap0
            if (tap0 === exp[0]) begin
                $display("  tap0: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[0], tap0, TAP_DISTANCE*1 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap0: FAIL (expected %0d, got %0d)", exp[0], tap0);
                tap_errors[0] = tap_errors[0] + 1;
                errors = errors + 1;
            end

            // Check tap1
            if (tap1 === exp[1]) begin
                $display("  tap1: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[1], tap1, TAP_DISTANCE*2 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap1: FAIL (expected %0d, got %0d)", exp[1], tap1);
                tap_errors[1] = tap_errors[1] + 1;
                errors = errors + 1;
            end

            // Check tap2
            if (tap2 === exp[2]) begin
                $display("  tap2: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[2], tap2, TAP_DISTANCE*3 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap2: FAIL (expected %0d, got %0d)", exp[2], tap2);
                tap_errors[2] = tap_errors[2] + 1;
                errors = errors + 1;
            end

            // Check tap3
            if (tap3 === exp[3]) begin
                $display("  tap3: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[3], tap3, TAP_DISTANCE*4 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap3: FAIL (expected %0d, got %0d)", exp[3], tap3);
                tap_errors[3] = tap_errors[3] + 1;
                errors = errors + 1;
            end

            // Check tap4
            if (tap4 === exp[4]) begin
                $display("  tap4: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[4], tap4, TAP_DISTANCE*5 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap4: FAIL (expected %0d, got %0d)", exp[4], tap4);
                tap_errors[4] = tap_errors[4] + 1;
                errors = errors + 1;
            end

            // Check tap5
            if (tap5 === exp[5]) begin
                $display("  tap5: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[5], tap5, TAP_DISTANCE*6 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap5: FAIL (expected %0d, got %0d)", exp[5], tap5);
                tap_errors[5] = tap_errors[5] + 1;
                errors = errors + 1;
            end

            // Check tap6
            if (tap6 === exp[6]) begin
                $display("  tap6: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[6], tap6, TAP_DISTANCE*7 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap6: FAIL (expected %0d, got %0d)", exp[6], tap6);
                tap_errors[6] = tap_errors[6] + 1;
                errors = errors + 1;
            end

            // Check tap7
            if (tap7 === exp[7]) begin
                $display("  tap7: PASS (expected %0d, got %0d, delay=%0d)",
                         exp[7], tap7, TAP_DISTANCE*8 + BRAM_LATENCY);
                pass_count = pass_count + 1;
            end else begin
                $display("  tap7: FAIL (expected %0d, got %0d)", exp[7], tap7);
                tap_errors[7] = tap_errors[7] + 1;
                errors = errors + 1;
            end

            $display("");
            $display("  Snapshot result: %0d/8 taps correct", pass_count);
        end

        $display("");

        // =====================================================================
        // Phase 3: Continuous verification - check taps match reference model
        // =====================================================================
        $display("================================================================================");
        $display("[Phase 3] Continuous verification for 1000 cycles...");
        $display("================================================================================");

        begin
            reg [31:0] exp [0:7];
            integer ref_idx;
            integer continuous_errors;
            integer cycle_errors;
            continuous_errors = 0;

            for (i = 0; i < 1000; i = i + 1) begin
                // Apply new input
                shiftin = history_wr_idx + 1;  // Continue the pattern

                @(posedge clock);
                record_input(shiftin);

                // After clock edge, taps show data from previous cycle's computation
                // Calculate expected values based on history
                cycle_errors = 0;

                for (t = 0; t < 8; t = t + 1) begin
                    ref_idx = history_wr_idx - (TAP_DISTANCE * (t+1) + BRAM_LATENCY);
                    if (ref_idx >= 0) begin
                        exp[t] = history[ref_idx];
                    end else begin
                        exp[t] = 32'hDEADBEEF;  // Haven't written this location yet
                    end
                end

                // Check all taps
                if (tap0 !== exp[0] && exp[0] !== 32'hDEADBEEF) begin
                    tap_errors[0] = tap_errors[0] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap1 !== exp[1] && exp[1] !== 32'hDEADBEEF) begin
                    tap_errors[1] = tap_errors[1] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap2 !== exp[2] && exp[2] !== 32'hDEADBEEF) begin
                    tap_errors[2] = tap_errors[2] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap3 !== exp[3] && exp[3] !== 32'hDEADBEEF) begin
                    tap_errors[3] = tap_errors[3] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap4 !== exp[4] && exp[4] !== 32'hDEADBEEF) begin
                    tap_errors[4] = tap_errors[4] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap5 !== exp[5] && exp[5] !== 32'hDEADBEEF) begin
                    tap_errors[5] = tap_errors[5] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap6 !== exp[6] && exp[6] !== 32'hDEADBEEF) begin
                    tap_errors[6] = tap_errors[6] + 1;
                    cycle_errors = cycle_errors + 1;
                end
                if (tap7 !== exp[7] && exp[7] !== 32'hDEADBEEF) begin
                    tap_errors[7] = tap_errors[7] + 1;
                    cycle_errors = cycle_errors + 1;
                end

                continuous_errors = continuous_errors + cycle_errors;

                // Debug first error
                if (continuous_errors > 0 && continuous_errors <= cycle_errors && cycle_errors > 0) begin
                    $display("  First error at cycle %0d:", i);
                    $display("    tap0: exp=%0d got=%0d", exp[0], tap0);
                    $display("    tap7: exp=%0d got=%0d", exp[7], tap7);
                end

                // Progress report every 250 cycles
                if ((i+1) % 250 == 0) begin
                    $display("  Progress: %0d/1000 cycles, errors: %0d", i+1, continuous_errors);
                end
            end

            errors = errors + continuous_errors;

            if (continuous_errors == 0) begin
                $display("  [PASS] All 1000 cycles verified successfully!");
            end else begin
                $display("  [FAIL] %0d tap mismatches in continuous verification", continuous_errors);
            end
        end

        $display("");

        // =====================================================================
        // Phase 4: Test with distinctive pixel patterns
        // =====================================================================
        $display("================================================================================");
        $display("[Phase 4] Testing with distinctive pixel patterns...");
        $display("================================================================================");

        begin
            reg [31:0] marker_pixel;
            integer inject_idx;
            integer found_at_tap [0:7];
            integer check_errors;
            check_errors = 0;

            // Inject a unique marker pixel
            marker_pixel = make_pixel(10'd999, 10'd888, 12'd4095);
            inject_idx = history_wr_idx;
            shiftin = marker_pixel;
            @(posedge clock);
            record_input(shiftin);

            $display("  Injected marker pixel 0x%08h at history index %0d", marker_pixel, inject_idx);
            $display("  (X=%0d, Y=%0d, Brightness=%0d)",
                     get_x(marker_pixel), get_y(marker_pixel), get_brightness(marker_pixel));

            // Now run with zeros and watch for the marker to appear at each tap
            for (t = 0; t < 8; t = t + 1) begin
                found_at_tap[t] = 0;
            end

            // Run until marker should have passed through all taps
            // tap7 has delay of 8192+2 = 8194, so run 8200 cycles
            for (i = 0; i < 8200; i = i + 1) begin
                shiftin = 32'h0;
                @(posedge clock);
                record_input(shiftin);

                // Check each tap for the marker
                // Note: We count cycles AFTER injection, so expected delay = TAP_DISTANCE*(n+1) + MARKER_LATENCY
                if (tap0 === marker_pixel && found_at_tap[0] == 0) begin
                    found_at_tap[0] = i + 1;
                    $display("  Found marker at tap0 after %0d cycles (expected %0d)",
                             found_at_tap[0], TAP_DISTANCE * 1 + MARKER_LATENCY);
                end
                if (tap1 === marker_pixel && found_at_tap[1] == 0) begin
                    found_at_tap[1] = i + 1;
                    $display("  Found marker at tap1 after %0d cycles (expected %0d)",
                             found_at_tap[1], TAP_DISTANCE * 2 + MARKER_LATENCY);
                end
                if (tap2 === marker_pixel && found_at_tap[2] == 0) begin
                    found_at_tap[2] = i + 1;
                    $display("  Found marker at tap2 after %0d cycles (expected %0d)",
                             found_at_tap[2], TAP_DISTANCE * 3 + MARKER_LATENCY);
                end
                if (tap3 === marker_pixel && found_at_tap[3] == 0) begin
                    found_at_tap[3] = i + 1;
                    $display("  Found marker at tap3 after %0d cycles (expected %0d)",
                             found_at_tap[3], TAP_DISTANCE * 4 + MARKER_LATENCY);
                end
                if (tap4 === marker_pixel && found_at_tap[4] == 0) begin
                    found_at_tap[4] = i + 1;
                    $display("  Found marker at tap4 after %0d cycles (expected %0d)",
                             found_at_tap[4], TAP_DISTANCE * 5 + MARKER_LATENCY);
                end
                if (tap5 === marker_pixel && found_at_tap[5] == 0) begin
                    found_at_tap[5] = i + 1;
                    $display("  Found marker at tap5 after %0d cycles (expected %0d)",
                             found_at_tap[5], TAP_DISTANCE * 6 + MARKER_LATENCY);
                end
                if (tap6 === marker_pixel && found_at_tap[6] == 0) begin
                    found_at_tap[6] = i + 1;
                    $display("  Found marker at tap6 after %0d cycles (expected %0d)",
                             found_at_tap[6], TAP_DISTANCE * 7 + MARKER_LATENCY);
                end
                if (tap7 === marker_pixel && found_at_tap[7] == 0) begin
                    found_at_tap[7] = i + 1;
                    $display("  Found marker at tap7/shiftout after %0d cycles (expected %0d)",
                             found_at_tap[7], TAP_DISTANCE * 8 + MARKER_LATENCY);
                end
            end

            $display("");
            $display("  Marker pixel tracking results:");
            for (t = 0; t < 8; t = t + 1) begin
                if (found_at_tap[t] == TAP_DISTANCE * (t+1) + MARKER_LATENCY) begin
                    $display("    tap%0d: PASS - delay = %0d cycles (exact match)", t, found_at_tap[t]);
                end else if (found_at_tap[t] > 0) begin
                    $display("    tap%0d: FAIL - delay = %0d cycles (expected %0d, diff=%0d)",
                             t, found_at_tap[t], TAP_DISTANCE * (t+1) + MARKER_LATENCY,
                             found_at_tap[t] - (TAP_DISTANCE * (t+1) + MARKER_LATENCY));
                    check_errors = check_errors + 1;
                end else begin
                    $display("    tap%0d: FAIL - marker not found!", t);
                    check_errors = check_errors + 1;
                end
            end

            errors = errors + check_errors;
        end

        $display("");

        // =====================================================================
        // Phase 5: Verify shiftout == tap7 invariant
        // =====================================================================
        $display("================================================================================");
        $display("[Phase 5] shiftout == tap7 verification (1000 random cycles)...");
        $display("================================================================================");

        begin
            integer shiftout_errors;
            shiftout_errors = 0;

            for (i = 0; i < 1000; i = i + 1) begin
                shiftin = $random;
                @(posedge clock);

                if (shiftout !== tap7) begin
                    if (shiftout_errors < 3) begin
                        $display("  [FAIL] Cycle %0d: shiftout=0x%08h, tap7=0x%08h",
                                 i, shiftout, tap7);
                    end
                    shiftout_errors = shiftout_errors + 1;
                end
            end

            if (shiftout_errors == 0) begin
                $display("  [PASS] shiftout == tap7 for all 1000 random cycles");
            end else begin
                $display("  [FAIL] shiftout != tap7 in %0d of 1000 cycles", shiftout_errors);
                errors = errors + shiftout_errors;
            end
        end

        $display("");

        // =====================================================================
        // Final Report
        // =====================================================================
        $display("================================================================================");
        $display("SIMULATION COMPLETE");
        $display("================================================================================");
        $display("");
        $display("Tap error counts:");

        for (t = 0; t < 8; t = t + 1) begin
            if (tap_errors[t] == 0) begin
                $display("  tap%0d (delay %0d cycles): PASS",
                         t, TAP_DISTANCE * (t+1) + BRAM_LATENCY);
            end else begin
                $display("  tap%0d (delay %0d cycles): %0d errors",
                         t, TAP_DISTANCE * (t+1) + BRAM_LATENCY, tap_errors[t]);
            end
        end

        $display("");
        $display("Total errors: %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("========================================");
            $display("        ALL TESTS PASSED               ");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("        TESTS FAILED: %0d errors        ", errors);
            $display("========================================");
        end

        $display("");
        $finish;
    end

    //=========================================================================
    // Timeout watchdog
    //=========================================================================
    initial begin
        #(CLK_PERIOD * 25000 * 10);  // ~2.5M ns timeout
        $display("");
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

endmodule
