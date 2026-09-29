"""The 68882's microword, nanoword and ROM formats: plan 8.8.11, work 6b.

The one definition of every field, its width and its values.  The
assembler (asm.py) packs with it, the disassembler (disasm.py) and the
architectural simulator (6c) unpack with it, and `verilog_header()` writes
the same positions for the RTL (item 7), so the three cannot disagree.

Fields are listed least significant first; a field's position is the sum
of the widths before it.  Every field's code 0 is "nothing": no operand
(zero), no operation, nothing written, nothing held changed - so the
all-zero nanoword is the NOP, and a field the source does not mention is 0.
"""

from collections import OrderedDict


class Enum:
    """A field's named values: code by name, name by code."""

    def __init__(self, *names):
        self.names = list(names)
        self.code = {n: i for i, n in enumerate(names)}

    def __contains__(self, n):
        return n in self.code

    def __getitem__(self, n):
        return self.code[n]

    def name(self, c):
        return self.names[c] if c < len(self.names) else '?%d' % c


class Field:
    def __init__(self, name, width, enum=None, doc=''):
        self.name, self.width, self.enum, self.doc = name, width, enum, doc
        self.lsb = 0                                  # set by Format

    @property
    def mask(self):
        return (1 << self.width) - 1


class Format:
    def __init__(self, name, *fields):
        self.name = name
        self.fields = OrderedDict()
        pos = 0
        for f in fields:
            f.lsb = pos
            pos += f.width
            self.fields[f.name] = f
            if f.enum is not None:
                assert len(f.enum.names) <= 1 << f.width, (name, f.name)
        self.width = pos

    def pack(self, values):
        w = 0
        for n, v in values.items():
            f = self.fields[n]
            if isinstance(v, str):
                v = f.enum[v]
            if not 0 <= v <= f.mask:
                raise ValueError('%s.%s = %r does not fit %d bits' % (self.name, n, v, f.width))
            w |= v << f.lsb
        return w

    def unpack(self, w):
        return OrderedDict((n, (w >> f.lsb) & f.mask) for n, f in self.fields.items())

    def names(self, w):
        """Unpacked, with enum fields as names."""
        out = OrderedDict()
        for n, v in self.unpack(w).items():
            e = self.fields[n].enum
            out[n] = e.name(v) if e is not None else v
        return out


# -- sizes (8.8.10, 8.8.11) -------------------------------------------------------

UROM_WORDS = 4096                # 8.8.19: grown from 2,048 for the transcendentals and packed decimal
NROM_WORDS = 1024
KROM_WORDS = 256
ENTRY_WORDS = 1024
TEMPS = 32
LIVE_AT_CHECKPOINT = 11          # T0-T10: what a busy frame holds (8.8.15)
STACK_DEPTH = 4

MANT_BITS = 67
EXP_BITS = 18
BIAS = 16383


# -- the sequencer (8.8.12) ----------------------------------------------------------

SEQ = Enum('NEXT', 'JUMP', 'CALL', 'RET', 'BRT', 'BRF', 'DISP', 'WAIT')

# Conditions for BRT/BRF.  The flags are the previous microinstruction's
# (8.8.9); the tags are Table 8-13's classes of the source and destination
# operands; KABOVE/KBELOW are the direction bits of the last constant read
# (8.6.14 item 19); S is the sign of the last ALU result word; RPEXT: the
# rounding precision's exponent range is extended's (EXT or SGLX).  TINY and
# HUGE: the last result word's exponent below the rounding precision's
# minimum or above its maximum - comparators beside the round logic
# (Daniel, 2026-09-29), so 8.6.4's range checks cost no clocks.  LE: N or Z
# of the last result, signed <= 0 (the timing pass, 8.8.19: log1ps's u < 0
# steps test it in one word).
COND = Enum(
    'TRUE', 'Z', 'N', 'C', 'V', 'STK', 'INEX', 'RCARRY',
    'LCZ', 'Q0', 'DFLAG', 'SCZ', 'KABOVE', 'KBELOW', 'EXCEN', 'PENDING',
    'SNORM', 'SUNN', 'SZERO', 'SINF', 'SNAN', 'SSNAN', 'SNEG', 'SDEN',
    'DNORM', 'DUNN', 'DZERO', 'DINF', 'DNAN', 'DSNAN', 'DNEG', 'DDEN',
    'EN_BSUN', 'EN_SNAN', 'EN_OPERR', 'EN_OVFL', 'EN_UNFL', 'EN_DZ', 'EN_INEX2', 'EN_INEX1',
    'PREC_EXT', 'PREC_SGL', 'PREC_DBL', 'RND_RN', 'RND_RZ', 'RND_RM', 'RND_RP', 'DYNK',
    'SAVEREQ', 'ABORT', 'CUHANDOFF', 'SRCREG', 'SAMEREG',
    'S', 'RPEXT', 'TINY', 'HUGE', 'LCEQ', 'LCSCEQ', 'RMRM', 'RMRP', 'LE',
)

