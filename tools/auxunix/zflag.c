/* zflag: cc's start-up shape (2026-11-04: /bin/cc's main, `move.l a0,_x` with
   A0 = 0 then `beq`, faulted on the IIcx at 64 MB) in a program of its own.
   A/UX 3.1, K&R C:  cc -o zflag zflag.c ; ./zflag ; ./zflag t
   p is the first write to its bss page unless an argument is given (t:
   the page touched first).  "ok" = the branch went right; "BUG" = the
   strrchr result (0) was stored and the test took the non-zero path. */
#include <stdio.h>
char *strrchr();
char *p;
main(ac, av) int ac; char **av; {
  char name[8];
  strcpy(name, "cc");
  if (ac > 1) p = name;                  /* t: the bss page written first */
  p = strrchr(name, '/');
  if (p) { printf("BUG: p = %lx\n", (long)p); exit(1); }
  printf("ok (%s)\n", ac > 1 ? "page touched first" : "first write to the page");
  exit(0);
}
