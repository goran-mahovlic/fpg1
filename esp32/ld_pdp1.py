# ld_pdp1.py - PDP-1 Paper Tape Loader for ULX3S ESP32
# Based on emard's osd loaders for C64/UK101
#
# FIXED 2026-02-12: Root cause analysis by EMARD agent
# - Changed SPI channel from 1 to 2 (VSPI, not HSPI)
# - Added alloc_emergency_exception_buf(100) for ISR safety
# - Reduced baudrate from 20MHz to 3MHz for stability
# - Added gc.collect() for memory management
# - Fixed CS pin logic to match emard's osd.py
#
# Usage:
#   import ld_pdp1
#   ld = ld_pdp1.ld_pdp1(spi, cs)
#   ld.load("/sd/pdp1/snowflake.rim")
#
# Or quick load:
#   import ld_pdp1
#   ld_pdp1.load("/sd/pdp1/snowflake.rim")

from machine import SPI, Pin
from micropython import const, alloc_emergency_exception_buf
import time
import os
import gc

# CRITICAL: Allocate emergency exception buffer for ISR safety
# This MUST be called before any SPI operations on ESP32
alloc_emergency_exception_buf(100)

# SPI Configuration - from emard/ulx3s_c64/esp32/osd/osdpin.py
# ULX3S v3.1.6/v3.1.7 direct wifi_gpio pins (NO external wiring needed!)
# https://github.com/emard/ulx3s_c64/blob/main/esp32/osd/osdpin.py#L18
gpio_cs   = const(19)
gpio_sck  = const(26)
gpio_miso = const(12)
gpio_mosi = const(4)

# SPI channel and frequency - CRITICAL: use channel 2, not 1!
spi_channel = const(2)  # VSPI on ESP32
# FIXED 2026-02-13: Changed from 3MHz to 1MHz for better timing margin
# 3MHz caused SPI commands to fail on ULX3S v3.1.7 with ESP32 OSD bitstream
spi_freq = const(1000000)  # 1 MHz - verified working

# SPI Commands (MiSTer compatible via esp32_osd.v)
CMD_FILE_TX_EN   = const(0x53)
CMD_FILE_TX_DATA = const(0x54)
CMD_FILE_INDEX   = const(0x55)
CMD_STATUS       = const(0x1E)
CMD_OSD_ENABLE   = const(0x41)
CMD_OSD_DISABLE  = const(0x40)
CMD_READ_BTN     = const(0xFB)  # Read button status (clears IRQ)
CMD_READ_IRQ     = const(0xF1)  # Read IRQ flags
CMD_OSD_WRITE    = const(0x20)  # Write OSD line (0x20-0x2F for lines 0-15)

# IRQ pin from FPGA - FIXED 2026-02-14: Use GPIO 22 for v3.1.7 (per Emard)
# GPIO 25 was wrong, Emard's C64 osd.py uses GPIO 22 (wifi_gpio22)
gpio_irq = const(22)

# =============================================================================
# Button Bit Masks (ACTIVE-HIGH after FPGA debounce)
# =============================================================================
# ULX3S button mapping from ulx3s_input.v:
#   BTN[0] = PWR (DO NOT USE - it's RESET!)
#   BTN[1] = UP
#   BTN[2] = DOWN
#   BTN[3] = LEFT
#   BTN[4] = RIGHT
#   BTN[5] = F1
#   BTN[6] = F2
# =============================================================================
BTN_UP    = const(0x02)  # btn[1]
BTN_DOWN  = const(0x04)  # btn[2]
BTN_LEFT  = const(0x08)  # btn[3]
BTN_RIGHT = const(0x10)  # btn[4]
BTN_F1    = const(0x20)  # btn[5]
BTN_F2    = const(0x40)  # btn[6]

# =============================================================================
# OSD COMBO - VERIFIED 2026-02-14 via debug_buttons()
# =============================================================================
# ULX3S button mapping (from ulx3s_input.v):
#   BTN[1] = UP    = 0x02
#   BTN[2] = DOWN  = 0x04
#   BTN[3] = LEFT  = 0x08
#   BTN[4] = RIGHT = 0x10
#
# Cursor combo = UP+DOWN+LEFT+RIGHT = 0x02+0x04+0x08+0x10 = 0x1E
#
# NOTE: C64 uses 0x78 because C64 has different button mapping.
# Our PDP-1 port uses ULX3S native mapping, so we use 0x1E.
# =============================================================================
OSD_CURSOR_COMBO = const(0x1E)  # ULX3S cursor combo: UP+DOWN+LEFT+RIGHT

# File type index for RIM files
FILE_INDEX_RIM = const(1)


def init_spi():
    """Initialize SPI and CS pin with correct settings"""
    global spi, cs
    spi = SPI(spi_channel, baudrate=spi_freq, polarity=0, phase=0,
              bits=8, firstbit=SPI.MSB,
              sck=Pin(gpio_sck), mosi=Pin(gpio_mosi), miso=Pin(gpio_miso))
    cs = Pin(gpio_cs, Pin.OUT)
    cs.on()  # CS inactive = HIGH = on()  (FIXED 2026-02-13)
    return spi, cs


