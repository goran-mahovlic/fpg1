/**
 * @file osd_menu.cpp
 * @brief OSD Menu System Implementation
 *
 * Renders hierarchical menu to 256x128 monochrome buffer.
 * Designed for PDP-1 emulator on-screen display.
 */

#include "osd_menu.h"
#include <string.h>

// ============================================================================
// Constructor
// ============================================================================

OSDMenu::OSDMenu() {
    memset(&state, 0, sizeof(MenuState));
    initFont();
}

// ============================================================================
// Initialization
// ============================================================================

void OSDMenu::begin(MenuItem* rootMenu) {
    state.root = rootMenu;
    state.current = rootMenu;
    state.selectedIndex = 0;
    state.scrollOffset = 0;
    state.stackDepth = 0;
    state.visible = false;
    state.lastActivity = millis();

    // Skip initial separators
    if (rootMenu && rootMenu->submenu.count > 0) {
        state.selectedIndex = findNextSelectable(-1, 1);
    }
}

// ============================================================================
// Font Initialization (Basic 8x8 ASCII font)
// ============================================================================

void OSDMenu::initFont() {
    // Initialize with zeros
    memset(font8x8, 0, sizeof(font8x8));

    // Space (32)
    // Already zero

    // Letters A-Z (65-90)
    const uint8_t letters[][8] = {
        // A
        {0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00},
        // B
        {0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00},
        // C
        {0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00},
        // D
        {0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00},
        // E
        {0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00},
        // F
        {0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00},
        // G
        {0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00},
        // H
        {0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00},
        // I
        {0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00},
        // J
        {0x1E, 0x0C, 0x0C, 0x0C, 0x6C, 0x6C, 0x38, 0x00},
        // K
        {0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00},
        // L
        {0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00},
        // M
        {0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00},
        // N
        {0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00},
        // O
        {0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00},
        // P
        {0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00},
        // Q
        {0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00},
        // R
        {0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00},
        // S
        {0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00},
        // T
        {0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00},
        // U
        {0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00},
        // V
        {0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00},
        // W
        {0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00},
        // X
        {0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00},
        // Y
        {0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00},
        // Z
        {0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00}
    };

    for (int i = 0; i < 26; i++) {
        memcpy(font8x8['A' - 32 + i], letters[i], 8);
        // Lowercase (same as uppercase for simplicity)
        memcpy(font8x8['a' - 32 + i], letters[i], 8);
    }

    // Numbers 0-9 (48-57)
    const uint8_t numbers[][8] = {
        {0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00}, // 0
        {0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00}, // 1
        {0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00}, // 2
        {0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00}, // 3
        {0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00}, // 4
        {0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00}, // 5
        {0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00}, // 6
        {0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00}, // 7
        {0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00}, // 8
        {0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00}  // 9
    };

    for (int i = 0; i < 10; i++) {
        memcpy(font8x8['0' - 32 + i], numbers[i], 8);
    }

    // Special characters
    const uint8_t colon[] = {0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00};
    memcpy(font8x8[':' - 32], colon, 8);

    const uint8_t period[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00};
    memcpy(font8x8['.' - 32], period, 8);

    const uint8_t hyphen[] = {0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00};
    memcpy(font8x8['-' - 32], hyphen, 8);

    const uint8_t lbracket[] = {0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00};
    memcpy(font8x8['[' - 32], lbracket, 8);

    const uint8_t rbracket[] = {0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00};
    memcpy(font8x8[']' - 32], rbracket, 8);

    const uint8_t slash[] = {0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00};
    memcpy(font8x8['/' - 32], slash, 8);

    const uint8_t arrow[] = {0x00, 0x18, 0x0C, 0xFE, 0x0C, 0x18, 0x00, 0x00};
    memcpy(font8x8['>' - 32], arrow, 8);
}

// ============================================================================
// Navigation
// ============================================================================

bool OSDMenu::navigate(NavCommand cmd) {
    if (!state.current || cmd == NAV_NONE) {
        return false;
    }

    state.lastActivity = millis();
    bool changed = false;

    switch (cmd) {
        case NAV_UP: {
            int8_t next = findNextSelectable(state.selectedIndex, -1);
            if (next >= 0 && next != state.selectedIndex) {
                state.selectedIndex = next;
                changed = true;
            }
            break;
        }

        case NAV_DOWN: {
            int8_t next = findNextSelectable(state.selectedIndex, 1);
            if (next >= 0 && next != state.selectedIndex) {
                state.selectedIndex = next;
                changed = true;
            }
            break;
        }

        case NAV_LEFT:
        case NAV_BACK:
            if (state.stackDepth > 0) {
                exitSubmenu();
                changed = true;
            } else if (cmd == NAV_BACK) {
                setVisible(false);
                changed = true;
            }
            break;

        case NAV_RIGHT:
        case NAV_SELECT:
            activateItem();
            changed = true;
            break;

        default:
            break;
    }

    // Adjust scroll offset if needed
    const uint8_t visibleRows = 10;  // Max visible menu items
    if (state.selectedIndex < state.scrollOffset) {
        state.scrollOffset = state.selectedIndex;
    } else if (state.selectedIndex >= state.scrollOffset + visibleRows) {
        state.scrollOffset = state.selectedIndex - visibleRows + 1;
    }

    return changed;
}

