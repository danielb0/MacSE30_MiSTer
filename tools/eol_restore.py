#!/usr/bin/env python3
"""eol_restore.py FILE [REV] - give FILE back the line endings it has at REV
(default HEAD), line by line.

For files with MIXED endings (rtl/scsi.v came from the MacPlus core with 177
LF-only lines among CRLF ones): an editor that rewrites every line's ending
makes the whole file a diff.  Lines that match a line of the committed file
(difflib's equal blocks) take that line's ending back; new and changed lines
take NEW (default CRLF, the file's majority).  The result's diff against REV
is the real edits only.
"""
import difflib
import subprocess
import sys

path = sys.argv[1]
rev = sys.argv[2] if len(sys.argv) > 2 else "HEAD"
new_eol = b"\r\n"

old = subprocess.run(["git", "show", "%s:%s" % (rev, path)], capture_output=True, check=True).stdout
cur = open(path, "rb").read()


def split(data):
    """[(text without its ending, ending)]; the last line may have none."""
    out = []
    for ln in data.split(b"\n"):
        out.append((ln[:-1], b"\r\n") if ln.endswith(b"\r") else (ln, b"\n"))
    if data.endswith(b"\n"):
        out.pop()                      # split leaves an empty tail after the last newline
    else:
        out[-1] = (out[-1][0], b"")
    return out


o = split(old)
c = split(cur)
sm = difflib.SequenceMatcher(a=[t for t, _ in o], b=[t for t, _ in c], autojunk=False)
eol = [new_eol] * len(c)
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "equal":
        for k in range(i2 - i1):
            eol[j1 + k] = o[i1 + k][1]
if c and c[-1][1] == b"":
    eol[-1] = o[-1][1] if o else b""
open(path, "wb").write(b"".join(t + e for (t, _), e in zip(c, eol)))
kept = sum(i2 - i1 for tag, i1, i2, j1, j2 in sm.get_opcodes() if tag == "equal")
print("%s: %d lines, %d kept from %s, %d new/changed" % (path, len(c), kept, rev, len(c) - kept))
