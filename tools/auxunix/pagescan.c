/* pagescan: find a program's code pages in physical RAM and diff them
   against the file.  A/UX 3.1, K&R C, as root:
     cc -o pagescan pagescan.c ; ./pagescan /bin/cc
   Every 4 KB page of /dev/mem at least 1/4 equal to one of the file's
   text pages is printed: its address, the text page, the bytes that
   differ, and the first differences (offset in page, file, RAM). */
#include <stdio.h>
unsigned char f[262144], m[65536];
long be(p) unsigned char *p; { return ((long)p[0]<<24)|((long)p[1]<<16)|(p[2]<<8)|p[3]; }
main(ac, av) int ac; char **av; {
  int fd, fl, n, i, k, s, ns, lo, hi, d, eq, nc, t, nt, bad = 0;
  long vaddr, size, ptr, off, pg, pa = 0;
  fd = open(av[1], 0); fl = read(fd, f, sizeof f); close(fd);
  ns = (f[2]<<8)|f[3]; s = 20 + ((f[16]<<8)|f[17]);
  for (i = 0; i < ns && strncmp((char *)f + s + 40*i, ".text", 5); i++) ;
  if (i == ns) { printf("no .text\n"); exit(1); }
  s += 40*i; vaddr = be(f+s+12); size = be(f+s+16); ptr = be(f+s+20);
  nt = (vaddr + size + 4095) / 4096;
  printf(".text vaddr %lx size %lx file %lx: pages 0-%x\n", vaddr, size, ptr, (nt-1)*4096);
  if (ptr - vaddr + nt*4096L > fl) { printf("file too big for the buffer\n"); exit(1); }
  if ((fd = open("/dev/mem", 0)) < 0) { perror("/dev/mem"); exit(1); }
  for (;;) {                                           /* to 64 MB; an unreadable 64 KB is skipped */
    if (pa >= 0x4000000L) break;
    lseek(fd, pa, 0);
    if ((n = read(fd, m, sizeof m)) <= 0) {
      if (!bad) { printf("phys %08lx: read %d: ", pa, n); fflush(stdout); perror(""); }
      bad = 1; pa += sizeof m; continue;
    }
    if (bad) printf("phys %08lx: readable again\n", pa);
    bad = 0;
    for (k = 0; k + 4096 <= n; k += 4096)
      for (t = 0; t < nt; t++) {
        pg = t * 4096L;
        lo = vaddr > pg ? vaddr - pg : 0;              /* the page's bytes the file has */
        hi = vaddr + size < pg + 4096 ? vaddr + size - pg : 4096;
        off = ptr + pg - vaddr; nc = hi - lo;          /* file index of page byte 0 */
        for (eq = 0, i = lo + 256; i < lo + 384 && i < hi; i++) eq += (m[k+i] == f[off+i]);
        if (eq < 24) continue;
        for (eq = 0, i = lo; i < hi; i++) eq += (m[k+i] == f[off+i]);
        if (4 * eq < nc) continue;
        printf("phys %08lx = text page %lx: %d of %d bytes differ\n", pa + k, pg, nc - eq, nc);
        for (d = 0, i = lo; i < hi && d < 12; i++)
          if (m[k+i] != f[off+i]) { d++; printf("  %03x  %02x  %02x\n", i, f[off+i], m[k+i]); }
      }
    pa += n;
  }
  printf("scanned %ld MB\n", pa >> 20);
  exit(0);
}
