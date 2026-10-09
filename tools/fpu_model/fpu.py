"""The 68882 as software sees it, one instruction at a time: the
specification layer.

`FPU` holds FP0-FP7, FPCR, FPSR and FPIAR and executes the general
(type 000) instructions from their command words, the conditionals'
predicates, FMOVECR, and the control-register and FMOVEM transfers.  Each
call returns an `Outcome`: the exception the chip would report (its vector,
and whether the MPU sees it pre- or mid-instruction), the exceptional
operand an FSAVE would hold, and any value stored to the MPU.  The dialog
over the coprocessor interface, the state frames' timing and the CU's
concurrency are the RTL's.

Citations: UM pages and sections.  Switches: switches.py.
"""

from dataclasses import dataclass
from typing import Optional, List

from xreal import (Ext, EMAX, BIAS, M64, J_BIT, Q_BIT, NAN, inf, zero,
                   ext_from_exact, ext_bits96, from_int, from_single,
                   from_double)
from rounding import (RN, RZ, RM, RP, EXT, SGL, DBL, SGL_MANT, DBL_MANT,
                      PREC_FMT, Fmt, post_process, round_to_quantum,
                      round_integer)
import constants
import packed
import transcend
from switches import Switches, DEFAULT

# FPSR.
CC_N, CC_Z, CC_I, CC_NAN = 1 << 27, 1 << 26, 1 << 25, 1 << 24
CC_MASK = 0x0F000000
QUOT_MASK = 0x00FF0000
EXC_MASK = 0x0000FF00
AEXC_MASK = 0x000000F8
FPSR_MASK = 0x0FFFFFF8          # bits 31-28 and 2-0 read zero (UM 4-70)
FPCR_MASK = 0x0000FFF0          # bits 31-16 and 3-0 read zero

# EXC and ENABLE bits (bit n of the byte at 15-8).
BSUN, SNAN, OPERR, OVFL, UNFL, DZ, INEX2, INEX1 = (1 << b for b in
                                                   range(15, 7, -1))
# AEXC.
A_IOP, A_OVFL, A_UNFL, A_DZ, A_INEX = (1 << b for b in range(7, 2, -1))

# Vectors in priority order; INEX is one vector for both bits.
V_BSUN, V_INEX, V_DZ, V_UNFL, V_OPERR, V_OVFL, V_SNAN = 48, 49, 50, 51, 52, 53, 54
V_FLINE = 11

# The formats of the source/destination specifier (Tables 4-14, 4-15).
FMT_L, FMT_S, FMT_X, FMT_P, FMT_W, FMT_D, FMT_B, FMT_PK = range(8)
INT_BITS = {FMT_L: 32, FMT_W: 16, FMT_B: 8}


class Unmodelled(Exception):
    """An instruction whose result is not in the model yet (packed decimal,
    the transcendentals), or a switch set to 'unknown'."""


@dataclass
class Outcome:
    vector: Optional[int] = None    # the exception taken, if any
    when: Optional[str] = None      # 'pre' or 'mid'
    xop: Optional[Ext] = None       # the exceptional operand
    store: object = None            # a value moved to the MPU/memory
    cond: Optional[bool] = None     # a conditional's answer


