#!/usr/bin/env python3
"""What the SE/30 ROM asks of the 68030 PMMU - read from the ROM itself.

Scans the 256KB ROM shared by the Mac II FDHD, IIx, IIcx and SE/30
(checksum $97221136) for every instruction that touches the PMMU or a control
register, and decodes the ROM-resident MMU table that _SwapMMUMode loads into
CRP and TC for 24-bit and 32-bit mode.

WHY THIS EXISTS
    SE30_PLAN.md 1.7 recorded that the TG68K PMMU port makes the MMU registers
    PMOVE-only and traps a MOVEC to them.  Whether the SE/30 ROM ever does
    that is a question the ROM answers directly, and so is the larger one in
    1.8: what geometry, descriptor formats and walker behaviour the ROM
    actually depends on.  Everything printed here is read from the ROM image;
    nothing is taken from an emulator.  SE30_PLAN.md 1.11 records the reading.

WHAT IT KNOWS THAT A DISASSEMBLER DOES NOT
    Capstone's 68k backend decodes coprocessor-ID 0 (the on-chip MMU) as if it
    were the FPU, so PMOVE/PTEST/PFLUSH/PLOAD come out as fmove/ftrap.  The
    F-line decoder below follows the MC68030 UM second-word formats instead.
    MOVEC register codes cover the 68030's own set and the 68040's MMU set, so
    a 040-style MOVEC to TC/ITTx/DTTx/URP/SRP/MMUSR would be reported, not
    silently mis-read.

    Hits are candidates: the scan is at every even offset, so a matching word
    pair inside data or in the middle of another instruction is reported too.
    `scan` prints them all; classify them by reading the surrounding code
    (`dis` does that when capstone is installed).

USAGE
    se30_rom_mmu.py scan  <rom>            every MOVEC and MMU F-line candidate
    se30_rom_mmu.py table <rom>            decode the CRP/TC table and its page tables
    se30_rom_mmu.py dis   <rom> <hex-off> [<hex-len>]   disassemble a window (needs capstone)

The ROM is expected at its physical base $40800000; offsets are file offsets.
"""
import struct
import sys

BASE = 0x40800000

# MOVEC Rc codes.  68030: SFC DFC CACR USP VBR CAAR MSP ISP (MC68030 UM, MOVEC).
# The rest are 68040 MMU registers and must never appear in a 68030 ROM.
RC = {0x000: "SFC", 0x001: "DFC", 0x002: "CACR",
      0x800: "USP", 0x801: "VBR", 0x802: "CAAR", 0x803: "MSP", 0x804: "ISP",
      0x003: "TC(040)", 0x004: "ITT0(040)", 0x005: "ITT1(040)",
      0x006: "DTT0(040)", 0x007: "DTT1(040)",
      0x805: "MMUSR(040)", 0x806: "URP(040)", 0x807: "SRP(040)"}


def w16(rom, o):
    return struct.unpack(">H", rom[o:o + 2])[0]


def w32(rom, o):
    return struct.unpack(">I", rom[o:o + 4])[0]


def mmu_decode(w1, w2):
    """MC68030 cpID=0 F-line: describe the second word, or None if not one."""
    top = w2 >> 13
    rw = "reg->ea" if (w2 >> 9) & 1 else "ea->reg"
    if top == 0 and (w2 & 0x1C00) in (0x0800, 0x0C00) and (w2 & 0x01FF) == 0:
        return "PMOVE TT%d %s" % ((w2 >> 10) & 1, rw)
    if top == 2 and (w2 & 0x00FF) == 0:
        name = {0: "TC", 2: "SRP", 3: "CRP"}.get((w2 >> 10) & 7)
        if name:
            return "PMOVE %s %s%s" % (name, rw, " FD" if (w2 >> 8) & 1 else "")
    if top == 3 and (w2 & 0x1DFF) == 0:
        return "PMOVE MMUSR " + rw
    if top == 1:
        mode = (w2 >> 10) & 7
        if mode == 1:
            return "PLOAD%s fc=%02X" % ("R" if (w2 >> 9) & 1 else "W", w2 & 0x1F)
        if mode in (4, 6):
            return "PFLUSH mode=%d mask=%X fc=%02X" % (mode, (w2 >> 5) & 7, w2 & 0x1F)
        if w2 == 0x2400:
            return "PFLUSHA"
    if top == 4:
        return "PTEST%s level=%d fc=%02X" % ("R" if (w2 >> 9) & 1 else "W",
                                            (w2 >> 10) & 7, w2 & 0x1F)
    return None


