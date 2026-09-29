"""The 68882 architectural simulator: plan 8.8.19, work 6c.

Runs the assembled microcode on a bit-exact model of 8.8.10's datapath,
one microinstruction a clock, and is **the definition of what every field
of fields.py does** - the RTL (item 7) is written against this file.  Around
it, the parts of the chip that are not microcode: the BIU's decode and its
conditionals (8.6.9), the CU's unpacking of S, D and X operands (8.8.13),
the entry table, and the pending exception the BIU takes at the end of an
instruction.

`run(cmd, ...)` executes one instruction from a vector's state; vec.py runs
the model's vectors through it.

THE CLOCK (8.8.9).  The next address is chosen from the flags the previous
microinstruction left; then the datapath executes and leaves new flags.  A
`wait n` word executes its nanoword once and holds the sequencer n more
clocks.

THE WORD.  A temporary is (s, e, m): the sign, an 18-bit two's complement
exponent biased by 16383 (held here as a signed int), a 67-bit mantissa
(bit 66 the integer bit, bits 2-0 guard, round, sticky).  An FP register
image (s, e15, m64) is the word (s, e15, m64 << 3) - the same formula at
every exponent, denormals included (xreal.py's 2^(e-16446)).
"""

from collections import namedtuple

import fields as FD

M67 = (1 << 67) - 1
M64 = (1 << 64) - 1
M18 = (1 << 18) - 1
EMAX = 0x7FFF

Word = namedtuple('Word', 's e m')
ZERO_W = Word(0, 0, 0)

# FPSR / FPCR (plan 8.6.2).
CC_N, CC_Z, CC_I, CC_NAN = 1 << 27, 1 << 26, 1 << 25, 1 << 24
BSUN, SNAN, OPERR, OVFL, UNFL, DZ, INEX2, INEX1 = (1 << b for b in range(15, 7, -1))
A_IOP, A_OVFL, A_UNFL, A_DZ, A_INEX = (1 << b for b in range(7, 2, -1))
V_BSUN, V_INEX, V_DZ, V_UNFL, V_OPERR, V_OVFL, V_SNAN, V_FLINE = 48, 49, 50, 51, 52, 53, 54, 11


class SimError(Exception):
    """The microcode did something the hardware cannot (a microcode bug)."""


def s18(v):
    v &= M18
    return v - (1 << 18) if v >> 17 else v


def s67(v):
    v &= M67
    return v - (1 << 67) if v >> 66 else v


def fp_word(x):
    s, e, m = x
    return Word(s, e, m << 3)


def word_fp(w):
    if not 0 <= w.e <= EMAX:
        raise SimError('FP write with exponent %d outside 0-$7FFF' % w.e)
    return (w.s, w.e, (w.m >> 3) & M64)


def tag(w):
    """Table 8-13's class of a word: NORM, UNN, ZERO, INF, NAN."""
    if w.e == EMAX:
        return FD.TAG['NAN'] if (w.m >> 3) & ((1 << 63) - 1) else FD.TAG['INF']
    if w.m == 0:
        return FD.TAG['ZERO']
    return FD.TAG['NORM'] if w.m >> 66 else FD.TAG['UNN']


def is_snan(w):
    return tag(w) == FD.TAG['NAN'] and not (w.m >> 65) & 1


def is_den(w):
    return w.e == 0 and w.m != 0 and not w.m >> 66


# -- the CU's unpacking (8.8.13) --------------------------------------------------------

def unpack_ieee(v, ebits, fbits):
    s = (v >> (ebits + fbits)) & 1
    be = (v >> fbits) & ((1 << ebits) - 1)
    f = v & ((1 << fbits) - 1)
    bias = (1 << (ebits - 1)) - 1
    sh = 66 - fbits
    if be == (1 << ebits) - 1:
        return Word(s, EMAX, 0 if f == 0 else (1 << 66) | (f << (sh - 0)))
    if be == 0:
        return Word(s, 0, 0) if f == 0 else Word(s, 1 - bias + 16383, f << sh)
    return Word(s, be - bias + 16383, ((1 << fbits) | f) << sh)


def unpack_x(v):
    return Word((v >> 95) & 1, (v >> 80) & EMAX, (v & M64) << 3)


