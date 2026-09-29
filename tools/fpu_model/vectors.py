"""Test vectors for the RTL (plan 8.7 work 5d, for 8.4 item 7): every
instruction the model executes, as a line of fixed hex fields that a
Verilog bench reads with $fscanf, and that `replay.py` reads back through
the model.

    python vectors.py [out.vec] [scale] [seed]

The file is generated, not kept: it is deterministic in its seed and the
model's switches (both in the header), so a bench regenerates it.

One vector a line, '#' lines are comments.  Fields (hex, fixed width,
space-separated; an 80-bit register image is sign-and-exponent then the
64-bit mantissa, 20 digits):

   1 group     a word (rounding, convert, packed, fmovecr, transcend,
               special, trap, cond, decode)
   2 kind      G a general instruction (command word), C a conditional
               (predicate)
   3 cmd       4   the command word, or the predicate
   4 fpcr      8   before
   5 fpsr      8   before
   6 rx        20  FPm (the source register of opclass 000) before
   7 ry        20  FPn (the destination) before
   8 rc        20  FPc (FSINCOS's cosine register, command bits 2-0) before
   9 operand   24  opclass 010's source, right-aligned in 96 bits (B W L S
                   D X P as the command word's format says)
  10 dreg      8   Dn for a dynamic k-factor
 expected:
  11 ry'       20  FPn after
  12 rc'       20  FPc after
  13 fpsr'     8   after
  14 vector    2   the exception vector taken, 00 if none (0B F-line)
  15 when      1   0 none, 1 pre-instruction, 2 mid-instruction
  16 store     24  opclass 011's stored value right-aligned; a
                   conditional's answer (0/1)
  17 xop       20  the exceptional operand (0 when none or undefined)

Register numbers: rx is FP1 and ry FP2 (RX = RY = 2 when the command says
so); FSINCOS's FPc is whatever its command word names, FP5 here.  FPIAR is
not in the vectors (the model has no program counter to give it).
"""

import random
import sys

from xreal import Ext, BIAS, EMAX, J_BIT, Q_BIT, ext_from_exact, zero, inf, NAN
import fpu as F
from fpu import FPU, Unmodelled
from switches import DEFAULT

M64 = (1 << 64) - 1
RX, RY, RC = 1, 2, 5


def x80(x: Ext):
    return (x.s << 79) | (x.e << 64) | x.m


def from80(v):
    return Ext((v >> 79) & 1, (v >> 64) & EMAX, v & M64)


def fields_of(group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, out):
    ry2, rc2, fpsr2, vec, when, store, xop = out
    return '%s %s %04X %08X %08X %020X %020X %020X %024X %08X %020X %020X %08X %02X %X %024X %020X' % (
        group, kind, cmd, fpcr, fpsr, x80(rx), x80(ry), x80(rc), operand, dreg,
        x80(ry2), x80(rc2), fpsr2, vec, when, store, x80(xop))


def execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, sw=DEFAULT):
    """Run one vector's instruction through the model; the expected half."""
    f = FPU(sw)
    f.fpcr, f.fpsr = fpcr, fpsr
    f.fp[RX], f.fp[RY], f.fp[RC] = rx, ry, rc
    if kind == 'C':
        o = f.condition(cmd)
        store = int(bool(o.cond)) if o.cond is not None else 0
    else:
        o = f.general(cmd, operand, dreg=dreg)
        store = o.store if isinstance(o.store, int) else 0
    when = {None: 0, 'pre': 1, 'mid': 2}[o.when]
    xop = x80(o.xop) if o.xop is not None else 0
    return (f.fp[RY], f.fp[RC], f.fpsr, o.vector or 0, when, store, from80(xop) if xop else Ext(0, 0, 0))


# -- operand generators ------------------------------------------------------------------

def special_values():
    return [zero(0), zero(1), inf(0), inf(1), NAN, Ext(1, EMAX, J_BIT | Q_BIT | 0x1234),
            Ext(0, EMAX, J_BIT | 0x5678),                          # SNaN
            Ext(0, 0, 1), Ext(1, 0, (1 << 63) - 1),                # denormals
            Ext(0, 0, J_BIT | 1),                                  # pseudo-denormal
            Ext(0, BIAS + 3, 0x4000000000000000),                  # unnormal
            Ext(0, BIAS, J_BIT), Ext(1, BIAS, J_BIT),              # +-1
            Ext(0, 0x7FFE, M64), Ext(1, 0x7FFE, M64),              # the largest
            Ext(0, 1, J_BIT)]


