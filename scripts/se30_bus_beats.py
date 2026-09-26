#!/usr/bin/env python3
"""The 68030's bus beats, from MC68030 UM 7.2 - the oracle for the kernel's
32-bit port (SE30_PLAN.md 1.13 item 1, recorded in 1.14).

WHY THIS EXISTS
    The TG68K kernel moves every operand as 16-bit beats.  The SE/30's
    devices are 8-bit ports on D31-D24 and its RAM and ROM are 32-bit
    ports; the real processor splits an operand into beats by the port
    width each beat's DSACK pair reports (dynamic bus sizing).  Plan 1.13
    decided the kernel gets that behaviour, and asked first for the beat
    contract as a table, written before any VHDL: for each operand size,
    address offset and port width, how many beats, which operand bytes
    ride which data lanes on each, and how the kernel's byte mask
    (`memmask`) is consumed to produce it.  This script is that table's
    source.  Everything in it is from the manual; nothing from an emulator
    or another core.

WHAT IT HOLDS
    Four tables transcribed from the manual, literally, and one rule:

      Table 7-4  the operand bytes a port must present on a read, by lane
      Table 7-5  what the processor drives on all four lanes on a write
      Table 7-6  the number of bus cycles per operand, by alignment and port
      Table 7-7  the lanes a port of each width takes on a write / uncached read

      The rule (7.2.1, 7.2.2): each beat moves the most the port can take
      from the current address to the port's own boundary - n = min(bytes
      remaining, port width - (A mod port width)) - and the next beat starts
      n bytes on with SIZ1-0 reporting what remains (Table 7-2), the port
      answering its width on DSACK1-0 (Table 7-1).

    The rule is run for every case and checked against the four tables:
    Table 7-6's counts, Table 7-7's lanes, the OPn positions of Table 7-4,
    and that Table 7-5's lanes carry the right byte wherever Table 7-7 says
    a port reads them.  Table 7-5's other lanes are replication the manual
    calls implementation ("output but never used"); they are kept verbatim
    so the kernel can drive exactly what the chip drives.

THE KERNEL'S MASK
    `memmask` in TG68KdotC_Kernel.vhd is six bits, active low, one bit per
    byte of the operand counted from its address A: bit 4 is the byte at A,
    bit 3 at A+1, ... bit 0 at A+4; bit 5 (A-1) is never used and stays 1.
    That is what `memmaskmux <= memmask when addr(0)='1' else
    memmask(4 downto 0)&'1'` means: a word beat's strobes are the two bytes
    of the word containing A, so for an even A the window shifts up one.
    Today every beat consumes two bits (`memmask <= memmask(3 downto 0)&"11"`)
    because every beat is a word.  The 030 contract consumes n bits, n from
    DSACK: `memmask <= memmask(5-n downto 0) & ones(n)`, and the operand
    is done when bits 4..0 are all ones - which, unlike today's
    `memmaskmux(3)`, is known only when DSACK names the width.  The columns
    `mask` / `mask'` here are that, in the kernel's own spelling.

CASES
    Operands: byte, word, long (the CPU's), 3-byte and 5-byte (bit fields,
    the kernel's masks 100011 and 100000), and the instruction prefetch
    (always an aligned long, Table 7-6 footnote).  Ports 8, 16, 32.  Every
    A1-A0.  A 5-byte field is two operand cycles per the note to UM 11.6.14
    ("may span 5 bytes that require two operand cycles"); the manual does
    not say which comes first, and here it is the long at A then the byte
    at A+4 (bytes F0..F4) - the owner adopted that 2026-09-26.  The
    kernel holds it as one five-byte mask (100000) whose beats never cross
    the boundary after the fourth byte (plan 1.15), so the mask column is
    that; `oc` marks the second cycle's beat.

USAGE
    se30_bus_beats.py check            run the rule against the tables
    se30_bus_beats.py emit  FILE       write the beat table (sim/kernel_bus)
    se30_bus_beats.py md               the same as Markdown, for reading
"""
import sys

LANES = ("D31:24", "D23:16", "D15:8", "D7:0")   # lane 0 is the top byte
PORTS = (32, 16, 8)                              # Table 7-6's L:W:B order
SIZ = {1: "01", 2: "10", 3: "11", 4: "00"}       # Table 7-2
DSACK = {8: "HL", 16: "LH", 32: "LL"}            # Table 7-1, DSACK1 DSACK0

