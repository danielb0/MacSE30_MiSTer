"""Where an instruction's clocks go (plan 8.8.19's timing pass): each
microinstruction's clocks charged to the nearest label at or before it.

    python profile.py OPMODE [count [span]]      e.g. python profile.py 14

Runs the 'transcend' (or 'rounding') vectors of that register-to-register
opmode with normal operands (exponents within span of 0, default 8) and
extended PREC, and prints the clocks per
label, averaged over the vectors, largest first - and the same for the
slowest of them.
"""

import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vec                                                    # noqa: E402


def main(op, count=40, span=8):
    r, labels = vec.load([os.path.join(HERE, 'ucode', 'fpu.uc')])
    chip = vec.Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'), tadj=r.tadj)
    by_addr = sorted((a, n) for n, a in labels.items() if r.rom[a] is not None and r.rom[a].table_of is None)
    owner = {}
    j = 0
    for a in range(len(r.rom)):
        while j + 1 < len(by_addr) and by_addr[j + 1][0] <= a:
            j += 1
        owner[a] = by_addr[j][1] if by_addr and by_addr[j][0] <= a else '?'
    tally, runs, total = Counter(), 0, 0
    worst = (0, None, None)
    step = chip.step

    def counted():
        a = chip.upc
        c0 = chip.clocks
        step()
        tally[owner.get(a, '?')] += chip.clocks - c0
    chip.step = counted
    for line in open(os.path.join(HERE, '..', 'fpu_model', 'out', 'fpu.vec')):
        if line[0] == '#':
            continue
        v = vec.parse(line)
        if v[1] != 'G' or (v[2] >> 13) != 0 or (v[2] & 0x7F) != op or (v[3] >> 6) & 3:
            continue
        x = v[5]
        if x.e in (0, 0x7FFF) or not x.m >> 63 or abs(x.e - 16383) > span:
            continue
        before = Counter(tally)
        got = vec.execute(chip, v)
        if got[3]:
            continue
        if got[7] > worst[0]:
            worst = (got[7], x, tally - before)
        runs += 1
        total += got[7]
        if runs >= count:
            break
    print('opmode $%02X: %d vectors, %.0f clocks on average' % (op, runs, total / max(runs, 1)))
    for name, c in tally.most_common(25):
        print('  %-12s %7.1f' % (name, c / max(runs, 1)))
    if worst[1] is not None:
        x = worst[1]
        print('slowest: %d clocks, source %X.%04X.%016X' % (worst[0], x.s, x.e, x.m))
        for name, c in worst[2].most_common(25):
            print('  %-12s %7d' % (name, c))


if __name__ == '__main__':
    main(int(sys.argv[1], 16), int(sys.argv[2]) if len(sys.argv) > 2 else 40,
         int(sys.argv[3]) if len(sys.argv) > 3 else 8)
