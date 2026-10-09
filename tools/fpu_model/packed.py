"""Packed decimal in and out: the algorithm layer.

The manual gives the format (Table 3-4, Figure 3-11), the k-factor (4-68)
and the accuracy (4.3.3: 0.97 of a unit in the last digit in RN, 1.47 in
the other modes, for values in double's range), and says the conversions
use the constant ROM's powers of ten; it does not give the algorithm.
Motorola's 68040 FPSP does: decbin.sa (3.3, 12/19/90) and bindec.sa (3.4,
1/3/91) convert "a value in 68881/882 format", bindec pointing to "the 68882
manual for examples" - Motorola's software statement of the 68882's
FMOVE.P, read as a lead.  This module is those routines step
for step (their step names A1-A16 are kept), each FPSP floating-point
instruction replaced by the exact core rounding in the mode FPSP sets for
it, so the result is FPSP's to the bit.  The powers of ten are the ROM's
(the FMOVECR constants $33-$3F with the directions of switches.py item 19), or
FPSP's own tables (item 23).

Where FPSP cannot be followed literally, the model takes what FPSP means:
a denormal's multiply by SCALE uses its true value (FPSP
hands the operand to the FPU through a busy frame after overwriting its
exponent with a 15-bit-masked negative one, and at k = 0 divides that
corrupted operand); a pseudo-denormal (exponent 0, integer bit 1) is a
denormal with its true value (FPSP's normalizing loop shifts once before
testing, dropping the integer bit).
"""

from xreal import Ext, BIAS, EMAX, SCALE, J_BIT, ext_from_exact, zero
from rounding import post_process, round_to_quantum, EXT, RN, RZ, RM, RP
import constants


# -- extended arithmetic in a given rounding mode ------------------------------
# Each returns (result, inexact) - the INEX2 of that one instruction.

def _val(x: Ext):
    return x.exact()                    # (s, m, e)


def xround(s, m, e, sticky, rnd):
    """One extended-precision result, exceptions disabled (FPSP runs these
    with the FPCR's enable byte clear): a tiny result is denormalized as
    the post-processing does; an overflow cannot occur here."""
    if m == 0:
        return zero(s), sticky
    r = post_process(s, m, e, sticky, EXT, rnd, 'reg')
    assert not r.ovfl, 'decimal conversion overflowed extended'
    return r.ext(), r.inex


def xmul(a: Ext, b: Ext, rnd):
    s1, m1, e1 = _val(a)
    s2, m2, e2 = _val(b)
    return xround(s1 ^ s2, m1 * m2, e1 + e2, False, rnd)


def xdiv(a: Ext, b: Ext, rnd):
    s1, m1, e1 = _val(a)
    s2, m2, e2 = _val(b)
    if m1 == 0:
        return zero(s1 ^ s2), False
    sh = max(0, 80 + m2.bit_length() - m1.bit_length())
    q, r = divmod(m1 << sh, m2)
    return xround(s1 ^ s2, q, e1 - e2 - sh, r != 0, rnd)


def xadd(a: Ext, b: Ext, rnd):
    s1, m1, e1 = _val(a)
    s2, m2, e2 = _val(b)
    e = min(e1, e2)
    v = (-1 if s1 else 1) * (m1 << (e1 - e)) + (-1 if s2 else 1) * (m2 << (e2 - e))
    if v == 0:
        return zero(1 if rnd == RM else 0), False
    return xround(1 if v < 0 else 0, abs(v), e, False, rnd)


def xint(a: Ext, rnd):
    """FINT in extended precision."""
    s, m, e = _val(a)
    if m == 0:
        return a, False
    K, inexact = round_to_quantum(s, m, e, False, 0, rnd)
    return (ext_from_exact(s, K, 0) if K else zero(s)), inexact


def to_long(a: Ext, rnd):
    """FMOVE.L FPn,Dn: the value rounded to an integer."""
    s, m, e = _val(a)
    K, _ = round_to_quantum(s, m, e, False, 0, rnd)
    return -K if s else K


def xint_of(n):
    return ext_from_exact(1 if n < 0 else 0, abs(n), 0)


ONE = Ext(0, BIAS, J_BIT)
TEN = xint_of(10)


# -- the powers of ten ------------------------------------------------------------

def _ptens_rom():
    """PTENRN/RM/RP from the ROM: the FMOVECR images for 10^1 ... 10^4096
    with the item-19 directions (RZ uses RM's)."""
    out = {}
    for mode, col in ((RN, 0), (RM, 2), (RP, 3)):
        t = []
        for i in range(13):
            (be, m), inexact, adj = constants.WINUAE_DOCUMENTED[0x33 + i]
            if inexact:
                m = (m & ~0xFFFFFFFF) | ((m + adj[col]) & 0xFFFFFFFF)
            t.append(Ext(0, be, m))
        out[mode] = t
    return out


