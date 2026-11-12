"""Compare two KTRACE files step by step: only the phi1 edges at which the
kernel steps (go 1), in order - the clocks it waits are dropped, so two runs
whose bus cycles differ in length (the KCLK timing vehicle's memory, a clock
longer: tg68k.v item 7) compare equal when the kernel does the same things.
din is kept on an acknowledged read beat and ds on an acknowledged bus beat,
as ktrace_cmp_masked.py keeps them; the releases' clock counts are dropped.

  python ktrace_steps.py A.txt B.txt
"""
import re
import sys

pat = re.compile(r'^\d+ go (\S) bv (\S) din (\S+) ds (\S+) be (\S) wa (\S) wb (\S) wd (\S+) \| a (\S+) bs (\S\S)')


def load(name):
    out = []
    for line in open(name):
        m = pat.match(line)
        if not m or m.group(1) != '1':
            continue
        go, bv, din, ds, be, wa, wb, wd, a, bs = m.groups()
        ack = bv == '1' and bs != '01'
        out.append((bv, din if ack and bs in ('00', '10') else '-', ds if ack else '-', be, wa, wb, wd, a, bs))
    return out


a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b))
bad = [i for i in range(n) if a[i] != b[i]]
print('%d / %d kernel steps, %d differ in the first %d' % (len(a), len(b), len(bad), n))
for i in bad[:5]:
    print('  step %d\n    A %s\n    B %s' % (i, ' '.join(a[i]), ' '.join(b[i])))
sys.exit(0 if not bad and abs(len(a) - len(b)) <= 2 else 1)
