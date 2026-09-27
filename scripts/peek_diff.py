#!/usr/bin/env python3
"""Diff a JTAG memory peek of the ROM image against the ROM file.

    quartus_stp -t scripts/read_probes.tcl peek 200000 64 > peek.txt
    python scripts/peek_diff.py peek.txt [rom file]

The peek prints "  <longword address>: <longword>" lines (SE30_PLAN.md 3.8
item 18); the ROM image lives at controller longword $200000 (byte
$800000), so a peeked longword at $200000 + k is the ROM file's bytes
4k .. 4k+3, big-endian.  Each wrong longword is classified:
  doubled      one of the true words repeated - the read capture took the
               same word twice (late: the second word for both; early: the
               first)
  neighbour    the true longword of an address +-1 .. +-4 longwords away -
               an address error (a column bit) rather than a data one
  bits         otherwise: the differing bit numbers, which name DQ pins
Read the same range twice: a wrong word that changes between the two is the
read; one that stays is the image (or a stable address error).
"""
import re
import sys

ROM = r"C:\temp\Mac\ROMS\256KB ROMs\1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM"
ROM_LW = 0x200000                      # the ROM image's first longword address in the controller's space


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rom = open(sys.argv[2] if len(sys.argv) > 2 else ROM, "rb").read()
    n_lw = len(rom) // 4

    def true_lw(k):
        return int.from_bytes(rom[4 * k:4 * k + 4], "big") if 0 <= k < n_lw else None

    lines = open(sys.argv[1]).read().splitlines()
    total = wrong = 0
    for line in lines:
        m = re.match(r"\s*([0-9A-Fa-f]{6}):\s*([0-9A-Fa-f]{8})", line)
        if not m:
            continue
        a, d = int(m.group(1), 16), int(m.group(2), 16)
        k = a - ROM_LW
        t = true_lw(k)
        if t is None:
            print("%06X: %08X   (outside the ROM image)" % (a, d))
            continue
        total += 1
        if d == t:
            continue
        wrong += 1
        hi, lo = t >> 16, t & 0xFFFF
        verdict = None
        if d == (lo << 16 | lo):
            verdict = "doubled: the second word twice (a late capture)"
        elif d == (hi << 16 | hi):
            verdict = "doubled: the first word twice (an early capture)"
        else:
            for off in (1, -1, 2, -2, 4, -4):
                if true_lw(k + off) == d:
                    verdict = "neighbour: the true longword at %+d (an address error)" % off
                    break
        if verdict is None:
            bits = [i for i in range(32) if (d ^ t) >> i & 1]
            verdict = "bits %s differ (DQ pins %s)" % (bits, sorted(set(b % 16 for b in bits)))
        print("%06X: read %08X, ROM %08X   %s" % (a, d, t, verdict))
    print("%d longwords compared, %d wrong" % (total, wrong))
    return 1 if wrong else 0


if __name__ == "__main__":
    sys.exit(main())
