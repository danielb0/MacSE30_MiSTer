"""Check convert.py's FMOVEM / FMOVE-control records (M form) against the
68882 reference model - plan 8.9.8.

    python check_m.py <mvec>... [--show N]

Compared: FP0-FP7, FPCR, FPSR and FPIAR after, and the longwords moved
out (memory in address order, or the data/address register).  WinUAE's
model, not silicon (plan 8.6.15).

The model lists FMOVEM's registers FP0 at the lowest address, which holds
when the list's mode field and the effective address agree.  The FPU sees
only the mode field and transfers in its order (FP7 first for a
predecrement list); the 030 takes the address direction from the effective
address.  Where they disagree (a predecrement list with a control or
postincrement address, a postincrement list with -(An)), the registers land
in the other order - applied here, as the bus protocol gives it.
"""
import argparse
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))

from fpu import FPU                                           # noqa: E402
from switches import DEFAULT                                  # noqa: E402
from vectors import from80, x80                               # noqa: E402


def blocks_reversed(v):
    return [x for i in range(len(v) - 3, -1, -3) for x in v[i:i + 3]]


def run(cmd, dreg, eamode, fp, fpcr, fpsr, fpiar, vin):
    oc = cmd >> 13
    swap = oc in (6, 7) and (not (cmd >> 12) & 1) != (eamode == 4)
    if swap and oc == 6:
        vin = blocks_reversed(vin)
    f = FPU(DEFAULT)
    f.fp = [from80(x) for x in fp]
    f.fpcr, f.fpsr, f.fpiar = fpcr, fpsr, fpiar
    oc = cmd >> 13
    if oc == 6:
        vin = [(vin[i] << 64) | (vin[i + 1] << 32) | vin[i + 2] for i in range(0, len(vin), 3)]
    o = f.general(cmd, vin, dreg=dreg)
    out = []
    if oc == 5:
        out = list(o.store)
    elif oc == 7:
        for v in o.store:
            out += [(v >> 64) & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF]
        if swap:
            out = blocks_reversed(out)
    return [x80(x) for x in f.fp], f.fpcr, f.fpsr, f.fpiar, out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('mvec', nargs='+')
    ap.add_argument('--show', type=int, default=3)
    a = ap.parse_args(argv)
    n = Counter()
    shown = Counter()
    for p in a.mvec:
        for line in open(p):
            if line.startswith('#') or not line.strip():
                continue
            pre, vin, post, vout = line.split('|')
            t = pre.split()
            group, cmd, dreg, eamode = t[0], int(t[2], 16), int(t[3], 16), int(t[4])
            fp = [int(x, 16) for x in t[5:13]]
            fpcr, fpsr, fpiar = (int(x, 16) for x in t[13:16])
            vin = [] if vin.strip() == '-' else [int(x, 16) for x in vin.split()]
            q = post.split()
            want = ([int(x, 16) for x in q[0:8]], int(q[8], 16), int(q[9], 16), int(q[10], 16),
                    [] if vout.strip() == '-' else [int(x, 16) for x in vout.split()])
            k = '%s oc%d' % (group, cmd >> 13)
            try:
                got = run(cmd, dreg, eamode, fp, fpcr, fpsr, fpiar, vin)
            except Exception as e:
                n[k + ' error'] += 1
                if shown[k] < a.show:
                    shown[k] += 1
                    print('ERROR %s %s: %s' % (k, e, line.strip()[:200]))
                continue
            names = ['fp', 'fpcr', 'fpsr', 'fpiar', 'out']
            diff = [names[i] for i in range(5) if want[i] != got[i]]
            if not diff:
                n[k + ' pass'] += 1
                continue
            n[k + ' fail ' + '+'.join(diff)] += 1
            if shown[k] < a.show:
                shown[k] += 1
                print('DIFF %s %04X: %s' % (k, cmd, ', '.join(diff)))
                for i in range(5):
                    if want[i] != got[i]:
                        print('    %-5s winuae %s\n          ours   %s' % (names[i], want[i], got[i]))
    for k, v in sorted(n.items()):
        print('%-40s %8d' % (k, v))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