# Dispatch keys (seq DISP; the `cond` field selects one): the key is ORed
# into the target's low bits, so a table is aligned to its size.  TAGPAIR
# is source class x 5 + destination class (25 of 32).
DISPATCH = Enum('TAGPAIR', 'STAG', 'DTAG', 'RND', 'PREC', 'SFMT', 'DFMT', 'KFACTOR', 'RPREC',
                'OPMODE', 'RMODE')
DISPATCH_BITS = {'TAGPAIR': 5, 'STAG': 3, 'DTAG': 3, 'RND': 2, 'PREC': 2,
                 'SFMT': 3, 'DFMT': 3, 'KFACTOR': 1, 'RPREC': 2, 'OPMODE': 6, 'RMODE': 2}

# Table 8-13's operand classes, in its column order.
TAG = Enum('NORM', 'UNN', 'ZERO', 'INF', 'NAN')
RND = Enum('RN', 'RZ', 'RM', 'RP')
PREC = Enum('EXT', 'SGL', 'DBL', 'SGLX')     # FPCR's 3 is taken as EXT; RPREC's 3 is SGLX
# The command word's formats (8.6.7): 111 is dynamic-k packed, out only.
FMT = Enum('L', 'S', 'X', 'P', 'W', 'D', 'B', 'PK')
KFACTOR = Enum('STATIC', 'DYNAMIC')

KEY_ENUM = {'TAGPAIR': None, 'STAG': TAG, 'DTAG': TAG, 'RND': RND, 'PREC': PREC,
            'SFMT': FMT, 'DFMT': FMT, 'KFACTOR': KFACTOR, 'RPREC': PREC, 'OPMODE': None, 'RMODE': RND}

MICRO = Format(
    'micro',
    Field('nano', 10, doc='nanoword address'),
    Field('ra', 5, doc='temporary on port A'),
    Field('rb', 8, doc='temporary on port B, or the constant ROM address'),
    Field('rd', 5, doc='destination temporary'),
    Field('seq', 3, SEQ),
    Field('cond', 6, doc='condition (BRT/BRF) or dispatch key (DISP)'),
    Field('target', 12, doc='jump/call/branch target; WAIT: clocks to hold'),
)
assert MICRO.width == 49


# -- the datapath controls (8.8.10, 8.8.11) ------------------------------------------

ASRC = Enum('ZERO', 'T', 'FP', 'CU')
# SQT: the square root's trial value, (Q << 1) | (3 or 1) << LC - the
# suffix 11 when the word's direction flag is set (the nonrestoring root's
# add step), 01 when it is clear.
BSRC = Enum('ZERO', 'T', 'K', 'KLC', 'FP', 'OPINT', 'OPRAW', 'CU', 'BOOTH',
            'RINC', 'RMASK', 'SQT', 'Q', 'SC', 'LC', 'CMD')
# The FP register: the instruction's source (RX of opclass 000; RY, the
# register stored, of opclass 011), its destination (RY), FSINCOS's cosine
# register (command bits 2-0), or the one the microword's ra names.  FMOVEM
# of the data registers is the BIU's and the CU's, not the microcode's.
FPSEL = Enum('SRC', 'DST', 'C', 'RA')
SHK = Enum('NONE', 'LSL', 'LSR', 'ASR')
# The shift amount.  LZC also copies the amount into SC, so the exponent
# can be adjusted by it on the next clock.
SHA = Enum('LIT', 'SC', 'LC', 'LZC', 'LCPSC', 'LCMSC')
# MANT: the ALU on the mantissas, the exponent passed from A (MANTB: from
# B); EXP: the ALU on the exponents, the mantissa passed from A (EXPB:
# from B).  UM 1.2: one ALU "used for both mantissa and exponent".
EMODE = Enum('MANT', 'MANTB', 'EXP', 'EXPB')
# NOP: no operation, no flags - the default, so an all-zero nanoword does
# nothing.  Any other operation sets the flags (a compare is one with no
# destination).  ADDSUB: A + B when the direction flag is clear, A - B when
# it is set; SUBADD the reverse (nonrestoring steps: subtract while the
# remainder is not negative).
ALU = Enum('NOP', 'ADD', 'SUB', 'RSUB', 'PASSA', 'PASSB', 'AND', 'OR', 'XOR',
           'ANDN', 'ADDSUB', 'SUBADD')
