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
    ecp5.prog('/pdp1.bit')
    print("FPGA programmed successfully!")

    gc.collect()

    # Wait for FPGA to initialize after programming
    print("Waiting 2 seconds for FPGA init...")
    time.sleep(2)

    gc.collect()

    # Load and run snowflake demo
    print("\nLoading snowflake.rim...")
    import ld_pdp1
    result = ld_pdp1.load('/snowflake.rim')

    if result:
        print("\nSUCCESS! Snowflake demo running!")
        print("Check VGA display for rotating dots pattern.")
    else:
        print("\nWARNING: load() returned False")
        print("Demo may not be running correctly.")

except Exception as e:
    print("\nAUTO-BOOT FAILED!")
    print("Error:", str(e))
    import sys
    sys.print_exception(e)
    print("\nManual commands:")
    print("  import ecp5; ecp5.prog('/pdp1.bit')")
    print("  import ld_pdp1; ld_pdp1.load('/snowflake.rim')")

print("=" * 40 + "\n")
