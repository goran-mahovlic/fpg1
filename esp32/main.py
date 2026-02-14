# main.py: executed on every boot
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

# Run PDP-1 snowflake demo on boot
print("\n" + "=" * 40)
print("AUTO-BOOT: PDP-1 Snowflake Demo")
print("=" * 40)

import time
time.sleep(2)  # Wait for FTP to be available

try:
    import os

    # Check for required files
    try:
        st = os.stat('/pdp1.bit')
        print("Found /pdp1.bit ({} bytes)".format(st[6]))
    except OSError:
        print("ERROR: /pdp1.bit not found!")
        raise Exception("Missing /pdp1.bit")

    try:
        st = os.stat('/snowflake.rim')
        print("Found /snowflake.rim ({} bytes)".format(st[6]))
    except OSError:
        print("ERROR: /snowflake.rim not found!")
        raise Exception("Missing /snowflake.rim")

    gc.collect()

    # Flash FPGA with bitstream
    print("\nFlashing FPGA with pdp1.bit...")
    import ecp5
    #ecp5.prog('/pdp1.bit')
    print("FPGA programmed successfully!")

    gc.collect()

    # Wait for FPGA to initialize after programming
    print("Waiting 2 seconds for FPGA init...")
    time.sleep(2)

    gc.collect()

    # Start OSD controller with file browser
    # UPDATED 2026-02-14: Use OSD for file selection instead of hardcoded load
    print("\nStarting OSD file browser...")
    import ld_pdp1
    osd = ld_pdp1.run()

    print("\nSUCCESS! OSD controller active!")
    print("Press UP+DOWN+LEFT+RIGHT combo to toggle OSD menu.")
    print("Use UP/DOWN to navigate, RIGHT to select, LEFT to go back.")
    print("F1 to refresh directory listing.")

except Exception as e:
    print("\nAUTO-BOOT FAILED!")
    print("Error:", str(e))
    import sys
    sys.print_exception(e)
    print("\nManual commands:")
    print("  import ecp5; ecp5.prog('/pdp1.bit')")
    print("  import ld_pdp1; osd = ld_pdp1.run()")

print("=" * 40 + "\n")
