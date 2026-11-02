"""ftime.py - reads tb_cpfpu's run.log from PROG=ftime (FUTURE ADDITIONS 13):
the MPU's clocks per FPU instruction, against the MC68881/882 UM's
figures for an MC68020 on the same clock (Section 8; sim/fpu/table8_3.csv).

    python ftime.py [run.log]

'iso': one instruction with the FPU idle (each loop: I1, pad, I2, pad,
against the pad-only loop) - the MPU's time. 'str': eight back to back
(against the pad-only loop) - the throughput. Per instruction: clocks,
CIR cycles, clocks with AS* low on CIR cycles, response reads, come-agains.
"""
import re
import sys

ITER = 32
# case: (name, kind, the 68020's clocks, where from). iso: the MPU's time -
# Table 8-3's total less its tail (the MPU released), the cache case for the
# conditionals (Table 8-7); EA times from Table 8-1's cache case
CASES = {
    1:  ('FNOP', 'iso', 18, 'T8-7 cache'),
    2:  ('FADD/FSUB.X FPm,FPn', 'iso', 18, 'T8-9 14 + T8-10 4 (6 overlap)'),
    3:  ('FMUL.X FPm,FPn', 'iso', 18, 'as FADD'),
    4:  ('FMOVE.X FPm,FPn', 'iso', 18, 'as FADD'),
    5:  ('FMOVE.L Dn,FPn', 'iso', 35, 'T8-3 48-8, Dn -5 (T8-11)'),
    6:  ('FMOVE.L FPn,Dn', 'iso', 108, 'T8-3 110, Dn -2 (T8-11)'),
    7:  ('FMOVE.D (An),FPn', 'iso', 42, 'T8-3 40 (head) + (An) 2'),
    8:  ('FMOVE.D FPn,(An)', 'iso', 46, 'T8-3 44 + (An) 2'),
    9:  ('FMOVE.X (An),FPn', 'iso', 48, 'T8-3 46 (head) + (An) 2'),
    10: ('FMOVE.X FPn,(An)', 'iso', 52, 'T8-3 50 + (An) 2'),
    11: ('FADD/FSUB.D (An),FPn', 'iso', 39, 'T8-3 75-38 + (An) 2'),
    12: ('FADD/FSUB.L Dn,FPn', 'iso', 35, 'T8-3 94-54, Dn -5'),
    13: ('FTST.X FPn', 'iso', 18, 'as FADD'),
    14: ('FBEQ.W not taken', 'iso', 18, 'T8-7 cache'),
    15: ('FBNE.W taken', 'iso', 20, 'T8-7 cache'),
    16: ('FCMP.X FPm,FPn', 'iso', 18, 'as FADD'),
    21: ('FNOP', 'str', None, ''),
    22: ('FADD/FSUB.X FPm,FPn', 'str', 39, 'T8-3 56 - head 17'),
    23: ('FMUL.X FPm,FPn', 'str', 59, 'T8-3 76 - head 17'),
    24: ('FMOVE.X FPm,FPn', 'str', None, ''),
    27: ('FMOVE.D (An),FPn', 'str', None, ''),
    28: ('FMOVE.D FPn,(An)', 'str', None, ''),
    31: ('FADD/FSUB.D (An),FPn', 'str', 39, 'T8-3 75 - head 36'),
    33: ('FTST.X FPn', 'str', 21, 'T8-3 36 - tail 15'),
}

log = sys.argv[1] if len(sys.argv) > 1 else 'run.log'
marks = []
for ln in open(log, errors='replace'):
    m = re.search(r'TMARK (\d+) clk (\d+) cir (\d+) circlk (\d+) resp (\d+) ca (\d+)', ln)
    if m:
        marks.append(tuple(int(x) for x in m.groups()))
span = {}
for (n, *v), (_, *w) in zip(marks, marks[1:]):
    span[n] = [b - a for a, b in zip(v, w)]
ref = {'iso': span[100], 'str': span[300]}
print('%-24s %4s %8s %6s %6s %5s %5s %7s  %s' % ('instruction', '', 'clocks', 'CIR', 'CIRclk', 'resp', 'CA', '68020', 'from'))
for n, (name, kind, r020, src) in CASES.items():
    if n not in span:
        continue
    k = 2 * ITER if kind == 'iso' else 8 * ITER
    d = [(x - y) / k for x, y in zip(span[n], ref[kind])]
    d[1:] = [x for x in d[1:]]
    print('%-24s %4s %8.1f %6.2f %6.1f %5.2f %5.2f %7s  %s' % (name, kind, d[0], d[1], d[2], d[3], d[4],
                                                           '' if r020 is None else r020, src))
print('pad-only loop: %.1f clocks an iteration (iso), %.1f (str)' % (span[100][0] / ITER, span[300][0] / ITER))
