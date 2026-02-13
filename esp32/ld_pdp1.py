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
# FIXED 2026-02-13: Continuous CS transfer by Jelena Kovacevic
# - Problem: CS was deactivated after each chunk, causing FSM reset
# - Solution: Single CS cycle for entire file transfer
# - CMD_FILE_TX_DATA (0x54) sent ONCE at start, then raw data bytes
#
# ADDED 2026-02-13: IRQ support by Jelena Kovacevic
# - FPGA raises IRQ on GPIO25 when button state changes
# - ESP32 IRQ handler reads button status via CMD_READ_BTN (0xFB)
# - OSD menu can react to button presses
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
CMD_READ_BTN     = const(0xFB)  # Read button status (clears IRQ)
CMD_READ_IRQ     = const(0xF1)  # Read IRQ flags
CMD_OSD_WRITE    = const(0x20)  # Write OSD line (0x20-0x2F for lines 0-15)

# IRQ pin from FPGA (wifi_gpio25 = E9 on ULX3S v3.1.7)
# Check LPF: esp32_osd_irq is on site E9 which maps to ESP32 GPIO25
gpio_irq = const(25)

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
        """Send file data bytes (legacy - CS per chunk)

        NOTE: For better performance, use start_file_transfer() /
        send_file_chunk() / end_file_transfer() for continuous transfer.
        """
        self._cs_active()
        self.spi.write(bytearray([CMD_FILE_TX_DATA]))
        self.spi.write(data)
        self._cs_inactive()

    # =========================================================================
    # Continuous File Transfer API (FIXED 2026-02-13)
    # =========================================================================
    # These methods keep CS active during entire file transfer.
    # This prevents FSM reset between chunks in esp32_osd.v
    # =========================================================================

    def start_file_transfer(self):
        """Start continuous file transfer - CS stays active

        Must call end_file_transfer() when done!
        """
        self._cs_active()
        self.spi.write(bytearray([CMD_FILE_TX_DATA]))  # Command ONCE
        self._transfer_active = True

    def send_file_chunk(self, data):
        """Send raw data chunk during active transfer

        Args:
            data: bytes/bytearray to send (NO command prefix!)

        Raises:
            RuntimeError: if start_file_transfer() not called
        """
        if not getattr(self, '_transfer_active', False):
            raise RuntimeError("Call start_file_transfer() first")
        self.spi.write(data)

    def end_file_transfer(self):
        """End continuous file transfer - deactivates CS"""
        self._cs_inactive()
        self._transfer_active = False

    def load(self, filename, verbose=True):
        """Load RIM paper tape file to PDP-1

        FIXED 2026-02-13: Uses continuous CS transfer.
        Previous version deactivated CS after each chunk, which caused
        the FSM in esp32_osd.v to reset to IDLE state, losing file_download.

        Now uses single CS cycle for entire file:
        1. CS active
        2. Send CMD_FILE_TX_DATA (0x54) ONCE
        3. Stream all data bytes (no command prefix per chunk)
        4. CS inactive
        """

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

        # Enable file transfer mode in FPGA
        self.file_tx_enable(True)

        # Stream file with CONTINUOUS CS (FIXED!)
        CHUNK_SIZE = 256
        total_sent = 0

        # Start continuous transfer - CS active, command sent ONCE
        self.start_file_transfer()

        try:
            while True:
                chunk = f.read(CHUNK_SIZE)
                if not chunk:
                    break
                # Send raw data - NO command prefix per chunk!
                self.send_file_chunk(chunk)
                total_sent += len(chunk)
                if verbose and total_sent % 1024 == 0:
                    print("  {}/{} bytes".format(total_sent, filesize))

        except Exception as e:
            print("Error during transfer: {}".format(e))
            self.end_file_transfer()  # Deactivate CS on error
            f.close()
            self.file_tx_enable(False)
            gc.collect()
            return False

        # End transfer (deactivate CS) - MUST be after all data sent
        self.end_file_transfer()

        f.close()

        # Disable file transfer mode
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