class ld_pdp1:
    def __init__(self, spi=None, cs=None):
        if spi is None or cs is None:
            self.spi, self.cs = init_spi()
        else:
            self.spi = spi
            self.cs = cs
        # Ensure CS starts inactive (HIGH)
        self.cs.on()  # HIGH = inactive (FIXED 2026-02-13)

    def _cs_active(self):
        """CS active (active low) = LOW = off()

        FIXED 2026-02-13: Pin.on() gives HIGH, Pin.off() gives LOW
        CS is active-low, so we need LOW for active = off()
        """
        self.cs.off()  # LOW = active

    def _cs_inactive(self):
        """CS inactive (high) = HIGH = on()"""
        self.cs.on()  # HIGH = inactive

    def ctrl(self, i):
        """Send control byte via status command"""
        self._cs_active()
        self.spi.write(bytearray([CMD_STATUS, i & 0xFF, 0, 0, 0]))
        self._cs_inactive()

    def cpu_halt(self):
        """Halt CPU (status bit 1)"""
        self.ctrl(2)

    def cpu_run(self):
        """Start/continue CPU (status bit 0)"""
        self.ctrl(0)

    def cpu_reset(self):
        """Reset CPU (status bit 0)"""
        self.ctrl(1)

    def file_tx_enable(self, en=True):
        """Enable/disable file transfer mode"""
        self._cs_active()
        self.spi.write(bytearray([CMD_FILE_TX_EN, 1 if en else 0]))
        self._cs_inactive()

    def file_index(self, idx):
        """Set file type index"""
        self._cs_active()
        self.spi.write(bytearray([CMD_FILE_INDEX, idx & 0xFF]))
        self._cs_inactive()

    def file_tx_data(self, data):
        """Send file data bytes"""
        self._cs_active()
        self.spi.write(bytearray([CMD_FILE_TX_DATA]))
        self.spi.write(data)
        self._cs_inactive()

    def load(self, filename, verbose=True):
        """Load RIM paper tape file to PDP-1"""

        # Check file exists
        try:
            stat = os.stat(filename)
            filesize = stat[6]
        except OSError as e:
            print("Error: File not found: {} ({})".format(filename, e))
            return False

        if verbose:
            print("Loading {} ({} bytes)".format(filename, filesize))

        # Open file
        try:
            f = open(filename, "rb")
        except OSError as e:
            print("Error: Cannot open file: {} ({})".format(filename, e))
            return False

        # Set file index for RIM type
        self.file_index(FILE_INDEX_RIM)

        # Enable file transfer
        self.file_tx_enable(True)

        # Stream file in chunks
        CHUNK_SIZE = 256
        total_sent = 0

        try:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                self.file_tx_data(chunk)
                total_sent += len(chunk)
                if verbose and total_sent % 1024 == 0:
                    print("  {}/{} bytes".format(total_sent, filesize))
                    gc.collect()  # Prevent memory fragmentation
        except Exception as e:
            print("Error during transfer: {}".format(e))
            f.close()
            self.file_tx_enable(False)
            gc.collect()
            return False

        f.close()

        # Disable file transfer
        self.file_tx_enable(False)

        if verbose:
            print("Done. Sent {} bytes.".format(total_sent))

        gc.collect()
        return True

    def load_from_bytes(self, data, verbose=True):
        """Load RIM paper tape data from bytes (already in memory)

        ADDED 2026-02-13: Allows loading from pre-read file data,
        solving SD/SPI pin conflict by reading file before SPI init.
        """
        if verbose:
            print("Sending {} bytes to FPGA...".format(len(data)))

        # Set file index for RIM type
        self.file_index(FILE_INDEX_RIM)

        # Enable file transfer
        self.file_tx_enable(True)

        # Stream data in chunks
        CHUNK_SIZE = 256
        total_sent = 0
        offset = 0

        try:
            while offset < len(data):
                chunk = data[offset:offset + CHUNK_SIZE]
                self.file_tx_data(chunk)
                total_sent += len(chunk)
                offset += CHUNK_SIZE
                if verbose and total_sent % 1024 == 0:
                    print("  {}/{} bytes".format(total_sent, len(data)))
                    gc.collect()  # Prevent memory fragmentation
        except Exception as e:
            print("Error during transfer: {}".format(e))
            self.file_tx_enable(False)
            gc.collect()
            return False

        # Disable file transfer
        self.file_tx_enable(False)

        if verbose:
            print("Done. Sent {} bytes.".format(total_sent))

        gc.collect()
        return True

    def load_and_run(self, filename, verbose=True):
        """Load RIM file and start execution with proper halt/reset/run sequence"""
        # Halt CPU before loading
        if verbose:
            print("Halting CPU...")
        self.cpu_halt()
        time.sleep_ms(50)

        # Reset CPU
        if verbose:
            print("Resetting CPU...")
        self.cpu_reset()
        time.sleep_ms(50)

        # Load the file
        if self.load(filename, verbose):
            time.sleep_ms(100)  # Wait for FPGA to process

            # Start CPU
            if verbose:
                print("Starting CPU...")
            self.cpu_run()
            gc.collect()
            return True
        return False

    def load_and_run_from_bytes(self, data, verbose=True):
        """Load RIM data from bytes and start execution

        ADDED 2026-02-13: Companion to load_from_bytes for pre-read data.
        """
        # Halt CPU before loading
        if verbose:
            print("Halting CPU...")
        self.cpu_halt()
        time.sleep_ms(50)

        # Reset CPU
        if verbose:
            print("Resetting CPU...")
        self.cpu_reset()
        time.sleep_ms(50)

        # Load from bytes
        if self.load_from_bytes(data, verbose):
            time.sleep_ms(100)  # Wait for FPGA to process

            # Start CPU
            if verbose:
                print("Starting CPU...")
            self.cpu_run()
            gc.collect()
            return True
        return False


