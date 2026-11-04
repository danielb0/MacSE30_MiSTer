/* memtest: write and check as much user memory as A/UX gives, to find
   bad RAM above what the kernel keeps.  A/UX 3.1, K&R C:
     cc -o memtest memtest.c ; ./memtest 28 3
   (MB to take, passes).  Each pass writes every long with a pattern
   from its address, reads it all back at once, then again after 20 s
   idle; the first errors are printed: address, expected, read, xor. */
#include <stdio.h>
char *sbrk();
long *b[64]; int nb, ne;
chk(pass, wait) int pass, wait; {
  int j, i; long e, *p;
  for (j = 0; j < nb; j++)
    for (p = b[j], i = 0; i < 1048576 / sizeof(long); i++, p++) {
      e = (long)p ^ (pass & 1 ? 0xffffffffL : 0) ^ ((long)pass << 28);
      if (*p != e && ++ne <= 40)
        printf("%s %08lx: wrote %08lx read %08lx xor %08lx\n",
               wait ? "idle" : "now ", (long)p, e, *p, e ^ *p);
    }
}
main(ac, av) int ac; char **av; {
  int mb = atoi(av[1]), np = atoi(av[2]), pass, j, i; long *p; char *c;
  for (nb = 0; nb < mb && nb < 64; nb++) {
    c = sbrk(1048576);
    if (c == (char *)-1) break;
    b[nb] = (long *)c;
  }
  printf("%d MB from %08lx to %08lx\n", nb, (long)b[0], (long)b[nb-1] + 1048576);
  for (pass = 0; pass < np; pass++) {
    for (j = 0; j < nb; j++)
      for (p = b[j], i = 0; i < 1048576 / sizeof(long); i++, p++)
        *p = (long)p ^ (pass & 1 ? 0xffffffffL : 0) ^ ((long)pass << 28);
    ne = 0; chk(pass, 0);
    printf("pass %d: %d errors now", pass, ne); fflush(stdout);
    sleep(20); ne = 0; chk(pass, 1);
    printf(", %d after 20 s\n", ne);
  }
  exit(0);
}
