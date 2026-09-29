"""The manual's clocks for one vector (plan 8.8.16, 8.8.19): what the
microcode's path, padded, must take - from the entry to the END word.

The figures are UM Section 8's detail tables (the 68881's, 8.5.2),
transcribed in Docs\\fpu\\UM_section8_timing_tables.md:

  a register destination: input conversion (Table 8-13, by the source's
      format and class, its sign for B/W/L, and the destination's class)
      + calculation (8-14 dyadic, 8-15 monadic, by the operation, the
      classes, the signs and the notes' conditions; the exception
      identifiers IOP and NAN1-NAN7 from 8-19)
      + rounding (8-18, by PREC and the outcome) where the calculation's
      figure carries "+";
  a store: output conversion (8-16, 8-17);
  FMOVECR: Table 8-15's 18 (extended) or 26 (single or double).

The case is chosen from the operands' classes and the model's own
rounding outcomes (rounding.TRACE): the model runs the vector again.
Where the tables are silent our reading is recorded here and in 8.8.19:

  - FPm and packed sources take the "Monadic or Dyadic" tables' row by the
    destination register's class for a monadic operation too; B/W/L, S, D
    and X monadic sources the in-memory monadic table.
  - An unnormalized or denormalized operand is "Normalized" in the
    calculation tables (Table 8-13's "not normalized" time converted it).
  - FDIV's "denormalized" and FMUL's "not normalized" intermediate: the
    result tiny (it is what rounding.py calls it).
  - A domain error from a normalized source where Table 8-15 names no
    exception (FASIN, FACOS, FATANH beyond 1, FATANH at +/-1): IOP, as
    note 4 does for FLOGNP1 <= -1.
  - Table 8-18's extended "round overflow (not caused by rounding)": an
    overflow whose rounding also carried; "(caused by rounding)": an
    overflow only the carry made.  For single and double "round
    overflow" is the carry.  A zero result: 6.
  - FSIN, FCOS, FTAN, FSINCOS outside (-9, +9) add FREM's time by 2pi
    (exponent 2): 40 + 70 INT((1 + E - 2)/64).
  - FMOD and FREM's "quotient is zero": the model's quotient.
  - FSINCOS's "+": the sine's rounding.
  - Packed decimal: the typical figures, 822 in and 1,942 out (+14 for a
    dynamic k-factor, Table 8-3's note) - Daniel's rule, 8.8.16.

spec(v) returns (clocks, case, own) or None where the microcode's clocks
are not the tables' (the conditionals and the F-line decodes: the BIU's).
`own`: the figure is a floor - the instruction pads to it, and where our
algorithm needs longer takes its own time (Daniel's packed decimal rule,
8.8.16, carried to the other data-dependent figures; 8.8.19):

  - FMOD, FREM and the large-argument reduction of FSIN, FCOS, FTAN and
    FSINCOS: the formula counts whole 64-bit chunks of quotient; the last,
    partial chunk runs a bit a clock;
  - FSGLDIV with its OVFL or UNFL trap enabled and the result over- or
    underflowing (or at the largest exponent, where the rounding may
    overflow it): the exceptional operand needs FDIV's 64-bit quotient;
  - FINT, FINTRZ with a result that overflows the rounding precision
    (Table 8-15's figures carry no rounding time);
  - packed decimal, in and out: the typical figures.
"""

import os
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))
import rounding                                               # noqa: E402
import vectors                                                # noqa: E402
from fpu import FPU                                           # noqa: E402
from xreal import BIAS, EMAX                                  # noqa: E402

N, U, Z, I, NAN = 'N', 'U', 'Z', 'I', 'NaN'
FMT_NAMES = ['L', 'S', 'X', 'P', 'W', 'D', 'B', 'PK']
RN, RZ, RM, RP = 0, 1, 2, 3


def cls(x):
    """Table 8-13's class of an extended value."""
    if x.e == EMAX:
        return NAN if x.m & ((1 << 63) - 1) else I
    if x.m == 0:
        return Z
    return N if x.m >> 63 else U


