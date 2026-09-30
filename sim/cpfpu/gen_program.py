"""gen_program.py - the program for tb_cpfpu.v (SE30_PLAN.md 8.9.4, item 7d):
FPU instructions as the 68030 runs them against the MC68882 on the bus,
one of each dialog the kernel must carry, with the results left in RAM.

    $0000   vectors: SSP $8000, PC $1000; vector v -> $2000 + 16v, a stub
            that writes $DEAD00vv to $3FF0 and stops (an F-line is $DEAD000B)
    $1000   moveq   #3,d0
            lea     $3100.w,a0
            fnop                          cpBcc: condition, null CA=0
            fmove.l #0,fpcr               cpGEN: evaluate-and-transfer #imm
            fmove.l d0,fp0                cpGEN: evaluate-and-transfer Dn (CA=1, B/W/L)
            fadd.x  fp0,fp0               cpGEN: register to register
            fmove.d fp0,(a0)              cpGEN: store, $3208 CA=0, to memory
            fmove.s #1.5,fp1              cpGEN: #imm, CA=0 form $1504
            fmul.x  fp1,fp0
            fmove.l fp0,d1                cpGEN: store to Dn
            move.l  d1,$3000.w
            fmovem.x fp0/fp1,-(a7)        transfer multiple, predecrement
            fmovem.x (a7)+,fp2/fp3        transfer multiple, postincrement
            move.l  a7,$3004.w
            ftst.x  fp0
            fbgt.w  T                     cpBcc taken
            move.l  #$BAD,$3008.w
    T:      move.l  #$600D,$3008.w
            fmove.x fp2,$3010.w           store X with an abs.W after the command
            fmove.x fp3,$3020.w
            fsave   -(a7)                 cpSAVE: an idle frame
            move.l  (a7),$300C.w
            frestore (a7)+                cpRESTORE
            move.l  a7,$3030.w
            move.l  #$600D0001,$3FF0.w
            stop    #$2700

Writes program.hex (64K 16-bit words) and expect.txt (address, value,
mask - the results the bench checks).
"""

img = [0] * 65536


def put(addr, words):
    for i, w in enumerate(words):
        img[addr // 2 + i] = w & 0xFFFF


def L(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]


# vectors and their stubs
for v in range(256):
    put(4 * v, L(0x2000 + 16 * v))
    put(0x2000 + 16 * v, [0x21FC] + L(0xDEAD0000 | v) + [0x3FF0, 0x4E72, 0x2700])
put(0, L(0x8000))
put(4, L(0x1000))

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
p += [0x21FC] + L(0xBAD) + [0x3008]            # move.l #$BAD,$3008.w
p += [0x21FC] + L(0x600D) + [0x3008]           # T: move.l #$600D,$3008.w
p += [0xF238, 0x6900, 0x3010]                  # fmove.x fp2,$3010.w
p += [0xF238, 0x6980, 0x3020]                  # fmove.x fp3,$3020.w
p += [0xF327]                                  # fsave -(a7)
p += [0x21D7, 0x300C]                          # move.l (a7),$300C.w
p += [0xF35F]                                  # frestore (a7)+
p += [0x21CF, 0x3030]                          # move.l a7,$3030.w
p += [0x21FC] + L(0x600D0001) + [0x3FF0]       # the end marker
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
print('program: %d words at $1000; %d results' % (len(p), len(expect)))
