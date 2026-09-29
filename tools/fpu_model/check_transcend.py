"""The transcendentals (plan 8.7 work 5c) against the manual: 8.6.8's
special cases in every RND, 8.6.14 items 1 and 2 in both settings, the
accuracy of 4.3.2 (worst case one unit of double = 4096 units of
extended; typically about 64) measured with mpmath over each function's
domain, the ranges the results must stay in under every rounding mode,
the flags (INEX2 on computed results, UNFL, OVFL and the catastrophic
exceptional operand, DZ, OPERR), FSINCOS's two registers, and the
documented losses (trig reduction above 2pi, near 10^20 total) as
reports.
"""

import random
import sys

import mpmath

from harness import Checks
from xreal import Ext, BIAS, EMAX, J_BIT, NAN, inf, zero, ext_from_exact
import fpu as F
from fpu import FPU
from switches import Switches

RNDS = ('RN', 'RZ', 'RM', 'RP')
mpmath.mp.prec = 320


class HalfPi:
    """An expected result of +/-pi/2, rounded (Ext is a tuple; this is not)."""
    def __init__(self, s):
        self.s = s

    def __repr__(self):
        return '%spi/2' % ('-' if self.s else '+')
ONE = Ext(0, BIAS, J_BIT)

OPS = {'sinh': 0x02, 'lognp1': 0x06, 'etoxm1': 0x08, 'tanh': 0x09, 'atan': 0x0A,
       'asin': 0x0C, 'atanh': 0x0D, 'sin': 0x0E, 'tan': 0x0F, 'etox': 0x10,
       'twotox': 0x11, 'tentox': 0x12, 'logn': 0x14, 'log10': 0x15, 'log2': 0x16,
       'cosh': 0x19, 'acos': 0x1C, 'cos': 0x1D}


def run_op(op, x, rnd=0, prec=0, sw=None, enable=0):
    f = FPU(sw) if sw else FPU()
    f.fpcr = enable | (prec << 6) | (rnd << 4)
    f.fp[1] = x
    o = f.general((1 << 10) | (2 << 7) | op)
    return f.fp[2], f.fpsr, o


def mpv(x: Ext):
    s, m, e = x.exact()
    v = mpmath.mpf(m) * mpmath.mpf(2) ** e
    return -v if s else v


def exc_str(fpsr):
    names = ('BSUN', 'SNAN', 'OPERR', 'OVFL', 'UNFL', 'DZ', 'INEX2', 'INEX1')
    return ','.join(n for i, n in enumerate(names) if fpsr & (1 << (15 - i))) or '-'


def same(a, b):
    if a.is_nan and b.is_nan:
        return True
    return a == b


