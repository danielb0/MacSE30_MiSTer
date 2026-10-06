# The format census of an erased-then-written 1.44 MB HFS image: every
# 512-byte sector the volume does not use should still hold the ROM
# formatter's fill ($4082EC5E: 512 x F6).  python census.py <image>
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from soak import unwrap, hfs_base, Vol, be16, be32

P = []
V = unwrap(open(sys.argv[1], "rb").read(), P)
v = Vol(V[hfs_base(V):], P); v.audit()
nsec = len(V) // 512
bm = V[v.vbmst * 512:v.vbmst * 512 + (v.nmal + 7) // 8]
used = {b for b in range(v.nmal) if bm[b >> 3] & (0x80 >> (b & 7))}
spb = v.alsz // 512
owned = set()
for b in used:
    for k in range(spb): owned.add(v.alst + b * spb + k)
first_alloc, end_alloc = v.alst, v.alst + v.nmal * spb
kinds = {}
odd = []
for s in range(nsec):
    blk = V[s * 512:(s + 1) * 512]
    if s < first_alloc: zone = "system (boot, MDB, bitmap)"
    elif s >= end_alloc: zone = "after the allocation blocks"
    elif s in owned: zone = "in use"
    else: zone = "free"
    allf6 = blk == b"\xF6" * 512
    kinds.setdefault(zone, [0, 0])[0 if allf6 else 1] += 1
    if zone in ("free", "after the allocation blocks") and not allf6 and len(odd) < 12:
        odd.append((s, s // 36, (s // 18) % 2, s % 18 + 1, sorted(set(blk))[:6]))
print("volume '%s': %d sectors" % (v.name, nsec))
for z, (f6, other) in kinds.items():
    print("  %-30s %5d all F6, %5d other" % (z, f6, other))
for s, c, h, r, vals in odd:
    print("  not F6: sector %d (cylinder %d side %d R %d), byte values %s" % (s, c, h, r, vals))
