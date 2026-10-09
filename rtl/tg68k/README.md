# rtl/tg68k - the 68030

| file | from |
|---|---|
| `TG68K_Pack.vhd`, `TG68KdotC_Kernel.vhd`, `TG68K_ALU.vhd` | the TG68K.C kernel (Tobias Gubener), as carried by `apolkosnik/Minimig-AGA_MiSTer` branch `030_mmu2` (`c3e8a0d`), with the DIVU divide-by-zero CCR fix from `danifunker/MacIIvi_MiSTer` (`498eb34`); changed here: the 68030 bus (dynamic bus sizing, 32-bit port, fetch unit), the paced timing hooks, and instruction fixes |
| `TG68K_PMMU_030.vhd` | apolkosnik's 68030 PMMU, the same branch |
| `tg68k.v`, `se30_cache030.v`, `se30_pace030.v` | this core: the kernel on the 68030 bus, the 68030's caches, and its instruction timing (MC68030 User's Manual, Section 11) |

Licence: LGPL-3.0-or-later, per the headers (Tobias Gubener 2009-2020 and
the patch authors named there; the PMMU work is apolkosnik's).
