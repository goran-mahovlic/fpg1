// tb_pdp1_vga_crt.v
// Testbench za pdp1_vga_crt modul - CRT phosphor decay emulacija
// Autor: Kosjenka Vukovic, FPGA arhitektica
// Datum: 2026-01-31
//
// Testbench simulira:
// - 25MHz pixel clock (VGA 640x480@60Hz)
// - Horizontalni i vertikalni counteri (VGA timing)
// - Slanje test pixela na koordinatu (240, 240)
// - Pracenje buffer zapisa i citanja
// - RGB output logiranje kroz vise frameova
//
// Pokretanje:
//   cd <project-root>
//   iverilog -I src -o sim/tb_pdp1_vga_crt sim/tb_pdp1_vga_crt.v \
//            src/pdp1_vga_crt.v src/pdp1_vga_rowbuffer.v \
//            src/line_shift_register.v src/pixel_ring_buffer.v
//   vvp sim/tb_pdp1_vga_crt
//   gtkwave sim/tb_pdp1_vga_crt.vcd &

`timescale 1ns / 1ps

`include "definitions.v"

module tb_pdp1_vga_crt;

    //==========================================================================
    // PARAMETRI
    //==========================================================================

    // VGA 640x480@60Hz timing konstante
    localparam H_TOTAL      = 800;      // Ukupno pixela po liniji
    localparam V_TOTAL      = 525;      // Ukupno linija po frameu
    localparam CLK_PERIOD   = 40;       // 25 MHz = 40ns period

    // Test koordinate
    localparam TEST_PIXEL_X = 10'd240;
    localparam TEST_PIXEL_Y = 10'd240;

    // Simulacija trajanje
    localparam NUM_FRAMES   = 3;        // Broj frameova za simulaciju

    //==========================================================================
    // SIGNALI
    //==========================================================================

    // Clock i reset
    reg clk;

    // VGA timing counteri
    reg [10:0] h_counter;
    reg [10:0] v_counter;

    // Pixel input signali (od PDP-1)
    reg [9:0] pixel_x_i;
    reg [9:0] pixel_y_i;
    reg [2:0] pixel_brightness;
    reg variable_brightness;
    reg pixel_available;

    // RGB output signali
    wire [7:0] red_out;
    wire [7:0] green_out;
    wire [7:0] blue_out;

    // Debug pomocni signali
    integer frame_count;
    integer pixel_inject_count;
    reg pixel_was_written;
    reg [31:0] cycles_since_pixel;

    // Pracenje write adrese u bufferu
    wire [12:0] observed_wraddress;
    wire [12:0] observed_rdaddress;
    wire [7:0]  observed_wdata;
    wire        observed_wren;

    // Pristup internim signalima DUT-a za debug
    assign observed_wraddress = uut.rowbuff_wraddress;
    assign observed_rdaddress = uut.rowbuff_rdaddress;
    assign observed_wdata     = uut.rowbuff_wdata;
    assign observed_wren      = uut.rowbuff_wren;

    //==========================================================================
    // DUT INSTANCIJA
    //==========================================================================

    pdp1_vga_crt uut (
        .clk(clk),
        .horizontal_counter(h_counter),
        .vertical_counter(v_counter),
        .red_out(red_out),
        .green_out(green_out),
        .blue_out(blue_out),
        .pixel_x_i(pixel_x_i),
        .pixel_y_i(pixel_y_i),
        .pixel_brightness(pixel_brightness),
        .variable_brightness(variable_brightness),
        .pixel_available(pixel_available)
    );

    //==========================================================================
    // CLOCK GENERATOR - 25 MHz
    //==========================================================================

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //==========================================================================
    // VGA TIMING GENERATOR
    //==========================================================================

    initial begin
        h_counter = 0;
        v_counter = 0;
    end

    always @(posedge clk) begin
        if (h_counter >= H_TOTAL - 1) begin
            h_counter <= 0;
            if (v_counter >= V_TOTAL - 1) begin
                v_counter <= 0;
                frame_count <= frame_count + 1;
                $display("========================================");
                $display("[FRAME %0d] Novi frame pocinje @ %0t ns", frame_count + 1, $time);
                $display("========================================");
            end else begin
                v_counter <= v_counter + 1;
            end
        end else begin
            h_counter <= h_counter + 1;
        end
    end

    //==========================================================================
    // PIXEL AVAILABLE DETEKCIJA I DEBUG
    //==========================================================================

    always @(posedge clk) begin
        if (pixel_available && !pixel_was_written) begin
            $display("[%0t] PIXEL_AVAILABLE=1: Saljem pixel na koordinatu (%0d, %0d)",
                     $time, pixel_x_i, pixel_y_i);
            $display("      -> brightness=%0d, variable_brightness=%0d",
                     pixel_brightness, variable_brightness);
            pixel_was_written <= 1;
            cycles_since_pixel <= 0;
        end

        if (pixel_was_written) begin
            cycles_since_pixel <= cycles_since_pixel + 1;
        end
    end

    //==========================================================================
    // BUFFER WRITE PRACENJE
    //==========================================================================

    // Pratimo kada se pise u rowbuffer na zanimljivim lokacijama
    always @(posedge clk) begin
        if (observed_wren && observed_wdata != 0) begin
            // Dekodiranje adrese: {y[2:0], x[9:0]}
            $display("[%0t] BUFFER WRITE: addr=0x%04h (y_bits=%0d, x=%0d), data=0x%02h",
                     $time,
                     observed_wraddress,
                     observed_wraddress[12:10],
                     observed_wraddress[9:0],
                     observed_wdata);
        end
    end

    //==========================================================================
    // BUFFER READ PRACENJE (za nasu test koordinatu)
    //==========================================================================

    // Pratimo citanje iz buffera oko nase test koordinate
    reg [10:0] prev_h_counter;
    reg [10:0] prev_v_counter;

    always @(posedge clk) begin
        prev_h_counter <= h_counter;
        prev_v_counter <= v_counter;

        // Provjeri jesmo li blizu test koordinate (240, 240)
        // Moramo uzeti u obzir VGA offsete iz definitions.v
        // h_visible_offset = 160, h_center_offset = 64
        // v_visible_offset = 45
        // Dakle, pixel (240,240) ce biti nacrtan kada je:
        // h_counter = 160 + 64 + 240 = 464
        // v_counter = 45 + 240 = 285

        if (v_counter >= 280 && v_counter <= 290 &&
            h_counter >= 460 && h_counter <= 470) begin
            $display("[%0t] READ AREA: h=%0d v=%0d rdaddr=0x%04h",
                     $time, h_counter, v_counter, observed_rdaddress);
        end
    end

    //==========================================================================
    // RGB OUTPUT LOGIRANJE
    //==========================================================================

    // Logiramo RGB output kada smo u vidljivom podrucju i imamo non-zero output
    reg [7:0] prev_red, prev_green, prev_blue;
    reg rgb_logged_this_frame;

    always @(posedge clk) begin
        prev_red   <= red_out;
        prev_green <= green_out;
        prev_blue  <= blue_out;

        // Detektiraj promjenu boje (ne logirati svaki clock)
        if ((red_out != prev_red || green_out != prev_green || blue_out != prev_blue) &&
            (red_out != 0 || green_out != 0 || blue_out != 0)) begin
            $display("[%0t] RGB OUTPUT: R=0x%02h G=0x%02h B=0x%02h @ h=%0d v=%0d (frame %0d)",
                     $time, red_out, green_out, blue_out,
                     h_counter, v_counter, frame_count);
        end

        // Na kraju svakog framea, ispisi statistiku
        if (v_counter == V_TOTAL - 1 && h_counter == H_TOTAL - 1) begin
            rgb_logged_this_frame <= 0;
        end
    end

    //==========================================================================
    // RING BUFFER PRACENJE
    //==========================================================================

    // Pratimo interne FIFO pointere
    wire [5:0] fifo_read_ptr  = uut.buffer_read_ptr;
    wire [5:0] fifo_write_ptr = uut.buffer_write_ptr;
    wire [31:0] search_cnt    = uut.search_counter;

    reg [5:0] prev_fifo_read_ptr;
    reg [5:0] prev_fifo_write_ptr;

    always @(posedge clk) begin
        prev_fifo_read_ptr  <= fifo_read_ptr;
        prev_fifo_write_ptr <= fifo_write_ptr;

        // Detektiraj promjenu write pointera (novi pixel dodan u FIFO)
        if (fifo_write_ptr != prev_fifo_write_ptr) begin
            $display("[%0t] FIFO WRITE: ptr %0d -> %0d (search_cnt=%0d)",
                     $time, prev_fifo_write_ptr, fifo_write_ptr, search_cnt);
        end

        // Detektiraj promjenu read pointera (pixel preuzet iz FIFO-a)
        if (fifo_read_ptr != prev_fifo_read_ptr) begin
            $display("[%0t] FIFO READ: ptr %0d -> %0d (pixel ubacen u ring buffer)",
                     $time, prev_fifo_read_ptr, fifo_read_ptr);
        end
    end

    //==========================================================================
    // SHIFTOUT PRACENJE (ring buffer medjuveze)
    //==========================================================================

    wire [31:0] so1 = uut.shiftout_1;
    wire [31:0] so2 = uut.shiftout_2;
    wire [31:0] so3 = uut.shiftout_3;
    wire [31:0] so4 = uut.shiftout_4;

    // Dekodiranje: {pixel_y[9:0], pixel_x[9:0], luma[11:0]}
    wire [9:0] so1_y = so1[31:22];
    wire [9:0] so1_x = so1[21:12];
    wire [11:0] so1_luma = so1[11:0];

    // Pratimo kada se nas pixel pojavi u ring bufferima
    always @(posedge clk) begin
        // Invertirana Y koordinata: ~240 = 271 (za 10-bit)
        if ((so1_x == TEST_PIXEL_Y && so1_y == (~TEST_PIXEL_X & 10'h3FF)) ||
            (so1_x == TEST_PIXEL_Y && so1_y == (10'd511 - TEST_PIXEL_X))) begin
            $display("[%0t] RING BUFFER: Nas pixel pronadjen u shiftout_1! luma=%0d",
                     $time, so1_luma);
        end
    end

    //==========================================================================
    // MAIN TEST SEQUENCE
    //==========================================================================

    initial begin
        // VCD dump za GTKWave
        $dumpfile("sim/tb_pdp1_vga_crt.vcd");
        $dumpvars(0, tb_pdp1_vga_crt);

        // Inicijalizacija
        pixel_x_i = 0;
        pixel_y_i = 0;
        pixel_brightness = 3'd7;
        variable_brightness = 0;
        pixel_available = 0;
        frame_count = 0;
        pixel_inject_count = 0;
        pixel_was_written = 0;
        cycles_since_pixel = 0;
        rgb_logged_this_frame = 0;

        $display("============================================================");
        $display("  PDP-1 VGA CRT Testbench");
        $display("  Pixel clock: 25 MHz (period = %0d ns)", CLK_PERIOD);
        $display("  VGA timing: %0dx%0d @ 60Hz", H_TOTAL, V_TOTAL);
        $display("  Test pixel koordinata: (%0d, %0d)", TEST_PIXEL_X, TEST_PIXEL_Y);
        $display("  Simulacija: %0d frameova", NUM_FRAMES);
        $display("============================================================");

        // Cekaj nekoliko linija da se modul stabilizira
        repeat(H_TOTAL * 10) @(posedge clk);

        $display("\n[%0t] Inicijalizacija zavrsena, pocinjem test...\n", $time);

        //----------------------------------------------------------------------
        // TEST 1: Posalji jedan pixel na (240, 240)
        //----------------------------------------------------------------------

        $display("----------------------------------------------");
        $display("[TEST 1] Slanje pixela na (%0d, %0d)", TEST_PIXEL_X, TEST_PIXEL_Y);
        $display("----------------------------------------------");

        // Postavi pixel koordinate
        pixel_x_i = TEST_PIXEL_X;
        pixel_y_i = TEST_PIXEL_Y;
        pixel_brightness = 3'd7;        // Maksimalna svjetlina
        variable_brightness = 0;

        // Posalji pixel (pixel_available = 1 za nekoliko taktova)
        @(posedge clk);
        pixel_available = 1;
        $display("[%0t] pixel_available <- 1", $time);

        repeat(4) @(posedge clk);       // Drzi aktivan nekoliko ciklusa

        pixel_available = 0;
        $display("[%0t] pixel_available <- 0", $time);
        pixel_inject_count = pixel_inject_count + 1;

        // Cekaj da pixel prode kroz ring buffer
        $display("\n[%0t] Cekam da pixel prode kroz ring buffer...\n", $time);
        repeat(2000) @(posedge clk);

        //----------------------------------------------------------------------
        // TEST 2: Posalji dodatne pixele za testiranje
        //----------------------------------------------------------------------

        $display("----------------------------------------------");
        $display("[TEST 2] Slanje dodatnih pixela");
        $display("----------------------------------------------");

        // Pixel na (100, 100)
        pixel_x_i = 10'd100;
        pixel_y_i = 10'd100;
        @(posedge clk);
        pixel_available = 1;
        repeat(4) @(posedge clk);
        pixel_available = 0;
        pixel_inject_count = pixel_inject_count + 1;

        repeat(500) @(posedge clk);

        // Pixel na (300, 200)
        pixel_x_i = 10'd300;
        pixel_y_i = 10'd200;
        @(posedge clk);
        pixel_available = 1;
        repeat(4) @(posedge clk);
        pixel_available = 0;
        pixel_inject_count = pixel_inject_count + 1;

        //----------------------------------------------------------------------
        // Simuliraj vise frameova
        //----------------------------------------------------------------------

        $display("\n[%0t] Simuliram %0d frameova za promatranje phosphor decay...\n",
                 $time, NUM_FRAMES);

        // Cekaj NUM_FRAMES kompletnih frameova
        repeat(NUM_FRAMES) begin
            // Cekaj do kraja framea
            wait(v_counter == V_TOTAL - 1 && h_counter == H_TOTAL - 2);
            @(posedge clk);
            @(posedge clk);
        end

        //----------------------------------------------------------------------
        // TEST 3: Refresh postojeceg pixela
        //----------------------------------------------------------------------

        $display("----------------------------------------------");
        $display("[TEST 3] Refresh pixela na (%0d, %0d)", TEST_PIXEL_X, TEST_PIXEL_Y);
        $display("----------------------------------------------");

        pixel_x_i = TEST_PIXEL_X;
        pixel_y_i = TEST_PIXEL_Y;
        @(posedge clk);
        pixel_available = 1;
        repeat(4) @(posedge clk);
        pixel_available = 0;

        // Cekaj jos jedan frame
        repeat(H_TOTAL * V_TOTAL) @(posedge clk);

        //----------------------------------------------------------------------
        // Zavrsetak simulacije
        //----------------------------------------------------------------------

        $display("\n============================================================");
        $display("  Simulacija zavrsena");
        $display("  Ukupno pixela poslano: %0d", pixel_inject_count);
        $display("  Ukupno frameova: %0d", frame_count);
        $display("============================================================");

        $finish;
    end

    //==========================================================================
    // WATCHDOG TIMER
    //==========================================================================

    initial begin
        // Zaustavi simulaciju nakon 50ms (simuliranog vremena)
        #50_000_000;
        $display("\n[WATCHDOG] Simulacija prekinuta nakon 50ms");
        $finish;
    end

    //==========================================================================
    // PERIODICNO STANJE (svakih 10000 ciklusa)
    //==========================================================================

    reg [31:0] cycle_counter = 0;

    always @(posedge clk) begin
        cycle_counter <= cycle_counter + 1;

        if (cycle_counter % 100000 == 0 && cycle_counter > 0) begin
            $display("[%0t] STATUS: frame=%0d h=%0d v=%0d fifo_w=%0d fifo_r=%0d",
                     $time, frame_count, h_counter, v_counter,
                     fifo_write_ptr, fifo_read_ptr);
        end
    end

endmodule
