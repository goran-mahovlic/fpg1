/**
 * file_transfer.cpp - ROM/RIM File Transfer to FPGA
 *
 * Handles file loading from SD card to FPGA memory with IRQ signaling.
 * Supports PDP/ROM, RIM, and BIN file formats.
 */

#include "file_transfer.h"
#include "config.h"
#include <SD.h>
#include <SPI.h>
#include <string.h>

// Global instance
FileTransfer fileTransfer;

// FPGA transfer protocol commands
#define CMD_TRANSFER_START      0x80
#define CMD_TRANSFER_DATA       0x81
#define CMD_TRANSFER_END        0x82
#define CMD_TRANSFER_ABORT      0x83

// IOCTL register addresses (directly matching FPGA memory map)
#define IOCTL_ADDR_COMMAND      0x00
#define IOCTL_ADDR_FILE_TYPE    0x01
#define IOCTL_ADDR_SIZE_LOW     0x02
#define IOCTL_ADDR_SIZE_HIGH    0x03
#define IOCTL_ADDR_DATA         0x04
#define IOCTL_ADDR_STATUS       0x05

bool FileTransfer::startTransfer(const char* filepath, uint8_t fileIdx) {
    if (active) {
        Serial.println("Transfer already in progress");
        return false;
    }

    // Open file
    File f = SD.open(filepath, FILE_READ);
    if (!f) {
        Serial.printf("Failed to open file: %s\n", filepath);
        return false;
    }

    // Store file info
    fileSize = f.size();
    bytesTransferred = 0;
    fileType = fileIdx;
    active = true;
    state = TRANSFER_STARTING;

    // Extract filename from path
    const char* name = filepath;
    const char* lastSlash = strrchr(filepath, '/');
    if (lastSlash) {
        name = lastSlash + 1;
    }
    strncpy(filename, name, sizeof(filename) - 1);
    filename[sizeof(filename) - 1] = '\0';

    // Convert Arduino File to FILE* is not direct, use file handle differently
    file = (FILE*)malloc(sizeof(File));
    memcpy(file, &f, sizeof(File));

    Serial.printf("Starting transfer: %s (%lu bytes, type %d)\n",
                  filename, fileSize, fileType);

    return true;
}

bool FileTransfer::processTransfer() {
    if (!active) {
        return false;
    }

    switch (state) {
        case TRANSFER_STARTING:
            state = TRANSFER_SENDING_HEADER;
            return true;

        case TRANSFER_SENDING_HEADER:
            if (sendHeader()) {
                state = TRANSFER_SENDING_DATA;
            } else {
                state = TRANSFER_ERROR;
                abortTransfer();
                return false;
            }
            return true;

        case TRANSFER_SENDING_DATA:
            if (bytesTransferred >= fileSize) {
                state = TRANSFER_COMPLETING;
            } else if (!sendDataChunk()) {
                state = TRANSFER_ERROR;
                abortTransfer();
                return false;
            }
            return true;

        case TRANSFER_COMPLETING:
            if (completeTransfer()) {
                active = false;
                state = TRANSFER_IDLE;
                Serial.println("Transfer completed successfully");
                return false;  // Done
            }
            return true;

        case TRANSFER_ERROR:
        case TRANSFER_IDLE:
        default:
            return false;
    }
}

bool FileTransfer::sendHeader() {
    // Assert FPGA IRQ to signal transfer start
    digitalWrite(FPGA_IRQ_PIN, HIGH);
    delayMicroseconds(10);

    // Select FPGA for SPI transfer
    digitalWrite(FPGA_CS_PIN, LOW);

    // Send transfer start command
    SPI.transfer(CMD_TRANSFER_START);
    SPI.transfer(fileType);

    // Send file size (32-bit, little-endian)
    SPI.transfer(fileSize & 0xFF);
    SPI.transfer((fileSize >> 8) & 0xFF);
    SPI.transfer((fileSize >> 16) & 0xFF);
    SPI.transfer((fileSize >> 24) & 0xFF);

    // Deselect FPGA
    digitalWrite(FPGA_CS_PIN, HIGH);

    // Clear IRQ
    digitalWrite(FPGA_IRQ_PIN, LOW);

    // Wait for FPGA ready (check status)
    delayMicroseconds(100);

    Serial.printf("Header sent: type=%d, size=%lu\n", fileType, fileSize);

    return true;
}

