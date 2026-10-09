"""The 68882 microcode assembler.

Source to the four ROM images - the µROM (4,096 x 49), the
nROM (1,024 nanowords), the entry table (1,024 x 11) and the constant ROM
(consts.py) - with a listing, a symbol file and a Verilog header, and the
checks that make the images safe to run:
  - capacity (µROM, nROM, constant names and addresses, temporaries);
  - every target defined, every dispatch table aligned and complete,
    no fall-through off the end of the code;
  - the µPC stack: no recursion, calls nested at most four deep;
  - checkpoints: only T0-T10 live after one, Q, MD and MD3 dead,
    by liveness over the whole program (context-insensitive, so it can
    only err towards reporting too much);
  - the entry table: every index filled.

THE SOURCE.  One microinstruction a line; `;` starts a comment.

    label:  d=T3 a=T1 b=T2>>SC alu=sub stk=shift | if N goto neg

Datapath clauses (any order; what is not said is the nanoword's default -
nothing selected, nothing written, flags held):
    a=Tn | FP[sel] | CU | 0
    b=Tn | K[name] | K[name+n] | K[name+LC] | K[name-n+LC] | FP[sel] | OPINT | OPRAW | CU
      | BOOTH | RINC | RMASK | SQT | Q | SC | LC | CMD | 0
      with an optional shift: <<amt (left), >>amt (logical), >>>amt
      (arithmetic); amt = a number, SC, LC, LZC, LC+SC or LC-SC
    d=Tn | FP[sel] | MD | MD3 | OBUFH | OBUFL | OBUFX | EXOP | SC | -
    alu= mode= dir= cin= osh= q= sign= stk= dl= a2= bx= rnd= fpsr= ctl=  (fields.py's names,
      any case)
    lc=hold|dec|alu|<number>     exc=OPERR,DZ,...  (ORed into lit)    lit=<number>
    budget=N | rbudget=N   (ctl=BUDGET/RBUDGET, lit = N/2: N even, 0 to 510)
    rtime=ROW              (ctl=RTIME, lit = fields.RROW: Table 8-18's row)
    sel = src | dst | c | ra
Sequencing, after `|` (default: next):
    next | goto L | call L | ret | if C goto L | unless C goto L
    | dispatch KEY L | wait N | budget N | waitb [N]   (fields.WAITMODE)
Directives:
    .include "file"          .org N           .align N        .export label
    .table NAME KEY [cu|hold]  (entries until .end: `SRC DST label` for TAGPAIR,
                              `VALUE label` otherwise, `*` a wildcard,
                              `default label`; `KEYS :: microinstruction`
                              puts the word in the slot (it must end in
                              goto or dispatch); an OPMODE table's
                              `redundant model` copies switches.py item 6's
                              opmodes from their bases, as .redundant does)
                             `cu` (TAGPAIR, inline words): the
                              conversion the 68882's CU does - each word's
                              budget=N leaves the microword for the CU's
                              table (ucode.cvt.hex), the CU spending it
                              before the hand-off; `hold`: the APU keeps it,
                              and the same N is how long the MPU is held
                              (an integer source)
    .entry KINDS OPMODE label    KINDS: reg, L S X P W D B, `*`, comma lists
    .entry cr label          .entry out.F label      .entry default label
    .tadj KINDS OPMODE N | cr N | out.F N   a signed adjustment of the
                              instruction's clocks, for the entries .entry's
                              KINDS OPMODE name: the APU starts with budget N
                              (N > 0) or its elapsed count at -N (N < 0) -
                              Table 8-3's 68882 against the 68881's phases
    .redundant model         (the redundant opmodes as the model decodes
                              them)
Numbers: decimal, $hex or 0xhex.
"""

import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

import fields as FD
import consts

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fpu_model'))


class AsmError(Exception):
    pass


def num(s):
    s = s.strip()
    if s.startswith('$'):
        return int(s[1:], 16)
    return int(s, 0)


class Loc:
    def __init__(self, path, line, text):
        self.path, self.line, self.text = path, line, text

    def __str__(self):
        return '%s:%d' % (os.path.basename(self.path), self.line)


class UInstr:
    def __init__(self, loc):
        self.loc = loc
        self.nano = OrderedDict()           # field -> enum name or int
        self.ra = self.rb = self.rd = 0
        self.seq = 'NEXT'
        self.cond = 0                       # int (COND or DISPATCH code)
        self.target = None                  # label, int, or None
        self.addr = None
        self.table_of = None                # set for a table's jump words
        self.kname = None                   # the named constant read, if any

    def setn(self, field, value, what):
        old = self.nano.get(field)
        if old is not None and old != value:
            raise AsmError('%s: %s: %s wants %s=%s, already %s' % (self.loc, what, field, field, value, old))
        self.nano[field] = value


class Table:
    def __init__(self, name, key, loc):
        self.name, self.key, self.loc = name, key, loc
        self.bits = FD.DISPATCH_BITS[key]
        self.entries = {}
        self.default = None
        self.redundant = False
        self.addr = None
        self.kind = ''                      # '', 'cu' or 'hold'
        self.cvid = 0                       # its number in ucode.cvt.hex


class Program:
    def __init__(self):
        self.code = []                      # UInstr in source order (with .org/.align markers)
        self.layout_ops = []                # ('instr', UInstr) | ('org', n) | ('align', n)
        self.labels = {}                    # name -> ('code', UInstr) | ('table', Table) | ('pending',)
        self.pending_labels = []
        self.tables = OrderedDict()
        self.entries = {}                   # index -> (label, loc)
        self.entry_default = None
        self.tadj = {}                      # entry index -> (N, loc)
        self.redundant = False
        self.exports = []
        self.warnings = []


# -- parsing ------------------------------------------------------------------------

FP_SEL = {'src': 'SRC', 'dst': 'DST', 'c': 'C', 'ra': 'RA'}
SHIFT_RE = re.compile(r'^(.*?)(<<|>>>|>>)(.+)$')
AMOUNTS = {'SC': 'SC', 'LC': 'LC', 'LZC': 'LZC', 'LC+SC': 'LCPSC', 'LC-SC': 'LCMSC'}
PLAIN_B = {'OPINT', 'OPRAW', 'CU', 'BOOTH', 'RINC', 'RMASK', 'SQT', 'Q', 'SC', 'LC', 'CMD'}
DST_NAMED = {'MD', 'MD3', 'OBUFH', 'OBUFL', 'OBUFX', 'EXOP', 'SC'}
ENUM_CLAUSES = {'bx': ('bx', FD.BX), 'alu': ('alu', FD.ALU), 'mode': ('emode', FD.EMODE), 'dir': ('dir', FD.DIR),
                'osh': ('osh', FD.OSH), 'q': ('qop', FD.QOP), 'sign': ('sgn', FD.SGN),
                'stk': ('stk', FD.STK), 'rnd': ('rnd', FD.RNDM), 'fpsr': ('fpsr', FD.FPSR),
                'ctl': ('ctl', FD.CTL)}


