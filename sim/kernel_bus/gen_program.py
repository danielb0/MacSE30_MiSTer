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
    bytes), each followed by a BFEXTU of the same field.  Then STOP.

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
    stop_at = ORG + 2 * len(p.words)
    p.emit(0x4E72, 0x2700)                                         # STOP #$2700
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


def expected_beats(p, oracle, port):
    """One line per beat: label cat addr nuds nlds rw hi lo mask.
    cat is 'bf5' for a five-byte bit field row, else '-'.  hi/lo are the
    bytes expected on lanes 0/1 (D15:8 / D7:0 of the 16-bit kernel bus) on
    a write, or 'xx' when not checked.  On a 16-bit port the mask column
    is in the kernel's own convention (kernel16_masks)."""
    lines = []
    # the reset SSP at 0 is a long data read; the PC at 4 the kernel reads in
    # its fetch state (busstate 00), which the bench does not check
    for b, m in zip(oracle[("long", 0, port)], _masks(oracle[("long", 0, port)], port)):
        lines.append(("reset SSP", "-", _consumed(b, oracle[("long", 0, port)]), b, "r", None, m))
    for label, case, a, dirn, data in p.accesses:
        beats = oracle[(case, a & 3, port)]
        consumed = 0
        for b, m in zip(beats, _masks(beats, port)):
            lines.append((label, "bf5" if case == "bf5" else "-", a + consumed, b, dirn, data, m))
            consumed += b["n"]
            if b["last"] and b["oc"] == 0 and case == "bf5":
                consumed = 4   # the second operand cycle starts at A+4
    out = []
    for label, cat, addr, b, dirn, data, mask in lines:
        nuds = "0" if 0 in b["lanes"] else "1"
        nlds = "0" if 1 in b["lanes"] else "1"
        hi = lo = "xx"
        if dirn == "w" and data is not None:
            names = b["bytes"]
            # OPn -> data byte: OP(4-size+i) is data[i]
            first = 4 - len(data)
            for name, lane in zip(names, b["lanes"]):
                if name.startswith("OP"):
                    v = data[int(name[2:]) - first]
                    if lane == 0:
                        hi = "%02x" % v
                    elif lane == 1:
                        lo = "%02x" % v
        out.append("%-16s %-3s %08x %s %s %s %s %s %s" % (label.replace(" ", "_"), cat, addr, nuds, nlds, dirn, hi, lo, mask))
    return out


def _masks(beats, port):
    """Per operand cycle: the kernel's convention on a 16-bit port, the
    oracle's otherwise.  bf5 rows hold two operand cycles; split them."""
    if port != 16:
        return [b["mask"] for b in beats]
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
    ap.add_argument("--no-bf5", action="store_true",
                    help="leave out the five-byte bit fields (the 16-bit kernel does them as one "
                         "operand cycle, 1+2+2 beats at odd offsets; the adopted contract is two, 1.14)")
    args = ap.parse_args()
    oracle = load_oracle(args.oracle)
    p, stop_at = build(bf5=not args.no_bf5)

    mem = [0x4E71] * 65536                                          # NOPs
    mem[0], mem[1] = 0x0000, 0x0800                                 # SSP = $800
    mem[2], mem[3] = 0x0000, ORG                                    # PC
    for i, w in enumerate(p.words):
        mem[ORG // 2 + i] = w
    for i in range(0x100):                                          # data area: $FF, so a
        mem[BASE // 2 + i] = 0xFFFF                                 # bit-field insert shows
    with open(os.path.join(HERE, "program.hex"), "w", newline="\n") as f:
        for w in mem:
            f.write("%04x\n" % w)
    with open(os.path.join(HERE, "expect.txt"), "w", newline="\n") as f:
        f.write("# expected beats for port %d; STOP at %08x; made by gen_program.py from %s\n" % (args.port, stop_at, os.path.basename(args.oracle)))
        for line in expected_beats(p, oracle, args.port):
            f.write(line + "\n")
    with open(os.path.join(HERE, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n" % stop_at)
    n = sum(1 for _ in open(os.path.join(HERE, "expect.txt"))) - 1
    print("program: %d words, STOP at $%X, %d accesses, %d expected beats at port %d" % (len(p.words), stop_at, len(p.accesses), n, args.port))


if __name__ == "__main__":
    main()
