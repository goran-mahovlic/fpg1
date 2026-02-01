// pdp1_vga_crt.v
// TASK-194: CRT phosphor decay emulation for PDP-1 vector display
// TASK-200: Prilagodeno za 640x480@60Hz (timing fix)
// TASK-XXX: Upgrade na 1024x768@50Hz (Jelena Horvat)
// Adapted for ECP5/Yosys synthesis by REGOC Team
//
// This module implements a 1024 x 768 @ 50 Hz vector display output.
// Uses BRAM-based shift registers to simulate phosphor decay.
// PDP-1 1024x1024 display mapped to 1024x768 frame (768 lines visible).
//
// Architecture:
// - pdp1_vga_rowbuffer: Stores next 8 lines to be drawn (64 Kbit BRAM)
// - line_shift_register x3: 1-line delays for 3x3 blur kernel
// - pixel_ring_buffer x4: "Hadron collider" style circular buffers
//   Connected: 1->2->3->4->1 for pixel storage and decay
//
// Dependencies:
// - pdp1_vga_rowbuffer.v
// - line_shift_register.v
// - pixel_ring_buffer.v

module pdp1_vga_crt (
  input clk,                                                   /* Clock input, 1024 x 768 @ 50 Hz is 51 MHz pixel clock */

  input [10:0] horizontal_counter,                             /* Current video drawing position */
  input [10:0] vertical_counter,

  output reg [7:0] red_out,                                    /* Outputs RGB values for corresponding pixels */
  output reg [7:0] green_out,
  output reg [7:0] blue_out,

  input  [9:0] pixel_x_i,                                      /* Gets input from PDP as a peripheral IOT device */
  input  [9:0] pixel_y_i,                                      /* Don't forget the input is clocked at 50 MHz */
  input  [2:0] pixel_brightness,                               /* Pixel brightness / intensity */

  input  variable_brightness,                                  /* Should we respect specified brightness levels? */

  input  pixel_available,                                      /* High when there is a pixel to be written */

  // DEBUG outputs
  output wire [5:0] debug_write_ptr,                           /* FIFO write pointer for debug */
  output wire [5:0] debug_read_ptr,                            /* FIFO read pointer for debug */
  output wire       debug_wren,                                /* Write enable signal for debug */
  output wire [10:0] debug_search_counter,                     /* Search counter MSBs for debug */
  output wire [11:0] debug_luma1,                              /* Luma from ring buffer 1 output */
  output wire       debug_rowbuff_wren,                        /* Rowbuffer write enable for LED */
  output wire       debug_inside_visible,                      /* inside_visible_area signal */
  output wire       debug_pixel_to_rowbuff,                    /* Non-zero pixel written to rowbuffer */
  output wire [15:0] debug_rowbuff_write_count,                /* Non-zero pixels written to rowbuffer per frame */
  output wire [9:0]  debug_ring_buffer_wrptr                   /* Ring buffer 1 write pointer for pixel debug */
);

//////////////////  PARAMETERS  ///////////////////

parameter
   DATA_WIDTH                    = 'd32,
   offset                        = 2'd3,
   brightness                    = 8'd242;

//////////////////  FUNCTIONS  ////////////////////

function automatic [11:0] dim_pixel;
   input [11:0] luma;
   // VRACENA ORIGINALNA LOGIKA (fpg1/src/pdp1_vga_crt.v):
   // - Standardni decay: luma - 1
   // - Step-down na 2576 kad luma u rasponu 3864-3936 (afterglow simulacija)
   // Prijašnji kod (luma - 8) bio je 8x brži i uništavao pokretne objekte (brodove)
   dim_pixel = (luma > 12'd3864 && luma < 12'd3936) ? 12'd2576 : luma - 1'b1;
endfunction


////////////////////  TASKS  //////////////////////