INT_BITS = {'L': 32, 'W': 16, 'B': 8}


def opint(v, fmt):
    bits = INT_BITS[fmt]
    v &= (1 << bits) - 1
    if v >> (bits - 1):
        v -= 1 << bits
    return Word(1 if v < 0 else 0, 0, abs(v))


# -- the BIU's conditionals (8.6.9) ---------------------------------------------------------
# The predicate against FPCC is a 16 x 32 truth table - a 512-bit ROM in the
# BIU - as the model's default for 8.6.14 item 17 has it (WinUAE's 6888x
# table, a lead; it agrees with 8.6.9's equations on the eight FPCC values
# the chip produces).  The table is the model's own, not a copy.

import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', 'fpu_model'))
import fpu as _model                                      # noqa: E402
from switches import DEFAULT as _SW                       # noqa: E402


def predicate(pred, cc):
    if _SW.fpcc_table == 'winuae':
        return bool(_model.WINUAE_CC_TABLE[cc * 32 + (pred & 0x1F)])
    return _model.evaluate_equation(pred, cc)


def trap_vector(fpsr, fpcr):
    """The BIU's pending exception: 6.1.9's priority; the inexact vector for
    [(OVFL | INEX2) & EN.INEX2] | [INEX1 & EN.INEX1] (6.1.10)."""
    exc, en = fpsr & 0xFF00, fpcr & 0xFF00
    for bit, vec in ((BSUN, V_BSUN), (SNAN, V_SNAN), (OPERR, V_OPERR),
                     (OVFL, V_OVFL), (UNFL, V_UNFL), (DZ, V_DZ)):
        if exc & en & bit:
            return vec
    if ((exc & (OVFL | INEX2)) and (en & INEX2)) or ((exc & INEX1) and (en & INEX1)):
        return V_INEX
    return 0


def accrue(fpsr):
    exc = fpsr
    a = 0
    if exc & (BSUN | SNAN | OPERR):
        a |= A_IOP
    if exc & OVFL:
        a |= A_OVFL
    if (exc & UNFL) and (exc & INEX2):
        a |= A_UNFL
    if exc & DZ:
        a |= A_DZ
    if exc & (INEX1 | INEX2 | OVFL):
        a |= A_INEX
    return fpsr | a


# -- the chip ---------------------------------------------------------------------------

# The range comparators' limits by RPREC (EXT, SGL, DBL, SGLX): the biased
# exponents a normalized result may have (rounding.py's formats).
RANGE = {0: (0, 0x7FFE), 1: (16383 - 126, 16383 + 127), 2: (16383 - 1022, 16383 + 1023),
         3: (0, 0x7FFE)}

_E = {n: {name: i for i, name in enumerate(f.enum.names)} for n, f in FD.NANO.fields.items() if f.enum}


class Unimplemented(Exception):
    pass


