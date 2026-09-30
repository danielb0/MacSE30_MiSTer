#!/usr/bin/env python3
"""The kernel bus bench's program and its expected beats (plan 1.14).

Writes `program.hex` - a 64K-word memory image for tb_kernel_bus.v - and
`expect.txt`, the beats the program must produce on a port of the given
width, looked up row by row in beats.txt (the oracle from UM 7.2, made by
scripts/se30_bus_beats.py).  Nothing here is derived from the kernel; the
bench compares what the kernel does against this.

THE PROGRAM
    D0 = $01020304, so the operand bytes are OP0..OP3 = 01 02 03 04.  For
    each size (byte, word, long) at each offset 0..3 from $2000: write D0
    to (A0), read it back into D1, store D1 as a long at a result slot
    from $3000.  Then the bit fields: at each offset, BFINS D0 into a
    16-bit field at bit offset 4 (three bytes) and a 32-bit one (five
    bytes), each followed by a BFEXTU of the same field.  Then PMOVE of
    CRP and SRP from and to memory in every control alterable mode, two
    long operands each (preloaded sources, `Program.data`).  Then STOP.

    After the operands, control flow - a subroutine, a loop, a forward
    branch, TRAP #0 and a level-1 interrupt that the bench raises when the
    program writes IRQ_RAISE and drops when the handler writes IRQ_CLEAR -
    leaving D2..D6 in slots 12..16.  Its beats are not in expect.txt (the
    stack frames' order is the kernel's business); the bench checks the
    slots and the fetch rule.

    Instruction fetches are not in expect.txt: the 16-bit kernel fetches
    words and the 030 contract is an aligned long (1.14); the bench skips
    busstate=00 beats.  The reset SSP read is a data beat and is included;
    the reset PC the kernel reads in its fetch state.

    --no-bf5 leaves the five-byte fields out.  On the 16-bit kernel today
    they are one operand cycle with the mask 100000 consumed two bytes a
    beat - 1+2+2 beats at an odd offset - where the adopted contract
    (1.14: two operand cycles, long then byte) gives 1+2+1+1.  With them
    in, the 16-bit run fails on exactly those rows until plan 1.13 step 2
    is made; without them it is the regression run of everything else.

USAGE
    gen_program.py [--port 16|32|8] [--oracle ../../sim/kernel_bus/beats.txt]
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
D0 = [0x01, 0x02, 0x03, 0x04]
BASE = 0x2000
RESULT = 0x3000
ORG = 0x1000
IRQ_RAISE = 0x3080      # a write here makes the bench raise a level-1 interrupt
IRQ_CLEAR = 0x3084      # a write here (by the handler) drops it


def load_oracle(path):
    """(case, A1A0, port) -> list of beat dicts, in order."""
    idx = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip() or line.startswith("case"):
                continue
            parts = line.split()
            case, a1a0, port = parts[0], int(parts[1]), int(parts[2])
            # columns: case A1A0 port oc beat of SIZ A1A0' n bytes lanes
            #          drive (four tokens) DSACK mask mask' last
            assert len(parts) == 19, line
            b = {
                "oc": int(parts[3]), "siz": parts[6], "a1a0": int(parts[7]), "n": int(parts[8]),
                "bytes": parts[9].split("+"), "lanes": [int(x) for x in parts[10].split("+")],
                "drive": parts[11:15], "dsack": parts[15], "mask": parts[16], "last": parts[18] == "1",
            }
            idx.setdefault((case, a1a0, port), []).append(b)
    return idx


class Program:
    def __init__(self):
        self.words = []          # code words from ORG
        self.accesses = []       # (label, case, A, dir, data bytes or None)
        self.data = []           # (A, long) preloaded into memory

    def emit(self, *ws):
        self.words.extend(ws)

    def lea(self, addr):
        self.emit(0x41F9, addr >> 16, addr & 0xFFFF)              # LEA (xxx).L,A0

    def access(self, label, case, addr, dirn, data=None):
        self.accesses.append((label, case, addr, dirn, data))


def build(bf5=True):
    p = Program()
    p.emit(0x203C, 0x0102, 0x0304)                                 # MOVE.L #$01020304,D0
    slot = RESULT
    for size, case, wr, rd in ((1, "byte", 0x1080, 0x1210), (2, "word", 0x3080, 0x3210), (4, "long", 0x2080, 0x2210)):
        for off in range(4):
            a = BASE + off
            p.lea(a)
            p.emit(wr)                                             # MOVE.x D0,(A0)
            p.access("%s w +%d" % (case, off), case, a, "w", D0[4 - size:])
            p.emit(rd)                                             # MOVE.x (A0),D1
            p.access("%s r +%d" % (case, off), case, a, "r")
            p.emit(0x23C1, slot >> 16, slot & 0xFFFF)              # MOVE.L D1,(slot).L
            # D1 after MOVE.B/W keeps its upper bytes: the bench zeroes D1
            # only at the start, so the slot holds D0's low `size` bytes
            # in the low lanes and the previous D1's upper bytes above -
            # which are D0's own bytes after the first long read, and zero
            # before it.  Expected value tracked here.
            p.access("slot %s +%d" % (case, off), "long", slot, "w", None)
            slot += 4
    # MOVEM (plan 3.8 item 23): each register is its own operand, the next
    # at the previous one's address plus its size.  On the 32-bit port a
    # long moves in one beat, and the kernel stepped from its first beat's
    # address by the 16-bit shape's constant 2 - the second register went
    # to A+2 (the ROM's RAM data-bus test, MOVEM.L D0-D1,(A0), found it on
    # the board).  D2 carries a second known long; D3/D4 take the reads.
    p.emit(0x243C, 0x0506, 0x0708)                                 # MOVE.L #$05060708,D2
    D2 = [0x05, 0x06, 0x07, 0x08]
    for off in range(4):
        a = BASE + off
        p.lea(a)
        p.emit(0x48D0, 0x0005)                                     # MOVEM.L D0/D2,(A0)
        p.access("movem.l w +%d" % off, "long", a, "w", D0)
        p.access("movem.l w2 +%d" % off, "long", a + 4, "w", D2)
        p.emit(0x4CD0, 0x0018)                                     # MOVEM.L (A0),D3/D4
        p.access("movem.l r +%d" % off, "long", a, "r")
        p.access("movem.l r2 +%d" % off, "long", a + 4, "r")
        p.emit(0x4890, 0x0005)                                     # MOVEM.W D0/D2,(A0)
        p.access("movem.w w +%d" % off, "word", a, "w", D0[2:])
        p.access("movem.w w2 +%d" % off, "word", a + 2, "w", D2[2:])
        p.lea(a + 8)
        p.emit(0x48E0, 0xA000)                                     # MOVEM.L D0/D2,-(A0): D2 first, at A-4
        p.access("movem.l pd +%d" % off, "long", a + 4, "w", D2)
        p.access("movem.l pd2 +%d" % off, "long", a, "w", D0)
        p.emit(0x4CD8, 0x0018)                                     # MOVEM.L (A0)+,D3/D4
        p.access("movem.l pi +%d" % off, "long", a, "r")
        p.access("movem.l pi2 +%d" % off, "long", a + 4, "r")
    for off in range(4):
        a = BASE + off
        p.lea(a)
        p.emit(0xEFD0, 0x0110)                                     # BFINS D0,(A0){4:16}
        p.access("bf3 ins r +%d" % off, "3byte", a, "r")
        p.access("bf3 ins w +%d" % off, "3byte", a, "w")
        p.emit(0xE9D0, 0x1110)                                     # BFEXTU (A0){4:16},D1
        p.access("bf3 ext r +%d" % off, "3byte", a, "r")
    # the five-byte fields last: where the kernel's beat count differs from
    # the contract (odd offsets) the stream desynchronises from there on,
    # so only their own rows are affected
    for off in range(4 if bf5 else 0):
        a = BASE + off
        p.lea(a)
        p.emit(0xEFD0, 0x0100)                                     # BFINS D0,(A0){4:32}
        p.access("bf5 ins r +%d" % off, "bf5", a, "r")
        p.access("bf5 ins w +%d" % off, "bf5", a, "w")
        p.emit(0xE9D0, 0x1100)                                     # BFEXTU (A0){4:32},D1
        p.access("bf5 ext r +%d" % off, "bf5", a, "r")
    # PMOVE of a 64-bit root pointer (CRP, SRP): two long operands, the
    # high long at EA and the low long at EA + 4.  The ROM's _SwapMMUMode
    # does PMOVE (A0),CRP.  On the 32-bit port the kernel stepped from the
    # high long by the beat step (1.15 item 4) instead of PMOVE's +4 and
    # read the low long at EA + 2 (EA + 1 on the 8-bit device).  Every
    # control alterable mode (the 030's PMOVE takes no other; (An)+ and
    # -(An) are the F-line), and (An) misaligned by 2.  Each load is
    # written back with PMOVE to memory in the same mode, so the value the
    # MMU took is on the lanes.  Sources are preloaded (p.data) in the
    # operand area, so PORT=8 runs every access on the 8-bit device.
    src, dst = BASE + 0x10, BASE + 0x80
    k = 0
    for name, ld, st in (("crp", 0x4C00, 0x4E00), ("srp", 0x4800, 0x4A00)):
        for mode in ("(an)", "(an)+2", "(d16,an)", "(d8,an,xn)", "(xxx).w", "(xxx).l"):
            if mode == "(an)+2":
                src += 2
                dst += 2
            hi = ((0x7F01 + k) << 16) | 0x0002                     # L/U 0, limit, DT = 2
            lo = 0x00012340 + k * 0x01010100                       # table address, bits 3-0 clear
            v = [(hi >> s) & 0xFF for s in (24, 16, 8, 0)] + [(lo >> s) & 0xFF for s in (24, 16, 8, 0)]
            p.data.append((src, hi))
            p.data.append((src + 4, lo))
            for a, ext, dirn in ((src, ld, "r"), (dst, st, "w")):
                if mode in ("(an)", "(an)+2"):
                    p.lea(a)
                    p.emit(0xF010, ext)                            # PMOVE (A0),rp / rp,(A0)
                elif mode == "(d16,an)":
                    p.lea(a - 0x10)
                    p.emit(0xF028, ext, 0x0010)                    # ($10,A0)
                elif mode == "(d8,an,xn)":
                    p.lea(a - 0x20)
                    p.emit(0x43F8, 0x0010)                         # LEA $10.w,A1
                    p.emit(0xF030, ext, 0x9010)                    # ($10,A0,A1.W)
                elif mode == "(xxx).w":
                    p.emit(0xF038, ext, a)                         # (a).W
                else:
                    p.emit(0xF039, ext, a >> 16, a & 0xFFFF)       # (a).L
                p.access("pm %s %s %sh" % (name, mode, dirn), "long", a, dirn, v[:4] if dirn == "w" else None)
                p.access("pm %s %s %sl" % (name, mode, dirn), "long", a + 4, dirn, v[4:] if dirn == "w" else None)
            if mode == "(an)+2":
                src += 2
                dst += 2
            src += 8
            dst += 8
            k += 1
    assert src <= BASE + 0x80 and dst <= BASE + 0x100
    # control flow (not in the beat stream; checked by its results and the
    # fetch rule): a subroutine, a loop, a forward branch, a trap, an
    # interrupt.  D2..D6 land in slots 12..16.
    p.emit(0x46FC, 0x2000)                                         # MOVE #$2000,SR: interrupts on
    bsr_at = ORG + 2 * len(p.words)
    p.emit(0x6100, 0x0000)                                         # BSR.W sub (displacement patched below)
    p.emit(0x23C2, 0x0000, RESULT + 48)                            # MOVE.L D2,(slot 12).L
    p.emit(0x7603)                                                 # MOVEQ #3,D3
    p.emit(0x5383, 0x66FC)                                         # loop: SUBQ.L #1,D3; BNE.S loop
    p.emit(0x23C3, 0x0000, RESULT + 52)                            # MOVE.L D3,(slot 13).L
    p.emit(0x6002, 0x4E71)                                         # BRA.S over; NOP
    p.emit(0x283C, 0xF0F0, 0xF0F0)                                 # MOVE.L #$F0F0F0F0,D4
    p.emit(0x23C4, 0x0000, RESULT + 56)                            # MOVE.L D4,(slot 14).L
    p.emit(0x4E40)                                                 # TRAP #0
    p.emit(0x23C5, 0x0000, RESULT + 60)                            # MOVE.L D5,(slot 15).L
    p.emit(0x7C00)                                                 # MOVEQ #0,D6
    p.emit(0x23C6, 0x0000, IRQ_RAISE)                              # MOVE.L D6,(raise).L: the bench raises IRQ
    p.emit(0x4A86, 0x67FC)                                         # wait: TST.L D6; BEQ.S wait
    p.emit(0x23C6, 0x0000, RESULT + 64)                            # MOVE.L D6,(slot 16).L
    stop_at = ORG + 2 * len(p.words)
    p.emit(0x4E72, 0x2700)                                         # STOP #$2700
    sub_at = ORG + 2 * len(p.words)
    p.emit(0x243C, 0xAAAA, 0x5555, 0x4E75)                         # sub: MOVE.L #$AAAA5555,D2; RTS
    trap_at = ORG + 2 * len(p.words)
    p.emit(0x2A3C, 0x0000, 0x5EC7, 0x4E73)                         # trap: MOVE.L #$5EC7,D5; RTE
    irq_at = ORG + 2 * len(p.words)
    p.emit(0x2C3C, 0x0000, 0x01E7)                                 # irq: MOVE.L #$1E7,D6
    p.emit(0x23C6, 0x0000, IRQ_CLEAR, 0x4E73)                      #      MOVE.L D6,(clear).L; RTE
    p.words[(bsr_at - ORG) // 2 + 1] = (sub_at - (bsr_at + 2)) & 0xFFFF
    p.vectors = {0x80: trap_at, 0x64: irq_at}                      # TRAP #0, autovector level 1
    return p, stop_at


def kernel16_masks(beats):
    """The 16-bit kernel's memmask before each beat of one operand cycle.
    The oracle's mask moves by the bytes consumed (bit 4 is always the byte
    at the beat's own address); the kernel's moves a word a beat
    (`memmask <= memmask(3 downto 0)&"11"`, its address stepping by 2),
    with memmaskmux reading bit 5 as the byte at addr-1 when addr is odd.
    The two agree on the operand-start mask and on every even-address
    beat, and differ by one bit position after an odd first beat.  This
    derives the kernel's from the oracle's start mask and its own rule."""
    m = int(beats[0]["mask"], 2)
    out = []
    for b in beats:
        out.append(format(m, "06b"))
        m = ((m << 2) | 3) & 0x3F
    return out


def expected_beats(p, oracle, port, code8=False):
    """One line per beat: label cat addr siz lanes rw b0 b1 b2 b3 mask.
    cat is 'bf5' for a five-byte bit field row, else '-'; siz the SIZ1 SIZ0
    the kernel must drive; lanes the four lanes the port takes, as 0/1 for
    lanes 0..3 (0 = D31:24); b0..b3 the bytes expected on those lanes on a
    write, or 'xx' when not checked."""
    lines = []
    # the reset SSP at 0 is a long data read; the PC at 4 the kernel reads in
    # its fetch state (busstate 00), which the bench does not check
    # the device at each address: with --port 8 only the operand area is
    # the 8-bit device; code, vectors and result slots stay in 32-bit memory
    # (the SE/30's own arrangement - code never runs from an 8-bit port, and
    # the kernel fetches a word a beat until 1.15 step 2c)
    def port_of(addr):
        if port == 8 and not code8:
            return 8 if (addr >> 8) == (BASE >> 8) else 32
        return port
    for b, m in zip(oracle[("long", 0, port_of(0))], _masks(oracle[("long", 0, port_of(0))], port)):
        lines.append(("reset SSP", "-", _consumed(b, oracle[("long", 0, port_of(0))]), b, "r", None, m))
    for label, case, a, dirn, data in p.accesses:
        beats = oracle[(case, a & 3, port_of(a))]
        consumed = 0
        for b, m in zip(beats, _masks(beats, port)):
            lines.append((label, "bf5" if case == "bf5" else "-", a + consumed, b, dirn, data, m))
            consumed += b["n"]
    out = []
    for label, cat, addr, b, dirn, data, mask in lines:
        lanes = "".join("1" if k in b["lanes"] else "0" for k in range(4))
        bytes_ = ["xx"] * 4
        if dirn == "w" and data is not None:
            # OPn -> data byte: OP(4-size+i) is data[i]
            first = 4 - len(data)
            for name, lane in zip(b["bytes"], b["lanes"]):
                if name.startswith("OP"):
                    bytes_[lane] = "%02x" % data[int(name[2:]) - first]
        out.append("%-16s %-3s %08x %s %s %s %s %s %s %s %s" % (
            label.replace(" ", "_"), cat, addr, b["siz"], lanes, dirn, bytes_[0], bytes_[1], bytes_[2], bytes_[3], mask))
    return out


def _masks(beats, port):
    """Per operand cycle: the kernel's convention on a 16-bit port, the
    oracle's otherwise.  bf5 rows hold two operand cycles; split them."""
    return [b["mask"] for b in beats]   # the kernel's mask is the oracle's since 1.15 step 2a
    out, cycle = [], []
    for b in beats:
        cycle.append(b)
        if b["last"]:
            out += kernel16_masks(cycle)
            cycle = []
    return out


