/* Linux shim for WinUAE's cputest generator (SE/30 core, plan 8.9.8) */
#include <sys/stat.h>
#include <sys/types.h>
static inline int _wmkdir(const char *p) { return mkdir(p, 0777); }