class Chip:
    def __init__(self, urom, nrom, entry, krom, unimpl=None, idle=0):
        self.urom, self.nrom, self.entry, self.krom = urom, nrom, entry, krom
        self.unimpl, self.idle = unimpl, idle
        self._dec = [None] * len(urom)
        self.fp = [(0, EMAX, M64)] * 8
        self.fpcr = self.fpsr = 0
        self.trace = None

    def _decode(self, a):
        d = self._dec[a]
        if d is None:
            m = FD.MICRO.unpack(self.urom[a])
            n = FD.NANO.names(self.nrom[m['nano']])
            d = self._dec[a] = (m, n)
        return d

    # -- per-instruction state ------------------------------------------------------------
    def start(self, cmd, src, src_tag_word, dreg=0, operand=0):
        self.cmd = cmd
        self.opclass = cmd >> 13
        self.rx, self.ry = (cmd >> 10) & 7, (cmd >> 7) & 7
        self.src_fp = self.ry if self.opclass == 3 else self.rx
        self.cu = src                          # the CU's operand (S/D/X/B/W/L)
        self.operand = operand
        self.dreg = dreg
        sw = src_tag_word
        dw = fp_word(self.fp[self.ry])
        self.stag, self.dtag = tag(sw), tag(dw)
        self.s_snan, self.d_snan = is_snan(sw), is_snan(dw)
        self.s_den, self.d_den = is_den(sw), is_den(dw)
        self.s_neg, self.d_neg = sw.s, dw.s
        self.T = [ZERO_W] * FD.TEMPS
        self.Q = self.QX = self.MD = self.MD3 = 0
        self.SC = self.LC = 0
        self.Z = self.N = self.C = self.V = 0
        self.STK = self.INEX = self.DFLAG = self.LZC = self.KDIR = self.S = 0
        self.TINY = self.HUGE = 0
        self.RPREC = 0
        self.RMODE = None                      # FPCR's RND until an RM_* sets it
        self.OBUF = 0
        self.EXOP = (0, 0, 0)
        self.stack = []
        self.clocks = 0
        self.done = False

    # -- conditions and dispatch keys ------------------------------------------------------
    def cond(self, c):
        name = FD.COND.names[c]
        prec, rnd = (self.fpcr >> 6) & 3, (self.fpcr >> 4) & 3
        T_ = FD.TAG
        v = {
            'TRUE': 1, 'Z': self.Z, 'N': self.N, 'C': self.C, 'V': self.V, 'STK': self.STK,
            'INEX': self.INEX, 'RCARRY': self.C, 'LCZ': self.LC == 0, 'Q0': self.Q & 1,
            'DFLAG': self.DFLAG, 'SCZ': self.SC == 0, 'KABOVE': self.KDIR == FD.DIR_ABOVE,
            'KBELOW': self.KDIR == FD.DIR_BELOW,
            'EXCEN': bool(self.fpsr & self.fpcr & 0xFF00), 'PENDING': 0,
            'SNORM': self.stag == T_['NORM'], 'SUNN': self.stag == T_['UNN'],
            'SZERO': self.stag == T_['ZERO'], 'SINF': self.stag == T_['INF'],
            'SNAN': self.stag == T_['NAN'], 'SSNAN': self.s_snan, 'SNEG': self.s_neg,
            'SDEN': self.s_den,
            'DNORM': self.dtag == T_['NORM'], 'DUNN': self.dtag == T_['UNN'],
            'DZERO': self.dtag == T_['ZERO'], 'DINF': self.dtag == T_['INF'],
            'DNAN': self.dtag == T_['NAN'], 'DSNAN': self.d_snan, 'DNEG': self.d_neg,
            'DDEN': self.d_den,
            'PREC_EXT': prec in (0, 3), 'PREC_SGL': prec == 1, 'PREC_DBL': prec == 2,
            'RND_RN': rnd == 0, 'RND_RZ': rnd == 1, 'RND_RM': rnd == 2, 'RND_RP': rnd == 3,
            'DYNK': self.opclass == 3 and ((self.cmd >> 10) & 7) == 7,
            'SAVEREQ': 0, 'ABORT': 0, 'CUHANDOFF': 0,
            'SRCREG': self.opclass == 0, 'SAMEREG': self.rx == self.ry,
            'S': self.S, 'RPEXT': self.RPREC in (0, 3), 'TINY': self.TINY, 'HUGE': self.HUGE,
            'LCEQ': self.LC == self._lit, 'LCSCEQ': self.LC - self.SC == self._lit,
            'RMRM': self._rmode() == 2, 'RMRP': self._rmode() == 3, 'LE': self.N or self.Z,
        }
        if name.startswith('EN_'):
            return bool(self.fpcr & {'EN_BSUN': BSUN, 'EN_SNAN': SNAN, 'EN_OPERR': OPERR,
                                     'EN_OVFL': OVFL, 'EN_UNFL': UNFL, 'EN_DZ': DZ,
                                     'EN_INEX2': INEX2, 'EN_INEX1': INEX1}[name])
        return bool(v[name])

    def key(self, k):
        name = FD.DISPATCH.names[k]
        if name == 'TAGPAIR':
            return self.stag * 5 + self.dtag
        if name == 'STAG':
            return self.stag
        if name == 'DTAG':
            return self.dtag
        if name == 'RND':
            return (self.fpcr >> 4) & 3
        if name == 'PREC':
            return (self.fpcr >> 6) & 3
        if name in ('SFMT', 'DFMT'):
            return (self.cmd >> 10) & 7
        if name == 'KFACTOR':
            return int(((self.cmd >> 10) & 7) == 7)
        if name == 'RPREC':
            return self.RPREC
        if name == 'RMODE':
            return self._rmode()
        if name == 'OPMODE':
            return self.cmd & 0x3F
        raise SimError('dispatch key %s' % name)

    def _rmode(self):
        return (self.fpcr >> 4) & 3 if self.RMODE is None else self.RMODE

    # -- the round logic (8.8.10) -------------------------------------------------------------
    def _round(self, mode, a):
        if mode == 'RPREC':
            lsb = {0: 3, 1: 43, 2: 14, 3: 43}[self.RPREC]
        else:
            lsb = {'EXT': 3, 'SGL': 43, 'DBL': 14, 'TRUNC': 3}[mode]
        rnd = 1 if mode == 'TRUNC' else self._rmode()
        m = a.m
        g = (m >> (lsb - 1)) & 1
        r = (m >> (lsb - 2)) & 1
        s = bool(m & ((1 << (lsb - 2)) - 1)) or bool(self.STK)
        inexact = bool(g or r or s)
        if rnd == 0:
            up = g and (r or s or (m >> lsb) & 1)
        elif rnd == 1:
            up = False
        elif rnd == 2:
            up = a.s and inexact
        else:
            up = (not a.s) and inexact
        return (1 << lsb) if up else 0, M67 & ~((1 << lsb) - 1), inexact

    # -- one microinstruction ------------------------------------------------------------------
    def step(self):
        a = self.upc
        if a == self.unimpl:
            raise Unimplemented('instruction $%04X' % self.cmd)
        m, n = self._decode(a)
        self._lit = n['lit']                   # LCEQ/LCSCEQ compare with the word's literal
        seq = FD.SEQ.names[m['seq']]
        # the next address, from the flags before this word
        nxt = a + 1
        hold = 0
        if seq == 'JUMP':
            nxt = m['target']
        elif seq == 'CALL':
            if len(self.stack) >= FD.STACK_DEPTH:
                raise SimError('µPC stack overflow at $%03X' % a)
            self.stack.append(a + 1)
            nxt = m['target']
        elif seq == 'RET':
            if not self.stack:
                raise SimError('ret with an empty µPC stack at $%03X' % a)
            nxt = self.stack.pop()
        elif seq in ('BRT', 'BRF'):
            c = self.cond(m['cond'])
            if c == (seq == 'BRT'):
                nxt = m['target']
        elif seq == 'DISP':
            nxt = m['target'] | self.key(m['cond'])
        elif seq == 'WAIT':
            hold = m['target']
        if self.trace is not None:
            import disasm
            self.trace.append('%03X  %s' % (a, disasm.format_word(self.urom[a], self.nrom)))
        self.execute(m, n)
        self.clocks += 1 + hold
        self.upc = nxt

    def execute(self, m, n):
        e = n
        # A
        asrc = e['asrc']
        if asrc == 'ZERO':
            A = ZERO_W
        elif asrc == 'T':
            A = self.T[m['ra']]
        elif asrc == 'FP':
            A = fp_word(self.fp[self._fpsel(e['fpsel'], m)])
        else:
            A = self.cu
        if e['a2']:
            if e['emode'] in ('EXP', 'EXPB'):
                raise SimError('a2 in exponent mode')
            A = Word(A.s, A.e, (A.m << 1) & M67)
        # the direction flag of ADDSUB/SUBADD (and SQT's suffix)
        dflag_src = e['dir']
        # the round logic, on A
        rinc = rmask = 0
        if e['rnd'] != 'NONE':
            rinc, rmask, self.INEX = self._round(e['rnd'], A)
        # B
        bsrc = e['bsrc']
        booth_neg = False
        if bsrc == 'ZERO':
            B = ZERO_W
        elif bsrc == 'T':
            B = self.T[m['rb']]
        elif bsrc in ('K', 'KLC'):
            addr = (m['rb'] + (self.LC if bsrc == 'KLC' else 0)) & 0xFF
            s, ex, mm, d = FD.kword_fields(self.krom[addr])
            B = Word(s, ex, mm)
            self.KDIR = d
        elif bsrc == 'FP':
            B = fp_word(self.fp[self._fpsel(e['fpsel'], m)])
        elif bsrc == 'OPINT':
            B = self.cu
        elif bsrc == 'OPRAW':
            B = Word(0, 0, (self.operand >> (32 * (2 - (self.LC & 3)))) & 0xFFFFFFFF)
        elif bsrc == 'CU':
            B = self.cu
        elif bsrc == 'BOOTH':
            q = self.Q
            d = -4 * ((q >> 2) & 1) + 2 * ((q >> 1) & 1) + (q & 1) + self.QX
            booth_neg = d < 0
            mag = abs(d)
            B = Word(0, 0, {0: 0, 1: self.MD, 2: self.MD << 1, 3: self.MD3, 4: self.MD << 2}[mag] & M67)
        elif bsrc == 'RINC':
            if e['rnd'] == 'NONE':
                raise SimError('b=RINC with rnd=none')
            B = Word(0, 0, rinc)
        elif bsrc == 'RMASK':
            if e['rnd'] == 'NONE':
                raise SimError('b=RMASK with rnd=none')
            B = Word(0, 0, rmask)
        elif bsrc == 'SQT':
            f = {'PREVN': self.N, 'DFLAG': self.DFLAG}.get(dflag_src)
            if f is None:
                raise SimError('b=SQT needs dir=prevn or dir=dflag')
            B = Word(0, 0, ((self.Q << 1) | ((3 if f else 1) << self.LC)) & M67)
        elif bsrc == 'Q':
            B = Word(0, 0, self.Q)
        elif bsrc == 'SC':
            B = Word(0, self.SC, self.SC)
        elif bsrc == 'LC':
            B = Word(0, self.LC, self.LC)
        elif bsrc == 'CMD':
            B = Word(0, self.cmd, self.cmd)
        else:
            raise SimError('bsrc %s' % bsrc)
        bx = e['bx']
        if bx == 'E2M':
            B = Word(B.s, B.e, B.e & M67)
        elif bx == 'M2E':
            B = Word(B.s, s18(B.m), B.m)
        # the barrel shifter, on B's mantissa
        shk = e['shk']
        out_bits = 0
        if shk != 'NONE':
            sha = e['sha']
            if sha == 'LIT':
                amt = e['lit']
            elif sha == 'SC':
                amt = self.SC
            elif sha == 'LC':
                amt = self.LC
            elif sha == 'LZC':
                amt = self.LZC
            elif sha == 'LCPSC':
                amt = self.LC + self.SC
            else:
                amt = self.LC - self.SC
                if amt < 0:
                    raise SimError('shift amount LC-SC = %d is negative' % amt)
            bm = B.m
            if shk == 'LSL':
                bm2 = (bm << amt) & M67
            elif shk == 'LSR':
                bm2 = bm >> amt if amt < 67 else 0
                out_bits = bm & ((1 << min(amt, 67)) - 1)
            else:
                v = s67(bm)
                bm2 = (v >> min(amt, 67)) & M67
                out_bits = bm & ((1 << min(amt, 67)) - 1)
            B = Word(B.s, B.e, bm2)
            if sha == 'LZC':
                self._sc_from_lzc = amt
        # the ALU
        alu, mode = e['alu'], e['emode']
        if alu == 'NOP':
            if e['dst'] != 'NONE' or e['osh'] != 'NONE':
                raise SimError('alu=nop with a destination or an output shift')
            self._side_effects(e, m, None, B, A, out_bits, 0, 0)
            return
        exp_mode = mode in ('EXP', 'EXPB')
        width = 18 if exp_mode else 67
        mask = (1 << width) - 1
        if exp_mode:
            x, y = A.e & mask, B.e & mask
        else:
            x, y = A.m, B.m
        if alu in ('ADDSUB', 'SUBADD'):
            flag = {'PREVN': self.N, 'DFLAG': self.DFLAG, 'BSIGN': B.s, 'BOOTH': booth_neg}[e['dir']]
            sub = bool(flag) if alu == 'ADDSUB' else not flag
            op = 'SUB' if sub else 'ADD'
        else:
            op = alu
        cin = e['cin']
        sx = x - (1 << width) if x >> (width - 1) else x
        sy = y - (1 << width) if y >> (width - 1) else y
        if op == 'ADD':
            Ru, Rs = x + y + cin, sx + sy + cin
        elif op == 'SUB':
            Ru, Rs = x - y + cin, sx - sy + cin
        elif op == 'RSUB':
            Ru, Rs = y - x + cin, sy - sx + cin
        elif op == 'PASSA':
            Ru, Rs = x, sx
        elif op == 'PASSB':
            Ru, Rs = y, sy
        elif op == 'AND':
            Ru = x & y; Rs = Ru
        elif op == 'OR':
            Ru = x | y; Rs = Ru
        elif op == 'XOR':
            Ru = x ^ y; Rs = Ru
        elif op == 'ANDN':
            Ru = x & ~y & mask; Rs = Ru
        else:
            raise SimError('alu %s' % op)
        r = Ru & mask
        C = (Ru >> width) & 1 if op in ('ADD', 'SUB', 'RSUB') else 0
        N = (r >> (width - 1)) & 1
        Z = int(r == 0)
        V = int(op in ('ADD', 'SUB', 'RSUB') and not -(1 << (width - 1)) <= Rs < (1 << (width - 1)))
        # the output shifter (mantissa modes)
        osh = e['osh']
        r2 = r
        dropped = 0
        if osh != 'NONE' and exp_mode:
            if osh != 'R1':
                raise SimError('only R1 in exponent mode')
            r2 = (s18(r) >> 1) & M18
        elif osh != 'NONE':
            if osh == 'L1':
                r2 = (r << 1) & M67
            elif osh == 'L1Q':
                r2 = (r << 1) & M67
                self.Q = ((self.Q << 1) | (1 - N)) & M67
            elif osh == 'R1':
                r2 = ((Ru & ((1 << 68) - 1)) >> 1) & M67
                dropped = r & 1
            elif osh == 'R3Q':
                r2 = (Rs >> 3) & M67
                self.QX = (self.Q >> 2) & 1
                self.Q = (self.Q >> 3) | ((Rs & 7) << 64)
            elif osh == 'QBIT':
                self.Q |= (1 - N) << self.LC
            elif osh == 'NORM':
                norm = 67 - r.bit_length() if r else 0
                r2 = (r << norm) & M67
        # the result word
        sgn = {'A': A.s, 'B': B.s, 'XOR': A.s ^ B.s, 'N': N, 'ZERO': 0, 'ONE': 1,
               'NOTA': A.s ^ 1, 'NOTB': B.s ^ 1}[e['sgn']]
        if mode == 'MANT':
            res = Word(sgn, A.e, r2)
        elif mode == 'MANTB':
            res = Word(sgn, B.e, r2)
        elif mode == 'EXP':
            res = Word(sgn, s18(r2), A.m)
        else:
            res = Word(sgn, s18(r2), B.m)
        if osh == 'NORM':
            res = Word(res.s, s18(res.e - norm), res.m)
        self.Z, self.N, self.C, self.V, self.S = Z, N, C, V, sgn
        self.LZC = 67 - res.m.bit_length()
        lo, hi = RANGE[self.RPREC]
        self.TINY, self.HUGE = int(res.e < lo), int(res.e > hi)
        if e['dl']:
            self.DFLAG = N
        self._side_effects(e, m, res, B, A, out_bits, dropped, r)

    def _fpsel(self, sel, m):
        if sel == 'SRC':
            return self.src_fp
        if sel == 'DST':
            return self.ry
        if sel == 'C':
            return self.cmd & 7
        return m['ra'] & 7

    def _side_effects(self, e, m, res, B, A, out_bits, dropped, r):
        # sticky (after the round logic has used it)
        stk = e['stk']
        if stk == 'CLR':
            self.STK = 0
        elif stk == 'SHIFT':
            self.STK |= int(bool(out_bits) or bool(dropped))
        elif stk == 'NZ':
            self.STK |= int(r != 0)
        # the destination
        d = e['dst']
        if d == 'T':
            self.T[m['rd']] = res
        elif d == 'FP':
            self.fp[self._fpsel(e['fpsel'], m)] = word_fp(res)
        elif d == 'MD':
            self.MD = res.m
        elif d == 'MD3':
            self.MD3 = res.m
        elif d == 'OBUFH':
            self.OBUF = (self.OBUF & ((1 << 64) - 1)) | (((res.m >> 35) & 0xFFFFFFFF) << 64)
        elif d == 'OBUFL':
            self.OBUF = (self.OBUF & ~M64 & ((1 << 96) - 1)) | ((res.m >> 3) & M64)
        elif d == 'OBUFX':
            self.OBUF = (res.s << 95) | ((res.e & EMAX) << 80) | ((res.m >> 3) & M64)
        elif d == 'EXOP':
            self.EXOP = (res.s, res.e & EMAX, (res.m >> 3) & M64)
        elif d == 'SC':
            v = res.e if e['emode'] in ('EXP', 'EXPB') else s67(res.m)
            self.SC = max(0, min(127, v))
        if e['shk'] != 'NONE' and e['sha'] == 'LZC':
            if d == 'SC':
                raise SimError('sha=LZC and d=SC in one word')
            self.SC = self._sc_from_lzc
        # Q
        q = e['qop']
        if q != 'HOLD' and e['osh'] in ('L1Q', 'R3Q'):
            raise SimError('q=%s with osh=%s' % (q, e['osh']))
        if q == 'LOAD':
            self.Q = res.m
        elif q == 'LOADB':
            self.Q, self.QX = B.m, 0
        elif q == 'CLEAR':
            self.Q = self.QX = 0
        # LC
        lc = e['lcop']
        if lc == 'LIT':
            self.LC = e['lit']
        elif lc == 'DEC':
            self.LC = (self.LC - 1) & 0xFF
        elif lc == 'INC':
            self.LC = (self.LC + 1) & 0xFF
        elif lc == 'ALU':
            if res is None:
                raise SimError('lc=alu with alu=nop')
            self.LC = (res.e if e['emode'] in ('EXP', 'EXPB') else res.m) & 0xFF
        # FPSR
        f = e['fpsr']
        if f == 'CLREXC':
            self.fpsr &= ~0xFF00
        if f in ('FPCC', 'FPCCINEX'):
            if res is None:
                raise SimError('fpsr=fpcc with alu=nop')
            t = tag(res)
            cc = CC_N if res.s else 0
            cc |= {FD.TAG['NAN']: CC_NAN, FD.TAG['INF']: CC_I, FD.TAG['ZERO']: CC_Z}.get(t, 0)
            self.fpsr = (self.fpsr & ~0x0F000000) | cc
        if f == 'ORLIT':
            self.fpsr |= e['lit'] << 8
        if f in ('INEX2R', 'FPCCINEX') and self.INEX:
            self.fpsr |= INEX2
        if f == 'QUOT':
            s = res.s if res is not None else 0
            self.fpsr = (self.fpsr & ~0x00FF0000) | (((s << 7) | (self.Q & 0x7F)) << 16)
        if f == 'ACCRUE':
            self.fpsr = accrue(self.fpsr)
        # control
        c = e['ctl']
        if c == 'END':
            # The instruction's end: AEXC accrues from EXC (6.1.10) - the
            # BIU's logic, as it takes the pending exception.
            self.fpsr = accrue(self.fpsr)
            self.done = True
        elif c == 'RETAG':
            if res is None:
                raise SimError('ctl=retag with alu=nop')
            self.stag, self.s_snan, self.s_den, self.s_neg = tag(res), is_snan(res), is_den(res), res.s
        elif c.startswith('RM_'):
            self.RMODE = None if c == 'RM_FPCR' else {'RM_RN': 0, 'RM_RZ': 1, 'RM_RM': 2, 'RM_RP': 3}[c]
        elif c.startswith('RP_'):
            if c == 'RP_PREC':
                p = (self.fpcr >> 6) & 3
                self.RPREC = 0 if p == 3 else p
            elif c == 'RP_DFMT':
                self.RPREC = {1: 1, 5: 2}.get((self.cmd >> 10) & 7, 0)
            else:
                self.RPREC = {'RP_EXT': 0, 'RP_SGL': 1, 'RP_DBL': 2, 'RP_SGLX': 3}[c]

    # -- one instruction -----------------------------------------------------------------------
    def run(self, entry_index, max_clocks=200000):
        self.upc = self.entry[entry_index]
        steps = 0
        while not self.done:
            self.step()
            steps += 1
            if steps > max_clocks:
                raise SimError('no END after %d microinstructions' % steps)
        return self.clocks
