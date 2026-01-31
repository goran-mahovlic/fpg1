# DEBUG SESSION: Coordinate System Fix
**Date:** 2026-01-31
**Author:** Jelena (Debug Agent)
**Tags:** DEBUG, ANIMATION, CRT, COORDINATES, PHOSPHOR

## Problem Description

User reported seeing a green bar on the RIGHT edge of the screen instead of an orbit in the center.

Serial debug output showed:
```
F:019A A:00 X:644 Y:515
F:019B A:00 X:657 Y:603
```

Coordinates were around 500-760 (near center 512 of 1024) but displayed on the right edge.

## Root Cause Analysis

### Issue 1: PDP-1 Coordinate Transformation Applied to TEST_ANIMATION

The CRT module (`pdp1_vga_crt.v`) applied PDP-1 specific coordinate transformation:
```verilog
{ buffer_pixel_y, buffer_pixel_x } <= { ~pixel_x_i, pixel_y_i };
```

This transformation:
- Inverts X axis (`~pixel_x_i`): PDP-1 has origin at TOP-RIGHT, VGA at TOP-LEFT
- Swaps X and Y: rotates coordinates for correct orientation

For TEST_ANIMATION mode, this transformation was incorrect because animation already uses VGA-native coordinates.

### Issue 2: Wrong Center Coordinates

test_animation.v used PDP-1 1024x1024 coordinates:
```verilog
localparam CENTER_X = 10'd512;   // 1024/2
localparam CENTER_Y = 10'd512;   // 1024/2
localparam SEMI_A   = 8'd200;
localparam SEMI_B   = 8'd160;
```

But for direct VGA output (640x480), it should use:
```verilog
localparam CENTER_X = 10'd320;   // 640/2
localparam CENTER_Y = 10'd240;   // 480/2
localparam SEMI_A   = 8'd100;
localparam SEMI_B   = 8'd80;
```

### Issue 3: Signed Arithmetic Bug

The coordinate calculation used bit slicing for division:
```verilog
pixel_x <= CENTER_X + x_offset[14:7];  // WRONG for negative offsets!
```

For signed values, bit extraction doesn't preserve sign. Fixed with arithmetic shift:
```verilog
pixel_x <= CENTER_X + (x_offset >>> 7);  // Correct: preserves sign
```

## Fixes Applied

### 1. pdp1_vga_crt.v - Conditional Coordinate Transformation

Added `ifdef TEST_ANIMATION` to use direct coordinates without inversion/swap:
```verilog
`ifdef TEST_ANIMATION
    // Direct coordinates for TEST_ANIMATION mode
    { buffer_pixel_y, buffer_pixel_x } <= { pixel_y_i, pixel_x_i };
`else
    // PDP-1 transformation
    { buffer_pixel_y, buffer_pixel_x } <= { ~pixel_x_i, pixel_y_i };
`endif
```

### 2. test_animation.v - Correct VGA Coordinates

Changed parameters to 640x480 center:
```verilog
localparam CENTER_X = 10'd320;   // 640/2
localparam CENTER_Y = 10'd240;   // 480/2
localparam SEMI_A   = 8'd100;    // polu-os X
localparam SEMI_B   = 8'd80;     // polu-os Y
```

### 3. test_animation.v - Signed Arithmetic Fix

Changed from bit slicing to arithmetic shift:
```verilog
pixel_x <= CENTER_X + (x_offset >>> 7);
pixel_y <= CENTER_Y + (y_offset >>> 7);
```

### 4. serial_debug.v - Added LED Status

Extended debug format from:
```
F:xxxx A:yy X:zzz Y:www
```
To:
```
F:xxxx A:yy X:zzz Y:www L:bbbbbbbb
```

Where L shows 8-bit LED status in binary for hardware state debugging.

### 5. test_animation.v - Exposed debug_angle

Added `debug_angle` output port to avoid accessing internal signals:
```verilog
output wire [7:0]  debug_angle
```

## Verification Results

After fixes, serial output shows correct coordinates:
```
F:0F45 A:7F X:258 Y:241
F:0F46 A:1A X:391 Y:287
```

- X ranges: 220-419 (expected: 320 +/- 100 = 220-420)
- Y ranges: 160-319 (expected: 240 +/- 80 = 160-320)

The elliptical orbit is now correctly centered on the 640x480 display.

## Files Modified

1. `/home/klaudio/port_fpg1/src/pdp1_vga_crt.v` - Conditional coordinate transformation
2. `/home/klaudio/port_fpg1/src/test_animation.v` - VGA coordinates + signed arithmetic
3. `/home/klaudio/port_fpg1/src/serial_debug.v` - LED status output
4. `/home/klaudio/port_fpg1/src/top_pdp1.v` - Wire up new signals

## Lessons Learned

1. **Coordinate Systems Matter**: PDP-1 origin (TOP-RIGHT) vs VGA origin (TOP-LEFT) requires explicit handling
2. **Signed vs Unsigned**: Bit extraction `[n:m]` doesn't work for signed values; use `>>> n` for signed division
3. **Debug Output is Essential**: LED status and serial output are critical for FPGA debugging
4. **Conditional Compilation**: Use `ifdef` to maintain compatibility between modes

## Build Command

```bash
source /home/klaudio/Programs/oss-cad-suite/environment
cd /home/klaudio/port_fpg1
make clean && make pdp1_anim
bun ~/.claude/tools/ULX3S-Remote.ts flash build/pdp1_anim.bit
timeout 5 bun ~/.claude/tools/ULX3S-Remote.ts serial
```
