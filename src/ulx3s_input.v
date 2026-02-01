//============================================================================
// ULX3S Input Module for PDP-1 Spacewar!
// TASK-195: Keyboard/Joystick Mapping
// Author: Grga Pitic, REGOC periferija expert
//============================================================================
//
// ULX3S Hardware:
//   - 7 buttons: BTN[6:0]
//   - 4 DIP switches: SW[3:0]
//
// Button Layout (active high after active-low board input):
//   BTN[0] = PWR (active low on board, directly under FPGA)
//   BTN[1] = UP
//   BTN[2] = DOWN
//   BTN[3] = LEFT
//   BTN[4] = RIGHT
//   BTN[5] = F1 (active low on board)
//   BTN[6] = F2 (active low on board)
//
// Spacewar! Control Mapping:
//   Player 1 (Left player - "Needle"):
//     BTN[3] = Rotate CCW (counter-clockwise)
//     BTN[4] = Rotate CW (clockwise)
//     BTN[1] = Thrust
//     BTN[0] = Fire torpedo
//
//   Player 2 (Right player - "Wedge"):
//     SW[0] + BTN[3] = Rotate CCW
//     SW[0] + BTN[4] = Rotate CW
//     SW[0] + BTN[1] = Thrust
//     SW[0] + BTN[2] = Fire torpedo
//
//   Alternative: SW[1] enables single-player mode (P1 only)
//
// Output joystick_emu format (matches keyboard.v):
//   [0] = P1 fire
//   [1] = P1 left (CCW)
//   [2] = P1 thrust
//   [3] = P1 right (CW)
//   [4] = P2 fire
//   [5] = P2 left (CCW)
//   [6] = P2 thrust
//   [7] = P2 right (CW)
//
//============================================================================

module ulx3s_input #(
    parameter CLK_FREQ = 25_000_000,   // Clock frequency in Hz
    parameter DEBOUNCE_MS = 10         // Debounce time in milliseconds
)(
    input  wire        clk,
    input  wire        rst_n,

    // ULX3S hardware inputs (directly from pins, active low buttons)
    input  wire [6:0]  btn_n,          // Buttons active low from board
    input  wire [3:0]  sw,             // DIP switches

    // Joystick emulation output (active high, directly usable)
    output reg  [7:0]  joystick_emu,

    // LED feedback output
    output wire [7:0]  led_feedback,

    // Additional control signals
    output wire        p2_mode_active, // Player 2 mode active indicator
    output wire        single_player   // Single player mode indicator
);

//============================================================================
// Parameters and Constants
//============================================================================
localparam DEBOUNCE_COUNT = (CLK_FREQ / 1000) * DEBOUNCE_MS;
localparam CNT_WIDTH = $clog2(DEBOUNCE_COUNT + 1);

//============================================================================
// Active high conversion from active low buttons
//============================================================================
wire [6:0] btn_raw;
assign btn_raw = ~btn_n;  // Convert active low to active high

//============================================================================
// Debounce Logic
// - Each button gets its own debounce counter
// - Output is stable after DEBOUNCE_MS milliseconds
//============================================================================
reg [CNT_WIDTH-1:0] debounce_cnt [6:0];
reg [6:0] btn_sync_0, btn_sync_1;  // Double FF synchronizer
reg [6:0] btn_debounced;

integer i;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        btn_sync_0 <= 7'b0;
        btn_sync_1 <= 7'b0;
        btn_debounced <= 7'b0;
        for (i = 0; i < 7; i = i + 1) begin
            debounce_cnt[i] <= 0;
        end
    end else begin
        // Synchronize inputs (metastability protection)
        btn_sync_0 <= btn_raw;
        btn_sync_1 <= btn_sync_0;

        // Debounce each button
        for (i = 0; i < 7; i = i + 1) begin
            if (btn_sync_1[i] != btn_debounced[i]) begin
                // Button state changed, start/continue counting
                if (debounce_cnt[i] < DEBOUNCE_COUNT) begin
                    debounce_cnt[i] <= debounce_cnt[i] + 1;
                end else begin
                    // Stable for long enough, accept new state
                    btn_debounced[i] <= btn_sync_1[i];
                    debounce_cnt[i] <= 0;
                end
            end else begin
                // Button stable, reset counter
                debounce_cnt[i] <= 0;
            end
        end
    end
end

//============================================================================
// DIP Switch Synchronization (no debounce needed, they're stable)
//============================================================================
reg [3:0] sw_sync_0, sw_sync_1;
reg [3:0] sw_stable;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sw_sync_0 <= 4'b0;
        sw_sync_1 <= 4'b0;
        sw_stable <= 4'b0;
    end else begin
        sw_sync_0 <= sw;
        sw_sync_1 <= sw_sync_0;
        sw_stable <= sw_sync_1;
    end
end

//============================================================================
// Mode Control
//============================================================================
assign p2_mode_active = sw_stable[0];  // SW[0] = Player 2 mode modifier
assign single_player  = sw_stable[1];  // SW[1] = Single player mode

//============================================================================
// Joystick Mapping Logic
//============================================================================
// Player 1 controls (active when SW[0] = 0, or always in single player)
wire p1_fire, p1_ccw, p1_thrust, p1_cw;

// Player 2 controls (active when SW[0] = 1 and not single player)
wire p2_fire, p2_ccw, p2_thrust, p2_cw;

// Player 1: Direct button mapping
assign p1_fire   = btn_debounced[0] & ~p2_mode_active;  // BTN[0] = Fire
assign p1_ccw    = btn_debounced[3] & ~p2_mode_active;  // BTN[3] = LEFT = CCW
assign p1_thrust = btn_debounced[1] & ~p2_mode_active;  // BTN[1] = UP = Thrust
assign p1_cw     = btn_debounced[4] & ~p2_mode_active;  // BTN[4] = RIGHT = CW

// Player 2: Same buttons but with SW[0] modifier
assign p2_fire   = btn_debounced[2] & p2_mode_active & ~single_player;  // BTN[2] = DOWN = Fire
assign p2_ccw    = btn_debounced[3] & p2_mode_active & ~single_player;  // BTN[3] = LEFT = CCW
assign p2_thrust = btn_debounced[1] & p2_mode_active & ~single_player;  // BTN[1] = UP = Thrust
assign p2_cw     = btn_debounced[4] & p2_mode_active & ~single_player;  // BTN[4] = RIGHT = CW

//============================================================================
// Output Assignment
//============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        joystick_emu <= 8'b0;
    end else begin
        joystick_emu[0] <= p1_fire;    // P1 fire
        joystick_emu[1] <= p1_ccw;     // P1 left (CCW)
        joystick_emu[2] <= p1_thrust;  // P1 thrust
        joystick_emu[3] <= p1_cw;      // P1 right (CW)
        joystick_emu[4] <= p2_fire;    // P2 fire
        joystick_emu[5] <= p2_ccw;     // P2 left (CCW)
        joystick_emu[6] <= p2_thrust;  // P2 thrust
        joystick_emu[7] <= p2_cw;      // P2 right (CW)
    end
end

//============================================================================
// LED Feedback
// - Shows current joystick state for debugging
// - Lower 4 LEDs = Player 1 controls
// - Upper 4 LEDs = Player 2 controls (when active)
//============================================================================
assign led_feedback = joystick_emu;

endmodule
