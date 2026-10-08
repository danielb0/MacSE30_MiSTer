#!/usr/bin/env python3
"""The mmu16 bench's program (tb_mmu16.v's header): the ROM's mod-3 RAM
test ($40803714) over regions below and above 8 MB, through the PMMU in
32-bit mode as the cold start runs it.

THE PROGRAM (supervisor, from $1000)
    CACR $2001 (EI, WA: the probe deck's reading at the board's failure)
    each mode change as _SwapMMUMode ($40803B2E) makes it: PMOVE $0CB1.W,TC
      first (an odd long read: MMUType 4 in the top byte, so E = 0 and
      translation is off), then PMOVE (A0),CRP; PMOVE 8(A0),TC from the
      ROM's row
    24-bit mode from the row at $40803B92 (MMUType 4), a read of $2000 under it
    32-bit mode from the row at $40803B9E (TC $80F04D00)
    for each run (RUNS below):
      [MMU off: PMOVE $0CB1.W,TC alone; or back on: the 32-bit sequence]
      A7 = A0 = start, A1 = end, D6 = 0; the pushes the ROM's caller
      ($40802BBC) makes - MOVEM.L D0-D7/A0-A6,-(A7), MOVE.W SR,-(A7),
      MOVE.L D0,-(A7) - so the stack sits just below the region as on the
      board; A6 = the return; JMP $40803714 (the ROM image)
      MOVE.L D6,$3000+4n
    STOP #$2700
    exceptions (vectors 2-63, $1E00): the format/vector word and the
    stacked PC to $3F00, then the STOP

Writes program.hex, stop_at.txt ({STOP address} {runs}), regions.txt and
rom.hex (the ROM image as 64K longs).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROM", "/c/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM")
ORG, EXC = 0x1000, 0x1E00

# (start, end, MMU): first the 8 KB of KNOWN ISSUES 13 (the Amiga trapdoor,
# $00DD4000-$00DD5FFF, untranslated before 2026-10-08: D6 $DAE5D8EC)
RUNS = [
    (0x00DD3000, 0x00DD7000, "32"),
    (0x00DE0000, 0x00DE1000, "32"),          # clear of the first: each run's pushes sit below its start
    (0x00100000, 0x00101000, "32"),
    (0x007FF000, 0x00801000, "32"),
    (0x00C00000, 0x00C01000, "off"),
    (0x00DD8000, 0x00DD9000, "32"),
    (0x00FFF000, 0x01000000, "32"),
]


# MMU16_RUNS="start:end:mode,..." (hex addresses) overrides RUNS
if os.environ.get("MMU16_RUNS"):
    RUNS = [(int(a, 16), int(b, 16), m) for a, b, m in (r.split(":") for r in os.environ["MMU16_RUNS"].split(","))]


def rom_path(p):
    if os.name == "nt" and p.startswith("/c/"):
        return "C:/" + p[3:]
    return p


def main():
    w, at, fix = [], {}, []

    def here():
        return ORG + 2 * len(w)

    def emit(*words):
        w.extend(words)

    def l32(v):
        emit((v >> 16) & 0xFFFF, v & 0xFFFF)

    def absref(name):
        fix.append((len(w), name))
        emit(0, 0)

    emit(0x203C); l32(0x2001)                        # MOVE.L #$2001,D0
    emit(0x4E7B, 0x0002)                             # MOVEC D0,CACR
    emit(0xF038, 0x4000, 0x0CB1)                     # PMOVE $0CB1.W,TC (MMUType 4 in the top byte: E=0)
    emit(0x41F9); l32(0x40803B92)                    # LEA 24-bit row,A0
    emit(0xF010, 0x4C00)                             # PMOVE (A0),CRP
    emit(0xF028, 0x4000, 0x0008)                     # PMOVE 8(A0),TC
    emit(0x2039); l32(0x2000)                        # MOVE.L $2000,D0
    mmu = "off"
    for n, (s, e, mode) in enumerate(RUNS):
        if mode != mmu:
            emit(0xF038, 0x4000, 0x0CB1)             # PMOVE $0CB1.W,TC: translation off first, as the ROM
            if mode == "32":
                emit(0x41F9); l32(0x40803B9E)        # LEA 32-bit row,A0
                emit(0xF010, 0x4C00)                 # PMOVE (A0),CRP
                emit(0xF028, 0x4000, 0x0008)         # PMOVE 8(A0),TC
            mmu = mode
        emit(0x2E7C); l32(s)                         # MOVEA.L #start,A7
        emit(0x204F)                                 # MOVEA.L A7,A0
        emit(0x227C); l32(e)                         # MOVEA.L #end,A1
        emit(0x7C00)                                 # MOVEQ #0,D6
        emit(0x48E7, 0xFFFE)                         # MOVEM.L D0-D7/A0-A6,-(A7)
        emit(0x40E7)                                 # MOVE.W SR,-(A7)
        emit(0x2F00)                                 # MOVE.L D0,-(A7)
        emit(0x4DF9); absref("ret%d" % n)            # LEA ret,A6
        emit(0x4EF9); l32(0x40803714)                # JMP the ROM's test
        at["ret%d" % n] = here()
        emit(0x23C6); l32(0x3000 + 4 * n)            # MOVE.L D6,$3000+4n
    emit(0x2E7C); l32(0x8000)                        # MOVEA.L #$8000,A7
    at["fin"] = here()
    emit(0x4E72, 0x2700)                             # STOP #$2700
    for i, name in fix:
        w[i], w[i + 1] = at[name] >> 16, at[name] & 0xFFFF
    assert here() <= EXC

    exc = [0x33EF, 0x0006, 0x0000, 0x3F02,           # MOVE.W 6(A7),$3F02
           0x23EF, 0x0002, 0x0000, 0x3F04,           # MOVE.L 2(A7),$3F04
           0x33FC, 0x0001, 0x0000, 0x3F00,           # MOVE.W #1,$3F00
           0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]   # JMP fin

    mem = [0x4E71] * 65536
    mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]         # SSP, PC
    for v in range(2, 64):
        mem[2 * v], mem[2 * v + 1] = EXC >> 16, EXC & 0xFFFF
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    for i, x in enumerate(exc):
        mem[EXC // 2 + i] = x
    for a in range(0x3000, 0x4000, 2):               # result slots and the exception record: zero
        mem[a // 2] = 0
    mem[0xCB0 // 2], mem[0xCB2 // 2], mem[0xCB4 // 2] = 0x0004, 0x0000, 0x0000   # MMUType ($CB1) = 4

    rom = open(rom_path(ROM), "rb").read()
    assert len(rom) == 262144 and rom[0:4] == bytes.fromhex("97221136"), "not the 97221136 ROM"
    with open(os.path.join(HERE, "rom.hex"), "w") as f:
        for i in range(0, len(rom), 4):
            f.write(rom[i:i + 4].hex() + "\n")
    with open(os.path.join(HERE, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(HERE, "stop_at.txt"), "w") as f:
        f.write("%x %d\n" % (at["fin"], len(RUNS)))
    with open(os.path.join(HERE, "regions.txt"), "w") as f:
        for s, e, _ in RUNS:
            f.write("%08x %08x\n" % (s, e))
    print("mmu16: %d runs, STOP at $%X" % (len(RUNS), at["fin"]))


if __name__ == "__main__":
    main()
