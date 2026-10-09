"""The model's switches: every point where the 68882 manual is silent or
contradicts itself.

Each switch is a numbered item.  The default is the manual's reading, or,
where the manual is silent, WinUAE's answer - a lead, not evidence.
Settling an item later, from silicon or by decision, is a change to
one default here.  The FPGA is built for one setting; the switches exist only
in the model.
"""

from dataclasses import dataclass


@dataclass
class Switches:
    # Item 1.  FATANH(+1) and FATANH(-1).  'manual': +1 gives -inf and
    # -1 gives +inf, with DZ, as printed twice (4-28, 6.1.6).  'ieee':
    # sign(x) x inf (WinUAE; Motorola's 68040 FPSP).
    fatanh_one: str = 'manual'

    # Item 2.  FLOGNP1(-1).  'manual': a NaN and DZ (4-60, both editions).
    # 'neg_inf': -inf and DZ (6.1.6's "for the FLOGx instructions"; WinUAE).
    flognp1_minus_one: str = 'manual'

    # Item 3.  FMOVE <ea>,FPn in single or double PREC.  'section6': the
    # post-processing of 6.1.4-6.1.5, overflowing and underflowing at the
    # PREC range like every other instruction.  'table': 4-65 read literally
    # - the mantissa rounded to PREC, the exponent kept to extended's range,
    # so OVFL and UNFL arise only where extended's would.
    fmove_in_range: str = 'section6'

    # Item 4.  FSCALE's and FREM's INEX2, and FMOD's OVFL, which their pages
    # list as "cleared" while their notes say the re-rounded FPn may be
    # inexact or overflow.  'section6': 6.1.7/6.1.4 decide, as for every
    # other rounded result (a design decision).  'table': those
    # bits forced clear.
    rem_scale_inex: str = 'section6'

    # Item 5.  FMOD/FREM's quotient byte when no quotient is computed.  The
    # manual is silent.  'winuae': a NaN or an operand error gives quotient
    # 0 and sign 0; a source infinity or a destination zero gives 0 with the
    # sign XOR (softfloat floatx80_mod/rem).  'unchanged': the byte is left
    # as it was.
    quotient_special: str = 'winuae'

    # Item 6.  The redundant opmodes ($05 $07 $0B $13 $17 $1B $29-$2F $39
    # $3B-$3F).  'winuae': each is its neighbour with opmode bit 0 clear, and
    # $38-$3F split by bit 1 into FCMP and FTST.  'unknown': the model
    # refuses to execute them.
    redundant_opmodes: str = 'winuae'

    # Item 7.  FMOVECR's undocumented offsets.  'winuae': WinUAE's table and
    # its PREC/RND adjustments.  'unknown': the model refuses them.
    fmovecr_undefined: str = 'winuae'

    # Item 8.  The NaN a reset or a null FRESTORE loads into FP0-FP7.
    reset_nan: tuple = (0, 0x7FFF, 0xFFFF_FFFF_FFFF_FFFF)

    # Item 9.  FSGLMUL/FSGLDIV input truncation: 24 mantissa bits counting
    # the integer bit (4-98, 4-100; WinUAE), or 23 (4-17).
    sgl_truncate_bits: int = 24

    # Item 10.  The state frames' version number.
    version: int = 0x1F

    # Item 17.  The FPCC combinations the chip never produces.  'winuae': its
    # 6888x truth table, 16 FPCC values x 32 predicates.  'equations': the
    # predicates' equations on the bits as written.
    fpcc_table: str = 'winuae'

    # Item 18.  FPCC after an enabled SNAN, OPERR or DZ trap leaves the
    # destination register unchanged.  'unchanged' (execution terminated)
    # or 'result' (set from the result that was not written).
    fpcc_on_trap: str = 'unchanged'

    # Item 19.  The documented FMOVECR constants.  'rom64': 4-72's "fetches
    # an extended precision constant ... rounds it to the precision" - the
    # ROM holds a 64-bit constant and the side the true value lies on; the
    # bits are WinUAE's (a lead: log10(2) and e truncated rather than
    # nearest, log10(e) exact), then the manual's PREC post-processing;
    # the design decision, corroborated by Motorola's FPSP.
    # 'exact': the exact value rounded once.  'winuae': WinUAE's whole
    # procedure, whose PREC rounding keeps the extended exponent range (so
    # 10^64 does not overflow in single, against 2.2.2's range control).
    fmovecr_documented: str = 'rom64'

    # Item 20.  FINT/FINTRZ in single or double PREC.  'twice': rounded to an
    # integer (4-50), then rounded to PREC as every register result is
    # (2.2.2).  'once': one rounding to the coarser of the two.
    fint_prec: str = 'twice'

    # Item 21.  FGETMAN in single or double PREC.  'exact': the mantissa
    # unrounded - 4-48 lists INEX2 as cleared.  'rounded': rounded to PREC.
    fgetman_prec: str = 'exact'

    # Item 22.  FCMP when an operand is a NaN: the N bit.  'winuae': N clear
    # (WinUAE drops the sign for the 6888x and keeps it for the 68040).
    # 'sign': N is the propagated NaN's sign, as for any NaN result (2-1).
    fcmp_nan_sign: str = 'winuae'

    # Item 23.  The powers of ten the decimal conversions use.  'rom': the
    # constant ROM's (the FMOVECR images for 10^1 ... 10^4096 with item 19's
    # directions) - UM 4.3.3, "the on-chip ROM values of powers of 10".
    # 'fpsp': Motorola's 68040 FPSP tables verbatim (get_op.sa), whose RM
    # and RP entries for 10^2048 are one unit high.
    pten_tables: str = 'rom'

    # Item 24.  FMOVE.P of a zero, infinity or NaN.  'manual': the packed format and the
    # FMOVE page - a signaling NaN sets SNAN and is stored nonsignaling, and
    # a k-factor above +17 is an operand error for every source.  'fpsp':
    # FPSP's p_move - the register's image stored as it is, "status bits
    # are not set", no OPERR for the k-factor.
    packed_out_special: str = 'manual'


DEFAULT = Switches()
