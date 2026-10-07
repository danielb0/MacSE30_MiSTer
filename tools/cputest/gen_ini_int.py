# Make cputestgen.ini for the SE/30 core's 68030 INTEGER corpus (plan
# 1.18.6): the shipped ini, global cpu=68030, no FPU, gzip off, the chosen
# 68020+ presets enabled (the 68000-68010 ones never: their cpu= excludes a
# 68030 anyway), every other preset left disabled.  Optional: mode=<list>
# and test_rounds=<n> to override in the enabled presets (a quick sample).
#
#   python gen_ini_int.py <shipped ini> <out ini> BASIC,EXTSRC,EXTDST [mode=add,move] [test_rounds=1]
import re, sys
src, dst, groups = sys.argv[1], sys.argv[2], sys.argv[3].split(',')
over = dict(a.split('=', 1) for a in sys.argv[4:])
lines = open(src, newline='').read().replace('\r\n', '\n').split('\n')
out, sec, s68020, on = [], 'cputest', False, False
for l in lines:
    m = re.match(r'^\[test=(\w+)\]', l)
    if m:
        sec, on = m.group(1), False
    elif l.startswith('[cputest]'):
        sec = 'cputest'
    if '68020+ presets' in l:
        s68020 = True
    if sec == 'cputest':
        if l.startswith('cpu='): l = 'cpu=68030'
        elif l.startswith('fpu='): l = 'fpu='
        elif l.startswith('feature_gzip='): l = 'feature_gzip=0'
        elif l.startswith('verbose='): l = 'verbose=0'
    elif l.startswith('enabled='):
        on = s68020 and sec in groups
        l = 'enabled=%d' % on
        if on:
            l += ''.join('\n%s=%s' % kv for kv in over.items())
    elif on and any(l.startswith(k + '=') for k in over):
        continue
    out.append(l)
open(dst, 'w', newline='\n').write('\n'.join(out))
