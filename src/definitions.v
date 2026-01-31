/* 640 x 480 @ 60 Hz constants (TASK-200: smanjena rezolucija za timing fix) */
/* Pixel clock: 25 MHz, Frame rate: 25M / (800*525) = 59.52 Hz              */

`define   h_front_porch          11'd16
`define   h_back_porch           11'd48

`define   h_sync_pulse           11'd96

`define   v_sync_pulse           11'd2
`define   v_front_porch          11'd10
`define   v_back_porch           11'd33

`define   h_line_timing          11'd800
`define   v_line_timing          11'd525

`define   h_visible_offset       11'd160       /* h_front_porch + h_sync_pulse + h_back_porch = 16+96+48 = 160 */
`define   h_center_offset        11'd64        /* (640-512)/2 = 64, za centriranje PDP-1 512x512 displeja */
`define   h_visible_offset_end   11'd704       /* h_visible_offset + 640 - h_center_offset = 160 + 640 - 64 - 32 = 704 */

`define   v_visible_offset       11'd45        /* v_front_porch + v_sync_pulse + v_back_porch = 10+2+33 = 45 */
`define   v_visible_offset_end   11'd525       /* v_visible_offset + 480 = 45 + 480 = 525 */


/* Joystick, defined in core configuration string as 
   "J,Left,Right,Thrust,Fire,HyperSpace;", therefore:
*/

`define   joystick_left          5'd4
`define   joystick_right         5'd5
`define   joystick_thrust        5'd6
`define   joystick_fire          5'd7
`define   joystick_hyperspace    5'd8


/* Outputs */

`define   output_crt             2'b00
`define   output_console         2'b01
`define   output_teletype        2'b10

/* Status options */

`define  menu_enable_rim            status[5]
`define  menu_disable_rim           status[6]
`define  menu_reset                 status[7]
`define  menu_aspect_ratio          status[1]
`define  menu_hardware_multiply     status[4]
`define  menu_variable_brightness   status[8]
`define  menu_crt_wait              status[9]


/* Console switches */

`define  start_button               console_switches[0]
`define  stop_button                console_switches[1]
`define  continue_button            console_switches[2]
`define  examine_button             console_switches[3]
`define  deposit_button             console_switches[4]
`define  readin_button              console_switches[5]
`define  reader_button              console_switches[6]
`define  tapefeed_button            console_switches[7]

`define  single_inst_switch         console_switches[8]
`define  single_step_switch         console_switches[9]
`define  power_switch               console_switches[10]


/* Teletype special characters */

`define  lowercase                  6'o72
`define  uppercase                  6'o74
`define  carriage_return            6'o77
