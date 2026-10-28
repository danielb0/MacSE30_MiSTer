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
    $3018        the SR a read's fault stacks (the bench's check)
    $301C        HMODE complete: D0, D1 at the continuation, $3024 = 1 (checked)
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
            [the shape's prelude]          (X-readers: ori #$10,ccr)
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
# class 7: TRACE=1 (T1, every instruction) or 0 (T0, change of flow) set for
# the shape's instruction alone (ori.w to SR, the prelude's last), a trace
# handler on vector 9 (TH) recording each iteration's first trace
TRACE = os.environ.get("TRACE", "")

# the faulting address: empty slot $A.  MMU=1 is the SE/30 in 24-bit mode:
# the ROM's table (IS=8) ignores the top byte - the Pawn's own $10A02E20.
FAULT = 0x10A02E20 if MMU else 0xFA002E20
INV = 0x00203100 if MMU else FAULT
USPV = 0x00103104 if MMU else FAULT + 4          # w_jsr_wp's user stack: its push faults

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
    "r_movem9":   ("r", [], [0x4CD0, 0x0E3F], None),              # movem.l (a0),d0-d5/a1-a3  (KNOWN ISSUES 47)
    "r_movem_w":  ("r", [], [0x4C90, 0x0003], None),              # movem.w (a0),d0-d1
    "r_add":      ("r", [], [0xD090], None),                      # add.l (a0),d0
    "r_tst":      ("r", [], [0x4A50], None),                      # tst.w (a0)
    # X read from the CCR: a junk X stacked would be added in on the rerun
    "r_addx":     ("r", [0x003C, 0x0010, 0x43F8, 0x3100], [0xD388], FAULT + 4),   # ori #$10,ccr ; lea $3100,a1 ; addx.l -(a0),-(a1)
    "r_abcd":     ("r", [0x003C, 0x0010, 0x43F8, 0x3100], [0xC308], FAULT + 1),   # ori #$10,ccr ; lea $3100,a1 ; abcd -(a0),-(a1)
    # writes to empty slot space
    "w_move_b":   ("w", [], [0x1080], None),                      # move.b d0,(a0)
    "w_move_w":   ("w", [], [0x3080], None),                      # move.w d0,(a0)
    "w_move_l":   ("w", [], [0x2080], None),                      # move.l d0,(a0)
    "w_move_l2":  ("w", [], [0x2080], FAULT + 2),                 # move.l d0,(a0), word-misaligned
    "w_d16":      ("w", [], [0x2140, 0x0038], FAULT - 0x38),      # move.l d0,$38(a0)
    "w_clr":      ("w", [], [0x4290], None),                      # clr.l (a0)
    "w_movem":    ("w", [], [0x48D0, 0x0003], None),              # movem.l d0-d1,(a0)
    # read-modify-write
    "m_tas":      ("m", [], [0x4AD0], None),                      # tas (a0)
    "m_cas":      ("m", [], [0x0ED0, 0x0040], None),              # cas.l d0,d1,(a0)
    "m_add":      ("m", [], [0xD190], None),                      # add.l d0,(a0)
    "m_negx":     ("m", [0x003C, 0x0010], [0x4090], None),        # ori #$10,ccr ; negx.l (a0)
    "m_roxl":     ("m", [0x003C, 0x0010], [0xE5D0], None),        # ori #$10,ccr ; roxl.w (a0)
    "m_move":     ("m", [], [0x2090], None),                      # move.l (a0),(a0): a read, then a write
    # locked cycles (class 13): CAS2's second address faults (its first, $3100,
    # is RAM); CAS on a write-protected page (MMU=1: logical $103100, the
    # second megabyte WP) - the read goes out, the locked write faults
    "m_cas2":     ("m", [[0x227C, FAULT >> 16, FAULT & 0xFFFF]],
                   [0x0EFC, 0x8040, 0x90C2], 0x3100),             # movea.l #F,a1 ; cas2.l d0:d2,d1:d3,(a0):(a1)
    "m_cas2a":    ("m", [[0x43F8, 0x3100]], [0x0EFC, 0x8040, 0x90C2], None),  # lea $3100,a1 ; cas2.l, (a0) faults
    "m_cas_wp":   ("m", [], [0x0ED0, 0x0040], 0x00103100 if MMU else None),  # cas.l d0,d1,(a0), (a0) = d0
    "m_tas_wp":   ("m", [], [0x4AD0], 0x00103100 if MMU else None),           # tas (a0)
    "m_add_wp":   ("m", [], [0xD190], 0x00103100 if MMU else None),           # add.l d0,(a0): the write-back faults
    # KNOWN ISSUES 51's class: a write-only instruction's destination on an
    # invalid page (MMU=1: logical $203100, the third megabyte invalid) - the
    # kernel's answered read must not fault as a read; the SSW says write
    "w_clr_inv":  ("w", [], [0x4290], INV),                          # clr.l (a0)
    "w_st_inv":   ("w", [], [0x50D0], INV),                          # st (a0)
    "w_pack_inv": ("w", [[0x227C, (INV + 1) >> 16, (INV + 1) & 0xFFFF]],
                   [0x8348, 0x0000], 0x3106),                        # movea.l #INV+1,a1 ; pack -(a0),-(a1),#0
    # KNOWN ISSUES 53's class: a change of flow whose own write faults - JSR
    # in user mode, its return address to the user stack (MMU=1: the WP
    # megabyte, a write-back fault; MMU=0: the empty slot); traced under T0
    # as well as T1.  The target is the next word (FN)
    "w_jsr_wp":   ("w", [[0x227C, (USPV >> 16) & 0xFFFF, USPV & 0xFFFF], [0x4E61]],
                   [0x4EB8, 0x0000], None),                          # movea.l #USP,a1 ; move a1,usp ; (user) jsr FN.w
    # class 12, MMU=1 only: the Nth access faults - logical $800000-$8FFFFF is
    # RAM (CI) right below empty slot 9 at $900000 (ZONE: $8FFFF0-$8FFFFF)
    "c_cmpm":     ("r", [[0x227C, 0x0090, 0x0000]], [0xB388], 0x8FFFF0),   # cmpm.l (a0)+,(a1)+: the second read
    "c_movem":    ("r", [], [0x4CD0, 0x000F], 0x8FFFF8),                   # movem.l (a0),d0-d3: d2 and d3
    "c_movem_w":  ("w", [], [0x48D0, 0x000F], 0x8FFFF8),                   # movem.l d0-d3,(a0): d2 and d3
    "c_move_mm":  ("w", [[0x227C, 0x0090, 0x0000]], [0x2290], 0x8FFFF0),   # move.l (a0),(a1): the write
    "c_movep":    ("r", [], [0x0148, 0x0000], 0x8FFFFC),                   # movep.l 0(a0),d0: bytes 3 and 4
    "c_cmp2":     ("r", [], [0x04D0, 0x1000], 0x8FFFFC),                   # cmp2.l (a0),d1: the upper bound
    "c_bfext":    ("r", [], [0xE9D0, 0x0200], 0x8FFFFC),                   # bfextu (a0){8:32},d0: the fifth byte
    "c_addx":     ("r", [[0x227C, 0x0090, 0x0004]], [0xD388], 0x8FFFF4),   # addx.l -(a0),-(a1): the destination
    "c_split":    ("r", [], [0x2010], 0x8FFFFE),                           # move.l (a0),d0: its second word
    "c_split_w":  ("w", [], [0x2080], 0x8FFFFE),                           # move.l d0,(a0): its second word
    "c_unpk":     ("w", [[0x227C, 0x0090, 0x0002]], [0x8388, 0x0000], 0x8FFFF4),   # unpk -(a0),-(a1),#0: the word write
    "c_pack":     ("w", [[0x227C, 0x0090, 0x0001]], [0x8348, 0x0000], 0x8FFFF6),   # pack -(a0),-(a1),#0: the byte write
    "c_moves":    ("r", [[0x45F8, 0x0005], [0x4E7B, 0xA000]], [0x0E90, 0x0000], 0x8FFFFE),   # lea 5.w,a2 ; movec a2,sfc ; moves.l (a0),d0: split
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
    # class 7, TRACE only: changes of flow, no exception - each lands on Fn
    "o_bra":      ("o", [], [0x6000, 0x0002], None),              # bra.w Fn
    "o_beq":      ("o", [], [0x6700, 0x0002], None),              # beq.w Fn (Z from moveq #0,d2: taken)
    "o_bne":      ("o", [], [0x6600, 0x0002], None),              # bne.w Fn: not taken
    "o_dbf_t":    ("o", [], [0x51C9, 0x0002], None),              # dbf d1,Fn (d1.w $BF96: taken)
    "o_dbf_nt":   ("o", [], [0x51CA, 0x0002], None),              # dbf d2,Fn (d2.w 0: expires, falls through)
    "o_rts":      ("o", [[0x4878, 0x0000]], [0x4E75], None),      # pea Fn.w ; rts
    "o_movesr":   ("o", [], [0x46FC, 0x0000], None),              # move #(T|$2000),sr: an SR write
}
# under trace: t_trace sets T1 itself; an address error's JMP (t_adderr) is
# not one the UM says completes; T0's traps are TRAP and TRAPV ("instruction
# traps" - CHK's and DIVU's are left to T1)
NOTRACE = {"1": ("t_trace", "t_adderr"), "0": ("t_trace", "t_adderr", "t_chk", "t_div0")}.get(TRACE, ())
if not TRACE:
    NOTRACE = tuple(k for k, v in SHAPES.items() if v[0] == "o")      # the flow shapes are trace's
