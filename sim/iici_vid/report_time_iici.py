#!/usr/bin/env python3
"""The IIci's timing windows (gen_time_iici.py, run.sh CACHE=11) against the
MC68030 User's Manual, Section 11 - the same model as sim/system's
report_time.py (its tables, part() and Equation 11-2 are imported), with
each window's wait states W taken from the cycles the bench measured in it
(reads and writes apart: a card hit is 2 clocks, W 0; an MDU read 5, W 3;
a write 4, W 2; the video's and the refresh's waits included).  So the
ratio isolates the CPU's pace from the memory, as the SE/30's report does.

    python report_time_iici.py [run.log]
Prints, per window: core clocks a turn, the 68030's (Eq. 11-2), the ratio
core / 68030 (below 1: the core runs it faster than a 68030 would).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "system"))
from report_time import part, cache_case   # noqa: E402

MARKER = 4                                  # the start marker's write, inside each window


def main():
    log = os.path.join(HERE, sys.argv[1] if len(sys.argv) > 1 else "run.log")
    win = {}
    for line in open(os.path.join(HERE, "tt_windows.txt")):
        k, turns, name = line.rstrip("\n").split(" ", 2)
        win[int(k)] = (int(turns), name)
    m = {}
    for line in open(log):
        g = re.search(r"---- tw (\d+) clk (\d+) reads (\d+) (\d+) writes (\d+) (\d+) hits (\d+)", line)
        if g:
            k, clk, nr, lr, nw, lw, h = map(int, g.groups())
            m[k] = dict(clk=clk, nr=nr, lr=lr, nw=nw, lw=lw, h=h)
    missing = [k for k in win if k not in m]
    if missing:
        sys.exit("windows missing from %s: %s" % (log, missing))

    print("%-3s %-44s %9s %9s %7s  %-6s %-6s %s" % ("w", "loop", "core/turn", "68030", "ratio", "W rd", "W wr", "data cycles (reads, of them card hits; writes)"))
    for k in sorted(win):
        turns, name = win[k]
        d = m[k]
        core = (d["clk"] / 2.0 - MARKER) / turns
        wr = d["lr"] / d["nr"] - 2 if d["nr"] else None
        ww = d["lw"] / d["nw"] - 2 if d["nw"] else None
        b = k % 20
        if b == 2:
            model = [part("DBcc loop")]
        elif b == 3:
            model = [part("ADD Rn,Dn"), part("LSd #,Dy"), part("MOVE Rn,Dn"), part("SUB Rn,Dn"), part("DBcc loop")]
        elif b == 4:
            model = [part("MOVE Rn,(An)+", write_w=ww), part("DBcc loop")]
        elif b == 5:
            model = [part("fea (An)+", read_w=wr), part("MOVE EA,Dn"), part("DBcc loop")]
        elif b == 6:
            model = [part("fea (An)+", read_w=wr), part("MOVE SRC,(An)+", write_w=ww), part("DBcc loop")]
        elif b == 7:
            model = ([part("fea (An)+", read_w=wr), part("MOVE SRC,(An)+", write_w=ww)] * 8
                     + [part("SUB Rn,Dn"), part("Bcc taken")])
        elif b == 15:
            model = [part("SUBQ #,Rn"), part("Bcc taken")]
        elif b == 16:
            model = [part("TST Dn"), part("Bcc.B not taken"), part("MOVE Rn,Dn"), part("DBcc loop")]
        elif b == 17:
            model = [part("fea (d8,An,Xn)", read_w=wr), part("MOVE EA,Dn"), part("DBcc loop")]
        ref = cache_case(model)
        print("%-3d %-44s %9.2f %9.2f %7.3f  %-6s %-6s %d (%d), %d" % (
            k, name, core, ref, core / ref,
            "%.2f" % wr if wr is not None else "-", "%.2f" % ww if ww is not None else "-",
            d["nr"], d["h"], d["nw"]))


if __name__ == "__main__":
    main()
