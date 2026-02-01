/**
 * file_browser.cpp - SD Card File Browser Implementation
 *
 * Provides directory navigation and file listing with extension filtering
 * for PDP-1 ROM/RIM file loading.
 */

#include "file_browser.h"
#include "config.h"
#include <SD.h>
#include <string.h>
#include <algorithm>

// Global instance
FileBrowser fileBrowser;

bool FileBrowser::init() {
    // Initialize SD card
    if (!SD.begin(SD_CS_PIN)) {
        Serial.println("SD Card initialization failed!");
        return false;
    }

    Serial.println("SD Card initialized successfully");

    // Set root directory
    strcpy(currentPath, "/");
    filter[0] = '\0';

    // Initial scan
    scanDirectory();

    return true;
}

bool FileBrowser::setDirectory(const char* path) {
    if (!path || strlen(path) >= sizeof(currentPath)) {
        return false;
    }

    // Check if directory exists
    File dir = SD.open(path);
    if (!dir) {
        Serial.printf("Directory not found: %s\n", path);
        return false;
    }

    if (!dir.isDirectory()) {
        dir.close();
        Serial.printf("Not a directory: %s\n", path);
        return false;
    }

    dir.close();

    // Set new path
    strcpy(currentPath, path);

    // Ensure path ends with /
    size_t len = strlen(currentPath);
    if (len > 0 && currentPath[len - 1] != '/') {
        if (len < sizeof(currentPath) - 1) {
            currentPath[len] = '/';
            currentPath[len + 1] = '\0';
        }
    }

    scanDirectory();
    return true;
}

void FileBrowser::setFilter(const char* extensions) {
    if (extensions) {
        strncpy(filter, extensions, sizeof(filter) - 1);
        filter[sizeof(filter) - 1] = '\0';
        // Convert to uppercase for case-insensitive matching
        for (char* p = filter; *p; p++) {
            *p = toupper(*p);
        }
    } else {
        filter[0] = '\0';
    }

    // Re-scan with new filter
    scanDirectory();
}

void FileBrowser::scanDirectory() {
    entries.clear();

    File dir = SD.open(currentPath);
    if (!dir) {
        Serial.printf("Failed to open directory: %s\n", currentPath);
        return;
    }

    if (!dir.isDirectory()) {
        dir.close();
        return;
    }

    // Add parent directory entry if not at root
    if (strcmp(currentPath, "/") != 0) {
        FileEntry parent;
        strcpy(parent.name, "..");
        parent.size = 0;
        parent.isDirectory = true;
        entries.push_back(parent);
    }

    // Scan all entries
    File entry = dir.openNextFile();
    while (entry) {
        FileEntry fe;

        // Get filename (skip path)
        const char* name = entry.name();
        const char* lastSlash = strrchr(name, '/');
        if (lastSlash) {
            name = lastSlash + 1;
        }

        // Skip hidden files
        if (name[0] == '.') {
            entry = dir.openNextFile();
            continue;
        }

        strncpy(fe.name, name, sizeof(fe.name) - 1);
        fe.name[sizeof(fe.name) - 1] = '\0';
        fe.size = entry.size();
        fe.isDirectory = entry.isDirectory();

        // Apply filter (directories always pass)
        if (fe.isDirectory || matchesFilter(fe.name)) {
            entries.push_back(fe);
        }

        entry = dir.openNextFile();
    }

    dir.close();

    // Sort entries: directories first, then alphabetically
    std::sort(entries.begin(), entries.end(), [](const FileEntry& a, const FileEntry& b) {
        // Parent directory always first
        if (strcmp(a.name, "..") == 0) return true;
        if (strcmp(b.name, "..") == 0) return false;

        // Directories before files
        if (a.isDirectory != b.isDirectory) {
            return a.isDirectory;
        }

        // Alphabetical order (case-insensitive)
        return strcasecmp(a.name, b.name) < 0;
    });

    Serial.printf("Scanned %s: %d entries\n", currentPath, entries.size());
}

bool FileBrowser::matchesFilter(const char* filename) {
    // No filter = match all
    if (filter[0] == '\0') {
        return true;
    }

    // Find extension
    const char* dot = strrchr(filename, '.');
    if (!dot || dot == filename) {
        return false;  // No extension
    }

    // Extract extension (uppercase)
    char ext[16];
    strncpy(ext, dot + 1, sizeof(ext) - 1);
    ext[sizeof(ext) - 1] = '\0';
    for (char* p = ext; *p; p++) {
        *p = toupper(*p);
    }

    // Check against filter list (comma-separated)
    char filterCopy[32];
    strcpy(filterCopy, filter);

    char* token = strtok(filterCopy, ",");
    while (token) {
        // Trim whitespace
        while (*token == ' ') token++;

        if (strcmp(ext, token) == 0) {
            return true;
        }
        token = strtok(NULL, ",");
    }

    return false;
}

const std::vector<FileEntry>& FileBrowser::getEntries() {
    return entries;
}

size_t FileBrowser::getEntryCount() {
    return entries.size();
}

bool FileBrowser::navigateUp() {
    if (strcmp(currentPath, "/") == 0) {
        return false;  // Already at root
    }

    // Remove trailing slash
    size_t len = strlen(currentPath);
    if (len > 1 && currentPath[len - 1] == '/') {
        currentPath[len - 1] = '\0';
        len--;
    }

    // Find last slash
    char* lastSlash = strrchr(currentPath, '/');
    if (lastSlash) {
        if (lastSlash == currentPath) {
            // Root directory
            currentPath[1] = '\0';
        } else {
            *lastSlash = '\0';
        }
    }

    scanDirectory();
    return true;
}

bool FileBrowser::navigateInto(size_t index) {
    if (index >= entries.size()) {
        return false;
    }

    const FileEntry& entry = entries[index];

    if (!entry.isDirectory) {
        return false;  // Can't navigate into file
    }

    // Handle parent directory
    if (strcmp(entry.name, "..") == 0) {
        return navigateUp();
    }

    // Build new path
    char newPath[256];
    if (strcmp(currentPath, "/") == 0) {
        snprintf(newPath, sizeof(newPath), "/%s", entry.name);
    } else {
        snprintf(newPath, sizeof(newPath), "%s/%s", currentPath, entry.name);
    }

    return setDirectory(newPath);
}

const char* FileBrowser::getCurrentPath() {
    return currentPath;
}

const FileEntry* FileBrowser::getEntry(size_t index) {
    if (index >= entries.size()) {
        return nullptr;
    }
    return &entries[index];
}
