# HARDWARE TEST PROCEDURE - ULX3S v3.1.7
# PDP-1 FPGA Emulator (FPG-1 Port)

**Dokument:** Hardware Test & Verification Procedure
**Platforma:** ULX3S v3.1.7 (LFE5U-85F-6BG381C)
**Autor:** Grga Babic, REGOC Hardware & Peripherals Specialist
**Datum:** 2026-01-31
**Task:** TASK-197
**Verzija:** 1.0

---

## TABLE OF CONTENTS

1. [Hardware Overview](#1-hardware-overview)
2. [Pre-Test Requirements](#2-pre-test-requirements)
3. [Bitstream Upload Procedure](#3-bitstream-upload-procedure)
4. [Hardware Verification Checklist](#4-hardware-verification-checklist)
5. [HDMI Output Test Procedure](#5-hdmi-output-test-procedure)
6. [Spacewar! Control Test Procedure](#6-spacewar-control-test-procedure)
7. [LED Indicator Reference](#7-led-indicator-reference)
8. [Troubleshooting Guide](#8-troubleshooting-guide)
9. [Pin Mapping Reference](#9-pin-mapping-reference)

---

## 1. HARDWARE OVERVIEW

### 1.1 ULX3S Board Specifications

| Specification | Value |
|---------------|-------|
| FPGA | Lattice ECP5 LFE5U-85F-6BG381C |
| Clock Source | 25 MHz on-board oscillator |
| Logic Elements | 83,640 LUT4 |
| EBR Memory | 208 blocks (18 Kbit each) |
| DSP Blocks | 156 |
| PLL Count | 4 |
| GPIO Banks | Multiple 3.3V LVCMOS33 |

### 1.2 Required Hardware

- [ ] ULX3S v3.1.7 board
- [ ] USB-C cable (power and programming)
- [ ] HDMI monitor (supports 1280x1024 or 1024x768)
- [ ] HDMI cable (standard Type A)
- [ ] Computer with fujprog installed

### 1.3 Optional Hardware

- [ ] USB keyboard (for future OSD control)
- [ ] Serial console (ESP32 UART for debugging)
- [ ] Logic analyzer (for debugging)

---

## 2. PRE-TEST REQUIREMENTS

### 2.1 Software Prerequisites

```bash
# Verify fujprog is installed
which fujprog
# Expected output: /usr/local/bin/fujprog (or similar)

# Verify bitstream file exists
ls -lh /home/klaudio/port_fpg1/build/pdp1.bit
# Expected: ~445 KB file dated 2026-01-31

# Check FTDI device access
lsusb | grep -i ftdi
# Expected: Bus XXX Device XXX: ID 0403:6015 Future Technology Devices International, Ltd
```

### 2.2 Board Physical Inspection

Before powering on, verify:

- [ ] **No physical damage** to board or connectors
- [ ] **USB-C connector** is clean and undamaged
- [ ] **HDMI connector** pins are straight and clean
- [ ] **DIP switches** move freely (SW1-SW4)
- [ ] **Push buttons** click properly (BTN1-BTN6)
- [ ] **LEDs** are not physically damaged (LED0-LED7)
- [ ] **No short circuits** visible on board

### 2.3 Initial Power-On Test

```bash
# Connect USB-C cable
# Board should:
# - Power LED should illuminate (usually red PWR LED)
# - Some LEDs may flash during ESP32 boot
# - No smoke, unusual smells, or excessive heat

# Verify FTDI device enumeration
lsusb | grep FTDI
# Expected: ID 0403:6015 FT231X USB UART
```

---

## 3. BITSTREAM UPLOAD PROCEDURE

### 3.1 SRAM Upload (Temporary - Lost on Power Cycle)

**Use case:** Quick testing, development iterations

```bash
# Navigate to project directory
cd /home/klaudio/port_fpg1

# Upload bitstream to SRAM
fujprog build/pdp1.bit

# Expected output:
# ULX2S / ULX3S JTAG programmer v4.8 (git hash...)
# Using FTDI interface
# Programming: 100%
# Done.
```

**Timing:** ~15-30 seconds

**Verification:**
- LED7 should turn ON (indicates PLL locked)
- HDMI output should become active within 1-2 seconds
- LEDs 0-6 may show various states based on configuration

### 3.2 FLASH Upload (Permanent - Survives Power Cycle)

**Use case:** Production deployment, field testing

```bash
# Upload bitstream to SPI FLASH
fujprog -j flash build/pdp1.bit

# Expected output:
# ULX2S / ULX3S JTAG programmer v4.8
# Using FTDI interface
# Programming flash: 100%
# Done.
```

**Timing:** ~60-90 seconds

**Verification:**
- Power cycle the board (disconnect/reconnect USB)
- Configuration should automatically load from FLASH
- LED7 should illuminate after ~2-3 seconds (PLL lock)
- HDMI output should activate

### 3.3 Upload Troubleshooting

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| `fujprog: device not found` | USB not connected or FTDI driver issue | Check `lsusb`, reconnect USB, check permissions |
| `Programming failed at X%` | Board power issue, bad USB cable | Try different USB port/cable, check power LED |
| `JTAG chain not detected` | JTAG pins damaged or ESP32 interference | Check wifi_gpio0 pullup, try pressing BTNPWR |
| Upload succeeds but no config | Wrong bitstream format or corrupt file | Verify .bit file size (~445KB), re-synthesize |

---

## 4. HARDWARE VERIFICATION CHECKLIST

Use this checklist after each bitstream upload:

### 4.1 Immediate Post-Upload (0-5 seconds)

- [ ] **LED7 (PLL Lock)** - Should turn ON solid
  - If OFF: PLL failed to lock, check clock constraints
  - If blinking: Possible clock instability

- [ ] **LED6 (Single Player Mode)** - Reflects SW1 state
  - Toggle SW1, LED6 should mirror the switch

- [ ] **LED5 (Player 2 Mode)** - Reflects SW0 state
  - Toggle SW0, LED5 should mirror the switch

- [ ] **LED4 (Test Pattern)** - Reflects SW3 state
  - Toggle SW3, LED4 should mirror the switch
  - When SW3=ON, test pattern should appear on HDMI

### 4.2 HDMI Connection Test (5-15 seconds)

- [ ] **Monitor detects signal** - "No signal" message should disappear
- [ ] **Resolution detected** - Monitor OSD should show 1280x1024 @ ~50Hz
- [ ] **Image stable** - No flickering, snow, or artifacts
- [ ] **Colors correct** - If test pattern active, verify R/G/B channels

### 4.3 Interactive Control Test (15-60 seconds)

- [ ] **BTN1 (UP/FIRE1)** - LED0 mirrors button state when pressed
- [ ] **BTN2 (DOWN/FIRE2)** - LED1 mirrors button state when pressed
- [ ] **BTN3 (LEFT)** - LED2 mirrors button state when pressed
- [ ] **BTN4 (RIGHT)** - LED3 mirrors button state when pressed

### 4.4 System Stability Test (1-5 minutes)

- [ ] **No LED flickering** - LEDs should be stable (solid ON or OFF)
- [ ] **No HDMI dropouts** - Signal should remain stable
- [ ] **No excessive heating** - FPGA should be warm but not hot to touch
- [ ] **Repeatable behavior** - Power cycle 3x, behavior should be identical

---

## 5. HDMI OUTPUT TEST PROCEDURE

### 5.1 Test Pattern Mode

**Purpose:** Verify HDMI/DVI video pipeline without CPU complexity

**Procedure:**

1. **Activate Test Pattern**
   ```
   - Set SW3 = ON (up position)
   - LED4 should turn ON
   - HDMI output should show test pattern within 1 second
   ```

2. **Expected Output**
   - **Resolution:** 1280x1024 @ 50Hz (or configured resolution)
   - **Pattern type:** (Depends on implementation - TBD)
     - Option A: Color bars (R/G/B/White stripes)
     - Option B: Grid pattern with coordinates
     - Option C: Solid color cycling

3. **Verify Video Timing**
   ```
   Monitor OSD should report:
   - Horizontal: 1280 pixels
   - Vertical: 1024 pixels
   - Refresh: ~48-52 Hz
   - Signal type: DVI or HDMI
   ```

4. **Visual Quality Checks**
   - [ ] **Sharp edges** - No blurring on pattern boundaries
   - [ ] **Correct colors** - R/G/B channels not swapped
   - [ ] **No tearing** - Vertical sync working
   - [ ] **No jitter** - Stable image, no horizontal drift
   - [ ] **Full screen** - Pattern fills entire display area

### 5.2 PDP-1 Display Mode

**Purpose:** Verify CRT emulation and vector display

**Procedure:**

1. **Deactivate Test Pattern**
   ```
   - Set SW3 = OFF (down position)
   - LED4 should turn OFF
   ```

2. **Expected Initial State**
   - **Black screen** with potential faint phosphor dots
   - **CRT scanline effect** may be visible (if implemented)
   - **Waiting for CPU initialization**

3. **Spacewar! Boot Sequence** (if ROM loaded)
   - After 2-5 seconds, vector graphics should appear
   - Ships, star, and hyperspace boundary
   - Smooth vector drawing (not blocky pixels)

4. **CRT Phosphor Decay Test**
   - Press FIRE button (BTN1 or BTN2) to shoot
   - Projectile trail should have **fade-out effect**
   - Fade duration: ~500ms (depends on ring buffer implementation)

### 5.3 HDMI Troubleshooting Matrix

| Symptom | Diagnosis | Solution |
|---------|-----------|----------|
| No signal at all | TMDS not transmitting | Check clk_shift (should be 5x pixel clock) |
| Signal detected but black screen | Video timing wrong or PLL unlock | Verify LED7, check PLL config |
| Corrupted image, random colors | TMDS encoding issue | Verify GPDI pin mapping in LPF file |
| Image shifts horizontally | H-sync timing off | Check vga.vhd timing parameters |
| Image flickers | V-sync issue or refresh rate mismatch | Check monitor compatibility, try different monitor |
| Colors swapped (e.g., red appears blue) | RGB channel swap in GPDI mapping | Verify gpdi_dp[2:0] order in constraints |
| Image "tears" during motion | No V-sync or framebuffer issue | Check VGA timing generation |

---

## 6. SPACEWAR! CONTROL TEST PROCEDURE

### 6.1 Control Mapping

**Player 1 Controls (Single Player Mode: SW1 = ON):**

| Function | Button | Physical Location | LED Feedback |
|----------|--------|-------------------|--------------|
| Rotate CCW | BTN3 (LEFT) | Bottom left of board | LED2 |
| Rotate CW | BTN4 (RIGHT) | Bottom right of board | LED3 |
| Thrust | BTN1 (UP) | Top right corner | LED0 |
| Fire | BTN2 (DOWN) | Top right, below BTN1 | LED1 |
| Hyperspace | BTN5 (F1) | Left side, below BTN3 | - |

**Player 2 Controls (Two Player Mode: SW0 = ON, SW1 = OFF):**

| Function | Button | Note |
|----------|--------|------|
| Rotate CCW | BTN5 | Shared with P1 Hyperspace |
| Rotate CW | BTN6 | Separate button |
| Thrust | BTN4 | Note: different than P1 |
| Fire | BTN2 | Shared with P1 Fire |

### 6.2 Single Player Test Procedure

**Setup:**
```
- SW0 = OFF (P2 mode disabled)
- SW1 = ON (Single player mode)
- SW2 = OFF (Reserved)
- SW3 = OFF (CRT mode, not test pattern)

Expected LEDs:
- LED7 = ON (PLL locked)
- LED6 = ON (Single player mode active)
- LED5 = OFF (P2 mode inactive)
- LED4 = OFF (Not test pattern)
```

**Step 1: Verify LED Feedback**

Press and hold each button, verify corresponding LED:

| Button | Press | Expected LED State | Release | Expected LED State |
|--------|-------|-------------------|---------|-------------------|
| BTN1 | Hold | LED0 = ON | Release | LED0 = OFF |
| BTN2 | Hold | LED1 = ON | Release | LED1 = OFF |
| BTN3 | Hold | LED2 = ON | Release | LED2 = OFF |
| BTN4 | Hold | LED3 = ON | Release | LED3 = OFF |

**Result:** [ ] PASS / [ ] FAIL

**Step 2: Verify Ship Rotation**

1. Observe initial ship orientation on screen
2. Press and hold BTN3 (LEFT)
   - Ship should rotate counter-clockwise
   - Rotation should be smooth (not jerky)
3. Release BTN3
   - Rotation should stop immediately
4. Press and hold BTN4 (RIGHT)
   - Ship should rotate clockwise
5. Release BTN4

**Result:** [ ] PASS / [ ] FAIL

**Step 3: Verify Thrust**

1. Press and hold BTN1 (UP/FIRE1)
2. Ship should:
   - Display thrust flame at rear
   - Accelerate in current direction
   - Momentum should continue after button release
3. Observe motion physics
   - Newtonian physics (no drag)
   - Ship continues drifting

**Result:** [ ] PASS / [ ] FAIL

**Step 4: Verify Fire**

1. Press BTN2 (DOWN/FIRE2) briefly
2. Projectile should:
   - Launch from ship position
   - Travel in ship's facing direction
   - Leave phosphor trail (fade-out)
   - Wrap around screen edges
3. Rapid fire test:
   - Press BTN2 multiple times quickly
   - Each press should fire new projectile
   - Max ~3-5 projectiles on screen simultaneously

**Result:** [ ] PASS / [ ] FAIL

**Step 5: Verify Hyperspace**

1. Press BTN5 (F1)
2. Ship should:
   - Disappear from current position
   - Reappear at random location
   - Brief invulnerability period
3. Warning: Limited hyperspace uses (typically 3-5)

**Result:** [ ] PASS / [ ] FAIL

### 6.3 Two Player Test Procedure

**Setup:**
```
- SW0 = ON (P2 mode enabled)
- SW1 = OFF (Disable single player mode)
- SW2 = OFF
- SW3 = OFF

Expected LEDs:
- LED7 = ON
- LED6 = OFF (Single player OFF)
- LED5 = ON (P2 mode active)
- LED4 = OFF
```

**Test Matrix:**

| Player | Rotate CCW | Rotate CW | Thrust | Fire | Hyperspace |
|--------|-----------|-----------|--------|------|------------|
| P1 | BTN3 | BTN4 | BTN1 | BTN2 | BTN5 |
| P2 | BTN5 | BTN6 | BTN4 | BTN2 | (shared) |

**Note:** In two-player mode, BTN2 (Fire) and BTN5 may be shared resources.

**Simultaneous Input Test:**
1. P1 presses BTN1 (Thrust)
2. P2 presses BTN4 (Thrust) at same time
3. Both ships should respond independently
4. No control conflicts or freezing

**Result:** [ ] PASS / [ ] FAIL

### 6.4 Control Timing Test

**Button Debouncing:**
- Press button rapidly 10 times
- Each press should register
- No double-triggers
- No missed inputs

**Button Hold:**
- Hold button for 5+ seconds
- Action should continue smoothly
- No timeout or lag

**Multiple Simultaneous Buttons:**
- Press BTN1 + BTN3 (Thrust + Rotate)
- Ship should thrust AND rotate simultaneously
- Try all combinations

---

## 7. LED INDICATOR REFERENCE

### 7.1 LED Mapping Table

| LED | Physical Location | Function | Expected State | Notes |
|-----|-------------------|----------|----------------|-------|
| LED7 | Rightmost | PLL Locked | ON = Locked, OFF = Failed | Critical - must be ON |
| LED6 | | Single Player Mode | Mirrors SW1 | ON = Single player active |
| LED5 | | Player 2 Mode Active | Mirrors SW0 | ON = P2 controls enabled |
| LED4 | | Test Pattern Mode | Mirrors SW3 | ON = Test pattern output |
| LED3 | | Player Control Feedback | Mirrors BTN4 | Real-time button state |
| LED2 | | Player Control Feedback | Mirrors BTN3 | Real-time button state |
| LED1 | | Player Control Feedback | Mirrors BTN2 | Real-time button state |
| LED0 | Leftmost | Player Control Feedback | Mirrors BTN1 | Real-time button state |

### 7.2 LED Diagnostic Patterns

**Normal Operation:**
```
LED7: [ON]  - PLL locked
LED6: [ON]  - If SW1=ON (single player)
LED5: [OFF] - If SW0=OFF (no P2)
LED4: [OFF] - If SW3=OFF (CRT mode)
LED3-0: [Dynamic] - Mirror button presses
```

**Test Pattern Mode:**
```
LED7: [ON]
LED6: [varies]
LED5: [varies]
LED4: [ON]  - Test pattern active
LED3-0: [Dynamic]
```

**Error State - PLL Not Locked:**
```
LED7: [OFF] or [BLINKING]
LED6-0: [Undefined behavior]
Action: Check clock constraints, verify 25MHz input
```

**Power-On Sequence:**
```
T=0s:    All LEDs may flash during configuration load
T=0.5s:  LED7 should turn ON (PLL lock)
T=1s:    LED6-4 reflect switch states
T=2s:    System ready, LED3-0 respond to buttons
```

---

## 8. TROUBLESHOOTING GUIDE

### 8.1 Power and Configuration Issues

#### 8.1.1 Board Does Not Power On

**Symptoms:**
- No LEDs illuminate
- USB device not detected by computer
- No heat from FPGA

**Diagnosis Steps:**
1. Check USB-C cable integrity
   ```bash
   # Try cable with known-good device
   # Look for physical damage to connector
   ```
2. Verify USB port provides power
   ```bash
   lsusb  # Should show FTDI device if powered
   ```
3. Check board power LED (usually red PWR LED near USB connector)
4. Measure voltage on 3.3V test points (if accessible)

**Solutions:**
- Replace USB cable
- Try different USB port (USB 3.0 recommended)
- Check for board shorts or damaged power circuitry
- Contact hardware supplier if persistent

#### 8.1.2 Configuration Upload Fails

**Error:** `fujprog: device not found`

**Causes & Solutions:**

| Cause | Check | Solution |
|-------|-------|----------|
| FTDI permissions | `ls -l /dev/ttyUSB*` | Add user to `dialout` group: `sudo usermod -a -G dialout $USER` |
| USB driver issue | `dmesg \| tail` | Install FTDI drivers, reload USB module |
| ESP32 interference | Physical inspection | Press and hold BTN_PWR during upload |
| JTAG pins damaged | Visual inspection | RMA board if physically damaged |

**Error:** `Programming failed at X%`

**Causes:**
- Bitstream corruption
- Power instability during upload
- FLASH memory wear (for FLASH uploads)

**Solutions:**
```bash
# Verify bitstream integrity
md5sum build/pdp1.bit
# Compare with expected hash from build log

# Try SRAM upload first (faster, safer)
fujprog build/pdp1.bit

# If SRAM works but FLASH fails:
# 1. FLASH may be worn out
# 2. Try erasing FLASH first
fujprog -j flash -e  # Erase
fujprog -j flash build/pdp1.bit  # Re-upload
```

### 8.2 HDMI / Video Issues

#### 8.2.1 No HDMI Signal

**LED7 State: OFF**
- **Diagnosis:** PLL failed to lock
- **Check:** Verify 25 MHz clock input
- **Solution:**
  ```bash
  # Check constraint file clock specification
  grep -i "clk_25mhz" src/ulx3s_v317_pdp1.lpf
  # Should show: FREQUENCY PORT "clk_25mhz" 25 MHZ;
  ```
- **If persistent:** PLL configuration error, review PLL parameters

**LED7 State: ON, but still no signal**
- **Diagnosis:** TMDS encoding or GPDI pin mapping issue
- **Check:** Toggle SW3 to enable test pattern
  - If test pattern also fails: Video pipeline broken
  - If test pattern works: CPU/framebuffer issue
- **Solution:**
  ```bash
  # Verify GPDI pin assignments
  grep -i "gpdi" src/ulx3s_v317_pdp1.lpf
  # Check for typos or swapped pins
  ```

#### 8.2.2 Distorted or Corrupted Video

**Symptom:** Image visible but colors wrong, lines shifted, or artifacts

**Diagnosis Matrix:**

| Visual Problem | Likely Cause | Fix |
|----------------|--------------|-----|
| Colors swapped (R<->B) | GPDI channel order | Swap pin assignments for Red/Blue channels |
| Horizontal shift/wrap | H-sync timing | Adjust h_pulse, h_back_porch in vga.vhd |
| Vertical roll | V-sync timing | Adjust v_pulse, v_back_porch in vga.vhd |
| Random pixel noise | Clock instability | Check clk_shift frequency (should be 5x clk_pixel) |
| Image "tears" vertically | Frame sync issue | Check vblank signal and framebuffer management |
| Faint/dim image | Brightness scaling | Check pixel intensity calculation |

**Quick Diagnostic Command:**
```bash
# Check timing parameters in video timing generator
grep -E "h_pulse|v_pulse|h_pixels|v_lines" src/video/vga.vhd
```

#### 8.2.3 Monitor Rejects Signal

**Monitor Error:** "Out of Range" or "Not Supported"

**Cause:** Timing parameters exceed monitor capabilities

**Solution:**
```bash
# Check configured resolution
grep -i "definitions" src/
# If using 1280x1024@60Hz, try switching to @50Hz
# Edit video timing to match monitor specs
```

**Common Safe Timings:**
- 1024x768 @ 60Hz (65 MHz pixel clock)
- 1280x1024 @ 50Hz (75 MHz pixel clock)
- 1280x1024 @ 60Hz (108 MHz pixel clock) - may be unstable on ECP5

### 8.3 Control Input Issues

#### 8.3.1 Buttons Not Responding

**LED Feedback Test:**
1. Press BTN1, check LED0
   - If LED0 lights up: Button works, issue is in game logic
   - If LED0 stays off: Hardware or input routing issue

**Hardware Check:**
```bash
# Verify button pin assignments
grep "btn\[" src/ulx3s_v317_pdp1.lpf
# Verify pull-up/pull-down configuration
# BTN[1-6] should have PULLMODE=DOWN
# BTN[0] (PWR) should have PULLMODE=UP
```

**Common Issues:**
- Reversed button polarity (active high vs. active low)
- Missing input synchronizer (metastability)
- Incorrect pull-up/pull-down configuration

#### 8.3.2 Buttons Stuck or Double-Trigger

**Symptom:** Single press registers as multiple presses

**Cause:** Lack of debouncing logic

**Check:** Review button input module for debounce logic
```verilog
// Should have ~10-50ms debounce delay
// Typical implementation: shift register or counter
```

**Workaround:** Press buttons more deliberately (slower)

#### 8.3.3 Multiple Buttons Conflict

**Symptom:** Pressing two buttons simultaneously causes unexpected behavior

**Diagnosis:**
- Check for shared resources in button handling
- Verify input ports are independent (not multiplexed)

**Solution:**
- May require firmware update to handle simultaneous inputs
- Check clock domain crossing if buttons sampled in different clock domains

### 8.4 System Stability Issues

#### 8.4.1 Random Crashes or Freezes

**Symptoms:**
- Video freezes after random time
- LEDs stop responding
- Requires power cycle to recover

**Diagnosis Steps:**

1. **Check PLL Lock Stability**
   - Monitor LED7 during freeze
   - If LED7 turns OFF: PLL losing lock (thermal or VCO issue)
   - If LED7 stays ON: Logic hang

2. **Check Clock Domain Crossing**
   ```bash
   # Look for CDC signals in design
   grep -i "cdc\|async\|synchronizer" src/*.v
   # All async signals should have 2-3 FF synchronizer chains
   ```

3. **Check Timing Analysis**
   ```bash
   # Review timing report from last build
   grep -i "error\|fail\|violation" build/pdp1_pnr.log
   # Look for setup/hold violations
   ```

4. **Check Temperature**
   - FPGA should be warm but not hot
   - If excessive heat: Possible routing congestion or high toggle rate

**Solutions:**
- Add timing constraints for critical paths
- Increase CDC synchronizer depth
- Reduce clock frequencies to relax timing
- Improve cooling (heatsink or airflow)

#### 8.4.2 Intermittent Video Dropouts

**Symptom:** HDMI signal drops for 1-2 seconds, then recovers

**Cause:** HDMI handshake or TMDS encoding instability

**Check:**
```bash
# Verify HDMI clock is stable
# clk_shift should be solid 5x clk_pixel
# No jitter or frequency drift
```

**Monitor Compatibility:**
- Some monitors are more sensitive to timing variations
- Try different HDMI cable (shorter = better)
- Try different monitor

### 8.5 Advanced Debugging

#### 8.5.1 Serial Console Debug Output (ESP32)

ULX3S has an ESP32 module that can provide UART debug output.

**Enable Serial Monitoring:**
```bash
# Install minicom or screen
sudo apt install minicom

# Connect to ESP32 UART
minicom -D /dev/ttyUSB1 -b 115200

# Or using screen
screen /dev/ttyUSB1 115200
```

**Note:** This requires ESP32 passthrough firmware or FPGA debug UART implementation.

#### 8.5.2 Logic Analyzer Capture

**Critical Signals to Probe:**
- `clk_25mhz` - Input clock (should be stable 25 MHz)
- `clk_pixel` - Pixel clock (75 MHz or 108 MHz)
- `clk_shift` - HDMI serializer clock (5x pixel clock)
- `pll_locked` - PLL lock indicator
- `btn[1:6]` - Button inputs
- `gpdi_dp[3:0]` - HDMI differential pairs (requires differential probe)

**Recommended Probing Points:**
- Refer to ULX3S schematic for test points
- Use through-hole GPIO headers as probe points
- Avoid loading high-speed signals (>100MHz) with standard probes

---

## 9. PIN MAPPING REFERENCE

### 9.1 Complete Pin Assignment Table

Extracted from `/home/klaudio/port_fpg1/src/ulx3s_v317_pdp1.lpf`

#### 9.1.1 System Clock
| Signal | Site | IO Type | Frequency | Note |
|--------|------|---------|-----------|------|
| clk_25mhz | G2 | LVCMOS33 | 25 MHz | On-board oscillator |

#### 9.1.2 Push Buttons (Active Low)
| Signal | Site | Pullmode | Function | Note |
|--------|------|----------|----------|------|
| btn[0] | D6 | UP | PWR Button | Under FPGA, affects ESP32 |
| btn[1] | R1 | DOWN | UP / FIRE1 | Player control |
| btn[2] | T1 | DOWN | DOWN / FIRE2 | Player control |
| btn[3] | R18 | DOWN | LEFT | Player control |
| btn[4] | V1 | DOWN | RIGHT | Player control |
| btn[5] | U1 | DOWN | F1 / Hyperspace | Player control |
| btn[6] | H16 | DOWN | F2 | Player control |

**Important:** Buttons are active LOW on hardware (pressed = 0, released = 1)

#### 9.1.3 DIP Switches
| Signal | Site | Function | Note |
|--------|------|----------|------|
| sw[0] | E8 | Player 2 Mode | ON = Enable P2 controls |
| sw[1] | D8 | Single Player Mode | ON = Single player |
| sw[2] | D7 | Reserved | Future use |
| sw[3] | E7 | CRT/Test Pattern | ON = Test pattern |

#### 9.1.4 LED Indicators
| Signal | Site | Function |
|--------|------|----------|
| led[7] | H3 | PLL Locked |
| led[6] | E1 | Single Player Mode |
| led[5] | E2 | P2 Mode Active |
| led[4] | D1 | Test Pattern Mode |
| led[3] | D2 | Button 4 Feedback |
| led[2] | C1 | Button 3 Feedback |
| led[1] | C2 | Button 2 Feedback |
| led[0] | B2 | Button 1 Feedback |

**Drive Strength:** 4 mA
**IO Type:** LVCMOS33
**Pullmode:** NONE

#### 9.1.5 HDMI/GPDI Output (TMDS Differential)
| Signal | Site (+) | Site (-) | Function |
|--------|----------|----------|----------|
| gpdi_dp[3] / gpdi_dn[3] | A17 | B18 | Clock Channel |
| gpdi_dp[2] / gpdi_dn[2] | A12 | A13 | Red Channel |
| gpdi_dp[1] / gpdi_dn[1] | A14 | C14 | Green Channel |
| gpdi_dp[0] / gpdi_dn[0] | A16 | B16 | Blue Channel |

**Note:** These are pseudo-differential (single-ended with inverted pair)
**IO Type:** LVCMOS33
**Drive:** 4 mA

#### 9.1.6 WiFi/ESP32 Control
| Signal | Site | Pullmode | Function |
|--------|------|----------|----------|
| wifi_gpio0 | L2 | UP | ESP32 control (keep HIGH to prevent FPGA reboot) |

**Critical:** wifi_gpio0 must be driven HIGH (1) to prevent ESP32 from rebooting the FPGA during operation.

### 9.2 Physical Button Layout (Top View)

```
                      ULX3S v3.1.7 Board
                    (View from top/component side)

                        USB-C Connector
                              [===]
                                |
       [BTN1]  [BTN2]           |         [HDMI]
        R1      T1              |         Connector
      (UP)    (DOWN)            |            []
                                |            ||
                                |            ||
                      +-------------------+
                      |                   |
       [BTN_PWR]  +   |      FPGA         |  + [LED 7-0]
          D6      |   |     LFE5U-85      |  |  (H3..B2)
                  |   |                   |  |
      [BTN5]      |   |                   |  |
       U1(F1)     |   +-------------------+  |
                  |                          |
      [BTN3]      |   [SW1-4: E8,D8,D7,E7]  |
       R18        |   (DIP Switches)         |
      (LEFT)      |                          |
                  |   [BTN4]                 |
      [BTN6]      |    V1                    |
       H16        |   (RIGHT)                |
      (F2)        |                          |
                  |                          |
                  +--------------------------|
```

### 9.3 Clock Architecture Diagram

```
           ULX3S Clock Distribution (PDP-1 Emulator)

  [25 MHz]                     +-------------+
  Onboard  -------------------→| EHXPLLL     |
  Oscillator                   | (PLL #1)    |
   (Site G2)                   +-------------+
                                      |
                   +------------------+------------------+
                   |                  |                  |
              [clk_shift]        [clk_pixel]       [clk_cpu_base]
               ~375 MHz           75-108 MHz          ~50 MHz
                   |                  |                  |
                   v                  v                  v
            +-----------+      +-----------+      +-----------+
            |  HDMI     |      |  VGA      |      | Prescaler |
            |  TMDS     |      |  Timing   |      |  /28      |
            | Encoder   |      | Generator |      +-----------+
            +-----------+      +-----------+            |
                   |                  |                 v
                   v                  v            [clk_cpu]
              [gpdi_dp/dn]      [hsync,vsync]     ~1.79 MHz
              HDMI Output       Video Sync        PDP-1 CPU Clock
```

**Key Frequencies:**
- **clk_25mhz:** 25 MHz (input)
- **clk_pixel:** 75 MHz (1280x1024@50Hz) or 108 MHz (1280x1024@60Hz)
- **clk_shift:** 375 MHz (for 75MHz pixel) or 540 MHz (for 108MHz pixel)
- **clk_cpu:** ~1.791 MHz (PDP-1 instruction cycle rate)

---

## APPENDIX A: QUICK REFERENCE CARD

### Upload Commands
```bash
# SRAM (temporary)
fujprog /home/klaudio/port_fpg1/build/pdp1.bit

# FLASH (permanent)
fujprog -j flash /home/klaudio/port_fpg1/build/pdp1.bit
```

### Expected States After Upload
- LED7: ON (PLL locked)
- LED6: Mirrors SW1 (single player mode)
- LED5: Mirrors SW0 (P2 mode)
- LED4: Mirrors SW3 (test pattern)
- HDMI: Active signal within 1-2 seconds

### Critical Checks
1. [ ] LED7 ON (if OFF, PLL failed)
2. [ ] HDMI signal detected by monitor
3. [ ] Buttons mirror to LEDs (BTN1→LED0, etc.)
4. [ ] Test pattern appears when SW3=ON
5. [ ] No excessive heat from FPGA

### Emergency Recovery
```bash
# If board becomes unresponsive:
1. Disconnect USB
2. Wait 5 seconds
3. Reconnect USB
4. Board will auto-load from FLASH (if previously written)
```

---

## DOCUMENT CHANGELOG

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-31 | Grga Babic | Initial release for TASK-197 |

---

## REFERENCES

- **ULX3S Hardware:** https://github.com/emard/ulx3s
- **Constraint File:** `/home/klaudio/port_fpg1/src/ulx3s_v317_pdp1.lpf`
- **Architecture Doc:** `/home/klaudio/port_fpg1/ARCHITECTURE.md`
- **Fujprog Tool:** https://github.com/kost/fujprog
- **ECP5 Primitives:** Lattice FPGA-TN-02032

---

**END OF HARDWARE TEST PROCEDURE**
