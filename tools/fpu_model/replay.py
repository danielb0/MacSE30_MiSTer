"""Read a vector file back and run every vector through the model: the
writer and a parser of the fields agree, the model is deterministic, and
nothing was lost in the hex (plan 8.7.4).  The parser here is the one a
Verilog bench's $fscanf mirrors: split on spaces, fixed-width hex.

    python replay.py fpu.vec
"""

import sys
from collections import Counter

from harness import Checks
from vectors import execute, from80, fields_of, x80

WIDTHS = [None, None, 4, 8, 8, 20, 20, 20, 24, 8, 20, 20, 8, 2, 1, 24, 20]


def parse(line):
    f = line.split()
    assert len(f) == 17, 'field count %d' % len(f)
    for w, v in zip(WIDTHS, f):
        assert w is None or len(v) == w, 'width of %r' % v
    group, kind = f[0], f[1]
    cmd, fpcr, fpsr = (int(v, 16) for v in f[2:5])
    rx, ry, rc = (from80(int(v, 16)) for v in f[5:8])
    operand, dreg = int(f[8], 16), int(f[9], 16)
    expect = (from80(int(f[10], 16)), from80(int(f[11], 16)), int(f[12], 16), int(f[13], 16),
              int(f[14], 16), int(f[15], 16), from80(int(f[16], 16)))
    return group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, expect


def main(path):
    c = Checks()
    groups, bad = Counter(), []
    lines = 0
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        lines += 1
        group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, expect = parse(line)
        groups[group] += 1
        got = execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg)
        again = fields_of(group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, got)
        if again != line.rstrip('\n') and len(bad) < 5:
            bad.append('%s\n       %s' % (line.rstrip(), again))
    c.check('every vector parses (17 fixed-width fields) and replays to the same line',
            not bad, lines, bad)
    c.check('groups: ' + ', '.join('%s %d' % kv for kv in sorted(groups.items())), True, lines)
    return c.summary()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'fpu.vec'))
