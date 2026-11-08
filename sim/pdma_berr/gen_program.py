"""gen_program.py - the program for tb_pdma_berr.v: NetBSD's ncrscsi data-in
moves (sys/arch/mac68k/dev/mac68k5380.c do_ncr5380_drq_intr, netbsd-11:
"#define R4 *long_data++ = *long_drq++") reading the SE/30's SCSI handshake
window $50006000 a long at a time, and a bus-error handler that does what
NetBSD's nofault/longjmp path needs: it records the frame and resumes
elsewhere with the SP restored (no RTE).

    $0000   vectors: SSP $8000, PC $1000; vector 2 -> H, the rest -> $2300
    $1000   move.l  a7,$3010.w          SP before
            movea.l #$50006000,a0       ncr_5380_with_drq
            movea.l #$5000,a1           the buffer
            moveq   #7,d1               8 longs = 32 bytes
    MOVE:   move.l  (a0)+,(a1)+         R4
            dbra    d1,MOVE
            move.l  #$600D0001,$3FF0.w  end: no bus error
            stop    #$2700
    H:      addq.l  #1,$3020.w          handler entries
            move.l  $2(a7),$3024.w      the frame's PC
            move.w  $6(a7),$3028.w      format / vector offset
            move.w  $A(a7),$302A.w      SSW
            move.l  $10(a7),$302C.w     the data cycle fault address
            move.l  a0,$3030.w          A0 as the fault left it
            move.l  a1,$3034.w          A1
            movea.l $3010.w,a7          longjmp: the SP before
            move.l  #$600D0002,$3FF0.w  end: the handler's path
            stop    #$2700
Writes program.hex and layout.txt (MOVE's address).
"""
import os
MMU = os.environ.get("MMU", "0") == "1"   # NetBSD-style: the port through a translated, cache-inhibited KVA
LOG = 0xE0006000 if MMU else 0x50006000   # the logical address of ncr_5380_with_drq
img = [0] * 65536
def put(a, ws):
    for i, w in enumerate(ws): img[a // 2 + i] = w & 0xFFFF
def long(v): return [(v >> 16) & 0xFFFF, v & 0xFFFF]
H = 0x1100
for v in range(256): put(4 * v, long(0x2300))
put(0, long(0x8000)); put(4, long(0x1000)); put(8, long(H))
put(0x2300, [0x21FC] + long(0xDEADFFFF) + [0x3FF0, 0x4E72, 0x2700])
p = []
if MMU:
    # TC $80F04D00 (E, PS 15... as the ROM's 32-bit row: IS 0, TIA 4, TIB 13),
    # CRP -> sixteen early-terminating short descriptors: identity for
    # $0-$D (U M; $5 CI), and $E -> $50000000 (U M CI): logical $E0006000 is
    # the handshake window, as NetBSD's IOBase mapping makes it
    TABLE = 0x4000
    for n in range(16):
        d = (n << 28) | (0x59 if n == 5 else 0x19)
        if n == 0xE: d = 0x50000000 | 0x59
        put(TABLE + 4 * n, long(d))
    p += [0x21FC] + long(0x7FFF0002) + [0x3F00]    # move.l #$7FFF0002,$3F00.w
    p += [0x21FC] + long(TABLE) + [0x3F04]         # move.l #table,$3F04.w
    p += [0xF038, 0x4C00, 0x3F00]                  # pmove $3F00.w,crp
    p += [0x21FC] + long(0x80F04D00) + [0x3F08]    # move.l #$80F04D00,$3F08.w
    p += [0xF038, 0x4000, 0x3F08]                  # pmove $3F08.w,tc
if os.environ.get("CACHE", "0") == "1":
    p += [0x203C] + long(0x2101)                   # move.l #$2101,d0
    p += [0x4E7B, 0x0002]                          # movec d0,cacr
p += [0x21CF, 0x3010]                       # move.l a7,$3010.w
p += [0x207C] + long(LOG)                   # movea.l #ncr_5380_with_drq,a0
p += [0x227C] + long(0x5000)                # movea.l #$5000,a1
p += [0x7207]                               # moveq #7,d1
MOVE = 0x1000 + 2 * len(p)
p += [0x22D8]                               # move.l (a0)+,(a1)+
p += [0x51C9, (MOVE - (0x1000 + 2 * len(p) + 2)) & 0xFFFF]   # dbra d1,MOVE
p += [0x21FC] + long(0x600D0001) + [0x3FF0, 0x4E72, 0x2700]
put(0x1000, p)
h = []
h += [0x52B8, 0x3020]                       # addq.l #1,$3020.w
h += [0x21EF, 0x0002, 0x3024]               # move.l 2(a7),$3024.w
h += [0x31EF, 0x0006, 0x3028]               # move.w 6(a7),$3028.w
h += [0x31EF, 0x000A, 0x302A]               # move.w $A(a7),$302A.w
h += [0x21EF, 0x0010, 0x302C]               # move.l $10(a7),$302C.w
h += [0x21C8, 0x3030]                       # move.l a0,$3030.w
h += [0x21C9, 0x3034]                       # move.l a1,$3034.w
h += [0x2E78, 0x3010]                       # movea.l $3010.w,a7
h += [0x21FC] + long(0x600D0002) + [0x3FF0, 0x4E72, 0x2700]
put(H, h)
with open("program.hex", "w") as f:
    for w in img: f.write("%04x\n" % w)
with open("layout.txt", "w") as f: f.write("%x %x\n" % (MOVE, LOG))
