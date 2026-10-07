"""Harness I (plan 1.18.6): WinUAE cputest 68030 INTEGER rounds run as
programs on the kernel, the wrapper and GLUE (sim/cputest_int).

    python3 harness_i.py <sampled.txt>... -o <dir> [--batch N]

Each round runs at its own addresses (the bench has 8 MB, decoded in full):
  1. its input bytes - the first value each byte it reads had - stored;
  2. its instruction words copied to the PC WinUAE ran them at, and a JMP
     back to the harness at the PC WinUAE ended at (the next instruction,
     or a branch's target), so PC-relative operands and branches run as
     recorded.  The generator puts a NOP/ILLEGAL pair, in either order,
     after the instruction and at a branch target, and its post PC R
     subtracts the END pair's NOP (cputest.cpp: extraopcodeendsize), right
     or not for the target: a round that left the straight path really
     ended at R - 2, R or R + 2.  So it gets the generator's NOP ($2048,
     MOVEA.L A0,A0: no register, no flag) at R - 2 and R and its JMP at
     R + 2;
  3. the three stack pointers loaded (MOVEC: USP, ISP, MSP, as the record's
     sp fields give them - its A7 is always the USP), then SR, which picks
     the active one, and D0-A6; a JMP to the instruction;
  4. back in the harness: SR (the CCR in user mode, MOVE from CCR), D0-A7
     and a copy of every byte the round wrote, taken at once; a user-mode
     round returns to supervisor mode through TRAP #15, whose handler sets
     the stacked SR to $2700.
The checks: the registers (A7 the ACTIVE stack pointer after the round, the
record's sp field), SR (the CCR in user mode) and the written bytes against
WinUAE's.  Left out: rounds whose accesses or code fall outside the
RAM or inside the harness, or overlap the code or the JMP placed for them.

Memory: $0-$7FFF and $500000-$6FFFFF the generator's; the vectors at VBR
$8000, stubs $8400 ($DEADxxxx to the marker at $9FF0, the round number at
$9FF4), the TRAP #15 handler $9400, the harness's stack below $9E00 (a
round's own ISP and MSP take the TRAP #15 and stub frames), the harness code
from $A000, results from $18000; program.hex is the first 128 KB.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from convert import parse                                     # noqa: E402

VBR, STUBS, TRAPH, SSP, MARK, CODE0, CODE1, RES0, RES1 = (
    0x8000, 0x8400, 0x9400, 0x9E00, 0x9FF0, 0xA000, 0x18000, 0x18000, 0x20000)
HARNESS = (0x8000, 0x20000)
RAMTOP = 0x800000


def L(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]


def movei(addr, size, v):
    if size == 1:
        return [0x13FC, v & 0xFF] + L(addr)
    if size == 2:
        return [0x33FC, v & 0xFFFF] + L(addr)
    return [0x23FC] + L(v) + L(addr)


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def prepare(rec):
    """The round's facts, or None when the harness cannot run it."""
    if rec['exc'] != 4 or len(rec['mem']) < 3 or 'sp' not in rec:
        return None
    if rec['post']['sr'] & 0xC000:
        return None                             # it turns tracing on: the harness's next instruction would trace
    if '/MOVES' in rec['dir']:
        return None                             # SFC/DFC are not in the record
    acc = rec['mem'][:-3]                       # the end marker's frame: the last three writes
    pc0, pc1 = rec['pre']['pc'], rec['post']['pc']
    n = len(rec['words'])
    code = (pc0, pc0 + 2 * n)
    straight = pc1 == code[1]
    jmpa = pc1 if straight else pc1 + 2
    jmp = (pc1 if straight else pc1 - 2, jmpa + 6)   # the JMP and, off the straight path, the NOPs
    if pc0 & 1 or pc1 & 1 or jmp[0] < 0 or overlaps(*code, *jmp):
        return None
    for lo, hi in (code, jmp):
        if hi > RAMTOP or overlaps(lo, hi, *HARNESS):
            return None
    for k, a, s, v in acc:
        if a + s > RAMTOP or overlaps(a, a + s, *HARNESS) or overlaps(a, a + s, *jmp):
            return None
        if k == 'w' and overlaps(a, a + s, *code):
            return None                         # self-modifying
    nops = [] if straight else [pc1 - 2, pc1]
    reads, wr = {}, {}
    for k, a, s, v in acc:
        for j in range(s):
            b = (v >> (8 * (s - 1 - j))) & 0xFF
            if k == 'r':
                if a + j not in reads and a + j not in wr:
                    reads[a + j] = b
            else:
                wr[a + j] = b
    return acc, reads, wr, nops, jmpa


