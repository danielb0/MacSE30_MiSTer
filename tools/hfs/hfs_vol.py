"""Read-only HFS consistency check of the first HFS partition of a disk image:
the catalog's parent links and threads, every fork's extents (first three
from the catalog, the rest from the extents overflow B-tree) against the
volume bitmap - overlaps, blocks in use but free in the bitmap, blocks set in
the bitmap that nothing owns - and the MDB's counts.
Usage: python hfs_vol.py image"""
import sys, struct

def be16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def be32(b, o): return struct.unpack(">I", b[o:o+4])[0]

img = open(sys.argv[1], "rb").read()
base = 0
if img[512:514] == b"PM":
    for i in range(be32(img, 512 + 4)):
        e = img[512 * (1 + i):512 * (2 + i)]
        if e[48:80].split(b"\0")[0] == b"Apple_HFS":
            base = be32(e, 8) * 512; break
V = img[base:]
m = V[1024:1024 + 162]
assert be16(m, 0) == 0x4244
vbmst, nmal, alsz, alst, free = be16(m, 14), be16(m, 18), be32(m, 20), be16(m, 28), be16(m, 34)
name = m[37:37 + m[36]].decode("mac-roman")
xtsz, ctsz = be32(m, 130), be32(m, 146)
xtext = [(be16(m, 134 + 4 * i), be16(m, 136 + 4 * i)) for i in range(3)]
ctext = [(be16(m, 150 + 4 * i), be16(m, 152 + 4 * i)) for i in range(3)]
print("volume '%s': %d allocation blocks of %d, %d free per MDB" % (name, nmal, alsz, free))

def ab(n): return alst * 512 + n * alsz
def fork(ext, size):
    d = b""
    for st, c in ext:
        if c: d += V[ab(st):ab(st) + c * alsz]
    return d[:size]

def leaves(tree):
    ns = be16(tree, 14 + 18); n = be32(tree, 14 + 10); seen = set()
    while n and n not in seen:
        seen.add(n)
        nd = tree[n * ns:(n + 1) * ns]
        if nd[8] != 0xFF: print("  non-leaf node %d in a leaf chain" % n); return
        cnt = be16(nd, 10)
        offs = [be16(nd, ns - 2 * (i + 1)) for i in range(cnt + 1)]
        for i in range(cnt):
            yield n, nd[offs[i]:offs[i + 1]]
        n = be32(nd, 0)

owner = {}                                    # allocation block -> owner
problems = []
def own(ext, who):
    for st, c in ext:
        for b in range(st, st + c):
            if b in owner: problems.append("block %d owned by both %s and %s" % (b, owner[b], who))
            owner[b] = who

own(xtext, "extents file"); own(ctext, "catalog file")
# extents overflow
xt = fork(xtext, xtsz)
over = {}
for n, r in leaves(xt):
    ftype, fid, sblk = r[1], be32(r, 2), be16(r, 6)
    ext = [(be16(r, 8 + 4 * i), be16(r, 10 + 4 * i)) for i in range(3)]
    over.setdefault((fid, ftype), []).append((sblk, ext))
for (fid, ftype), lst in over.items():
    for sblk, ext in lst:
        own(ext, "overflow of file %d fork %02X" % (fid, ftype))

ct = fork(ctext, ctsz)
files, dirs, dthr, fthr = {}, {}, {}, {}
for n, r in leaves(ct):
    kl = r[0]; par = be32(r, 2); nm = r[7:7 + r[6]].decode("mac-roman", "replace")
    p = 1 + kl; p += p & 1; t = r[p]
    if t == 2:
        fid = be32(r, p + 20)
        files[fid] = (par, nm)
        own([(be16(r, p + 74 + 4 * i), be16(r, p + 76 + 4 * i)) for i in range(3)], "file %d '%s' data" % (fid, nm))
        own([(be16(r, p + 86 + 4 * i), be16(r, p + 88 + 4 * i)) for i in range(3)], "file %d '%s' rsrc" % (fid, nm))
    elif t == 1: dirs[be32(r, p + 6)] = (par, nm)
    elif t == 3: dthr[par] = (be32(r, p + 10), r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace"))
    elif t == 4: fthr[par] = (be32(r, p + 10), r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace"))

for fid, (par, nm) in files.items():
    if par not in dirs: problems.append("file %d '%s': parent %d missing" % (fid, nm, par))
for did, (par, nm) in dirs.items():
    if did != 2 and par not in dirs: problems.append("folder %d '%s': parent %d missing" % (did, nm, par))
    if did not in dthr: problems.append("folder %d '%s': no thread" % (did, nm))
    elif dthr[did] != (par, nm): problems.append("folder %d '%s': thread says %s" % (did, nm, dthr[did]))
for did in dthr:
    if did not in dirs: problems.append("folder thread %d %s: no folder record" % (did, dthr[did]))
for fid, v in fthr.items():
    if fid not in files: problems.append("file thread %d %s: no file record" % (fid, v))
    elif files[fid] != v: problems.append("file thread %d %s: file record says %s" % (fid, v, files[fid]))

bm = V[vbmst * 512: vbmst * 512 + (nmal + 7) // 8]
setb = {b for b in range(nmal) if bm[b >> 3] & (0x80 >> (b & 7))}
used_free = sorted(b for b in owner if b not in setb)
set_unowned = sorted(b for b in setb if b not in owner)
if used_free: problems.append("%d blocks in use but free in the bitmap, e.g. %s (%s)" % (len(used_free), used_free[:5], owner[used_free[0]]))
if set_unowned: problems.append("%d blocks set in the bitmap that nothing owns, e.g. %s" % (len(set_unowned), set_unowned[:8]))
if nmal - len(setb) != free: problems.append("MDB free %d, bitmap free %d" % (free, nmal - len(setb)))
print("files %d, folders %d, file threads %d, folder threads %d, blocks in use %d (bitmap %d)"
      % (len(files), len(dirs), len(fthr), len(dthr), len(owner), len(setb)))
print("PROBLEMS: %d" % len(problems))
for p in problems: print("  " + p)
