"""gen_program.py - the program for tb_busfault.v: the SE/30 ROM's empty-slot
probe and its bus-error handler, run from RAM (SE30_PLAN.md 5.11 item 5).

The probe is the ROM's own code at $408043EA-$408043F6 and the handler the
ROM's at $40804F28, byte for byte, with two additions the bench needs: a
counter of handler entries at the handler's head, and end markers.

    $0000        vectors: SSP $8000, PC $1000; vector 2 -> $2000 (unexpected),
                 3 -> $2200, 4 -> $2100, 14 -> $2400, the rest -> $2300
    $1000        the probe:
                   lea     $3000.w,a2            the ROM's a2 block
                   move.l  #H,4(a2)              the handler
                   move.l  #C,8(a2)              the continuation
                   movea.l #$F9FFFFFF,a5         slot 9, as the ROM
                   moveq   #N,d7                 the retry count (the ROM: 100)
                   move.l  a7,$3010.w            SP before
                   move.l  $8.w,(a2)             ROM $408043EA
                   move.l  4(a2),$8.w            ROM $408043EE
      PROBE:       move.b  (a5),d1               ROM $408043F4 - faults
                   move.l  (a2),$8.w             ROM $408043F6
                   move.l  #$600D0001,$3FF0.w    end: the read did not fault
                   stop    #$2700
      C:           move.l  a7,$3018.w            SP after the unwind
                   move.l  (a2),$8.w             ROM $40804484
                   move.l  #$600D0002,$3FF0.w    end: the ROM's path
                   stop    #$2700
      H:           addq.l  #1,$3020.w            (the bench's counter)
                   moveq   #0,d0                 ROM $40804F28 ...
                   subq.w  #1,d7
                   bne.s   R
                   move.l  #$FFFFFECC,d0
                   move.w  (a7),d7
                   adda.w  #$5C,a7               discard the 92-byte format $B frame
                   clr.w   -(a7)                 a format-0 frame to C
                   move.l  8(a2),-(a7)
                   move.w  d7,-(a7)
      R:           rte                           re-run the faulted read
    $2000...     the unexpected-exception stubs: an end marker $DEADxxxx, STOP

Writes program.hex (64K 16-bit words) and layout.txt (the addresses the
bench checks against).  N is the first argument (default 3); a second
argument "write" makes the probe a write, move.b d1,(a5): the handler's
RTE with DF set must rerun the write (KNOWN ISSUES 7).
"""
import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3
WRITE = len(sys.argv) > 2 and sys.argv[2] == "write"
img = [0] * 65536

def put(addr, words):
    for i, w in enumerate(words):
        img[addr // 2 + i] = w & 0xFFFF

def long(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]

# vectors
for v in range(256):
    put(4 * v, long(0x2300))
put(0, long(0x8000))
put(4, long(0x1000))
put(8, long(0x2000))
put(12, long(0x2200))
put(16, long(0x2100))
put(56, long(0x2400))

def stub(addr, code):
    put(addr, [0x21FC] + long(code) + [0x3FF0, 0x4E72, 0x2700])

stub(0x2000, 0xDEAD0002)                          # a bus error before the probe installs H
stub(0x2100, 0xDEAD0004)                          # illegal instruction (the board's System Error 3)
stub(0x2200, 0xDEAD0003)                          # address error
stub(0x2300, 0xDEADFFFF)                          # anything else
stub(0x2400, 0xDEAD000E)                          # format error (an RTE the kernel refuses)

H = 0x1100
C = 0x1080
prog = []
prog += [0x45F8, 0x3000]                          # lea $3000.w,a2
prog += [0x257C] + long(H) + [0x0004]             # move.l #H,4(a2)
prog += [0x257C] + long(C) + [0x0008]             # move.l #C,8(a2)
prog += [0x2A7C] + long(0xF9FFFFFF)               # movea.l #$F9FFFFFF,a5
prog += [0x7E00 | N]                              # moveq #N,d7
prog += [0x21CF, 0x3010]                          # move.l a7,$3010.w
prog += [0x24B8, 0x0008]                          # move.l $8.w,(a2)
prog += [0x21EA, 0x0004, 0x0008]                  # move.l 4(a2),$8.w
PROBE = 0x1000 + 2 * len(prog)
prog += [0x1A81 if WRITE else 0x1215]             # move.b d1,(a5) / move.b (a5),d1
prog += [0x21D2, 0x0008]                          # move.l (a2),$8.w
prog += [0x21FC] + long(0x600D0001) + [0x3FF0]    # move.l #$600D0001,$3FF0.w
prog += [0x4E72, 0x2700]                          # stop #$2700
assert 0x1000 + 2 * len(prog) <= C
put(0x1000, prog)

put(C, [0x21CF, 0x3018,                           # move.l a7,$3018.w
        0x21D2, 0x0008,                           # move.l (a2),$8.w
        0x21FC] + long(0x600D0002) + [0x3FF0,     # move.l #$600D0002,$3FF0.w
        0x4E72, 0x2700])                          # stop #$2700

put(H, [0x52B8, 0x3020,                           # addq.l #1,$3020.w
        0x7000,                                   # moveq #0,d0
        0x5347,                                   # subq.w #1,d7
        0x6614,                                   # bne.s R (+$14)
        0x203C, 0xFFFF, 0xFECC,                   # move.l #$FFFFFECC,d0
        0x3E17,                                   # move.w (a7),d7
        0xDEFC, 0x005C,                           # adda.w #$5C,a7
        0x4267,                                   # clr.w -(a7)
        0x2F2A, 0x0008,                           # move.l 8(a2),-(a7)
        0x3F07,                                   # move.w d7,-(a7)
        0x4E73])                                  # R: rte

with open("program.hex", "w") as f:
    for w in img:
        f.write("%04x\n" % w)
with open("layout.txt", "w") as f:
    f.write("%x %x %x %d %d\n" % (PROBE, H, C, N, WRITE))
print("program.hex: N=%d, %s, probe at $%X, handler $%X, continuation $%X" % (N, "write" if WRITE else "read", PROBE, H, C))