int8_t OSDMenu::findNextSelectable(int8_t from, int8_t direction) {
    if (!state.current) return -1;

    uint8_t count = state.current->submenu.count;
    MenuItem* items = state.current->submenu.items;

    int8_t idx = from + direction;

    while (idx >= 0 && idx < count) {
        if (items[idx].type != ITEM_SEPARATOR) {
            return idx;
        }
        idx += direction;
    }

    return from;  // Stay at current if nothing found
}

void OSDMenu::enterSubmenu(uint8_t index) {
    MenuItem* item = &state.current->submenu.items[index];

    if (item->type != ITEM_SUBMENU) return;
    if (state.stackDepth >= MAX_MENU_DEPTH) return;

    // Push current state
    state.menuStack[state.stackDepth] = state.selectedIndex;
    state.stackMenus[state.stackDepth] = state.current;
    state.stackDepth++;

    // Enter submenu
    state.current = item;
    state.selectedIndex = findNextSelectable(-1, 1);
    state.scrollOffset = 0;
}

void OSDMenu::exitSubmenu() {
    if (state.stackDepth == 0) return;

    state.stackDepth--;
    state.current = state.stackMenus[state.stackDepth];
    state.selectedIndex = state.menuStack[state.stackDepth];
    state.scrollOffset = 0;

    // Recalculate scroll offset
    const uint8_t visibleRows = 10;
    if (state.selectedIndex >= visibleRows) {
        state.scrollOffset = state.selectedIndex - visibleRows + 1;
    }
}

void OSDMenu::activateItem() {
    MenuItem* item = getSelectedItem();
    if (!item) return;

    switch (item->type) {
        case ITEM_SUBMENU:
            enterSubmenu(state.selectedIndex);
            break;

        case ITEM_TOGGLE:
            if (item->toggle.value) {
                *(item->toggle.value) = !*(item->toggle.value);
            }
            break;

        case ITEM_TRIGGER:
            if (item->trigger.action) {
                item->trigger.action(item);
            }
            break;

        case ITEM_FILE_SELECT:
            if (item->trigger.action) {
                item->trigger.action(item);
            }
            break;

        default:
            break;
    }
}

// ============================================================================
// Rendering
// ============================================================================

void OSDMenu::render(uint8_t* buffer) {
    clearBuffer(buffer);

    if (!state.visible || !state.current) {
        return;
    }

    MenuItem* menu = state.current;
    MenuItem* items = menu->submenu.items;
    uint8_t count = menu->submenu.count;

    // Draw title bar
    drawFilledRect(buffer, 0, 0, OSD_WIDTH, 12);
    const char* title = menu->label ? menu->label : "PDP-1 Emulator";
    drawString(buffer, 4, 2, title, true);

    // Draw menu items
    const int startY = 16;
    const int itemHeight = 11;
    const int maxVisible = 10;

    for (int i = 0; i < maxVisible && (i + state.scrollOffset) < count; i++) {
        int itemIndex = i + state.scrollOffset;
        MenuItem* item = &items[itemIndex];
        int y = startY + i * itemHeight;
        bool selected = (itemIndex == state.selectedIndex);

        if (selected) {
            drawFilledRect(buffer, 0, y, OSD_WIDTH, itemHeight);
        }

        if (item->type == ITEM_SEPARATOR) {
            // Draw separator line
            drawHLine(buffer, 8, y + 5, OSD_WIDTH - 16);
        } else {
            // Draw selection indicator
            if (selected) {
                drawString(buffer, 4, y + 2, ">", true);
            }

            // Draw label
            drawString(buffer, 16, y + 2, item->label, selected);

            // Draw value for toggles
            if (item->type == ITEM_TOGGLE && item->toggle.value) {
                const char* valStr = *(item->toggle.value) ?
                    item->toggle.onText : item->toggle.offText;
                char valBuf[32];
                snprintf(valBuf, sizeof(valBuf), "[%s]", valStr);
                int valX = OSD_WIDTH - strlen(valBuf) * 8 - 8;
                drawString(buffer, valX, y + 2, valBuf, selected);
            }

            // Draw submenu indicator
            if (item->type == ITEM_SUBMENU) {
                drawString(buffer, OSD_WIDTH - 16, y + 2, ">", selected);
            }

            // Draw file select indicator
            if (item->type == ITEM_FILE_SELECT) {
                drawString(buffer, OSD_WIDTH - 24, y + 2, "...", selected);
            }
        }
    }

    // Draw scroll indicators if needed
    if (state.scrollOffset > 0) {
        drawString(buffer, OSD_WIDTH - 16, startY, "^", false);
    }
    if (state.scrollOffset + maxVisible < count) {
        drawString(buffer, OSD_WIDTH - 16, startY + (maxVisible - 1) * itemHeight, "v", false);
    }

    // Draw border
    drawRect(buffer, 0, 0, OSD_WIDTH, OSD_HEIGHT);
}

