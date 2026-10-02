"""Harness B (plan 8.9.8, 7e-4): a sample of WinUAE cputest rounds run as
programs on the 68030 kernel and the 68882 under ModelSim (sim/cpfpu) - the
030's half of the corpus: effective addresses, the dialogs, FMOVEM's
transfer order, the operand lengths.

    python3 harness_b.py <se30_GROUP.txt>... -o <dir> [--per N] [--batch N] [--seed S]

Each batch is a tb_cpfpu program (prog_NN.hex, expect_NN.txt, list_NN.txt).
The bench's RAM is 128 KB and decodes the low 17 address bits, so a round
keeps its own registers and addresses: its memory accesses land at their
aliases, which must all fall in the free window; the program stores the
round's operand bytes there, loads FP0-FP7, FPCR/FPSR/FPIAR and D0-A7
(supervisor mode: A7 is the round's A7), runs the instruction and an FNOP,
and stores every register and the FPU's state for the checks.

A round is taken when it ended normally (the end marker after the FNOP),
not traced, uses no PC-relative address and no branch, every access
aliases into the window, and - for the FPU's own result - our reference
model agrees with WinUAE on it (check.py / check_m.py), so a failure here
is the 030's side or the bus protocol, not an arithmetic difference.
Sampled per (instruction, addressing mode), up to --per rounds each.
"""
import argparse
import os
import random
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))

import convert                                                # noqa: E402
from convert import parse, frame_pc, ext_words                # noqa: E402
from replay import parse as vparse                            # noqa: E402
from check import want_of, model_run                          # noqa: E402
import check_m                                                # noqa: E402

CODE0, CODE1 = 0x4000, 0xC000
RES0, RES1 = 0xC000, 0x14000
FREE0, FREE1 = 0x14000, 0x20000
MASK = 0x1FFFF


def L(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]


def model_agrees(cv, rec):
    """Convert the round as harness A does and run the model on it."""
    cv.out.clear()
    cv.mout.clear()
    group = 'w' + rec['dir'].split('/')[1].split('_', 1)[1]
    op = rec['words'][0]
    if (op & 0xFFC0) == 0xF200:
        cv.general(group, rec)
    elif (op & 0xFF80) == 0xF280 or (op & 0xFFC0) == 0xF240:
        cv.conditional(group, rec)
    else:
        return False
    for line in cv.out:
        v = vparse(line)
        if model_run(v) != want_of(v):
            return False
        return True
    for line in cv.mout:
        pre, vin, post, vout = line.split('|')
        t = pre.split()
        cmd, dreg, eamode = int(t[2], 16), int(t[3], 16), int(t[4])
        fp = [int(x, 16) for x in t[5:13]]
        fpcr, fpsr, fpiar = (int(x, 16) for x in t[13:16])
        vin = [] if vin.strip() == '-' else [int(x, 16) for x in vin.split()]
        q = post.split()
        want = ([int(x, 16) for x in q[0:8]], int(q[8], 16), int(q[9], 16), int(q[10], 16),
                [] if vout.strip() == '-' else [int(x, 16) for x in vout.split()])
        got = check_m.run(cmd, dreg, eamode, fp, fpcr, fpsr, fpiar, vin)
        return got[0] == want[0] and got[1:3] == want[1:3] and got[4] == want[4]
    return False


def instr_len(rec):
    """The instruction's words, without the FNOP after it, or None."""
    w = rec['words']
    for n in range(2, len(w) - 1):
        if w[n] == 0xF280 and w[n + 1] == 0 and n + 2 == len(w):
            return n
    return None


def suitable(rec):
    w = rec['words']
    op = w[0]
    n = instr_len(rec)
    if n is None:
        return None
    if rec['pre']['sr'] & 0xC000:
        return None                                   # traced
    if rec['exc'] != 4 or frame_pc(rec) is None or frame_pc(rec) < rec['pre']['pc'] + 2 * n + 4:
        return None
    if (op & 0xFF80) == 0xF280 or (op & 0xFFF8) == 0xF248:
        return None                                   # FBcc, FDBcc: branches
    if (op & 0xFFF8) == 0xF278 and (op & 7) in (2, 3, 4):
        return None                                   # FTRAPcc: kept out (traps leave the program)
    mode, reg = (op >> 3) & 7, op & 7
    if mode == 7 and reg in (2, 3):
        return None                                   # PC-relative
    if (op & 0xFFC0) == 0xF200 and (w[1] >> 13) in (4, 5) and not (w[1] >> 10) & 7:
        return None                                   # an empty control list: 8.6.14 item 20, open
    # the instruction's own accesses: everything before the end marker's frame
    acc = rec['mem'][:-3] if len(rec['mem']) >= 3 else []
    if acc and mode == 6 and (rec['words'][2] >> 15) and ((rec['words'][2] >> 12) & 7) == reg:
        return None                                   # indexed by its own base register
    if acc and not (2 <= mode <= 6 or (mode == 7 and reg in (0, 1))):
        return None
    if acc and max(a + s for _, a, s, _ in acc) - min(a for _, a, _, _ in acc) > 256:
        return None
    return n, mode, acc


