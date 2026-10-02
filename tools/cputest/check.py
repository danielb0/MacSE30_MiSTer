"""Run convert.py's vectors (WinUAE cputest, plan 8.9.8) through the 68882
reference model (tools/fpu_model) or the microcode on its simulator
(tools/fpu_ucode) and list where they differ from WinUAE's results.

    python check.py <vec>... [--ucode] [--show N] [--only KEY] [--dump FILE]

Compared: FPn after, FSINCOS's cosine register, FPSR after, the vector,
when it is taken, a store's data; not the exceptional operand (WinUAE does
not record it).  Differences are grouped by instruction (opmode and source
format, or the conditional) and by which fields differ.  WinUAE's model,
not silicon (plan 8.6.15): each difference is a question for the manual.
"""
import argparse
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_ucode'))

from replay import parse                                      # noqa: E402
from vectors import execute, x80                              # noqa: E402

FIELDS = ['ry', 'rc', 'fpsr', 'vector', 'when', 'store']
FMT_NAMES = ['L', 'S', 'X', 'P', 'W', 'D', 'B', 'Pk']


def key(v):
    group, kind, cmd = v[0], v[1], v[2]
    if kind == 'C':
        return '%s:cond' % group
    oc = cmd >> 13
    if oc == 3:
        return '%s:out.%s' % (group, FMT_NAMES[(cmd >> 10) & 7])
    if oc == 2 and ((cmd >> 10) & 7) == 7:
        return '%s:fmovecr' % group
    if oc == 1:
        return '%s:opclass1' % group
    src = 'reg' if oc == 0 else FMT_NAMES[(cmd >> 10) & 7]
    return '%s:$%02X.%s' % (group, cmd & 0x7F, src)


def want_of(v):
    e = v[-1]
    return (x80(e[0]), x80(e[1]), e[2], e[3], e[4], e[5])


def model_run(v):
    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, _ = v
    r = execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg)
    return (x80(r[0]), x80(r[1]), r[2], r[3], r[4], r[5])


def ucode_runner():
    import vec as V
    r, labels = V.load([os.path.join(HERE, '..', 'fpu_ucode', 'ucode', 'fpu.uc')])
    chip = V.Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'), tadj=r.tadj)

    def run(v):
        try:
            got = V.execute(chip, v)
        except V.Unimplemented:
            return None
        return (V.x80(got[0]), V.x80(got[1]), got[2], got[3], got[4], got[5])
    return run


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('vec', nargs='+')
    ap.add_argument('--ucode', action='store_true', help='the microcode simulator, not the model')
    ap.add_argument('--show', type=int, default=2)
    ap.add_argument('--only', default=None)
    ap.add_argument('--dump', default=None, help='write every differing vector line here')
    a = ap.parse_args(argv)
    run = ucode_runner() if a.ucode else model_run
    stats = defaultdict(Counter)
    shown = Counter()
    dump = open(a.dump, 'w', newline='\n') if a.dump else None
    total = Counter()
    for p in a.vec:
        for line in open(p):
            if line.startswith('#') or not line.strip():
                continue
            v = parse(line)
            k = key(v)
            if a.only and not k.startswith(a.only):
                continue
            total['vectors'] += 1
            try:
                got = run(v)
            except Exception as e:              # the model refusing an input is a finding too
                stats[k]['error ' + type(e).__name__] += 1
                total['error'] += 1
                if shown[k] < a.show:
                    shown[k] += 1
                    print('ERROR %s: %s: %s' % (k, e, line.strip()))
                continue
            if got is None:
                stats[k]['unimpl'] += 1
                total['unimpl'] += 1
                continue
            want = want_of(v)
            diff = [FIELDS[i] for i in range(6) if want[i] != got[i]]
            if not diff:
                stats[k]['pass'] += 1
                total['pass'] += 1
                continue
            stats[k]['fail ' + '+'.join(diff)] += 1
            total['fail'] += 1
            if dump:
                dump.write(line)
            if shown[k] < a.show:
                shown[k] += 1
                print('DIFF %s: %s' % (k, line.strip()))
                for i in range(6):
                    if want[i] != got[i]:
                        print('    %-6s winuae %X  ours %X' % (FIELDS[i], want[i], got[i]))
    print()
    for k in sorted(stats):
        c = stats[k]
        bad = {x: n for x, n in c.items() if x != 'pass'}
        if bad:
            print('%-24s pass %7d  %s' % (k, c['pass'], ', '.join('%s %d' % kv for kv in sorted(bad.items()))))
    print('TOTAL %s' % ', '.join('%s %d' % kv for kv in sorted(total.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