# Release SD card pins to allow SPI access
def release_sd_pins():
    """Put SD card pins in high-impedance mode"""
    # SD pins that need to be released: 2, 4, 12, 13, 14, 15
    sd_pins = [2, 4, 12, 13, 14, 15]
    for p in sd_pins:
        try:
            pin = Pin(p, Pin.IN)  # Set as input (high-Z)
            del pin
        except:
            pass
    print("SD pins released")
    gc.collect()


# Convenience function for interactive use
def load(filename):
    """Quick load function - initializes SPI and loads file

    FIXED 2026-02-13: Read file into memory BEFORE releasing SD pins!
    GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD and SPI.
    Previous code released SD pins first, which unmounted SD card.

    New sequence:
    1. Read file into memory (SD still works)
    2. Release SD pins (unmounts SD but we have data in RAM)
    3. Init SPI and send data to FPGA
    """
    # Step 1: Read file into memory while SD is still accessible
    try:
        stat = os.stat(filename)
        filesize = stat[6]
    except OSError as e:
        print("Error: File not found: {} ({})".format(filename, e))
        return False

    print("Reading {} ({} bytes) into memory...".format(filename, filesize))

    try:
        with open(filename, "rb") as f:
            file_data = f.read()
    except OSError as e:
        print("Error: Cannot read file: {}".format(e))
        return False

    gc.collect()
    print("File loaded into RAM ({} bytes)".format(len(file_data)))

    # Step 2: Now release SD pins and initialize SPI
    # NOTE: Commented out - SPI works without releasing SD pins on ULX3S v3.1.7
    # release_sd_pins()

    # Initialize SPI with correct settings (1 MHz for stability)
    spi, cs = init_spi()

    ld = ld_pdp1(spi, cs)

    # Step 3: Send data to FPGA using modified load_from_bytes method
    result = ld.load_and_run_from_bytes(file_data, verbose=True)
    gc.collect()
    return result


# Test function - minimal SPI test
def test():
    """Test SPI communication - minimal test that should NOT crash"""
    print("=== SPI Test Start ===")

    # Step 1: Initialize with correct settings
    print("1. Initializing SPI channel 2 @ 3MHz...")
    spi, cs = init_spi()
    print("   SPI init OK")

    # Step 2: Create loader instance
    print("2. Creating ld_pdp1 instance...")
    ld = ld_pdp1(spi, cs)
    print("   Instance OK")

    # Step 3: Test OSD toggle
    print("3. Testing OSD toggle...")
    try:
        ld._cs_active()
        spi.write(bytearray([CMD_OSD_ENABLE]))
        ld._cs_inactive()
        time.sleep_ms(5000)

        ld._cs_active()
        spi.write(bytearray([CMD_OSD_DISABLE]))
        ld._cs_inactive()
        print("   OSD toggle OK")
    except Exception as e:
        print("   OSD toggle FAILED: {}".format(e))

    print("=== SPI Test Complete ===")
    gc.collect()
    return ld


# Ultra-minimal test - just SPI init, no data transfer
def test_minimal():
    """Ultra-minimal test - only SPI initialization"""
    print("=== Minimal SPI Init Test ===")
    print("Pins: CS={}, SCK={}, MOSI={}, MISO={}".format(gpio_cs, gpio_sck, gpio_mosi, gpio_miso))
    try:
        spi = SPI(spi_channel, baudrate=spi_freq, polarity=0, phase=0,
                  sck=Pin(gpio_sck), mosi=Pin(gpio_mosi), miso=Pin(gpio_miso))
        cs = Pin(gpio_cs, Pin.OUT)
        cs.on()  # HIGH = inactive (FIXED 2026-02-13)
        print("SPI({}) @ {}Hz init OK".format(spi_channel, spi_freq))
        return True
    except Exception as e:
        print("SPI init FAILED: {}".format(e))
        return False


# =============================================================================
# OSD Controller with IRQ Support and COMBO Detection
# =============================================================================
# FIXED 2026-02-13 by Emard Agent based on C64 osd.py analysis
#
# CHANGES:
# 1. Button combo: 0x1E (UP+DOWN+LEFT+RIGHT) umjesto 0x7E (sve tipke)
# 2. IRQ: PULL_UP + IRQ_FALLING (kao C64) umjesto PULL_DOWN + IRQ_RISING
# 3. SPI read: write_readinto sa padding (kao C64 spi_read_btn)
# 4. Enable state tracking: enable bytearray za wait-for-release
# =============================================================================

# SPI command buffers (like C64 osd.py)
spi_read_irq = bytearray([1, 0xF1, 0, 0, 0, 0, 0])  # 7 bytes
spi_read_btn = bytearray([1, 0xFB, 0, 0, 0, 0, 0])  # 7 bytes
spi_result = bytearray(7)