def _ptens_fpsp():
    """FPSP's own tables (get_op.S), verbatim."""
    rn = [(0x4002, 0xA000000000000000), (0x4005, 0xC800000000000000),
          (0x400C, 0x9C40000000000000), (0x4019, 0xBEBC200000000000),
          (0x4034, 0x8E1BC9BF04000000), (0x4069, 0x9DC5ADA82B70B59E),
          (0x40D3, 0xC2781F49FFCFA6D5), (0x41A8, 0x93BA47C980E98CE0),
          (0x4351, 0xAA7EEBFB9DF9DE8E), (0x46A3, 0xE319A0AEA60E91C7),
          (0x4D48, 0xC976758681750C17), (0x5A92, 0x9E8B3B5DC53D5DE5),
          (0x7525, 0xC46052028A20979B)]
    rm = [0xA000000000000000, 0xC800000000000000, 0x9C40000000000000,
          0xBEBC200000000000, 0x8E1BC9BF04000000, 0x9DC5ADA82B70B59D,
          0xC2781F49FFCFA6D5, 0x93BA47C980E98CDF, 0xAA7EEBFB9DF9DE8D,
          0xE319A0AEA60E91C6, 0xC976758681750C17, 0x9E8B3B5DC53D5DE5,
          0xC46052028A20979A]
    rp = [0xA000000000000000, 0xC800000000000000, 0x9C40000000000000,
          0xBEBC200000000000, 0x8E1BC9BF04000000, 0x9DC5ADA82B70B59E,
          0xC2781F49FFCFA6D6, 0x93BA47C980E98CE0, 0xAA7EEBFB9DF9DE8E,
          0xE319A0AEA60E91C7, 0xC976758681750C18, 0x9E8B3B5DC53D5DE6,
          0xC46052028A20979B]
    return {RN: [Ext(0, e, m) for e, m in rn],
            RM: [Ext(0, rn[i][0], rm[i]) for i in range(13)],
            RP: [Ext(0, rn[i][0], rp[i]) for i in range(13)]}


PTEN_ROM = _ptens_rom()
PTEN_FPSP = _ptens_fpsp()


def pow10(n, table, rnd):
    """10^n by binary powering from a power-of-ten table, each multiply
    rounded in rnd (decbin's calc_p, bindec's A7 and A13)."""
    p, i, inexact = ONE, 0, False
    while n:
        if n & 1:
            p, ix = xmul(p, table[i], rnd)
            inexact |= ix
        n >>= 1
        i += 1
    return p, inexact


# -- the packed image -------------------------------------------------------------

def unpack_fields(v):
    """The 96-bit packed image's fields (Figure 3-11)."""
    return {
        'SM': (v >> 95) & 1, 'SE': (v >> 94) & 1, 'YY': (v >> 92) & 3,
        'EXP': [(v >> (88 - 4 * i)) & 0xF for i in range(3)],   # EXP2 EXP1 EXP0
        'EXP3': (v >> 76) & 0xF,
        'M16': (v >> 64) & 0xF,
        'FRAC': [(v >> (60 - 4 * i)) & 0xF for i in range(16)],  # MANT15 .. MANT0
    }


# -- decbin: packed to extended (FPSP decbin.sa; get_op.sa's unpack) ------------------

RTABLE = [RN, RN, RN, RN, RM, RP, RM, RP, RM, RP, RP, RM, RP, RM, RM, RP]


def decode_in(v, rnd, pten):
    """A packed operand as extended: (Ext, INEX1).  get_op's special cases
    first: $FFF with SE and YY set is an infinity or a NaN whose image *is*
    the extended one (Table 3-4 note 1); an all-zero integer digit and
    fraction is a signed zero whatever the exponent (note 2)."""
    f = unpack_fields(v)
    frac64 = v & ((1 << 64) - 1)
    exp12 = (v >> 80) & 0xFFF
    if exp12 == 0xFFF and f['SE'] and f['YY'] == 3:
        return Ext(f['SM'], EMAX, frac64), False
    if f['M16'] == 0 and frac64 == 0:
        return zero(f['SM']), False
    return decbin(f, rnd, pten)


