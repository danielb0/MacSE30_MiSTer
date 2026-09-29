"""The assembler's checks (plan 8.8.18).

  - the formats: widths, every enum fits its field, pack/unpack inverse;
  - the constant ROM against the model, bit for bit: the FMOVECR rows as
    rom64 and item 7's table, every table word shifted into place against
    transcend.rom_fixed for each i < 34 and scale s <= i;
  - the sample program assembles clean, and its disassembly reassembles to
    the same microwords, nanowords and entry table, field for field;
  - the entry table: the redundant opmodes as the model decodes them;
  - every check fails on a source made to break it (one each).

Prints one line per check and a PASS/FAIL total; exits 1 on a failure.
"""

import os
import sys
import tempfile
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fields as FD                                           # noqa: E402
import consts                                                 # noqa: E402
import asm                                                    # noqa: E402
import disasm                                                 # noqa: E402
import transcend as T                                         # noqa: E402
import constants                                              # noqa: E402
import fpu                                                    # noqa: E402

results = []


def check(name, ok, detail=''):
    results.append(ok)
    print('%s  %s%s' % ('PASS' if ok else 'FAIL', name, ('  -- ' + detail) if detail and not ok else ''))


def assemble_text(src):
    fd, path = tempfile.mkstemp(suffix='.uc')
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(textwrap.dedent(src))
    try:
        return asm.assemble([path])
    finally:
        os.remove(path)


def expect_error(name, src, words):
    """The source must fail - an AsmError or a reported error - with every
    one of `words` in the message."""
    try:
        r = assemble_text(src)
        msg = '\n'.join(r.errors)
    except asm.AsmError as e:
        msg = str(e)
    ok = bool(msg) and all(w in msg for w in words)
    check('rejects: ' + name, ok, msg or 'assembled without error')


# -- the formats ------------------------------------------------------------------------

check('microword is 48 bits', FD.MICRO.width == 48)
check('nanoword fits 72 bits (%d)' % FD.NANO.width, FD.NANO.width <= 72)
fits = all(f.enum is None or len(f.enum.names) <= 1 << f.width
           for fmt in (FD.MICRO, FD.NANO) for f in fmt.fields.values())
check('every enum fits its field', fits)
check('COND fits the 6-bit cond field', len(FD.COND.names) <= 64)
zero_is_nothing = all(f.enum is None or f.enum.names[0] in ('NONE', 'NOP', 'ZERO', 'HOLD', 'NEXT', 'MANT',
                                                            'SRC', 'LIT', 'PREVN', 'A')
                      for f in FD.NANO.fields.values())
check('code 0 of every nanoword field is its default', zero_is_nothing)
import random
rng = random.Random(1)
inv = True
for fmt in (FD.MICRO, FD.NANO):
    for _ in range(200):
        vals = {n: rng.randrange(1 << f.width) for n, f in fmt.fields.items()}
        inv &= fmt.unpack(fmt.pack(vals)) == vals
check('pack/unpack are inverse', inv)
dispatch_ok = (4 * 5 + 4) < (1 << FD.DISPATCH_BITS['TAGPAIR']) and set(FD.DISPATCH_BITS) == set(FD.DISPATCH.names)
check('TAGPAIR codes fit its 32-entry table', dispatch_ok)

# -- the constant ROM against the model -----------------------------------------------------

bad = []
for off in range(0x40):
    s, e, m, d = FD.kword_fields(consts.ROM[consts.FMOVECR_BASE + off])
    if off in constants.WINUAE_DOCUMENTED:
        (be, m64), inexact, adj = constants.WINUAE_DOCUMENTED[off]
        want_d = {(0, 0, 0, 1): 1, (0, -1, -1, 0): 2}.get(tuple(adj), 0) if inexact else 0
        if (s, e, m, d) != (0, be, m64 << 3, want_d):
            bad.append(off)
    else:
        ws, we, wm = constants.WINUAE_UNDEFINED[off if off <= 10 else 0]
        if (s, e, m, d) != (ws, we, wm << 3, 0):
            bad.append(off)
check('FMOVECR rows: rom64 images and directions, item 7 table', not bad, 'offsets %s' % bad)

bad = 0
for base, tab in ((consts.ATAN_BASE, T._ATAN), (consts.LNUP_BASE, T._LNUP), (consts.LNDN_BASE, T._LNDN)):
    for i in range(consts.TABLE_WORDS):
        w = consts.ROM[base + i] & ((1 << FD.MANT_BITS) - 1)
        if w >> (FD.MANT_BITS - 1):
            w -= 1 << FD.MANT_BITS
        for s in range(i + 1):
            bad += (w >> (i - s)) != T.rom_fixed(tab, i, s)
check('atan/ln tables: every word placed by i - s equals rom_fixed', bad == 0, '%d mismatches' % bad)
gains = all(FD.kword_fields(consts.ROM[consts.GAIN_BASE + i])[2] == T.gain(i) for i in range(34))
check('CORDIC gains equal transcend.gain', gains)
named = {'pi': T.PI, 'twopi': T.TWOPI, 'ln2': T.LN2, 'log10_e': T.LOG10_E, 'inv_ln2': T.INV_LN2}
ok = True
for n, x in named.items():
    s, e, m, _ = FD.kword_fields(consts.ROM[consts.NAMES[n]])
    ok &= (s, m, e) == (x.s, x.m, x.e + 66 + FD.BIAS)
check('named I67 constants equal the model\'s', ok)

# -- the sample: clean, and the round trip ---------------------------------------------------