# --------------------------------------------------------------- Table 7-4
# Read cycles: the operand bytes a port must present, by lane.  '.' is a
# PRn / Nn byte: needed only by a cachable read, don't-care otherwise.
# Key: (size, A1A0).  Values: long-word port lanes 0-3, word port lanes 0-1,
# byte port lane 0.
T74 = {
    (1, 0): ("OP3 . . .",   "OP3 .",   "OP3"),
    (1, 1): (". OP3 . .",   ". OP3",   "OP3"),
    (1, 2): (". . OP3 .",   "OP3 .",   "OP3"),
    (1, 3): (". . . OP3",   ". OP3",   "OP3"),
    (2, 0): ("OP2 OP3 . .", "OP2 OP3", "OP2"),
    (2, 1): (". OP2 OP3 .", ". OP2",   "OP2"),
    (2, 2): (". . OP2 OP3", "OP2 OP3", "OP2"),
    (2, 3): (". . . OP2",   ". OP2",   "OP2"),
    (3, 0): ("OP1 OP2 OP3 .", "OP1 OP2", "OP1"),
    (3, 1): (". OP1 OP2 OP3", ". OP1",   "OP1"),
    (3, 2): (". . OP1 OP2",   "OP1 OP2", "OP1"),
    (3, 3): (". . . OP1",     ". OP1",   "OP1"),
    (4, 0): ("OP0 OP1 OP2 OP3", "OP0 OP1", "OP0"),
    (4, 1): (". OP0 OP1 OP2",   ". OP0",   "OP0"),
    (4, 2): (". . OP0 OP1",     "OP0 OP1", "OP0"),
    (4, 3): (". . . OP0",       ". OP0",   "OP0"),
}

# --------------------------------------------------------------- Table 7-5
# Write cycles: what the processor drives on lanes 0-3.  '*' marks the
# manual's "output but never used".  Word rows are 'x' in A1: same for 0/2
# and for 1/3.
T75 = {
    (1, 0): "OP3 OP3 OP3 OP3", (1, 1): "OP3 OP3 OP3 OP3",
    (1, 2): "OP3 OP3 OP3 OP3", (1, 3): "OP3 OP3 OP3 OP3",
    (2, 0): "OP2 OP3 OP2 OP3", (2, 1): "OP2 OP2 OP3 OP2",
    (2, 2): "OP2 OP3 OP2 OP3", (2, 3): "OP2 OP2 OP3 OP2",
    (3, 0): "OP1 OP2 OP3 OP0*", (3, 1): "OP1 OP1 OP2 OP3",
    (3, 2): "OP1 OP2 OP1 OP2",  (3, 3): "OP1 OP1 OP2* OP1",
    (4, 0): "OP0 OP1 OP2 OP3",  (4, 1): "OP0 OP0 OP1 OP2",
    (4, 2): "OP0 OP1 OP0 OP1",  (4, 3): "OP0 OP0 OP1* OP0",
}

# --------------------------------------------------------------- Table 7-6
# Bus cycles per operand, 32:16:8-bit port, by A1A0.  None = N/A.
T76 = {
    "instr": ((1, 2, 4), None, None, None),
    1: ((1, 1, 1), (1, 1, 1), (1, 1, 1), (1, 1, 1)),
    2: ((1, 1, 2), (1, 2, 2), (1, 1, 2), (2, 2, 2)),
    4: ((1, 2, 4), (2, 3, 4), (2, 2, 4), (2, 3, 4)),
}

# --------------------------------------------------------------- Table 7-7
# Active lanes on a write or an uncached read: for each (size, A1A0), per
# lane, which port widths take it (B, W, L).
T77 = {
    (1, 0): ("BWL", "-", "-", "-"),
    (1, 1): ("B", "WL", "-", "-"),
    (1, 2): ("BW", "-", "L", "-"),
    (1, 3): ("B", "W", "-", "L"),
    (2, 0): ("BWL", "WL", "-", "-"),
    (2, 1): ("B", "WL", "L", "-"),
    (2, 2): ("BW", "W", "L", "L"),
    (2, 3): ("B", "W", "-", "L"),
    (3, 0): ("BWL", "WL", "L", "-"),
    (3, 1): ("B", "WL", "L", "L"),
    (3, 2): ("BW", "W", "L", "L"),
    (3, 3): ("B", "W", "-", "L"),
    (4, 0): ("BWL", "WL", "L", "L"),
    (4, 1): ("B", "WL", "L", "L"),
    (4, 2): ("BW", "W", "L", "L"),
    (4, 3): ("B", "W", "-", "L"),
}
PORTLETTER = {8: "B", 16: "W", 32: "L"}