def _temp(s, loc):
    m = re.match(r'^T(\d+)$', s, re.I)
    if not m:
        return None
    n = int(m.group(1))
    if n >= FD.TEMPS:
        raise AsmError('%s: T%d: there are %d temporaries' % (loc, n, FD.TEMPS))
    return n


def _fp(u, s, loc, what):
    m = re.match(r'^FP\[(\w+)\]$', s, re.I)
    if not m:
        return False
    sel = FP_SEL.get(m.group(1).lower())
    if sel is None:
        raise AsmError('%s: %s: FP[%s]: the selector is src, dst, c or ra' % (loc, what, m.group(1)))
    u.setn('fpsel', sel, what)
    return True


def _lit(u, value, what):
    if not 0 <= value <= 0xFF:
        raise AsmError('%s: %s: literal %d does not fit 8 bits' % (u.loc, what, value))
    u.setn('lit', value, what)


def parse_a(u, v):
    t = _temp(v, u.loc)
    if t is not None:
        u.setn('asrc', 'T', 'a'); u.ra = t
    elif _fp(u, v, u.loc, 'a'):
        u.setn('asrc', 'FP', 'a')
    elif v.upper() == 'CU':
        u.setn('asrc', 'CU', 'a')
    elif v == '0':
        u.setn('asrc', 'ZERO', 'a')
    else:
        raise AsmError('%s: a=%s: not an A source' % (u.loc, v))


def parse_b(u, v, knames):
    m = SHIFT_RE.match(v)
    if m:
        base, op, amt = m.group(1), m.group(2), m.group(3)
        u.setn('shk', {'<<': 'LSL', '>>': 'LSR', '>>>': 'ASR'}[op], 'b')
        a = AMOUNTS.get(amt.upper())
        if a is not None:
            u.setn('sha', a, 'b')
        else:
            try:
                n = num(amt)
            except ValueError:
                raise AsmError('%s: b=%s: shift amount %r' % (u.loc, v, amt))
            if not 0 <= n <= 127:
                raise AsmError('%s: b=%s: shift amount %d outside 0-127' % (u.loc, v, n))
            u.setn('sha', 'LIT', 'b')
            _lit(u, n, 'b')
    else:
        base = v
    t = _temp(base, u.loc)
    if t is not None:
        u.setn('bsrc', 'T', 'b'); u.rb = t
        return
    if _fp(u, base, u.loc, 'b'):
        u.setn('bsrc', 'FP', 'b')
        return
    km = re.match(r'^K\[([\w$]+)(?:-(\d+))?(?:\+([\w$]+))?\]$', base, re.I)
    if km:
        name, back, off = km.group(1).lower(), km.group(2), km.group(3)
        if name[0] == '$' or name[0].isdigit():
            addr = num(name)
        elif name in knames:
            addr = knames[name]
            u.kname = name
        else:
            raise AsmError('%s: K[%s]: no such constant (consts.py)' % (u.loc, name))
        if back is not None:                            # a table read one entry behind LC
            if off is None or off.upper() != 'LC':
                raise AsmError('%s: K[%s]: name-n only before +LC' % (u.loc, base))
            addr -= int(back)
        if off is not None and off.upper() == 'LC':
            u.setn('bsrc', 'KLC', 'b')
        else:
            u.setn('bsrc', 'K', 'b')
            addr += num(off) if off is not None else 0
        if not 0 <= addr < FD.KROM_WORDS:
            raise AsmError('%s: K[%s]: address $%X outside the ROM' % (u.loc, base, addr))
        u.rb = addr
        return
    if base.upper() in PLAIN_B:
        u.setn('bsrc', base.upper(), 'b')
        return
    if base == '0':
        u.setn('bsrc', 'ZERO', 'b')
        return
    raise AsmError('%s: b=%s: not a B source' % (u.loc, v))


def parse_d(u, v):
    t = _temp(v, u.loc)
    if t is not None:
        u.setn('dst', 'T', 'd'); u.rd = t
    elif _fp(u, v, u.loc, 'd'):
        u.setn('dst', 'FP', 'd')
    elif v.upper() in DST_NAMED:
        u.setn('dst', v.upper(), 'd')
    elif v == '-':
        u.setn('dst', 'NONE', 'd')
    else:
        raise AsmError('%s: d=%s: not a destination' % (u.loc, v))


def parse_clause(u, c, knames):
    if '=' not in c:
        raise AsmError('%s: %r: expected name=value' % (u.loc, c))
    k, v = c.split('=', 1)
    k = k.lower()
    if k == 'a':
        parse_a(u, v)
    elif k == 'b':
        parse_b(u, v, knames)
    elif k == 'd':
        parse_d(u, v)
    elif k in ENUM_CLAUSES:
        field, enum = ENUM_CLAUSES[k]
        if v.upper() not in enum:
            raise AsmError('%s: %s=%s: one of %s' % (u.loc, k, v, ', '.join(n.lower() for n in enum.names)))
        u.setn(field, v.upper(), k)
    elif k in ('cin', 'dl', 'a2'):
        if v not in ('0', '1'):
            raise AsmError('%s: %s=%s: 0 or 1' % (u.loc, k, v))
        u.setn(k, int(v), k)
    elif k == 'lc':
        if v.upper() in ('HOLD', 'DEC', 'ALU', 'INC'):
            u.setn('lcop', v.upper(), 'lc')
        else:
            u.setn('lcop', 'LIT', 'lc')
            _lit(u, num(v), 'lc')
    elif k == 'exc':
        bits = 0
        for n in v.upper().split(','):
            if n not in FD.EXC_BITS:
                raise AsmError('%s: exc=%s: %s is not an EXC bit' % (u.loc, v, n))
            bits |= 1 << FD.EXC_BITS[n]
        _lit(u, bits, 'exc')
    elif k == 'lit':
        _lit(u, num(v), 'lit')
    elif k == 'rtime':
        if v.upper() not in FD.RROW:
            raise AsmError('%s: rtime=%s: one of %s' % (u.loc, v, ', '.join(n.lower() for n in FD.RROW.names)))
        u.setn('ctl', 'RTIME', k)
        _lit(u, FD.RROW[v.upper()], k)
    elif k in ('budget', 'rbudget'):
        n = num(v)
        if n & 1 or not 0 <= n <= 510:
            raise AsmError('%s: %s=%d: an even number of clocks, 0 to 510' % (u.loc, k, n))
        u.setn('ctl', k.upper(), k)
        _lit(u, n >> 1, k)
    elif k == 'fp':
        sel = FP_SEL.get(v.lower())
        if sel is None:
            raise AsmError('%s: fp=%s: src, dst, c or ra' % (u.loc, v))
        u.setn('fpsel', sel, 'fp')
    else:
        raise AsmError('%s: unknown clause %r' % (u.loc, c))


