"""Mutation test of the model's checks: each mutant is a documented fault
put into a copy of the model; the checks must fail on every one.  A mutant
the checks miss is a hole in the checks.  Run by `run.sh mutate`.

A mutant that makes the model crash counts as caught, and is marked so:
the crash is the checks noticing, but not by a failed comparison.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ['xreal.py', 'rounding.py', 'fpu.py', 'constants.py', 'switches.py',
         'packed.py', 'transcend.py', 'harness.py', 'check_rounding.py',
         'check_tables.py', 'check_packed.py', 'check_transcend.py']
CHECK_TIMEOUT = 300
CHECKS = (('check_rounding.py', ['15']), ('check_tables.py', []), ('check_packed.py', ['1000']),
          ('check_transcend.py', ['150']))

MUTANTS = [
    # rounding.py - Figure 6-3 and 6.1.4-6.1.5
    ('rounding.py', "up = rem > half or (rem == half and (sticky or (K & 1)))",
     "up = rem > half or (rem == half and (sticky or not (K & 1)))", 'RN: a tie to odd'),
    ('rounding.py', "up = rem > half or (rem == half and (sticky or (K & 1)))",
     "up = rem >= half", 'RN: a tie away from zero'),
    ('rounding.py', "up = rem > half or (rem == half and (sticky or (K & 1)))",
     "up = rem > half or (rem == half and (K & 1))", 'RN: a sticky tail ignored on a tie'),
    ('rounding.py', "        up = bool(s)\n", "        up = not s\n", 'RM and RP swapped'),
    ('rounding.py', "tiny = E < fmt.emin", "tiny = E <= fmt.emin",
     'tiny at the minimum exponent (against the 6-11 footnote)'),
    ('rounding.py', "if Er > fmt.emax:", "if Er >= fmt.emax:", 'overflow one exponent early'),
    ('rounding.py', "q = fmt.emin - (fmt.p - 1)", "q = fmt.emin - fmt.p",
     'the denormal LSB one bit low'),
    ('rounding.py', "return Rounded('inf', s, 0, 0, False, True, inexact, E, xop)",
     "return Rounded('inf', s, 0, 0, False, True, True, E, xop)", 'INEX2 forced on overflow'),
    ('rounding.py', "to_inf = (rnd == RN or (rnd == RM and s) or (rnd == RP and not s))",
     "to_inf = (rnd == RN)", 'a directed overflow always the largest'),
    ('rounding.py', "            be = 0 if Er > 0xA000 else (Er + BIAS - 0x6000) & 0x7FFF",
     "            be = 0 if Er > 0xA000 else (Er + BIAS + 0x6000) & 0x7FFF",
     'the overflow wrap with the wrong sign'),
    # xreal.py
    ('xreal.py', "        return ext_from_exact(s, f, 1 - bias - fbits)",
     "        return ext_from_exact(s, f, -bias - fbits)", 'S/D denormals in, off by two'),
    # fpu.py - the instructions
    ('fpu.py', "s = d.s if d.s == b.s else (1 if rnd == RM else 0)", "s = d.s",
     'the sign of +0 + -0'),
    ('fpu.py', "            return self._finish_reg(dst, zero(1 if rnd == RM else 0), exc, src)",
     "            return self._finish_reg(dst, zero(0), exc, src)", 'x + -x is +0 in RM'),
    ('fpu.py', "sticky = r * r != M", "sticky = False", 'FSQRT drops the sticky'),
    ('fpu.py', "res, exc, xop = self._round(s, q, e1 - e2 - sh, r != 0, fmt, rnd, exc)",
     "res, exc, xop = self._round(s, q, e1 - e2 - sh, False, fmt, rnd, exc)",
     'FDIV drops the remainder'),
    ('fpu.py', "            return self._finish_reg(dst, inf(s), exc | DZ, src)",
     "            return self._finish_reg(dst, inf(s), exc, src)", 'FDIV by zero without DZ'),
    ('fpu.py', "        if d.is_inf:\n            return self._finish_reg(dst, inf(s), exc, src)\n        if src.is_zero:",
     "        if src.is_zero:", 'inf / 0 raises DZ'),
    ('fpu.py', "        if v < lo or v > hi:", "        if v < lo or v >= hi:",
     'an integer store\'s range off by one'),
    ('fpu.py', "            res = (d if (not monadic and d.is_nan) else src).quiet()",
     "            res = (src if src.is_nan else d).quiet()", 'two NaNs give the source\'s'),
    ('fpu.py', "        blocked = bool(exc & self.fpcr & (SNAN | OPERR | DZ))",
     "        blocked = False", 'an enabled SNAN/OPERR/DZ trap writes the register'),
    ('fpu.py', "        if (exc & UNFL) and (exc & INEX2):", "        if exc & UNFL:",
     'AEXC.UNFL without INEX2'),
    ('fpu.py', "        if exc & (INEX1 | INEX2 | OVFL):", "        if exc & (INEX1 | INEX2):",
     'AEXC.INEX without OVFL'),
    ('fpu.py', "        if ((exc & (OVFL | INEX2)) and (en & INEX2)) or \\",
     "        if ((exc & INEX2) and (en & INEX2)) or \\", 'no inexact trap on an overflow'),
    ('fpu.py', "        for bit, vec in ((BSUN, V_BSUN), (SNAN, V_SNAN), (OPERR, V_OPERR),\n                         (OVFL, V_OVFL),",
     "        for bit, vec in ((BSUN, V_BSUN), (SNAN, V_SNAN), (OPERR, V_OPERR),\n                         (INEX2, V_INEX), (OVFL, V_OVFL),", 'the trap priority wrong'),
    ('fpu.py', "            cc = CC_Z | (CC_N if d.s else 0)", "            cc = CC_Z",
     'FCMP -0 against a zero loses N'),
    ('fpu.py', "        if pred & 0x10 and nan:", "        if nan:", 'BSUN on the IEEE-aware predicates'),
    ('fpu.py', "        regs = [r for r in range(8) if lst & (1 << (r if predec else 7 - r))]",
     "        regs = [r for r in range(8) if lst & (1 << (7 - r))]", 'FMOVEM -(An) list order'),
    ('fpu.py', "FPCR_MASK = 0x0000FFF0", "FPCR_MASK = 0x0000FFFF", 'FPCR bits 3-0 kept'),
    ('fpu.py', "        sel = sel or 0b001", "        sel = sel", 'control list 000 moves nothing'),
    ('fpu.py', "REDUNDANT = {0x05: 0x04,", "REDUNDANT = {0x05: 0x06,", 'redundant $05 is not FSQRT'),
    ('fpu.py', "        if nearest and (2 * r > b or (2 * r == b and (N & 1))):",
     "        if nearest and (2 * r >= b):", 'FREM rounds a tie away'),
    ('fpu.py', "        n = m2 >> -e2 if e2 < 0 else m2 << e2        # chopped toward zero",
     "        n = (m2 + (1 << (-e2 - 1)) >> -e2) if e2 < 0 else m2 << e2",
     'FSCALE rounds the scale instead of chopping'),
    # packed.py and the packed paths of fpu.py - plan 8.7.2
    ('packed.py', "    e -= 16\n", "    e -= 15\n", 'decbin: the mantissa read as 16 digits'),
    ('packed.py', "    if f['SE']:\n        e = -e\n    e -= 16", "    e -= 16", 'decbin: SE ignored'),
    ('packed.py', "    if f['M16'] == 0 and frac64 == 0:",
     "    if f['M16'] == 0 and frac64 == 0 and exp12 == 0:", 'a zero needs a zero exponent'),
    ('packed.py', "        return Ext(f['SM'], EMAX, frac64), False",
     "        return Ext(f['SM'], EMAX, frac64 & ~(1 << 62)), False", "a packed NaN's bit 62 lost"),
    ('packed.py', "    return r, inexact\n", "    return r, True\n", 'decbin: INEX1 always'),
    ('packed.py', "        elif LEN > 17:\n            LEN = 17", "        elif LEN > 17:\n            LEN = 18",
     'bindec: LEN capped at 18'),
    ('packed.py', "            if k > 0:\n                operr = True", "            pass",
     'bindec: no OPERR for k > 17'),
    ('packed.py', "        if inexact:\n            Y = Ext(Y.s, Y.e, Y.m | 1)", "        pass",
     'bindec A10: the lost bits not ORed into Y'),
    ('packed.py', "        frac = ((frac + 0x80) & ~0x7F) & ((1 << 64) - 1)\n    mant_digits",
     "        frac = frac & ~0x7F\n    mant_digits", 'bindec A14: the fraction truncated at bit 7'),
    ('packed.py', "    bits |= (e4[1] << 88) | (e4[2] << 84) | (e4[3] << 80) | (e4[0] << 76)",
     "    bits |= (e4[1] << 88) | (e4[2] << 84) | (e4[3] << 80)", 'bindec: EXP3 not written'),
    ('packed.py', "    pos = [64] + [60 - 4 * i for i in range(16)]",
     "    pos = [60 - 4 * i for i in range(17)]", 'bindec: the first digit not in M16'),
    ('packed.py', "        YINT, ix = xint(Ext(sigma, Y.e, Y.m), rnd)",
     "        YINT, ix = xint(Ext(0, Y.e, Y.m), rnd)", 'bindec A12: FINT of +Y whatever the sign'),
    ('packed.py', "        YINT, ix = xint(Ext(sigma, Y.e, Y.m), rnd)",
     "        YINT, ix = xint(Ext(sigma, Y.e, Y.m), RN)", 'bindec A12: FINT in RN whatever RND'),
    ('packed.py', "RTABLE = [RN, RN, RN, RN, RM, RP, RM, RP,", "RTABLE = [RN, RN, RN, RN, RP, RM, RP, RM,",
     "decbin: RZ's power-of-ten directions reversed", "survive: moves the extended result by "
     "a few units, below the manual's double-precision bound; bit-exactness to FPSP is the "
     "audit's (plan 8.7.2)"),
    ('packed.py', "RBDTBL = [RN, RN, RN, RN, RP, RP, RM, RM,", "RBDTBL = [RN, RN, RN, RN, RM, RM, RP, RP,",
     "bindec: RZ's scale directions reversed"),
    ('packed.py', "            fp0, _ = xmul(fp0, LOG2UP1, RM)", "            fp0, _ = xmul(fp0, LOG2, RM)",
     'bindec A3: LOG2 for negative logs too', 'survive: A13 re-derives ILOG; no output '
     'differed in 20,000 conversions (plan 8.7.2)'),
    ('fpu.py', "            k = kraw - 0x80 if kraw & 0x40 else kraw", "            k = kraw",
     'the k-factor not sign-extended'),
    ('packed.py', "    assert not r.ovfl, 'decimal conversion overflowed extended'",
     "    assert not (r.ovfl or r.unfl)", "bindec refuses a tiny intermediate (the audit's crash)"),
    ('packed.py', "        elif denorm:", "        elif False:", 'bindec: the normal A9 order for denormals',
     "survive: the audit found no input where FPSP's denormal order and the normal one differ "
     "(68,327 cases); kept literal to FPSP (plan 8.7.2)"),
    # transcend.py and the transcendentals in fpu.py - plan 8.7.3
    ('transcend.py', "            X, Y, Z = X - asr(Y, i + s), Y + asr(X, i - s), Z - rom_fixed(_ATAN, i, s)",
     "            X, Y, Z = X - asr(Y, i + s), Y - asr(X, i - s), Z - rom_fixed(_ATAN, i, s)",
     'CORDIC rotation: y turned the wrong way'),
    ('transcend.py', "    X = gain(s)\n", "    X = gain(s + 1)\n", 'CORDIC rotation: the gain for the wrong start'),
    ('transcend.py', "    s = max(0, -exponent(z) - 1)\n    if s >= 34:",
     "    s = 0\n    if s >= 34:", 'CORDIC rotation: no scaling for small z'),
    ('transcend.py', "    elif k == 1:\n        sn, cs = c, s.neg()", "    elif k == 1:\n        sn, cs = c, s",
     'sincos: the second quadrant\'s cosine sign'),
    ('transcend.py', "    e0 = min(x.e, TWOPI.e)\n    r = (x.m << (x.e - e0)) % (TWOPI.m << (TWOPI.e - e0))",
     "    import constants\n    pm, pe, _ = constants.DOCUMENTED[0x00]\n    e0 = min(x.e, pe + 1)\n"
     "    r = (x.m << (x.e - e0)) % (pm << (pe + 1 - e0))",
     'an accurate reduction (a 256-bit 2pi): the documented loss gone'),
    ('transcend.py', "        X, Y, Z = X + asr(Y, i + s), Y - asr(X, i - s), Z + rom_fixed(_ATAN, i, s)\n        elif Y < 0:",
     "        X, Y, Z = X + asr(Y, i + s), Y - asr(X, i - s), Z - rom_fixed(_ATAN, i, s)\n        elif Y < 0:",
     'CORDIC vectoring: the angle accumulated the wrong way'),
    ('transcend.py', "        L = rom_fixed(_LNUP, i)\n        if not L:",
     "        L = rom_fixed(_LNUP, i - 1)\n        if not L:", 'exp: the ln(1 + 2^-i) table off by one'),
    ('transcend.py', "            D = D + step if up else D - step\n    D = D + R if up else D - R",
     "            D = D + step if up else D - step\n    D = D", 'expm1: the residual dropped',
     "survive: the residual is under 2^-66 of the result (about 2 units of extended), below "
     "the manual's bound; bit-exactness to the microcode is the RTL bench's (plan 8.7.3)"),
    ('transcend.py', "                L -= rom_fixed(_LNDN, i, s)        # - ln(1 - 2^-i) > 0",
     "                L += rom_fixed(_LNDN, i, s)        # - ln(1 - 2^-i) > 0", 'log1p: a table term with the wrong sign'),
    ('transcend.py', "    return i_add(i_mul(i_from_int(E), LN2), lm)", "    return i_add(i_mul(i_from_int(E + 1), LN2), lm)",
     'logn: the exponent off by one'),
    ('transcend.py', "    if exponent(r) >= 0 and not r.is_zero():\n        return I67(r.s, ALMOST_ONE.m, ALMOST_ONE.e)\n    return r",
     "    return r", 'sin/cos/tanh not bounded below 1'),
    ('transcend.py', "    d = i_mul(i_sub(ONE_I, a), i_add(ONE_I, a))", "    d = i_sub(ONE_I, i_mul(a, a))",
     'asin: 1 - x^2 computed with cancellation',
     "survive: an extended x has 64 bits, so x^2 truncated to 67 still holds 1 - 2d exactly - "
     "the cancellation cannot occur; the product form is kept as the robust one (plan 8.7.3)"),
    ('fpu.py', "        if not blocked:\n            self.fp[fpc] = cos_r\n            self.fp[fps] = sin_r",
     "        if not blocked:\n            self.fp[fps] = sin_r\n            self.fp[fpc] = cos_r", 'FSINCOS: FPs = FPc keeps the cosine'),
    ('fpu.py', "            return self._finish_reg(dst, Ext(0, BIAS, J_BIT), exc, src)\n        if src.is_inf:\n            return self._finish_reg(dst, NAN, exc | OPERR, src)\n        return self._transcend(dst, src, exc, rnd, fmt, lambda v: transcend.sincos(v)[1])",
     "            return self._finish_reg(dst, src, exc, src)\n        if src.is_inf:\n            return self._finish_reg(dst, NAN, exc | OPERR, src)\n        return self._transcend(dst, src, exc, rnd, fmt, lambda v: transcend.sincos(v)[1])",
     'FCOS(0) is 0'),
    ('fpu.py', "        return self._round(r.s, r.m, r.e, True, fmt, rnd, exc)",
     "        return self._round(r.s, r.m, r.e, False, fmt, rnd, exc)", 'transcendentals without the sticky (INEX2)'),
]


def main():
    caught = 0
    missed = []
    known = []
    work = tempfile.mkdtemp(prefix='fpu_mut_')
    try:
        for mut in MUTANTS:
            fn, a, b, desc = mut[:4]
            expect = mut[4] if len(mut) > 4 else None
            d = os.path.join(work, 'm')
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)
            for f in FILES:
                shutil.copy(os.path.join(HERE, f), d)
            path = os.path.join(d, fn)
            text = open(path, encoding='utf-8').read()
            if a not in text:
                print('STALE  %s (the mutated text is not in %s)' % (desc, fn), flush=True)
                missed.append(desc)
                continue
            open(path, 'w', encoding='utf-8').write(text.replace(a, b, 1))
            fails, crashed, hung = 0, False, False
            for script, args in CHECKS:
                # A check normally takes seconds; a mutant that hangs one (an
                # endless loop) is stopped and counted as caught by a hang.
                try:
                    r = subprocess.run([sys.executable, script] + args, cwd=d,
                                       capture_output=True, text=True, timeout=CHECK_TIMEOUT)
                except subprocess.TimeoutExpired:
                    crashed = True
                    hung = True
                    continue
                fails += sum(1 for l in r.stdout.splitlines() if l.startswith('FAIL'))
                if r.returncode != 0 and 'Traceback' in r.stderr:
                    crashed = True
            if expect:
                what = 'caught' if (fails or crashed) else 'survived'
                print('KNOWN  %-55s %s (%s)' % (desc, what, expect), flush=True)
                known.append(desc)
                continue
            if fails or crashed:
                caught += 1
                print('caught %-55s %s' % (desc, '%d FAIL lines' % fails if fails else
                                            ('(a hang, stopped after %d s)' % CHECK_TIMEOUT if hung
                                             else '(a crash)')),
                      flush=True)
            else:
                missed.append(desc)
                print('MISSED %s' % desc, flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('==== %s: %d of %d mutants caught; %d known survivors, each with its reason'
          % ('PASS' if not missed else 'FAIL', caught, len(MUTANTS) - len(known), len(known)),
          flush=True)
    return 1 if missed else 0


if __name__ == '__main__':
    sys.exit(main())
