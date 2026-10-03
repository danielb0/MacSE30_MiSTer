#!/usr/bin/env python3
"""The system bench's write-only program (SE30_PLAN.md 1.17.2): the
instructions whose memory destination a 68000 reads before writing and a
68030 does not - CLR, Scc, MOVE from SR, MOVE from CCR.  The MC68030 UM's
tables list no operand read for any of them: CLR Mem 4(0/1/1) (p. 11-44),
Scc Mem 5(0/1/1) (p. 11-44), MOVE SR,Mem and MOVE CCR,Mem 5(0/1/1)
(p. 11-39).

Writes clrtest/program.hex, clrtest/stop_at.txt and clrtest/count.txt (the
number of writes the program makes into $3100-$31FF).

THE PROGRAM (supervisor, from $1000; A0 = $3100, D0 = 4)
    CLR.B/W/L in (A0), (A0)+, -(A0), 8(A0), 8(A0,D0.W), $3140.W, $3150.L
    ST (A0), 8(A0), $3160.L
    MOVE SR,(A0), MOVE SR,$3170.L, MOVE CCR,(A0)
    then STOP.  Every destination is in $3100-$31FF; the bench counts the
    data cycles there: one write each, no read.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "clrtest")
ORG = 0x1000


def main():
    w = [0x41F9, 0x0000, 0x3100,                                       # LEA $3100,A0
         0x7004]                                                       # MOVEQ #4,D0
    n = 0
    for base in (0x4200, 0x4240, 0x4280):                              # CLR.B, CLR.W, CLR.L
        w += [base | 0x10]                                             # (A0)
        w += [base | 0x18]                                             # (A0)+
        w += [base | 0x20]                                             # -(A0)
        w += [base | 0x28, 0x0008]                                     # 8(A0)
        w += [base | 0x30, 0x0008]                                     # 8(A0,D0.W)
        w += [base | 0x38, 0x3140]                                     # $3140.W
        w += [base | 0x39, 0x0000, 0x3150]                             # $3150.L
        n += 7
    w += [0x50D0, 0x50E8, 0x0008, 0x50F9, 0x0000, 0x3160]             # ST (A0) / 8(A0) / $3160.L
    w += [0x40D0, 0x40F9, 0x0000, 0x3170]                              # MOVE SR,(A0) / $3170.L
    w += [0x42D0]                                                      # MOVE CCR,(A0)
    n += 6
    stop_at = ORG + 2 * len(w)
    w += [0x4E72, 0x2700]                                              # STOP #$2700
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
    with open(os.path.join(OUT, "count.txt"), "w", newline="\n") as f:
        f.write("%d\n" % n)
    print("write-only program: %d words, %d writes, STOP at $%X" % (len(w), n, stop_at))


if __name__ == "__main__":
    main()
