"""The transcendentals: plan 8.7 work 5c, the algorithm layer.

Daniel's decision (2026-09-29): CORDIC and shift-add - what an adder, a
barrel shifter and a constant ROM compute (UM 1.2), "the highly recursive
nature of the algorithms used" on "an ALU with a finite precision of 67
bits" (UM 4.3.2).  The manual's accuracy is the spec: one unit in the last
place of double worst case, about 64 units of extended typically.

The machinery here is the microcode's arithmetic, not floating point:
  - fixed-point registers of 67 bits, two's complement, 64 fraction bits
    (Q2.64: -4 <= v < 4), with arithmetic right shifts that truncate - the
    datapath's adder and barrel shifter;
  - I67, the internal floating format of the compositions (a sign, a
    67-bit mantissa, an unbounded exponent): every operation truncates its
    exact result to 67 bits - no rounding hardware between steps;
  - constants as the ROM holds them: 67-bit mantissas.
The final result goes through the ordinary post-processing (rounding.py)
from its 67 bits with the sticky bit set, so INEX2 is set for every
computed result ("INEX2 ... may be set even if an exact result is
produced", UM 4.3.2).

Plan 8.7.3 records the design and what the checks measure.
"""

import math
from fractions import Fraction

F = 64                      # fraction bits of the fixed-point registers
W = 67                      # register and mantissa width
ONE = 1 << F


# -- I67: the internal floating format -------------------------------------------

class I67:
    """(-1)^s x m x 2^e with m exactly 67 bits (or zero)."""
    __slots__ = ('s', 'm', 'e')

    def __init__(self, s, m, e):
        if m:
            n = m.bit_length()
            if n > W:
                m >>= n - W                  # truncate
                e += n - W
            elif n < W:
                m <<= W - n
                e -= W - n
        self.s, self.m, self.e = s, m, e

    @staticmethod
    def exact(s, num, e):
        return I67(s, num, e)

    def is_zero(self):
        return self.m == 0

    def neg(self):
        return I67(self.s ^ 1, self.m, self.e)

    def frac(self):
        v = Fraction(self.m) * Fraction(2) ** self.e
        return -v if self.s else v

    def __repr__(self):
        return 'I67(%d,%X,%d)' % (self.s, self.m, self.e)


def i_add(a: I67, b: I67):
    if a.m == 0:
        return b
    if b.m == 0:
        return a
    e = min(a.e, b.e)
    v = (-1 if a.s else 1) * (a.m << (a.e - e)) + (-1 if b.s else 1) * (b.m << (b.e - e))
    return I67(1 if v < 0 else 0, abs(v), e)


def i_sub(a, b):
    return i_add(a, b.neg())


def i_mul(a, b):
    return I67(a.s ^ b.s, a.m * b.m, a.e + b.e)


def i_div(a, b):
    # 67 quotient bits by shift-subtract, the remainder dropped (truncation)
    if a.m == 0:
        return I67(a.s ^ b.s, 0, 0)
    q = (a.m << (W + 1)) // b.m
    return I67(a.s ^ b.s, q, a.e - b.e - (W + 1))


