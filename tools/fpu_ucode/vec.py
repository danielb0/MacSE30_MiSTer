"""Run the model's test vectors (tools/fpu_model/out/fpu.vec, plan 8.7.4)
through the microcode on the architectural simulator: plan 8.8.19.

    python vec.py [ucode source...] [--vec FILE] [--only GROUP[:OPMODE]]
                  [--show N] [--trace]

The BIU's part of each instruction is here, as hardware logic: the decode
(F-line for opmodes $40-$7F, opclass 001, FMOVECR offsets $40-$7F), the
conditionals (predicate and BSUN), the CU's unpacking of the source, the
entry-table index; then the microcode runs to its END and the BIU takes the
pending exception.  Each vector's seven results are compared: FPn, FPc,
FPSR, vector, when, store, exceptional operand.  An instruction whose entry
is the `unimpl` label counts as not yet written, not as a failure.
"""

import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fields as FD                                           # noqa: E402
import asm                                                    # noqa: E402
import sim                                                    # noqa: E402
from sim import Chip, Word, SimError, Unimplemented           # noqa: E402

MODEL = os.path.join(HERE, '..', 'fpu_model')
sys.path.insert(0, MODEL)
from replay import parse                                      # noqa: E402

RX, RY, RC = 1, 2, 5
FMT_NAMES = FD.FMT.names


def x80(t):
    s, e, m = t
    return (s << 79) | (e << 64) | m


def load(sources):
    r = asm.assemble(sources)
    if r.errors:
        raise SystemExit('assembly errors:\n' + '\n'.join(r.errors))
    labels = {n: e[1].addr for n, e in r.prog.labels.items()}
    return r, labels


def execute(chip, v):
    """One vector on the chip: (ry', rc', fpsr', vector, when, store, xop,
    clocks) or raises Unimplemented."""
    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, _ = v
    chip.fp = [(0, 0x7FFF, (1 << 64) - 1)] * 8
    chip.fp[RX], chip.fp[RY], chip.fp[RC] = tuple(rx), tuple(ry), tuple(rc)
    chip.fpcr, chip.fpsr = fpcr, fpsr
    none = (chip.fp[RY], chip.fp[RC])
    if kind == 'C':
        pred = cmd & 0x1F
        cc = (fpsr >> 24) & 0xF
        if pred & 0x10 and cc & 1:
            chip.fpsr |= sim.BSUN | sim.A_IOP
            if fpcr & sim.BSUN:
                return none + (chip.fpsr, sim.V_BSUN, 1, 0, 0, 0)
        return none + (chip.fpsr, 0, 0, int(sim.predicate(pred, cc)), 0, 0)
    opclass = cmd >> 13
    rxf = (cmd >> 10) & 7
    ext = cmd & 0x7F
    fline = none + (chip.fpsr, sim.V_FLINE, 1, 0, 0, 0)
    if opclass == 1 or (opclass in (0, 2) and ext >= 0x40 and not (opclass == 2 and rxf == 7)):
        return fline
    if opclass == 0:
        idx = FD.entry_general('reg', ext)
        src = sim.fp_word(chip.fp[rxf])
        chip.start(cmd, src, src)
    elif opclass == 2 and rxf == 7:
        if ext >= 0x40:
            return fline                        # 8.6.14 item 7: WinUAE's F-line
        idx = FD.ENTRY_FMOVECR
        chip.start(cmd, sim.ZERO_W, sim.ZERO_W)
    elif opclass == 2:
        f = FMT_NAMES[rxf]
        idx = FD.entry_general(f, ext)
        if f == 'S':
            w = sim.unpack_ieee(operand & 0xFFFFFFFF, 8, 23)
        elif f == 'D':
            w = sim.unpack_ieee(operand & ((1 << 64) - 1), 11, 52)
        elif f == 'X':
            w = sim.unpack_x(operand)
        elif f in ('B', 'W', 'L'):
            w = sim.opint(operand, f)
        else:
            w = sim.ZERO_W                      # packed: the APU decodes OPRAW
        tw = w if f not in ('B', 'W', 'L') else Word(w.s, 0x3FFF, (1 << 66) if w.m else 0)
        chip.start(cmd, w, tw, operand=operand)
    elif opclass == 3:
        idx = FD.entry_store(FMT_NAMES[rxf])
        src = sim.fp_word(chip.fp[(cmd >> 7) & 7])
        chip.start(cmd, src, src, dreg=dreg)
    else:
        raise Unimplemented('opclass %d' % opclass)
    clocks = chip.run(idx)
    vec = sim.trap_vector(chip.fpsr, chip.fpcr)
    when = 0 if not vec else (2 if opclass == 3 else 1)
    xop = x80(chip.EXOP) if vec in (sim.V_SNAN, sim.V_OPERR, sim.V_DZ, sim.V_OVFL, sim.V_UNFL) else 0
    store = chip.OBUF if opclass == 3 else 0
    return (chip.fp[RY], chip.fp[RC], chip.fpsr, vec, when, store, xop, clocks)


