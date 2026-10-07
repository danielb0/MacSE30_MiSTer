"""Convert se30dump.py's records (WinUAE cputest rounds) into the 68882
vector format of tools/fpu_model/vectors.py - plan 8.9.8, 7e-4, harness A.

    python3 convert.py <se30_GROUP.txt>... -o <out.vec> [-m <out.mvec>]

Each round becomes one vector on the bench's fixed registers (source FP1,
destination FP2, FSINCOS's cosine FP5): the instruction's FP register
fields are rewritten to those and their values taken from the round's
state before it ran; FPCR and FPSR from it too; the operand from what the
round read (memory), its instruction words (immediate) or its Dn.  The
expected half is WinUAE's: FPn after, FPSR after, the exception the round
took.  WinUAE records no exceptional operand, so xop is 0 and is not to be
compared (check.py).  Identical vectors (rounds differing only in the 030's
condition codes or trace bits) are written once.

FMOVEM and the control-register moves need all eight registers: they go to
-m in their own form (check_m.py).  What is left out, and counted: FSAVE and
FRESTORE, F-lines the 030 decides (an effective address the instruction may
not use), FSINCOS whose sine and cosine registers are the same, FMOVE of
two control registers from an immediate (the generator writes one longword:
the 030 takes the next instruction's as the second), and anything whose
round ended in an exception other than the end marker's, a trace, the
F-line, BSUN, the conditional trap or the FPU's own (48-54).

WinUAE's model, not silicon (plan 8.6.15): a mismatch is a question for the
manual or hardware, not a verdict.
"""
import argparse
import sys
from collections import Counter

RX, RY, RC = 1, 2, 5
FMT = {0: 'L', 1: 'S', 2: 'X', 3: 'P', 4: 'W', 5: 'D', 6: 'B', 7: 'P'}
SIZE = {'L': 4, 'S': 4, 'X': 12, 'P': 12, 'W': 2, 'D': 8, 'B': 1}
NSTATE = 29


def state(tok):
    """16 regs, SR, PC, FP0-7, FPCR, FPSR, FPIAR."""
    v = [int(t, 16) for t in tok]
    return {'d': v[0:8], 'a': v[8:16], 'sr': v[16], 'pc': v[17], 'fp': v[18:26],
            'fpcr': v[26], 'fpsr': v[27], 'fpiar': v[28]}


def parse(line):
    t = line.split()
    rec = {'dir': t[0], 'op': t[1][3:]}
    i = t.index('pre')
    rec['pre'] = state(t[i + 1:i + 1 + NSTATE])
    j = t.index('mem')
    k = t.index('post')
    rec['mem'] = [(m[0], int(m[1:9], 16), int(m.split(':')[1]), int(m.split(':')[2], 16)) for m in t[j + 1:k]]
    rec['post'] = state(t[k + 1:k + 1 + NSTATE])
    a, b = t[k + 1 + NSTATE][4:].split(',')
    rec['exc'], rec['excx'] = int(a), int(b)
    if len(t) > k + 2 + NSTATE and t[k + 2 + NSTATE] == 'sp':           # the integer corpus's (se30dump.py)
        sp = t[k + 3 + NSTATE:k + 8 + NSTATE]
        rec['sp'] = [int(x, 16) for x in sp[:4]] + [int(sp[4])]
    w = rec['op']
    rec['words'] = [int(w[i:i + 4], 16) for i in range(0, len(w), 4)]
    return rec


def frame_pc(rec):
    """The PC of the round's last exception frame (format $0/$2: the
    longword written at SP+2)."""
    longs = [m for m in rec['mem'] if m[0] == 'w' and m[2] == 4]
    return longs[-1][3] if longs else None


def data_bytes(accesses, size):
    """The first accesses' values joined, exactly size bytes, else None."""
    v, n = 0, 0
    for _, _, s, val in accesses:
        if n == size:
            break
        v = (v << (8 * s)) | val
        n += s
    return v if n == size else None


