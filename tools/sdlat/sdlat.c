/* sdlat.c - the latency of synchronous writes to the MiSTer's SD card, as
 * Main_MiSTer makes them for a mounted image (O_RDWR | O_SYNC, one write()
 * per core request).  SE30_PLAN.md KNOWN ISSUES 17: A/UX 3.1's 8 KB root
 * writes came back ABORTED COMMAND from rtl/scsi.v's IO-stall watchdog, which
 * ended any HPS transfer that took longer than 2^24 clocks (~535 ms); this
 * measures what the card actually does under the same kind of writes.
 *
 * Build (WSL, the Main_MiSTer cross toolchain):
 *   arm-none-linux-gnueabihf-gcc -O2 -static -o sdlat sdlat.c
 * Run on the MiSTer (ssh root@<mister>, password 1), with the SE/30 core
 * running or not:
 *   ./sdlat /media/fat/sdlat.tmp 8192 2000
 * = 2000 writes of 8192 bytes at random offsets in a 256 MB scratch file,
 * opened O_SYNC; prints the latency histogram and the worst ten.  Delete the
 * scratch file afterwards.  Seconds to minutes depending on the card.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SCRATCH_BYTES (256u << 20)

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
  const char *path = argc > 1 ? argv[1] : "/media/fat/sdlat.tmp";
  unsigned size = argc > 2 ? (unsigned)atoi(argv[2]) : 8192;
  unsigned count = argc > 3 ? (unsigned)atoi(argv[3]) : 2000;
  if (size == 0 || size > (1u << 20) || count == 0) { fprintf(stderr, "bad size/count\n"); return 2; }

  /* the scratch file: written once, unsynchronised, so its blocks exist */
  int fd = open(path, O_RDWR | O_CREAT, 0644);
  if (fd < 0) { perror(path); return 1; }
  char *buf = malloc(1u << 20);
  memset(buf, 0x5a, 1u << 20);
  struct stat_like { long long sz; } st;
  st.sz = lseek(fd, 0, SEEK_END);
  if (st.sz < (long long)SCRATCH_BYTES) {
    lseek(fd, 0, SEEK_SET);
    for (unsigned off = 0; off < SCRATCH_BYTES; off += (1u << 20))
      if (write(fd, buf, 1u << 20) != (1 << 20)) { perror("fill"); return 1; }
    fsync(fd);
  }
  close(fd);

  fd = open(path, O_RDWR | O_SYNC);
  if (fd < 0) { perror("O_SYNC open"); return 1; }

  /* the histogram: <1, <2, <5, <10, <20, <50, <100, <200, <500, <1000, <2000, >=2000 ms */
  static const double edge[] = {1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000};
  unsigned hist[12] = {0};
  double worst[10] = {0}; unsigned worst_i[10] = {0};
  double total = 0, max = 0;
  srand(12345);
  for (unsigned i = 0; i < count; i++) {
    unsigned blocks = SCRATCH_BYTES / size;
    off_t off = (off_t)(rand() % blocks) * size;
    buf[0] = (char)i;
    double t0 = now_ms();
    if (pwrite(fd, buf, size, off) != (ssize_t)size) { perror("pwrite"); return 1; }
    double dt = now_ms() - t0;
    total += dt; if (dt > max) max = dt;
    int b = 0; while (b < 11 && dt >= edge[b]) b++;
    hist[b]++;
    for (int w = 0; w < 10; w++) if (dt > worst[w]) {   /* insert, keep sorted */
      for (int k = 9; k > w; k--) { worst[k] = worst[k - 1]; worst_i[k] = worst_i[k - 1]; }
      worst[w] = dt; worst_i[w] = i; break;
    }
  }
  close(fd);

  printf("sdlat: %u O_SYNC writes of %u bytes, random offsets in %s\n", count, size, path);
  printf("  mean %.2f ms, max %.1f ms\n", total / count, max);
  const char *lab[] = {"<1", "<2", "<5", "<10", "<20", "<50", "<100", "<200", "<500", "<1000", "<2000", ">=2000"};
  for (int b = 0; b < 12; b++) if (hist[b]) printf("  %7s ms: %u\n", lab[b], hist[b]);
  printf("  worst:");
  for (int w = 0; w < 10 && worst[w] > 0; w++) printf(" %.0f(#%u)", worst[w], worst_i[w]);
  printf("\n  the IO-stall watchdog ended a transfer at 535 ms (2^24) before, 8.6 s (2^28) now\n");
  return 0;
}
