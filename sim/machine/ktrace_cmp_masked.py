"""Compare two KTRACE files with the kernel's unused inputs masked.

din is kept only on an acknowledged read beat (go 1, bv 1, bs 00 or 10) and
ds only on an acknowledged bus beat (go 1, bv 1, bs not 01); everything else
(go, bv, be, the walker's, the kernel's address and busstate, the releases)
is compared as it is.  Also counts the raw differences per field.
  python ktn.py A.txt B.txt
"""
import sys, re, difflib
pat = re.compile(r'^(\d+) go (\S) bv (\S) din (\S+) ds (\S+) (be .*\| a \S+ bs (\S\S).*)$')
def load(name):
    out = []; raw = []
    for line in open(name):
        line = line.rstrip('\n'); m = pat.match(line)
        if not m: out.append(line.strip()); raw.append(None); continue
        _, go, bv, din, ds, rest, bs = m.groups()
        ack = go == '1' and bv == '1' and bs != '01'
        out.append('go %s bv %s din %s ds %s %s' % (go, bv, din if ack and bs in ('00', '10') else '-', ds if ack else '-', rest.rstrip()))
        raw.append((din, ds))
    return out, raw
a, ra = load(sys.argv[1]); b, rb = load(sys.argv[2])
hunks = 0; tail = 0
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
    if tag == 'equal': continue
    # the run's end: the bench stops a clock or two apart when the bus is a clk late
    if i1 >= len(a) - 2 and j1 >= len(b) - 2 and (i2 - i1) + (j2 - j1) <= 2: tail += 1; continue
    hunks += 1
    if hunks <= 5:
        print('---- hunk', hunks, tag, i1 + 1, i2, j1 + 1, j2)
        for k in range(i1, min(i2, i1 + 6)): print('  A', a[k])
        for k in range(j1, min(j2, j1 + 6)): print('  B', b[k])
print('%d / %d lines, %d hunk(s) with unused din/ds masked%s' % (len(a), len(b), hunks, ' (the last line apart: the bench stops a clock later)' if tail else ''))
if len(a) == len(b):
    nd = sum(1 for x, y in zip(ra, rb) if x and y and x[0] != y[0]); ns = sum(1 for x, y in zip(ra, rb) if x and y and x[1] != y[1])
    print('raw: din differs on %d lines, ds on %d (all on beats where the kernel does not use them, if 0 hunks)' % (nd, ns))
sys.exit(0 if hunks == 0 else 1)
