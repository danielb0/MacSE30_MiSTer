"""gen_program.py - the programs for tb_cpfpu.v (SE30_PLAN.md 8.9.4, item 7d):
FPU instructions as the 68030 runs them against the MC68882 on the bus,
with the results left in RAM.

    python gen_program.py [b1|b2|full]

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

b2 (stage B2: the operand transfers) - every EA mode the full program
does not reach: (d16,An), (An)+ and -(An) with a word and a byte, a
misaligned double through (d8,An,Xn.W*2), (xxx).L, (d16,PC), byte and
word immediates, a byte into Dn (the low byte only), a dynamic FMOVEM
list, FMOVEM of the three control registers to memory, packed decimal
with a static and a dynamic k-factor (transfer single register), and an
An destination outside the primitive's class (AB, then the F-line).

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
elif MODE == 'b2':
    # stage B2: the operand transfers in the modes and lengths the full
    # program does not reach
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3100)                    # lea $3100.w,a0
    a.emit(0x43F8, 0x3200)                    # lea $3200.w,a1
    a.emit(0x45F8, 0x3160)                    # lea $3160.w,a2
    a.emit(0x47F8, 0x3180)                    # lea $3180.w,a3
    a.emit(0x7405)                            # moveq #5,d2
    a.emit(0x760C)                            # moveq #$0C,d3   (FP2/FP3, predecrement list)
    a.emit(0x7801)                            # moveq #1,d4     (k-factor)
    a.emit([0x2A3C] + L(0x12345678))          # move.l #$12345678,d5
    a.emit(0xF23C, 0x4000, *L(7))             # fmove.l #7,fp0
    a.emit(0xF23C, 0x5880, 0x00FE)            # fmove.b #-2,fp1
    a.emit(0xF23C, 0x5100, 0x012C)            # fmove.w #300,fp2
    a.emit(0xF200, 0x0422)                    # fadd.x fp1,fp0        5.0
    a.emit(0xF228, 0x6000, 0x0010)            # fmove.l fp0,($10,a0)  -> $3110
    a.emit(0xF219, 0x7100)                    # fmove.w fp2,(a1)+     -> $3200, a1 $3202
    a.emit(0xF221, 0x7880)                    # fmove.b fp1,-(a1)     -> $3201, a1 $3201
    a.emit(0x21C9, 0x3004)                    # move.l a1,$3004.w
    a.emit(0xF230, 0x7500, 0x2208)            # fmove.d fp2,(8,a0,d2.w*2) -> $3112, misaligned
    a.emit(0xF239, 0x6400, 0x0000, 0x3120)    # fmove.s fp0,$00003120.l
    a.emit(0xF23A, 0x4980)                    # fmove.x (K15,pc),fp3: the displacement
    a.fix.append((len(a.w), 'K15'))           #   is from its own word, as a branch's
    a.emit(0)
    a.emit(0xF238, 0x6980, 0x3130)            # fmove.x fp3,$3130.w
    a.emit(0xF227, 0xE830)                    # fmovem.x d3,-(a7)     dynamic: FP2, FP3
    a.emit(0xF21F, 0xD00C)                    # fmovem.x (a7)+,fp4/fp5
    a.emit(0xF238, 0x6A00, 0x3140)            # fmove.x fp4,$3140.w
    a.emit(0xF238, 0x6A80, 0x3150)            # fmove.x fp5,$3150.w
    a.emit(0xF212, 0xBC00)                    # fmovem.l fpcr/fpsr/fpiar,(a2)
    a.emit(0xF210, 0x6C02)                    # fmove.p fp0,(a0){#2}
    a.emit(0xF213, 0x7C40)                    # fmove.p fp0,(a3){d4}
    a.emit(0xF205, 0x7880)                    # fmove.b fp1,d5
    a.emit(0x21C5, 0x3008)                    # move.l d5,$3008.w
    a.label('BADEA'); a.emit(0xF20B, 0x6000)  # fmove.l fp0,a3: not data alterable - AB, F-line
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    a.label('K15'); a.emit(0x3FFF, 0x0000, 0xC000, 0x0000, 0x0000, 0x0000)   # 1.5
    p = a.done()
    put(0x1000, p)
    put(4 * 11, L(0x2400))
    put(0x2400, [0x52B8, 0x3010, 0x21EF, 0x0002, 0x3014, 0x31EF, 0x0006, 0x3018,
                 0x58AF, 0x0002, 0x4E73])     # the F-line handler (as b1's)
    expect = [
        (0x3004, 0x00003201, 0xFFFFFFFF),     # A1 after (a1)+ word, -(a1) byte
        (0x3008, 0x123456FE, 0xFFFFFFFF),     # FMOVE.B to D5: the low byte only
        (0x3010, 0x00000001, 0xFFFFFFFF),     # the F-line, once (the An destination)
        (0x3014, a.lab['BADEA'], 0xFFFFFFFF),
        (0x3018, 0x002C0000, 0xFFFF0000),
        (0x3100, 0x00000005, 0xFFFFFFFF),     # FMOVE.P {#2} of 5.0
        (0x3104, 0x00000000, 0xFFFFFFFF),
        (0x3108, 0x00000000, 0xFFFFFFFF),
        (0x3110, 0x00004072, 0xFFFFFFFF),     # the long 5 at $3110, then the double from $3112
        (0x3114, 0xC0000000, 0xFFFFFFFF),
        (0x3118, 0x00000000, 0xFFFF0000),
        (0x3120, 0x40A00000, 0xFFFFFFFF),     # FMOVE.S 5.0 through (xxx).L
        (0x3130, 0x3FFF0000, 0xFFFFFFFF),     # 1.5 through (d16,PC)
        (0x3134, 0xC0000000, 0xFFFFFFFF),
        (0x3138, 0x00000000, 0xFFFFFFFF),
        (0x3140, 0x40070000, 0xFFFFFFFF),     # FP4 = FP2 = 300, through dynamic FMOVEM
        (0x3144, 0x96000000, 0xFFFFFFFF),
        (0x3148, 0x00000000, 0xFFFFFFFF),
        (0x3150, 0x3FFF0000, 0xFFFFFFFF),     # FP5 = FP3 = 1.5
        (0x3154, 0xC0000000, 0xFFFFFFFF),
        (0x3160, 0x00000000, 0xFFFFFFFF),     # FPCR
        (0x3168, 0x00000000, 0xFFFFFFFF),     # FPIAR (no PC was asked for)
        (0x3180, 0x00000005, 0xFFFFFFFF),     # FMOVE.P {D4 = 1} of 5.0
        (0x3184, 0x00000000, 0xFFFFFFFF),
        (0x3188, 0x00000000, 0xFFFFFFFF),
        (0x3200, 0x01FE0000, 0xFFFF0000),     # the word 300, then the byte -2 at $3201
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
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