class Batch:
    def __init__(self):
        self.code = [0x203C] + L(VBR) + [0x4E7B, 0x0801]      # move.l #VBR,d0; movec d0,vbr
        self.res, self.expect, self.list = RES0, [], []

    def here(self):
        return CODE0 + 2 * len(self.code)

    def add(self, rec, prep, k):
        acc, reads, wr, nops, jmpa = prep
        pre, post = rec['pre'], rec['post']
        usp, isp, msp, a7_post, s_post = rec['sp']
        s_pre = (pre['sr'] >> 13) & 1
        nres = 4 * 17 + len(wr)
        nres = (nres + 3) & ~3
        w = [0x23FC] + L(k) + L(MARK + 4)       # the round number, for a stub's report
        for a in sorted(reads):                 # the inputs, a byte at a time
            w += movei(a, 1, reads[a])
        for i, x in enumerate(rec['words']):    # the instruction, where WinUAE ran it
            w += movei(pre['pc'] + 2 * i, 2, x)
        for a in nops:
            w += movei(a, 2, 0x2048)            # the generator's NOP, MOVEA.L A0,A0
        cont_ofs = len(w)                       # the JMP back: its target patched below
        w += [0x33FC, 0x4EF9] + L(jmpa)
        w += [0x23FC, 0, 0] + L(jmpa + 2)
        regs = pre['d'] + pre['a'][:7] + [0]
        data = []
        for x in regs:
            data += L(x)
        dstart = self.here() + 2 * (len(w) + 2)
        w += [0x6000, 2 * len(data) + 2] + data # bra.w over the data
        # the three stack pointers (MOVEC $800 USP, $803 MSP, $804 ISP);
        # SR then picks the active one, as on the chip
        for sp, cr in ((usp, 0x800), (msp, 0x803), (isp, 0x804)):
            w += [0x203C] + L(sp) + [0x4E7B, cr]              # move.l #sp,d0; movec d0,<sp>
        w += [0x4CF9, 0x7FFF] + L(dstart)                     # movem.l (d).l,d0-a6
        w += [0x46FC, pre['sr']]                              # move #sr,sr
        w += [0x4EF9] + L(pre['pc'])                          # jmp the instruction
        cont = self.here() + 2 * len(w)
        w[cont_ofs + 5], w[cont_ofs + 6] = L(cont)
        r = self.res
        if s_post:
            w += [0x40F9] + L(r + 64)                         # move sr,(r+64).l
        else:
            w += [0x42F9] + L(r + 64)                         # move ccr,(r+64).l
        w += [0x48F9, 0xFFFF] + L(r)                          # movem.l d0-a7,(r).l
        for j, a in enumerate(sorted(wr)):                    # the written bytes, at once
            w += [0x13F9] + L(a) + L(r + 68 + j)              # (before TRAP #15 can push a frame)
        if not s_post:
            w += [0x4E4F]                                     # trap #15: back to supervisor
        w += [0x46FC, 0x2700] + [0x4FF9] + L(SSP)             # move #$2700,sr; lea ssp,a7
        if self.here() + 2 * len(w) + 64 > CODE1 or r + nres > RES1:
            return False
        self.code += w
        self.res += nres
        for i, x in enumerate(post['d'] + post['a'][:7] + [a7_post]):
            self.expect.append((r + 4 * i, x, 0xFFFFFFFF))
        if s_post:
            self.expect.append((r + 64, post['sr'] << 16, 0xFFFF0000))
        else:
            self.expect.append((r + 64, (post['sr'] & 0xFF) << 16, 0xFFFF0000))
        for j, a in enumerate(sorted(wr)):
            b = r + 68 + j
            sh = 8 * (3 - (b & 3))
            self.expect.append((b & ~3, wr[a] << sh, 0xFF << sh))
        self.list.append('%d %s %s pre_sr %04x pc %06X->%06X res %05X reads %d writes %d' % (
            k, rec['dir'], ''.join('%04x' % x for x in rec['words']), pre['sr'], pre['pc'], post['pc'],
            r, len(reads), len(wr)))
        return True

    def finish(self):
        self.code += [0x23FC] + L(0x600D0001) + L(MARK) + [0x4E72, 0x2700]
        img = [0] * 65536

        def put(addr, ws):
            for i, x in enumerate(ws):
                img[addr // 2 + i] = x & 0xFFFF
        put(0, L(SSP) + L(CODE0))                             # reset: SSP, PC
        for v in range(256):
            put(VBR + 4 * v, L(STUBS + 16 * v))
            put(STUBS + 16 * v, [0x23FC] + L(0xDEAD0000 | v) + L(MARK) + [0x4E72, 0x2700])
        put(VBR + 4 * 47, L(TRAPH))                           # TRAP #15
        put(TRAPH, [0x3EBC, 0x2700, 0x4E73])                  # move.w #$2700,(a7); rte
        put(CODE0, self.code)
        return img


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('records', nargs='+')
    ap.add_argument('-o', required=True)
    ap.add_argument('--batch', type=int, default=150)
    a = ap.parse_args(argv)
    os.makedirs(a.o, exist_ok=True)
    recs, skipped = [], 0
    for p in a.records:
        for line in open(p):
            rec = parse(line)
            prep = prepare(rec)
            if prep is None:
                skipped += 1
            else:
                recs.append((rec, prep))
    nb, b, total, k = 0, Batch(), 0, 0

    def flush(b, nb):
        img = b.finish()
        with open(os.path.join(a.o, 'prog_%03d.hex' % nb), 'w', newline='\n') as f:
            f.write(''.join('%04x\n' % x for x in img))
        with open(os.path.join(a.o, 'expect_%03d.txt' % nb), 'w', newline='\n') as f:
            f.write(''.join('%08x %08x %08x\n' % e for e in b.expect))
        with open(os.path.join(a.o, 'list_%03d.txt' % nb), 'w', newline='\n') as f:
            f.write('\n'.join(b.list) + '\n')
    for rec, prep in recs:
        if len(b.list) >= a.batch or not b.add(rec, prep, k):
            flush(b, nb)
            nb += 1
            b = Batch()
            if not b.add(rec, prep, k):
                raise SystemExit('a round does not fit an empty batch: %s' % rec['dir'])
        k += 1
        total += 1
    if b.list:
        flush(b, nb)
        nb += 1
    print('%d rounds in %d batches; %d left out (outside the RAM, inside the harness, or overlapping its code)'
          % (total, nb, skipped))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
