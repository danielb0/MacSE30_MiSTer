"""gen_program.py - the programs for tb_cpfpu.v (SE30_PLAN.md 8.9.4, item 7d):
FPU instructions as the 68030 runs them against the MC68882 on the bus,
with the results left in RAM.

    python gen_program.py [b1|full]

Both programs: vectors at $0000 - SSP $8000, PC $1000, vector v -> $2000 +
16v, a stub that writes $DEAD00vv to $3FF0 and stops - except vector 11
(the F-line) in b1, which is a handler; the program at $1000 ends by
writing $600D0001 to $3FF0 and stopping.

b1 (stage B1: cpGEN and cpBcc.W with the null and take-pre primitives -
no operand transfer):
            fnop                          cpBcc: condition, null CA=0 TF=0
            fmovecr.x #$32,fp0            1.0; register destination
            ftst.x  fp0
            fbgt.w  T1                    taken
            move.l  #$BAD1,$3000.w
    T1:     move.l  #$600D1,$3000.w
            fsub.x  fp0,fp0               +0
            fbeq.w  T2                    taken
            move.l  #$BAD2,$3004.w
    T2:     move.l  #$600D2,$3004.w
            fbne.w  B3                    not taken
            move.l  #$600D3,$3008.w
            bra.w   N3
    B3:     move.l  #$BAD3,$3008.w
    N3:     fmovecr.x #$32,fp0
            fsin.x  fp0                   long: null CA=1 re-reads while it runs
            ftst.x  fp0
            fbgt.w  T4
            move.l  #$BAD4,$300C.w
    T4:     move.l  #$600D4,$300C.w
    ILL:    dc.w $F200,$2000              opclass 001: the chip answers $1C0B -
                                          XA, then the F-line, frame $0 at ILL
            move.l  #$600D0001,$3FF0.w
            stop    #$2700
    F-line handler (vector 11):
            addq.l  #1,$3010.w            entries
            move.l  2(a7),$3014.w         the stacked PC
            move.w  6(a7),$3018.w         the format and vector offset
            addq.l  #4,2(a7)              past the two words
            rte

full: the program the bench must run once stage B is whole (operand
transfers, FMOVEM, FSAVE/FRESTORE).

Writes program.hex (64K 16-bit words) and expect.txt (address, value, mask).
"""
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'b1'
img = [0] * 65536


def put(addr, words):
    for i, w in enumerate(words):
        img[addr // 2 + i] = w & 0xFFFF


def L(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]


class Asm:
    """Words with labels; a branch's displacement is from its extension word."""
    def __init__(self, org):
        self.org, self.w, self.lab, self.fix = org, [], {}, []

    def here(self):
        return self.org + 2 * len(self.w)

    def label(self, n):
        self.lab[n] = self.here()

    def emit(self, *ws):
        for x in ws:
            self.w.extend(x if isinstance(x, list) else [x])

    def br(self, op, target):                 # op, then a 16-bit displacement
        self.emit(op)
        self.fix.append((len(self.w), target))
        self.emit(0)

    def done(self):
        for i, t in self.fix:
            self.w[i] = (self.lab[t] - (self.org + 2 * i)) & 0xFFFF
        return self.w


def movel_abs(v, a):                          # move.l #v,a.w
    return [0x21FC] + L(v) + [a]


for v in range(256):
    put(4 * v, L(0x2000 + 16 * v))
    put(0x2000 + 16 * v, [0x21FC] + L(0xDEAD0000 | v) + [0x3FF0, 0x4E72, 0x2700])
put(0, L(0x8000))
put(4, L(0x1000))

if MODE == 'b1':
    a = Asm(0x1000)
    a.emit(0xF280, 0x0000)                    # fnop
    a.emit(0xF200, 0x5C32)                    # fmovecr.x #$32,fp0
    a.emit(0xF200, 0x003A)                    # ftst.x fp0
    a.br(0xF292, 'T1')                        # fbgt.w
    a.emit(movel_abs(0xBAD1, 0x3000))
    a.label('T1'); a.emit(movel_abs(0x600D1, 0x3000))
    a.emit(0xF200, 0x0028)                    # fsub.x fp0,fp0
    a.br(0xF281, 'T2')                        # fbeq.w
    a.emit(movel_abs(0xBAD2, 0x3004))
    a.label('T2'); a.emit(movel_abs(0x600D2, 0x3004))
    a.br(0xF28E, 'B3')                        # fbne.w
    a.emit(movel_abs(0x600D3, 0x3008))
    a.br(0x6000, 'N3')                        # bra.w
    a.label('B3'); a.emit(movel_abs(0xBAD3, 0x3008))
    a.label('N3'); a.emit(0xF200, 0x5C32)     # fmovecr.x #$32,fp0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0
    a.emit(0xF200, 0x003A)                    # ftst.x fp0
    a.br(0xF292, 'T4')                        # fbgt.w
    a.emit(movel_abs(0xBAD4, 0x300C))
    a.label('T4'); a.emit(movel_abs(0x600D4, 0x300C))
    a.label('ILL'); a.emit(0xF200, 0x2000)    # an illegal command word
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    ill = a.lab['ILL']
    # the F-line handler
    put(4 * 11, L(0x2400))
    put(0x2400, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x21EF, 0x0002, 0x3014,      # move.l 2(a7),$3014.w
                 0x31EF, 0x0006, 0x3018,      # move.w 6(a7),$3018.w
                 0x58AF, 0x0002,              # addq.l #4,2(a7)
                 0x4E73])                     # rte
    expect = [
        (0x3000, 0x000600D1, 0xFFFFFFFF),     # FBGT after FMOVECR 1.0: taken
        (0x3004, 0x000600D2, 0xFFFFFFFF),     # FBEQ after FSUB: taken
        (0x3008, 0x000600D3, 0xFFFFFFFF),     # FBNE: not taken
        (0x300C, 0x000600D4, 0xFFFFFFFF),     # FSIN(1.0) > 0: taken
        (0x3010, 0x00000001, 0xFFFFFFFF),     # the F-line handler, once
        (0x3014, ill, 0xFFFFFFFF),            # its frame's PC: the operation word
        (0x3018, 0x002C0000, 0xFFFF0000),     # format 0, vector offset $2C
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),     # the end marker
    ]
