#!/usr/bin/env python3
"""The system bench's trace program: single-stepping, as MacsBug's S and T
commands do it (the audit of 2026-10-07: upstream listed "JMP post-trace
returns to wrong PC" as open, a failure that depended on cumulative state,
so the steps run on the whole bus: the wrapper, the pacing and, with
"cache", the 68030's caches).

MC68030 UM 8.1.7 and Table 8-6: with T1 = 1, T0 = 0 every instruction takes
a trace exception after it completes; vector 9, the six-word format $2
frame: SR, the PC of the NEXT instruction, $2024, the address of the
instruction traced.  A traced STOP does not stop: it loads SR, traces, and
execution continues after it.

Writes <dir>/program.hex, stop_at.txt, count.txt (the number of longs the
handler logs) and want.hex (those longs), where <dir> is tracetest, or
tracecache with the argument "cache" (CACR $2101 before tracing, the
ROM's setting).

THE PROGRAM (supervisor, from $1000; the handler logs to $3400 via A5)
    setup, untraced:  LEA $3400,A5; [CACR $2101]; MOVEQ #0,D2; MOVEQ #0,D3;
                      MOVEQ #2,D1; MOVE #$A700,SR (T1 on)
    traced:           ADD.L D1,D2; LEA $3200,A1; MOVE.L D2,(A1)+;
                      L: ADDQ.W #1,D3; DBRA D1,L (taken twice, then not);
                      BRA.S over an ILLEGAL; CMPI.W #3,D3; BEQ.S over an
                      ILLEGAL (taken); BNE.S (not taken); JSR sub (MOVEQ
                      #5,D4; RTS); JMP over an ILLEGAL; MOVEM.L D1-D4,-(A7);
                      MOVEM.L (A7)+,D1-D4; NOP; STOP #$A700 (traced: no
                      stop); MOVE #$2700,SR (traced: T1 was set at its start)
    end:              eight NOPs (untraced), STOP #$2700
    handler ($1100):  CLR.W (A5)+; MOVE.W 6(A7),(A5)+; MOVE.L 2(A7),(A5)+;
                      MOVE.L 8(A7),(A5)+; RTE - three longs a step:
                      {$0000, format/vector}, the stacked PC, the
                      instruction address
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = len(sys.argv) > 1 and sys.argv[1] == "cache"
OUT = os.path.join(HERE, "tracecache" if CACHE else "tracetest")
ORG, H, LOG = 0x1000, 0x1100, 0x3400


def main():
    w, at = [], {}

    def here():
        return ORG + 2 * len(w)

    def lab(n):
        at[n] = here()

    def emit(*words):
        w.extend(words)

    fix = []                                         # (word index, label, kind)

    def ref(n, kind):
        fix.append((len(w), n, kind))
        w.append(0)
        if kind == "abs":
            w.append(0)

    # setup, untraced
    emit(0x4BF9, LOG >> 16, LOG & 0xFFFF)            # LEA $3400,A5
    if CACHE:
        emit(0x203C, 0x0000, 0x2101)                 # MOVE.L #$2101,D0
        emit(0x4E7B, 0x0002)                         # MOVEC D0,CACR
    emit(0x7400, 0x7600, 0x7202)                     # MOVEQ #0,D2; #0,D3; #2,D1
    emit(0x46FC, 0xA700)                             # MOVE #$A700,SR
    # traced
    lab("a1"); emit(0xD481)                          # ADD.L D1,D2
    lab("a2"); emit(0x43F9, 0x0000, 0x3200)          # LEA $3200,A1
    lab("a3"); emit(0x22C2)                          # MOVE.L D2,(A1)+
    lab("L"); emit(0x5243)                           # ADDQ.W #1,D3
    lab("db"); emit(0x51C9); ref("L", "rel")         # DBRA D1,L
    lab("b1"); emit(0x6002, 0x4AFC)                  # BRA.S over; ILLEGAL
    lab("over"); emit(0x0C43, 0x0003)                # CMPI.W #3,D3
    lab("b2"); emit(0x6702, 0x4AFC)                  # BEQ.S eq; ILLEGAL
    lab("eq"); emit(0x6602)                          # BNE.S (not taken)
    lab("j1"); emit(0x4EB9); ref("sub", "abs")       # JSR sub
    lab("after"); emit(0x4EF9); ref("tgt", "abs")    # JMP tgt
    emit(0x4AFC)                                     # ILLEGAL
    lab("tgt"); emit(0x48E7, 0x7800)                 # MOVEM.L D1-D4,-(A7)
    lab("mm2"); emit(0x4CDF, 0x001E)                 # MOVEM.L (A7)+,D1-D4
    lab("nop"); emit(0x4E71)                         # NOP
    lab("s1"); emit(0x4E72, 0xA700)                  # STOP #$A700 (traced)
    lab("end"); emit(0x46FC, 0x2700)                 # MOVE #$2700,SR (traced)
    lab("pad"); emit(*([0x4E71] * 8))                # untraced: the bench's STOP detection
    lab("fin"); emit(0x4E72, 0x2700)                 # STOP #$2700  (sees its fetch; prefetch must
                                                     # not reach it before the last trace ends)
    lab("sub"); emit(0x7805)                         # MOVEQ #5,D4
    lab("rts"); emit(0x4E75)                         # RTS
    for i, n, kind in fix:
        if kind == "rel":
            w[i] = (at[n] - (ORG + 2 * i)) & 0xFFFF
        else:
            w[i], w[i + 1] = at[n] >> 16, at[n] & 0xFFFF
    assert here() <= H

    # the steps: (the instruction traced, the next one)
    path = ["a1", "a2", "a3", "L", "db", "L", "db", "L", "db", "b1", "over", "b2", "eq",
            "j1", "sub", "rts", "after", "tgt", "mm2", "nop", "s1", "end", "pad"]
    want = []
    for i in range(len(path) - 1):
        want += [0x00002024, at[path[i + 1]], at[path[i]]]

    mem = [0x4E71] * 65536
    mem[0], mem[1] = 0x0000, 0x8000                  # SSP
    mem[2], mem[3] = 0x0000, ORG                     # PC
    mem[0x24 // 2], mem[0x26 // 2] = 0x0000, H       # vector 9: trace
    for v in (2, 3, 4, 8):                           # bus/address error, illegal, privilege: stop
        mem[4 * v // 2], mem[4 * v // 2 + 1] = 0x0000, 0x1180
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    for i, x in enumerate([0x425D, 0x3AEF, 0x0006, 0x2AEF, 0x0002, 0x2AEF, 0x0008, 0x4E73]):
        mem[H // 2 + i] = x
    for i, x in enumerate([0x4E72, 0x2700]):         # an unexpected exception: STOP here
        mem[0x1180 // 2 + i] = x

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(OUT, "stop_at.txt"), "w") as f:
        f.write("%x\n" % at["fin"])
    with open(os.path.join(OUT, "count.txt"), "w") as f:
        f.write("%d\n" % len(want))
    with open(os.path.join(OUT, "want.hex"), "w") as f:
        for x in want:
            f.write("%08x\n" % x)
    print("%s: %d traced steps, %d longs at $%X, STOP at $%X" % (os.path.basename(OUT), len(path) - 1, len(want), LOG, at["fin"]))


if __name__ == "__main__":
    main()
