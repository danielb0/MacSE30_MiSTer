"""The transcendental differences against the true value - plan 8.9.8.

    python accuracy.py <model_diff.vec>

For each transcendental vector where WinUAE and our model differ, the true
result (mpmath, 200 bits) and each side's error in units of the last place
at the vector's rounding precision; summarized by operation and by the
argument's size.  Neither side is the 68882: this says how far each is from
the mathematics, which the manual's accuracy statements bound.
"""
import os
import sys
from collections import defaultdict

import mpmath as mp

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))

from fpu import FPU                                           # noqa: E402
from switches import DEFAULT                                  # noqa: E402
from replay import parse                                      # noqa: E402
from vectors import x80                                       # noqa: E402
from check import want_of, model_run                          # noqa: E402

mp.mp.prec = 200
F = {0x02: mp.sinh, 0x06: mp.log1p, 0x08: mp.expm1, 0x09: mp.tanh, 0x0A: mp.atan, 0x0C: mp.asin,
     0x0D: mp.atanh, 0x0E: mp.sin, 0x0F: mp.tan, 0x10: mp.exp, 0x11: lambda x: mp.power(2, x),
     0x12: lambda x: mp.power(10, x), 0x14: mp.log, 0x15: mp.log10, 0x16: lambda x: mp.log(x, 2),
     0x19: mp.cosh, 0x1C: mp.acos, 0x1D: mp.cos}
NAME = {0x02: 'FSINH', 0x06: 'FLOGNP1', 0x08: 'FETOXM1', 0x09: 'FTANH', 0x0A: 'FATAN', 0x0C: 'FASIN',
        0x0D: 'FATANH', 0x0E: 'FSIN', 0x0F: 'FTAN', 0x10: 'FETOX', 0x11: 'FTWOTOX', 0x12: 'FTENTOX',
        0x14: 'FLOGN', 0x15: 'FLOG10', 0x16: 'FLOG2', 0x19: 'FCOSH', 0x1C: 'FACOS', 0x1D: 'FCOS'}


def val(x80v):
    s, e, m = (x80v >> 79) & 1, (x80v >> 64) & 0x7FFF, x80v & ((1 << 64) - 1)
    if e == 0x7FFF:
        return None
    v = mp.mpf(m) * mp.power(2, e - 16383 - 63)
    return -v if s else v


def ulps(res, true, p):
    if res is None or true is None or not mp.isfinite(true):
        return None
    if true == 0:
        return 0 if res == 0 else float('inf')
    u = mp.power(2, mp.floor(mp.log(abs(true), 2)) - p + 1)
    return float(abs(res - true) / u)


def source(v):
    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, _ = v
    if cmd >> 13 == 0:
        return x80(rx)
    f = FPU(DEFAULT)
    src, _ = f.convert_in((cmd >> 10) & 7, operand)
    return x80(src)


def bucket(x):
    a = abs(x)
    for lim, name in ((1, '|x|<1'), (64, '1..64'), (2 ** 14, '64..2^14'), (2 ** 30, '2^14..2^30')):
        if a < lim:
            return name
    return '>=2^30'


def main(path):
    st = defaultdict(lambda: [0, 0, 0, 0, 0])   # n, ours<=1, winuae<=1, ours better, winuae better
    for line in open(path):
        v = parse(line)
        cmd = v[2]
        if v[1] != 'G' or cmd >> 13 not in (0, 2):
            continue
        op = cmd & 0x7F
        sc = 0x30 <= op <= 0x37
        if op not in F and not sc:
            continue
        if (v[3] >> 6) & 3 == 3:
            continue                            # PREC = 11: its own cause (triage.py)
        x = val(source(v))
        if x is None:
            continue
        want, got = want_of(v), model_run(v)
        p = {0: 64, 1: 24, 2: 53, 3: 64}[(v[3] >> 6) & 3]
        try:
            pairs = [(mp.sin(x), want[0], got[0])] if sc else [(F[op](x), want[0], got[0])]
            if sc:
                pairs.append((mp.cos(x), want[1], got[1]))
        except (ValueError, ZeroDivisionError):
            continue
        for k, (t, w, g) in enumerate(pairs):
            if w == g:
                continue
            ew, eg = ulps(val(w), t, p), ulps(val(g), t, p)
            if ew is None or eg is None:
                continue
            name = ('FSINCOS.' + ('sin' if k == 0 else 'cos')) if sc else NAME[op]
            for key in ((name, 'all'), (name, bucket(x))):
                s = st[key]
                s[0] += 1
                s[1] += eg <= 1
                s[2] += ew <= 1
                s[3] += eg < ew
                s[4] += ew < eg
    print('%-14s %-11s %7s %10s %10s %11s %11s' % ('operation', 'argument', 'n', 'ours<=1ulp', 'wuae<=1ulp',
                                                 'ours closer', 'wuae closer'))
    for (name, b), s in sorted(st.items()):
        print('%-14s %-11s %7d %10d %10d %11d %11d' % (name, b, *s))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
