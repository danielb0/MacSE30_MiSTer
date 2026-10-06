# Sanity of every catalog node of an HFS image: the record-offset table at
# the node's end (in a DC42's last 84 bytes of a sector, the next FILE
# block) and the records it points at.  python node_check.py <image>
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from soak import unwrap, hfs_base, Vol, be16, be32

P = []
img = unwrap(open(sys.argv[1], "rb").read(), P)
V = img[hfs_base(img):]
v = Vol(V, P)
blocks = []
for st, c in v.extents(4, 0, v.ctext, v.ctsz):
    for k in range(c * v.alsz // 512): blocks.append(v.alst + st * v.alsz // 512 + k)
for n, b in enumerate(blocks):
    nd = V[b * 512:(b + 1) * 512]
    kind, cnt = nd[8], be16(nd, 10)
    if kind not in (0x00, 0x01, 0x02, 0xFF) or (kind == 0 and cnt == 0 and len(set(nd)) == 1): continue
    offs = [be16(nd, 512 - 2 * (i + 1)) for i in range(cnt + 1)]
    bad = [o for o in offs if o < 14 or o > 512 - 2 * (cnt + 1)]
    mono = all(offs[i] < offs[i + 1] for i in range(cnt))
    keys_ok = True
    for i in range(cnt):
        r = nd[offs[i]:offs[i + 1]] if not bad and mono else b""
        if r and (r[0] < 6 or r[0] > 37 or len(r) < r[0] + 2): keys_ok = False
    flag = "" if (not bad and mono and keys_ok) else "  <-- BAD: offsets %s%s%s" % (offs, "" if mono else " not increasing", "" if keys_ok else ", a key out of range")
    print("node %2d image block %4d (file blocks %d/%d) kind %02X recs %d%s" % (n, b, b, b + 1, kind, cnt, flag))
