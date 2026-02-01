#pragma once
#include <stdint.h>
#include <stdio.h>

// File type indices for FPGA loading
#define FILE_TYPE_PDP_ROM   0   // PDP/ROM files
#define FILE_TYPE_RIM       1   // RIM files
#define FILE_TYPE_BIN       2   // BIN files

// Transfer states
enum TransferState {
    TRANSFER_IDLE,
    TRANSFER_STARTING,
    TRANSFER_SENDING_HEADER,
    TRANSFER_SENDING_DATA,
    TRANSFER_COMPLETING,
    TRANSFER_ERROR
};

class FileTransfer {
public:
    bool startTransfer(const char* filepath, uint8_t fileType);
    bool processTransfer();  // Call from main loop
    void abortTransfer();
    bool isActive();
    uint8_t getProgress();  // 0-100%
    TransferState getState();
    const char* getFilename();
    uint32_t getBytesTransferred();
    uint32_t getFileSize();

private:
    FILE* file;
    uint32_t fileSize;
    uint32_t bytesTransferred;
    uint8_t fileType;
    bool active;
    TransferState state;
    char filename[32];

    // Transfer buffer
    static const size_t TRANSFER_CHUNK_SIZE = 256;
    uint8_t buffer[TRANSFER_CHUNK_SIZE];

    bool sendHeader();
    bool sendDataChunk();
    bool completeTransfer();
    void signalFPGA(uint8_t command);
};

extern FileTransfer fileTransfer;
