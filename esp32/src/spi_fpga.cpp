/**
 * @file spi_fpga.cpp
 * @brief ESP32 SPI Driver Implementation for FPGA Communication
 *
 * Uses ESP-IDF SPI master driver with DMA for efficient transfers.
 * Implements MiSTer-compatible protocol with handshaking.
 */

#include "spi_fpga.h"
#include "config.h"

#include <driver/spi_master.h>
#include <driver/gpio.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <string.h>

static const char* TAG = "SPI_FPGA";

// ============================================================================
// SPI Handle and DMA Buffer
// ============================================================================

static spi_device_handle_t s_spiHandle = nullptr;
static uint8_t* s_dmaBuffer = nullptr;

// DMA-capable buffer size (must be 32-bit aligned)
#define DMA_BUFFER_SIZE  512

// Global instance
SPIFpga spiFpga;

// ============================================================================
// Initialization
// ============================================================================

bool SPIFpga::init() {
    if (m_initialized) {
        ESP_LOGW(TAG, "Already initialized");
        return true;
    }

    ESP_LOGI(TAG, "Initializing SPI FPGA driver");

    // Configure GPIO pins for handshaking
    gpio_config_t io_conf = {};

    // ESP_READY output pin
    io_conf.pin_bit_mask = (1ULL << PIN_ESP_READY);
    io_conf.mode = GPIO_MODE_OUTPUT;
    io_conf.pull_up_en = GPIO_PULLUP_DISABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.intr_type = GPIO_INTR_DISABLE;
    gpio_config(&io_conf);
    gpio_set_level((gpio_num_t)PIN_ESP_READY, 0);

    // OSD_IRQ input pin with pull-up
    io_conf.pin_bit_mask = (1ULL << PIN_OSD_IRQ);
    io_conf.mode = GPIO_MODE_INPUT;
    io_conf.pull_up_en = GPIO_PULLUP_ENABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    gpio_config(&io_conf);

    // CS pin as manual GPIO for fine control
    io_conf.pin_bit_mask = (1ULL << PIN_SPI_CS);
    io_conf.mode = GPIO_MODE_OUTPUT;
    io_conf.pull_up_en = GPIO_PULLUP_ENABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    gpio_config(&io_conf);
    gpio_set_level((gpio_num_t)PIN_SPI_CS, 1);  // CS inactive (high)

    // Configure SPI bus
    spi_bus_config_t busConfig = {};
    busConfig.mosi_io_num = PIN_SPI_MOSI;
    busConfig.miso_io_num = PIN_SPI_MISO;
    busConfig.sclk_io_num = PIN_SPI_CLK;
    busConfig.quadwp_io_num = -1;
    busConfig.quadhd_io_num = -1;
    busConfig.max_transfer_sz = DMA_BUFFER_SIZE;
    busConfig.flags = SPICOMMON_BUSFLAG_MASTER;

    esp_err_t ret = spi_bus_initialize(SPI2_HOST, &busConfig, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize SPI bus: %s", esp_err_to_name(ret));
        return false;
    }

    // Configure SPI device
    spi_device_interface_config_t devConfig = {};
    devConfig.clock_speed_hz = SPI_CLOCK_HZ;
    devConfig.mode = 0;  // CPOL=0, CPHA=0
    devConfig.spics_io_num = -1;  // Manual CS control
    devConfig.queue_size = 4;
    devConfig.flags = 0;

    ret = spi_bus_add_device(SPI2_HOST, &devConfig, &s_spiHandle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add SPI device: %s", esp_err_to_name(ret));
        spi_bus_free(SPI2_HOST);
        return false;
    }

    // Allocate DMA-capable buffer
    s_dmaBuffer = (uint8_t*)heap_caps_malloc(DMA_BUFFER_SIZE, MALLOC_CAP_DMA);
    if (!s_dmaBuffer) {
        ESP_LOGE(TAG, "Failed to allocate DMA buffer");
        spi_bus_remove_device(s_spiHandle);
        spi_bus_free(SPI2_HOST);
        return false;
    }

    m_initialized = true;
    ESP_LOGI(TAG, "SPI FPGA driver initialized (CLK=%d Hz)", SPI_CLOCK_HZ);

    return true;
}

// ============================================================================
// Low-level SPI Operations
// ============================================================================

void SPIFpga::assertCS() {
    gpio_set_level((gpio_num_t)PIN_SPI_CS, 0);
}

void SPIFpga::deassertCS() {
    gpio_set_level((gpio_num_t)PIN_SPI_CS, 1);
}

bool SPIFpga::waitReady() {
    // Signal ESP ready
    gpio_set_level((gpio_num_t)PIN_ESP_READY, 1);

    // Wait for FPGA to acknowledge (IRQ goes low when ready)
    uint32_t startMs = xTaskGetTickCount() * portTICK_PERIOD_MS;
    while (gpio_get_level((gpio_num_t)PIN_OSD_IRQ) != 0) {
        uint32_t elapsed = (xTaskGetTickCount() * portTICK_PERIOD_MS) - startMs;
        if (elapsed > SPI_TIMEOUT_MS) {
            ESP_LOGW(TAG, "Timeout waiting for FPGA ready");
            gpio_set_level((gpio_num_t)PIN_ESP_READY, 0);
            return false;
        }
        taskYIELD();
    }

    return true;
}

bool SPIFpga::isReady() {
    return gpio_get_level((gpio_num_t)PIN_OSD_IRQ) == 0;
}

bool SPIFpga::hasIrq() {
    return gpio_get_level((gpio_num_t)PIN_OSD_IRQ) == 1;
}

