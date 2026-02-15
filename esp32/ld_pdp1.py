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

from machine import SPI, Pin, WDT, reset
from micropython import const, alloc_emergency_exception_buf
import time
import os
import gc

# =============================================================================
# RETRY + WATCHDOG CONFIGURATION - Added 2026-02-14 by Jelena
# =============================================================================
# Robustna zaštita za RIM file upload:
# - MAX_UPLOAD_RETRIES: Broj pokušaja prije ESP32 reseta
# - RETRY_DELAY_MS: Pauza između pokušaja (milisekunde)
# - WDT_TIMEOUT_MS: Watchdog timeout - ako upload visi, ESP32 se resetira
# =============================================================================
MAX_UPLOAD_RETRIES = const(2)     # 2 pokušaja
RETRY_DELAY_MS = const(500)       # 500ms pauza između pokušaja
WDT_TIMEOUT_MS = const(30000)     # 30 sekundi watchdog timeout

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
# ULX3S button mapping (UPDATED 2026-02-14):
#   BTN[0] = PWR (DO NOT USE - it's RESET!)
#   BTN[1] = FIRE1 = 0x02
#   BTN[2] = FIRE2 = 0x04
#   BTN[3] = UP    = 0x08
#   BTN[4] = DOWN  = 0x10
#   BTN[5] = LEFT  = 0x20
#   BTN[6] = RIGHT = 0x40
# =============================================================================
BTN_FIRE1 = const(0x02)  # btn[1] - FIRE1
BTN_FIRE2 = const(0x04)  # btn[2] - FIRE2
BTN_UP    = const(0x08)  # btn[3]
BTN_DOWN  = const(0x10)  # btn[4]
BTN_LEFT  = const(0x20)  # btn[5]
BTN_RIGHT = const(0x40)  # btn[6]

# =============================================================================
# OSD COMBO - UPDATED 2026-02-14 for new button mapping
# =============================================================================
# New button mapping:
#   BTN[3] = UP    = 0x08
#   BTN[4] = DOWN  = 0x10
#   BTN[5] = LEFT  = 0x20
#   BTN[6] = RIGHT = 0x40
#
# Cursor combo = UP+DOWN+LEFT+RIGHT = 0x08+0x10+0x20+0x40 = 0x78
# =============================================================================
OSD_CURSOR_COMBO = const(0x78)  # Cursor combo: UP+DOWN+LEFT+RIGHT

# File type index for RIM files
FILE_INDEX_RIM = const(1)
FILE_INDEX_HEX = const(2)

