# ESP32 OSD Design Document for ULX3S PDP-1 Emulator

**Version:** 1.0
**Date:** 2026-01-31
**Author:** Grga Babic, UI/UX Designer, REGOC Team
**Task:** TASK-120

---

## 1. Executive Summary

This document defines the On-Screen Display (OSD) system design for the PDP-1 emulator running on ULX3S (ECP5 FPGA) with ESP32 as the control processor. The design is MiSTer-compatible in protocol and user experience, adapted for ESP32-specific hardware constraints.

### Key Design Decisions

| Aspect | MiSTer Original | ULX3S ESP32 Adaptation |
|--------|-----------------|------------------------|
| Communication | 16-bit parallel HPS bus | SPI (10 MHz max) |
| Control Processor | ARM HPS (DE10-Nano) | ESP32-WROOM |
| OSD Resolution | 256x64 pixels | 256x128 pixels (extended) |
| Menu Rendering | HPS-side | ESP32-side |
| File System | SD via HPS | SD via ESP32 (shared pins) |

---

## 2. System Architecture

### 2.1 Block Diagram

```
+------------------+       SPI Bus        +------------------+
|                  |  MOSI/MISO/SCK/CS    |                  |
|     ESP32        |<-------------------->|    ECP5 FPGA     |
|   (Controller)   |                      |   (PDP-1 Core)   |
|                  |       GPIO           |                  |
|  +------------+  |  IRQ/READY lines     |  +------------+  |
|  | WiFi/BT    |  |<-------------------->|  | OSD Module |  |
|  +------------+  |                      |  +------------+  |
|  +------------+  |                      |  +------------+  |
|  | SD Card    |  |  (Directly shared)   |  | Video Mixer|  |
|  +------------+  |                      |  +------------+  |
+------------------+                      +------------------+
        |                                          |
        v                                          v
   [WiFi Config]                            [HDMI Output]
   [Web Interface]                          [640x480@60Hz]
```

### 2.2 ULX3S ESP32-FPGA Pin Mapping

Based on ULX3S v3.x board design:

| Signal | ESP32 GPIO | FPGA Pin | Direction | Description |
|--------|------------|----------|-----------|-------------|
| SPI_CLK | GPIO14 | GN11 | ESP32->FPGA | SPI Clock (max 10 MHz) |
| SPI_MOSI | GPIO15 | GP11 | ESP32->FPGA | Master Out, Slave In |
| SPI_MISO | GPIO2 | GP12 | FPGA->ESP32 | Master In, Slave Out |
| SPI_CS | GPIO17 | GN12 | ESP32->FPGA | Chip Select (active low) |
| OSD_IRQ | GPIO16 | GP13 | FPGA->ESP32 | Interrupt request |
| ESP_READY | GPIO4 | GN13 | ESP32->FPGA | ESP32 ready for data |

**Note:** GPIO5 should NOT be driven high during boot (interferes with programming).

---

## 3. Communication Protocol

### 3.1 SPI Configuration

```
Mode:           SPI Mode 0 (CPOL=0, CPHA=0)
Clock Speed:    10 MHz maximum (ESP32 SPI slave limit)
Word Size:      8-bit (assembled into 16-bit commands)
Byte Order:     MSB first
CS Polarity:    Active Low
```

### 3.2 Command Frame Format

Each command consists of a command byte followed by optional data bytes:

```
| CMD (8-bit) | DATA0 (8-bit) | DATA1 (8-bit) | ... |
```

### 3.3 Command Set (MiSTer-Compatible)

| Command | Code | Parameters | Description |
|---------|------|------------|-------------|
| OSD_CMD_ENABLE | 0x41 | x,y,w,h (4x16-bit) | Enable OSD at position |
| OSD_CMD_DISABLE | 0x40 | - | Disable OSD |
| OSD_CMD_WRITE | 0x20-0x2F | offset,data[] | Write to OSD buffer |
| CFG_READ | 0x14 | offset | Read config string byte |
| STATUS_SET | 0x1E | status[31:0] | Set status bits |
| JOYSTICK_0 | 0x02 | joy[15:0] | Joystick 0 state |
| JOYSTICK_1 | 0x03 | joy[15:0] | Joystick 1 state |
| FILE_TX | 0x53 | enable | Start/stop file transfer |
| FILE_TX_DAT | 0x54 | data | File data byte |
| FILE_INDEX | 0x55 | index | Set file index |
| KEYBOARD | 0x05 | scancode | PS/2 key event |

