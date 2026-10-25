"""gen_program.py - the program for tb_busfault_irq.v: one exception-raising
instruction run ITER times, an interrupt raised by the bench at a different
clock of every iteration (KNOWN ISSUES 46, SE30_PLAN.md).

The class: an interrupt arriving while an exception is being raised by
anything but the PMMU's page-fault path - an external bus error (GLUE's UI6
timeout on an empty slot; the bus error comes at the END of a long bus
cycle) or an instruction's own trap.  The 68030 ends a bus-errored access
with the bus error and samples interrupts only at instruction boundaries
(UM 3ed 8.1, 8.2): wherever the interrupt arrives, the exception's frame,
the registers and the instruction's outcome are those of the run without
it, and the interrupt is taken once, at a boundary.

    $0000        vectors: SSP $5F00, PC $1000; 2-11, 32-47 -> XH (the
                 exception handler); 25-31 (autovectors) -> IH; the rest -> a stub
    $1000        the loop (below); $3000 variables; $3F80 the interrupt's
                 acknowledge, $3F90 the iteration marker, $3F94 the
                 continuation marker (all watched by the bench); $3FF0 end
    $4000        MMU=1: the ROM's 24-bit table ($40800050, 16 descriptors)
    $6000+64*i   iteration i's record:
                   +0 exceptions taken   +4 interrupts taken
                   +8 the interrupt's stacked PC  +12 its SR.w, format.w
                   +16 exceptions taken before the interrupt
                   +20.. the first exception's frame: SR/PC, PC/format,
                         and by format: (2) the address; ($A/$B) the
                         internal word/SSW, pipe C/B, fault address, DOB;
                         ($B) the stage B address
                   +48 A0  +52 D0  +56 D1  +60 SR at the continuation

The loop, per iteration:
      loop: move.l a7,$3004.w ; clr.l $3008.w ; clr.l $300C.w
            move.l d7,$3F90.w             the marker: the bench's clock 0
            move.w #$2000,sr              interrupts open
            movea.l #A0,a0 ; move.l #$11111111,d0 ; move.l #$BF96,d1 ; moveq #0,d2
            [the shape's prelude]
      F:    the shape's instruction       raises the exception
      Fn:   nop
      C:    move.l d7,$3F94.w ; nop x PAD ; move.w #$2700,sr ; the record
            addq.l #1,d7 ; cmp.l $3014.w,d7 ; bne loop
XH, per HMODE: abort (discard the frame: the SP of the loop, jmp C - what
MacsBug's or a Slot Manager probe's unwinding leaves); rerun (RTE once, then
abort at the second exception: a bus error's DF-set rerun, a trap's return);
complete (bus errors: DF cleared, the DIB $C0DE5EED, RTE - the handler
finishes the access, UM 8.2.2).

Writes program.hex and layout.txt.  Environment: SHAPE, HMODE, MMU, CACHE,
PAD; SHAPELIST=1 prints the shapes.
"""
import os, sys

SHAPE = os.environ.get("SHAPE", "r_movea_l")
HMODE = os.environ.get("HMODE", "abort")
MMU = os.environ.get("MMU", "0") == "1"
CACHE = os.environ.get("CACHE", "0") == "1"
PAD = int(os.environ.get("PAD", "40"))

# the faulting address: empty slot $A.  MMU=1 is the SE/30 in 24-bit mode:
# the ROM's table (IS=8) ignores the top byte - the Pawn's own $10A02E20.
FAULT = 0x10A02E20 if MMU else 0xFA002E20

