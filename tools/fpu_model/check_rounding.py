"""The model's rounding against mpmath (plan 8.7, the checks).

For add, subtract, multiply, divide, square root, FMOVE in (PREC), FINT,
FINTRZ and the S/D/X/L/W/B stores, in every PREC and RND, the model's
register image and its UNFL/OVFL/INEX2 are compared with a reference built
here from mpmath's own correctly rounded operations (mpmath.libmp, an
independent implementation of rounding).  Only the manual's rules are
restated here, from plan 8.6.4 - tininess before rounding at the format's
minimum exponent, the result denormalized to that exponent, overflow after
rounding with 6.1.4's default results - not the model's code.
"""

import random
import sys

from mpmath import libmp
from mpmath.libmp import (from_man_exp, mpf_add, mpf_mul, mpf_div, mpf_sqrt,
                          fzero, round_nearest, round_down, round_floor,
                          round_ceiling)

from harness import Checks
from xreal import Ext, EMAX, BIAS, SCALE
import fpu as F
from fpu import FPU

MODES = [round_nearest, round_down, round_floor, round_ceiling]   # RN RZ RM RP
FMTS = {0: (64, -16383, 16383), 1: (24, -126, 127), 2: (53, -1022, 1023)}


def to_mpf(x: Ext):
    s, m, e = x.exact()
    return from_man_exp(-m if s else m, e)


def exponent(v):
    """E of a nonzero mpf value written as 1.f x 2^E."""
    sign, man, exp, bc = v
    return exp + bc - 1


def ref_round(v, p, emin, emax, mode):
    """The manual's post-processing of the exact value v to a format of p
    bits and exponent range [emin, emax].  v is an mpf, or an _Exactish
    for a result mpmath must round itself (a quotient, a root).

    Returns (('zero'|'fin'|'inf', sign, (man, exp))), unfl, ovfl, inex.
    """
    if isinstance(v, _Exactish):
        approx = v(0, None)                 # 400 bits, truncated
        rnd_at = v
        is_exact = v.is_exact
    else:
        approx = v
        rnd_at = lambda prec, rnd: libmp.normalize(v[0], v[1], v[2], v[3], prec, rnd)
        is_exact = lambda r: libmp.mpf_cmp(r, v) == 0
    sign = approx[0]
    E = exponent(approx)
    if E < emin:
        # Tiny: denormalized, the LSB at 2^(emin - p + 1).
        lsb = emin - p + 1
        prec = E - lsb + 1
        if prec <= 0:
            # Below one LSB: mpmath cannot round at zero precision, so the
            # manual's cases are spelled out (a tie, exactly half an LSB,
            # goes to the even neighbour, zero).
            c = libmp.mpf_cmp(libmp.mpf_abs(approx), from_man_exp(1, lsb - 1))
            if c == 0 and isinstance(v, _Exactish) and not v.is_exact(approx):
                c = 1
            up = {round_nearest: c > 0, round_down: False,
                  round_floor: bool(sign), round_ceiling: not sign}[mode]
            if up:
                return ('fin', sign, (1, lsb)), True, False, True
            return ('zero', sign, None), True, False, True
        r = rnd_at(prec, mode)
        inex = not is_exact(r)
        if r == fzero or r[1] == 0:
            return ('zero', sign, None), True, False, inex
        return ('fin', sign, (r[1], r[2])), True, False, inex
    r = rnd_at(p, mode)
    inex = not is_exact(r)
    if exponent(r) > emax:
        to_inf = (mode == round_nearest or (mode == round_floor and sign)
                  or (mode == round_ceiling and not sign))
        if to_inf:
            return ('inf', sign, None), False, True, inex
        return ('fin', sign, ((1 << p) - 1, emax - p + 1)), False, True, inex
    return ('fin', sign, (r[1], r[2])), False, False, inex


def value_eq(x: Ext, ref):
    kind, sign, mv = ref
    if kind == 'inf':
        return x.is_inf and x.s == sign
    if kind == 'zero':
        return x.is_zero and x.s == sign
    if not x.is_finite or x.is_zero or x.s != sign:
        return False
    s, m, e = x.exact()
    return libmp.mpf_cmp(from_man_exp(m, e), from_man_exp(*mv)) == 0