### 3.4 Handshaking Protocol

```
ESP32                              FPGA
  |                                  |
  |-- Assert CS low ---------------->|
  |-- Send CMD byte ---------------->|
  |<-- Wait for READY high ----------|
  |-- Send/Receive DATA bytes ------>|
  |-- Deassert CS high ------------->|
  |                                  |
```

For file transfers, IRQ line signals when FPGA needs more data.

---

## 4. OSD Module Design (FPGA Side)

### 4.1 Module Interface

```verilog
module esp32_osd #(
    parameter OSD_COLOR    = 3'd4,    // Cyan
    parameter OSD_X_OFFSET = 12'd0,
    parameter OSD_Y_OFFSET = 12'd0,
    parameter OSD_WIDTH    = 12'd256,
    parameter OSD_HEIGHT   = 12'd128  // Extended from 64
)(
    // System
    input         clk_sys,            // System clock (50 MHz)
    input         clk_video,          // Video clock (25 MHz)
    input         rst_n,              // Active low reset

    // SPI Interface
    input         spi_clk,
    input         spi_mosi,
    output        spi_miso,
    input         spi_cs_n,

    // Handshake
    output        osd_irq,            // Interrupt to ESP32
    input         esp_ready,          // ESP32 ready signal

    // Video Input (from CRT)
    input  [23:0] video_in,           // RGB888
    input         video_de,           // Data enable
    input         video_hs,           // Horizontal sync
    input         video_vs,           // Vertical sync

    // Video Output (to HDMI encoder)
    output [23:0] video_out,          // RGB888 with OSD overlay
    output        video_de_out,
    output        video_hs_out,
    output        video_vs_out,

    // Control outputs
    output [31:0] status,             // Menu status bits
    output [15:0] joystick_0,         // Joystick state
    output [15:0] joystick_1,

    // File I/O
    output        ioctl_download,     // Download in progress
    output  [7:0] ioctl_index,        // File type index
    output        ioctl_wr,           // Write strobe
    output [24:0] ioctl_addr,         // Write address
    output  [7:0] ioctl_dout,         // Write data
    input         ioctl_wait          // Core not ready
);
```

### 4.2 Internal Architecture

```
+------------------+     +------------------+     +------------------+
|  SPI Slave       |---->|  Command Decoder |---->|  OSD Buffer      |
|  (CDC included)  |     |  & State Machine |     |  (256x16 bytes)  |
+------------------+     +------------------+     +------------------+
                                  |                        |
                                  v                        v
                         +------------------+     +------------------+
                         |  Status/Control  |     |  OSD Renderer    |
                         |  Registers       |     |  (pixel gen)     |
                         +------------------+     +------------------+
                                                           |
                                                           v
                                                  +------------------+
                                                  |  Video Mixer     |
                                                  |  (overlay)       |
                                                  +------------------+
```

### 4.3 Clock Domain Crossing

SPI operates at 10 MHz, FPGA system at 50 MHz, video at 25 MHz:

```verilog
// SPI to system clock CDC
reg [2:0] spi_clk_sync;
always @(posedge clk_sys) spi_clk_sync <= {spi_clk_sync[1:0], spi_clk};
wire spi_clk_rising = (spi_clk_sync[2:1] == 2'b01);

// OSD buffer is dual-port RAM
// Port A: Write from SPI domain (clk_sys synchronized)
// Port B: Read from video domain (clk_video)
```

---

## 5. ESP32 Firmware Architecture

### 5.1 Component Structure

```
esp32_osd_firmware/
├── src/
│   ├── main.cpp              # Entry point, task creation
│   ├── spi_fpga.cpp          # FPGA SPI communication
│   ├── spi_fpga.h
│   ├── osd_menu.cpp          # Menu rendering & navigation
│   ├── osd_menu.h
│   ├── file_browser.cpp      # SD card file browser
│   ├── file_browser.h
│   ├── file_transfer.cpp     # ROM/RIM file transfer
│   ├── file_transfer.h
│   ├── input_handler.cpp     # Button/joystick handling
│   ├── input_handler.h
│   ├── wifi_manager.cpp      # WiFi configuration
│   ├── wifi_manager.h
│   └── config.h              # Pin definitions, constants
├── platformio.ini
└── README.md
```