class FPU:
    def __init__(self, switches: Switches = DEFAULT):
        self.sw = switches
        self.reset()

    # -- reset: FP0-FP7 nonsignaling NaNs, the control registers 0.
    def reset(self):
        self.fp: List[Ext] = [Ext(*self.sw.reset_nan)] * 8
        self.fpcr = 0
        self.fpsr = 0
        self.fpiar = 0
        self.null_state = True

    # -- FPCR fields
    @property
    def rnd(self):
        return (self.fpcr >> 4) & 3

    @property
    def prec_fmt(self):
        return PREC_FMT[(self.fpcr >> 6) & 3]

    # -- FPSR helpers ------------------------------------------------------
    def _set_fpcc(self, x: Ext):
        """Table 2-1: N Z I NAN from the result's data type."""
        cc = CC_N if x.s else 0
        if x.is_nan:
            cc |= CC_NAN
        elif x.is_inf:
            cc |= CC_I
        elif x.is_zero:
            cc |= CC_Z
        self.fpsr = (self.fpsr & ~CC_MASK) | cc

    def _accrue(self, exc):
        """6.1.10: IOP |= BSUN|SNAN|OPERR; OVFL |= OVFL; UNFL |= UNFL&INEX2;
        DZ |= DZ; INEX |= INEX1|INEX2|OVFL."""
        a = 0
        if exc & (BSUN | SNAN | OPERR):
            a |= A_IOP
        if exc & OVFL:
            a |= A_OVFL
        if (exc & UNFL) and (exc & INEX2):
            a |= A_UNFL
        if exc & DZ:
            a |= A_DZ
        if exc & (INEX1 | INEX2 | OVFL):
            a |= A_INEX
        self.fpsr |= a

    def _trap(self, exc):
        """The highest-priority enabled exception (6.1.9), or None.  The
        inexact trap: [(OVFL | INEX2) & EN.INEX2] | [INEX1 & EN.INEX1]
        (6.1.10)."""
        en = self.fpcr & EXC_MASK
        for bit, vec in ((BSUN, V_BSUN), (SNAN, V_SNAN), (OPERR, V_OPERR),
                         (OVFL, V_OVFL), (UNFL, V_UNFL), (DZ, V_DZ)):
            if exc & en & bit:
                return vec
        if ((exc & (OVFL | INEX2)) and (en & INEX2)) or \
                ((exc & INEX1) and (en & INEX1)):
            return V_INEX
        return None

    def _begin(self, pc):
        """The start of every instruction that can raise an exception: EXC
        cleared (2.3.3); FPIAR loaded with the instruction's address unless
        all arithmetic exceptions are disabled (2.4)."""
        self.fpsr &= ~EXC_MASK
        if pc is not None and (self.fpcr & 0x7F00):
            self.fpiar = pc & 0xFFFFFFFF
        self.null_state = False

    def _finish_reg(self, dst, result, exc, src, xop_round=None,
                    write=True, fpcc=True):
        """End of an instruction with a register destination: the trap,
        the register (unchanged under an enabled SNAN, OPERR or DZ trap,
        6.1.2/6.1.3/6.1.6), FPCC, AEXC."""
        self.fpsr |= exc
        vec = self._trap(exc)
        blocked = bool(exc & self.fpcr & (SNAN | OPERR | DZ))
        if write and not blocked:
            self.fp[dst] = result
        if fpcc and (not blocked or self.sw.fpcc_on_trap == 'result'):
            self._set_fpcc(result)
        self._accrue(exc)
        xop = None
        if vec in (V_SNAN, V_OPERR, V_DZ):
            xop = src                   # the source, converted to extended
        elif vec in (V_OVFL, V_UNFL):
            xop = xop_round
        return Outcome(vector=vec, when='pre' if vec else None, xop=xop)

    # -- operand conversion in --------------------------------------
    def convert_in(self, fmt, raw):
        """The source operand of an <ea>-to-register instruction as
        extended: (Ext, INEX1)."""
        if fmt in INT_BITS:
            return from_int(raw, INT_BITS[fmt]), False
        if fmt == FMT_S:
            return from_single(raw), False
        if fmt == FMT_D:
            return from_double(raw), False
        if fmt == FMT_X:
            return ext_bits96(raw), False
        # Packed: to extended regardless of PREC, by RND (6.1.8), INEX1 if
        # inexact - the algorithm layer (packed.py).
        return packed.decode_in(raw, self.rnd, self._pten())

    def _pten(self):
        return packed.PTEN_FPSP if self.sw.pten_tables == 'fpsp' else packed.PTEN_ROM

    # -- decode ----------------------------------------------------
    REDUNDANT = {0x05: 0x04, 0x07: 0x06, 0x0B: 0x0A, 0x13: 0x12, 0x17: 0x16,
                 0x1B: 0x1A, 0x29: 0x28, 0x2A: 0x28, 0x2B: 0x28, 0x2C: 0x28,
                 0x2D: 0x28, 0x2E: 0x28, 0x2F: 0x28, 0x39: 0x38, 0x3C: 0x38,
                 0x3D: 0x38, 0x3B: 0x3A, 0x3E: 0x3A, 0x3F: 0x3A}

    def opmode(self, ext):
        """The operation an opmode names, after switches.py item 6; None for an
        F-line (opmodes $40-$7F)."""
        if ext >= 0x40:
            return None
        if ext in self.REDUNDANT:
            if self.sw.redundant_opmodes != 'winuae':
                raise Unmodelled('redundant opmode $%02X' % ext)
            return self.REDUNDANT[ext]
        return ext

    def general(self, cmd, operand=None, pc=None, dreg=0):
        """Execute a general instruction from its command word.

        operand: the source's raw bits for opclass 010, a list of longwords
        for 100, a list of 96-bit images for FMOVEM to the registers (110).
        dreg: the data register for a dynamic k-factor or FMOVEM list.
        """
        opclass = cmd >> 13
        rx = (cmd >> 10) & 7
        ry = (cmd >> 7) & 7
        ext = cmd & 0x7F
        if opclass == 0b000:
            op = self.opmode(ext)
            if op is None:
                return Outcome(vector=V_FLINE, when='pre')
            return self.arith(op, ry, self.fp[rx], False, pc, cmd)
        if opclass == 0b001:
            return Outcome(vector=V_FLINE, when='pre')         # UM 4.7.1.7
        if opclass == 0b010:
            if rx == 0b111:
                return self.fmovecr(ext, ry, pc)
            op = self.opmode(ext)
            if op is None:
                return Outcome(vector=V_FLINE, when='pre')
            src, inex1 = self.convert_in(rx, operand)
            return self.arith(op, ry, src, inex1, pc, cmd)
        if opclass == 0b011:
            return self.fmove_out(rx, ry, ext, pc, dreg)
        if opclass == 0b100:
            return self.fmove_cr_in(rx, operand)
        if opclass == 0b101:
            return self.fmove_cr_out(rx)
        return self.fmovem(cmd, operand, dreg)

    # -- the arithmetic instructions --------------------------------
    MONADIC = {0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x09, 0x0A, 0x0C,
               0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x14, 0x15, 0x16, 0x18,
               0x19, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F, 0x3A} | set(range(0x30, 0x38))

    def arith(self, op, dst, src, inex1, pc, cmd=0):
        self._begin(pc)
        exc = INEX1 if inex1 else 0
        rnd, fmt = self.rnd, self.prec_fmt
        d = self.fp[dst]
        monadic = op in self.MONADIC

        # NaNs (4.5.4): SNAN for a signaling operand; the result is the one
        # NaN, or the destination's when both are NaNs; made nonsignaling.
        nans = [x for x in ((src,) if monadic else (d, src)) if x.is_nan]
        if nans:
            if any(x.is_snan for x in nans):
                exc |= SNAN
            res = (d if (not monadic and d.is_nan) else src).quiet()
            if op == 0x38:                      # FCMP: FPCC only
                return self._fcmp_nan(res, exc, src)
            if op == 0x3A:                      # FTST
                return self._finish_reg(dst, res, exc, src, write=False)
            if op in (0x21, 0x25) and self.sw.quotient_special == 'winuae':
                self.fpsr &= ~QUOT_MASK
            if 0x30 <= op <= 0x37:                  # FSINCOS: the NaN to both
                return self._sincos_write(dst, op & 7, res, res, exc, src, None)
            return self._finish_reg(dst, res, exc, src)

        if op == 0x3A:                          # FTST: FPCC from the source
            return self._finish_reg(dst, src, exc, src, write=False)
        if op == 0x38:
            return self._fcmp(d, src, exc)

        if 0x30 <= op <= 0x37:
            return self._op_fsincos(dst, op & 7, src, exc, rnd, fmt)
        handler = self.DYADIC_OPS.get(op) if not monadic else self.MONADIC_OPS.get(op)
        if handler is None:
            raise Unmodelled('opmode $%02X' % op)
        return handler(self, dst, d, src, exc, rnd, fmt)

    # -- the rounding step common to them ---------------------------------
    def _round(self, s, m, e, sticky, fmt, rnd, exc, suppress=0):
        """Post-process an exact nonzero intermediate to a register: the
        result, the EXC bits, the exceptional operand."""
        r = post_process(s, m, e, sticky, fmt, rnd, 'reg')
        if r.unfl:
            exc |= UNFL
        if r.ovfl:
            exc |= OVFL
        if r.inex:
            exc |= INEX2
        exc &= ~suppress
        return r.ext(), exc, r.xop

    def _rounded_value(self, dst, x: Ext, exc, src, rnd, fmt, suppress=0):
        """Write x (finite or special) after the post-processing."""
        if not x.is_finite or x.is_zero:
            if x.is_zero:
                x = zero(x.s)
            return self._finish_reg(dst, x, exc, src)
        s, m, e = x.exact()
        res, exc, xop = self._round(s, m, e, False, fmt, rnd, exc, suppress)
        return self._finish_reg(dst, res, exc, src, xop)

    # Monadic --------------------------------------------------------------
    def _op_fmove(self, dst, d, src, exc, rnd, fmt):
        if self.sw.fmove_in_range == 'table':
            fmt = {SGL: SGL_MANT, DBL: DBL_MANT}.get(fmt, fmt)
        return self._rounded_value(dst, src, exc, src, rnd, fmt)

    def _op_fabs(self, dst, d, src, exc, rnd, fmt):
        if self.sw.fmove_in_range == 'table':
            fmt = {SGL: SGL_MANT, DBL: DBL_MANT}.get(fmt, fmt)
        return self._rounded_value(dst, Ext(0, src.e, src.m), exc, src, rnd, fmt)

    def _op_fneg(self, dst, d, src, exc, rnd, fmt):
        if self.sw.fmove_in_range == 'table':
            fmt = {SGL: SGL_MANT, DBL: DBL_MANT}.get(fmt, fmt)
        return self._rounded_value(dst, src.neg(), exc, src, rnd, fmt)

    def _fint(self, dst, src, exc, int_rnd, rnd, fmt):
        if not src.is_finite or src.is_zero:
            return self._rounded_value(dst, src, exc, src, rnd, fmt)
        s, m, e = src.exact()
        mode = self.sw.fint_prec
        if mode == 'once' and fmt.p < 64:
            E = m.bit_length() - 1 + e
            q = max(0, E - (fmt.p - 1))
            K, inexact = round_to_quantum(s, m, e, False, q, int_rnd)
            if inexact:
                exc |= INEX2
            if K == 0:
                return self._finish_reg(dst, zero(s), exc, src)
            res, exc, xop = self._round(s, K, q, False, fmt, rnd, exc)
            return self._finish_reg(dst, res, exc, src, xop)
        K, inexact = round_integer(s, m, e, False, int_rnd)
        if inexact:
            exc |= INEX2
        if K == 0:
            return self._finish_reg(dst, zero(s), exc, src)
        if mode == 'int_only':
            fmt = EXT
        res, exc, xop = self._round(s, K, 0, False, fmt, rnd, exc)
        return self._finish_reg(dst, res, exc, src, xop)

    def _op_fint(self, dst, d, src, exc, rnd, fmt):
        return self._fint(dst, src, exc, rnd, rnd, fmt)

    def _op_fintrz(self, dst, d, src, exc, rnd, fmt):
        return self._fint(dst, src, exc, RZ, rnd, fmt)

    def _op_fsqrt(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, zero(src.s), exc, src)
        if src.s:                                   # x < 0, or -inf
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if src.is_inf:
            return self._finish_reg(dst, inf(0), exc, src)
        _, m, e = src.exact()
        if e & 1:
            m, e = m << 1, e - 1
        k = max(0, 140 - m.bit_length()) // 2 + 1     # at least 70 root bits
        M = m << (2 * k)
        r = _isqrt(M)
        sticky = r * r != M
        res, exc, xop = self._round(0, r, (e - 2 * k) // 2, sticky, fmt, rnd, exc)
        return self._finish_reg(dst, res, exc, src, xop)

    def _op_fgetexp(self, dst, d, src, exc, rnd, fmt):
        if src.is_inf:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if src.is_zero:
            return self._finish_reg(dst, zero(src.s), exc, src)
        s, m, e = src.exact()
        E = m.bit_length() - 1 + e                 # of the normalized input
        return self._rounded_value(dst, ext_from_exact(1 if E < 0 else 0, abs(E), 0),
                                   exc, src, rnd, fmt)

    def _op_fgetman(self, dst, d, src, exc, rnd, fmt):
        if src.is_inf:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if src.is_zero:
            return self._finish_reg(dst, zero(src.s), exc, src)
        s, m, e = src.exact()
        n = m.bit_length()
        x = Ext(s, BIAS, m << (64 - n))            # in [1.0, 2.0)
        if self.sw.fgetman_prec == 'rounded':
            return self._rounded_value(dst, x, exc, src, rnd, fmt)
        return self._finish_reg(dst, x, exc, src)

    # The transcendentals (the algorithms, transcend.py) ---------------------
    def _computed(self, r, exc, rnd, fmt):
        """A transcendental's I67 result through the post-processing, with
        the sticky bit set: INEX2 for every computed result (UM 4.3.2).
        An exact zero stays a signed zero."""
        if r.is_zero():
            return zero(r.s), exc, None
        return self._round(r.s, r.m, r.e, True, fmt, rnd, exc)

    def _transcend(self, dst, src, exc, rnd, fmt, fn):
        res, exc, xop = self._computed(fn(transcend.i_from_ext(src)), exc, rnd, fmt)
        return self._finish_reg(dst, res, exc, src, xop)

    def _halfpi(self, s, exc, rnd, fmt):
        return self._computed(transcend.HALFPI.neg() if s else transcend.HALFPI, exc, rnd, fmt)

    def _op_fsinh(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero or src.is_inf:
            return self._finish_reg(dst, src, exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.sinh)

    def _op_flognp1(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if src.is_inf:
            return self._finish_reg(dst, NAN if src.s else src, exc | (OPERR if src.s else 0), src)
        v = transcend.i_from_ext(src)
        if src.s:
            c = transcend.i_add(transcend.ONE_I, v)          # 1 + x
            if c.is_zero():                                   # switches.py item 2
                if self.sw.flognp1_minus_one == 'manual':
                    return self._finish_reg(dst, NAN, exc | DZ, src)
                return self._finish_reg(dst, inf(1), exc | DZ, src)
            if c.s:
                return self._finish_reg(dst, NAN, exc | OPERR, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.lognp1)

    def _op_fetoxm1(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if src.is_inf:
            return self._finish_reg(dst, Ext(1, BIAS, J_BIT) if src.s else src, exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.etoxm1)

    def _op_ftanh(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if src.is_inf:
            return self._finish_reg(dst, Ext(src.s, BIAS, J_BIT), exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.tanh)

    def _op_fatan(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if src.is_inf:
            res, exc, xop = self._halfpi(src.s, exc, rnd, fmt)
            return self._finish_reg(dst, res, exc, src, xop)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.atan)

    def _unit_domain(self, src):
        """|x| > 1 or an infinity: outside asin's, acos's and atanh's domain."""
        if src.is_inf:
            return True
        s, m, e = src.exact()
        return (m << e if e >= 0 else 0) > 1 or (e < 0 and m > (1 << -e))

    def _op_fasin(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if self._unit_domain(src):
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.asin)

    def _op_facos(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            res, exc, xop = self._halfpi(0, exc, rnd, fmt)
            return self._finish_reg(dst, res, exc, src, xop)
        if self._unit_domain(src):
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.acos)

    def _op_fatanh(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if self._unit_domain(src):
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        s, m, e = src.exact()
        if (m << e if e >= 0 else (m >> -e if not m & ((1 << -e) - 1) else -1)) == 1:
            # x = +/-1 - switches.py item 1: as printed, +1 gives -inf and -1
            # gives +inf; 'ieee', sign(x) x inf.  DZ either way.
            sign = (s ^ 1) if self.sw.fatanh_one == 'manual' else s
            return self._finish_reg(dst, inf(sign), exc | DZ, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.atanh)

    def _trig(self, dst, src, exc, rnd, fmt, fn):
        if src.is_zero:
            return self._finish_reg(dst, src, exc, src)
        if src.is_inf:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        return self._transcend(dst, src, exc, rnd, fmt, fn)

    def _op_fsin(self, dst, d, src, exc, rnd, fmt):
        return self._trig(dst, src, exc, rnd, fmt, lambda v: transcend.sincos(v)[0])

    def _op_ftan(self, dst, d, src, exc, rnd, fmt):
        return self._trig(dst, src, exc, rnd, fmt, transcend.tan)

    def _op_fcos(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, Ext(0, BIAS, J_BIT), exc, src)
        if src.is_inf:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        return self._transcend(dst, src, exc, rnd, fmt, lambda v: transcend.sincos(v)[1])

    def _exp_like(self, dst, src, exc, rnd, fmt, fn):
        if src.is_zero:
            return self._finish_reg(dst, Ext(0, BIAS, J_BIT), exc, src)
        if src.is_inf:
            return self._finish_reg(dst, zero(0) if src.s else src, exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, fn)

    def _op_fetox(self, dst, d, src, exc, rnd, fmt):
        return self._exp_like(dst, src, exc, rnd, fmt, transcend.etox)

    def _op_ftwotox(self, dst, d, src, exc, rnd, fmt):
        return self._exp_like(dst, src, exc, rnd, fmt, transcend.twotox)

    def _op_ftentox(self, dst, d, src, exc, rnd, fmt):
        return self._exp_like(dst, src, exc, rnd, fmt, transcend.tentox)

    def _log_like(self, dst, src, exc, rnd, fmt, fn):
        if src.is_zero:
            return self._finish_reg(dst, inf(1), exc | DZ, src)
        if src.s:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if src.is_inf:
            return self._finish_reg(dst, src, exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, fn)

    def _op_flogn(self, dst, d, src, exc, rnd, fmt):
        return self._log_like(dst, src, exc, rnd, fmt, transcend.logn)

    def _op_flog10(self, dst, d, src, exc, rnd, fmt):
        return self._log_like(dst, src, exc, rnd, fmt, transcend.log10)

    def _op_flog2(self, dst, d, src, exc, rnd, fmt):
        return self._log_like(dst, src, exc, rnd, fmt, transcend.log2)

    def _op_fcosh(self, dst, d, src, exc, rnd, fmt):
        if src.is_zero:
            return self._finish_reg(dst, Ext(0, BIAS, J_BIT), exc, src)
        if src.is_inf:
            return self._finish_reg(dst, inf(0), exc, src)
        return self._transcend(dst, src, exc, rnd, fmt, transcend.cosh)

    def _sincos_write(self, fps, fpc, sin_r, cos_r, exc, src, xop):
        """FSINCOS's two destinations: FPc gets the cosine, then FPs the sine,
        so FPs = FPc keeps the sine; FPCC from the sine (4-104)."""
        self.fpsr |= exc
        vec = self._trap(exc)
        blocked = bool(exc & self.fpcr & (SNAN | OPERR | DZ))
        if not blocked:
            self.fp[fpc] = cos_r
            self.fp[fps] = sin_r
        if not blocked or self.sw.fpcc_on_trap == 'result':
            self._set_fpcc(sin_r)
        self._accrue(exc)
        out = None
        if vec in (V_SNAN, V_OPERR, V_DZ):
            out = src
        elif vec in (V_OVFL, V_UNFL):
            out = xop
        return Outcome(vector=vec, when='pre' if vec else None, xop=out)

    def _op_fsincos(self, fps, fpc, src, exc, rnd, fmt):
        if src.is_zero:
            return self._sincos_write(fps, fpc, src, Ext(0, BIAS, J_BIT), exc, src, None)
        if src.is_inf:
            return self._sincos_write(fps, fpc, NAN, NAN, exc | OPERR, src, None)
        s, c = transcend.sincos(transcend.i_from_ext(src))
        sr, exc_s, xop = self._computed(s, exc, rnd, fmt)
        cr, exc_c, _ = self._computed(c, exc, rnd, fmt)
        # UNFL is the sine's (the cosine cannot underflow); INEX2 either's.
        exc = exc_s | (exc_c & INEX2)
        return self._sincos_write(fps, fpc, sr, cr, exc, src, xop)

    MONADIC_OPS = {0x00: _op_fmove, 0x01: _op_fint, 0x03: _op_fintrz,
                   0x04: _op_fsqrt, 0x18: _op_fabs, 0x1A: _op_fneg,
                   0x1E: _op_fgetexp, 0x1F: _op_fgetman,
                   0x02: _op_fsinh, 0x06: _op_flognp1, 0x08: _op_fetoxm1,
                   0x09: _op_ftanh, 0x0A: _op_fatan, 0x0C: _op_fasin,
                   0x0D: _op_fatanh, 0x0E: _op_fsin, 0x0F: _op_ftan,
                   0x10: _op_fetox, 0x11: _op_ftwotox, 0x12: _op_ftentox,
                   0x14: _op_flogn, 0x15: _op_flog10, 0x16: _op_flog2,
                   0x19: _op_fcosh, 0x1C: _op_facos, 0x1D: _op_fcos}

    # Dyadic ---------------------------------------------------------------
    def _addsub(self, dst, d, src, exc, rnd, fmt, sub):
        b = src.neg() if sub else src
        if d.is_inf or b.is_inf:
            if d.is_inf and b.is_inf and d.s != b.s:
                return self._finish_reg(dst, NAN, exc | OPERR, src)
            return self._finish_reg(dst, inf(d.s if d.is_inf else b.s), exc, src)
        if d.is_zero and b.is_zero:
            # Like signs keep theirs; unlike give +0, -0 in RM (4-22, 4-111).
            s = d.s if d.s == b.s else (1 if rnd == RM else 0)
            return self._finish_reg(dst, zero(s), exc, src)
        v = _signed(d) + _signed(b)                  # exact, as (num, e)
        num, e = v
        if num == 0:
            return self._finish_reg(dst, zero(1 if rnd == RM else 0), exc, src)
        res, exc, xop = self._round(1 if num < 0 else 0, abs(num), e, False,
                                    fmt, rnd, exc)
        return self._finish_reg(dst, res, exc, src, xop)

    def _op_fadd(self, dst, d, src, exc, rnd, fmt):
        return self._addsub(dst, d, src, exc, rnd, fmt, False)

    def _op_fsub(self, dst, d, src, exc, rnd, fmt):
        return self._addsub(dst, d, src, exc, rnd, fmt, True)

    def _mul(self, dst, d, src, exc, rnd, fmt, sgl=False):
        s = d.s ^ src.s
        if (d.is_zero and src.is_inf) or (d.is_inf and src.is_zero):
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if d.is_inf or src.is_inf:
            return self._finish_reg(dst, inf(s), exc, src)
        if d.is_zero or src.is_zero:
            return self._finish_reg(dst, zero(s), exc, src)
        _, m1, e1 = d.exact()
        _, m2, e2 = src.exact()
        if sgl:
            m1, e1 = self._sgl_trunc(m1, e1)
            m2, e2 = self._sgl_trunc(m2, e2)
            fmt = SGL_MANT
        res, exc, xop = self._round(s, m1 * m2, e1 + e2, False, fmt, rnd, exc)
        return self._finish_reg(dst, res, exc, src, xop)

    def _sgl_trunc(self, m, e):
        """FSGLMUL/FSGLDIV's inputs: the normalized mantissa truncated,
        unrounded, to sgl_truncate_bits bits."""
        n = m.bit_length()
        keep = self.sw.sgl_truncate_bits
        if n > keep:
            return m >> (n - keep), e + (n - keep)
        return m, e

    def _div(self, dst, d, src, exc, rnd, fmt, sgl=False):
        s = d.s ^ src.s
        if (d.is_zero and src.is_zero) or (d.is_inf and src.is_inf):
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if d.is_inf:
            return self._finish_reg(dst, inf(s), exc, src)
        if src.is_zero:                     # range / 0: DZ (4-40)
            return self._finish_reg(dst, inf(s), exc | DZ, src)
        if d.is_zero or src.is_inf:
            return self._finish_reg(dst, zero(s), exc, src)
        _, m1, e1 = d.exact()
        _, m2, e2 = src.exact()
        if sgl:
            m1, e1 = self._sgl_trunc(m1, e1)
            m2, e2 = self._sgl_trunc(m2, e2)
            fmt = SGL_MANT
        sh = max(0, 80 + m2.bit_length() - m1.bit_length())
        q, r = divmod(m1 << sh, m2)
        res, exc, xop = self._round(s, q, e1 - e2 - sh, r != 0, fmt, rnd, exc)
        return self._finish_reg(dst, res, exc, src, xop)

    def _op_fmul(self, dst, d, src, exc, rnd, fmt):
        return self._mul(dst, d, src, exc, rnd, fmt)

    def _op_fsglmul(self, dst, d, src, exc, rnd, fmt):
        return self._mul(dst, d, src, exc, rnd, fmt, sgl=True)

    def _op_fdiv(self, dst, d, src, exc, rnd, fmt):
        return self._div(dst, d, src, exc, rnd, fmt)

    def _op_fsgldiv(self, dst, d, src, exc, rnd, fmt):
        return self._div(dst, d, src, exc, rnd, fmt, sgl=True)

    def _modrem(self, dst, d, src, exc, rnd, fmt, nearest):
        """FMOD (N toward zero, 4-62) and FREM (N to nearest, 4-86)."""
        qs = d.s ^ src.s
        special_q = self.sw.quotient_special == 'winuae'

        def set_q(n, sign):
            self.fpsr = (self.fpsr & ~QUOT_MASK) | (sign << 23) | ((n & 0x7F) << 16)

        suppress = 0
        if self.sw.rem_scale_inex == 'table':
            suppress = INEX2 if nearest else OVFL
        if src.is_zero or d.is_inf:
            if special_q:
                set_q(0, 0)
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if d.is_zero:
            if special_q:
                set_q(0, qs)
            return self._finish_reg(dst, zero(d.s), exc, src)
        if src.is_inf:
            # FPn re-rounded to PREC (note 2).
            if special_q:
                set_q(0, qs)
            return self._rounded_value(dst, d, exc, src, rnd, fmt, suppress)
        _, m1, e1 = d.exact()
        _, m2, e2 = src.exact()
        # |d| / |src| as a ratio of integers at a common exponent.
        e0 = min(e1, e2)
        a, b = m1 << (e1 - e0), m2 << (e2 - e0)
        N, r = divmod(a, b)
        if nearest and (2 * r > b or (2 * r == b and (N & 1))):
            N += 1
            r -= b                              # r now negative or zero
        set_q(N, qs)
        if r == 0:
            return self._finish_reg(dst, zero(d.s), exc, src)
        s = d.s ^ (1 if r < 0 else 0)
        res, exc, xop = self._round(s, abs(r), e0, False, fmt, rnd, exc, suppress)
        return self._finish_reg(dst, res, exc, src, xop)

    def _op_fmod(self, dst, d, src, exc, rnd, fmt):
        return self._modrem(dst, d, src, exc, rnd, fmt, False)

    def _op_frem(self, dst, d, src, exc, rnd, fmt):
        return self._modrem(dst, d, src, exc, rnd, fmt, True)

    def _op_fscale(self, dst, d, src, exc, rnd, fmt):
        suppress = INEX2 if self.sw.rem_scale_inex == 'table' else 0
        if src.is_inf:
            return self._finish_reg(dst, NAN, exc | OPERR, src)
        if d.is_zero or d.is_inf:
            return self._finish_reg(dst, d, exc, src)
        if src.is_zero:
            return self._rounded_value(dst, d, exc, src, rnd, fmt, suppress)
        s2, m2, e2 = src.exact()
        n = m2 >> -e2 if e2 < 0 else m2 << e2        # chopped toward zero
        if s2:
            n = -n
        # "When the absolute value of the source operand is >= 2^14, an
        # overflow or underflow always results" (4-93): the scale is pushed
        # far enough that it does whatever FPn is, and held to 2^16 - past
        # the 17-bit intermediate's catastrophic limit ($A000, 6-10), where
        # a larger scale changes nothing a program can see.
        if n >= 1 << 14:
            n = min(max(n, (1 << 15) + 64), 1 << 16)
        elif n <= -(1 << 14):
            n = max(min(n, -((1 << 15) + 64)), -(1 << 16))
        s, m, e = d.exact()
        res, exc, xop = self._round(s, m, e + n, False, fmt, rnd, exc, suppress)
        return self._finish_reg(dst, res, exc, src, xop)

    DYADIC_OPS = {0x20: _op_fdiv, 0x21: _op_fmod, 0x22: _op_fadd,
                  0x23: _op_fmul, 0x24: _op_fsgldiv, 0x25: _op_frem,
                  0x26: _op_fscale, 0x27: _op_fsglmul, 0x28: _op_fsub}

    # FCMP (4-32) -----------------------------------------------------------
    def _fcmp(self, d, src, exc):
        """FPCC from dest - src; I always cleared; the table of 4-32."""
        if d.is_inf or src.is_inf:
            if d.is_inf and src.is_inf:
                cc = (CC_N | CC_Z) if (d.s and src.s) else (CC_Z if d.s == src.s else (CC_N if d.s else 0))
            elif d.is_inf:
                cc = CC_N if d.s else 0
            else:
                cc = 0 if src.s else CC_N
        elif d.is_zero and src.is_zero:
            cc = CC_Z | (CC_N if d.s else 0)
        else:
            diff = _cmp_exact(d, src)
            cc = CC_Z if diff == 0 else (CC_N if diff < 0 else 0)
        self.fpsr = (self.fpsr & ~CC_MASK) | cc | exc
        self._accrue(exc)
        vec = self._trap(exc)
        return Outcome(vector=vec, when='pre' if vec else None,
                       xop=src if vec else None)

    def _fcmp_nan(self, res, exc, src):
        cc = CC_NAN
        if self.sw.fcmp_nan_sign == 'sign' and res.s:
            cc |= CC_N
        self.fpsr = (self.fpsr & ~CC_MASK) | cc | exc
        self._accrue(exc)
        vec = self._trap(exc)
        return Outcome(vector=vec, when='pre' if vec else None,
                       xop=src if vec else None)

    # -- FMOVECR (4-72) -----------------------------------------------------
    def fmovecr(self, off, dst, pc=None):
        if off >= 0x40 and self.sw.fmovecr_undefined == 'winuae':
            # WinUAE: offsets $40-$7F take the F-line on a 6888x - decoded
            # before the instruction starts, like every other F-line, so
            # EXC is not cleared.
            return Outcome(vector=V_FLINE, when='pre')
        self._begin(pc)
        rnd, fmt = self.rnd, self.prec_fmt
        if off in constants.DOCUMENTED:
            if self.sw.fmovecr_documented == 'winuae':
                return self._fmovecr_winuae_doc(off, dst, rnd)
            if self.sw.fmovecr_documented == 'rom64':
                return self._fmovecr_rom64(off, dst, rnd, fmt)
            m, e, sticky = constants.DOCUMENTED[off]
            if m == 0:
                return self._finish_reg(dst, zero(0), 0, None)
            res, exc, xop = self._round(0, m, e, sticky, fmt, rnd, 0)
            return self._finish_reg(dst, res, exc, None, xop)
        if off >= 0x40 or self.sw.fmovecr_undefined != 'winuae':
            if self.sw.fmovecr_undefined != 'winuae':
                raise Unmodelled('FMOVECR $%02X' % off)
            # WinUAE: offsets $40-$7F take the F-line on a 6888x.
            return Outcome(vector=V_FLINE, when='pre')
        return self._fmovecr_winuae_undef(off, dst, rnd)

    def _prec_code(self):
        return (self.fpcr >> 6) & 3

    def _winuae_round(self, x: Ext, rnd):
        """WinUAE's fpp_round32/fpp_round64 for PREC single/double: the
        mantissa rounded, the exponent range extended's; zero and $7FFF
        exponents untouched."""
        prec = self._prec_code()
        if prec == 0 or x.e == EMAX or x.m == 0:
            return x, False
        f = SGL_MANT if prec == 1 else DBL_MANT
        s, m, e = x.exact()
        r = post_process(s, m, e, False, f, rnd, 'reg')
        return r.ext(), r.inex

    def _winuae_rom_image(self, off, rnd):
        """WinUAE's constant: its extended image, the low longword adjusted
        by RND when it treats the constant as inexact."""
        (be, m), inexact, adj = constants.WINUAE_DOCUMENTED[off]
        if inexact:
            m = (m & ~0xFFFFFFFF) | ((m + adj[rnd]) & 0xFFFFFFFF)
        return Ext(0, be, m), bool(inexact)

    def _fmovecr_winuae_doc(self, off, dst, rnd):
        # As WinUAE does it: the image, then its round32/round64 (the
        # mantissa to PREC, the exponent range extended's), INEX2 from its
        # table or from that rounding.
        x, inexact = self._winuae_rom_image(off, rnd)
        x, inex2 = self._winuae_round(x, rnd)
        return self._finish_reg(dst, x, INEX2 if (inexact or inex2) else 0, None)

    def _fmovecr_rom64(self, off, dst, rnd, fmt):
        # switches.py item 19's third reading: the ROM holds a 64-bit extended
        # constant and which side of it the true value lies (WinUAE's
        # images and adjustments, a lead); 4-72's "rounds it to the
        # precision specified" is then the manual's post-processing, range
        # control included.
        x, inexact = self._winuae_rom_image(off, rnd)
        if x.is_zero:
            return self._finish_reg(dst, zero(0), 0, None)
        s, m, e = x.exact()
        res, exc, xop = self._round(s, m, e, False, fmt, rnd, INEX2 if inexact else 0)
        return self._finish_reg(dst, res, exc, None, xop)

    def _fmovecr_winuae_undef(self, off, dst, rnd):
        idx = off if off <= 10 else 0
        prec = self._prec_code()
        x = Ext(*constants.WINUAE_UNDEFINED[idx])
        adjust, extra_cc = 0, 0
        if idx in (1, 7) and prec == 1:
            adjust = -1 if rnd == RN else (1 if rnd in (RZ, RM) else 0)
        if idx == 2 and prec == 1 and rnd == RP:
            adjust = -1
        if idx == 3:
            extra_cc = CC_I if (prec == 1 and rnd in (RN, RP)) else CC_NAN
        if idx == 7:
            extra_cc = CC_NAN
        x, _ = self._winuae_round(x, rnd)
        if adjust:
            x = Ext(x.s, x.e, (x.m + adjust * (0x80 << 32)) & M64)
        out = self._finish_reg(dst, x, 0, None)
        self.fpsr |= extra_cc
        return out

    # -- FMOVE FPm,<ea> (4-64..4-69) ----------------------------------------
    def fmove_out(self, fmt, src_reg, ext, pc=None, dreg=0):
        """The value stored, and any exception - reported mid-instruction,
        after the store.  FPCC is not changed (2.3.1)."""
        self._begin(pc)
        x = self.fp[src_reg]
        rnd = self.rnd
        exc = 0
        if fmt in (FMT_P, FMT_PK):
            # The k-factor: static in the extension, or the low 7 bits of Dn
            # (bits 6-4 of the extension name it), two's complement.
            kraw = (dreg if fmt == FMT_PK else ext) & 0x7F
            k = kraw - 0x80 if kraw & 0x40 else kraw
            val, exc = self._to_packed(x, k, rnd)
            xop = None
        elif fmt in INT_BITS:
            val, exc = self._to_int(x, INT_BITS[fmt], rnd)
            xop = None
        else:
            f = {FMT_S: SGL, FMT_D: DBL, FMT_X: EXT}[fmt]
            val, exc, xop = self._to_ieee(x, f, rnd)
        self.fpsr |= exc
        self._accrue(exc)
        vec = self._trap(exc)
        if vec in (V_SNAN, V_OPERR):
            xop = x
        return Outcome(vector=vec, when='mid' if vec else None,
                       xop=xop if vec else None, store=val)

    def _to_packed(self, x, k, rnd):
        """FMOVE.P: (the 96-bit image, EXC).  Zero, infinity and NaN store
        the register's image with the integer-digit word cleared (FPSP
        p_move; Table 3-4's forms); the rest is bindec (packed.py)."""
        if not x.is_finite or x.is_zero:
            exc = 0
            if self.sw.packed_out_special == 'manual':
                if x.is_snan:
                    x = x.quiet()
                    exc |= SNAN
                if k > 17:
                    exc |= OPERR
            return x.bits96(), exc
        bits, inex2, operr = packed.bindec(x, k, rnd, self._pten())
        return bits, (INEX2 if inex2 else 0) | (OPERR if operr else 0)

    def _to_int(self, x, bits, rnd):
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
        mask = (1 << bits) - 1
        if x.is_nan:
            exc = 0
            if x.is_snan:
                x = x.quiet()
                exc |= SNAN
            else:
                exc |= OPERR                    # Table 6-2
            return (x.m >> (64 - bits)) & mask, exc
        if x.is_inf:
            return (lo if x.s else hi) & mask, OPERR
        if x.is_zero:
            return 0, 0
        s, m, e = x.exact()
        K, inexact = round_integer(s, m, e, False, rnd)
        v = -K if s else K
        exc = INEX2 if inexact else 0
        if v < lo or v > hi:
            return (lo if s else hi) & mask, exc | OPERR
        return v & mask, exc

    def _to_ieee(self, x, f, rnd):
        """S, D or X to memory: (bits, exc, exceptional operand)."""
        if f is EXT:
            ebits, fbits, bias = 15, 64, BIAS
        elif f is DBL:
            ebits, fbits, bias = 11, 52, 1023
        else:
            ebits, fbits, bias = 8, 23, 127
        emax = (1 << ebits) - 1
        exc = 0

        def pack(s, be, frac):
            if f is EXT:
                return (s << 95) | (be << 80) | frac
            return (s << (ebits + fbits)) | (be << fbits) | frac

        if x.is_nan:
            if x.is_snan:
                x = x.quiet()
                exc |= SNAN
            if f is EXT:
                return pack(x.s, EMAX, x.m), exc, None
            # "truncated if necessary" (6.1.2): the fraction's top bits.
            return pack(x.s, emax, (x.m >> (63 - fbits)) & ((1 << fbits) - 1)), exc, None
        if x.is_inf:
            return pack(x.s, emax, 0), 0, None
        if x.is_zero:
            return pack(x.s, 0, 0), 0, None
        s, m, e = x.exact()
        r = post_process(s, m, e, False, f, rnd, 'mem')
        exc |= (UNFL if r.unfl else 0) | (OVFL if r.ovfl else 0) | (INEX2 if r.inex else 0)
        if r.kind == 'inf':
            return pack(s, emax, 0), exc, r.xop
        if r.kind == 'zero':
            return pack(s, 0, 0), exc, r.xop
        if f is EXT:
            return r.ext().bits96() | (s << 95), exc, r.xop
        K, q = r.K, r.q
        if K.bit_length() < f.p:                 # a denormal of the format
            return pack(s, 0, K << (q - (f.emin - (f.p - 1)))), exc, r.xop
        n = K.bit_length()
        K <<= f.p - n
        q -= f.p - n
        be = q + (f.p - 1) + bias
        return pack(s, be, K & ((1 << fbits) - 1)), exc, r.xop

    # -- FMOVE(M) of the control registers (Table 4-17) ----------------------
    def _cr_list(self, sel):
        # FPCR (bit 12), FPSR (11), FPIAR (10), in that order; list 000
        # moves FPIAR on the current chip (Table 4-17 note).
        sel = sel or 0b001
        return [n for bit, n in ((4, 'fpcr'), (2, 'fpsr'), (1, 'fpiar')) if sel & bit]

    def fmove_cr_in(self, sel, values):
        for name, v in zip(self._cr_list(sel), values):
            if name == 'fpcr':
                self.fpcr = v & FPCR_MASK
            elif name == 'fpsr':
                self.fpsr = v & FPSR_MASK
            else:
                self.fpiar = v & 0xFFFFFFFF
        self.null_state = False
        return Outcome()

    def fmove_cr_out(self, sel):
        return Outcome(store=[getattr(self, n) for n in self._cr_list(sel)])

    # -- FMOVEM of the data registers (4-74..4-79) --------------------------
    def fmovem(self, cmd, values, dreg=0):
        dr = (cmd >> 13) & 1
        mode = (cmd >> 11) & 3
        lst = (dreg & 0xFF) if (mode & 1) else (cmd & 0xFF)
        predec = not (mode & 2)
        # The list's MSB first: -(An) bit 7 = FP7 ... bit 0 = FP0; the others
        # bit 7 = FP0 ... bit 0 = FP7.  FP0 is always at the lowest address.
        regs = [r for r in range(8) if lst & (1 << (r if predec else 7 - r))]
        self.null_state = False
        if dr:
            return Outcome(store=[self.fp[r].bits96() for r in regs])
        for r, v in zip(regs, values):
            self.fp[r] = ext_bits96(v)          # moved as is, unchecked
        return Outcome()

    # -- the conditionals -------------------------------------------
    def condition(self, pred, pc=None):
        """FBcc/FDBcc/FScc/FTRAPcc's predicate: the answer, or BSUN's trap
        instead of it.  Bit 5 of the predicate is ignored."""
        pred &= 0x1F
        cc = (self.fpsr >> 24) & 0xF
        nan = bool(cc & 1)
        if pred & 0x10 and nan:
            self.fpsr |= BSUN | A_IOP
            if self.fpcr & BSUN:
                if pc is not None:
                    self.fpiar = pc & 0xFFFFFFFF
                return Outcome(vector=V_BSUN, when='pre')
        return Outcome(cond=self._evaluate(pred, cc))

    def _evaluate(self, pred, cc):
        if self.sw.fpcc_table == 'winuae':
            return bool(WINUAE_CC_TABLE[cc * 32 + pred])
        return evaluate_equation(pred, cc)


def evaluate_equation(pred, cc):
    """The predicates' equations on N Z I NAN as written."""
    N, Z, NAN_ = bool(cc & 8), bool(cc & 4), bool(cc & 1)
    p = pred & 0x0F
    return [
        False, Z, not (NAN_ or Z or N), Z or not (NAN_ or N),
        N and not (NAN_ or Z), Z or (N and not NAN_), not (NAN_ or Z), not NAN_,
        NAN_, NAN_ or Z, NAN_ or not (N or Z), NAN_ or Z or not N,
        NAN_ or (N and not Z), NAN_ or Z or N, not Z, True,
    ][p]


# WinUAE's condition_table_6888x (fpp.cpp, d42db95): 16 FPCC values (N Z I
# NAN as a nibble) x 32 predicates.  A lead.
WINUAE_CC_TABLE = [int(c) for c in (
    '00110011001100110011001100110011'
    '00000000111111110000000011111111'
    '00110011001100110011001100110011'
    '00000000111111110000000011111111'
    '01010101010101010101010101010101'
    '01010101111111110101010111111111'
    '01010101010101010101010101010101'
    '01010101111111110101010111111111'
    '00001111000011110000111100001111'
    '00000000111111110000000011111111'
    '00001111000011110000111100001111'
    '00000000111111110000000011111111'
    '01010101010101010101010101010101'
    '01010101111111110101010111111111'
    '01010101010101010101010101010101'
    '01010101111111110101010111111111')]


# -- exact helpers -----------------------------------------------------------

def _isqrt(n):
    import math
    return math.isqrt(n)


class _Dy:
    """A signed exact value num x 2^e, summable."""
    __slots__ = ('num', 'e')

    def __init__(self, num, e):
        self.num, self.e = num, e

    def __add__(self, o):
        e = min(self.e, o.e)
        return ((self.num << (self.e - e)) + (o.num << (o.e - e)), e)


def _signed(x: Ext):
    s, m, e = x.exact()
    return _Dy(-m if s else m, e)


def _cmp_exact(a: Ext, b: Ext):
    num, e = _signed(a) + _Dy(-_signed(b).num, _signed(b).e)
    return (num > 0) - (num < 0)