def canonical(x: Ext):
    """The chip never produces an unnormalized result: normalized wherever
    the exponent allows (exponent 0 with the integer bit set included)."""
    if not x.is_finite or x.is_zero:
        return True
    if x.e == 0:
        return True                 # denormal or pseudo-denormal, both chip forms
    return bool(x.m >> 63)


def rand_ext(rng, erange, special=0.0):
    s = rng.getrandbits(1)
    e = rng.randint(*erange)
    kind = rng.random()
    if kind < 0.25:
        m = (1 << 63) | rng.getrandbits(63)
    elif kind < 0.40:
        # Few bits set: exact results, ties, carries.
        m = (1 << 63) | (rng.getrandbits(8) << rng.randint(0, 55))
    elif kind < 0.50:
        m = (1 << 64) - 1 - (rng.getrandbits(4) << rng.randint(0, 40))
    elif kind < 0.60:
        m = (1 << 63) | ((1 << rng.randint(0, 63)) - 1)
    else:
        m = (1 << 63) | rng.getrandbits(63)
    if e == 0 and rng.random() < 0.5:
        m &= (1 << 63) - 1          # a denormal
        m = m or 1
    return Ext(s, e, m)


def exp_ranges():
    # Around the three formats' extremes and the middle, as biased extended
    # exponents.
    r = [(BIAS - 70, BIAS + 70)]
    for E in (-126, 127, -1022, 1023):
        r.append((BIAS + E - 70, BIAS + E + 70))
    r += [(0, 140), (0x7FFE - 140, 0x7FFE)]
    return r


def run(checks: Checks, n_per=60, seed=1):
    rng = random.Random(seed)
    ranges = exp_ranges()
    ops = [
        (0x22, 'FADD', lambda a, b: mpf_add(a, b, 0)),
        (0x28, 'FSUB', lambda a, b: mpf_add(a, libmp.mpf_neg(b), 0)),
        (0x23, 'FMUL', lambda a, b: mpf_mul(a, b, 0)),
        (0x20, 'FDIV', None),
    ]
    for prec in (0, 1, 2):
        p, emin, emax = FMTS[prec]
        for rnd in range(4):
            mode = MODES[rnd]
            tag = 'PREC %s RND %s' % ('XSD'[prec], ('RN', 'RZ', 'RM', 'RP')[rnd])
            for opm, name, exact_fn in ops:
                bad, count = [], 0
                for rg in ranges:
                    for _ in range(n_per):
                        a = rand_ext(rng, rg)
                        b = rand_ext(rng, ranges[rng.randrange(len(ranges))]
                                     if name in ('FMUL', 'FDIV') else rg)
                        if name == 'FDIV':
                            A, B = to_mpf(a), to_mpf(b)
                            if A == fzero or B == fzero:
                                continue            # the special-case tables'
                            ref_v = _div_ref(A, B)
                        else:
                            ref_v = exact_fn(to_mpf(a), to_mpf(b))
                            if ref_v == fzero:
                                continue            # exact zeros: the sign table's
                        f = FPU()
                        f.fpcr = (prec << 6) | (rnd << 4)
                        f.fp[1] = a
                        f.fp[2] = b
                        f.general((2 << 10) | (1 << 7) | opm)
                        got = f.fp[1]
                        exc = f.fpsr & 0xFF00
                        ref, unfl, ovfl, inex = ref_round(ref_v, p, emin, emax, mode)
                        ok = (value_eq(got, ref) and canonical(got)
                              and bool(exc & F.UNFL) == unfl
                              and bool(exc & F.OVFL) == ovfl
                              and bool(exc & F.INEX2) == inex)
                        count += 1
                        if not ok and len(bad) < 3:
                            bad.append('%r %s %r -> %r exc %04X; ref %s u%d o%d i%d'
                                       % (a, name, b, got, exc, ref, unfl, ovfl, inex))
                checks.check('%s, %s: every result and UNFL/OVFL/INEX2 as mpmath'
                             % (name, tag), not bad, count, bad)
            # FSQRT, FMOVE (PREC), FINT, FINTRZ: monadic.
            for opm, name in ((0x04, 'FSQRT'), (0x00, 'FMOVE FPm'),
                              (0x01, 'FINT'), (0x03, 'FINTRZ')):
                bad, count = [], 0
                for rg in ranges:
                    for _ in range(n_per):
                        a = rand_ext(rng, rg)
                        if name == 'FSQRT':
                            a = Ext(0, a.e, a.m)
                        A = to_mpf(a)
                        if A == fzero:
                            continue
                        if name == 'FSQRT':
                            ref_v = _sqrt_ref(A)
                        elif name == 'FMOVE FPm':
                            ref_v = A
                        else:
                            ref_v = _int_ref(A, rnd if name == 'FINT' else 1)
                            if ref_v is None:
                                ref_v = 'zero'
                        f = FPU()
                        f.fpcr = (prec << 6) | (rnd << 4)
                        f.fp[1] = a
                        f.general((1 << 10) | (1 << 7) | opm)
                        got = f.fp[1]
                        exc = f.fpsr & 0xFF00
                        if ref_v == 'zero':
                            # Rounded to zero as an integer: the signed zero.
                            ok = got.is_zero and got.s == a.s and bool(exc & F.INEX2)
                            refd = 'zero'
                        else:
                            if name in ('FINT', 'FINTRZ'):
                                ref_v, int_inex = ref_v
                            ref, unfl, ovfl, inex = ref_round(ref_v, p, emin, emax, mode)
                            if name in ('FINT', 'FINTRZ'):
                                inex = inex or int_inex
                            ok = (value_eq(got, ref) and canonical(got)
                                  and bool(exc & F.UNFL) == unfl
                                  and bool(exc & F.OVFL) == ovfl
                                  and bool(exc & F.INEX2) == inex)
                            refd = (ref, unfl, ovfl, inex)
                        count += 1
                        if not ok and len(bad) < 3:
                            bad.append('%s %r -> %r exc %04X; ref %s' % (name, a, got, exc, refd))
                checks.check('%s, %s: every result and UNFL/OVFL/INEX2 as mpmath'
                             % (name, tag), not bad, count, bad)
    run_stores(checks, rng, n_per)
    run_boundaries(checks)
    run_modrem_scale_sgl(checks, rng, n_per)


