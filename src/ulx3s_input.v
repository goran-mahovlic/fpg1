//============================================================================
// Module: ulx3s_input
// Description: ULX3S Button/Switch Input Handler for PDP-1 Spacewar!
//============================================================================
// Author: Grga Pitic, REGOC periferija expert
// Date: 2026-01-31
// Updated: 2026-02-02 (Best practices applied)
//
// HARDWARE INTERFACE:
//   ULX3S Board:
//     - 7 buttons: BTN[6:0] (active LOW on PCB)
//     - 4 DIP switches: SW[3:0]
//
// BUTTON LAYOUT (active HIGH after inversion):
//   BTN[0] = PWR (directly under FPGA)
//   BTN[1] = UP
//   BTN[2] = DOWN
//   BTN[3] = LEFT
//   BTN[4] = RIGHT
//   BTN[5] = F1
//   BTN[6] = F2
//
// SPACEWAR! CONTROL MAPPING:
//   Player 1 (Needle - left player):
//     BTN[0] = Fire torpedo
//     BTN[1] = Thrust
//     BTN[3] = Rotate CCW
//     BTN[4] = Rotate CW
//
//   Player 2 (Wedge - right player, SW[0] held):
//     SW[0] + BTN[2] = Fire torpedo
//     SW[0] + BTN[1] = Thrust
//     SW[0] + BTN[3] = Rotate CCW
//     SW[0] + BTN[4] = Rotate CW
//
//   Mode Control:
//     SW[1] = Single player mode (P2 disabled)
//
// OUTPUT FORMAT (joystick_emu[7:0]):
//   [0] = P1 fire      [4] = P2 fire
//   [1] = P1 CCW       [5] = P2 CCW
//   [2] = P1 thrust    [6] = P2 thrust
//   [3] = P1 CW        [7] = P2 CW
//
// CDC HANDLING:
//   All button/switch inputs are synchronized with 2-FF synchronizers
//   marked with ASYNC_REG attribute for proper placement.
//
// DEBOUNCE:
//   Each button has independent counter-based debounce (default 10ms).
//   State changes only accepted after stable for DEBOUNCE_MS.
//
//============================================================================