class OsdController:
    """OSD Controller with IRQ-driven button handling - C64 style"""

    def __init__(self, spi=None, cs=None):
        """Initialize OSD controller"""
        if spi is None or cs is None:
            self.spi, self.cs = init_spi()
        else:
            self.spi = spi
            self.cs = cs

        self.osd_visible = False
        self.menu_cursor = 0
        self.menu_items = []
        self._irq_enabled = False

        # Enable state tracking (like C64)
        # Bit 0: OSD visible
        # Bit 1: Wait for all buttons released
        self.enable = bytearray(1)

        # FIXED 2026-02-14: Polling mechanism for ISR safety
        # ISR ne smije print() - samo postavlja flag, main loop procesira
        self._pending_btn = 0
        self._btn_event = False
        self._osd_toggled = False  # Flag za OSD toggle event

        # Ensure CS starts inactive (HIGH)
        self.cs.on()  # HIGH = inactive

    def _cs_active(self):
        """Activate CS (active low) = LOW = off()

        FIXED 2026-02-13: Pin.on()=HIGH, Pin.off()=LOW
        CS is active-low, so LOW = active
        """
        self.cs.off()  # LOW = active

    def _cs_inactive(self):
        """Deactivate CS = HIGH = on()"""
        self.cs.on()  # HIGH = inactive

    # =========================================================================
    # IRQ Handling - FIXED to match C64 osd.py
    # =========================================================================

    def setup_irq(self):
        """Setup IRQ handler for FPGA button events - C64 style"""
        try:
            # C64 uses: Pin.PULL_UP + IRQ_FALLING
            self.irq_pin = Pin(gpio_irq, Pin.IN, Pin.PULL_UP)
            self._irq_handler_ref = self._irq_handler  # Prevent GC
            self.irq_pin.irq(trigger=Pin.IRQ_FALLING, handler=self._irq_handler_ref)
            self._irq_enabled = True
            print("IRQ on GPIO{} (PULL_UP, FALLING)".format(gpio_irq))
            print("OSD combo: UP+DOWN+LEFT+RIGHT (4 tipke)")
        except Exception as e:
            print("IRQ setup failed: {}".format(e))
            self._irq_enabled = False

    def disable_irq(self):
        """Disable IRQ handler"""
        if self._irq_enabled:
            try:
                self.irq_pin.irq(handler=None)
                self._irq_enabled = False
            except:
                pass

    def _irq_handler(self, pin):
        """Handle IRQ from FPGA - MINIMAL ISR, BEZ PRINT!

        FIXED 2026-02-14: ISR ne smije:
        - print() - ZABRANJENO (I/O)
        - .format() - ZABRANJENO (alocira memoriju)
        - Kompleksne operacije - ZABRANJENO

        ISR samo cita SPI i postavlja flagove.
        poll_events() procesira evente iz main loop-a.
        """
        # FAZA 1: Check IRQ flag (Emardov pristup)
        self._cs_active()
        self.spi.write_readinto(spi_read_irq, spi_result)
        self._cs_inactive()
        btn_irq = spi_result[6]  # BYTE 6 per Emard!

        # Check if it's a button event (bit 7 = IRQ pending)
        if btn_irq & 0x80:
            # FAZA 2: Read button status (also clears IRQ)
            self._cs_active()
            self.spi.write_readinto(spi_read_btn, spi_result)
            self._cs_inactive()
            btn = spi_result[6]  # BYTE 6 per Emard!

            # SAMO postavi flag - NEMA PRINT!
            if btn > 1:
                self._pending_btn = btn
                self._btn_event = True

    def poll_events(self):
        """Procesira button evente - poziva se iz main loop-a

        FIXED 2026-02-14: Sva logika koja koristi print() je OVDJE,
        ne u ISR handleru. ISR samo postavlja flagove.
        """
        if not self._btn_event:
            return

        # Clear flag i uzmi button vrijednost
        self._btn_event = False
        btn = self._pending_btn

        # Debug output - OVDJE JE SIGURNO jer smo izvan ISR-a
        print("BTN: 0x{:02x}".format(btn))

        # State machine (Emardov pristup)
        if self.enable[0] & 2:  # Wait for all buttons released
            if btn == 1:  # btn == 1, NE btn <= 1 per Emard!
                self.enable[0] &= 1  # Clear wait bit
        else:
            # Check for cursor combo: 0x1E (ULX3S mapping: UP+DOWN+LEFT+RIGHT)
            if (btn & 0x1E) == 0x1E:  # VERIFIED via debug_buttons()
                self.enable[0] = (self.enable[0] ^ 1) | 2  # Toggle OSD, set wait
                self._osd_enable_hw(self.enable[0] & 1)
                self.osd_visible = bool(self.enable[0] & 1)
                print("OSD toggle: {}".format("ON" if self.osd_visible else "OFF"))
                if self.osd_visible:
                    # Use cached directory listing (populated at startup)
                    self.show_dir()

            # Normal button handling when OSD visible
            elif self.enable[0] == 1:  # OSD on, not waiting
                # Single button press detection (with BTN[0] possibly set)
                btn_only = btn & 0x7E  # Mask out BTN[0]
                if btn_only == BTN_UP:
                    self.menu_up()
                elif btn_only == BTN_DOWN:
                    self.menu_down()
                elif btn_only == BTN_LEFT:
                    self.updir()
                elif btn_only == BTN_RIGHT:
                    self.select_entry()
                elif btn_only == BTN_F1:
                    # F1 = refresh directory listing
                    self.refresh_dir()

    # =========================================================================
    # SPI Communication - C64 style with write_readinto
    # =========================================================================

    def read_irq_flags(self):
        """Read IRQ flags from FPGA

        FIXED 2026-02-14: Use byte 6 per Emardov pristup!
        C64 FPGA adds 4 dummy bytes delay, we must match this.
        """
        self._cs_active()
        self.spi.write_readinto(spi_read_irq, spi_result)
        self._cs_inactive()
        return spi_result[6]  # FIXED: Position 6 per Emard!

    def read_buttons(self):
        """Read button status from FPGA (also clears button IRQ)

        FIXED 2026-02-14: Use byte 6 per Emardov pristup!
        """
        self._cs_active()
        self.spi.write_readinto(spi_read_btn, spi_result)
        self._cs_inactive()
        return spi_result[6]  # FIXED: Position 6 per Emard!

    def _osd_enable_hw(self, en):
        """Low-level OSD enable/disable - FIXED 2026-02-14 per Emardov pristup

        Emard koristi 6-byte format: [0, 0xFE, 0, 0, 0, en]
        Ovo osigurava kompatibilnost s esp32_osd.v firmware.
        """
        self._cs_active()
        # FIXED: Use Emard's 6-byte format for OSD enable
        self.spi.write(bytearray([0, 0xFE, 0, 0, 0, 1 if en else 0]))
        self._cs_inactive()

    def osd_enable(self, enable):
        """Enable or disable OSD overlay - FIXED 2026-02-14 per Emardov pristup"""
        self._cs_active()
        # FIXED: Use Emard's 6-byte format for OSD enable
        self.spi.write(bytearray([0, 0xFE, 0, 0, 0, 1 if enable else 0]))
        self._cs_inactive()

    def osd_write_line(self, line, text):
        """Write text to OSD line (0-15, max 32 chars)"""
        if line < 0 or line > 15:
            return
        # Pad or truncate to 32 chars (MicroPython compatible)
        text = str(text)[:32]
        text = text + ' ' * (32 - len(text))  # Manual padding
        self._cs_active()
        self.spi.write(bytearray([CMD_OSD_WRITE + line]))
        self.spi.write(text.encode('ascii', 'replace'))
        self._cs_inactive()

    def osd_clear(self):
        """Clear all OSD lines"""
        for i in range(16):
            self.osd_write_line(i, "")

    # =========================================================================
    # File Browser System - C64 style
    # =========================================================================
    # Based on emard/ulx3s_c64/esp32/osd/osd.py file browser
    # =========================================================================

    def init_fb(self):
        """Initialize file browser state"""
        self.fb_topitem = 0
        self.fb_cursor = 0
        self.fb_selected = -1
        self.cwd = "/"
        self.direntries = []
        self.screen_y = 14  # OSD lines for directory display (lines 1-14)

    def read_dir(self):
        """Read directory contents - C64 style

        NOTE: SD card pins (GPIO 4, 12) are shared with SPI. When SPI is active,
        SD card may not be accessible. If directory read fails, keep existing
        cached entries.
        """
        if not hasattr(self, 'cwd'):
            self.init_fb()

        # Try to read directory, but don't clear existing cache if it fails
        new_entries = []
        try:
            ls = sorted(os.listdir(self.cwd))
            for fname in ls:
                try:
                    fullpath = self.fullpath(fname)
                    stat = os.stat(fullpath)
                    if stat[0] & 0o170000 == 0o040000:
                        new_entries.append([fname, 1, 0])  # directory
                    else:
                        # Filter: only show .rim, .bin, .bit files
                        if fname.endswith('.rim') or fname.endswith('.bin') or fname.endswith('.bit'):
                            new_entries.append([fname, 0, stat[6]])  # file
                except:
                    pass
                gc.collect()
            # Only update if we got entries (SD was accessible)
            if new_entries:
                self.direntries = new_entries
        except Exception as e:
            print("read_dir: SD not accessible, using cache")

    def fullpath(self, fname):
        """Get full path for filename"""
        if self.cwd.endswith("/"):
            return self.cwd + fname
        else:
            return self.cwd + "/" + fname

    def show_dir(self):
        """Display directory listing on OSD"""
        # Header
        self.osd_write_line(0, "=== {} ===".format(self.cwd[:26]))

        # Directory entries
        for i in range(self.screen_y):
            self.show_dir_line(i)

        # Footer with instructions
        self.osd_write_line(15, "U/D:Nav L:Bk R:Sel F1:Rfsh")

    def show_dir_line(self, y):
        """Show single directory line - C64 style"""
        if y < 0 or y >= self.screen_y:
            return

        # Markers: space, cursor (>), selected (*)
        smark = [' ', '>', '*']

        mark = 0
        invert = 0
        if y == self.fb_cursor - self.fb_topitem:
            mark = 1
            invert = 1
        if y == self.fb_selected - self.fb_topitem:
            mark = 2

        i = y + self.fb_topitem
        if i >= len(self.direntries):
            self.osd_write_line(y + 1, "")
            return

        entry = self.direntries[i]
        if entry[1]:  # directory
            line = "{}{:<26}  DIR".format(smark[mark], entry[0][:26])
        else:  # file
            size = entry[2]
            if size >= 1024*1024:
                sizestr = "{}M".format(size // (1024*1024))
            elif size >= 1024:
                sizestr = "{}K".format(size // 1024)
            else:
                sizestr = "{}".format(size)
            line = "{}{:<26} {:>4}".format(smark[mark], entry[0][:26], sizestr[:4])

        self.osd_write_line(y + 1, line)

    def refresh_dir(self):
        """Refresh directory listing - ADDED 2026-02-14

        Called on F1 press. Attempts to re-read SD card directory.
        NOTE: This may fail if SD pins are held by SPI. In that case,
        we keep the cached listing and show a message.
        """
        self.osd_write_line(15, "Refreshing...")
        old_count = len(self.direntries)
        self.read_dir()  # Will use cache if SD not accessible
        new_count = len(self.direntries)

        if new_count != old_count:
            # Directory changed, reset cursor
            self.fb_cursor = 0
            self.fb_topitem = 0

        self.show_dir()
        self.osd_write_line(15, "F1:Refresh {} files".format(new_count))

    def move_dir_cursor(self, step):
        """Move cursor in directory - C64 style"""
        oldcursor = self.fb_cursor

        if step == 1:  # DOWN
            if self.fb_cursor < len(self.direntries) - 1:
                self.fb_cursor += 1
        elif step == -1:  # UP
            if self.fb_cursor > 0:
                self.fb_cursor -= 1

        if oldcursor != self.fb_cursor:
            screen_line = self.fb_cursor - self.fb_topitem
            if 0 <= screen_line < self.screen_y:
                # Move cursor inside screen, no scroll
                self.show_dir_line(oldcursor - self.fb_topitem)
                self.show_dir_line(screen_line)
            else:
                # Scroll needed
                if screen_line < 0:
                    if self.fb_topitem > 0:
                        self.fb_topitem -= 1
                        self.show_dir()
                else:
                    if self.fb_topitem + self.screen_y < len(self.direntries):
                        self.fb_topitem += 1
                        self.show_dir()

    def select_entry(self):
        """Select current entry - directory or file"""
        if not self.direntries or self.fb_cursor >= len(self.direntries):
            return

        entry = self.direntries[self.fb_cursor]
        if entry[1]:  # Directory
            oldselected = self.fb_selected - self.fb_topitem
            self.fb_selected = self.fb_cursor
            try:
                self.cwd = self.fullpath(entry[0])
            except:
                self.fb_selected = -1
            self.show_dir_line(oldselected)
            self.show_dir_line(self.fb_cursor - self.fb_topitem)
            self.init_fb()
            self.cwd = self.fullpath(entry[0]) if entry[1] else self.cwd
            self.read_dir()
            self.show_dir()
        else:  # File
            self.load_file(entry[0])

    def updir(self):
        """Go up one directory level"""
        if len(self.cwd) < 2:
            self.cwd = "/"
        else:
            parts = self.cwd.split("/")[:-1]
            self.cwd = "/".join(parts) if parts else "/"
            if not self.cwd:
                self.cwd = "/"

        self.init_fb()
        self.read_dir()
        self.show_dir()

    def load_file(self, fname):
        """Load selected file

        IMPORTANT: GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD
        and SPI. To load a file, we must:
        1. Read file into memory (while SD is accessible)
        2. Close SD access
        3. Release SD pins
        4. Reinit SPI
        5. Send data to FPGA
        """
        fullpath = self.fullpath(fname)

        # Show loading message
        self.osd_write_line(15, "Loading {}...".format(fname[:20]))

        # Handle different file types
        if fname.endswith('.bit'):
            # FPGA bitstream - ecp5.prog() handles file reading internally
            self._osd_enable_hw(0)
            self.enable[0] = 0
            try:
                import ecp5
                # NOTE: ecp5.prog() deinits SPI, so we need to reinit after
                ecp5.prog(fullpath)
                print("Loaded bitstream: {}".format(fullpath))
                # Reinit SPI after ecp5.prog()
                release_sd_pins()
                self.spi, self.cs = init_spi()
            except Exception as e:
                print("Bitstream load error: {}".format(e))
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_write_line(15, "LOAD ERROR!")
                return
        elif fname.endswith('.rim') or fname.endswith('.bin'):
            # PDP-1 tape file - MUST read into memory first!
            self._osd_enable_hw(0)
            self.enable[0] = 0
            self.osd_visible = False

            # Step 1: Read file into memory while SD is still accessible
            try:
                with open(fullpath, "rb") as f:
                    file_data = f.read()
                print("Read {} bytes into memory".format(len(file_data)))
            except Exception as e:
                print("File read error: {}".format(e))
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "READ FAILED!")
                return

            gc.collect()

            # Step 2: Release SD pins to allow clean SPI access
            release_sd_pins()

            # Step 3: Reinitialize SPI (pins now free from SD)
            self.spi, self.cs = init_spi()

            # Step 4: Send data to FPGA using load_from_bytes
            loader = ld_pdp1(self.spi, self.cs)
            result = loader.load_and_run_from_bytes(file_data, verbose=False)

            gc.collect()

            if not result:
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "LOAD FAILED!")
            else:
                print("Loaded: {}".format(fullpath))

    def menu_up(self):
        """Move menu cursor up"""
        self.move_dir_cursor(-1)

    def menu_down(self):
        """Move menu cursor down"""
        self.move_dir_cursor(1)


