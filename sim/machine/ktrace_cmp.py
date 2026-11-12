"""Compare two KTRACE files from tb_se30_machine (+define+KTRACE).

Each phi1 line starts with its clock index; that index is dropped, so a run
that is one clock late from some point on shows as one hunk (the extra
line) instead of a difference on every line after it.  Prints each hunk
(up to LIMIT lines of it) and the count; exit status 0 when identical.

  python ktrace_cmp.py A.txt B.txt [LIMIT]
"""
import difflib
import sys


def load(name):
    out = []
    with open(name) as f:
        for line in f:
            line = line.rstrip('\n')
            if line[:1].isdigit():
                line = line.split(' ', 1)[1]
            out.append(line)
    return out


a, b = load(sys.argv[1]), load(sys.argv[2])
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 12
hunks = 0
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
    if tag == 'equal':
        continue
    hunks += 1
    print('---- hunk %d: %s A %d-%d, B %d-%d' % (hunks, tag, i1 + 1, i2, j1 + 1, j2))
    for k in range(i1, min(i2, i1 + limit)):
        print('  A ' + a[k])
    for k in range(j1, min(j2, j1 + limit)):
        print('  B ' + b[k])
print('%d lines / %d lines, %d hunk(s)' % (len(a), len(b), hunks))
sys.exit(0 if hunks == 0 else 1)
