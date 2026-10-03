#!/usr/bin/env python3
"""The system bench's SCSI handshake bus-error program (SE30_PLAN.md 9.6
item 3): a blind read and a blind write at $50006060 / $50006000 with no
DRQ ever (the bench ties GLUE's scsi_drq low), so GLUE waits and UI6's
timeout bus-errors each access.  A bus-error handler records the frame's
format/vector word (SP+6) and its special status word (SP+$A) in slots at
$3000, restores SP from a saved copy and resumes - so it survives either
frame size, which is the question: UM 8.1.2 builds the short frame ($A) at
an instruction boundary and the long one ($B) during an instruction, and
"data read faults only generate the long bus fault frame" (8.2.2).  The
SE/30 ROM's own handler ($40826B26) always discards 92 bytes ($B).

Writes berrtest/program.hex and berrtest/stop_at.txt.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "berrtest")
ORG = 0x1000
SAVED, CONT, SLOTS = 0x2F00, 0x2F04, 0x3000


def main():
    w = []
    def pc(): return ORG + 2 * len(w)
    def l(v): return [v >> 16, v & 0xFFFF]
    fix = []
    w += [0x21FC, 0, 0, 0x0008]; fix.append((len(w) - 3, 'handler'))       # MOVE.L #handler,$0008.W
    w += [0x45F9] + l(SLOTS)                                                # LEA slots,A2
    for kind in ('read', 'write'):
        w += [0x23FC, 0, 0] + l(CONT); fix.append((len(w) - 4, 'cont_' + kind))   # MOVE.L #cont,(CONT).L
        w += [0x23CF] + l(SAVED)                                            # MOVE.L A7,(SAVED).L
        if kind == 'read':
            w += [0x43F9] + l(0x50006060)                                   # LEA $50006060,A1
            w += [0x2011]                                                   # MOVE.L (A1),D0: blind read
        else:
            w += [0x43F9] + l(0x50006000)                                   # LEA $50006000,A1
            w += [0x203C, 0x1122, 0x3344]                                   # MOVE.L #$11223344,D0
            w += [0x2280]                                                   # MOVE.L D0,(A1): blind write
        w += [0x4E71, 0x4E71]
        globals()['cont_' + kind] = pc()
    stop_at = pc()
    w += [0x4E72, 0x2700]                                                   # STOP #$2700
    handler = pc()
    w += [0x34EF, 0x0006]                                                   # MOVE.W 6(A7),(A2)+: format/vector
    w += [0x34EF, 0x000A]                                                   # MOVE.W $A(A7),(A2)+: SSW
    w += [0x2E79] + l(SAVED)                                                # MOVEA.L (SAVED).L,A7
    w += [0x2079] + l(CONT)                                                 # MOVEA.L (CONT).L,A0
    w += [0x4ED0]                                                           # JMP (A0)
    names = {'handler': handler, 'cont_read': cont_read, 'cont_write': cont_write}
    for i, n in fix:
        w[i], w[i + 1] = names[n] >> 16, names[n] & 0xFFFF
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
    print("berr program: %d words, STOP at $%X, handler $%X" % (len(w), stop_at, handler))


if __name__ == "__main__":
    main()
