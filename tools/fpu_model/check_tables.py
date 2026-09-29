"""The model against the manual's own tables and examples, transcribed by
hand from the plan (8.6.x) - independent of the model's code.

Covered: the special cases of 8.6.8 (signed zeros, infinities, NaNs, OPERR
and DZ) for the arithmetic instructions the model has; FCMP's table
(4-32); the conditionals (8.6.9) - the equations against WinUAE's table
on the eight FPCC values the chip produces; FMOVECR's documented constants
against mpmath in every PREC and RND; the FPSR accrual rules (6.1.10); the
trap rules (6.1.9, 6.1.2-6.1.6: priority, the unchanged register, the
exceptional operand, the inexact trap on an overflow); FSAVE-visible
reset state; the manual's single-precision overflow example (6-16).
"""

import sys
import mpmath
from mpmath import libmp

from harness import Checks
from xreal import Ext, BIAS, EMAX, NAN, inf, zero, ext_from_exact, M64, Q_BIT
import fpu as F
from fpu import FPU, evaluate_equation, WINUAE_CC_TABLE
import constants
import check_rounding
from switches import Switches

RNDS = ('RN', 'RZ', 'RM', 'RP')

ONE = Ext(0, BIAS, 1 << 63)
TWO = Ext(0, BIAS + 1, 1 << 63)
HALF = Ext(0, BIAS - 1, 1 << 63)
THREE = Ext(0, BIAS + 1, 3 << 62)
QNAN = Ext(0, EMAX, (1 << 63) | Q_BIT | 0x1234)
SNAN_ = Ext(1, EMAX, (1 << 63) | 0x5678)


def fp(prec=0, rnd=0, enable=0):
    f = FPU()
    f.fpcr = enable | (prec << 6) | (rnd << 4)
    return f


def dy(f, op, d, s):
    f.fp[0], f.fp[1] = d, s
    return f.general((1 << 10) | (0 << 7) | op)


def mono(f, op, s):
    f.fp[1] = s
    return f.general((1 << 10) | (0 << 7) | op)


def same(a: Ext, b: Ext):
    if a.is_nan and b.is_nan:
        return a == b
    if a.is_zero and b.is_zero:
        return a.s == b.s
    if a.is_inf and b.is_inf:
        return a.s == b.s
    return a == b


def cc_str(fpsr):
    c = (fpsr >> 24) & 0xF
    return ''.join(n for b, n in ((8, 'N'), (4, 'Z'), (2, 'I'), (1, 'NAN')) if c & b) or '-'


def exc_str(fpsr):
    names = ('BSUN', 'SNAN', 'OPERR', 'OVFL', 'UNFL', 'DZ', 'INEX2', 'INEX1')
    return ','.join(n for i, n in enumerate(names) if fpsr & (1 << (15 - i))) or '-'


