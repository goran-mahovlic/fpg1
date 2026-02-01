/* 1024 x 768 @ 50 Hz constants (TASK-XXX: upgrade rezolucije, Jelena Horvat)   */
/* Pixel clock: 51 MHz, Frame rate: 51M / (1264*808) = 49.93 Hz                 */
/*                                                                               */
/* Timing izracun za 1024x768@50Hz:                                             */
/* H total = 1024 + 24 (front) + 136 (sync) + 80 (back) = 1264                  */
/* V total = 768 + 3 (front) + 6 (sync) + 31 (back) = 808                       */
/* Frame rate = 51,000,000 / (1264 * 808) = 49.93 Hz                            */
/*                                                                               */
/* NAPOMENA: Koristimo 50Hz umjesto 60Hz jer:                                   */
/* - 60Hz: 65 MHz pixel = 325 MHz shift (marginalno za ECP5)                    */
/* - 50Hz: 51 MHz pixel = 255 MHz shift (sigurno < 400 MHz limit)               */

`define   h_front_porch          11'd24
`define   h_back_porch           11'd80

`define   h_sync_pulse           11'd136

`define   v_sync_pulse           11'd6
`define   v_front_porch          11'd3
`define   v_back_porch           11'd31

`define   h_line_timing          11'd1264      /* 1024 + 24 + 136 + 80 = 1264 */
`define   v_line_timing          11'd808       /* 768 + 3 + 6 + 31 = 808 */

`define   h_visible_offset       11'd240       /* h_sync + h_back + h_front = 136 + 80 + 24 = 240 */
`define   h_center_offset        11'd0         /* Bez centriranja - koristi puni 1024x1024 PDP-1 display */
`define   h_visible_offset_end   11'd1264      /* h_visible_offset + 1024 = 240 + 1024 = 1264 */

`define   v_visible_offset       11'd40        /* v_front + v_sync + v_back = 3 + 6 + 31 = 40 */
`define   v_visible_offset_end   11'd808       /* v_visible_offset + v_visible = 40 + 768 = 808 */

/* CRT vertical offset - pomice PDP-1 sliku dolje za N linija */
/* PDP-1 ima 1024x1024 koordinatni sustav, VGA prikazuje 768 linija */
/* Offset 128 pomice vidljivo podrucje s 0-767 na 128-895 */
`define   v_crt_offset           10'd128       /* Vertikalni pomak slike u PDP-1 koordinatama */


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