# shape: (family, prelude words, instruction words, A0 override)
#   family: r read, w write, m read-modify-write, f fetch, t trap
SHAPES = {
    # reads from empty slot space
    "r_movea_l":  ("r", [], [0x2050], None),                      # movea.l (a0),a0   - the Pawn
    "r_cmp_w":    ("r", [], [0xB250], None),                      # cmp.w (a0),d1     - its next
    "r_move_b":   ("r", [], [0x1010], None),                      # move.b (a0),d0
    "r_move_w":   ("r", [], [0x3010], None),                      # move.w (a0),d0
    "r_move_l":   ("r", [], [0x2010], None),                      # move.l (a0),d0
    "r_move_l2":  ("r", [], [0x2010], FAULT + 2),                 # move.l (a0),d0, word-misaligned
    "r_move_l1":  ("r", [], [0x2010], FAULT + 1),                 # move.l (a0),d0, byte-misaligned
    "r_d16":      ("r", [], [0x2028, 0x0038], FAULT - 0x38),      # move.l $38(a0),d0
    "r_abs":      ("r", [], [0x2039, FAULT >> 16, FAULT & 0xFFFF], None),   # move.l (xxx).l,d0
    "r_idx":      ("r", [], [0x2030, 0x2004], FAULT - 4),         # move.l 4(a0,d2.w),d0
    "r_movem":    ("r", [], [0x4CD0, 0x0003], None),              # movem.l (a0),d0-d1
    "r_add":      ("r", [], [0xD090], None),                      # add.l (a0),d0
    "r_tst":      ("r", [], [0x4A50], None),                      # tst.w (a0)
    # writes to empty slot space
    "w_move_b":   ("w", [], [0x1080], None),                      # move.b d0,(a0)
    "w_move_w":   ("w", [], [0x3080], None),                      # move.w d0,(a0)
    "w_move_l":   ("w", [], [0x2080], None),                      # move.l d0,(a0)
    "w_move_l2":  ("w", [], [0x2080], FAULT + 2),                 # move.l d0,(a0), word-misaligned
    "w_d16":      ("w", [], [0x2140, 0x0038], FAULT - 0x38),      # move.l d0,$38(a0)
    "w_clr":      ("w", [], [0x4290], None),                      # clr.l (a0)
    # read-modify-write
    "m_tas":      ("m", [], [0x4AD0], None),                      # tas (a0)
    "m_cas":      ("m", [], [0x0ED0, 0x0040], None),              # cas.l d0,d1,(a0)
    "m_add":      ("m", [], [0xD190], None),                      # add.l d0,(a0)
    # instruction fetch from empty slot space
    "f_jmp":      ("f", [], [0x4ED0], None),                      # jmp (a0)
    "f_jsr":      ("f", [], [0x4E90], None),                      # jsr (a0)
    # an instruction's own exception (the trap part)
    "t_trap":     ("t", [], [0x4E45], None),                      # trap #5
    "t_trapv":    ("t", [0x46FC, 0x2002], [0x4E76], None),        # move #$2002,sr ; trapv
    "t_chk":      ("t", [], [0x4181], None),                      # chk.w d1,d0 (d0 $1111 > $BF96)
    "t_div0":     ("t", [], [0x80C2], None),                      # divu.w d2,d0 (d2 0)
    "t_priv":     ("t", [0x46FC, 0x0000], [0x46FC, 0x2000], None),   # user mode ; move #$2000,sr
    "t_illegal":  ("t", [], [0x4AFC], None),                      # illegal
    "t_aline":    ("t", [], [0xA123], None),                      # an A-line
    "t_fline":    ("t", [], [0xFE00, 0x0000], None),              # an F-line, coprocessor 7 (none)
    "t_trace":    ("t", [0x46FC, 0xA000], [0x5280], None),        # T1 ; addq.l #1,d0 (traced)
    "t_adderr":   ("t", [], [0x4ED0], 0x00001001),                # jmp (a0), a0 odd: address error
}
if os.environ.get("SHAPELIST") == "1":
    for k, v in SHAPES.items():
        print(k, v[0])
    sys.exit(0)
fam, pre, ins, a0o = SHAPES[SHAPE]
A0 = FAULT if a0o is None else a0o
assert HMODE in ("abort", "rerun", "complete")
assert not (HMODE == "complete" and fam in "ft"), "complete is a bus error's"

