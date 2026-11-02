# rtl/tg68k - the 68030

| file | from |
|---|---|
| `TG68K_Pack.vhd`, `TG68KdotC_Kernel.vhd`, `TG68K_ALU.vhd` | the TG68K.C kernel (Tobias Gubener), as carried by `apolkosnik/Minimig-AGA_MiSTer` branch `030_mmu2` (`c3e8a0d`), with the DIVU divide-by-zero CCR fix from `danifunker/MacIIvi_MiSTer` (`498eb34`); changed here: the 68030 bus (dynamic bus sizing, 32-bit port, fetch unit), the paced timing hooks, and instruction fixes |
| `TG68K_PMMU_030.vhd` | apolkosnik's 68030 PMMU, the same branch |
| `tg68k.v`, `se30_cache030.v`, `se30_pace030.v` | this core: the kernel on the 68030 bus, the 68030's caches, and its instruction timing (MC68030 User's Manual, Section 11) |

The changes to the kernel and the PMMU are listed in `TG68K_030_changelog.md` in the repository root.

**Known limitation - read before taking this kernel for another machine.** A
bus-error handler that returns with DF set (the page-fault path) makes this
kernel re-execute the whole instruction; the 68030 reruns only the faulted
cycle (UM 8.2.3). An FPU operand split across the faulting page likewise
reruns its first cycle. The earlier accesses go out again: harmless for RAM,
but an I/O read with a side effect (a FIFO, a read-to-clear interrupt flag)
loses data - a real risk on a machine that pages memory while software
touches hardware, such as an Amiga under VMM, NetBSD or Linux. The SE/30 and
IIcx are unaffected. Details: the changelog's "Known open".

Licence: LGPL-3.0-or-later, per the headers (Tobias Gubener 2009-2020 and
the patch authors named there; the PMMU work is apolkosnik's).
