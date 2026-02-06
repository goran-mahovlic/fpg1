#!/usr/bin/env python3
"""
hex2verilog_init.py - Convert HEX file to Verilog initial block

Converts spacewar.hex (5-digit hex per line) to Verilog include file
with explicit memory initialization for ECP5/Yosys compatibility.

Yosys IGNORES $readmemh in initial blocks for ECP5 BRAM!
This script generates explicit assignments that Yosys WILL synthesize.

Author: Emard, REGOC FPGA Crisis Expert
"""

import sys
import os

def convert_hex_to_verilog(input_file, output_file):
    """Convert HEX file to Verilog initial block."""

    print(f"Reading: {input_file}")

    with open(input_file, 'r') as f:
        lines = f.readlines()

    # Count statistics
    total_words = len(lines)
    non_zero_count = 0

    # Get source filename for comment
    source_name = os.path.basename(input_file)

    # Build output
    output_lines = []
    output_lines.append(f"// Auto-generated from {source_name}")
    output_lines.append("// DO NOT EDIT MANUALLY - regenerate with hex2verilog_init.py")
    output_lines.append(f"// Total words: {total_words}")
    output_lines.append("//")
    output_lines.append("// This file is included in pdp1_main_ram.v")
    output_lines.append("// Yosys ignores $readmemh for ECP5 BRAM, so we use explicit assignments")
    output_lines.append("")
    output_lines.append("initial begin")

    for addr, line in enumerate(lines):
        line = line.strip()
        if not line:
            continue

        # Parse 5-digit hex value (PDP-1 is 18-bit = max 0x3FFFF)
        try:
            value = int(line, 16)
        except ValueError:
            print(f"Warning: Invalid hex at line {addr}: '{line}'")
            continue

        # Only emit non-zero values to save space
        # (Verilog memory is zero-initialized by default in simulation,
        # but for synthesis we need to be explicit about what we want)
        if value != 0:
            # Format: 18-bit hex value
            output_lines.append(f"    mem[{addr}] = 18'h{value:05X};")
            non_zero_count += 1

    output_lines.append("end")
    output_lines.append("")

    # Write output
    print(f"Writing: {output_file}")
    print(f"  Total words: {total_words}")
    print(f"  Non-zero words: {non_zero_count}")

    with open(output_file, 'w') as f:
        f.write('\n'.join(output_lines))

    print("Done!")
    return non_zero_count

def main():
    import argparse

    parser = argparse.ArgumentParser(description='Convert HEX file to Verilog initial block')
    parser.add_argument('input_file', help='Input HEX file')
    parser.add_argument('-o', '--output', required=True, help='Output Verilog file')

    args = parser.parse_args()

    if not os.path.exists(args.input_file):
        print(f"Error: Input file not found: {args.input_file}")
        sys.exit(1)

    convert_hex_to_verilog(args.input_file, args.output)

if __name__ == "__main__":
    main()
