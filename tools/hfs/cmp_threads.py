"""Read-only: compare two images of the same HFS volume (before, after) and
list the after image's orphan file threads with what the before image had
(the file, its thread, its thread-exists flag), the threads made since,
and the before image's threads now gone. Uses hfs_threads.py beside it.
Usage: python cmp_threads.py before.vhd after.vhd  (SE30_PLAN.md 10.4)"""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
import sys
src = open(os.path.join(HERE, "hfs_threads.py")).read().replace("\nmain()\n", "\n")
ns = {}; exec(compile(src, "hfs_threads.py", "exec"), ns)
def load(p):
    with open(p, "rb") as f:
        for base, size, desc in ns["partitions"](f):
            c = ns["catalog"](f, base)
            if c: return c[2], ns["walk"](c[1])
mb, b = load(sys.argv[1]); ma, a = load(sys.argv[2])
print("backup nxtCNID %d, after nxtCNID %d" % (mb["nxtCNID"], ma["nxtCNID"]))
print("backup file threads: %s" % sorted(b["fthreads"]))
orph = sorted(f for f in a["fthreads"] if f not in a["files"])
print("%-6s %-32s %-22s %-12s %s" % ("ID", "name", "in backup as file?", "thread then?", "thread-exists flag then"))
for f in orph:
    nm = a["fthreads"][f][1]
    fb = b["files"].get(f)
    print("%-6d %-32s %-22s %-12s %s" % (f, nm, "yes" if fb else ("no (new, ID >= %d)" % mb["nxtCNID"] if f >= mb["nxtCNID"] else "no"),
          "yes" if f in b["fthreads"] else "no", ("set" if fb and fb[2] & 2 else ("clear" if fb else "-"))))
new_valid = sorted(f for f in a["fthreads"] if f in a["files"] and f not in b["fthreads"])
print("threads made since the backup, file still present: %s" % [(f, a["files"][f][1]) for f in new_valid])
gone = sorted(f for f in b["fthreads"] if f not in a["fthreads"])
print("backup threads now gone (deleted properly): %s" % [(f, b["fthreads"][f][1]) for f in gone])
