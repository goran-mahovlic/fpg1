#!/usr/bin/env python3
"""
mif2hex.py - Altera MIF to Verilog HEX converter

Converts Altera Memory Initialization Files (.mif) to Verilog $readmemh format (.hex)

Supported MIF features:
- DATA_RADIX: BIN, HEX, OCT, DEC
- ADDRESS_RADIX: HEX, DEC, OCT, BIN
- Sequential and sparse address formats
- Comments (-- style)

Author: Dora Matic (REGOC team)
Task: TASK-190 MIF to HEX Conversion
"""

import re
import sys
import argparse
from pathlib import Path


def parse_mif(mif_path: Path) -> dict:
    """
    Parse an Altera MIF file and extract memory contents.

    Returns:
        dict with keys: width, depth, address_radix, data_radix, data (dict of addr->value)
    """
    with open(mif_path, 'r') as f:
        content = f.read()

    # Remove comments (-- style)
    content = re.sub(r'--.*$', '', content, flags=re.MULTILINE)

    # Parse header parameters
    width_match = re.search(r'WIDTH\s*=\s*(\d+)', content, re.IGNORECASE)
    depth_match = re.search(r'DEPTH\s*=\s*(\d+)', content, re.IGNORECASE)
    addr_radix_match = re.search(r'ADDRESS_RADIX\s*=\s*(\w+)', content, re.IGNORECASE)
    data_radix_match = re.search(r'DATA_RADIX\s*=\s*(\w+)', content, re.IGNORECASE)

    if not all([width_match, depth_match]):
        raise ValueError(f"Missing WIDTH or DEPTH in {mif_path}")

    width = int(width_match.group(1))
    depth = int(depth_match.group(1))
    address_radix = addr_radix_match.group(1).upper() if addr_radix_match else 'HEX'
    data_radix = data_radix_match.group(1).upper() if data_radix_match else 'HEX'

    # Extract CONTENT block
    content_match = re.search(r'CONTENT\s*BEGIN\s*(.*?)\s*END', content, re.DOTALL | re.IGNORECASE)
    if not content_match:
        raise ValueError(f"No CONTENT BEGIN...END block found in {mif_path}")

    content_block = content_match.group(1)

    # Parse address:data pairs
    data = {}
    radix_base = {'BIN': 2, 'OCT': 8, 'DEC': 10, 'HEX': 16}
    addr_base = radix_base.get(address_radix, 16)
    data_base = radix_base.get(data_radix, 16)

    # Match patterns like "0000 : 1234;" or "[0000..001F] : 0000;"
    # Standard pattern: addr : value;
    for match in re.finditer(r'([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f]+)\s*;', content_block):
        addr_str, value_str = match.groups()
        addr = int(addr_str, addr_base)
        value = int(value_str, data_base)
        data[addr] = value

    # Range pattern: [start..end] : value;
    for match in re.finditer(r'\[([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\]\s*:\s*([0-9A-Fa-f]+)\s*;', content_block):
        start_str, end_str, value_str = match.groups()
        start = int(start_str, addr_base)
        end = int(end_str, addr_base)
        value = int(value_str, data_base)
        for addr in range(start, end + 1):
            data[addr] = value

    return {
        'width': width,
        'depth': depth,
        'address_radix': address_radix,
        'data_radix': data_radix,
        'data': data
    }


def convert_to_hex(mif_data: dict, fill_gaps: bool = True) -> list:
    """
    Convert parsed MIF data to HEX format lines.

    Args:
        mif_data: Parsed MIF dictionary
        fill_gaps: If True, fill missing addresses with zeros

    Returns:
        List of hex strings (one per address)
    """
    width = mif_data['width']
    depth = mif_data['depth']
    data = mif_data['data']

    # Calculate hex digits needed for the width
    hex_digits = (width + 3) // 4  # Round up

    lines = []
    for addr in range(depth):
        if addr in data:
            value = data[addr]
        elif fill_gaps:
            value = 0
        else:
            continue

        # Format as hex with proper width
        hex_str = format(value, f'0{hex_digits}X')
        lines.append(hex_str)

    return lines


def mif_to_hex(input_path: Path, output_path: Path, verbose: bool = False) -> dict:
    """
    Convert a MIF file to HEX format.

    Returns:
        dict with conversion statistics
    """
    mif_data = parse_mif(input_path)
    hex_lines = convert_to_hex(mif_data)

    with open(output_path, 'w') as f:
        for line in hex_lines:
            f.write(line + '\n')

    stats = {
        'input': str(input_path),
        'output': str(output_path),
        'width': mif_data['width'],
        'depth': mif_data['depth'],
        'data_radix': mif_data['data_radix'],
        'entries': len(mif_data['data']),
        'hex_lines': len(hex_lines)
    }

    if verbose:
        print(f"Converted: {input_path.name}")
        print(f"  Width: {stats['width']} bits, Depth: {stats['depth']} words")
        print(f"  Data radix: {stats['data_radix']}")
        print(f"  Entries: {stats['entries']}, Output lines: {stats['hex_lines']}")
        print(f"  Output: {output_path}")

    return stats


def main():
    parser = argparse.ArgumentParser(
        description='Convert Altera MIF files to Verilog $readmemh HEX format',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s input.mif                    # Creates input.hex in same directory
  %(prog)s input.mif -o output.hex      # Specify output file
  %(prog)s *.mif -d /path/to/output/    # Batch convert to directory
        """
    )

    parser.add_argument('input', nargs='+', type=Path,
                        help='Input MIF file(s)')
    parser.add_argument('-o', '--output', type=Path,
                        help='Output HEX file (single file mode)')
    parser.add_argument('-d', '--output-dir', type=Path,
                        help='Output directory for batch conversion')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')

    args = parser.parse_args()

    results = []

    for input_path in args.input:
        if not input_path.exists():
            print(f"Error: {input_path} not found", file=sys.stderr)
            continue

        # Determine output path
        if args.output and len(args.input) == 1:
            output_path = args.output
        elif args.output_dir:
            args.output_dir.mkdir(parents=True, exist_ok=True)
            output_path = args.output_dir / (input_path.stem + '.hex')
        else:
            output_path = input_path.with_suffix('.hex')

        try:
            stats = mif_to_hex(input_path, output_path, verbose=args.verbose)
            results.append(stats)
        except Exception as e:
            print(f"Error converting {input_path}: {e}", file=sys.stderr)

    if args.verbose and len(results) > 1:
        print(f"\nTotal: {len(results)} files converted")

    return 0 if results else 1


if __name__ == '__main__':
    sys.exit(main())
