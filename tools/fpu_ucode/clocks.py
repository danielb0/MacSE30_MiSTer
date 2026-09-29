"""The microcode's clocks against the manual's (plan 8.8.16, 8.8.19): a first
measure, before 6c's per-case padding.

    python clocks.py

For register-to-register vectors with normalized operands, extended PREC
and no exception, the min/max clocks per instruction next to the budget
from UM Section 8's detail tables: the FPm input conversion (Table 8-13,
14), the calculation (8-14, 8-15) and extended rounding (8-18, 6).  Our
clocks count from the entry to the END word.
"""

import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import vec                                                    # noqa: E402

# opmode: (name, calculation clocks, rounded)
BUDGET = {0x00: ('FMOVE', 2, True), 0x18: ('FABS', 4, True), 0x1A: ('FNEG', 4, True),
          0x22: ('FADD', 28, True), 0x28: ('FSUB', 28, True), 0x23: ('FMUL', 46, True),
          0x27: ('FSGLMUL', 34, False), 0x20: ('FDIV', 78, True), 0x24: ('FSGLDIV', 44, False),
          0x38: ('FCMP', 10, False), 0x3A: ('FTST', 8, False), 0x04: ('FSQRT', 76, True),
          0x01: ('FINT', 30, True), 0x03: ('FINTRZ', 30, True), 0x1E: ('FGETEXP', 20, True),
          0x1F: ('FGETMAN', 6, False), 0x26: ('FSCALE', 20, True),
          # Table 8-15, the transcendentals: FSIN, FCOS, FTAN and FSINCOS for
          # sources in (-9 ... +9), past which REM's time is added
          0x0E: ('FSIN', 360, True), 0x1D: ('FCOS', 360, True), 0x0F: ('FTAN', 442, True),
          0x30: ('FSINCOS', 420, True), 0x0A: ('FATAN', 372, True), 0x0C: ('FASIN', 550, True),
          0x1C: ('FACOS', 594, True), 0x10: ('FETOX', 466, True), 0x11: ('FTWOTOX', 536, True),
          0x12: ('FTENTOX', 536, True), 0x08: ('FETOXM1', 514, True), 0x14: ('FLOGN', 494, True),
          0x16: ('FLOG2', 550, True), 0x15: ('FLOG10', 550, True), 0x06: ('FLOGNP1', 540, True),
          0x02: ('FSINH', 656, True), 0x19: ('FCOSH', 576, True), 0x09: ('FTANH', 630, True),
          0x0D: ('FATANH', 662, True)}
TRIG = (0x0E, 0x1D, 0x0F, 0x30)
MONADIC = TRIG + (0x0A, 0x0C, 0x1C, 0x10, 0x11, 0x12, 0x08, 0x14, 0x16, 0x15, 0x06, 0x02,
                  0x19, 0x09, 0x0D, 0x00, 0x18, 0x1A, 0x3A, 0x04, 0x01, 0x03, 0x1E, 0x1F)


def main():
    r, labels = vec.load([os.path.join(HERE, 'ucode', 'fpu.uc')])
    chip = vec.Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'))
    clk = defaultdict(list)
    normal = lambda x: x.e not in (0, 0x7FFF) and x.m >> 63
    for line in open(os.path.join(HERE, '..', 'fpu_model', 'out', 'fpu.vec')):
        if line[0] == '#':
            continue
        v = vec.parse(line)
        if v[0] not in ('rounding', 'transcend') or v[1] != 'G' or (v[3] >> 6) & 3:
            continue
        op = v[2] & 0x7F
        if (v[2] >> 13) or op & 0x78 == 0x30 and op != 0x30 or op not in BUDGET:
            continue
        if not (normal(v[5]) and (op in MONADIC or normal(v[6]))):
            continue
        if op in TRIG and v[5].e - 16383 > 3 or op in TRIG and v[5].e - 16383 == 3 and v[5].m >= 9 << 60:
            continue
        try:
            got = vec.execute(chip, v)
        except vec.Unimplemented:
            continue
        if not got[3]:
            clk[op].append(got[7])
    print('%-8s %5s %5s %7s  %s' % ('', 'min', 'max', 'budget', 'over'))
    for op in sorted(clk, key=lambda o: BUDGET.get(o, ('?',))[0]):
        name, calc, rounded = BUDGET.get(op, ('$%02X' % op, 0, False))
        b = 14 + calc + (6 if rounded else 0)
        c = clk[op]
        over = max(c) - b
        print('%-8s %5d %5d %7d  %s' % (name, min(c), max(c), b, ('+%d' % over) if over > 0 else ''))


if __name__ == '__main__':
    main()