def scan(rom):
    print("MOVEC candidates ($4E7A/$4E7B followed by a valid Rc code):")
    for o in range(0, len(rom) - 2, 2):
        op = w16(rom, o)
        if op in (0x4E7A, 0x4E7B):
            ext = w16(rom, o + 2)
            rc = ext & 0xFFF
            if rc in RC:
                d = "MOVEC Rc,Rn" if op == 0x4E7A else "MOVEC Rn,Rc"
                print("  %06X (%08X): %s  %s%d  Rc=$%03X %s" % (
                    o, BASE + o, d, "A" if ext & 0x8000 else "D",
                    (ext >> 12) & 7, rc, RC[rc]))
    print("MMU F-line candidates ($F000-$F03F followed by a valid MMU second word):")
    for o in range(0, len(rom) - 2, 2):
        op = w16(rom, o)
        if (op & 0xFFC0) == 0xF000:
            d = mmu_decode(op, w16(rom, o + 2))
            if d:
                print("  %06X (%08X): %-28s ea=%o w2=%04X" % (
                    o, BASE + o, d, op & 0x3F, w16(rom, o + 2)))


def dec_tc(tc):
    ps = (tc >> 20) & 15
    return ("E=%d SRE=%d FCL=%d PS=%d(%dB) IS=%d TIA=%d TIB=%d TIC=%d TID=%d" % (
        tc >> 31 & 1, tc >> 25 & 1, tc >> 24 & 1, ps, 1 << ps, tc >> 16 & 15,
        tc >> 12 & 15, tc >> 8 & 15, tc >> 4 & 15, tc & 15))


def dec_rp(hi, lo):
    dt = hi & 3
    return "L/U=%d limit=$%04X bit9=%d DT=%d(%s) table=%08X" % (
        hi >> 31 & 1, hi >> 16 & 0x7FFF, hi >> 9 & 1, dt,
        ("invalid", "page", "short table", "long table")[dt], lo)


def dec_short(d):
    flags = "".join(f for f, b in (("WP ", 2), ("U ", 3), ("M ", 4), ("CI ", 6))
                    if d >> b & 1)
    return "DT=%d addr=%08X %s" % (d & 3, d & ~0xFF, flags)


def table(rom, off=0x3B7A):
    """The [MMUType-3][mode] -> {CRP, TC} rows that _SwapMMUMode indexes."""
    print("MMU table at ROM %06X (%08X): rows of CRP(8) + TC(4), 24-bit then 32-bit:"
          % (off, BASE + off))
    tables = []
    for t, mmutype in enumerate(("MMUType 3 (68851)", "MMUType 4 (68030)")):
        for m, mode in enumerate(("24-bit", "32-bit")):
            o = off + t * 0x18 + m * 0xC
            hi, lo, tc = w32(rom, o), w32(rom, o + 4), w32(rom, o + 8)
            print("  %s %s @%08X" % (mmutype, mode, BASE + o))
            print("     CRP %08X%08X  %s" % (hi, lo, dec_rp(hi, lo)))
            print("     TC  %08X          %s" % (tc, dec_tc(tc)))
            if tc >> 31 and (hi & 3) == 2:
                tables.append((lo, 1 << (tc >> 12 & 15), mmutype, mode))
    seen = set()
    for lo, n, mmutype, mode in tables:
        if lo in seen:
            continue
        seen.add(lo)
        if not BASE <= lo < BASE + len(rom):
            print("  level-A table at %08X is not in ROM" % lo)
            continue
        o = lo - BASE
        print("  level-A table at %08X (ROM %06X), %d short descriptors, used by %s %s:"
              % (lo, o, n, mmutype, mode))
        for i in range(n):
            print("    [%2d] %08X  %s" % (i, w32(rom, o + 4 * i), dec_short(w32(rom, o + 4 * i))))


def dis(rom, start, length):
    from capstone import Cs, CS_ARCH_M68K, CS_MODE_M68K_030
    md = Cs(CS_ARCH_M68K, CS_MODE_M68K_030)
    o, end = start, start + length
    while o < end:
        op = w16(rom, o)
        d = mmu_decode(op, w16(rom, o + 2)) if (op & 0xFFC0) == 0xF000 else None
        if d:
            ea, n = op & 0x3F, 4
            if ea == 0x39:
                n = 8
            elif ea in (0x38, 0x3A) or (ea >> 3) in (5, 6):
                n = 6
            print("  %08X  %-24s %s   [F-line, MMU]" % (BASE + o, rom[o:o + n].hex(" ", 2), d))
            o += n
            continue
        ins = next(md.disasm(rom[o:o + 12], BASE + o), None)
        if ins is None:
            print("  %08X  %-24s dc.w" % (BASE + o, rom[o:o + 2].hex()))
            o += 2
            continue
        print("  %08X  %-24s %s %s" % (BASE + o, rom[o:o + ins.size].hex(" ", 2),
                                       ins.mnemonic, ins.op_str))
        o += ins.size


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    rom = open(argv[2], "rb").read()
    if len(rom) != 0x40000 or w32(rom, 0) != 0x97221136:
        print("warning: not the $97221136 256KB ROM (size %d, checksum %08X)"
              % (len(rom), w32(rom, 0)))
    cmd = argv[1]
    if cmd == "scan":
        scan(rom)
    elif cmd == "table":
        table(rom)
    elif cmd == "dis":
        dis(rom, int(argv[3], 16), int(argv[4], 16) if len(argv) > 4 else 0x80)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