SEQ_WORDS = {'next', 'goto', 'call', 'ret', 'if', 'unless', 'dispatch', 'wait', 'budget', 'waitb'}


def _target(s):
    return num(s) if s[0] == '$' or s[0].isdigit() else s


def word_rules(u):
    """What one microinstruction cannot do (sim.py raises the same at run
    time): the datapath has one of each."""
    n = u.nano.get
    nop = n('alu', 'NOP') == 'NOP'
    if n('dst', 'NONE') != 'NONE' and nop:
        raise AsmError('%s: a destination needs an ALU operation (alu=passb for a move)' % u.loc)
    if nop and (n('osh', 'NONE') != 'NONE' or n('fpsr', 'NONE') in ('FPCC', 'FPCCINEX', 'QUOT')
                or n('lcop', 'HOLD') == 'ALU'):
        raise AsmError('%s: osh, fpsr=fpcc/quot and lc=alu need an ALU result' % u.loc)
    if n('qop', 'HOLD') != 'HOLD' and n('osh', 'NONE') in ('L1Q', 'R3Q', 'QBIT'):
        raise AsmError('%s: q= and a Q-shifting osh in one word' % u.loc)
    if n('sha') == 'LZC' and n('shk', 'NONE') != 'NONE' and n('dst') == 'SC':
        raise AsmError('%s: a shift by LZC writes SC; d=SC too' % u.loc)
    if n('emode', 'MANT') in ('EXP', 'EXPB') and n('osh', 'NONE') not in ('NONE', 'R1'):
        raise AsmError('%s: in exponent mode the output shifter only halves (osh=r1)' % u.loc)
    if n('emode', 'MANT') in ('EXP', 'EXPB') and n('a2'):
        raise AsmError('%s: a2 shifts the mantissa; not in exponent mode' % u.loc)
    if n('bsrc') == 'SQT' and n('dir', 'PREVN') not in ('PREVN', 'DFLAG'):
        raise AsmError('%s: b=SQT takes its suffix from dir=prevn or dir=dflag' % u.loc)
    if n('bsrc') in ('RINC', 'RMASK') and n('rnd', 'NONE') == 'NONE':
        raise AsmError('%s: b=%s needs a rnd= mode' % (u.loc, n('bsrc')))
    # A constant sharing its word (consts.py) is read by its own field only.
    field = consts.FIELDS.get(u.kname)
    mode, bx = n('emode', 'MANT'), n('bx', 'NONE')
    if field == 'exp' and not (mode == 'EXP' or bx == 'E2M'):
        raise AsmError('%s: K[%s] is an exponent: use it in mode=exp (or bx=e2m)' % (u.loc, u.kname))
    if field == 'mant' and not ((mode == 'MANT' and bx != 'E2M') or (mode == 'EXP' and bx == 'M2E')):
        raise AsmError('%s: K[%s] is a mantissa: use it in mode=mant (or bx=m2e)' % (u.loc, u.kname))


def parse_seq(u, s):
    w = [x for x in s.split()]
    if not w:
        return
    op = w[0].lower()
    if op == 'next' and len(w) == 1:
        u.seq = 'NEXT'
    elif op == 'goto' and len(w) == 2:
        u.seq, u.target = 'JUMP', _target(w[1])
    elif op == 'call' and len(w) == 2:
        u.seq, u.target = 'CALL', _target(w[1])
    elif op == 'ret' and len(w) == 1:
        u.seq = 'RET'
    elif op in ('if', 'unless') and len(w) == 4 and w[2].lower() == 'goto':
        c = w[1].upper()
        if c not in FD.COND:
            raise AsmError('%s: condition %s: not in fields.COND' % (u.loc, w[1]))
        u.seq = 'BRT' if op == 'if' else 'BRF'
        u.cond, u.target = FD.COND[c], _target(w[3])
    elif op == 'dispatch' and len(w) == 3:
        k = w[1].upper()
        if k not in FD.DISPATCH:
            raise AsmError('%s: dispatch key %s: one of %s' % (u.loc, w[1], ', '.join(FD.DISPATCH.names)))
        u.seq, u.cond, u.target = 'DISP', FD.DISPATCH[k], _target(w[2])
    elif op in ('wait', 'budget') and len(w) == 2:
        n = num(w[1])
        if not 1 <= n < 1 << 12:
            raise AsmError('%s: %s %d: 1 to 4095 clocks' % (u.loc, op, n))
        u.seq, u.target = 'WAIT', n
        u.cond = FD.WAITMODE['HOLD' if op == 'wait' else 'ADD']
    elif op == 'waitb' and len(w) in (1, 2):
        n = num(w[1]) if len(w) == 2 else 0
        if not 0 <= n < 1 << 12:
            raise AsmError('%s: waitb %d: 0 to 4095 clocks' % (u.loc, n))
        u.seq, u.target, u.cond = 'WAIT', n, FD.WAITMODE['UNTIL']
    else:
        raise AsmError('%s: sequencing %r' % (u.loc, s))


def _key_values(key, s, loc):
    """The codes a table entry's key text covers."""
    if key == 'TAGPAIR':
        parts = s.split()
        if len(parts) != 2:
            raise AsmError('%s: a TAGPAIR entry is SRC DST label' % loc)
        srcs = range(5) if parts[0] == '*' else [_enum_code(FD.TAG, parts[0], loc)]
        dsts = range(5) if parts[1] == '*' else [_enum_code(FD.TAG, parts[1], loc)]
        return [a * 5 + b for a in srcs for b in dsts]
    enum = FD.KEY_ENUM[key]
    if s == '*':
        return list(range(1 << FD.DISPATCH_BITS[key]))
    return [_enum_code(enum, s, loc)]


def _enum_code(enum, s, loc):
    if enum is None:
        return num(s)
    if s.upper() in enum:
        return enum[s.upper()]
    try:
        return num(s)
    except ValueError:
        raise AsmError('%s: %s: one of %s' % (loc, s, ', '.join(enum.names)))


ENTRY_KINDS = ['reg'] + [f for f in FD.FMT.names if f != 'PK']


