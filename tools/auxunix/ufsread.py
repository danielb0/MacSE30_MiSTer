# Read-only 4.2BSD FFS reader for the A/UX root slice (big-endian).
# usage: ufsread.py IMG ls PATH | get PATH OUT
import sys, struct

IMG, CMD, PATH = sys.argv[1], sys.argv[2], sys.argv[3]
PART = 96 * 512
f = open(IMG, 'rb')

def rd(off, n):
    f.seek(PART + off)
    return f.read(n)

sb = rd(8192, 2048)
L = lambda o: struct.unpack('>i', sb[o:o + 4])[0]
sblkno, cblkno, iblkno, dblkno = L(8), L(12), L(16), L(20)
cgoffset, cgmask = L(24), L(28)
bsize, fsize, frag = L(48), L(52), L(56)
nindir, inopb = L(116), L(120)
ipg, fpg = L(184), L(188)

def cgstart(c):
    return fpg * c + cgoffset * (c & ~cgmask)

def inode(ino):
    c = ino // ipg
    fr = cgstart(c) + iblkno + ((ino % ipg) // inopb) * frag
    off = fr * fsize + (ino % inopb) * 128
    return rd(off, 128)

def blocks(di):
    size = struct.unpack('>I', di[12:16])[0]
    db = list(struct.unpack('>12i', di[40:88]))
    ib = list(struct.unpack('>3i', di[88:100]))
    out = db[:]
    def ind(b, lvl):
        if b == 0:
            return [0] * (nindir ** (lvl + 1))
        p = list(struct.unpack('>%di' % nindir, rd(b * fsize, bsize)))
        if lvl == 0:
            return p
        r = []
        for q in p:
            r += ind(q, lvl - 1)
        return r
    need = (size + bsize - 1) // bsize
    lvl = 0
    while len(out) < need and lvl < 3:
        out += ind(ib[lvl], lvl)
        lvl += 1
    return size, out[:need]

def read_file(ino):
    di = inode(ino)
    size, bl = blocks(di)
    data = bytearray()
    for b in bl:
        data += rd(b * fsize, bsize) if b else bytes(bsize)
    return di, bytes(data[:size])

def readdir(ino):
    _, d = read_file(ino)
    ents, p = [], 0
    while p < len(d):
        i, rl, nl = struct.unpack('>IHH', d[p:p + 8])
        if rl == 0:
            p = (p // 512 + 1) * 512
            continue
        if i:
            ents.append((d[p + 8:p + 8 + nl].decode('latin1'), i))
        p += rl
    return ents

def lookup(path):
    ino = 2
    for part in [x for x in path.split('/') if x]:
        m = dict(readdir(ino))
        ino = m[part]
    return ino

ino = lookup(PATH)
if CMD == 'ls':
    for n, i in sorted(readdir(ino)):
        di = inode(i)
        mode = struct.unpack('>H', di[0:2])[0]
        size = struct.unpack('>I', di[12:16])[0]
        print('%06o %10d %s' % (mode, size, n))
else:
    di, data = read_file(ino)
    open(sys.argv[4], 'wb').write(data)
    print('wrote', len(data))
