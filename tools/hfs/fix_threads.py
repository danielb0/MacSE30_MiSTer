#!/usr/bin/env python3
"""Make a machfs-written HFS floppy one the Finder lists.  machfs leaves the
volume's and the root folder's dates at 0 and the root folder's window
rectangle (DInfo frRect) empty: A/UX 3.1's Mac environment shows such a
volume as "N K in disk, 0 items" (fpstress.img 2026-10-17, MacsBug and
pressure floppies 2026-10-22).  This sets the MDB's drCrDate/drLsMod, the
root folder's dirCrDat/dirMdDat (now) and its frRect (60,40)-(260,420) -
fpstress2.img's fix, proven on the board.

--threads also makes the catalog regular for Disk First Aid: machfs sizes
thread records to their names (22-30 data bytes) where HFS has a fixed 46
(Inside Macintosh: Files 2-88); this pads the folder threads to 46, drops the
optional file threads (clearing filFlags bit 1, as Apple's own volumes have
none) and repacks the leaf - a single-leaf catalog only.

    python fix_threads.py [--threads] image.img [more.img ...]   (in place)
"""
import struct
import sys
import time

MAC_EPOCH = 2082844800                          # 1904-01-01 to 1970-01-01, seconds


def catalog_leaf(b):
    mdb = 1024
    assert b[mdb:mdb + 2] == b'BD', 'not an HFS volume'
    blk = struct.unpack('>I', b[mdb + 20:mdb + 24])[0]
    st = struct.unpack('>H', b[mdb + 28:mdb + 30])[0] * 512
    s, n = struct.unpack('>HH', b[mdb + 150:mdb + 154])
    cat = st + s * blk
    depth, root, nrecs, first, last, nsz = struct.unpack('>HIIIIH', b[cat + 14:cat + 34])
    return cat, depth, first, last, nsz


def records(b, node, nsz):
    nrec = struct.unpack('>H', b[node + 10:node + 12])[0]
    offs = [struct.unpack('>H', b[node + nsz - 2 - 2 * i:node + nsz - 2 * i])[0] for i in range(nrec + 1)]
    out = []
    for i in range(nrec):
        o, e = node + offs[i], node + offs[i + 1]
        kl = b[o]
        r = o + 1 + kl + ((1 + kl) & 1)
        out.append((o, r, e))
    return out


def finder(b):
    now = int(time.time() - time.timezone) + MAC_EPOCH   # Mac time is local
    struct.pack_into('>II', b, 1024 + 2, now, now)       # drCrDate, drLsMod
    cat, depth, first, last, nsz = catalog_leaf(b)
    node = cat + first * nsz
    while True:                                          # the root folder's record: key (parent 1), type 1, dirID 2
        for o, r, e in records(b, node, nsz):
            if b[r] == 1 and struct.unpack('>I', b[o + 2:o + 6])[0] == 1 and struct.unpack('>I', b[r + 6:r + 10])[0] == 2:
                struct.pack_into('>II', b, r + 10, now, now)                # dirCrDat, dirMdDat
                struct.pack_into('>hhhh', b, r + 22, 60, 40, 260, 420)       # frRect
                return
        node = struct.unpack('>I', b[node:node + 4])[0]
        assert node, 'no root folder record'
        node = cat + node * nsz


def threads(b):
    cat, depth, first, last, nsz = catalog_leaf(b)
    assert depth == 1 and first == last, 'the catalog is not a single leaf (depth %d)' % depth
    node = cat + first * nsz
    recs = []
    for o, r, e in records(b, node, nsz):
        key, data = bytes(b[o:r]), bytearray(b[r:e])
        t = data[0]
        if t == 4:
            continue                                     # a file thread: optional, dropped
        if t == 3 and len(data) < 46:
            data += bytes(46 - len(data))
        if t == 2:
            data[2] &= ~0x02                             # filFlags: no thread record
        recs.append(key + bytes(data))
    body = b''.join(recs)
    assert 14 + len(body) + 2 * (len(recs) + 1) <= nsz, 'does not fit one node'
    nd = bytearray(nsz)
    nd[0:14] = b[node:node + 14]
    struct.pack_into('>H', nd, 10, len(recs))
    o = 14
    for i, r in enumerate(recs):
        nd[o:o + len(r)] = r
        struct.pack_into('>H', nd, nsz - 2 - 2 * i, o)
        o += len(r)
    struct.pack_into('>H', nd, nsz - 2 - 2 * len(recs), o)
    b[node:node + nsz] = nd
    struct.pack_into('>I', b, cat + 14 + 6, len(recs))  # bthNRecs


if __name__ == '__main__':
    args = sys.argv[1:]
    thr = '--threads' in args
    for p in [a for a in args if a != '--threads']:
        b = bytearray(open(p, 'rb').read())
        if thr:
            threads(b)
        finder(b)
        open(p, 'wb').write(b)
        print('%s: dates and the root window set%s' % (p, ', threads regular' if thr else ''))
