"""gen_program.py - the programs for tb_cpfpu.v (SE30_PLAN.md 8.9.4, item 7d):
FPU instructions as the 68030 runs them against the MC68882 on the bus,
with the results left in RAM.

    python gen_program.py [b1|b2|b3a|b3b|b3c|b3u|b3n|b3s|b3r|b3x|b4|b5a|b5b|b5c|b5d|mmu|fsw|fif|fsx|frs|fullea|fulleab|full]

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

fullea (KNOWN ISSUES 20: A/UX's StartMonitor took "bad F-Line instruction"
on FMOVE.W ([$47EC2204],$5A),FP0 - the dialog had no full extension
format): the full format (UM 2.2) through the coprocessor's EA - both of
StartMonitor's encodings ($01F2: BS, IS, long bd, memory indirect with a
word od; $0161: word bd from A0, memory indirect, null od, a double
written through the pointer), preindexed and postindexed with word
displacements, (bd.L,An,Xn.L*4) without indirection, (bd,PC) and
([An,Xn.W*4]) with null bd and od.

full: the program the bench must run once stage B is whole (operand
transfers, FMOVEM, FSAVE/FRESTORE).

Writes program.hex (64K 16-bit words), expect.txt (address, value, mask) and
inject.txt: the instruction whose first response read the bench answers with
the reserved primitive $0B00 (0 for none), and 1 when the bench raises VIA1's
IRQ inside dialogs (b3c), and the number of CPU-space cycles to anything
but the 68882 the run must make (b5a; all ones: unchecked).
"""
import os
import sys