# =============================================================================
# OSD Quick Start - C64 style
# =============================================================================

def start_osd(mount_sd=True):
    """Initialize and start OSD controller with IRQ support - C64 style

    Usage:
        import ld_pdp1
        osd = ld_pdp1.start_osd()
        # Press UP+DOWN+LEFT+RIGHT (cursor keys) to toggle OSD menu

    Args:
        mount_sd: If True, mount SD card first (default)

    IMPORTANT: GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD card
    and SPI. SD card must be unmounted and pins released before SPI works!
    """
    # Mount SD card like C64 does
    if mount_sd:
        try:
            from machine import SDCard
            os.mount(SDCard(slot=3), "/sd")
            print("SD card mounted at /sd")
        except Exception as e:
            print("SD mount: {}".format(e))

    # Initialize OSD controller
    # CRITICAL: OsdController.init_spi() will configure GPIO 12 for SPI MISO
    # But SD card may still hold these pins. We need to release them first!

    # Step 1: Read directory listing into memory while SD is accessible
    direntries_cache = []
    cwd_start = "/sd"
    try:
        ls = sorted(os.listdir(cwd_start))
        for fname in ls:
            try:
                fullpath = cwd_start + "/" + fname
                stat = os.stat(fullpath)
                if stat[0] & 0o170000 == 0o040000:
                    direntries_cache.append([fname, 1, 0])  # directory
                else:
                    if fname.endswith('.rim') or fname.endswith('.bin') or fname.endswith('.bit'):
                        direntries_cache.append([fname, 0, stat[6]])  # file
            except:
                pass
        gc.collect()
    except Exception as e:
        print("read_dir error: {}".format(e))

    # Step 2: Unmount SD and release pins for SPI
    # NOTE: Commented out for now - keep SD mounted for file loading
    # try:
    #     os.umount("/sd")
    #     print("SD unmounted for SPI")
    # except:
    #     pass

    # Step 3: Release SD pins to allow SPI access
    # CRITICAL: This releases GPIO 4 and 12 from SD card controller
    release_sd_pins()

    # Step 4: Initialize OSD controller (will init SPI)
    osd = OsdController()
    osd.init_fb()  # Initialize file browser
    osd.cwd = cwd_start
    osd.direntries = direntries_cache  # Use cached directory
    osd.setup_irq()

    # Handle any pending IRQ
    osd._irq_handler(0)

    print("=" * 40)
    print("OSD Ready - C64 style")
    print("Combo: Press UP+DOWN+LEFT+RIGHT")
    print("Navigate: UP/DOWN")
    print("Select: RIGHT  |  Back: LEFT")
    print("=" * 40)

    return osd