# ------------------------------------------------------------------ the rule
def beat_bytes(remaining, a, port):
    """Bytes moved in one beat: to the port's own boundary, at most what
    remains (7.2.1: 'the greatest number of bytes possible for the port')."""
    width = port // 8
    return min(remaining, width - (a % width))


def active_lanes(size, a1a0, port):
    """Lanes a port takes for a transfer of `size` bytes at offset A1A0
    (the rule behind Table 7-7): a 32-bit port from lane A1A0, a 16-bit
    port from lane A0 on D31:16, an 8-bit port lane 0 only."""
    width = port // 8
    first = a1a0 % width
    return list(range(first, min(first + size, width)))


def mask_str(m):
    return format(m, "06b")


def ones(n):
    return (1 << n) - 1


def operand_beats(size, a1a0, port, names):
    """The beats of one operand: `names` are the operand's bytes in address
    order (OP(4-size)..OP3 for a CPU operand).  A five-byte bit field is
    one operand with a boundary after its fourth byte: the 68030 accesses
    it as two operand cycles (UM 11.6.14 note), long then byte, and no
    beat crosses the boundary.  Returns a list of dicts, one per beat."""
    beats = []
    remaining = size
    a = a1a0
    mask = 0b111111 & ~(ones(size) << (5 - size))     # bit 4 = byte at A
    i = 0
    while remaining:
        n = beat_bytes(remaining, a, port)
        if size == 5 and remaining > 1:                 # the long boundary
            n = min(n, remaining - 1)
        siz = min(remaining, 4)
        lanes = active_lanes(siz, a & 3, port)[:n]
        assert len(lanes) == n, (size, a1a0, port, remaining, a, n, lanes)
        mask_after = ((mask << n) | ones(n)) & 0b111111
        beats.append({
            "oc": 1 if size == 5 and remaining == 1 else 0,
            "siz": SIZ[siz], "a1a0": a & 3, "n": n,
            "bytes": names[i:i + n], "lanes": lanes,
            "dsack": DSACK[port],
            "mask": mask_str(mask), "mask_after": mask_str(mask_after),
            "last": remaining == n,
        })
        # the last beat leaves bits 4..0 all ones; bit 5 then holds the
        # byte just consumed (the kernel's own shift does the same, ending
        # its long write at "011111")
        assert ((mask_after & 0x1f) == 0x1f) == (remaining == n)
        remaining -= n
        a += n
        i += n
        mask = mask_after
    return beats


def cases():
    """Every case of the table, in the order the file lists them."""
    out = []
    for port in PORTS:
        out.append(("instr", 0, port, [operand_beats(4, 0, port, ["OP0", "OP1", "OP2", "OP3"])]))
    for size in (1, 2, 4, 3, 5):
        for a1a0 in range(4):
            for port in PORTS:
                if size <= 4:
                    names = ["OP%d" % k for k in range(4 - size, 4)]
                else:
                    names = ["F0", "F1", "F2", "F3", "F4"]
                out.append((size, a1a0, port, [operand_beats(size, a1a0, port, names)]))
    return out