if os.environ.get("SHAPELIST") == "1":
    for k, v in SHAPES.items():
        if k not in NOTRACE:
            print(k, v[0])
    sys.exit(0)
assert SHAPE not in NOTRACE, "not a shape under TRACE=" + TRACE
fam, pre, ins, a0o = SHAPES[SHAPE]
C12 = SHAPE.startswith("c_")
assert MMU or not C12, "class 12's shapes need MMU=1 (the RAM below slot 9)"
A0 = FAULT if a0o is None else a0o
assert HMODE in ("abort", "rerun", "complete")
assert not (HMODE == "complete" and fam in "fto"), "complete is a bus error's"

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
TH = 0x1D00
if TRACE:
    put(4 * 9, long(TH))
# the SR a read's fault must stack (UM 8.2.2: the CCR before the instruction -
# moveq #0,d2's Z, and X where the prelude sets it); the bench reads $3018
put(0x3018, long((0x0004 if SHAPE == "w_jsr_wp" else 0x2014 if 0x003C in pre else 0x2004) |   # (w_jsr_wp: user mode)
                 {"1": 0x8000, "0": 0x4000}.get(TRACE, 0)))
# HMODE complete: D0 and D1 as the UM fixes them - a completed read's data is
# the DIB ($C0DE5EED, right-justified, sign-extended by the instruction); a
# completed write moves nothing.  The bench checks $301C/$3020 when $3024 is 1
DIB = 0xC0DE5EED
EXPECT = {"r_move_b": (0x111111ED, 0xBF96), "r_move_w": (0x11115EED, 0xBF96),
          "r_move_l": (DIB, 0xBF96), "r_add": ((0x11111111 + DIB) & 0xFFFFFFFF, 0xBF96),
          "r_movem": (DIB, DIB), "r_movem9": (DIB, DIB), "r_movem_w": (0x5EED, 0x5EED),
          "w_move_l": (0x11111111, 0xBF96), "w_movem": (0x11111111, 0xBF96),
          "m_add": (0x11111111, 0xBF96), "m_move": (0x11111111, 0xBF96),
          # a locked cycle's frame with DF cleared says the handler emulated the
          # whole CAS/TAS (UM 8.2.2): nothing of it runs, D0 is the handler's
          "m_cas": (0x11111111, 0xBF96), "m_tas": (0x11111111, 0xBF96),
          "m_cas2": (0x11111111, 0xBF96), "m_cas2a": (0x11111111, 0xBF96),
          "m_cas_wp": (0x11111111, 0xBF96), "m_tas_wp": (0x11111111, 0xBF96), "m_add_wp": (0x11111111, 0xBF96),
          "w_clr_inv": (0x11111111, 0xBF96), "w_st_inv": (0x11111111, 0xBF96), "w_pack_inv": (0x11111111, 0xBF96),
          "w_jsr_wp": (0x11111111, 0xBF96),
          # class 12: the zone's values before the fault, the DIB after it
          "c_cmpm": (0x11111111, 0xBF96), "c_movem": (0x55556666, 0x77778888),
          "c_movem_w": (0x11111111, 0xBF96), "c_move_mm": (0x11111111, 0xBF96),
          "c_movep": (0x7788EDED, 0xBF96), "c_cmp2": (0x11111111, 0xBF96),
          "c_bfext": (0x778888ED, 0xBF96), "c_addx": (0x11111111, 0xBF96),
          # a split operand: the first word from the zone, the rest the DIB's
          # (right-justified, UM 8.2.2)
          "c_split": (0x88885EED, 0xBF96), "c_split_w": (0x11111111, 0xBF96),
          "c_unpk": (0x11111111, 0xBF96), "c_pack": (0x11111111, 0xBF96), "c_moves": (0x88885EED, 0xBF96)}
