"""The checkpoints' spacing (plan 8.8.12, 8.8.19's timing pass): the
longest run of clocks, per instruction, in which a waiting FSAVE could not
be let in - from the instruction's start to its first checkpoint, between
checkpoints, and from the last to the END word.  END's padding does not
count: the instruction is finished, and the BIU cuts the pad short.

    python cpgap.py [--limit N] [--only GROUP]

Runs every vector; prints per instruction the longest gap (from the
checkpoint that opens it to where it closes) and flags those over the
limit.  The limit (default 125): 8.8.12's "about 70" where the loops allow,
and never more than one atomic step - a loop that keeps its state in Q, MD
or MD3 (FDIV's and the helpers' divides, FSQRT's root, the multiplies,
FMOD's last chunk) cannot hold a checkpoint - with its setup and the
instruction's ending.  Exit status 1 when any gap is over.
"""

import argparse
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vec                                                    # noqa: E402
import fields as FD                                           # noqa: E402
from replay import parse                                      # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=125)
    ap.add_argument('--vec', default=os.path.join(vec.MODEL, 'out', 'fpu.vec'))
    ap.add_argument('--only', default=None, help='a vector group')
    a = ap.parse_args(argv)
    r, labels = vec.load([os.path.join(HERE, 'ucode', 'fpu.uc')])
    chip = vec.Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'), tadj=r.tadj)
    names = sorted((ad, n) for n, ad in labels.items())

    def where(addr):
        best = '?'
        for ad, n in names:
            if ad <= addr:
                best = n
            else:
                break
        return best

    worst = defaultdict(lambda: (0, ''))
    step = chip.step
    state = {}

    def counted():
        a = chip.upc
        c0 = chip.clocks
        if state['since'] is None:                 # (a .tadj may start the count above 0, 8.9.7)
            state['since'] = c0
        m, n = chip._decode(a)
        step()
        if chip.done:                              # END: its own clock counts, not the pad
            gap = c0 + 1 - state['since']
            state['gap'] = max(state['gap'], (gap, '%s -> %s' % (state['from'], where(a))))
        elif n['ctl'] == 'CHECKPOINT':
            gap = chip.clocks - state['since']
            state['gap'] = max(state['gap'], (gap, '%s -> %s' % (state['from'], where(a))))
            state['since'] = chip.clocks
            state['from'] = where(a)
    chip.step = counted
    for line in open(a.vec):
        if line[0] == '#' or not line.strip():
            continue
        v = parse(line)
        if a.only and v[0] != a.only:
            continue
        state.update(since=None, gap=(0, ''), **{'from': 'start'})
        try:
            vec.execute(chip, v)
        except vec.Unimplemented:
            continue
        k = vec.opkey(v)[1].split('.')[0]
        if state['gap'] > worst[k]:
            worst[k] = state['gap']
    over = 0
    for k in sorted(worst, key=lambda k: -worst[k][0]):
        g, w = worst[k]
        flag = '  OVER' if g > a.limit else ''
        over += bool(flag)
        print('%-8s %5d  (%s)%s' % (k, g, w, flag))
    print('%d instructions with a gap over %d clocks' % (over, a.limit))
    return 1 if over else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