DIR = Enum('PREVN', 'DFLAG', 'BSIGN', 'BOOTH')
# NORM (Daniel, 2026-09-29: small exponent hardware for the timing tables):
# the result mantissa shifted left by its leading zeros and the exponent
# lowered by the count, in one clock.  QBIT: no shift; Q |= (1 - N) << LC
# (the square root's bit).  In exponent mode only R1 is allowed: the 18-bit
# result shifted right arithmetically (halving an exponent).
OSH = Enum('NONE', 'L1', 'L1Q', 'R1', 'R3Q', 'NORM', 'QBIT')
QOP = Enum('HOLD', 'LOAD', 'LOADB', 'CLEAR')
DST = Enum('NONE', 'T', 'FP', 'MD', 'MD3', 'OBUFH', 'OBUFL', 'OBUFX', 'EXOP', 'SC')
SGN = Enum('A', 'B', 'XOR', 'N', 'ZERO', 'ONE', 'NOTA', 'NOTB')
STK = Enum('HOLD', 'CLR', 'SHIFT', 'NZ')
# The round logic's boundary and mode (8.8.10): EXT/SGL/DBL at bit 3/43/14
# by FPCR RND; TRUNC at bit 3 toward zero (FINTRZ, the I67 truncations);
# RPREC by the rounding-precision register, which the CTL codes RP_* load
# (FPCR PREC for an ordinary result, the destination format for a store,
# and SGLX - code 3: single's mantissa with extended's exponent range, UM
# 6.1.4's note - for FSGLMUL/FSGLDIV) so one post-processing subroutine
# serves them all.
RNDM = Enum('NONE', 'EXT', 'SGL', 'DBL', 'TRUNC', 'RPREC')
# FPSR actions: CLREXC at an instruction's start; FPCC from the result;
# ORLIT ORs the literal into EXC; INEX2R sets INEX2 if the round logic
# found the result inexact; QUOT the quotient byte from Q and the sign;
# ACCRUE ORs EXC into AEXC at the end (6.1.10).
FPSR = Enum('NONE', 'CLREXC', 'FPCC', 'ORLIT', 'INEX2R', 'QUOT', 'ACCRUE', 'FPCCINEX')
# INC: the CORDIC loops count i upward (their shifts and table index are
# LC-based); their exits test LCEQ (LC = lit) and LCSCEQ (LC - SC = lit,
# the shift-amount adder's output) - plan 8.8.19.
LCOP = Enum('HOLD', 'LIT', 'DEC', 'ALU', 'INC')
# END: the instruction is complete - AEXC accrues from EXC (6.1.10) and
# the BIU takes EXC AND ENABLE as the pending exception (6.1.9's
# priority), pre-instruction for a register destination, mid-instruction
# for a store.  RP_*: load the rounding-
# precision register (PREC codes: 0 EXT, 1 SGL, 2 DBL; FPCR's 3 is EXT).
# RM_*: the rounding-mode register RMODE the round logic follows - FPCR's
# RND until set (every instruction starts there), or RN/RZ/RM/RP fixed:
# packed decimal's steps round in the modes Motorola's FPSP sets (8.8.19).
# RETAG: the source's tags from this word's result - a packed operand, which
# the CU cannot classify, after the APU has converted it.
CTL = Enum('NONE', 'RELEASE', 'OPWANT', 'STORED', 'CHECKPOINT', 'END',
           'HANDOFF', 'SAVED', 'RESTORED',
           'RP_PREC', 'RP_EXT', 'RP_SGL', 'RP_DBL', 'RP_DFMT', 'RP_SGLX',
           'RM_FPCR', 'RM_RN', 'RM_RZ', 'RM_RM', 'RM_RP', 'RETAG')

# Moving a value between B's fields, before the barrel shifter: E2M puts
# B's exponent (sign-extended) in its mantissa - FGETEXP; M2E puts the low
# 18 bits of B's mantissa (two's complement) in its exponent - FSCALE.
BX = Enum('NONE', 'E2M', 'M2E')