def parse_tadj(prog, args, loc):
    w = args.split()
    if len(w) == 2 and (w[0].lower() == 'cr' or w[0].lower().startswith('out.')):
        n = int(w[1].replace('+', ''))
        if not -128 <= n <= 127:
            raise AsmError('%s: .tadj: N -128 to 127' % loc)
        if w[0].lower() == 'cr':
            idx = FD.ENTRY_FMOVECR
        else:
            f = w[0][4:].upper()
            if f not in FD.FMT:
                raise AsmError('%s: out.%s: a format of %s' % (loc, f, ', '.join(FD.FMT.names)))
            idx = FD.entry_store(f)
        if idx in prog.tadj:
            raise AsmError('%s: .tadj for entry $%03X already given at %s' % (loc, idx, prog.tadj[idx][1]))
        prog.tadj[idx] = (n, loc)
        return
    if len(w) != 3:
        raise AsmError('%s: .tadj KINDS OPMODE N | cr N | out.F N' % loc)
    kinds = ENTRY_KINDS if w[0] == '*' else w[0].split(',')
    op, n = num(w[1]), int(w[2].replace('+', ''))
    if not 0 <= op < 0x40 or not -128 <= n <= 127:
        raise AsmError('%s: .tadj: opmode $00-$3F, N -128 to 127' % loc)
    for k in kinds:
        kk = 'reg' if k.lower() == 'reg' else k.upper()
        if kk != 'reg' and (kk not in FD.FMT or kk == 'PK'):
            raise AsmError('%s: source kind %s: reg or one of L S X P W D B' % (loc, k))
        idx = FD.entry_general(kk, op)
        if idx in prog.tadj:
            raise AsmError('%s: .tadj for entry $%03X already given at %s' % (loc, idx, prog.tadj[idx][1]))
        prog.tadj[idx] = (n, loc)


def parse_entry(prog, args, loc):
    w = args.split()
    def put(idx, label):
        if idx in prog.entries:
            raise AsmError('%s: entry $%03X already given at %s' % (loc, idx, prog.entries[idx][1]))
        prog.entries[idx] = (label, loc)
    if len(w) == 2 and w[0].lower() == 'default':
        prog.entry_default = (w[1], loc)
    elif len(w) == 2 and w[0].lower() == 'cr':
        put(FD.ENTRY_FMOVECR, w[1])
    elif len(w) == 2 and w[0].lower().startswith('out.'):
        f = w[0][4:].upper()
        if f not in FD.FMT:
            raise AsmError('%s: out.%s: a format of %s' % (loc, f, ', '.join(FD.FMT.names)))
        put(FD.entry_store(f), w[1])
    elif len(w) == 3:
        kinds = ENTRY_KINDS if w[0] == '*' else w[0].split(',')
        op = num(w[1])
        if not 0 <= op < 0x40:
            raise AsmError('%s: opmode $%X: $00-$3F ($40-$7F are the BIU\'s F-line)' % (loc, op))
        for k in kinds:
            kk = 'reg' if k.lower() == 'reg' else k.upper()
            if kk != 'reg' and (kk not in FD.FMT or kk == 'PK'):
                raise AsmError('%s: source kind %s: reg or one of L S X P W D B' % (loc, k))
            put(FD.entry_general(kk, op), w[2])
    else:
        raise AsmError('%s: .entry %s' % (loc, args))


def parse_uinstr(text, loc, knames):
    u = UInstr(loc)
    if '|' not in text and text.split()[0].lower() in SEQ_WORDS:
        text = '|' + text                          # a line of sequencing alone
    body, _, seq = text.partition('|')
    for c in body.split():
        parse_clause(u, c, knames)
    parse_seq(u, seq)
    word_rules(u)
    return u


def parse_file(prog, path, knames, seen=None):
    seen = seen or set()
    ap = os.path.abspath(path)
    if ap in seen:
        raise AsmError('%s: included twice' % path)
    seen.add(ap)
    table = None
    with open(path, encoding='utf-8') as fh:
        lines = fh.read().splitlines()
    for n, raw in enumerate(lines, 1):
        loc = Loc(path, n, raw)
        text = raw.split(';', 1)[0].strip()
        if not text:
            continue
        if table is not None:
            if text.lower() == '.end':
                table = None
                continue
            if '::' in text:
                # A microinstruction in the slot itself, saving the jump:
                # it must leave by goto or dispatch (the next slot is not
                # its successor).
                keytext, body = (x.strip() for x in text.split('::', 1))
                label = parse_uinstr(body, loc, knames)
                if label.seq not in ('JUMP', 'DISP'):
                    raise AsmError('%s: a microinstruction in a table slot must end in goto or dispatch' % loc)
            else:
                parts = text.rsplit(None, 1)
                if len(parts) != 2:
                    raise AsmError('%s: table entry: keys then a label' % loc)
                keytext, label = parts
            if keytext.lower() == 'redundant' and isinstance(label, str) and label.lower() == 'model':
                if table.key != 'OPMODE':
                    raise AsmError('%s: `redundant model` is for an OPMODE table' % loc)
                table.redundant = True
                continue
            if keytext.lower() == 'default':
                table.default = label
                continue
            wild = '*' in keytext
            for code in _key_values(table.key, keytext, loc):
                if code in table.entries:
                    if wild:
                        continue                  # a wildcard fills what is not yet given
                    raise AsmError('%s: table %s: entry %s given twice'
                                   % (loc, table.name, _key_name(table.key, code)))
                table.entries[code] = label
            continue
        while True:                                        # labels
            m = re.match(r'^([A-Za-z_][\w.]*):\s*(.*)$', text)
            if not m:
                break
            name = m.group(1)
            if name in prog.labels or name in prog.pending_labels:
                raise AsmError('%s: label %s defined twice' % (loc, name))
            prog.pending_labels.append(name)
            text = m.group(2)
        if not text:
            continue
        if text.startswith('.'):
            parts = text.split(None, 1)
            d, args = parts[0].lower(), (parts[1] if len(parts) > 1 else '')
            if d == '.include':
                inc = args.strip().strip('"')
                parse_file(prog, os.path.join(os.path.dirname(path), inc), knames, seen)
            elif d == '.org':
                prog.layout_ops.append(('org', num(args), loc))
            elif d == '.align':
                a = num(args)
                if a & (a - 1):
                    raise AsmError('%s: .align %d: a power of two' % (loc, a))
                prog.layout_ops.append(('align', a, loc))
            elif d == '.export':
                prog.exports.append((args.strip(), loc))
            elif d == '.table':
                w = args.split()
                if len(w) not in (2, 3) or w[1].upper() not in FD.DISPATCH_BITS or                    (len(w) == 3 and (w[2].lower() not in ('cu', 'hold') or w[1].upper() != 'TAGPAIR')):
                    raise AsmError('%s: .table NAME KEY [cu|hold] (cu and hold are TAGPAIR tables)' % loc)
                if w[0] in prog.labels or w[0] in prog.tables:
                    raise AsmError('%s: %s defined twice' % (loc, w[0]))
                table = Table(w[0], w[1].upper(), loc)
                if len(w) == 3:
                    table.kind = w[2].lower()
                prog.tables[w[0]] = table
                prog.labels[w[0]] = ('table', table)
            elif d == '.entry':
                parse_entry(prog, args, loc)
            elif d == '.tadj':
                parse_tadj(prog, args, loc)
            elif d == '.redundant':
                if args.strip().lower() != 'model':
                    raise AsmError('%s: .redundant model' % loc)
                prog.redundant = True
            else:
                raise AsmError('%s: unknown directive %s' % (loc, d))
            if prog.pending_labels and d not in ('.org', '.align', '.export', '.entry', '.tadj', '.redundant', '.include'):
                raise AsmError('%s: a label must name a microinstruction' % loc)
            continue
        u = parse_uinstr(text, loc, knames)
        for name in prog.pending_labels:
            prog.labels[name] = ('code', u)
        prog.pending_labels = []
        prog.code.append(u)
        prog.layout_ops.append(('instr', u, loc))
    if table is not None:
        raise AsmError('%s: .table %s has no .end' % (table.loc, table.name))


