"""The constant ROM (plan 8.8.10), built from the reference model's own
tables so the microcode and the model cannot disagree about a bit.

Layout (256 words of fields.KWORD_BITS):
  $00-$3F  FMOVECR, by offset: the documented constants as 8.6.14 item 19's
           `rom64` (a 64-bit image and the direction of the true value -
           Daniel's decision, 2026-09-29), the undocumented offsets as item
           7's WinUAE table (the model's default)
  $40-$61  atan(2^-i), i = 0..33       } fixed point, two's complement,
  $62-$83  ln(1 + 2^-i), i = 0..33     } floor(v x 2^(64+i)), so that an
  $84-$A5  ln(1 - 2^-i), i = 0..33     } arithmetic right shift by i - s
                                       } places it in Q2.64 scaled by 2^s
                                       } with the model's truncation
                                       } toward -infinity (8.7.3)
  $A6-$C7  the CORDIC gain corrections 1/K(i0), i0 = 0..33, in Q2.64
  $C8-     named constants (below)
The tables stop at 34 words: beyond, the shifter makes the value from
`fx_one` (transcend.rom_fixed).  The model's atanh(2^-i) table is not used
by any algorithm and is not in the ROM.

A floating constant is (sign, the biased 18-bit exponent, the 67-bit
mantissa with bit 66 the integer bit); a fixed-point one carries its scale
in the exponent field (64 + i), which nothing reads.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fpu_model'))

import constants                                   # noqa: E402
import transcend as T                              # noqa: E402
from fields import (kword, KROM_WORDS, MANT_BITS, BIAS,          # noqa: E402
                    DIR_EXACT, DIR_ABOVE, DIR_BELOW)

FMOVECR_BASE = 0x00
ATAN_BASE = 0x40
LNUP_BASE = 0x62
LNDN_BASE = 0x84
GAIN_BASE = 0xA6
NAMED_BASE = 0xC8
TABLE_WORDS = T.ATAN_WORDS                          # 34

MANT_MASK = (1 << MANT_BITS) - 1


def _fixed(v, scale):
    """A fixed-point value (an integer, already floor(v x 2^scale)) as a
    two's complement ROM word."""
    assert -(1 << (MANT_BITS - 1)) <= v < 1 << (MANT_BITS - 1), (v, scale)
    return kword(1 if v < 0 else 0, scale, v & MANT_MASK)


def _i67(x: T.I67):
    """An I67 value m x 2^e (m of 67 bits) in the internal format."""
    if x.m == 0:
        return kword(x.s, 0, 0)
    assert x.m.bit_length() == MANT_BITS
    return kword(x.s, x.e + (MANT_BITS - 1) + BIAS, x.m)


def _ext(s, be, m64, direction=DIR_EXACT):
    """An extended image (biased exponent, 64-bit mantissa)."""
    return kword(s, be, m64 << 3, direction)


def _direction(adj):
    """WinUAE's per-RND adjustment of the RN image (RN, RZ, RM, RP)."""
    if adj == (0, 0, 0, 1):
        return DIR_ABOVE                  # RP steps up: the value lies above
    if adj == (0, -1, -1, 0):
        return DIR_BELOW                  # RZ/RM step down: it lies below
    assert adj == (0, 0, 0, 0), adj
    return DIR_EXACT


def _exp_word(e):
    return kword(0, e, 0)


