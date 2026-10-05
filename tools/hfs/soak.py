"""The GCR-writing soak (SE30_PLAN.md 5.15.10 gate 5): a seeded source floppy,
blank round images, and a host checker that judges every copy against the
SEED, never against another copy.

    python soak.py make   <dir> [--rounds N]   source + blank round images
    python soak.py check  <image> [<image> ...] audit + compare every soak set
          [--sets-only]                         volume problems reported, not failed
                                                (a used SCSI disk has its own)
    python soak.py selftest                     the checker must be able to fail

The payload: a folder 'Soak' (a nested folder 'Inner' in it) of files whose
every 512-byte block is unique across the whole set - a header naming the
file, the fork and the block, then a SHA-256 stream keyed by the same - so a
sector that lands in the wrong place, or a stale sector left where a new one
should be, never reads back as correct data (MacPlus 2026-08-23: "a checker
that cannot fail is not a checker"). Resource forks are real resource files
(one 'DATA' resource), so the Finder copies them as it would any file; their
header bytes $30-$7D are the File Manager's directory copy and are reported,
never counted (Apple TN 74; MacPlus hfs_fork_diff.py).

check reads raw images, DiskCopy 4.2 images (both checksums verified, the tag
sum skipping the first 12 tag bytes - DiskCopy's quirk, as se30_flp_sdwriter.v
writes it) and partitioned SCSI images. Per volume: the catalog's links and
threads, every fork's extents (the overflow B-tree included) against the
bitmap and the MDB (as hfs_vol.py). Then every folder holding 'Big 1' is a
soak set: each manifest file present, type/creator right, both forks exact.
Run it on CLEANLY EJECTED images (the DC42 checksums are written on eject)."""
import hashlib, os, struct, sys

def be16(b, o): return struct.unpack_from(">H", b, o)[0]
def be32(b, o): return struct.unpack_from(">I", b, o)[0]

# ---------------------------------------------------------------- the payload
TYPE, CREATOR = b"BINA", b"SOAK"

def manifest():
    """[(path inside the set, data length, rsrc payload length or 0)].
    Odd lengths on purpose: partial last blocks, forks ending mid-sector."""
    m = [("Big 1", 262145, 0),
         ("Mid 1", 98303, 12000),
         ("Mid 2", 65537, 0),
         ("Mid 3", 50001, 4097),
         ("Mid 4", 81920, 0)]
    for i in range(10):
        m.append(("Small %02d" % i, 8191 + 101 * i, 3000 if i % 3 == 0 else 0))
    for i in range(16):
        m.append(("Inner:Tiny %02d" % i, (i * 187) % 3001, 777 if i % 4 == 1 else 0))
    m.append(("Inner:Rsrc only", 0, 20000))
    m.append(("Inner:Empty", 0, 0))
    return m

def stream(path, fork, length):
    """The fork's bytes: per 512-byte block a 16-byte header, then SHA-256."""
    out = bytearray()
    tag = hashlib.sha256(("SE30SOAK/" + path).encode("mac-roman")).digest()[:6]
    n = 0
    while len(out) < length:
        hdr = b"SOAK" + tag + bytes([fork]) + b"\0" + struct.pack(">I", n)
        blk = bytearray(hdr)
        k = 0
        while len(blk) < 512:
            blk += hashlib.sha256(tag + bytes([fork]) + struct.pack(">II", n, k)).digest()
            k += 1
        out += blk[:512]
        n += 1
    return bytes(out[:length])

def rsrc_fork(path, length):
    if length == 0:
        return b""
    from macresources import Resource, make_file
    return bytes(make_file([Resource(b"DATA", 128, data=stream(path, 1, length))]))

def expected():
    return {p: (stream(p, 0, d), rsrc_fork(p, r)) for p, d, r in manifest()}

# ---------------------------------------------------------------- containers
def dc42_sum(b):
    s = 0
    for i in range(0, len(b) - 1, 2):
        s = (s + be16(b, i)) & 0xFFFFFFFF
        s = ((s >> 1) | (s << 31)) & 0xFFFFFFFF
    return s