def run():
    """Quick start: mount SD, init SPI, start OSD with DIRECT POLLING

    FIXED 2026-02-14: IRQ ne radi pouzdano na GPIO22.
    Umjesto toga, koristimo direktni SPI polling kao debug_buttons().
    Polling je pouzdan i verificiran - vidimo button evente!
    """
    gc.collect()
    osd = start_osd(mount_sd=True)

    # Disable IRQ - koristimo polling umjesto toga
    osd.disable_irq()

    print("OSD Running - DIRECT POLLING mode")
    print("Combo: UP+DOWN+LEFT+RIGHT to toggle OSD")
    print("Press Ctrl+C to exit")

    last_btn = 0

    try:
        while True:
            # Direktno citaj buttone preko SPI (kao debug_buttons)
            osd._cs_active()
            osd.spi.write_readinto(spi_read_btn, spi_result)
            osd._cs_inactive()
            btn = spi_result[6]

            # Procesira samo kad se promijeni
            if btn != last_btn and btn > 1:
                osd._pending_btn = btn
                osd._btn_event = True
                osd.poll_events()
            elif btn == 0 and last_btn != 0:
                # Released - clear wait bit if needed
                if osd.enable[0] & 2:
                    osd.enable[0] &= 1

            last_btn = btn
            time.sleep_ms(50)

    except KeyboardInterrupt:
        print("\nExited by user")

    return osd