def rand_ext(rng):
    r = rng.random()
    if r < 0.08:
        return rng.choice(special_values())
    band = rng.choice([(BIAS - 70, BIAS + 70), (BIAS - 126 - 40, BIAS - 126 + 40),
                       (BIAS + 127 - 40, BIAS + 127 + 40), (BIAS - 1022 - 40, BIAS - 1022 + 40),
                       (BIAS + 1023 - 40, BIAS + 1023 + 40), (0, 80), (0x7FFE - 80, 0x7FFE)])
    e = rng.randint(*band)
    kind = rng.random()
    if kind < 0.3:
        m = J_BIT | (rng.getrandbits(8) << rng.randint(0, 55))
    elif kind < 0.4:
        m = M64 - (rng.getrandbits(4) << rng.randint(0, 40))
    else:
        m = J_BIT | rng.getrandbits(63)
    if e == 0 and rng.random() < 0.5:
        m &= (1 << 63) - 1
    return Ext(rng.getrandbits(1), e, m)


def rand_fpcr(rng, enables=0.15):
    en = 0
    if rng.random() < enables:
        en = rng.getrandbits(8) << 8
    return en | (rng.randint(0, 2) << 6) | (rng.randint(0, 3) << 4)


def rand_fpsr(rng):
    # A prior FPCC, quotient, EXC and AEXC: the instruction must clear
    # or keep each as the manual says.
    return (rng.getrandbits(4) << 24) | (rng.getrandbits(8) << 16) | \
        (rng.getrandbits(8) << 8) | (rng.getrandbits(5) << 3)


