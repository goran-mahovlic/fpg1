/**
 * @file spi_fpga.h
 * @brief ESP32 SPI Driver for FPGA Communication
 *
 * MiSTer-compatible SPI protocol implementation for OSD and file transfer.
 * Provides command interface for menu overlay, joystick input, and ROM loading.
 */

#pragma once

#include <stdint.h>
#include <stddef.h>

// ============================================================================
// MiSTer-compatible SPI Commands
// ============================================================================

// OSD Commands
#define OSD_CMD_DISABLE  0x40    // Disable OSD overlay
#define OSD_CMD_ENABLE   0x41    // Enable OSD overlay
#define OSD_CMD_WRITE    0x20    // Write OSD line (0x20-0x2F for lines 0-15)

// Status and Input Commands
#define STATUS_SET       0x1E    // Set core status bits
#define JOYSTICK_0       0x02    // Player 1 joystick state
#define JOYSTICK_1       0x03    // Player 2 joystick state

// File Transfer Commands
#define FILE_TX          0x53    // Start file transfer
#define FILE_TX_DAT      0x54    // File data byte
#define FILE_INDEX       0x55    // Set file slot index

// ============================================================================
// Transfer Configuration
// ============================================================================

#define SPI_CHUNK_SIZE   256    // OSD buffer chunk size in bytes
#define SPI_TIMEOUT_MS   100    // Command timeout in milliseconds

// ============================================================================
// SPIFpga Class
// ============================================================================

/**
 * @class SPIFpga
 * @brief SPI master driver for FPGA communication
 *
 * Implements MiSTer-compatible protocol with handshaking support.
 * Uses ESP-IDF SPI master driver for hardware acceleration.
 */
class SPIFpga {
public:
    /**
     * @brief Initialize SPI peripheral and GPIO pins
     * @return true if initialization successful
     */
    bool init();

    /**
     * @brief Send raw command with optional data payload
     * @param cmd Command byte
     * @param data Optional data buffer
     * @param len Length of data buffer
     */
    void sendCommand(uint8_t cmd, const uint8_t* data = nullptr, size_t len = 0);

    /**
     * @brief Send OSD framebuffer lines to FPGA
     * @param buffer Pointer to OSD pixel buffer
     * @param lineStart First line to transfer
     * @param numLines Number of lines to transfer
     */
    void sendOsdBuffer(const uint8_t* buffer, size_t lineStart, size_t numLines);

    /**
     * @brief Enable or disable OSD overlay
     * @param enable true to show OSD, false to hide
     */
    void setOsdEnable(bool enable);

    /**
     * @brief Set FPGA core status register
     * @param status 32-bit status value
     */
    void setStatus(uint32_t status);

    /**
     * @brief Update joystick state for player
     * @param player Player index (0 or 1)
     * @param state 16-bit joystick button/direction state
     */
    void setJoystick(uint8_t player, uint16_t state);

    /**
     * @brief Begin file transfer to specified slot
     * @param index File slot index
     */
    void startFileTransfer(uint8_t index);

    /**
     * @brief Send single byte during file transfer
     * @param byte Data byte to transfer
     */
    void sendFileData(uint8_t byte);

    /**
     * @brief Complete file transfer and release bus
     */
    void endFileTransfer();

    /**
     * @brief Check if FPGA is ready for commands
     * @return true if FPGA ready signal is asserted
     */
    bool isReady();

    /**
     * @brief Check if FPGA has pending interrupt
     * @return true if IRQ signal is asserted
     */
    bool hasIrq();

private:
    /**
     * @brief Assert chip select (active low)
     */
    void assertCS();

    /**
     * @brief Deassert chip select
     */
    void deassertCS();

    /**
     * @brief Wait for FPGA ready signal with timeout
     * @return true if ready, false if timeout
     */
    bool waitReady();

    /**
     * @brief Transfer single byte over SPI
     * @param data Byte to transmit
     * @return Received byte
     */
    uint8_t transfer(uint8_t data);

    /**
     * @brief Transfer buffer over SPI
     * @param txBuf Transmit buffer (can be nullptr)
     * @param rxBuf Receive buffer (can be nullptr)
     * @param len Transfer length
     */
    void transferBuffer(const uint8_t* txBuf, uint8_t* rxBuf, size_t len);

    bool m_initialized = false;
    bool m_transferActive = false;
};

// Global SPI FPGA instance
extern SPIFpga spiFpga;