# =============================================================================
# BUTTON DEBUG MODE - Added 2026-02-13 by Emard Agent
# =============================================================================
# Use this to debug button presses and verify FPGA IRQ communication.
# Run: import ld_pdp1; ld_pdp1.debug_buttons()
# =============================================================================

def debug_buttons(duration_sec=30):
    """Interactive button debug mode - shows pressed buttons in real-time.

    This function helps diagnose:
    1. If button presses are detected by FPGA
    2. If IRQ is generated correctly
    3. If SPI read commands work

    Usage:
        import ld_pdp1
        ld_pdp1.debug_buttons()
        # Press buttons on ULX3S - they should appear on screen
        # Press Ctrl+C to exit

    Args:
        duration_sec: How long to run (default 30 seconds)
    """
    print("=" * 50)
    print("BUTTON DEBUG MODE - ULX3S")
    print("=" * 50)
    print("Reading byte 6 (per Emard)")
    print("OSD Combo: (btn & 0x1E) == 0x1E (ULX3S mapping)")
    print("Wait for release: btn == 1")
    print("Press Ctrl+C to exit")
    print("=" * 50)

    # Release SD pins and init SPI
    release_sd_pins()
    spi, cs = init_spi()

    # Button reading buffers (like C64 osd.py)
    spi_read_btn = bytearray([1, 0xFB, 0, 0, 0, 0, 0])
    spi_read_irq = bytearray([1, 0xF1, 0, 0, 0, 0, 0])
    spi_result = bytearray(7)

    last_btn = 0
    start = time.ticks_ms()

    try:
        while time.ticks_diff(time.ticks_ms(), start) < duration_sec * 1000:
            # FAZA 1: Read IRQ flags (Emardov pristup)
            cs.off()
            spi.write_readinto(spi_read_irq, spi_result)
            cs.on()
            irq_flags = spi_result[6]  # FIXED: Byte 6 per Emard!

            # FAZA 2: Read button status (also clears IRQ)
            cs.off()
            spi.write_readinto(spi_read_btn, spi_result)
            cs.on()
            btn = spi_result[6]  # FIXED: Byte 6 per Emard!

            # Only print when something changes or IRQ detected
            if btn != last_btn or (irq_flags & 0x80):
                parts = []
                if btn & BTN_UP:    parts.append("UP")
                if btn & BTN_DOWN:  parts.append("DOWN")
                if btn & BTN_LEFT:  parts.append("LEFT")
                if btn & BTN_RIGHT: parts.append("RIGHT")
                if btn & BTN_F1:    parts.append("F1")
                if btn & BTN_F2:    parts.append("F2")

                if parts:
                    msg = "+".join(parts)
                    # Check for OSD combo (ULX3S mapping: 0x1E)
                    if (btn & 0x1E) == 0x1E:
                        msg += "  <<< OSD COMBO!"
                    print("BTN: 0x{:02X} = {}  IRQ:0x{:02X}".format(btn, msg, irq_flags))
                elif btn == 0 and last_btn != 0:
                    print("BTN: 0x00 = (released)")

                last_btn = btn

            time.sleep_ms(50)

    except KeyboardInterrupt:
        print("\nExited by user")

    print("=" * 50)
    print("Button debug ended")
    print("=" * 50)
    gc.collect()