# ---------------------------------------------------------------- the checks
def check():
    fails = []

    def expect(cond, what):
        if not cond:
            fails.append(what)

    # Table 7-7 is the lane rule, exactly
    for (size, a1a0), row in T77.items():
        for port in PORTS:
            want = [i for i, s in enumerate(row) if PORTLETTER[port] in s]
            got = active_lanes(size, a1a0, port)
            expect(want == got, "T7-7 size %d A1A0 %d port %d: table %s rule %s" % (size, a1a0, port, want, got))

    # Table 7-4: the OPn on the lanes Table 7-7 activates, in address order
    for (size, a1a0), cols in T74.items():
        names = ["OP%d" % k for k in range(4 - size, 4)]
        for port, col in zip(PORTS, cols):
            entries = col.split()
            lanes = active_lanes(size, a1a0, port)
            got = [entries[l] for l in lanes]
            expect(got == names[:len(lanes)], "T7-4 size %d A1A0 %d port %d: %s" % (size, a1a0, port, got))
            # and nothing else in the port's part of the bus is an OP byte
            others = [e for i, e in enumerate(entries) if i not in lanes]
            expect(all(e == "." for e in others), "T7-4 stray OP: size %d A1A0 %d port %d" % (size, a1a0, port))

    # Table 7-5: wherever Table 7-7 says a port reads a lane, the lane holds
    # the byte the rule puts there
    for (size, a1a0), row in T75.items():
        drive = [e.rstrip("*") for e in row.split()]
        names = ["OP%d" % k for k in range(4 - size, 4)]
        for port in PORTS:
            for i, lane in enumerate(active_lanes(size, a1a0, port)):
                expect(drive[lane] == names[i], "T7-5 size %d A1A0 %d port %d lane %d: drives %s wants %s" % (size, a1a0, port, lane, drive[lane], names[i]))

    # Table 7-6: beat counts
    for size, rows in T76.items():
        for a1a0, counts in enumerate(rows):
            if counts is None:
                continue
            for port, want in zip(PORTS, counts):
                got = len(operand_beats(4 if size == "instr" else size, a1a0, port, ["b"] * 4))
                expect(got == want, "T7-6 %s A1A0 %d port %d: table %d rule %d" % (size, a1a0, port, want, got))

    # the mask: bits 4..0 consumed to all ones exactly on the last beat
    for size, a1a0, port, ocs in cases():
        for beats in ocs:
            for b in beats:
                expect((b["mask_after"][1:] == "11111") == b["last"], "mask %s A1A0 %d port %d: %s" % (size, a1a0, port, b))
            expect(beats[0]["mask"][0] == "1", "mask bit 5 not set at operand start")

    # the five-byte field: two operand cycles, no beat across the boundary
    for a1a0 in range(4):
        for port in PORTS:
            bts = operand_beats(5, a1a0, port, list("ABCDE"))
            expect(sum(b["n"] for b in bts if b["oc"] == 0) == 4, "bf5 first cycle A1A0 %d port %d" % (a1a0, port))
            expect([b["n"] for b in bts if b["oc"] == 1] == [1], "bf5 second cycle A1A0 %d port %d" % (a1a0, port))
            expect(bts[0]["mask"] == "100000", "bf5 mask")

    # the manual's own worked examples
    ex = operand_beats(4, 0, 16, ["OP0", "OP1", "OP2", "OP3"])          # Fig 7-5/7-6
    expect([(b["siz"], b["a1a0"], b["bytes"]) for b in ex] == [("00", 0, ["OP0", "OP1"]), ("10", 2, ["OP2", "OP3"])], "Fig 7-5")
    ex = operand_beats(2, 0, 8, ["OP2", "OP3"])                          # Fig 7-7/7-8
    expect([(b["siz"], b["a1a0"], b["bytes"]) for b in ex] == [("10", 0, ["OP2"]), ("01", 1, ["OP3"])], "Fig 7-7")
    ex = operand_beats(4, 1, 16, ["OP0", "OP1", "OP2", "OP3"])          # Fig 7-9/7-10
    expect([(b["siz"], b["a1a0"], b["bytes"]) for b in ex] == [("00", 1, ["OP0"]), ("11", 2, ["OP1", "OP2"]), ("01", 0, ["OP3"])], "Fig 7-9")
    ex = operand_beats(2, 1, 16, ["OP2", "OP3"])                          # Fig 7-12/7-13
    expect([(b["siz"], b["a1a0"], b["bytes"]) for b in ex] == [("10", 1, ["OP2"]), ("01", 2, ["OP3"])], "Fig 7-12")
    ex = operand_beats(4, 3, 32, ["OP0", "OP1", "OP2", "OP3"])          # Fig 7-15/7-16
    expect([(b["siz"], b["a1a0"], b["bytes"]) for b in ex] == [("00", 3, ["OP0"]), ("11", 0, ["OP1", "OP2", "OP3"])], "Fig 7-15")

    # the kernel's present sequence for a long write to a word port:
    # "100001" -> "000111" -> "011111" (its own comment at the longaktion
    # mask; the "111111" it goes on to is the idle shift after the operand)
    # - two beats of two bytes: the same two consumptions
    ex = operand_beats(4, 0, 16, ["OP0", "OP1", "OP2", "OP3"])
    expect([b["mask"] for b in ex] + [ex[-1]["mask_after"]] == ["100001", "000111", "011111"], "kernel 16-bit long: %s" % [b["mask"] for b in ex])
    return fails


# --------------------------------------------------------------- the output
def case_name(size):
    return {"instr": "instr", 1: "byte", 2: "word", 3: "3byte", 4: "long", 5: "bf5"}[size]


