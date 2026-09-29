"""The 68882 microcode disassembler (plan 8.8.18): the ROM images back to
the assembler's source syntax.

The listing uses `format_word`; `disassemble` writes a whole program that
reassembles to the same microwords and nanowords field for field - the
assembler's round-trip test (test_asm.py) - and is what the architectural
simulator (6c) prints when it traces.
"""

import sys

import fields as FD
import consts

KADDR = {}
for _n, _a in consts.NAMES.items():
    KADDR.setdefault(_a, _n)

AMOUNT_TEXT = {'SC': 'SC', 'LC': 'LC', 'LZC': 'LZC', 'LCPSC': 'LC+SC', 'LCMSC': 'LC-SC'}
FP_TEXT = {'SRC': 'src', 'DST': 'dst', 'C': 'c', 'RA': 'ra'}
ENUM_OUT = [('bx', 'bx'), ('alu', 'alu'), ('emode', 'mode'), ('dir', 'dir'), ('osh', 'osh'), ('qop', 'q'),
            ('sgn', 'sign'), ('stk', 'stk'), ('rnd', 'rnd'), ('fpsr', 'fpsr'), ('ctl', 'ctl')]


def _k(addr, lc):
    name = KADDR.get(addr)
    base = name if name is not None else '$%02X' % addr
    return 'K[%s+LC]' % base if lc else 'K[%s]' % base


def clauses(m, n):
    """The source clauses of one microword m and its nanoword n (both as
    fields.names() dictionaries)."""
    out = []
    fp_used = False
    lit_used = False
    fp = 'FP[%s]' % FP_TEXT[n['fpsel']]
    if n['dst'] != 'NONE':
        if n['dst'] == 'T':
            out.append('d=T%d' % m['rd'])
        elif n['dst'] == 'FP':
            out.append('d=' + fp); fp_used = True
        else:
            out.append('d=' + n['dst'])
    a = n['asrc']
    if a == 'T':
        out.append('a=T%d' % m['ra'])
    elif a == 'FP':
        out.append('a=' + fp); fp_used = True
    elif a == 'CU':
        out.append('a=CU')
    b = n['bsrc']
    if b != 'ZERO' or n['shk'] != 'NONE':
        if b == 'T':
            bt = 'T%d' % m['rb']
        elif b in ('K', 'KLC'):
            bt = _k(m['rb'], b == 'KLC')
        elif b == 'FP':
            bt = fp; fp_used = True
        elif b == 'ZERO':
            bt = '0'
        else:
            bt = b
        if n['shk'] != 'NONE':
            op = {'LSL': '<<', 'LSR': '>>', 'ASR': '>>>'}[n['shk']]
            if n['sha'] == 'LIT':
                amt = str(n['lit']); lit_used = True
            else:
                amt = AMOUNT_TEXT[n['sha']]
            bt += op + amt
        out.append('b=' + bt)
    for f, name in ENUM_OUT:
        if FD.NANO.fields[f].enum.code[n[f]] != 0:
            out.append('%s=%s' % (name, n[f].lower()))
    if n['cin']:
        out.append('cin=1')
    if n['dl']:
        out.append('dl=1')
    if n['a2']:
        out.append('a2=1')
    if n['lcop'] != 'HOLD':
        if n['lcop'] == 'LIT':
            out.append('lc=%d' % n['lit']); lit_used = True
        else:
            out.append('lc=' + n['lcop'].lower())
    if n['fpsr'] == 'ORLIT' and n['lit']:
        names = [k for k, v in sorted(FD.EXC_BITS.items(), key=lambda kv: -kv[1]) if n['lit'] >> v & 1]
        out.append('exc=' + ','.join(names)); lit_used = True
    if n['lit'] and not lit_used:
        out.append('lit=%d' % n['lit'])
    if n['fpsel'] != 'SRC' and not fp_used:
        out.append('fp=' + FP_TEXT[n['fpsel']])
    return out


def seq_text(m, label=None):
    s = m['seq']
    t = label(m['target']) if label else '$%03X' % m['target']
    if s == 'NEXT':
        return ''
    if s == 'JUMP':
        return 'goto ' + t
    if s == 'CALL':
        return 'call ' + t
    if s == 'RET':
        return 'ret'
    if s in ('BRT', 'BRF'):
        return '%s %s goto %s' % ('if' if s == 'BRT' else 'unless', FD.COND.name(m['cond']), t)
    if s == 'DISP':
        return 'dispatch %s %s' % (FD.DISPATCH.name(m['cond']), t)
    mode = FD.WAITMODE.name(m['cond'])
    if mode == 'UNTIL':
        return 'waitb %d' % m['target']
    return '%s %d' % ('wait' if mode == 'HOLD' else 'budget', m['target'])


def format_word(uword, nrom, label=None):
    m = FD.MICRO.names(uword)
    n = FD.NANO.names(nrom[m['nano']])
    body = ' '.join(clauses(m, n)) or 'alu=nop'
    sq = seq_text(m, label)
    return body + (' | ' + sq if sq else '')


def disassemble(urom, nrom, entry, used):
    """A complete source for the words at the addresses in `used` (the µROM
    image cannot say which zero words are real), with the entry table."""
    targets = set()
    for a in used:
        m = FD.MICRO.names(urom[a])
        if m['seq'] in ('JUMP', 'CALL', 'BRT', 'BRF', 'DISP'):
            targets.add(m['target'])
    targets |= set(entry)
    label = lambda t: 'L%03X' % t
    lines, pc = [], None
    for a in sorted(used):
        if a != pc:
            lines.append('.org $%03X' % a)
        if a in targets:
            lines.append('%s:' % label(a))
        lines.append('    ' + format_word(urom[a], nrom, label))
        pc = a + 1
    lines.append('.entry default %s' % label(entry[0x3FF]))
    for idx, e in enumerate(entry):
        if e == entry[0x3FF]:
            continue
        if idx < 0x200:
            k, op = idx >> 6, idx & 0x3F
            kind = 'reg' if k == 0 else FD.FMT.name(k - 1)
            lines.append('.entry %s $%02X %s' % (kind, op, label(e)))
        elif idx == FD.ENTRY_FMOVECR:
            lines.append('.entry cr %s' % label(e))
        elif 0x208 <= idx < 0x210:
            lines.append('.entry out.%s %s' % (FD.FMT.name(idx - 0x208), label(e)))
        else:
            raise ValueError('entry $%03X is not expressible and differs from the default' % idx)
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    import os
    stem = sys.argv[1] if len(sys.argv) > 1 else os.path.join('out', 'ucode')
    rd = lambda ext: [int(x, 16) for x in open(stem + ext).read().split()]
    urom, nrom, entry = rd('.urom.hex'), rd('.nrom.hex'), rd('.entry.hex')
    used = [a for a, w in enumerate(urom) if w]
    sys.stdout.write(disassemble(urom, nrom, entry, used))
