/* fpstress.c - A/UX self-check for the core: FPU work interrupted by the
 * clock, SIGALRM handlers arriving during it, and paging (KNOWN ISSUES 25/26/28).
 * Every round must give the reference bit for bit; any difference is a
 * CPU/FPU state lost across an interrupt, signal or page fault.
 *   cc -O -o fpstress fpstress.c -lm
 *   ./fpstress [rounds [megabytes]]      e.g. ./fpstress 30 4 &  (several at once)
 * K&R C on purpose (A/UX 3.1's cc).  NOSIG=1 in the environment: no signals.
 * The handler does INTEGER work only: A/UX 3.1's sendsig saves no FPU state
 * (only fpsave/fprest at a context switch do), so FPU work in a handler
 * clobbers the interrupted code's fp0/fp1 - on a real SE/30 too. */
#include <stdio.h>
#include <math.h>
#include <signal.h>

extern char *malloc();
long hsum;
int ticks;

long iwork(n)
int n;
{
	long s;
	int i;

	s = 0;
	for (i = 1; i <= n; i++)
		s = s * 31 + i;
	return s;
}

double work(n)
int n;
{
	double s;
	int i;

	s = 0.0;
	for (i = 1; i <= n; i++)
		s += sin((double)i * 0.001) * sqrt((double)i) / (1.0 + cos((double)i * 0.0007) * 0.5);
	return s;
}

void tick()
{
	hsum += iwork(200);
	ticks++;
	signal(SIGALRM, tick);
	if (getenv("NOSIG") == 0) alarm(1);
}

main(argc, argv)
int argc;
char **argv;
{
	int rounds, mb, r, bad;
	long i, n;
	unsigned long *buf, x;
	double ref, v;
	long h, hs;

	rounds = argc > 1 ? atoi(argv[1]) : 20;
	mb = argc > 2 ? atoi(argv[2]) : 0;
	bad = 0;
	ref = work(20000);
	h = iwork(200);
	printf("pid %d ref %.17g\n", getpid(), ref);
	fflush(stdout);
	signal(SIGALRM, tick);
	if (getenv("NOSIG") == 0) alarm(1);

	n = (long)mb * 262144L;		/* longs */
	buf = 0;
	if (n > 0) {
		buf = (unsigned long *)malloc((unsigned)(n * 4));
		if (buf == 0) {
			printf("pid %d malloc %d MB failed\n", getpid(), mb);
			n = 0;
		}
	}
	for (r = 0; r < rounds; r++) {
		v = work(20000);
		if (v != ref) {
			printf("pid %d MISMATCH round %d: %.17g\n", getpid(), r, v);
			bad++;
		}
		x = (unsigned long)r * 0x9E3779B1 + 12345;
		for (i = 0; i < n; i++)
			buf[i] = x ^ (unsigned long)i * 0x85EBCA77;
		for (i = 0; i < n; i++)
			if (buf[i] != (x ^ (unsigned long)i * 0x85EBCA77)) {
				printf("pid %d MEMORY round %d at %ld\n", getpid(), r, i);
				bad++;
				break;
			}
	}
	alarm(0);
	hs = 0;
	for (i = 0; i < ticks; i++)
		hs += h;
	if (hs != hsum) {
		printf("pid %d HANDLER sum %ld, expected %ld\n", getpid(), hsum, hs);
		bad++;
	}
	printf("pid %d %s: %d rounds, %d MB, %d signals\n", getpid(), bad ? "FAIL" : "ok", rounds, mb, ticks);
	exit(bad ? 1 : 0);
}