uint8_t SPIFpga::transfer(uint8_t data) {
    spi_transaction_t trans = {};
    trans.length = 8;
    trans.tx_buffer = &data;
    trans.rx_buffer = s_dmaBuffer;
    trans.flags = 0;

    esp_err_t ret = spi_device_polling_transmit(s_spiHandle, &trans);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SPI transfer failed: %s", esp_err_to_name(ret));
        return 0xFF;
    }

    return s_dmaBuffer[0];
}

void SPIFpga::transferBuffer(const uint8_t* txBuf, uint8_t* rxBuf, size_t len) {
    if (len == 0) return;

    // Process in chunks that fit in DMA buffer
    size_t offset = 0;
    while (offset < len) {
        size_t chunkLen = (len - offset > DMA_BUFFER_SIZE) ? DMA_BUFFER_SIZE : (len - offset);

        spi_transaction_t trans = {};
        trans.length = chunkLen * 8;

        if (txBuf) {
            memcpy(s_dmaBuffer, txBuf + offset, chunkLen);
            trans.tx_buffer = s_dmaBuffer;
        } else {
            memset(s_dmaBuffer, 0xFF, chunkLen);
            trans.tx_buffer = s_dmaBuffer;
        }

        trans.rx_buffer = s_dmaBuffer;

        esp_err_t ret = spi_device_polling_transmit(s_spiHandle, &trans);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "SPI buffer transfer failed: %s", esp_err_to_name(ret));
            return;
        }

        if (rxBuf) {
            memcpy(rxBuf + offset, s_dmaBuffer, chunkLen);
        }

        offset += chunkLen;
    }
}

// ============================================================================
// Command Interface
// ============================================================================

void SPIFpga::sendCommand(uint8_t cmd, const uint8_t* data, size_t len) {
    if (!m_initialized) {
        ESP_LOGE(TAG, "Not initialized");
        return;
    }

    assertCS();

    // Send command byte
    transfer(cmd);

    // Send data if provided
    if (data && len > 0) {
        transferBuffer(data, nullptr, len);
    }

    deassertCS();
}

// ============================================================================
// OSD Functions
// ============================================================================

void SPIFpga::setOsdEnable(bool enable) {
    ESP_LOGI(TAG, "OSD %s", enable ? "enabled" : "disabled");
    sendCommand(enable ? OSD_CMD_ENABLE : OSD_CMD_DISABLE);
}

void SPIFpga::sendOsdBuffer(const uint8_t* buffer, size_t lineStart, size_t numLines) {
    if (!m_initialized || !buffer) {
        ESP_LOGE(TAG, "Invalid state or buffer");
        return;
    }

    // Calculate bytes per line (OSD_WIDTH / 8 for 1-bit pixels)
    const size_t bytesPerLine = OSD_WIDTH / 8;  // 32 bytes per line

    for (size_t i = 0; i < numLines; i++) {
        size_t lineNum = lineStart + i;
        if (lineNum >= (OSD_HEIGHT)) {
            break;
        }

        // OSD_CMD_WRITE base is 0x20, add line number for specific line
        uint8_t lineCmd = OSD_CMD_WRITE | (lineNum & 0x0F);

        assertCS();
        transfer(lineCmd);

        // Send line data in chunks
        const uint8_t* lineData = buffer + (lineNum * bytesPerLine);
        size_t remaining = bytesPerLine;
        size_t offset = 0;

        while (remaining > 0) {
            size_t chunkSize = (remaining > SPI_CHUNK_SIZE) ? SPI_CHUNK_SIZE : remaining;
            transferBuffer(lineData + offset, nullptr, chunkSize);
            offset += chunkSize;
            remaining -= chunkSize;
        }

        deassertCS();

        // Small delay between lines for FPGA processing
        taskYIELD();
    }
}

// ============================================================================
// Status and Input
// ============================================================================

void SPIFpga::setStatus(uint32_t status) {
    uint8_t data[4];
    data[0] = (status >> 0) & 0xFF;
    data[1] = (status >> 8) & 0xFF;
    data[2] = (status >> 16) & 0xFF;
    data[3] = (status >> 24) & 0xFF;

    sendCommand(STATUS_SET, data, 4);
    ESP_LOGD(TAG, "Status set: 0x%08lX", (unsigned long)status);
}

void SPIFpga::setJoystick(uint8_t player, uint16_t state) {
    uint8_t data[2];
    data[0] = state & 0xFF;
    data[1] = (state >> 8) & 0xFF;

    uint8_t cmd = (player == 0) ? JOYSTICK_0 : JOYSTICK_1;
    sendCommand(cmd, data, 2);
}

// ============================================================================
// File Transfer
// ============================================================================

void SPIFpga::startFileTransfer(uint8_t index) {
    if (m_transferActive) {
        ESP_LOGW(TAG, "Transfer already active, ending previous");
        endFileTransfer();
    }

    ESP_LOGI(TAG, "Starting file transfer, index=%d", index);

    // Set file index
    uint8_t idxData = index;
    sendCommand(FILE_INDEX, &idxData, 1);

    // Begin transfer
    assertCS();
    transfer(FILE_TX);
    transfer(0x01);  // Transfer start flag

    m_transferActive = true;
}

void SPIFpga::sendFileData(uint8_t byte) {
    if (!m_transferActive) {
        ESP_LOGE(TAG, "No active transfer");
        return;
    }

    // Send data command with byte
    transfer(FILE_TX_DAT);
    transfer(byte);
}

void SPIFpga::endFileTransfer() {
    if (!m_transferActive) {
        return;
    }

    // End transfer sequence
    transfer(FILE_TX);
    transfer(0x00);  // Transfer end flag
    deassertCS();

    // Clear ready signal
    gpio_set_level((gpio_num_t)PIN_ESP_READY, 0);

    m_transferActive = false;
    ESP_LOGI(TAG, "File transfer complete");
}
