#!/usr/bin/env python3
"""The instruction probe's program (tb_insn_probe.v; SE30_PLAN.md KNOWN ISSUES 20).

A/UX's jump-table loader - the code startmac builds on its stack ($7FF2B0-
$7FF500 on the board, 2026-10-14) - loses D1/A1 with no fault, cache on or
off.  Its unusual instructions, each run here on the kernel with operands
chosen to tell a right result from the plausible wrong ones, the result
registers and the CCR stored to slots from $3000, the expected values worked
out here from the MC68030 UM (and M68000PRM) semantics:

  CMPA.W A2,A2       the "fits in 16 bits" idiom: the source word sign-extended
                     to 32 bits and compared with the whole register
  SUBQ.W #8,A0       word-sized on an address register: all 32 bits, CCR kept
  ADDQ.W #8,A3
  ADDA.W (d8,PC,D0.W),A0 / MOVE.W (d8,PC,D0.W),-(A1) / ADD.W (d8,PC,D0.W),D3
  SUBA.L A1,A2, MOVEA.L -(A0),A1, MOVE.W -(A0),D1
  BSET.B #0,7(A0)    Z from the bit before it is set
  MOVEM.L D1/D5-D7/A1/A3 to and from the stack around a BSR/RTS (the
                     relocator's save across its callback)

Writes program.hex (64K words) and expect.txt ({slot} {value} {mask} {what}).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ORG, SLOTS, END = 0x1000, 0x3000, 0x3FFC
w = []
expect = []
slot = [SLOTS]


def here():
    return ORG + 2 * len(w)


def emit(*ws):
    w.extend(x & 0xFFFF for x in ws)


def l32(v):
    emit(v >> 16, v)


def store_reg(code, what, want, mask=0xFFFFFFFF):
    """MOVE.L <reg>,abs.l: code is the 23C0+reg opcode."""
    emit(code); l32(slot[0])
    expect.append((slot[0], want & 0xFFFFFFFF, mask, what))
    slot[0] += 4


def store_ccr(what, want):
    emit(0x40C7)                       # MOVE.W SR,D7
    emit(0x0287); l32(0x1F)            # ANDI.L #$1F,D7: the CCR's five flags
    emit(0x23C7); l32(slot[0])         # MOVE.L D7,slot
    expect.append((slot[0], want, 0xFFFFFFFF, what))
    slot[0] += 4


def movel_imm(op, v):
    emit(op); l32(v)


A = {0: 0x207C, 1: 0x227C, 2: 0x247C, 3: 0x267C}            # MOVEA.L #imm,An
D = {0: 0x203C, 1: 0x223C, 3: 0x263C, 7: 0x2E3C}            # MOVE.L #imm,Dn
SA = {0: 0x23C8, 1: 0x23C9, 2: 0x23CA, 3: 0x23CB, 7: 0x23CF}  # MOVE.L An,abs.l
SD = {0: 0x23C0, 1: 0x23C1, 3: 0x23C3, 5: 0x23C5, 6: 0x23C6}  # MOVE.L Dn,abs.l

emit(0x46FC, 0x2700)                   # MOVE.W #$2700,SR
CACR = int(os.environ.get("CACR", "0"), 0)
emit(0x203C); l32(CACR)                # MOVE.L #CACR,D0 (run_wrapper.sh's CACR; the bare kernel has no caches)
emit(0x4E7B, 0x0002)                   # MOVEC D0,CACR
emit(0x4E71)

# ---- CMPA.W A2,A2 (B4CA)
for v, ccr, why in ((0x00012345, 0x00, "CMPA.W A2,A2, A2=$00012345: not equal (Z clear)"),
                    (0x00002345, 0x04, "CMPA.W A2,A2, A2=$00002345: equal (Z set)"),
                    (0xFFFF8000, 0x04, "CMPA.W A2,A2, A2=$FFFF8000: equal"),
                    (0x00008000, 0x01, "CMPA.W A2,A2, A2=$00008000: $8000 - $FFFF8000 borrows (C set only)")):
    emit(0x44FC, 0x0000)               # MOVE #0,CCR
    movel_imm(A[2], v)
    emit(0xB4CA)
    store_ccr(why, ccr)

# ---- SUBQ.W #8,A0 (5148) / ADDQ.W #8,A3 (504B): 32 bits, CCR untouched
emit(0x44FC, 0x0015)                   # MOVE #$15,CCR: X N V C set
movel_imm(A[0], 0x00010004)
emit(0x5148)
store_ccr("SUBQ.W #8,A0 leaves the CCR ($15)", 0x15)
store_reg(SA[0], "SUBQ.W #8,A0 from $00010004: $0000FFFC (all 32 bits)", 0x0000FFFC)
movel_imm(A[3], 0x0001FFFC)
emit(0x504B)
store_reg(SA[3], "ADDQ.W #8,A3 from $0001FFFC: $00020004", 0x00020004)

# ---- the PC-relative indexed operands, a table placed after a BRA
movel_imm(D[0], 2)                     # index: the table's second word
movel_imm(A[0], 0x00020000)
tbl_bra = len(w); emit(0x6000, 0)      # BRA.W over the table (fixed below)
tbl = here()
emit(0x1234, 0xFFF0, 0x0100, 0x8001)   # the table: words at +0, +2, +4, +6
w[tbl_bra + 1] = (here() - (ORG + 2 * tbl_bra + 2)) & 0xFFFF
ext = here() + 2                       # ADDA.W (d8,PC,D0.W),A0: the brief word's address is the PC base
emit(0xD0FB, (tbl - ext) & 0xFF)       # brief: D0.W, scale 1, d8
store_reg(SA[0], "ADDA.W (d8,PC,D0.W),A0: $00020000 + sext($FFF0) = $0001FFF0", 0x0001FFF0)
movel_imm(A[1], 0x00003100)
ext = here() + 2
emit(0x333B, (tbl - ext) & 0xFF)       # MOVE.W (d8,PC,D0.W),-(A1)
store_reg(SA[1], "MOVE.W (d8,PC,D0.W),-(A1): A1 = $30FE", 0x000030FE)
movel_imm(D[0], 4)
movel_imm(D[3], 0x0000FF00)
ext = here() + 2
emit(0xD67B, (tbl - ext) & 0xFF)       # ADD.W (d8,PC,D0.W),D3
store_ccr("ADD.W ... ,D3: Z C X set ($15)", 0x15)
store_reg(SD[3], "ADD.W (d8,PC,D0.W),D3: $FF00 + $0100 = $0000 (word), the high word kept", 0x00000000)

# ---- SUBA.L, MOVEA.L -(A0), MOVE.W -(A0)
movel_imm(A[2], 0x00341300)
movel_imm(A[1], 0x00341162)
emit(0x95C9)                           # SUBA.L A1,A2
store_reg(SA[2], "SUBA.L A1,A2: $341300 - $341162 = $19E", 0x0000019E)

# ---- the relocator's save across its callback: MOVEM.L D1/D5-D7/A1/A3,-(A7);
#      BSR (the callback trashes them); MOVEM.L (A7)+,...
movel_imm(0x2E7C, 0x00008000)          # MOVEA.L #$8000,A7
movel_imm(D[1], 0x00000004)
movel_imm(A[1], 0x00341162)
movel_imm(A[3], 0x007FF338)
emit(0x48E7, 0x4750)                   # MOVEM.L D1/D5-D7/A1/A3,-(A7)
emit(0x5449)                           # ADDQ.W #2,A1
cb_bsr = len(w); emit(0x6100, 0)       # BSR.W callback (fixed below)
emit(0x4CDF, 0x0AE2)                   # MOVEM.L (A7)+,D1/D5-D7/A1/A3
store_reg(SD[1], "MOVEM restore across the callback: D1 = 4", 0x00000004)
store_reg(SA[1], "MOVEM restore: A1 = $341162", 0x00341162)
store_reg(SA[3], "MOVEM restore: A3 = $7FF338", 0x007FF338)
store_reg(SA[7], "MOVEM restore: A7 back to $8000", 0x00008000)
emit(0xD3C1)                           # ADDA.L D1,A1 - the loop's next step
store_reg(SA[1], "ADDA.L D1,A1: $341166", 0x00341166)
done_bra = len(w); emit(0x6000, 0)     # BRA.W the end
cb = here()
w[cb_bsr + 1] = (cb - (ORG + 2 * cb_bsr + 2)) & 0xFFFF
movel_imm(D[1], 0xDEADBEEF)            # the callback: trash every saved register
movel_imm(A[1], 0x5C06100A)
movel_imm(A[3], 0x11111111)
emit(0x7AFF, 0x7CFE, 0x7EFD)           # MOVEQ to D5, D6, D7
emit(0x48E7, 0x0880)                   # MOVEM.L D4/A0,-(A7)   (the board's callback's own save)
emit(0x4CDF, 0x0110)                   # MOVEM.L (A7)+,D4/A0
emit(0x4E75)                           # RTS
w[done_bra + 1] = (here() - (ORG + 2 * done_bra + 2)) & 0xFFFF

# ---- BSET.B #0,7(A0): Z from the old bit
movel_imm(A[0], 0x00003800)
emit(0x44FC, 0x0000)                   # MOVE #0,CCR (X too: BSET leaves it)
emit(0x08E8, 0x0000, 0x0007)           # BSET.B #0,7(A0)
store_ccr("BSET.B #0,7(A0) on $00: Z set", 0x04)
emit(0x44FC, 0x0000)
emit(0x08E8, 0x0000, 0x0007)
store_ccr("BSET.B #0,7(A0) again: Z clear", 0x00)

# ---- the end marker
emit(0x23FC); l32(0x600D600D); l32(END)   # MOVE.L #$600D600D,END
stop_at = here()
emit(0x4E72, 0x2700)                      # STOP #$2700 (sim/predec_fault's harness stops on its fetch)
emit(0x60FE)

mem = [0] * 65536
mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]
for v in range(2, 64):
    mem[2 * v], mem[2 * v + 1] = 0x0000, 0x2000            # every exception -> $2000
mem[0x2000 // 2:0x2000 // 2 + 6] = [0x23FC, 0xBAD0, 0xBAD0, 0x0000, END >> 16 and 0, END & 0xFFFF]
mem[0x2000 // 2:0x2000 // 2 + 7] = [0x23FC, 0xBAD0, 0xBAD0, 0x0000, END & 0xFFFF, 0x60FE, 0]
for i, x in enumerate(w):
    mem[ORG // 2 + i] = x
assert here() < 0x2000
with open(os.path.join(HERE, "program.hex"), "w") as f:
    for x in mem:
        f.write("%04x\n" % x)
with open(os.path.join(HERE, "expect.txt"), "w") as f:
    for a, v, m, what in expect:
        f.write("%08x %08x %s\n" % (a, v, what))
with open(os.path.join(HERE, "stop_at.txt"), "w") as f:
    f.write("%x %d\n" % (stop_at, len(expect)))
with open(os.path.join(HERE, "listing.bin"), "wb") as f:
    f.write(b"".join(x.to_bytes(2, "big") for x in mem[ORG // 2:0x2000 // 2]))
print("insn_probe: %d checks, program $%X-$%X" % (len(expect), ORG, here()))