def dc42_wrap(data, tags, name):
    nm = name.encode("mac-roman")[:63]
    hdr = bytearray(84)
    hdr[0] = len(nm); hdr[1:1 + len(nm)] = nm
    struct.pack_into(">IIII", hdr, 64, len(data), len(tags), dc42_sum(data),
                     dc42_sum(tags[12:]) if tags else 0)
    hdr[80] = 1 if len(data) == 819200 else 0      # 800K / 400K
    hdr[81] = 0x22 if len(data) == 819200 else 0x02
    hdr[82:84] = b"\x01\x00"
    return bytes(hdr) + data + tags

def unwrap(img, problems):
    """The volume's bytes, after verifying a DiskCopy header if there is one."""
    if len(img) >= 84 and img[82:84] == b"\x01\x00" and 0 < img[0] < 64:
        dsz, tsz, dsum, tsum = struct.unpack_from(">IIII", img, 64)
        if 84 + dsz + tsz == len(img) and dsz in (409600, 819200, 737280, 1474560):
            data, tags = img[84:84 + dsz], img[84 + dsz:]
            d, t = dc42_sum(data), dc42_sum(tags[12:]) if tsz else 0
            print("  DiskCopy 4.2: data %d B, tags %d B; data sum %08X (header %08X), tag sum %08X (header %08X)"
                  % (dsz, tsz, d, dsum, t, tsum))
            if d != dsum: problems.append("DC42 data checksum %08X, header says %08X" % (d, dsum))
            if t != tsum: problems.append("DC42 tag checksum %08X, header says %08X" % (t, tsum))
            return data
    return img

def hfs_base(img):
    if img[512:514] == b"PM":
        for i in range(be32(img, 512 + 4)):
            e = img[512 * (1 + i):512 * (2 + i)]
            if e[48:80].split(b"\0")[0] == b"Apple_HFS":
                return be32(e, 8) * 512
    return 0

