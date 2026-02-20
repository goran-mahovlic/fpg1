# main.py: executed on every boot
# UPDATED 2026-02-20 by Jelena: OSD Game Selection Menu
#
# Na boot-u prikazuje listu dostupnih igrica na OSD-u i ceka odabir.
# Korisnik odabire igricu pritiskom na gumbe BTN[1-4].

try:
    import wifiman
except:
    print('wifiman.py error')
import gc
gc.collect()
import uftpd
from ntptime import settime
try:
    settime()
    print('NTP time set')
except:
    print('NTP not available')

# =============================================================================
# GAME SELECTION MENU
# =============================================================================
# Dostupne igrice:
#   BTN[1] (FIRE1) = PONG (default ROM - samo restart CPU)
#   BTN[2] (FIRE2) = Minskytron (/minskytron.rim)
#   BTN[3] (UP)    = Snowflake (/snowflake.rim)
#   BTN[4] (DOWN)  = Snowflake Pure (/snowflake_pure.rim)
#
# Button bit masks (from ld_pdp1.py):
#   BTN_FIRE1 = 0x02  # btn[1]
#   BTN_FIRE2 = 0x04  # btn[2]
#   BTN_UP    = 0x08  # btn[3]
#   BTN_DOWN  = 0x10  # btn[4]
# =============================================================================

GAMES = [
    # (button_mask, name, file_path, description)
    (0x02, "PONG", None, "Default ROM - CPU restart only"),
    (0x04, "Minskytron", "/minskytron.rim", "Classic PDP-1 demo"),
    (0x08, "Snowflake", "/snowflake.rim", "Snowflake demo"),
    (0x10, "Snowflake Pure", "/snowflake_pure.rim", "Pure snowflake variant"),
]

print("\n" + "=" * 40)
print("PDP-1 GAME SELECTION MENU")
print("=" * 40)

import time
time.sleep(1)  # Wait for FTP to be ready

try:
    import os

    # Check for bitstream
    try:
        st = os.stat('/pdp1.bit')
        print("Found /pdp1.bit ({} bytes)".format(st[6]))
    except OSError:
        print("ERROR: /pdp1.bit not found!")
        raise Exception("Missing /pdp1.bit")

    gc.collect()

    # Flash FPGA with bitstream (uncomment when needed)
    print("\nFlashing FPGA with pdp1.bit...")
    import ecp5
    # ecp5.prog('/pdp1.bit')  # Uncomment to enable FPGA programming
    print("FPGA programmed successfully!")

    gc.collect()

    # Wait for FPGA to initialize
    print("Waiting 2 seconds for FPGA init...")
    time.sleep(2)

    gc.collect()

    # Initialize OSD loader
    print("\nInitializing OSD...")
    import ld_pdp1

    # Create OsdController instance (has OSD methods)
    # AND ld_pdp1 instance (has load/cpu methods)
    spi, cs = ld_pdp1.init_spi()
    osd = ld_pdp1.OsdController(spi, cs)  # For OSD and button reading
    loader = ld_pdp1.ld_pdp1(spi, cs)      # For loading RIM files

    gc.collect()

    # Enable OSD and show menu
    osd.osd_enable(True)
    osd.osd_clear()

    # Display game selection menu
    osd.osd_write_line(0, "=== PDP-1 GAME SELECT ===")
    osd.osd_write_line(1, "")
    osd.osd_write_line(2, "BTN1 (FIRE1): PONG")
    osd.osd_write_line(3, "  Default ROM - restart CPU")
    osd.osd_write_line(4, "")
    osd.osd_write_line(5, "BTN2 (FIRE2): Minskytron")
    osd.osd_write_line(6, "  Classic PDP-1 demo")
    osd.osd_write_line(7, "")
    osd.osd_write_line(8, "BTN3 (UP): Snowflake")
    osd.osd_write_line(9, "  Snowflake demo")
    osd.osd_write_line(10, "")
    osd.osd_write_line(11, "BTN4 (DOWN): Snowflake Pure")
    osd.osd_write_line(12, "  Pure variant")
    osd.osd_write_line(13, "")
    osd.osd_write_line(14, "Press button to select...")
    osd.osd_write_line(15, "")

    print("\nOSD Menu displayed. Waiting for button press...")
    print("BTN1=PONG, BTN2=Minskytron, BTN3=Snowflake, BTN4=Snowflake Pure")

    # Wait for button press with timeout
    selected_game = None
    timeout_sec = 30  # 30 seconds timeout (was 60)
    start_time = time.ticks_ms()
    last_btn = 0
    last_countdown = -1

    while selected_game is None:
        # Calculate remaining time
        elapsed_ms = time.ticks_diff(time.ticks_ms(), start_time)
        remaining = timeout_sec - (elapsed_ms // 1000)

        # Update countdown on OSD (only when second changes)
        if remaining != last_countdown:
            last_countdown = remaining
            osd.osd_write_line(14, "Select in {:2d}s (default: PONG)".format(remaining))

        # Check timeout
        if remaining <= 0:
            print("\nTimeout - defaulting to PONG")
            selected_game = GAMES[0]
            break

        # Read button status via OsdController
        btn = osd.read_buttons()

        # Process only on new press (not on release)
        if btn != last_btn and btn > 1:
            # Check each game's button
            for game in GAMES:
                btn_mask, name, path, desc = game
                if btn & btn_mask:
                    selected_game = game
                    print("\nSelected: {} (btn=0x{:02X})".format(name, btn))
                    break

        last_btn = btn
        time.sleep_ms(50)

    # Game selected - process it
    btn_mask, name, path, desc = selected_game

    # Update OSD to show selection
    osd.osd_clear()
    osd.osd_write_line(0, "=== LOADING ===")
    osd.osd_write_line(2, "Game: " + name)
    osd.osd_write_line(4, desc)

    if path is None:
        # PONG - just restart CPU
        osd.osd_write_line(6, "Restarting CPU...")
        print("\nPONG selected - restarting CPU only")
        loader.cpu_halt()
        time.sleep_ms(100)
        loader.cpu_reset()
        time.sleep_ms(100)
        loader.cpu_run()
        osd.osd_write_line(8, "CPU running!")
    else:
        # Load RIM file
        osd.osd_write_line(6, "Loading: " + path)
        print("\nLoading: " + path)

        # Check file exists
        try:
            st = os.stat(path)
            print("Found {} ({} bytes)".format(path, st[6]))
        except OSError:
            osd.osd_write_line(8, "ERROR: File not found!")
            print("ERROR: {} not found!".format(path))
            raise Exception("Missing " + path)

        # Load the RIM file using loader instance
        loader.load(path, verbose=True)
        osd.osd_write_line(8, "Loaded successfully!")

    # Wait a moment then disable OSD
    time.sleep(2)
    osd.osd_enable(False)

    print("\nSUCCESS! Game loaded and running!")
    print("=" * 40)

    # Enter main OSD loop for file browser access
    print("\nStarting OSD controller (combo: UP+DOWN+LEFT+RIGHT to toggle)...")
    osd_main = ld_pdp1.run()

except Exception as e:
    print("\nBOOT FAILED!")
    print("Error:", str(e))
    import sys
    sys.print_exception(e)
    print("\nManual commands:")
    print("  import ecp5; ecp5.prog('/pdp1.bit')")
    print("  import ld_pdp1; osd = ld_pdp1.run()")

print("=" * 40 + "\n")