def denorm(x):
    return x.e == 0 and x.m != 0 and not x.m >> 63


def snan(x):
    return cls(x) == NAN and not (x.m >> 62) & 1


# -- Table 8-13: input conversion --------------------------------------------------------

ROW = {N: 0, U: 12, Z: 6, I: 4, NAN: 6}           # the destination's class, every sub-table
DYADIC = {'L': {N: (24, 26), Z: 22},
          'S': {N: 18, U: 36, Z: 22, I: 24, NAN: 26},
          'D': {N: 16, U: 34, Z: 20, I: 22, NAN: 24},
          'X': {N: 10, U: 26, Z: 12, I: 12, NAN: 14},
          'reg': {N: 14, U: 30, Z: 16, I: 16, NAN: 18}}
MONADIC_MEM = {'L': {N: (22, 24), Z: 20},
               'S': {N: 16, U: 30, Z: 20, I: 24, NAN: 24},
               'D': {N: 14, U: 28, Z: 18, I: 22, NAN: 22},
               'X': {N: 8, U: 20, Z: 10, I: 12, NAN: 12}}
PACKED_ROW = {N: 0, U: 26, Z: 20, I: 18, NAN: 20}  # a nonzero finite packed source


def conversion(fmt, s, sneg, d, monadic):
    if fmt == 'P':
        if s in (N, U):
            return 822 + PACKED_ROW[d]
        return (24 if s == NAN else 22) + ROW[d]
    f = 'L' if fmt in ('B', 'W', 'L') else fmt
    if monadic and f != 'reg':
        t = MONADIC_MEM[f][s]
        return t[sneg] if isinstance(t, tuple) else t
    t = DYADIC[f][s]
    return (t[sneg] if isinstance(t, tuple) else t) + ROW[d]


# -- Table 8-19: the exception identifiers -----------------------------------------------

def exc_time(ident, src, dst):
    """src/dst: the operands (the one a NAN2/4-7 names is whichever is the NaN)."""
    if ident == 'IOP':
        return 32 if denorm(src) else 20
    if ident == 'NAN1':                              # the destination a NaN
        return (30 if snan(dst) else 28) + (24 if denorm(src) else 0)
    if ident == 'NAN3':
        return {(False, False): 28, (False, True): 30, (True, False): 32, (True, True): 30}[
            (snan(src), snan(dst))]
    nan = src if cls(src) == NAN else dst
    base = {'NAN2': 28, 'NAN4': 30, 'NAN5': 8, 'NAN6': 38, 'NAN7': 22}[ident]
    return base + (2 if snan(nan) else 0)


# -- Table 8-14: the dyadic operations ---------------------------------------------------
# A cell: an int, 'X+' (the note's figure, rounding added), an int with '+',
# ('s', a, b) by the source's sign, ('d', a, b) by the destination's,
# ('ds', (a, b), (c, d)) by both (destination +: (source +, source -)),
# or an exception identifier.  Rows: destination N, Z, I, NaN; columns:
# source N, Z, I, NaN.

def _grid(nn, nz, ni, zn, zz, zi, in_, iz, ii, nan_row=('NAN1', 'NAN2', 'NAN2', 'NAN3'), col_nan='NAN2'):
    return {N: {N: nn, Z: nz, I: ni, NAN: col_nan}, Z: {N: zn, Z: zz, I: zi, NAN: col_nan},
            I: {N: in_, Z: iz, I: ii, NAN: col_nan}, NAN: dict(zip((N, Z, I, NAN), nan_row))}


