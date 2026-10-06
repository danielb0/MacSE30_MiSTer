# Every thread record of an HFS catalog: its key, its record length, its
# fields.  An HFS thread (cdrThdRec / cdrFThdRec) is 46 bytes: type,
# reserved, 8 reserved, parent ID, a Str31 padded to 32 (IM: Files 2-88).
# python threads.py <image>
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from soak import unwrap, hfs_base, Vol, be16, be32

P = []
img = unwrap(open(sys.argv[1], "rb").read(), P)
V = img[hfs_base(img):]
v = Vol(V, P)
for r in v.leaves(v.read(v.extents(4, 0, v.ctext, v.ctsz), v.ctsz)):
    kl = r[0]; par = be32(r, 2); nm = r[7:7 + r[6]]
    p = 1 + kl; p += p & 1; t = r[p]
    if t in (3, 4):
        print("thread type %d key (cnid %d, name len %d) key length %d record length %d data length %d: parent %d name %r" %
              (t, par, r[6], kl, len(r), len(r) - p, be32(r, p + 10), r[p + 15:p + 15 + r[p + 14]]))