def _frac(x: Ext):
    from fractions import Fraction
    s, m, e = x.exact()
    v = Fraction(m) * (Fraction(2) ** e)
    return -v if s else v


def _mpf_of_fraction(v):
    # A dyadic rational as an exact mpf.
    num, den = v.numerator, v.denominator
    k = den.bit_length() - 1
    assert den == 1 << k
    return from_man_exp(num, -k)


def run_modrem_scale_sgl(checks: Checks, rng, n_per):
    """FMOD, FREM (value and quotient byte), FSCALE, FSGLMUL and FSGLDIV,
    against exact rational arithmetic and mpmath's rounding."""
    from fractions import Fraction
    import math
    near = [(BIAS - 40, BIAS + 40)]
    for prec in (0, 1, 2):
        p, emin, emax = FMTS[prec]
        for rnd in range(4):
            mode = MODES[rnd]
            tag = 'PREC %s RND %s' % ('XSD'[prec], ('RN', 'RZ', 'RM', 'RP')[rnd])
            for opm, name in ((0x21, 'FMOD'), (0x25, 'FREM')):
                bad, count = [], 0
                for _ in range(n_per * 4):
                    a = rand_ext(rng, near[0])
                    b = rand_ext(rng, (a.e - rng.randint(0, 70), a.e + 2))
                    A, B = _frac(a), _frac(b)
                    if A == 0 or B == 0:
                        continue
                    t = A / B
                    N = math.trunc(t)
                    if name == 'FREM':
                        fl = math.floor(t)
                        d = t - fl
                        N = fl + (1 if d > Fraction(1, 2) or (d == Fraction(1, 2) and fl % 2) else 0)
                    r = A - N * B
                    f = FPU()
                    f.fpcr = (prec << 6) | (rnd << 4)
                    f.fp[1], f.fp[2] = a, b
                    f.general((2 << 10) | (1 << 7) | opm)
                    got, exc = f.fp[1], f.fpsr & 0xFF00
                    qs, qb = (f.fpsr >> 23) & 1, (f.fpsr >> 16) & 0x7F
                    if r == 0:
                        ok = got.is_zero and got.s == a.s and not (exc & 0xFF00)
                        refd = 'zero'
                    else:
                        ref, unfl, ovfl, inex = ref_round(_mpf_of_fraction(r), p, emin, emax, mode)
                        ok = (value_eq(got, ref) and bool(exc & F.UNFL) == unfl
                              and bool(exc & F.OVFL) == ovfl and bool(exc & F.INEX2) == inex)
                        refd = ref
                    ok = ok and qs == (a.s ^ b.s) and qb == (abs(N) & 0x7F)
                    count += 1
                    if not ok and len(bad) < 3:
                        bad.append('%r %s %r -> %r exc %04X q %d/%d; ref %s N %d'
                                   % (a, name, b, got, exc, qs, qb, refd, N))
                checks.check('%s, %s: the remainder, its flags and the quotient byte, exactly'
                             % (name, tag), not bad, count, bad)
            # FSCALE: FPn x 2^trunc(src), |src| < 2^14.
            bad, count = [], 0
            for _ in range(n_per * 4):
                a = rand_ext(rng, exp_ranges()[rng.randrange(len(exp_ranges()))])
                sv = Fraction(rng.randint(-20000, 20000), rng.choice([1, 2, 3, 7]))
                n = math.trunc(sv)
                if abs(sv) >= 1 << 14 or _frac(a) == 0:
                    continue
                num, den = sv.numerator, sv.denominator
                f = FPU()
                f.fpcr = (prec << 6) | (rnd << 4)
                f.fp[1] = a
                # the source as an extended: num/den via FDIV would round; use
                # an exact binary value instead where den is a power of two.
                if den not in (1, 2):
                    continue
                from xreal import ext_from_exact
                f.fp[2] = ext_from_exact(1 if num < 0 else 0, abs(num), -(den.bit_length() - 1))
                f.general((2 << 10) | (1 << 7) | 0x26)
                got, exc = f.fp[1], f.fpsr & 0xFF00
                ref, unfl, ovfl, inex = ref_round(_mpf_of_fraction(_frac(a) * Fraction(2) ** n),
                                                  p, emin, emax, mode)
                ok = (value_eq(got, ref) and bool(exc & F.UNFL) == unfl
                      and bool(exc & F.OVFL) == ovfl and bool(exc & F.INEX2) == inex)
                count += 1
                if not ok and len(bad) < 3:
                    bad.append('%r scale %s -> %r exc %04X; ref %s' % (a, sv, got, exc, ref))
            checks.check('FSCALE, %s: FPn x 2^trunc(src), every result and flag' % tag,
                         not bad, count, bad)
            # FSGLMUL/FSGLDIV: inputs truncated to 24 bits (8.6.14 item 9's
            # default), the mantissa rounded to single, extended's range.
            for opm, name in ((0x27, 'FSGLMUL'), (0x24, 'FSGLDIV')):
                bad, count = [], 0
                for rg in exp_ranges():
                    for _ in range(n_per):
                        a = rand_ext(rng, rg)
                        b = rand_ext(rng, exp_ranges()[rng.randrange(len(exp_ranges()))])
                        A, B = to_mpf(a), to_mpf(b)
                        if A == fzero or B == fzero:
                            continue
                        At = libmp.normalize(A[0], A[1], A[2], A[3], 24, round_down)
                        Bt = libmp.normalize(B[0], B[1], B[2], B[3], 24, round_down)
                        ref_v = mpf_mul(At, Bt, 0) if name == 'FSGLMUL' else _div_ref(At, Bt)
                        f = FPU()
                        f.fpcr = (prec << 6) | (rnd << 4)
                        f.fp[1], f.fp[2] = a, b
                        f.general((2 << 10) | (1 << 7) | opm)
                        got, exc = f.fp[1], f.fpsr & 0xFF00
                        ref, unfl, ovfl, inex = ref_round(ref_v, 24, -16383, 16383, mode)
                        ok = (value_eq(got, ref) and bool(exc & F.UNFL) == unfl
                              and bool(exc & F.OVFL) == ovfl and bool(exc & F.INEX2) == inex)
                        count += 1
                        if not ok and len(bad) < 3:
                            bad.append('%r %s %r -> %r exc %04X; ref %s' % (a, name, b, got, exc, ref))
                checks.check('%s, %s: PREC ignored, the mantissa single, the range extended'
                             % (name, tag), not bad, count, bad)


