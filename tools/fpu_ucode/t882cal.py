"""Calibrate ucode/t882.uc against timing matrices (plan 8.9.7, 7e-3).

    python t882cal.py zero                  every operation's N = 0
    python t882cal.py set LOG0              N = -(tail error) in LOG0, a matrix
                                            measured with every N = 0
    python t882cal.py refine LOG0 LOG1      LOG1 measured with set's N: a row
                                            still too long there is path-bound
                                            by that much - N = -d0 + d1, the
                                            least shortening that has effect

LOGs are sim/fpu/tb_fpu_timing.v +matrix outputs.  The tail errors are
against Table 8-3 (sim/fpu/table8_3.csv).  Each mode rewrites t882.uc: its
summary table and its .tadj directives; the cr and out.F lines are kept.
Why two measurements: a negative N starts the APU's count later, which
shortens an instruction only while its budget, not its microcode path, ends
it - so iterating N -= error would drift on a path-bound row, and an N more
negative than has effect would shorten that operation's other cases.
"""
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UC = os.path.join(HERE, 'ucode', 't882.uc')
CSV = os.path.join(HERE, '..', '..', 'sim', 'fpu', 'table8_3.csv')

# the operations the matrix measures: name -> opmodes it stands for
OPS = {'FABS': [0x18], 'FNEG': [0x1A], 'FADD': [0x22], 'FSUB': [0x28], 'FMUL': [0x23],
       'FDIV': [0x20], 'FCMP': [0x38], 'FTST': [0x3A], 'FSQRT': [0x04], 'FINT': [0x01],
       'FINTRZ': [0x03], 'FGETEXP': [0x1E], 'FGETMAN': [0x1F], 'FSCALE': [0x26],
       'FSGLMUL': [0x27], 'FSGLDIV': [0x24], 'FMOD': [0x21], 'FREM': [0x25],
       'FSIN': [0x0E], 'FCOS': [0x1D], 'FTAN': [0x0F], 'FSINCOS': list(range(0x30, 0x38)),
       'FATAN': [0x0A], 'FASIN': [0x0C], 'FACOS': [0x1C], 'FATANH': [0x0D], 'FSINH': [0x02],
       'FCOSH': [0x19], 'FTANH': [0x09], 'FETOX': [0x10], 'FETOXM1': [0x08], 'FTWOTOX': [0x11],
       'FTENTOX': [0x12], 'FLOGN': [0x14], 'FLOGNP1': [0x06], 'FLOG10': [0x15], 'FLOG2': [0x16],
       'FMOVE': [0x00]}
CLASSES = {'reg': 'FPm', 'S,D,X': 'S', 'B,W,L': 'L', 'P': 'P'}
# rows whose measurement is not the table's case: (op, column) -> take the
# adjustment of another row instead (FATANH of an integer is atanh(1))
BORROW = {('FATANH', 'L'): 'FASIN'}
# the CU's own moves have no APU time to adjust
SKIP = {('FMOVE', 'FPm'), ('FMOVE', 'S'), ('FMOVE', 'D'), ('FMOVE', 'X')}


def table():
    t = {}
    for r in csv.reader(l for l in open(CSV) if not l.startswith('#')):
        t[(r[0], r[1])] = r[2:]
    return t


def num(x):
    try:
        return int(x)
    except ValueError:
        return 0 if x == '*' else None


def tails(log, T):
    """(op, column) -> the tail's error against the table."""
    meas = {}
    for l in open(log):
        m = re.match(r'TIMING (\S+)\s+(\S+)\s+total\s+(\d+)\s+tail\s+(\d+)\s+head\s+(\d+)', l)
        if m:
            meas[(m.group(1), m.group(2))] = tuple(int(x) for x in m.groups()[2:])
    d = {}
    for op in OPS:
        for col in CLASSES.values():
            if (op, col) in SKIP:
                continue
            src = BORROW.get((op, col), op)
            mv = meas.get((src, col))
            t = T.get(('FMOVE to FPn' if src == 'FMOVE' else src, col))
            if mv is not None and t is not None:
                d[(op, col)] = mv[1] - num(t[1])
    return d


def main(argv):
    mode = argv[0]
    text = open(UC).read()
    keep = re.findall(r'^\.tadj (?:cr|out\.\w+) -?\d+$', text, re.M)
    T = table()
    n = {}                                    # (op, column) -> N
    if mode == 'set':
        d0 = tails(argv[1], T)
        n = {k: -v for k, v in d0.items()}
    elif mode == 'refine':
        d0, d1 = tails(argv[1], T), tails(argv[2], T)
        for k, v in d0.items():
            n[k] = -v + max(d1.get(k, 0), 0)
            if d1.get(k, 0) > 0:
                print('path-bound: %s %s by %d' % (k[0], k[1], d1[k]))
    elif mode != 'zero':
        print(__doc__)
        return 1
    adj = {}
    for (op, col), v in n.items():
        kinds = [k for k, c in CLASSES.items() if c == col][0]
        for om in OPS[op]:
            adj[(kinds, om)] = v
    out = [
        "; t882.uc - Table 8-3's 68882 against the 68881's phases the microcode pads to",
        "; (SE30_PLAN.md 8.9.7, 7e-3): each instruction's clocks adjusted, by operation and",
        "; source class, so that with the table's typical operands (sim/fpu/tb_fpu_timing.v",
        "; +matrix: 3.0 into 2.25; 2.5 for FINT, 0.5 for the inverse functions, 7.25 for",
        "; FMOD and FREM; the MPU reading the response at once, UM 8.4) its head, tail and",
        "; total are the table's.  N < 0 starts the APU's elapsed count at -N; N > 0 is",
        "; added at END to whichever ends the instruction, its path or its budget.  The",
        "; classes: a register (reg), memory S, D and X (the same in every row), the",
        "; integers B, W and L, packed P.  Every other case keeps the 68881's difference from the",
        "; typical one.  Written by t882cal.py from a matrix; the cr and out.F lines by hand.",
        ";",
        ";            reg   S/D/X   B/W/L      P"]
    for op, modes in OPS.items():
        out.append('; %-8s %+5d %+6d %+6d %+6d' % (op, adj.get(('reg', modes[0]), 0),
                                                  adj.get(('S,D,X', modes[0]), 0), adj.get(('B,W,L', modes[0]), 0),
                                                  adj.get(('P', modes[0]), 0)))
    for op, modes in OPS.items():
        for om in modes:
            for kinds in CLASSES:
                n = adj.get((kinds, om), 0)
                if n:
                    out.append('.tadj %s $%02X %d' % (kinds, om, n))
    out.append('; the APU\'s own stores and the constant ROM (Table 8-3: FMOVE to memory L 110,')
    out.append('; P 2006; FMOVECR 32), measured the same way')
    out.extend(keep)
    open(UC, 'w', newline='\n').write('\n'.join(out) + '\n')
    print('wrote', UC)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
