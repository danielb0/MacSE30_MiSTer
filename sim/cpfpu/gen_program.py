"""gen_program.py - the programs for tb_cpfpu.v (SE30_PLAN.md 8.9.4, item 7d):
FPU instructions as the 68030 runs them against the MC68882 on the bus,
with the results left in RAM.

    python gen_program.py [b1|b2|b3a|b3b|b3c|b4|b5a|b5b|b5c|b5d|mmu|full]

Every program: vectors at $0000 - SSP $8000, PC $1000, vector v -> $2000 +
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

b3a (stage B3: the conditionals' completion) - after an FTST of +1: FScc
to Dn (the low byte only), (An), (An)+, -(An), (d16,An), (xxx).W, (xxx).L
and -(A7) (a byte moves A7 by 2); FDBEQ looping until the counter's low
word is -1 and FDBGT falling through; FTRAPcc with no operand, .W and .L,
false and true (vector 7, frame $2: the next instruction and this one's
address); FBGT.L taken and FBEQ.L not.

b3b (stage B3: frame $9 and its RTE) - take mid-instruction (an FMOVE.B
out of range with OPERR enabled: vector 52; frame $9's scanPC, format
word, instruction address, operation word and tempEA) and a protocol
violation the MPU detects (the bench answers an FNOP's response read with
the reserved $0B00: vector 13, scanPC the displacement word); each handler
clears the chip and returns, and the RTE reads the response CIR again.

b3c (stage B3: interrupts inside a dialog) - the bench raises VIA1's IRQ
at the first come-again ($8900, IA = 1: frame $9, the RTE reading the
response again) and at an FSAVE's not-ready ($01: frame $0 at the FSAVE,
which the RTE starts again); an FSIN's result through the busy save and
restore that follow.

b4 (stage B4: cpSAVE and cpRESTORE) - the reset phase's null frame
through (An) (the reserved word written 0, the next long untouched); an
FDIV by zero with DZ enabled, its pending exception saved in an idle frame
through -(An) (60 bytes, the command image at +4, EXC_PEND active at
+$38), the chip then idle with nothing pending (an FNOP takes nothing);
an idle frame through (d16,An); FRESTORE (An)+ reinstating the exception,
taken by the next FNOP (vector 50, frame $0 at the FNOP - the handler
resets the chip with FRESTORE of a null frame through (xxx).W); FRESTORE
through (d8,An,Xn) and an FSAVE of what it restored; an invalid format
word through (An)+ - the format error (vector 14, frame $0 at the
FRESTORE, An not moved); FRESTORE of a null frame through (d16,PC), then
null frames through (xxx).W and (xxx).L.

b5a (stage B5: no coprocessor) - cpGEN, cpBcc, cpScc, cpSAVE and
cpRESTORE with CpID 2: the initiating access ends in a bus error and the
MPU takes the F-line at the operation word, one CPU-space cycle each.

b5b (stage B5: trace) - under T1 each FPU instruction traced once, a cpGEN
only once the 68882 is done (the trace handler's FSAVE finds it idle), the
bench's IRQ taken at the FSIN's released-while-running null (IA = 1, frame
$9); under T0 only the taken FBcc and the FDBcc's branch traced.

b5c (stage B5: a bus error after the initiating access) - the bench
bus-errors the first access to six addresses inside dialogs (operand
reads and writes, FMOVEM, an extension word's fetch, an FSAVE frame's
write, an FRESTORE frame's read); each long frame's fields are filed and
the RTE goes on from the fault - FADD's sum right, not re-executed.

b5d (the same under the PMMU: page faults) - fails until B5c's PMMU
term is in (plan 8.9.4): the page fault inside FADD's dialog takes the
protocol violation.

mmu (the PMMU through the wrapper) - b5d's tables and walk, an FPU
instruction fetched translated, and page faults on a plain MOVE's read
and write, re-run by the handler; the write must not reach memory before
its fault.

full: the program the bench must run once stage B is whole (operand
transfers, FMOVEM, FSAVE/FRESTORE).

Writes program.hex (64K 16-bit words), expect.txt (address, value, mask) and
inject.txt: the instruction whose first response read the bench answers with
the reserved primitive $0B00 (0 for none), and 1 when the bench raises VIA1's
IRQ inside dialogs (b3c), and the number of CPU-space cycles to anything
but the 68882 the run must make (b5a; all ones: unchecked).
"""
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'b1'
inject = 0                                    # the instruction whose response read the bench answers $0B00
irq = 0                                       # 1: the bench raises VIA1's IRQ inside dialogs (b3c)
cps = 0xFFFFFFFF                              # CPU-space cycles to IDs but 1 (and IACKs) expected; all ones: unchecked
berrs = []                                    # data addresses whose first access the bench bus-errors (b5c)
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

    def br32(self, op, target):               # op, then a 32-bit displacement
        self.emit(op)
        self.fix.append((len(self.w), '=' + target))
        self.emit(0, 0)

    def done(self):
        for i, t in self.fix:
            if t.startswith('='):
                d = (self.lab[t[1:]] - (self.org + 2 * i)) & 0xFFFFFFFF
                self.w[i], self.w[i + 1] = d >> 16, d & 0xFFFF
            else:
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
elif MODE == 'b3a':
    # stage B3a: the conditional instructions' completion - cpScc, cpDBcc,
    # cpTRAPcc, cpBcc.L - after an FTST of +1 (GT true, EQ false)
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3100)                    # lea $3100.w,a0
    a.emit(0x43F8, 0x3104)                    # lea $3104.w,a1
    a.emit(0x45F8, 0x310A)                    # lea $310A.w,a2
    a.emit([0x223C] + L(0x12345600))          # move.l #$12345600,d1
    a.emit([0x243C] + L(0xABCDEFFF))          # move.l #$ABCDEFFF,d2
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF200, 0x003A)                    # ftst.x fp0
    a.emit(0xF241, 0x0012)                    # fsgt d1            low byte FF
    a.emit(0xF242, 0x0001)                    # fseq d2            low byte 00
    a.emit(0xF250, 0x0012)                    # fsgt (a0)          $3100 FF
    a.emit(0xF259, 0x0001)                    # fseq (a1)+         $3104 00, a1 $3105
    a.emit(0xF262, 0x0012)                    # fsgt -(a2)         a2 $3109, $3109 FF
    a.emit(0xF268, 0x000E, 0x0010)            # fsne ($10,a0)      $3110 FF
    a.emit(0xF278, 0x0012, 0x3120)            # fsgt $3120.w       FF
    a.emit(0xF279, 0x0001, 0x0000, 0x3121)    # fseq $00003121.l   00
    a.emit(0xF267, 0x0012)                    # fsgt -(a7)         a7 $7FFE (a byte: 2)
    a.emit(0x21CF, 0x3004)                    # move.l a7,$3004.w
    a.emit(0x31DF, 0x3008)                    # move.w (a7)+,$3008.w
    a.emit(0x21C1, 0x3024)                    # move.l d1,$3024.w
    a.emit(0x21C2, 0x3028)                    # move.l d2,$3028.w
    a.emit(0x21C9, 0x302C)                    # move.l a1,$302C.w
    a.emit(0x21CA, 0x3030)                    # move.l a2,$3030.w
    a.emit(0x7800)                            # moveq #0,d4
    a.emit(0x7602)                            # moveq #2,d3
    a.label('L2'); a.emit(0x5284)             # addq.l #1,d4
    a.emit(0xF24B); a.br(0x0001, 'L2')        # fdbeq d3,L2        false: loops until d3.w = -1
    a.emit(0xF24B); a.br(0x0012, 'BAD')       # fdbgt d3,BAD       true: falls through
    a.emit(0x21C3, 0x300C)                    # move.l d3,$300C.w
    a.emit(0x21C4, 0x3010)                    # move.l d4,$3010.w
    a.emit(0xF27C, 0x0001)                    # ftrapeq            false
    a.emit(0xF27A, 0x0012, 0x1234)            # ftrapgt.w #$1234   true: vector 7
    a.emit(0xF27B, 0x0001, 0x1234, 0x5678)    # ftrapeq.l #...     false
    a.label('TR2'); a.emit(0xF27C, 0x0012)    # ftrapgt            true: vector 7
    a.label('AFT'); a.br32(0xF2D2, 'T5')      # fbgt.l T5          taken
    a.emit(movel_abs(0xBAD5, 0x3034))
    a.label('T5'); a.emit(movel_abs(0x600D5, 0x3034))
    a.br32(0xF2C1, 'BAD')                     # fbeq.l BAD         not taken
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    a.label('BAD'); a.emit(movel_abs(0xBAD0BAD0, 0x3FF0))
    a.emit(0x4E72, 0x2700)
    p = a.done()
    put(0x1000, p)
    for s in range(0x3100, 0x3124, 4):
        put(s, L(0xAAAAAAAA))
    # vector 7 (cpTRAPcc): count, frame PC (the next instruction), format
    # word, instruction address (frame $2)
    put(4 * 7, L(0x2400))
    put(0x2400, [0x52B8, 0x3014, 0x21EF, 0x0002, 0x3018, 0x31EF, 0x0006, 0x301C,
                 0x21EF, 0x0008, 0x3020, 0x4E73])
    expect = [
        (0x3004, 0x00007FFE, 0xFFFFFFFF),     # FScc -(A7): down by 2
        (0x3008, 0xFF000000, 0xFFFF0000),     # ... the byte at the new A7
        (0x300C, 0x0000FFFF, 0xFFFFFFFF),     # FDBEQ ran D3.W down to -1
        (0x3010, 0x00000003, 0xFFFFFFFF),     # ... three passes
        (0x3014, 0x00000002, 0xFFFFFFFF),     # two FTRAPcc taken
        (0x3018, a.lab['AFT'], 0xFFFFFFFF),   # ... the last one's frame PC: the next instruction
        (0x301C, 0x201C0000, 0xFFFF0000),     # ... format $2, offset $1C
        (0x3020, a.lab['TR2'], 0xFFFFFFFF),   # ... its instruction address
        (0x3024, 0x123456FF, 0xFFFFFFFF),     # FSGT D1: the low byte only
        (0x3028, 0xABCDEF00, 0xFFFFFFFF),     # FSEQ D2
        (0x302C, 0x00003105, 0xFFFFFFFF),     # (A1)+ up by 1
        (0x3030, 0x00003109, 0xFFFFFFFF),     # -(A2) down by 1
        (0x3034, 0x000600D5, 0xFFFFFFFF),     # FBGT.L taken
        (0x3100, 0xFFAAAAAA, 0xFFFFFFFF),     # FSGT (A0)
        (0x3104, 0x00AAAAAA, 0xFFFFFFFF),     # FSEQ (A1)+
        (0x3108, 0xAAFFAAAA, 0xFFFFFFFF),     # FSGT -(A2) at $3109
        (0x3110, 0xFFAAAAAA, 0xFFFFFFFF),     # FSNE ($10,A0)
        (0x3120, 0xFF00AAAA, 0xFFFFFFFF),     # (xxx).W FF, (xxx).L 00
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3b':
    # stage B3b: frame $9 and its RTE - a take mid-instruction primitive
    # (an FMOVE.B out of range with OPERR enabled) and a protocol violation
    # the MPU detects: the 68882 sends no primitive the MPU refuses, so the
    # bench answers the FNOP's response read with the reserved $0B00
    # (inject.txt); each handler clears the chip and returns, and the RTE
    # reads the response CIR again to end the dialog - the FNOP's through
    # cpBcc's scanPC, its displacement word
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3100)                    # lea $3100.w,a0
    a.emit(0xF23C, 0x9000, *L(0x2000))        # fmove.l #$2000,fpcr   OPERR enabled
    a.emit(0xF23C, 0x4000, *L(1000))          # fmove.l #1000,fp0
    a.label('MID'); a.emit(0xF210, 0x7800)    # fmove.b fp0,(a0)      take mid (vector 52)
    a.label('AF1'); a.emit(movel_abs(0x600D1, 0x3008))
    a.label('PVI'); a.emit(0xF280, 0x0000)    # fnop                  answered $0B00: protocol violation
    a.label('AF2'); a.emit(movel_abs(0x600D2, 0x300C))
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)

    def frame9(base, clear):                  # record a frame $9's fields at base..
        return [0x52B8, base,                 # addq.l #1,base.w
                0x21EF, 0x0002, base + 4,     # move.l 2(a7): scanPC
                0x31EF, 0x0006, base + 8,     # move.w 6(a7): format, offset
                0x21EF, 0x0008, base + 12,    # move.l 8(a7): the instruction's address
                0x31EF, 0x000E, base + 16,    # move.w $E(a7): the operation word
                0x21EF, 0x0010, base + 20,    # move.l $10(a7): the effective address
                ] + clear + [0x4E73]          # rte
    put(4 * 52, L(0x2400))
    put(0x2400, frame9(0x3010, [0xF338, 0x3300]))     # fsave $3300.w: the exception cleared
    put(4 * 13, L(0x2480))
    put(0x2480, frame9(0x3030, [0xF378, 0x3400]))     # frestore $3400.w: a null frame
    inject = a.lab['PVI']
    expect = [
        (0x3008, 0x000600D1, 0xFFFFFFFF),     # on past the FMOVE.B after the RTE
        (0x300C, 0x000600D2, 0xFFFFFFFF),     # on past the FMOVE.D after the RTE
        (0x3010, 0x00000001, 0xFFFFFFFF),     # take mid, once
        (0x3014, a.lab['AF1'], 0xFFFFFFFF),   # ... scanPC: past the command word
        (0x3018, 0x90D00000, 0xFFFF0000),     # ... format $9, offset $D0 (vector 52)
        (0x301C, a.lab['MID'], 0xFFFFFFFF),   # ... the instruction's address
        (0x3020, 0xF2100000, 0xFFFF0000),     # ... the operation word
        (0x3024, 0x00003100, 0xFFFFFFFF),     # ... the evaluated EA
        (0x3030, 0x00000001, 0xFFFFFFFF),     # the protocol violation, once
        (0x3034, a.lab['PVI'] + 2, 0xFFFFFFFF),   # ... scanPC: cpBcc's displacement word
        (0x3038, 0x90340000, 0xFFFF0000),     # ... format $9, offset $34 (vector 13)
        (0x303C, a.lab['PVI'], 0xFFFFFFFF),
        (0x3040, 0xF2800000, 0xFFFF0000),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3c':
    # stage B3c: interrupts inside a dialog (UM 10.5.2.6) - the bench's
    # VIA1 IRQ (level 1, autovector 25) at the first come-again - the
    # first FMOVECR's, which holds the MPU to its end (7e-3: Table 8-3's
    # T = 0, 8.6.14 item 22; before, the second one's, waiting for the
    # FSIN) - $8900: null,
    # CA = 1, IA = 1 - frame $9, the RTE reading the response again - and
    # at an FSAVE's not-ready ($01: frame $0 at the FSAVE, the RTE starting
    # it again); the handler files each frame's format word, scanPC/PC,
    # instruction address and operation word
    a = Asm(0x1000)
    a.emit(0x47F8, 0x3400)                    # lea $3400.w,a3
    a.emit(0x46FC, 0x2000)                    # move.w #$2000,sr     interrupts on
    a.label('FCR'); a.emit(0xF200, 0x5C32)    # fmovecr.x #$32,fp0   1.0, held: IRQ
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released (the CU)
    a.emit(0xF200, 0x5C8F)                    # fmovecr.x #$0f,fp1   waits for the FSIN
    a.emit(0xF200, 0x003A)                    # ftst.x fp0
    a.br(0xF292, 'T1')                        # fbgt.w T1
    a.emit(movel_abs(0xBAD1, 0x3008))
    a.label('T1'); a.emit(movel_abs(0x600D1, 0x3008))
    a.emit(0xF200, 0x5C32)                    # fmovecr.x #$32,fp0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released, running
    a.label('FSV'); a.emit(0xF323)            # fsave -(a3)          not ready: IRQ
    a.emit(0x21D3, 0x3004)                    # move.l (a3),$3004.w  the format word
    a.emit(0xF35B)                            # frestore (a3)+       the FSIN goes on
    a.emit(0x21CB, 0x300C)                    # move.l a3,$300C.w
    a.emit(0xF238, 0x6400, 0x3040)            # fmove.s fp0,$3040.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(4 * 25, L(0x2400))
    put(0x2400, [0x2E38, 0x3010,              # move.l $3010.w,d7
                 0xE98F,                      # lsl.l #4,d7
                 0x4DF8, 0x3020,              # lea $3020.w,a6
                 0xDDC7,                      # adda.l d7,a6          this entry's slot
                 0x3CAF, 0x0006,              # move.w 6(a7),(a6)     format, offset
                 0x2D6F, 0x0002, 0x0004,      # move.l 2(a7),4(a6)    scanPC / PC
                 0x2D6F, 0x0008, 0x0008,      # move.l 8(a7),8(a6)    ($9: the instruction's address)
                 0x3D6F, 0x000E, 0x000C,      # move.w $E(a7),$C(a6)  ($9: the operation word)
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w: the bench drops the IRQ
                 0x4E73])                     # rte
    irq = 1
    expect = [
        (0x3004, 0x1F000000, 0xFF000000),     # FSAVE's frame (idle or busy) after the restart
        (0x3008, 0x000600D1, 0xFFFFFFFF),     # FBGT after the interrupted FSIN: taken
        (0x300C, 0x00003400, 0xFFFFFFFF),     # (A3)+ back to $3400
        (0x3010, 0x00000002, 0xFFFFFFFF),     # two interrupts
        (0x3020, 0x90640000, 0xFFFF0000),     # the first: frame $9, offset $64 (vector 25)
        (0x3024, a.lab['FCR'] + 4, 0xFFFFFFFF),    # ... scanPC: past the command word
        (0x3028, a.lab['FCR'], 0xFFFFFFFF),   # ... the instruction's address
        (0x302C, 0xF2000000, 0xFFFF0000),     # ... the operation word
        (0x3030, 0x00640000, 0xFFFF0000),     # the second: frame $0, offset $64
        (0x3034, a.lab['FSV'], 0xFFFFFFFF),   # ... PC: the FSAVE, to start again
        (0x3040, 0x3F576AA4, 0xFFFFFFFF),     # sin(1.0) through the save and restore
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b5a':
    # stage B5a: no coprocessor (UM 10.5.2.8) - every category with CpID 2,
    # which nothing answers: the initiating access (the command or
    # condition write, the save read, the restore write after the format
    # word's read) ends in a bus error and the MPU takes the F-line, frame
    # $0 at the operation word; the 68882 (ID 1) then runs as before
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3100)                    # lea $3100.w,a0
    a.label('BG'); a.emit(0xF400, 0x0000)     # cpGEN, ID 2
    a.label('BB'); a.emit(0xF480, 0x0000)     # cpBcc.W, ID 2
    a.label('BC'); a.emit(0xF440, 0x0012)     # cpScc D0, ID 2
    a.label('BS'); a.emit(0xF528, 0x0000)     # cpSAVE (0,a0), ID 2
    a.label('BR'); a.emit(0xF568, 0x0000)     # cpRESTORE (0,a0), ID 2
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0      (ID 1)
    a.emit(0xF200, 0x003A)                    # ftst.x fp0
    a.br(0xF292, 'T1')                        # fbgt.w T1
    a.emit(movel_abs(0xBAD1, 0x3008))
    a.label('T1'); a.emit(movel_abs(0x600D1, 0x3008))
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(0x3100, L(0x1F380000))                # a format word for the restore to read
    cps = 5                                   # one initiating access each, bus-errored, nothing after it
    put(4 * 11, L(0x2400))
    put(0x2400, [0x2E38, 0x3010,              # move.l $3010.w,d7
                 0xE58F,                      # lsl.l #2,d7
                 0x4DF8, 0x3020,              # lea $3020.w,a6
                 0xDDC7,                      # adda.l d7,a6
                 0x2CAF, 0x0002,              # move.l 2(a7),(a6)   the frame's PC
                 0x3D6F, 0x0006, 0x0020,      # move.w 6(a7),$20(a6)  the format word
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x58AF, 0x0002,              # addq.l #4,2(a7)     past the two words
                 0x4E73])                     # rte
    expect = [
        (0x3008, 0x000600D1, 0xFFFFFFFF),     # the 68882 runs after
        (0x3010, 0x00000005, 0xFFFFFFFF),     # five F-lines
        (0x3020, a.lab['BG'], 0xFFFFFFFF),    # ... each at its operation word
        (0x3024, a.lab['BB'], 0xFFFFFFFF),
        (0x3028, a.lab['BC'], 0xFFFFFFFF),
        (0x302C, a.lab['BS'], 0xFFFFFFFF),
        (0x3030, a.lab['BR'], 0xFFFFFFFF),
        (0x3040, 0x002C0000, 0xFFFF0000),     # ... format $0, offset $2C
        (0x3044, 0x002C0000, 0xFFFF0000),
        (0x3048, 0x002C0000, 0xFFFF0000),
        (0x304C, 0x002C0000, 0xFFFF0000),
        (0x3050, 0x002C0000, 0xFFFF0000),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b5b':
    # stage B5b: trace (UM 8.1.7, 10.5.2.5). Trace on every instruction
    # (T1): each FPU instruction traced once, frame $2, its address in the
    # frame - and a cpGEN not before the 68882 is done: the MPU reads on
    # through the released-while-running nulls ($0900, CA = 0, PF = 0) to
    # PF = 1, so an FSAVE in the trace handler finds the chip idle; the
    # bench's IRQ at the FSIN's first $0900 is taken there (IA = 1) with
    # frame $9, not the trace frame. Trace on change of flow (T0): a taken
    # FBcc and an FDBcc branch traced, the FBcc not taken and the expired
    # FDBcc not.
    a = Asm(0x1000)
    a.emit(0x46FC, 0xA000)                    # move.w #$A000,sr     T1
    a.label('FMC'); a.emit(0xF200, 0x5C32)    # fmovecr.x #$32,fp0
    a.label('FSN'); a.emit(0xF200, 0x000E)    # fsin.x fp0           IRQ at its first $0900
    a.label('FTS'); a.emit(0xF200, 0x003A)    # ftst.x fp0
    a.label('FB1'); a.br(0xF292, 'MS6')       # fbgt.w MS6           taken
    a.emit(movel_abs(0xBAD1, 0x3008))
    a.label('MS6'); a.emit(0x46FC, 0x6000)    # move.w #$6000,sr     T0 (traced: T1 was on)
    a.label('FBQ'); a.br(0xF281, 'BAD')       # fbeq.w BAD           not taken: no trace
    a.label('FB2'); a.br(0xF292, 'T2')        # fbgt.w T2            taken: traced
    a.emit(movel_abs(0xBAD2, 0x3008))
    a.label('T2'); a.emit(0x7601)             # moveq #1,d3          not traced
    a.label('FDB'); a.emit(0xF24B); a.br(0x0001, 'FDB')   # fdbeq d3,FDB   branches once (traced), then expires
    a.label('MS2'); a.emit(0x46FC, 0x2000)    # move.w #$2000,sr     alters SR: traced
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    a.label('BAD'); a.emit(movel_abs(0xBAD0BAD0, 0x3FF0))
    a.emit(0x4E72, 0x2700)
    p = a.done()
    put(0x1000, p)
    # vector 9 (trace): the instruction's address (frame $2 +8) to $3100 +
    # 4n, and the format word of an FSAVE taken there to $3140 + 4n
    put(4 * 9, L(0x2400))
    put(0x2400, [0x2E38, 0x3010, 0xE58F,      # move.l $3010.w,d7; lsl.l #2,d7
                 0x4DF8, 0x3100, 0xDDC7,      # lea $3100.w,a6; adda.l d7,a6
                 0x2CAF, 0x0008,              # move.l 8(a7),(a6)
                 0xF338, 0x3300,              # fsave $3300.w
                 0x3D78, 0x3300, 0x0040,      # move.w $3300.w,$40(a6)
                 0xF378, 0x3300,              # frestore $3300.w
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x4E73])                     # rte
    # vector 25 (the bench's IRQ): count, format word, scanPC, PC
    put(4 * 25, L(0x2480))
    put(0x2480, [0x52B8, 0x3014,              # addq.l #1,$3014.w
                 0x31EF, 0x0006, 0x3018,      # move.w 6(a7),$3018.w
                 0x21EF, 0x0002, 0x301C,      # move.l 2(a7),$301C.w
                 0x21EF, 0x0008, 0x3020,      # move.l 8(a7),$3020.w
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w: the bench drops the IRQ
                 0x4E73])
    irq = a.lab['FSN']
    cps = 1                                   # the one IACK
    traced = ['FMC', 'FSN', 'FTS', 'FB1', 'MS6', 'FB2', 'FDB', 'MS2']
    expect = [(0x3100 + 4 * i, a.lab[t], 0xFFFFFFFF) for i, t in enumerate(traced)] + [
        (0x3008, 0x00000000, 0xFFFFFFFF),     # no wrong path taken
        (0x3010, len(traced), 0xFFFFFFFF),    # eight traces, no more
        (0x3144, 0x1F380000, 0xFFFF0000),     # the FSIN's trace: the chip already idle
        (0x3014, 0x00000001, 0xFFFFFFFF),     # the IRQ, once
        (0x3018, 0x90640000, 0xFFFF0000),     # ... frame $9 at the FSIN's null, IA = 1
        (0x301C, a.lab['FSN'] + 4, 0xFFFFFFFF),
        (0x3020, a.lab['FSN'], 0xFFFFFFFF),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b5c':
    # stage B5c: a bus error after the initiating access (UM 10.5.2.8) -
    # the bench fails the first access to: FADD's second operand long (the
    # sum must be 1 + 2, not an addend twice), an FMOVE.X store's third long,
    # FMOVEM's second register through (A2)+, a second FADD's extension word
    # (fetched inside its dialog), a long of an FSAVE's frame written and of
    # the FRESTORE's read; the handler files each long frame's format word,
    # SSW, fault address and PC, and returns; the dialog goes on from the
    # fault
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3200)                    # lea $3200.w,a0
    a.emit(0x43F8, 0x3300)                    # lea $3300.w,a1
    a.emit(0x45F8, 0x3400)                    # lea $3400.w,a2
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.label('FAD'); a.emit(0xF210, 0x4822)    # fadd.x (a0),fp0       $3204 faults
    a.label('FST'); a.emit(0xF211, 0x6800)    # fmove.x fp0,(a1)      $3308 faults
    a.label('FMM'); a.emit(0xF21A, 0xD00C)    # fmovem.x (a2)+,fp4/fp5  $3410 faults
    a.emit(0x21CA, 0x3004)                    # move.l a2,$3004.w
    a.emit(0x47F8, 0x3700)                    # lea $3700.w,a3
    while a.here() % 4:
        a.emit(0x4E71)                        # nop: the next FADD's extension word on a long of its own
    a.label('FA2'); a.emit(0xF238, 0x4822, 0x3210)   # fadd.x $3210.w,fp0  its extension word's fetch faults
    a.label('FSV'); a.emit(0xF323)            # fsave -(a3)           a frame long's write faults
    a.label('FRS'); a.emit(0xF35B)            # frestore (a3)+        a frame long's read faults
    a.emit(0x21CB, 0x300C)                    # move.l a3,$300C.w
    a.emit(0xF200, 0x6000)                    # fmove.l fp0,d0
    a.emit(0x21C0, 0x3008)                    # move.l d0,$3008.w
    a.emit(0xF238, 0x6A00, 0x3500)            # fmove.x fp4,$3500.w
    a.emit(0xF238, 0x6A80, 0x3510)            # fmove.x fp5,$3510.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(0x3200, L(0x40000000) + L(0x80000000) + L(0))    # 2.0
    put(0x3400, L(0x40010000) + L(0xA0000000) + L(0))    # 5.0
    put(0x340C, L(0x40010000) + L(0xC0000000) + L(0))    # 6.0
    put(0x3210, L(0x40010000) + L(0x80000000) + L(0))    # 4.0
    berrs = [0x3204, 0x3308, 0x3410, a.lab['FA2'] + 4, 0x36E4, 0x36E9]   # (bit 0: the read)
    # vector 2 (bus error): per fault at $3020 + 16n - format word, SSW,
    # fault address, PC
    put(4 * 2, L(0x2400))
    put(0x2400, [0x2E38, 0x3010, 0xE98F,      # move.l $3010.w,d7; lsl.l #4,d7
                 0x4DF8, 0x3020, 0xDDC7,      # lea $3020.w,a6; adda.l d7,a6
                 0x3CAF, 0x0006,              # move.w 6(a7),(a6)
                 0x3D6F, 0x000A, 0x0002,      # move.w $A(a7),2(a6)
                 0x2D6F, 0x0010, 0x0004,      # move.l $10(a7),4(a6)
                 0x2D6F, 0x0002, 0x0008,      # move.l 2(a7),8(a6)
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x4E73])                     # rte
    expect = [
        (0x3004, 0x00003418, 0xFFFFFFFF),     # (A2)+ past both registers, once
        (0x3008, 0x00000007, 0xFFFFFFFF),     # 1 + 2.0 + 4.0
        (0x300C, 0x00003700, 0xFFFFFFFF),     # -(A3) then (A3)+: back where it was
        (0x3010, 0x00000006, 0xFFFFFFFF),     # six bus errors
        (0x3020, 0xB0080000, 0xFFFF0000),     # ... long frames, vector 2
        (0x3024, 0x00003204, 0xFFFFFFFF),     # ... at the faulted accesses
        (0x3030, 0xB0080000, 0xFFFF0000),
        (0x3034, 0x00003308, 0xFFFFFFFF),
        (0x3040, 0xB0080000, 0xFFFF0000),
        (0x3044, 0x00003410, 0xFFFFFFFF),
        (0x3050, 0xB0080000, 0xFFFF0000),     # the extension word's fetch
        (0x3054, a.lab['FA2'] + 4, 0xFFFFFFFF),
        (0x3058, a.lab['FA2'] + 4, 0xFFFFFFFF),   # ... inside the dialog: its PC the fetch's address
        (0x3060, 0xB0080000, 0xFFFF0000),     # the save's write
        (0x3064, 0x000036E4, 0xFFFFFFFF),
        (0x3070, 0xB0080000, 0xFFFF0000),     # the restore's read
        (0x3074, 0x000036E8, 0xFFFFFFFF),
        (0x3300, 0x40000000, 0xFFFFFFFF),     # 3.0 stored whole
        (0x3304, 0xC0000000, 0xFFFFFFFF),
        (0x3308, 0x00000000, 0xFFFFFFFF),
        (0x3500, 0x40010000, 0xFFFFFFFF),     # FP4 = 5.0
        (0x3504, 0xA0000000, 0xFFFFFFFF),
        (0x3510, 0x40010000, 0xFFFFFFFF),     # FP5 = 6.0
        (0x3514, 0xC0000000, 0xFFFFFFFF),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b5d':
    # stage B5c with the PMMU: page faults inside dialogs, as virtual memory
    # makes them - 4 KB pages identity-mapped through three levels of short
    # descriptors (TIA 4, TIB 8, TIC 8), pages 4, 5, 8 and 9 invalid; an
    # FADD reads its operand from page 5, an FMOVE.X stores to page 4, one
    # through -(A3) to page 8, and an FMOVE.X reads through -(A4) from page
    # 9 - the predecrement written before the fault, so a rollback to the
    # instruction's start (the kernel's restart for a data read) would
    # leave A4 undecremented; the handler makes the faulted page valid
    # (from the frame's fault address), PFLUSHAs and returns; the dialog
    # goes on from the fault (plan 8.9.4 B5c)
    a = Asm(0x1000)
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp     (as the ROM's _SwapMMUMode)
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0x43F8, 0x5000)                    # lea $5000.w,a1
    a.label('FAD'); a.emit(0xF211, 0x4822)    # fadd.x (a1),fp0      page 5: faults
    a.emit(0x45F8, 0x4000)                    # lea $4000.w,a2
    a.label('FST'); a.emit(0xF212, 0x6800)    # fmove.x fp0,(a2)     page 4: faults
    a.emit(0x47F9, *L(0x800C))                # lea $800C,a3
    a.emit(0xF223, 0x6800)                    # fmove.x fp0,-(a3)    page 8: faults, A3 already down
    a.emit(0x21CB, 0x301C)                    # move.l a3,$301C.w
    a.emit(0x49F9, *L(0x900C))                # lea $900C,a4
    a.emit(0xF224, 0x4880)                    # fmove.x -(a4),fp1    page 9: a read faults, A4 already down
    a.emit(0x21CC, 0x3000)                    # move.l a4,$3000.w
    a.emit(0xF201, 0x6080)                    # fmove.l fp1,d1
    a.emit(0x21C1, 0x3004)                    # move.l d1,$3004.w
    a.emit(0xF200, 0x6000)                    # fmove.l fp0,d0
    a.emit(0x21C0, 0x3008)                    # move.l d0,$3008.w
    a.emit(0x2012)                            # move.l (a2),d0
    a.emit(0x21C0, 0x300C)                    # move.l d0,$300C.w
    a.emit(0x202A, 0x0004)                    # move.l 4(a2),d0
    a.emit(0x21C0, 0x3018)                    # move.l d0,$3018.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(0x5000, L(0x40000000) + L(0x80000000) + L(0))    # 2.0 on page 5
    put(0x9000, L(0x40010000) + L(0xE0000000) + L(0))    # 7.0 on page 9
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n in range(32):
        if n not in (4, 5, 8, 9):
            put(0x6800 + 4 * n, L((n << 12) | 1))        # C[n]: page n, valid
    # vector 2: file the frame as b5c's handler does, then make the
    # faulted page valid - C[fa >> 12] = (fa & $FFFFF000) | 1 - and flush
    put(4 * 2, L(0x2400))
    put(0x2400, [0x2E38, 0x3010, 0xE98F,      # move.l $3010.w,d7; lsl.l #4,d7
                 0x4DF8, 0x3020, 0xDDC7,      # lea $3020.w,a6; adda.l d7,a6
                 0x3CAF, 0x0006,              # move.w 6(a7),(a6)
                 0x3D6F, 0x000A, 0x0002,      # move.w $A(a7),2(a6)
                 0x2D6F, 0x0010, 0x0004,      # move.l $10(a7),4(a6)
                 0x2D6F, 0x0002, 0x0008,      # move.l 2(a7),8(a6)
                 0x2C2F, 0x0010,              # move.l $10(a7),d6   the fault address
                 0x2A06,                      # move.l d6,d5
                 0x0285, 0xFFFF, 0xF000,      # andi.l #$FFFFF000,d5
                 0x5285,                      # addq.l #1,d5        a valid page descriptor
                 0xE08E, 0xE48E,              # lsr.l #8,d6; lsr.l #2,d6
                 0x0206, 0x00FC,              # andi.b #$FC,d6      its entry's offset
                 0x4BF8, 0x6800,              # lea $6800.w,a5
                 0x2B85, 0x6000,              # move.l d5,(0,a5,d6.w)
                 0xF000, 0x2400,              # pflusha
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x4E73])                     # rte
    expect = [
        (0x3008, 0x00000003, 0xFFFFFFFF),     # 1 + 2.0, once
        (0x300C, 0x40000000, 0xFFFFFFFF),     # 3.0 stored on page 4
        (0x3018, 0xC0000000, 0xFFFFFFFF),
        (0x3010, 0x00000004, 0xFFFFFFFF),     # four page faults
        (0x3020, 0xB0080000, 0xFFFF0000),     # ... long frames, vector 2
        (0x3024, 0x00005000, 0xFFFFFFFF),     # ... the FADD's operand
        (0x3030, 0xB0080000, 0xFFFF0000),
        (0x3034, 0x00004000, 0xFFFFFFFF),     # ... the store
        (0x3040, 0xB0080000, 0xFFFF0000),
        (0x3044, 0x00008000, 0xFFFFFFFF),     # ... the -(A3) store
        (0x301C, 0x00008000, 0xFFFFFFFF),     # A3 decremented once, not rolled back
        (0x3050, 0xB0080000, 0xFFFF0000),
        (0x3054, 0x00009000, 0xFFFFFFFF),     # ... the -(A4) read
        (0x3000, 0x00009000, 0xFFFFFFFF),     # A4 decremented once, not rolled back
        (0x3004, 0x00000007, 0xFFFFFFFF),     # 7.0 read
        (0x8000, 0x40000000, 0xFFFFFFFF),     # 3.0 stored on page 8
        (0x8004, 0xC0000000, 0xFFFFFFFF),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b7e':
    # item 7e-1 (plan 8.9.6): the CU's overlap through the kernel - with DZ
    # enabled an FDIV by zero is released and runs while the next
    # instruction goes to the CU; its exception is reported (UM 7.5,
    # Figures 7-32/7-33; 5.2.3.6) as take mid-instruction by an FADD.B #3
    # whose dialog is held until the hand-off (frame $9 - its RTE resumes
    # the dialog), then as take pre-instruction by the FNOP after a
    # register FADD the CU released (frame $0 - its RTE starts the FNOP
    # again).  The handler is UM 5.2.2's: FSAVE, BSET of bit 27 in the BIU
    # flags (serviced), FRESTORE, RTE; it files the frame's format word and
    # PC, the FPU frame's format and FPIAR - the FDIV's while the CU's
    # instruction waits, the FADD's once it has run
    a = Asm(0x1000)
    a.emit(0xF23C, 0x9000, *L(0x400))         # fmove.l #$400,fpcr   DZ enabled
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF23C, 0x4080, *L(0))             # fmove.l #0,fp1
    a.label('FDV'); a.emit(0xF200, 0x0420)    # fdiv.x fp1,fp0       DZ, released
    a.label('FAB'); a.emit(0xF23C, 0x58A2, 3) # fadd.b #3,fp1        the CU, held: take mid
    a.emit(0xF238, 0xA400, 0x3004)            # fmove.l fpiar,$3004.w (before a store passes its own)
    a.emit(0xF201, 0x6080)                    # fmove.l fp1,d1
    a.emit(0x21C1, 0x3000)                    # move.l d1,$3000.w    0 + 3
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF23C, 0x4080, *L(0))             # fmove.l #0,fp1
    a.emit(0xF23C, 0x4100, *L(5))             # fmove.l #5,fp2
    a.emit(0xF23C, 0x4180, *L(2))             # fmove.l #2,fp3
    a.label('FDV2'); a.emit(0xF200, 0x0420)   # fdiv.x fp1,fp0       DZ, released
    a.label('FAD'); a.emit(0xF200, 0x0D22)    # fadd.x fp3,fp2       the CU, released
    a.label('FNP'); a.emit(0xF280, 0x0000)    # fnop                 take pre, started again
    a.emit(0xF238, 0xA400, 0x300C)            # fmove.l fpiar,$300C.w
    a.emit(0xF202, 0x6100)                    # fmove.l fp2,d2
    a.emit(0x21C2, 0x3008)                    # move.l d2,$3008.w    5 + 2
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(4 * 50, L(0x2400))                    # vector 50: DZ
    put(0x2400, [0x2E38, 0x3040,              # move.l $3040.w,d7
                 0xE98F,                      # lsl.l #4,d7
                 0x4DF8, 0x3050,              # lea $3050.w,a6
                 0xDDC7,                      # adda.l d7,a6          this entry's slot
                 0x3CAF, 0x0006,              # move.w 6(a7),(a6)     format, offset
                 0x2D6F, 0x0002, 0x0004,      # move.l 2(a7),4(a6)    scanPC / PC
                 0xF327,                      # fsave -(a7)
                 0x3D57, 0x0008,              # move.w (a7),8(a6)     the FPU frame's format
                 0xF22E, 0xA400, 0x000C,      # fmove.l fpiar,$C(a6)
                 0x08EF, 0x0003, 0x0038,      # bset #3,$38(a7)       BIU flag 27: serviced
                 0xF35F,                      # frestore (a7)+
                 0x52B8, 0x3040,              # addq.l #1,$3040.w
                 0x4E73])                     # rte
    expect = [
        (0x3000, 0x00000003, 0xFFFFFFFF),     # the FADD.B ran after the handler: 0 + 3
        (0x3004, a.lab['FAB'], 0xFFFFFFFF),   # ... FPIAR its own
        (0x3008, 0x00000007, 0xFFFFFFFF),     # the FADD ran after the handler: 5 + 2
        (0x300C, a.lab['FAD'], 0xFFFFFFFF),
        (0x3040, 0x00000002, 0xFFFFFFFF),     # two DZ exceptions
        (0x3050, 0x90C80000, 0xFFFF0000),     # the first: frame $9, vector 50 - mid
        (0x3054, a.lab['FAB'] + 6, 0xFFFFFFFF),    # ... scanPC past the immediate
        (0x3058, 0x1F380000, 0xFFFF0000),     # ... an idle frame (the FADD.B in its CU area)
        (0x305C, a.lab['FDV'], 0xFFFFFFFF),   # ... FPIAR the FDIV's
        (0x3060, 0x00C80000, 0xFFFF0000),     # the second: frame $0 - pre, at the FNOP
        (0x3064, a.lab['FNP'], 0xFFFFFFFF),
        (0x3068, 0x1F380000, 0xFFFF0000),
        (0x306C, a.lab['FDV2'], 0xFFFFFFFF),
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'mmu':
    # the PMMU through the wrapper, no dialog faulting: b5d's tables and
    # pages 4 and 5 invalid; a walk of three levels with its U-bit writes,
    # an FPU instruction fetched translated, then a plain MOVE reading page
    # 5 and one writing page 4 - each a page fault that the handler makes
    # valid, the access re-run.  The handler turns translation off to read
    # physical $4000: the write must not have reached memory before its
    # fault (the 68030 runs no bus cycle for an invalid page).
    a = Asm(0x1000)
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF200, 0x6000)                    # fmove.l fp0,d0
    a.emit(0x21C0, 0x3000)                    # move.l d0,$3000.w
    a.emit(0x2238, 0x5000)                    # move.l $5000.w,d1    page 5: faults
    a.emit(0x21C1, 0x3004)                    # move.l d1,$3004.w
    a.emit(movel_abs(0xC0DE0004, 0x4000))     # move.l #..,$4000.w   page 4: faults
    a.emit(0x2438, 0x4000)                    # move.l $4000.w,d2
    a.emit(0x21C2, 0x3008)                    # move.l d2,$3008.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(0x4000, L(0xA5A5A5A5))
    put(0x5000, L(0x12345678))
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6F0C, L(0x00C04880))                           # ... and with E clear
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n in range(32):
        if n not in (4, 5):
            put(0x6800 + 4 * n, L((n << 12) | 1))        # C[n]: page n, valid
    put(4 * 2, L(0x2400))
    put(0x2400, [0x2E38, 0x3010, 0xE98F,      # move.l $3010.w,d7; lsl.l #4,d7
                 0x4DF8, 0x3020, 0xDDC7,      # lea $3020.w,a6; adda.l d7,a6
                 0x3CAF, 0x0006,              # move.w 6(a7),(a6)
                 0x2D6F, 0x0010, 0x0004,      # move.l $10(a7),4(a6)   the fault address
                 0xF038, 0x4000, 0x6F0C,      # pmove.l $6F0C.w,tc     translation off
                 0x2D78, 0x4000, 0x0008,      # move.l $4000.w,8(a6)   physical $4000
                 0xF038, 0x4000, 0x6F08,      # pmove.l $6F08.w,tc     and on
                 0x2C2F, 0x0010,              # move.l $10(a7),d6
                 0x2A06,                      # move.l d6,d5
                 0x0285, 0xFFFF, 0xF000,      # andi.l #$FFFFF000,d5
                 0x5285,                      # addq.l #1,d5        a valid page descriptor
                 0xE08E, 0xE48E,              # lsr.l #8,d6; lsr.l #2,d6
                 0x0206, 0x00FC,              # andi.b #$FC,d6      its entry's offset
                 0x4BF8, 0x6800,              # lea $6800.w,a5
                 0x2B85, 0x6000,              # move.l d5,(0,a5,d6.w)
                 0xF000, 0x2400,              # pflusha
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x4E73])                     # rte
    expect = [
        (0x3000, 0x00000001, 0xFFFFFFFF),     # the FPU, fetched translated
        (0x3004, 0x12345678, 0xFFFFFFFF),     # page 5 read, re-run
        (0x3008, 0xC0DE0004, 0xFFFFFFFF),     # page 4 written, re-run
        (0x3010, 0x00000002, 0xFFFFFFFF),     # two page faults
        (0x3020, 0xB0080000, 0xFFFF0000),     # ... long frames, vector 2
        (0x3024, 0x00005000, 0xFFFFFFFF),
        (0x3030, 0x00080000, 0x0FFF0000),     # ... vector 2 (the MOVE's last access: short
        (0x3034, 0x00004000, 0xFFFFFFFF),     #     frame or long, 030 UM 8.1.2)
        (0x3038, 0xA5A5A5A5, 0xFFFFFFFF),     # ... and physical $4000 not yet written
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b4':
    # stage B4: cpSAVE and cpRESTORE in every EA form the two allow
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3100)                    # lea $3100.w,a0
    a.emit(0x43F8, 0x3200)                    # lea $3200.w,a1
    a.emit(0x45F8, 0x3180)                    # lea $3180.w,a2
    a.emit(0x47F8, 0x3400)                    # lea $3400.w,a3
    a.emit(0x7208)                            # moveq #8,d1
    a.emit(0xF310)                            # fsave (a0)            reset phase: null
    a.emit(0xF23C, 0x9000, *L(0x0400))        # fmove.l #$400,fpcr    DZ enabled
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF23C, 0x4080, *L(0))             # fmove.l #0,fp1
    a.emit(0xF200, 0x0420)                    # fdiv.x fp1,fp0        DZ pending
    a.emit(0xF323)                            # fsave -(a3)           idle, the exception in it
    a.emit(0x21CB, 0x3004)                    # move.l a3,$3004.w
    a.emit(0xF328, 0x0010)                    # fsave ($10,a0)        idle, nothing pending
    a.emit(0xF280, 0x0000)                    # fnop                  takes nothing
    a.emit(movel_abs(0x600D1, 0x3008))
    a.emit(0xF35B)                            # frestore (a3)+        the exception back
    a.emit(0x21CB, 0x300C)                    # move.l a3,$300C.w
    a.label('FNOPX'); a.emit(0xF280, 0x0000)  # fnop                  takes DZ (vector 50)
    a.emit(0xF370, 0x1008)                    # frestore (8,a0,d1.w)  the frame at $3110
    a.emit(0xF312)                            # fsave (a2)
    a.label('BADR'); a.emit(0xF359)           # frestore (a1)+        $1F3A: format error
    a.emit(0x21C9, 0x3010)                    # move.l a1,$3010.w
    a.emit(0xF37A)                            # frestore (NULLF,pc)   the displacement is
    a.fix.append((len(a.w), 'NULLF'))         #   from its own word
    a.emit(0)
    a.emit(0xF338, 0x31D0)                    # fsave $31D0.w         null again (past the idle frame at $3180)
    a.emit(0xF339, 0x0000, 0x31D8)            # fsave $000031D8.l
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    a.label('NULLF'); a.emit(*L(0))           # a null frame
    p = a.done()
    put(0x1000, p)
    for s in (0x3104, 0x31D4, 0x31DC):
        put(s, L(0xAAAAAAAA))                 # the long after each null frame
    put(0x3200, L(0x1F3A0000))                # an invalid format word
    # vector 50 (DZ): count, frame PC, format word; reset the chip with a
    # null frame through (xxx).W; resume past the FNOP
    put(4 * 50, L(0x2400))
    put(0x2400, [0x52B8, 0x3014, 0x21EF, 0x0002, 0x3018, 0x31EF, 0x0006, 0x301C,
                 0xF378, 0x3300,              # frestore $3300.w
                 0x58AF, 0x0002, 0x4E73])     # addq.l #4,2(a7); rte
    # vector 14 (format error): as vector 50's, past the one-word FRESTORE
    put(4 * 14, L(0x2440))
    put(0x2440, [0x52B8, 0x3020, 0x21EF, 0x0002, 0x3024, 0x31EF, 0x0006, 0x3028,
                 0x54AF, 0x0002, 0x4E73])     # addq.l #2,2(a7); rte
    expect = [
        (0x3004, 0x000033C4, 0xFFFFFFFF),     # -(A3): 60 bytes below $3400
        (0x3008, 0x000600D1, 0xFFFFFFFF),     # the FNOP after FSAVE took nothing
        (0x300C, 0x00003400, 0xFFFFFFFF),     # (A3)+: past the 60 bytes
        (0x3010, 0x00003200, 0xFFFFFFFF),     # (A1)+ not moved by the format error
        (0x3014, 0x00000001, 0xFFFFFFFF),     # DZ taken once
        (0x3018, a.lab['FNOPX'], 0xFFFFFFFF), # ... at the FNOP
        (0x301C, 0x00C80000, 0xFFFF0000),     # ... format 0, offset $C8
        (0x3020, 0x00000001, 0xFFFFFFFF),     # the format error once
        (0x3024, a.lab['BADR'], 0xFFFFFFFF),  # ... at the FRESTORE
        (0x3028, 0x00380000, 0xFFFF0000),     # ... format 0, offset $38
        (0x3100, 0x00380000, 0xFFFFFFFF),     # the null frame, reserved word 0
        (0x3104, 0xAAAAAAAA, 0xFFFFFFFF),     # ... and nothing after it
        (0x3110, 0x1F380000, 0xFFFFFFFF),     # the idle frame through (d16,An)
        (0x3148, 0x08000000, 0x08000000),     # ... nothing pending (bit 27 high)
        (0x3180, 0x1F380000, 0xFFFFFFFF),     # FSAVE after FRESTORE of an idle frame
        (0x31D0, 0x00380000, 0xFFFFFFFF),     # null through (xxx).W
        (0x31D4, 0xAAAAAAAA, 0xFFFFFFFF),
        (0x31D8, 0x00380000, 0xFFFFFFFF),     # null through (xxx).L
        (0x31DC, 0xAAAAAAAA, 0xFFFFFFFF),
        (0x33C4, 0x1F380000, 0xFFFFFFFF),     # the idle frame through -(An)
        (0x33C8, 0x04200000, 0xFFFFFFFF),     # ... the command image first after it
        (0x33FC, 0x00000000, 0x08000000),     # ... the exception pending (bit 27 low)
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'cmpm':
    # PC Exchange's 11-byte DOS-name compare (EXFS 16 at $E9E - KNOWN ISSUES 9,
    # 2026-10-06): SF D0; CMPM.L (A0)+,(A1)+; BNE; CMPM.L; BNE; CMPM.W; BNE;
    # CMPM.B; BNE; ST D0 - with one operand in a buffer at 2 mod 4 (the volume
    # record's directory sector at +$176), as the board's lookup runs it.
    data = bytearray(0x140)
    nm = b'FINDER  DAT'
    for off in (0x00, 0x22, 0x41, 0x63, 0x100, 0x122):
        data[off:off + 11] = nm
    data[0x80:0x8B] = b'FINDER  DAX'                   # differs in the last byte
    put(0x3100, [(data[i] << 8) | data[i + 1] for i in range(0, len(data), 2)])
    a = Asm(0x1000)
    a.emit(0xF280, 0x0000)                             # fnop: the bench wants one coprocessor cycle
    def cmp_at(a0, a1, res):                           # the compare, its truth byte to res
        a.emit(0x41F8, a0, 0x43F8, a1)                 # lea a0.w,a0 ; lea a1.w,a1
        a.br(0x6100, 'CMP')                            # bsr.w CMP
        a.emit(0x7200, 0x1200, 0x21C1, res)            # moveq #0,d1 ; move.b d0,d1 ; move.l d1,res.w
    cmp_at(0x3100, 0x3122, 0x3000)                     # aligned vs 2 mod 4
    cmp_at(0x3122, 0x3100, 0x3004)                     # 2 mod 4 vs aligned
    cmp_at(0x3100, 0x3200, 0x3008)                     # both aligned
    cmp_at(0x3122, 0x3222, 0x300C)                     # both 2 mod 4
    cmp_at(0x3100, 0x3141, 0x3010)                     # aligned vs 1 mod 4
    cmp_at(0x3100, 0x3163, 0x3014)                     # aligned vs 3 mod 4
    cmp_at(0x3100, 0x3180, 0x3018)                     # unequal: 0
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3122)             # one CMPM.L, its CCR and pointers
    a.emit(0xB388, 0x42C1, 0x21C1, 0x301C)             # cmpm.l (a0)+,(a1)+ ; move ccr,d1 ; -> $301C
    a.emit(0x21C8, 0x3020, 0x21C9, 0x3024)             # a0 -> $3020, a1 -> $3024
    a.emit(0x2438, 0x3122, 0x21C2, 0x3028)             # move.l $3122.w,d2 (a misaligned long) -> $3028
    a.emit(0x43F8, 0x3122, 0x2611, 0x21C3, 0x302C)     # move.l (a1),d3 -> $302C
    a.emit(0x41F8, 0x3100, 0xB690, 0x42C1, 0x21C1, 0x3030)   # cmp.l (a0),d3 ; ccr -> $3030
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3200, 0xB308, 0x42C1, 0x21C1, 0x3034)   # cmpm.b (a0)+,(a1)+ both aligned ; ccr
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3200, 0xB348, 0x42C1, 0x21C1, 0x3038)   # cmpm.w both aligned ; ccr
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3200, 0xB388, 0x42C1, 0x21C1, 0x303C)   # cmpm.l both aligned ; ccr
    a.emit(0x41F8, 0x3122, 0x43F8, 0x3200, 0xB388, 0x42C1, 0x21C1, 0x3040)   # cmpm.l source 2 mod 4 ; ccr
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3200, 0x4E71, 0xB388, 0x42C1, 0x21C1, 0x3044)   # nop then cmpm.l both aligned
    a.emit(0x41F8, 0x3100, 0x43F8, 0x3200, 0x2018, 0xB099, 0x42C1, 0x21C1, 0x3048)   # move.l (a0)+,d0 ; cmp.l (a1)+,d0 ; ccr
    # the other read-read forms, last (they change $3200): ADDX.L/SUBX.L -(Ay),-(Ax), ABCD -(Ay),-(Ax)
    a.emit(0x023C, 0x0000, 0x41F8, 0x3104, 0x43F8, 0x3204, 0xD388, 0x21F8, 0x3200, 0x304C)   # X clear; addx.l ; $3200 -> $304C
    a.emit(0x023C, 0x0000, 0x41F8, 0x3104, 0x43F8, 0x3204, 0x9388, 0x21F8, 0x3200, 0x3050)   # subx.l ; -> $3050
    a.emit(0x023C, 0x0000, 0x41F8, 0x3101, 0x43F8, 0x3201, 0xC308, 0x21F8, 0x3200, 0x3054)   # abcd -(a0),-(a1) ; -> $3054
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                             # stop #$2700
    a.label('CMP')
    a.emit(0x51C0, 0xB388, 0x660E, 0xB388, 0x660A, 0xB348, 0x6606, 0xB308, 0x6602, 0x50C0, 0x4E75)
    p = a.done()
    put(0x1000, p)
    expect = [
        (0x3000, 0x000000FF, 0xFFFFFFFF),   # aligned vs 2 mod 4: equal
        (0x3004, 0x000000FF, 0xFFFFFFFF),
        (0x3008, 0x000000FF, 0xFFFFFFFF),
        (0x300C, 0x000000FF, 0xFFFFFFFF),
        (0x3010, 0x000000FF, 0xFFFFFFFF),
        (0x3014, 0x000000FF, 0xFFFFFFFF),
        (0x3018, 0x00000000, 0xFFFFFFFF),   # unequal
        (0x301C, 0x00000004, 0x0000001F),   # CCR after one equal CMPM.L: Z only
        (0x3020, 0x00003104, 0xFFFFFFFF),   # both pointers advanced by 4
        (0x3024, 0x00003126, 0xFFFFFFFF),
        (0x3028, 0x46494E44, 0xFFFFFFFF),   # 'FIND' read at 2 mod 4
        (0x302C, 0x46494E44, 0xFFFFFFFF),
        (0x3030, 0x00000004, 0x0000001F),   # cmp.l of the same: Z
        (0x3034, 0x00000004, 0x0000001F),   # cmpm.b aligned: Z
        (0x3038, 0x00000004, 0x0000001F),   # cmpm.w aligned: Z
        (0x303C, 0x00000004, 0x0000001F),   # cmpm.l aligned: Z
        (0x3040, 0x00000004, 0x0000001F),   # cmpm.l misaligned source: Z
        (0x3044, 0x00000004, 0x0000001F),   # after a nop
        (0x3048, 0x00000004, 0x0000001F),   # move.l/cmp.l pair: Z
        (0x304C, 0x8C929C88, 0xFFFFFFFF),   # 'FIND' + 'FIND'
        (0x3050, 0x46494E44, 0xFFFFFFFF),   # and back
        (0x3054, 0x92494E44, 0xFFFFFFFF),   # BCD 46 + 46 = 92 in the first byte
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
with open('inject.txt', 'w') as f:
    f.write(' '.join('%08x' % v for v in [inject, irq, cps] + (berrs + [0] * 8)[:8]) + '\n')
with open('expect.txt', 'w') as f:
    f.write(''.join('%08x %08x %08x\n' % e for e in expect))
print('program %s: %d words at $1000; %d results' % (MODE, len(p), len(expect)))