# class 12: the zone (tb RAM $1FFF0, the CI megabyte's last 16 bytes) and the
# bus accesses each iteration makes to it - each once, the replay's point (an
# I/O access must not repeat); HMODE rerun re-runs them (KNOWN ISSUES 47's
# limit) and is not checked.  The bench reads $3034 when $3038 is 1
ZN = {"c_cmpm": 1, "c_movem": 2, "c_movem_w": 2, "c_move_mm": 1, "c_movep": 2,
      "c_cmp2": 1, "c_bfext": 1, "c_addx": 1, "c_split": 1, "c_split_w": 1,
      "c_unpk": 1, "c_pack": 1, "c_moves": 1}
if C12:
    put(0x1FFF0, long(0x11112222) + long(0x33334444) + long(0x55556666) + long(0x77778888))
    if HMODE != "rerun":
        put(0x3034, long(ZN[SHAPE]) + long(1))
# class 11: the first frame's SSW (DF, RM, RW, SIZE, FC - bits 8-0) and fault
# address as the UM fixes them (8.2.1, Table 8-7): DF set, RM for a locked
# cycle, RW the faulted cycle's, SIZE its operand's (00 long, 01 byte, 10
# word; a misaligned long's first cycle still says four bytes remain, 5.2.4),
# FC 5 (supervisor data).  The bench checks $3028/$302C when $3030 is 1
B, W, L = 1, 2, 0
SSWX = {"r_movea_l": (1, L), "r_cmp_w": (1, W), "r_move_b": (1, B), "r_move_w": (1, W),
        "r_move_l": (1, L), "r_move_l2": (1, L), "r_move_l1": (1, L), "r_d16": (1, L),
        "r_abs": (1, L), "r_idx": (1, L), "r_movem": (1, L), "r_movem9": (1, L),
        "r_movem_w": (1, W), "r_add": (1, L), "r_tst": (1, W), "r_addx": (1, L), "r_abcd": (1, B),
        "w_move_b": (0, B), "w_move_w": (0, W), "w_move_l": (0, L), "w_move_l2": (0, L),
        "w_d16": (0, L), "w_clr": (0, L), "w_movem": (0, L),
        "w_clr_inv": (0, L), "w_st_inv": (0, B), "w_pack_inv": (0, B), "w_jsr_wp": (0, L),
        "m_tas": (1, B), "m_cas": (1, L), "m_add": (1, L), "m_negx": (1, L), "m_roxl": (1, W),
        "m_move": (1, L), "m_cas2": (1, L), "m_cas2a": (1, L), "m_cas_wp": (1, L), "m_tas_wp": (1, B), "m_add_wp": (0 if MMU else 1, L),   # MMU off: the empty slot faults ADD's read
        "c_cmpm": (1, L), "c_movem": (1, L), "c_movem_w": (0, L), "c_move_mm": (0, L),
        "c_movep": (1, B), "c_cmp2": (1, L), "c_bfext": (1, B), "c_addx": (1, L),
        "c_split": (1, W), "c_split_w": (0, W),
        "c_unpk": (0, W), "c_pack": (0, B), "c_moves": (1, W)}