else:
    p = []
    p += [0x7003]                                  # moveq #3,d0
    p += [0x41F8, 0x3100]                          # lea $3100.w,a0
    p += [0xF280, 0x0000]                          # fnop (fbf.w *+2)
    p += [0xF23C, 0x9000] + L(0)                   # fmove.l #0,fpcr
    p += [0xF200, 0x4000]                          # fmove.l d0,fp0
    p += [0xF200, 0x0022]                          # fadd.x fp0,fp0
    p += [0xF210, 0x7400]                          # fmove.d fp0,(a0)
    p += [0xF23C, 0x4480] + L(0x3FC00000)          # fmove.s #1.5,fp1
    p += [0xF200, 0x0423]                          # fmul.x fp1,fp0
    p += [0xF201, 0x6000]                          # fmove.l fp0,d1
    p += [0x21C1, 0x3000]                          # move.l d1,$3000.w
    p += [0xF227, 0xE003]                          # fmovem.x fp0/fp1,-(a7)
    p += [0xF21F, 0xD030]                          # fmovem.x (a7)+,fp2/fp3
    p += [0x21CF, 0x3004]                          # move.l a7,$3004.w
    p += [0xF200, 0x003A]                          # ftst.x fp0
    p += [0xF292, 10]                              # fbgt.w T (over the next 8 bytes)
    p += movel_abs(0xBAD, 0x3008)
    p += movel_abs(0x600D, 0x3008)                 # T:
    p += [0xF238, 0x6900, 0x3010]                  # fmove.x fp2,$3010.w
    p += [0xF238, 0x6980, 0x3020]                  # fmove.x fp3,$3020.w
    p += [0xF327]                                  # fsave -(a7)
    p += [0x21D7, 0x300C]                          # move.l (a7),$300C.w
    p += [0xF35F]                                  # frestore (a7)+
    p += [0x21CF, 0x3030]                          # move.l a7,$3030.w
    p += movel_abs(0x600D0001, 0x3FF0)             # the end marker
    p += [0x4E72, 0x2700]                          # stop #$2700
    put(0x1000, p)
    expect = [
        (0x3000, 0x00000009, 0xFFFFFFFF),   # D1: (3 + 3) x 1.5
        (0x3004, 0x00008000, 0xFFFFFFFF),   # A7 after the FMOVEM pair
        (0x3008, 0x0000600D, 0xFFFFFFFF),   # FBGT taken
        (0x300C, 0x1F380000, 0xFFFF0000),   # FSAVE: the idle format word
        (0x3010, 0x40020000, 0xFFFFFFFF),   # FP2 = 9.0 (FP0 through the stack)
        (0x3014, 0x90000000, 0xFFFFFFFF),
        (0x3018, 0x00000000, 0xFFFFFFFF),
        (0x3020, 0x3FFF0000, 0xFFFFFFFF),   # FP3 = 1.5
        (0x3024, 0xC0000000, 0xFFFFFFFF),
        (0x3028, 0x00000000, 0xFFFFFFFF),
        (0x3030, 0x00008000, 0xFFFFFFFF),   # A7 after FSAVE/FRESTORE
        (0x3100, 0x40180000, 0xFFFFFFFF),   # FMOVE.D: 6.0
        (0x3104, 0x00000000, 0xFFFFFFFF),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),   # the end marker
    ]

with open('program.hex', 'w') as f:
    f.write(''.join('%04x\n' % w for w in img))
with open('expect.txt', 'w') as f:
    f.write(''.join('%08x %08x %08x\n' % e for e in expect))
print('program %s: %d words at $1000; %d results' % (MODE, len(p), len(expect)))
