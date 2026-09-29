"""Where a checkpoint may go (plan 8.8.12): the words, in the source lines
given, whose live-out in every call chain is within T0-T10 (Q, MD and MD3
dead) and whose control field is free for ctl=checkpoint.

    python cpcand.py FILE:FIRST-LAST [...]     e.g. python cpcand.py transcend.uc:180-230

Prints each such word's line; `-` marks one that is legal but has its
control field taken.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm                                                    # noqa: E402
import fields as FD                                           # noqa: E402


def main(argv):
    r = asm.assemble([os.path.join(HERE, 'ucode', 'fpu.uc')])
    if r.errors:
        raise SystemExit('\n'.join(r.errors))
    allowed = {'T%d' % i for i in range(FD.LIVE_AT_CHECKPOINT)}
    ranges = []
    for a in argv:
        f, span = a.split(':')
        lo, hi = (int(x) for x in span.split('-'))
        ranges.append((f, lo, hi))
    for u in sorted((u for u in r.rom if u is not None), key=lambda u: (u.loc.path, u.loc.line)):
        base = os.path.basename(u.loc.path)
        if not any(base == f and lo <= u.loc.line <= hi for f, lo, hi in ranges):
            continue
        out = asm.check.live_out(u.addr)
        bad = out - allowed
        free = u.nano.get('ctl', 'NONE') in ('NONE', None)
        mark = ' ' if not bad and free else ('-' if not bad else 'x')
        extra = '' if not bad else '   [%s]' % ', '.join(sorted(bad))
        print('%s %s:%-5d %s%s' % (mark, base, u.loc.line, u.loc.text.strip()[:70], extra))


if __name__ == '__main__':
    main(sys.argv[1:])
