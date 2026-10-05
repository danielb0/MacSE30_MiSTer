"""Compare a folder on one HFS image, file by file and fork by fork, with a
folder on another (a Finder copy against its source).

    python fork_cmp.py <copy image> <copy folder> <source image> [<source folder>]

Folders are colon paths from the volume's root ('' = the root). Every file
under the source folder, nested folders included, must be on the copy at
the same relative path with the same type, creator and forks. Resource-fork
header bytes $30-$7D are the File Manager's directory copy and are reported,
never counted (Apple TN 74; MacPlus hfs_fork_diff.py). Raw, DiskCopy 4.2
(checksums verified) and partitioned images; overflow extents followed (the
reader and the volume audit are soak.py's)."""
import sys
sys.stdout.reconfigure(errors="replace")
from soak import Vol, unwrap, hfs_base

def open_vol(path):
    P = []
    print(path)
    V = unwrap(open(path, "rb").read(), P)
    v = Vol(V[hfs_base(V):], P)
    v.audit()
    for p in P: print("  PROBLEM " + p)
    return v, P

def find_dir(v, path):
    did = 2
    for part in [p for p in path.split(":") if p]:
        kids = [d for d, (par, nm) in v.dirs.items() if par == did and nm.lower() == part.lower()]
        if not kids: sys.exit("no folder '%s' on '%s'" % (path, v.name))
        did = kids[0]
    return did

def tree(v, root):
    """{relative path: fid} for every file under root."""
    out = {}
    def rel(did):
        parts = []
        while did != root:
            par, nm = v.dirs[did]; parts.append(nm); did = par
        return ":".join(reversed(parts))
    under = {root}
    grew = True
    while grew:
        grew = False
        for d, (par, _) in v.dirs.items():
            if par in under and d not in under: under.add(d); grew = True
    for fid, f in v.files.items():
        if f[0] in under:
            r = rel(f[0]); out[(r + ":" if r else "") + f[1]] = fid
    return out

def forks(v, fid):
    par, nm, typ, cre, dl, rl, de, re_ = v.files[fid]
    return typ, cre, v.read(v.extents(fid, 0x00, de, dl), dl), v.read(v.extents(fid, 0xFF, re_, rl), rl)

def main(a):
    cv, cp = open_vol(a[0]); sv, sp = open_vol(a[2])
    ct, st = tree(cv, find_dir(cv, a[1])), tree(sv, find_dir(sv, a[3] if len(a) > 3 else ""))
    ok = bad = 0
    for p in sorted(st, key=str.lower):
        if p.split(":")[-1] in ("Desktop", "Desktop DB", "Desktop DF"):
            continue
        if p not in ct:
            print("  %-48s MISSING on the copy" % p); bad += 1; continue
        cT, cC, cd, cr = forks(cv, ct[p]); sT, sC, sd, sr = forks(sv, st[p])
        issues = []
        if (cT, cC) != (sT, sC): issues.append("type/creator %r/%r, source %r/%r" % (cT, cC, sT, sC))
        if cd != sd: issues.append("data DIFFERS (%d vs %d B)" % (len(cd), len(sd)))
        hdr = ""
        if cr != sr:
            if len(cr) == len(sr) and len(sr) >= 0x7E and cr[:0x30] == sr[:0x30] and cr[0x7E:] == sr[0x7E:]:
                hdr = "  [rsrc $30-$7D: the File Manager's]"
            else:
                issues.append("rsrc DIFFERS (%d vs %d B)" % (len(cr), len(sr)))
        if issues: bad += 1; print("  %-48s %s" % (p, "; ".join(issues)))
        else: ok += 1; print("  %-48s identical (data %d, rsrc %d)%s" % (p, len(sd), len(sr), hdr))
    extra = sorted(set(ct) - set(st))
    for p in extra: print("  %-48s only on the copy" % p)
    print("\n%d identical, %d differ or missing, %d only on the copy; volume problems: copy %d, source %d"
          % (ok, bad, len(extra), len(cp), len(sp)))
    print("FORK CMP: %s" % ("PASS" if bad == 0 and ok > 0 else "FAIL"))
    return bad == 0 and ok > 0

if __name__ == "__main__":
    if len(sys.argv) < 4: sys.exit(__doc__)
    sys.exit(0 if main(sys.argv[1:]) else 1)