# =============================================================================
# OSD Controller with IRQ Support (ADDED 2026-02-13)
# =============================================================================
# Provides interactive OSD menu with button handling via IRQ.
# Based on emard's osd.py IRQ handler pattern.
# =============================================================================

class OsdController:
    """OSD Controller with IRQ-driven button handling"""

    def __init__(self, spi=None, cs=None):
        """Initialize OSD controller with optional existing SPI/CS"""
        if spi is None or cs is None:
            self.spi, self.cs = init_spi()
        else:
            self.spi = spi
            self.cs = cs

        self.osd_visible = False
        self.menu_cursor = 0
        self.menu_items = []
        self._irq_enabled = False

        # Ensure CS starts inactive
        self.cs.off()

    def _cs_active(self):
        """Activate CS (active low)"""
        self.cs.on()

    def _cs_inactive(self):
        """Deactivate CS"""
        self.cs.off()

    # =========================================================================
    # IRQ Handling
    # =========================================================================

    def setup_irq(self):
        """Setup IRQ handler for FPGA button events

        Call this to enable automatic button handling via interrupts.
        """
        try:
            self.irq_pin = Pin(gpio_irq, Pin.IN, Pin.PULL_DOWN)
            self.irq_pin.irq(trigger=Pin.IRQ_RISING, handler=self._irq_handler)
            self._irq_enabled = True
            print("IRQ handler installed on GPIO{}".format(gpio_irq))
        except Exception as e:
            print("IRQ setup failed: {}".format(e))
            self._irq_enabled = False

    def disable_irq(self):
        """Disable IRQ handler"""
        if self._irq_enabled:
            try:
                self.irq_pin.irq(handler=None)
                self._irq_enabled = False
                print("IRQ handler disabled")
            except:
                pass

    def _irq_handler(self, pin):
        """Handle IRQ from FPGA - button state changed

        This is called in ISR context - keep it fast!
        """
        # Read IRQ flags first
        irq_flags = self.read_irq_flags()

        if irq_flags & 0x80:  # Button IRQ pending
            # Read button status (this also clears IRQ in FPGA)
            btn_status = self.read_buttons()
            self._handle_button(btn_status)

    def _handle_button(self, btn_status):
        """Process button press

        btn_status bits (active-high):
          bit 0 = BTN[0] (PWR) - Toggle OSD
          bit 1 = BTN[1] (UP)  - Menu up
          bit 2 = BTN[2] (DOWN) - Menu down
          bit 3 = BTN[3] (LEFT) - Back
          bit 4 = BTN[4] (RIGHT) - Enter directory
          bit 5 = BTN[5] (F1) - Select
          bit 6 = BTN[6] (F2) - Cancel
        """
        if btn_status & 0x01:  # PWR button - toggle OSD
            self.toggle_osd()
        elif self.osd_visible:
            if btn_status & 0x02:  # UP
                self.menu_up()
            elif btn_status & 0x04:  # DOWN
                self.menu_down()
            elif btn_status & 0x20:  # F1 - Select
                self.menu_select()
            elif btn_status & 0x40:  # F2 - Cancel/back
                self.osd_enable(False)
                self.osd_visible = False

    # =========================================================================
    # SPI Communication
    # =========================================================================

    def read_irq_flags(self):
        """Read IRQ flags from FPGA

        Returns:
            int: IRQ flags (bit7 = button IRQ pending)
        """
        self._cs_active()
        self.spi.write(bytearray([CMD_READ_IRQ]))
        result = bytearray(1)
        self.spi.readinto(result)
        self._cs_inactive()
        return result[0]

    def read_buttons(self):
        """Read button status from FPGA (also clears button IRQ)

        Returns:
            int: Button status (bit6:0 = BTN[6:0], active-high)
        """
        self._cs_active()
        self.spi.write(bytearray([CMD_READ_BTN]))
        result = bytearray(1)
        self.spi.readinto(result)
        self._cs_inactive()
        return result[0] & 0x7F  # Mask to 7 bits

    def osd_enable(self, enable):
        """Enable or disable OSD overlay"""
        self._cs_active()
        if enable:
            self.spi.write(bytearray([CMD_OSD_ENABLE]))
        else:
            self.spi.write(bytearray([CMD_OSD_DISABLE]))
        self._cs_inactive()

    def osd_write_line(self, line, text):
        """Write text to OSD line

        Args:
            line: Line number (0-15)
            text: Text string (max 32 chars, will be padded/truncated)
        """
        if line < 0 or line > 15:
            return

        # Pad or truncate to 32 chars
        text = text[:32].ljust(32)

        self._cs_active()
        self.spi.write(bytearray([CMD_OSD_WRITE + line]))  # 0x20 + line
        self.spi.write(text.encode('ascii', errors='replace'))
        self._cs_inactive()

    def osd_clear(self):
        """Clear all OSD lines"""
        for i in range(16):
            self.osd_write_line(i, "")

    # =========================================================================
    # Menu System
    # =========================================================================

    def toggle_osd(self):
        """Toggle OSD visibility"""
        self.osd_visible = not self.osd_visible
        if self.osd_visible:
            self.osd_enable(True)
            self.show_main_menu()
        else:
            self.osd_enable(False)

    def show_main_menu(self):
        """Display main OSD menu"""
        self.menu_items = [
            ("Load Snowflake", "/sd/pdp1/snowflake.rim"),
            ("Load Spacewar", "/sd/pdp1/spacewar.rim"),
            ("Load Pong", "/sd/pdp1/pong.rim"),
            ("Browse Files", None),
        ]
        self.menu_cursor = 0
        self._draw_menu()

    def _draw_menu(self):
        """Redraw menu with current cursor position"""
        self.osd_write_line(0, "=== PDP-1 Menu ===")
        self.osd_write_line(1, "")

        for i, (name, _) in enumerate(self.menu_items):
            marker = ">" if i == self.menu_cursor else " "
            self.osd_write_line(2 + i, "{} {}".format(marker, name))

        # Clear remaining lines
        for i in range(2 + len(self.menu_items), 16):
            self.osd_write_line(i, "")

    def menu_up(self):
        """Move menu cursor up"""
        if self.menu_cursor > 0:
            self.menu_cursor -= 1
            self._draw_menu()

    def menu_down(self):
        """Move menu cursor down"""
        if self.menu_cursor < len(self.menu_items) - 1:
            self.menu_cursor += 1
            self._draw_menu()

    def menu_select(self):
        """Select current menu item"""
        if self.menu_cursor >= len(self.menu_items):
            return

        name, path = self.menu_items[self.menu_cursor]

        if path is None:
            # Browse files - not implemented yet
            self.osd_write_line(15, "Not implemented")
            return

        # Load the selected file
        self.osd_write_line(15, "Loading...")
        self.osd_enable(False)
        self.osd_visible = False

        # Create loader and load file
        loader = ld_pdp1(self.spi, self.cs)
        result = loader.load_and_run(path, verbose=False)

        if not result:
            # Show error
            self.osd_enable(True)
            self.osd_visible = True
            self.osd_write_line(15, "Load FAILED!")
        else:
            print("Loaded: {}".format(path))


# =============================================================================
# OSD Quick Start
# =============================================================================

def start_osd():
    """Initialize and start OSD controller with IRQ support

    Usage:
        import ld_pdp1
        osd = ld_pdp1.start_osd()
        # Press PWR button to toggle OSD menu
    """
    release_sd_pins()
    osd = OsdController()
    osd.setup_irq()
    print("OSD ready. Press PWR button to open menu.")
    return osd
