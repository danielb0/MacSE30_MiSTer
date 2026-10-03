#!/usr/bin/env python3
"""The timetest report (SE30_PLAN.md 1.17): each window's clocks on the
core, from run_timetest.log, against the MC68030 User's Manual, 3rd ed.
(1990), Section 11, for the same loop on the same bus.

THE MANUAL'S MODEL (UM 11.3-11.6; the tables read from the page images)
  Cache case (the instruction cache on): Equation 11-2 - each part's
  instruction-cache-case time (CC) less the overlap with the part before,
  min(head of this part, tail of the last):
      t = CC1 + sum over i>1 of [CCi - min(Hi, Ti-1)]
  The tables assume two-clock bus cycles; UM 11.5 adds wait states:
      rule 1a  a fetch-EA part with an operand read: W to its tail and CC;
      rule 3a  an operation part with a write: W to its tail and CC.
  W is the cycle's clocks less the tables' two.  An operand on an 8-bit
  port takes four byte cycles (dynamic sizing, UM 7.2), so its W is all
  four cycles' clocks less two.  The SE/30's cycle lengths: RAM 4 (the
  Guide's one wait state), ASC 5 read / 4 write, the SCSI DACK port 4 a
  byte; the video RAM's come from the bench's own measured cycles, which
  are the video PALs' (plan 2.12) - so the comparison isolates the CPU.

  No-cache case (the instruction cache off): the tables' average
  no-cache-case time (NCC), with UM 11.5's formula for wait states:
      NCC = NCCt + (data reads and writes) x W + (instruction accesses) x W
  The manual calls this "equal to or greater than the actual" (the access
  counts are rounded up, no overlap).  A lower estimate is given beside it:
  the internal clocks the tables imply (NCCt less two per listed access)
  plus the bus clocks the core itself ran in the window (its fetch count
  matches a 68030's for these loops - each taken branch refills the pipe
  with two long fetches, UM 11.2.2).

Prints one row per window: core clocks a turn, the 68030 figure, and the
ratio core/68030 (below 1 = the core runs it faster than a 68030 would).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
C16M = 15.6672e6

# ---------------------------------------------------------------- the tables
# (head, tail, CC, NCC, reads, instruction accesses, writes), UM 11.6
T = {
    # 11.6.1 fetch effective address (p. 11-26)
    "fea (An)":         (1, 1, 3, 3, 1, 0, 0),
    "fea (An)+":        (0, 1, 3, 3, 1, 0, 0),
    # 11.6.6 MOVE (p. 11-37)
    "MOVE Rn,Dn":       (2, 0, 2, 2, 0, 1, 0),
    "MOVE Rn,An":       (2, 0, 2, 2, 0, 1, 0),
    "MOVE EA,Dn":       (0, 0, 2, 2, 0, 1, 0),
    "MOVE Rn,(An)":     (0, 1, 3, 4, 0, 1, 1),
    "MOVE Rn,(An)+":    (0, 1, 3, 4, 0, 1, 1),
    "MOVE SRC,(An)":    (2, 0, 4, 5, 0, 1, 1),
    "MOVE SRC,(An)+":   (2, 0, 4, 5, 0, 1, 1),
    "MOVE EA,(d16,An)": (2, 0, 4, 5, 0, 1, 1),
    # 11.6.8 arithmetic/logical (pp. 11-40, 11-41)
    "ADD Rn,Dn":        (2, 0, 2, 2, 0, 1, 0),
    "ADD EA,Dn":        (0, 0, 2, 2, 0, 1, 0),
    "SUB Rn,Dn":        (2, 0, 2, 2, 0, 1, 0),
    "CMPA Rn,An":       (4, 0, 4, 4, 0, 1, 0),
    # 11.6.9 immediate arithmetic (p. 11-42)
    "ADDQ #,Rn":        (2, 0, 2, 2, 0, 1, 0),
    "SUBQ #,Rn":        (2, 0, 2, 2, 0, 1, 0),
    # 11.6.11 single operand (p. 11-44)
    "TST Dn":           (0, 0, 2, 2, 0, 1, 0),
    # 11.6.12 shift/rotate (p. 11-45)
    "LSd #,Dy":         (4, 0, 4, 4, 0, 1, 0),
    "ROXd Dn":          (10, 0, 12, 12, 0, 1, 0),
    # 11.6.15 conditional branch (p. 11-48)
    "Bcc taken":        (6, 0, 6, 8, 0, 2, 0),
    "Bcc.B not taken":  (4, 0, 4, 4, 0, 1, 0),
    "DBcc loop":        (6, 0, 6, 8, 0, 2, 0),     # cc false, count not expired
}


def part(name, read_w=None, write_w=None):
    """A table entry with UM 11.5's wait states: read_w on a fetch-EA part
    (rule 1a), write_w on an operation part that writes (rule 3a)."""
    h, t, cc, ncc, r, p, w = T[name]
    if read_w is not None:
        assert r == 1 and name.startswith("fea")
        t, cc = t + read_w, cc + read_w
    if write_w is not None:
        assert w == 1
        t, cc = t + write_w, cc + write_w
    return (h, t, cc)


def cache_case(turn, turns=50):
    """Equation 11-2 over `turns` repetitions of a turn's parts, per turn
    (the steady state: the first turn's lack of a predecessor removed)."""
    seq = turn * turns
    total = seq[0][2]
    for prev, cur in zip(seq, seq[1:]):
        total += cur[2] - min(cur[0], prev[1])
    first = turn[0][2] - min(turn[0][0], turn[-1][1])           # as if preceded by the last turn
    return (total - seq[0][2] + first) / turns


def no_cache(instrs, wait_instr, data_waits):
    """UM 11.5's no-cache formula: instrs = [(name, count)], data_waits =
    the W of each data access in a turn (summed).  Returns (NCC with
    waits, internal clocks the tables imply)."""
    ncc = acc = internal = 0
    for name, n in instrs:
        h, t, cc, nc, r, p, w = T[name]
        ncc += n * nc
        acc += n * p
        internal += n * (nc - 2 * (r + p + w))
    return ncc + acc * wait_instr + data_waits, internal


def main():
    log = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1 else "run_timetest.log")
    win = {}
    for line in open(os.path.join(HERE, "timetest", "windows.txt")):
        k, turns, name = line.rstrip("\n").split(" ", 2)
        win[int(k)] = (int(turns), name)
    m = {}
    for line in open(log):
        g = re.search(r"---- tw (\d+) clocks (\d+) fetch (\d+) (\d+) data (\d+) (\d+) hits (\d+)", line)
        if g:
            k, clk, nf, lf, nd, ld, h = map(int, g.groups())
            # each window holds the start marker's write, 4 clocks (and the
            # end marker's read too before plan 1.17.2's fix, when CLR read
            # its destination: two data cycles in a window with none of its own)
            m[k] = dict(clk=clk, nf=nf, lf=lf, nd=nd, ld=ld, h=h)
    # the marker cycles: two per window before the fix, one after - read off
    # window 0, which has no data cycle of its own
    mk = m[0]["nd"] if 0 in m else 1
    for k in m:
        m[k].update(clk=m[k]["clk"] - 4 * mk, nd=m[k]["nd"] - mk, ld=m[k]["ld"] - 4 * mk)
    missing = [k for k in win if k not in m]
    if missing:
        sys.exit("windows missing from %s: %s" % (log, missing))

    RAM = 4 - 2                               # the Guide's one wait state: a 4-clock cycle
    def per(k): return m[k]["clk"] / win[k][0]

    rows = []
    # 0: DBRA alone, uncached
    hi, internal = no_cache([("DBcc loop", 1)], RAM, 0)
    lo = internal + m[0]["lf"] / win[0][0]
    rows.append((0, per(0), lo, hi, "no-cache: %d internal + the bus; NCC formula %d" % (internal, hi)))
    # 1: the chime pass, uncached; ASC reads 5 clocks (W 3), writes 4 (W 2)
    chime = [("fea (An)", 1), ("MOVE EA,Dn", 1),        # move.b (a0),d7
             ("MOVE Rn,An", 1),                         # movea.l a0,a2
             ("ADDQ #,Rn", 1),                          # addq.w #1,a0
             ("CMPA Rn,An", 1),                         # cmpa.l a0,a1
             ("Bcc taken", 1),                          # bhi (511 passes in 512)
             ("fea (An)", 1), ("ADD EA,Dn", 1),         # add.b (a0),d7
             ("ROXd Dn", 1),                            # roxr.b #1,d7
             ("MOVE EA,(d16,An)", 3),                   # move.b d7,$600/$400/$200(a0)
             ("MOVE Rn,(An)", 1),                       # move.b d7,(a0)
             ("MOVE Rn,Dn", 1),                         # move.w d0,d4
             ("SUBQ #,Rn", 36), ("Bcc taken", 35), ("Bcc.B not taken", 1),   # the delay
             ("TST Dn", 1), ("Bcc taken", 1),           # tst.w d3; beq
             ("DBcc loop", 1)]                          # dbra d2
    hi, internal = no_cache(chime, RAM, 2 * 3 + 4 * 2)
    lo = internal + (m[1]["lf"] + m[1]["ld"]) / win[1][0]
    rows.append((1, per(1), lo, hi, "no-cache: %d internal + the bus; NCC formula %d" % (internal, hi)))
    def cached_rows(b):
        """windows b..b+9: 2-11's loops (b = 2), or the same under the PMMU (b = 12)"""
        # DBRA alone, cached
        rows.append((b, per(b), cache_case([part("DBcc loop")]), None, "Eq. 11-2"))
        # register-only
        rows.append((b + 1, per(b + 1), cache_case([part("ADD Rn,Dn"), part("LSd #,Dy"), part("MOVE Rn,Dn"),
                                                    part("SUB Rn,Dn"), part("DBcc loop")]), None, "Eq. 11-2"))
        # RAM
        rows.append((b + 2, per(b + 2), cache_case([part("MOVE Rn,(An)+", write_w=RAM), part("DBcc loop")]), None, "Eq. 11-2, W 2"))
        rows.append((b + 3, per(b + 3), cache_case([part("fea (An)+", read_w=RAM), part("MOVE EA,Dn"), part("DBcc loop")]), None, "Eq. 11-2, W 2"))
        rows.append((b + 4, per(b + 4), cache_case([part("fea (An)+", read_w=RAM), part("MOVE SRC,(An)+", write_w=RAM),
                                                    part("DBcc loop")]), None, "Eq. 11-2, W 2"))
        # the video RAM, its cycles as the bench measured them
        vl = m[b + 5]["ld"] / m[b + 5]["nd"]  # clocks a byte cycle
        rows.append((b + 5, per(b + 5), cache_case([part("MOVE Rn,(An)+", write_w=4 * vl - 2), part("DBcc loop")]), None,
                     "Eq. 11-2, byte cycles %.2f measured" % vl))
        vb = m[b + 6]["ld"] / m[b + 6]["nd"]
        rows.append((b + 6, per(b + 6), cache_case([part("MOVE Rn,(An)+", write_w=vb - 2), part("DBcc loop")]), None,
                     "Eq. 11-2, byte cycles %.2f measured" % vb))
        v9 = (m[b + 7]["ld"] - 4 * 500) / (m[b + 7]["nd"] - 500)
        rows.append((b + 7, per(b + 7), cache_case([part("fea (An)+", read_w=RAM), part("MOVE SRC,(An)+", write_w=4 * v9 - 2),
                                                    part("DBcc loop")]), None, "Eq. 11-2, byte cycles %.2f measured" % v9))
        # SCSI blind, a long through the 8-bit DACK port = four 4-clock cycles
        SC = 4 * 4 - 2
        rows.append((b + 8, per(b + 8), cache_case([part("fea (An)", read_w=SC), part("MOVE SRC,(An)+", write_w=RAM)] * 8
                                                   + [part("DBcc loop")]), None, "Eq. 11-2, port W 14, RAM W 2"))
        rows.append((b + 9, per(b + 9), cache_case([part("fea (An)+", read_w=RAM), part("MOVE SRC,(An)", write_w=SC)] * 8
                                                   + [part("DBcc loop")]), None, "Eq. 11-2, RAM W 2, port W 14"))
    cached_rows(2)
    if 12 in win:
        cached_rows(12)                       # an ATC hit costs a 68030 nothing (UM 11.2.6)

    print("%-3s %-88s %9s %15s %11s  %s" % ("w", "loop", "core/turn", "68030/turn", "core/68030", "basis"))
    for k, core, lo, hi, basis in rows:
        name = win[k][1]
        if hi is None:
            print("%-3d %-88s %9.2f %15.2f %11.2f  %s" % (k, name, core, lo, core / lo, basis))
        else:
            print("%-3d %-88s %9.2f %7.1f-%-7.1f %5.2f-%-5.2f  %s" % (k, name, core, lo, hi, core / hi, core / lo, basis))
    c = per(1)
    lo, hi = rows[1][2], rows[1][3]
    print("\nthe chime: 30,000 passes = %.2f s on the core, %.2f-%.2f s on a 68030 by the manual"
          % (30000 * c / C16M, 30000 * lo / C16M, 30000 * hi / C16M))
    for k in (10, 11):
        print("SCSI %s: core %.2f MB/s, 68030 %.2f MB/s (32 bytes a turn, DRQ never stalling)"
              % ("read " if k == 10 else "write", 32 * C16M / per(k) / 1e6, 32 * C16M / rows[k][2] / 1e6))


if __name__ == "__main__":
    main()
