"""Sample the 68030 integer corpus as cputestgen writes it (plan 1.18.6).

The generator's text records (se30dump.py) for the integer presets run to
tens of gigabytes: every round is stored once per input-flag combination.
This reads them from a pipe as they are written and keeps, per instruction
form, up to --per rounds - a reservoir, so the kept rounds are spread over
the whole stream - and only rounds harness_i.py can run:

  - ended normally: exc 4, the generator's ILLEGAL end marker, its frame
    the last three writes;
  - not traced (SR T1/T0 clear);
  - not an instruction that would disturb the harness itself (the
    control registers, the PMMU, STOP, RESET, the vector-table base).

The form is the directory (mnemonic and size) and the opcode word with its
register numbers masked (bits 11-9, and 2-0 unless the EA mode is 7, where
they choose the mode), and the supervisor bit.

    mkfifo se30_vectors.txt; cputestgen & python3 sample_int.py se30_vectors.txt -o sampled.txt
"""
import argparse
import random
import re
import sys
from collections import defaultdict

SKIP = re.compile(r'/(MOVEC|MVC2R|MVR2C|PMOVE|PFLUSH|PTEST|PLOAD|STOP|RESET|ILLEGAL|BKPT|TRAP\b|TRAP\.|CALLM|RTM|LPSTOP|CINV|CPUSH|MOVE16)', re.I)


def form(dirname, op0, s):
    m = op0 & 0xF1F8
    if (op0 >> 3) & 7 == 7:
        m |= op0 & 7
    if (op0 >> 12) in (1, 2, 3) and (op0 >> 6) & 7 == 7:      # MOVE's destination mode 7
        m |= op0 & 0x0E00
    return (dirname, m, s)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', required=True)
    ap.add_argument('--per', type=int, default=3)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args(argv)
    rnd = random.Random(a.seed)
    pool, seen = defaultdict(list), defaultdict(int)
    n = taken = 0
    stats = defaultdict(int)
    with open(a.src, 'r', errors='replace') as f:
        for line in f:
            n += 1
            if n % 1000000 == 0:
                print('%d M records, %d forms' % (n // 1000000, len(pool)), file=sys.stderr, flush=True)
            sp = line.find(' ')
            d = line[:sp]
            if SKIP.search(d):
                stats['skip-instr'] += 1
                continue
            e = line.rfind('exc=')
            if not line.startswith('4,', e + 4):
                stats['exception'] += 1
                continue
            t = line.split()
            i = t.index('pre')
            sr = int(t[i + 17], 16)
            if sr & 0xC000:
                stats['traced'] += 1
                continue
            op0 = int(t[1][3:7], 16)
            k = form(d, op0, (sr >> 13) & 1)
            seen[k] += 1
            if len(pool[k]) < a.per:
                pool[k].append(line)
            elif rnd.random() < a.per / seen[k]:
                pool[k][rnd.randrange(a.per)] = line
    with open(a.o, 'w', newline='\n') as g:
        for k in sorted(pool):
            for line in pool[k]:
                g.write(line if line.endswith('\n') else line + '\n')
                taken += 1
    print('%d records read; kept %d rounds in %d forms; left out %s' % (n, taken, len(pool), dict(stats)))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
