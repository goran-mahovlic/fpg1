#!/usr/bin/env python3
"""
Generate Verilog BRAM init file for ECP5 DP16KD from hex file.

Usage: python3 gen_bram_init.py spacewar.hex > rom/spacewar_init.vh

Input: Hex file with 5-digit hex values, one per line (18-bit values)
Output: Verilog include file with INITVAL parameters for DP16KD

Author: EMARD, REGOC team
"""

import sys

def read_hex_file(filename):
    """Read hex file and return list of 18-bit values."""
    values = []
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('//'):
                try:
                    val = int(line, 16) & 0x3FFFF  # Mask to 18 bits
                    values.append(val)
                except ValueError:
                    pass
    return values

def pack_initval(values, start_addr):
    """
    Pack 16 x 18-bit values into one INITVAL_xx (320 bits).
    ECP5 DP16KD packs 18-bit words as 20-bit slots (2 unused bits per word).
    """
    result = 0
    for i in range(16):
        addr = start_addr + i
        if addr < len(values):
            val = values[addr]
        else:
            val = 0
        # Pack 18-bit value into 20-bit slot (bits 19:18 unused)
        result |= (val & 0x3FFFF) << (i * 20)
    return result

def generate_verilog_include(values, module_name="pdp1_main_ram"):
    """Generate Verilog include file with INITVAL parameters."""

    lines = []
    lines.append("// Auto-generated BRAM init values")
    lines.append("// Source: gen_bram_init.py")
    lines.append(f"// Words: {len(values)}")
    lines.append("")

    # For 4K x 18-bit, we need 4096/512 = 8 DP16KD blocks
    # Each DP16KD has 512 x 18-bit words
    # Each INITVAL_xx holds 16 words
    # So we need 512/16 = 32 INITVAL parameters per block (INITVAL_00 to INITVAL_1F)

    num_blocks = (len(values) + 511) // 512  # Round up

    for block in range(min(num_blocks, 8)):  # Max 8 blocks for 4K words
        base_addr = block * 512
        lines.append(f"// Block {block}: addresses {base_addr} to {base_addr + 511}")

        for row in range(32):  # 32 INITVAL per block (00 to 1F)
            start_addr = base_addr + row * 16
            packed = pack_initval(values, start_addr)
            # Format as 320-bit hex (80 hex digits)
            hex_str = format(packed, '080X')
            param_name = f"INITVAL_{row:02X}"
            lines.append(f".{param_name}(320'h{hex_str}),")

        lines.append("")

    return '\n'.join(lines)