def spi_diag():
    """SPI diagnostic - tests basic SPI communication with FPGA.

    Returns True if SPI appears to work, False if not.
    """
    print("=" * 50)
    print("SPI DIAGNOSTIC")
    print("=" * 50)

    # Release SD pins
    release_sd_pins()

    # Init SPI
    spi, cs = init_spi()

    # Test 1: Check if CS pin works
    print("\n1. Testing CS pin...")
    print("   CS HIGH (inactive)")
    cs.on()
    time.sleep_ms(100)
    print("   CS LOW (active)")
    cs.off()
    time.sleep_ms(100)
    cs.on()
    print("   CS back to HIGH")

    # Test 2: Send OSD enable and check for change
    print("\n2. Sending OSD_ENABLE (0x41)...")
    cs.off()
    time.sleep_ms(5)
    spi.write(bytearray([0x41]))
    time.sleep_ms(5)
    cs.on()
    print("   Sent. Check if OSD appears on screen.")

    time.sleep_ms(500)

    # Test 3: Read IRQ flags (Emardov pristup: byte 6)
    print("\n3. Reading IRQ flags (0xF1) - Emardov pristup...")
    spi_read = bytearray([1, 0xF1, 0, 0, 0, 0, 0])
    spi_result = bytearray(7)
    cs.off()
    spi.write_readinto(spi_read, spi_result)
    cs.on()
    irq_val = spi_result[6]  # FIXED: Byte 6 per Emard!
    print("   Response: {} -> IRQ flags (byte 6): 0x{:02X}".format(
        [hex(b) for b in spi_result], irq_val))

    # Test 4: Read buttons (Emardov pristup: byte 6)
    print("\n4. Reading buttons (0xFB) - Emardov pristup...")
    spi_read = bytearray([1, 0xFB, 0, 0, 0, 0, 0])
    cs.off()
    spi.write_readinto(spi_read, spi_result)
    cs.on()
    btn_val = spi_result[6]  # FIXED: Byte 6 per Emard!
    print("   Response: {} -> Buttons (byte 6): 0x{:02X}".format(
        [hex(b) for b in spi_result], btn_val))

    # Test 5: OSD disable
    print("\n5. Sending OSD_DISABLE (0x40)...")
    cs.off()
    time.sleep_ms(5)
    spi.write(bytearray([0x40]))
    time.sleep_ms(5)
    cs.on()
    print("   Sent. Check if OSD disappears.")

    print("\n" + "=" * 50)
    # Check if we got any response at position 2
    if irq_val == 0 and btn_val == 0:
        print("INFO: Both IRQ and buttons are 0x00")
        print("This is NORMAL when no buttons pressed and no pending IRQ.")
        print("SPI communication appears to work!")
        return True
    else:
        print("SPI appears to be working!")
        print("IRQ flags: 0x{:02X}, Buttons: 0x{:02X}".format(irq_val, btn_val))
        return True