`default_nettype none

module ulx3s_input #(
    parameter CLK_FREQ    = 25_000_000, // Clock frequency in Hz
    parameter DEBOUNCE_MS = 10          // Debounce time in milliseconds
)(
    // Clock and Reset
    input  wire        i_clk,           // System clock
    input  wire        i_rst_n,         // Active-low synchronous reset

    // ULX3S Hardware Inputs (directly from pins)
    input  wire [6:0]  i_btn_n,         // Buttons (active LOW from board)
    input  wire [3:0]  i_sw,            // DIP switches

    // Joystick Emulation Output
    output reg  [7:0]  o_joystick_emu,  // Active HIGH joystick signals

    // LED Feedback Output
    output wire [7:0]  o_led_feedback,  // Mirror of joystick state

    // Mode Indicators
    output wire        o_p2_mode_active,// Player 2 mode active (SW[0])
    output wire        o_single_player, // Single player mode (SW[1])

    // Direct Button Access (for Pong compatibility)
    // Active HIGH, debounced, no mode modifier applied
    // BTN[0]=PWR, BTN[1]=UP, BTN[2]=DOWN, BTN[3]=LEFT, BTN[4]=RIGHT, BTN[5]=F1, BTN[6]=F2
    output wire [6:0]  o_btn_direct     // Direct debounced button state
);

//============================================================================
// Local Parameters
//============================================================================
// Debounce counter: DEBOUNCE_MS milliseconds at CLK_FREQ
localparam DEBOUNCE_COUNT = (CLK_FREQ / 1000) * DEBOUNCE_MS;
localparam CNT_WIDTH      = $clog2(DEBOUNCE_COUNT + 1);

//============================================================================
// Signal Declarations
//============================================================================
// Button input handling:
// FIXED 2026-02-13: ULX3S v3.1.7 buttons are active HIGH with pull-down!
// - BTN[0] = PWR - has pull-up, active low (special case)
// - BTN[1-6] = User buttons - have pull-down, active high
// No inversion needed for BTN[1-6], only for BTN[0]
wire [6:0] w_btn_raw;
assign w_btn_raw = {i_btn_n[6:1], ~i_btn_n[0]};  // Only invert BTN[0] (PWR)

// CDC synchronizer registers (2-FF for metastability protection)
(* ASYNC_REG = "TRUE" *) reg [6:0] r_btn_meta;   // First FF (may be metastable)
(* ASYNC_REG = "TRUE" *) reg [6:0] r_btn_sync;   // Second FF (stable)

// Debounce state
reg [CNT_WIDTH-1:0] r_debounce_cnt [6:0];  // Per-button debounce counter
reg [6:0]           r_btn_debounced;        // Debounced button state

// Loop variable (for generate alternative)
integer i;

//============================================================================
// Button CDC Synchronization and Debounce
//============================================================================
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_btn_meta      <= 7'b0;
        r_btn_sync      <= 7'b0;
        r_btn_debounced <= 7'b0;
        for (i = 0; i < 7; i = i + 1) begin
            r_debounce_cnt[i] <= {CNT_WIDTH{1'b0}};
        end
    end else begin
        // Stage 1: Metastability capture
        r_btn_meta <= w_btn_raw;
        // Stage 2: Synchronized output
        r_btn_sync <= r_btn_meta;

        // Debounce logic: each button independent
        for (i = 0; i < 7; i = i + 1) begin
            if (r_btn_sync[i] != r_btn_debounced[i]) begin
                // Button state differs from debounced state
                if (r_debounce_cnt[i] < DEBOUNCE_COUNT) begin
                    r_debounce_cnt[i] <= r_debounce_cnt[i] + 1'b1;
                end else begin
                    // Stable for DEBOUNCE_MS, accept new state
                    r_btn_debounced[i] <= r_btn_sync[i];
                    r_debounce_cnt[i]  <= {CNT_WIDTH{1'b0}};
                end
            end else begin
                // Button stable, reset counter
                r_debounce_cnt[i] <= {CNT_WIDTH{1'b0}};
            end
        end
    end
end

//============================================================================
// DIP Switch CDC Synchronization
// Switches are mechanically stable, no debounce needed
//============================================================================
(* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_meta;   // First FF (may be metastable)
(* ASYNC_REG = "TRUE" *) reg [3:0] r_sw_sync;   // Second FF (stable)
reg [3:0] r_sw_stable;                          // Third FF (output register)

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_sw_meta   <= 4'b0;
        r_sw_sync   <= 4'b0;
        r_sw_stable <= 4'b0;
    end else begin
        r_sw_meta   <= i_sw;
        r_sw_sync   <= r_sw_meta;
        r_sw_stable <= r_sw_sync;
    end
end

//============================================================================
// Mode Control Outputs
//============================================================================
assign o_p2_mode_active = r_sw_stable[0];  // SW[0] = Player 2 mode modifier
assign o_single_player  = r_sw_stable[1];  // SW[1] = Single player mode

//============================================================================
// Joystick Mapping Logic (Combinational)
//============================================================================
// Internal mode wires for cleaner logic
wire w_p2_mode   = r_sw_stable[0];
wire w_single_p  = r_sw_stable[1];

// Player 1 controls (active when SW[0]=0)
wire w_p1_fire   = r_btn_debounced[0] & ~w_p2_mode;  // BTN[0] = Fire
wire w_p1_ccw    = r_btn_debounced[3] & ~w_p2_mode;  // BTN[3] = LEFT = CCW
wire w_p1_thrust = r_btn_debounced[1] & ~w_p2_mode;  // BTN[1] = UP = Thrust
wire w_p1_cw     = r_btn_debounced[4] & ~w_p2_mode;  // BTN[4] = RIGHT = CW

// Player 2 controls (active when SW[0]=1 and not single player)
wire w_p2_fire   = r_btn_debounced[2] & w_p2_mode & ~w_single_p;  // BTN[2] = DOWN = Fire
wire w_p2_ccw    = r_btn_debounced[3] & w_p2_mode & ~w_single_p;  // BTN[3] = LEFT = CCW
wire w_p2_thrust = r_btn_debounced[1] & w_p2_mode & ~w_single_p;  // BTN[1] = UP = Thrust
wire w_p2_cw     = r_btn_debounced[4] & w_p2_mode & ~w_single_p;  // BTN[4] = RIGHT = CW

//============================================================================
// Output Register
// Registered output for clean timing to downstream logic
//============================================================================
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_joystick_emu <= 8'b0;
    end else begin
        o_joystick_emu[0] <= w_p1_fire;    // P1 fire
        o_joystick_emu[1] <= w_p1_ccw;     // P1 left (CCW)
        o_joystick_emu[2] <= w_p1_thrust;  // P1 thrust
        o_joystick_emu[3] <= w_p1_cw;      // P1 right (CW)
        o_joystick_emu[4] <= w_p2_fire;    // P2 fire
        o_joystick_emu[5] <= w_p2_ccw;     // P2 left (CCW)
        o_joystick_emu[6] <= w_p2_thrust;  // P2 thrust
        o_joystick_emu[7] <= w_p2_cw;      // P2 right (CW)
    end
end

//============================================================================
// LED Feedback Output
// Direct mirror of joystick state for visual debugging
// Lower 4 LEDs = Player 1, Upper 4 LEDs = Player 2
//============================================================================
assign o_led_feedback = o_joystick_emu;

//============================================================================
// Direct Button Output (for Pong compatibility)
// No SW[0] mode modifier - buttons directly accessible
// Pong needs: BTN[1]=P1 UP, BTN[2]=P1 DOWN, BTN[5]=P2 UP, BTN[6]=P2 DOWN
//============================================================================
assign o_btn_direct = r_btn_debounced;

endmodule

`default_nettype wire  // Restore default for other modules