MODE = sys.argv[1] if len(sys.argv) > 1 else 'b1'
inject = 0                                    # the instruction whose response read the bench answers $0B00
irq = 0                                       # 1: the bench raises VIA1's IRQ inside dialogs (b3c)
ucheck = ([], [])                             # (user-code ranges, user-data ranges): tb_cpfpu.v's user-mode checks (fsw, fif)
cps = 0xFFFFFFFF                              # CPU-space cycles to IDs but 1 (and IACKs) expected; all ones: unchecked
CACR_K28 = int(os.environ.get('B3_CACR', '0'), 0)   # KNOWN ISSUES 28's programs (b3u, b5u, b3r): the cache control register first
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
elif MODE == 'b3u':
    # KNOWN ISSUES 26 (A/UX xeyes, "Memory fault"): a dialog resumed in
    # USER mode by an RTE - frame $9 from the bench's IRQ at the come-again
    # of an FMOVE.D FP0,-(A7) waiting for an FSIN (cp_rte), then a bus error
    # on the next FMOVE.D's write and on an FMOVE.D (A7)+'s read (long
    # frames, cp_rsm) - must take A7 as the USP, and (A7)+ write it back
    # there; the TRAP #0 at the end files both stack pointers
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x41F8, 0x3800)                    # lea $3800.w,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts on
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released, running
    a.label('FM1'); a.emit(0xF227, 0x7400)    # fmove.d fp0,-(a7)    come-again: IRQ
    a.emit(0x21CF, 0x3004)                    # move.l a7,$3004.w
    a.emit(0x21D7, 0x3008)                    # move.l (a7),$3008.w
    a.emit(0x21EF, 0x0004, 0x300C)            # move.l 4(a7),$300C.w
    a.label('FM2'); a.emit(0xF227, 0x7400)    # fmove.d fp0,-(a7)    its write bus-errors once
    a.emit(0x21CF, 0x3030)                    # move.l a7,$3030.w
    a.emit(0x21EF, 0x0004, 0x3034)            # move.l 4(a7),$3034.w
    a.label('FM3'); a.emit(0xF21F, 0x5480)    # fmove.d (a7)+,fp1    its first read bus-errors once
    a.emit(0x21CF, 0x303C)                    # move.l a7,$303C.w
    a.emit(0xF238, 0x7480, 0x3040)            # fmove.d fp1,$3040.w
    a.emit(0x4E40)                            # trap #0
    p = a.done()
    put(0x1000, p)
    put(4 * 25, L(0x2400))                    # the bench's IRQ: count, SSP, format word
    put(0x2400, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x21CF, 0x301C,              # move.l a7,$301C.w
                 0x31EF, 0x0006, 0x3020,      # move.w 6(a7),$3020.w
                 0x21EF, 0x0008, 0x3038,      # move.l 8(a7),$3038.w  the instruction's address
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w: the bench drops the IRQ
                 0x4E73])                     # rte
    put(4 * 2, L(0x2480))                     # the bus error: count, SSP, format word
    put(0x2480, [0x52B8, 0x3024,              # addq.l #1,$3024.w
                 0x21CF, 0x302C,              # move.l a7,$302C.w
                 0x31EF, 0x0006, 0x3028,      # move.w 6(a7),$3028.w
                 0x4E73])                     # rte: the faulted beat again
    put(4 * 32, L(0x2500))                    # TRAP #0: both stack pointers, then stop
    put(0x2500, [0x21CF, 0x3014,              # move.l a7,$3014.w
                 0x4E68,                      # move.l usp,a0
                 0x21C8, 0x3018,              # move.l a0,$3018.w
                 *movel_abs(0x600D0001, 0x3FF0),
                 0x4E72, 0x2700])             # stop #$2700
    irq = a.lab['FM1']                        # at FM1's first come-again ($8900: it waits for the FSIN)
    berrs = [0x37F0, 0x37F0 | 1]              # FM2's first long; FM3's (bit 0: the read)
    expect = [
        (0x3004, 0x000037F8, 0xFFFFFFFF),     # FM1: USP down by 8
        (0x3008, 0x3FEAED54, 0xFFFFFFFF),     # ... sin(1.0) as a double, on the user stack
        (0x300C, 0x8F090CEE, 0xFFFFFFFF),
        (0x3010, 0x00000001, 0xFFFFFFFF),     # the IRQ, once
        (0x301C, 0x00007FEC, 0xFFFFFFFF),     # ... on the ISP: $8000 less frame $9
        (0x3020, 0x90640000, 0xFFFF0000),     # ... frame $9, vector 25
        (0x3038, a.lab['FM1'], 0xFFFFFFFF),   # ... inside FM1's dialog
        (0x3024, 0x00000002, 0xFFFFFFFF),     # the bus errors, FM2's and FM3's
        (0x3028, 0xB0080000, 0xFFFF0000),     # ... a long frame, vector 2
        (0x302C, 0x00007FA4, 0xFFFFFFFF),     # ... on the ISP: $8000 less $5C
        (0x3030, 0x000037F0, 0xFFFFFFFF),     # FM2: USP down by 8 more
        (0x3034, 0x8F090CEE, 0xFFFFFFFF),
        (0x303C, 0x000037F8, 0xFFFFFFFF),     # FM3: USP up by 8
        (0x3040, 0x3FEAED54, 0xFFFFFFFF),     # ... the double into FP1
        (0x3044, 0x8F090CEE, 0xFFFFFFFF),
        (0x3014, 0x00007FF8, 0xFFFFFFFF),     # TRAP #0: the ISP intact ($8000 less frame $0)
        (0x3018, 0x000037F8, 0xFFFFFFFF),     # ... and the USP
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3n':
    # KNOWN ISSUES 28 (compile 79's JTRACE, A/UX fpstress): a level-1
    # interrupt inside a user-mode dialog stacks frame $9; level 2 is pending
    # at the level-1 handler's FIRST instruction - so it is taken there, with
    # a format $0 frame whose PC is that handler's address and whose SR is the
    # handler's (S, IPL 1) (UM 8.1.4); its RTE runs the level-1 handler, whose
    # RTE resumes the dialog in user mode. The kernel used to stack frame $9
    # again (cp_f9 still set): the level-1 handler never ran and the dialog
    # resumed in supervisor mode
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x41F8, 0x3800)                    # lea $3800.w,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts on
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released, running
    a.emit(0xF227, 0x7400)                    # fmove.d fp0,-(a7)
    a.emit(0x21CF, 0x3004)                    # move.l a7,$3004.w
    a.emit(0x21D7, 0x3008)                    # move.l (a7),$3008.w
    a.emit(0x21EF, 0x0004, 0x300C)            # move.l 4(a7),$300C.w
    a.emit(0x4E40)                            # trap #0
    p = a.done()
    put(0x1000, p)
    put(4 * 25, L(0x2400))                    # level 1: count, drop
    put(0x2400, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w
                 0x4E73])                     # rte
    put(4 * 26, L(0x2480))                    # level 2: count, its frame, level 1's count so far, drop
    put(0x2480, [0x52B8, 0x3020,              # addq.l #1,$3020.w
                 0x31D7, 0x3024,              # move.w (a7),$3024.w     SR
                 0x21EF, 0x0002, 0x3028,      # move.l 2(a7),$3028.w    PC
                 0x31EF, 0x0006, 0x302C,      # move.w 6(a7),$302C.w    format, offset
                 0x21F8, 0x3010, 0x3030,      # move.l $3010.w,$3030.w  level 1's count
                 0x21FC, 0x0000, 0x0001, 0x3F0C,   # move.l #1,$3F0C.w
                 0x4E73])                     # rte
    put(4 * 32, L(0x2500))                    # TRAP #0: both stack pointers, then stop
    put(0x2500, [0x21CF, 0x3014,              # move.l a7,$3014.w
                 0x4E68,                      # move.l usp,a0
                 0x21C8, 0x3018,              # move.l a0,$3018.w
                 *movel_abs(0x600D0001, 0x3FF0),
                 0x4E72, 0x2700])             # stop #$2700
    irq = 0xFFFFFFFD
    expect = [
        (0x3020, 0x00000001, 0xFFFFFFFF),     # level 2, once
        (0x3024, 0x21000000, 0xFF000000),     # ... its SR: level 1's handler's (S, IPL 1)
        (0x3028, 0x00002400, 0xFFFFFFFF),     # ... its PC: level 1's handler, not yet run
        (0x302C, 0x00680000, 0xFFFF0000),     # ... format $0, vector 26
        (0x3030, 0x00000000, 0xFFFFFFFF),     # ... level 1's handler had not run
        (0x3010, 0x00000001, 0xFFFFFFFF),     # level 1's handler ran, once
        (0x3004, 0x000037F8, 0xFFFFFFFF),     # the dialog finished in user mode: USP - 8
        (0x3008, 0x3FEAED54, 0xFFFFFFFF),     # sin(1.0)
        (0x300C, 0x8F090CEE, 0xFFFFFFFF),
        (0x3014, 0x00007FF8, 0xFFFFFFFF),     # TRAP #0 from user mode: the ISP intact
        (0x3018, 0x000037F8, 0xFFFFFFFF),     # ... and the USP
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3s':
    # KNOWN ISSUES 28's sibling: b3n for cpSAVE - an FSAVE that finds the
    # 68882 busy takes level 1 (frame $0 at the FSAVE, to start it again);
    # level 2 pending at the level-1 handler's first instruction must stack
    # that handler's address (cp_trap_pc, as cp_f9, was cleared only at the
    # next instruction); then the FSAVE runs again and the FSIN completes
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x47F8, 0x3400)                    # lea $3400.w,a3
    a.emit(0x46FC, 0x2000)                    # move.w #$2000,sr     interrupts on
    a.emit(0xF200, 0x5C32)                    # fmovecr.x #$32,fp0   1.0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released, running
    a.label('FSV'); a.emit(0xF323)            # fsave -(a3)          not ready: level 1, then 2
    a.emit(0xF35B)                            # frestore (a3)+
    a.emit(0x21CB, 0x300C)                    # move.l a3,$300C.w
    a.emit(0xF238, 0x6400, 0x3040)            # fmove.s fp0,$3040.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    p = a.done()
    put(0x1000, p)
    put(4 * 25, L(0x2400))                    # level 1: count, its PC, drop
    put(0x2400, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x21EF, 0x0002, 0x3014,      # move.l 2(a7),$3014.w
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w
                 0x4E73])                     # rte
    put(4 * 26, L(0x2480))                    # level 2: count, its frame, level 1's count so far, drop
    put(0x2480, [0x52B8, 0x3020,              # addq.l #1,$3020.w
                 0x21EF, 0x0002, 0x3028,      # move.l 2(a7),$3028.w    PC
                 0x31EF, 0x0006, 0x302C,      # move.w 6(a7),$302C.w    format, offset
                 0x21F8, 0x3010, 0x3030,      # move.l $3010.w,$3030.w  level 1's count
                 0x21FC, 0x0000, 0x0001, 0x3F0C,   # move.l #1,$3F0C.w
                 0x4E73])                     # rte
    irq = 0xFFFFFFFC
    expect = [
        (0x3020, 0x00000001, 0xFFFFFFFF),     # level 2, once
        (0x3028, 0x00002400, 0xFFFFFFFF),     # ... its PC: level 1's handler, not yet run
        (0x302C, 0x00680000, 0xFFFF0000),     # ... format $0, vector 26
        (0x3030, 0x00000000, 0xFFFFFFFF),     # ... level 1's handler had not run
        (0x3010, 0x00000001, 0xFFFFFFFF),     # level 1's handler ran, once
        (0x3014, a.lab['FSV'], 0xFFFFFFFF),   # ... its frame: the FSAVE, to start again
        (0x300C, 0x00003400, 0xFFFFFFFF),     # (A3)+ back to $3400
        (0x3040, 0x3F576AA4, 0xFFFFFFFF),     # sin(1.0) through the save and restore
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3r':
    # KNOWN ISSUES 28 (A/UX fpstress: wrong FPU results, then user code in
    # supervisor mode): a user process's FPU loop - FSIN, FSQRT, FMOVE.D/.X
    # through -(A7) and (A7)+, A7 checked every pass - run twice, the second
    # time under the bench's random IRQs, whose handler does what a context
    # switch does with the FPU (FSAVE, FMOVEM of every register, other FPU
    # work, all restored, FRESTORE); the two sums must agree bit for bit
    N = int(os.environ.get('B3R_N', '60'))
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x4BF8, 0x3100)                    # lea $3100.w,a5       the results
    a.emit(0x41F8, 0x3800)                    # lea $3800.w,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts on
    a.emit(0x4EF8, 0x1800)                    # jmp $1800.w
    p = a.done()
    put(0x1000, p)
    u = Asm(0x1800)
    u.label('PASS')
    u.emit(0xF23C, 0x4100, *L(0))             # fmove.l #0,fp2
    u.emit(0x3E3C, N - 1)                     # move.w #N-1,d7
    u.label('L')
    u.emit(0xF207, 0x4000)                    # fmove.l d7,fp0
    u.emit(0xF23C, 0x5423, 0x3F50, 0x624D, 0xD2F1, 0xA9FC)   # fmul.d #0.001,fp0
    u.emit(0xF200, 0x000E)                    # fsin.x fp0
    u.emit(0xF227, 0x7400)                    # fmove.d fp0,-(a7)
    u.emit(0xF21F, 0x5480)                    # fmove.d (a7)+,fp1
    u.emit(0xF200, 0x0498)                    # fabs.x fp1
    u.emit(0xF200, 0x0484)                    # fsqrt.x fp1
    u.emit(0xF200, 0x0522)                    # fadd.x fp1,fp2
    u.emit(0xF227, 0x6900)                    # fmove.x fp2,-(a7)
    u.emit(0xF21F, 0x4980)                    # fmove.x (a7)+,fp3
    u.emit(0xF200, 0x0D38)                    # fcmp.x fp3,fp2
    u.br(0xF28E, 'BAD')                       # fbne.w BAD
    u.emit(0xBFFC, *L(0x3800))                # cmpa.l #$3800,a7
    u.br(0x6600, 'BAD')                       # bne.w BAD
    u.br(0x51CF, 'L')                         # dbra d7,L
    u.emit(0xF21D, 0x7500)                    # fmove.d fp2,(a5)+
    u.emit(0x4E41)                            # trap #1              the next pass (IRQs on)
    u.emit(0x0CB8, *L(2), 0x3020)             # cmpi.l #2,$3020.w
    u.br(0x6600, 'PASS')                      # bne.w PASS
    u.emit(0x2038, 0x3100, 0xB0B8, 0x3108)    # move.l $3100.w,d0; cmp.l $3108.w,d0
    u.br(0x6600, 'BAD')
    u.emit(0x2038, 0x3104, 0xB0B8, 0x310C)    # move.l $3104.w,d0; cmp.l $310C.w,d0
    u.br(0x6600, 'BAD')
    u.emit(0x4E40)                            # trap #0
    u.label('BAD'); u.emit(movel_abs(1, 0x3018))
    u.emit(0x4E40)                            # trap #0
    put(0x1800, u.done())
    put(4 * 25, L(0x2400))                    # the IRQ: a context switch's FPU work
    put(0x2400, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0xF327,                      # fsave -(a7)
                 0xF227, 0xE0FF,              # fmovem.x fp0-fp7,-(a7)
                 0xF227, 0xBC00,              # fmovem.l fpcr/fpsr/fpiar,-(a7)
                 0xF200, 0x5C32,              # fmovecr.x #$32,fp0   (another process's work)
                 0xF200, 0x5C8F,              # fmovecr.x #$0f,fp1
                 0xF200, 0x5D0F,              # fmovecr.x #$0f,fp2
                 0xF200, 0x0D22,              # fadd.x fp3,fp2
                 0xF21F, 0x9C00,              # fmovem.l (a7)+,fpcr/fpsr/fpiar
                 0xF21F, 0xD0FF,              # fmovem.x (a7)+,fp0-fp7
                 0xF35F,                      # frestore (a7)+
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w: the bench drops the IRQ
                 0x4E73])                     # rte
    put(4 * 26, L(0x2580))                    # level 2 (KNOWN ISSUES 28: nests on level 1): FPU work too
    put(0x2580, [0x52B8, 0x3028,              # addq.l #1,$3028.w
                 0xF327,                      # fsave -(a7)
                 0xF227, 0xE0FF,              # fmovem.x fp0-fp7,-(a7)
                 0xF200, 0x5D0F,              # fmovecr.x #$0f,fp2   (another process's work)
                 0xF21F, 0xD0FF,              # fmovem.x (a7)+,fp0-fp7
                 0xF35F,                      # frestore (a7)+
                 0x21FC, 0x0000, 0x0001, 0x3F0C,   # move.l #1,$3F0C.w: the bench drops it
                 0x4E73])                     # rte
    put(4 * 33, L(0x2480))                    # TRAP #1: count the pass; the first arms the IRQs
    put(0x2480, [0x52B8, 0x3020,              # addq.l #1,$3020.w
                 0x0CB8, 0x0000, 0x0001, 0x3020,   # cmpi.l #1,$3020.w
                 0x6608,                      # bne.s +8
                 0x21FC, 0x0000, 0x0001, 0x3F04,   # move.l #1,$3F04.w: random IRQs on
                 0x4E73])                     # rte
    put(4 * 32, L(0x2500))                    # TRAP #0: IRQs off, both stack pointers, a count check, stop
    put(0x2500, [0x21FC, 0x0000, 0x0001, 0x3F08,   # move.l #1,$3F08.w
                 0x21CF, 0x3014,              # move.l a7,$3014.w
                 0x4E68,                      # move.l usp,a0
                 0x21C8, 0x301C,              # move.l a0,$301C.w
                 0x0CB8, 0x0000, 0x0014, 0x3010,   # cmpi.l #20,$3010.w
                 0x6308,                      # bls.s +8
                 0x21FC, 0x0000, 0x0001, 0x3024,   # move.l #1,$3024.w: more than 20 IRQs
                 *movel_abs(0x600D0001, 0x3FF0),
                 0x4E72, 0x2700])             # stop #$2700
    irq = 0xFFFFFFFE
    expect = [
        (0x3018, 0x00000000, 0xFFFFFFFF),     # no BAD: every pass's A7 and FP3 = FP2, the two sums equal
        (0x3020, 0x00000002, 0xFFFFFFFF),     # two passes
        (0x3024, 0x00000001, 0xFFFFFFFF),     # more than 20 IRQs in the second
        (0x3014, 0x00007FF8, 0xFFFFFFFF),     # TRAP #0: the ISP intact
        (0x301C, 0x00003800, 0xFFFFFFFF),     # ... and the USP
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'b3x':
    # KNOWN ISSUES 38 (xeyes, 2026-10-21: resumed at an FPU store's d16 word
    # under constant program switching): b3r's two passes with xeyes's shapes
    # - FADD/FINTRZ then FMOVE.W FP0,-$5A(A6), a long store through
    # (d8,A6,D6.W), a double through (xxx).L after an FSIN, each read back
    # into the sum (no FPSR dependence: A/UX's switch saves FPCR only) - the
    # level-1 handler A/UX's switch exactly (unix.dis fpsave/fprest $547D6):
    # FSAVE, FPCR and FP0-FP7 only after a non-null frame; the other
    # process's FRESTORE, its FPU work (an integer store through (d16,A1),
    # an FSIN left running), its FSAVE; then this process's FPCR, FP0-FP7
    # and FRESTORE; RTE.  +IRQSEED=<hex> varies the interrupts' timing.
    N = int(os.environ.get('B3R_N', '60'))
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x4BF8, 0x3100)                    # lea $3100.w,a5       the results
    a.emit(0x41F8, 0x3800)                    # lea $3800.w,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts on
    a.emit(0x4EF8, 0x1800)                    # jmp $1800.w
    p = a.done()
    put(0x1000, p)
    u = Asm(0x1800)
    u.label('PASS')
    u.emit(0xF23C, 0x4100, *L(0))             # fmove.l #0,fp2
    u.emit(0x3E3C, N - 1)                     # move.w #N-1,d7
    u.emit(0x4DF8, 0x3A00)                    # lea $3A00.w,a6
    u.emit(0x7C00)                            # moveq #0,d6
    u.label('L')
    u.emit(0xF207, 0x4000)                    # fmove.l d7,fp0
    u.emit(0xF23C, 0x5423, 0x3FF5, 0xEB85, 0x1EB8, 0x51EC)   # fmul.d #1.37,fp0
    u.emit(0xF23C, 0x5422, 0x3FE0, 0, 0, 0)   # fadd.d #0.5,fp0     (xeyes $FFA)
    u.emit(0xF200, 0x0003)                    # fintrz fp0          (xeyes $1006)
    u.emit(0xF22E, 0x7000, 0xFFA6)            # fmove.w fp0,-$5a(a6) (xeyes $100A)
    u.emit(0xF236, 0x6000, 0x60C0)            # fmove.l fp0,(-$40,a6,d6.w)
    u.emit(0xF200, 0x000E)                    # fsin.x fp0          (running)
    u.emit(0xF239, 0x7400, 0x0000, 0x3B00)    # fmove.d fp0,$3b00.l
    u.emit(0xF22E, 0x5080, 0xFFA6)            # fmove.w -$5a(a6),fp1
    u.emit(0xF200, 0x0522)                    # fadd.x fp1,fp2
    u.emit(0xF236, 0x4180, 0x60C0)            # fmove.l (-$40,a6,d6.w),fp3
    u.emit(0xF200, 0x0D22)                    # fadd.x fp3,fp2
    u.emit(0xF239, 0x5600, 0x0000, 0x3B00)    # fmove.d $3b00.l,fp4
    u.emit(0xF200, 0x1122)                    # fadd.x fp4,fp2
    u.br(0x51CF, 'L')                         # dbra d7,L
    u.emit(0xF21D, 0x7500)                    # fmove.d fp2,(a5)+
    u.emit(0x4E41)                            # trap #1              the next pass (IRQs on)
    u.emit(0x0CB8, *L(2), 0x3020)             # cmpi.l #2,$3020.w
    u.br(0x6600, 'PASS')                      # bne.w PASS
    u.emit(0x2038, 0x3100, 0xB0B8, 0x3108)    # move.l $3100.w,d0; cmp.l $3108.w,d0
    u.br(0x6600, 'BAD')
    u.emit(0x2038, 0x3104, 0xB0B8, 0x310C)    # move.l $3104.w,d0; cmp.l $310C.w,d0
    u.br(0x6600, 'BAD')
    u.emit(0x4E40)                            # trap #0
    u.label('BAD'); u.emit(movel_abs(1, 0x3018))
    u.emit(0x4E40)                            # trap #0
    put(0x1800, u.done())
    put(4 * 25, L(0x2600))                    # the IRQ: A/UX's context switch with the FPU
    put(0x2600, [0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x48E7, 0x80C0,              # movem.l d0/a0-a1,-(a7)
                 0x41F8, 0x5000,              # lea $5000.w,a0      fpsave: this process's frame
                 0xF310,                      # fsave (a0)
                 0x4A10,                      # tst.b (a0)
                 0x6710,                      # beq.s +16           (null: nothing more)
                 0x41F8, 0x4F00,              # lea $4F00.w,a0
                 0xF210, 0xB000,              # fmove.l fpcr,(a0)
                 0x41F8, 0x4F10,              # lea $4F10.w,a0
                 0xF210, 0xF0FF,              # fmovem.x fp0-fp7,(a0)
                 0x43F8, 0x5200,              # lea $5200.w,a1      the other process: fprest
                 0xF351,                      # frestore (a1)
                 0x43F8, 0x3C80,              # lea $3C80.w,a1      its FPU work
                 0xF200, 0x5C32,              # fmovecr.x #$32,fp0
                 0xF200, 0x0022,              # fadd.x fp0,fp0
                 0xF200, 0x0003,              # fintrz fp0
                 0xF229, 0x7000, 0xFFF0,      # fmove.w fp0,-$10(a1)
                 0xF200, 0x000E,              # fsin.x fp0          (left running)
                 0x43F8, 0x5200,              # lea $5200.w,a1      its fpsave
                 0xF311,                      # fsave (a1)
                 0x43F8, 0x5000,              # lea $5000.w,a1      fprest: this process
                 0x4A11,                      # tst.b (a1)
                 0x6710,                      # beq.s +16
                 0x41F8, 0x4F00,              # lea $4F00.w,a0
                 0xF210, 0x9000,              # fmove.l (a0),fpcr
                 0x41F8, 0x4F10,              # lea $4F10.w,a0
                 0xF210, 0xD0FF,              # fmovem.x (a0),fp0-fp7
                 0xF351,                      # frestore (a1)
                 0x4CDF, 0x0301,              # movem.l (a7)+,d0/a0-a1
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w: the bench drops the IRQ
                 0x4E73])                     # rte
    put(4 * 26, L(0x2580))                    # level 2 (b3r's): nests on level 1, FPU work too
    put(0x2580, [0x52B8, 0x3028,
                 0xF327, 0xF227, 0xE0FF, 0xF200, 0x5D0F, 0xF21F, 0xD0FF, 0xF35F,
                 0x21FC, 0x0000, 0x0001, 0x3F0C,
                 0x4E73])
    put(4 * 33, L(0x2480))                    # TRAP #1: count the pass; the first arms the IRQs
    put(0x2480, [0x52B8, 0x3020, 0x0CB8, 0x0000, 0x0001, 0x3020, 0x6608,
                 0x21FC, 0x0000, 0x0001, 0x3F04, 0x4E73])
    put(4 * 32, L(0x2500))                    # TRAP #0: as b3r's
    put(0x2500, [0x21FC, 0x0000, 0x0001, 0x3F08, 0x21CF, 0x3014, 0x4E68, 0x21C8, 0x301C,
                 0x0CB8, 0x0000, 0x0014, 0x3010, 0x6308,
                 0x21FC, 0x0000, 0x0001, 0x3024,
                 *movel_abs(0x600D0001, 0x3FF0),
                 0x4E72, 0x2700])
    irq = 0xFFFFFFFB if os.environ.get('B3X_DLG') == '1' else 0xFFFFFFFE   # B3X_DLG=1: a switch at every suspended dialog
    expect = [
        (0x3018, 0x00000000, 0xFFFFFFFF),     # no BAD: the two passes' sums equal
        (0x3020, 0x00000002, 0xFFFFFFFF),     # two passes
        (0x3024, 0x00000001, 0xFFFFFFFF),     # more than 20 IRQs in the second
        (0x3014, 0x00007FF8, 0xFFFFFFFF),     # TRAP #0: the ISP intact
        (0x301C, 0x00003800, 0xFFFFFFFF),     # ... and the USP
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),     # no stray exception (a d16 word run: the F-line stub)
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
elif MODE == 'b5u':
    # KNOWN ISSUES 28: b5d's PMMU in USER mode, and the two resumes chained,
    # as A/UX makes them - an FMOVE.D FP0,-(A7) behind an FSIN takes the
    # bench's IRQ at its come-again (frame $9, RTE -> cp_rte), and the
    # resumed dialog's write then page-faults on the user stack's page 9
    # (long frame, b5d's pager handler, RTE -> cp_rsm); A7, the double and
    # both stack pointers at the TRAP #0 must come out right
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0x41F9, *L(0xA000))                # lea $A000,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts on
    a.emit(0xF23C, 0x4000, *L(1))             # fmove.l #1,fp0
    a.emit(0xF200, 0x000E)                    # fsin.x fp0           released, running
    a.label('FM1'); a.emit(0xF227, 0x7400)    # fmove.d fp0,-(a7)    IRQ at the come-again, then page 9 faults
    a.emit(0x21CF, 0x3004)                    # move.l a7,$3004.w
    a.emit(0x21D7, 0x3008)                    # move.l (a7),$3008.w
    a.emit(0x21EF, 0x0004, 0x300C)            # move.l 4(a7),$300C.w
    a.emit(0x4E40)                            # trap #0
    p = a.done()
    put(0x1000, p)
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n in range(32):
        if n != 9:
            put(0x6800 + 4 * n, L((n << 12) | 1))        # C[n]: page n, valid; 9 (the user stack's) not
    put(4 * 2, L(0x2400))                     # b5d's pager handler
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
    put(4 * 25, L(0x2480))                    # the bench's IRQ: count, format word, then drop it
    put(0x2480, [0x52B8, 0x3060,              # addq.l #1,$3060.w
                 0x31EF, 0x0006, 0x3064,      # move.w 6(a7),$3064.w
                 0x21FC, 0x0000, 0x0001, 0x3F00,   # move.l #1,$3F00.w
                 0x4E73])                     # rte
    put(4 * 32, L(0x2500))                    # TRAP #0: both stack pointers, then stop
    put(0x2500, [0x21CF, 0x3014,              # move.l a7,$3014.w
                 0x4E68,                      # move.l usp,a0
                 0x21C8, 0x3018,              # move.l a0,$3018.w
                 *movel_abs(0x600D0001, 0x3FF0),
                 0x4E72, 0x2700])             # stop #$2700
    irq = a.lab['FM1']
    expect = [
        (0x3060, 0x00000001, 0xFFFFFFFF),     # the IRQ, once
        (0x3064, 0x90640000, 0xFFFF0000),     # ... frame $9 (inside FM1's dialog)
        (0x3010, 0x00000001, 0xFFFFFFFF),     # one page fault
        (0x3020, 0xB0080000, 0xFFFF0000),     # ... a long frame, vector 2
        (0x3024, 0x00009FF8, 0xFFFFFFFF),     # ... at the USER stack's -8
        (0x3004, 0x00009FF8, 0xFFFFFFFF),     # A7 = USP - 8
        (0x3008, 0x3FEAED54, 0xFFFFFFFF),     # sin(1.0) on the user stack
        (0x300C, 0x8F090CEE, 0xFFFFFFFF),
        (0x3014, 0x00007FF8, 0xFFFFFFFF),     # TRAP #0: the ISP intact
        (0x3018, 0x00009FF8, 0xFFFFFFFF),     # ... and the USP
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE in ('fsw', 'fswi'):
    # scan 3 (2026-10-18, the bug-class scans before the next test releases):
    # an FPU instruction's MEMORY operand page-faulting, in user mode as A/UX
    # runs FPU code - each case runs one instruction twice through the same
    # subroutine (so FPIAR is the same): its operand at FSW_R + off (resident)
    # and at FSW_P + off, the page at FSW_P invalid (FSW_WP=1: valid but
    # write-protected, copy-on-write) and the page below resident, so an
    # operand that straddles faults part way through its dialog's transfers.
    # FP0-FP7, FPCR/FPSR/FPIAR, A6 relative to the operand and the 192 bytes
    # around each operand are compared; $3100 = 0 when equal.  One case a
    # run: FSW=k (FSWLIST=1 lists them); FSW_SANITY=1 plants a difference;
    # B3_CACR the cache control register first (A/UX's $2101).
    FSW_R, FSW_P, FSW_INIT, FSW_O1, FSW_O2 = 0xC800, 0xE000, 0x4000, 0x4400, 0x4600
    SZ = {'L': (0, 4), 'S': (1, 4), 'X': (2, 12), 'P': (3, 12), 'W': (4, 2), 'D': (5, 8), 'B': (6, 1)}
    insns = []                                 # (words, adj, footprint, writes, what)
    for n, (k, fl) in SZ.items():
        insns.append(([0xF216, 0x4000 | k << 10 | 0x80], 0, fl, 0, 'FMOVE.%s (A6),FP1' % n))
        insns.append(([0xF216, 0x6000 | k << 10 | 0x80], 0, fl, 1, 'FMOVE.%s FP1,(A6)' % n))
    for n in 'SDX':
        k, fl = SZ[n]
        insns.append(([0xF216, 0x4000 | k << 10 | 0x80 | 0x22], 0, fl, 0, 'FADD.%s (A6),FP1' % n))
    insns += [([0xF216, 0x4880 | 0x38], 0, 12, 0, 'FCMP.X (A6),FP1'),
              ([0xF216, 0x4880 | 0x23], 0, 12, 0, 'FMUL.X (A6),FP1'),
              ([0xF21E, 0x4880], 0, 12, 0, 'FMOVE.X (A6)+,FP1'),
              ([0xF226, 0x6880], 12, 12, 1, 'FMOVE.X FP1,-(A6)'),
              ([0xF216, 0xD03C], 0, 48, 0, 'FMOVEM.X (A6),FP2-FP5'),
              ([0xF21E, 0xD03C], 0, 48, 0, 'FMOVEM.X (A6)+,FP2-FP5'),
              ([0xF216, 0xF03C], 0, 48, 1, 'FMOVEM.X FP2-FP5,(A6)'),
              ([0xF226, 0xE03C], 48, 48, 1, 'FMOVEM.X FP2-FP5,-(A6)'),
              ([0xF216, 0x8C00], 0, 8, 0, 'FMOVEM.L (A6),FPSR/FPIAR'),
              ([0xF216, 0xBC00], 0, 12, 1, 'FMOVEM.L FPCR/FPSR/FPIAR,(A6)'),
              ([0xF256, 0x0001], 0, 1, 1, 'FSEQ (A6)'),
              ([0xF256, 0x000F], 0, 1, 1, 'FST (A6)')]
    for n, (k, fl) in SZ.items():              # (d16,An): an extension word after the command word (xeyes, 2026-10-21)
        insns.append(([0xF22E, 0x4000 | k << 10 | 0x80, 0xFFE0], 0x20, fl, 0, 'FMOVE.%s -$20(A6),FP1' % n))
        insns.append(([0xF22E, 0x6000 | k << 10 | 0x80, 0xFFE0], 0x20, fl, 1, 'FMOVE.%s FP1,-$20(A6)' % n))
    cases = []
    for ws, adj, fl, wr, what in insns:
        offs = []
        for o in (0, -1, -2, -3, -(fl // 2) & ~1, -(fl - 1), -(fl - 2), -(fl - 4)):
            if -fl < o <= 0 and o not in offs:
                offs.append(o)
        for o in offs:
            cases.append((ws, adj, fl, wr, o, '%s at P%+d' % (what, o)))
    if os.environ.get('FSWLIST'):
        for k, c in enumerate(cases):
            print('%3d %s' % (k, c[5]))
        sys.exit(0)
    ws, adj, fl, wr, off, what = cases[int(os.environ['FSW'])]
    WPM = os.environ.get('FSW_WP') == '1'
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr (B3_CACR)
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0x41F9, *L(0xA000))                # lea $A000,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user
    a.label('U')
    a.emit(0x7E00)                            # moveq #0,d7          the differences
    for base, out in ((FSW_R, FSW_O1), (FSW_P, FSW_O2)):
        a.emit(0x4BF9, *L(base + off))        # lea base+off,a5
        a.emit(0x4DF9, *L(base + off + adj))  # lea base+off+adj,a6
        a.br(0x6100, 'RUN')                   # bsr RUN
        a.emit(0x41F9, *L(out))               # lea out,a0
        a.emit(0xF210, 0xF0FF)                # fmovem.x fp0-fp7,(a0)
        a.emit(0xF228, 0xBC00, 0x0060)        # fmovem.l fpcr/fpsr/fpiar,$60(a0)
        a.emit(0x214E, 0x006C)                # move.l a6,$6C(a0)    (relative: RUN subtracts A5)
    for lo1, lo2, n in ((FSW_O1, FSW_O2, 28), (FSW_R - 64, FSW_P - 64, 48)):
        a.emit(0x41F9, *L(lo1), 0x43F9, *L(lo2))   # lea; lea
        a.emit(0x303C, n - 1)                 # move.w #n-1,d0
        a.label('C%x' % lo1); a.emit(0xB388)  # cmpm.l (a0)+,(a1)+
        a.br(0x56C8, 'C%x' % lo1)             # dbne d0,C
        a.emit(0x56C1, 0x8E01)                # sne d1; or.b d1,d7
        a.emit(0xE38F)                        # lsl.l #1,d7: which compare
    a.emit(0x21C7, 0x3100)                    # move.l d7,$3100.w
    a.emit(0x4E40)                            # trap #0
    a.label('RUN')
    a.emit(0x41F8, FSW_INIT)                  # lea INIT.w,a0
    a.emit(0xF210, 0xD0FF)                    # fmovem.x (a0),fp0-fp7
    a.emit(0xF23C, 0x8800, 0, 0)              # fmove.l #0,fpsr
    a.label('INSN'); a.emit(*ws)              # THE INSTRUCTION
    a.emit(0x9DCD)                            # suba.l a5,a6
    a.emit(0x4E75)                            # rts
    p = a.done()
    put(0x1000, p)
    ucheck = ([(a.lab['U'], 0x1000 + 2 * len(p) + 16)],   # (code exact: the mode check; the prefetch's slack below as data)
              [((a.lab['U'] & ~3) - 4, a.lab['U']), (0x3100, 0x3104), (FSW_R - 64, FSW_R + 128), (FSW_P - 64, FSW_P + 128), (FSW_INIT, FSW_INIT + 0x60),
               (FSW_O1, FSW_O1 + 0x70), (FSW_O2, FSW_O2 + 0x70), (0x9F00, 0xA000)])
    vals = [0x3FFF0000, 0xC0000000, 0, 0x40000000, 0xA0000000, 0x00001234, 0xBFFE0000, 0xD5555555, 0x55555555,
            0x40130000, 0x8BADF00D, 0x00000000, 0x3FFC0000, 0xCCCCCCCC, 0xCCCCCCCD, 0x00000000, 0x00000000, 0,
            0x7FFF0000, 0, 0, 0x401E0000, 0xFFFFFFFF, 0xFFFFFFFE]
    for i, v in enumerate(vals):
        put(FSW_INIT + 4 * i, L(v))           # FP0-FP7: 1.5, 2.5.., -0.83, ..., 0, +inf, 2^31-ish
    import random
    rnd = random.Random(31)
    win = [rnd.randrange(0, 65536) for _ in range(96)]   # 192 bytes
    put(FSW_R - 64, win)
    if os.environ.get('FSW_SANITY') == '1':
        win = win[:40] + [win[40] ^ 0x5A5A] + win[41:]
    put(FSW_P - 64, win)
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n in range(32):
        if n == FSW_P >> 12:
            put(0x6800 + 4 * n, L((n << 12) | 5) if WPM else L(0))   # WP, or invalid
        else:
            put(0x6800 + 4 * n, L((n << 12) | 1))        # C[n]: page n, valid
    put(4 * 2, L(0x2400))                     # b5d's pager handler, saving what it uses (the user's D5-D7/A5-A6)
    put(0x2400, [0x48E7, 0x0706,              # movem.l d5-d7/a5-a6,-(a7): the frame now at 20(a7)
                 0x2E38, 0x3010, 0xE98F,      # move.l $3010.w,d7; lsl.l #4,d7
                 0x4DF8, 0x3020, 0xDDC7,      # lea $3020.w,a6; adda.l d7,a6
                 0x3CAF, 0x001A,              # move.w 26(a7),(a6)
                 0x3D6F, 0x001E, 0x0002,      # move.w 30(a7),2(a6)
                 0x2D6F, 0x0024, 0x0004,      # move.l 36(a7),4(a6)
                 0x2D6F, 0x0016, 0x0008,      # move.l 22(a7),8(a6)
                 0x2C2F, 0x0024,              # move.l 36(a7),d6    the fault address
                 0x2A06,                      # move.l d6,d5
                 0x0285, 0xFFFF, 0xF000,      # andi.l #$FFFFF000,d5
                 0x5285,                      # addq.l #1,d5        a valid page descriptor
                 0xE08E, 0xE48E,              # lsr.l #8,d6; lsr.l #2,d6
                 0x0206, 0x00FC,              # andi.b #$FC,d6      its entry's offset
                 0x4BF8, 0x6800,              # lea $6800.w,a5
                 0x2B85, 0x6000,              # move.l d5,(0,a5,d6.w)
                 0xF000, 0x2400,              # pflusha
                 0x52B8, 0x3010,              # addq.l #1,$3010.w
                 0x4CDF, 0x60E0,              # movem.l (a7)+,d5-d7/a5-a6
                 0x4E73])                     # rte
    put(4 * 32, L(0x2500))                    # TRAP #0: stop
    put(0x2500, [*movel_abs(0x600D0001, 0x3FF0), 0x4E72, 0x2700])
    faults = 0 if (WPM and not wr) else 1
    expect = [
        (0x3100, 0x00000000, 0xFFFFFFFF),     # the registers, then the memory windows, the same
        (0x3010, faults, 0xFFFFFFFF),         # one page fault (none: a read of a write-protected page)
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
    if os.environ.get('FSW_DUMP') == '1':      # every saved long printed (as failures)
        expect += [(o + 4 * i, 0xDEADBEEF, 0xFFFFFFFF) for o in (FSW_O1, FSW_O2) for i in range(28)]
    if MODE == 'fswi':
        # class 4b (2026-10-26): the fsw case's faulting run ITERATED, a level-1
        # interrupt at a different clock of each (offsets.txt, the bench's
        # +IRQLOOP: iteration i > 0 at offset i-1 after its marker) - every
        # iteration's registers and window must be the reference's, one
        # interrupt taken, the page fault(s) as fsw's.  Each iteration's TRAP #1
        # (supervisor) restores the window from a pristine copy ($5000),
        # invalidates (or write-protects) the page again and flushes the ATC.
        offs = [int(x) for x in open('offsets.txt').read().split()] if os.path.exists('offsets.txt') else []
        iters = 1 + len(offs)
        put(0x3014, L(iters))
        put(0x5000, [x for x in (win if os.environ.get('FSW_SANITY') != '1' else win)])   # (the pristine window)
        a = Asm(0x1000)
        a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr
        a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
        a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
        a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc
        a.emit(0x41F9, *L(0xA000))                # lea $A000,a0
        a.emit(0x4E60)                            # move.l a0,usp
        a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user, interrupts open
        a.label('U')
        a.emit(0x4BF9, *L(FSW_R + off))           # the reference: lea R+off,a5
        a.emit(0x4DF9, *L(FSW_R + off + adj))     # lea R+off+adj,a6
        a.br(0x6100, 'RUN')                       # bsr RUN
        a.emit(0x41F9, *L(FSW_O1))                # lea O1,a0
        a.emit(0xF210, 0xF0FF)                    # fmovem.x fp0-fp7,(a0)
        a.emit(0xF228, 0xBC00, 0x0060)            # fmovem.l fpcr/fpsr/fpiar,$60(a0)
        a.emit(0x214E, 0x006C)                    # move.l a6,$6C(a0)
        a.emit(0x7800)                            # moveq #0,d4          the iteration
        a.label('LOOP')
        a.emit(0x4E41)                            # trap #1              window, page, ATC, counts
        a.emit(0x21C4, 0x3F90)                    # move.l d4,$3F90.w    the marker: the bench's clock 0
        a.emit(0x4BF9, *L(FSW_P + off))           # lea P+off,a5
        a.emit(0x4DF9, *L(FSW_P + off + adj))     # lea P+off+adj,a6
        a.br(0x6100, 'RUN')                       # bsr RUN
        a.emit(0x41F9, *L(FSW_O2))                # lea O2,a0
        a.emit(0xF210, 0xF0FF)                    # fmovem.x fp0-fp7,(a0)
        a.emit(0xF228, 0xBC00, 0x0060)            # fmovem.l fpcr/fpsr/fpiar,$60(a0)
        a.emit(0x214E, 0x006C)                    # move.l a6,$6C(a0)
        a.emit(0x7E00)                            # moveq #0,d7          the differences
        for lo1, lo2, n in ((FSW_O1, FSW_O2, 28), (FSW_R - 64, FSW_P - 64, 48)):
            a.emit(0x41F9, *L(lo1), 0x43F9, *L(lo2))   # lea; lea
            a.emit(0x303C, n - 1)                 # move.w #n-1,d0
            a.label('C%x' % lo1); a.emit(0xB388)  # cmpm.l (a0)+,(a1)+
            a.br(0x56C8, 'C%x' % lo1)             # dbne d0,C
            a.emit(0x56C1, 0x8E01)                # sne d1; or.b d1,d7
            a.emit(0xE38F)                        # lsl.l #1,d7
        a.emit(0x2004, 0xE588)                    # move.l d4,d0; lsl.l #2,d0
        a.emit(0x41F9, *L(0x7000))                # lea $7000,a0
        a.emit(0x7200, 0x1238, 0x3013, 0x4841)    # moveq #0,d1; move.b $3013.w,d1; swap d1   the page faults
        a.emit(0x1238, 0x3F1B, 0xE149, 0x8E81)    # move.b $3F1B.w,d1; lsl.w #8,d1; or.l d1,d7   the interrupts
        a.emit(0x2187, 0x0800)                    # move.l d7,(0,a0,d0.l)   faults<<16 | interrupts<<8 | differences
        a.emit(0x5284)                            # addq.l #1,d4
        a.emit(0xB8B8, 0x3014)                    # cmp.l $3014.w,d4
        a.br(0x6600, 'LOOP')                      # bne.w LOOP
        a.emit(0x42B8, 0x3100)                    # clr.l $3100.w        (fsw's verdict word: the tables say it)
        a.emit(0x4E40)                            # trap #0
        a.label('RUN')
        a.emit(0x41F8, FSW_INIT)                  # lea INIT.w,a0
        a.emit(0xF210, 0xD0FF)                    # fmovem.x (a0),fp0-fp7
        a.emit(0xF23C, 0x8800, 0, 0)              # fmove.l #0,fpsr
        a.label('INSN'); a.emit(*ws)              # THE INSTRUCTION
        a.emit(0x9DCD)                            # suba.l a5,a6
        a.emit(0x4E75)                            # rts
        p = a.done()
        put(0x1000, p)
        put(0x3F1C, L(a.lab['INSN']) + L(a.lab['INSN'] + 2 * len(ws)))   # the instruction and the next: the bench's EVT
        n_p = FSW_P >> 12
        put(4 * 33, L(0x2700))                    # TRAP #1 (supervisor)
        put(0x2700, [0x48E7, 0x80C0,              # movem.l d0/a0-a1,-(a7)
                     0x41F9, *L(0x5000), 0x43F9, *L(FSW_P - 64),   # lea pristine,a0; lea P-64,a1
                     0x303C, 47,                  # move.w #47,d0
                     0x22D8, 0x51C8, 0xFFFC,      # move.l (a0)+,(a1)+; dbf d0,*-2
                     *movel_abs(((n_p << 12) | 5) if WPM else 0, 0x6800 + 4 * n_p),   # the page: WP, or invalid
                     0xF000, 0x2400,              # pflusha
                     0x42B8, 0x3010, 0x42B8, 0x3F18,   # clr.l $3010.w; clr.l $3F18.w
                     0x4CDF, 0x0301,              # movem.l (a7)+,d0/a0-a1
                     0x4E73])                     # rte
        put(4 * 25, L(0x2600))                    # level 1: drop it, count it
        put(0x2600, [*movel_abs(1, 0x3F00), 0x52B8, 0x3F18, 0x4E73])
        ucheck = ([(a.lab['U'], 0x1000 + 2 * len(p) + 16)],
                  [((a.lab['U'] & ~3) - 4, a.lab['U']), (0x3010, 0x3018), (0x3F18, 0x3F1C), (0x3F90, 0x3F94),
                   (0x3100, 0x3104), (FSW_R - 64, FSW_R + 128), (FSW_P - 64, FSW_P + 128), (FSW_INIT, FSW_INIT + 0x60),
                   (FSW_O1, FSW_O1 + 0x70), (FSW_O2, FSW_O2 + 0x70), (0x7000, 0x7C00), (0x9F00, 0xA000)])
        expect = [(0x3FF0, 0x600D0001, 0xFFFFFFFF)]
        assert iters <= 0x300, iters
        for i in range(iters):                    # the reference's registers and window; one interrupt (none in iteration 0); fsw's page faults
            expect += [(0x7000 + 4 * i, faults << 16 | (1 if i else 0) << 8, 0xFFFFFFFF)]
elif MODE == 'fif':
    # KNOWN ISSUES 38's second candidate (xeyes resumed at an FPU store's d16
    # word): the FETCH of an FPU instruction's extension words or immediate
    # data page-faulting DURING its dialog - the twin of isweep (KNOWN ISSUES
    # 29) for F-line instructions.  Each case runs the instruction twice, in
    # user mode: from RUN_R at $1800 (resident) on the operand at FIF_R, and
    # from a copy placed so its first k words end at $D000 and the rest are
    # on page $D000, invalid (the pager handler makes it valid), on the
    # operand at FIF_Q; FIF busy: an FSIN FP7 runs first, so the dialog
    # suspends (come-again) before its late fetches.  FP0-FP7, FPCR, FPSR,
    # FPIAR (relative to its instruction), A6 relative and the operand windows
    # compared ($3100 = 0), one page fault, no stray exception.
    FIF_R, FIF_Q, FIF_INIT, FIF_O1, FIF_O2, FIF_PG = 0x5800, 0x7800, 0x4000, 0x4400, 0x4600, 0xD000
    SZ = {'L': (0, 4), 'S': (1, 4), 'X': (2, 12), 'W': (4, 2), 'D': (5, 8), 'B': (6, 1)}
    def eas(base, ext_at):
        """(name, EA field, extension words, A6) for an operand at base; ext_at = the first extension word's address"""
        return [('-$20(A6)', 0x2E, [0xFFE0], base + 0x20),
                ('(-$20,A6,D6.W)', 0x36, [0x60E0], base + 0x20),
                ('($%X).W' % base, 0x38, [base], 0),
                ('($%X).L' % base, 0x39, [base >> 16, base & 0xFFFF], 0)]
    forms = []                                 # (what, builder(base, ext_at) -> (words, A6))
    for n, (k, fl) in SZ.items():
        for ei in range(4):
            def st(base, ext_at, k=k, ei=ei):
                nm, ea, ext, a6 = eas(base, ext_at)[ei]
                return [0xF200 | ea, 0x6000 | k << 10 | 0x80] + ext, a6
            def ld(base, ext_at, k=k, ei=ei):
                nm, ea, ext, a6 = eas(base, ext_at)[ei]
                return [0xF200 | ea, 0x4000 | k << 10 | 0x80] + ext, a6
            en = ['-$20(A6)', '(-$20,A6,D6.W)', '(xxx).W', '(xxx).L'][ei]
            forms.append(('FMOVE.%s FP1,%s' % (n, en), st))
            forms.append(('FMOVE.%s %s,FP1' % (n, en), ld))
        def pcrel(base, ext_at, k=k):
            return [0xF23A, 0x4000 | k << 10 | 0x80, (base - ext_at) & 0xFFFF], 0
        forms.append(('FMOVE.%s (d16,PC),FP1' % n, pcrel))
    IMM = {'L': [0x0001, 0x2345], 'S': [0x3FC0, 0x0000], 'W': [0x1234], 'B': [0x0042],
           'D': [0x3FE0, 0, 0, 0], 'X': [0x3FFF, 0, 0xC000, 0, 0, 0]}
    for n, iw in IMM.items():
        k = SZ[n][0]
        def imm(base, ext_at, k=k, iw=iw):
            return [0xF23C, 0x4000 | k << 10 | 0x80 | 0x22] + iw, 0      # FADD.<n> #imm,FP1
        forms.append(('FADD.%s #imm,FP1' % n, imm))
    # the FPU sweep gap's item 1 (2026-10-22): the remaining forms - split from
    # the first word on (the condition or command word's own fetch too); a
    # builder may return a tail, the word after the instruction a taken
    # branch skips (ADDQ.L #1,A6: a wrong decision shows in A6)
    PTRS = {FIF_R: 0x4800, FIF_Q: 0x4900}       # memory indirection: each run's pointer, holding its operand's address
    more = []
    for n, cmd in (('W', 0x6000 | 4 << 10 | 0x80), ('D', 0x6000 | 5 << 10 | 0x80)):
        more.append(('FMOVE.%s FP1,(-$20.L,A6) (full format, long bd)' % n,
                     lambda base, ext_at, cmd=cmd: ([0xF236, cmd, 0x0170, 0xFFFF, 0xFFE0], base + 0x20)))
        more.append(('FMOVE.%s FP1,([$10.W,A6]) (memory indirect)' % n,
                     lambda base, ext_at, cmd=cmd: ([0xF236, cmd, 0x0162, 0x0010, 0x0000], PTRS[base] - 0x10)))
    for n, cmd in (('W', 0x4000 | 4 << 10 | 0x80), ('D', 0x4000 | 5 << 10 | 0x80)):
        more.append(('FMOVE.%s (-$20.L,A6),FP1 (full format, long bd)' % n,
                     lambda base, ext_at, cmd=cmd: ([0xF236, cmd, 0x0170, 0xFFFF, 0xFFE0], base + 0x20)))
        more.append(('FMOVE.%s ([$10.W,A6]),FP1 (memory indirect)' % n,
                     lambda base, ext_at, cmd=cmd: ([0xF236, cmd, 0x0162, 0x0010, 0x0000], PTRS[base] - 0x10)))
    more += [('FBT.W (taken)', lambda base, ext_at: ([0xF28F, 0x0004], base, [0x528E])),
             ('FBT.L (taken)', lambda base, ext_at: ([0xF2CF, 0x0000, 0x0006], base, [0x528E])),
             ('FDBF D6 (D6 = 0: falls through)', lambda base, ext_at: ([0xF24E, 0x0000, 0x0004], base, [0x528E])),
             ('FTRAPF.W #$1234', lambda base, ext_at: ([0xF27A, 0x0000, 0x1234], base)),
             ('FST -$20(A6)', lambda base, ext_at: ([0xF26E, 0x000F, 0xFFE0], base + 0x20)),
             ('FMOVEM.X FP2-FP5,-$20(A6)', lambda base, ext_at: ([0xF22E, 0xF03C, 0xFFE0], base + 0x20)),
             ('FMOVEM.X -$20(A6),FP2-FP5', lambda base, ext_at: ([0xF22E, 0xD03C, 0xFFE0], base + 0x20)),
             ('FMOVE.L #$10,FPCR', lambda base, ext_at: ([0xF23C, 0x9000, 0x0000, 0x0010], base)),
             ('FMOVE.P FP1,-$20(A6){#5}', lambda base, ext_at: ([0xF22E, 0x6C80 | 5, 0xFFE0], base + 0x20)),
             ('FMOVE.P FP1,-$20(A6){D6}', lambda base, ext_at: ([0xF22E, 0x7C80 | 6 << 4, 0xFFE0], base + 0x20))]
    FIF_SUPER = os.environ.get('FIF_SUPER') == '1'   # KNOWN ISSUES 40's PMMU twin: the runs in supervisor mode, the PMMU forms added
    if FIF_SUPER:
        more += [('PMOVE.L TC,-$20(A6)', lambda base, ext_at: ([0xF02E, 0x4200, 0xFFE0], base + 0x20)),
                 ('PMOVE.L TC,(A6)', lambda base, ext_at: ([0xF016, 0x4200], base)),
                 ('PMOVE.W MMUSR,(A6)', lambda base, ext_at: ([0xF016, 0x6200], base)),
                 ('PFLUSHA', lambda base, ext_at: ([0xF000, 0x2400], base)),
                 # KNOWN ISSUES 41's class: the PMMU EA path's every form (a load to MMUSR stored back at (A5), the window's base)
                 ('PMOVE.L TC,(-$20,A6,D6.W)', lambda base, ext_at: ([0xF036, 0x4200, 0x60E0], base + 0x20)),
                 ('PMOVE.L TC,(xxx).W', lambda base, ext_at: ([0xF038, 0x4200, base], base)),
                 ('PMOVE.L TC,(xxx).L', lambda base, ext_at: ([0xF039, 0x4200, base >> 16, base & 0xFFFF], base)),
                 ('PMOVE.L TC,(-$20.L,A6) (full format, long bd)', lambda base, ext_at: ([0xF036, 0x4200, 0x0170, 0xFFFF, 0xFFE0], base + 0x20)),
                 ('PMOVE.L TC,([$10.W,A6]) (memory indirect)', lambda base, ext_at: ([0xF036, 0x4200, 0x0162, 0x0010, 0x0000], PTRS[base] - 0x10)),
                 ('PMOVE.W -$20(A6),MMUSR', lambda base, ext_at: ([0xF02E, 0x6000, 0xFFE0], base + 0x20, [0xF015, 0x6200])),
                 ('PMOVE.W (-$20,A6,D6.W),MMUSR', lambda base, ext_at: ([0xF036, 0x6000, 0x60E0], base + 0x20, [0xF015, 0x6200])),
                 ('PMOVE.W (xxx).L,MMUSR', lambda base, ext_at: ([0xF039, 0x6000, base >> 16, base & 0xFFFF], base, [0xF015, 0x6200])),
                 ('PMOVE.W (-$20.L,A6),MMUSR (full format, long bd)', lambda base, ext_at: ([0xF036, 0x6000, 0x0170, 0xFFFF, 0xFFE0], base + 0x20, [0xF015, 0x6200])),
                 ('PFLUSH #0,#0,-$20(A6)', lambda base, ext_at: ([0xF02E, 0x3810, 0xFFE0], base + 0x20)),
                 ('PTESTR #1,-$20(A6),#7', lambda base, ext_at: ([0xF02E, 0x9E11, 0xFFE0], base + 0x20, [0xF015, 0x6200])),
                 ('MOVE.L D6,(-$20.L,A6) (the integer twin of the full-format forms)', lambda base, ext_at: ([0x2D86, 0x0170, 0xFFFF, 0xFFE0], base + 0x20)),
                 ('PMOVE.L TC,([$10.L,A6]) (memory indirect, long bd)', lambda base, ext_at: ([0xF036, 0x4200, 0x0172, 0x0000, 0x0010, 0x0000], PTRS[base] - 0x10)),
                 ('PMOVE.L TC,([$10.W,A6],$20.L) (memory indirect, long od)', lambda base, ext_at: ([0xF036, 0x4200, 0x0163, 0x0010, 0x0000, 0x0020], PTRS[base] - 0x10)),
                 ('PMOVE.W ([$10.W,A6],$20.L),MMUSR (memory indirect, long od)', lambda base, ext_at: ([0xF036, 0x6000, 0x0163, 0x0010, 0x0000, 0x0020], PTRS[base] - 0x10, [0xF015, 0x6200]))]
    cases = []
    for what, b in forms + more:
        nw = len(b(FIF_R, 0x1802)[0])
        for kk in range(2 if (what, b) in forms else 1, nw):   # the words before the page boundary
            for busy in (0, 1):
                tag = (' [deferred: KI 42]' if what.startswith('PMOVE') and ('full format' in what or 'memory indirect' in what) else
                       ' [deferred: KI 43]' if what == 'PMOVE.W (xxx).L,MMUSR' else '')
                cases.append((what, b, kk, busy, '%s split after word %d%s%s' % (what, kk, ', the FPU busy' if busy else '', tag)))
    if os.environ.get('FIFLIST'):
        for i, c in enumerate(cases):
            print('%3d %s' % (i, c[4]))
        sys.exit(0)
    what, b, kk, busy, desc = cases[int(os.environ['FIF'])]
    def run_code(org, base):
        r = Asm(org)
        r.emit(0x41F8, FIF_INIT)              # lea INIT.w,a0
        r.emit(0xF210, 0xD0FF)                # fmovem.x (a0),fp0-fp7
        r.emit(0xF23C, 0x8800, 0, 0)          # fmove.l #0,fpsr
        r.emit(0x7C00)                        # moveq #0,d6
        if busy:
            r.emit(0xF200, 0x1F8E)            # fsin.x fp7: the FPU busy
        insn_at = org + 2 * len(r.w)
        res = b(base, insn_at + 4)
        return r, insn_at, res[0], res[1], (res[2] if len(res) > 2 else [])
    pre_words = 2 + 2 + 4 + 1 + (2 if busy else 0)
    org_q = FIF_PG - 2 * kk - 2 * pre_words
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0x41F9, *L(0xA000))                # lea $A000,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x2000 if os.environ.get('UCK_SANITY') == '2' or FIF_SUPER else 0x0000)
    if FIF_SUPER:
        a.emit(0x2E48)                        # movea.l a0,a7: the stack off FIF_Q's page (its M bit: PTEST's MMUSR)   # move.w #$0000,sr: user (UCK_SANITY=2: left supervisor - must FAIL)
    a.label('U')
    a.emit(0x7E00)                            # moveq #0,d7          the differences
    runs = []
    FIF_IRQ = os.environ.get('FIF_IRQ') == '1'   # A/UX's switch at the suspended dialog, then the fetch fault
    for org, base, out in ((0x1800, FIF_R, FIF_O1), (org_q, FIF_Q, FIF_O2)):
        if FIF_IRQ and base == FIF_Q:
            a.emit(*movel_abs(1, 0x3F04))     # the dialog interrupt armed: the faulting run only
        r, insn_at, ws, a6, tail = run_code(org, base)
        r.emit(*ws)                           # THE INSTRUCTION
        if tail:
            r.emit(*tail)                     # (a taken branch skips it)
        r.emit(0x9DCD)                        # suba.l a5,a6
        r.emit(0x4E75)                        # rts
        runs.append((org, r, insn_at))
        a.emit(0x4BF9, *L(PTRS[base] if 'memory indirect' in what else base))   # lea base,a5 (memory indirect: the pointer's address, as fsx)
        a.emit(0x4DF9, *L(a6 if a6 else base))   # lea A6,a6
        a.emit(0x4EB9, *L(org))               # jsr RUN
        a.emit(0x41F9, *L(out))               # lea out,a0
        a.emit(0xF210, 0xF0FF)                # fmovem.x fp0-fp7,(a0)
        a.emit(0xF228, 0xBC00, 0x0060)        # fmovem.l fpcr/fpsr/fpiar,$60(a0)
        if FIF_IRQ:
            a.emit(0x42A8, 0x0064)            # clr.l $64(a0): FPSR not compared (A/UX's switch does not save it)
        a.emit(0x214E, 0x006C)                # move.l a6,$6C(a0)
        if FIF_IRQ and base == FIF_Q:
            a.emit(*movel_abs(1, 0x3F08))     # disarmed
        a.emit(0x2028, 0x0068)                # move.l $68(a0),d0    FPIAR
        a.emit(0x670A)                        # beq.s +10: past the subi and the move
        a.emit(0x0480, *L(insn_at))           # subi.l #insn,d0
        a.emit(0x2140, 0x0068)                # move.l d0,$68(a0)
    for lo1, lo2, n in ((FIF_O1, FIF_O2, 28), (FIF_R - 64, FIF_Q - 64, 48)):
        a.emit(0x41F9, *L(lo1), 0x43F9, *L(lo2))   # lea; lea
        a.emit(0x303C, n - 1)                 # move.w #n-1,d0
        a.label('C%x' % lo1); a.emit(0xB388)  # cmpm.l (a0)+,(a1)+
        a.br(0x56C8, 'C%x' % lo1)             # dbne d0,C
        a.emit(0x56C1, 0x8E01)                # sne d1; or.b d1,d7
        a.emit(0xE38F)                        # lsl.l #1,d7
    a.emit(0x21C7, 0x3100)                    # move.l d7,$3100.w
    a.emit(0x4E40)                            # trap #0
    p = a.done()
    put(0x1000, p)
    ucode = [(a.lab['U'], 0x1000 + 2 * len(p) + 16)]   # (code exact: the mode check; the prefetch's slack below as data)
    uslack = [((a.lab['U'] & ~3) - 4, a.lab['U'])]
    for org, r, insn_at in runs:
        rw = r.done()
        put(org, rw)
        ucode.append((org, org + 2 * len(rw) + 16))
        uslack.append(((org & ~3) - 4, org))
    ucheck = (ucode, uslack + [(0x3100, 0x3104), (0x4800, 0x4804), (0x4900, 0x4904), (FIF_R - 64, FIF_R + 128), (FIF_Q - 64, FIF_Q + 128), (FIF_INIT, FIF_INIT + 0x60),
                      (FIF_O1, FIF_O1 + 0x70), (FIF_O2, FIF_O2 + 0x70), (0x9F00, 0xA000)] +
                     ([(0x3F00, 0x3F10)] if FIF_IRQ else []))
    if FIF_SUPER:
        ucheck = ([], [])                     # (supervisor code: the user-mode checks off)
    assert runs[1][2] + 2 * kk == FIF_PG, (hex(runs[1][2]), kk)
    vals = [0x3FFF0000, 0xC0000000, 0, 0x40000000, 0xA0000000, 0x00001234, 0xBFFE0000, 0xD5555555, 0x55555555,
            0x40130000, 0x8BADF00D, 0x00000000, 0x3FFC0000, 0xCCCCCCCC, 0xCCCCCCCD, 0x00000000, 0x00000000, 0,
            0x7FFF0000, 0, 0, 0x401E0000, 0xFFFFFFFF, 0xFFFFFFFE]
    for i, v in enumerate(vals):
        put(FIF_INIT + 4 * i, L(v))
    import random
    rnd = random.Random(38)
    win = [rnd.randrange(0, 65536) for _ in range(96)]
    put(0x4800, L(FIF_R)); put(0x4900, L(FIF_Q))   # the memory-indirect forms' pointers
    put(FIF_R - 64, win)
    if os.environ.get('FIF_SANITY') == '1':
        win = win[:40] + [win[40] ^ 0x5A5A] + win[41:]   # a planted difference (must FAIL)
    put(FIF_Q - 64, win)
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n in range(32):
        put(0x6800 + 4 * n, L(0) if n == FIF_PG >> 12 else L((n << 12) | 1))   # page $D000 invalid
    put(4 * 2, L(0x2400))                     # fsw's pager handler
    put(0x2400, [0x48E7, 0x0706, 0x2E38, 0x3010, 0xE98F, 0x4DF8, 0x3020, 0xDDC7,
                 0x3CAF, 0x001A, 0x3D6F, 0x001E, 0x0002, 0x2D6F, 0x0024, 0x0004, 0x2D6F, 0x0016, 0x0008,
                 0x2C2F, 0x0024, 0x2A06, 0x0285, 0xFFFF, 0xF000, 0x5285, 0xE08E, 0xE48E, 0x0206, 0x00FC,
                 0x4BF8, 0x6800, 0x2B85, 0x6000, 0xF000, 0x2400, 0x52B8, 0x3010, 0x4CDF, 0x60E0, 0x4E73])
    put(4 * 32, L(0x2500))                    # TRAP #0: stop
    put(0x2500, [*movel_abs(0x600D0001, 0x3FF0), 0x4E72, 0x2700])
    if FIF_IRQ:                               # b3x's handler: A/UX's switch (its count at $3030)
        put(4 * 25, L(0x2600))
        put(0x2600, [0x52B8, 0x3030, 0x48E7, 0x80C0,
                     0x41F8, 0x5000, 0xF310, 0x4A10, 0x6710,
                     0x41F8, 0x4F00, 0xF210, 0xB000, 0x41F8, 0x4F10, 0xF210, 0xF0FF,
                     0x43F8, 0x5200, 0xF351,
                     0x43F8, 0x3C80, 0xF200, 0x5C32, 0xF200, 0x0022, 0xF200, 0x0003,
                     0xF229, 0x7000, 0xFFF0, 0xF200, 0x000E,
                     0x43F8, 0x5200, 0xF311,
                     0x43F8, 0x5000, 0x4A11, 0x6710,
                     0x41F8, 0x4F00, 0xF210, 0x9000, 0x41F8, 0x4F10, 0xF210, 0xD0FF,
                     0xF351, 0x4CDF, 0x0301,
                     0x21FC, 0x0000, 0x0001, 0x3F00, 0x4E73])
        irq = 0xFFFFFFFB
    expect = [
        (0x3100, 0x00000000, 0xFFFFFFFF),     # the registers, then the memory windows, the same
        (0x3010, 0x00000001, 0xFFFFFFFF),     # one page fault: the instruction's own fetch
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),     # no stray exception (a run of an extension word: the F-line stub)
    ]
    if FIF_SUPER:                             # absolute checks: the pair compare passes two runs that are wrong alike (KNOWN ISSUES 42)
        off = 0x20 if 'long od' in what else 0
        for bse in (FIF_R, FIF_Q):
            wl = win if bse == FIF_R else (win[:40] + [win[40] ^ 0x5A5A] + win[41:] if os.environ.get('FIF_SANITY') == '1' else win)
            if what.startswith('PMOVE.L TC,'):
                expect.append((bse + off, 0x80C04880, 0xFFFFFFFF))      # TC landed at the operand
            elif what.startswith('PMOVE.W') and what.endswith('MMUSR') or 'MMUSR (' in what and what.startswith('PMOVE.W ('):
                expect.append((bse, (wl[32 + off // 2] & 0xEE47) << 16, 0xFFFF0000))   # the word the EA names, back at (A5) through MMUSR's implemented bits (UM fig. 9-38)
            elif what.startswith('PTESTR'):
                expect.append((bse, 0x0003 << 16, 0xFFFF0000))          # MMUSR: N = 3, nothing else
            elif what.startswith('MOVE.L D6,'):
                expect.append((bse, 0, 0xFFFFFFFF))                     # D6 = 0 at the operand
    if os.environ.get('FIF_DUMP') == '1':     # both runs' saved FP0-FP7, FPCR/FPSR/FPIAR, A6 printed (as failures)
        expect += [(o + 4 * i, 0xDEADBEEF, 0xFFFFFFFF) for o in (FIF_O1, FIF_O2) for i in range(28)]
elif MODE == 'fsx':
    # The FPU sweep gap's item 1 (2026-10-22): fsw's DATA faults over every EA
    # form - each run has its own copy of the code (as fif), so absolute,
    # PC-relative, full-format and memory-indirect forms can name their own
    # operand.  The reference on the resident operand at FSX_R, the faulting
    # run on FSX_P + off, the page at FSX_P invalid (FSX_WP=1: valid but
    # write-protected, the writes only) and the page below resident, so an
    # operand that straddles faults part way through its dialog's transfers;
    # 'ptr' forms put the memory-indirect POINTER on the invalid page instead
    # (the operand resident).  FP0-FP7, FPCR, FPSR, FPIAR (relative), A6
    # relative and the windows compared; the user-mode checks (ucheck.hex).
    FSX_R, FSX_P, FSX_INIT, FSX_O1, FSX_O2 = 0xC800, 0xE000, 0x4000, 0x4400, 0x4600
    FSX_T = 0xB800                             # the 'ptr' forms' operand (resident) for the faulting run
    WPM = os.environ.get('FSX_WP') == '1'
    SZ = {'L': (0, 4), 'S': (1, 4), 'X': (2, 12), 'P': (3, 12), 'W': (4, 2), 'D': (5, 8), 'B': (6, 1)}
    forms = []                                 # (what, footprint, writes, ptr, builder(opnd, ext_at, ptrat) -> (words, A6))
    for n, (k, fl) in SZ.items():
        st, ld = 0x6000 | k << 10 | 0x80, 0x4000 | k << 10 | 0x80
        for cmd, wr, dn in ((st, 1, 'FP1,%s'), (ld, 0, '%s,FP1')):
            if wr and n == 'P':
                cmd |= 5                       # the static k-factor +5
            forms += [(dn % '-$20(A6)', n, fl, wr, 0, lambda o, e, q, c=cmd: ([0xF22E, c, 0xFFE0], o + 0x20)),
                      (dn % '(-$20,A6,D6.W)', n, fl, wr, 0, lambda o, e, q, c=cmd: ([0xF236, c, 0x60E0], o + 0x20)),
                      (dn % '(xxx).L', n, fl, wr, 0, lambda o, e, q, c=cmd: ([0xF239, c, o >> 16, o & 0xFFFF], 0)),
                      (dn % '(-$20.L,A6) full', n, fl, wr, 0, lambda o, e, q, c=cmd: ([0xF236, c, 0x0170, 0xFFFF, 0xFFE0], o + 0x20)),
                      (dn % '([$10.W,A6]) indirect', n, fl, wr, 0, lambda o, e, q, c=cmd: ([0xF236, c, 0x0162, 0x0010, 0x0000], q - 0x10)),
                      (dn % '([$10.W,A6]) indirect, the pointer faulting', n, fl, wr, 1,
                       lambda o, e, q, c=cmd: ([0xF236, c, 0x0162, 0x0010, 0x0000], q - 0x10))]
            if not wr:
                forms.append((dn % '(d16,PC)', n, fl, 0, 0, lambda o, e, q, c=cmd: ([0xF23A, c, (o - e) & 0xFFFF], 0)))
    forms += [('FST -$20(A6)', 'B', 1, 1, 0, lambda o, e, q: ([0xF26E, 0x000F, 0xFFE0], o + 0x20)),
              ('FMOVEM.X FP2-FP5,-$20(A6)', 'X', 48, 1, 0, lambda o, e, q: ([0xF22E, 0xF03C, 0xFFE0], o + 0x20)),
              ('FMOVEM.X -$20(A6),FP2-FP5', 'X', 48, 0, 0, lambda o, e, q: ([0xF22E, 0xD03C, 0xFFE0], o + 0x20)),
              ('FMOVEM.L FPCR/FPSR/FPIAR,-$20(A6)', 'L', 12, 1, 0, lambda o, e, q: ([0xF22E, 0xBC00, 0xFFE0], o + 0x20)),
              ('FMOVE.P FP1,-$20(A6){D6}', 'P', 12, 1, 0, lambda o, e, q: ([0xF22E, 0x7C80 | 6 << 4, 0xFFE0], o + 0x20))]
    cases = []
    for what, n, fl, wr, ptr, b in forms:
        if WPM and (not wr or ptr):
            continue                           # write-protected: the writes only (a pointer's read never faults there)
        offs = []
        for o in ((0, -2) if ptr else (0, -1, -2, -3, -(fl // 2) & ~1, -(fl - 1), -(fl - 2), -(fl - 4))):
            if (ptr and o in (0, -2)) or (not ptr and -fl < o <= 0 and o not in offs):
                offs.append(o)
        for o in offs:
            cases.append((what, fl, wr, ptr, b, o, 'FMOVE.%s %s at P%+d' % (n, what, o) if not what.startswith(('FST', 'FMOVEM', 'FMOVE.P')) else '%s at P%+d' % (what, o)))
    if os.environ.get('FSXLIST'):
        for i, c in enumerate(cases):
            print('%3d %s' % (i, c[6]))
        sys.exit(0)
    what, fl, wr, ptr, b, off, desc = cases[int(os.environ['FSX'])]
    # the reference: operand at FSX_R + off, its pointer at $4800 (resident);
    # the faulting run: operand at FSX_P + off (or, ptr, at FSX_T + off with its pointer at FSX_P + off)
    pco = (0x8800, 0xA100) if '(d16,PC)' in what else (0x1800, 0x1A00)   # (d16,PC): each copy within 16 KB of its operand (a 16-bit displacement)
    runs_def = [(pco[0], FSX_R + off, 0x4800, FSX_O1), (pco[1], (FSX_T if ptr else FSX_P) + off, (FSX_P + off) if ptr else 0x4900, FSX_O2)]
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)   # move.l #CACR,d0; movec d0,cacr
    a.emit(0x41F8, 0x6F00)                    # lea $6F00.w,a0
    a.emit(0xF010, 0x4C00)                    # pmove.q (a0),crp
    a.emit(0xF028, 0x4000, 0x0008)            # pmove.l 8(a0),tc     translation on
    a.emit(0x41F9, *L(0xA000))                # lea $A000,a0
    a.emit(0x4E60)                            # move.l a0,usp
    a.emit(0x46FC, 0x0000)                    # move.w #$0000,sr     user
    a.label('U')
    a.emit(0x7E00)                            # moveq #0,d7          the differences
    runs = []
    for org, opnd, ptrat, out in runs_def:
        r = Asm(org)
        r.emit(0x41F8, FSX_INIT)              # lea INIT.w,a0
        r.emit(0xF210, 0xD0FF)                # fmovem.x (a0),fp0-fp7
        r.emit(0xF23C, 0x8800, 0, 0)          # fmove.l #0,fpsr
        r.emit(0x7C00)                        # moveq #0,d6
        insn_at = org + 2 * len(r.w)
        ws, a6 = b(opnd, insn_at + 4, ptrat)
        r.emit(*ws)                           # THE INSTRUCTION
        r.emit(0x9DCD)                        # suba.l a5,a6
        r.emit(0x4E75)                        # rts
        runs.append((org, r, insn_at, opnd, ptrat))
        a.emit(0x4BF9, *L(ptrat if 'indirect' in what else opnd))   # lea operand,a5 (indirect: its pointer - A6 is set from it)
        a.emit(0x4DF9, *L(a6 if a6 else opnd))   # lea A6,a6
        a.emit(0x4EB9, *L(org))               # jsr RUN
        a.emit(0x41F9, *L(out))               # lea out,a0
        a.emit(0xF210, 0xF0FF)                # fmovem.x fp0-fp7,(a0)
        a.emit(0xF228, 0xBC00, 0x0060)        # fmovem.l fpcr/fpsr/fpiar,$60(a0)
        a.emit(0x214E, 0x006C)                # move.l a6,$6C(a0)
        a.emit(0x2028, 0x0068)                # move.l $68(a0),d0    FPIAR
        a.emit(0x670A)                        # beq.s +10: past the subi and the move
        a.emit(0x0480, *L(insn_at))           # subi.l #insn,d0
        a.emit(0x2140, 0x0068)                # move.l d0,$68(a0)
    lo2 = runs_def[1][1]                      # the faulting run's operand
    for lo1, lo2, n in ((FSX_O1, FSX_O2, 28), (FSX_R + off - 64, lo2 - 64, 48)):
        a.emit(0x41F9, *L(lo1), 0x43F9, *L(lo2))   # lea; lea
        a.emit(0x303C, n - 1)                 # move.w #n-1,d0
        a.label('C%x' % lo1); a.emit(0xB388)  # cmpm.l (a0)+,(a1)+
        a.br(0x56C8, 'C%x' % lo1)             # dbne d0,C
        a.emit(0x56C1, 0x8E01)                # sne d1; or.b d1,d7
        a.emit(0xE38F)                        # lsl.l #1,d7
    a.emit(0x21C7, 0x3100)                    # move.l d7,$3100.w
    a.emit(0x4E40)                            # trap #0
    p = a.done()
    put(0x1000, p)
    ucode = [(a.lab['U'], 0x1000 + 2 * len(p) + 16)]
    uslack = [((a.lab['U'] & ~3) - 4, a.lab['U'])]
    for org, r, insn_at, opnd, ptrat in runs:
        rw = r.done()
        put(org, rw)
        ucode.append((org, org + 2 * len(rw) + 16))
        uslack.append(((org & ~3) - 4, org))
    ucheck = (ucode, uslack + [(0x3100, 0x3104), (0x4800, 0x4804), (0x4900, 0x4904),
                               (FSX_R - 128, FSX_R + 128), (FSX_P - 128, FSX_P + 128), (FSX_T - 128, FSX_T + 128),   # (the compare reads from operand - 64; operand >= base - 47)
                               (FSX_INIT, FSX_INIT + 0x60), (FSX_O1, FSX_O1 + 0x70), (FSX_O2, FSX_O2 + 0x70), (0x9F00, 0xA000)])
    vals = [0x3FFF0000, 0xC0000000, 0, 0x40000000, 0xA0000000, 0x00001234, 0xBFFE0000, 0xD5555555, 0x55555555,
            0x40130000, 0x8BADF00D, 0x00000000, 0x3FFC0000, 0xCCCCCCCC, 0xCCCCCCCD, 0x00000000, 0x00000000, 0,
            0x7FFF0000, 0, 0, 0x401E0000, 0xFFFFFFFF, 0xFFFFFFFE]
    for i, v in enumerate(vals):
        put(FSX_INIT + 4 * i, L(v))
    import random
    rnd = random.Random(31)
    win = [rnd.randrange(0, 65536) for _ in range(96)]   # 192 bytes
    for base in (FSX_R, FSX_P, FSX_T):
        put(base - 64, win)
    if os.environ.get('FSX_SANITY') == '1':
        put(lo2 - 64 + 80, [win[40] ^ 0x5A5A])   # a planted difference (must FAIL)
    for org, r, insn_at, opnd, ptrat in runs:
        put(ptrat, [opnd >> 16, opnd & 0xFFFF])     # the pointers last (over the windows)
    put(0x6F00, L(0x00000002) + L(0x00006000))           # CRP: short table descriptors at $6000
    put(0x6F08, L(0x80C04880))                           # TC: E, PS 12, IS 0, TIA 4, TIB 8, TIC 8
    put(0x6000, L(0x00006040 | 2))                       # A[0] -> B
    put(0x6040, L(0x00006800 | 2))                       # B[0] -> C
    for n_ in range(32):
        if n_ == FSX_P >> 12:
            put(0x6800 + 4 * n_, L((n_ << 12) | 5) if WPM else L(0))   # WP, or invalid
        else:
            put(0x6800 + 4 * n_, L((n_ << 12) | 1))
    put(4 * 2, L(0x2400))                     # fsw's pager handler
    put(0x2400, [0x48E7, 0x0706, 0x2E38, 0x3010, 0xE98F, 0x4DF8, 0x3020, 0xDDC7,
                 0x3CAF, 0x001A, 0x3D6F, 0x001E, 0x0002, 0x2D6F, 0x0024, 0x0004, 0x2D6F, 0x0016, 0x0008,
                 0x2C2F, 0x0024, 0x2A06, 0x0285, 0xFFFF, 0xF000, 0x5285, 0xE08E, 0xE48E, 0x0206, 0x00FC,
                 0x4BF8, 0x6800, 0x2B85, 0x6000, 0xF000, 0x2400, 0x52B8, 0x3010, 0x4CDF, 0x60E0, 0x4E73])
    put(4 * 32, L(0x2500))                    # TRAP #0: stop
    put(0x2500, [*movel_abs(0x600D0001, 0x3FF0), 0x4E72, 0x2700])
    faults = 0 if (WPM and not wr) else 1
    expect = [
        (0x3100, 0x00000000, 0xFFFFFFFF),     # the registers, then the memory windows, the same
        (0x3010, faults, 0xFFFFFFFF),         # one page fault
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
elif MODE == 'frs':
    # The FPU sweep gap's item 2 (2026-10-22): the FPU's rsweep - a random
    # user program (FRS=seed) of FPU and integer instructions over every EA
    # form (fif/fsx's: (An), (An)+, -(An), (d16,An), (d8,An,Xn), (xxx).L,
    # (d16,PC), #imm, the full format and memory indirection; FMOVEM, the
    # control registers, FBcc/FScc/FDBcc/FTRAPcc, transcendentals left
    # busy), run twice from two copies: the reference on resident pages, then
    # with a random set of its code, data, pointer and stack pages invalid
    # (FRS_WP=1: some write-protected) and random IRQs running a context
    # switch (the full save: FPCR/FPSR/FPIAR, FP0-FP7, FSAVE; FRS_AUX=1:
    # A/UX's, FPCR and FP0-FP7 only - then no FPSR-dependent instruction and
    # FPSR/FPIAR not compared; FRS_DLG=1: a switch at every suspended
    # dialog).  The pager finds the page as the UM says (8.2.1: DF - the data
    # cycle fault address; a fetch - stage B = PC+4 (format $A) or SP+$24
    # (format $B), stage C two lower).  D0-D7, A0-A3 (from the data base),
    # FP0-FP7, FPCR, FPSR, FPIAR (from the code base), the FTRAPcc count
    # and the data windows compared; the user-mode checks.  FRSLIST=n lists
    # n seeds; FRS_N the instruction count (150).
    if os.environ.get('FRSLIST'):
        for s in range(int(os.environ['FRSLIST'])):
            print('%3d frs seed %d' % (s, s))
        sys.exit(0)
    import random
    SEED = int(os.environ.get('FRS', '0'))
    AUXH = os.environ.get('FRS_AUX') == '1'
    WPM = os.environ.get('FRS_WP') == '1'
    NOPS = int(os.environ.get('FRS_N', '150'))
    rnd = random.Random(0xF25 * 1000 + SEED)
    CB1, DB1 = 0xC000, 0xE000                          # run 1: code, data ($2000 window, then a page of pointer cells and the stack)
    CB2, DB2 = None, 0x16000                           # run 2: its code placed (below) with the page boundary $13000 inside it
    OUT1, OUT2, INIT = 0x4400, 0x4600, 0x4000
    DLEN, CELLS, NOUT = 0x2000, 0x2000, 40
    SZ = {0: 4, 1: 4, 2: 12, 3: 12, 4: 2, 5: 8, 6: 1}   # L S X P W D B
    def poff(span):                                    # an operand offset in the window, often across its page boundary
        if rnd.random() < 0.5:
            return 0x1000 + rnd.randrange(-14, 9) & ~1
        return rnd.randrange(64, DLEN - 64 - span) & ~1
    ncell = [0]
    prog = []                                          # items: f(db, cb, here) -> words; the same choices in both runs
    def lea(an, f):                                    # LEA f(db).L,An
        return lambda db, cb, h: [0x41F9 | an << 9] + L(f(db))
    def fea(span, store, dn_ok=False):
        """(pre-items, ea field, f(db, cb, ext_at) -> extension words) for a memory/Dn operand"""
        forms = ['an', 'pi', 'pd', 'd16', 'd8x', 'absl', 'full', 'mind'] + ([] if store else ['pcrel']) + (['dn'] * 2 if dn_ok else [])
        m = rnd.choice(forms)
        an = rnd.randrange(4)
        o = poff(span)
        if m == 'dn':
            return [], rnd.randrange(6), lambda db, cb, x: []
        if m == 'an':
            return [lea(an, lambda db: db + o)], 0x10 | an, lambda db, cb, x: []
        if m == 'pi':
            return [lea(an, lambda db: db + o)], 0x18 | an, lambda db, cb, x: []
        if m == 'pd':
            return [lea(an, lambda db: db + o + span)], 0x20 | an, lambda db, cb, x: []
        if m == 'd16':
            d = rnd.randrange(-0x80, 0x80) & ~1
            return [lea(an, lambda db: db + o - d)], 0x28 | an, lambda db, cb, x: [d & 0xFFFF]
        if m == 'd8x':
            d = rnd.randrange(-0x40, 0x40) & ~1
            return [lea(an, lambda db: db + o - d)], 0x30 | an, lambda db, cb, x: [0xC000 | (d & 0xFF)]   # (d8,An,A4.W), A4 = 0
        if m == 'absl':
            return [], 0x39, lambda db, cb, x: L(db + o)
        if m == 'full':
            bd = rnd.randrange(-0x100, 0x100) & ~1
            return [lea(an, lambda db: db + o - bd)], 0x30 | an, lambda db, cb, x: [0x0170] + L(bd & 0xFFFFFFFF)   # (bd.L,An), IS
        if m == 'mind':
            k = ncell[0]; ncell[0] += 1
            cell = CELLS + 4 * k
            bd = rnd.randrange(-0x40, 0x40) & ~1
            od = rnd.randrange(-0x40, 0x40) & ~1
            cells.append((cell, o - od))
            ext = rnd.choice(([0x0162], [0x0163]))       # ([bd.W,An],od.W) or od.L
            def mx(db, cb, x, ext=ext, bd=bd, od=od):
                return ext + [bd & 0xFFFF] + ([od & 0xFFFF] if ext == [0x0162] else L(od & 0xFFFFFFFF))
            return [lea(an, lambda db: db + cell - bd)], 0x30 | an, mx
        # pcrel: an operand in the copy's literal pool
        po = 2 * rnd.randrange(0, 64 - 6)
        return [], 0x3A, lambda db, cb, x: [(pool_at[0] + po - x) & 0xFFFF]
    cells = []
    def emit_fpu(pre, w1, w2, extf, tail=()):
        for p in pre:
            prog.append(p)
        def f(db, cb, h, w1=w1, w2=w2, extf=extf, tail=tail):
            return [w1, w2] + extf(db, cb, h + 4) + list(tail)
        prog.append(f)
    ARITH = (0x00, 0x22, 0x23, 0x28, 0x20, 0x38, 0x27, 0x24, 0x01, 0x03, 0x18, 0x1A)   # FMOVE FADD FMUL FSUB FDIV FCMP FSGLMUL FSGLDIV FINT FINTRZ FABS FNEG
    MONO = (0x04, 0x1E, 0x1F, 0x3A, 0x25, 0x21, 0x26)                                   # FSQRT FGETEXP FGETMAN FTST FREM FMOD FSCALE
    SLOW = (0x0E, 0x1D, 0x0A, 0x10, 0x14, 0x02, 0x11)                                   # FSIN FCOS FATAN FETOX FLOGN FSINH FTWOTOX: busy dialogs
    def i_rr():
        r = rnd.random()
        if r < 0.08:                                     # FMOVECR #ofs,FPn
            emit_fpu([], 0xF200, 0x5C00 | rnd.randrange(8) << 7 | rnd.choice((0, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x3F)), lambda db, cb, x: [])
            return
        op = rnd.choice(SLOW) if r < 0.25 else rnd.choice(ARITH + MONO)
        emit_fpu([], 0xF200, rnd.randrange(8) << 10 | rnd.randrange(8) << 7 | op, lambda db, cb, x: [])
    def i_ld():
        fmt = rnd.choice((0, 1, 2, 4, 5, 6))             # (no packed source: random digits are undefined)
        pre, ea, extf = fea(SZ[fmt], False, fmt in (0, 1, 4, 6))
        op = rnd.choice((0x00, 0x22, 0x23, 0x28, 0x38, 0x20))
        emit_fpu(pre, 0xF200 | ea, 0x4000 | fmt << 10 | rnd.randrange(8) << 7 | op, extf)
    def i_st():
        fmt = rnd.choice((0, 1, 2, 3, 4, 5, 6))
        pre, ea, extf = fea(SZ[fmt], True, fmt in (0, 1, 4, 6))
        k = rnd.randrange(-8, 18) & 0x7F if fmt == 3 else 0
        emit_fpu(pre, 0xF200 | ea, 0x6000 | fmt << 10 | rnd.randrange(8) << 7 | k, extf)
    def i_imm():
        fmt = rnd.choice((0, 1, 2, 4, 5, 6))
        n = {0: 2, 1: 2, 2: 6, 4: 1, 5: 4, 6: 1}[fmt]
        iw = [rnd.randrange(65536) for _ in range(n)]
        if fmt == 6:
            iw = [iw[0] & 0xFF]
        if fmt == 2:
            iw[1] = 0                                    # (the X format's zero word)
        op = rnd.choice((0x00, 0x22, 0x23, 0x28, 0x38))
        emit_fpu([], 0xF23C, 0x4000 | fmt << 10 | rnd.randrange(8) << 7 | op, lambda db, cb, x, iw=iw: list(iw))
    def i_movem():
        lst = rnd.randrange(1, 256)
        if rnd.random() < 0.5:                           # to memory: (An), (d16,An), (xxx).L - or -(An)
            if rnd.random() < 0.3:
                an = rnd.randrange(4); o = poff(96)
                rev = int('{:08b}'.format(lst)[::-1], 2)
                emit_fpu([lea(an, lambda db: db + o + 96)], 0xF220 | an, 0xE000 | rev, lambda db, cb, x: [])
            else:
                an = rnd.randrange(4); o = poff(96); m = rnd.randrange(3)
                if m == 0:
                    emit_fpu([lea(an, lambda db: db + o)], 0xF210 | an, 0xF000 | lst, lambda db, cb, x: [])
                elif m == 1:
                    d = rnd.randrange(-0x40, 0x40) & ~1
                    emit_fpu([lea(an, lambda db: db + o - d)], 0xF228 | an, 0xF000 | lst, lambda db, cb, x, d=d: [d & 0xFFFF])
                else:
                    emit_fpu([], 0xF239, 0xF000 | lst, lambda db, cb, x: L(db + o))
        else:                                            # from memory: data written by the program or the window's
            an = rnd.randrange(4); o = poff(96)
            if rnd.random() < 0.5:
                emit_fpu([lea(an, lambda db: db + o)], 0xF218 | an, 0xD000 | lst, lambda db, cb, x: [])   # (An)+
            else:
                emit_fpu([], 0xF239, 0xD000 | lst, lambda db, cb, x: L(db + o))
    def i_ctl():
        r = rnd.random()
        if r < 0.5:
            v = rnd.randrange(3) << 6 | rnd.randrange(4) << 4       # FPCR: precision X/S/D, a rounding mode; no enables
            emit_fpu([], 0xF23C, 0x9000, lambda db, cb, x, v=v: L(v))
        elif r < 0.7 and not AUXH:
            v = rnd.randrange(1 << 32) & 0x0FFFFFF8                  # FPSR: the condition codes, quotient, EXC, AEXC
            emit_fpu([], 0xF23C, 0x8800, lambda db, cb, x, v=v: L(v))
        elif not AUXH:
            emit_fpu([], 0xF200 | rnd.randrange(6), 0xA800, lambda db, cb, x: [])   # FMOVE.L FPSR,Dn
        else:
            emit_fpu([], 0xF200 | rnd.randrange(6), 0xB000, lambda db, cb, x: [])   # FMOVE.L FPCR,Dn
    def i_cond():
        c = rnd.randrange(32); r = rnd.random()
        if r < 0.3:
            prog.append(lambda db, cb, h, c=c: [0xF280 | c, 0x0004, 0x5286])       # FBcc.W over ADDQ.L #1,D6
        elif r < 0.45:
            prog.append(lambda db, cb, h, c=c: [0xF2C0 | c, 0x0000, 0x0006, 0x5286])   # FBcc.L
        elif r < 0.65:
            prog.append(lambda db, cb, h, c=c, d=rnd.randrange(6): [0xF240 | d, c])    # FScc Dn
        elif r < 0.8:
            prog.append(lambda db, cb, h, c=c, d=rnd.randrange(6): [0xF248 | d, c, 0x0004, 0x5286])   # FDBcc Dn over ADDQ
        else:
            prog.append(lambda db, cb, h, c=c, v=rnd.randrange(65536): [0xF27A, c, v])   # FTRAPcc.W #
    def i_push():
        a_, b_ = rnd.randrange(8), rnd.randrange(8)
        prog.append(lambda db, cb, h: [0xF227, 0x6800 | a_ << 7, 0xF21F, 0x4800 | b_ << 7])   # FMOVE.X FPa,-(A7); FMOVE.X (A7)+,FPb
    dn = lambda: rnd.randrange(6)
    def i_int():
        r = rnd.random()
        if r < 0.2:
            prog.append(lambda db, cb, h, a=dn(), v=rnd.randrange(256): [0x7000 | a << 9 | v])
        elif r < 0.45:
            prog.append(lambda db, cb, h, w=rnd.choice((0xD000, 0x9000, 0xC000, 0x8000)) | dn() << 9 | rnd.randrange(3) << 6 | dn(): [w])
        elif r < 0.55:
            prog.append(lambda db, cb, h, w=0xE000 | rnd.randrange(8) << 9 | rnd.randrange(2) << 8 | rnd.randrange(3) << 6 | rnd.randrange(4) << 3 | dn(): [w])
        elif r < 0.65:
            prog.append(lambda db, cb, h, w=rnd.choice((0xC0C0, 0xC1C0)) | dn() << 9 | dn(): [w])
        elif r < 0.85:                                   # MOVE.L <ea>,Dn / Dn,<ea>
            pre, ea, extf = fea(4, rnd.random() < 0.5)
            st = ea != 0x3A and rnd.random() < 0.5
            for p in pre:
                prog.append(p)
            w = 0x2000 | ((ea & 7) << 9 | (ea >> 3) << 6 | dn()) if st else 0x2000 | dn() << 9 | ea
            prog.append(lambda db, cb, h, w=w, extf=extf: [w] + extf(db, cb, h + 2))
        else:
            prog.append(lambda db, cb, h, w=0x50C0 | rnd.randrange(16) << 8 | dn(): [w])   # Scc
    OPS = [(i_rr, 6), (i_ld, 6), (i_st, 6), (i_imm, 3), (i_movem, 2), (i_ctl, 1), (i_push, 1), (i_int, 5)] + ([] if AUXH else [(i_cond, 3)])
    bag = [f for f, wt in OPS for _ in range(wt)]
    for _ in range(NOPS):
        rnd.choice(bag)()
    pool = [rnd.randrange(65536) for _ in range(64)]
    dregs = [rnd.randrange(1 << 32) for _ in range(6)]
    win = [rnd.randrange(65536) for _ in range(DLEN // 2)]
    pool_at = [0]
    def render(cb, db, out, back):
        w = []
        def at():
            return cb + 2 * len(w)
        w += [0x2E7C] + L(db + CELLS + 0xFF0)           # movea.l #stack,a7
        w += [0xF238, 0xD0FF, INIT]                     # fmovem.x INIT.w,fp0-fp7
        w += [0xF23C, 0x9000, 0, 0, 0xF23C, 0x8800, 0, 0]   # fmove.l #0,fpcr; #0,fpsr
        w += [0x387C, 0x0000]                           # movea.w #0,a4
        for i, v in enumerate(dregs):
            w += [0x203C | i << 9] + L(v)               # move.l #v,dn
        w += [0x7C00, 0x7E00]                           # moveq #0,d6; moveq #0,d7
        for item in prog:
            w += item(db, cb, at())
        w += [0x48F9, 0x0FFF] + L(out)                  # movem.l d0-d7/a0-a3,out.l
        for i in range(4):
            w += [0x04B9] + L(db) + L(out + 32 + 4 * i)  # subi.l #db,out+32+4i
        w += [0xF239, 0xF0FF] + L(out + 48)             # fmovem.x fp0-fp7,out+48
        w += [0xF239, 0xBC00] + L(out + 144)            # fmovem.l fpcr/fpsr/fpiar,out+144
        w += [0x4AB9] + L(out + 152) + [0x670A]         # tst.l out+152; beq.s +10 (FPIAR stays 0: the 68882 asks for the
        w += [0x04B9] + L(cb) + L(out + 152)            #   instruction address only with an exception enabled) - subi.l #cb,out+152
        w += [0x23F8, 0x3040] + L(out + 156)            # move.l $3040.w,out+156 (the FTRAPcc count)
        w += [0x42B8, 0x3040]                           # clr.l $3040.w
        if AUXH:
            w += [0x42B9] + L(out + 148) + [0x42B9] + L(out + 152)   # FPSR, FPIAR not compared (A/UX's switch saves neither)
        w += [0x4EF9] + L(back)                         # jmp back
        pool_at[0] = at()
        return w + pool
    for _ in range(2):                                  # (the pool's address from the first pass)
        r1 = render(CB1, DB1, OUT1, 0)
    CB2 = 0x13000 - 2 * rnd.randrange(4, len(r1) - 4)  # the boundary at a random word of the program (or its pool)
    a = Asm(0x1000)
    a.emit(0x203C, *L(CACR_K28), 0x4E7B, 0x0002)       # move.l #CACR,d0; movec d0,cacr
    a.emit(0x41F8, 0x6F00, 0xF010, 0x4C00, 0xF028, 0x4000, 0x0008)   # pmove.q (a0),crp; pmove.l 8(a0),tc
    a.emit(0x41F9, *L(0xA000), 0x4E60)                 # move.l #$A000,usp
    a.emit(0x46FC, 0x0000)                             # user
    a.label('U')
    a.emit(0x4EF9, *L(CB1))                            # jmp run 1
    a.label('B1')
    if os.environ.get('FRS_NOIRQ') != '1':
        a.emit(*movel_abs(1, 0x3F04))                  # the random IRQs on: the faulting run only
    a.emit(0x4EF9, *L(CB2))                            # jmp run 2
    a.label('B2')
    a.emit(*movel_abs(1, 0x3F08))                      # off
    a.emit(0x7E00)                                     # moveq #0,d7
    for lo1, lo2, n in ((OUT1, OUT2, NOUT), (DB1, DB2, DLEN // 4)):
        a.emit(0x41F9, *L(lo1), 0x43F9, *L(lo2), 0x303C, n - 1)
        a.label('C%x' % lo1); a.emit(0xB388)          # cmpm.l (a0)+,(a1)+
        a.br(0x56C8, 'C%x' % lo1)                     # dbne d0,C
        a.emit(0x56C1, 0x8E01, 0xE38F)                 # sne d1; or.b d1,d7; lsl.l #1,d7
    a.emit(0x21C7, 0x3100, 0x4E40)                     # move.l d7,$3100.w; trap #0
    p = a.done()
    put(0x1000, p)
    for _ in range(2):
        r1 = render(CB1, DB1, OUT1, a.lab['B1'])
    put(CB1, r1)
    for _ in range(2):
        r2 = render(CB2, DB2, OUT2, a.lab['B2'])
    put(CB2, r2)
    assert len(r1) == len(r2)
    assert CB1 + 2 * len(r1) < DB1 and CB2 + 2 * len(r2) < DB2, (hex(CB1 + 2 * len(r1)), hex(CB2 + 2 * len(r2)))
    vals = [0x3FFF0000, 0xC0000000, 0, 0x40000000, 0xA0000000, 0x00001234, 0xBFFE0000, 0xD5555555, 0x55555555,
            0x40130000, 0x8BADF00D, 0x00000000, 0x3FFC0000, 0xCCCCCCCC, 0xCCCCCCCD, 0x00000000, 0x00000000, 0,
            0x7FFF0000, 0, 0, 0x401E0000, 0xFFFFFFFF, 0xFFFFFFFE]
    for i, v in enumerate(vals):
        put(INIT + 4 * i, L(v))
    for db in (DB1, DB2):
        put(db, win)
        for cell, off in cells:
            put(db + cell, L(db + off))
    if os.environ.get('FRS_SANITY') == '1':
        put(DB2 + 0x1400, [win[0x1400 // 2] ^ 0x5A5A])  # a planted difference (must FAIL)
    put(0x6F00, L(0x00000002) + L(0x00006000))         # CRP; TC: E, PS 12, TIA 4, TIB 8, TIC 8
    put(0x6F08, L(0x80C04880))
    put(0x6000, L(0x00006040 | 2))
    put(0x6040, L(0x00006800 | 2))
    pg2 = sorted(set(range(CB2 >> 12, (CB2 + 2 * len(r2)) // 0x1000 + 1)) | {DB2 >> 12, (DB2 >> 12) + 1, (DB2 >> 12) + 2})
    bad = {}
    for pgn in pg2:
        r = rnd.random()
        if r < 0.5:
            bad[pgn] = 'inv'
        elif WPM and r < 0.75 and pgn >= DB2 >> 12:
            bad[pgn] = 'wp'
    if not bad:
        bad[rnd.choice(pg2)] = 'inv'
    for n in range(32):
        d = (n << 12) | 1
        if bad.get(n) == 'inv':
            d = 0
        elif bad.get(n) == 'wp':
            d |= 4
        put(0x6800 + 4 * n, L(d))
    if os.environ.get('FRSINFO') == '1':
        print('frs %d: code %X/%X, %d words, %d cells; pages %s' % (SEED, CB1, CB2, len(r1), len(cells),
              ' '.join('%X:%s' % (k, v) for k, v in sorted(bad.items()))), file=sys.stderr)
    put(4 * 2, L(0x2400))                              # the pager (UM 8.2.1): the page of the fault, valid
    put(0x2400, [0x48E7, 0x0704,                       # movem.l d5-d7/a5,-(a7)   (16 bytes)
                 0x3E2F, 0x001A,                       # move.w $1a(a7),d7     SSW
                 0x0807, 0x0008,                       # btst #8,d7            DF
                 0x6706,                               # beq.s fetch
                 0x2C2F, 0x0020,                       # move.l $20(a7),d6     the data cycle fault address
                 0x6022,                               # bra.s have
                 0x3A2F, 0x0016,                       # fetch: move.w $16(a7),d5   format/vector
                 0x0245, 0xF000,                       # andi.w #$f000,d5
                 0x0C45, 0xB000,                       # cmpi.w #$b000,d5
                 0x6606,                               # bne.s short
                 0x2C2F, 0x0034,                       # move.l $34(a7),d6     stage B address (SP+$24)
                 0x6006,                               # bra.s stg
                 0x2C2F, 0x0012,                       # short: move.l $12(a7),d6   PC
                 0x5886,                               # addq.l #4,d6          stage B = PC+4
                 0x0807, 0x000F,                       # stg: btst #15,d7      FC
                 0x6702,                               # beq.s have
                 0x5586,                               # subq.l #2,d6          stage C = B-2
                 0x2A06,                               # have: move.l d6,d5
                 0x0285, 0xFFFF, 0xF000,               # andi.l #$fffff000,d5
                 0x5285,                               # addq.l #1,d5
                 0xE08E, 0xE48E, 0x0206, 0x00FC,       # d6 = page * 4
                 0x4BF8, 0x6800,                       # lea $6800.w,a5
                 0x2B85, 0x6000,                       # move.l d5,(a5,d6.w)
                 0xF000, 0x2400,                       # pflusha
                 0x52B8, 0x3010,                       # addq.l #1,$3010.w
                 0x0CB8, 0x0000, 0x00C8, 0x3010,       # cmpi.l #200,$3010.w
                 0x6304,                               # bls.s +4
                 0x4E72, 0x2700,                       # stop #$2700: a fault loop (the marker stays unset)
                 0x4CDF, 0x20E0,                       # movem.l (a7)+,d5-d7/a5
                 0x4E73])                              # rte
    put(4 * 7, L(0x2780))                              # FTRAPcc: count it
    put(0x2780, [0x52B8, 0x3040, 0x4E73])
    put(4 * 32, L(0x2500))                             # TRAP #0: stop
    put(0x2500, [*movel_abs(0x600D0001, 0x3FF0), 0x4E72, 0x2700])
    if AUXH:                                           # A/UX's switch (b3x's)
        put(4 * 25, L(0x2600))
        put(0x2600, [0x52B8, 0x3030, 0x48E7, 0x80C0,
                     0x41F8, 0x5000, 0xF310, 0x4A10, 0x6710,
                     0x41F8, 0x4F00, 0xF210, 0xB000, 0x41F8, 0x4F10, 0xF210, 0xF0FF,
                     0x43F8, 0x5200, 0xF351,
                     0x43F8, 0x3C80, 0xF200, 0x5C32, 0xF200, 0x0022, 0xF200, 0x0003,
                     0xF229, 0x7000, 0xFFF0, 0xF200, 0x000E,
                     0x43F8, 0x5200, 0xF311,
                     0x43F8, 0x5000, 0x4A11, 0x6710,
                     0x41F8, 0x4F00, 0xF210, 0x9000, 0x41F8, 0x4F10, 0xF210, 0xD0FF,
                     0xF351, 0x4CDF, 0x0301,
                     0x21FC, 0x0000, 0x0001, 0x3F00, 0x4E73])
    else:                                              # the full save (b3r's, FPSR/FPIAR too)
        put(4 * 25, L(0x2700))
        put(0x2700, [0x52B8, 0x3030, 0xF327, 0xF227, 0xE0FF, 0xF227, 0xBC00,
                     0xF200, 0x5C32, 0xF200, 0x5C8F, 0xF200, 0x5D0F, 0xF200, 0x0D22, 0xF200, 0x000E,
                     0xF21F, 0x9C00, 0xF21F, 0xD0FF, 0xF35F,
                     0x21FC, 0x0000, 0x0001, 0x3F00, 0x4E73])
    put(4 * 26, L(0x2580))                             # level 2 (the random mode's VIA2): nests on level 1, FPU work too, the whole state kept
    put(0x2580, [0x52B8, 0x3028, 0xF327, 0xF227, 0xE0FF, 0xF227, 0xBC00, 0xF200, 0x5D0F,
                 0xF21F, 0x9C00, 0xF21F, 0xD0FF, 0xF35F,
                 0x21FC, 0x0000, 0x0001, 0x3F0C, 0x4E73])
    irq = 0xFFFFFFFB if os.environ.get('FRS_DLG') == '1' else 0xFFFFFFFE
    ucode = [(a.lab['U'], 0x1000 + 2 * len(p) + 16), (CB1, CB1 + 2 * len(r1) + 16), (CB2, CB2 + 2 * len(r2) + 16)]
    udata = [((a.lab['U'] & ~3) - 4, a.lab['U']), ((CB1 & ~3) - 4, CB1), ((CB2 & ~3) - 4, CB2),
             (pool_at[0] - (CB2 - CB1), pool_at[0] + 128), (pool_at[0], pool_at[0] + 128),     # the literal pools (PC-relative reads)
             (DB1 - 0x100, DB1 + 0x3000), (DB2 - 0x100, DB2 + 0x3000),                          # the windows, cells, stacks (+ an EA's reach)
             (OUT1, OUT1 + 4 * NOUT), (OUT2, OUT2 + 4 * NOUT), (INIT, INIT + 0x60), (0x3040, 0x3044), (0x3100, 0x3104), (0x3F00, 0x3F10), (0x9F00, 0xA000)]
    ucheck = (ucode, udata)
    expect = [
        (0x3100, 0x00000000, 0xFFFFFFFF),     # the registers, then the data windows, the same
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),     # no stray exception, no fault loop
    ]
    if os.environ.get('FRS_DUMP') == '1':     # both runs' saved state printed (as failures)
        expect += [(o + 4 * i, 0xDEADBEEF, 0xFFFFFFFF) for o in (OUT1, OUT2) for i in range(NOUT)]
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
elif MODE in ('fullea', 'fulleab'):
    # the full extension format through the coprocessor's EA (UM 2.2);
    # fulleab bus-errors the first access to five of its beats inside the
    # dialogs - a long bd's second word, the memory-indirect pointer's read
    # (twice), the write through a pointer, an od's fetch - and the RTE of
    # each long frame goes on from the fault
    a = Asm(0x1000)
    a.emit(0x41F8, 0x3420)                    # lea $3420.w,a0
    a.emit(0x43F8, 0x3700)                    # lea $3700.w,a1
    a.emit(0x7403)                            # moveq #3,d2
    # 1. StartMonitor's $1000626C: BS IS, bd.L, memory indirect, od.W
    while (a.here() + 8) % 4:
        a.emit(0x4E71)                        # nop: bd's second word on a long of its own
    a.label('C1')
    a.emit(0xF230, 0x5000, 0x01F2, *L(0x3400), 0x005A)   # fmove.w ([$3400.l],$5a),fp0: 300
    a.emit(0xF238, 0x6000, 0x3300)            # fmove.l fp0,$3300.w
    # 2. StartMonitor's $1000DA98: bd.W from A0, memory indirect, null od: a write
    a.emit(0xF200, 0x0100)                    # fmove.x fp0,fp2
    a.emit(0xF230, 0x7500, 0x0161, 0xFFFC)    # fmove.d fp2,([-4,a0]): through ($341C) to $3600
    # 3. preindexed: ([$10,a1,d2.w*4],$8)
    while (a.here() + 8) % 4:
        a.emit(0x4E71)                        # nop: od on a long of its own
    a.label('C3')
    a.emit(0xF231, 0x4180, 0x2522, 0x0010, 0x0008)       # fmove.l ...,fp3: 7
    a.emit(0xF238, 0x6180, 0x3304)            # fmove.l fp3,$3304.w
    # 4. postindexed: ([$20,a1],d2.l*2,-4)
    a.emit(0xF231, 0x4200, 0x2B26, 0x0020, 0xFFFC)       # fmove.l ...,fp4: 9
    a.emit(0xF238, 0x6200, 0x3308)            # fmove.l fp4,$3308.w
    # 5. no indirection: ($100.l,a1,d2.l*4)
    a.emit(0xF231, 0x4280, 0x2D30, *L(0x100)) # fmove.l ...,fp5: 11
    a.emit(0xF238, 0x6280, 0x330C)            # fmove.l fp5,$330C.w
    # 6. (bd,PC) in the full format: bd from the extension word's address
    a.emit(0xF23B, 0x4300)                    # fmove.l (K13,pc),fp6: 13
    a.label('EXT6'); a.emit(0x0160, 0)
    a.emit(0xF238, 0x6300, 0x3310)            # fmove.l fp6,$3310.w
    # 7. null bd and od: ([a1,d2.w*4])
    a.emit(0xF231, 0x4380, 0x2511)            # fmove.l ...,fp7: 15
    a.emit(0xF238, 0x6380, 0x3314)            # fmove.l fp7,$3314.w
    a.emit(movel_abs(0x600D0001, 0x3FF0))
    a.emit(0x4E72, 0x2700)                    # stop #$2700
    a.label('K13'); a.emit(*L(13))
    p = a.done()
    p[(a.lab['EXT6'] - 0x1000) // 2 + 1] = (a.lab['K13'] - a.lab['EXT6']) & 0xFFFF
    put(0x1000, p)
    put(0x3400, L(0x3500)); put(0x355A, [300])          # 1: the pointer, the word
    put(0x341C, L(0x3600))                              # 2: the pointer
    put(0x371C, L(0x3800)); put(0x3808, L(7))           # 3
    put(0x3720, L(0x3900)); put(0x3902, L(9))           # 4: $3900 + 3*2 - 4
    put(0x380C, L(11))                                  # 5: $3700 + $100 + 3*4
    put(0x370C, L(0x3A00)); put(0x3A00, L(15))          # 7
    expect = [
        (0x3300, 300, 0xFFFFFFFF),            # 1
        (0x3600, 0x4072C000, 0xFFFFFFFF),     # 2: 300.0 as a double
        (0x3604, 0x00000000, 0xFFFFFFFF),
        (0x3304, 7, 0xFFFFFFFF),              # 3
        (0x3308, 9, 0xFFFFFFFF),              # 4
        (0x330C, 11, 0xFFFFFFFF),             # 5
        (0x3310, 13, 0xFFFFFFFF),             # 6
        (0x3314, 15, 0xFFFFFFFF),             # 7
        (0x3FF0, 0x600D0001, 0xFFFFFFFF),
    ]
    if MODE == 'fulleab':
        berrs = [a.lab['C1'] + 8, 0x3400 | 1, 0x3600, a.lab['C3'] + 8, 0x3720 | 1]   # (bit 0: the read)
        put(4 * 2, L(0x2400))                 # vector 2: b5c's handler, a frame's fields per fault
        put(0x2400, [0x2E38, 0x3010, 0xE98F, 0x4DF8, 0x3020, 0xDDC7, 0x3CAF, 0x0006,
                     0x3D6F, 0x000A, 0x0002, 0x2D6F, 0x0010, 0x0004, 0x2D6F, 0x0002, 0x0008,
                     0x52B8, 0x3010, 0x4E73])
        expect += [(0x3010, 5, 0xFFFFFFFF)]   # five bus errors, each a long frame at its access
        for k, fa in enumerate([a.lab['C1'] + 8, 0x3400, 0x3600, a.lab['C3'] + 8, 0x3720]):
            expect += [(0x3020 + 16 * k, 0xB0080000, 0xFFFF0000), (0x3024 + 16 * k, fa, 0xFFFFFFFF)]

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

with open('ucheck.hex', 'w') as f:               # 16 code pairs, then 32 data pairs; all zero = off
    if os.environ.get('UCK_SANITY') == '1' and ucheck[1]:
        ucheck = (ucheck[0], [r for r in ucheck[1] if r != (0x9F00, 0xA000)])   # the user stack unnamed: must FAIL
    pr = (list(ucheck[0]) + [(0, 0)] * 16)[:16] + (list(ucheck[1]) + [(0, 0)] * 32)[:32]
    assert len(ucheck[0]) <= 16 and len(ucheck[1]) <= 32
    f.write(''.join('%08x\n%08x\n' % (lo, hi) for lo, hi in pr))
with open('program.hex', 'w') as f:
    f.write(''.join('%04x\n' % w for w in img))
with open('inject.txt', 'w') as f:
    f.write(' '.join('%08x' % v for v in [inject, irq, cps] + (berrs + [0] * 8)[:8]) + '\n')
with open('expect.txt', 'w') as f:
    f.write(''.join('%08x %08x %08x\n' % e for e in expect))
print('program %s: %d words at $1000; %d results' % (MODE, len(p), len(expect)))
