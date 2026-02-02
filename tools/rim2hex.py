#!/usr/bin/env python3
"""
rim2hex.py - PDP-1 RIM Paper Tape to Verilog HEX converter

Supports both standard RIM format and Macro1 block format:
- Standard RIM: DIO addr + data pairs
- Macro1 block: DIO start_addr + DIO end_addr + raw_data[] + checksum

RIM Format (PDP-1 paper tape):
- Leader/trailer: bytes without bit7 set (ignored)
- Data bytes have bit7 set (0x80 mask = data marker)
- Lower 6 bits of each byte contain data
- Three 6-bit values form one 18-bit word

Based on FPG1 FPGA implementation by hrvach:
https://github.com/hrvach/fpg1

Author: Jelena Kovacevic, REGOC team (with Macro1 fix from Kosjenka Vukovic)
"""

import argparse
import sys
from pathlib import Path

# PDP-1 opcodes (6 bits)
DIO_OPCODE = 0o32  # 26 decimal - Deposit I/O
JMP_OPCODE = 0o60  # 48 decimal - Jump
DAC_OPCODE = 0o24  # 20 decimal - Deposit AC


def extract_blocks(rim_bytes):
    """
    Extract data blocks separated by leader/trailer.

    Data bytes have bit7 set (0x80). Leader/trailer bytes don't.
    Returns list of blocks, each block is list of 6-bit values.
    """
    blocks = []
    current_block = []

    for b in rim_bytes:
        if b & 0x80:  # Data byte
            current_block.append(b & 0x3F)  # Extract lower 6 bits
        else:  # Leader/trailer
            if len(current_block) >= 3:  # Need at least one word
                blocks.append(current_block)
            current_block = []

    # Don't forget last block
    if len(current_block) >= 3:
        blocks.append(current_block)

    return blocks


def bytes_to_words(data_bytes):
    """
    Convert 6-bit data bytes to 18-bit words.

    Each word = 3 consecutive 6-bit values:
    word = (byte1 & 0x3F) << 12 | (byte2 & 0x3F) << 6 | (byte3 & 0x3F)
    """
    words = []
    i = 0
    while i + 2 < len(data_bytes):
        w = (data_bytes[i] << 12) | (data_bytes[i+1] << 6) | data_bytes[i+2]
        words.append(w)
        i += 3
    return words


def parse_rim_block(words, memory, verbose=False):
    """
    Parse standard RIM format (DIO + data pairs).

    Returns (loaded_count, start_address or None)
    """
    i = 0
    start_addr = None
    loaded = 0

    while i < len(words):
        word = words[i]
        opcode = (word >> 12) & 0o77
        addr = word & 0o7777

        if opcode == DIO_OPCODE:
            if i + 1 < len(words):
                data = words[i + 1]
                memory[addr] = data
                loaded += 1
                if verbose:
                    print(f"    RIM DIO @ {addr:04o}: {data:06o}")
                i += 2
            else:
                i += 1
        elif opcode == JMP_OPCODE:
            start_addr = addr
            if verbose:
                print(f"    RIM JMP -> {addr:04o}")
            i += 1
        else:
            i += 1

    return loaded, start_addr


def parse_macro_block(words, memory, verbose=False):
    """
    Parse Macro1 block format:
    - word[0] = DIO start_addr (where to load)
    - word[1] = DIO end_addr (exclusive)
    - word[2..n] = raw data words
    - Last word may be checksum (ignored)

    Returns number of words loaded, or 0 if not a valid Macro1 block.
    """
    if len(words) < 2:
        return 0

    word0 = words[0]
    word1 = words[1]

    opcode0 = (word0 >> 12) & 0o77
    opcode1 = (word1 >> 12) & 0o77

    # Both must be DIO instructions
    if opcode0 != DIO_OPCODE or opcode1 != DIO_OPCODE:
        return 0

    start_addr = word0 & 0o7777
    end_addr = word1 & 0o7777
    count = end_addr - start_addr

    # Sanity check
    if count <= 0 or count > len(words) - 2:
        return 0

    if verbose:
        print(f"    Macro1 block: {start_addr:04o} - {end_addr:04o} ({count} words)")

    # Load data words
    addr = start_addr
    for i in range(2, 2 + count):
        if i < len(words):
            memory[addr] = words[i]
            if verbose and addr < start_addr + 5:
                print(f"      {addr:04o}: {words[i]:06o}")
            addr += 1

    if verbose and count > 5:
        print(f"      ... ({count - 5} more words)")

    return count