def run_boundaries(checks: Checks):
    """Cases random operands do not reach."""
    # A tie with a sticky tail: 1.0 / (2^p - 1) = 1.000...0 1 000...0 1 ...
    # in binary - the guard bit set, the round bits clear down to bit 2p,
    # then a one.  RN must round up (the tail breaks the tie); an even LSB
    # would otherwise keep it down.
    bad, count = [], 0
    for prec in (0, 1, 2):
        p, emin, emax = FMTS[prec]
        for rnd in range(4):
            f = FPU()
            f.fpcr = (prec << 6) | (rnd << 4)
            f.fp[1] = Ext(0, BIAS + p - 1, ((1 << p) - 1) << (64 - p))
            f.fp[2] = Ext(0, BIAS, 1 << 63)
            f.general((1 << 10) | (2 << 7) | 0x20)
            ref, unfl, ovfl, inex = ref_round(_div_ref(from_man_exp(1, 0),
                                                       from_man_exp((1 << p) - 1, 0)),
                                              p, emin, emax, MODES[rnd])
            got = f.fp[2]
            count += 1
            if not (value_eq(got, ref) and bool(f.fpsr & F.INEX2) == inex):
                bad.append('PREC %d RND %d: %r, ref %s' % (prec, rnd, got, ref))
    checks.check('FDIV 1/(2^p - 1): a sticky tail breaks an RN tie, every PREC and RND',
                 not bad, count, bad)
    # The integer stores at the edges of their ranges.
    bad, count = [], 0
    for code, name, bits in ((F.FMT_L, 'L', 32), (F.FMT_W, 'W', 16), (F.FMT_B, 'B', 8)):
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
        for num2 in (2 * hi, 2 * hi + 1, 2 * hi + 2, 2 * lo, 2 * lo - 1, 2 * lo - 2,
                     2 * hi - 1, 2 * lo + 1):          # value = num2 / 2
            for rnd in range(4):
                f = FPU()
                f.fpcr = rnd << 4
                f.fp[3] = from_man_exp_ext(num2, -1)
                o = f.general(0x6000 | (code << 10) | (3 << 7))
                A = from_man_exp(num2, -1)
                ir = _int_ref(A, rnd)
                v, inex = (0, True) if ir is None else (libmp.to_int(ir[0]), ir[1])
                operr = not (lo <= v <= hi)
                if operr:
                    v = lo if num2 < 0 else hi
                exc = f.fpsr & 0xFF00
                count += 1
                if not (o.store == v & ((1 << bits) - 1) and bool(exc & F.OPERR) == operr
                        and bool(exc & F.INEX2) == inex):
                    bad.append('%s %d/2 RND %d -> %X exc %04X; ref %d operr %d'
                               % (name, num2, rnd, o.store, exc, v, operr))
    checks.check('FMOVE.B/W/L at the ends of their ranges and half a unit beyond, every RND',
                 not bad, count, bad)