def run(c: Checks, n=300, seed=7):
    rng = random.Random(seed)
    z, nz, pinf, ninf = zero(0), zero(1), inf(0), inf(1)
    m1 = ONE.neg()
    two = Ext(0, BIAS + 1, J_BIT)
    halfpi = mpmath.pi / 2

    c.section('8.6.8: the special cases, every RND')
    # (name, source, expected Ext or 'NAN' or ('pi/2', sign) , EXC)
    rows = [
        ('sinh', z, z, '-'), ('sinh', nz, nz, '-'), ('sinh', ninf, ninf, '-'),
        ('lognp1', nz, nz, '-'), ('lognp1', pinf, pinf, '-'), ('lognp1', ninf, 'NAN', 'OPERR'),
        ('lognp1', Ext(1, BIAS + 1, J_BIT), 'NAN', 'OPERR'),
        ('etoxm1', nz, nz, '-'), ('etoxm1', pinf, pinf, '-'), ('etoxm1', ninf, m1, '-'),
        ('tanh', nz, nz, '-'), ('tanh', pinf, ONE, '-'), ('tanh', ninf, m1, '-'),
        ('atan', nz, nz, '-'), ('atan', pinf, HalfPi(0), 'INEX2'), ('atan', ninf, HalfPi(1), 'INEX2'),
        ('asin', nz, nz, '-'), ('asin', pinf, 'NAN', 'OPERR'), ('asin', two, 'NAN', 'OPERR'),
        ('asin', Ext(1, BIAS, J_BIT | 1), 'NAN', 'OPERR'),
        ('atanh', nz, nz, '-'), ('atanh', ninf, 'NAN', 'OPERR'), ('atanh', two.neg(), 'NAN', 'OPERR'),
        ('sin', nz, nz, '-'), ('sin', pinf, 'NAN', 'OPERR'),
        ('tan', z, z, '-'), ('tan', ninf, 'NAN', 'OPERR'),
        ('cos', nz, ONE, '-'), ('cos', pinf, 'NAN', 'OPERR'),
        ('etox', nz, ONE, '-'), ('etox', pinf, pinf, '-'), ('etox', ninf, z, '-'),
        ('twotox', z, ONE, '-'), ('twotox', ninf, z, '-'),
        ('tentox', nz, ONE, '-'), ('tentox', pinf, pinf, '-'),
        ('logn', z, ninf, 'DZ'), ('logn', nz, ninf, 'DZ'), ('logn', pinf, pinf, '-'),
        ('logn', ninf, 'NAN', 'OPERR'), ('logn', m1, 'NAN', 'OPERR'), ('logn', ONE, z, '-'),
        ('log10', z, ninf, 'DZ'), ('log10', m1, 'NAN', 'OPERR'),
        ('log2', nz, ninf, 'DZ'), ('log2', ninf, 'NAN', 'OPERR'),
        ('cosh', nz, ONE, '-'), ('cosh', ninf, pinf, '-'),
        ('acos', z, HalfPi(0), 'INEX2'), ('acos', nz, HalfPi(0), 'INEX2'),
        ('acos', pinf, 'NAN', 'OPERR'), ('acos', two.neg(), 'NAN', 'OPERR'),
    ]
    bad = []
    for name, x, want, exc in rows:
        for rnd in range(4):
            got, fpsr, o = run_op(OPS[name], x, rnd)
            if isinstance(want, HalfPi):
                ref = mpmath.pi / 2 * (-1 if want.s else 1)
                ok = got.is_finite and not got.is_zero and abs(mpv(got) - ref) < mpmath.mpf(2) ** -62
            elif want == 'NAN':
                ok = got.is_nan
            else:
                ok = same(got, want)
            if not ok or exc_str(fpsr) != exc:
                bad.append('%s(%r) %s: %r %s, want %s %s' % (name, x, RNDS[rnd], got,
                                                             exc_str(fpsr), want, exc))
    c.check('every row of the table for the eighteen functions (4 x %d)' % len(rows), not bad,
            4 * len(rows), bad[:6])

    c.section('8.6.14 items 1 and 2, both settings')
    got, fpsr, _ = run_op(OPS['atanh'], ONE)
    got2, fpsr2, _ = run_op(OPS['atanh'], m1)
    c.check("FATANH(+1) = -inf and FATANH(-1) = +inf with DZ ('manual', 4-28 as printed)",
            got == ninf and got2 == pinf and exc_str(fpsr) == exc_str(fpsr2) == 'DZ',
            '%r %r %s' % (got, got2, exc_str(fpsr)))
    sw = Switches(fatanh_one='ieee')
    got, fpsr, _ = run_op(OPS['atanh'], ONE, sw=sw)
    got2, _, _ = run_op(OPS['atanh'], m1, sw=sw)
    c.check("FATANH(+/-1) = +/-inf with DZ ('ieee')", got == pinf and got2 == ninf
            and exc_str(fpsr) == 'DZ', '%r %r' % (got, got2))
    got, fpsr, _ = run_op(OPS['lognp1'], m1)
    c.check("FLOGNP1(-1) = NaN with DZ ('manual', 4-60)", got.is_nan and exc_str(fpsr) == 'DZ',
            '%r %s' % (got, exc_str(fpsr)))
    got, fpsr, _ = run_op(OPS['lognp1'], m1, sw=Switches(flognp1_minus_one='neg_inf'))
    c.check("FLOGNP1(-1) = -inf with DZ ('neg_inf', 6.1.6)", got == ninf and exc_str(fpsr) == 'DZ',
            '%r %s' % (got, exc_str(fpsr)))
    f = FPU()
    f.fpcr = F.DZ
    f.fp[2] = two
    f.fp[1] = zero(0)
    o = f.general((1 << 10) | (2 << 7) | OPS['logn'])
    c.check('FLOGN(0) with DZ enabled: vector 50, the register not modified',
            o.vector == 50 and f.fp[2] == two, str(o))

    c.section('4.3.2: accuracy against mpmath (extended, RN); bound 4096, typically 64')

    def mag(lo, hi, sign=None):
        E = rng.randint(lo, hi)
        s = rng.getrandbits(1) if sign is None else sign
        return Ext(s, BIAS + E, J_BIT | rng.getrandbits(63))

    def near_one(sign, below=True):
        k = rng.randint(2, 62)
        d = mpmath.mpf(2) ** -k * mpmath.mpf(rng.random())
        v = 1 - d if below else 1 + d
        man, e = mpmath.frexp(v)
        return Ext(sign, BIAS + e - 1, int(man * 2 ** 64))

    dom = {
        'sin': (mpmath.sin, lambda: mag(-80, 2)), 'cos': (mpmath.cos, lambda: mag(-80, 2)),
        'tan': (mpmath.tan, lambda: mag(-80, 2)), 'atan': (mpmath.atan, lambda: mag(-80, 80)),
        'asin': (mpmath.asin, lambda: mag(-80, -1) if rng.random() < .7 else near_one(rng.getrandbits(1))),
        'acos': (mpmath.acos, lambda: mag(-80, -1) if rng.random() < .7 else near_one(rng.getrandbits(1))),
        'etox': (mpmath.exp, lambda: mag(-80, 13)),
        'twotox': (lambda v: mpmath.mpf(2) ** v, lambda: mag(-80, 13)),
        'tentox': (lambda v: mpmath.mpf(10) ** v, lambda: mag(-80, 11)),
        'etoxm1': (mpmath.expm1, lambda: mag(-80, 13)),
        'sinh': (mpmath.sinh, lambda: mag(-80, 13)), 'cosh': (mpmath.cosh, lambda: mag(-80, 13)),
        'tanh': (mpmath.tanh, lambda: mag(-80, 8)),
        'logn': (mpmath.ln, lambda: mag(-16000, 16000, 0) if rng.random() < .6 else near_one(0, rng.random() < .5)),
        'log2': (lambda v: mpmath.log(v, 2), lambda: mag(-16000, 16000, 0) if rng.random() < .6 else near_one(0, rng.random() < .5)),
        'log10': (mpmath.log10, lambda: mag(-16000, 16000, 0) if rng.random() < .6 else near_one(0, rng.random() < .5)),
        'lognp1': (mpmath.log1p, lambda: mag(-80, 60, 0) if rng.random() < .5 else mag(-80, -1, 1)),
        'atanh': (mpmath.atanh, lambda: mag(-80, -1) if rng.random() < .7 else near_one(rng.getrandbits(1))),
    }
    for name, (ref, gen) in dom.items():
        errs, bad = [], []
        for _ in range(n):
            x = gen()
            got, fpsr, _ = run_op(OPS[name], x)
            want = ref(mpv(x))
            if not got.is_finite or want == 0 or abs(want) > mpmath.mpf(2) ** 16383 \
                    or abs(want) < mpmath.mpf(2) ** -16382:
                continue
            ulp = mpmath.mpf(2) ** (mpmath.floor(mpmath.log(abs(want), 2)) - 63)
            e = float(abs(mpv(got) - want) / ulp)
            errs.append(e)
            if e > 4096 and len(bad) < 3:
                bad.append('%r -> %r: %.0f ulp' % (x, got, e))
            if not (fpsr & F.INEX2) and len(bad) < 3:
                bad.append('%r -> %r: INEX2 clear' % (x, got))
        errs.sort()
        c.check('%-6s within 4096 ulp, INEX2 set (median %.1f, p99 %.1f, worst %.1f)'
                % (name, errs[len(errs) // 2], errs[int(.99 * len(errs))], errs[-1]),
                not bad, len(errs), bad)

    c.section('ranges every rounding mode must keep')
    bad = []
    for _ in range(n):
        x = mag(-10, 6)
        for rnd in range(4):
            for name, lim in (('sin', 1), ('cos', 1), ('tanh', 1)):
                got, _, _ = run_op(OPS[name], x, rnd)
                if abs(mpv(got)) > lim:
                    bad.append('%s(%r) %s = %r' % (name, x, RNDS[rnd], got))
            got, _, _ = run_op(OPS['atan'], x, rnd)
            if abs(mpv(got)) > halfpi:
                bad.append('atan(%r) %s = %r' % (x, RNDS[rnd], got))
    c.check('|sin|, |cos|, |tanh| <= 1 and |atan| <= pi/2 after rounding, every RND',
            not bad, 4 * n, bad[:4])

    c.section('flags and exceptional operands')
    got, fpsr, _ = run_op(OPS['tentox'], ONE)
    c.check('4.3.2\'s example: FTENTOX #1 is computed - INEX2 set (%r)' % (got,),
            bool(fpsr & F.INEX2), exc_str(fpsr))
    got, fpsr, _ = run_op(OPS['sin'], Ext(0, 0, 1 << 40))           # a denormal
    c.check('FSIN of a denormal: the denormal back, UNFL and INEX2',
            got == Ext(0, 0, 1 << 40) and exc_str(fpsr) == 'UNFL,INEX2', '%r %s' % (got, exc_str(fpsr)))
    got, fpsr, o = run_op(OPS['etox'], ext_from_exact(0, 12000, 0), enable=F.OVFL)
    c.check('FETOX(12000): OVFL, +inf, the exceptional operand wrapped (not catastrophic)',
            got == pinf and o.vector == 53 and o.xop.e != 0, '%r %s' % (got, o))
    got, fpsr, o = run_op(OPS['etox'], ext_from_exact(0, 60000, 0), enable=F.OVFL)
    c.check('FETOX(60000): a catastrophic overflow - the exceptional operand\'s exponent $0000 (6-10)',
            o.vector == 53 and o.xop.e == 0, str(o))
    got, fpsr, o = run_op(OPS['etox'], ext_from_exact(1, 11400, 0))
    c.check('FETOX(-11400): a denormal result, UNFL', got.e == 0 and got.m and 'UNFL' in exc_str(fpsr),
            '%r %s' % (got, exc_str(fpsr)))
    got, fpsr, _ = run_op(OPS['sin'], ext_from_exact(0, 3, 0), prec=1)
    c.check('single PREC: FSIN(3) rounded to 24 bits', got.m & ((1 << 40) - 1) == 0,
            repr(got))

    c.section('FSINCOS (4-104)')
    f = FPU()
    f.fp[1] = two
    f.general((1 << 10) | (4 << 7) | 0x30 | 5)          # FSINCOS FP1,FP5:FP4
    sref, cref = mpmath.sin(2), mpmath.cos(2)
    ok = abs(mpv(f.fp[4]) - sref) < mpmath.mpf(2) ** -58 and abs(mpv(f.fp[5]) - cref) < mpmath.mpf(2) ** -58
    c.check('FPs = RY gets the sine, FPc = bits 2-0 the cosine; FPCC from the sine (+)',
            ok and (f.fpsr >> 24) & 0xF == 0, '%r %r' % (f.fp[4], f.fp[5]))
    f.general((1 << 10) | (4 << 7) | 0x30 | 4)          # FPs = FPc = FP4
    c.check('FPs = FPc: the register keeps the sine', abs(mpv(f.fp[4]) - sref) < mpmath.mpf(2) ** -58,
            repr(f.fp[4]))
    f = FPU()
    f.fp[1] = pinf
    f.general((1 << 10) | (4 << 7) | 0x30 | 5)
    c.check('FSINCOS of infinity: NaN in both, OPERR', f.fp[4].is_nan and f.fp[5].is_nan
            and exc_str(f.fpsr) == 'OPERR', exc_str(f.fpsr))

    c.section('the documented loss (UM 4-102): large arguments lose accuracy in the reduction, '
              'all of it above about 10^20')
    med = {}
    for E in (4, 14, 20, 40, 60, 66, 70):
        errs = []
        for _ in range(40):
            x = Ext(0, BIAS + E, J_BIT | rng.getrandbits(63))
            got, _, _ = run_op(OPS['sin'], x)
            errs.append(float(abs(mpv(got) - mpmath.sin(mpv(x)))))
        errs.sort()
        med[E] = errs[20]
        c.check('reported: FSIN near 2^%d, median absolute error %.2e' % (E, errs[20]), True, 40)
    # The manual's behaviour, replicated (the fidelity rule): accurate at
    # moderate sizes, the accuracy gone past 10^20 = 2^66.4.
    c.check('FSIN keeps its accuracy near 2^14 (median error below 1e-15)', med[14] < 1e-15,
            '%.2e' % med[14])
    c.check('FSIN has lost all accuracy near 2^70 (median error above 0.1)', med[70] > 0.1,
            '%.2e' % med[70])
    errs = []
    for _ in range(40):
        d = mpmath.mpf(2) ** -rng.randint(10, 40)
        man, e = mpmath.frexp(mpmath.pi + d)
        x = Ext(0, BIAS + e - 1, int(man * 2 ** 64))
        got, _, _ = run_op(OPS['sin'], x)
        ref = mpmath.sin(mpv(x))
        errs.append(float(abs(mpv(got) - ref) / (mpmath.mpf(2) ** (mpmath.floor(mpmath.log(abs(ref), 2)) - 63))))
    errs.sort()
    c.check('FSIN just above pi (the result small): median %.0f ulp - the 67-bit pi\'s error as '
            'an absolute error (item 26)' % errs[20], True, 40)


if __name__ == '__main__':
    c = Checks()
    run(c, n=int(sys.argv[1]) if len(sys.argv) > 1 else 300)
    sys.exit(c.summary())