LOCKED = ("m_tas", "m_cas", "m_cas2", "m_cas2a", "m_cas_wp", "m_tas_wp")
if SHAPE in SSWX:
    rw, sz = SSWX[SHAPE]
    ssw = 0x100 | (0x80 if SHAPE in LOCKED else 0) | (rw << 6) | (sz << 4) | (1 if SHAPE == "w_jsr_wp" else 5)   # (user data)
    faddr = {"r_move_l1": FAULT + 1, "r_move_l2": FAULT + 2, "w_move_l2": FAULT + 2}.get(SHAPE, FAULT)
    if SHAPE in ("m_cas_wp", "m_tas_wp", "m_add_wp", "w_jsr_wp") and MMU:
        faddr = 0x00103100
    if SHAPE.endswith("_inv"):
        faddr = INV
    if C12:
        faddr = 0x00900000
    put(0x3028, long(ssw) + long(faddr) + long(1))
if SHAPE == "m_cas_wp":
    put(0x3100, long(0x11111111))                # CAS's compare equal: the write goes out
if HMODE == "complete" and SHAPE in EXPECT:
    put(0x301C, long(EXPECT[SHAPE][0]) + long(EXPECT[SHAPE][1]) + long(1))
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
    desc = [0x19 | (n << 20) | (0x04 if SHAPE in ("m_cas_wp", "m_tas_wp", "m_add_wp", "w_jsr_wp") and n == 1 else 0) for n in range(8)] + [0x00800059 if C12 else 0x40800019] + \
           [0x59 | ((0xF0 | s) << 24) for s in range(9, 15)] + [0x50F00059]
    if SHAPE.endswith("_inv"):
        desc[2] = 0                              # the third megabyte invalid (DT 0)
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
if TRACE:
    p.i(0x42B8, 0x305C)                          # clr.l $305C.w         traces this iteration
