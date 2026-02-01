#!/usr/bin/env python3
"""
PDP-1 Pixel Visualizer
======================
Parsira serial debug output i rekonstruira sliku iz pixel podataka.

Format poruke: P:xxxxx X:xxx Y:xxx B:x R:xxxx

Korištenje:
  # Direktno sa serial porta
  python3 pixel_visualizer.py /dev/ttyUSB0

  # Iz log datoteke
  python3 pixel_visualizer.py -f serial_log.txt

  # Sa ASCII outputom
  python3 pixel_visualizer.py -f serial_log.txt --ascii

  # Snimi kao PNG
  python3 pixel_visualizer.py -f serial_log.txt -o output.png

Autor: REGOČ tim (Jelena, Emard)
Datum: 2026-02-01
"""

import re
import sys
import argparse
from collections import defaultdict
from typing import Optional, Tuple, Dict, List

# Boje za ASCII vizualizaciju (brightness 0-7)
ASCII_CHARS = " .:-=+*#@"

# Regex za parsiranje pixel debug poruke
PIXEL_PATTERN = re.compile(r'P:(\d+)\s+X:(\d+)\s+Y:(\d+)\s+B:(\d+)(?:\s+R:(\d+))?')
FRAME_PATTERN = re.compile(r'F:(\d+)\s+PC:(\d+)')

class PixelBuffer:
    """Buffer za rekonstrukciju slike iz pixel podataka

    PDP-1 koristi 1024x1024 prostor (10-bit koordinate), ali se prikazuje na 512x512.
    Za VGA 640x480, centralni 512x512 je vidljiv.
    ASCII output: 160x100 za čitljiv prikaz (scale=6.4, zaokruženo na 6)
    """

    def __init__(self, width: int = 1024, height: int = 1024, scale: int = 8):
        self.width = width
        self.height = height
        self.scale = scale  # Faktor smanjenja (8 = 1024->128, ili 6 za 1024->170)
        self.scaled_width = width // scale
        self.scaled_height = height // scale

        # Pixel buffer: (x, y) -> max brightness
        self.pixels: Dict[Tuple[int, int], int] = defaultdict(int)

        # Statistika
        self.total_pixels = 0
        self.unique_positions = 0
        self.current_frame = 0
        self.last_pc = 0

    def add_pixel(self, x: int, y: int, brightness: int, pixel_num: int):
        """Dodaj pixel u buffer"""
        # Skaliraj koordinate
        sx = x // self.scale
        sy = y // self.scale

        # Ograniči na dimenzije
        if 0 <= sx < self.scaled_width and 0 <= sy < self.scaled_height:
            # Zadrži maksimalni brightness za poziciju
            old = self.pixels[(sx, sy)]
            if brightness > old:
                self.pixels[(sx, sy)] = brightness
                if old == 0:
                    self.unique_positions += 1

        self.total_pixels += 1

    def set_frame(self, frame: int, pc: int):
        """Postavi trenutni frame"""
        self.current_frame = frame
        self.last_pc = pc

    def to_ascii(self, max_width: int = 160) -> str:
        """Pretvori buffer u ASCII art

        Args:
            max_width: Maksimalna širina ASCII outputa (default 160 za čitljivost)
        """
        lines = []
        lines.append(f"Frame: {self.current_frame}  PC: {self.last_pc:03o}  Pixels: {self.total_pixels}  Unique: {self.unique_positions}")
        lines.append(f"Buffer: {self.width}x{self.height} -> {self.scaled_width}x{self.scaled_height} (scale {self.scale})")

        # Dodatno skaliranje ako je potrebno za terminal
        display_scale = 1
        if self.scaled_width > max_width:
            display_scale = (self.scaled_width + max_width - 1) // max_width
            display_width = self.scaled_width // display_scale
            display_height = self.scaled_height // display_scale
        else:
            display_width = self.scaled_width
            display_height = self.scaled_height

        lines.append(f"Display: {display_width}x{display_height}")
        lines.append("+" + "-" * display_width + "+")

        for y in range(display_height):
            row = "|"
            for x in range(display_width):
                # Pronađi maksimalni brightness u bloku
                max_b = 0
                for dy in range(display_scale):
                    for dx in range(display_scale):
                        sx = x * display_scale + dx
                        sy = y * display_scale + dy
                        b = self.pixels.get((sx, sy), 0)
                        if b > max_b:
                            max_b = b
                row += ASCII_CHARS[min(max_b, len(ASCII_CHARS)-1)]
            row += "|"
            lines.append(row)

        lines.append("+" + "-" * display_width + "+")
        return "\n".join(lines)

    def to_ppm(self) -> bytes:
        """Pretvori buffer u PPM sliku (binary format)"""
        header = f"P6\n{self.scaled_width} {self.scaled_height}\n255\n".encode()

        pixels = bytearray()
        for y in range(self.scaled_height):
            for x in range(self.scaled_width):
                b = self.pixels.get((x, y), 0)
                # Phosphor zelena boja
                intensity = int((b / 7.0) * 255)
                pixels.extend([0, intensity, int(intensity * 0.3)])  # RGB

        return header + bytes(pixels)

    def save_png(self, filename: str):
        """Snimi kao PNG (koristi PIL ako dostupan)"""
        try:
            from PIL import Image

            img = Image.new('RGB', (self.scaled_width, self.scaled_height), (0, 0, 0))

            for (x, y), b in self.pixels.items():
                intensity = int((b / 7.0) * 255)
                img.putpixel((x, y), (0, intensity, int(intensity * 0.3)))

            img.save(filename)
            print(f"Saved PNG: {filename}")

        except ImportError:
            # Fallback: snimi kao PPM
            ppm_filename = filename.replace('.png', '.ppm')
            with open(ppm_filename, 'wb') as f:
                f.write(self.to_ppm())
            print(f"PIL not available, saved PPM: {ppm_filename}")

    def clear(self):
        """Očisti buffer za novi frame"""
        self.pixels.clear()
        self.total_pixels = 0
        self.unique_positions = 0


