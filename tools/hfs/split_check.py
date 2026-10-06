# Test the SD writer's dedupe race on a written DC42 (plan 5.16.8 gate 3):
# every 512-byte sector of the source's file data is looked for in the
# written payload by its LAST 84 bytes (which reach the card in the next
# file block); for each one found, are its FIRST 428 bytes right too?
# python split_check.py <written dc42> <source image>
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from soak import unwrap, hfs_base, Vol

def payload(p):
    P = []; return unwrap(open(p, "rb").read(), P)

W = payload(sys.argv[1]); S = payload(sys.argv[2])
v = Vol(S[hfs_base(S):], []); v.audit()
tail = {}
for s in range(len(W) // 512):
    t = W[s * 512 + 428:(s + 1) * 512]
    if len(set(t)) > 4: tail.setdefault(t, []).append(s)
whole = head_bad = notfound = 0
runs = []
for fid, (par, nm, t, c, dl, rl, de, re_) in v.files.items():
    for ft, ext, ln in ((0, de, dl), (0xFF, re_, rl)):
        data = v.read(v.extents(fid, ft, ext, ln), ln)
        for k in range(len(data) // 512):
            sec = data[k * 512:(k + 1) * 512]
            t = sec[428:]
            if len(set(t)) <= 4: continue
            hits = tail.get(t, [])
            if not hits: notfound += 1; continue
            s = hits[0]
            if W[s * 512:s * 512 + 428] == sec[:428]: whole += 1
            else:
                head_bad += 1
                if len(runs) < 10: runs.append((nm, ft, k, s))
print("source sectors located by their last 84 bytes: %d whole, %d with the first 428 bytes wrong, %d not found" % (whole, head_bad, notfound))
for r in runs: print("  head wrong: %s fork %02X sector %d at written sector %d" % r)
