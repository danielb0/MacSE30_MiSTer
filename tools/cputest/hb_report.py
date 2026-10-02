"""Harness B's failures by round and field (plan 8.9.8):
    python hb_report.py <batch dir> [NN ...]"""
import os
import re
import sys

RES0, SZ = 0xC000, 172


def field(off):
    if off < 32:
        return 'D%d' % (off // 4)
    if off < 64:
        return 'A%d' % ((off - 32) // 4)
    if off < 160:
        return 'FP%d.%d' % ((off - 64) // 12, ((off - 64) % 12) // 4)
    return {160: 'FPCR', 164: 'FPSR', 168: 'FPIAR'}.get(off, '?%d' % off)


def main(d, which):
    for n in which:
        lst = open(os.path.join(d, 'list_%s.txt' % n)).read().splitlines()
        log = open(os.path.join(d, 'run_%s.log' % n)).read()
        m = re.search(r'marker (\w+)', log)
        fails = re.findall(r'FAIL \$(\w+): (\w+), expected (\w+) \(mask (\w+)\)', log)
        by = {}
        first_missing = None
        for a, got, want, mask in fails:
            a = int(a, 16)
            if RES0 <= a < RES0 + SZ * len(lst):
                i, off = divmod(a - RES0, SZ)
                if int(got, 16) == 0 and first_missing is None and off == 0:
                    pass
                by.setdefault(i, []).append('%s %s want %s' % (field(off), got, want))
            else:
                by.setdefault('mem', []).append('$%05X %s want %s mask %s' % (a, got, want, mask))
        print('== batch %s: marker %s, %d failing checks' % (n, m.group(1) if m else '?', len(fails)))
        stopped = None
        for i in sorted(k for k in by if k != 'mem'):
            allzero = all(x.split()[1] == '00000000' for x in by[i])
            if allzero and len(by[i]) > 20 and stopped is None:
                stopped = i
            if stopped is not None and i >= stopped:
                continue
            print('  round %d: %s\n     %s' % (i, lst[i], '; '.join(by[i][:6])))
        if stopped is not None:
            print('  stopped at round %d: %s' % (stopped, lst[stopped]))
        for x in by.get('mem', [])[:6]:
            print('  mem ' + x)


if __name__ == '__main__':
    d = sys.argv[1]
    which = sys.argv[2:] or sorted(f[4:6] for f in os.listdir(d) if f.startswith('run_'))
    main(d, which)
