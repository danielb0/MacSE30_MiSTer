"""Post-processing: underflow check, round, overflow check (plan 8.6.4;
UM 4.5.5.2, 6.1.4, 6.1.5, 6.1.7, Figure 6-3).

The intermediate result is given exactly - (-1)^s x m x 2^e, plus a flag
`sticky` meaning "and something more below 2^e, not zero" - which is what
the 67-bit intermediate computes, its sticky bit the OR of every bit below
the guard and round bits (UM 3.x: "as if to infinite precision and then
round").  Every threshold below is the manual's, in the terms of UM 3.6's
tables: a format's exponent field runs from its minimum 0 to its maximum
(255, 2047, 32767), a normalized intermediate 1.f x 2^E has the biased
exponent E + bias, and

  underflow (tiny, before rounding): biased exponent <= the minimum - except
      extended, where exponent 0 with the integer bit set is normalized
      (6-11 footnote), so extended is tiny only below it: E < -16383;
  overflow (after rounding): biased exponent >= the maximum.

INEX2 is the rounding's G/R/S alone (Figure 6-3); an overflow does not set
it (6.1.7 note: "even though the INEX1 or INEX2 bits may not be set").
"""

from typing import NamedTuple, Optional
from xreal import Ext, BIAS, EMAX, ext_from_exact, inf

RN, RZ, RM, RP = 0, 1, 2, 3


class Fmt(NamedTuple):
    name: str
    p: int          # mantissa bits, integer bit included
    emin: int       # smallest unbiased exponent of a normalized number
    emax: int       # largest


# The formats.  emin is the smallest normalized exponent: single and double
# E >= -126/-1022 (biased 1); extended E >= -16383 (biased 0, footnote 6-11).
EXT = Fmt('X', 64, -16383, 16383)
SGL = Fmt('S', 24, -126, 127)
DBL = Fmt('D', 53, -1022, 1023)
# FSGLMUL/FSGLDIV: the mantissa rounded to single, the exponent range kept
# extended's (UM 6.1.4 note).
SGL_MANT = Fmt('SX', 24, -16383, 16383)
# 8.6.14 item 3, the 'table' reading of FMOVE <ea>,FPn: the same shape.
DBL_MANT = Fmt('DX', 53, -16383, 16383)

# FPCR PREC (bits 7-6): 00 extended, 01 single, 10 double, 11 undefined.
# The undefined setting is taken as extended here and flagged by the caller.
PREC_FMT = {0: EXT, 1: SGL, 2: DBL, 3: EXT}


def round_to_quantum(s, m, e, sticky, q, rnd):
    """Round (-1)^s x (m x 2^e + tail) to a multiple of 2^q.

    Returns (K, inexact): the magnitude K x 2^q.  Figure 6-3: RN adds one
    when the guard bit is set unless it is a tie with an even LSB; RM adds
    one to a negative inexact result, RP to a positive one; RZ chops.
    """
    if e >= q:
        if not sticky:
            return m << (e - q), False
        # The tail lies below 2^e: widen m so the quantum sits above it.
        m <<= e - q + 2
        e = q - 2
    sh = q - e
    K = m >> sh
    rem = m & ((1 << sh) - 1)
    inexact = rem != 0 or sticky
    if not inexact:
        return K, False
    half = 1 << (sh - 1)
    if rnd == RN:
        up = rem > half or (rem == half and (sticky or (K & 1)))
    elif rnd == RZ:
        up = False
    elif rnd == RM:
        up = bool(s)
    else:
        up = not s
    return K + (1 if up else 0), True


