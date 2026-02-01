#!/usr/bin/env python3
"""
rim2hex.py - PDP-1 RIM Paper Tape to Verilog HEX converter

Converts DEC Read-In Mode (RIM) paper tape format to Verilog $readmemh format.
Simulates the PDP-1 RIM bootloader to extract program data.

RIM Format (PDP-1 paper tape):
- Leader/trailer: 0x00 bytes (ignored)
- Data bytes have bit7 set (0x80 mask = data marker)
- Lower 6 bits of each byte contain data
- Initial blocks use DIO format to load bootloader at 7751-7775
- After JMP to bootloader, remaining data is processed by bootloader logic

The bootloader (at 7751-7775) uses a specific protocol:
- Reads pairs of 18-bit words from tape
- First word is DIO instruction with target address
- Second word is data to store

This script simulates that bootloader behavior to extract the complete program.

Based on FPG1 FPGA implementation by hrvach:
https://github.com/hrvach/fpg1

Output:
- 4096 lines (one per PDP-1 memory word)
- Each line: 5 hex digits representing 18-bit value

Author: Jelena Kovacevic, REGOC team
Task: Snowflake ROM conversion for PDP-1 emulator
"""

import argparse
import sys
from pathlib import Path


# PDP-1 opcodes (6 bits)
DIO_OPCODE = 0o32  # 26 decimal - Deposit I/O
JMP_OPCODE = 0o60  # 48 decimal - Jump
DAC_OPCODE = 0o24  # 20 decimal - Deposit AC


def read_rim_bytes(rim_path: Path) -> bytes:
    """Read RIM file as binary."""
    with open(rim_path, 'rb') as f:
        return f.read()


def extract_data_bytes(rim_bytes: bytes) -> list:
    """
    Extract data bytes from RIM tape (bytes with bit7 set).
    Returns list of 6-bit values (stripped of 0x80 marker).
    """
    data_bytes = []
    for b in rim_bytes:
        if b & 0x80:  # Data marker present
            data_bytes.append(b & 0x3F)  # Extract lower 6 bits
    return data_bytes


def decode_18bit_words(data_bytes: list) -> list:
    """
    Decode 6-bit data bytes into 18-bit words.
    Each word = 3 consecutive 6-bit values.
    """
    words = []
    i = 0
    while i + 2 < len(data_bytes):
        word = (data_bytes[i] << 12) | (data_bytes[i+1] << 6) | data_bytes[i+2]
        words.append(word)
        i += 3
    return words


def simulate_rim_loading(words: list, verbose: bool = False) -> tuple:
    """
    Simulate the RIM loading process.

    RIM tape structure:
    1. Initial DIO instructions load bootloader at 7751-7775
    2. JMP 7751 transfers control to bootloader
    3. Bootloader reads remaining words as DIO+data pairs

    Returns tuple of (memory_dict, start_address)
    """
    memory = {}
    start_address = 0o100  # Default start
    bootloader_active = False
    i = 0

    if verbose:
        print(f"Total words to process: {len(words)}")

    while i < len(words):
        word = words[i]
        opcode = (word >> 12) & 0o77
        address = word & 0o7777

        if not bootloader_active:
            # Phase 1: Initial loading of bootloader
            if opcode == DIO_OPCODE:
                if i + 1 < len(words):
                    data = words[i + 1]
                    memory[address] = data
                    if verbose:
                        print(f"  Init DIO @ {address:04o}: {data:06o}")
                    i += 2
                else:
                    i += 1
            elif opcode == JMP_OPCODE:
                if verbose:
                    print(f"  JMP -> {address:04o} - Bootloader activated")
                bootloader_active = True
                # The JMP target (7751) is the bootloader start
                # But the JMP instruction itself might carry start address info
                # For snowflake, the actual start is in 7760 (jmp 0100)
                i += 1
            else:
                if verbose and word != 0:
                    print(f"  Init: Unknown opcode {opcode:02o} at word {i}: {word:06o}")
                i += 1
        else:
            # Phase 2: Bootloader is processing remaining tape
            # Each pair: DIO instruction + data word
            if opcode == DIO_OPCODE:
                if i + 1 < len(words):
                    data = words[i + 1]
                    if address < 4096:
                        memory[address] = data
                        if verbose:
                            print(f"  Boot DIO @ {address:04o}: {data:06o}")
                    i += 2
                else:
                    i += 1
            elif opcode == JMP_OPCODE:
                # JMP marks end of loading, address is program start
                start_address = address
                if verbose:
                    print(f"  End JMP -> {address:04o} - Loading complete")
                # Don't break - there might be more segments
                i += 1
            else:
                # Some tapes have embedded data that isn't DIO/JMP
                # Try treating as DIO anyway (address might be implicit)
                if i + 1 < len(words) and address < 4096:
                    data = words[i + 1]
                    # Only store if it looks like valid code
                    if data != 0 or address in memory:
                        memory[address] = data
                        if verbose:
                            print(f"  Boot implicit @ {address:04o}: {data:06o}")
                i += 2

    return memory, start_address