def i_sqrt(a):
    m, e = a.m, a.e
    if e & 1:
        m, e = m << 1, e - 1
    m <<= 2 * W
    e -= 2 * W
    return I67(0, math.isqrt(m), e // 2)


def i_from_ext(x):
    s, m, e = x.exact()
    return I67(s, m, e)


def i_from_int(n):
    return I67(1 if n < 0 else 0, abs(n), 0)


# -- the constant ROM ------------------------------------------------------------
# Every constant is computed here to 200 bits and truncated to 67, as a ROM
# of 67-bit words would hold it.

def _fx(v):
    """A Fraction as a Q2.64 fixed-point integer, truncated toward -inf."""
    return math.floor(v * ONE)


def _rom_tables():
    """atan(2^-i), atanh(2^-i), ln(1 + 2^-i), ln(1 - 2^-i) and the CORDIC
    gain corrections, to 200 bits, from integer series (no library)."""
    P = 220
    one = 1 << P

    def atan_pow2(i):
        # atan(2^-i) = sum (-1)^k 2^-i(2k+1)/(2k+1)
        total, k, sign = 0, 0, 1
        while True:
            term = (one >> (i * (2 * k + 1))) // (2 * k + 1)
            if term == 0:
                break
            total += sign * term
            sign, k = -sign, k + 1
        return total

    def atanh_pow2(i):
        total, k = 0, 0
        while True:
            term = (one >> (i * (2 * k + 1))) // (2 * k + 1)
            if term == 0:
                break
            total += term
            k += 1
        return total

    def ln1p_pow2(i, sign):
        # ln(1 + sign 2^-i) = 2 atanh(sign / (2^(i+1) + sign))
        t = Fraction(sign, (1 << (i + 1)) + sign)
        total, k = Fraction(0), 0
        tk = t
        while True:
            term = tk / (2 * k + 1)
            if abs(term) < Fraction(1, one):
                break
            total += term
            tk *= t * t
            k += 1
        return math.floor(2 * total * one)

    # atan(2^0) = pi/4: its series does not converge in this form.
    import constants
    pm, pe, _ = constants.DOCUMENTED[0x00]
    atan = [pm >> -(pe - 2 + P)] + [atan_pow2(i) for i in range(1, W + 2)]
    atanh = [0] + [atanh_pow2(i) for i in range(1, W + 2)]
    ln_up = [ln1p_pow2(i, 1) for i in range(0, W + 2)]
    ln_dn = [0] + [ln1p_pow2(i, -1) for i in range(1, W + 2)]
    return P, atan, atanh, ln_up, ln_dn


_P, _ATAN, _ATANH, _LNUP, _LNDN = _rom_tables()


ATAN_WORDS = 34             # atan(2^-i) in ROM for i < 34


def rom_fixed(table, i, shift=0):
    """table[i] x 2^shift in Q2.64, truncated - the ROM word shifted into
    place by the barrel shifter.  From i = 34 on, atan(2^-i) is 2^-i to
    within 2^-3i/3 - below the register's last bit even scaled by 2^33 - so
    the shifter makes it and the ROM holds 34 words."""
    if table is _ATAN and i >= ATAN_WORDS:
        sh = F + shift - i
        return 1 << sh if sh >= 0 else 0
    if (table is _LNUP or table is _LNDN) and i >= ATAN_WORDS:
        # ln(1 +/- 2^-i) = +/-2^-i - 2^-(2i+1) +/- 2^-3i/3: the first two
        # terms from the shifter; the third, scaled by 2^s <= 2^i, is under
        # 2^-4 of the last bit.
        v = ((1 << (600 - i)) if table is _LNUP else -(1 << (600 - i))) - (1 << (600 - 2 * i - 1))
        return v >> (600 - F - shift)
    return table[i] >> (_P - F - shift) if _P - F - shift >= 0 else table[i] << (shift - _P + F)


def _gain_inv(i0, n):
    """1 / prod_{i=i0}^{n-1} sqrt(1 + 2^-2i), in Q2.64 (a ROM constant per
    starting iteration)."""
    import decimal
    decimal.getcontext().prec = 80
    k = decimal.Decimal(1)
    for i in range(i0, n):
        k *= (1 + decimal.Decimal(2) ** (-2 * i)).sqrt()
    return int((decimal.Decimal(ONE) / k).to_integral_value(rounding=decimal.ROUND_FLOOR))


N_ITER = W                  # CORDIC iterations: i = i0 .. i0 + 66
# The gain correction per starting iteration; from i0 = 34 on it is 1 to
# within 2^-67 (a ROM of 34 words).
_GAIN = [_gain_inv(i0, i0 + N_ITER) for i0 in range(34)]


def gain(i0):
    return _GAIN[i0] if i0 < len(_GAIN) else ONE


def _pi_rom():
    """pi to 200 bits (Machin), as the ROM's source."""
    import constants
    m, e, _ = constants.DOCUMENTED[0x00]
    return m, e


# 2pi with the datapath's 67 bits: the reduction constant (8.7.3).  pi
# itself for the quadrant step, also 67 bits.
_PI_M, _PI_E = _pi_rom()
TWOPI = I67(0, _PI_M, _PI_E + 1)
PI = I67(0, _PI_M, _PI_E)
HALFPI = I67(0, _PI_M, _PI_E - 1)
QUARTERPI = I67(0, _PI_M, _PI_E - 2)


# -- fixed point ------------------------------------------------------------------

def to_fixed(x: I67, shift=0):
    """x x 2^shift as a Q2.64 integer, truncated toward zero (the barrel
    shifter aligning a mantissa)."""
    sh = x.e + shift + F
    v = x.m << sh if sh >= 0 else x.m >> -sh
    return -v if x.s else v


def from_fixed(v, shift=0):
    """A Q2.64 value, times 2^-shift, as I67."""
    return I67(1 if v < 0 else 0, abs(v), -F - shift)

def asr(v, n):
    """Arithmetic shift right, truncating toward -inf (two's complement)."""
    return v >> n


ONE_I = I67(0, 1, 0)
ALMOST_ONE = I67(0, (1 << W) - 1, -W)             # 1 - 2^-67


def bounded(r: I67):
    """A result whose true value lies strictly inside (-1, 1) - sin, cos,
    tanh - computed as +/-1 or beyond: +/-(1 - 2^-67), so the final rounding
    (its sticky bit says "a little above") cannot carry it past 1 in any
    mode."""
    if exponent(r) >= 0 and not r.is_zero():
        return I67(r.s, ALMOST_ONE.m, ALMOST_ONE.e)
    return r


def exponent(x: I67):
    """E with x in [2^E, 2^(E+1))."""
    return x.m.bit_length() - 1 + x.e


# -- sin, cos, tan: circular CORDIC, rotation mode --------------------------------------

def cordic_rotate(z: I67):
    """cos z and sin z for 0 <= z <= pi/4, by circular CORDIC in rotation
    mode, scaled for small z so sin keeps its relative precision: with
    z < 2^-s the y and z registers hold y 2^s and z 2^s, and the iterations
    run from i0 = s (the rotations before it are never taken) for 67 steps,
    leaving a residual angle 2^-66 of z whatever its size.  Returns (cos,
    sin) as I67."""
    if z.is_zero():
        return from_fixed(ONE), I67(0, 0, 0)
    s = max(0, -exponent(z) - 1)
    if s >= 34:
        # Below 2^-34: sin z = z (z^3/6 is under 2^-67 of it), cos z =
        # 1 - z^2/2 on the 64 fraction bits.
        return from_fixed(ONE - ((to_fixed(z) ** 2) >> (F + 1))), z
    X = gain(s)
    Y = 0                                          # y 2^s
    Z = to_fixed(z, s)                             # z 2^s
    for i in range(s, s + N_ITER):
        if Z >= 0:
            X, Y, Z = X - asr(Y, i + s), Y + asr(X, i - s), Z - rom_fixed(_ATAN, i, s)
        else:
            X, Y, Z = X + asr(Y, i + s), Y - asr(X, i - s), Z + rom_fixed(_ATAN, i, s)
    return from_fixed(X), from_fixed(Y, s)


def reduce_2pi(x: I67):
    """FSIN's first step (UM 4-102): an argument outside [-2pi, 2pi] is
    reduced into it - an exact remainder by the 67-bit 2pi, toward zero,
    like FMOD.  Its error is n (C - 2pi) for n multiples of the constant C,
    and swamps the result near 10^20, as the manual says."""
    if abs(x.frac()) <= TWOPI.frac():
        return x
    e0 = min(x.e, TWOPI.e)
    r = (x.m << (x.e - e0)) % (TWOPI.m << (TWOPI.e - e0))
    return I67(x.s, r, e0)


def sincos(x: I67):
    """(sin x, cos x) as I67: the reduction, the quadrant (k pi/2 against
    the 67-bit pi, k <= 4), CORDIC on [0, pi/4], the quadrant's swaps."""
    z = reduce_2pi(x)
    neg = z.s
    z = I67(0, z.m, z.e)
    k, r = 0, z
    while r.frac() > QUARTERPI.frac():
        r = i_sub(r, HALFPI)
        k += 1
    c, s = cordic_rotate(I67(0, r.m, r.e))
    if r.s:
        s = s.neg()
    k &= 3
    if k == 0:
        sn, cs = s, c
    elif k == 1:
        sn, cs = c, s.neg()
    elif k == 2:
        sn, cs = s.neg(), c.neg()
    else:
        sn, cs = c.neg(), s
    if neg:
        sn = sn.neg()
    return bounded(sn), bounded(cs)


def tan(x: I67):
    """FTAN: sin / cos (Table 8-3: FTAN 455 = FSIN 373 + a divide)."""
    s, c = sincos(x)
    return i_div(s, c)


# -- atan, asin, acos: circular CORDIC, vectoring mode ----------------------------------

def cordic_vector(X, Y, s):
    """Vectoring from (x, y 2^s), y >= 0, driving y to zero from iteration
    s; returns atan(y/x) 2^s in Q2.64."""
    Z = 0
    for i in range(s, s + N_ITER):
        if Y > 0:
            X, Y, Z = X + asr(Y, i + s), Y - asr(X, i - s), Z + rom_fixed(_ATAN, i, s)
        elif Y < 0:
            X, Y, Z = X - asr(Y, i + s), Y + asr(X, i - s), Z - rom_fixed(_ATAN, i, s)
    return Z


def atan(v: I67):
    """FATAN.  |v| < 2^-34: v (v^3/3 is under 2^-67 of it).  |v| < 1:
    vectoring from (1, v), scaled by 2^s for v < 2^-s.  |v| >= 1: vectoring
    from (2^-k, v 2^-k) - the angle ignores a common scale, so no divide
    (Table 8-3: FATAN 385, FSIN's time)."""
    if v.is_zero():
        return v
    a = I67(0, v.m, v.e)
    Ev = exponent(a)
    if Ev < -34:
        return v
    if Ev < 0:
        s = max(0, -Ev - 1)
        r = from_fixed(cordic_vector(ONE, to_fixed(a, s), s), s)
    else:
        k = Ev + 1                                 # v 2^-k in [1/2, 1)
        r = from_fixed(cordic_vector(ONE >> k if k < F else 0, to_fixed(a, -k), 0))
    return r.neg() if v.s else r


def asin(x: I67):
    """FASIN: atan(x / sqrt((1 - |x|)(1 + |x|))), the two factors exact so
    nothing cancels near 1 (FASIN 563 = a square root, a divide and FATAN).
    asin(+/-1) = +/-pi/2."""
    a = I67(0, x.m, x.e)
    d = i_mul(i_sub(ONE_I, a), i_add(ONE_I, a))
    if d.is_zero():
        return HALFPI.neg() if x.s else HALFPI
    return atan(i_div(x, i_sqrt(d)))


def acos(x: I67):
    """FACOS: 2 atan(sqrt((1 - x)/(1 + x))), small near 1 without
    cancellation (FACOS 607 = FASIN + 44).  acos(-1) = pi, acos(1) = 0."""
    den = i_add(ONE_I, x)
    if den.is_zero():
        return PI
    num = i_sub(ONE_I, x)
    if num.is_zero():
        return I67(0, 0, 0)
    r = atan(i_sqrt(i_div(num, den)))
    return I67(r.s, r.m, r.e + 1)


# -- e^x and relatives: shift-add ---------------------------------------------------------

LN2 = I67(0, _LNUP[0], -_P)                        # ln 2 = ln(1 + 2^0)
INV_LN2 = i_div(ONE_I, LN2)


def _const(off):
    import constants
    m, e, _ = constants.DOCUMENTED[off]
    return I67(0, m, e)


LOG10_E = _const(0x0E)
LOG2_E = i_div(ONE_I, LN2)
LOG2_10 = i_div(_const(0x31), LN2)


def _exp_frac(R):
    """e^r for 0 <= r < ln 2 in Q2.64: y = 1, and for i = 1 ... 66 the
    factor (1 + 2^-i) - y += y >> i - taken while r covers its logarithm
    (a ROM word).  The residual, below 2^-66, is dropped."""
    Y = ONE
    for i in range(1, N_ITER):
        L = rom_fixed(_LNUP, i)
        if not L:
            break                                 # the table's end: ln(1 + 2^-i) < 2^-64
        while R >= L:
            R -= L
            Y += asr(Y, i)
    return Y


def _scale2(y: I67, n):
    return I67(y.s, y.m, y.e + n)


def _overflowing(x: I67):
    """A result so far out that only its direction matters: 2^(+/-2^21)."""
    n = 1 << (exponent(x) + 1)
    return I67(0, 1 << (W - 1), (1 - W) + (-n if x.s else n))


def etox(x: I67):
    """FETOX: x = n ln 2 + r with the 67-bit ln 2, e^r by shift-add, times
    2^n."""
    if x.is_zero():
        return ONE_I
    if exponent(x) > 20:
        return _overflowing(x)
    q = i_mul(x, INV_LN2)
    n = math.floor(q.frac())
    r = i_sub(x, i_mul(i_from_int(n), LN2)) if n else x
    # The quotient's truncation can leave r a hair outside [0, ln 2).
    while r.s and not r.is_zero():
        n -= 1
        r = i_add(r, LN2)
    while not i_sub(r, LN2).s:
        n += 1
        r = i_sub(r, LN2)
    return _scale2(from_fixed(_exp_frac(to_fixed(r))), n)


def twotox(x: I67):
    """FTWOTOX: n = floor(x); 2^(x - n) = e^((x - n) ln 2), x - n exact."""
    if x.is_zero():
        return ONE_I
    if exponent(x) > 24:
        return _overflowing(x)
    n = math.floor(x.frac())
    f = i_sub(x, i_from_int(n)) if n else x
    return _scale2(from_fixed(_exp_frac(to_fixed(i_mul(f, LN2)))), n)


def tentox(x: I67):
    """FTENTOX: 2^(x log2 10) (FTENTOX 549 = FETOX + a multiply)."""
    if x.is_zero():
        return ONE_I
    return twotox(i_mul(x, LOG2_10))


def _expm1_small(u: I67):
    """e^u - 1 for |u| < 1/4 with its relative precision: D = y - 1 scaled
    by 2^s (|u| < 2^-s), each factor (1 + 2^-i) (u > 0) or (1 - 2^-i)
    (u < 0) taken as D += (1 + D) 2^-i or D -= (1 + D) 2^-i; the residual
    added at the end (e^r - 1 = r to 2^-66 of it)."""
    s = max(0, -exponent(u) - 1)
    R = to_fixed(I67(0, u.m, u.e), s)              # |u| 2^s
    D = 0
    up = not u.s
    i0 = max(1, s)
    for i in range(i0, i0 + N_ITER):
        L = rom_fixed(_LNUP, i, s) if up else -rom_fixed(_LNDN, i, s)
        if L <= 0:
            break
        while R >= L:
            R -= L
            step = asr((ONE << s) + D, i)
            D = D + step if up else D - step
    D = D + R if up else D - R
    return from_fixed(D, s)


def etoxm1(x: I67):
    """FETOXM1: |x| < 1/4 by the scaled shift-add, else e^x - 1."""
    if x.is_zero():
        return x
    Ex = exponent(x)
    if Ex < -66:
        return x
    if Ex < -2:
        return _expm1_small(x)
    return i_sub(etox(x), ONE_I)


def sinh(x: I67):
    """FSINH (the FPSP's formula): z = e^|x| - 1, sinh = sign (z + z/(1 + z))/2
    (Table 8-3: FSINH 669 = FETOXM1 527 + a divide + adds)."""
    z = etoxm1(I67(0, x.m, x.e))
    r = i_add(z, i_div(z, i_add(ONE_I, z)))
    return I67(x.s, r.m, r.e - 1)


def cosh(x: I67):
    """FCOSH: t = e^|x|, cosh = (t + 1/t)/2 (FCOSH 589 = FETOX + a divide)."""
    t = etox(I67(0, x.m, x.e))
    r = i_add(t, i_div(ONE_I, t))
    return I67(0, r.m, r.e - 1)


def tanh(x: I67):
    """FTANH (the FPSP's formula): z = e^(2|x|) - 1, tanh = sign z/(z + 2)
    (FTANH 643 = FETOXM1 + a divide).  For 2|x| > 256 it is 1 - 2^-67:
    just under 1, so no rounding mode can carry it past."""
    a = I67(0, x.m, x.e + 1)
    if exponent(a) > 7:
        return I67(x.s, ALMOST_ONE.m, ALMOST_ONE.e)
    z = etoxm1(a)
    r = i_div(z, i_add(z, I67(0, 1, 1)))
    return bounded(I67(x.s, r.m, r.e))


# -- logarithms: shift-add, y driven to 1 ------------------------------------------------

def _log1p_small(u: I67):
    """ln(1 + u) for |u| < 1/4 with its relative precision: y = 1 + u driven
    to 1 by factors (1 - 2^-i) (u > 0) or (1 + 2^-i) (u < 0), U = y - 1 and
    the logarithm both scaled by 2^s; ln(1 + U) = U for the residual."""
    s = max(0, -exponent(u) - 1)
    U = to_fixed(u, s)
    L = 0
    i0 = max(1, s)
    for i in range(i0, i0 + N_ITER):
        while U:
            step = asr((ONE << s) + U, i)
            if not step:
                break
            if U > 0:
                if U - step < 0:
                    break
                U -= step
                L -= rom_fixed(_LNDN, i, s)        # - ln(1 - 2^-i) > 0
            else:
                if U + step > 0:
                    break
                U += step
                L -= rom_fixed(_LNUP, i, s)
    return from_fixed(L + U, s)


def _log1p_frac(Mu):
    """ln(1 + u) for 0 <= u < 1 in Q2.64, unscaled."""
    U, L = Mu, 0
    for i in range(1, N_ITER):
        if not asr(ONE + U, i):
            break
        while U - asr(ONE + U, i) >= 0:
            U -= asr(ONE + U, i)
            L -= rom_fixed(_LNDN, i)
    return L + U


def logn(x: I67):
    """FLOGN: near 1 (|x - 1| < 1/4) FLOGNP1's scaled path, so a small result
    keeps its relative precision; otherwise x = 2^E m, E ln 2 + ln m."""
    u = i_sub(x, ONE_I)
    if u.is_zero():
        return u
    if exponent(u) < -2:
        return _log1p_small(u)
    E = exponent(x)
    m = I67(0, x.m, x.e - E)                       # [1, 2)
    lm = from_fixed(_log1p_frac(to_fixed(i_sub(m, ONE_I))))
    if E == 0:
        return lm
    return i_add(i_mul(i_from_int(E), LN2), lm)


def lognp1(x: I67):
    """FLOGNP1: |x| < 1/4 by the scaled shift-add, else ln(1 + x)."""
    if x.is_zero():
        return x
    Ex = exponent(x)
    if Ex < -66:
        return x
    if Ex < -2:
        return _log1p_small(x)
    return logn(i_add(ONE_I, x))


def log2(x: I67):
    """FLOG2: ln x log2(e) (FLOG2 563 = FLOGN 507 + a multiply)."""
    return i_mul(logn(x), LOG2_E)


def log10(x: I67):
    return i_mul(logn(x), LOG10_E)


def atanh(x: I67):
    """FATANH (the FPSP's formula): sign ln(1 + 2|x|/(1 - |x|))/2."""
    a = I67(0, x.m, x.e)
    r = lognp1(i_div(I67(0, a.m, a.e + 1), i_sub(ONE_I, a)))
    return I67(x.s, r.m, r.e - 1)
