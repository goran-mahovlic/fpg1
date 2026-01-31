/**
 * @file main.cpp
 * @brief ESP32 OSD Controller for PDP-1 Emulator
 *
 * Main application with PDP-1 specific menu structure.
 * Handles SPI communication with FPGA for OSD overlay.
 */

#include <Arduino.h>
#include <SPI.h>
#include "config.h"
#include "osd_menu.h"

// ============================================================================
// Global State
// ============================================================================

OSDMenu osdMenu;
uint8_t osdBuffer[OSD_BUFFER_SIZE];

// Settings storage
bool settingAspectWide = false;
bool settingHwMultiply = true;
bool settingVarBrightness = true;
bool settingCrtWait = true;

char romFilePath[128] = "";
char rimFilePath[128] = "";

// ============================================================================
// Menu Callbacks
// ============================================================================

void onLoadROM(MenuItem* item) {
    Serial.println("Load ROM File requested");
    // TODO: Trigger file browser via SPI command
}

void onLoadRIM(MenuItem* item) {
    Serial.println("Load RIM File requested");
    // TODO: Trigger file browser via SPI command
}

void onReset(MenuItem* item) {
    Serial.println("Reset triggered");
    // TODO: Send reset command to FPGA
}

void onSystemInfo(MenuItem* item) {
    Serial.println("System Info requested");
    // TODO: Show system info submenu
}

// ============================================================================
// Menu Definition - PDP-1 Emulator
// ============================================================================

MenuItem mainMenuItems[] = {
    MENU_FILE("Load ROM File...", ".bin", romFilePath, sizeof(romFilePath)),
    MENU_FILE("Load RIM File...", ".rim", rimFilePath, sizeof(rimFilePath)),
    MENU_SEPARATOR(),
    MENU_TOGGLE("Aspect Ratio", &settingAspectWide, "Wide", "Original"),
    MENU_TOGGLE("Hardware Multiply", &settingHwMultiply, "Yes", "No"),
    MENU_TOGGLE("Variable Brightness", &settingVarBrightness, "Yes", "No"),
    MENU_TOGGLE("CRT Wait", &settingCrtWait, "Yes", "No"),
    MENU_SEPARATOR(),
    MENU_TRIGGER("Reset", onReset),
    MENU_TRIGGER("System Info", onSystemInfo)
};

MenuItem rootMenu = MENU_SUBMENU("PDP-1 Emulator", mainMenuItems,
                                  sizeof(mainMenuItems) / sizeof(MenuItem));

// ============================================================================
// SPI Communication
// ============================================================================

SPIClass* hspi = nullptr;

void initSPI() {
    hspi = new SPIClass(HSPI);
    hspi->begin(PIN_SPI_CLK, PIN_SPI_MISO, PIN_SPI_MOSI, PIN_SPI_CS);
    pinMode(PIN_SPI_CS, OUTPUT);
    digitalWrite(PIN_SPI_CS, HIGH);
}

void sendOSDBuffer() {
    digitalWrite(PIN_SPI_CS, LOW);
    hspi->beginTransaction(SPISettings(SPI_CLOCK_HZ, MSBFIRST, SPI_MODE0));

    // Send command byte (0x01 = OSD buffer update)
    hspi->transfer(0x01);

    // Send buffer data
    for (int i = 0; i < OSD_BUFFER_SIZE; i++) {
        hspi->transfer(osdBuffer[i]);
    }

    hspi->endTransaction();
    digitalWrite(PIN_SPI_CS, HIGH);
}

void sendOSDVisibility(bool visible) {
    digitalWrite(PIN_SPI_CS, LOW);
    hspi->beginTransaction(SPISettings(SPI_CLOCK_HZ, MSBFIRST, SPI_MODE0));

    // Send command byte (0x02 = OSD visibility)
    hspi->transfer(0x02);
    hspi->transfer(visible ? 0x01 : 0x00);

    hspi->endTransaction();
    digitalWrite(PIN_SPI_CS, HIGH);
}

// ============================================================================
// Input Handling
// ============================================================================

NavCommand readNavInput() {
    // Check for interrupt from FPGA
    if (!digitalRead(PIN_OSD_IRQ)) {
        return NAV_NONE;
    }

    // Read command from FPGA via SPI
    digitalWrite(PIN_SPI_CS, LOW);
    hspi->beginTransaction(SPISettings(SPI_CLOCK_HZ, MSBFIRST, SPI_MODE0));

    hspi->transfer(0x10);  // Read input command
    uint8_t input = hspi->transfer(0x00);

    hspi->endTransaction();
    digitalWrite(PIN_SPI_CS, HIGH);

    switch (input) {
        case 0x01: return NAV_UP;
        case 0x02: return NAV_DOWN;
        case 0x03: return NAV_LEFT;
        case 0x04: return NAV_RIGHT;
        case 0x05: return NAV_SELECT;
        case 0x06: return NAV_BACK;
        case 0x10: // Menu toggle
            if (!osdMenu.isVisible()) {
                osdMenu.setVisible(true);
                return NAV_NONE;
            }
            break;
    }

    return NAV_NONE;
}

// ============================================================================
// Setup
// ============================================================================

void setup() {
    Serial.begin(115200);
    Serial.println("\n=== PDP-1 Emulator OSD Controller ===");

    // Initialize GPIO
    pinMode(PIN_OSD_IRQ, INPUT);
    pinMode(PIN_ESP_READY, OUTPUT);
    digitalWrite(PIN_ESP_READY, LOW);

    // Initialize SPI
    initSPI();
    Serial.println("SPI initialized");

    // Initialize menu system
    osdMenu.begin(&rootMenu);
    Serial.println("Menu system initialized");

    // Signal ready to FPGA
    digitalWrite(PIN_ESP_READY, HIGH);
    Serial.println("ESP32 OSD Controller ready");
}

// ============================================================================
// Main Loop
// ============================================================================

void loop() {
    static bool lastVisible = false;
    static uint32_t lastRender = 0;

    // Read navigation input
    NavCommand nav = readNavInput();

    // Process navigation
    if (nav != NAV_NONE) {
        if (osdMenu.navigate(nav)) {
            // Menu changed, force re-render
            lastRender = 0;
        }
    }

    // Update menu (handles timeout)
    osdMenu.update();

    // Check visibility change
    if (osdMenu.isVisible() != lastVisible) {
        lastVisible = osdMenu.isVisible();
        sendOSDVisibility(lastVisible);
        lastRender = 0;  // Force render on visibility change
    }

    // Render and send buffer at 30 fps max
    if (osdMenu.isVisible() && (millis() - lastRender > 33)) {
        osdMenu.render(osdBuffer);
        sendOSDBuffer();
        lastRender = millis();
    }

    // Small delay to prevent busy loop
    delay(1);
}