def parse_rim_simple(data_bytes: list, verbose: bool = False) -> tuple:
    """
    Simple DIO-based parsing without bootloader simulation.
    Just extracts all DIO+data pairs from the tape.
    """
    memory = {}
    start_address = 0o100

    i = 0
    while i + 5 < len(data_bytes):
        # Build 36-bit block from 6 x 6-bit values
        block = 0
        for j in range(6):
            block = (block << 6) | data_bytes[i + j]

        # Split into two 18-bit words
        instr_word = (block >> 18) & 0x3FFFF
        data_word = block & 0x3FFFF

        opcode = (instr_word >> 12) & 0o77

        if opcode == DIO_OPCODE:
            address = instr_word & 0o7777
            if address < 4096:
                memory[address] = data_word
                if verbose:
                    print(f"  DIO @ {address:04o}: {data_word:06o}")

        elif opcode == JMP_OPCODE:
            start_address = instr_word & 0o7777
            if verbose:
                print(f"  JMP -> {start_address:04o}")

        i += 6

    return memory, start_address


def generate_hex(memory: dict, depth: int = 4096) -> list:
    """Generate HEX file content from memory map."""
    lines = []
    for addr in range(depth):
        value = memory.get(addr, 0)
        lines.append(f"{value:05X}")
    return lines


def rim_to_hex(input_path: Path, output_path: Path, verbose: bool = False,
               simulate: bool = True) -> dict:
    """
    Convert RIM file to HEX format.
    Returns conversion statistics.
    """
    rim_bytes = read_rim_bytes(input_path)

    if verbose:
        print(f"Input file: {input_path}")
        print(f"File size: {len(rim_bytes)} bytes")

    data_bytes = extract_data_bytes(rim_bytes)

    if verbose:
        print(f"Data bytes: {len(data_bytes)}")

    if simulate:
        # Full simulation approach
        words = decode_18bit_words(data_bytes)
        if verbose:
            print(f"18-bit words: {len(words)}")
            print("\nSimulating RIM loading:")
        memory, start_address = simulate_rim_loading(words, verbose=verbose)
    else:
        # Simple DIO extraction
        if verbose:
            print("\nExtracting DIO pairs:")
        memory, start_address = parse_rim_simple(data_bytes, verbose=verbose)

    hex_lines = generate_hex(memory)

    with open(output_path, 'w') as f:
        for line in hex_lines:
            f.write(line + '\n')

    if memory:
        min_addr = min(memory.keys())
        max_addr = max(memory.keys())
    else:
        min_addr = max_addr = 0

    stats = {
        'input': str(input_path),
        'output': str(output_path),
        'file_size': len(rim_bytes),
        'data_bytes': len(data_bytes),
        'locations': len(memory),
        'min_addr': min_addr,
        'max_addr': max_addr,
        'start_addr': start_address,
        'hex_lines': len(hex_lines)
    }

    if verbose:
        print(f"\nStatistics:")
        print(f"  Loaded {stats['locations']} memory locations")
        print(f"  Address range: {min_addr:04o}-{max_addr:04o} ({min_addr}-{max_addr})")
        print(f"  Start address: {start_address:04o} ({start_address})")
        print(f"  Output: {output_path}")

    return stats


def main():
    parser = argparse.ArgumentParser(
        description='Convert PDP-1 RIM paper tape to Verilog $readmemh HEX format',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s snowflake.rim -o rom/snowflake.hex
  %(prog)s spacewar.rim -v --simulate

Based on FPG1 FPGA implementation by hrvach.
        """
    )

    parser.add_argument('input', type=Path, help='Input RIM file')
    parser.add_argument('-o', '--output', type=Path,
                        help='Output HEX file (default: input with .hex extension)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    parser.add_argument('--simulate', action='store_true', default=True,
                        help='Simulate bootloader (default)')
    parser.add_argument('--no-simulate', action='store_false', dest='simulate',
                        help='Simple DIO extraction only')

    args = parser.parse_args()

    if not args.input.exists():
        print(f"Error: {args.input} not found", file=sys.stderr)
        return 1

    output_path = args.output if args.output else args.input.with_suffix('.hex')
    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        stats = rim_to_hex(args.input, output_path, verbose=args.verbose,
                          simulate=args.simulate)
        print(f"Converted: {args.input.name} -> {output_path}")
        print(f"  {stats['locations']} locations, range {stats['min_addr']:04o}-{stats['max_addr']:04o}")
        print(f"  Start address: {stats['start_addr']:04o}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    sys.exit(main())
