// =============================================================================
// Testbench: test_pixel_path_tb.v
// =============================================================================
// Autor: Debug Team, REGOC
// Datum: 2026-01-31
//
// OPIS:
//   Testbench za provjeru pixel path od test_animation do pdp1_vga_crt.
//   Provjerava:
//   1. Da li test_animation generira pixel_valid pulseve
//   2. Da li koordinate izgledaju ispravno
//   3. Da li edge detection u CRT radi ispravno
//
// =============================================================================

`timescale 1ns/1ps

module test_pixel_path_tb;

    // =========================================================================
    // Clock generation - 25 MHz pixel clock (40ns period)
    // =========================================================================
    reg clk = 0;
    always #20 clk = ~clk;

    // =========================================================================
    // Reset generation
    // =========================================================================
    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    // =========================================================================
    // Frame tick generation - simulate vblank
    // =========================================================================
    reg frame_tick = 0;
    reg [19:0] frame_counter = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            frame_counter <= 0;
            frame_tick <= 0;
        end else begin
            frame_counter <= frame_counter + 1;
            // Frame tick every ~16.7ms at 25MHz = 416667 clocks
            // For simulation, use shorter period: every 10000 clocks
            frame_tick <= (frame_counter == 20'd10000);
            if (frame_counter == 20'd10000)
                frame_counter <= 0;
        end
    end

    // =========================================================================
    // Test animation instance
    // =========================================================================
    wire [9:0] anim_pixel_x;
    wire [9:0] anim_pixel_y;
    wire [2:0] anim_brightness;
    wire       anim_pixel_valid;
    wire [7:0] anim_debug_angle;

    test_animation test_anim_inst (
        .clk              (clk),
        .rst_n            (rst_n),
        .frame_tick       (frame_tick),
        .pixel_x          (anim_pixel_x),
        .pixel_y          (anim_pixel_y),
        .pixel_brightness (anim_brightness),
        .pixel_valid      (anim_pixel_valid),
        .debug_angle      (anim_debug_angle)
    );

    // =========================================================================
    // Edge detection - replicate CRT logic
    // =========================================================================
    reg prev_wren_i, prev_prev_wren_i, wren;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_wren_i <= 0;
            prev_prev_wren_i <= 0;
            wren <= 0;
        end else begin
            prev_prev_wren_i <= prev_wren_i;
            prev_wren_i <= anim_pixel_valid;
            wren <= prev_prev_wren_i & ~prev_wren_i;
        end
    end

    // =========================================================================
    // Monitoring and statistics
    // =========================================================================
    integer pixel_valid_count = 0;
    integer wren_count = 0;
    integer total_clocks = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            total_clocks <= total_clocks + 1;
            if (anim_pixel_valid)
                pixel_valid_count <= pixel_valid_count + 1;
            if (wren)
                wren_count <= wren_count + 1;
        end
    end

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("pixel_path.vcd");
        $dumpvars(0, test_pixel_path_tb);
    end

    // =========================================================================
    // Monitor
    // =========================================================================
    always @(posedge clk) begin
        if (anim_pixel_valid) begin
            $display("T=%0t: pixel_valid=1, X=%0d, Y=%0d, angle=%0d",
                     $time, anim_pixel_x, anim_pixel_y, anim_debug_angle);
        end
        if (wren) begin
            $display("T=%0t: wren=1 (CRT would receive pixel)", $time);
        end
    end

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=== Pixel Path Testbench ===");
        $display("Testing test_animation -> edge detection");
        $display("");

        // Wait for reset release
        @(posedge rst_n);
        $display("T=%0t: Reset released", $time);

        // Run for 50000 clocks (2ms at 25MHz)
        // This should cover several emit cycles (every 1024 clocks)
        repeat (50000) @(posedge clk);

        // Print statistics
        $display("");
        $display("=== Statistics ===");
        $display("Total clocks: %0d", total_clocks);
        $display("pixel_valid count: %0d", pixel_valid_count);
        $display("wren count: %0d", wren_count);
        $display("Expected pixels: %0d (every 1024 clocks)", total_clocks / 1024);
        $display("");

        if (pixel_valid_count > 0 && wren_count > 0) begin
            $display("TEST PASSED: Both pixel_valid and wren signals are active");
        end else if (pixel_valid_count > 0 && wren_count == 0) begin
            $display("TEST FAILED: pixel_valid works but wren never activates!");
            $display("Edge detection problem suspected.");
        end else begin
            $display("TEST FAILED: No pixel_valid signals detected!");
        end

        $finish;
    end

endmodule