S68 = ('s', 6, 8)
D68 = ('d', 6, 8)
DYADIC_OPS = {
    'FADD': _grid('ADD', '2+', 6, '2+', ('ds', (6, 26), (26, 6)), 6, 6, 6, ('ds', (6, 20), (20, 6))),
    'FSUB': _grid('SUB', '2+', 8, '4+', ('ds', (26, 8), (8, 26)), 8, 6, 6, ('ds', (20, 8), (8, 20))),
    'FCMP': _grid(('ds', ('CMP', 6), (6, 'CMP')), 6, ('ds', (8, 6), (6, 8)),
                  ('ds', (8, 6), (6, 8)), 6, ('ds', (8, 6), (6, 8)), 6, 6, 6, col_nan='NAN4'),
    'FDIV': _grid('DIV', 20, ('ds', (6, 8), (8, 6)), S68, 20, S68, S68, S68, 20),
    'FSGLDIV': _grid('SGLDIV', 20, ('ds', (6, 8), (8, 6)), S68, 20, S68, S68, S68, 20),
    'FMOD': _grid('MOD', 20, '6+', '6+', 20, '6+', 'IOP', 20, 20),
    'FREM': _grid('REM', 20, '6+', '6+', 20, '6+', 'IOP', 20, 20),
    'FMUL': _grid('MUL', D68, D68, S68, S68, 20, S68, 20, S68),
    'FSGLMUL': _grid('SGLMUL', D68, D68, S68, S68, 20, S68, 20, S68),
    'FSCALE': _grid('SCALE', '6+', 20, 6, 6, 20, 6, 6, 20),
}

# -- Table 8-15: the monadic operations --------------------------------------------------
# Columns N, Z, I, NaN; ('p', ext, sgl/dbl) by the rounding precision (notes
# 1, 2); ('s', a, b) by the source's sign; strings with '+' add rounding.

MONADIC_OPS = {
    'FABS': ('4+', '4+', 8, 'NAN2'), 'FNEG': ('4+', '4+', 8, 'NAN2'),
    'FACOS': ('594+', ('p', 12, 20), 20, 'NAN2'), 'FASIN': ('550+', 6, 20, 'NAN2'),
    'FATAN': ('372+', 6, ('s', ('p', 12, 20), ('p', 14, 22)), 'NAN2'),
    'FATANH': ('662+', 6, 20, 'NAN2'), 'FCOS': ('360+', 8, 20, 'NAN2'),
    'FCOSH': ('576+', 8, 8, 'NAN2'), 'FETOX': ('466+', 8, 6, 'NAN2'),
    'FETOXM1': ('514+', 6, S68, 'NAN2'), 'FGETEXP': ('GETEXP', 6, 20, 'NAN2'),
    'FGETMAN': (6, 6, 20, 'NAN2'), 'FINT': ('INT', 6, 60, 'NAN2'), 'FINTRZ': ('INT', 6, 60, 'NAN2'),
    'FLOGN': (('s', '494+', 'IOP'), 22, ('s', 6, 20), 'NAN2'),
    'FLOGNP1': ('540+', 6, ('s', 6, 20), 'NAN2'),
    'FLOG10': (('s', '550+', 'IOP'), 22, ('s', 6, 20), 'NAN2'),
    'FLOG2': (('s', '550+', 'IOP'), 22, ('s', 6, 20), 'NAN2'),
    'FMOVE': ('2+', 6, 6, 'NAN2'), 'FSIN': ('360+', 6, 20, 'NAN2'),
    'FSINCOS': ('420+', 20, 26, 'NAN6'), 'FSINH': ('656+', 6, 6, 'NAN2'),
    'FSQRT': (('s', '76+', 'IOP'), 6, ('s', 6, 20), 'NAN2'), 'FTAN': ('442+', 6, 20, 'NAN2'),
    'FTANH': ('630+', 6, 8, 'NAN2'), 'FTENTOX': ('536+', 8, 6, 'NAN2'),
    'FTST': (8, 8, 8, 'NAN5'), 'FTWOTOX': ('536+', 8, 6, 'NAN2'),
}
TRIG = ('FSIN', 'FCOS', 'FTAN', 'FSINCOS')
# a domain error from a normalized source (our reading: IOP)
DOMAIN = {'FASIN', 'FACOS', 'FATANH', 'FLOGNP1'}

