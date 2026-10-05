"""gen_program.py - the program for tb_busfault_dib.v: the SE/30 ROM's
Memory Manager pointer check and its bus-error handler, which completes the
faulted read in software (SE30_PLAN.md 1.18; the MC68030 UM 3ed 8.2.2).

The check is the ROM's own code at $4080E5F2-$4080E618 and the handler the
ROM's at $4080E59C-$4080E5A8, byte for byte, with the bench's additions: a
Lo3Bytes ($31A) of $FFFFFFFF as in 32-bit mode, a store of D0 straight
after the faulting read, a counter of handler entries, and end markers.
The board (compile 41, MODE32 7.5, 32-bit addressing on, 2026-10-05): the
check was given A6 = $BF7F134E, so its read of $38(a6) went to $BF7F1386,
super-slot $B, which has no card: GLUE's UI6 bus-errors it, as the real
PALs would, and the ROM's handler expects that.

    $0000        vectors: SSP $8000 (SP=hex in the environment), PC $1000; vector 2 -> $2000 (unexpected),
                 3 -> $2200, 4 -> $2100, 14 -> $2400, the rest -> $2300
    $1000        the check:
                   move.l  #$FFFFFFFF,$31A.w     Lo3Bytes, 32-bit mode
                   movea.l #A6,a6                the pointer under test
                   move.l  a7,$3010.w            SP before
                   movea.l $8.w,a2               ROM $4080E5F2
                   lea     H(pc),a3              ROM $4080E5F6
                   move.l  a3,$8.w               ROM $4080E5FA
                   move.l  a6,d0                 ROM $4080E5FE
                   and.l   $31a.w,d0             ROM $4080E600
                   movea.l d0,a6                 ROM $4080E604
      READ:        move.l  $38(a6),d0            ROM $4080E606 - faults
                   move.l  d0,$3030.w            (the bench: D0 as the read left it)
                   move.l  a2,$8.w               ROM $4080E60A
                   and.l   $31a.w,d0             ROM $4080E60E
                   sub.l   a6,d0                 ROM $4080E612
                   beq.s   +2                    ROM $4080E614
                   moveq   #$8F,d0               ROM $4080E616 (memAZErr)
                   move.l  d0,$3034.w            (the bench: the check's verdict)
                   move.l  a7,$3018.w            SP after
                   move.l  #$600D0002,$3FF0.w    end: the ROM's path
                   stop    #$2700
      H:           addq.l  #1,$3020.w            (the bench's counter)
                   andi.w  #$FEFF,$A(a7)         ROM $4080E59C: clear DF in the SSW
                   moveq   #-1,d0                ROM $4080E5A2
                   move.l  d0,$2C(a7)            ROM $4080E5A4: the Data Input Buffer
                   rte                           ROM $4080E5A8: complete the read with it
    $2000...     the unexpected-exception stubs: an end marker $DEADxxxx, STOP

Writes program.hex (64K 16-bit words) and layout.txt (the addresses the
bench checks against).  The first argument picks A6: "board" (default) is
the board's $BF7F134E, whose long read at $BF7F1386 is misaligned - two
word cycles on the 32-bit bus; "aligned" is $BF7F1350, one long cycle at
$BF7F1388.
"""
import sys

import os
variant = sys.argv[1] if len(sys.argv) > 1 else "board"
A6 = {"board": 0xBF7F134E, "aligned": 0xBF7F1350}[variant]
MMU = os.environ.get("MMU", "0") == "1"       # the ROM's 32-bit row loaded first
CACHE = os.environ.get("CACHE", "0") == "1"   # CACR $2101, the board's value
SP = int(os.environ.get("SP", "8000"), 16)
INSTR = os.environ.get("INSTR", "cmp")      # cmp: MODE32's RAM check, CMP.L $38(A6),D6 (the board's loop);
                                              # move: the ROM's own check, MOVE.L $38(A6),D0 (completed before 1.18);
                                              # write: MOVE.L D6,$38(A6), the handler says it did the write (DF
                                              # cleared, no DIB): the 68030 runs no second write cycle (UM 8.2.1)
HANDLER = os.environ.get("HANDLER", "zero")   # zero: the ROM's $4080E590 (clr.l the DIB, the one the board ran);
                                              # ones: its $4080E59C (moveq #-1, the pointer-deref check's)     # the initial SSP (7FFE: word-aligned, as 68k code often leaves it)
img = [0] * 65536