def _consumed(b, beats):
    c = 0
    for x in beats:
        if x is b:
            return c
        c += x["n"]
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=16)
    ap.add_argument("--oracle", default=os.path.join(HERE, "beats.txt"))
    ap.add_argument("--code8", action="store_true", help="with --port 8: everything on the 8-bit device, code included")
    ap.add_argument("--no-bf5", action="store_true",
                    help="leave out the five-byte bit fields (the 16-bit kernel does them as one "
                         "operand cycle, 1+2+2 beats at odd offsets; the adopted contract is two, 1.14)")
    args = ap.parse_args()
    oracle = load_oracle(args.oracle)
    p, stop_at = build(bf5=not args.no_bf5)

    mem = [0x4E71] * 65536                                          # NOPs
    mem[0], mem[1] = 0x0000, 0x0800                                 # SSP = $800
    mem[2], mem[3] = 0x0000, ORG                                    # PC
    for v, a in p.vectors.items():
        mem[v // 2], mem[v // 2 + 1] = a >> 16, a & 0xFFFF
    for i, w in enumerate(p.words):
        mem[ORG // 2 + i] = w
    for i in range(0x100):                                          # data area: $FF, so a
        mem[BASE // 2 + i] = 0xFFFF                                 # bit-field insert shows
    for a, v in p.data:                                             # PMOVE's sources
        mem[a // 2], mem[a // 2 + 1] = v >> 16, v & 0xFFFF
    with open(os.path.join(HERE, "program.hex"), "w", newline="\n") as f:
        for w in mem:
            f.write("%04x\n" % w)
    with open(os.path.join(HERE, "expect.txt"), "w", newline="\n") as f:
        f.write("# expected beats for port %d; STOP at %08x; made by gen_program.py from %s\n" % (args.port, stop_at, os.path.basename(args.oracle)))
        for line in expected_beats(p, oracle, args.port, args.code8):
            f.write(line + "\n")
    with open(os.path.join(HERE, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n%d\n" % (stop_at, len(p.words)))            # and the program's words, handlers included
    n = sum(1 for _ in open(os.path.join(HERE, "expect.txt"))) - 1
    print("program: %d words, STOP at $%X, %d accesses, %d expected beats at port %d" % (len(p.words), stop_at, len(p.accesses), n, args.port))


if __name__ == "__main__":
    main()
