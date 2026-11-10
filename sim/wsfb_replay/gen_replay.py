#!/usr/bin/env python3
"""gen_replay.py - the memory image for tb_wsfb_replay.v: NetBSD 11.1's
WSFBSBC kernel calling readdisklabel() on the IIcx's NetBSD disk, as the
board ran it before the MMU fault of 2026-11-09 (the X11/WSFB investigation:
whichType() came back to dk_getdisklabel with a6 on readdisklabel's frame,
twice, every register the same).

    gen_replay.py KERNEL DISK [-o ram.hex] [--icold] [--cacr HEX]

KERNEL is the ELF netbsd-WSFBSBC (decompressed, with symbols); DISK the raw
NetBSD disk image (sd1: its first $4200 bytes are what readdisklabel reads).

THE MACHINE STATE, AS THE BOARD HAD IT (the panic's register dump)
  - The kernel's text, rodata and data at their own addresses (VA = PA,
    .text at 0): readdisklabel $1D544, whichType $1D434, strcmp, strncpy.
  - NetBSD's 68030 MMU: TC $82C0AA00 (E, SRE, 4 KB pages, TIA 10, TIB 10),
    SRP short format, TT0/TT1 off; CACR CACHE_ON $3919 (both caches, burst,
    write-allocate).  Segments 0 and 1 identity; the buffer at VA $05660000
    and the heap structures (the buf, the disklabel) on pages of their own.
  - dk_getdisklabel's frame: a6 = $453C34, its d2 = $0A, d3 = $0C, d6 = 0,
    d7 = $40A, and readdisklabel's five arguments at $453BCC (dev $0:$40A,
    the strategy stub, lp, clp), called with its return address $25E226.
  - geteblk and biowait patched to stubs (the buf at $00987F00 with b_data
    $05660000, already filled from the disk); the strategy a bare RTS.
  - The bench stops at brelse ($234C8C, the success path: the loops done)
    or at $25E226 (returned past readdisklabel: the board's failure).
"""
import argparse, struct, sys

