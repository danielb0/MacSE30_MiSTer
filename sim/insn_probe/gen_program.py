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

KNOWN ISSUES 25 (the K25 checks): A/UX's X11 clients' memory-indirect
full-format EAs - xeyes' and xclock's instructions byte for byte, and the
long od, long bd, null bd, pre- and postindexed and no-indirection forms.

Writes program.hex (64K words) and expect.txt ({slot} {value} {mask} {what}).
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ORG, SLOTS, END = 0x1000, 0x3000, 0x3FFC
w = []
expect = []
data = {}                              # address -> longword, preset in memory
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
SD = {0: 0x23C0, 1: 0x23C1, 2: 0x23C2, 3: 0x23C3, 5: 0x23C5, 6: 0x23C6}  # MOVE.L Dn,abs.l

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

# ---- KNOWN ISSUES 25: memory-indirect full-format EAs (UM 2.2, the full
#      extension word), A/UX's X11 clients.  A frame at A6 = $3A00 holds
#      pointers at -4 ($39FC -> $3B00) and +8 ($3A08 -> $3C00); a wrong
#      length runs an extension word as an opcode (the exception marker).
data[0x39FC] = 0x00003B00
data[0x3A08] = 0x00003C00
data[0x3B2A] = 0x2A2A2A2A
data[0x3B2E] = 0x2E2E2E2E
data[0x3B5E] = 0x5E5E5E5E
data[0x3D5E] = 0xCAFEF00D
data[0x3CB4] = 0x800000B4
data[0x3C40] = 0x00003E00             # postindex: [$3C00+$40] -> $3E00
data[0x3E10] = 0x13579BDF             #   + D1 ($8) + od ($8)
data[0x3C48] = 0x2468ACE0             # preindex decoy: read if the index is dropped
data[0x3C50] = 0x00003E80
data[0x3E90] = 0x0F1E2D3C
data[0x3B04] = 0x00003F00             # null bd: [$3B00+4]... (see below)
data[0x3F20] = 0x76543210
data[0x3B00] = 0x00003D00             # the operand of ([-4,A6]): xeyes' pointer to a pointer
data[0x13B20] = 0x01020304            # long od: [$39FC] + $00010020 (beyond 64K)
movel_imm(0x2C7C, 0x00003A00)         # MOVEA.L #$3A00,A6
# the destination form with a distinct source first: [$3B00+$5E] := [$3D00+$5E]
movel_imm(A[0], 0x00003D00)
emit(0x2DA8, 0x005E, 0x0162, 0xFFFC, 0x005E)   # MOVE.L $5E(A0),([-4,A6],$5E)
emit(0x2239); l32(0x3B5E)             # MOVE.L $3B5E,D1
store_reg(SD[1], "K25 MOVE.L $5E(A0),([-4,A6],$5E) with A0=$3D00: [$3B5E] = $CAFEF00D", 0xCAFEF00D)
# xeyes $21354-$21370, as A/UX runs it
emit(0x2076, 0x0161, 0xFFFC)          # MOVEA.L ([-4,A6]),A0
emit(0x2DA8, 0x005E, 0x0162, 0xFFFC, 0x005E)   # MOVE.L $5E(A0),([-4,A6],$5E)
emit(0x2436, 0x0162, 0xFFFC, 0x002E)  # MOVE.L ([-4,A6],$2E),D2
emit(0x2476, 0x0162, 0xFFFC, 0x002A)  # MOVEA.L ([-4,A6],$2A),A2
store_reg(SA[0], "K25 xeyes MOVEA.L ([-4,A6]),A0: [[$39FC]] = $3D00", 0x00003D00)
emit(0x23C2); l32(slot[0])            # MOVE.L D2,slot
expect.append((slot[0], 0x2E2E2E2E, 0xFFFFFFFF, "K25 xeyes MOVE.L ([-4,A6],$2E),D2: $2E2E2E2E")); slot[0] += 4
store_reg(SA[2], "K25 xeyes MOVEA.L ([-4,A6],$2A),A2: $2A2A2A2A", 0x2A2A2A2A)
emit(0x2239); l32(0x3B5E)
store_reg(SD[1], "K25 xeyes self-copy keeps [$3B5E] = $CAFEF00D", 0xCAFEF00D)
# xclock $16B4-$16C0: a branch not taken, then the source form
emit(0x44FC, 0x0000)                  # MOVE #0,CCR: BLT not taken
emit(0x6D00, 0x0040)                  # BLT.W (never: lands in the exception table's way if taken)
emit(0x2036, 0x0162, 0x0008, 0x00B4)  # MOVE.L ([8,A6],$B4),D0
store_ccr("K25 xclock MOVE.L ([8,A6],$B4),D0: N set", 0x08)
store_reg(SD.get(0, 0x23C0), "K25 xclock MOVE.L ([8,A6],$B4),D0: $800000B4", 0x800000B4)
# the other sizes and index forms
emit(0x2036, 0x0163, 0xFFFC, 0x0001, 0x0020)   # MOVE.L ([-4,A6],$00010020.L),D0 - long od
store_reg(SD[0], "K25 ([bd.w,A6],od.l): [$3B00+$10020] = [$13B20] = $01020304", 0x01020304)
emit(0x2036, 0x0172, 0xFFFF, 0xFFFC, 0x005E)   # MOVE.L ([$FFFFFFFC.L,A6],$5E),D0 - long bd
store_reg(SD[0], "K25 ([bd.l,A6],od.w): $CAFEF00D", 0xCAFEF00D)
movel_imm(A[3], 0x00003B04)
emit(0x2033, 0x0152, 0x0020)          # MOVE.L ([A3],$20),D0 - null bd: [$3B04] = $3F00, +$20
store_reg(SD[0], "K25 ([A3],od.w) null bd: [$3F20] = $76543210", 0x76543210)
movel_imm(D[1], 0x00000008)
movel_imm(A[3], 0x00003C00)
emit(0x2033, 0x1926, 0x0040, 0x0008)  # MOVE.L ([$40,A3],D1.L,$8),D0 - postindexed
store_reg(SD[0], "K25 ([$40,A3],D1.L,$8) postindexed: [$3E10] = $13579BDF", 0x13579BDF)
emit(0x2033, 0x1922, 0x0048, 0x0010)  # MOVE.L ([$48,A3,D1.L],$10),D0 - preindexed: [$3C50] = $3E80
store_reg(SD[0], "K25 ([$48,A3,D1.L],$10) preindexed: [$3E90] = $0F1E2D3C", 0x0F1E2D3C)
emit(0x2033, 0x1920, 0x0048)          # MOVE.L ($48,A3,D1.L),D0 - full format, word bd, no memory indirection
store_reg(SD[0], "K25 ($48,A3,D1.L) full format: [$3C50] = $3E80", 0x00003E80)

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
for a, v in data.items():
    mem[a // 2], mem[a // 2 + 1] = v >> 16, v & 0xFFFF
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
