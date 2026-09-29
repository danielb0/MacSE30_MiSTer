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
         'harness.py', 'check_rounding.py', 'check_tables.py']

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
]


def main():
    caught = 0
    missed = []
    work = tempfile.mkdtemp(prefix='fpu_mut_')
    try:
        for fn, a, b, desc in MUTANTS:
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
            fails, crashed = 0, False
            for script, args in (('check_rounding.py', ['15']), ('check_tables.py', [])):
                r = subprocess.run([sys.executable, script] + args, cwd=d,
                                   capture_output=True, text=True)
                fails += sum(1 for l in r.stdout.splitlines() if l.startswith('FAIL'))
                if r.returncode != 0 and 'Traceback' in r.stderr:
                    crashed = True
            if fails or crashed:
                caught += 1
                print('caught %-55s %s' % (desc, '%d FAIL lines' % fails if fails else '(a crash)'),
                      flush=True)
            else:
                missed.append(desc)
                print('MISSED %s' % desc, flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print('==== %s: %d of %d mutants caught' % ('PASS' if not missed else 'FAIL',
                                               caught, len(MUTANTS)), flush=True)
    return 1 if missed else 0


if __name__ == '__main__':
    sys.exit(main())