r = asm.assemble([os.path.join(HERE, 'tests', 'sample.uc')])
check('sample assembles with no errors', not r.errors, '; '.join(r.errors))
check('sample assembles with no warnings', not r.warnings, '; '.join(r.warnings))
used = [a for a, u in enumerate(r.rom) if u is not None]
src = disasm.disassemble(r.urom, r.nrom, r.entry, used)
r2 = assemble_text(src)
same = True
for a in range(FD.UROM_WORDS):
    m1, m2 = FD.MICRO.unpack(r.urom[a]), FD.MICRO.unpack(r2.urom[a])
    n1, n2 = r.nrom[m1.pop('nano')], r2.nrom[m2.pop('nano')]
    same &= m1 == m2 and n1 == n2
check('disassembly reassembles to the same words', same)
check('disassembly reassembles to the same entry table', r.entry == r2.entry)
check('nanowords are shared (%d for %d words)' % (r.nnano, len(used)), r.nnano < len(used))

# -- the entry table ----------------------------------------------------------------------------

red = all(r.entry[FD.entry_general(k, red)] == r.entry[FD.entry_general(k, base)]
          for k in asm.ENTRY_KINDS for red, base in fpu.FPU.REDUNDANT.items())
check('redundant opmodes enter as the model decodes them (8.6.14 item 6)', red)
check('FMOVECR and store entries', r.entry[FD.ENTRY_FMOVECR] == r.prog.labels['fmovecr'][1].addr
      and r.entry[FD.entry_store('X')] == r.prog.labels['fmove_out'][1].addr)

# -- each check, broken on purpose --------------------------------------------------------------

HEAD = """
    .export idle
    idle: alu=nop | goto idle
    .entry default idle
"""
expect_error('an undefined label', HEAD + "x: alu=nop | goto nowhere\n.export x\n", ['nowhere', 'not defined'])
expect_error('a temporary past T31', HEAD + "d=T32 a=0 alu=passa\n", ['T32'])
expect_error('a destination without an operation', HEAD + "d=T1 a=T0\n", ['destination needs'])
expect_error('q= with a Q-shifting output shift', HEAD + "d=T1 a=T1 b=T2 alu=add osh=l1q q=clear\n", ['Q-shifting'])
expect_error('the output shifter in exponent mode', HEAD + "d=T1 a=T1 alu=passa mode=exp osh=r1\n", ['exponent mode'])
expect_error('RINC without a round mode', HEAD + "d=T1 a=T1 b=RINC alu=add\n", ['rnd='])
expect_error('two literals in one word', HEAD + "d=T1 b=T0<<3 alu=passb lc=5\n", ['lit'])
expect_error('two FP registers in one word', HEAD + "d=FP[dst] b=FP[src] alu=passb\n", ['fpsel'])
expect_error('an unknown constant', HEAD + "d=T1 b=K[tau] alu=passb\n", ['tau'])
expect_error('wait 0', HEAD + "alu=nop | wait 0\n", ['wait'])
expect_error('an unknown condition', HEAD + "x: alu=nop | if MAYBE goto x\n", ['MAYBE'])
expect_error('falling off the end', HEAD + "x: alu=nop\n.export x\n", ['no microinstruction'])
expect_error('a checkpoint with T11 live', HEAD + """
    x: d=T11 a=0 alu=passa
       ctl=checkpoint
       d=T0 a=T11 alu=passa | goto idle
    .export x
""", ['checkpoint', 'T11'])
expect_error('a checkpoint with Q live', HEAD + """
    x: q=clear
       ctl=checkpoint
       d=T0 b=Q alu=passb | goto idle
    .export x
""", ['checkpoint', 'Q'])
expect_error('a checkpoint inside a callee with the caller\'s T20 live', HEAD + """
    x: d=T20 a=0 alu=passa | call s
       d=T0 a=T20 alu=passa | goto idle
    s: ctl=checkpoint | ret
    .export x
""", ['checkpoint', 'T20'])
expect_error('recursion', HEAD + """
    x: alu=nop | call x
       goto idle
    .export x
""", ['recursion'])
expect_error('calls five deep', HEAD + """
    x:  alu=nop | call s1
        goto idle
    s1: alu=nop | call s2
        ret
    s2: alu=nop | call s3
        ret
    s3: alu=nop | call s4
        ret
    s4: alu=nop | call s5
        ret
    s5: ret
    .export x
""", ['5 deep'])
expect_error('dispatch into a table of another key', HEAD + """
    x: alu=nop | dispatch RND t
    .table t PREC
      * idle
    .end
    .export x
""", ['keyed by PREC'])
expect_error('dispatch to an unaligned label', HEAD + """
    x: alu=nop | dispatch RND y
    y: alu=nop | goto idle
    .export x
""", ['not aligned'])
expect_error('an incomplete table', HEAD + """
    x: alu=nop | dispatch RND t
    .table t RND
      RN idle
    .end
    .export x
""", ['no target'])
expect_error('an entry given twice', HEAD + ".entry reg $22 idle\n.entry reg $22 idle\n", ['already'])
expect_error('an opmode past $3F', HEAD + ".entry reg $40 idle\n", ['$40'])
expect_error('an entry table with holes and no default', """
    .export idle
    idle: alu=nop | goto idle
    .entry reg $22 idle
""", ['empty', 'default'])
expect_error('a label on nothing', HEAD + "dangling:\n", ['name nothing'])
expect_error('the µROM overflowing', HEAD + ".org $7FF\nalu=nop | goto idle\nalu=nop | goto idle\n", ['full'])

n_fail = results.count(False)
print('%d PASS, %d FAIL' % (results.count(True), n_fail))
sys.exit(1 if n_fail else 0)
