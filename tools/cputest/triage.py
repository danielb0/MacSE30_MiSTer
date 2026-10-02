"""Sort check.py's differences (--dump) by cause - plan 8.9.8.

    python triage.py <model_diff.vec> [--show N]

Each differing vector is tested against a list of candidate causes, in
order; the first that explains it (the model, re-run with that one rule
changed, then agrees with WinUAE in every compared field - or the stated
pattern holds) names it.  What no cause explains is listed by instruction.
A cause here is a hypothesis about where WinUAE and our model part, to be
settled from the manual - not a verdict on either.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))

from replay import parse                                      # noqa: E402
from dataclasses import replace                               # noqa: E402
from switches import DEFAULT                                  # noqa: E402
from vectors import execute, x80                              # noqa: E402
from check import key, want_of                                # noqa: E402

# the model's switches for 8.6.14's open questions, each alternative alone
ALTS = [('fatanh_one', 'ieee'), ('flognp1_minus_one', 'neg_inf'), ('fmove_in_range', 'table'),
        ('rem_scale_inex', 'table'), ('quotient_special', 'unchanged'), ('fmovecr_documented', 'winuae'),
        ('fmovecr_documented', 'exact'), ('fint_prec', 'once'), ('fgetman_prec', 'rounded'),
        ('fcmp_nan_sign', 'sign'), ('pten_tables', 'fpsp'), ('packed_out_special', 'fpsp'),
        ('fpcc_on_trap', 'result'), ('fpcc_table', 'equations'), ('sgl_truncate_bits', 23)]
SW = {a: replace(DEFAULT, **{a[0]: a[1]}) for a in ALTS}
SW_NOTRUNC = replace(DEFAULT, sgl_truncate_bits=64)
TRANS = {0x02, 0x06, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x14, 0x15, 0x16,
         0x19, 0x1C, 0x1D} | set(range(0x30, 0x38))

J = 1 << 63


def run(v, fpcr=None, operand=None, sw=DEFAULT):
    group, kind, cmd, f, fpsr, rx, ry, rc, op, dreg, _ = v
    r = execute(kind, cmd, f if fpcr is None else fpcr, fpsr, rx, ry, rc,
                op if operand is None else operand, dreg, sw=sw)
    return (x80(r[0]), x80(r[1]), r[2], r[3], r[4], r[5])


def nan_j(want, got):
    """Equal but for the integer bit of a NaN result (exponent $7FFF)."""
    for w, g in ((want[0], got[0]), (want[1], got[1])):
        if w != g:
            if (w >> 64) & 0x7FFF != 0x7FFF or (w ^ g) != J:
                return False
    return want[2:] == got[2:]


def causes(v, want, got):
    fpcr = v[3]
    if nan_j(want, got):
        yield 'NaN result: WinUAE integer bit 0, ours 1'
    if (fpcr >> 6) & 3 == 3:
        for p, name in ((2, 'double'), (1, 'single')):
            if run(v, fpcr=(fpcr & ~0xC0) | (p << 6)) == want:
                yield 'FPCR PREC=11: WinUAE rounds as %s, ours extended' % name
                break
        else:
            g2 = run(v, fpcr=(fpcr & ~0xC0) | (2 << 6))
            if nan_j(want, g2):
                yield 'FPCR PREC=11 as double, and a NaN integer bit'
    cmd = v[2]
    if v[1] == 'G' and (cmd >> 13) in (0, 2) and (cmd & 0x7F) == 0x24:
        if run(v, sw=SW_NOTRUNC) == want:
            yield 'FSGLDIV: WinUAE truncates neither operand, ours both to 24 bits'
            return
        w, g = want[0], got[0]
        if (w >> 64) & 0x7FFF == 0x7FFE and (g >> 64) == (w >> 64) and w & ((1 << 40) - 1) == (1 << 40) - 1:
            yield 'FSGLDIV overflow: WinUAE largest extended, ours largest single-mantissa'
            return
    for a, sw in SW.items():
        try:
            if run(v, sw=sw) == want:
                yield 'switch %s=%r (WinUAE), ours %r' % (a[0], a[1], getattr(DEFAULT, a[0]))
                return
        except Exception:
            pass
    op = cmd & 0x7F
    gen = v[1] == 'G' and (cmd >> 13) in (0, 2)
    exc = lambda f: (f >> 8) & 0xFF
    if gen and op in (0x21, 0x25) and run(v, fpcr=fpcr & ~0xC0)[0] == want[0] and (fpcr >> 6) & 3:
        yield 'FREM/FMOD: WinUAE does not round the remainder to PREC, ours does (FREM note 2)'
        return
    if gen and op in (0x21, 0x25) and want[0] == got[0] and (want[2] ^ got[2]) == 0x800:
        yield 'FREM/FMOD: WinUAE sets UNFL on an exact zero remainder, ours not'
        return
    if gen and op == 0x26 and want[0] != got[0] and (got[2] & 0x1800):
        yield 'FSCALE |scale| >= 2^14: ours overflows/underflows (4-102), WinUAE scales'
        return
    if gen and want[0] == got[0] and (want[2] ^ got[2]) == 0x200 and want[2] & 0x1000 and not want[2] & 0x200:
        yield 'overflow: WinUAE OVFL without INEX2, ours with (%s)' % ('transcendental' if op in TRANS else 'other')
        return
    if v[1] == 'G' and (cmd >> 13) == 3 and (want[2] ^ got[2]) & 0x208 == 0x208 and want[2] & 0x2000             and want[5] == got[5]:
        yield 'integer store overflow: WinUAE OPERR alone, ours OPERR + INEX2'
        return
    if v[1] == 'G' and (cmd >> 13) == 2 and ((cmd >> 10) & 7) == 7 and want[0] == got[0]:
        yield 'FMOVECR: same value, FPSR %X (WinUAE) against %X' % (want[2], got[2])
        return
    if gen and op in range(0x30, 0x38) and want[0] == got[0] and want[1] != got[1]:
        yield 'FSINCOS: the cosine differs (the sine agrees)'
        return
    if v[1] == 'G' and (cmd >> 13) in (0, 2) and (cmd & 0x7F) in (0x01, 0x03):
        if run(v, fpcr=fpcr & ~0xC0) == want:
            yield 'FINT/FINTRZ: WinUAE does not round to PREC, ours twice'
            return
    if v[1] == 'G' and (cmd >> 13) in (0, 2) and (cmd & 0x7F) in TRANS:
        ws, gs = want[0], got[0]
        if ws >> 79 == gs >> 79 and (ws >> 64) & 0x7FFF != 0x7FFF and (gs >> 64) & 0x7FFF != 0x7FFF:
            # the distance in units of the last place at the vector's precision
            p = {0: 64, 1: 24, 2: 53, 3: 64}[(fpcr >> 6) & 3]
            def lin(x):
                return (((x >> 64) & 0x7FFF) << 64 | (x & ((1 << 64) - 1))) >> (64 - p)
            d = abs(lin(ws) - lin(gs))
            if 0 < d <= 4:
                yield 'transcendental: %d ulp%s apart at PREC%s' % (d, '' if d == 1 else 's',
                                                                 '' if want[2] == got[2] else ', FPSR differs')
                return
            if d:
                yield 'transcendental: %s ulps apart at PREC%s' % (
                    '<= 2^%d' % d.bit_length(), '' if want[2] == got[2] else ', FPSR differs')
                return
            if want[2] != got[2]:
                yield 'transcendental: same result, FPSR %X (WinUAE) against %X' % (want[2], got[2])
                return


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('diff')
    ap.add_argument('--show', type=int, default=3)
    a = ap.parse_args(argv)
    by = Counter()
    rest = defaultdict(list)
    for line in open(a.diff):
        v = parse(line)
        want = want_of(v)
        got = run(v)
        c = next(causes(v, want, got), None)
        if c:
            by[c] += 1
            continue
        k = key(v)
        rest[k].append((line.strip(), want, got))
    for c, n in by.most_common():
        print('%8d  %s' % (n, c))
    print('%8d  unexplained' % sum(len(x) for x in rest.values()))
    for k in sorted(rest, key=lambda k: -len(rest[k])):
        print('\n%s: %d' % (k, len(rest[k])))
        for line, want, got in rest[k][:a.show]:
            print('  ' + line)
            for i, name in enumerate(['ry', 'rc', 'fpsr', 'vector', 'when', 'store']):
                if want[i] != got[i]:
                    print('    %-6s winuae %X  ours %X' % (name, want[i], got[i]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