NANO = Format(
    'nano',
    Field('asrc', 2, ASRC),
    Field('bsrc', 4, BSRC),
    Field('fpsel', 2, FPSEL),
    Field('shk', 2, SHK),
    Field('sha', 3, SHA),
    Field('emode', 2, EMODE),
    Field('alu', 4, ALU),
    Field('dir', 2, DIR),
    Field('cin', 1),
    Field('osh', 3, OSH),
    Field('qop', 2, QOP),
    Field('dst', 4, DST),
    Field('sgn', 3, SGN),
    Field('stk', 2, STK),
    Field('dl', 1, doc='latch DFLAG from this result\'s N'),
    Field('a2', 1, doc='A\'s mantissa shifted left one place before the ALU (the square root\'s 2W)'),
    Field('bx', 2, BX),
    Field('rnd', 3, RNDM),
    Field('fpsr', 3, FPSR),
    Field('lcop', 3, LCOP),
    Field('ctl', 5, CTL),
    Field('lit', 8, doc='shared literal: shift amount, LC load, EXC bits'),
)

# The EXC byte's bits (FPSR 15-8), for `exc=` in the source (8.6.2).
EXC_BITS = {'BSUN': 7, 'SNAN': 6, 'OPERR': 5, 'OVFL': 4, 'UNFL': 3, 'DZ': 2,
            'INEX2': 1, 'INEX1': 0}


# -- the constant ROM word (8.8.10) --------------------------------------------------
# Bits 66-0 the mantissa, 84-67 the exponent, 85 the sign, 87-86 the
# direction (FMOVECR: 0 exact, 1 the true value above the image, 2 below).

KWORD_BITS = 88
DIR_EXACT, DIR_ABOVE, DIR_BELOW = 0, 1, 2


def kword(sign, exp, mant, direction=0):
    assert 0 <= mant < 1 << MANT_BITS, mant
    exp &= (1 << EXP_BITS) - 1
    return (direction << 86) | (sign << 85) | (exp << MANT_BITS) | mant


def kword_fields(w):
    mant = w & ((1 << MANT_BITS) - 1)
    exp = (w >> MANT_BITS) & ((1 << EXP_BITS) - 1)
    if exp >> (EXP_BITS - 1):
        exp -= 1 << EXP_BITS
    return (w >> 85) & 1, exp, mant, (w >> 86) & 3


# -- the entry table (8.8.11: Figure 1-9's "µPC select PLA") ---------------------------
# Index: bit 9 = 0 for a general instruction - bits 8-6 the source kind
# (0: a register, 1-7: a memory format 000-110 plus one), bits 5-0 the
# opmode; bit 9 = 1 for the others - $200 FMOVECR, $208 + format for
# FMOVE FPm,<ea>.

def entry_general(kind, opmode):
    """kind: 'reg' or a format name L S X P W D B."""
    k = 0 if kind == 'reg' else FMT[kind] + 1
    assert 0 <= opmode < 0x40
    return (k << 6) | opmode


ENTRY_FMOVECR = 0x200


def entry_store(fmt):
    return 0x208 + FMT[fmt]


# -- the Verilog header (item 7) -------------------------------------------------------

def verilog_header():
    out = ['// Generated by tools/fpu_ucode/fields.py - do not edit.',
           '// The 68882 microword, nanoword and constant formats (plan 8.8.11).', '']
    for fmt in (MICRO, NANO):
        p = fmt.name.upper()
        out.append('`define %s_W %d' % (p, fmt.width))
        for f in fmt.fields.values():
            out.append('`define %s_%s %d:%d' % (p, f.name.upper(), f.lsb + f.width - 1, f.lsb))
            if f.enum is not None:
                for i, n in enumerate(f.enum.names):
                    out.append('`define %s_%s_%s %d\'d%d' % (p, f.name.upper(), n, f.width, i))
        out.append('')
    out.append('`define COND_W 6')
    for i, n in enumerate(COND.names):
        out.append('`define COND_%s 6\'d%d' % (n, i))
    out.append('')
    for i, n in enumerate(DISPATCH.names):
        out.append('`define DISP_%s 6\'d%d' % (n, i))
    out.append('')
    out.append('`define KWORD_W %d' % KWORD_BITS)
    return '\n'.join(out) + '\n'
