// pdp1_vga_rowbuffer.v
// TASK-194: Row buffer for CRT display
// Ported from Emard's version for ECP5/Yosys synthesis
//
// Rowbuffer holds next 8 lines of pixels which should be drawn on the screen,
// storing pixels extracted from ring buffers.
//
// Memory: 8192 x 8-bit = 64 Kbit (4 DP16KD blocks on ECP5)
// Addressing: 13-bit = {current_y[2:0], current_x[9:0]}

module pdp1_vga_rowbuffer (
  input clock,
  input [7:0] data,
  input [12:0] rdaddress,
  input [12:0] wraddress,
  input wren,
  output reg [7:0] q
);

  // BRAM inference for ECP5
  (* ram_style = "block" *)
  reg [7:0] rowbuffer[0:8191];

  always @(posedge clock) begin
    q <= rowbuffer[rdaddress];
    if(wren)
      rowbuffer[wraddress] <= data;
  end

endmodule
