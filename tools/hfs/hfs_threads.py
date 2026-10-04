"""Read-only: find the HFS partitions of a whole-disk image (Apple partition
map), walk each catalog B-tree's leaves, and report file thread records with
no file record (Disk First Aid's "Missing file record for file thread"), plus
a summary. Usage: python hfs_threads.py image [--dump CNID ...]"""
import sys, struct, io

def be16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def be32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def partitions(f):
    f.seek(512)
    pm = f.read(512)
    if pm[0:2] != b"PM":
        return [(0, None, "whole")]
    n = be32(pm, 4)
    out = []
    for i in range(n):
        f.seek(512 * (1 + i))
        e = f.read(512)
        start, cnt = be32(e, 8), be32(e, 12)
        name = e[16:48].split(b"\0")[0].decode("mac-roman")
        typ = e[48:80].split(b"\0")[0].decode("mac-roman")
        out.append((start * 512, cnt * 512, "%s %s" % (typ, name)))
    return out

def catalog(f, base):
    f.seek(base + 1024)
    m = f.read(162)
    if be16(m, 0) != 0x4244:
        return None
    alBlkSiz, alBlSt = be32(m, 20), be16(m, 28)
    vname = m[37:37 + m[36]].decode("mac-roman")
    ctFlSize = be32(m, 146)
    ext = [(be16(m, 150 + 4 * i), be16(m, 152 + 4 * i)) for i in range(3)]
    cat = b""
    for st, c in ext:
        if c:
            f.seek(base + alBlSt * 512 + st * alBlkSiz)
            cat += f.read(c * alBlkSiz)
    return vname, cat[:ctFlSize], dict(alBlkSiz=alBlkSiz, alBlSt=alBlSt, ext=ext, nxtCNID=be32(m, 30),
                                       filCnt=be32(m, 84), dirCnt=be32(m, 88), lsMod=be32(m, 6))

def walk(cat):
    nodeSize = be16(cat, 14 + 18)
    firstLeaf = be32(cat, 14 + 10)
    files, fthreads, dirs, dthreads = {}, {}, {}, {}
    n, seen, leaves = firstLeaf, set(), 0
    while n and n not in seen:
        seen.add(n); leaves += 1
        nd = cat[n * nodeSize:(n + 1) * nodeSize]
        flink = be32(nd, 0); ntype = nd[8]; nrecs = be16(nd, 10)
        if ntype != 0xFF:
            print("  node %d in the leaf chain has type %d" % (n, ntype)); break
        offs = [be16(nd, nodeSize - 2 * (i + 1)) for i in range(nrecs + 1)]
        for i in range(nrecs):
            r = nd[offs[i]:offs[i + 1]]
            kl = r[0]; parID = be32(r, 2); name = r[7:7 + r[6]].decode("mac-roman", "replace")
            p = 1 + kl; p += p & 1
            typ = r[p]
            if typ == 2:                                   # file record
                flags = r[p + 2]; fid = be32(r, p + 20)
                files[fid] = (parID, name, flags, n)
            elif typ == 1:
                dirs[be32(r, p + 6)] = (parID, name, n)
            elif typ == 4:                                 # file thread: key parID = the file's ID
                tpar = be32(r, p + 10); tname = r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace")
                fthreads[parID] = (tpar, tname, n)
            elif typ == 3:
                tpar = be32(r, p + 10); tname = r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace")
                dthreads[parID] = (tpar, tname, n)
        n = flink
    return dict(nodeSize=nodeSize, leaves=leaves, files=files, fthreads=fthreads, dirs=dirs, dthreads=dthreads)

def main():
    img = sys.argv[1]
    dump = [int(x) for x in sys.argv[3:]] if len(sys.argv) > 2 and sys.argv[2] == "--dump" else []
    with open(img, "rb") as f:
        for base, size, desc in partitions(f):
            c = catalog(f, base)
            if not c: continue
            vname, cat, mdb = c
            w = walk(cat)
            print("volume '%s' at byte %d (%s): catalog %d bytes, node %d, %d leaves; %d files, %d dirs, %d file threads, %d dir threads; MDB files %d dirs %d nxtCNID %d"
                  % (vname, base, desc, len(cat), w["nodeSize"], w["leaves"], len(w["files"]), len(w["dirs"]),
                     len(w["fthreads"]), len(w["dthreads"]), mdb["filCnt"], mdb["dirCnt"], mdb["nxtCNID"]))
            orphan = [fid for fid in w["fthreads"] if fid not in w["files"]]
            for fid in sorted(orphan):
                tpar, tname, node = w["fthreads"][fid]
                pd = w["dirs"].get(tpar)
                print("  ORPHAN file thread: file ID %d -> parent %d ('%s'), name '%s', in leaf node %d"
                      % (fid, tpar, pd[1] if pd else "?", tname, node))
            for fid in dump:
                print("  ID %d: file %s thread %s dir %s" % (fid, w["files"].get(fid), w["fthreads"].get(fid), w["dirs"].get(fid)))
            flagged = [fid for fid, v in w["files"].items() if v[2] & 0x02]
            print("  files with the thread-exists flag: %d; of them without a thread: %d"
                  % (len(flagged), len([x for x in flagged if x not in w["fthreads"]])))

main()
