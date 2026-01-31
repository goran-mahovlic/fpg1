#pragma once
#include <vector>
#include <string>
#include <stdint.h>

struct FileEntry {
    char name[32];
    uint32_t size;
    bool isDirectory;
};

class FileBrowser {
public:
    bool init();
    bool setDirectory(const char* path);
    void setFilter(const char* extensions);  // "PDP,RIM,BIN"
    const std::vector<FileEntry>& getEntries();
    bool navigateUp();
    bool navigateInto(size_t index);
    const char* getCurrentPath();
    const FileEntry* getEntry(size_t index);
    size_t getEntryCount();

private:
    char currentPath[256];
    char filter[32];
    std::vector<FileEntry> entries;
    void scanDirectory();
    bool matchesFilter(const char* filename);
};

extern FileBrowser fileBrowser;
