"""Unit checks of the microcode's subroutines against the model (plan
8.8.19): each I67 helper of ucode/transcend.uc called directly on the
simulator, its result compared with tools/fpu_model/transcend.py's function
on the same operands, bit for bit.

    python unit.py [count]

The subroutine is entered at its label with the `halt` word as its return
address; the operands go in T11 and T12, the result comes from T11 (T14
for tofix).
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import vec                                                    # noqa: E402
import sim                                                    # noqa: E402
from sim import Word                                          # noqa: E402
import transcend as T                                         # noqa: E402

BIAS = 16383
M67 = (1 << 67) - 1


def word(x):
    if x.m == 0:
        return Word(x.s, 0, 0)
    return Word(x.s, x.e + 66 + BIAS, x.m)


def same(w, x):
    """The helper's word w against the model's I67 x."""
    if x.m == 0:
        return w.m == 0 and w.s == x.s
    return w == word(x)


class Unit:
    def __init__(self):
        r, labels = vec.load([os.path.join(HERE, 'ucode', 'fpu.uc')])
        self.labels = labels
        self.chip = vec.Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'))

    def call(self, label, fpcr=0, **temps):
        c = self.chip
        c.fpcr = fpcr
        c.start(0, sim.ZERO_W, sim.ZERO_W)
        for k, v in temps.items():
            c.T[int(k[1:])] = v
        c.stack = [self.labels['halt']]
        c.upc = self.labels[label]
        steps = 0
        while not c.done:
            c.step()
            steps += 1
            if steps > 100000:
                raise sim.SimError('%s does not return' % label)
        return c


def rand_i67(rng, erange=80):
    r = rng.random()
    if r < 0.03:
        return T.I67(rng.getrandbits(1), 0, 0)
    m = (1 << 66) | rng.getrandbits(66)
    if r < 0.15:
        m = (1 << 66) | (rng.getrandbits(6) << rng.randint(0, 60))
    elif r < 0.25:
        m = M67 - rng.getrandbits(rng.randint(1, 20))
    return T.I67(rng.getrandbits(1), m, rng.randint(-erange, erange) - 66)


def main(n=3000):
    u = Unit()
    rng = random.Random(7)
    results = []

    def check(name, fn, model, operands, out='T11'):
        bad = []
        for ops in operands:
            want = model(*ops)
            temps = {'T11': word(ops[0])}
            if len(ops) > 1:
                temps['T12'] = word(ops[1])
            c = u.call(fn, **temps)
            got = c.T[int(out[1:])]
            ok = same(got, want) if out == 'T11' else got.m == (want & M67)
            if not ok and len(bad) < 3:
                bad.append('%r %s -> %r, want %r' % (ops, fn, got, want))
            results.append(ok)
            if not ok and len(bad) >= 3:
                break
        print('%s  %-8s %d operand sets%s' % ('FAIL' if bad else 'PASS', name, len(operands),
                                             ''.join('\n    ' + b for b in bad)))

    pairs = []
    for _ in range(n):
        a, b = rand_i67(rng), rand_i67(rng)
        if rng.random() < 0.3 and a.m and b.m:          # close exponents: cancellation, carries
            b = T.I67(rng.getrandbits(1), b.m, a.e + rng.randint(-2, 2))
        if rng.random() < 0.05 and a.m:
            b = T.I67(1 - a.s, a.m, a.e)                  # an exact zero
        pairs.append((a, b))
    check('i_add', 'iadd', T.i_add, pairs)
    check('i_sub', 'isub', T.i_sub, pairs)
    check('i_mul', 'imul', T.i_mul, pairs)
    check('i_div', 'idiv', T.i_div, [(a, b) for a, b in pairs if b.m])
    pos = [(T.I67(0, a.m, a.e),) for a, _ in pairs]
    check('i_sqrt', 'isqrt', T.i_sqrt, pos)
    small = [(T.I67(a.s, a.m, rng.randint(-100, 0) - 66),) for a, _ in pairs if a.m]
    check('to_fixed', 'tofix', lambda x: T.to_fixed(x), small, out='T14')
    fx = [(rng.randint(-(1 << 66), (1 << 66) - 1) >> rng.randint(0, 60),) for _ in range(n)]
    bad = []
    for (v,) in fx:
        want = T.from_fixed(v)
        c = u.call('fromfix', T14=Word(0, 0, v & M67))
        ok = same(c.T[11], want)
        results.append(ok)
        if not ok and len(bad) < 3:
            bad.append('%X -> %r, want %r' % (v, c.T[11], want))
    print('%s  %-8s %d values%s' % ('FAIL' if bad else 'PASS', 'from_fix', len(fx),
                                    ''.join('\n    ' + b for b in bad)))
    nf = results.count(False)
    print('%d PASS, %d FAIL' % (results.count(True), nf))
    return 1 if nf else 0


if __name__ == '__main__':
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 3000))
