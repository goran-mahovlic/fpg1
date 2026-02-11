#!/usr/bin/env python3
"""
PDP-1 Serial Loader
===================

Load programs (HEX format) into PDP-1 FPGA via UART serial port.
Works with the serial_loader.v module in the FPGA.

Usage:
    python3 serial_loader.py /dev/ttyUSB0 program.hex
    python3 serial_loader.py /dev/ttyUSB0 --ping
    python3 serial_loader.py /dev/ttyUSB0 --stop
    python3 serial_loader.py /dev/ttyUSB0 --run
    python3 serial_loader.py /dev/ttyUSB0 --set-address 0o100
    python3 serial_loader.py /dev/ttyUSB0 --set-word 0o777777

Protocol:
    Commands (1 byte):
        'L' (0x4C) - Load: addr(2) + data(3) -> write to RAM
        'W' (0x57) - Write test_word: data(3)
        'A' (0x41) - Write test_address: addr(2)
        'R' (0x52) - Run CPU
        'S' (0x53) - Stop CPU
        'P' (0x50) - Ping (responds 'K')

HEX File Format:
    Each line contains one 18-bit word in hexadecimal (6 digits).
    Lines are loaded sequentially starting from address 0.
    Comments start with # or ;
    Empty lines are skipped.

    Example:
        740400  ; lio 400 - Load IO from address 400
        700007  ; dpy - Display pixel from IO register
        600001  ; jmp 1 - Jump to address 1

Author: Jelena Kovacevic, REGOC team
Date: 2026-02-11
"""

import serial
import sys
import time
import argparse


# Command bytes
CMD_LOAD = b'L'
CMD_WRITE_TW = b'W'
CMD_WRITE_TA = b'A'
CMD_RUN = b'R'
CMD_STOP = b'S'
CMD_PING = b'P'
RSP_OK = b'K'


def connect(port, baudrate=115200, timeout=1.0):
    """Open serial connection to FPGA."""
    try:
        ser = serial.Serial(port, baudrate, timeout=timeout)
        time.sleep(0.1)  # Give FTDI time to initialize
        ser.reset_input_buffer()
        return ser
    except serial.SerialException as e:
        print(f"Error: Cannot open {port}: {e}")
        sys.exit(1)


def ping(ser):
    """Test connection with ping command."""
    ser.reset_input_buffer()
    ser.write(CMD_PING)
    response = ser.read(1)
    if response == RSP_OK:
        print("OK - FPGA responded")
        return True
    else:
        print(f"Error: No response from FPGA (got: {response})")
        return False


def stop_cpu(ser):
    """Send stop command to halt CPU."""
    ser.write(CMD_STOP)
    print("CPU stopped")


def run_cpu(ser):
    """Send run command to start CPU."""
    ser.write(CMD_RUN)
    print("CPU running")


def set_test_address(ser, address):
    """Set CPU start address (test_address register)."""
    addr = address & 0xFFF  # 12-bit address
    cmd = bytes([
        ord('A'),
        (addr >> 8) & 0xFF,
        addr & 0xFF
    ])
    ser.write(cmd)
    print(f"Set test_address = 0o{address:04o} (0x{address:03X})")


def set_test_word(ser, word):
    """Set test_word register (18-bit)."""
    w = word & 0x3FFFF  # 18-bit word
    cmd = bytes([
        ord('W'),
        (w >> 16) & 0x03,
        (w >> 8) & 0xFF,
        w & 0xFF
    ])
    ser.write(cmd)
    print(f"Set test_word = 0o{word:06o} (0x{word:05X})")


def load_word(ser, address, word):
    """Load a single 18-bit word to RAM address."""
    addr = address & 0xFFF  # 12-bit address
    w = word & 0x3FFFF      # 18-bit word
    cmd = bytes([
        ord('L'),
        (addr >> 8) & 0xFF,
        addr & 0xFF,
        (w >> 16) & 0x03,
        (w >> 8) & 0xFF,
        w & 0xFF
    ])
    ser.write(cmd)


def parse_hex_line(line):
    """Parse a line from HEX file, return word or None."""
    # Strip whitespace
    line = line.strip()

    # Skip empty lines and comments
    if not line or line.startswith('#') or line.startswith(';'):
        return None

    # Remove inline comments
    for sep in ['#', ';', '//']:
        if sep in line:
            line = line.split(sep)[0].strip()

    if not line:
        return None

    try:
        # Parse as hexadecimal
        word = int(line, 16) & 0x3FFFF  # Limit to 18 bits
        return word
    except ValueError:
        print(f"Warning: Cannot parse line: {line}")
        return None