# -- layout ----------------------------------------------------------------------------

NOP_JUMP = None


def layout(prog):
    """Addresses: the code from 0 in source order (.org/.align move the
    counter), then the tables above it, largest first, each aligned to its
    size.  Returns the µROM as a list of UInstr or None."""
    if prog.pending_labels:
        raise AsmError('label(s) %s at the end of the source name nothing' % ', '.join(prog.pending_labels))
    rom = [None] * FD.UROM_WORDS
    pc = 0
    for op in prog.layout_ops:
        if op[0] == 'org':
            if op[1] < pc:
                raise AsmError('%s: .org $%X moves backwards (at $%X)' % (op[2], op[1], pc))
            pc = op[1]
        elif op[0] == 'align':
            pc = (pc + op[1] - 1) & ~(op[1] - 1)
        else:
            if pc >= FD.UROM_WORDS:
                raise AsmError('%s: the µROM is full (%d words)' % (op[2], FD.UROM_WORDS))
            op[1].addr = pc
            rom[pc] = op[1]
            pc += 1
    code_end = pc
    for t in sorted(prog.tables.values(), key=lambda t: -t.bits):
        size = 1 << t.bits
        a = (pc + size - 1) & ~(size - 1)
        if a + size > FD.UROM_WORDS:
            raise AsmError('%s: table %s does not fit the µROM' % (t.loc, t.name))
        t.addr = a
        if t.redundant:
            import fpu
            for red, base in fpu.FPU.REDUNDANT.items():
                if red not in t.entries and base in t.entries:
                    t.entries[red] = t.entries[base]
        for code in range(size):
            label = t.entries.get(code, t.default)
            if label is None and not _possible(t.key, code):
                label = a + code                  # a code the key never takes: a trap to itself
            if label is None:
                raise AsmError('%s: table %s: entry %s has no target and there is no default'
                               % (t.loc, t.name, _key_name(t.key, code)))
            if isinstance(label, UInstr):
                import copy
                u = copy.copy(label)
                u.nano = OrderedDict(label.nano)
                u.addr, u.table_of = a + code, t
            else:
                u = UInstr(t.loc)
                u.seq, u.target, u.addr, u.table_of = 'JUMP', label, a + code, t
            rom[a + code] = u
        pc = a + size
    prog.code_end = code_end
    prog.rom_end = pc
    return rom


def _possible(key, code):
    """Whether a dispatch key can produce the code at all."""
    if key == 'TAGPAIR':
        return code < 25
    enum = FD.KEY_ENUM[key]
    return enum is None or code < len(enum.names)