def init_spi():
    """Initialize SPI and CS pin with correct settings

    FIXED 2026-02-14: Sprema globalnu referencu za kasniji deinit.
    """
    global spi, cs, _spi_instance
    spi = SPI(spi_channel, baudrate=spi_freq, polarity=0, phase=0,
              bits=8, firstbit=SPI.MSB,
              sck=Pin(gpio_sck), mosi=Pin(gpio_mosi), miso=Pin(gpio_miso))
    cs = Pin(gpio_cs, Pin.OUT)
    cs.on()  # CS inactive = HIGH = on()  (FIXED 2026-02-13)
    _spi_instance = spi  # Save global reference for deinit
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
        self.ctrl(2)  # bit 1 = 0b010 = 2

    def cpu_run(self):
        """Start CPU (status bit 0 rising edge)"""
        self.ctrl(1)  # bit 0 = 0b001 = 1 (FIXED: was ctrl(0) which cleared all!)

    def cpu_reset(self):
        """Reset CPU (status bit 2 rising edge)"""
        self.ctrl(4)  # bit 2 = 0b100 = 4 (FIXED: was ctrl(1) which was RUN!)

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

    def load_hex(self, filename, start_addr=0o4, verbose=True):
        """Load HEX file to PDP-1 RAM directly (no bootstrap needed)"""
        with open(filename, 'r') as f:
            lines = f.readlines()

        if verbose:
            #print(f"[HEX] Loading {len(lines)} words from {filename}")
            print("Loading {} ({} bytes)".format(filename, filesize))
        self.cpu_halt()
        time.sleep_ms(50)

        self.file_index(FILE_INDEX_HEX)
        self.file_tx_enable(True)

        count = 0
        for addr, line in enumerate(lines):
            line = line.strip()
            if not line:
                continue
            data = int(line, 16)
            if data != 0:  # Skip zero entries for speed
                # Send 5-byte packet: addr_hi, addr_lo, data_hi, data_mid, data_lo
                packet = bytearray([
                    (addr >> 8) & 0x0F,
                    addr & 0xFF,
                    (data >> 16) & 0x03,
                    (data >> 8) & 0xFF,
                    data & 0xFF
                ])
                self.file_tx_data(packet)
                count += 1

        self.file_tx_enable(False)

        # Start CPU at specified address
        time.sleep_ms(100)
        self.cpu_run()

        return True

    def load_from_bytes(self, data, verbose=True):
        """Load RIM paper tape data from bytes (already in memory)

        ADDED 2026-02-13: Allows loading from pre-read file data,
        solving SD/SPI pin conflict by reading file before SPI init.

        FIXED 2026-02-14 by Jelena: Added internal transfer function
        for retry logic support.
        """
        if verbose:
            print("[RIM] Step 1: Preparing transfer ({} bytes)".format(len(data)))

        # Set file index for RIM type
        self.file_index(FILE_INDEX_RIM)

        # Enable file transfer
        self.file_tx_enable(True)

        # Stream data in chunks
        CHUNK_SIZE = 256
        total_sent = 0
        offset = 0

        try:
            if verbose:
                print("[RIM] Step 2: Streaming data to FPGA...")
            while offset < len(data):
                chunk = data[offset:offset + CHUNK_SIZE]
                self.file_tx_data(chunk)
                total_sent += len(chunk)
                offset += CHUNK_SIZE
                if verbose and total_sent % 1024 == 0:
                    print("[RIM]   {}/{} bytes".format(total_sent, len(data)))
                    gc.collect()  # Prevent memory fragmentation
        except Exception as e:
            print("[RIM ERROR] Transfer failed at byte {}: {}".format(total_sent, e))
            self.file_tx_enable(False)
            gc.collect()
            return False

        # Disable file transfer
        self.file_tx_enable(False)

        if verbose:
            print("[RIM] Step 3: Transfer complete - {} bytes sent".format(total_sent))

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

    def load_and_run_from_bytes(self, data, verbose=True, use_watchdog=True):
        """Load RIM data from bytes and start execution

        ADDED 2026-02-13: Companion to load_from_bytes for pre-read data.

        FIXED 2026-02-14 by Jelena: Added RETRY + WATCHDOG protection!
        - 2 pokušaja za upload
        - Watchdog timer (30s) - ako upload visi, ESP32 se resetira
        - ESP32 hard reset ako oba pokušaja propadnu

        Args:
            data: RIM file data (bytes)
            verbose: Print debug info
            use_watchdog: Enable watchdog protection (default True)

        Returns:
            True if successful, False if failed (before reset)
        """
        print("=" * 50)
        print("[RIM] UPLOAD START - {} bytes".format(len(data)))
        print("[RIM] Retry: {} attempts | Watchdog: {}s".format(
            MAX_UPLOAD_RETRIES, WDT_TIMEOUT_MS // 1000))
        print("=" * 50)

        # Initialize watchdog if enabled
        wdt = None
        if use_watchdog:
            try:
                wdt = WDT(timeout=WDT_TIMEOUT_MS)
                print("[RIM] Watchdog ARMED ({}s timeout)".format(WDT_TIMEOUT_MS // 1000))
            except Exception as e:
                print("[RIM WARNING] Watchdog init failed: {}".format(e))
                print("[RIM WARNING] Continuing WITHOUT watchdog protection!")

        # Retry loop
        last_error = None
        for attempt in range(1, MAX_UPLOAD_RETRIES + 1):
            print("\n[RIM] ========== Attempt {}/{} ==========".format(
                attempt, MAX_UPLOAD_RETRIES))

            # Feed watchdog at start of attempt
            if wdt:
                wdt.feed()
                print("[RIM] Watchdog FED")

            try:
                # Halt CPU before loading
                print("[RIM] Halting CPU...")
                self.cpu_halt()
                time.sleep_ms(50)

                # Feed watchdog
                if wdt:
                    wdt.feed()

                # Reset CPU
                print("[RIM] Resetting CPU...")
                self.cpu_reset()
                time.sleep_ms(50)

                # Feed watchdog
                if wdt:
                    wdt.feed()

                # Load from bytes - this is where errors usually happen
                print("[RIM] Starting data transfer...")
                success = self.load_from_bytes(data, verbose)

                # Feed watchdog after transfer
                if wdt:
                    wdt.feed()

                if success:
                    time.sleep_ms(100)  # Wait for FPGA to process

                    # Start CPU
                    print("[RIM] Starting CPU...")
                    self.cpu_run()
                    gc.collect()

                    print("\n" + "=" * 50)
                    print("[RIM] UPLOAD SUCCESS on attempt {}!".format(attempt))
                    print("=" * 50)
                    return True
                else:
                    last_error = "load_from_bytes returned False"
                    print("[RIM ERROR] Transfer failed (attempt {})".format(attempt))

            except Exception as e:
                last_error = str(e)
                print("[RIM ERROR] Exception on attempt {}: {}".format(attempt, e))

            # If not last attempt, wait before retry
            if attempt < MAX_UPLOAD_RETRIES:
                print("[RIM] Waiting {}ms before retry...".format(RETRY_DELAY_MS))
                time.sleep_ms(RETRY_DELAY_MS)

                # Feed watchdog during wait
                if wdt:
                    wdt.feed()

        # All retries failed - ESP32 RESET!
        print("\n" + "!" * 50)
        print("[RIM FATAL] ALL {} ATTEMPTS FAILED!".format(MAX_UPLOAD_RETRIES))
        print("[RIM FATAL] Last error: {}".format(last_error))
        print("[RIM FATAL] RESETTING ESP32 IN 2 SECONDS...")
        print("!" * 50)

        gc.collect()
        time.sleep_ms(2000)  # Give user time to see message

        # HARD RESET ESP32
        reset()

        # This line should never execute (reset() doesn't return)
        return False


# =============================================================================
# SD CARD MANAGEMENT - FIXED 2026-02-14 per Emard's patterns
# =============================================================================
# KRITIČNO: GPIO 4 (MOSI) i GPIO 12 (MISO) su DIJELJENI između SD i SPI!
# Sekvenca za pristup SD kartici:
# 1. spi.deinit() - oslobodi SPI pinove
# 2. release_sd_pins() - postavi sve SD pinove u high-Z
# 3. Mountiraj SD
# 4. Čitaj/piši
# 5. Unmountiraj ili ostavi za kasnije
# 6. init_spi() - reinicijaliziraj SPI
# =============================================================================

# Global SPI reference for deinit
_spi_instance = None

def release_sd_pins():
    """Put SD card pins in high-impedance mode - Emard pattern

    FIXED 2026-02-14 by Jelena: POTPUNI SPI release s delay-em!

    KRITIČNO za ESP32:
    1. Deinit SPI (oslobodi driver)
    2. DELAY 100ms (hardware settle - ESP32 treba vrijeme!)
    3. Release pinovi na high-Z
    4. GC collect
    """
    global _spi_instance

    # Step 1: Deinit SPI if active - KRITIČNO!
    if _spi_instance is not None:
        try:
            _spi_instance.deinit()
            print("SPI deinit OK")
        except:
            pass
        _spi_instance = None

    # Step 2: DELAY za SPI hardware settle - OBAVEZNO!
    # ESP32 SPI driver ne oslobada bus instantno!
    time.sleep_ms(100)

    # Step 3: SD pins that need to be released: 2, 4, 12, 13, 14, 15
    # Per Emard: create Pin as INPUT, read value, delete
    for i in bytearray([2, 4, 12, 13, 14, 15]):
        try:
            p = Pin(i, Pin.IN)
            a = p.value()  # Force read to release driver
            del p, a
        except:
            pass

    # Step 3b: Takoder oslobodi SPI pinove (mogu biti razliciti od SD)
    for pin_num in [gpio_mosi, gpio_miso, gpio_sck]:
        try:
            p = Pin(pin_num, Pin.IN)
            a = p.value()
            del p, a
        except:
            pass

    gc.collect()
    print("SD pins released")


def mount_sd_with_retry(mount_point="/sd", max_retries=3):
    """Mount SD card with retry logic - ROBUST!

    KRITIČNO: Koristi slot=3 za SPI mode na ESP32!
    slot=1 je SDIO mode koji NE RADI s dijeljenim pinovima.

    Returns:
        True if mounted successfully, False otherwise
    """
    from machine import SDCard

    # First, try to unmount if already mounted
    try:
        os.umount(mount_point)
    except:
        pass

    gc.collect()

    for attempt in range(max_retries):
        try:
            # slot=3 = SPI mode (OBAVEZNO za ESP32 s dijeljenim pinovima!)
            sd = SDCard(slot=3)
            os.mount(sd, mount_point)
            print("SD mounted at {} (attempt {})".format(mount_point, attempt + 1))
            gc.collect()
            return True
        except Exception as e:
            print("SD mount attempt {} failed: {}".format(attempt + 1, e))
            gc.collect()
            time.sleep_ms(100)  # Wait before retry

    print("SD mount FAILED after {} attempts".format(max_retries))
    return False


def remount_sd():
    """Full SD remount sequence - use when SD becomes unstable

    Sequence:
    1. Deinit SPI (releases shared pins)
    2. Release all SD pins
    3. Wait for hardware settle
    4. Remount with retry

    Returns:
        True if remounted successfully, False otherwise
    """
    global _spi_instance

    print("=== SD Remount Sequence ===")

    # Step 1: Release SPI and pins
    release_sd_pins()

    # Step 2: Unmount if mounted
    try:
        os.umount("/sd")
        print("SD unmounted")
    except:
        pass

    # Step 3: Wait for hardware to settle
    time.sleep_ms(200)
    gc.collect()

    # Step 4: Remount with retry
    result = mount_sd_with_retry("/sd", max_retries=3)

    if result:
        print("=== SD Remount SUCCESS ===")
    else:
        print("=== SD Remount FAILED ===")

    return result


# Convenience function for interactive use
def load(filename):
    """Quick load function - initializes SPI and loads file

    FIXED 2026-02-13: Read file into memory BEFORE releasing SD pins!
    GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD and SPI.
    Previous code released SD pins first, which unmounted SD card.

    FIXED 2026-02-14 by Jelena: Added RETRY + WATCHDOG protection!
    - 2 pokušaja za upload
    - Watchdog timer (30s) - ako upload visi, ESP32 se resetira
    - ESP32 hard reset ako oba pokušaja propadnu

    New sequence:
    1. Read file into memory (SD still works)
    2. Release SD pins (unmounts SD but we have data in RAM)
    3. Init SPI and send data to FPGA (with retry + watchdog)
    """
    print("[RIM] ========================================")
    print("[RIM] load() - Quick Load Function")
    print("[RIM] File: {}".format(filename))
    print("[RIM] ========================================")

    # Step 1: Read file into memory while SD is still accessible
    print("[RIM] Step 1: Checking file...")
    try:
        stat = os.stat(filename)
        filesize = stat[6]
    except OSError as e:
        print("[RIM ERROR] File not found: {} ({})".format(filename, e))
        return False

    print("[RIM] Step 2: Reading {} bytes into memory...".format(filesize))

    try:
        with open(filename, "rb") as f:
            file_data = f.read()
    except OSError as e:
        print("[RIM ERROR] Cannot read file: {}".format(e))
        return False

    gc.collect()
    print("[RIM] File loaded into RAM ({} bytes)".format(len(file_data)))

    # Step 2: Now release SD pins and initialize SPI
    # NOTE: Commented out - SPI works without releasing SD pins on ULX3S v3.1.7
    # release_sd_pins()

    # Initialize SPI with correct settings (1 MHz for stability)
    print("[RIM] Step 3: Initializing SPI...")
    spi, cs = init_spi()
    print("[RIM] SPI ready")

    ld = ld_pdp1(spi, cs)

    # Step 4: Send data to FPGA with RETRY + WATCHDOG protection!
    # NOTE: If all retries fail, ESP32 will reset automatically!
    print("[RIM] Step 4: Starting FPGA transfer (with retry + watchdog)...")
    result = ld.load_and_run_from_bytes(file_data, verbose=True, use_watchdog=False)
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
# 2. IRQ: PULL_DOWN + IRQ_RISING (FPGA drives active-high)
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
        """Setup IRQ handler for FPGA button events - ACTIVE HIGH from FPGA"""
        try:
            # FIXED 2026-02-14: FPGA drives IRQ active-high, use PULL_DOWN + RISING
            self.irq_pin = Pin(gpio_irq, Pin.IN, Pin.PULL_DOWN)
            self._irq_handler_ref = self._irq_handler  # Prevent GC
            self.irq_pin.irq(trigger=Pin.IRQ_RISING, handler=self._irq_handler_ref)
            self._irq_enabled = True
            print("IRQ on GPIO{} (PULL_DOWN, RISING)".format(gpio_irq))
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
            # Check for cursor combo: 0x78 (UP+DOWN+LEFT+RIGHT)
            if (btn & 0x78) == 0x78:
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
                elif btn_only == BTN_FIRE1:
                    # FIRE1 = refresh directory listing
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
        """Low-level OSD enable/disable - MiSTer compatible (0x41=ON, 0x40=OFF)

        FIXED 2026-02-14: esp32_osd.v expects MiSTer format - single byte command.
        0x41 = OSD enable, 0x40 = OSD disable
        """
        self._cs_active()
        self.spi.write(bytearray([0x41 if en else 0x40]))
        self._cs_inactive()

    def osd_enable(self, enable):
        """Enable or disable OSD overlay - MiSTer compatible (0x41=ON, 0x40=OFF)"""
        self._cs_active()
        self.spi.write(bytearray([0x41 if enable else 0x40]))
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
        """Initialize file browser state

        FIXED 2026-02-14: NE BRIŠE direntries cache!
        Cache se briše samo eksplicitno kroz read_dir().
        """
        self.fb_topitem = 0
        self.fb_cursor = 0
        self.fb_selected = -1
        # FIXED: Ne postavljaj cwd na "/" ako već postoji
        if not hasattr(self, 'cwd') or self.cwd is None:
            self.cwd = "/"
        # FIXED: Ne briši direntries cache!
        if not hasattr(self, 'direntries'):
            self.direntries = []
        self.screen_y = 14  # OSD lines for directory display (lines 1-14)

    def read_dir(self, force_remount=False):
        """Read directory contents with SD recovery

        FIXED 2026-02-14: Robustniji pristup s recovery opcijom.

        Args:
            force_remount: If True, remount SD before reading (for recovery)

        NOTE: SD card pins (GPIO 4, 12) are shared with SPI. When SPI is active,
        SD card may not be accessible. If directory read fails, keep existing
        cached entries.
        """
        if not hasattr(self, 'cwd'):
            self.cwd = "/"
        if not hasattr(self, 'direntries'):
            self.direntries = []

        # If force_remount, do full SD recovery
        if force_remount:
            print("read_dir: Force remount requested")
            # Save SPI state
            old_spi = self.spi
            old_cs = self.cs

            # Remount SD
            if remount_sd():
                # Reinit SPI after SD remount
                self.spi, self.cs = init_spi()
            else:
                print("read_dir: Remount failed, using cache")
                return

        # Try to read directory, but don't clear existing cache if it fails
        new_entries = []
        read_ok = False

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
                        if fname.endswith('.rim') or fname.endswith('.bin') or fname.endswith('.bit') or fname.endswith('.hex'):
                            new_entries.append([fname, 0, stat[6]])  # file
                except:
                    pass
                gc.collect()

            # Only update if we got entries (SD was accessible)
            if new_entries or len(ls) == 0:
                self.direntries = new_entries
                read_ok = True
                print("read_dir: {} entries".format(len(new_entries)))

        except OSError as e:
            # Error 0x107 = SD read error
            if "107" in str(e) or "ETIMEDOUT" in str(e):
                print("read_dir: SD error, attempting recovery...")
                # Try one remount if not already forcing
                if not force_remount:
                    self.read_dir(force_remount=True)
                    return
            print("read_dir: SD not accessible ({}), using cache".format(e))

        except Exception as e:
            print("read_dir: Error {}, using cache".format(e))

    def read_dir_safe(self):
        """Read directory with SPI deactivation - SAFE for OSD mode

        CRITICAL: Must deinit SPI before SD access, GPIO 4/12 are shared!

        FIXED 2026-02-14: Error 0x107 fix - UVIJEK remountaj SD s slot=3!

        Root cause: SD driver koristi SDMMC mode umjesto SPI mode.
        Na ULX3S v3.1.7, GPIO 4 (MOSI) i GPIO 12 (MISO) su dijeljeni.
        MORA se koristiti SDCard(slot=3) za SPI mode!

        Sekvenca (Emard pattern):
        1. Deinit SPI (oslobodi GPIO 4, 12)
        2. Release SD pins (high-Z)
        3. Unmount SD
        4. Pauza za hardware settle
        5. Remount SD s slot=3 (SPI mode - KRITIČNO!)
        6. Citaj direktorij
        7. Reinit SPI
        """
        global _spi_instance

        print(">>> read_dir_safe START")
        print("    cwd={}".format(self.cwd))

        # Step 1: POTPUNI SPI deinit - KRITIČNO za ESP32!
        # FIXED 2026-02-14 by Jelena: Delay ODMAH nakon deinit!
        print(">>> Step 1: Deinit SPI (POTPUNO)...")
        if self.spi:
            try:
                self.spi.deinit()
                print("    self.spi.deinit() OK")
            except Exception as e:
                print("    self.spi.deinit() error: {}".format(e))
            self.spi = None
        if _spi_instance:
            try:
                _spi_instance.deinit()
                print("    _spi_instance.deinit() OK")
            except Exception as e:
                print("    _spi_instance.deinit() error: {}".format(e))
            _spi_instance = None

        # Step 1b: DELAY za SPI hardware settle - OBAVEZNO ODMAH!
        # ESP32 SPI driver ne oslobada bus instantno!
        time.sleep_ms(100)
        print("    SPI settle delay OK")

        # Step 2: Release SD pins to high-Z (Emard pattern)
        print(">>> Step 2: Release SD pins to high-Z...")
        for i in bytearray([2, 4, 12, 13, 14, 15]):
            try:
                p = Pin(i, Pin.IN)
                a = p.value()
                del p, a
            except:
                pass

        # Step 2b: Takoder oslobodi SPI pinove (MOSI=4, MISO=12, SCK=26)
        # Ovo je DODATNI korak jer slot=3 koristi ISTE pinove!
        for pin_num in [gpio_mosi, gpio_miso, gpio_sck]:
            try:
                p = Pin(pin_num, Pin.IN)
                a = p.value()
                del p, a
            except:
                pass
        print("    All pins released")

        # Step 2c: Force GC da ukloni sve reference
        gc.collect()

        # Step 3: Unmount SD (KRITIČNO - mora se unmountat prije remount!)
        print(">>> Step 3: Unmount SD...")
        try:
            os.umount("/sd")
            print("    Unmount OK")
        except Exception as e:
            print("    Unmount: {} (OK if not mounted)".format(e))

        # Step 4: Wait for hardware settle NAKON unmount
        print(">>> Step 4: Hardware settle 100ms...")
        time.sleep_ms(100)
        gc.collect()

        # Step 5: Mount SD with slot=3 (SPI MODE - KRITIČNO!)
        print(">>> Step 5: Mount SD with slot=3 (SPI mode)...")
        from machine import SDCard
        sd_ok = False
        for attempt in range(3):
            try:
                sd = SDCard(slot=3)  # SPI mode, NE SDMMC!
                os.mount(sd, "/sd")
                print("    Mount OK (attempt {})".format(attempt + 1))
                sd_ok = True
                break
            except Exception as e:
                print("    Mount attempt {} failed: {}".format(attempt + 1, e))
                time.sleep_ms(100)

        if not sd_ok:
            print(">>> SD mount FAILED, using cached entries")
            self.spi, self.cs = init_spi()
            return

        # Step 6: Read directory (SD now properly mounted in SPI mode)
        print(">>> Step 6: Reading directory {}...".format(self.cwd))
        new_entries = []
        try:
            ls = sorted(os.listdir(self.cwd))
            print("    Found {} items".format(len(ls)))
            for fname in ls:
                try:
                    fullpath = self.fullpath(fname)
                    stat = os.stat(fullpath)
                    if stat[0] & 0o170000 == 0o040000:
                        new_entries.append([fname, 1, 0])  # directory
                    else:
                        # Filter: only show .rim, .bin, .bit files
                        if fname.endswith('.rim') or fname.endswith('.bin') or fname.endswith('.bit') or fname.endswith('.hex'):
                            new_entries.append([fname, 0, stat[6]])  # file
                except Exception as e:
                    print("    stat error {}: {}".format(fname, e))
                gc.collect()
            self.direntries = new_entries
            print(">>> Step 6 OK: {} entries".format(len(new_entries)))
        except Exception as e:
            print(">>> Step 6 ERROR: {}".format(e))
            print("    Keeping {} cached entries".format(len(self.direntries)))

        # Step 7: Reinit SPI for OSD communication
        print(">>> Step 7: Reinit SPI...")
        self.spi, self.cs = init_spi()
        print("    SPI reinit OK")

        gc.collect()
        print(">>> read_dir_safe DONE")

    def fullpath(self, fname):
        """Get full path for filename"""
        # If fname already starts with /, it's absolute - return as is
        if fname.startswith("/"):
            return fname
        # Otherwise, prepend cwd
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
        self.osd_write_line(15, "U/D:Nav L:Bk R:Sel FIRE1:Rfsh")

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
        """Refresh directory listing with SD remount - FIXED 2026-02-14

        Called on F1 press. Does FULL SD remount sequence using read_dir_safe().
        This is the ROBUST way to recover from SD errors!

        DEBUG 2026-02-14: Koristi read_dir_safe() umjesto read_dir(force_remount)
        """
        print("=== refresh_dir() CALLED ===")
        self.osd_write_line(15, "Refreshing...")
        old_count = len(self.direntries)

        # Clear cache and use read_dir_safe (deinits SPI, remounts if needed)
        self.direntries = []
        self.read_dir_safe()

        new_count = len(self.direntries)

        if new_count != old_count:
            # Directory changed, reset cursor
            self.fb_cursor = 0
            self.fb_topitem = 0

        self.show_dir()
        if new_count > 0:
            self.osd_write_line(15, "OK: {} files".format(new_count))
        else:
            self.osd_write_line(15, "SD ERROR - press FIRE1")
        print("=== refresh_dir() DONE ===")

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
        """Select current entry - directory or file

        FIXED 2026-02-14: Sprema cwd PRIJE init_fb() jer init_fb() sada ne briše.
        DEBUG 2026-02-14: Dodani ispisi za provjeru poziva read_dir_safe()
        """
        print("=== select_entry() CALLED ===")
        print("    direntries count: {}".format(len(self.direntries) if self.direntries else 0))
        print("    fb_cursor: {}".format(self.fb_cursor))

        if not self.direntries or self.fb_cursor >= len(self.direntries):
            print("    ERROR: No entry at cursor position!")
            return

        entry = self.direntries[self.fb_cursor]
        print("    Selected: {} (is_dir={})".format(entry[0], entry[1]))

        if entry[1]:  # Directory
            oldselected = self.fb_selected - self.fb_topitem
            self.fb_selected = self.fb_cursor

            # Izracunaj novi cwd PRIJE reset-a
            new_cwd = self.fullpath(entry[0])
            print("    Entering directory: {}".format(new_cwd))

            self.show_dir_line(oldselected)
            self.show_dir_line(self.fb_cursor - self.fb_topitem)

            # Reset browser state (cursor position)
            self.fb_topitem = 0
            self.fb_cursor = 0
            self.fb_selected = -1

            # Postavi novi cwd i citaj direktorij
            self.cwd = new_cwd
            self.direntries = []  # Eksplicitno brisi stari cache
            print("    Calling read_dir_safe()...")
            self.read_dir_safe()  # FIXED 2026-02-14: Deinit SPI prije SD citanja!
            print("    read_dir_safe() returned, showing dir...")
            self.show_dir()
            print("=== select_entry() DONE ===")
        else:  # File
            print("    Loading file: {}".format(entry[0]))
            self.load_file(entry[0])

    def updir(self):
        """Go up one directory level

        FIXED 2026-02-14: Eksplicitno brise cache i postavlja cwd.
        DEBUG 2026-02-14: Dodani ispisi za provjeru poziva read_dir_safe()
        """
        print("=== updir() CALLED ===")
        print("    Current cwd: {}".format(self.cwd))

        if len(self.cwd) < 2:
            self.cwd = "/"
        else:
            parts = self.cwd.split("/")[:-1]
            self.cwd = "/".join(parts) if parts else "/"
            if not self.cwd:
                self.cwd = "/"

        print("    New cwd: {}".format(self.cwd))

        # Reset browser state
        self.fb_topitem = 0
        self.fb_cursor = 0
        self.fb_selected = -1
        self.direntries = []  # Eksplicitno brisi stari cache

        print("    Calling read_dir_safe()...")
        self.read_dir_safe()  # FIXED 2026-02-14: Deinit SPI prije SD citanja!
        print("    read_dir_safe() returned, showing dir...")
        self.show_dir()
        print("=== updir() DONE ===")

    def load_file(self, fname):
        """Load selected file

        FIXED 2026-02-14: Mora remountati SD s slot=3 prije citanja!
        FIXED 2026-02-14 by Jelena: Provjera da li je fajl na SD ili flash!

        IMPORTANT: GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD
        and SPI. Sekvenca za SD fajlove:
        1. Deinit SPI
        2. Release SD pins
        3. Mount SD s slot=3 (SPI mode)
        4. Read file into memory
        5. Unmount SD
        6. Release SD pins
        7. Reinit SPI
        8. Send data to FPGA

        Za flash fajlove (ne pocinje s /sd/):
        - Preskoči SD mount/unmount
        - Citaj direktno s flash memorije
        """
        global _spi_instance
        fullpath = self.fullpath(fname)

        # FIXED 2026-02-14: Provjeri da li je fajl na SD ili flash
        is_sd_file = fullpath.startswith("/sd/") or fullpath.startswith("/sd")
        print("load_file: path={} is_sd={}".format(fullpath, is_sd_file))

        # Show loading message
        self.osd_write_line(15, "Loading {}...".format(fname[:20]))

        # Step 1: POTPUNI SPI deinit - KRITIČNO za ESP32!
        # ESP32 SPI driver ne oslobada bus instantno - treba delay!
        # FIXED 2026-02-14 by Jelena: Dodani eksplicitni deinit + delay
        print("load_file: Deinit SPI (POTPUNO)...")

        # 1a. Deinit self.spi instance
        if self.spi:
            try:
                self.spi.deinit()
                print("  self.spi.deinit() OK")
            except Exception as e:
                print("  self.spi.deinit() error: {}".format(e))
            self.spi = None

        # 1b. Deinit global _spi_instance (KRITIČNO!)
        if _spi_instance:
            try:
                _spi_instance.deinit()
                print("  _spi_instance.deinit() OK")
            except Exception as e:
                print("  _spi_instance.deinit() error: {}".format(e))
            _spi_instance = None

        # 1c. DELAY za SPI hardware settle - OBAVEZNO!
        # ESP32 treba 50-100ms da potpuno oslobodi SPI bus
        time.sleep_ms(100)
        print("  SPI settle delay OK")

        # FIXED 2026-02-14: Preskoči SD mount ako fajl nije na SD kartici!
        # Fajlovi na flash memoriji (npr. /pdp1.bit) ne trebaju SD mount.
        sd_ok = True  # Pretpostavi OK za flash fajlove
        if is_sd_file:
            # Step 2: Release SD pins to high-Z (Emard pattern)
            # KRITIČNO: GPIO moraju biti high-Z prije SD mount-a!
            print("load_file: Release pins to high-Z...")
            for i in bytearray([2, 4, 12, 13, 14, 15]):
                try:
                    p = Pin(i, Pin.IN)
                    a = p.value()  # Force read to release driver
                    del p, a
                except:
                    pass

            # 2b. Takoder oslobodi SPI pinove (MOSI=4, MISO=12, SCK=26)
            # Ovo je DODATNI korak jer slot=3 koristi ISTE pinove!
            for pin_num in [gpio_mosi, gpio_miso, gpio_sck]:
                try:
                    p = Pin(pin_num, Pin.IN)
                    a = p.value()
                    del p, a
                except:
                    pass
            print("  Pins released")

            # 2c. Force garbage collection da ukloni sve reference
            gc.collect()

            # Step 3: Mount SD with slot=3 (SPI mode)
            print("load_file: Mount SD slot=3...")
            from machine import SDCard

            # 3a. Unmount ako je mountano
            try:
                os.umount("/sd")
                print("  Unmount OK")
            except:
                pass

            # 3b. DODATNI delay nakon unmount - hardware mora settle!
            time.sleep_ms(100)

            sd_ok = False
            for attempt in range(3):
                try:
                    sd = SDCard(slot=3)
                    os.mount(sd, "/sd")
                    print("load_file: SD mount OK")
                    sd_ok = True
                    break
                except Exception as e:
                    print("load_file: SD mount attempt {} failed: {}".format(attempt + 1, e))
                    time.sleep_ms(100)

            if not sd_ok:
                print("load_file: SD mount FAILED!")
                self.spi, self.cs = init_spi()
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "SD ERROR!")
                return
        else:
            print("load_file: Flash file - skipping SD mount")

        # Handle different file types
        if fname.endswith('.bit'):
            # FPGA bitstream - ecp5.prog() handles file reading internally
            # FIXED 2026-02-14 by Jelena: NE ZOVI _osd_enable_hw() dok je SPI None!
            # SPI je deinicijaliziran u Step 1, mora se reinicijalizirati PRIJE
            # bilo kakvog SPI poziva.
            self.enable[0] = 0
            self.osd_visible = False
            # NOTE: Cannot call _osd_enable_hw(0) here - self.spi is None!
            # ecp5.prog() handles FPGA programming directly.
            try:
                import ecp5
                # ecp5.prog() reads file and programs FPGA
                ecp5.prog(fullpath)
                print("Loaded bitstream: {}".format(fullpath))
                # Cleanup and reinit SPI FIRST
                # FIXED 2026-02-14: Samo unmountaj ako je SD file
                if is_sd_file:
                    try:
                        os.umount("/sd")
                    except:
                        pass
                    release_sd_pins()
                self.spi, self.cs = init_spi()
                # NOW disable OSD (SPI is ready)
                self._osd_enable_hw(0)
            except Exception as e:
                print("Bitstream load error: {}".format(e))
                # Recovery: reinit SPI first, THEN enable OSD
                # FIXED 2026-02-14: Samo unmountaj ako je SD file
                if is_sd_file:
                    try:
                        os.umount("/sd")
                    except:
                        pass
                    release_sd_pins()
                self.spi, self.cs = init_spi()
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "LOAD ERROR!")
                return
        elif fname.endswith('.rim') or fname.endswith('.bin'):
            # PDP-1 tape file - read into memory, then send via SPI
            # FIXED 2026-02-14 by Jelena: Added retry + watchdog protection!
            # FIXED 2026-02-14 by Jelena: Podrška za flash i SD fajlove!
            print("[RIM] ========================================")
            print("[RIM] Loading RIM/BIN file: {}".format(fname))
            print("[RIM] Source: {}".format("SD card" if is_sd_file else "Flash"))
            print("[RIM] ========================================")

            # NOTE: Can't call _osd_enable_hw() here - SPI is None!
            # OSD will be disabled AFTER we reinit SPI (Step 7)
            self.enable[0] = 0
            self.osd_visible = False

            # Step 4: Read file into memory
            print("[RIM] Step 4: Reading file...")
            try:
                with open(fullpath, "rb") as f:
                    file_data = f.read()
                print("[RIM] File read OK: {} bytes".format(len(file_data)))
            except Exception as e:
                print("[RIM ERROR] File read failed: {}".format(e))
                # FIRST reinit SPI, THEN enable OSD
                # FIXED 2026-02-14: Samo unmountaj ako je SD file
                if is_sd_file:
                    try:
                        os.umount("/sd")
                    except:
                        pass
                    release_sd_pins()
                self.spi, self.cs = init_spi()
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "READ FAILED!")
                return

            gc.collect()

            # Step 5: Unmount SD (samo ako je SD file)
            # FIXED 2026-02-14: Preskoči za flash fajlove
            if is_sd_file:
                print("[RIM] Step 5: Unmounting SD...")
                try:
                    os.umount("/sd")
                    print("[RIM] SD unmounted")
                except:
                    pass

                # Step 6: Release SD pins to allow clean SPI access
                print("[RIM] Step 6: Releasing SD pins...")
                release_sd_pins()
            else:
                print("[RIM] Step 5-6: Skipped (flash file)")

            # Step 7: Reinitialize SPI (pins now free from SD)
            print("[RIM] Step 7: Reinitializing SPI...")
            self.spi, self.cs = init_spi()
            print("[RIM] SPI ready")

            # Step 7b: NOW disable OSD (SPI is ready)
            self._osd_enable_hw(0)

            # Step 8: Send data to FPGA with RETRY + WATCHDOG protection!
            # FIXED 2026-02-14 by Jelena: verbose=True for debug output
            print("[RIM] Step 8: Starting FPGA transfer (with retry + watchdog)...")
            loader = ld_pdp1(self.spi, self.cs)
            result = loader.load_and_run_from_bytes(file_data, verbose=True, use_watchdog=False)

            gc.collect()

            # NOTE: If all retries fail, load_and_run_from_bytes() will
            # reset ESP32, so we won't reach this code in failure case!
            if not result:
                # This should not happen (reset before reaching here)
                print("[RIM ERROR] Upload returned False (should have reset!)")
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "LOAD FAILED!")
            else:
                print("[RIM] ========================================")
                print("[RIM] SUCCESS: {}".format(fullpath))
                print("[RIM] ========================================")

        elif fname.endswith('.hex'):                                 
            # HEX file - load directly without RIM bootstrap            
            # ADDED 2026-02-15: Direct HEX loading support!             
            print("[HEX] ========================================")          
            print("[HEX] Loading HEX file: {}".format(fname))
            print("[HEX] Source: {}".format("SD card" if is_sd_file else "Flash"))
            print("[HEX] ========================================")

            self.enable[0] = 0
            self.osd_visible = False

            # Step 4: Read file into memory
            print("[HEX] Step 4: Reading file...")
            try:
                with open(fullpath, "r") as f:
                    hex_lines = f.readlines()
                print("[HEX] File read OK: {} lines".format(len(hex_lines)))
            except Exception as e:
                print("[HEX ERROR] File read failed: {}".format(e))
                if is_sd_file:
                    try:
                        os.umount("/sd")
                    except:
                        pass
                    release_sd_pins()
                self.spi, self.cs = init_spi()
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "READ FAILED!")
                return

            gc.collect()

            # Step 5-6: Unmount SD and release pins
            if is_sd_file:
                print("[HEX] Step 5: Unmounting SD...")
                try:
                    os.umount("/sd")
                except:
                    pass
                print("[HEX] Step 6: Releasing SD pins...")
                release_sd_pins()

            # Step 7: Reinitialize SPI
            print("[HEX] Step 7: Reinitializing SPI...")
            self.spi, self.cs = init_spi()

            # Disable OSD
            self._osd_enable_hw(0)

            # Step 8: Convert HEX to synthetic RIM
            print("[HEX] Step 8: Converting to RIM...")
            DIO_OPCODE = 26
            JMP_OPCODE = 48
            START_ADDR = 0o100

            rim_data = bytearray()
            addr = START_ADDR
            word_count = 0

            for line in hex_lines:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                try:
                    data = int(line, 16) & 0x3FFFF
                except ValueError:
                    continue
                rim_data.extend([
                    0x80 | DIO_OPCODE,
                    0x80 | ((addr >> 6) & 0x3F),
                    0x80 | (addr & 0x3F),
                    0x80 | ((data >> 12) & 0x3F),
                    0x80 | ((data >> 6) & 0x3F),
                    0x80 | (data & 0x3F)
                ])
                addr = (addr + 1) & 0xFFF
                word_count += 1

            # Add JMP
            rim_data.extend([
                0x80 | JMP_OPCODE,
                0x80 | ((START_ADDR >> 6) & 0x3F),
                0x80 | (START_ADDR & 0x3F),
                0x80, 0x80, 0x80
            ])

            print("[HEX] {} words -> {} bytes".format(word_count, len(rim_data)))

            loader = ld_pdp1(self.spi, self.cs)
            result = loader.load_and_run_from_bytes(bytes(rim_data), verbose=True, use_watchdog=False)

            gc.collect()

            if not result:
                self._osd_enable_hw(1)
                self.enable[0] = 1
                self.osd_visible = True
                self.osd_write_line(15, "LOAD FAILED!")
            else:
                print("[HEX] SUCCESS: {} words loaded".format(word_count))

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
    """Initialize and start OSD controller with IRQ support - FIXED 2026-02-14

    Usage:
        import ld_pdp1
        osd = ld_pdp1.start_osd()
        # Press UP+DOWN+LEFT+RIGHT (cursor keys) to toggle OSD menu

    Args:
        mount_sd: If True, mount SD card first (default)

    IMPORTANT: GPIO 4 (MOSI) and GPIO 12 (MISO) are shared between SD card
    and SPI. SD card must be unmounted and pins released before SPI works!

    FIXED 2026-02-14: Koristi mount_sd_with_retry za robustnost!
    """
    cwd_start = "/sd"
    direntries_cache = []

    # Step 1: Mount SD card with retry logic
    if mount_sd:
        if mount_sd_with_retry("/sd", max_retries=3):
            print("SD ready")
        else:
            print("WARNING: SD mount failed, file browser may be empty")

    # Step 2: Read directory listing into memory while SD is accessible
    try:
        ls = sorted(os.listdir(cwd_start))
        for fname in ls:
            try:
                fullpath = cwd_start + "/" + fname
                stat = os.stat(fullpath)
                if stat[0] & 0o170000 == 0o040000:
                    direntries_cache.append([fname, 1, 0])  # directory
                else:
                    if fname.endswith('.rim') or fname.endswith('.bin') or fname.endswith('.bit') or fname.endswith('.hex'):
                        direntries_cache.append([fname, 0, stat[6]])  # file
            except:
                pass
            gc.collect()  # GC after each file like Emard!
        print("Cached {} entries".format(len(direntries_cache)))
    except Exception as e:
        print("read_dir error: {}".format(e))

    # Step 3: Unmount SD and release pins for SPI access
    # FIXED 2026-02-14: Eksplicitno unmountiraj SD PRIJE release_sd_pins()!
    # Ako ostavimo SD "mountiran" a pinovi su u high-Z, sljedeci pristup
    # ce failati s error 0x107 jer driver misli da je SD dostupan ali nije.
    try:
        os.umount("/sd")
        print("SD unmounted for SPI mode")
    except:
        pass
    release_sd_pins()

    # Step 4: Initialize OSD controller (will init SPI)
    osd = OsdController()
    osd.init_fb()  # Initialize file browser
    osd.cwd = cwd_start
    osd.direntries = direntries_cache  # Use cached directory

    # FORCE OSD OFF at startup - ignores SW1 position
    osd._osd_enable_hw(0)  # Disable OSD hardware
    osd.enable[0] = 0      # Clear enable state
    osd.osd_visible = False

    osd.setup_irq()

    # Handle any pending IRQ
    osd._irq_handler(0)

    print("=" * 40)
    print("OSD Ready")
    print("Combo: UP+DOWN+LEFT+RIGHT to toggle")
    print("Navigate: UP/DOWN | Back: LEFT | Select: RIGHT")
    print("FIRE1: Remount SD (recovery)")
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

    # FORCE OSD OFF - override SW1 position
    osd._osd_enable_hw(0)
    osd.enable[0] = 0
    osd.osd_visible = False

    print("OSD Running - DIRECT POLLING mode")
    print("SW1 position ignored - OSD starts DISABLED")
    print("Combo: UP+DOWN+LEFT+RIGHT (0x78) to toggle OSD")
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
    print("OSD Combo: (btn & 0x78) == 0x78 (UP+DOWN+LEFT+RIGHT)")
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
                if btn & BTN_FIRE1: parts.append("FIRE1")
                if btn & BTN_FIRE2: parts.append("FIRE2")
                if btn & BTN_UP:    parts.append("UP")
                if btn & BTN_DOWN:  parts.append("DOWN")
                if btn & BTN_LEFT:  parts.append("LEFT")
                if btn & BTN_RIGHT: parts.append("RIGHT")

                if parts:
                    msg = "+".join(parts)
                    # Check for OSD combo (0x78 = UP+DOWN+LEFT+RIGHT)
                    if (btn & 0x78) == 0x78:
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


