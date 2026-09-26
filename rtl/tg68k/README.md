# rtl/tg68k - the TG68K.C 68030 kernel, as imported

Imported 2026-09-26 for SE30_PLAN.md 1.13 (the kernel's 32-bit bus). The
kernel is ours to change (plan 1.12, owner's decision); this file records
where it came from so the delta stays listed. **The delta since the import
is plan 1.15's beat engine** (steps 2a, 2b, 2c); the import commit is
`8366903`, so `git diff 8366903 -- rtl/tg68k` shows exactly what we changed.

| file | from | as taken |
|---|---|---|
| `TG68K_Pack.vhd` | `apolkosnik/Minimig-AGA_MiSTer@030_mmu2`, tip `c3e8a0d` (2026-07-25) | byte-identical, LF |
| `TG68K_ALU.vhd` | the same, **plus the one hunk the plan says to take**: `danifunker/MacIIvi_MiSTer@498eb34` (2026-08-15), the DIVU divide-by-zero CCR correction adjudicated on a Macintosh IIcx capture (plan 1.12's table) | LF; 20 changed lines against upstream, **plus the `beat_step` input of plan 1.15** |
| `TG68K_PMMU_030.vhd` | upstream `c3e8a0d` | byte-identical; `ATC_ENTRIES` stays 22 (the IIvi's 22 -> 8 is an area workaround the plan declines) |
| `TG68KdotC_Kernel.vhd` | upstream `c3e8a0d` | LF; **our change: the beat engine of plan 1.15** - n bytes a beat, the 32-bit shape by the `DATA_WIDTH` generic with `dsack` in and `siz` out, and the fetch unit (the aligned-long prefetch with a holding register; the core's acknowledge is `clkena_core`). `git diff 8366903 -- rtl/tg68k` is the whole delta from the import |
| `TG68K_Pack.vhd` (again) | | the ALU component gained `beat_step` |
| `TG68K_Cache_030.vhd` | upstream `c3e8a0d` | byte-identical, CRLF as upstream has it |

Not taken: `TG68K.vhd` (upstream's Amiga top; the Mac bus wrapper is
`tg68k.v`, still to be written for this core - plan 1.13 item 4),
`TG68K_CacheCtrl_030.vhd` (reference only in the IIvi build), `TG68K.qip`
(no Quartus project yet). Line endings are as inherited.

Licence: LGPL-3, per the headers (Tobias Gubener 2009-2020 and the patch
authors named there; the 68030 PMMU, cache and audit work are apolkosnik's).

The reference clones are at `C:\Git\MiSTer-devel\Minimig-AGA_MiSTer_030_mmu2`
and `C:\Git\MiSTer-devel\MacIIvi_MiSTer`; `diff` against them is the way to
see the delta. Benches: `sim/kernel_bus/` (the bus beats, plan 1.14),
`sim/pmmu_rom_contract/` (the PMMU alone).
