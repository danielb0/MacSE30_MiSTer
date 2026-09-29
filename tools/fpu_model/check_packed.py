"""Packed decimal (plan 8.7 work 5b) against the manual: the k-factor
examples of 4-69, Table 3-4's special forms, the accuracy bound of 4.3.3
(0.97 of a unit in the last digit in RN, 1.47 in the other modes, for
values in double's range) measured with exact rationals, exact powers of
ten, and the flags (INEX1 in, INEX2 and OPERR out).  Reported, not
checked: FPSP's second-pass carry, the round trip of doubles, and where
item 23's two table sets differ.
"""

import random
import sys
from fractions import Fraction

from harness import Checks
from xreal import Ext, BIAS, EMAX, ext_from_exact, zero, inf, NAN, Q_BIT, J_BIT
import fpu as F
from fpu import FPU
import packed
from switches import Switches

RNDS = ('RN', 'RZ', 'RM', 'RP')


def pk(sm, se, exp, digits, exp3=0):
    """A packed image from a sign, an exponent (0-999) and up to 17
    digits (a list, or a string of decimal digits)."""
    if isinstance(digits, str):
        digits = [int(c) for c in digits]
    digits = list(digits) + [0] * (17 - len(digits))
    v = (sm << 95) | (se << 94)
    e = [int(c) for c in '%03d' % exp] if isinstance(exp, int) else exp
    v |= (e[0] << 88) | (e[1] << 84) | (e[2] << 80) | (exp3 << 76)
    v |= digits[0] << 64
    for i, d in enumerate(digits[1:]):
        v |= d << (60 - 4 * i)
    return v


def value_of_packed(v):
    """The exact value a packed string denotes (decimal digits)."""
    f = packed.unpack_fields(v)
    M = 0
    for d in [f['M16']] + f['FRAC']:
        M = M * 10 + d
    e = 0
    for d in [f['EXP3']] + f['EXP']:
        e = e * 10 + d
    if f['SE']:
        e = -e
    val = Fraction(M) * Fraction(10) ** (e - 16)
    return -val if f['SM'] else val


def fr(x: Ext):
    s, m, e = x.exact()
    v = Fraction(m) * Fraction(2) ** e
    return -v if s else v


def fmove_in(f, v, reg=0):
    return f.general(0x4000 | (F.FMT_P << 10) | (reg << 7), v)


def fmove_out(f, reg, k):
    return f.general(0x6000 | (F.FMT_P << 10) | (reg << 7) | (k & 0x7F))


def text(v):
    fl = packed.unpack_fields(v)
    ds = [fl['M16']] + fl['FRAC']
    return '%s%d.%sE%s%s' % ('-' if fl['SM'] else '+', ds[0],
                             ''.join(map(str, ds[1:])).rstrip('0'),
                             '-' if fl['SE'] else '+', ''.join(map(str, fl['EXP'])))


