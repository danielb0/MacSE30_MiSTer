#!/usr/bin/env python3
"""The system bench's video-RAM program (Speedometer's Graphics finding,
SE30_PLAN.md 1.16.3): the CPU's cycles into the SE/30's 8-bit video RAM,
through the kernel, the wrapper, GLUE and se30_video together.

Writes vramtest/program.hex and vramtest/stop_at.txt.

THE PROGRAM (supervisor, from $1000, the instruction cache on as the ROM
leaves it; the data cache off - the ROM's tables make the video CI)
    window 0  MOVE.L D0,(A0)+ ; DBRA   1000 turns into VRAM at $FE000000
              (each long four byte cycles on the 8-bit port)
    window 1  MOVE.B D0,(A0)+ ; DBRA   1000 turns
    window 2  MOVE.L (A0)+,D2 ; DBRA   1000 turns
    Each window between marker writes to $30B0+8w and $30B4+8w; the bench
    times the windows and every VRAM cycle in them.  Then STOP.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vramtest")
ORG = 0x1000
VRAM = 0xFE000000


def main():
    w = []
    def pc(): return ORG + 2 * len(w)
    def marker(a): w.extend([0x23C0, a >> 16, a & 0xFFFF])            # MOVE.L D0,(a).L
    w.extend([0x7001, 0x4E7B, 0x0002])                                 # MOVEQ #1,D0; MOVEC D0,CACR: EI
    w.extend([0x203C, 0x5555, 0xAAAA])                                 # MOVE.L #$5555AAAA,D0
    for k, op in enumerate((0x20C0, 0x10C0, 0x2418)):                  # MOVE.L D0,(A0)+ / MOVE.B D0,(A0)+ / MOVE.L (A0)+,D2
        w.extend([0x41F9, VRAM >> 16, VRAM & 0xFFFF])                  # LEA VRAM,A0
        w.extend([0x323C, 999])                                        # MOVE.W #999,D1
        marker(0x30B0 + 8 * k)
        if pc() & 2:
            w.append(0x4E71)                                           # NOP: the loop on a long
        w.extend([op, 0x51C9, 0xFFFC])                                 # loop: op; DBRA D1,loop
        marker(0x30B4 + 8 * k)
    stop_at = pc()
    w.extend([0x4E72, 0x2700])                                         # STOP #$2700
    mem = [0x4E71] * 65536
    mem[0], mem[1] = 0x0000, 0x0800
    mem[2], mem[3] = 0x0000, ORG
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "program.hex"), "w", newline="\n") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(OUT, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n%d\n" % (stop_at, len(w)))
    print("vram program: %d words, STOP at $%X" % (len(w), stop_at))


if __name__ == "__main__":
    main()