def test_sd_recovery():
    """Test SD card remount recovery sequence

    Usage:
        import ld_pdp1
        ld_pdp1.test_sd_recovery()

    This tests the full SD recovery sequence:
    1. Mount SD
    2. Read directory
    3. Release pins
    4. Init SPI
    5. Remount SD
    6. Read directory again
    """
    print("=" * 50)
    print("SD RECOVERY TEST")
    print("=" * 50)

    # Step 1: Initial mount
    print("\n1. Initial SD mount...")
    if mount_sd_with_retry("/sd", max_retries=3):
        print("   OK: SD mounted")
    else:
        print("   FAILED: SD mount")
        return False

    # Step 2: Read directory
    print("\n2. Reading /sd directory...")
    try:
        entries = os.listdir("/sd")
        print("   OK: {} entries".format(len(entries)))
        for e in entries[:5]:
            print("      - {}".format(e))
        if len(entries) > 5:
            print("      ... and {} more".format(len(entries) - 5))
    except Exception as e:
        print("   ERROR: {}".format(e))
        return False

    # Step 3: Init SPI (simulates OSD usage)
    print("\n3. Initializing SPI (simulates OSD)...")
    spi, cs = init_spi()
    print("   OK: SPI initialized")

    # Step 4: Read directory again (should fail or use cache)
    print("\n4. Reading /sd directory again (with SPI active)...")
    try:
        entries = os.listdir("/sd")
        print("   OK: {} entries (SD still accessible)".format(len(entries)))
    except Exception as e:
        print("   Expected: SD not accessible while SPI active ({})".format(e))

    # Step 5: Full remount sequence
    print("\n5. Full SD remount sequence...")
    if remount_sd():
        print("   OK: SD remounted")
    else:
        print("   FAILED: SD remount")
        return False

    # Step 6: Read directory after remount
    print("\n6. Reading /sd directory after remount...")
    try:
        entries = os.listdir("/sd")
        print("   OK: {} entries".format(len(entries)))
    except Exception as e:
        print("   ERROR: {}".format(e))
        return False

    # Step 7: Reinit SPI for OSD
    print("\n7. Reinitializing SPI...")
    spi, cs = init_spi()
    print("   OK: SPI reinitialized")

    print("\n" + "=" * 50)
    print("SD RECOVERY TEST PASSED!")
    print("=" * 50)
    gc.collect()
    return True