img = [0] * 65536
def put(addr, words):
    for i, w in enumerate(words):
        img[addr // 2 + i] = w & 0xFFFF
def long(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]

XH, IH, STUB = 0x1800, 0x1A00, 0x1C00
for v in range(256):
    put(4 * v, long(STUB))
put(0, long(0x5F00))
put(4, long(0x1000))
for v in list(range(2, 12)) + list(range(32, 48)):
    put(4 * v, long(XH))
for v in range(25, 32):
    put(4 * v, long(IH))
put(STUB, [0x21FC] + long(0xDEADFFFF) + [0x3FF0, 0x4E72, 0x2700])

starts = []          # every instruction's address: where an interrupt may be taken
class Code:
    def __init__(self, base):
        self.base, self.w = base, []
    def pc(self):
        return self.base + 2 * len(self.w)
    def i(self, *words):
        starts.append(self.pc())
        self.w += [x & 0xFFFF for x in words]

# ---------------------------------------------------------------- the loop
p = Code(0x1000)
if MMU:
    # the ROM's 24-bit row ($40803B7A): TC $80F84500 (E, PS 32K, IS 8, TIA 4,
    # TIB 5 - its sixteen descriptors terminate early); the descriptors of
    # $40800050 copied to RAM ($0-$7: RAM, $8: ROM, $9-$E: slots CI, $F: I/O CI)
    TABLE = 0x4000
    desc = [0x19 | (n << 20) for n in range(8)] + [0x40800019] + \
           [0x59 | ((0xF0 | s) << 24) for s in range(9, 15)] + [0x50F00059]
    put(TABLE, sum((long(d) for d in desc), []))
    p.i(0x21FC, *long(0x7FFF0002), 0x3F00)       # move.l #$7FFF0002,$3F00.w
    p.i(0x21FC, *long(TABLE), 0x3F04)            # move.l #table,$3F04.w
    p.i(0xF038, 0x4C00, 0x3F00)                  # pmove $3F00.w,crp
    p.i(0x21FC, *long(0x80F84500), 0x3F08)       # move.l #$80F84500,$3F08.w
    p.i(0xF038, 0x4000, 0x3F08)                  # pmove $3F08.w,tc
if CACHE:
    p.i(0x203C, *long(0x2101))                   # move.l #$2101,d0
    p.i(0x4E7B, 0x0002)                          # movec d0,cacr
p.i(0x4BF8, 0x6000)                              # lea $6000.w,a5
p.i(0x7E00)                                      # moveq #0,d7
LOOP = p.pc()
p.i(0x21CF, 0x3004)                              # move.l a7,$3004.w
p.i(0x42B8, 0x3008)                              # clr.l $3008.w
p.i(0x42B8, 0x300C)                              # clr.l $300C.w
p.i(0x21C7, 0x3F90)                              # move.l d7,$3F90.w     the marker
p.i(0x46FC, 0x2000)                              # move #$2000,sr
p.i(0x207C, *long(A0))                           # movea.l #A0,a0
p.i(0x203C, *long(0x11111111))                   # move.l #$11111111,d0
p.i(0x223C, *long(0x0000BF96))                   # move.l #$BF96,d1
p.i(0x7400)                                      # moveq #0,d2
for k in range(0, len(pre), 2):
    p.i(*pre[k:k + 2])
F = p.pc()
p.i(*ins)
FN = p.pc()
p.i(0x4E71)                                      # nop
C = p.pc()
p.i(0x21C7, 0x3F94)                              # move.l d7,$3F94.w     the continuation
for _ in range(PAD):
    p.i(0x4E71)                                  # nop: late interrupts land here
p.i(0x46FC, 0x2700)                              # move #$2700,sr
p.i(0x2B48, 48)                                  # move.l a0,48(a5)
p.i(0x2B40, 52)                                  # move.l d0,52(a5)
p.i(0x2B41, 56)                                  # move.l d1,56(a5)
p.i(0x40ED, 62)                                  # move.w sr,62(a5)
p.i(0x2B78, 0x3008, 0)                           # move.l $3008.w,0(a5)
p.i(0x2B78, 0x300C, 4)                           # move.l $300C.w,4(a5)
p.i(0x4BED, 64)                                  # lea 64(a5),a5
p.i(0x5287)                                      # addq.l #1,d7
p.i(0xBEB8, 0x3014)                              # cmp.l $3014.w,d7
p.i(0x6600, (LOOP - (p.pc() + 2)) & 0xFFFF)      # bne.w loop
p.i(0x21FC, *long(0x600D0001), 0x3FF0)           # move.l #$600D0001,$3FF0.w
p.i(0x4E72, 0x2700)                              # stop #$2700
assert p.pc() <= XH
put(p.base, p.w)

# ------------------------------------------- XH: the exception handler
x = Code(XH)
x.i(0x21CC, 0x3040)                              # move.l a4,$3040.w     (the bench: XH entered)
x.i(0x21C6, 0x3044)                              # move.l d6,$3044.w
x.i(0x52B8, 0x3008)                              # addq.l #1,$3008.w
x.i(0x0CB8, 0, 1, 0x3008)                        # cmpi.l #1,$3008.w
SK1 = x.pc(); x.i(0x6600, 0)                     # bne.w out
x.i(0x2B57, 20)                                  # move.l (a7),20(a5)
x.i(0x2B6F, 4, 24)                               # move.l 4(a7),24(a5)
x.i(0x3C2F, 6)                                   # move.w 6(a7),d6
x.i(0xE04E)                                      # lsr.w #8,d6
x.i(0xE84E)                                      # lsr.w #4,d6
x.i(0x0C46, 2)                                   # cmpi.w #2,d6
SK2 = x.pc(); x.i(0x6600, 0)                     # bne.w notfmt2
x.i(0x2B6F, 8, 28)                               # move.l 8(a7),28(a5)
SK3 = x.pc(); x.i(0x6000, 0)                     # bra.w out
NF2 = x.pc()
x.i(0x0C46, 0xA)                                 # cmpi.w #$A,d6
SK4 = x.pc(); x.i(0x6500, 0)                     # blo.w out
x.i(0x2B6F, 8, 28)                               # move.l 8(a7),28(a5)    internal, SSW
x.i(0x2B6F, 12, 32)                              # move.l 12(a7),32(a5)   pipe C, B
x.i(0x2B6F, 16, 36)                              # move.l 16(a7),36(a5)   fault address
x.i(0x2B6F, 24, 40)                              # move.l 24(a7),40(a5)   DOB
x.i(0x0C46, 0xB)                                 # cmpi.w #$B,d6
SK5 = x.pc(); x.i(0x6600, 0)                     # bne.w out
x.i(0x2B6F, 0x24, 44)                            # move.l $24(a7),44(a5)  stage B address
OUT = x.pc()
x.i(0x2878, 0x3040)                              # movea.l $3040.w,a4
x.i(0x2C38, 0x3044)                              # move.l $3044.w,d6
for at in (SK1, SK3, SK4, SK5):
    x.w[(at - XH) // 2 + 1] = (OUT - (at + 2)) & 0xFFFF
x.w[(SK2 - XH) // 2 + 1] = (NF2 - (SK2 + 2)) & 0xFFFF
ABORT = None
if HMODE == "complete":
    x.i(0x026F, 0xFEFF, 0x000A)                  # andi.w #$FEFF,$A(a7)   DF := 0
    x.i(0x2F7C, *long(0xC0DE5EED), 0x002C)       # move.l #$C0DE5EED,$2C(a7)  the DIB
    x.i(0x4E73)                                  # rte
else:
    if HMODE == "rerun":
        x.i(0x0CB8, 0, 2, 0x3008)                # cmpi.l #2,$3008.w
        x.i(0x6402)                              # bhs.s abort
        x.i(0x4E73)                              # rte
    ABORT = x.pc()
    x.i(0x2E78, 0x3004)                          # movea.l $3004.w,a7
    x.i(0x4EF9, *long(C))                        # jmp C
assert x.pc() <= IH
put(XH, x.w)

# ------------------------------------------- IH: the interrupt handler
h = Code(IH)
h.i(0x52B8, 0x300C)                              # addq.l #1,$300C.w
h.i(0x0CB8, 0, 1, 0x300C)                        # cmpi.l #1,$300C.w
BNE = h.pc(); h.i(0x6600)                        # bne.s ack
h.i(0x2B6F, 2, 8)                                # move.l 2(a7),8(a5)     the stacked PC
h.i(0x3B57, 12)                                  # move.w (a7),12(a5)     SR
h.i(0x3B6F, 6, 14)                               # move.w 6(a7),14(a5)    format
h.i(0x2B78, 0x3008, 16)                          # move.l $3008.w,16(a5)  exceptions so far
ACK = h.pc()
h.i(0x21FC, *long(1), 0x3F80)                    # move.l #1,$3F80.w      the acknowledge
h.i(0x4E73)                                      # rte
h.w[(BNE - IH) // 2] = 0x6600 | (ACK - (BNE + 2))
put(IH, h.w)

with open("program.hex", "w") as f:
    for w in img:
        f.write("%04x\n" % w)
with open("layout.txt", "w") as f:
    # F Fn C XH IH fault-address family hmode, then every instruction start
    f.write("%x %x %x %x %x %x %s %s %d\n" % (F, FN, C, XH, IH, A0, fam, HMODE, len(starts)))
    f.write(" ".join("%x" % s for s in starts) + "\n")
print("program.hex: SHAPE=%s (%s) HMODE=%s MMU=%d CACHE=%d A0=$%08X F=$%X C=$%X" % (SHAPE, fam, HMODE, MMU, CACHE, A0, F, C))