def gen(scale=1, seed=1, sw=DEFAULT):
    """Yield (group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg)."""
    rng = random.Random(seed)
    arith = [0x00, 0x01, 0x03, 0x04, 0x18, 0x1A, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23,
             0x24, 0x25, 0x26, 0x27, 0x28, 0x38, 0x3A]
    trans = [0x02, 0x06, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12,
             0x14, 0x15, 0x16, 0x19, 0x1C, 0x1D, 0x30 | RC]
    base = lambda: (rand_ext(rng), rand_ext(rng), rand_ext(rng))

    # Register-to-register arithmetic, every PREC and RND, some traps enabled.
    for _ in range(3000 * scale):
        op = rng.choice(arith)
        rx, ry, rc = base()
        same = rng.random() < 0.05
        cmd = ((RY if same else RX) << 10) | (RY << 7) | op
        yield ('rounding', 'G', cmd, rand_fpcr(rng), rand_fpsr(rng), rx, ry, rc, 0, 0)

    # <ea> to register from every format.
    fmts = [(F.FMT_B, 8), (F.FMT_W, 16), (F.FMT_L, 32), (F.FMT_S, 32), (F.FMT_D, 64),
            (F.FMT_X, 96)]
    for _ in range(1500 * scale):
        fmt, bits = rng.choice(fmts)
        op = rng.choice(arith[:17])
        operand = rng.getrandbits(bits)
        if fmt == F.FMT_X:
            operand = rand_ext(rng).bits96() | (rng.getrandbits(16) << 64)   # unused bits: don't care
        cmd = 0x4000 | (fmt << 10) | (RY << 7) | op
        rx, ry, rc = base()
        yield ('convert', 'G', cmd, rand_fpcr(rng), rand_fpsr(rng), rx, ry, rc, operand, 0)

    # Register to memory in every format; packed with static and dynamic k.
    for _ in range(1500 * scale):
        fmt = rng.choice([F.FMT_B, F.FMT_W, F.FMT_L, F.FMT_S, F.FMT_D, F.FMT_X, F.FMT_P, F.FMT_PK])
        k = rng.choice([17, rng.randint(-64, 63), rng.randint(1, 17), rng.randint(-20, 0)])
        ext = (k & 0x7F) if fmt == F.FMT_P else ((3 << 4) if fmt == F.FMT_PK else 0)
        cmd = 0x6000 | (fmt << 10) | (RY << 7) | ext
        rx, ry, rc = base()
        yield ('convert', 'G', cmd, rand_fpcr(rng), rand_fpsr(rng), rx, ry, rc, 0, k & 0xFFFFFFFF)

    # Packed in: decimal strings, specials, non-decimal digits.
    for _ in range(800 * scale):
        v = 0
        r = rng.random()
        if r < 0.1:
            v = (rng.getrandbits(1) << 95) | (0x7FFF << 80) | rng.choice([0, rng.getrandbits(64)])
        elif r < 0.2:
            v = (rng.getrandbits(2) << 94) | (rng.getrandbits(12) << 80)      # a zero
        else:
            digits = [rng.randint(0, 9 if rng.random() < 0.95 else 15) for _ in range(17)]
            v = (rng.getrandbits(2) << 94)
            for i, d in enumerate([rng.randint(0, 9) for _ in range(3)]):
                v |= d << (88 - 4 * i)
            v |= digits[0] << 64
            for i, d in enumerate(digits[1:]):
                v |= d << (60 - 4 * i)
        op = rng.choice([0x00, 0x00, 0x22, 0x23])
        cmd = 0x4000 | (F.FMT_P << 10) | (RY << 7) | op
        rx, ry, rc = base()
        yield ('packed', 'G', cmd, rand_fpcr(rng), rand_fpsr(rng), rx, ry, rc, v, 0)

    # FMOVECR: every offset, every PREC and RND.
    for off in range(0x80):
        for prec in range(3):
            for rnd in range(4):
                cmd = 0x5C00 | (RY << 7) | off
                rx, ry, rc = base()
                yield ('fmovecr', 'G', cmd, (prec << 6) | (rnd << 4), rand_fpsr(rng), rx, ry, rc, 0, 0)

    # The transcendentals: bit-exact to the model (the microcode's oracle).
    for _ in range(3000 * scale):
        op = rng.choice(trans)
        rx, ry, rc = base()
        if rng.random() < 0.5:
            # a moderate argument, where the functions do their work
            rx = Ext(rng.getrandbits(1), BIAS + rng.randint(-40, 8), J_BIT | rng.getrandbits(63))
            if op in (0x0C, 0x1C, 0x0D):
                rx = Ext(rx.s, BIAS - rng.randint(1, 60), rx.m)
            if op in (0x14, 0x15, 0x16):
                rx = Ext(0, rx.e, rx.m)
        cmd = (RX << 10) | (RY << 7) | op
        yield ('transcend', 'G', cmd, rand_fpcr(rng, 0.05), rand_fpsr(rng), rx, ry, rc, 0, 0)

    # Every operation on every pair of special values, traps on and off.
    specials = special_values()
    for op in arith + trans:
        for a in specials:
            for b in (specials if op >= 0x20 and op < 0x30 or op == 0x38 else specials[:1]):
                for en in (0, 0xFF00):
                    cmd = (RX << 10) | (RY << 7) | op
                    yield ('special', 'G', cmd, en | (rng.randint(0, 3) << 4), rand_fpsr(rng),
                           a, b, rand_ext(rng), 0, 0)

    # Conditionals: all sixteen FPCC values, all 64 predicate codes, BSUN
    # enabled and not.
    for cc in range(16):
        for pred in range(64):
            for en in (0, F.BSUN):
                rx, ry, rc = base()
                yield ('cond', 'C', pred, en, (cc << 24) | rand_fpsr(rng) & 0x00FFFFFF,
                       rx, ry, rc, 0, 0)

    # Decode: opmodes $40-$7F, opclass 001, the redundant opmodes.
    for ext in list(range(0x40, 0x80)) + [0x05, 0x07, 0x0B, 0x13, 0x17, 0x1B, 0x29, 0x2F, 0x39,
                                           0x3B, 0x3C, 0x3F]:
        rx, ry, rc = base()
        yield ('decode', 'G', (RX << 10) | (RY << 7) | ext, 0, 0, rx, ry, rc, 0, 0)
    for _ in range(8):
        rx, ry, rc = base()
        yield ('decode', 'G', 0x2000 | rng.getrandbits(13), 0, 0, rx, ry, rc, 0, 0)


def write(path, scale=1, seed=1, sw=DEFAULT):
    n = 0
    skipped = 0
    with open(path, 'w', newline='\n') as out:
        out.write('# 68882 test vectors - tools/fpu_model/vectors.py, plan 8.7.4\n')
        out.write('# seed %d, scale %d; switches: %s\n' % (seed, scale, sw))
        out.write('# group kind cmd fpcr fpsr rx ry rc operand dreg | ry\' rc\' fpsr\' vector '
                  'when store xop\n')
        for group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg in gen(scale, seed, sw):
            try:
                o = execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, sw)
            except Unmodelled:
                skipped += 1
                continue
            out.write(fields_of(group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, o) + '\n')
            n += 1
    return n, skipped


if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else 'fpu.vec'
    scale = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    n, skipped = write(path, scale, seed)
    print('%d vectors to %s (%d unmodelled skipped)' % (n, path, skipped))