class Rounded(NamedTuple):
    kind: str               # 'zero', 'fin' or 'inf'
    s: int
    K: int                  # value K x 2^q (kind 'fin'; 0 for 'zero')
    q: int
    unfl: bool              # EXC.UNFL: tiny
    ovfl: bool              # EXC.OVFL
    inex: bool              # EXC.INEX2: the rounding lost bits
    E: int                  # the intermediate's unbiased exponent (unrounded)
    xop: Optional[Ext]      # the exceptional operand for OVFL/UNFL (8.6.10)

    def ext(self):
        """The register image (extended; PREC's range is already applied)."""
        if self.kind == 'inf':
            return inf(self.s)
        if self.kind == 'zero':
            return Ext(self.s, 0, 0)
        return ext_from_exact(self.s, self.K, self.q)

    def value(self):
        """(sign, K, q) - for packing to a memory format."""
        return self.s, self.K, self.q


def largest(fmt):
    """(K, q) of the format's largest finite magnitude."""
    return (1 << fmt.p) - 1, fmt.emax - (fmt.p - 1)


def exceptional_operand(s, m, e, sticky, rnd, E, fmt, dest, ovfl):
    """The exceptional operand for an overflow or underflow (UM 6.1.4, 6.1.5).

    Register destination: the intermediate rounded to extended precision,
    its exponent wrapped by -$6000 (overflow) or +$6000 (underflow) and
    truncated to 15 bits; $0000 for a catastrophic over/underflow of the
    17-bit intermediate exponent (unbiased above $A000, or at or below
    $16001 = -40959 two's complement).  Memory destination: the mantissa
    rounded to the destination's precision, the exponent biased as a normal
    extended number.
    """
    p = 64 if dest == 'reg' else fmt.p
    K, _ = round_to_quantum(s, m, e, sticky, E - (p - 1), rnd)
    Er = E
    if K >> p:                          # the rounding carried out
        K >>= 1
        Er += 1
    mant = K << (64 - p)
    if dest == 'reg':
        if ovfl:
            be = 0 if Er > 0xA000 else (Er + BIAS - 0x6000) & 0x7FFF
        else:
            be = 0 if Er <= -40959 else (Er + BIAS + 0x6000) & 0x7FFF
    else:
        be = (Er + BIAS) & 0x7FFF
    return Ext(s, be, mant)


def post_process(s, m, e, sticky, fmt, rnd, dest='reg'):
    """Underflow check, round, overflow check, for a nonzero finite
    intermediate (-1)^s x (m x 2^e + tail).  fmt is PREC's format for a
    register destination, the destination's for memory."""
    assert m > 0
    E = m.bit_length() - 1 + e
    tiny = E < fmt.emin
    if tiny:
        # Denormalized: shifted right to the format's minimum exponent, then
        # rounded there (6.1.5).  A result rounding to nothing is a signed
        # zero, or in RM/RP the smallest denormal - Figure 6-3's rounding
        # gives both.
        q = fmt.emin - (fmt.p - 1)
    else:
        q = E - (fmt.p - 1)
    K, inexact = round_to_quantum(s, m, e, sticky, q, rnd)
    xop = None
    if K == 0:
        return Rounded('zero', s, 0, q, True, False, inexact, E,
                       exceptional_operand(s, m, e, sticky, rnd, E, fmt, dest, False))
    if tiny:
        xop = exceptional_operand(s, m, e, sticky, rnd, E, fmt, dest, False)
        return Rounded('fin', s, K, q, True, False, inexact, E, xop)
    if K >> fmt.p:                      # carry out of the mantissa
        K >>= 1
        q += 1
    Er = K.bit_length() - 1 + q
    if Er > fmt.emax:
        xop = exceptional_operand(s, m, e, sticky, rnd, E, fmt, dest, True)
        # 6.1.4's trap-disabled results.
        to_inf = (rnd == RN or (rnd == RM and s) or (rnd == RP and not s))
        if to_inf:
            return Rounded('inf', s, 0, 0, False, True, inexact, E, xop)
        LK, Lq = largest(fmt)
        return Rounded('fin', s, LK, Lq, False, True, inexact, E, xop)
    return Rounded('fin', s, K, q, False, False, inexact, E, None)


def round_integer(s, m, e, sticky, rnd):
    """Round to an integer (quantum 2^0); for FINT and the B/W/L stores."""
    return round_to_quantum(s, m, e, sticky, 0, rnd)