// ============================================================================
// Drawing Primitives
// ============================================================================

void OSDMenu::clearBuffer(uint8_t* buffer) {
    memset(buffer, 0, OSD_BUFFER_SIZE);
}

void OSDMenu::drawChar(uint8_t* buffer, int x, int y, char c, bool invert) {
    if (c < 32 || c > 127) return;
    if (x < 0 || x >= OSD_WIDTH - 8) return;
    if (y < 0 || y >= OSD_HEIGHT - 8) return;

    const uint8_t* glyph = font8x8[c - 32];

    for (int row = 0; row < 8; row++) {
        uint8_t rowData = glyph[row];
        if (invert) rowData = ~rowData;

        for (int col = 0; col < 8; col++) {
            if (rowData & (0x80 >> col)) {
                int px = x + col;
                int py = y + row;
                int byteIdx = (py * OSD_WIDTH + px) / 8;
                int bitIdx = 7 - (px % 8);
                buffer[byteIdx] |= (1 << bitIdx);
            }
        }
    }
}

void OSDMenu::drawString(uint8_t* buffer, int x, int y, const char* str, bool invert) {
    if (!str) return;

    int cx = x;
    while (*str) {
        drawChar(buffer, cx, y, *str, invert);
        cx += 8;
        str++;
        if (cx >= OSD_WIDTH - 8) break;
    }
}

void OSDMenu::drawHLine(uint8_t* buffer, int x, int y, int width) {
    if (y < 0 || y >= OSD_HEIGHT) return;

    for (int i = 0; i < width; i++) {
        int px = x + i;
        if (px >= 0 && px < OSD_WIDTH) {
            int byteIdx = (y * OSD_WIDTH + px) / 8;
            int bitIdx = 7 - (px % 8);
            buffer[byteIdx] |= (1 << bitIdx);
        }
    }
}

void OSDMenu::drawRect(uint8_t* buffer, int x, int y, int w, int h) {
    // Top and bottom lines
    drawHLine(buffer, x, y, w);
    drawHLine(buffer, x, y + h - 1, w);

    // Left and right lines
    for (int i = 0; i < h; i++) {
        int py = y + i;
        if (py >= 0 && py < OSD_HEIGHT) {
            // Left edge
            if (x >= 0 && x < OSD_WIDTH) {
                int byteIdx = (py * OSD_WIDTH + x) / 8;
                int bitIdx = 7 - (x % 8);
                buffer[byteIdx] |= (1 << bitIdx);
            }
            // Right edge
            int rx = x + w - 1;
            if (rx >= 0 && rx < OSD_WIDTH) {
                int byteIdx = (py * OSD_WIDTH + rx) / 8;
                int bitIdx = 7 - (rx % 8);
                buffer[byteIdx] |= (1 << bitIdx);
            }
        }
    }
}

void OSDMenu::drawFilledRect(uint8_t* buffer, int x, int y, int w, int h) {
    for (int row = y; row < y + h && row < OSD_HEIGHT; row++) {
        if (row < 0) continue;
        drawHLine(buffer, x, row, w);
    }
}

// ============================================================================
// Visibility and State
// ============================================================================

void OSDMenu::setVisible(bool show) {
    state.visible = show;
    if (show) {
        state.lastActivity = millis();
    }
}

void OSDMenu::update() {
    // Auto-hide after timeout
    if (state.visible && (millis() - state.lastActivity > MENU_TIMEOUT_MS)) {
        setVisible(false);
    }
}

MenuItem* OSDMenu::getSelectedItem() {
    if (!state.current) return nullptr;
    if (state.selectedIndex >= state.current->submenu.count) return nullptr;
    return &state.current->submenu.items[state.selectedIndex];
}

uint8_t OSDMenu::getVisibleItemCount() {
    return state.current ? state.current->submenu.count : 0;
}

uint8_t OSDMenu::getSelectableItemCount() {
    if (!state.current) return 0;

    uint8_t count = 0;
    for (uint8_t i = 0; i < state.current->submenu.count; i++) {
        if (state.current->submenu.items[i].type != ITEM_SEPARATOR) {
            count++;
        }
    }
    return count;
}