def rows():
    """One row per beat, as strings, plus the header."""
    hdr = ["case", "A1A0", "port", "oc", "beat", "of", "SIZ", "A1A0'", "n", "bytes", "lanes", "drive", "DSACK", "mask", "mask'", "last"]
    out = []
    for size, a1a0, port, ocs in cases():
        for beats in ocs:
            for i, b in enumerate(beats):
                oc = b["oc"]
                # what the processor drives on all four lanes (Table 7-5),
                # with the beat's bytes substituted for the OPn names
                # Table 7-5 names the bytes still to go OP(4-SIZ)..OP3, which
                # is what they are for a CPU operand; a bit field's bytes are
                # F0..F4, so map the last SIZ names of the cycle onto them
                siz_n = {"01": 1, "10": 2, "11": 3, "00": 4}[b["siz"]]
                drive = T75[(siz_n, b["a1a0"])].split()
                names = (["F0", "F1", "F2", "F3"] if size == 5 and oc == 0 else
                         ["F4"] if size == 5 else ["OP0", "OP1", "OP2", "OP3"])
                ren = {"OP%d" % (4 - siz_n + k): names[len(names) - siz_n + k] for k in range(siz_n)}
                drive = [ren.get(d.rstrip("*"), d.rstrip("*")) + ("*" if d.endswith("*") else "") for d in drive]
                out.append([
                    case_name(size), str(a1a0), str(port), str(oc), str(i + 1), str(len(beats)),
                    b["siz"], str(b["a1a0"]), str(b["n"]), "+".join(b["bytes"]),
                    "+".join(str(l) for l in b["lanes"]), " ".join(drive),
                    b["dsack"], b["mask"], b["mask_after"], "1" if b["last"] else "0",
                ])
    return hdr, out


HEADER = """\
# The 68030's bus beats - MC68030 UM 7.2, run by scripts/se30_bus_beats.py.
# SE30_PLAN.md 1.14.  Regenerate: python scripts/se30_bus_beats.py emit sim/kernel_bus/beats.txt
#
# One line per beat.  Columns:
#   case   byte/word/long: a CPU operand; 3byte: a bit field in 3 bytes;
#          bf5: a 32-bit bit field spanning 5 bytes, two operand cycles
#          (UM 11.6.14 note; long at A then byte at A+4 - order adopted
#          by the owner 2026-09-26): one five-byte mask, no beat crossing
#          the boundary after the fourth byte;
#          instr: an instruction prefetch, always a long at A1A0=00
#   A1A0   the operand's address offset in its longword
#   port   the port width the device answers on DSACK, 32 / 16 / 8
#   oc     operand cycle (0, or 1 for the beat of bf5's second)
#   beat   this beat's number within the operand cycle, of `of`
#   SIZ    SIZ1 SIZ0 driven: bytes remaining, Table 7-2 (00 = four)
#   A1A0'  A1 A0 driven on this beat
#   n      bytes the port takes on this beat
#   bytes  which bytes, in address order: OPn as UM Fig 7-3 (OP3 is the
#          least significant), Fn for a bit field's bytes
#   lanes  the lanes they ride: 0 = D31:24, 1 = D23:16, 2 = D15:8, 3 = D7:0
#          (Table 7-7 for the port; Table 7-4 on a read, Table 7-5 on a write)
#   drive  what the processor puts on lanes 0-3 on a write, Table 7-5 verbatim
#          (* = output but never used)
#   DSACK  DSACK1 DSACK0 the port asserts, Table 7-1
#   mask   the kernel's memmask before the beat: bit 4 = byte A, bit 3 = A+1,
#          ... bit 0 = A+4, active low; bit 5 always 1
#   mask'  after the beat: mask(5-n:0) & n ones - bit 5 then holds the byte
#          just consumed, as the kernel's own shift leaves it
#   last   1 on the operand cycle's final beat: mask' bits 4..0 all ones
#
"""


def emit(path):
    hdr, out = rows()
    widths = [max(len(h), max(len(r[i]) for r in out)) for i, h in enumerate(hdr)]
    with open(path, "w", newline="\n") as f:
        f.write(HEADER)
        f.write("  ".join(h.ljust(w) for h, w in zip(hdr, widths)).rstrip() + "\n")
        for r in out:
            f.write("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() + "\n")


def md():
    hdr, out = rows()
    print("| " + " | ".join(hdr) + " |")
    print("|" + "---|" * len(hdr))
    for r in out:
        print("| " + " | ".join(r) + " |")


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd == "check":
        fails = check()
        for f in fails:
            print("FAIL", f)
        n = sum(len(b) for _, _, _, ocs in cases() for b in ocs)
        print("%s: %d beats over %d cases, %d table entries, %d failures" % (
            "==== PASS" if not fails else "==== FAIL", n, len(cases()),
            len(T74) * 3 + len(T75) + sum(1 for r in T76.values() for c in r if c) * 3 + len(T77) * 3, len(fails)))
        return 1 if fails else 0
    if cmd == "emit":
        if check():
            print("tables and rule disagree; run check")
            return 1
        emit(argv[2])
        return 0
    if cmd == "md":
        md()
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