def run(c: Checks, n=300, seed=5):
    rng = random.Random(seed)

    c.section('4-69: the k-factor examples, +12345.678765')
    want = {-5: '+1.234567877E+004', -3: '+1.2345679E+004', -1: '+1.23457E+004',
            0: '+1.2346E+004', 1: '+1.E+004', 3: '+1.23E+004', 5: '+1.2346E+004'}
    f = FPU()
    fmove_in(f, pk(0, 0, 4, '12345678765'))
    bad = []
    for k, w in want.items():
        o = fmove_out(f, 0, k)
        if text(o.store) != w:
            bad.append('k=%d: %s, want %s' % (k, text(o.store), w))
    c.check('all seven, digit for digit (RN)', not bad, len(want), bad)
    # The same through a dynamic k-factor (4-69: "independent of the source").
    bad = []
    for k, w in want.items():
        o = f.general(0x6000 | (F.FMT_PK << 10) | (0 << 7) | (3 << 4), dreg=k & 0xFFFFFFFF)
        if text(o.store) != w:
            bad.append('k=%d: %s' % (k, text(o.store)))
    c.check('the same with a dynamic k-factor from Dn (the upper 25 bits ignored)',
            not bad, len(want), bad)

    c.section('Table 3-4: the special forms in')
    f = FPU()
    fmove_in(f, (1 << 95) | (0x7FFF << 80))
    c.check('SE = YY = 1, exponent $FFF, fraction 0: -infinity; FPCC N I',
            f.fp[0] == Ext(1, EMAX, 0) and (f.fpsr >> 24) & 0xF == 0b1010, repr(f.fp[0]))
    nanfrac = (J_BIT | Q_BIT | 0x0123456789ABCDEF) & ((1 << 64) - 1)
    f = FPU()
    fmove_in(f, (0x7FFF << 80) | nanfrac)
    c.check('a nonzero fraction: a NaN, the fraction bit for bit into the mantissa; '
            'bit 62 set, so no SNAN',
            f.fp[0] == Ext(0, EMAX, nanfrac) and not (f.fpsr & F.SNAN), repr(f.fp[0]))
    f = FPU()
    fmove_in(f, (0x7FFF << 80) | (0x0123456789ABCDEF & ~Q_BIT))
    c.check('bit 62 clear: a signaling NaN - SNAN, stored nonsignaling',
            (f.fpsr & F.SNAN) and f.fp[0].m & Q_BIT, '%08X %r' % (f.fpsr, f.fp[0]))
    f = FPU()
    fmove_in(f, pk(1, 1, [0xA, 0xB, 0xC], '0'))
    c.check('a zero with non-decimal exponent digits: a true -0 (note 2)',
            f.fp[0] == zero(1) and not (f.fpsr & 0xFF00), repr(f.fp[0]))
    f1, f2 = FPU(), FPU()
    fmove_in(f1, pk(0, 0, 0, [1, 0xA, 3]))
    fmove_in(f2, pk(0, 0, 0, [2, 0, 3]))
    c.check('non-decimal digits in range: converted "in the same manner" - 1.A3 = 2.03',
            f1.fp[0] == f2.fp[0], '%r %r' % (f1.fp[0], f2.fp[0]))
    f = FPU()
    f.fpcr = 1 << 6                                  # PREC single
    o = fmove_in(f, pk(0, 0, 0, '12345678901234567'))
    c.check('FMOVE.P in single PREC: to extended first (INEX1), then to single (INEX2)',
            (f.fpsr & F.INEX1) and (f.fpsr & F.INEX2) and f.fp[0].m & ((1 << 40) - 1) == 0,
            '%08X %r' % (f.fpsr, f.fp[0]))
    f = FPU()
    f.fp[1] = ext_from_exact(0, 1, 0)
    f.general(0x4000 | (F.FMT_P << 10) | (1 << 7) | 0x22, pk(0, 0, 0, '25'))  # FADD.P #2.5,FP1
    c.check('a packed source to an arithmetic instruction: FADD.P #2.5,FP1 = 3.5',
            fr(f.fp[1]) == Fraction(7, 2) and not (f.fpsr & F.INEX1), repr(f.fp[1]))

    c.section("4.3.3: accuracy in - decimal to double (PREC double), every RND")
    # The manual's bound is IEEE 754's for conversions to double: 0.97 of
    # a unit in the last place of the destination in RN, 1.47 otherwise.
    # The chip's route: FMOVE.P to extended (INEX1), then PREC double.
    for rnd in range(4):
        bound = Fraction(97, 100) if rnd == 0 else Fraction(147, 100)
        worst, worst_x, bad, count, inex_bad, wrong_side = (Fraction(0), Fraction(0), [],
                                                            0, [], 0)
        side_bad = []
        for _ in range(n):
            nd = rng.randint(1, 17)
            digits = [rng.randint(1, 9)] + [rng.randint(0, 9) for _ in range(nd - 1)]
            e = rng.randint(0, 300)
            v = pk(rng.getrandbits(1), rng.getrandbits(1), e, digits)
            exact = value_of_packed(v)
            f = FPU()
            f.fpcr = (2 << 6) | (rnd << 4)
            fmove_in(f, v)
            got = f.fp[0]
            s_, m, ee = got.exact()
            E = m.bit_length() - 1 + ee
            err = abs(fr(got) - exact) / Fraction(2) ** (E - 52)
            worst = max(worst, err)
            # The extended intermediate, reported: FMOVE.P in extended.
            g = FPU()
            g.fpcr = rnd << 4
            fmove_in(g, v)
            s2, m2, e2 = g.fp[0].exact()
            worst_x = max(worst_x, abs(fr(g.fp[0]) - exact) / Fraction(2) ** e2)
            if bool(g.fpsr & F.INEX1) != (fr(g.fp[0]) != exact) and len(inex_bad) < 3:
                inex_bad.append('%s -> %r INEX1 %d' % (text(v), g.fp[0], bool(g.fpsr & F.INEX1)))
            if rnd and fr(got) != exact:
                d = fr(got) - exact
                right = {1: abs(fr(got)) < abs(exact), 2: d < 0, 3: d > 0}[rnd]
                if not right and len(side_bad) < 3:
                    side_bad.append('%s -> %r' % (text(v), got))
            if rnd and fr(g.fp[0]) != exact:
                d = fr(g.fp[0]) - exact
                wrong_side += not {1: abs(fr(g.fp[0])) < abs(exact), 2: d < 0, 3: d > 0}[rnd]
            count += 1
            if err > bound and len(bad) < 3:
                bad.append('%s -> %r: %.3f ulp' % (text(v), got, float(err)))
        c.check('%s: within %s of a unit of double (worst %.3f)' % (RNDS[rnd], float(bound),
                                                                    float(worst)),
                not bad, count, bad)
        c.check('%s: INEX1 exactly when the extended result is not the decimal value'
                % RNDS[rnd], not inex_bad, count, inex_bad)
        if rnd:
            # Reported, not checked: the manual bounds the magnitude only.
            # FPSP's decbin puts about 1 in 20,000 directed conversions to
            # double on the wrong side of the value (plan 8.7.2).
            c.check('%s: reported - doubles on the wrong side of the value: %d%s'
                    % (RNDS[rnd], len(side_bad), (' e.g. ' + side_bad[0]) if side_bad else ''),
                    True, count)
        c.check("%s: reported - the extended intermediate's worst error %.3f ulp of extended, "
                'on the wrong side of the value %d times' % (RNDS[rnd], float(worst_x), wrong_side),
                True, count)

    c.section("4.3.3: accuracy out - doubles to decimal, every RND and k")
    carries = 0
    for rnd in range(4):
        bound = Fraction(97, 100) if rnd == 0 else Fraction(147, 100)
        worst, bad, count, flag_bad, worst_x = Fraction(0), [], 0, [], Fraction(0)
        side_bad = []
        for _ in range(n):
            E = rng.randint(-1020, 1020)
            x = Ext(rng.getrandbits(1), BIAS + E, (J_BIT | rng.getrandbits(63)))
            xd = Ext(x.s, x.e, x.m & ~((1 << 11) - 1))          # a double
            k = rng.choice([17, 17, rng.randint(1, 17), rng.randint(-20, 0)])
            for src, is_double in ((xd, True), (x, False)):
                f = FPU()
                f.fpcr = rnd << 4
                f.fp[2] = src
                tr = packed.BindecTrace()
                bits, inex2, operr = packed.bindec(src, k, rnd, packed.PTEN_ROM, tr)
                carries += tr.second_pass_carry
                o = fmove_out(f, 2, k)
                assert o.store == bits
                d = value_of_packed(o.store)
                fl = packed.unpack_fields(o.store)
                e10 = int(''.join(map(str, fl['EXP'])))
                e10 = -e10 if fl['SE'] else e10
                # The last digit written: LEN = k digits (E format), or the
                # digits down to 10^k (F format), at most 17.
                unit = Fraction(10) ** (e10 - (k - 1) if k > 0 else max(k, e10 - 16))
                err = abs(d - fr(src)) / unit
                # IEEE 754 5.6 (the bound's source): a directed conversion
                # errs toward its direction.
                if rnd and d != fr(src):
                    right = {1: abs(d) < abs(fr(src)), 2: d < fr(src), 3: d > fr(src)}[rnd]
                    if not right and len(side_bad) < 3:
                        side_bad.append('%r k=%d -> %s' % (src, k, text(o.store)))
                if is_double:
                    worst = max(worst, err)
                    count += 1
                    if err > bound and len(bad) < 3:
                        bad.append('%r k=%d -> %s: %.3f units' % (src, k, text(o.store), float(err)))
                else:
                    worst_x = max(worst_x, err)
                if bool(f.fpsr & F.INEX2) != (d != fr(src)) or (f.fpsr & F.OPERR):
                    if len(flag_bad) < 3:
                        flag_bad.append('%r k=%d -> %s exc %04X' % (src, k, text(o.store),
                                                                    f.fpsr & 0xFF00))
        c.check('%s: doubles within %s of a unit in the last digit (worst %.3f)'
                % (RNDS[rnd], float(bound), float(worst)), not bad, count, bad)
        c.check('%s: INEX2 exactly when the string is not the value; no OPERR' % RNDS[rnd],
                not flag_bad, 2 * count, flag_bad)
        if rnd:
            c.check('%s: every inexact string on the side of the value its mode names'
                    % RNDS[rnd], not side_bad, 2 * count, side_bad)
        c.check("%s: reported - extended sources (outside the bound's scope) worst %.3f units"
                % (RNDS[rnd], float(worst_x)), True, count)
    c.check("reported: FPSP's second-pass carry (A13, LEN + 1) reached", True,
            '%d of %d conversions' % (carries, 8 * n))

    c.section("denormal sources out (outside the bound's scope; within a unit of the last digit)")
    bad, count, worst = [], 0, Fraction(0)
    for _ in range(n):
        m = rng.getrandbits(rng.randint(1, 63)) or 1
        x = Ext(rng.getrandbits(1), 0, m)
        k = rng.choice([17, rng.randint(1, 17), rng.randint(-64, 0), 0])
        rnd = rng.randint(0, 3)
        f = FPU()
        f.fpcr = rnd << 4
        f.fp[2] = x
        o = fmove_out(f, 2, k)
        d = value_of_packed(o.store)
        fl = packed.unpack_fields(o.store)
        e10 = int(''.join(map(str, fl['EXP'])))
        e10 = -e10 if fl['SE'] else e10
        unit = Fraction(10) ** (e10 - (k - 1) if k > 0 else max(k, e10 - 16))
        err = abs(d - fr(x)) / unit
        worst = max(worst, err)
        count += 1
        if (err > Fraction(147, 100) or bool(f.fpsr & F.INEX2) != (d != fr(x))) and len(bad) < 3:
            bad.append('%r k=%d %s -> %s: %.3f units, exc %04X' % (x, k, RNDS[rnd], text(o.store),
                                                                 float(err), f.fpsr & 0xFF00))
    c.check('every denormal converts (every k and RND), within 1.47 units of its last digit, '
            'INEX2 exact (worst %.3f)' % float(worst), not bad, count, bad)

    c.section('4.3.3: exact powers of ten, in and out')
    bad = []
    for p in range(0, 28):
        for rnd in range(4):
            f = FPU()
            f.fpcr = rnd << 4
            fmove_in(f, pk(0, 0, p, '1'))
            if fr(f.fp[0]) != 10 ** p or (f.fpsr & F.INEX1):
                bad.append('in 1E+%d %s: %r' % (p, RNDS[rnd], f.fp[0]))
            o = fmove_out(f, 0, 17)
            if value_of_packed(o.store) != 10 ** p or (f.fpsr & F.INEX2):
                bad.append('out 10^%d %s: %s' % (p, RNDS[rnd], text(o.store)))
    c.check('10^0 ... 10^27 convert exactly both ways, no INEX1/INEX2, every RND',
            not bad, 28 * 4, bad[:4])

    c.section('6.1.3: OPERR out')
    f = FPU()
    fmove_in(f, pk(0, 0, 4, '12345678765'))
    bad = []
    for k in (18, 40, 63):
        o = fmove_out(f, 0, k)
        if not (f.fpsr & F.OPERR):
            bad.append('k=%d: %08X' % (k, f.fpsr))
        g = FPU()
        g.fp[0] = f.fp[0]
        if fmove_out(g, 0, 17).store != o.store:
            bad.append('k=%d does not give k=17\'s string' % k)
    # 2/3 has more than 17 significant digits: k = 17 rounds the last one.
    g = FPU()
    g.fp[0] = ext_from_exact(0, 2, 0)
    g.fp[1] = ext_from_exact(0, 3, 0)
    g.general((1 << 10) | (0 << 7) | 0x20)
    s17, s18 = fmove_out(g, 0, 17).store, fmove_out(g, 0, 18).store
    if s17 != s18 or text(s17) != '+6.6666666666666667E-001':
        bad.append('2/3: k=17 %s, k=18 %s' % (text(s17), text(s18)))
    c.check('k = +18 ... +63: OPERR, and the string of k = +17 (2/3: +6.6666666666666667E-001)',
            not bad, 4, bad)
    f = FPU()
    fmove_in(f, pk(0, 0, 999, '1'))
    f.fp[1] = ext_from_exact(0, 10 ** 5, 0)
    f.general((1 << 10) | (0 << 7) | 0x23)          # 1E999 x 1E5 = 1E1004
    o = fmove_out(f, 0, 1)
    fl = packed.unpack_fields(o.store)
    c.check('a decimal exponent of 1004: OPERR, 004 in the exponent and 1 in EXP3',
            (f.fpsr & F.OPERR) and fl['EXP'] == [0, 0, 4] and fl['EXP3'] == 1,
            '%s EXP3 %d exc %04X' % (text(o.store), fl['EXP3'], f.fpsr & 0xFF00))
    f = FPU(Switches())
    f.fpcr = F.OPERR
    fmove_in(f, pk(0, 0, 4, '12345678765'))
    o = fmove_out(f, 0, 20)
    c.check('with OPERR enabled: stored, then a mid-instruction exception (vector 52)',
            o.vector == 52 and o.when == 'mid' and o.store is not None, str(o))

    c.section('the special forms out (item 24)')
    f = FPU()
    f.fp[0], f.fp[1], f.fp[2] = zero(1), inf(0), Ext(0, EMAX, J_BIT | 0x1234)   # an SNaN
    o0, o1 = fmove_out(f, 0, 5), fmove_out(f, 1, 5)
    c.check('-0 and +inf: the register image, the integer-digit word clear, no flags',
            o0.store == zero(1).bits96() and o1.store == inf(0).bits96()
            and not (f.fpsr & 0xFF00), '%X %X' % (o0.store, o1.store))
    o2 = fmove_out(f, 2, 5)
    c.check("'manual': an SNaN sets SNAN and is stored nonsignaling",
            (f.fpsr & F.SNAN) and (o2.store & Q_BIT), '%X %08X' % (o2.store, f.fpsr))
    g = FPU(Switches(packed_out_special='fpsp'))
    g.fp[2] = f.fp[2]
    o3 = fmove_out(g, 2, 30)
    c.check("'fpsp': the image as it is, no status, no OPERR for k = 30",
            o3.store == f.fp[2].bits96() and not (g.fpsr & 0xFF00), '%X %08X' % (o3.store, g.fpsr))

    c.section('item 23: the ROM\'s powers of ten against FPSP\'s tables (reported)')
    diffs = 0
    tried = 0
    for _ in range(n):
        # 10^2048 is used only for decimal exponents of 2048 and more:
        # binary exponents beyond +-6804 (extended values outside double's
        # range, where the manual's bound does not apply).
        E = rng.choice([rng.randint(-16382, -6804), rng.randint(6804, 16383)])
        x = Ext(0, BIAS + E, J_BIT | rng.getrandbits(63))
        for rnd in (1, 2, 3):
            a = packed.bindec(x, 17, rnd, packed.PTEN_ROM)
            b = packed.bindec(x, 17, rnd, packed.PTEN_FPSP)
            tried += 1
            diffs += a != b
    c.check('outputs of magnitude 10^+-(2048 ... 4932), RZ/RM/RP: results that differ',
            True, '%d of %d' % (diffs, tried))


if __name__ == '__main__':
    c = Checks()
    run(c, n=int(sys.argv[1]) if len(sys.argv) > 1 else 300)
    sys.exit(c.summary())