p.i(0x21C7, 0x3F90)                              # move.l d7,$3F90.w     the marker
p.i(0x46FC, 0x2000)                              # move #$2000,sr
p.i(0x207C, *long(A0))                           # movea.l #A0,a0
p.i(0x203C, *long(0x11111111))                   # move.l #$11111111,d0
p.i(0x223C, *long(0x0000BF96))                   # move.l #$BF96,d1
p.i(0x7400)                                      # moveq #0,d2
TBIT = {"1": 0x8000, "0": 0x4000}.get(TRACE, 0)
if TRACE and SHAPE == "t_priv":
    pre = [0x46FC, TBIT]                         # move #T,sr: user mode, traced
if pre and isinstance(pre[0], list):              # whole instructions
    for w in pre:
        p.i(*w)
else:                                            # two-word instructions
    for k in range(0, len(pre), 2):
        p.i(*pre[k:k + 2])
if SHAPE == "w_jsr_wp":
    p.i(0x46FC, TBIT | 0x0004)                   # move #(T|Z),sr: user mode, the next instruction traced
elif TRACE and SHAPE != "t_priv":
    p.i(0x007C, TBIT)                            # ori.w #T,sr: the next instruction traced
F = p.pc()
if SHAPE == "w_jsr_wp":
    ins = [0x4EB8, F + 4]                        # jsr FN.w