def decbin(f, rnd, pten):
    # A1 (calc_e): the three exponent digits by multiply-and-add - a
    # non-decimal digit is used as its value (note 2) - signed by SE, less
    # 16 for the 17 digits read as an integer.
    e = 0
    for d in f['EXP']:
        e = e * 10 + d
    if f['SE']:
        e = -e
    e -= 16
    SE = 1 if e < 0 else 0
    e = abs(e)
    SM = f['SM']
    # A2 (calc_m): the 17 digits as an integer; exact (< 16 x 10^16 < 2^58).
    digits = [f['M16']] + f['FRAC']
    M = 0
    for d in digits:
        M = M * 10 + d
    fp0 = xint_of(-M if SM else M)
    # A3 (ap_st_z): for |exp| > 27, append or strip zeros to pull the
    # exponent toward zero.  Exact either way.
    if e > 27:
        if not SE:
            count = _lead_zeros(f)
            e -= count
            if e < 0:
                e, SE = -e, 1
            p, _ = pow10(count, pten[RN], RN)
            fp0, _ = xmul(fp0, p, RN)
        else:
            count = _trail_zeros(f)
            e -= count
            if e <= 0:
                e, SE = -e, 0
            p, _ = pow10(count, pten[RN], RN)
            fp0, _ = xdiv(fp0, p, RN)
    # A4 (pwrten): 10^e in the mode RTABLE gives for {RND, SM, SE}, from
    # that mode's table; A5 (norm): one multiply or divide in that mode.
    mode = RTABLE[(rnd << 2) | (SM << 1) | SE]
    p, _ = pow10(e, pten[mode], mode)
    if SE:
        r, inexact = xdiv(fp0, p, mode)
    else:
        r, inexact = xmul(fp0, p, mode)
    # "Check if the final mul or div resulted in an inex2 exception.  If
    # so, set inex1" - the last instruction's INEX2 only.
    return r, inexact


def _lead_zeros(f):
    if f['M16']:
        return 0
    count = 1
    lw2, lw3 = f['FRAC'][:8], f['FRAC'][8:]
    scan = lw2
    if not any(lw2):
        count += 8
        scan = lw3
    for d in scan:
        if d:
            break
        count += 1
    return count


def _trail_zeros(f):
    lw2, lw3 = f['FRAC'][:8], f['FRAC'][8:]
    count = 0
    scan = lw3
    if not any(lw3):
        count = 8
        scan = lw2
    for d in reversed(scan):
        if d:
            break
        count += 1
    return count


# -- bindec: extended to packed (FPSP bindec.sa, binstr.sa) ------------------------

LOG2 = Ext(0, 0x3FFD, 0x9A209A84FBCFF798)       # log10(2), below
LOG2UP1 = Ext(0, 0x3FFD, 0x9A209A84FBCFF799)    # and one unit above
RBDTBL = [RN, RN, RN, RN, RP, RP, RM, RM, RP, RM, RM, RP, RM, RP, RP, RM]


class BindecTrace:
    """What the conversion did, for the checks: the passes, and whether
    A13's second-pass carry (LEN + 1) was taken."""

    def __init__(self):
        self.passes = 0
        self.second_pass_carry = False