def ext_words(fmt, mode, reg):
    """Extension words an EA takes (68020 brief formats only: cputest's
    default leaves the full format off)."""
    if mode in (0, 1, 2, 3, 4):
        return 0
    if mode in (5, 6):
        return 1
    if reg in (0, 2, 3):
        return 1
    if reg == 1:
        return 2
    if reg == 4:
        return {'B': 1, 'W': 1, 'L': 2, 'S': 2, 'D': 4, 'X': 6, 'P': 6}[fmt]
    return None


class Conv:
    def __init__(self):
        self.out = {}
        self.mout = {}
        self.n = Counter()

    def fmovem(self, group, rec):
        """FMOVEM and the control-register moves: one line in convert.py's
        M form (check_m.py) - all eight FPn, FPCR/FPSR/FPIAR before and after,
        the longwords moved in and out."""
        w, pre, post = rec['words'], rec['pre'], rec['post']
        op, cmd = w[0], w[1]
        mode, reg = (op >> 3) & 7, op & 7
        oc = cmd >> 13
        start = pre['pc']
        if rec['exc'] == 11 and frame_pc(rec) == start:
            return self.n.update(['skip fmovem fline by the 030 (ea)'])
        if oc in (4, 5):
            sel = (cmd >> 10) & 7
            nreg = bin(sel).count('1') or 1
            nlong = nreg
        else:
            dyn = (cmd >> 11) & 1
            lst = (pre['d'][(cmd >> 4) & 7] & 0xFF) if dyn else (cmd & 0xFF)
            nreg = bin(lst).count('1')
            nlong = 3 * nreg
        dreg = pre['d'][(cmd >> 4) & 7] if oc in (6, 7) else 0
        if mode == 7 and reg == 4:
            ne = 2 * nlong if oc == 4 else None
        else:
            ne = ext_words('L', mode, reg)
        if ne is None:
            return self.n.update(['skip fmovem ea'])
        end = start + 2 * (2 + ne)
        if w[2 + ne:4 + ne] != [0xF280, 0x0000]:
            return self.n.update(['skip fmovem no fnop after'])
        if not self.ended(rec, end + 4):
            return self.n.update(['skip fmovem exception %d' % rec['exc']])
        vin, vout = [], []
        if oc in (4, 6):
            if mode in (0, 1):
                if nlong != 1:
                    return self.n.update(['skip fmovem register list'])
                vin = [pre['d' if mode == 0 else 'a'][reg]]
            elif mode == 7 and reg == 4:
                vin = [(w[2 + 2 * i] << 16) | w[3 + 2 * i] for i in range(nlong)]
            else:
                rd = [m for m in rec['mem'] if m[0] == 'r']
                acc = []
                for m in rd:
                    if len(acc) == nlong:
                        break
                    if m[2] != 4:
                        return self.n.update(['skip fmovem read size'])
                    acc.append(m[3])
                if len(acc) != nlong:
                    return self.n.update(['skip fmovem reads'])
                vin = acc
        else:
            if mode in (0, 1):
                if nlong != 1:
                    return self.n.update(['skip fmovem register list'])
                vout = [post['d' if mode == 0 else 'a'][reg]]
            else:
                wr = [m for m in rec['mem'] if m[0] == 'w']
                acc = []
                for m in wr:
                    if len(acc) == nlong:
                        break
                    if m[2] != 4:
                        return self.n.update(['skip fmovem write size'])
                    acc.append(m)
                if len(acc) != nlong:
                    return self.n.update(['skip fmovem writes'])
                vout = [m[3] for m in sorted(acc, key=lambda m: m[1])]   # -(An) writes top down
        line = '%s M %04X %08X %d %s %08X %08X %08X | %s | %s %08X %08X %08X | %s' % (
            group, cmd, dreg, mode, ' '.join('%020X' % x for x in pre['fp']), pre['fpcr'], pre['fpsr'], pre['fpiar'],
            ' '.join('%08X' % x for x in vin) or '-',
            ' '.join('%020X' % x for x in post['fp']), post['fpcr'], post['fpsr'], post['fpiar'],
            ' '.join('%08X' % x for x in vout) or '-')
        if line in self.mout:
            self.n['duplicate'] += 1
        else:
            self.mout[line] = 1
            self.n['vector M'] += 1

    def emit(self, group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, ry2, rc2, fpsr2, vec, when, store):
        line = '%s %s %04X %08X %08X %020X %020X %020X %024X %08X %020X %020X %08X %02X %X %024X %020X' % (
            group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, ry2, rc2, fpsr2, vec, when, store, 0)
        if line in self.out:
            self.n['duplicate'] += 1
        else:
            self.out[line] = 1
            self.n['vector ' + kind] += 1

    def ended(self, rec, end):
        """The round finished the instruction normally: the end marker's
        illegal at or past end (the FNOP's), or a trace."""
        if rec['exc'] == 9:
            return True
        return rec['exc'] == 4 and frame_pc(rec) is not None and frame_pc(rec) >= end

    def general(self, group, rec):
        w, pre, post = rec['words'], rec['pre'], rec['post']
        op, cmd = w[0], w[1]
        mode, reg = (op >> 3) & 7, op & 7
        oc, rxf, ryf, ext = cmd >> 13, (cmd >> 10) & 7, (cmd >> 7) & 7, cmd & 0x7F
        if oc in (4, 5, 6, 7):
            return self.fmovem(group, rec)
        start = pre['pc']
        if oc == 1 or (oc in (0, 2) and ext >= 0x40 and not (oc == 2 and rxf == 7)) or \
                (oc == 2 and rxf == 7 and ext >= 0x40):
            # the FPU's own F-line (vec.py's decode)
            if rec['exc'] == 11 and frame_pc(rec) == start:
                return self.emit(group, 'G', cmd, pre['fpcr'], pre['fpsr'], 0, 0, 0, 0, 0, 0, 0,
                                 post['fpsr'], 11, 1, 0)
            return self.n.update(['skip fline expected, got %d' % rec['exc']])
        if rec['exc'] == 11 and frame_pc(rec) == start:
            return self.n.update(['skip fline by the 030 (ea)'])
        rx = ry = rc = operand = dreg = store = 0
        fs = 0x30 <= ext <= 0x37 and (oc == 0 or (oc == 2 and rxf != 7))
        c = cmd & 7
        if oc == 0:
            if mode or reg:
                return self.n.update(['skip opclass 0 with an ea'])
            src = rxf
            nlen = 2
            rx = pre['fp'][src]
            cmd2 = (cmd & ~(7 << 10) & ~(7 << 7)) | (RX << 10) | (RY << 7)
        elif oc == 2 and rxf == 7:
            if mode or reg:
                return self.n.update(['skip fmovecr with an ea'])
            nlen = 2
            cmd2 = (cmd & ~(7 << 7)) | (RY << 7)
        elif oc == 2:
            f = FMT[rxf]
            if rxf == 7:
                return self.n.update(['skip opclass 2 format 7'])
            ne = ext_words(f, mode, reg)
            if ne is None:
                return self.n.update(['skip ea'])
            nlen = 2 + ne
            if mode == 0:
                if f not in ('L', 'S', 'W', 'B'):
                    return self.n.update(['skip Dn with %s' % f])
                operand = pre['d'][reg] & ((1 << (8 * SIZE[f])) - 1)
            elif mode == 1:
                return self.n.update(['skip An source'])
            elif mode == 7 and reg == 4:
                v = 0
                for x in w[2:2 + ne]:
                    v = (v << 16) | x
                if f == 'B':
                    v &= 0xFF
                operand = v
            else:
                v = data_bytes([m for m in rec['mem'] if m[0] == 'r'], SIZE[f])
                if v is None:
                    return self.n.update(['skip operand reads'])
                operand = v
            cmd2 = (cmd & ~(7 << 7)) | (RY << 7)
        else:                                   # opclass 3: FPn to <ea>
            f = FMT[rxf]
            ne = ext_words(f, mode, reg)
            if ne is None or (mode == 7 and reg == 4):
                return self.n.update(['skip store ea'])
            nlen = 2 + ne
            if rxf == 7:
                dreg = pre['d'][(cmd >> 4) & 7]
            src = ryf
            cmd2 = (cmd & ~(7 << 7)) | (RY << 7)
            ry = pre['fp'][src]
        end = start + 2 * nlen
        if w[nlen:nlen + 2] != [0xF280, 0x0000]:
            return self.n.update(['skip no fnop after'])
        dst = ryf
        if oc in (0, 2):
            ry = pre['fp'][dst]
            if fs:
                if c == dst:
                    return self.n.update(['skip fsincos c = s'])
                rc = pre['fp'][c]
                cmd2 = (cmd2 & ~7) | RC
        vec = when = 0
        if self.ended(rec, end + 4):
            pass
        elif 48 <= rec['exc'] <= 54 and frame_pc(rec) is not None:
            vec, when = rec['exc'], (2 if oc == 3 else 1)
        else:
            return self.n.update(['skip exception %d' % rec['exc']])
        if oc == 3:
            f = FMT[rxf]
            if vec and when == 2:
                store = 0
            elif mode == 0:
                if f not in ('L', 'S', 'W', 'B'):
                    return self.n.update(['skip store Dn with %s' % f])
                store = post['d'][reg] & ((1 << (8 * SIZE[f])) - 1)
            else:
                v = data_bytes([m for m in rec['mem'] if m[0] == 'w'], SIZE[f])
                if v is None:
                    return self.n.update(['skip store writes'])
                store = v
            ry2 = post['fp'][ryf]
            rc2 = 0
        else:
            ry2 = post['fp'][dst]
            rc2 = post['fp'][c] if fs else 0
        self.emit(group, 'G', cmd2, pre['fpcr'], pre['fpsr'], rx, ry, rc, operand, dreg,
                  ry2, rc2, post['fpsr'], vec, when, store)

    def conditional(self, group, rec):
        w, pre, post = rec['words'], rec['pre'], rec['post']
        op = w[0]
        start = pre['pc']
        if (op & 0xFF80) == 0xF280:             # FBcc
            what = 'FBcc'
            pred = op & 0x3F
            if op & 0x40:
                disp = ((w[1] << 16) | w[2]) - ((1 << 32) if w[1] & 0x8000 else 0)
                nlen = 3
            else:
                disp = w[1] - (0x10000 if w[1] & 0x8000 else 0)
                nlen = 2
            target = (start + 2 + disp) & 0xFFFFFFFF
            if op == 0xF280 and w[1] == 0 and len(w) >= 2:
                return self.n.update(['skip fnop'])
        elif (op & 0xFFF8) == 0xF248:           # FDBcc
            what = 'FDBcc'
            pred, nlen = w[1] & 0x3F, 3
        elif (op & 0xFFF8) == 0xF278 and (op & 7) in (2, 3, 4):   # FTRAPcc
            what = 'FTRAPcc'
            pred, nlen = w[1] & 0x3F, {2: 3, 3: 4, 4: 2}[op & 7]
        elif (op & 0xFFC0) == 0xF240:           # FScc (F278-F279: absolute addresses)
            what = 'FScc'
            mode, reg = (op >> 3) & 7, op & 7
            ne = ext_words('B', mode, reg)
            if ne is None or mode == 1 or (mode == 7 and reg == 4):
                return self.n.update(['skip fscc ea'])
            pred, nlen = w[1] & 0x3F, 2 + ne
        else:
            return self.n.update(['skip unknown %04X' % op])
        fpcr, fpsr = pre['fpcr'], pre['fpsr']
        if rec['exc'] == 11 and frame_pc(rec) == start:
            return self.emit(group, 'C', pred, fpcr, fpsr, 0, 0, 0, 0, 0, 0, 0, post['fpsr'], 11, 1, 0)
        if rec['exc'] == 48:
            return self.emit(group, 'C', pred, fpcr, fpsr, 0, 0, 0, 0, 0, 0, 0, post['fpsr'], 48, 1, 0)
        if what == 'FBcc':
            fpc = frame_pc(rec)            # the end marker's or a trace's: the next PC
            if not (rec['exc'] in (4, 9) and fpc is not None):
                return self.n.update(['skip fbcc exception %d' % rec['exc']])
            if target in (start + 2 * nlen, start + 2 * nlen + 2):
                return self.n.update(['skip fbcc target = fall-through'])
            if fpc in (target, target + 2):
                cond = 1
            elif fpc >= start + 2 * nlen:
                cond = 0
            else:
                return self.n.update(['skip fbcc pc'])
        elif what == 'FTRAPcc':
            if rec['exc'] == 7:
                cond = 1
            elif self.ended(rec, start + 2 * nlen):
                cond = 0
            else:
                return self.n.update(['skip ftrapcc exception %d' % rec['exc']])
        elif what == 'FDBcc':
            if rec['exc'] not in (4, 9):
                return self.n.update(['skip fdbcc exception %d' % rec['exc']])
            r = op & 7
            cond = int((post['d'][r] & 0xFFFF) == (pre['d'][r] & 0xFFFF))
        else:
            if not self.ended(rec, start + 2 * nlen):
                return self.n.update(['skip fscc exception %d' % rec['exc']])
            mode, reg = (op >> 3) & 7, op & 7
            if mode == 0:
                b = post['d'][reg] & 0xFF
            else:
                b = data_bytes([m for m in rec['mem'] if m[0] == 'w'], 1)
                if b is None:
                    return self.n.update(['skip fscc write'])
            if b not in (0, 0xFF):
                return self.n.update(['skip fscc value'])
            cond = int(b == 0xFF)
        self.emit(group, 'C', pred, fpcr, fpsr, 0, 0, 0, 0, 0, 0, 0, post['fpsr'], 0, 0, cond)

    def record(self, line):
        rec = parse(line)
        group = 'w' + rec['dir'].split('/')[1].split('_', 1)[1]
        op = rec['words'][0]
        self.n['rounds'] += 1
        if (op & 0xFFC0) == 0xF200:
            self.general(group, rec)
        elif (op & 0xFF80) == 0xF280 or (op & 0xFFC0) == 0xF240:
            self.conditional(group, rec)
        elif (op & 0xFF80) == 0xF300 or (op & 0xFFC0) == 0xF340:
            self.n['skip fsave/frestore'] += 1
        else:
            self.n['skip opword %04X' % (op & 0xFFC0)] += 1


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('records', nargs='+')
    ap.add_argument('-o', required=True)
    ap.add_argument('-m', default=None, help='FMOVEM and control-register moves, M form')
    a = ap.parse_args(argv)
    cv = Conv()
    for p in a.records:
        for line in open(p):
            cv.record(line)
    with open(a.o, 'w', newline='\n') as f:
        f.write('# 68882 vectors from WinUAE cputest (tools/cputest/convert.py, plan 8.9.8): %s\n'
                % ' '.join(p.split('/')[-1] for p in a.records))
        f.write('# group kind cmd fpcr fpsr rx ry rc operand dreg | ry\' rc\' fpsr\' vector when store xop(0: not recorded)\n')
        for line in cv.out:
            f.write(line + '\n')
    if a.m:
        with open(a.m, 'w', newline='\n') as f:
            f.write('# FMOVEM/FMOVE-control from WinUAE cputest (convert.py): group M cmd dreg eamode FP0-7 FPCR FPSR FPIAR'
                    ' | in | FP0-7 FPCR FPSR FPIAR after | out\n')
            for line in cv.mout:
                f.write(line + '\n')
    for k, v in sorted(cv.n.items()):
        print('%-40s %9d' % (k, v))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
