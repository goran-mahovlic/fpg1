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
spi_freq = const(3000000)  # 3 MHz - stable, tested by emard

# SPI Commands (MiSTer compatible via esp32_osd.v)
CMD_FILE_TX_EN   = const(0x53)
CMD_FILE_TX_DATA = const(0x54)
CMD_FILE_INDEX   = const(0x55)
CMD_STATUS       = const(0x1E)
CMD_OSD_ENABLE   = const(0x41)
CMD_OSD_DISABLE  = const(0x40)

# File type index for RIM files
FILE_INDEX_RIM = const(1)


def init_spi():
    """Initialize SPI and CS pin with correct settings"""
    global spi, cs
    spi = SPI(spi_channel, baudrate=spi_freq, polarity=0, phase=0,
              bits=8, firstbit=SPI.MSB,
              sck=Pin(gpio_sck), mosi=Pin(gpio_mosi), miso=Pin(gpio_miso))
    cs = Pin(gpio_cs, Pin.OUT)
    cs.off()  # CS inactive (high) - using off() like emard's code
    return spi, cs


class ld_pdp1:
    def __init__(self, spi=None, cs=None):
        if spi is None or cs is None:
            self.spi, self.cs = init_spi()
        else:
            self.spi = spi
            self.cs = cs
        # Ensure CS starts inactive (high)
        self.cs.off()

    def _cs_active(self):
        """CS active (active low) - matches emard's cs.on()"""
        self.cs.on()

    def _cs_inactive(self):
        """CS inactive (high) - matches emard's cs.off()"""
        self.cs.off()

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
    """Quick load function - initializes SPI and loads file"""
    # Release SD card pins first
    release_sd_pins()

    # Initialize SPI with correct settings
    spi, cs = init_spi()

    ld = ld_pdp1(spi, cs)
    result = ld.load_and_run(filename)
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
        cs.off()
        print("SPI({}) @ {}Hz init OK".format(spi_channel, spi_freq))
        return True
    except Exception as e:
        print("SPI init FAILED: {}".format(e))
        return False
