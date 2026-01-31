/**
 * @file osd_menu.h
 * @brief OSD Menu System for PDP-1 Emulator
 *
 * Provides hierarchical menu structure with navigation and rendering
 * to a 256x128 monochrome buffer for FPGA overlay display.
 */

#ifndef OSD_MENU_H
#define OSD_MENU_H

#include <Arduino.h>
#include "config.h"

// ============================================================================
// Menu Item Types
// ============================================================================

enum MenuItemType {
    ITEM_SUBMENU,       // Opens a sub-menu
    ITEM_TOGGLE,        // Boolean toggle (Yes/No, On/Off)
    ITEM_TRIGGER,       // Action trigger (executes callback)
    ITEM_FILE_SELECT,   // Opens file browser
    ITEM_SEPARATOR      // Visual separator line
};

// ============================================================================
// Navigation Commands
// ============================================================================

enum NavCommand {
    NAV_NONE,
    NAV_UP,
    NAV_DOWN,
    NAV_LEFT,
    NAV_RIGHT,
    NAV_SELECT,
    NAV_BACK
};

// ============================================================================
// Menu Item Structure
// ============================================================================

struct MenuItem;  // Forward declaration

typedef void (*MenuCallback)(MenuItem* item);

struct MenuItem {
    const char* label;          // Display text
    MenuItemType type;          // Item type

    union {
        struct {
            MenuItem* items;    // Sub-menu items array
            uint8_t count;      // Number of items
        } submenu;

        struct {
            bool* value;        // Pointer to boolean value
            const char* onText;  // Text when true (e.g., "Yes")
            const char* offText; // Text when false (e.g., "No")
        } toggle;

        struct {
            MenuCallback action; // Callback function
        } trigger;

        struct {
            const char* extension; // File extension filter
            char* selectedPath;    // Selected file path buffer
            uint16_t pathSize;     // Buffer size
        } fileSelect;
    };
};

// ============================================================================
// Menu State
// ============================================================================

struct MenuState {
    MenuItem* root;              // Root menu
    MenuItem* current;           // Current menu level
    uint8_t selectedIndex;       // Currently selected item
    uint8_t scrollOffset;        // Scroll position for long menus
    uint8_t menuStack[MAX_MENU_DEPTH];  // Navigation stack (indices)
    MenuItem* stackMenus[MAX_MENU_DEPTH]; // Menu pointers stack
    uint8_t stackDepth;          // Current stack depth
    bool visible;                // Menu visibility
    uint32_t lastActivity;       // Last input timestamp (for timeout)
};

// ============================================================================
// OSD Menu Class
// ============================================================================

class OSDMenu {
public:
    OSDMenu();

    /**
     * @brief Initialize the menu system
     * @param rootMenu Pointer to root menu structure
     */
    void begin(MenuItem* rootMenu);

    /**
     * @brief Process navigation input
     * @param cmd Navigation command
     * @return true if menu state changed
     */
    bool navigate(NavCommand cmd);

    /**
     * @brief Render menu to buffer
     * @param buffer Output buffer (OSD_BUFFER_SIZE bytes)
     */
    void render(uint8_t* buffer);

    /**
     * @brief Show/hide the menu
     * @param show true to show, false to hide
     */
    void setVisible(bool show);

    /**
     * @brief Check if menu is visible
     * @return true if menu is currently shown
     */
    bool isVisible() const { return state.visible; }

    /**
     * @brief Update menu (call periodically for timeout handling)
     */
    void update();

    /**
     * @brief Get currently selected item
     * @return Pointer to selected MenuItem
     */
    MenuItem* getSelectedItem();

private:
    MenuState state;
    uint8_t font8x8[96][8];  // Built-in 8x8 font (ASCII 32-127)

    void initFont();
    void clearBuffer(uint8_t* buffer);
    void drawChar(uint8_t* buffer, int x, int y, char c, bool invert);
    void drawString(uint8_t* buffer, int x, int y, const char* str, bool invert);
    void drawHLine(uint8_t* buffer, int x, int y, int width);
    void drawRect(uint8_t* buffer, int x, int y, int w, int h);
    void drawFilledRect(uint8_t* buffer, int x, int y, int w, int h);

    void enterSubmenu(uint8_t index);
    void exitSubmenu();
    void activateItem();
    uint8_t getVisibleItemCount();
    uint8_t getSelectableItemCount();
    int8_t findNextSelectable(int8_t from, int8_t direction);
};

// ============================================================================
// Helper Macros for Menu Definition
// ============================================================================

#define MENU_SUBMENU(lbl, sub, cnt) \
    { lbl, ITEM_SUBMENU, { .submenu = { sub, cnt } } }

#define MENU_TOGGLE(lbl, val, on, off) \
    { lbl, ITEM_TOGGLE, { .toggle = { val, on, off } } }

#define MENU_TRIGGER(lbl, cb) \
    { lbl, ITEM_TRIGGER, { .trigger = { cb } } }

#define MENU_FILE(lbl, ext, path, size) \
    { lbl, ITEM_FILE_SELECT, { .fileSelect = { ext, path, size } } }

#define MENU_SEPARATOR() \
    { NULL, ITEM_SEPARATOR, { } }

#endif // OSD_MENU_H
