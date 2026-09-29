"""The constant ROM (FMOVECR, plan 8.6.8; UM 4-72/4-73) and the exact values
it rounds from.

The documented constants are computed here from integer series to 256 bits,
so the model needs nothing beyond the standard library; the checks compare
them with mpmath.  An irrational constant is carried as its first 256 bits
with a sticky tail (it never ends), a power of ten exactly.
"""

PREC_BITS = 256


def _atan_inv(n, bits):
    """atan(1/n) x 2^bits, truncated (Taylor series; n >= 2)."""
    one = 1 << (bits + 16)
    term = one // n
    total, k, sign, n2 = term, 1, -1, n * n
    while term:
        term //= n2
        total += sign * (term // (2 * k + 1))
        sign, k = -sign, k + 1
    return total >> 16


def _atanh_inv(n, bits):
    """atanh(1/n) x 2^bits, truncated."""
    one = 1 << (bits + 16)
    term = one // n
    total, k, n2 = term, 1, n * n
    while term:
        term //= n2
        total += term // (2 * k + 1)
        k += 1
    return total >> 16


def _exact_constants(bits=PREC_BITS + 32):
    g = bits
    pi = 4 * (4 * _atan_inv(5, g) - _atan_inv(239, g))           # Machin
    # e = sum 1/k!
    one = 1 << (g + 16)
    term, e_sum, k = one, one, 1
    while term:
        term //= k
        e_sum += term
        k += 1
    e = e_sum >> 16
    ln2 = 2 * _atanh_inv(3, g)                                  # ln 2 = 2 atanh(1/3)
    ln10 = 3 * ln2 + 2 * _atanh_inv(9, g)                       # ln 1.25 = 2 atanh(1/9)
    scale = 1 << g
    return {
        'pi': pi, 'e': e, 'ln2': ln2, 'ln10': ln10,
        'log10_2': ln2 * scale // ln10,
        'log2_e': scale * scale // ln2,
        'log10_e': scale * scale // ln10,
    }, g


def _as_mantissa(v, g):
    """A positive fixed-point value v x 2^-g as (m, e, sticky) with the
    leading 256 bits of m kept and the rest folded into sticky."""
    n = v.bit_length()
    drop = n - PREC_BITS
    return v >> drop, drop - g, True


_C, _G = _exact_constants()

# Offset -> (m, e, sticky): the value m x 2^e (plus a tail when sticky).
DOCUMENTED = {
    0x00: _as_mantissa(_C['pi'], _G),
    0x0B: _as_mantissa(_C['log10_2'], _G),
    0x0C: _as_mantissa(_C['e'], _G),
    0x0D: _as_mantissa(_C['log2_e'], _G),
    0x0E: _as_mantissa(_C['log10_e'], _G),
    0x0F: (0, 0, False),                        # 0.0
    0x30: _as_mantissa(_C['ln2'], _G),
    0x31: _as_mantissa(_C['ln10'], _G),
}
for _i, _n in enumerate([0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024,
                         2048, 4096]):
    DOCUMENTED[0x32 + _i] = (10 ** _n, 0, False)

NAMES = {0x00: 'pi', 0x0B: 'log10(2)', 0x0C: 'e', 0x0D: 'log2(e)',
         0x0E: 'log10(e)', 0x0F: '0.0', 0x30: 'ln(2)', 0x31: 'ln(10)'}
for _i, _n in enumerate([0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024,
                         2048, 4096]):
    NAMES[0x32 + _i] = '10^%d' % _n


# --- WinUAE's tables (leads, plan 8.6.14 items 7 and 19; fpp.cpp at d42db95).
# Documented constants: the extended image (RN), whether WinUAE treats it as
# inexact, and its adjustment of the low longword per RND (RN, RZ, RM, RP).
WINUAE_DOCUMENTED = {
    0x00: ((0x4000, 0xC90FDAA2_2168C235), 1, (0, -1, -1, 0)),
    0x0B: ((0x3FFD, 0x9A209A84_FBCFF798), 1, (0, 0, 0, 1)),
    0x0C: ((0x4000, 0xADF85458_A2BB4A9A), 1, (0, 0, 0, 1)),
    0x0D: ((0x3FFF, 0xB8AA3B29_5C17F0BC), 1, (0, -1, -1, 0)),
    0x0E: ((0x3FFD, 0xDE5BD8A9_37287195), 0, (0, 0, 0, 0)),
    0x0F: ((0x0000, 0x00000000_00000000), 0, (0, 0, 0, 0)),
    0x30: ((0x3FFE, 0xB17217F7_D1CF79AC), 1, (0, -1, -1, 0)),
    0x31: ((0x4000, 0x935D8DDD_AAA8AC17), 1, (0, -1, -1, 0)),
    0x32: ((0x3FFF, 0x80000000_00000000), 0, (0, 0, 0, 0)),
    0x33: ((0x4002, 0xA0000000_00000000), 0, (0, 0, 0, 0)),
    0x34: ((0x4005, 0xC8000000_00000000), 0, (0, 0, 0, 0)),
    0x35: ((0x400C, 0x9C400000_00000000), 0, (0, 0, 0, 0)),
    0x36: ((0x4019, 0xBEBC2000_00000000), 0, (0, 0, 0, 0)),
    0x37: ((0x4034, 0x8E1BC9BF_04000000), 0, (0, 0, 0, 0)),
    0x38: ((0x4069, 0x9DC5ADA8_2B70B59E), 1, (0, -1, -1, 0)),
    0x39: ((0x40D3, 0xC2781F49_FFCFA6D5), 1, (0, 0, 0, 1)),
    0x3A: ((0x41A8, 0x93BA47C9_80E98CE0), 1, (0, -1, -1, 0)),
    0x3B: ((0x4351, 0xAA7EEBFB_9DF9DE8E), 1, (0, -1, -1, 0)),
    0x3C: ((0x46A3, 0xE319A0AE_A60E91C7), 1, (0, -1, -1, 0)),
    0x3D: ((0x4D48, 0xC9767586_81750C17), 1, (0, 0, 0, 1)),
    0x3E: ((0x5A92, 0x9E8B3B5D_C53D5DE5), 1, (0, -1, -1, 0)),
    0x3F: ((0x7525, 0xC4605202_8A20979B), 1, (0, -1, -1, 0)),
}

# Undocumented offsets $01-$0A: WinUAE's "68881 and 68882 have identical
# undefined fields" table; every other undocumented offset below $40 reads
# entry 0.  Images as (sign, exponent, mantissa).
WINUAE_UNDEFINED = [
    (0, 0x4000, 0x00000000_00000000),
    (0, 0x4001, 0xFE000682_00000000),
    (0, 0x4001, 0xFFC00503_80000000),
    (0, 0x2000, 0x7FFFFFFF_00000000),
    (0, 0x0000, 0xFFFFFFFF_FFFFFFFF),
    (0, 0x3C00, 0xFFFFFFFF_FFFFF800),
    (0, 0x3F80, 0xFFFFFF00_00000000),
    (0, 0x0001, 0xF65D8D9C_00000000),
    (0, 0x7FFF, 0x001E0000_00000000),
    (0, 0x43FF, 0x000E0000_00000000),
    (0, 0x407F, 0x00060000_00000000),
]