def from_man_exp_ext(num, e):
    from xreal import ext_from_exact
    return ext_from_exact(1 if num < 0 else 0, abs(num), e)


def _div_ref(A, B):
    def f(prec, rnd):
        if prec == 0:
            # "Exact" for the exponent and sign: a quotient to 400 bits,
            # its exactness tested by multiplying back.
            return mpf_div(A, B, 400, round_down)
        return mpf_div(A, B, prec, rnd)
    return _Exactish(f, lambda r: libmp.mpf_cmp(mpf_mul(r, B, 0), A) == 0)


def _sqrt_ref(A):
    def f(prec, rnd):
        if prec == 0:
            return mpf_sqrt(A, 400, round_down)
        return mpf_sqrt(A, prec, rnd)
    return _Exactish(f, lambda r: libmp.mpf_cmp(mpf_mul(r, r, 0), A) == 0)


class _Exactish:
    """An inexact-by-nature result (a quotient, a root): mpmath rounds it
    itself at each precision; exactness is tested by the inverse."""

    def __init__(self, f, is_exact):
        self.f, self.is_exact = f, is_exact

    def __call__(self, prec, rnd):
        return self.f(prec, rnd)


def _int_ref(A, rnd):
    """An integer rounding with mpmath: (the integer as an mpf, inexact)."""
    mode = MODES[rnd]
    # Round at the precision that puts the LSB at 2^0.
    E = exponent(A)
    if E < -1:
        # |A| < 1/2: RN and RZ give 0; RM/RP by sign.
        if mode in (round_nearest, round_down) or \
                (mode == round_floor and not A[0]) or (mode == round_ceiling and A[0]):
            return None
        return from_man_exp(-1 if A[0] else 1, 0), True
    if E == -1:
        # 1/2 <= |A| < 1
        half = libmp.mpf_cmp(libmp.mpf_abs(A), from_man_exp(1, -1))
        up = {round_nearest: half > 0, round_down: False,
              round_floor: bool(A[0]), round_ceiling: not A[0]}[mode]
        if not up:
            return None
        return from_man_exp(-1 if A[0] else 1, 0), True
    r = libmp.normalize(A[0], A[1], A[2], A[3], E + 1, mode)
    return r, libmp.mpf_cmp(r, A) != 0


