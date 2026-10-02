"""Patch WinUAE's cputest.cpp (a build copy, never the clone) so that the
generator also writes every round it stores as one text line - plan 8.9.8,
7e-4, harness A.  The line carries what WinUAE's own emulation of the
round used and produced, so the 68882 benches can take the FPU's part of
it without the 030's (the effective address, the dialog):

    <dir> op=<instruction words> pre ... mem ... post ... exc=<n>,<extra>

    pre/post  D0-D7 A0-A7 (8 hex each), SR, PC, FP0-FP7 (20 hex: sign and
              exponent word, mantissa), FPCR, FPSR, FPIAR
    mem       the instruction's top-level data reads and writes, in order:
              r<addr>:<size>:<value> or w<addr>:<size>:<value>
    exc       test_exception and test_exception_extra as the .dat stores them

A round the generator drops later (every round of an opcode skipped) is
dropped here too.  Reads: the generator's get_byte/word/long_test, which the
FPU's operand fetch, FMOVEM and the exception processing use; instruction
words come from get_iword/prefetch and are not data reads.

    python se30dump.py cputest.cpp    (in place)
"""
import sys

GLOBALS = r'''
// SE/30 core (plan 8.9.8): every stored round as one text line
// (tools/cputest/se30dump.py patched this in; not part of WinUAE)
static FILE *se30_f;
static int se30_on, se30_depth;
static std::string se30_acc, se30_pending;
static struct regstruct se30_pre;
static void se30_log(char k, uaecptr a, int s, uae_u32 v)
{
	if (!se30_on || se30_depth)
		return;
	char b[64];
	snprintf(b, sizeof b, " %c%08x:%d:%0*x", k, a, s, s * 2, v);
	se30_acc += b;
}
static void se30_state(std::string &s, struct regstruct *r, uaecptr pc)
{
	char b[64];
	for (int i = 0; i < 16; i++) {
		snprintf(b, sizeof b, " %08x", r->regs[i]);
		s += b;
	}
	snprintf(b, sizeof b, " %04x %08x", r->sr & 0xffff, pc);
	s += b;
	for (int i = 0; i < 8; i++) {
		snprintf(b, sizeof b, " %04x%016llx", r->fp[i].fpx.high, (unsigned long long)r->fp[i].fpx.low);
		s += b;
	}
	snprintf(b, sizeof b, " %08x %08x %08x", r->fpcr, r->fpsr, r->fpiar);
	s += b;
}
'''

WRAP_PUT = r'''
void put_byte_test(uaecptr addr, uae_u32 v) { se30_depth++; se30_put_byte_test(addr, v); se30_depth--; se30_log('w', addr, 1, v & 0xff); }
void put_word_test(uaecptr addr, uae_u32 v) { se30_depth++; se30_put_word_test(addr, v); se30_depth--; se30_log('w', addr, 2, v & 0xffff); }
void put_long_test(uaecptr addr, uae_u32 v) { se30_depth++; se30_put_long_test(addr, v); se30_depth--; se30_log('w', addr, 4, v); }
'''

WRAP_GET = r'''
uae_u32 get_byte_test(uaecptr addr) { se30_depth++; uae_u32 v = se30_get_byte_test(addr); se30_depth--; se30_log('r', addr, 1, v); return v; }
uae_u32 get_word_test(uaecptr addr) { se30_depth++; uae_u32 v = se30_get_word_test(addr); se30_depth--; se30_log('r', addr, 2, v); return v; }
uae_u32 get_long_test(uaecptr addr) { se30_depth++; uae_u32 v = se30_get_long_test(addr); se30_depth--; se30_log('r', addr, 4, v); return v; }
'''

RECORD = r'''								{	// SE/30 (plan 8.9.8)
									std::string s = dir;
									char b[32];
									s += " op=";
									for (uaecptr a = startpc; a < pc - 4; a += 2) {
										snprintf(b, sizeof b, "%04x", get_word_debug(a));
										s += b;
									}
									s += " pre";
									se30_state(s, &se30_pre, startpc);
									s += " mem";
									s += se30_acc;
									s += " post";
									se30_state(s, &regs, regs.pc - extraopcodeendsize);
									snprintf(b, sizeof b, " exc=%d,%d\n", test_exception, test_exception_extra);
									s += b;
									se30_pending += s;
								}
'''


def sub(text, old, new, count=1):
    n = text.count(old)
    if n != count:
        raise SystemExit('anchor found %d times, expected %d: %r' % (n, count, old[:70]))
    return text.replace(old, new)


def main(path):
    t = open(path, newline='').read()
    if 'se30_state' in t:
        raise SystemExit('already patched')
    t = sub(t, '#include "options.h"\n', '#include "options.h"\n' + GLOBALS)
    for f in ('byte', 'word', 'long'):
        t = sub(t, 'void put_%s_test(uaecptr addr, uae_u32 v)\n{' % f,
                'static void se30_put_%s_test(uaecptr addr, uae_u32 v)\n{' % f)
        t = sub(t, 'uae_u32 get_%s_test(uaecptr addr)\n{' % f,
                'static uae_u32 se30_get_%s_test(uaecptr addr)\n{' % f)
    # the wrappers after the last of each family
    t = sub(t, '\nstatic uae_u32 se30_get_byte_test(uaecptr addr)\n{',
            WRAP_PUT + '\nstatic uae_u32 se30_get_byte_test(uaecptr addr)\n{')
    t = sub(t, '\nuae_u32 get_byte_debug(uaecptr addr)', WRAP_GET + '\nuae_u32 get_byte_debug(uaecptr addr)')
    t = sub(t, '\t\t\t\t\t\t\texecute_ins(pc - endopcodesize, branch_target_pc, dp, fpumode);\n',
            '\t\t\t\t\t\t\tse30_pre = regs; se30_acc.clear(); se30_on = 1;\n'
            '\t\t\t\t\t\t\texecute_ins(pc - endopcodesize, branch_target_pc, dp, fpumode);\n'
            '\t\t\t\t\t\t\tse30_on = 0;\n')
    t = sub(t, '\t\t\t\t\t\t\t\ttest_count++;\n\t\t\t\t\t\t\t\tsubtest_count++;\n\t\t\t\t\t\t\t\tccr_done++;\n',
            RECORD + '\t\t\t\t\t\t\t\ttest_count++;\n\t\t\t\t\t\t\t\tsubtest_count++;\n\t\t\t\t\t\t\t\tccr_done++;\n')
    t = sub(t, '\t\t\t\t\tif (!ccr_done) {\n', '\t\t\t\t\tif (!ccr_done) {\n\t\t\t\t\t\tse30_pending.clear();\n')
    t = sub(t, '\t\t\t\t\t\ttest_count_missed = 0;\n',
            '\t\t\t\t\t\ttest_count_missed = 0;\n'
            '\t\t\t\t\t\tif (se30_f) fputs(se30_pending.c_str(), se30_f);\n'
            '\t\t\t\t\t\tse30_pending.clear();\n')
    t = sub(t, '\tstruct ini_data *ini = ini_load(_T("cputestgen.ini"), false);\n',
            '\tse30_f = fopen("se30_vectors.txt", "w");\n'
            '\tstruct ini_data *ini = ini_load(_T("cputestgen.ini"), false);\n')
    open(path, 'w', newline='').write(t)
    print('patched', path)


if __name__ == '__main__':
    main(sys.argv[1])