### 5.2 Main Loop Pseudocode

```cpp
void app_main() {
    // Initialize hardware
    init_spi_master();
    init_gpio();
    init_sd_card();
    init_wifi();  // Optional, for future web config

    // Main loop
    while (true) {
        // Handle button input
        if (button_pressed(BTN_MENU)) {
            toggle_osd();
        }

        if (osd_visible) {
            handle_menu_navigation();
            render_osd_to_buffer();
            send_osd_buffer_to_fpga();
        }

        // Handle file transfer if active
        if (file_transfer_active) {
            process_file_transfer();
        }

        // Send joystick state
        send_joystick_state();

        // Check for IRQ from FPGA
        if (gpio_read(OSD_IRQ)) {
            handle_fpga_request();
        }

        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
```

### 5.3 SPI Communication Implementation

```cpp
// config.h
#define SPI_FPGA_HOST    HSPI_HOST
#define PIN_SPI_CLK      14
#define PIN_SPI_MOSI     15
#define PIN_SPI_MISO     2
#define PIN_SPI_CS       17
#define PIN_OSD_IRQ      16
#define PIN_ESP_READY    4
#define SPI_CLOCK_HZ     10000000  // 10 MHz

// spi_fpga.cpp
void send_osd_command(uint8_t cmd, uint8_t* data, size_t len) {
    spi_transaction_t trans = {
        .length = (1 + len) * 8,
        .tx_buffer = tx_buffer,
        .rx_buffer = rx_buffer
    };

    tx_buffer[0] = cmd;
    memcpy(tx_buffer + 1, data, len);

    gpio_set_level(PIN_ESP_READY, 1);
    spi_device_transmit(spi_handle, &trans);
    gpio_set_level(PIN_ESP_READY, 0);
}

void send_osd_buffer(uint8_t* buffer, size_t line_start, size_t num_lines) {
    uint8_t cmd = 0x20 | (line_start >> 8);
    uint8_t offset = line_start & 0xFF;

    // Send in chunks of 256 bytes
    for (size_t i = 0; i < num_lines * 32; i += 256) {
        send_osd_command(cmd, buffer + i, 256);
    }
}
```

---

## 6. Menu Structure for PDP-1

### 6.1 Configuration String (CONF_STR equivalent)

```
PDP1;;
-;
F,PDPRIMBIN;
-;
O1,Aspect Ratio,Original,Wide;
O4,Hardware multiply,No,Yes;
O8,Var. brightness,Yes,No;
O9,CRT wait,No,Yes;
-;
R7,Reset;
-;
J,Fire,Thrust,Left,Right,Hyper;
V,v1.00
```

### 6.2 Menu Layout (256x128 pixels)

```
+------------------------------------------+
|  PDP-1 Emulator           [ULX3S v1.0]  |
+------------------------------------------+
|  > Load ROM File...                      |
|    Load RIM File...                      |
|  ----------------------------------      |
|    Aspect Ratio:     [Original]          |
|    Hardware Multiply: [Yes]              |
|    Variable Brightness: [Yes]            |
|    CRT Wait:          [No]               |
|  ----------------------------------      |
|    Reset                                 |
|  ----------------------------------      |
|    System Info                           |
+------------------------------------------+
|  [UP/DOWN: Navigate] [LEFT/RIGHT: Value] |
+------------------------------------------+
```

### 6.3 Status Bit Mapping

| Bit | Function | Values |
|-----|----------|--------|
| 0 | Reserved (Soft Reset) | - |
| 1 | Aspect Ratio | 0=Original, 1=Wide |
| 4 | Hardware Multiply | 0=No, 1=Yes |
| 5 | RIM Mode Enable | Trigger |
| 6 | RIM Mode Disable | Trigger |
| 7 | Reset | Trigger |
| 8 | Variable Brightness | 0=Yes, 1=No |
| 9 | CRT Wait | 0=No, 1=Yes |

---

## 7. File Transfer Protocol

### 7.1 ROM/RIM Loading Sequence