task output_pixel;                                                                        /* It outputs a pixel and adjusts is color depending on the luminosity */
   input [7:0] intensity;                                                                 /* A bright pixel is blue-white and a darker one is green */
   begin

   red_out <= inside_visible_area ? {5'b0, intensity[7:5]} : 8'b0;

      if (intensity >= 8'h80) begin
         green_out <= inside_visible_area ? intensity      : 8'b0;
         blue_out <= inside_visible_area ? intensity       : 8'b0;
         red_out <= inside_visible_area ? intensity[7:6]   : 8'b0;
      end
      else begin
         green_out <= inside_visible_area ? intensity      : 8'b0;
         blue_out <= inside_visible_area ? intensity[7]    : 8'b0;
      end

   end
endtask


////////////////////  WIRES  //////////////////////

wire [7:0] rowbuff_rdata;                                      /* Output from row buffer */
wire [7:0] p31_w, p21_w, p13_w, p23_w, p33_w;                  /* Output from line shift registers */
wire [255:0] taps1, taps2, taps3, taps4;                       /* Ring buffer taps (8 per ring buffer, 32-bit each) */

wire [31:0] shiftout_1_w, shiftout_2_w,                        /* Ring buffer outputs */
            shiftout_3_w, shiftout_4_w;

wire [9:0] current_y, current_x;                               /* Current visible screen area position */

//////////////////  REGISTERS  ////////////////////

reg  [12:0] rowbuff_rdaddress, rowbuff_wraddress;              /* Row buffer addressing, this is for storing next 8 lines to be drawn */
reg  [7:0] rowbuff_wdata;
reg  [0:0] rowbuff_wren;

/* Create 3x3 pixel matrix from registers to multiply with the blur kernel */
reg [7:0] p11, p12, p13, // <- p13_w <- line1
          p21, p22, p23, // <- p23_w <- line2
          p31, p32, p33; // <- p33_w <- line3 <- row buffer


reg [31:0] shiftout_1, shiftout_2, shiftout_3, shiftout_4;     /* Store (and manipulate) values being output from LFSR shift registers */

reg [9:0] pixel_x, pixel_y;
reg [9:0] pixel_1_x, pixel_1_y, pixel_2_x, pixel_2_y,
          pixel_3_x, pixel_3_y, pixel_4_x, pixel_4_y;

reg [11:0] luma, luma_1, luma_2, luma_3, luma_4;

integer i;                                                     /* Used in for loop as index */

reg [31:0] pass_counter = 32'd1;                               /* Counts vertical refresh cycles */
reg [9:0]  erase_counter;
reg        pixel_found;                                        /* Used in rowbuffer write logic to track if pixel was found */

reg [31:0] search_counter;                                     /* Counts how many clock cycles passed since we didn't see the pixel to be added on any of the ring buffer taps */

reg [9:0] next_pixel_x, next_pixel_y;                          /* Store the values from the fifo buffer at read pointer to these temporary registers */

reg [9:0] buffer_pixel_x[63:0];                                /* FIFO buffer storing the pixels to be written to ring buffer (when empty slot found) */
reg [9:0] buffer_pixel_y[63:0];

reg [5:0] buffer_read_ptr, buffer_write_ptr;                   /* Pointers to FIFO buffer position for read and write operations,
                                                                  when not equal there is something waiting to be written */
reg [15:0] pixel_out;

reg prev_wren_i, prev_prev_wren_i, wren;                       /* Store write enable signals to detect a rising edge */

reg inside_visible_area;                                       /* Indicate if we are currently within area which is visible */

// DEBUG: Export internal signals
assign debug_write_ptr = buffer_write_ptr;
assign debug_read_ptr = buffer_read_ptr;
assign debug_wren = wren;
assign debug_search_counter = search_counter[31:21];  // MSBs to see if it's large
assign debug_luma1 = luma_1;

// DEBUG: Provjeri koordinate u vidljivom rasponu (0-1023 za puni 1024x1024 PDP-1 display)
wire [9:0] dbg_px = pixel_x_i;
wire [9:0] dbg_py = pixel_y_i;
wire dbg_coord_in_range = (pixel_x_i < 10'd1024) && (pixel_y_i < 10'd1024);

// DEBUG: Export rowbuffer write signal za LED indikator
assign debug_rowbuff_wren = rowbuff_wren;

// DEBUG: Export inside_visible_area signal
assign debug_inside_visible = inside_visible_area;

// DEBUG: Signalizacija da se piksel upisuje u rowbuffer (non-zero data)
assign debug_pixel_to_rowbuff = rowbuff_wren && (rowbuff_wdata != 8'd0);

// DEBUG: Brojac non-zero piksela upisanih u rowbuffer po frameu
reg [15:0] rowbuff_nonzero_count;
reg [15:0] debug_rowbuff_count_latched;
reg [10:0] prev_v_counter_dbg;

always @(posedge clk) begin
    prev_v_counter_dbg <= vertical_counter;
    // Detect frame start (v_counter wraps)
    if (vertical_counter == 11'd0 && prev_v_counter_dbg != 11'd0) begin
        debug_rowbuff_count_latched <= rowbuff_nonzero_count;
        rowbuff_nonzero_count <= 16'd0;
    end else if (rowbuff_wren && rowbuff_wdata != 8'd0) begin
        rowbuff_nonzero_count <= rowbuff_nonzero_count + 1'b1;
    end
end

assign debug_rowbuff_write_count = debug_rowbuff_count_latched;



/////////////////  ASSIGNMENTS  ///////////////////

assign p21_w = p21;
assign p31_w = p31;

assign current_y = (vertical_counter >= `v_visible_offset && vertical_counter < `v_visible_offset_end) ? vertical_counter - `v_visible_offset : 11'b0;
assign current_x = (horizontal_counter >= `h_visible_offset + `h_center_offset && horizontal_counter < `h_visible_offset_end + `h_center_offset) ? horizontal_counter - (`h_visible_offset + `h_center_offset): 11'b0;

/* PDP-1 Y koordinata = current_y + v_crt_offset */
/* Ovo pomice vidljivo podrucje u PDP-1 koordinatnom sustavu */
wire [9:0] pdp1_y;
assign pdp1_y = current_y + `v_crt_offset;


///////////////////  MODULES  /////////////////////

/* Row buffer keeps the next 8 lines to be drawn and we populate it with pixels as ring buffer advances */
pdp1_vga_rowbuffer rowbuffer(
   .data(rowbuff_wdata),
   .rdaddress(rowbuff_rdaddress),
   .clock(clk),
   .wraddress(rowbuff_wraddress),
   .wren(rowbuff_wren),
   .q(rowbuff_rdata));


/* To enable blurring, create 3 1-line shift registers */
/* FIX: Uklonjen current_x > 0 uvjet koji je gubio prvi piksel svake linije */
line_shift_register line1(.clock(clk), .shiftout(p13_w), .shiftin(p21_w));
line_shift_register line2(.clock(clk), .shiftout(p23_w), .shiftin(p31_w));
line_shift_register line3(.clock(clk), .shiftout(p33_w), .shiftin(rowbuff_rdata));


/* Create 4 pixel ring buffers with 8 taps each and connect them in a loop (a.k.a. hadron collider style) */
/* e.g. ring_buffer_1 .. shiftout_1_w -> {pixel_1_y, pixel_1_x, luma_1} -> shiftout_2 .. ring_buffer_2    */

// Debug wire for ring buffer 1 write pointer
wire [9:0] ring_buf1_wrptr;

pixel_ring_buffer ring_buffer_1(.clock(clk),  .shiftin(shiftout_1),  .shiftout(shiftout_1_w),  .taps(taps1), .debug_wrptr(ring_buf1_wrptr) );
pixel_ring_buffer ring_buffer_2(.clock(clk),  .shiftin(shiftout_2),  .shiftout(shiftout_2_w),  .taps(taps2), .debug_wrptr() );
pixel_ring_buffer ring_buffer_3(.clock(clk),  .shiftin(shiftout_3),  .shiftout(shiftout_3_w),  .taps(taps3), .debug_wrptr() );
pixel_ring_buffer ring_buffer_4(.clock(clk),  .shiftin(shiftout_4),  .shiftout(shiftout_4_w),  .taps(taps4), .debug_wrptr() );

// Debug: expose ring buffer 1 write pointer
assign debug_ring_buffer_wrptr = ring_buf1_wrptr;


////////////////  ALWAYS BLOCKS  //////////////////

always @(posedge clk) begin
     next_pixel_x <= buffer_pixel_x[buffer_read_ptr];
     next_pixel_y <= buffer_pixel_y[buffer_read_ptr];

     search_counter <= search_counter + 1'b1;

     { pixel_1_y, pixel_1_x, luma_1 } <= shiftout_1_w;         /* shiftout_?_w is where ring buffers (lfsr) connect to each other */
     { pixel_2_y, pixel_2_x, luma_2 } <= shiftout_2_w;         /* Store these values to corresponding registers */
     { pixel_3_y, pixel_3_x, luma_3 } <= shiftout_3_w;
     { pixel_4_y, pixel_4_x, luma_4 } <= shiftout_4_w;

     if(wren) begin
          // =======================================================================
          // KOORDINATNA TRANSFORMACIJA - ovisi o modu rada
          // =======================================================================
          // TEST_ANIMATION: direktne koordinate (X, Y) - bez transformacije
          // PDP-1 MODE: origin u GORNJEM DESNOM kutu
          //   ~pixel_x_i invertira X os (0→1023, 1023→0)
          //   Swap X↔Y rotira koordinate za ispravnu orijentaciju
          //   Rezultat: { buffer_pixel_y, buffer_pixel_x } = { ~X, Y }

`ifdef TEST_ANIMATION
          // TEST_ANIMATION: direktno koristi koordinate bez transformacije
          if (variable_brightness && pixel_brightness > 3'b0 && pixel_brightness < 3'b100)
          begin
            { buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { pixel_y_i, pixel_x_i };

            { buffer_pixel_y[buffer_write_ptr + 3'd1], buffer_pixel_x[buffer_write_ptr + 3'd1] } <= { pixel_y_i + 1'b1, pixel_x_i };
            { buffer_pixel_y[buffer_write_ptr + 3'd2], buffer_pixel_x[buffer_write_ptr + 3'd2] } <= { pixel_y_i, pixel_x_i + 1'b1};
            { buffer_pixel_y[buffer_write_ptr + 3'd3], buffer_pixel_x[buffer_write_ptr + 3'd3] } <= { pixel_y_i - 1'b1, pixel_x_i };
            { buffer_pixel_y[buffer_write_ptr + 3'd4], buffer_pixel_x[buffer_write_ptr + 3'd4] } <= { pixel_y_i, pixel_x_i - 1'b1};

            buffer_write_ptr <= buffer_write_ptr + 3'd5;
          end
          else
          begin
            { buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { pixel_y_i, pixel_x_i };
            buffer_write_ptr <= buffer_write_ptr + 1'b1;
          end
`else
          // PDP-1 MODE: X/Y swap + X inverzija - PUNI 1024x1024 display
          // Koordinate iz CPU-a su 0-1023 (kao original)
          // 1) Inverzija X: ~pixel_x_i = 1023 - pixel_x_i (10-bit inverzija)
          // 2) X/Y swap: invertirani X ide u Y buffer, Y ide u X buffer
          // BEZ skaliranja - koristi pune 10-bit koordinate za 1024x1024 display
          if (variable_brightness && pixel_brightness > 3'b0 && pixel_brightness < 3'b100)
          begin
            { buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };

            { buffer_pixel_y[buffer_write_ptr + 3'd1], buffer_pixel_x[buffer_write_ptr + 3'd1] } <= { ~pixel_x_i + 1'b1, pixel_y_i };
            { buffer_pixel_y[buffer_write_ptr + 3'd2], buffer_pixel_x[buffer_write_ptr + 3'd2] } <= { ~pixel_x_i, pixel_y_i + 1'b1 };
            { buffer_pixel_y[buffer_write_ptr + 3'd3], buffer_pixel_x[buffer_write_ptr + 3'd3] } <= { ~pixel_x_i - 1'b1, pixel_y_i };
            { buffer_pixel_y[buffer_write_ptr + 3'd4], buffer_pixel_x[buffer_write_ptr + 3'd4] } <= { ~pixel_x_i, pixel_y_i - 1'b1 };

            buffer_write_ptr <= buffer_write_ptr + 3'd5;
          end
          else
          begin
            { buffer_pixel_y[buffer_write_ptr], buffer_pixel_x[buffer_write_ptr] } <= { ~pixel_x_i, pixel_y_i };
            buffer_write_ptr <= buffer_write_ptr + 1'b1;
          end
`endif

          if (buffer_write_ptr == buffer_read_ptr)
               search_counter <= 0;
     end

     begin
     /* Dimming old pixels at the points where ring buffers connect. They are stored into registers and connected: 1->2, 2->3, 3->4, 4->1 */
     /* FIX: Dimming VRAĆEN - phosphor decay svakih 8 prolaza */
     shiftout_1 <= luma_4[11:4] ? { pixel_4_y, pixel_4_x, pass_counter[2:0] == 3'b0 ? dim_pixel(luma_4) : luma_4 } : 0;
     shiftout_2 <= luma_1[11:4] ? { pixel_1_y, pixel_1_x, pass_counter[2:0] == 3'b0 ? dim_pixel(luma_1) : luma_1 } : 0;
     shiftout_3 <= luma_2[11:4] ? { pixel_2_y, pixel_2_x, pass_counter[2:0] == 3'b0 ? dim_pixel(luma_2) : luma_2 } : 0;
     shiftout_4 <= luma_3[11:4] ? { pixel_3_y, pixel_3_x, pass_counter[2:0] == 3'b0 ? dim_pixel(luma_3) : luma_3 } : 0;

     /* Add new pixel */

     /* If we didn't find a pixel on one of the taps within inter-tap distance, assume there is
        nothing to update and once we find a dark pixel we can re-use, add the current one to that position */
     /* FIX BUG 4: search_counter threshold mora biti > TAP_DISTANCE ring buffera (512) */
     /* TASK-XXX: Threshold zadrzan na 640, dovoljan za ring buffer TAP_DISTANCE 512 */

     if (buffer_write_ptr != buffer_read_ptr && search_counter > 640 && (!luma_1[11:4] || !luma_2[11:4] || !luma_3[11:4] || !luma_4[11:4]))
     begin
         if (luma_4[11:4] == 0)
               shiftout_1 <= { { next_pixel_y, next_pixel_x, 12'd4095 } };
         else if (luma_1[11:4] == 0)
               shiftout_2 <= { { next_pixel_y, next_pixel_x, 12'd4095 } };
         else if (luma_2[11:4] == 0)
               shiftout_3 <= { { next_pixel_y, next_pixel_x, 12'd4095 } };
         else if (luma_3[11:4] == 0)
               shiftout_4 <= { { next_pixel_y, next_pixel_x, 12'd4095 } };

         buffer_read_ptr <= buffer_read_ptr + 1'b1;

         next_pixel_x <= buffer_pixel_x[buffer_read_ptr + 1'b1];
         next_pixel_y <= buffer_pixel_y[buffer_read_ptr + 1'b1];

         search_counter <= 0;
      end

     /* Update existing pixel, treat this as an existing pixel refresh only if it's visible on the screen
        (search counter is < 1024 and we in fact found the pixel on one of the LFSR outputs) */

   else if (buffer_write_ptr != buffer_read_ptr &&
      (  (pixel_1_x == next_pixel_x && pixel_1_y == next_pixel_y)
      || (pixel_2_x == next_pixel_x && pixel_2_y == next_pixel_y)
      || (pixel_3_x == next_pixel_x && pixel_3_y == next_pixel_y)
      || (pixel_4_x == next_pixel_x && pixel_4_y == next_pixel_y)
      ))
   begin
      if (pixel_1_x == next_pixel_x && pixel_1_y == next_pixel_y)
         shiftout_2 <= { next_pixel_y, next_pixel_x, 12'd4095};

      else if (pixel_2_x == next_pixel_x && pixel_2_y == next_pixel_y)
         shiftout_3 <= { next_pixel_y, next_pixel_x, 12'd4095};

      else if (pixel_3_x == next_pixel_x && pixel_3_y == next_pixel_y)
         shiftout_4 <= { next_pixel_y, next_pixel_x, 12'd4095};

      else if (pixel_4_x == next_pixel_x && pixel_4_y == next_pixel_y)
         shiftout_1 <= { next_pixel_y, next_pixel_x, 12'd4095};

      /* Increment the read_ptr pointer as we have just inserted one pixel from the write fifo buffer */
      buffer_read_ptr <= buffer_read_ptr + 1'b1;

      next_pixel_x <= buffer_pixel_x[buffer_read_ptr + 1'b1];
      next_pixel_y <= buffer_pixel_y[buffer_read_ptr + 1'b1];

      search_counter <= 0;

   end

     /* We have seen our pixel exists in ring buffer on one of the taps. Reset search counter so we don't add another one but wait for it to appear
     on the LSFR outputs (in shiftout_? registers). As we buffer 8 lines ahead and have 8 taps per ring buffer, we will "catch" the pixel in time to be output */
     else
         for (i=8; i>0; i=i-1'b1)
            if ((taps1[i * DATA_WIDTH-1 -: 10] == next_pixel_y && taps1[i * DATA_WIDTH-11 -: 10] == next_pixel_x && taps1[i * DATA_WIDTH-21 -: 8])
              ||(taps2[i * DATA_WIDTH-1 -: 10] == next_pixel_y && taps2[i * DATA_WIDTH-11 -: 10] == next_pixel_x && taps2[i * DATA_WIDTH-21 -: 8])
              ||(taps3[i * DATA_WIDTH-1 -: 10] == next_pixel_y && taps3[i * DATA_WIDTH-11 -: 10] == next_pixel_x && taps3[i * DATA_WIDTH-21 -: 8])
              ||(taps4[i * DATA_WIDTH-1 -: 10] == next_pixel_y && taps4[i * DATA_WIDTH-11 -: 10] == next_pixel_x && taps4[i * DATA_WIDTH-21 -: 8])
               )

               search_counter <= 0;
     end
end

always @(posedge clk) begin
   /* Read from one line buffer to the screen and prepare the next line */

   rowbuff_rdaddress <= {current_y[2:0], current_x};
   rowbuff_wren <= 1'b1;

   /* Shift the 3x3 register values (connected to the lfsr line buffers). We use these to apply a blur kernel since without it the graphics are too sharp for a CRT output */
   p11 <= p12; p12 <= p13; p13 <= p13_w;
   p21 <= p22; p22 <= p23; p23 <= p23_w;
   p31 <= p32; p32 <= p33; p33 <= p33_w;

   /* Simple averaging blur kernel, but instead with 9, we divide by 8. Since this applies only to phosphor trail anyways, it will never overflow the max value for pixel_out register width */
   if ( p22 < brightness)
	begin
		pixel_out <= ( {8'b0, p11[7:1]} + p12 + p13 + p21 + p22 + p23 + p31 + p32 + p33[7:1] ) >> 3;		/* Remove chance of overflow by taking two pixels with 0.5 coefficient */
		p21 <= pixel_out;
	end
   else
      pixel_out <= p22;

   output_pixel(pixel_out);

   // =========================================================================
   // FIX: Odvojeni erase i pixel write - pixel write ima prioritet
   // =========================================================================
   // PROBLEM: Stari kod je imao erase u if, pixel write u else - erase je blokirao pixel write
   // RJESENJE: Pixel write se uvijek pokusava, erase samo kad nema piksela za upisati

   // Prvo provjeri ima li piksela za upisati iz ring buffera
   // Pixel write prioritet - trazi piksel koji treba upisati u rowbuffer
   pixel_found = 1'b0;

   for (i=8; i>0; i=i-1'b1) begin
      if (!pixel_found && pdp1_y < taps1[i * DATA_WIDTH-1 -: 10] && taps1[i * DATA_WIDTH-1 -: 10] - pdp1_y <= 3'd7 && taps1[i * DATA_WIDTH - 21 -: 8] > 0) begin
         rowbuff_wraddress <= {taps1[i * DATA_WIDTH - 8 -: 3], taps1[i * DATA_WIDTH - 11 -: 10]};
         rowbuff_wdata <= taps1[i * DATA_WIDTH - 21 -: 8];
         pixel_found = 1'b1;
      end
      else if (!pixel_found && pdp1_y < taps2[i * DATA_WIDTH-1 -: 10] && taps2[i * DATA_WIDTH-1 -: 10] - pdp1_y <= 3'd7 && taps2[i * DATA_WIDTH - 21 -: 8] > 0) begin
         rowbuff_wraddress <= {taps2[i * DATA_WIDTH - 8 -: 3], taps2[i * DATA_WIDTH - 11 -: 10]};
         rowbuff_wdata <= taps2[i * DATA_WIDTH - 21 -: 8];
         pixel_found = 1'b1;
      end
      else if (!pixel_found && pdp1_y < taps3[i * DATA_WIDTH-1 -: 10] && taps3[i * DATA_WIDTH-1 -: 10] - pdp1_y <= 3'd7 && taps3[i * DATA_WIDTH - 21 -: 8] > 0) begin
         rowbuff_wraddress <= {taps3[i * DATA_WIDTH - 8 -: 3], taps3[i * DATA_WIDTH - 11 -: 10]};
         rowbuff_wdata <= taps3[i * DATA_WIDTH - 21 -: 8];
         pixel_found = 1'b1;
      end
      else if (!pixel_found && pdp1_y < taps4[i * DATA_WIDTH-1 -: 10] && taps4[i * DATA_WIDTH-1 -: 10] - pdp1_y <= 3'd7 && taps4[i * DATA_WIDTH - 21 -: 8] > 0) begin
         rowbuff_wraddress <= {taps4[i * DATA_WIDTH - 8 -: 3], taps4[i * DATA_WIDTH - 11 -: 10]};
         rowbuff_wdata <= taps4[i * DATA_WIDTH - 21 -: 8];
         pixel_found = 1'b1;
      end
   end

   // Ako nije pronaden piksel, nastavi s erase-om (ne blokiraj pixel write)
   if (!pixel_found && erase_counter < current_x) begin
      rowbuff_wraddress <= {current_y[2:0], erase_counter};
      rowbuff_wdata <= 0;
      erase_counter <= erase_counter + 1'b1;
   end

   // Reset erase counter na kraju linije
   // FIX: h_counter ide 0-799, nikad ne dođe do 800!
   if (horizontal_counter == `h_line_timing - 1)
      erase_counter <= 0;

end


always @(posedge clk) begin
   inside_visible_area <= (horizontal_counter >= `h_visible_offset + `h_center_offset && horizontal_counter < `h_visible_offset_end + `h_center_offset);

   // FIX: h_counter ide 0-799, nikad ne dođe do 800!
   if (horizontal_counter == `h_line_timing - 1)
      pass_counter <= pass_counter + 1'b1;                     /* Counts the number of vertical refresh passes, used to slow down pixel dimming (do one for every n passes) */

   prev_prev_wren_i <= prev_wren_i;                            /* Falling edge detect on a write enable signal, with additional clock to allow the signal to stabilize */
   prev_wren_i <= pixel_available;
   /* FIX: Falling edge detection - piksel je spreman kad signal PADA */
   wren <= prev_prev_wren_i & ~prev_wren_i;

end


endmodule
