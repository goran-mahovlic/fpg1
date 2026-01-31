// tb_coord_test.v
// MINIMALNI testbench za koordinatno mapiranje pdp1_vga_crt modula
// Autor: Jelena Horvat, FPGA Verification Engineer
// Datum: 2026-01-31
//
// Cilj: Pratiti pixel (100,100) kroz coordinate mapping pipeline
// i vidjeti gdje zavrsava na VGA outputu.
//
// NAPOMENA: Ne instanciramo cijeli CRT, vec samo logiku za coordinate mapping

`timescale 1ns/1ps

// Definicije za 640x480@60Hz
`define   h_line_timing          11'd800
`define   h_visible_offset       11'd160
`define   h_center_offset        11'd64
`define   h_visible_offset_end   11'd704
`define   v_visible_offset       11'd45
`define   v_visible_offset_end   11'd525

module tb_coord_test;

    //==========================================================
    // Signali
    //==========================================================
    reg clk = 0;
    reg [10:0] horizontal_counter = 0;
    reg [10:0] vertical_counter = 0;

    // Ulazni pixel od PDP-1 (512x512 prostor)
    reg [9:0] pixel_x_i = 0;
    reg [9:0] pixel_y_i = 0;
    reg pixel_available = 0;

    // Pipeline registri (kopija iz CRT modula)
    reg [9:0] buffer_pixel_x[63:0];
    reg [9:0] buffer_pixel_y[63:0];
    reg [5:0] buffer_write_ptr = 0;
    reg [5:0] buffer_read_ptr = 0;

    reg [9:0] next_pixel_x, next_pixel_y;

    // Ring buffer format: {pixel_y[9:0], pixel_x[9:0], luma[11:0]} = 32 bits
    reg [31:0] shiftout_1, shiftout_2, shiftout_3, shiftout_4;
    reg [9:0] pixel_1_x, pixel_1_y;
    reg [9:0] pixel_2_x, pixel_2_y;
    reg [9:0] pixel_3_x, pixel_3_y;
    reg [9:0] pixel_4_x, pixel_4_y;
    reg [11:0] luma_1, luma_2, luma_3, luma_4;

    // VGA koordinate (output prostor)
    wire [9:0] current_x, current_y;
    wire inside_visible_area;

    // Rowbuffer adresiranje
    wire [12:0] rowbuff_rdaddress;
    wire [12:0] rowbuff_wraddress_calc;

    // Edge detection za pixel_available
    reg prev_pixel_available = 0;
    reg prev_prev_pixel_available = 0;
    reg wren = 0;

    //==========================================================
    // Coordinate Mapping Logic (iz pdp1_vga_crt.v)
    //==========================================================

    // Mapiranje PDP-1 koordinata na VGA visible area
    assign current_y = (vertical_counter >= `v_visible_offset &&
                        vertical_counter < `v_visible_offset_end)
                       ? vertical_counter - `v_visible_offset : 11'b0;

    assign current_x = (horizontal_counter >= `h_visible_offset + `h_center_offset &&
                        horizontal_counter < `h_visible_offset_end + `h_center_offset)
                       ? horizontal_counter - (`h_visible_offset + `h_center_offset) : 11'b0;

    assign inside_visible_area = (horizontal_counter >= `h_visible_offset + `h_center_offset &&
                                  horizontal_counter < `h_visible_offset_end + `h_center_offset);

    // Rowbuffer adresa: {current_y[2:0], current_x[9:0]} - 13 bits
    assign rowbuff_rdaddress = {current_y[2:0], current_x};

    // Za taps matching, ring buffer lookup koristi pixel koordinate direktno
    // Format u ring bufferu: {pixel_y, pixel_x, luma} where Y is MSB
    assign rowbuff_wraddress_calc = {pixel_1_y[2:0], pixel_1_x};

    //==========================================================
    // VGA Timing Generator
    //==========================================================
    always #20 clk = ~clk;  // 25 MHz pixel clock

    always @(posedge clk) begin
        if (horizontal_counter >= `h_line_timing - 1) begin
            horizontal_counter <= 0;
            if (vertical_counter >= 524)
                vertical_counter <= 0;
            else
                vertical_counter <= vertical_counter + 1;
        end
        else begin
            horizontal_counter <= horizontal_counter + 1;
        end
    end

    //==========================================================
    // Edge Detection (kopija iz CRT modula)
    //==========================================================
    always @(posedge clk) begin
        prev_prev_pixel_available <= prev_pixel_available;
        prev_pixel_available <= pixel_available;
        wren <= prev_prev_pixel_available & ~prev_pixel_available;  // Falling edge
    end

    //==========================================================
    // FIFO Buffer Write Logic (pojednostavljena verzija)
    //==========================================================
    always @(posedge clk) begin
        if (wren) begin
            // Ispravljen X<->Y swap (kao u TASK-XXX)
            buffer_pixel_x[buffer_write_ptr] <= pixel_x_i;
            buffer_pixel_y[buffer_write_ptr] <= pixel_y_i;
            buffer_write_ptr <= buffer_write_ptr + 1;

            $display("[%0t] FIFO WRITE: pixel_x_i=%d, pixel_y_i=%d -> buffer[%d]",
                     $time, pixel_x_i, pixel_y_i, buffer_write_ptr);
        end
    end

    //==========================================================
    // FIFO Buffer Read Logic (pojednostavljena verzija)
    //==========================================================
    always @(posedge clk) begin
        next_pixel_x <= buffer_pixel_x[buffer_read_ptr];
        next_pixel_y <= buffer_pixel_y[buffer_read_ptr];
    end

    //==========================================================
    // Ring Buffer Insert (simulacija)
    //==========================================================
    reg [15:0] insert_delay = 0;
    reg pixel_inserted = 0;

    always @(posedge clk) begin
        if (buffer_write_ptr != buffer_read_ptr && !pixel_inserted) begin
            insert_delay <= insert_delay + 1;

            // Nakon 1024+ ciklusa, ubaci pixel u ring buffer
            if (insert_delay > 1024) begin
                // Format: {pixel_y[9:0], pixel_x[9:0], luma[11:0]}
                shiftout_1 <= {next_pixel_y, next_pixel_x, 12'd4095};
                pixel_1_y <= next_pixel_y;
                pixel_1_x <= next_pixel_x;
                luma_1 <= 12'd4095;

                buffer_read_ptr <= buffer_read_ptr + 1;
                pixel_inserted <= 1;

                $display("[%0t] RING BUFFER INSERT:", $time);
                $display("       next_pixel_x=%d, next_pixel_y=%d", next_pixel_x, next_pixel_y);
                $display("       shiftout_1 = {y=%d, x=%d, luma=%d}",
                         next_pixel_y, next_pixel_x, 4095);
                $display("       32-bit value = 0x%08X", {next_pixel_y, next_pixel_x, 12'd4095});
            end
        end
    end

    //==========================================================
    // Monitor: Provjera kada current_x/current_y odgovara pixelu
    //==========================================================
    reg match_found = 0;

    always @(posedge clk) begin
        if (pixel_inserted && !match_found) begin
            // Provjera: kada VGA scan dostigne koordinate naseg pixela
            if (current_x == pixel_1_x && current_y == pixel_1_y && inside_visible_area) begin
                $display("");
                $display("========================================");
                $display("[%0t] VGA SCAN MATCH FOUND!", $time);
                $display("========================================");
                $display("  Input PDP-1 coordinates:  X=%d, Y=%d", pixel_x_i, pixel_y_i);
                $display("  Stored in ring buffer:    X=%d, Y=%d", pixel_1_x, pixel_1_y);
                $display("  VGA scan position:");
                $display("    horizontal_counter = %d", horizontal_counter);
                $display("    vertical_counter   = %d", vertical_counter);
                $display("    current_x          = %d", current_x);
                $display("    current_y          = %d", current_y);
                $display("  Rowbuffer address:        0x%04X ({y[2:0],x} = {%d,%d})",
                         rowbuff_rdaddress, current_y[2:0], current_x);
                $display("========================================");
                $display("");
                match_found <= 1;
            end
        end
    end

    //==========================================================
    // Glavni Test
    //==========================================================
    initial begin
        // VCD dump za GTKWave
        $dumpfile("tb_coord_test.vcd");
        $dumpvars(0, tb_coord_test);

        $display("");
        $display("==============================================");
        $display(" COORDINATE MAPPING TEST - pdp1_vga_crt");
        $display(" Pixel (100, 100) through pipeline");
        $display("==============================================");
        $display("");
        $display("Timing constants (640x480@60Hz):");
        $display("  h_visible_offset = %d", `h_visible_offset);
        $display("  h_center_offset  = %d", `h_center_offset);
        $display("  v_visible_offset = %d", `v_visible_offset);
        $display("  Total H offset   = %d (h_visible + h_center)",
                 `h_visible_offset + `h_center_offset);
        $display("");
        $display("Expected mapping for pixel (100,100):");
        $display("  VGA horizontal = 100 + %d = %d",
                 `h_visible_offset + `h_center_offset,
                 100 + `h_visible_offset + `h_center_offset);
        $display("  VGA vertical   = 100 + %d = %d",
                 `v_visible_offset,
                 100 + `v_visible_offset);
        $display("");

        // Cekaj nekoliko ciklusa
        repeat(100) @(posedge clk);

        // Posalji pixel na (100, 100)
        $display("[%0t] Sending pixel at PDP-1 coordinates (100, 100)", $time);
        pixel_x_i = 10'd100;
        pixel_y_i = 10'd100;
        pixel_available = 1;

        repeat(5) @(posedge clk);
        pixel_available = 0;

        // Cekaj da se pixel umetne u ring buffer
        $display("[%0t] Waiting for pixel to be inserted into ring buffer...", $time);
        wait(pixel_inserted);

        $display("");
        $display("[%0t] Pixel inserted. Waiting for VGA scan to reach position...", $time);
        $display("       Looking for: current_x=%d, current_y=%d", pixel_1_x, pixel_1_y);

        // Cekaj da VGA scan dode do te pozicije (max 2 frame-a)
        repeat(800 * 525 * 2) @(posedge clk);

        if (!match_found) begin
            $display("");
            $display("WARNING: Match not found within 2 frames!");
            $display("  Last VGA position: h=%d, v=%d, current_x=%d, current_y=%d",
                     horizontal_counter, vertical_counter, current_x, current_y);
            $display("  Pixel stored at: x=%d, y=%d", pixel_1_x, pixel_1_y);
        end

        $display("");
        $display("==============================================");
        $display(" TEST COMPLETE");
        $display("==============================================");
        $display("");

        $finish;
    end

    // Timeout
    initial begin
        #100_000_000;  // 100ms timeout
        $display("TIMEOUT - test took too long");
        $finish;
    end

endmodule