```
ESP32                              FPGA
  |                                  |
  |-- FILE_INDEX (index=0) --------->|  // Set file type
  |-- FILE_TX (enable=1) ----------->|  // Start transfer
  |                                  |
  |-- FILE_TX_DAT (byte 0) --------->|  // Send data
  |-- FILE_TX_DAT (byte 1) --------->|
  |   ...                            |
  |<-- IRQ (if ioctl_wait) ----------|  // Wait if needed
  |   ...                            |
  |-- FILE_TX_DAT (last byte) ------>|
  |-- FILE_TX (enable=0) ----------->|  // End transfer
  |                                  |
```

### 7.2 File Browser Implementation

```cpp
struct FileEntry {
    char name[32];
    uint32_t size;
    bool is_directory;
};

class FileBrowser {
public:
    void set_directory(const char* path);
    void set_filter(const char* extensions);  // "PDP,RIM,BIN"
    FileEntry* get_entries();
    size_t get_entry_count();
    void navigate_up();
    void navigate_into(size_t index);
    const char* get_current_path();

private:
    char current_path[256];
    std::vector<FileEntry> entries;
    char filter[32];
};
```

---

## 8. Input Handling

### 8.1 ULX3S Button Mapping (from ulx3s_input.v)

| Button | Function (OSD Active) | Function (OSD Hidden) |
|--------|----------------------|----------------------|
| BTN0 | (Reserved - WiFi) | (Reserved - WiFi) |
| BTN1 | Menu Up | Player 2 Fire |
| BTN2 | Menu Down | Player 2 Thrust |
| BTN3 | Menu Left/Back | Player 2 Left |
| BTN4 | Menu Right/Enter | Player 2 Right |
| BTN5 | Toggle OSD | Toggle OSD |
| BTN6 | Select/OK | Player 1 Hyperspace |

### 8.2 USB Keyboard Support (Future)

ESP32 can act as USB Host for keyboards:

```cpp
// Keyboard to PS/2 scancode conversion
void send_key_event(uint8_t usb_keycode, bool pressed) {
    uint8_t ps2_code = usb_to_ps2_map[usb_keycode];
    uint8_t scancode[3];

    if (ps2_code & 0x80) {  // Extended key
        scancode[0] = 0xE0;
        scancode[1] = pressed ? (ps2_code & 0x7F) : 0xF0;
        scancode[2] = ps2_code & 0x7F;
        send_osd_command(0x05, scancode, 3);
    } else {
        scancode[0] = pressed ? ps2_code : 0xF0;
        scancode[1] = ps2_code;
        send_osd_command(0x05, scancode, pressed ? 1 : 2);
    }
}
```

---

## 9. Integration with Existing Code

### 9.1 Changes to top_pdp1.v

Add ESP32 SPI pins and OSD module:

```verilog
// Add to port list:
input  wire        esp32_spi_clk,
input  wire        esp32_spi_mosi,
output wire        esp32_spi_miso,
input  wire        esp32_spi_cs_n,
output wire        esp32_osd_irq,
input  wire        esp32_ready,

// Instantiate OSD module:
esp32_osd #(
    .OSD_COLOR(3'd4)  // Cyan
) osd_inst (
    .clk_sys(clk_cpu),
    .clk_video(clk_pixel),
    .rst_n(rst_pixel_n),

    .spi_clk(esp32_spi_clk),
    .spi_mosi(esp32_spi_mosi),
    .spi_miso(esp32_spi_miso),
    .spi_cs_n(esp32_spi_cs_n),

    .osd_irq(esp32_osd_irq),
    .esp_ready(esp32_ready),

    .video_in({vga_r, vga_g, vga_b}),
    .video_de(vga_de),
    .video_hs(vga_hsync),
    .video_vs(vga_vsync),

    .video_out({osd_r, osd_g, osd_b}),
    .video_de_out(osd_de),
    .video_hs_out(osd_hs),
    .video_vs_out(osd_vs),

    .status(osd_status),
    .joystick_0(osd_joystick_0),
    .joystick_1(osd_joystick_1),

    .ioctl_download(osd_ioctl_download),
    .ioctl_index(osd_ioctl_index),
    .ioctl_wr(osd_ioctl_wr),
    .ioctl_addr(osd_ioctl_addr),
    .ioctl_dout(osd_ioctl_dout),
    .ioctl_wait(osd_ioctl_wait)
);
```