OPNAMES = {0x00: 'FMOVE', 0x01: 'FINT', 0x02: 'FSINH', 0x03: 'FINTRZ', 0x04: 'FSQRT',
           0x06: 'FLOGNP1', 0x08: 'FETOXM1', 0x09: 'FTANH', 0x0A: 'FATAN', 0x0C: 'FASIN',
           0x0D: 'FATANH', 0x0E: 'FSIN', 0x0F: 'FTAN', 0x10: 'FETOX', 0x11: 'FTWOTOX',
           0x12: 'FTENTOX', 0x14: 'FLOGN', 0x15: 'FLOG10', 0x16: 'FLOG2', 0x18: 'FABS',
           0x19: 'FCOSH', 0x1A: 'FNEG', 0x1C: 'FACOS', 0x1D: 'FCOS', 0x1E: 'FGETEXP',
           0x1F: 'FGETMAN', 0x20: 'FDIV', 0x21: 'FMOD', 0x22: 'FADD', 0x23: 'FMUL',
           0x24: 'FSGLDIV', 0x25: 'FREM', 0x26: 'FSCALE', 0x27: 'FSGLMUL', 0x28: 'FSUB',
           0x38: 'FCMP', 0x3A: 'FTST'}
for _k in range(0x30, 0x38):
    OPNAMES[_k] = 'FSINCOS'


# -- Table 8-18: rounding ----------------------------------------------------------------

def round_time(prec, o, rnd):
    """o: rounding.TRACE's record, or None for an exact zero result (a tiny
    result rounded to zero is an underflow)."""
    mrm = rnd in (RM, RP)
    if prec == 0:
        if o is None:
            return 6, 'zero'
        if o['tiny']:
            return 34, 'unfl'
        if o['ovfl']:
            if o['by_round']:
                return 22 if mrm else 20, 'ovfl by rounding'
            if o['carry']:
                return 18 if mrm else 16, 'ovfl, carried'
            return 16 if mrm else 14, 'ovfl'
        return 6, 'normal'
    if o is None:
        return 6, 'zero'
    c = o['carry']
    if o['tiny']:
        return (60 if c else 56), 'unfl'
    if o['ovfl']:
        return (32 if mrm else 30) + (4 if c else 0), 'ovfl'
    return (28 if c else 24), 'carry' if c else 'normal'


# -- Tables 8-16 and 8-17: stores --------------------------------------------------------

def store_time(fmt, x, o, operr, rnd, dynk):
    c = cls(x)
    neg = x.s
    if fmt in ('B', 'W', 'L'):
        if c == Z:
            return 18
        if c == NAN:
            return 24
        if c == I:
            return 26 if neg else 24
        if c == N:
            return (56 if neg else 52) if operr else (52 if neg else 50)
        return (66 if neg else 62) if operr else (62 if neg else 60)
    if fmt in ('S', 'D'):
        if c == Z:
            return 16
        if c == I:
            return 18
        if c == NAN:
            return exc_time('NAN7', x, x)
        base = 38 if c == N else 48
        if o is None or o['zero'] and not o['tiny']:
            return base
        k = o['carry']
        if o['tiny']:
            return base + 28 + (4 if k else 0)
        if o['ovfl']:
            return base + (8 if rnd in (RM, RP) else 6) + (4 if k else 0)
        return base + (4 if k else 0)
    if fmt == 'X':
        if c in (Z, I):
            return 16
        if c == NAN:
            return exc_time('NAN7', x, x)
        if c == N:
            return 18
        return 56 if denorm(x) else 26
    # packed
    if c in (Z, I):
        return 24
    if c == NAN:
        return exc_time('NAN2', x, x)
    return 1942 + (14 if dynk else 0)


# -- one vector ----------------------------------------------------------------------------