def load_hex_file(ser, filename, start_address=0, verbose=False):
    """Load a HEX file into PDP-1 RAM."""
    print(f"Loading {filename}...")

    words_loaded = 0
    current_addr = start_address

    try:
        with open(filename, 'r') as f:
            for line_num, line in enumerate(f, 1):
                word = parse_hex_line(line)
                if word is not None:
                    load_word(ser, current_addr, word)
                    if verbose:
                        print(f"  [{current_addr:04o}] = {word:06o}")
                    current_addr += 1
                    words_loaded += 1

                    # Small delay every 64 words to not overflow UART buffer
                    if words_loaded % 64 == 0:
                        time.sleep(0.01)
    except FileNotFoundError:
        print(f"Error: File not found: {filename}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {e}")
        sys.exit(1)

    # Final flush
    time.sleep(0.05)

    print(f"Loaded {words_loaded} words to addresses 0o{start_address:04o} - 0o{current_addr-1:04o}")
    return words_loaded


def parse_octal_or_hex(value_str):
    """Parse a number from string (octal if starts with 0o, hex if 0x, else decimal)."""
    value_str = value_str.strip()
    if value_str.startswith('0o') or value_str.startswith('0O'):
        return int(value_str, 8)
    elif value_str.startswith('0x') or value_str.startswith('0X'):
        return int(value_str, 16)
    else:
        return int(value_str)


def main():
    parser = argparse.ArgumentParser(
        description='PDP-1 Serial Loader - Load programs via UART',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s /dev/ttyUSB0 program.hex          # Load and run program
  %(prog)s /dev/ttyUSB0 program.hex --no-run # Load only, don't start
  %(prog)s /dev/ttyUSB0 --ping               # Test connection
  %(prog)s /dev/ttyUSB0 --stop               # Stop CPU
  %(prog)s /dev/ttyUSB0 --run                # Start CPU
  %(prog)s /dev/ttyUSB0 --set-address 0o100  # Set start address (octal)
  %(prog)s /dev/ttyUSB0 --set-word 0o777777  # Set test word (octal)
'''
    )

    parser.add_argument('port', help='Serial port (e.g., /dev/ttyUSB0)')
    parser.add_argument('file', nargs='?', help='HEX file to load')
    parser.add_argument('--ping', action='store_true', help='Test connection')
    parser.add_argument('--stop', action='store_true', help='Stop CPU')
    parser.add_argument('--run', action='store_true', help='Start CPU')
    parser.add_argument('--no-run', action='store_true', help='Do not start CPU after loading')
    parser.add_argument('--set-address', metavar='ADDR', help='Set test_address (octal: 0o100, hex: 0x40)')
    parser.add_argument('--set-word', metavar='WORD', help='Set test_word (octal: 0o777777)')
    parser.add_argument('--start-address', metavar='ADDR', default='0',
                        help='Start loading at this RAM address (default: 0)')
    parser.add_argument('--baud', type=int, default=115200, help='Baud rate (default: 115200)')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')

    args = parser.parse_args()

    # Open serial connection
    ser = connect(args.port, args.baud)

    try:
        # Handle commands
        if args.ping:
            ping(ser)
            return

        if args.stop:
            stop_cpu(ser)
            return

        if args.set_address:
            addr = parse_octal_or_hex(args.set_address)
            set_test_address(ser, addr)
            return

        if args.set_word:
            word = parse_octal_or_hex(args.set_word)
            set_test_word(ser, word)
            return

        if args.run and not args.file:
            run_cpu(ser)
            return

        # Load file if specified
        if args.file:
            # Ping first to verify connection
            if not ping(ser):
                sys.exit(1)

            # Stop CPU before loading
            stop_cpu(ser)
            time.sleep(0.1)

            # Parse start address
            start_addr = parse_octal_or_hex(args.start_address)

            # Load the file
            words = load_hex_file(ser, args.file, start_addr, args.verbose)

            if words > 0:
                # Set test_address to start address (or first loaded address)
                set_test_address(ser, start_addr)

                # Start CPU unless --no-run
                if not args.no_run:
                    time.sleep(0.1)
                    run_cpu(ser)
                    print("Done!")
                else:
                    print("Done! (CPU not started - use --run to start)")
        else:
            parser.print_help()

    finally:
        ser.close()


if __name__ == "__main__":
    main()