### 9.2 Pin Constraints (ulx3s_v31.lpf)

```
# ESP32 SPI for OSD
LOCATE COMP "esp32_spi_clk"  SITE "L2";   # GN11
LOCATE COMP "esp32_spi_mosi" SITE "N3";   # GP11
LOCATE COMP "esp32_spi_miso" SITE "N1";   # GP12
LOCATE COMP "esp32_spi_cs_n" SITE "M1";   # GN12
LOCATE COMP "esp32_osd_irq"  SITE "L1";   # GP13
LOCATE COMP "esp32_ready"    SITE "L3";   # GN13

IOBUF PORT "esp32_spi_clk"  PULLMODE=DOWN IO_TYPE=LVCMOS33;
IOBUF PORT "esp32_spi_mosi" PULLMODE=DOWN IO_TYPE=LVCMOS33;
IOBUF PORT "esp32_spi_miso" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=8;
IOBUF PORT "esp32_spi_cs_n" PULLMODE=UP   IO_TYPE=LVCMOS33;
IOBUF PORT "esp32_osd_irq"  PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=8;
IOBUF PORT "esp32_ready"    PULLMODE=DOWN IO_TYPE=LVCMOS33;
```

---

## 10. Testing Plan

### 10.1 Unit Tests

| Test | Description | Pass Criteria |
|------|-------------|---------------|
| SPI_LOOPBACK | ESP32 sends, reads back via logic analyzer | Data matches |
| OSD_BUFFER | Write pattern, verify on screen | Pattern visible |
| STATUS_BITS | Toggle each status bit | Core responds |
| FILE_XFER | Transfer test file (256 bytes) | Data verified |

### 10.2 Integration Tests

| Test | Description | Pass Criteria |
|------|-------------|---------------|
| OSD_TOGGLE | Press menu button | OSD appears/disappears |
| MENU_NAV | Navigate all menu items | All items accessible |
| ROM_LOAD | Load Spacewar! | Game runs correctly |
| JOYSTICK | Test all directions | Ships respond |

### 10.3 Performance Metrics

| Metric | Target | Method |
|--------|--------|--------|
| OSD Latency | < 16ms | Button to screen update |
| File Transfer | > 100 KB/s | Time to load ROM |
| Input Latency | < 5ms | Button to FPGA response |

---

## 11. Future Enhancements (V3)

1. **WiFi Configuration**
   - Web interface for settings
   - OTA firmware updates
   - ROM download over HTTP

2. **Bluetooth Controller Support**
   - PS4/Xbox controller pairing
   - Custom button mapping

3. **Savestate System**
   - Save/restore emulator state
   - Multiple slots

4. **Screenshot Capture**
   - Capture frame buffer
   - Save to SD card

---

## 12. References

1. [MiSTer FPGA Documentation - Core Configuration String](https://mister-devel.github.io/MkDocs_MiSTer/developer/conf_str/)
2. [ULX3S Manual](https://github.com/emard/ulx3s/blob/master/doc/MANUAL.md)
3. [ESP-IDF SPI Slave Driver](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/peripherals/spi_slave.html)
4. [ESP32 SPI Communication](https://randomnerdtutorials.com/esp32-spi-communication-arduino/)

---

## Appendix A: OSD Character Set

Standard ASCII 7-bit character set with custom symbols:

| Code | Symbol | Description |
|------|--------|-------------|
| 0x10 | - | Arrow up |
| 0x11 | - | Arrow down |
| 0x12 | - | Arrow left |
| 0x13 | - | Arrow right |
| 0x14 | - | Checkbox empty |
| 0x15 | - | Checkbox filled |
| 0x16 | - | Folder icon |
| 0x17 | - | File icon |

---

## Appendix B: Error Codes

| Code | Meaning | Recovery |
|------|---------|----------|
| 0x01 | SPI timeout | Retry command |
| 0x02 | Invalid command | Check protocol |
| 0x03 | Buffer overflow | Reduce data size |
| 0x04 | SD card error | Check card |
| 0x05 | File not found | Check path |
| 0x06 | Transfer aborted | User action or error |

---

**Document End**

*Generated by Grga Babic, REGOC UI/UX Team*
*Task: TASK-120 - ESP32 OSD Design for ULX3S PDP-1*