bool FileTransfer::sendDataChunk() {
    File* f = (File*)file;

    // Read chunk from file
    size_t toRead = min((size_t)(fileSize - bytesTransferred), TRANSFER_CHUNK_SIZE);
    size_t bytesRead = f->read(buffer, toRead);

    if (bytesRead == 0) {
        Serial.println("File read error");
        return false;
    }

    // Signal FPGA: data incoming
    digitalWrite(FPGA_IRQ_PIN, HIGH);
    delayMicroseconds(5);

    // Select FPGA
    digitalWrite(FPGA_CS_PIN, LOW);

    // Send data command
    SPI.transfer(CMD_TRANSFER_DATA);

    // Send chunk size
    SPI.transfer(bytesRead & 0xFF);

    // Send data bytes
    for (size_t i = 0; i < bytesRead; i++) {
        SPI.transfer(buffer[i]);
    }

    // Deselect FPGA
    digitalWrite(FPGA_CS_PIN, HIGH);

    // Clear IRQ
    digitalWrite(FPGA_IRQ_PIN, LOW);

    bytesTransferred += bytesRead;

    // Progress output every 10%
    static uint8_t lastProgress = 0;
    uint8_t progress = getProgress();
    if (progress >= lastProgress + 10) {
        Serial.printf("Transfer progress: %d%%\n", progress);
        lastProgress = progress;
    }

    // Small delay to let FPGA process
    delayMicroseconds(50);

    return true;
}

bool FileTransfer::completeTransfer() {
    File* f = (File*)file;

    // Close file
    f->close();
    free(file);
    file = nullptr;

    // Signal transfer complete
    digitalWrite(FPGA_IRQ_PIN, HIGH);
    delayMicroseconds(10);

    digitalWrite(FPGA_CS_PIN, LOW);
    SPI.transfer(CMD_TRANSFER_END);
    SPI.transfer(0x00);  // Success status
    digitalWrite(FPGA_CS_PIN, HIGH);

    digitalWrite(FPGA_IRQ_PIN, LOW);

    return true;
}

void FileTransfer::abortTransfer() {
    if (file) {
        File* f = (File*)file;
        f->close();
        free(file);
        file = nullptr;
    }

    // Signal abort to FPGA
    digitalWrite(FPGA_IRQ_PIN, HIGH);
    delayMicroseconds(10);

    digitalWrite(FPGA_CS_PIN, LOW);
    SPI.transfer(CMD_TRANSFER_ABORT);
    digitalWrite(FPGA_CS_PIN, HIGH);

    digitalWrite(FPGA_IRQ_PIN, LOW);

    active = false;
    state = TRANSFER_IDLE;
    bytesTransferred = 0;

    Serial.println("Transfer aborted");
}

bool FileTransfer::isActive() {
    return active;
}

uint8_t FileTransfer::getProgress() {
    if (fileSize == 0) {
        return 0;
    }
    return (uint8_t)((bytesTransferred * 100) / fileSize);
}

TransferState FileTransfer::getState() {
    return state;
}

const char* FileTransfer::getFilename() {
    return filename;
}

uint32_t FileTransfer::getBytesTransferred() {
    return bytesTransferred;
}

uint32_t FileTransfer::getFileSize() {
    return fileSize;
}

void FileTransfer::signalFPGA(uint8_t command) {
    // Generic FPGA command signal via IRQ pulse
    digitalWrite(FPGA_IRQ_PIN, HIGH);
    delayMicroseconds(5);

    digitalWrite(FPGA_CS_PIN, LOW);
    SPI.transfer(command);
    digitalWrite(FPGA_CS_PIN, HIGH);

    digitalWrite(FPGA_IRQ_PIN, LOW);
}