def rim_to_hex(input_path, output_path, verbose=False):
    """
    Convert RIM file to HEX format.

    Handles both standard RIM and Macro1 block formats.
    Returns conversion statistics.
    """
    with open(input_path, 'rb') as f:
        rim_bytes = f.read()

    if verbose:
        print(f"Input: {input_path} ({len(rim_bytes)} bytes)")

    # Extract blocks separated by leader/trailer
    blocks = extract_blocks(rim_bytes)

    if verbose:
        print(f"Found {len(blocks)} data blocks")

    memory = {}
    program_start = 0o100  # Default start address
    total_loaded = 0

    for block_num, block in enumerate(blocks):
        words = bytes_to_words(block)

        if len(words) < 1:
            continue

        word0 = words[0]
        opcode0 = (word0 >> 12) & 0o77
        addr0 = word0 & 0o7777

        if verbose:
            print(f"  Block {block_num + 1}: {len(words)} words, first={word0:06o} (op={opcode0:02o})")

        # Case 1: Single JMP instruction
        if opcode0 == JMP_OPCODE and len(words) == 1:
            if verbose:
                print(f"    JMP -> {addr0:04o}")
            if addr0 != 0o7751:  # Not bootloader jump
                program_start = addr0
            continue

        # Case 2: Check for Macro1 block format (two consecutive DIO instructions)
        if opcode0 == DIO_OPCODE and len(words) >= 2:
            word1 = words[1]
            opcode1 = (word1 >> 12) & 0o77
            addr1 = word1 & 0o7777

            if opcode1 == DIO_OPCODE:
                count = addr1 - addr0
                # Valid Macro1 block if count > 0 and we have enough data
                if 0 < count <= len(words) - 2:
                    loaded = parse_macro_block(words, memory, verbose)
                    if loaded > 0:
                        total_loaded += loaded
                        continue

        # Case 3: Fall back to standard RIM parsing
        loaded, start = parse_rim_block(words, memory, verbose)
        total_loaded += loaded
        if start is not None:
            program_start = start

    # Generate HEX output (4096 lines for full PDP-1 memory)
    with open(output_path, 'w') as f:
        for addr in range(4096):
            value = memory.get(addr, 0)
            f.write(f"{value:05X}\n")

    # Statistics
    stats = {
        'input': str(input_path),
        'output': str(output_path),
        'file_size': len(rim_bytes),
        'blocks': len(blocks),
        'locations': len(memory),
        'min_addr': min(memory) if memory else 0,
        'max_addr': max(memory) if memory else 0,
        'start_addr': program_start
    }

    if verbose:
        print(f"\nStatistics:")
        print(f"  Loaded {stats['locations']} memory locations")
        print(f"  Address range: {stats['min_addr']:04o} - {stats['max_addr']:04o}")
        print(f"  Program start: {stats['start_addr']:04o}")
        print(f"  Output: {output_path}")

    return stats


def main():
    parser = argparse.ArgumentParser(
        description='Convert PDP-1 RIM paper tape (with Macro1 block support) to HEX',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s snowflake.rim -o rom/snowflake.hex
  %(prog)s spacewar.rim -v

Supports both standard RIM format and Macro1 block format.
Based on FPG1 FPGA implementation by hrvach.
        """
    )

    parser.add_argument('input', type=Path, help='Input RIM file')
    parser.add_argument('output', type=Path, nargs='?', help='Output HEX file')
    parser.add_argument('-o', '--output-opt', type=Path, dest='output_opt',
                        help='Output HEX file (alternative syntax)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')

    args = parser.parse_args()

    if not args.input.exists():
        print(f"Error: {args.input} not found", file=sys.stderr)
        return 1

    # Handle output path
    output_path = args.output or args.output_opt
    if output_path is None:
        output_path = args.input.with_suffix('.hex')

    # Create output directory if needed
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        stats = rim_to_hex(args.input, output_path, verbose=args.verbose)
        print(f"Converted: {args.input.name} -> {output_path}")
        print(f"  {stats['locations']} locations loaded")
        print(f"  Range: {stats['min_addr']:04o} - {stats['max_addr']:04o}")
        print(f"  Start: {stats['start_addr']:04o}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