# ---------------------------------------------------------------- the volume
class Vol:
    def __init__(self, V, problems):
        self.V, self.P = V, problems
        m = V[1024:1024 + 162]
        if be16(m, 0) != 0x4244:
            raise ValueError("no HFS MDB (signature %04X)" % be16(m, 0))
        self.vbmst, self.nmal, self.alsz = be16(m, 14), be16(m, 18), be32(m, 20)
        self.alst, self.free = be16(m, 28), be16(m, 34)
        self.name = m[37:37 + m[36]].decode("mac-roman", "replace")
        self.xtsz, self.ctsz = be32(m, 130), be32(m, 146)
        self.xtext = self.ext3(m, 134)
        self.ctext = self.ext3(m, 150)
        self.over = {}
        self.over = self.read_overflow()

    @staticmethod
    def ext3(b, o): return [(be16(b, o + 4 * i), be16(b, o + 2 + 4 * i)) for i in range(3)]

    def extents(self, fid, ftype, first, size):
        """The fork's extents in order, overflow records appended."""
        ext = [e for e in first if e[1]]
        have = sum(c for _, c in ext)
        for sblk, more in sorted(self.over.get((fid, ftype), [])):
            if sblk != have:
                self.P.append("file %d fork %02X: overflow record at block %d, expected %d" % (fid, ftype, sblk, have))
            ext += [e for e in more if e[1]]; have += sum(c for _, c in more)
        if have * self.alsz < size:
            self.P.append("file %d fork %02X: %d bytes but extents hold %d" % (fid, ftype, size, have * self.alsz))
        return ext

    def read(self, ext, size):
        out = bytearray()
        for st, c in ext:
            a = self.alst * 512 + st * self.alsz
            out += self.V[a:a + c * self.alsz]
        return bytes(out[:size])

    def leaves(self, tree):
        ns = be16(tree, 14 + 18); n = be32(tree, 14 + 10); seen = set()
        while n and n not in seen:
            seen.add(n)
            nd = tree[n * ns:(n + 1) * ns]
            if len(nd) < ns or nd[8] != 0xFF:
                self.P.append("node %d in a leaf chain is not a leaf" % n); return
            cnt = be16(nd, 10)
            offs = [be16(nd, ns - 2 * (i + 1)) for i in range(cnt + 1)]
            for i in range(cnt):
                yield nd[offs[i]:offs[i + 1]]
            n = be32(nd, 0)

    def read_overflow(self):
        over = {}
        for r in self.leaves(self.read([e for e in self.xtext if e[1]], self.xtsz)):
            over.setdefault((be32(r, 2), r[1]), []).append((be16(r, 6), self.ext3(r, 8)))
        return over

    def audit(self):
        """hfs_vol.py's checks: ownership, threads, bitmap, MDB."""
        owner, P = {}, self.P
        def own(ext, who):
            for st, c in ext:
                for b in range(st, st + c):
                    if b >= self.nmal: P.append("%s: block %d past the volume's %d" % (who, b, self.nmal)); continue
                    if b in owner: P.append("block %d owned by both %s and %s" % (b, owner[b], who))
                    owner[b] = who
        own(self.xtext, "extents file"); own(self.ctext, "catalog file")
        for (fid, ft), lst in self.over.items():
            for _, ext in lst: own(ext, "overflow of file %d fork %02X" % (fid, ft))
        self.files, dirs, dthr, fthr = {}, {}, {}, {}
        for r in self.leaves(self.read([e for e in self.ctext if e[1]], self.ctsz)):
            kl = r[0]; par = be32(r, 2); nm = r[7:7 + r[6]].decode("mac-roman", "replace")
            p = 1 + kl; p += p & 1; t = r[p]
            if t == 2:
                fid = be32(r, p + 20)
                dl, rl = be32(r, p + 26), be32(r, p + 36)
                de = self.ext3(r, p + 74); re_ = self.ext3(r, p + 86)
                own(de, "file %d '%s' data" % (fid, nm)); own(re_, "file %d '%s' rsrc" % (fid, nm))
                self.files[fid] = (par, nm, r[p + 4:p + 8], r[p + 8:p + 12], dl, rl, de, re_)
            elif t == 1: dirs[be32(r, p + 6)] = (par, nm)
            elif t == 3: dthr[par] = (be32(r, p + 10), r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace"))
            elif t == 4: fthr[par] = (be32(r, p + 10), r[p + 15:p + 15 + r[p + 14]].decode("mac-roman", "replace"))
        for fid, f in self.files.items():
            if f[0] not in dirs: P.append("file %d '%s': parent %d missing" % (fid, f[1], f[0]))
        for did, (par, nm) in dirs.items():
            if did != 2 and par not in dirs: P.append("folder %d '%s': parent %d missing" % (did, nm, par))
            if did not in dthr: P.append("folder %d '%s': no thread" % (did, nm))
            elif dthr[did] != (par, nm): P.append("folder %d '%s': thread says %s" % (did, nm, dthr[did]))
        for did in dthr:
            if did not in dirs: P.append("folder thread %d %s: no folder record" % (did, dthr[did]))
        for fid, v in fthr.items():
            if fid not in self.files: P.append("file thread %d %s: no file record" % (fid, v))
            elif self.files[fid][:2] != v: P.append("file thread %d %s: file record says %s" % (fid, v, self.files[fid][:2]))
        bm = self.V[self.vbmst * 512:self.vbmst * 512 + (self.nmal + 7) // 8]
        setb = {b for b in range(self.nmal) if bm[b >> 3] & (0x80 >> (b & 7))}
        used_free = sorted(b for b in owner if b not in setb)
        set_unowned = sorted(b for b in setb if b not in owner)
        if used_free: P.append("%d blocks in use but free in the bitmap, e.g. %s" % (len(used_free), used_free[:5]))
        if set_unowned: P.append("%d blocks set in the bitmap that nothing owns, e.g. %s" % (len(set_unowned), set_unowned[:8]))
        if self.nmal - len(setb) != self.free: P.append("MDB free %d, bitmap free %d" % (self.free, self.nmal - len(setb)))
        self.dirs = dirs
        print("  volume '%s': %d blocks of %d, %d free; %d files, %d folders, %d blocks owned"
              % (self.name, self.nmal, self.alsz, self.free, len(self.files), len(dirs), len(owner)))

    def path(self, did):
        parts = []
        while did not in (1, 2):
            par, nm = self.dirs[did]; parts.append(nm); did = par
        return ":".join(reversed(parts))

# ---------------------------------------------------------------- the check
def check_sets(v, exp):
    """Every folder holding 'Big 1' is a soak set; returns (sets, bad)."""
    by_dir = {}
    for fid, f in v.files.items():
        by_dir.setdefault(f[0], {})[f[1]] = fid
    roots = [d for d, names in by_dir.items() if "Big 1" in names]
    sets = bad = 0
    for root in sorted(roots, key=v.path):
        sets += 1
        inner = [d for d, (par, nm) in v.dirs.items() if par == root and nm == "Inner"]
        where = {"": root, "Inner": inner[0] if inner else None}
        fails, notes = [], 0
        for p in exp:
            folder, _, nm = p.rpartition(":")
            d = where.get(folder)
            fid = by_dir.get(d, {}).get(nm) if d is not None else None
            if fid is None:
                fails.append("%s: missing" % p); continue
            par, _, typ, cre, dl, rl, de, re_ = v.files[fid]
            wd = v.read(v.extents(fid, 0x00, de, dl), dl)
            wr = v.read(v.extents(fid, 0xFF, re_, rl), rl)
            ed, er = exp[p]
            if (typ, cre) != (TYPE, CREATOR): fails.append("%s: type/creator %r/%r" % (p, typ, cre))
            if wd != ed:
                fails.append("%s: data %s" % (p, describe(wd, ed)))
            if wr != er:
                if len(wr) == len(er) and len(er) >= 0x7E and wr[:0x30] == er[:0x30] and wr[0x7E:] == er[0x7E:]:
                    notes += 1
                else:
                    fails.append("%s: rsrc %s" % (p, describe(wr, er)))
        extra = [nm for nm in by_dir.get(root, {}) if nm not in {p for p in exp if ":" not in p}]
        extra += ["Inner:" + nm for nm in by_dir.get(where["Inner"], {}) if "Inner:" + nm not in exp]
        verdict = "PASS" if not fails else "FAIL"
        print("  set '%s': %d files, %s%s%s" % (v.path(root) or "(root)", len(exp), verdict,
              "" if not notes else ", %d rsrc headers differ only at $30-$7D (the File Manager's)" % notes,
              "" if not extra else ", extra files %s" % extra))
        for f in fails[:12]: print("    " + f)
        if len(fails) > 12: print("    ... %d more" % (len(fails) - 12))
        bad += bool(fails)
    return sets, bad

def describe(got, want):
    if len(got) != len(want):
        return "length %d, expected %d" % (len(got), len(want))
    blocks = [i // 512 for i in range(0, len(want), 512) if got[i:i + 512] != want[i:i + 512]]
    first = blocks[0] * 512
    hdr = got[first:first + 16]
    who = ""
    if hdr[:4] == b"SOAK":
        who = " (block %d holds payload block %d of fork %d%s)" % (
            blocks[0], be32(hdr, 12), hdr[10], "" if hdr[4:10] == want[first + 4:first + 10] else " of ANOTHER file")
    return "%d of %d blocks differ, first block %d%s" % (len(blocks), (len(want) + 511) // 512, blocks[0], who)

def check_image(path, exp=None, img=None, sets_only=False):
    exp = exp or expected()
    print(path)
    P = []
    img = img if img is not None else open(path, "rb").read()
    V = unwrap(img, P)
    try:
        v = Vol(V[hfs_base(V):], P)
    except ValueError as e:
        print("  " + str(e)); print("  RESULT: FAIL"); return False
    v.audit()
    sets, bad = check_sets(v, exp)
    for p in P: print("  PROBLEM " + p)
    ok = (sets_only or not P) and sets > 0 and bad == 0
    if sets == 0: print("  no soak set (no folder holds 'Big 1')")
    print("  RESULT: %s (%d sets, %d failed, %d volume problems)" % ("PASS" if ok else "FAIL", sets, bad, len(P)))
    return ok

# ---------------------------------------------------------------- make
def source_volume():
    import machfs
    v = machfs.Volume(); v.name = "Soak Source"
    soak = machfs.Folder(); v["Soak"] = soak
    soak["Inner"] = machfs.Folder()
    for p, (d, r) in expected().items():
        f = machfs.File(); f.type, f.creator = TYPE, CREATOR
        f.data, f.rsrc = bytearray(d), bytearray(r)
        folder, _, nm = p.rpartition(":")
        (soak[folder] if folder else soak)[nm] = f
    return v.write(size=819200, align=512, desktopdb=False, bootable=False)

def make(out, rounds):
    os.makedirs(out, exist_ok=True)
    vol = source_volume()
    open(os.path.join(out, "soak_source.dsk"), "wb").write(vol)
    payload = sum(len(d) + len(r) for d, r in expected().values())
    free = be16(vol, 1024 + 34) * be32(vol, 1024 + 20)
    print("soak_source.dsk: %d files, %d payload bytes, %d bytes free on the source" % (len(manifest()), payload, free))
    for r in range(1, rounds + 1):
        for drive, dc in (("int", r % 2 == 0), ("ext", r % 2 == 1)):
            nm = "soak_r%d_%s.%s" % (r, drive, "image" if dc else "dsk")
            blank = bytes(819200)
            open(os.path.join(out, nm), "wb").write(dc42_wrap(blank, bytes(1600 * 12), nm) if dc else blank)
            print(nm, "(blank, %s)" % ("DiskCopy 4.2 with tags" if dc else "raw"))
    open(os.path.join(out, "soak_final_int.dsk"), "wb").write(bytes(819200))
    print("soak_final_int.dsk (blank, raw): takes the last round's SCSI copy")

# ---------------------------------------------------------------- selftest
def selftest():
    exp = expected()
    vol = bytearray(source_volume())
    results = []
    def run(label, img, want):
        print("--- " + label)
        got = check_image(label, exp, bytes(img))
        results.append((label, got == want))
        print("    selftest: %s (expected %s)" % ("ok" if got == want else "WRONG", "PASS" if want else "FAIL"))
    run("clean raw source", vol, True)
    run("clean DC42", dc42_wrap(bytes(vol), bytes(19200), "x"), True)
    # locate Big 1's first extent and a Mid 1 rsrc fork through the checker's own reader
    P = []; v = Vol(bytes(vol), P); v.audit()
    fids = {f[1]: (fid, f) for fid, f in v.files.items()}
    _, big = fids["Big 1"]; st = big[6][0][0]; a = v.alst * 512 + st * v.alsz
    m = bytearray(vol); m[a + 512:a + 1024], m[a + 1024:a + 1536] = vol[a + 1024:a + 1536], vol[a + 512:a + 1024]
    run("two sectors of Big 1 swapped", m, False)
    _, mid = fids["Mid 1"]; ra = v.alst * 512 + mid[7][0][0] * v.alsz
    m = bytearray(vol); m[ra + 0x200] ^= 0x01
    run("one bit of Mid 1's resource data", m, False)
    m = bytearray(vol); m[ra + 0x40] ^= 0xFF
    run("Mid 1's rsrc header at $40 (the File Manager's bytes)", m, True)
    _, small = fids["Small 03"]; sa = v.alst * 512 + small[6][0][0] * v.alsz
    m = bytearray(vol); m[sa:sa + 512] = vol[a:a + 512]
    run("Small 03's first sector replaced by Big 1's (a misplaced write)", m, False)
    m = bytearray(vol); m[sa + 100] ^= 0x80
    dc = bytearray(dc42_wrap(bytes(vol), bytes(19200), "x")); dc[84 + sa + 100] ^= 0x80
    run("DC42 data changed after its checksum", dc, False)
    m = bytearray(vol); bm = v.vbmst * 512; m[bm + (st >> 3)] &= ~(0x80 >> (st & 7)) & 0xFF
    run("a block of Big 1 freed in the bitmap", m, False)
    print()
    for label, ok in results: print("%-62s %s" % (label, "ok" if ok else "WRONG"))
    allok = all(ok for _, ok in results)
    print("SELFTEST: %s" % ("PASS" if allok else "FAIL"))
    return allok

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: sys.exit(__doc__)
    if a[0] == "make" and len(a) >= 2:
        make(a[1], int(a[a.index("--rounds") + 1]) if "--rounds" in a else 3)
    elif a[0] == "check" and len(a) >= 2:
        exp = expected()
        oks = [check_image(p, exp, sets_only="--sets-only" in a) for p in a[1:] if not p.startswith("--")]
        print("\nSOAK CHECK: %s (%d of %d images pass)" % ("PASS" if all(oks) else "FAIL", sum(oks), len(oks)))
        sys.exit(0 if all(oks) else 1)
    elif a[0] == "selftest":
        sys.exit(0 if selftest() else 1)
    else:
        sys.exit(__doc__)