def put(addr, words):
    for i, w in enumerate(words):
        img[addr // 2 + i] = w & 0xFFFF

def long(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]

for v in range(256):
    put(4 * v, long(0x2300))
put(0, long(SP))
put(4, long(0x1000))
put(8, long(0x2000))
put(12, long(0x2200))
put(16, long(0x2100))
put(56, long(0x2400))

def stub(addr, code):
    put(addr, [0x21FC] + long(code) + [0x3FF0, 0x4E72, 0x2700])

stub(0x2000, 0xDEAD0002)                          # a bus error before the check installs H
stub(0x2100, 0xDEAD0004)                          # illegal instruction
stub(0x2200, 0xDEAD0003)                          # address error
stub(0x2300, 0xDEADFFFF)                          # anything else
stub(0x2400, 0xDEAD000E)                          # format error (an RTE the kernel refuses)

H = 0x1100
prog = []
prog += [0x21FC] + long(0xFFFFFFFF) + [0x031A]    # move.l #$FFFFFFFF,$31A.w  (only the ROM's variant masks with it)
if MMU:
    # the ROM's 32-bit row ($40803B9A): CRP $7FFF0002 / table, TC $80F04D00
    # (E, PS=15, IS=0, TIA=4, TIB=13); the table is $4083F5A0's sixteen
    # short early-terminating descriptors - $0-$4 U M, $5-$F U M CI.  On the
    # board MODE32's rows at $38E8/$38FC hold exactly this row for both modes
    # (peeked 2026-10-05).
    TABLE = 0x4000
    put(TABLE, sum((long((n << 28) | (0x19 if n < 5 else 0x59)) for n in range(16)), []))
    prog += [0x21FC] + long(0x7FFF0002) + [0x3F00]    # move.l #$7FFF0002,$3F00.w   CRP high
    prog += [0x21FC] + long(TABLE) + [0x3F04]         # move.l #table,$3F04.w       CRP low
    prog += [0xF038, 0x4C00, 0x3F00]                  # pmove $3F00.w,crp
    prog += [0x21FC] + long(0x80F04D00) + [0x3F08]    # move.l #$80F04D00,$3F08.w
    prog += [0xF038, 0x4000, 0x3F08]                  # pmove $3F08.w,tc
if CACHE:
    prog += [0x203C] + long(0x2101)                   # move.l #$2101,d0
    prog += [0x4E7B, 0x0002]                          # movec d0,cacr
prog += [0x21CF, 0x3010]                          # move.l a7,$3010.w
if INSTR == "move":
    prog += [0x2C7C] + long(A6)                       # movea.l #A6,a6
    prog += [0x2478, 0x0008]                          # movea.l $8.w,a2            ROM $4080E5F2
    LEA = 0x1000 + 2 * len(prog)
    prog += [0x47FA, (H - (LEA + 2)) & 0xFFFF]        # lea H(pc),a3               ROM $4080E5F6
    prog += [0x21CB, 0x0008]                          # move.l a3,$8.w             ROM $4080E5FA
    prog += [0x200E]                                  # move.l a6,d0               ROM $4080E5FE
    prog += [0xC0B8, 0x031A]                          # and.l $31a.w,d0            ROM $4080E600
    prog += [0x2C40]                                  # movea.l d0,a6              ROM $4080E604
    READ = 0x1000 + 2 * len(prog)
    prog += [0x202E, 0x0038]                          # move.l $38(a6),d0          ROM $4080E606 - faults
    prog += [0x21C0, 0x3030]                          # move.l d0,$3030.w          (the bench: D0 as the read left it)
    prog += [0x21CA, 0x0008]                          # move.l a2,$8.w             ROM $4080E60A
    prog += [0xC0B8, 0x031A]                          # and.l $31a.w,d0            ROM $4080E60E
    prog += [0x908E]                                  # sub.l a6,d0                ROM $4080E612
    prog += [0x6702]                                  # beq.s +2                   ROM $4080E614
    prog += [0x708F]                                  # moveq #$8F,d0              ROM $4080E616 (memAZErr)
    REG_AFTER = 0x3038                                # (unused)
elif INSTR == "write":
    prog += [0x2C7C] + long(A6)                       # movea.l #A6,a6
    prog += [0x2C0E]                                  # move.l a6,d6
    prog += [0xE9C6, 0x6218]                          # bfextu d6{8:24},d6         (D6 = the low 24 bits, as the check leaves it)
    prog += [0x2478, 0x0008]                          # movea.l $8.w,a2
    prog += [0x21FC] + long(H) + [0x0008]             # move.l #H,$8.w
    READ = 0x1000 + 2 * len(prog)
    prog += [0x2D46, 0x0038]                          # move.l d6,$38(a6)          - faults, a write
    prog += [0x21C6, 0x3030]                          # move.l d6,$3030.w          (the bench: D6, untouched)
    prog += [0x708F]                                  # moveq #$8F,d0              (the bench: a verdict to check the path by)
    prog += [0x48F8, 0x0400, 0x0008]                  # movem.l a2,$8.w
else:
    # MODE32's 32-bit Memory Manager check, RAM $22BE-$231C as peeked from the
    # hung board: the pointer under test in D6 masked to 24 bits by BFEXTU
    # (the "32-bit clean" strip), A6 the raw pointer, the ROM's handler
    # $4080E590 (DIB := 0) armed, then CMP.L $38(A6),D6 - the board's loop.
    prog += [0x2C7C] + long(A6)                       # movea.l #A6,a6             (the routine: movea.l a1,a6; suba.l -4(a0),a6)
    prog += [0x2C0E]                                  # move.l a6,d6               RAM $22EA
    prog += [0xE9C6, 0x6218]                          # bfextu d6{8:24},d6         RAM $22EC
    prog += [0x2478, 0x0008]                          # movea.l $8.w,a2            RAM $22BE
    prog += [0x21FC] + long(H) + [0x0008]             # move.l #H,$8.w             RAM $22C2 (the ROM's $4080E590)
    READ = 0x1000 + 2 * len(prog)
    prog += [0xBCAE, 0x0038]                          # cmp.l $38(a6),d6           RAM $22F0 - faults
    prog += [0x21C6, 0x3030]                          # move.l d6,$3030.w          (the bench: D6 after the compare, unchanged)
    prog += [0x2C46]                                  # movea.l d6,a6              RAM $22F4
    prog += [0x6702]                                  # beq.s +2                   RAM $2312 (via bra $2312)
    prog += [0x708F]                                  # moveq #$8F,d0              RAM $2314 (memAZErr)
    prog += [0x48F8, 0x0400, 0x0008]                  # movem.l a2,$8.w            RAM $2316
prog += [0x21C0, 0x3034]                          # move.l d0,$3034.w          (the bench: the check's verdict)
prog += [0x21CF, 0x3018]                          # move.l a7,$3018.w          SP after
prog += [0x21FC] + long(0x600D0002) + [0x3FF0]    # move.l #$600D0002,$3FF0.w  end: the software's path
prog += [0x4E72, 0x2700]                          # stop #$2700
assert 0x1000 + 2 * len(prog) <= H
put(0x1000, prog)

if INSTR == "write":
    put(H, [0x52B8, 0x3020,                       # addq.l #1,$3020.w
            0x026F, 0xFEFF, 0x000A,               # andi.w #$FEFF,$A(a7)       DF := 0: "the data has been correctly written"
            0x4E73])                              # rte
    DIB = 0
elif HANDLER == "ones":
    put(H, [0x52B8, 0x3020,                       # addq.l #1,$3020.w
            0x026F, 0xFEFF, 0x000A,               # andi.w #$FEFF,$A(a7)       ROM $4080E59C
            0x70FF,                               # moveq #-1,d0               ROM $4080E5A2
            0x2F40, 0x002C,                       # move.l d0,$2C(a7)          ROM $4080E5A4
            0x4E73])                              # rte                        ROM $4080E5A8
    DIB = 0xFFFFFFFF
else:
    put(H, [0x52B8, 0x3020,                       # addq.l #1,$3020.w
            0x026F, 0xFEFF, 0x000A,               # andi.w #$FEFF,$A(a7)       ROM $4080E590
            0x42AF, 0x002C,                       # clr.l $2C(a7)              ROM $4080E596
            0x4E73])                              # rte                        ROM $4080E59A
    DIB = 0

with open("program.hex", "w") as f:
    for w in img:
        f.write("%04x\n" % w)
with open("layout.txt", "w") as f:
    # the register the bench checks after the instruction: MOVE leaves the DIB
    # in D0; CMP leaves D6 as BFEXTU made it, the pointer's low 24 bits
    f.write("%x %x %x %x %x\n" % (READ, H, A6 + 0x38, DIB if INSTR == "move" else (A6 & 0xFFFFFF), 0 if INSTR == "write" else 1))
print("program.hex: %s, INSTR=%s, MMU=%d, CACHE=%d, SP=$%04X, HANDLER=%s, A6=$%08X, read at $%X faults on $%08X, handler $%X" % (variant, INSTR, MMU, CACHE, SP, HANDLER, A6, READ, A6 + 0x38, H))
