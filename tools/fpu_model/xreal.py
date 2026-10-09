"""The extended-precision register value and the memory formats.

An extended value is (s, e, m): the sign, the 15-bit biased exponent and the
64-bit mantissa with its explicit integer bit (UM Table 3-3).  For every
exponent below $7FFF the value is (-1)^s x m x 2^(e - 16446): exponent 0 and
exponent 1 differ by a factor of two like any other pair, because the
68882's denormals use the same bias as its normalized numbers (Table 3-3:
normalized 2^(e-16383) x 1.f for 0 <= e < 32767; denormalized 2^-16383 x
0.f).  So exponent 0 with the integer bit set is a normalized number (the
"pseudo-denormal"), exponent 0 with it clear a denormal, and a nonzero
exponent with it clear an unnormal, normalized before use.

Exact values are carried as Python integers, (sign, m, e) meaning
(-1)^sign x m x 2^e; nothing here rounds.
"""

from typing import NamedTuple

BIAS = 16383
EMAX = 0x7FFF
SCALE = 16446                   # value = m x 2^(e - SCALE) below EMAX
M64 = (1 << 64) - 1
J_BIT = 1 << 63                 # the explicit integer bit
Q_BIT = 1 << 62                 # the NaN's nonsignaling bit (clear = SNaN)
FRAC = J_BIT - 1


class Ext(NamedTuple):
    s: int
    e: int
    m: int

    # The kinds.  At exponent $7FFF the integer bit is a don't-care.
    @property
    def is_nan(self):
        return self.e == EMAX and (self.m & FRAC) != 0

    @property
    def is_snan(self):
        return self.is_nan and not (self.m & Q_BIT)

    @property
    def is_inf(self):
        return self.e == EMAX and (self.m & FRAC) == 0

    @property
    def is_zero(self):
        # An unnormalized zero (any exponent, mantissa 0) is a true zero
        # (UM 3.5.1).
        return self.e != EMAX and self.m == 0

    @property
    def is_finite(self):
        return self.e != EMAX

    @property
    def is_denormal(self):
        # Exponent 0, integer bit 0, fraction nonzero (Table 3-3).
        return self.e == 0 and self.m != 0 and not (self.m & J_BIT)

    def exact(self):
        """(sign, m, e) with value (-1)^sign x m x 2^e, for a finite value."""
        assert self.is_finite
        return self.s, self.m, self.e - SCALE

    def quiet(self):
        """A signaling NaN made nonsignaling: bit 62 set, nothing else changed
        (UM 4.5.4.2)."""
        return Ext(self.s, self.e, self.m | Q_BIT)

    def neg(self):
        return Ext(self.s ^ 1, self.e, self.m)

    def bits96(self):
        """The 96-bit memory image: sign, exponent, 16 zero bits, mantissa."""
        return (self.s << 95) | (self.e << 80) | self.m

    def __repr__(self):
        return 'Ext(%d,$%04X,$%016X)' % (self.s, self.e, self.m)


def ext_bits96(v):
    """An extended memory operand; the 16 unused bits are don't-cares on input
    (Table 3-3)."""
    return Ext((v >> 95) & 1, (v >> 80) & EMAX, v & M64)


# The NaN the chip creates for an invalid operation: all-ones mantissa
# (UM 3.2.5, 6.1.3).  Positive; the manual gives no sign for it.
NAN = Ext(0, EMAX, M64)
# The infinity the chip creates: maximum exponent, mantissa zero (6-16).
def inf(s):
    return Ext(s, EMAX, 0)
def zero(s):
    return Ext(s, 0, 0)


def ext_from_exact(s, K, q):
    """The canonical register image of (-1)^s x K x 2^q, which must be exactly
    representable in extended: normalized wherever the biased exponent is 0
    or more (exponent 0 with the integer bit set included), a denormal
    below."""
    if K == 0:
        return zero(s)
    n = K.bit_length()
    E = n - 1 + q                      # unbiased exponent of the leading bit
    be = E + BIAS
    if be >= 0:
        assert be < EMAX, 'not representable'
        sh = 64 - n
        m = K << sh if sh >= 0 else K >> -sh
        assert (m >> 64) == 0 and (sh >= 0 or (K & ((1 << -sh) - 1)) == 0)
        return Ext(s, be, m)
    # Denormal: exponent 0, value m x 2^-16446.
    sh = q + SCALE
    assert sh >= 0, 'below the smallest denormal'
    return Ext(s, 0, K << sh)


def exact_leading_exponent(m, e):
    """The unbiased exponent E of m x 2^e written as 1.f x 2^E."""
    return m.bit_length() - 1 + e


# ---------------------------------------------------------------------------
# Conversion in (UM 3.5.1): every external operand becomes extended, exactly.
# (Packed decimal is the algorithm layer's, packed.py.)

def from_int(v, bits):
    """B, W or L: two's complement, `bits` wide."""
    v &= (1 << bits) - 1
    if v >> (bits - 1):
        v -= 1 << bits
    return ext_from_exact(1 if v < 0 else 0, abs(v), 0)


def _from_ieee(v, ebits, fbits):
    s = (v >> (ebits + fbits)) & 1
    be = (v >> fbits) & ((1 << ebits) - 1)
    f = v & ((1 << fbits) - 1)
    emax = (1 << ebits) - 1
    bias = (1 << (ebits - 1)) - 1
    if be == emax:
        if f == 0:
            return inf(s)
        # A NaN's fraction moves to the top of the extended fraction, so its
        # nonsignaling bit lands on bit 62.  The integer bit is a don't-care
        # at exponent $7FFF; it is written as one, as the chip's own NaN has it.
        return Ext(s, EMAX, J_BIT | (f << (63 - fbits)))
    if be == 0:
        # Zero, or a denormal - normalized on the way in (UM 3.5.1).
        return ext_from_exact(s, f, 1 - bias - fbits)
    return ext_from_exact(s, (1 << fbits) | f, be - bias - fbits)


def from_single(v):
    return _from_ieee(v, 8, 23)


def from_double(v):
    return _from_ieee(v, 11, 52)
