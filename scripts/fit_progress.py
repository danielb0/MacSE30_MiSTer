#!/usr/bin/env python3
"""scripts/fit_progress.py - a compile's progress, readable while it runs and
after it is stopped (2026-10-19: a stopped quartus_fit loses the console
messages it has buffered, and its reports are written only at the end).

Quartus keeps each stage's messages in db/<rev>.<stage>.qmsg and updates
that file every few minutes and at phase boundaries.  This decodes the
four stages' message files (map, fit, sta, asm) into one readable log -
every warning, critical warning and error, and the progress lines (phase
timings, the router's estimates and congestion) - appending what is new.

    python scripts/fit_progress.py <rev> [<log>]          once
    python scripts/fit_progress.py <rev> <log> --watch     every 60 s until
                                                           output_files/.compile_in_progress goes

build_only.sh runs the second form beside the compile; the log is
output_files/build_<stamp>_progress.log.
"""
import os
import re
import sys
import time

STAGES = ("map", "fit", "sta", "asm")
REC = re.compile(rb'\{ "(Info|Extra Info|Warning|Critical Warning|Error)" "([A-Z0-9_]+)" "((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)"')
PROGRESS = ("elapsed time", "Router estimated", "routing", "placement", "Processing started",
            "Processing ended", "was successful", "unsuccessful", "Implemented", "congestion", "peak interconnect")


def messages(rev):
    out = []
    for st in STAGES:
        p = os.path.join("db", "%s.%s.qmsg" % (rev, st))
        try:
            d = open(p, "rb").read()
        except OSError:
            continue
        for m in REC.finditer(d):
            sev, mid, _, text = (x.decode("latin-1") for x in m.groups())
            if sev in ("Warning", "Critical Warning", "Error") or any(k in text for k in PROGRESS):
                out.append("%-4s %-16s %s" % (st, sev, text))
    return out


def main():
    rev = sys.argv[1]
    log = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else None
    watch = "--watch" in sys.argv
    seen = 0
    while True:
        lines = messages(rev)
        new = lines[seen:] if len(lines) >= seen else lines   # a stage restarted: write it again
        if new:
            stamp = time.strftime("[%H:%M:%S]")
            text = "".join("%s %s\n" % (stamp, l) for l in new)
            if log:
                with open(log, "a", encoding="utf-8") as f:
                    f.write(text)
            else:
                sys.stdout.write(text)
            seen = len(lines)
        if not watch or not os.path.exists(os.path.join("output_files", ".compile_in_progress")):
            break
        time.sleep(60)


if __name__ == "__main__":
    main()