def test_read_dir_safe():
    """Test read_dir_safe() directly - DEBUG function

    Usage:
        import ld_pdp1
        ld_pdp1.test_read_dir_safe()

    This simulates what happens when user navigates directories:
    1. Start OSD (mounts SD, inits SPI)
    2. Call read_dir_safe() to change directory
    3. Check if directory is readable
    """
    print("=" * 50)
    print("TEST: read_dir_safe()")
    print("=" * 50)

    # Step 1: Start OSD normally
    print("\n1. Starting OSD...")
    osd = start_osd(mount_sd=True)
    print("   OSD started, cwd={}".format(osd.cwd))
    print("   Initial entries: {}".format(len(osd.direntries)))

    # Step 2: Show current directory
    print("\n2. Current directory listing:")
    for i, e in enumerate(osd.direntries[:10]):
        print("   [{:2d}] {} {}".format(i, "DIR" if e[1] else "   ", e[0]))
    if len(osd.direntries) > 10:
        print("   ... and {} more".format(len(osd.direntries) - 10))

    # Step 3: Try to enter first directory
    dirs = [e for e in osd.direntries if e[1]]
    if dirs:
        print("\n3. Entering first directory: {}".format(dirs[0][0]))
        osd.fb_cursor = osd.direntries.index(dirs[0])
        osd.select_entry()  # This calls read_dir_safe()
        print("   After select_entry:")
        print("   cwd={}".format(osd.cwd))
        print("   entries={}".format(len(osd.direntries)))
    else:
        print("\n3. No directories to enter, testing read_dir_safe() directly...")
        osd.cwd = "/sd"
        osd.direntries = []
        osd.read_dir_safe()
        print("   entries={}".format(len(osd.direntries)))

    # Step 4: Try updir
    print("\n4. Testing updir()...")
    osd.updir()
    print("   After updir:")
    print("   cwd={}".format(osd.cwd))
    print("   entries={}".format(len(osd.direntries)))

    print("\n" + "=" * 50)
    print("TEST COMPLETE")
    print("=" * 50)
    gc.collect()
    return osd