FIELDS = ['ry', 'rc', 'fpsr', 'vector', 'when', 'store', 'xop']


def compare(v, got):
    exp = v[-1]
    want = (tuple(exp[0]), tuple(exp[1]), exp[2], exp[3], exp[4], exp[5],
            x80(tuple(exp[6])) if exp[6] else 0)
    have = got[:7]
    return [(FIELDS[i], want[i], have[i]) for i in range(7) if want[i] != have[i]]


def opkey(v):
    group, kind, cmd = v[0], v[1], v[2]
    if kind == 'C':
        return group, 'cond'
    oc = cmd >> 13
    if oc == 3:
        return group, 'out.' + FMT_NAMES[(cmd >> 10) & 7]
    if oc == 2 and ((cmd >> 10) & 7) == 7:
        return group, 'fmovecr'
    src = 'reg' if oc == 0 else FMT_NAMES[(cmd >> 10) & 7]
    return group, '$%02X.%s' % (cmd & 0x7F, src)


def fmt_val(name, x):
    if name in ('ry', 'rc'):
        return '%X.%04X.%016X' % x
    return '%X' % x


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('sources', nargs='*', default=[os.path.join(HERE, 'ucode', 'fpu.uc')])
    ap.add_argument('--vec', default=os.path.join(MODEL, 'out', 'fpu.vec'))
    ap.add_argument('--only', default=None, help='group, or group:key (e.g. rounding:$22.reg)')
    ap.add_argument('--show', type=int, default=3)
    ap.add_argument('--trace', action='store_true')
    a = ap.parse_args(argv)
    r, labels = load(a.sources)
    chip = Chip(r.urom, r.nrom, r.entry, r.krom, unimpl=labels.get('unimpl'))
    stats = defaultdict(Counter)
    shown = Counter()
    for line in open(a.vec):
        if line.startswith('#') or not line.strip():
            continue
        v = parse(line)
        g, k = opkey(v)
        if a.only and a.only not in (g, '%s:%s' % (g, k)):
            continue
        if a.trace:
            chip.trace = []
        try:
            got = execute(chip, v)
        except Unimplemented:
            stats[(g, k)]['unimpl'] += 1
            continue
        except SimError as e:
            stats[(g, k)]['simerr'] += 1
            if shown[(g, k)] < a.show:
                shown[(g, k)] += 1
                print('SIMERR %s %s: %s\n  %s' % (g, k, e, line.strip()))
                if chip.trace:
                    print('\n'.join('    ' + t for t in chip.trace[-40:]))
            continue
        diff = compare(v, got)
        if diff:
            stats[(g, k)]['fail'] += 1
            if shown[(g, k)] < a.show:
                shown[(g, k)] += 1
                print('FAIL %s %s: %s' % (g, k, line.strip()))
                for name, w, h in diff:
                    print('    %-6s want %s  got %s' % (name, fmt_val(name, w), fmt_val(name, h)))
                if chip.trace:
                    print('\n'.join('    ' + t for t in chip.trace[-60:]))
        else:
            stats[(g, k)]['pass'] += 1
    tot = Counter()
    print('\n%-28s %7s %7s %7s %7s' % ('group:instruction', 'pass', 'fail', 'simerr', 'unimpl'))
    for key in sorted(stats):
        c = stats[key]
        tot.update(c)
        if c['fail'] or c['simerr'] or c['pass']:
            print('%-28s %7d %7d %7d %7d' % ('%s:%s' % key, c['pass'], c['fail'], c['simerr'], c['unimpl']))
    print('%-28s %7d %7d %7d %7d' % ('TOTAL', tot['pass'], tot['fail'], tot['simerr'], tot['unimpl']))
    return 1 if tot['fail'] or tot['simerr'] else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