def generate_direct_dp16kd(values, module_name="pdp1_main_ram"):
    """Generate complete module with DP16KD instantiations."""

    lines = []
    lines.append("""/*
 * PDP-1 Main RAM - ECP5 Direct DP16KD Implementation
 * Auto-generated from hex file
 *
 * Uses direct DP16KD instantiation with INITVAL parameters
 * for guaranteed BRAM initialization on ECP5/Yosys.
 */

module pdp1_main_ram (
    input  wire [11:0] address_a,
    input  wire        clock_a,
    input  wire [17:0] data_a,
    input  wire        wren_a,
    output reg  [17:0] q_a,

    input  wire [11:0] address_b,
    input  wire        clock_b,
    input  wire [17:0] data_b,
    input  wire        wren_b,
    output reg  [17:0] q_b
);

    // 4K x 18-bit = 8 x DP16KD blocks (each 512 x 18-bit)
    wire [17:0] block_doa [0:7];
    wire [17:0] block_dob [0:7];
    wire [2:0] block_sel_a = address_a[11:9];
    wire [2:0] block_sel_b = address_b[11:9];
    wire [8:0] block_addr_a = address_a[8:0];
    wire [8:0] block_addr_b = address_b[8:0];

    // Mux output from selected block
    always @(posedge clock_a)
        q_a <= block_doa[block_sel_a];

    always @(posedge clock_b)
        q_b <= block_dob[block_sel_b];
""")

    # Generate 8 DP16KD blocks
    for block in range(8):
        base_addr = block * 512
        lines.append(f"""
    // Block {block}: addresses {base_addr} to {base_addr + 511}
    DP16KD #(
        .DATA_WIDTH_A(18),
        .DATA_WIDTH_B(18),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .CSDECODE_A("0b000"),
        .CSDECODE_B("0b000"),
        .WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL"),
        .GSR("DISABLED"),""")

        # Generate all 64 INITVAL parameters (00-3F for 1K words per block in 9-bit mode)
        # But for 18-bit width, we use 32 INITVAL (00-1F) for 512 words
        for row in range(64):  # Full 64 INITVAL for complete coverage
            start_addr = base_addr + row * 16
            packed = pack_initval(values, start_addr)
            hex_str = format(packed, '080X')
            param_name = f"INITVAL_{row:02X}"
            comma = "," if row < 63 else ""
            lines.append(f"        .{param_name}(320'h{hex_str}){comma}")

        lines.append(f"""    ) bram_{block} (
        .CLKA(clock_a),
        .CEA(block_sel_a == {block}),
        .OCEA(1'b1),
        .WEA(wren_a && (block_sel_a == {block})),
        .RSTA(1'b0),
        .CSA0(1'b0), .CSA1(1'b0), .CSA2(1'b0),
        .ADA0(block_addr_a[0]), .ADA1(block_addr_a[1]), .ADA2(block_addr_a[2]),
        .ADA3(block_addr_a[3]), .ADA4(block_addr_a[4]), .ADA5(block_addr_a[5]),
        .ADA6(block_addr_a[6]), .ADA7(block_addr_a[7]), .ADA8(block_addr_a[8]),
        .ADA9(1'b0), .ADA10(1'b0), .ADA11(1'b0), .ADA12(1'b0), .ADA13(1'b0),
        .DIA0(data_a[0]), .DIA1(data_a[1]), .DIA2(data_a[2]), .DIA3(data_a[3]),
        .DIA4(data_a[4]), .DIA5(data_a[5]), .DIA6(data_a[6]), .DIA7(data_a[7]),
        .DIA8(data_a[8]), .DIA9(data_a[9]), .DIA10(data_a[10]), .DIA11(data_a[11]),
        .DIA12(data_a[12]), .DIA13(data_a[13]), .DIA14(data_a[14]), .DIA15(data_a[15]),
        .DIA16(data_a[16]), .DIA17(data_a[17]),
        .DOA0(block_doa[{block}][0]), .DOA1(block_doa[{block}][1]), .DOA2(block_doa[{block}][2]),
        .DOA3(block_doa[{block}][3]), .DOA4(block_doa[{block}][4]), .DOA5(block_doa[{block}][5]),
        .DOA6(block_doa[{block}][6]), .DOA7(block_doa[{block}][7]), .DOA8(block_doa[{block}][8]),
        .DOA9(block_doa[{block}][9]), .DOA10(block_doa[{block}][10]), .DOA11(block_doa[{block}][11]),
        .DOA12(block_doa[{block}][12]), .DOA13(block_doa[{block}][13]), .DOA14(block_doa[{block}][14]),
        .DOA15(block_doa[{block}][15]), .DOA16(block_doa[{block}][16]), .DOA17(block_doa[{block}][17]),

        .CLKB(clock_b),
        .CEB(block_sel_b == {block}),
        .OCEB(1'b1),
        .WEB(wren_b && (block_sel_b == {block})),
        .RSTB(1'b0),
        .CSB0(1'b0), .CSB1(1'b0), .CSB2(1'b0),
        .ADB0(block_addr_b[0]), .ADB1(block_addr_b[1]), .ADB2(block_addr_b[2]),
        .ADB3(block_addr_b[3]), .ADB4(block_addr_b[4]), .ADB5(block_addr_b[5]),
        .ADB6(block_addr_b[6]), .ADB7(block_addr_b[7]), .ADB8(block_addr_b[8]),
        .ADB9(1'b0), .ADB10(1'b0), .ADB11(1'b0), .ADB12(1'b0), .ADB13(1'b0),
        .DIB0(data_b[0]), .DIB1(data_b[1]), .DIB2(data_b[2]), .DIB3(data_b[3]),
        .DIB4(data_b[4]), .DIB5(data_b[5]), .DIB6(data_b[6]), .DIB7(data_b[7]),
        .DIB8(data_b[8]), .DIB9(data_b[9]), .DIB10(data_b[10]), .DIB11(data_b[11]),
        .DIB12(data_b[12]), .DIB13(data_b[13]), .DIB14(data_b[14]), .DIB15(data_b[15]),
        .DIB16(data_b[16]), .DIB17(data_b[17]),
        .DOB0(block_dob[{block}][0]), .DOB1(block_dob[{block}][1]), .DOB2(block_dob[{block}][2]),
        .DOB3(block_dob[{block}][3]), .DOB4(block_dob[{block}][4]), .DOB5(block_dob[{block}][5]),
        .DOB6(block_dob[{block}][6]), .DOB7(block_dob[{block}][7]), .DOB8(block_dob[{block}][8]),
        .DOB9(block_dob[{block}][9]), .DOB10(block_dob[{block}][10]), .DOB11(block_dob[{block}][11]),
        .DOB12(block_dob[{block}][12]), .DOB13(block_dob[{block}][13]), .DOB14(block_dob[{block}][14]),
        .DOB15(block_dob[{block}][15]), .DOB16(block_dob[{block}][16]), .DOB17(block_dob[{block}][17])
    );
""")

    lines.append("endmodule")
    return '\n'.join(lines)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 gen_bram_init.py <hexfile> [--module]", file=sys.stderr)
        print("  --module: Generate complete module (default: just INITVAL params)", file=sys.stderr)
        sys.exit(1)

    hexfile = sys.argv[1]
    generate_module = "--module" in sys.argv

    values = read_hex_file(hexfile)
    print(f"// Read {len(values)} values from {hexfile}", file=sys.stderr)

    if generate_module:
        print(generate_direct_dp16kd(values))
    else:
        print(generate_verilog_include(values))