if SHAPE == "o_rts":                             # pea Fn.w: Fn is the rts's next word
    p.w[(F - 0x1000) // 2 - 3] = F + 2           # (the pea's operand, before the ori)
if SHAPE == "o_movesr":
    ins = [0x46FC, TBIT | 0x2004]                # the SR it has (Z from moveq #0,d2)
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
# a write the PMMU faults after the instruction's last access went to the
# write pending buffer: the frame may name the next instruction, with the SR
# after the instruction (UM 8.1.2: "the instruction that was executing at the
# time the fault was detected ... not necessarily the instruction that
# initiated the bus cycle").  The bench takes either pair: (F, $3018's SR) or
# ($3074, $3078) when $307C is 1
POST_SR = {"w_clr_inv": 0x2004, "w_st_inv": 0x2004, "w_pack_inv": 0x2004,
           "m_add_wp": 0x2000, "w_jsr_wp": 0x0004}   # CLR: Z; ST, PACK: none; ADD $11111111 + 0: none; JSR: user, Z kept
if MMU and SHAPE in POST_SR:
    put(0x3074, long(FN) + long(POST_SR[SHAPE] | TBIT) + long(1))

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
    if SHAPE == "w_jsr_wp":
        x.i(0x0057, 0x2000)                      # ori.w #$2000,(a7)      resume supervisor (the loop's move #$2700,sr)
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

# ------------------------------------------- TH: the trace handler (class 7)
if TRACE:
    t = Code(TH)
    # (only the instruction under test's traces: under T0 the loop's later
    # move #$2700,sr is a traced SR manipulation too)
    t.i(0x0CAF, *long(C), 8)                     # cmpi.l #C,8(a7)       the traced instruction's address
    BC = t.pc(); t.i(0x6400)                     # bcc.s skip
    t.i(0x52B8, 0x305C)                          # addq.l #1,$305C.w     traces this iteration
    t.i(0x0CB8, 0, 1, 0x305C)                    # cmpi.l #1,$305C.w
    BS = t.pc(); t.i(0x6600)                     # bne.s skip            (the first is recorded)
    t.i(0x21EF, 2, 0x3050)                       # move.l 2(a7),$3050.w  the stacked PC
    t.i(0x21EF, 8, 0x3054)                       # move.l 8(a7),$3054.w  the traced instruction's address
    t.i(0x31EF, 6, 0x3058)                       # move.w 6(a7),$3058.w  format/vector
    t.i(0x31D7, 0x305A)                          # move.w (a7),$305A.w   the SR copy
    SKIP = t.pc()
    t.w[(BS - TH) // 2] = 0x6600 | (SKIP - (BS + 2))
    t.w[(BC - TH) // 2] = 0x6400 | (SKIP - (BC + 2))
    t.i(0x0257, 0x3FFF)                          # andi.w #$3FFF,(a7)    no more tracing ...
    t.i(0x0CAF, *long(XH), 2)                    # cmpi.l #XH,2(a7)
    t.i(0x6606)                                  # bne.s out
    t.i(0x026F, 0x3FFF, 12)                      # andi.w #$3FFF,12(a7)  ... nor after a trap's RTE
    t.i(0x4E73)                                  # out: rte
    put(TH, t.w)
    # what the UM fixes (8.1.7): a bus error defers the trace until the
    # instruction resumes and completes - a completed access, never an
    # abort or a rerun into the same fault; a trap's processing comes first
    # (the trace's PC is the handler's); an illegal, unimplemented or
    # privileged instruction is not executed, so not traced; a JMP/JSR is
    # traced before its target's fetch faults.  The frame: format $2, vector
    # $24, the next instruction's PC, the traced instruction's address.
    # The bench reads $3060 count, PC, address, the SR copy's T bits, $3070 = 1
    if fam in "rwmc":
        # (w_jsr_wp: a change of flow, traced under T0 too)
        exp = (1, FN, F, TBIT) if ((TRACE == "1" or SHAPE == "w_jsr_wp") and HMODE == "complete") else (0, 0, 0, 0)
    elif fam == "f":
        exp = (1, A0, F, TBIT)
    elif SHAPE in ("t_trap", "t_trapv", "t_chk", "t_div0"):
        exp = (1, XH, F, 0)
    elif fam == "o":
        # T1 traces each; T0 the changes of flow - a branch taken, DBcc's
        # branch, RTS, an SR write - not a branch or DBcc falling through
        taken = SHAPE not in ("o_bne", "o_dbf_nt")
        exp = (1, FN, F, TBIT) if (TRACE == "1" or taken) else (0, 0, 0, 0)
    else:
        exp = (0, 0, 0, 0)
    put(0x3060, long(exp[0]) + long(exp[1]) + long(exp[2]) + long(exp[3]) + long(1))

with open("program.hex", "w") as f:
    for w in img:
        f.write("%04x\n" % w)
with open("layout.txt", "w") as f:
    # F Fn C XH IH fault-address family hmode, then every instruction start
    f.write("%x %x %x %x %x %x %s %s %d\n" % (F, FN, C, XH, IH, A0, fam, HMODE, len(starts)))
    f.write(" ".join("%x" % s for s in starts) + "\n")
print("program.hex: SHAPE=%s (%s) HMODE=%s MMU=%d CACHE=%d A0=$%08X F=$%X C=$%X" % (SHAPE, fam, HMODE, MMU, CACHE, A0, F, C))
