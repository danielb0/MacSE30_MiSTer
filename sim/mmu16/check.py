#!/usr/bin/env python3
"""Compare the mmu16 bench's regions (dump.txt) with the mod-3 test's
expected output: the ROM's fill (D0-D2, three longs a
MOVEM, the tail D0 then D1), then the two XOR passes, each starting with
D1 and D0.  Prints each region's first wrong longword and the count.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
# MOVEM.L d16(PC),D0-D2 at $4080373A: the constants' base depends on which
# extension word counts as the PC, so each candidate is read from the ROM
# and the best fit reported
def candidates():
    rom = [int(l, 16) for l in open(os.path.join(HERE, "rom.hex"))]
    def long_at(a):
        o = a - 0x40800000
        b = b"".join(rom[(o + k) // 4].to_bytes(4, "big") for k in (0, 4, 8, 12))
        k = o % 4
        return [int.from_bytes(b[k + 4 * j:k + 4 * j + 4], "big") for j in range(3)]
    return {hex(base): long_at(base) for base in (0x408037AA, 0x408037AC, 0x408037AE)}


def expected(n, D0, D1, D2):
    x = [(D0, D1, D2)[i % 3] for i in range(n)]
    x[0] ^= D1
    for i in range(1, n):
        x[i] ^= x[i - 1]
    x[0] ^= D0
    for i in range(1, n):
        x[i] ^= x[i - 1]
    return x


def main():
    mem = {}
    for line in open(os.path.join(HERE, "dump.txt")):
        a, v = line.split()
        mem[int(a, 16)] = int(v, 16)
    bad_total = 0
    for line in open(os.path.join(HERE, "regions.txt")):
        s, e = (int(t, 16) for t in line.split())
        best = None
        for base, (d0, d1, d2) in candidates().items():
            x = expected((e - s) // 4, d0, d1, d2)
            b = [(s + 4 * i, mem[s + 4 * i], x[i]) for i in range(len(x)) if mem[s + 4 * i] != x[i]]
            if best is None or len(b) < len(best[1]):
                best = (base, b)
        base, bad = best
        above = [(a, mem[a]) for a in range(e, min(e + 64, 0x1000000), 4) if mem[a] != 0]   # the dump wraps past 16 MB
        msg = "region %08x-%08x: %d wrong (constants from %s)" % (s, e, len(bad), base)
        if bad:
            a, g, w = bad[0]
            msg += ", first at %08x: %08x, expected %08x" % (a, g, w)
        if above:
            msg += "; written above the end: " + ", ".join("%08x=%08x" % t for t in above[:4])
        print(msg)
        bad_total += len(bad) + len(above)
    print("==== CHECK %s" % ("PASS" if bad_total == 0 else "FAIL"))
    return 1 if bad_total else 0


if __name__ == "__main__":
    raise SystemExit(main())
