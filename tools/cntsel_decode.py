import re, sys
BS = chr(92)

def cells(vo):
    txt = open(vo, encoding='latin-1').read()
    out = {}
    for i in range(5):
        head = 'cyclonev_lcell_comb ' + BS + 'pll_cfg_hdmi|dyn_phase_shift_inst|lcell_cnt_sel_%d|lcell_inst (' % i
        a = txt.index(head)
        ports = txt[a:txt.index(');', a)]
        mm = re.search(r"lut_mask = 64'h([0-9A-F]+);", txt[a:a + 4000])
        mask = int(mm.group(1), 16)
        ins = {}
        for p in 'abcdef':
            pm = re.search(r'\.data%s\((!?)([^)]*?)\s*\)' % p, ports)
            if pm:
                inv, sig = pm.group(1) == '!', pm.group(2).strip()
                um = re.search(r'usr_cnt_sel \[(\d)\]', sig)
                ins[p] = (inv, ('u', int(um.group(1))) if um else ('gnd', 0))
        out[i] = (mask, ins)
    return out

def phys(c, logical):
    v = 0
    for i in range(5):
        mask, ins = c[i]
        idx = 0
        for k, p in enumerate('abcdef'):
            if p in ins:
                inv, (kind, b) = ins[p]
                bit = (logical >> b) & 1 if kind == 'u' else 0
                idx |= (bit ^ inv) << k
        v |= ((mask >> idx) & 1) << i
    return v

for name in sys.argv[1:]:
    c = cells(name)
    print(name.replace(BS, '/').split('/')[-1], ' '.join('C%d->%d' % (l, phys(c, l)) for l in range(9)))
