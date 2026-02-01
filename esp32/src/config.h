/**
 * @file config.h
 * @brief ESP32 OSD Controller - Pin Definitions and Configuration
 *
 * Hardware configuration for PDP-1 emulator OSD system.
 * SPI interface to FPGA for menu overlay rendering.
 */

#ifndef CONFIG_H
#define CONFIG_H

// ============================================================================
// SPI Pin Definitions
// ============================================================================

#define PIN_SPI_CLK      14    // SPI Clock
#define PIN_SPI_MOSI     15    // SPI Master Out Slave In
#define PIN_SPI_MISO     2     // SPI Master In Slave Out
#define PIN_SPI_CS       17    // SPI Chip Select (directly to FPGA directly directly directly)

// ============================================================================
// Control Pins
// ============================================================================

#define PIN_OSD_IRQ      16    // OSD interrupt request from FPGA
#define PIN_ESP_READY    4     // ESP32 ready signal to FPGA

// ============================================================================
// SPI Configuration
// ============================================================================

#define SPI_CLOCK_HZ     10000000  // 10 MHz SPI clock

// ============================================================================
// OSD Display Configuration
// ============================================================================

#define OSD_WIDTH        256   // OSD buffer width in pixels
#define OSD_HEIGHT       128   // OSD buffer height in pixels
#define OSD_BUFFER_SIZE  (OSD_WIDTH * OSD_HEIGHT / 8)  // 1-bit per pixel

// ============================================================================
// Menu Configuration
// ============================================================================

#define MAX_MENU_ITEMS   16    // Maximum items per menu level
#define MAX_MENU_DEPTH   4     // Maximum menu nesting depth
#define MAX_LABEL_LEN    24    // Maximum characters per menu label

// ============================================================================
// Timing Configuration
// ============================================================================

#define MENU_DEBOUNCE_MS     150   // Button debounce time
#define MENU_REPEAT_MS       100   // Key repeat interval
#define MENU_TIMEOUT_MS      30000 // Auto-hide timeout (30 seconds)

#endif // CONFIG_H