def build():
    """(the 256 words, {name: address})."""
    rom = [0] * KROM_WORDS
    names = {}

    # FMOVECR by offset.
    for off in range(0x40):
        if off in constants.WINUAE_DOCUMENTED:
            (be, m), inexact, adj = constants.WINUAE_DOCUMENTED[off]
            rom[FMOVECR_BASE + off] = _ext(0, be, m, _direction(adj) if inexact else DIR_EXACT)
        else:
            s, be, m = constants.WINUAE_UNDEFINED[off if off <= 10 else 0]
            rom[FMOVECR_BASE + off] = _ext(s, be, m)
    names['fmovecr'] = FMOVECR_BASE
    names['pten'] = FMOVECR_BASE + 0x33               # 10^1 ... 10^4096 (UM 4.3.3)

    # The fixed-point tables: floor(v x 2^(64+i)) from the model's 220-bit ones.
    shift = T._P - T.F
    for base, table, name in ((ATAN_BASE, T._ATAN, 'atan'),
                              (LNUP_BASE, T._LNUP, 'lnup'),
                              (LNDN_BASE, T._LNDN, 'lndn')):
        for i in range(TABLE_WORDS):
            rom[base + i] = _fixed(table[i] >> (shift - i), T.F + i)
        names[name] = base
    for i in range(TABLE_WORDS):
        rom[GAIN_BASE + i] = _fixed(T.gain(i), T.F)
    names['gain'] = GAIN_BASE

    named = [
        ('fx_one', _fixed(T.ONE, T.F)),               # 1.0 in Q2.64
        ('fx_negone', _fixed(-T.ONE, T.F)),           # -1.0 in Q2.64
        ('pi', _i67(T.PI)),
        ('twopi', _i67(T.TWOPI)),
        ('halfpi', _i67(T.HALFPI)),
        ('quarterpi', _i67(T.QUARTERPI)),
        ('ln2', _i67(T.LN2)),
        ('inv_ln2', _i67(T.INV_LN2)),
        ('log10_e', _i67(T.LOG10_E)),
        ('log2_e', _i67(T.LOG2_E)),
        ('log2_10', _i67(T.LOG2_10)),
        ('almost_one', _i67(T.ALMOST_ONE)),
        ('one', _ext(0, BIAS, 1 << 63)),
        ('ten', _ext(0, BIAS + 3, 0xA << 60)),
        ('two31', _ext(0, BIAS + 31, 1 << 63)),
        ('two15', _ext(0, BIAS + 15, 1 << 63)),
        ('two7', _ext(0, BIAS + 7, 1 << 63)),
        # Exponent limits in the internal (extended-biased) exponent, for
        # 8.6.4's range checks by PREC and destination format.
        ('ext_emax', _exp_word(0x7FFE)),
        ('ext_emin', _exp_word(0)),                  # extended is tiny below biased 0 (rounding.py)
        ('dbl_emax', _exp_word(BIAS + 1023)),
        ('dbl_emin', _exp_word(BIAS - 1022)),
        ('sgl_emax', _exp_word(BIAS + 127)),
        ('sgl_emin', _exp_word(BIAS - 126)),
        ('dbl_bias', _exp_word(BIAS - 1023)),         # internal - IEEE double
        ('sgl_bias', _exp_word(BIAS - 127)),
        ('bias', _exp_word(BIAS)),
        ('int_exp', _exp_word(BIAS + MANT_BITS - 1)),  # an integer at bit 0 (OPINT)
        ('exp_inf', _exp_word(0x7FFF)),
        ('qbit', kword(0, 0, 1 << 65)),               # a NaN's nonsignaling bit (bit 62)
        ('nan', _ext(0, 0x7FFF, (1 << 64) - 1)),      # the chip's NaN (UM 6.1.3)
        # The exceptional operand (6.1.4, 6.1.5; rounding.exceptional_operand):
        # the exponent wrapped by $6000, or 0 past the 17-bit catastrophic
        # limits (biased: overflow above 57343, underflow at -24576 and below).
        ('xop_bias', _exp_word(0x6000)),
        ('ovfl_cat', _exp_word(BIAS + 0xA000)),
        ('unfl_cat', _exp_word(-24575)),
    ]
    for i, (n, w) in enumerate(named):
        rom[NAMED_BASE + i] = w
        names[n] = NAMED_BASE + i
    assert NAMED_BASE + len(named) <= KROM_WORDS
    return rom, names


ROM, NAMES = build()


if __name__ == '__main__':
    from fields import kword_fields
    for n, a in sorted(NAMES.items(), key=lambda kv: kv[1]):
        s, e, m, d = kword_fields(ROM[a])
        print('$%02X  %-10s  s=%d e=%6d m=%017X d=%d' % (a, n, s, e, m, d))
