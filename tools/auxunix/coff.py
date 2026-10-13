# A/UX m68k COFF reader: sections, symbols, and capstone disassembly.
# usage: coff.py FILE syms [regex] | dis SYMBOL [SYMBOL...] | sects
import sys, struct, re
import capstone

FN = sys.argv[1]
d = open(FN, 'rb').read()
magic, nscns, _, symptr, nsyms, opthdr, flags = struct.unpack('>HHiiiHH', d[:20])
sects = []
p = 20 + opthdr
for i in range(nscns):
    name = d[p:p + 8].rstrip(b'\0').decode()
    paddr, vaddr, size, scnptr = struct.unpack('>iiii', d[p + 8:p + 24])
    sects.append((name, vaddr, size, scnptr))
    p += 40
strtab = symptr + nsyms * 18
syms = []
i = 0
while i < nsyms:
    e = d[symptr + i * 18:symptr + i * 18 + 18]
    if e[:4] == b'\0\0\0\0':
        off = struct.unpack('>i', e[4:8])[0]
        name = d[strtab + off:d.index(b'\0', strtab + off)].decode('latin1')
    else:
        name = e[:8].rstrip(b'\0').decode('latin1')
    val, scn, typ, scl, naux = struct.unpack('>ihHbb', e[8:18])
    syms.append((name, val, scn, scl))
    i += 1 + naux

def sect_of(addr):
    for n, v, s, o in sects:
        if v <= addr < v + s and o:
            return n, v, s, o
    return None

text = sorted([s for s in syms if s[2] > 0 and sects[s[2] - 1][0] in ('.text', 'pstart')], key=lambda s: s[1])
byaddr = {}
for s in syms:
    byaddr.setdefault(s[1], s[0])

cmd = sys.argv[2]
if cmd == 'sects':
    for s in sects:
        print('%-8s vaddr %08x size %08x file %08x' % s)
elif cmd == 'syms':
    rx = re.compile(sys.argv[3] if len(sys.argv) > 3 else '.')
    for n, v, scn, scl in sorted(syms, key=lambda s: s[1]):
        if rx.search(n):
            sn = sects[scn - 1][0] if scn > 0 else str(scn)
            print('%08x %-6s cl%-3d %s' % (v, sn, scl, n))
elif cmd == 'dis':
    md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_030 | capstone.CS_MODE_BIG_ENDIAN)
    for want in sys.argv[3:]:
        cand = [s for s in text if s[0] == want]
        if not cand:
            print('?? ' + want)
            continue
        start = cand[0][1]
        nxt = [s[1] for s in text if s[1] > start]
        end = min(nxt) if nxt else start + 0x400
        n, v, sz, o = sect_of(start)
        code = d[o + start - v:o + end - v]
        print('\n==== %s %08x-%08x' % (want, start, end))
        for ins in md.disasm(code, start):
            lab = byaddr.get(ins.address)
            if lab and ins.address != start:
                print('%s:' % lab)
            ops = ins.op_str
            for m in re.findall(r'\$([0-9a-f]{5,8})', ops):
                a = int(m, 16)
                if a in byaddr:
                    ops += '   <' + byaddr[a] + '>'
            print('  %08x  %-8s %s' % (ins.address, ins.mnemonic, ops))