def bindec(x: Ext, k, rnd, pten, trace=None):
    """A finite nonzero register value to a packed image: (bits, INEX2,
    OPERR).  k is the k-factor, -64 to +63."""
    tr = trace or BindecTrace()
    sigma = x.s
    s, m, e = x.exact()
    # A1: "If input is unnormalized or denormalized, normalize it" and flag
    # a denormal: one whose normalized exponent field would be 0 or less.
    E = m.bit_length() - 1 + e                   # unbiased, of 1.f
    denorm = (E + BIAS) <= 0
    X = ext_from_exact(0, m, e)                  # A2: |X|
    # A3: ILOG, log10 of X, from e + 0.f in RM, times log10(2) (rounded
    # down, or up for a negative log), truncated toward minus infinity.
    if denorm:
        ILOG = -4933
    else:
        n = m.bit_length()
        onef = Ext(0, BIAS, m << (64 - n))       # 1.f
        fp0, _ = xadd(onef, xint_of(E), RM)
        fp0, _ = xadd(fp0, ONE.neg(), RM)
        if fp0.is_zero or not fp0.s:
            fp0, _ = xmul(fp0, LOG2, RM)
        else:
            fp0, _ = xmul(fp0, LOG2UP1, RM)
        ILOG = to_long(fp0, RM) if not fp0.is_zero else 0
    ICTR = 0
    inex2 = False
    operr = False
    while True:
        tr.passes += 1
        # A6: LEN.
        LEN = k if k > 0 else ILOG + 1 - k
        if LEN <= 0:
            LEN = 1
        elif LEN > 17:
            LEN = 17
            if k > 0:
                operr = True
        # A7: ISCALE and SCALE = 10^|ISCALE| in the mode RBDTBL gives for
        # {RND, LAMBDA, sign(X)}.
        if k <= 0 and not (k < ILOG):
            ILOG = k
        ISCALE = ILOG + 1 - LEN
        LAMBDA = 1 if ISCALE < 0 else 0
        extra24 = False
        if ISCALE < 0 and ISCALE <= -4908:
            ISCALE += 24
            extra24 = True
        ISCALE = abs(ISCALE)
        mode = RBDTBL[(rnd << 2) | (LAMBDA << 1) | sigma]
        table = pten[mode]
        SC, _ = pow10(ISCALE, table, mode)
        # A8, A9: RZ; Y = |X| / SCALE, or |X| x SCALE (after x 10^8 x 10^16
        # when ISCALE was brought up by 24).  The last instruction's INEX2
        # is kept for A10.
        if not LAMBDA:
            Y, inexact = xdiv(X, SC, RZ)
        elif denorm:
            # sc_mul's denormal path: the FPU completes X x SCALE (an
            # FRESTOREd busy frame), then x 10^8 and x 10^16 - always, 24 or
            # not; A10 sees the last multiply's INEX2.
            Y, _ = xmul(X, SC, RZ)
            Y, _ = xmul(Y, table[3], RZ)
            Y, inexact = xmul(Y, table[4], RZ)
        else:
            X2 = X
            if extra24:
                X2, _ = xmul(X2, table[3], RZ)
                X2, _ = xmul(X2, table[4], RZ)
            Y, inexact = xmul(X2, SC, RZ)
        # A10: an inexact scale ORs a one into Y's LSB.
        if inexact:
            Y = Ext(Y.s, Y.e, Y.m | 1)
        # A11, A12: YINT = FINT(+/-Y) in the user's mode; its INEX2 stays
        # in the user's FPSR.
        YINT, ix = xint(Ext(sigma, Y.e, Y.m), rnd)
        inex2 |= ix
        a = _abs_int(YINT)
        # A13: LEN digits?  (10^(LEN-1) and 10^LEN are exact.)
        if ICTR == 0:
            if not denorm and a < 10 ** (LEN - 1):
                ILOG -= 1
                ICTR = 1
                continue
            if a > 10 ** LEN:
                ILOG += 1
                ICTR = 1
                continue
            if a == 10 ** LEN:
                a //= 10
                ILOG += 1
            P = 10 ** LEN
        else:
            P = 10 ** LEN
            if a == P:
                # FPSP increments LEN here as well ("and inc LEN") - the
                # string then carries a leading zero digit.  Kept as
                # written; the checks report when it is reached.
                a //= 10
                ILOG += 1
                LEN += 1
                P *= 10
                tr.second_pass_carry = True
        break
    # A14: |YINT| / 10^LEN in RZ as a binary fraction (the point left of
    # bit 63), rounded at bit 7 ("strip off lsb not used by 882"), then
    # binstr's LEN digits.
    F, _ = xdiv(xint_of(a), xint_of(P), RZ)
    frac = _fraction64(F)
    if frac:
        frac = ((frac + 0x80) & ~0x7F) & ((1 << 64) - 1)
    mant_digits = _binstr(frac, LEN)
    # A15: the exponent's four digits, by the same route (|ILOG| / 10^4).
    fzero = F.is_zero
    if denorm:
        expo = (abs(ILOG) if k < 0 else 4933) if fzero else abs(ILOG)
    else:
        expo = 1 if fzero else abs(ILOG)
    Fe, _ = xdiv(xint_of(expo), xint_of(10000), RZ) if expo else (zero(0), False)
    efrac = _fraction64(Fe)
    efrac = ((efrac + 0x80) & ~0x7F) & ((1 << 64) - 1)
    e4 = _binstr(efrac, 4)                     # thousands, hundreds, tens, units
    if e4[0]:
        operr = True
    # A16: SM = sign of X, SE = sign of ILOG.
    SE = 1 if ILOG < 0 else 0
    bits = (sigma << 95) | (SE << 94)
    bits |= (e4[1] << 88) | (e4[2] << 84) | (e4[3] << 80) | (e4[0] << 76)
    # binstr writes LEN digits from M16 on; M16 is the low nibble of word 4.
    pos = [64] + [60 - 4 * i for i in range(16)]
    for d, p in zip(mant_digits, pos):
        bits |= d << p
    return bits, inex2, operr


def _abs_int(x: Ext):
    if x.is_zero:
        return 0
    s, m, e = x.exact()
    return m << e if e >= 0 else m >> -e


def _fraction64(F: Ext):
    """A value below 1 as the 64-bit fraction binstr takes: its mantissa
    shifted right to put the binary point left of bit 63 (A14: exponent
    $3FFE unshifted, each step down one more)."""
    if F.is_zero or F.e == 0:
        return 0
    d0 = F.e - 0x3FFD
    if d0 > 0:
        return F.m
    return F.m >> (-d0 + 1)


def _binstr(frac, n):
    """binstr.sa: n digits of a 64-bit binary fraction, each the integer
    part of the fraction times ten."""
    out = []
    for _ in range(n):
        frac *= 10
        out.append(frac >> 64)
        frac &= (1 << 64) - 1
    return out
