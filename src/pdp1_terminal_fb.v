/* Terminal frame buffer, contains 64 x 32 characters which correspond to letters on teletype emulator screen */
module pdp1_terminal_fb
(
  input clock,
  input [7:0] data,
  input [10:0] rdaddress,
  input [10:0] wraddress,
  output reg [7:0] q
);
  reg [7:0] framebuffer[0:2047];

  // Read-first behavior: separate always blocks for read and write
  // This ensures deterministic behavior and avoids read-during-write hazard
  // Author: Jelena Horvat, SNOWFLAKE FAZA 3

  // Read port - explicit read-first
  always @(posedge clock)
  begin
    q <= framebuffer[rdaddress];
  end

  // Write port - separate always block
  always @(posedge clock)
  begin
    framebuffer[wraddress] <= data;
  end
endmodule