def run_stores(checks: Checks, rng, n_per):
    """FMOVE FPm,<ea>.S/.D/.X/.L/.W/.B against mpmath's rounding."""
    ranges = exp_ranges()
    fmts = [(F.FMT_S, 'S', (24, -126, 127)), (F.FMT_D, 'D', (53, -1022, 1023)),
            (F.FMT_X, 'X', (64, -16383, 16383))]
    for rnd in range(4):
        mode = MODES[rnd]
        for code, name, (p, emin, emax) in fmts:
            bad, count = [], 0
            for rg in ranges:
                for _ in range(n_per):
                    a = rand_ext(rng, rg)
                    f = FPU()
                    f.fpcr = rnd << 4
                    f.fp[3] = a
                    o = f.general(0x6000 | (code << 10) | (3 << 7))
                    got = _unpack(o.store, name)
                    exc = f.fpsr & 0xFF00
                    ref, unfl, ovfl, inex = ref_round(to_mpf(a), p, emin, emax, mode)
                    ok = (value_eq(got, ref) and bool(exc & F.UNFL) == unfl
                          and bool(exc & F.OVFL) == ovfl and bool(exc & F.INEX2) == inex)
                    count += 1
                    if not ok and len(bad) < 3:
                        bad.append('%r -> %s %X %r exc %04X; ref %s u%d o%d i%d'
                                   % (a, name, o.store, got, exc, ref, unfl, ovfl, inex))
            checks.check('FMOVE.%s FPm,<ea>, RND %s: every image and UNFL/OVFL/INEX2 as mpmath'
                         % (name, ('RN', 'RZ', 'RM', 'RP')[rnd]), not bad, count, bad)
        for code, name, bits in ((F.FMT_L, 'L', 32), (F.FMT_W, 'W', 16), (F.FMT_B, 'B', 8)):
            bad, count = [], 0
            for _ in range(n_per * 8):
                E = rng.randint(-3, bits + 2)
                a = Ext(rng.getrandbits(1), BIAS + E, (1 << 63) | rng.getrandbits(63))
                if rng.random() < 0.3:
                    a = Ext(a.s, a.e, a.m & ~((1 << (64 - max(E, 0) - 1)) - 1))
                f = FPU()
                f.fpcr = rnd << 4
                f.fp[3] = a
                o = f.general(0x6000 | (code << 10) | (3 << 7))
                exc = f.fpsr & 0xFF00
                A = to_mpf(a)
                ir = _int_ref(A, rnd)
                if ir is None:
                    v, inex = 0, True
                else:
                    r, inex = ir
                    v = libmp.to_int(r)
                lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
                operr = not (lo <= v <= hi)
                if operr:
                    v = lo if a.s else hi
                ok = (o.store == v & ((1 << bits) - 1) and bool(exc & F.OPERR) == operr
                      and bool(exc & F.INEX2) == inex and not (exc & (F.OVFL | F.UNFL)))
                count += 1
                if not ok and len(bad) < 3:
                    bad.append('%r -> %s %X exc %04X; ref %d operr %d inex %d'
                               % (a, name, o.store, exc, v, operr, inex))
            checks.check('FMOVE.%s FPm,<ea>, RND %s: every integer, OPERR out of range, INEX2'
                         % (name, ('RN', 'RZ', 'RM', 'RP')[rnd]), not bad, count, bad)


def _unpack(v, name):
    from xreal import from_single, from_double, ext_bits96
    return {'S': from_single, 'D': from_double, 'X': ext_bits96}[name](v)


if __name__ == '__main__':
    c = Checks()
    run(c, n_per=int(sys.argv[1]) if len(sys.argv) > 1 else 60)
    sys.exit(c.summary())
