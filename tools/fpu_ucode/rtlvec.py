"""The RTL bench's vectors (plan 8.9, item 7a): the model's vectors with the
simulator's clocks, and the simulator's trace of one vector.

    python rtlvec.py [--vec FILE] [-o OUT]        vectors + clocks
    python rtlvec.py --trace N [-o OUT]           the trace of vector N

The bench (sim/fpu) holds the RTL to sim.py, which is the definition of
every field: each vector's seven results against the model (as vec.py
compares them), and its clocks against the simulator's.  A vector line is
the model's 17 fields and an 18th, the simulator's clocks in hex (0 for
the conditionals and the F-lines, which run no microcode).

The trace is one line per executed microinstruction - its address, the
clocks before it, and the state it leaves - in the format the bench prints
with +trace=N, so the first line that differs is the first microinstruction
the RTL gets wrong.  N counts the file's vectors from 0.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import vec                                                    # noqa: E402
import sim                                                    # noqa: E402
from sim import Chip                                          # noqa: E402
from replay import parse                                      # noqa: E402


class TraceChip(Chip):
    """A Chip that records the state each microinstruction leaves."""

    def _side_effects(self, e, m, res, B, A, out_bits, dropped, r):
        self._res = res
        Chip._side_effects(self, e, m, res, B, A, out_bits, dropped, r)

    def step(self):
        a, before = self.upc, self.clocks
        self._res = None
        Chip.step(self)
        self.lines.append(trace_line(self, a, before))


def trace_line(c, a, before):
    res = c._res
    rs = '-' if res is None else '%x.%05x.%017x' % (res.s, res.e & sim.M18, res.m)
    return ('U %03x C %d F %d%d%d%d%d %d%d%d%d%d SC %02x LC %02x LZ %02x Q %017x %d MD %017x %017x P %08x B %d R %s'
            % (a, before, c.Z, c.N, c.C, c.V, c.S, c.STK, int(bool(c.INEX)), c.DFLAG, c.TINY, c.HUGE,
               c.SC, c.LC, c.LZC, c.Q, c.QX, c.MD, c.MD3, c.fpsr, c.BUDGET, rs))


def vectors(path):
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        yield line.rstrip('\n')


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--vec', default=os.path.join(vec.MODEL, 'out', 'fpu.vec'))
    ap.add_argument('-o', '--out', default=None)
    ap.add_argument('--trace', type=int, default=None)
    ap.add_argument('--ucode', nargs='*', default=[os.path.join(HERE, 'ucode', 'fpu.uc')])
    a = ap.parse_args(argv)
    r, labels = vec.load(a.ucode)
    if a.trace is not None:
        chip = TraceChip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'))
        chip.lines = []
        for i, line in enumerate(vectors(a.vec)):
            if i == a.trace:
                vec.execute(chip, parse(line))
                break
        else:
            raise SystemExit('no vector %d' % a.trace)
        text = '\n'.join(chip.lines) + '\n'
        out = a.out or os.path.join(HERE, 'out', 'trace_%d.txt' % a.trace)
    else:
        chip = Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'))
        lines, bad = [], 0
        for line in vectors(a.vec):
            v = parse(line)
            got = vec.execute(chip, v)
            clocks = got[7] if len(got) > 7 else 0
            if vec.compare(v, got):
                bad += 1
            lines.append('%s %04X' % (line, clocks))
        if bad:
            raise SystemExit('%d vectors fail on the simulator: run vec.py first' % bad)
        text = '\n'.join(lines) + '\n'
        out = a.out or os.path.join(HERE, 'out', 'fpu_rtl.vec')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', newline='\n') as fh:
        fh.write(text)
    print('%s: %d lines' % (out, text.count('\n')))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