def run(c: Checks):
    c.section('8.6.8: the special cases, dest op source, every RND')
    P, M = 0, 1
    z, nz, i_, ni = zero(0), zero(1), inf(0), inf(1)
    one, none = ONE, ONE.neg()
    # (op, name, dest, source, expected result or 'NAN', EXC, rnd or None)
    rows = [
        (0x22, 'FADD +0 + -0', z, nz, z, '-', (0, 1, 3)),
        (0x22, 'FADD +0 + -0 in RM', z, nz, nz, '-', (2,)),
        (0x22, 'FADD -0 + -0', nz, nz, nz, '-', None),
        (0x22, 'FADD +0 + +0', z, z, z, '-', None),
        (0x22, 'FADD x + -x', one, none, z, '-', (0, 1, 3)),
        (0x22, 'FADD x + -x in RM', one, none, nz, '-', (2,)),
        (0x22, 'FADD +inf + -inf', i_, ni, 'NAN', 'OPERR', None),
        (0x22, 'FADD -inf + +inf', ni, i_, 'NAN', 'OPERR', None),
        (0x22, 'FADD +inf + 1', i_, one, i_, '-', None),
        (0x22, 'FADD 1 + -inf', one, ni, ni, '-', None),
        (0x28, 'FSUB +0 - +0', z, z, z, '-', (0, 1, 3)),
        (0x28, 'FSUB +0 - +0 in RM', z, z, nz, '-', (2,)),
        (0x28, 'FSUB -0 - -0', nz, nz, z, '-', (0, 1, 3)),
        (0x28, 'FSUB -0 - -0 in RM', nz, nz, nz, '-', (2,)),
        (0x28, 'FSUB +0 - -0', z, nz, z, '-', None),
        (0x28, 'FSUB -0 - +0', nz, z, nz, '-', None),
        (0x28, 'FSUB +inf - +inf', i_, i_, 'NAN', 'OPERR', None),
        (0x28, 'FSUB -inf - -inf', ni, ni, 'NAN', 'OPERR', None),
        (0x28, 'FSUB +inf - -inf', i_, ni, i_, '-', None),
        (0x23, 'FMUL 0 x inf', z, i_, 'NAN', 'OPERR', None),
        (0x23, 'FMUL -inf x 0', ni, z, 'NAN', 'OPERR', None),
        (0x23, 'FMUL -1 x +0', none, z, nz, '-', None),
        (0x23, 'FMUL -inf x -1', ni, none, i_, '-', None),
        (0x27, 'FSGLMUL 0 x inf', z, i_, 'NAN', 'OPERR', None),
        (0x20, 'FDIV 1 / +0', one, z, i_, 'DZ', None),
        (0x20, 'FDIV 1 / -0', one, nz, ni, 'DZ', None),
        (0x20, 'FDIV -1 / +0', none, z, ni, 'DZ', None),
        (0x20, 'FDIV +inf / +0 (no DZ)', i_, z, i_, '-', None),
        (0x20, 'FDIV -inf / +0 (no DZ)', ni, z, ni, '-', None),
        (0x20, 'FDIV 0 / 0', z, z, 'NAN', 'OPERR', None),
        (0x20, 'FDIV inf / inf', i_, ni, 'NAN', 'OPERR', None),
        (0x20, 'FDIV +0 / -1', z, none, nz, '-', None),
        (0x20, 'FDIV 1 / -inf', one, ni, nz, '-', None),
        (0x24, 'FSGLDIV 1 / +0', one, z, i_, 'DZ', None),
        (0x24, 'FSGLDIV 0 / 0', z, z, 'NAN', 'OPERR', None),
        (0x21, 'FMOD x mod 0', one, z, 'NAN', 'OPERR', None),
        (0x21, 'FMOD inf mod x', i_, one, 'NAN', 'OPERR', None),
        (0x21, 'FMOD -0 mod x', nz, one, nz, '-', None),
        (0x21, 'FMOD x mod inf = x', THREE, i_, THREE, '-', None),
        (0x25, 'FREM x rem 0', one, z, 'NAN', 'OPERR', None),
        (0x25, 'FREM +0 rem x', z, none, z, '-', None),
        (0x26, 'FSCALE x by inf', one, i_, 'NAN', 'OPERR', None),
        (0x26, 'FSCALE -0 by 3', nz, THREE, nz, '-', None),
        (0x26, 'FSCALE -inf by 3', ni, THREE, ni, '-', None),
        (0x26, 'FSCALE 3 by 0', THREE, z, THREE, '-', None),
        (0x26, 'FSCALE 3 by 1.5 (chopped: x2)', THREE, Ext(0, BIAS, 3 << 62), Ext(0, BIAS + 2, 3 << 62), '-', None),
        (0x26, 'FSCALE 3 by -1.5 (chopped: /2)', THREE, Ext(1, BIAS, 3 << 62), Ext(0, BIAS, 3 << 62), '-', None),
    ]
    for op, name, d, s, want, exc, rnds in rows:
        bad = []
        for rnd in (rnds if rnds is not None else range(4)):
            f = fp(rnd=rnd)
            dy(f, op, d, s)
            got = f.fp[0]
            w = NAN if want == 'NAN' else want
            e = exc_str(f.fpsr)
            if not (same(got, w) and e == exc):
                bad.append('%s: %r %s, want %r %s' % (RNDS[rnd], got, e, w, exc))
        c.check(name, not bad, 'ok', bad)

    mono_rows = [
        (0x04, 'FSQRT +0', z, z, '-'), (0x04, 'FSQRT -0', nz, nz, '-'),
        (0x04, 'FSQRT +inf', i_, i_, '-'), (0x04, 'FSQRT -inf', ni, 'NAN', 'OPERR'),
        (0x04, 'FSQRT -1', none, 'NAN', 'OPERR'),
        (0x04, 'FSQRT 4', Ext(0, BIAS + 2, 1 << 63), TWO, '-'),
        (0x18, 'FABS -0', nz, z, '-'), (0x18, 'FABS -inf', ni, i_, '-'),
        (0x1A, 'FNEG +0', z, nz, '-'), (0x1A, 'FNEG -inf', ni, i_, '-'),
        (0x01, 'FINT -0', nz, nz, '-'), (0x01, 'FINT -inf', ni, ni, '-'),
        (0x03, 'FINTRZ -0.5', HALF.neg(), nz, 'INEX2'),
        (0x1E, 'FGETEXP -0', nz, nz, '-'), (0x1E, 'FGETEXP inf', i_, 'NAN', 'OPERR'),
        (0x1E, 'FGETEXP 3', THREE, ONE, '-'),
        (0x1E, 'FGETEXP 0.5', HALF, ONE.neg(), '-'),
        (0x1F, 'FGETMAN -0', nz, nz, '-'), (0x1F, 'FGETMAN -inf', ni, 'NAN', 'OPERR'),
        (0x1F, 'FGETMAN -3 (in [1,2), the sign kept)', THREE.neg(), Ext(1, BIAS, 3 << 62), '-'),
        (0x00, 'FMOVE -inf', ni, ni, '-'),
    ]
    for op, name, s, want, exc in mono_rows:
        bad = []
        for rnd in range(4):
            f = fp(rnd=rnd)
            mono(f, op, s)
            got = f.fp[0]
            w = NAN if want == 'NAN' else want
            e = exc_str(f.fpsr)
            if not (same(got, w) and e == exc):
                bad.append('%s: %r %s, want %r %s' % (RNDS[rnd], got, e, w, exc))
        c.check(name, not bad, 'ok', bad)

    # FMOD/FREM (4-62, 4-86): value and the quotient byte (sign, 7 bits).
    def q_of(f):
        return (f.fpsr >> 23) & 1, (f.fpsr >> 16) & 0x7F
    n = lambda v: ext_from_exact(1 if v < 0 else 0, abs(v), 0)
    cases = [(0x21, 7, 2, 1, (0, 3)), (0x21, -7, 2, -1, (1, 3)), (0x21, 7, -2, 1, (1, 3)),
             (0x25, 5, 2, 1, (0, 2)), (0x25, 7, 2, -1, (0, 4)), (0x25, -7, 2, 1, (1, 4)),
             (0x25, 3, 2, -1, (0, 2)), (0x21, 1000, 3, 1, (0, 333 & 0x7F)),
             (0x25, 1000, 3, 1, (0, 333 & 0x7F)), (0x25, 1001, 3, -1, (0, 334 & 0x7F))]
    bad = []
    for op, a_, b_, r_, q_ in cases:
        f = fp()
        dy(f, op, n(a_), n(b_))
        if f.fp[0] != n(r_) or q_of(f) != q_:
            bad.append('%s %d, %d: %r q %s, want %d q %s' % ('FMOD' if op == 0x21 else 'FREM',
                                                             a_, b_, f.fp[0], q_of(f), r_, q_))
    c.check('FMOD (N toward zero) and FREM (N to nearest, ties even): values and the quotient byte',
            not bad, len(cases), bad)

    # FINT's examples (4-50): 137.57 -> 137 in RZ and RM, 138 in RN and RP.
    bad = []
    for rnd, want in ((0, 138), (1, 137), (2, 137), (3, 138)):
        f = fp(rnd=rnd)
        # 137.57 as the extended nearest: 13757/100 by FDIV.
        f.fp[0] = ext_from_exact(0, 13757, 0)
        f.fp[1] = ext_from_exact(0, 100, 0)
        f.general((1 << 10) | (0 << 7) | 0x20)
        f.general((0 << 10) | (0 << 7) | 0x01)
        s, m, e = f.fp[0].exact()
        if (m << e if e >= 0 else m >> -e) != want or (m & ((1 << -e) - 1) if e < 0 else 0):
            bad.append('%s: %r' % (RNDS[rnd], f.fp[0]))
    c.check('FINT 137.57: 137 in RZ and RM, 138 in RN and RP (4-50)', not bad, 'ok', bad)

    c.section('4.5.4: NaNs')
    f = fp()
    dy(f, 0x22, QNAN, Ext(1, EMAX, (1 << 63) | Q_BIT | 0x99))
    c.check('two nonsignaling NaNs: the destination\'s', f.fp[0] == QNAN, repr(f.fp[0]))
    f = fp()
    dy(f, 0x22, ONE, QNAN)
    c.check('one NaN (the source): that NaN, no exception',
            f.fp[0] == QNAN and exc_str(f.fpsr) == '-', repr(f.fp[0]))
    f = fp()
    dy(f, 0x23, SNAN_, ONE)
    c.check('a signaling NaN: SNAN set, made nonsignaling (bit 62), nothing else changed',
            f.fp[0] == SNAN_.quiet() and exc_str(f.fpsr) == 'SNAN', repr(f.fp[0]))
    f = fp(enable=F.SNAN)
    f.fp[0] = THREE
    o = dy(f, 0x23, THREE, SNAN_)
    c.check('a signaling NaN, SNAN trap enabled: the register not modified, vector 54, '
            'the source as the exceptional operand',
            f.fp[0] == THREE and o.vector == 54 and o.xop == SNAN_, '%r %s' % (f.fp[0], o))
    f = fp()
    dy(f, 0x22, SNAN_, QNAN)
    c.check('SNaN dest + QNaN source: SNAN, and the destination\'s NaN (quieted)',
            f.fp[0] == SNAN_.quiet() and exc_str(f.fpsr) == 'SNAN', repr(f.fp[0]))
    f = fp()
    dy(f, 0x20, z, z)
    c.check('an invalid operation creates the all-ones NaN $7FFF FFFFFFFF FFFFFFFF',
            f.fp[0] == Ext(0, 0x7FFF, M64), repr(f.fp[0]))

    c.section('4-32: FCMP\'s condition codes (dest \\ src)')
    vals = {'+range': ONE, '-range': ONE.neg(), '+0': z, '-0': nz, '+inf': i_, '-inf': ni}
    cols = ['+range', '-range', '+0', '-0', '+inf', '-inf']
    table = {
        '+range': ['{NZ}', '-', '-', '-', 'N', '-'],
        '-range': ['N', '{NZ}', 'N', 'N', 'N', '-'],
        '+0': ['N', '-', 'Z', 'Z', 'N', '-'],
        '-0': ['N', '-', 'NZ', 'NZ', 'N', '-'],
        '+inf': ['-', '-', '-', '-', 'Z', '-'],
        '-inf': ['N', 'N', 'N', 'N', 'N', 'NZ'],
    }
    bad = []
    for dn, row in table.items():
        for sn, want in zip(cols, row):
            d, s = vals[dn], vals[sn]
            if want == '{NZ}':
                # From the subtraction: equal -> Z; else by sign.  Tested with
                # the equal and two unequal operands.
                cases = [(d, s, 'Z'),
                         (d, Ext(s.s, s.e - 1, s.m), '-' if d.s == 0 else 'N'),
                         (d, Ext(s.s, s.e + 1, s.m), 'N' if d.s == 0 else '-')]
            else:
                cases = [(d, s, want)]
            for dd, ss, w in cases:
                for rnd in range(4):
                    f = fp(rnd=rnd)
                    f.fp[0] = dd
                    dy(f, 0x38, dd, ss)
                    got = cc_str(f.fpsr)
                    if got != w or f.fp[0] != dd:
                        bad.append('%s cmp %r, %s: %s want %s' % (dn, ss, RNDS[rnd], got, w))
    c.check('FCMP: all 36 cells (range cells three ways), every RND, I never set, '
            'no register written', not bad, 36, bad[:6])
    f = fp()
    f.fp[0] = ONE
    dy(f, 0x38, ONE, QNAN.neg())
    c.check('FCMP with a NaN: NAN set; N clear (8.6.14 item 22, WinUAE\'s lead)',
            cc_str(f.fpsr) == 'NAN', cc_str(f.fpsr))

    c.section('8.6.9: the conditionals')
    legal = [0b0000, 0b1000, 0b0100, 0b1100, 0b0010, 0b1010, 0b0001, 0b1001]
    bad = []
    for cc in legal:
        for pred in range(32):
            if evaluate_equation(pred, cc) != bool(WINUAE_CC_TABLE[cc * 32 + pred]):
                bad.append('FPCC %s pred $%02X' % (bin(cc), pred))
    c.check('the equations and WinUAE\'s table agree on the eight FPCC values the '
            'chip produces, all 32 predicates', not bad, len(legal) * 32, bad[:6])
    diff = [(cc, pred) for cc in range(16) if cc not in legal for pred in range(32)
            if evaluate_equation(pred, cc) != bool(WINUAE_CC_TABLE[cc * 32 + pred])]
    c.check('where they differ: only the FPCC values the chip never produces '
            '(8.6.14 item 17; reported)', True,
            '%d cells, e.g. %s' % (len(diff), ', '.join('%s/$%02X' % (bin(a), b) for a, b in diff[:4])))
    # BSUN: set and IOP when NAN is set and the predicate is $10-$1F.
    f = fp()
    f.fpsr = F.CC_NAN
    o = f.condition(0x12)
    c.check('GT with NAN set: BSUN and AEXC.IOP set, the answer false, no trap',
            (f.fpsr & F.BSUN) and (f.fpsr & F.A_IOP) and o.cond is False and o.vector is None,
            '%08X %s' % (f.fpsr, o))
    f = fp(enable=F.BSUN)
    f.fpsr = F.CC_NAN
    o = f.condition(0x32)
    c.check('GT (bit 5 set, ignored) with NAN and BSUN enabled: vector 48 instead of an answer',
            o.vector == 48 and o.cond is None, str(o))
    f = fp()
    f.fpsr = F.CC_NAN
    o = f.condition(0x02)
    c.check('OGT with NAN set: no BSUN', not (f.fpsr & F.BSUN) and o.cond is False, '%08X' % f.fpsr)

    c.section('4-72/4-73: FMOVECR, the documented constants against mpmath')
    mp = mpmath.mp
    mp.prec = 400
    exact = {0x00: mp.pi, 0x0B: mpmath.log10(2), 0x0C: mpmath.e, 0x0D: 1 / mpmath.ln2,
             0x0E: mpmath.log10(mpmath.e), 0x0F: mpmath.mpf(0), 0x30: mpmath.ln2,
             0x31: mpmath.ln(10)}
    for i, n in enumerate([0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]):
        exact[0x32 + i] = mpmath.mpf(10) ** n
    exact_sw = Switches(fmovecr_documented='exact')
    bad, count = [], 0
    for off, v in exact.items():
        for prec in (0, 1, 2):
            for rnd in range(4):
                f = FPU(exact_sw)
                f.fpcr = (prec << 6) | (rnd << 4)
                f.general(0x5C00 | (2 << 7) | off)
                got = f.fp[2]
                count += 1
                if v == 0:
                    ok = got == zero(0) and exc_str(f.fpsr) == '-'
                else:
                    # The full post-processing: 10^64 and up overflow in
                    # single PREC, 10^512 and up in double.
                    p, emin, emax = check_rounding.FMTS[prec]
                    ref, unfl, ovfl, inex = check_rounding.ref_round(
                        v._mpf_, p, emin, emax, check_rounding.MODES[rnd])
                    ok = (check_rounding.value_eq(got, ref)
                          and bool(f.fpsr & F.OVFL) == ovfl
                          and bool(f.fpsr & F.INEX2) == inex)
                if not ok:
                    bad.append('$%02X %s PREC %d %s: %r %s' % (off, constants.NAMES[off], prec,
                                                              RNDS[rnd], got, exc_str(f.fpsr)))
    c.check("item 19 'exact': all 22 documented offsets, every PREC and RND, the exact "
            'value rounded once, OVFL and INEX2 as mpmath', not bad, count, bad[:6])
    f = fp()
    f.general(0x5C00 | (2 << 7) | 0x00)
    c.check('FMOVECR #0 (pi), extended RN: $4000 C90FDAA2 2168C235',
            f.fp[2] == Ext(0, 0x4000, 0xC90FDAA22168C235), repr(f.fp[2]))
    # Where item 19's other readings differ from 'exact' (reported), and
    # the default's differences pinned: log10(2) and e in extended RN, and
    # log10(e) in extended - nothing else.
    for alt in ('rom64', 'winuae'):
        diffs = []
        for off in exact:
            for prec in (0, 1, 2):
                for rnd in range(4):
                    a, b = FPU(exact_sw), FPU(Switches(fmovecr_documented=alt))
                    a.fpcr = b.fpcr = (prec << 6) | (rnd << 4)
                    a.general(0x5C00 | (2 << 7) | off)
                    b.general(0x5C00 | (2 << 7) | off)
                    if a.fp[2] != b.fp[2] or (a.fpsr & 0xFF00) != (b.fpsr & 0xFF00):
                        diffs.append('$%02X/%s/%s' % (off, 'XSD'[prec], RNDS[rnd]))
        c.check("item 19: where '%s' differs from the exact rounding (reported)" % alt,
                True, '%d of %d: %s' % (len(diffs), 22 * 12, ', '.join(diffs)))
        if alt == 'rom64':
            want = ['$0B/X/RN', '$0C/X/RN', '$0E/X/RN', '$0E/X/RZ', '$0E/X/RM', '$0E/X/RP']
            c.check("the default ('rom64') differs from 'exact' only in log10(2) and e in "
                    'extended RN and log10(e) in extended', diffs == want, ', '.join(diffs))
    f = fp()
    f.general(0x5C00 | (2 << 7) | 0x0B)
    c.check("default: FMOVECR #$0B (log10 2), extended RN: WinUAE's $3FFD 9A209A84 FBCFF798 "
            '(the exact value rounds to ...799)',
            f.fp[2] == Ext(0, 0x3FFD, 0x9A209A84FBCFF798) and exc_str(f.fpsr) == 'INEX2',
            '%r %s' % (f.fp[2], exc_str(f.fpsr)))

    c.section('6.1.10: AEXC')
    f = fp()
    f.fpsr = 0
    dy(f, 0x20, z, z)                           # OPERR
    c.check('OPERR accrues IOP', (f.fpsr & 0xF8) == F.A_IOP, '%02X' % (f.fpsr & 0xFF))
    f = fp()
    dy(f, 0x20, ONE, z)                         # DZ
    c.check('DZ accrues DZ', (f.fpsr & 0xF8) == F.A_DZ, '%02X' % (f.fpsr & 0xFF))
    f = fp(prec=1)
    dy(f, 0x23, Ext(0, BIAS + 100, 1 << 63), Ext(0, BIAS + 100, 1 << 63))   # 2^200 in single
    c.check('an exact overflow (2^200 in single): OVFL, INEX2 clear, AEXC OVFL and INEX',
            exc_str(f.fpsr) == 'OVFL' and (f.fpsr & 0xF8) == (F.A_OVFL | F.A_INEX),
            '%s %02X' % (exc_str(f.fpsr), f.fpsr & 0xFF))
    f = fp()
    dy(f, 0x23, Ext(0, 1, 1 << 63), Ext(0, BIAS - 2, 1 << 63))  # exact tiny
    c.check('an exact underflow: EXC.UNFL, AEXC.UNFL clear (tiny and exact)',
            exc_str(f.fpsr) == 'UNFL' and (f.fpsr & 0xF8) == 0,
            '%s %02X' % (exc_str(f.fpsr), f.fpsr & 0xFF))
    f = fp()
    dy(f, 0x23, Ext(0, 1, 3 << 62), Ext(0, BIAS - 64, 1 << 63))  # inexact tiny
    c.check('an inexact underflow: UNFL and INEX2; AEXC UNFL and INEX',
            exc_str(f.fpsr) == 'UNFL,INEX2' and (f.fpsr & 0xF8) == (F.A_UNFL | F.A_INEX),
            '%s %02X' % (exc_str(f.fpsr), f.fpsr & 0xFF))
    f = fp()
    f.fpsr = 0xF8
    dy(f, 0x22, ONE, ONE)
    c.check('AEXC is sticky: an exact instruction leaves it', (f.fpsr & 0xF8) == 0xF8,
            '%02X' % (f.fpsr & 0xFF))
    f = fp()
    f.fpsr = 0xFF00
    dy(f, 0x22, ONE, ONE)
    c.check('EXC is cleared at the start of an arithmetic instruction', (f.fpsr & 0xFF00) == 0,
            '%04X' % (f.fpsr & 0xFFFF))
    f = fp()
    f.fpsr = 0xFF00
    f.general(0xA000 | (7 << 10))                     # FMOVEM control regs out
    c.check('FMOVE of the control registers leaves EXC alone', (f.fpsr & 0xFF00) == 0xFF00,
            '%04X' % (f.fpsr & 0xFFFF))

    c.section('6.1.9, 6.1.2-6.1.7: the traps')
    f = fp(enable=F.DZ)
    f.fp[0] = THREE
    o = dy(f, 0x20, THREE, z)
    c.check('DZ enabled: vector 50, FP0 not modified, the source as the exceptional operand',
            o.vector == 50 and f.fp[0] == THREE and o.xop == z and o.when == 'pre', str(o))
    f = fp(enable=F.OPERR)
    o = dy(f, 0x22, i_, ni)
    c.check('OPERR enabled: vector 52, FP0 not modified', o.vector == 52 and f.fp[0] == i_, str(o))
    f = fp(enable=F.INEX2)
    o = dy(f, 0x23, Ext(0, 0x7FFE, 1 << 63), TWO)     # an exact overflow
    c.check('OVFL with only INEX2 enabled: the inexact trap (vector 49), the default result written',
            o.vector == 49 and f.fp[0] == i_, str(o))
    f = fp(enable=F.OVFL | F.INEX2)
    o = dy(f, 0x23, Ext(0, 0x7FFE, M64), THREE)        # an inexact overflow
    c.check('OVFL and INEX2 both set and enabled: OVFL (53) by priority',
            o.vector == 53 and exc_str(f.fpsr) == 'OVFL,INEX2', '%s %s' % (o, exc_str(f.fpsr)))
    f = fp(enable=F.OPERR | F.INEX1)
    f.fpsr = 0
    o = dy(f, 0x22, i_, ni)
    c.check('OPERR enabled: vector 52', o.vector == 52, str(o))
    # The exceptional operand of an overflow to a register: the exponent
    # wrapped by -$6000 (6.1.4).  2^16000 x 2^16000: E = 32000.
    f = fp(enable=F.OVFL)
    big = Ext(0, BIAS + 16000, 1 << 63)
    o = dy(f, 0x23, big, big)
    want = Ext(0, (32000 + BIAS - 0x6000) & 0x7FFF, 1 << 63)
    c.check('OVFL exceptional operand: 2^32000 wrapped to $%04X' % want.e,
            o.vector == 53 and o.xop == want, '%r' % (o.xop,))
    f = fp(enable=F.UNFL)
    tiny = Ext(0, BIAS - 16000, 1 << 63)
    o = dy(f, 0x23, tiny, tiny)
    want = Ext(0, (-32000 + BIAS + 0x6000) & 0x7FFF, 1 << 63)
    c.check('UNFL exceptional operand: 2^-32000 wrapped to $%04X' % want.e,
            o.vector == 51 and o.xop == want, '%r' % (o.xop,))
    # FSCALE by an enormous source (the vectors found the model failing
    # here, 2026-09-29): "an overflow or underflow always results" (4-93),
    # the 17-bit intermediate far past its limit - catastrophic.
    f = fp(enable=F.OVFL)
    o = dy(f, 0x26, THREE, Ext(0, 0x7FFE, 1 << 63))            # x 2^(2^16383)
    c.check('FSCALE by 2^16383: OVFL, +inf, a catastrophic exceptional operand ($0000)',
            o.vector == 53 and f.fp[0] == inf(0) and o.xop.e == 0, '%r %s' % (f.fp[0], o))
    f = fp(enable=F.UNFL)
    o = dy(f, 0x26, THREE, Ext(1, 0x7FFE, 1 << 63))            # x 2^-(2^16383)
    c.check('FSCALE by -2^16383: UNFL, +0, a catastrophic exceptional operand ($0000)',
            o.vector == 51 and f.fp[0] == zero(0) and o.xop.e == 0, '%r %s' % (f.fp[0], o))
    f = fp(prec=1, rnd=2)
    dy(f, 0x23, Ext(0, BIAS + 100, 1 << 63), Ext(0, BIAS + 100, 1 << 63))
    c.check('6-16\'s example: single/RM positive overflow stores the largest single, '
            '$407E FFFFFF00 00000000', f.fp[0] == Ext(0, 0x407E, 0xFFFFFF0000000000),
            repr(f.fp[0]))
    f = fp(enable=F.OVFL)
    f.fp[7] = Ext(0, BIAS + 200, 1 << 63)
    o = f.general(0x6000 | (F.FMT_S << 10) | (7 << 7))
    c.check('FMOVE.S of 2^200 with OVFL enabled: stored +inf, then a mid-instruction '
            'exception (vector 53); FPCC unchanged', o.store == 0x7F800000 and o.vector == 53
            and o.when == 'mid', str(o))

    c.section('8.6.2, 8.6.14 item 8: reset and the control registers')
    f = FPU()
    c.check('reset: FP0-FP7 the nonsignaling NaN $7FFF FFFFFFFF FFFFFFFF, FPCR/FPSR/FPIAR 0',
            all(x == Ext(0, 0x7FFF, M64) for x in f.fp) and f.fpcr == f.fpsr == f.fpiar == 0,
            'ok')
    f.general(0x8000 | (7 << 10), [0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF])
    c.check('FMOVEM to FPCR/FPSR/FPIAR: unimplemented bits read zero ($0000FFF0, $0FFFFFF8)',
            f.fpcr == 0xFFF0 and f.fpsr == 0x0FFFFFF8 and f.fpiar == 0xFFFFFFFF,
            '%08X %08X' % (f.fpcr, f.fpsr))
    f = FPU()
    f.general(0x8000 | (0 << 10), [0x12345678])
    c.check('control-register list 000 moves FPIAR (Table 4-17)', f.fpiar == 0x12345678,
            '%08X' % f.fpiar)
    f = FPU()
    f.fp[0], f.fp[7] = ONE, TWO
    o = f.general(0xE000 | (2 << 11) | 0x81)       # FMOVEM FP0/FP7,<ea>: static, control
    c.check('FMOVEM out, static list, postincrement order: bit 7 = FP0, bit 0 = FP7',
            o.store == [ONE.bits96(), TWO.bits96()], str(o.store))
    o = f.general(0xE000 | (0 << 11) | 0x01)       # -(An): bit 0 = FP0
    o2 = f.general(0xE000 | (2 << 11) | 0x01)      # control: bit 0 = FP7
    c.check('FMOVEM out, list $01: FP0 for -(An), FP7 for the control modes',
            o.store == [ONE.bits96()] and o2.store == [TWO.bits96()], '%s %s' % (o.store, o2.store))
    f = FPU()
    f.general(0xC000 | (2 << 11) | 0x10, [SNAN_.bits96()])  # FMOVEM <ea>,FP3: static
    c.check('FMOVEM in: a signaling NaN loaded unchecked, no exception, FPSR untouched',
            f.fp[3] == SNAN_ and f.fpsr == 0, repr(f.fp[3]))

    c.section('8.6.7: decode')
    f = FPU()
    o = f.general((1 << 10) | 0x40)
    c.check('opmode $40: F-line', o.vector == 11, str(o))
    o = f.general(0x2000)
    c.check('opclass 001: F-line', o.vector == 11, str(o))
    f = fp()
    f.fp[1] = Ext(0, BIAS + 2, 1 << 63)
    f.general((1 << 10) | (1 << 7) | 0x05)
    c.check('redundant opmode $05 executes FSQRT (8.6.14 item 6, WinUAE\'s lead)',
            f.fp[1] == TWO, repr(f.fp[1]))


if __name__ == '__main__':
    c = Checks()
    run(c)
    sys.exit(c.summary())
