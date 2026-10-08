#!/usr/bin/env python3
"""The mmu16 bench's MODE32 program: MODE32 7.5's own RAM sizing, run on
the core's RTL (tb_mmu16.v with VIA2 and se30_simms).

WHY
    At 16 MB, a cold start under MODE32 Sad Macs on the board (D7 = 3,
    D6 $DAE5D8EC).  MODE32's INIT sizes the two banks itself with RAMSIZ
    forced to 11 (64 MB banks): bank A from 0 and bank B from 64 MB, with
    the routine at $100DE (a complement written at base + k MB + off, the
    base rewritten to beat a floating bus, then a search for an alias in
    the MBs below).  If its answer differs from the ROM's (the bank size
    from the old RAMSIZ, and MemTop), it runs the ROM's RAM test
    ($40802BBC) over the memory it thinks the ROM missed, on a cold start
    only ($B6DB6DB6 at $40000), and remaps the RAM.  On a real SE/30 with
    four 4 MB SIMMs it must find bank A 16 MB and bank B empty: d6
    $01000000, d7 0, against d4 $01000000 and d5 0, and do nothing.

THE PROGRAM (supervisor, from $1000)
    MODE32's code, $FD40-$1016F, copied from the disk image to the same
    addresses (its PC-relative references hold); $FE76, just after the
    decision, patched to JMP (A5); NOP.  VIA2: DDRA $C0, ORA $80 (RAMSIZ 10,
    as the ROM leaves it).  MemTop ($108) $01000000.  Three runs, each
    JSR $FE24 with A4 = VIA2 and A5 = the run's continuation, then D4-D7
    stored at $3000 + 16n: MMU off; 32-bit mode ($40803B9E);
    24-bit mode ($40803B92, last: its alias search bus-errors in slot space) -
    each mode change as _SwapMMUMode makes it.

Writes mode32/program.hex, stop_at.txt, regions.txt (empty), rom.hex.
"""
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "mode32")
DISK = os.environ.get("DISK", "C:/temp/Mac/MiSTer SE30 Backup - 7.10.2026/boo_.vhd")
CODE_FILE = 0xCA8C1C1 - 0x2C0          # the disk offset of address $FD40
CODE_LO, CODE_HI = 0xFD40, 0x10170
ORG, EXC = 0x1000, 0x1E00


def main():
    with open(DISK, "rb") as f:
        f.seek(CODE_FILE)
        code = bytearray(f.read(CODE_HI - CODE_LO))
    # sanity: the sizing entry and the routine, as read on 2026-10-08
    assert code[0xFE24 - CODE_LO:0xFE24 - CODE_LO + 4] == bytes.fromhex("4e7a2002"), "not MODE32 7.5's code"
    assert code[0x100DE - CODE_LO:0x100DE - CODE_LO + 4] == bytes.fromhex("48e71ff8")
    assert code[0xFE76 - CODE_LO:0xFE76 - CODE_LO + 4] == bytes.fromhex("e9c4319a")
    code[0xFE76 - CODE_LO:0xFE76 - CODE_LO + 4] = bytes.fromhex("4ed54e71")    # JMP (A5); NOP

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

    emit(0x13FC, 0x00C0); l32(0x50F02600)            # MOVE.B #$C0,VIA2 DDRA
    emit(0x13FC, 0x0080); l32(0x50F03E00)            # MOVE.B #$80,VIA2 ORA: RAMSIZ 10
    for n, mode in enumerate(("off", "32", "24")):
        if mode != "off":
            emit(0xF038, 0x4000, 0x0CB1)             # PMOVE $0CB1.W,TC: off first
            emit(0x41F9); l32(0x40803B92 if mode == "24" else 0x40803B9E)
            emit(0xF010, 0x4C00)                     # PMOVE (A0),CRP
            emit(0xF028, 0x4000, 0x0008)             # PMOVE 8(A0),TC
        emit(0x2E7C); l32(0x8000)                    # MOVEA.L #$8000,A7
        emit(0x287C); l32(0x50F02000)                # MOVEA.L #VIA2,A4
        emit(0x4BF9); absref("c%d" % n)              # LEA cont,A5
        emit(0x4EB9); l32(0xFE24)                    # JSR MODE32's sizing
        at["c%d" % n] = here()
        for k, reg in enumerate((4, 5, 6, 7)):       # MOVE.L Dn,$3000+16n+4k
            emit(0x23C0 | reg); l32(0x3000 + 16 * n + 4 * k)
    emit(0x2E7C); l32(0x8000)
    at["fin"] = here()
    emit(0x4E72, 0x2700)                             # STOP #$2700
    for i, name in fix:
        w[i], w[i + 1] = at[name] >> 16, at[name] & 0xFFFF
    assert here() <= EXC

    exc = [0x33EF, 0x0006, 0x0000, 0x3F02, 0x23EF, 0x0002, 0x0000, 0x3F04,
           0x33FC, 0x0001, 0x0000, 0x3F00, 0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]
    mem = [0x4E71] * 65536
    mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]
    for v in range(2, 64):
        mem[2 * v], mem[2 * v + 1] = EXC >> 16, EXC & 0xFFFF
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    for i, x in enumerate(exc):
        mem[EXC // 2 + i] = x
    for a in range(0x3000, 0x4000, 2):
        mem[a // 2] = 0
    mem[0xCB0 // 2], mem[0xCB2 // 2], mem[0xCB4 // 2] = 0x0004, 0x0000, 0x0000   # MMUType 4
    mem[0x108 // 2], mem[0x10A // 2] = 0x0100, 0x0000                            # MemTop 16 MB
    for i in range(0, len(code), 2):
        mem[(CODE_LO + i) // 2] = (code[i] << 8) | code[i + 1]

    os.makedirs(OUT, exist_ok=True)
    shutil.copy(os.path.join(HERE, "rom.hex"), os.path.join(OUT, "rom.hex"))
    with open(os.path.join(OUT, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(OUT, "stop_at.txt"), "w") as f:
        f.write("%x 0\n" % at["fin"])
    open(os.path.join(OUT, "regions.txt"), "w").close()
    print("mode32: 3 runs, STOP at $%X" % at["fin"])


if __name__ == "__main__":
    main()