def _run(v):
    """The model on the vector again, recording its roundings."""
    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, _ = v
    rounding.TRACE = []
    try:
        vectors.execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg)
        return rounding.TRACE
    finally:
        rounding.TRACE = None


def _source(fmt, operand, rnd):
    f = FPU()
    code = FMT_NAMES.index(fmt)
    return f.convert_in(code, operand)[0]


def _cell(cell, s, d, prec):
    """Resolve the sign and precision splits of a table cell."""
    while isinstance(cell, tuple):
        if cell[0] == 's':
            cell = cell[2] if s.s else cell[1]
        elif cell[0] == 'd':
            cell = cell[2] if d.s else cell[1]
        elif cell[0] == 'p':
            cell = cell[1] if prec == 0 else cell[2]
        else:                                          # 'ds'
            pair = cell[2] if d.s else cell[1]
            cell = pair[1] if s.s else pair[0]
    return cell


def spec(v):
    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, expect = v
    if kind == 'C':
        return None
    opclass = cmd >> 13
    rxf = (cmd >> 10) & 7
    ext = cmd & 0x7F
    prec = (fpcr >> 6) & 3
    prec = 0 if prec == 3 else prec
    rnd = (fpcr >> 4) & 3
    fpsr_out = expect[2]
    if opclass == 3:
        fmt = FMT_NAMES[rxf]
        src = _src_reg(v, (cmd >> 7) & 7)
        trace = [t for t in _run(v) if t['dest'] == 'mem']
        o = trace[-1] if trace else None
        dynk = fmt == 'PK'
        f = 'P' if fmt == 'PK' else fmt
        return (store_time(f, src, o, bool(fpsr_out & (1 << 13)), rnd, dynk), 'out.%s %s' % (fmt, cls(src)),
                f == 'P' and cls(src) in (N, U))
    if opclass == 2 and rxf == 7:
        if ext >= 0x40:
            return None
        return (18 if prec == 0 else 26), 'fmovecr', False
    if opclass not in (0, 2) or ext >= 0x40 and not (opclass == 2 and rxf == 7):
        return None
    op = OPNAMES.get(ext) or OPNAMES.get(FPU.REDUNDANT.get(ext, -1))
    if op is None:
        return None
    monadic = op in MONADIC_OPS
    if opclass == 0:
        fmt, src = 'reg', _src_reg(v, rxf)
    else:
        fmt = FMT_NAMES[rxf]
        src = _source(fmt, operand, rnd)
    dst = ry
    s, d = cls(src), cls(dst)
    if fmt in ('S', 'D'):
        s = _ieee_cls(fmt, operand)                    # Table 8-13 classes it in its own format
    t_conv = conversion(fmt, s, src.s, d, monadic)
    trace = [t for t in _run(v) if t['dest'] == 'reg']
    # the operand classes the calculation sees
    sc = N if s == U else s
    dc = N if d == U else d
    plus, case, own = False, '', fmt == 'P'
    if monadic:
        cell = _cell(MONADIC_OPS[op][(N, Z, I, NAN).index(sc)], src, dst, prec)
        if isinstance(cell, str) and cell.endswith('+') and cell[:-1].isdigit():
            calc, plus = int(cell[:-1]), True
            if op in DOMAIN and fpsr_out & ((1 << 13) | (1 << 10)):   # OPERR or DZ
                calc, plus = exc_time('IOP', src, dst), False
            elif op in TRIG and _abs_ge9(src):
                own = True
                e = _exp(src)
                calc += 40 + 70 * ((1 + e - 2) // 64)
        elif cell == 'GETEXP':
            e = _exp(src)
            calc = 16 if e == 0 else (20 if e > 0 else 22)
        elif cell == 'INT':
            calc = _fint_time(src, expect[0])
            own = any(t['ovfl'] for t in trace)
        elif isinstance(cell, str) and cell.startswith(('IOP', 'NAN')):
            calc = exc_time(cell, src, dst)
        else:
            calc = int(cell)
        case = '%s %s' % (op, sc)
    else:
        cell = _cell(DYADIC_OPS[op][dc][sc], src, dst, prec)
        if isinstance(cell, str) and cell.startswith(('IOP', 'NAN')):
            calc = exc_time(cell, src, dst)
        elif cell in ('ADD', 'SUB'):
            es, ed = _exp(src), _exp(dst)
            ms, md = _mant(src), _mant(dst)
            calc = 28 if es != ed else (24 if ms < md else 26)
            plus = True
        elif cell == 'CMP':
            calc = 8 if _exp(src) > _exp(dst) else 10
        elif cell in ('DIV', 'MUL'):
            o = trace[-1] if trace else None
            calc = (78 if cell == 'DIV' else 46) + (2 if o is not None and o['tiny'] else 0)
            plus = True
        elif cell in ('SGLDIV', 'SGLMUL'):
            o = trace[-1] if trace else None
            if cell == 'SGLDIV':
                en = fpcr >> 8
                top = cls(expect[0]) == N and expect[0].e == EMAX - 1
                own = bool(en & 0x10 and (o is not None and o['ovfl'] or top)
                           or en & 0x08 and o is not None and o['tiny'])
            if o is not None and o['tiny']:
                calc = 90 if cell == 'SGLDIV' else 80
            elif o is not None and o['ovfl']:
                calc = 62 if cell == 'SGLDIV' else 52
            else:
                calc = 44 if cell == 'SGLDIV' else 34
        elif cell in ('MOD', 'REM'):
            own = True
            if _quotient(src, dst, cell == 'REM') == 0:
                calc = 18
            else:
                calc = 40 + 70 * ((1 + _exp(dst) - _exp(src)) // 64)
            plus = True
        elif cell == 'SCALE':
            e = _exp(src)
            calc = 12 if e < 0 else (16 if e <= 15 else 20)
            plus = True
        elif isinstance(cell, str) and cell.endswith('+'):
            calc, plus = int(cell[:-1]), True
        else:
            calc = int(cell)
        case = '%s %s,%s' % (op, sc, dc)
    total = t_conv + calc
    if plus:
        o = trace[0] if op == 'FSINCOS' and trace else (trace[-1] if trace else None)
        r, rcase = round_time(prec, o, rnd)
        total += r
        case += ' +' + rcase
    return total, case, own


def _ieee_cls(fmt, raw):
    """A single or double operand's class in its own format: a denormal
    there is "not normalized" though extended holds it normalized."""
    eb, fb = (8, 23) if fmt == 'S' else (11, 52)
    e = (raw >> fb) & ((1 << eb) - 1)
    f = raw & ((1 << fb) - 1)
    if e == (1 << eb) - 1:
        return NAN if f else I
    if e == 0:
        return U if f else Z
    return N


def _src_reg(v, n):
    rx, ry, rc = v[5], v[6], v[7]
    return {vectors.RX: rx, vectors.RY: ry, vectors.RC: rc}[n]


def _exp(x):
    """The unbiased exponent of a nonzero finite value, normalized."""
    s, m, e = x.exact()
    return m.bit_length() - 1 + e


def _mant(x):
    return x.m << (64 - x.m.bit_length())


def _abs_ge9(x):
    s, m, e = x.exact()
    return Fraction(m) * Fraction(2) ** e >= 9


def _quotient(src, dst, nearest):
    s_, ms, es = src.exact()
    d_, md, ed = dst.exact()
    q = Fraction(md) * Fraction(2) ** ed / (Fraction(ms) * Fraction(2) ** es)
    if nearest:
        n = int(q)
        r = q - n
        if r > Fraction(1, 2) or r == Fraction(1, 2) and n & 1:
            n += 1
        return n
    return int(q)


def _fint_time(src, result):
    s, m, e = src.exact()
    if cls(result) == Z:
        return 28
    return 8 if e >= 0 or not m & ((1 << -e) - 1) else 30