def parse_line(line: str, buffer: PixelBuffer) -> bool:
    """Parsiraj liniju i dodaj podatke u buffer"""

    # Provjeri pixel debug poruku
    match = PIXEL_PATTERN.search(line)
    if match:
        pixel_num = int(match.group(1))
        x = int(match.group(2))
        y = int(match.group(3))
        brightness = int(match.group(4))
        ring_ptr = int(match.group(5)) if match.group(5) else 0

        buffer.add_pixel(x, y, brightness, pixel_num)
        return True

    # Provjeri frame info
    match = FRAME_PATTERN.search(line)
    if match:
        frame = int(match.group(1), 16)  # Hex frame number
        pc = int(match.group(2), 16)     # Hex PC
        buffer.set_frame(frame, pc)
        return True

    return False


def read_serial(port: str, baud: int = 115200) -> None:
    """Čitaj sa serial porta i vizualiziraj u realnom vremenu"""
    import serial

    buffer = PixelBuffer(scale=4)  # 512 -> 128
    last_frame = -1

    print(f"Connecting to {port} at {baud} baud...")

    with serial.Serial(port, baud, timeout=1) as ser:
        print("Connected. Press Ctrl+C to exit.")
        print()

        try:
            while True:
                line = ser.readline().decode('utf-8', errors='ignore').strip()
                if line:
                    parse_line(line, buffer)

                    # Osvježi prikaz na svakih 100 pixela ili novi frame
                    if buffer.total_pixels % 100 == 0 or buffer.current_frame != last_frame:
                        # Clear screen i prikaži
                        print("\033[2J\033[H")  # ANSI clear
                        print(buffer.to_ascii())
                        last_frame = buffer.current_frame

        except KeyboardInterrupt:
            print("\nExiting...")


def read_file(filename: str, buffer: PixelBuffer) -> None:
    """Čitaj iz log datoteke"""
    with open(filename, 'r') as f:
        for line in f:
            parse_line(line.strip(), buffer)


def main():
    parser = argparse.ArgumentParser(
        description='PDP-1 Pixel Visualizer - rekonstruira sliku iz serial debug outputa'
    )
    parser.add_argument('port', nargs='?', default=None,
                        help='Serial port (npr. /dev/ttyUSB0)')
    parser.add_argument('-f', '--file',
                        help='Čitaj iz log datoteke umjesto serial porta')
    parser.add_argument('-o', '--output',
                        help='Snimi sliku kao PNG')
    parser.add_argument('--ascii', action='store_true',
                        help='Prikaži kao ASCII art')
    parser.add_argument('-b', '--baud', type=int, default=115200,
                        help='Baud rate (default: 115200)')
    parser.add_argument('-s', '--scale', type=int, default=8,
                        help='Scale faktor (default: 8, tj. 1024->128)')
    parser.add_argument('-w', '--width', type=int, default=1024,
                        help='Originalna širina (default: 1024 za PDP-1)')
    parser.add_argument('-H', '--height', type=int, default=1024,
                        help='Originalna visina (default: 1024 za PDP-1)')
    parser.add_argument('--max-ascii-width', type=int, default=160,
                        help='Maksimalna širina ASCII outputa (default: 160)')

    args = parser.parse_args()

    buffer = PixelBuffer(width=args.width, height=args.height, scale=args.scale)

    if args.file:
        # Čitaj iz datoteke
        print(f"Reading from file: {args.file}")
        read_file(args.file, buffer)

        print(f"\nParsed {buffer.total_pixels} pixels at {buffer.unique_positions} unique positions")

        max_width = getattr(args, 'max_ascii_width', 160)

        if args.ascii:
            print()
            print(buffer.to_ascii(max_width))

        if args.output:
            buffer.save_png(args.output)

        if not args.ascii and not args.output:
            # Default: ASCII
            print()
            print(buffer.to_ascii(max_width))

    elif args.port:
        # Čitaj sa serial porta (real-time)
        try:
            read_serial(args.port, args.baud)
        except ImportError:
            print("Error: pyserial not installed. Run: pip install pyserial")
            sys.exit(1)
    else:
        # Čitaj sa stdin
        print("Reading from stdin... (pipe serial output or paste log)")
        for line in sys.stdin:
            parse_line(line.strip(), buffer)

        print(f"\nParsed {buffer.total_pixels} pixels")
        print()
        print(buffer.to_ascii())

        if args.output:
            buffer.save_png(args.output)


if __name__ == '__main__':
    main()