def movei(addr, size, v):
    """move.<size> #v,(addr).l"""
    if size == 1:
        return [0x13FC, v & 0xFF] + L(addr)
    if size == 2:
        return [0x33FC, v & 0xFFFF] + L(addr)
    return [0x23FC] + L(v) + L(addr)


class Batch:
    def __init__(self):
        self.code = []                                # words from CODE0
        self.res = RES0
        self.expect = []
        self.list = []
        self.touched = set()                          # alias bytes earlier rounds read or wrote
        self.slot = FREE0                             # the next free relocation slot
        self.slotw = 0x0400                           # ... for (xxx).W: the free low RAM, positive
                                                      # (a sign-extended $8000+ is slot space: a bus error)

    def here(self):
        return CODE0 + 2 * len(self.code)

    def fits(self, nwords, nres):
        return self.here() + 2 * nwords + 64 < CODE1 and self.res + nres < RES1

    def conflicts(self, acc):
        return any((a & MASK) + j in self.touched for _, a, s, _ in acc for j in range(s))

    def relocate(self, rec, n, acc):
        """Move the round's accesses to a fresh slot: the base register
        shifted (pre and post) or the absolute address rewritten.  Returns
        (pre, post, instruction words, accesses) or None (no room)."""
        import copy
        pre, post = copy.deepcopy(rec['pre']), copy.deepcopy(rec['post'])
        iw = list(rec['words'][:n])
        if not acc:
            return pre, post, iw, acc
        op = iw[0]
        mode, reg = (op >> 3) & 7, op & 7
        lo = min(a for _, a, _, _ in acc)
        span = (max(a + s for _, a, s, _ in acc) - lo + 3) & ~3
        if mode == 7 and reg == 0:
            if self.slotw < 0x1000 <= self.slotw + span:
                self.slotw = 0x1010                   # past the reset jump at $1000
            if self.slotw + span > 0x2000:
                return None
            t = self.slotw
            self.slotw += span + 4
        else:
            if self.slot + span > FREE1:
                return None
            t = self.slot
            self.slot += span + 4
        ea = [x for x in acc]
        delta = (t - lo) & 0xFFFFFFFF
        if 2 <= mode <= 6:
            pre['a'][reg] = (pre['a'][reg] + delta) & 0xFFFFFFFF
            post['a'][reg] = (post['a'][reg] + delta) & 0xFFFFFFFF
        elif reg == 0:
            old = (iw[2] - (0x10000 if iw[2] & 0x8000 else 0)) & 0xFFFFFFFF
            nw = (t + old - lo) & 0xFFFFFFFF
            if nw >= 0x8000:
                return None
            iw[2] = nw
            delta = (nw - old) & 0xFFFFFFFF
        else:
            old = (iw[2] << 16) | iw[3]
            new = (old + delta) & 0xFFFFFFFF
            iw[2], iw[3] = new >> 16, new & 0xFFFF
        acc = [(k, (a + delta) & 0xFFFFFFFF, s, v) for k, a, s, v in ea]
        for _, a, s, _ in acc:
            if a >= 0x40000000:
                return None                           # RAM is $00000000-$3FFFFFFF to GLUE
            if mode == 7 and reg == 0:
                if not (0x0400 <= a and a + s <= 0x2000 and not (0x1000 <= a < 0x1010)):
                    return None
            elif not (FREE0 <= (a & MASK) and (a & MASK) + s <= FREE1):
                return None
        return pre, post, iw, acc

    def add(self, rec, n, acc):
        r0 = self.relocate(rec, n, acc)
        if r0 is None:
            return False
        pre, post, iw, acc = r0
        if self.conflicts(acc):
            return False
        words = []
        for k, a, s, v in acc:
            if k == 'r':
                words += movei(a & MASK, s, v)
        # inline data: D0-A7, FP0-FP7 (96-bit), FPCR FPSR FPIAR - skipped by a BRA
        data = []
        for x in pre['d'] + pre['a']:
            data += L(x)
        for x in pre['fp']:
            data += [(x >> 64) & 0xFFFF, 0, (x >> 48) & 0xFFFF, (x >> 32) & 0xFFFF, (x >> 16) & 0xFFFF, x & 0xFFFF]
        data += L(pre['fpcr']) + L(pre['fpsr']) + L(pre['fpiar'])
        nres = 4 * (16 + 24 + 3)
        need = len(words) + 2 + len(data) + 6 + 6 + 4 + n + 2 + 6 + 6 + 4 + 2
        if not self.fits(need, nres):
            return False
        start = self.here()
        dstart = start + 2 * (len(words) + 2)
        words += [0x6000, 2 * len(data) + 2]          # bra.w over the data
        words += data
        words += [0xF239, 0xD0FF] + L(dstart + 64)    # fmovem.x (d).l,fp0-fp7
        words += [0xF239, 0x9C00] + L(dstart + 160)   # fmovem.l (d).l,fpcr/fpsr/fpiar
        words += [0x4CF9, 0xFFFF] + L(dstart)         # movem.l (d).l,d0-a7
        ipc = start + 2 * len(words)
        words += iw                                   # the instruction
        words += [0xF280, 0x0000]                     # fnop
        r = self.res
        words += [0x48F9, 0xFFFF] + L(r)              # movem.l d0-a7,(r).l
        words += [0xF239, 0xF0FF] + L(r + 64)         # fmovem.x fp0-fp7,(r+64).l
        words += [0xF239, 0xBC00] + L(r + 160)        # fmovem.l fpcr/fpsr/fpiar,(r+160).l
        self.code += words
        self.res += nres
        for _, a, s, _ in acc:
            self.touched.update((a & MASK) + j for j in range(s))
        # the checks
        for i, x in enumerate(post['d'] + post['a']):
            self.expect.append((r + 4 * i, x, 0xFFFFFFFF))
        for i, x in enumerate(post['fp']):
            b = r + 64 + 12 * i
            self.expect += [(b, ((x >> 64) & 0xFFFF) << 16, 0xFFFF0000), (b + 4, (x >> 32) & 0xFFFFFFFF, 0xFFFFFFFF),
                            (b + 8, x & 0xFFFFFFFF, 0xFFFFFFFF)]
        self.expect += [(r + 160, post['fpcr'], 0xFFFFFFFF), (r + 164, post['fpsr'], 0xFFFFFFFF)]
        if post['fpiar'] == pre['pc']:
            self.expect.append((r + 168, ipc, 0xFFFFFFFF))       # this instruction's address
        elif post['fpiar'] == pre['fpiar']:
            self.expect.append((r + 168, pre['fpiar'], 0xFFFFFFFF))
        last = {}
        for k, a, s, v in acc:
            if k == 'w':
                for j in range(s):
                    last[(a & MASK) + j] = (v >> (8 * (s - 1 - j))) & 0xFF
        for b, v in sorted(last.items()):
            sh = 8 * (3 - (b & 3))
            self.expect.append((b & ~3, v << sh, 0xFF << sh))
        self.list.append('%s %s at %05X: %s' % (rec['dir'], ''.join('%04x' % x for x in iw), ipc, ' '.join(
            '%s%06X:%d' % (k, a & MASK, s) for k, a, s, _ in acc)))
        return True

    def finish(self):
        self.code += [0x21FC] + L(0x600D0001) + [0x3FF0, 0x4E72, 0x2700]
        img = [0] * 65536

        def put(addr, ws):
            for i, w in enumerate(ws):
                img[addr // 2 + i] = w & 0xFFFF
        for v in range(256):
            put(4 * v, L(0x2000 + 16 * v))
            put(0x2000 + 16 * v, [0x21FC] + L(0xDEAD0000 | v) + [0x3FF0, 0x4E72, 0x2700])
        put(0, L(0x3E00))
        put(4, L(0x1000))
        put(0x1000, [0x4EF9] + L(CODE0))              # jmp code
        put(CODE0, self.code)
        return img


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('records', nargs='+')
    ap.add_argument('-o', required=True)
    ap.add_argument('--per', type=int, default=4)
    ap.add_argument('--batch', type=int, default=120)
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args(argv)
    rnd = random.Random(a.seed)
    cv = convert.Conv()
    pool = defaultdict(list)
    seen = defaultdict(int)
    for p in a.records:
        for line in open(p):
            rec = parse(line)
            s = suitable(rec)
            if not s:
                continue
            n, mode, acc = s
            key = (rec['dir'], mode, (rec['words'][0] & 7) if mode == 7 else 0,
                   (rec['words'][1] >> 13) if (rec['words'][0] & 0xFFC0) == 0xF200 else 0)
            seen[key] += 1
            # reservoir per key, model-agreeing rounds only
            if len(pool[key]) < a.per:
                if model_agrees(cv, rec):
                    pool[key].append(rec)
            elif rnd.random() < a.per / seen[key] and model_agrees(cv, rec):
                pool[key][rnd.randrange(a.per)] = rec
    os.makedirs(a.o, exist_ok=True)
    recs = [r for k in sorted(pool) for r in pool[k]]
    rnd.shuffle(recs)
    nb, b, total = 0, Batch(), 0

    def flush(b, nb):
        img = b.finish()
        with open(os.path.join(a.o, 'prog_%02d.hex' % nb), 'w', newline='\n') as f:
            f.write(''.join('%04x\n' % w for w in img))
        with open(os.path.join(a.o, 'expect_%02d.txt' % nb), 'w', newline='\n') as f:
            f.write(''.join('%08x %08x %08x\n' % e for e in b.expect))
        with open(os.path.join(a.o, 'list_%02d.txt' % nb), 'w', newline='\n') as f:
            f.write('\n'.join(b.list) + '\n')
    todo = recs
    while todo:
        later = []
        for rec in todo:
            n, mode, acc = suitable(rec)
            if len(b.list) >= a.batch:
                later.append(rec)
                continue
            if b.add(rec, n, acc):
                total += 1
            elif b.list:
                later.append(rec)                     # a conflict or no room: the next batch
        if not b.list:
            break
        flush(b, nb)
        nb += 1
        b = Batch()
        todo = later
    print('%d keys, %d rounds in %d batches' % (len(pool), total, nb))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
