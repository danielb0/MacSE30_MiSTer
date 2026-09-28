#!/usr/bin/env python3
"""Disassemble a PIC1654S program - the SE/30's ADB transceiver (342S0440-B).

WHY THIS EXISTS
    SE30_PLAN.md 6.3.3 and 6.12 item 2: the transceiver runs Apple's mask
    program, and what the program does is read from the program, not from
    anyone's annotation of it.  This prints it in the PIC1650-family
    mnemonics of the PIC1654S data sheet (Microchip DS33013A, 1990, the
    instruction summary on pp. 4-41 and 4-42), with the file registers
    named as the data sheet names them and the SE/30's wiring (sheet 4)
    beside each port bit.

THE IMAGE
    0x400 bytes: 512 words of two bytes, low byte first, twelve bits used
    (MAME's `342s0440-b.bin`, CRC32 cffb33eb).  Addresses are printed in
    octal, as the data sheet writes them, with hex beside.

USAGE
    pic_dis.py <image>            the listing
    pic_dis.py <image> --uses     which files, bits and instruction kinds
                                  the program touches (the checks of 6.12
                                  item 2)
"""
import struct
import sys

FILES = {0: "IND", 1: "RTCC", 2: "PC", 3: "STATUS", 4: "FSR", 5: "PORTA", 6: "PORTB"}
# the SE/30's wiring of each port bit (plan 6.2)
PINS = {
    (5, 0): "ST0", (5, 1): "ST1", (5, 2): "ADB drive (1 = pull low)", (5, 3): "ADB sense",
    (6, 0): "RB0 n.c.", (6, 1): "RB1 n.c.", (6, 2): "SCLK", (6, 3): "DIO", (6, 4): "INT*",
    (6, 5): "RB5 n.c.", (6, 6): "RB6 n.c.", (6, 7): "RB7 n.c.",
    (3, 0): "C", (3, 1): "DC", (3, 2): "Z",
}
BYTE_OPS = ["NOP/MOVWF", "CLRW/CLRF", "SUBWF", "DECF", "IORWF", "ANDWF", "XORWF", "ADDWF",
            "MOVF", "COMF", "INCF", "DECFSZ", "RRF", "RLF", "SWAPF", "INCFSZ"]


def fname(f):
    return FILES.get(f, "F%02o" % f)


def dis(w):
    """(mnemonic text, kind, file or None, bit or None)"""
    if w >> 10 == 0:
        op, d, f = (w >> 6) & 0xF, (w >> 5) & 1, w & 0x1F
        if op == 0:
            if d:
                return "MOVWF  %s" % fname(f), "MOVWF", f, None
            return ("NOP" if w == 0 else "?%04o (unused 0001-0037)" % w), "NOP", None, None
        if op == 1:
            return ("CLRF   %s" % fname(f), "CLRF", f, None) if d else ("CLRW", "CLRW", None, None)
        return "%-6s %s,%s" % (BYTE_OPS[op], fname(f), "F" if d else "W"), BYTE_OPS[op], f, None
    if w >> 10 == 1:
        op, b, f = (w >> 8) & 3, (w >> 5) & 7, w & 0x1F
        m = ["BCF", "BSF", "BTFSC", "BTFSS"][op]
        return "%-6s %s,%d" % (m, fname(f), b), m, f, b
    op = w >> 8
    k = w & 0xFF
    if op == 0x8:
        return "RETLW  %02X" % k, "RETLW", None, None
    if op == 0x9:
        return "CALL   %03o" % k, "CALL", None, None
    if op in (0xA, 0xB):
        return "GOTO   %03o" % (w & 0x1FF), "GOTO", None, None
    return "%-6s %02X" % (["MOVLW", "IORLW", "ANDLW", "XORLW"][op - 0xC], k), ["MOVLW", "IORLW", "ANDLW", "XORLW"][op - 0xC], None, None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    data = open(argv[1], "rb").read()
    if len(data) != 0x400:
        print("warning: %d bytes, not 1024" % len(data))
    words = struct.unpack("<%dH" % (len(data) // 2), data)
    if any(w >> 12 for w in words):
        print("warning: words with bits 15-12 set - not the low-byte-first 12-bit layout")
    if "--uses" in argv:
        from collections import Counter
        kinds, files, bits = Counter(), Counter(), Counter()
        for a, w in enumerate(words):
            text, kind, f, b = dis(w)
            kinds[kind] += 1
            if f is not None:
                files[fname(f)] += 1
                if b is not None:
                    bits["%s,%d" % (fname(f), b)] += 1
        print("instruction kinds:", dict(sorted(kinds.items())))
        print("files:", dict(sorted(files.items())))
        print("bits:", dict(sorted(bits.items())))
        return 0
    for a, w in enumerate(words):
        text, kind, f, b = dis(w)
        note = ""
        if f is not None and b is not None and (f, b) in PINS:
            note = "; " + PINS[(f, b)]
        print("%03o  %03X   %04o  %-22s%s" % (a, a, w, text, note))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
