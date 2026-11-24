#!/usr/bin/env python3
"""hdl_norm.py - an HDL file's logic as tokens: comments gone, `ifdef blocks
resolved for a macro set, whitespace ignored.  Two files with the same output
compile to the same design.  Used to prove a release tree differs from the
built tree only in comments and dead `ifdef code.

  hdl_norm.py [-D MACRO ...] A [B]   - with B: exit 0 if identical, else
                                       print the first difference, exit 1
"""
import re, sys

def strip_verilog(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == chr(92) else 1
            out.append(s[i:j+1]); i = j + 1
        elif s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2); out.append(' '); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

def strip_vhdl(s):
    out = []
    for line in s.split('\n'):
        res, i, inq = [], 0, False
        while i < len(line):
            if line[i] == '"': inq = not inq
            if not inq and line.startswith('--', i): break
            res.append(line[i]); i += 1
        out.append(''.join(res))
    return '\n'.join(out)

def resolve_ifdefs(s, defs):
    out, stack = [], []          # stack of (active_before, taken, active)
    active = True
    for line in s.split('\n'):
        m = re.match(r'\s*`(ifdef|ifndef|elsif|else|endif|define)\b\s*(\w*)', line)
        if m:
            k, name = m.group(1), m.group(2)
            if k in ('ifdef', 'ifndef'):
                cond = (name in defs) == (k == 'ifdef')
                stack.append((active, cond))
                active = active and cond
                continue
            if k == 'elsif':
                outer, taken = stack[-1]
                cond = (not taken) and name in defs
                stack[-1] = (outer, taken or cond); active = outer and cond
                continue
            if k == 'else':
                outer, taken = stack[-1]
                stack[-1] = (outer, True); active = outer and not taken
                continue
            if k == 'endif':
                outer, _ = stack.pop(); active = outer
                continue
            if k == 'define' and active:
                defs.add(name)
        if active:
            out.append(line)
    return '\n'.join(out)

TOK = re.compile(r'"(?:\\.|[^"\\])*"|[A-Za-z_$`][\w$]*|\d[\w\']*|\'[sS]?[bodhBODH][\w?]*|\S')

def norm(path, defs):
    s = open(path, encoding='latin-1').read()
    if path.lower().endswith(('.vhd', '.vhdl')):
        s = strip_vhdl(s); toks = TOK.findall(s)
        return toks
    # what Quartus leaves out: between "synthesis translate_off" and "translate_on" (comment pragmas)
    s = re.sub(r'//[ \t]*(?:synthesis|synopsys|altera|pragma)[ \t]+translate_off.*?//[ \t]*(?:synthesis|synopsys|altera|pragma)[ \t]+translate_on',
               ' ', s, flags=re.S)
    s = strip_verilog(s)
    s = resolve_ifdefs(s, set(defs))
    return TOK.findall(s)

if __name__ == '__main__':
    a = sys.argv[1:]; defs = []
    while a and a[0] == '-D':
        defs.append(a[1]); a = a[2:]
    ta = norm(a[0], defs)
    if len(a) == 1:
        print(' '.join(ta)); sys.exit(0)
    tb = norm(a[1], defs)
    if ta == tb: sys.exit(0)
    k = next((i for i, (x, y) in enumerate(zip(ta, tb)) if x != y), min(len(ta), len(tb)))
    print('DIFF at token %d: %r  vs  %r' % (k, ' '.join(ta[k-5:k+8]), ' '.join(tb[k-5:k+8])))
    sys.exit(1)
