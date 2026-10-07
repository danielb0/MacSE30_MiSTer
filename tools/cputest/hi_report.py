"""Name harness I's failures (plan 1.18.6): each FAIL line of a batch's
run log, as the round, its instruction and the field.

    python3 hi_report.py <batch dir> [batch number ...]

A round's results: D0-A7 at +0..+63, SR (the CCR in user mode) at +64 (its
upper word), then a copy of each byte the round wrote from +68.  The SR
fields are spelt out: T1 T0 S M, the mask, X N Z V C.
"""
import os
import re
import sys

REGS = ['D%d' % i for i in range(8)] + ['A%d' % i for i in range(8)]


def flags(v):
    return ''.join(c if v & (1 << b) else '.' for c, b in (('X', 4), ('N', 3), ('Z', 2), ('V', 1), ('C', 0)))


def report(d, nb):
    rounds = []
    for line in open(os.path.join(d, 'list_%s.txt' % nb)):
        t = line.split()
        if not t:
            continue
        rounds.append((int(t[t.index('res') + 1], 16), line.strip(), int(t[-1])))
    rounds.sort()
    out = []
    for line in open(os.path.join(d, 'run_%s.log' % nb)):
        m = re.match(r'# FAIL \$([0-9a-f]+): ([0-9a-f]+), expected ([0-9a-f]+) \(mask ([0-9a-f]+)\)', line)
        if not m:
            if line.startswith('# FAIL') or line.startswith('# ---- the run'):
                out.append(line.strip()[2:])
            continue
        a, got, want, mask = (int(x, 16) for x in m.groups())
        base = None
        for r0, desc, nw in rounds:
            if r0 <= a < r0 + 68 + nw + 4:
                base = (r0, desc)
        if base is None:
            out.append('?? $%06x' % a)
            continue
        off = a - base[0]
        if off < 64:
            field = '%s %08x, WinUAE %08x' % (REGS[off // 4], got, want)
        elif off == 64:
            g, w = got >> 16, want >> 16
            field = 'SR %04x (%s), WinUAE %04x (%s)' % (g, flags(g), w, flags(w))
        else:
            field = 'written bytes: %08x, WinUAE %08x (mask %08x)' % (got, want, mask)
        out.append('round %s\n      %s' % (base[1], field))
    return out


def main(argv):
    d = argv[0]
    nbs = argv[1:] or sorted(re.findall(r'run_(\d+)\.log', ' '.join(os.listdir(d))))
    for nb in nbs:
        for line in report(d, nb):
            print('[%s] %s' % (nb, line))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