def _key_name(key, code):
    if key == 'TAGPAIR':
        return '%s %s' % (FD.TAG.name(code // 5), FD.TAG.name(code % 5)) if code < 25 else str(code)
    return FD.KEY_ENUM[key].name(code) if FD.KEY_ENUM[key] else str(code)


def resolve(prog, rom):
    """Targets to addresses."""
    def addr_of(label, u):
        if isinstance(label, int):
            return label
        ent = prog.labels.get(label)
        if ent is None:
            raise AsmError('%s: %s is not defined' % (u.loc, label))
        return ent[1].addr
    for u in rom:
        if u is None or u.seq in ('NEXT', 'RET'):
            continue
        if u.seq == 'WAIT':
            continue
        a = addr_of(u.target, u)
        if u.seq == 'DISP':
            key = FD.DISPATCH.name(u.cond)
            ent = prog.labels.get(u.target, ('code',))
            if ent[0] == 'table' and ent[1].key != key:
                raise AsmError('%s: dispatch %s into table %s, which is keyed by %s'
                               % (u.loc, key, u.target, ent[1].key))
            if a & ((1 << FD.DISPATCH_BITS[key]) - 1):
                raise AsmError('%s: dispatch %s: %s ($%X) is not aligned to %d'
                               % (u.loc, key, u.target, a, 1 << FD.DISPATCH_BITS[key]))
        u.taddr = a


# -- encoding --------------------------------------------------------------------------

def nano_word(u):
    return FD.NANO.pack(u.nano)


def encode(prog, rom):
    nano_index = OrderedDict()
    nano_index[0] = 0                        # the NOP: nothing selected, nothing written
    for u in rom:
        if u is not None:
            w = nano_word(u)
            if w not in nano_index:
                nano_index[w] = len(nano_index)
    if len(nano_index) > FD.NROM_WORDS:
        raise AsmError('the nROM is full: %d distinct nanowords of %d' % (len(nano_index), FD.NROM_WORDS))
    urom, nrom = [0] * FD.UROM_WORDS, [0] * FD.NROM_WORDS
    for w, i in nano_index.items():
        nrom[i] = w
    for a, u in enumerate(rom):
        if u is None:
            continue
        target = u.target if u.seq == 'WAIT' else getattr(u, 'taddr', 0)
        urom[a] = FD.MICRO.pack({'nano': nano_index[nano_word(u)], 'ra': u.ra, 'rb': u.rb,
                                 'rd': u.rd, 'seq': u.seq, 'cond': u.cond, 'target': target})
    entry = [None] * FD.ENTRY_WORDS
    for idx, (label, loc) in prog.entries.items():
        entry[idx] = _label_addr(prog, label, loc)
    if prog.redundant:
        import fpu
        for kind in ENTRY_KINDS:
            for red, base in fpu.FPU.REDUNDANT.items():
                i, j = FD.entry_general(kind, red), FD.entry_general(kind, base)
                if entry[i] is None and entry[j] is not None:
                    entry[i] = entry[j]
    missing = [i for i, e in enumerate(entry) if e is None]
    if missing:
        if prog.entry_default is None:
            raise AsmError('the entry table has %d empty indices (first $%03X) and no .entry default'
                           % (len(missing), missing[0]))
        d = _label_addr(prog, *prog.entry_default)
        for i in missing:
            entry[i] = d
    return urom, nrom, entry, len(nano_index)


def _label_addr(prog, label, loc):
    ent = prog.labels.get(label)
    if ent is None:
        raise AsmError('%s: %s is not defined' % (loc, label))
    return ent[1].addr


# -- the checks ------------------------------------------------------------------------

TRACKED_EXTRA = ('Q', 'MD', 'MD3')


def uses_defs(u):
    n = u.nano
    use, dfn = set(), set()
    if n.get('asrc') == 'T':
        use.add('T%d' % u.ra)
    b = n.get('bsrc')
    if b == 'T':
        use.add('T%d' % u.rb)
    elif b == 'BOOTH':
        use |= {'MD', 'MD3', 'Q'}
    elif b in ('Q', 'SQT'):
        use.add('Q')
    if n.get('osh') in ('L1Q', 'R3Q'):
        use.add('Q'); dfn.add('Q')
    if n.get('qop') in ('LOAD', 'LOADB', 'CLEAR'):
        dfn.add('Q')
    d = n.get('dst')
    if d == 'T':
        dfn.add('T%d' % u.rd)
    elif d in ('MD', 'MD3'):
        dfn.add(d)
    return use, dfn


def cfg(prog, rom):
    """Successors of every µROM word, with calls to the callee and returns
    to every call site's successor (context-insensitive)."""
    succ = {}
    callers = defaultdict(list)                   # callee address -> call sites
    for u in rom:
        if u is not None and u.seq == 'CALL':
            callers[u.taddr].append(u.addr)
    # Which subroutine(s) each RET belongs to: the words reachable from the
    # callee's entry without following a call into its callee.
    ret_to = defaultdict(set)
    for entry, sites in callers.items():
        seen, stack = set(), [entry]
        while stack:
            a = stack.pop()
            if a in seen or rom[a] is None:
                continue
            seen.add(a)
            u = rom[a]
            if u.seq == 'RET':
                ret_to[a] |= {s + 1 for s in sites}
                continue
            stack.extend(_intra_succ(prog, rom, u))
    for u in rom:
        if u is None:
            continue
        if u.seq == 'RET':
            succ[u.addr] = sorted(ret_to.get(u.addr, ()))
        elif u.seq == 'CALL':
            succ[u.addr] = [u.taddr]
        else:
            succ[u.addr] = _intra_succ(prog, rom, u)
    return succ, callers, ret_to


def _intra_succ(prog, rom, u):
    s = u.seq
    if s in ('NEXT', 'WAIT'):
        return [u.addr + 1]
    if s == 'JUMP':
        return [u.taddr]
    if s in ('BRT', 'BRF'):
        return [u.taddr, u.addr + 1]
    if s == 'DISP':
        return [u.taddr + k for k in range(1 << FD.DISPATCH_BITS[FD.DISPATCH.name(u.cond)])]
    if s == 'CALL':
        return [u.addr + 1]                       # after the callee returns
    return []


def check(prog, rom):
    errors, warnings = [], []
    # Fall-through into nothing.
    for u in rom:
        if u is None:
            continue
        for a in _intra_succ(prog, rom, u):
            if not 0 <= a < FD.UROM_WORDS or rom[a] is None:
                errors.append('%s: continues to $%03X, where there is no microinstruction' % (u.loc, a))
            elif rom[a].table_of is not None and u.seq in ('NEXT', 'WAIT', 'BRT', 'BRF', 'CALL') and a == u.addr + 1:
                errors.append('%s: falls through into table %s' % (u.loc, rom[a].table_of.name))
    # A holding wait and END in one word: END's hold counts from the word's
    # first clock (sim.py) and the RTL's from its last - refused, not defined.
    for u in rom:
        if (u is not None and u.seq == 'WAIT' and u.cond != FD.WAITMODE['ADD']
                and u.nano.get('ctl') == 'END'):
            errors.append('%s: a holding wait and ctl=end in one word' % u.loc)
    succ, callers, ret_to = cfg(prog, rom)
    for u in rom:
        if u is not None and u.seq == 'RET' and not ret_to.get(u.addr):
            warnings.append('%s: ret reached from no call' % u.loc)

    # An FP register written, then read by the next word: the RTL reads the
    # next word's FP operand at the edge that writes this one, and has no
    # bypass - refused, whatever the selects (src and dst
    # are the command's, and may name one register).  After ctl=end no word
    # follows in the instruction.
    for u in rom:
        if u is None or u.nano.get('dst') != 'FP' or u.nano.get('ctl') == 'END':
            continue
        for s in succ.get(u.addr, ()):
            v = rom[s] if 0 <= s < FD.UROM_WORDS else None
            if v is not None and 'FP' in (v.nano.get('asrc'), v.nano.get('bsrc')):
                errors.append('%s: writes FP and the next word (%s) reads FP: no bypass' % (u.loc, v.loc))

    # The µPC stack: the deepest chain of calls.
    body = {}
    for entry in callers:
        seen, stack, calls = set(), [entry], set()
        while stack:
            a = stack.pop()
            if a in seen or rom[a] is None:
                continue
            seen.add(a)
            u = rom[a]
            if u.seq == 'CALL':
                calls.add(u.taddr)
            if u.seq != 'RET':
                stack.extend(_intra_succ(prog, rom, u))
        body[entry] = calls
    depth = {}
    def d(e, path):
        if e in path:
            raise AsmError('recursion through $%03X (%s): the µPC stack cannot hold it'
                           % (e, rom[e].loc))
        if e not in depth:
            depth[e] = 1 + max((d(c, path | {e}) for c in body.get(e, ())), default=0)
        return depth[e]
    worst = max((d(e, frozenset()) for e in callers), default=0)
    if worst > FD.STACK_DEPTH:
        errors.append('calls nest %d deep; the µPC stack holds %d' % (worst, FD.STACK_DEPTH))

    # Liveness at the checkpoints, context-sensitive (merging every return
    # point of a subroutine lets impossible paths make registers look
    # live).  Each subroutine gets two summaries: U, what it may read before
    # writing on the way to its RET, and D, what it writes on every way
    # there; a CALL is live_in = U + (live after it - D).  A checkpoint is
    # then judged per chain of calls that can be on the µPC stack above it:
    # its subroutine's liveness with the RET's live-out being what is live
    # after the call in the caller - judged the same way, outward.
    ud = {u.addr: uses_defs(u) for u in rom if u is not None}
    bodies = {}
    for entry in callers:
        seen, stack = set(), [entry]
        while stack:
            a = stack.pop()
            if a in seen or rom[a] is None:
                continue
            seen.add(a)
            if rom[a].seq != 'RET':
                stack.extend(_intra_succ(prog, rom, rom[a]))
        bodies[entry] = seen
    U, D = {e: set() for e in callers}, {e: None for e in callers}
    ALL = {'T%d' % i for i in range(FD.TEMPS)} | set(TRACKED_EXTRA)

    def liveness(words, ret_live):
        """live_in over `words` (a subroutine's body or the top level), a
        RET's live-out being ret_live, calls by their summaries."""
        live = {a: set() for a in words}

        def out(a):
            u = rom[a]
            if u.seq == 'RET':
                return set(ret_live)
            if u.seq == 'CALL':
                after = live.get(a + 1, set())
                return U[u.taddr] | (after - (D[u.taddr] or set()))
            o = set()
            for s in _intra_succ(prog, rom, u):
                o |= live.get(s, set())
            return o
        ch = True
        while ch:
            ch = False
            for a in sorted(words, reverse=True):
                use, dfn = ud[a]
                new = use | (out(a) - dfn)
                if new != live[a]:
                    live[a], ch = new, True
        return live, out

    def must_def(entry):
        """What every way from the entry to a RET writes (calls by D)."""
        body = bodies[entry]
        md = {a: None for a in body}               # None: not yet reached (top)
        md[entry] = set()
        ch = True
        while ch:
            ch = False
            for a in sorted(body):
                if md[a] is None:
                    continue
                u = rom[a]
                d = md[a] | ud[a][1]
                if u.seq == 'CALL':
                    d = d | (D[u.taddr] or set())
                    succs = [a + 1]
                elif u.seq == 'RET':
                    continue
                else:
                    succs = [s for s in _intra_succ(prog, rom, u) if s in body]
                for s in succs:
                    new = set(d) if md[s] is None else md[s] & d
                    if new != md[s]:
                        md[s], ch = new, True
        rets = [md[a] for a in body if rom[a].seq == 'RET' and md[a] is not None]
        return set.intersection(*[r | ud[a][1] for r, a in zip(rets, [a for a in body if rom[a].seq == 'RET' and md[a] is not None])]) if rets else set(ALL)

    for _ in range(len(callers) + 2):              # the summaries to a fixed point
        for e in callers:
            live, _o = liveness(bodies[e], set())
            U[e] = live[e]
            D[e] = must_def(e)
    top = [a for a in ud if not any(a in b for b in bodies.values())]
    memo = {}

    def contexts(entry, depth=0):
        """The live-out sets a RET of this subroutine can see: for each call
        of it, what is live after the call in its caller."""
        if entry in memo:
            return memo[entry]
        res = []
        for c in callers[entry]:
            holders = [e2 for e2, b in bodies.items() if c in b]
            if not holders:
                live, _o = liveness(top, set())
                res.append(frozenset(live.get(c + 1, set())))
            for e2 in holders:
                if depth > FD.STACK_DEPTH:
                    continue
                for ctx in contexts(e2, depth + 1):
                    live, _o = liveness(bodies[e2], ctx)
                    res.append(frozenset(live.get(c + 1, set())))
        memo[entry] = res
        return res

    allowed = {'T%d' % i for i in range(FD.LIVE_AT_CHECKPOINT)}
    lcache = {}

    def lv(key, words, ctx):
        if (key, ctx) not in lcache:
            lcache[(key, ctx)] = liveness(words, ctx)
        return lcache[(key, ctx)]

    def live_out(addr):
        """What is live after the word at addr, in every call chain that
        reaches it: what a checkpoint there would have to hold."""
        outs = []
        holders = [e for e, b in bodies.items() if addr in b]
        if not holders:
            live, o = lv('top', top, frozenset())
            outs.append(o(addr))
        for e in holders:
            for ctx in contexts(e) or [frozenset()]:
                live, o = lv(e, bodies[e], frozenset(ctx))
                outs.append(o(addr))
        return set().union(*outs) if outs else set()
    check.live_out = live_out                      # for cpcand.py: where a checkpoint may go

    for u in rom:
        if u is None or u.nano.get('ctl') != 'CHECKPOINT':
            continue
        out = live_out(u.addr)
        bad = sorted(out - allowed, key=lambda r: (len(r), r))
        if bad:
            errors.append('%s: checkpoint with %s live (a busy frame holds T0-T%d; Q, MD, MD3 must be dead)'
                          % (u.loc, ', '.join(bad), FD.LIVE_AT_CHECKPOINT - 1))

    # Reachability, for a warning.
    roots = {e for e in _entry_roots(prog)}
    seen, stack = set(), list(roots)
    while stack:
        a = stack.pop()
        if a in seen or a not in succ:
            continue
        seen.add(a)
        stack.extend(succ[a])
        if rom[a].seq == 'CALL':
            stack.append(a + 1)
    for u in rom:
        if u is not None and u.table_of is None and u.addr not in seen:
            warnings.append('%s: unreachable' % u.loc)
    return errors, warnings, worst


def _entry_roots(prog):
    for label, loc in list(prog.entries.values()) + ([prog.entry_default] if prog.entry_default else []):
        yield _label_addr(prog, label, loc)
    for label, loc in prog.exports:
        yield _label_addr(prog, label, loc)


# -- output ----------------------------------------------------------------------------

def hexlines(words, bits):
    w = (bits + 3) // 4
    return ''.join('%0*X\n' % (w, x) for x in words)


class Result:
    pass


# -- the CU's conversion times --------------------------------------------
# A `cu` or `hold` table's slots are each a word with budget=N: the time
# Table 8-13 gives that conversion.  ucode.cvt.hex holds the Ns, at
# {table number, tag pair}; ucode.cvsel.hex says, for each entry index, the
# table its first word dispatches to - {hold, number[3:0]}, 0 for none.  A `cu`
# table's words lose the budget (the CU spends it); a `hold` table's keep it.
CV_TABLES = 15                              # numbers 1-15

def cu_tables(prog):
    cvt = [0] * 512
    n = 0
    for t in prog.tables.values():
        if not t.kind:
            continue
        n += 1
        if n > CV_TABLES:
            raise AsmError('%s: more than %d cu/hold tables' % (t.loc, CV_TABLES))
        t.cvid = n
        for code in range(32):
            u = t.entries.get(code)
            if u is None:
                continue                    # (the default: a pair that cannot occur)
            if not isinstance(u, UInstr):
                raise AsmError('%s: table %s: the slots of a %s table must be inline words' % (t.loc, t.name, t.kind))
            if u.nano.get('ctl') != 'BUDGET':
                raise AsmError('%s: table %s slot %s: a %s word needs budget=N' % (u.loc, t.name, _key_name(t.key, code), t.kind))
            cvt[(n << 5) | code] = u.nano['lit'] * 2
    for t in prog.tables.values():          # strip after reading: a word may fill several slots
        if t.kind == 'cu':
            for x in t.entries.values():
                if x.nano.get('ctl') == 'BUDGET':
                    del x.nano['ctl']
                    del x.nano['lit']
    return cvt


def cu_select(prog, rom, entry):
    sel = [0] * FD.ENTRY_WORDS
    for i, a in enumerate(entry):
        u = rom[a] if a is not None and a < len(rom) else None
        if u is None or u.seq != 'DISP' or FD.DISPATCH.names[u.cond] != 'TAGPAIR':
            continue
        ent = prog.labels.get(u.target)
        if ent and ent[0] == 'table' and ent[1].kind:
            sel[i] = ((ent[1].kind == 'hold') << 4) | ent[1].cvid
    return sel


def assemble(paths):
    prog = Program()
    for p in paths:
        parse_file(prog, p, consts.NAMES)
    cvt = cu_tables(prog)                   # (before layout copies the table words)
    rom = layout(prog)
    resolve(prog, rom)
    for label, loc in prog.exports:
        if label not in prog.labels:
            raise AsmError('%s: .export %s: not defined' % (loc, label))
    urom, nrom, entry, nnano = encode(prog, rom)
    errors, warnings, depth = check(prog, rom)
    r = Result()
    r.prog, r.rom, r.urom, r.nrom, r.entry = prog, rom, urom, nrom, entry
    r.krom = consts.ROM
    r.cvt, r.cvsel = cvt, cu_select(prog, rom, entry)
    r.tadj = [prog.tadj.get(i, (0, None))[0] for i in range(FD.ENTRY_WORDS)]
    r.nnano, r.errors, r.warnings, r.depth = nnano, errors, warnings, depth
    return r


def write(r, outdir, stem='ucode'):
    import disasm
    os.makedirs(outdir, exist_ok=True)
    def put(name, text):
        with open(os.path.join(outdir, name), 'w', newline='\n') as fh:
            fh.write(text)
    put(stem + '.urom.hex', hexlines(r.urom, FD.MICRO.width))
    put(stem + '.nrom.hex', hexlines(r.nrom, FD.NANO.width))
    put(stem + '.entry.hex', hexlines(r.entry, 12))
    put(stem + '.krom.hex', hexlines(r.krom, FD.KWORD_BITS))
    # What the RTL needs of a nanoword before the nanoword itself is out of
    # the nROM: its operand addresses are registered with the
    # microword, so the FP select and whether the constant is indexed by LC
    # come from this small table on the nanoword's address - {KLC, FPSEL}.
    nsel = []
    for w in r.nrom:
        n = FD.NANO.unpack(w)
        nsel.append((int(n['bsrc'] == FD.BSRC.code['KLC']) << 2) | n['fpsel'])
    put(stem + '.nsel.hex', hexlines(nsel, 3))
    put(stem + '.cvt.hex', hexlines(r.cvt, 8))
    put(stem + '.cvsel.hex', hexlines(r.cvsel, 5))
    put(stem + '.tadj.hex', hexlines([v & 0xFF for v in r.tadj], 8))
    put('fpu_ucode.vh', FD.verilog_header() + _addr_defines(r))
    sym = {'labels': {n: e[1].addr for n, e in r.prog.labels.items()},
           'constants': consts.NAMES,
           'exports': [l for l, _ in r.prog.exports]}
    put(stem + '.sym.json', json.dumps(sym, indent=1, sort_keys=True) + '\n')
    lst = ['; %d microinstructions ($000-$%03X code, tables to $%03X), %d nanowords, calls %d deep'
           % (sum(1 for u in r.rom if u is not None), r.prog.code_end - 1, r.prog.rom_end - 1,
              r.nnano, r.depth)]
    byaddr = defaultdict(list)
    for n, e in r.prog.labels.items():
        byaddr[e[1].addr].append(n)
    for a, u in enumerate(r.rom):
        if u is None:
            continue
        for n in sorted(byaddr.get(a, ())):
            lst.append('%s:' % n)
        m = FD.MICRO.unpack(r.urom[a])
        if u.table_of is None:
            src = u.loc.text.split(';', 1)[0].strip()
        else:
            t = u.table_of
            src = '(table %s: %s)' % (t.name, _key_name(t.key, a - t.addr))
        lst.append('%03X  %012X  n%03X  %-60s ; %s' % (a, r.urom[a], m['nano'],
                   disasm.format_word(r.urom[a], r.nrom), src))
    put(stem + '.lst', '\n'.join(lst) + '\n')


def _addr_defines(r):
    out = ['', '// Exported microcode addresses.']
    for label, _ in r.prog.exports:
        out.append('`define UADDR_%s 12\'h%03X' % (label.upper().replace('.', '_'), r.prog.labels[label][1].addr))
    # The BIU's conditional predicate, sim.predicate's table: bit
    # FPCC x 32 + predicate[4:0].  Logic, not a ROM: it is 512 bits.
    import sim
    cc = 0
    for c in range(16):
        for p in range(32):
            if sim.predicate(p, c):
                cc |= 1 << (c * 32 + p)
    out += ['', '// The conditionals\' truth table (sim.predicate): bit FPCC x 32 + predicate[4:0].',
            '`define FPU_CC_TABLE 512\'h%0128X' % cc]
    # TINY and HUGE's limits by RPREC (sim.RANGE): the biased exponents a
    # normalized result may have.
    out += ['', '// The range comparators\' limits by RPREC (sim.RANGE).']
    for rp, (lo, hi) in sorted(sim.RANGE.items()):
        out.append('`define FPU_RANGE_LO_%d 18\'d%d' % (rp, lo))
        out.append('`define FPU_RANGE_HI_%d 18\'d%d' % (rp, hi))
    return '\n'.join(out) + '\n'


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description='The 68882 microcode assembler.')
    ap.add_argument('sources', nargs='+')
    ap.add_argument('-o', '--out', default='out')
    ap.add_argument('--stem', default='ucode')
    a = ap.parse_args(argv)
    try:
        r = assemble(a.sources)
    except AsmError as e:
        print('error:', e)
        return 1
    for w in r.warnings:
        print('warning:', w)
    for e in r.errors:
        print('error:', e)
    if r.errors:
        return 1
    write(r, a.out, a.stem)
    print('%d microinstructions, %d nanowords, calls %d deep -> %s'
          % (sum(1 for u in r.rom if u is not None), r.nnano, r.depth, a.out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
