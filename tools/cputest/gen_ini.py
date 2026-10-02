# Make cputestgen.ini for the SE/30 core's 68882 corpus (plan 8.9.8):
# the shipped ini, global cpu=68030 fpu=68882, gzip off, the chosen
# presets enabled, every other preset left disabled.
import re, sys
src, dst, groups = sys.argv[1], sys.argv[2], sys.argv[3].split(',')
lines = open(src, newline='').read().replace('\r\n', '\n').split('\n')
out, sec = [], 'cputest'
for l in lines:
    m = re.match(r'^\[test=(\w+)\]', l)
    if m: sec = m.group(1)
    elif l.startswith('[cputest]'): sec = 'cputest'
    if sec == 'cputest':
        if l.startswith('cpu='): l = 'cpu=68030'
        elif l.startswith('fpu='): l = 'fpu=68882'
        elif l.startswith('feature_gzip='): l = 'feature_gzip=0'
    elif l.startswith('enabled='):
        l = 'enabled=%d' % (1 if sec in groups else 0)
    out.append(l)
open(dst, 'w', newline='\n').write('\n'.join(out))