def load_elf(path):
    d = open(path, 'rb').read()
    shoff, = struct.unpack('>I', d[0x20:0x24])
    shentsize, shnum, shstrndx = struct.unpack('>HHH', d[0x2e:0x34])
    secs, syms = [], {}
    for i in range(shnum):
        o = shoff + i * shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack('>IIIIIIIIII', d[o:o + 40])
        secs.append(dict(name=name, type=typ, flags=flags, addr=addr, off=off, size=size, link=link))
    for s in secs:
        if s['type'] == 2:
            strs = secs[s['link']]
            for j in range(s['size'] // 16):
                o = s['off'] + j * 16
                nm, val, sz, inf, oth, shn = struct.unpack('>IIIBBH', d[o:o + 16])
                so = strs['off'] + nm
                syms.setdefault(d[so:d.index(b'\0', so)].decode(), val)
    return d, secs, syms

class Mem:
    def __init__(self, size=8 << 20):
        self.b = bytearray(size)
    def put(self, a, data):
        self.b[a:a + len(data)] = data
    def l(self, a, v):
        self.b[a:a + 4] = struct.pack('>I', v & 0xFFFFFFFF)
    def w(self, a, v):
        self.b[a:a + 2] = struct.pack('>H', v & 0xFFFF)
    def words(self, a, ws):
        for i, x in enumerate(ws):
            self.w(a + 2 * i, x)
    def rl(self, a):
        return struct.unpack('>I', self.b[a:a + 4])[0]

def hi(v): return (v >> 16) & 0xFFFF
def lo(v): return v & 0xFFFF

# addresses (VA; PA where it differs)
SEGTAB   = 0x700000            # 1024 short STEs
PT       = 0x701000            # page tables, 4 KB each, from here
BUF_VA, BUF_PA = 0x05660000, 0x7C0000
BP_VA          = 0x00987F00    # struct buf (geteblk's)
LP_VA          = 0x00921284    # the disklabel (dk_label)
CLP_VA         = 0x00921800    # the cpu_disklabel
HEAP_PAGES = {0x00987000: 0x780000, 0x00921000: 0x781000}
VBRTAB   = 0x7E0000
STUB     = 0x7F0000
XH       = 0x7F0800            # every exception: marker and spin
STRAT    = 0x7F0F00
SSP0     = 0x7F8000
MARK     = 0x7FFF00            # +0 $DEADDEAD on an exception, +4 format/vector, +8 PC
REGS     = 0x7F1000            # d0-d7/a0-a6 for the MOVEM
A6DG     = 0x453C34            # dk_getdisklabel's frame
ARGS     = 0x453BCC            # readdisklabel's arguments
RET      = 0x25E226            # dk_getdisklabel after the call
TC       = 0x82C0AA00
SRP_HI   = 0x80000202          # MMU51_SRP_BITS: lower limit 0, SG, short tables

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('kernel'); ap.add_argument('disk')
    ap.add_argument('-o', default='ram.hex')
    ap.add_argument('--cacr', default='3919', help='CACR as NetBSD loads it (CACHE_ON)')
    ap.add_argument('--warm', action='store_true',
                    help='before the call: the caches full of other valid lines (a 512-byte NOP sled run, '
                         '256 bytes read elsewhere) and the ATC loaded (PLOADR) for every page the replay uses, '
                         'as the board had them after the scheduler and the disk interrupt')
    ap.add_argument('--plant', action='store_true',
                    help="the sanity plant: whichType's LINK A6 as LEA -$20(A7),A7 (a6 never moves: must FAIL at $25E226)")
    a = ap.parse_args()

    d, secs, syms = load_elf(a.kernel)
    m = Mem()
    for s in secs:                                   # PROGBITS with SHF_ALLOC
        if s['type'] == 1 and (s['flags'] & 2) and s['addr'] + s['size'] <= SEGTAB:
            m.put(s['addr'], d[s['off']:s['off'] + s['size']])
    for n, want in (('readdisklabel', 0x1D544), ('whichType', 0x1D434), ('geteblk', 0x2350A0),
                    ('biowait', 0x23524C), ('brelse', 0x234C8C), ('dk_getdisklabel', 0x25E1A2)):
        if syms.get(n) != want:
            sys.exit(f'{n} at {syms.get(n)!r}, not {want:#x}: not the WSFBSBC kernel of 2026-11-02')

    # the stubs (outside the code under test)
    m.words(0x2350A0, [0x41F9, hi(BP_VA), lo(BP_VA), 0x4E75])     # geteblk: lea BP,a0; rts
    m.words(0x23524C, [0x7000, 0x4E75])                            # biowait: moveq #0,d0; rts
    m.words(STRAT, [0x4E75])                                       # the strategy: rts
    if a.plant:
        if m.rl(0x1D434) != 0x4E56FFE0:
            sys.exit('whichType does not start with link.w a6,#-$20')
        m.words(0x1D434, [0x4FEF, 0xFFE0])                         # lea -$20(a7),a7

    # MMU: identity segments 0, 1 (0-8 MB); segment 2 the heap pages; $15 the buffer
    ptn = 0
    def pagetable(entries):
        nonlocal ptn
        base = PT + ptn * 0x1000; ptn += 1
        for idx, pa in entries.items():
            m.l(base + 4 * idx, pa | 1)                          # page descriptor, DT 1
        return base
    for seg in (0, 1):
        t = pagetable({i: (seg << 22) | (i << 12) for i in range(1024)})
        m.l(SEGTAB + 4 * seg, t | 2)                             # table descriptor, DT 2 (short)
    t = pagetable({(va >> 12) & 0x3FF: pa for va, pa in HEAP_PAGES.items()})
    m.l(SEGTAB + 4 * 2, t | 2)
    t = pagetable({((BUF_VA >> 12) & 0x3FF) + i: BUF_PA + (i << 12) for i in range(8)})
    m.l(SEGTAB + 4 * (BUF_VA >> 22), t | 2)
    m.l(STUB + 0x700, SRP_HI); m.l(STUB + 0x704, SEGTAB)            # the root pointer
    m.l(STUB + 0x708, TC); m.l(STUB + 0x70C, 0)                     # TC; 0 for TT0/TT1

    def heap(va): return HEAP_PAGES[va & ~0xFFF] + (va & 0xFFF)
    # the buf: b_data at $30
    m.l(heap(BP_VA) + 0x30, BUF_VA)
    # the disklabel as dk_getdefaultlabel left it: secsize, secpercyl, secperunit
    m.l(heap(LP_VA) + 0x28, 512); m.l(heap(LP_VA) + 0x38, 64 * 32); m.l(heap(LP_VA) + 0x3C, 3072000)
    # the buffer: the disk's first $4200 bytes (block 0, the driver descriptor; the map)
    with open(a.disk, 'rb') as f:
        blk = f.read(0x4200)
    if blk[:2] != b'ER':
        sys.exit('the disk has no driver descriptor ("ER") at block 0')
    m.put(BUF_PA, blk)

    # the stack: readdisklabel's arguments; dk_getdisklabel's frame link
    for i, v in enumerate((0, 0x40A, STRAT, LP_VA, CLP_VA)):
        m.l(ARGS + 4 * i, v)
    m.l(A6DG, 0x453C80)                                             # its caller's a6 (unused)

    # registers at the call (the dump; a2-a5 dk_getdisklabel's own)
    regs = [0, 0, 0x0A, 0x0C, 0, 0, 0, 0x40A,                       # d0-d7
            0, 0, 0x0091D800, 0x00921284, 0x0091D810, 0, A6DG]      # a0-a6
    for i, v in enumerate(regs):
        m.l(REGS + 4 * i, v)

    # the start-up program
    orig0, orig4 = m.rl(0), m.rl(4)
    cacr = int(a.cacr, 16)
    p = [0x46FC, 0x2700,                                            # move #$2700,sr
         0x41F9, hi(VBRTAB), lo(VBRTAB), 0x4E7B, 0x8801,            # lea VBRTAB,a0; movec a0,vbr
         0x21FC, hi(orig0), lo(orig0), 0x0000,                      # move.l #orig,$0.w (the kernel's
         0x21FC, hi(orig4), lo(orig4), 0x0004,                      #   bytes under the reset vector)
         0x41F9, hi(STUB + 0x70C), lo(STUB + 0x70C),
         0xF010, 0x0800, 0xF010, 0x0C00,                            # pmove (a0),tt0; tt1
         0x41F9, hi(STUB + 0x700), lo(STUB + 0x700),
         0xF010, 0x4800, 0xF010, 0x4C00,                            # pmove (a0),srp; crp
         0xF000, 0x2400,                                            # pflusha
         0x41F9, hi(STUB + 0x708), lo(STUB + 0x708), 0xF010, 0x4000,  # pmove (a0),tc
         0x203C, hi(cacr), lo(cacr), 0x4E7B, 0x0002]                # move.l #cacr,d0; movec d0,cacr
    if a.warm:
        SLED, DREAD = 0x7F2000, 0x7F4000
        m.words(SLED, [0x4E71] * 255 + [0x4E75])                    # 255 NOPs; rts
        p += [0x4EB9, hi(SLED), lo(SLED),                           # jsr SLED: 16 foreign I-cache lines
              0x41F9, hi(DREAD), lo(DREAD), 0x303C, 63,             # lea DREAD,a0; move.w #63,d0
              0x2218, 0x51C8, 0xFFFC]                               # 1: move.l (a0)+,d1; dbra d0,1b
        pages = [(0x1D000, 6), (0x1C000, 6), (0x2C3000, 6), (0x2CD000, 6), (0x234000, 6), (0x235000, 6),
                 (0x25E000, 6), (0x2D0000, 5), (0x453000, 5), (BP_VA & ~0xFFF, 5), (LP_VA & ~0xFFF, 5)] + \
                [(BUF_VA + (i << 12), 5) for i in range(5)]
        for va, fc in pages:                                        # lea va,a0; ploadr #fc,(a0)
            p += [0x41F9, hi(va), lo(va), 0xF010, 0x2210 | fc]
    p += [
         0x2E7C, hi(ARGS), lo(ARGS),                                # movea.l #ARGS,a7
         0x2F3C, hi(RET), lo(RET),                                  # move.l #RET,-(a7)
         0x4CF9, 0x7FFF, hi(REGS), lo(REGS),                        # movem.l REGS,d0-d7/a0-a6
         0x46FC, 0x2010,                                            # move #$2010,sr (the dump's)
         0x4EF9, 0x0001, 0xD544]                                    # jmp readdisklabel
    m.words(STUB, p)
    m.words(XH, [0x33EF, 0x0006, hi(MARK + 4), lo(MARK + 4),        # move.w 6(a7),MARK+4
                 0x23EF, 0x0002, hi(MARK + 8), lo(MARK + 8),        # move.l 2(a7),MARK+8
                 0x23FC, 0xDEAD, 0xDEAD, hi(MARK), lo(MARK),        # move.l #$DEADDEAD,MARK
                 0x60FE])
    for v in range(256):
        m.l(VBRTAB + 4 * v, XH)
    m.l(0, SSP0); m.l(4, STUB)                                      # the reset vector

    with open(a.o, 'w', newline='\n') as f:                         # sparse: nonzero longwords
        last = -2
        for i in range(0, len(m.b), 4):
            v = m.rl(i)
            if v:
                if i // 4 != last + 1:
                    f.write(f'@{i // 4:x}\n')
                f.write(f'{v:08x}\n'); last = i // 4
    print(f'{a.o}: kernel {a.kernel}, disk {a.disk}, CACR {cacr:04x}')

if __name__ == '__main__':
    main()
