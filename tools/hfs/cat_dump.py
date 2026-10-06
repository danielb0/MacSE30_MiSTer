# Dump an HFS volume's catalog B-tree node by node: where each node sits in
# the image, its descriptor, and whether its bytes are all one value (never
# written since a format).  python cat_dump.py <image>
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from soak import unwrap, hfs_base, be16, be32

P = []
img = unwrap(open(sys.argv[1], "rb").read(), P)
V = img[hfs_base(img):]
m = V[1024:1024 + 162]
alst, alsz = be16(m, 28), be32(m, 20)
print("MDB: alloc start %d, alloc size %d, files %d, dirs %d, free %d, write count %d, modified %08X" %
      (alst, alsz, be32(m, 84), be32(m, 88), be16(m, 34), be32(m, 70), be32(m, 6)))
for nm, so, eo in (("extents", 130, 134), ("catalog", 146, 150)):
    size = be32(m, so)
    ext = [(be16(m, eo + 4 * i), be16(m, eo + 2 + 4 * i)) for i in range(3)]
    print("%s file: %d bytes, extents %s" % (nm, size, ext))
    blocks = []
    for st, c in ext:
        for k in range(c * alsz // 512):
            blocks.append(alst + st * alsz // 512 + k)
    hdr = V[blocks[0] * 512:(blocks[0] + 1) * 512]
    print("  header: depth %d root %d leafrecs %d first leaf %d last leaf %d nodesize %d maxkey %d total %d free %d" %
          (be16(hdr, 14), be32(hdr, 16), be32(hdr, 20), be32(hdr, 24), be32(hdr, 28), be16(hdr, 32),
           be16(hdr, 34), be32(hdr, 36), be32(hdr, 40)))
    if nm == "catalog":
        from soak import Vol
        v = Vol(V, [])
        print("  overflow records:", v.over)
        blocks = []
        for st, c in v.extents(4, 0, v.ctext, v.ctsz):
            for k in range(c * alsz // 512):
                blocks.append(alst + st * alsz // 512 + k)
    for n, b in enumerate(blocks):
        nd = V[b * 512:(b + 1) * 512]
        uni = len(set(nd)) == 1
        kind = struct.unpack_from(">b", nd, 8)[0]
        print("  node %3d at image block %4d: %s flink %d blink %d kind %d height %d recs %d" %
              (n, b, ("ALL %02X" % nd[0]) if uni else "      ", be32(nd, 0), be32(nd, 4), kind, nd[9], be16(nd, 10)))
        if n > 40: break
