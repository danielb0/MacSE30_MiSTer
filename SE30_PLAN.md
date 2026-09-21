# Plan: a Macintosh SE/30 model

Written 2026-09-21, in `MacPlus_MiSTer` on a parking branch. Transferred to
this repo the same day and revised here; work proceeds on `dev`.

**Revision 2026-09-21b.** Section 1 has been revised after reading the
upstream audit documents named in 1.2 and surveying the emulator and CPU-core
field. 1.5, 1.6 and 1.8 gained addenda; **1.7 was rewritten**; 1.9 was
re-ordered and two of its items closed; 1.10 is new. The original text of 1.1
to 1.4 stands.

**This document is being composed in sections, each one following its own
research pass.** Only Section 1 is written. It settles the CPU and the PMMU,
because that was the only open question capable of making the project
impossible. Nothing about the GLUE address map, the ASC, the SWIM, video,
SCSI or RAM sizing should be inferred from what is written here - those
sections do not exist yet, and the facts they need have not been read.

## Why this is a new core, not a `mac_model.v` entry

Adding the 512Ke was seven lines in `rtl/mac_model.v` because a 512Ke is a
Plus with two straps changed. An SE/30 shares almost nothing structural with
this core:

| this core | SE/30 |
|---|---|
| `cpuAddr` is `[23:0]` throughout (`MacPlus.sv:508`) | 32-bit machine |
| Plus/SE decode: ROM $400000, VIA $EFE1FE, IWM $DFE1FF (`rtl/addrDecoder.v`) | GLUE, I/O in the $5000_xxxx block |
| PWM sound buffer scanned out of RAM | ASC - no scan, no phase; `SOUND_PHASE_PLAN.md`'s entire problem space is absent |
| IWM / GCR | SWIM / FDHD |
| 68000 (fx68k) or the fantasy 020 | 68030 + PMMU + 68882 |

The base to build on is **`MacLC_MiSTer`**, not this repo. It already carries
32-bit CPU address plumbing (`rtl/addrController_top.v:18`), `asc.sv`,
`swim.v` with the MFM encoder/decoder pair, and a TG68K it already knows how
to regenerate. What this repo contributes is the 1-bit video path and the
VIA-shift-register ADB the SE/30 uses (`rtl/adb.sv`), which is the SE's
mechanism, not the LC's Egret.

---

# Section 1 - the CPU and the PMMU

## 1.1 The question this section had to answer

68030 Macs implement 24-bit compatibility mode *through* the on-chip PMMU
rather than by hardware address truncation, and the SE/30 boots in 24-bit
mode. If that is right, the boot ROM programs TC, CRP/SRP and the
translation tables early and expects translation to actually happen - so a
CPU without a working PMMU never reaches the Happy Mac.

TG68K has no MMU. `MacLC_MiSTer/docs/tg68kmissing.md` records MOVES as absent
and F-line traps as the mechanism by which the LC's ROM discovers there is no
MMU to talk to. Writing a 68030 PMMU from scratch - table walker, ATC,
transparent translation, format-$B fault frames with instruction restart -
would have been the dominant cost of the whole project and the reason to not
attempt it.

## 1.2 The answer: it exists, it is TG68K, and it boots

`danifunker/MacIIvi_MiSTer` (Macintosh IIvi, MC68030 @ **15.6672 MHz** -
the SE/30's exact clock, C15M = 31.3344 MHz / 2) carries:

```
rtl/tg68k/TG68K_PMMU_030.vhd        5,004 lines   the PMMU
rtl/tg68k/TG68K_Cache_030.vhd         376         on-chip cache
rtl/tg68k/TG68KdotC_Kernel.vhd     10,509         kernel, PMMU instantiated at :874
rtl/tg68k/TG68KdotC_Kernel.v      103,693         ghdl-synth output, PMMU inlined
68030_PMMU_TESTBENCH.md                           the verification campaign
SingleStepTests/pmmu/, results/pmmu/              MAME-captured corpus
```

Its `TG68K.qip` header names the provenance: *"TG68K.C 68030 core (030_mmu
branch) for the Mac LC II."* The repo's readme claims Mac OS 7.1 and 7.5.5
boot to the Finder on hardware with the PMMU active.

**That claim is theirs, not something this plan has verified.** Verifying it
is milestone 1 of Section 1's work, not an assumption to build on. But the
RTL is real - I read it - and its shape is consistent with a working
implementation rather than a sketch.

Both repos are GPLv2, same as our lineage. Per settled precedent, no
licensing question to raise.

## 1.3 What the RTL actually is

From the entity in `TG68K_PMMU_030.vhd:24-108`, the implementation covers:

- **Registers** TC, TT0, TT1, CRP, SRP (64-bit, via `reg_part`), MMUSR,
  reached by PMOVE decode - `reg_sel` is `brief(14:10)`, so the F-line
  coprocessor-id-0 encoding, not MOVEC.
- **Instructions** PMOVE (incl. PMOVEFD via `reg_fd`), PTEST, PFLUSH, PLOAD.
- **A real table walker** with its own memory port (`mem_req` / `mem_we` /
  `mem_addr` / `mem_wdat` / `mem_ack` / `mem_berr` / `mem_rdat`), doing short
  and long descriptors, early termination, limit checks and **U/M bit
  read-modify-write writeback**.
- **A 22-entry ATC** with PFLUSH-variant invalidation.
- **Transparent translation** matched on FC + address.
- **Faults**: `fault_status` / `fault_addr` / `fault_fc` / `fault_rw` /
  `fault_is_insn`, plus a separate MMU-configuration exception path
  (`mmu_config_err` / `mmu_config_ack`, MC68030 vector 56).
- **MMUDIS** (`mmudis`, MC68030 UM 9.2.3) as an input, defaulted low. The
  header notes this default exists *"because the Amiga platform has no MMUDIS
  source"* - see 1.7.

The debug surface is enormous (every walk descriptor, per-level sticky
captures, ATC valid/buserr vectors, walker state). That is a gift for
bring-up and an area cost to audit later.

**Provenance note:** the header comments reference `cpu_wrapper.v`, Agnus,
Paula, the Blitter and AmigaOS. This PMMU was written for an Amiga 68030
project and adopted into the Mac line. That matters for 1.7.

## 1.4 The integration contract

This is the part that has to be re-created on our base, and it is the real
deliverable of Section 1.

The PMMU is **instantiated inside the kernel** (`TG68KdotC_Kernel.vhd:874`),
not bolted on outside it. ghdl-synth inlines it, so the generated
`TG68KdotC_Kernel.v` is self-contained. The host therefore does not wire the
PMMU; it wires the *kernel*, which now has four new obligations:

**1. The CPU strap gains a third value.** `CPU = "10"` selects 68030-with-PMMU
(`TG68KdotC_Kernel.vhd` entity: `00->68000 01->68010 10->68030 (with PMMU)`).

> `68030_PMMU_TESTBENCH.md:138` says `CPU=2'b11`. **The doc is stale; the RTL
> is right.** That doc is dated 2026-06-12 and also describes the PMMU as a
> separate `pmmu_top` wrapper still to be built. The design moved. Read the
> VHDL, not the plan.

**2. The walker's memory port must be arbitrated onto the bus.** The kernel
exports `pmmu_walker_req` / `_we` / `_addr` / `_wdat` / `_ack` / `_data` /
`_berr`. In the IIvi these do *not* get a private SDRAM port - `tg68k.v`
turns them into ordinary bus cycles and raises `dbg_walk_cycle_o` while one
is in flight. The top then treats that cycle specially in the DTACK glue
(`MacIIvi.sv:1010`):

```verilog
wire walk_read = cpu_walk_cycle & (selectRAM | selectVRAM) & _cpuRW;
...
if (!_cpuAS & ( (cpuBusControl & mem_latch_d & ~walk_read)
              | (cpuBusControl & walk_read & sdram_ram_ready)
              | (!selectROM & !selectRAM & !selectVRAM) )) dtack_en <= 1;
```

Only the borrowed walk read waits for real SDRAM data-valid; every normal
access keeps the fast slot-start ack. Their comment records the failure mode
that forced this - the walk cycle is phase-misaligned with the SDRAM command
slot, so without the gate it latches `dout` before the read completes and
captures stale data, which presented as *"the 10MB-boot Sad Mac"*.

**This is good news for us.** That `dtack_en` / `cpuBusControl_d` idiom is our
own, evolved - compare `MacPlus.sv:594-617`. The walker gate is an addition
to a structure we already maintain, not a foreign one.

**3. `beat_valid` must be qualified.** A new kernel input. On `pmmu_fault` the
wrapper releases `clkena_in` so the exception can dispatch, but that
force-completed beat carries bus garbage; `beat_valid = 0` tells the core to
advance while consuming no data (stream latches, extension capture, directPC
and opcode retire all gate on it). It defaults to `1`, so a host that ignores
it silently gets the old behaviour and a corrupted fault path.

**4. FC=7 must bus-error, and MOVES now exists.** `MacIIvi.sv:1052-1060`
splits CPU space: `$F` is interrupt acknowledge and autovectors via VPA;
everything else must have no responder, with **both** VPA and DTACK
suppressed. Their comment: *"The boot ROM probes for hardware with `moves`
accesses (SFC=7) that MUST bus-error; asserting VPA there wrongly completes
the probe and corrupts the machine-config word."* This is an LC-lineage
finding and it is exactly the class of bug that costs a week if inherited
silently. Note the 030 kernel implements MOVES, which the LC's 020 kernel did
not - so the probe reaches the bus at all, which is why the rule matters now.

## 1.5 What 24-bit mode costs the hardware: nothing

Worth stating plainly because it removes work I had assumed.
`MacIIvi_MiSTer/docs/VASP_RETARGET.md:45`:

> 24-bit compatibility mode needs **no hardware translation** on an 030 Mac -
> the OS implements it with the PMMU (which this CPU core has); MAME's
> `maciivi` models none either.

So the SE/30 decoder is a **pure 32-bit decoder**. There is no 24-bit mode to
build, no truncation strap, no dual decode. The compatibility mapping is
software in the ROM's translation tables, and the PMMU we are importing is
what executes it. My earlier sketch of this project called for "a new
addrDecoder plus 24-bit mode" - the second half of that was wrong and is
withdrawn.

**Addendum - but 24-bit is the SE/30's *normal* mode.** The above is right
about the hardware and incomplete about the machine. The SE/30's ROM is
**32-bit dirty**: it contains 24-bit addressing code, so its Memory Manager
is not 32-bit clean, and a stock machine runs in 24-bit mode and sees
**8MB**, however much is fitted. 32-bit addressing needs either MODE32
(Connectix - period-correct, and built into System 7.5.3 / 7.5.5) or a Mac
IIsi / IIfx ROM SIMM, which is a hardware modification.

So 24-bit is not an edge case to get to eventually. It is the path a stock
SE/30 boots down every time, and it has to work first.

**Decided: the core targets the authentic machine - its own ROM, 24-bit, 8MB
- and period enhancements become menu options once the base machine works.**
Same shape as the MacPlus sound-phase call, where authentic behaviour is the
release default and the enhancement is an option on top.

Two consequences. **RAM sizing has an authentic ceiling of 8MB**, and the
IIvi's recent unlock to 48MB must not be copied - the IIvi is a 1993 machine
with a clean ROM, and an SE/30 doing that on its own ROM is a machine that
never existed. And **most of the "32-bit enhancement" is not core work**:
MODE32 is a disk-resident System extension and an alternative ROM is just a
different file, so all the core owes an enhancement path is full 32-bit
decode - which it has anyway, per above - and a RAM-size menu option above
8MB. Authenticity-first therefore constrains the default menu setting, not
the RTL, which makes it a cheap decision and a reversible one.

One open detail for the RAM section: MAME does SE/30 RAM-size configuration
in `via2_out_a`, so whatever size is offered has to reach the ROM as a valid
strap combination. What configurations the real ROM accepts, and whether
fitting more than 8MB with a stock ROM boots-and-ignores or confuses it, is
unread.

## 1.6 Cost

| item | number | source |
|---|---|---|
| PMMU logic | **~4.8k ALMs** | `MacIIvi.qsf:56` |
| generated kernel, 030 + PMMU + cache | 103,693 lines | measured |
| generated kernel, MacLC's 020 | 35,221 lines | measured |
| MacPlus today | 20,720 / 41,910 ALMs (49%), 135/553 RAM blocks | `output_files/MacPlus.fit.summary` |
| MacLC today | ~29.6k ALMs (71%), 503/553 RAM blocks | `MacLC_MiSTer/docs/CPU_Improvements_Prompt.md` |
| MacIIvi today | ~100% ALM; LOW placement effort fails fitter 170012 | `MacIIvi.qsf:50-60` |

The IIvi runs ~100% because it *additionally* carries NuBus and the mdc824
colour complex. An SE/30 needs neither, and its 1-bit 512x342 framebuffer
lives in main RAM rather than in the ~384 RAM blocks the LC spends on a
colour framebuffer. Their own per-entity audit (`MacIIvi.qsf:57-60`) found
every family-shared entity at or below the MacLC numbers - the IIvi's
overflow is device fullness, not a port regression. **Area looks survivable,
but it is not yet proven for our configuration and must not be treated as
settled.**

**Open - the framebuffer claim above is contradicted by MAME.**
`src/mame/apple/macii.cpp` maps dedicated VRAM, not main RAM:

```cpp
map(0xfe000000, 0xfe00ffff).ram().share("vram");
map(0xfee00000, 0xfee0ffff).ram().share("vram");
map(0xfeffe000, 0xfeffffff).rom().region("se30vrom", 0x0);
```

plus an `se30vrom` ROM region this plan has not accounted for at all. The
RAM-block half of the area argument rests on which of these is right, so it
is **not settled** until confirmed against hardware sources. The ALM half of
the argument does not depend on it.

## 1.7 Known deviations and risks

**RMC / atomic table search - confirmed, and it is our problem.** Documented
at the top of `TG68K_PMMU_030.vhd:8-20`; MC68030 UM 9.5.2 requires RMC
asserted for the whole duration of a table search so no other master can
interleave. The upstream port audit states the position as a contract term,
not an aside:

> "The port does *not* implement privileged RMC ... or atomic LOCK prefixes"
>
> "Host must not assume table-walker bus cycles hold BG or participate in
> multimaster arbitration"
>
> "External bus masters (DMA, debugger) may interleave with walker cycles;
> the PMMU does not serialize walks"
>
> "Host responsibility: External bus masters must coordinate via chipset
> arbitration"

So there is no mitigation that fails to transfer - the obligation is
delegated to the host by design. We must establish what else can be master of
our bus during a walk - floppy staging, SCSI pseudo-DMA, the video fetch -
and whether any of it can touch page-table memory. **This is design work in
Section 1, not a check**, and the answer may change the arbitration design.

**MMUDIS - there is no pin.** The entity carries an `mmudis` input defaulted
low (1.3), but the upstream port provides no wiring or support for it: "TC.E
is the sole disable lever." So if the SE/30's GLUE drives MMUDIS we get
nothing from upstream and would be building it ourselves. Whether GLUE drives
it at all is still unread.

**The kernels have diverged, and ours is the fork.** danifunker states the
PMMU came from `apolkosnik/Minimig-AGA_MiSTer` branch `030_mmu2`, and that he
"had to modify the kernel to handle BERR and STOP commands for Macintosh" and
"handle some of the PMMU commands a little differently as well, so the
kernels are a little bit different." That confirms 1.3's inference from the
Agnus/Paula/Blitter header comments, and gives the old "kernel bug drift"
warning a concrete shape: **at least two kernels, diverged, neither a
superset.** The Mac-specific fixes exist only in danifunker's; the audit
trail and the test suite exist only in apolkosnik's. BERR handling is
directly the FC=7 MOVES obligation in 1.4. **Diffing the two kernels is a
work item.** `68030_PMMU_TESTBENCH.md:281`'s advice stands - fix the VHDL and
re-run the converter, never patch the generated Verilog - and our
line-endings-by-provenance rule applies with force: these are inherited files.

**Upstream health, from the audit documents.** `030_MMU_PORT_AUDIT.md`
(91KB), `MMU_AUDIT.md` (72KB), `REVIEW_2026-07-23_CPU_MMU_CACHE.md` (32KB)
and `CPU_AUDIT.md` (21KB) on `030_mmu2` are a serious numbered audit trail -
roughly 100 defects (BUG #371 to #470) found and fixed across CPU, MMU and
cache. Good evidence of rigour, and equally evidence that this was
substantially broken recently. Open at the time of reading:

| item | state |
|---|---|
| JMP post-trace returns to wrong PC (real cputest BASIC) | **open**; isolated reproducer passes, failure depends on cumulative state |
| `mmu.library` $B000 access fault, photographed on hardware | **open**; needs a full integration test |
| `tb_cpu_wrapper_pmmu` scenarios 3-4, `tb_pmmu_comprehensive` F6 `fault_fc`, two older frame-format tests | pre-existing failures; the suite is **not green** |
| L1 cache | force-disabled by BUG #454, re-enabled 2026-07-24, **hardware soak still pending** |

**Host obligations the contract in 1.4 does not yet carry.**

- **Walker timeout**: BERR after ~503 busy cycles, and "host clock must not
  stall during active walks without asserting external DTACK." A hard number
  our SDRAM design has to respect.
- **ATC coherency is manual**: a CACR writeback does not flush the ATC;
  `PFLUSH` / `PFLUSHA` only.
- **Vector 2 only** for internal PMMU faults, not the 68851's vector 61.

**Deviations from the MC68030 UM that could bite a Mac ROM.** Six intentional
ones are documented. Three matter to us:

1. **PMMU registers are PMOVE-only.** The UM lists TC/TT0/TT1/MMUSR as
   MOVEC-accessible; the kernel's MOVEC whitelist *excludes* them, and such
   attempts trap as privilege violations. **If the SE/30 ROM reaches a PMMU
   register through MOVEC, it breaks.** Concrete, testable, and exactly what
   1.9 item 2 should be looking for.
2. **Format $B internal state ($20-$5C) is mostly zeroed**, except the
   stage-B address ($24) and the data-input buffer ($2C) - "sufficient for
   PTEST-based fault re-resolution but incomplete for handlers inspecting
   access records." Matters only if the Mac's handler reads those fields.
3. **Format $A offset $08 is truncated** to the LASTWRITE bit; full pipeline
   state is "impossible without pipeline tracking not present in the TG68K
   micro-engine." Structural, not cheaply fixable.

The other two deviations are *stricter* than WinUAE and spec-correct (RMW
transparent translation, reserved-bit masking).

**Two contradictions found while reading, recorded so they are not
rediscovered.** The audit documents disagree on the size of a Format $B
frame: `MMU_AUDIT.md` says 92 bytes (23 longs), the port audit says 48. **92
matches the MC68030 UM**; verify before relying on either. Separately, a
machine summary of these documents asserted that the MC68030 has neither RMC
nor MMUDIS. **Both claims are false** - UM 9.5.2 and 9.2.3 respectively - and
were summariser artifacts, not findings.

**PMMU oracle fidelity - and the cross-check is already done.** The IIvi's
corpus is MAME-captured, with two oracle quirks already found and
cross-checked against FS-UAE A3000 and a physical Macintosh IIcx. Upstream
has additionally cross-checked the RTL against WinUAE's `cpummu30.cpp`
directly: **13 aspects confirmed identical, 10 real differences documented.**
That largely closes the "cross-check against a second, independent 030 MMU"
item this plan would otherwise have raised. The canonical open implementation
is `cpummu030.c`, written by Andreas Grabher for **Previous** and shared by
Previous, WinUAE and Hatari - and it is already the reference they used.
Their rule and ours agree: real silicon outranks any emulator where the two
disagree.

**Simulation strategy is now an open decision, not a measurement.** This
subsection previously read "we sim with iverilog, they sim with Verilator"
and proposed measuring iverilog against the 103,693-line generated kernel.
That framing was too narrow. It has moved to **1.10**, which supersedes it.

**The regeneration path has environment traps.** `convert_to_verilog.sh`
documents them: ghdl-llvm needs a stashed `libLLVM-18` via `LD_LIBRARY_PATH`;
emitting ~6MB of Verilog through the WSL `/mnt/c` 9p mount runs at ~100KB/min
(25+ minutes) versus ~2 minutes on a native ext4 path; and GHDL 6.0.0 rejects
`-g` generic overrides, so the entity defaults must be used. We already have a
WSL toolchain, so this is transcription rather than discovery. **Note that
1.10 may remove the need to regenerate at all.**

## 1.8 What Section 1 does not settle

- Whether the SE/30 ROM's demands on the PMMU are the same as the IIvi's.
  Same CPU and same clock, but a 1989 256K ROM is not a 1992 1MB ROM. The
  MAME SE/30 driver and the ROM's own `StartBoot` path are the sources.
- The FPU. Every SE/30 shipped a 68882; TG68K has none and the IIvi
  deliberately has none because a stock IIvi has none. `AP68040`'s
  `ap040_fpu.v` (2,343 lines, extended precision) is the only open 68k FPU
  found, and it is an 040 FPU in an 040 core. Leaving it out boots, but
  produces a machine that never existed - which is the thing this project
  exists to avoid. **Open**, and now better understood: `ap040_fpu.v` is a
  **separable module** with an FPSP trap path, which is better news than "an
  040 FPU welded into an 040 core". But it is still an 040 FPU - the 040
  omits the transcendentals the 68881/68882 execute in hardware, which is
  precisely what its FPSP path exists to trap, and the 68882 is a
  **coprocessor on the F-line coprocessor interface**, not on-chip. Dropped
  in unmodified it yields an SE/30 that traps where real silicon computed.
  *Unverified detail; confirm against the manuals.* That the coprocessor
  interface is a real discriminator between 030 cores is corroborated by
  WF68K30L, which omits it and so could not host a 68882 either.
- Anything about GLUE, ASC, SWIM, video, SCSI or RAM sizing.

## 1.9 Proposed work for Section 1

Cheap and decisive first, per standing practice. Revised: two original items
are closed by the survey, one is reframed.

1. **Settle the simulation strategy** (1.10). This gates the verification
   ladder for everything downstream, so it comes before any further plan
   section. It is now a decision to take rather than only a number to
   measure - but the measurement in 1.10 bounds one of the options and is
   cheap.
2. **Read the SE/30 ROM's `StartBoot` / MMU path** and MAME's SE/30 driver,
   now located at `src/mame/apple/macii.cpp`. Confirm the 1.1 premise against
   the actual ROM rather than by analogy with the IIvi. **Look specifically
   for MOVEC access to PMMU registers** (1.7), which would break outright.
3. **Diff danifunker's kernel against `030_mmu2`**, to recover the
   Mac-specific BERR / STOP / PMMU changes as an explicit reviewable set
   rather than an opaque inheritance (1.7).
4. **Enumerate our bus masters** against the RMC obligation in 1.7 and design
   the arbitration. Promoted from a check to design work.
5. **Reproduce the IIvi's claim**: build their core, boot it, confirm the
   PMMU is live - and establish whether it boots 24-bit or 32-bit, since
   danifunker is himself unsure and 1.5 makes 24-bit our primary path.
6. Only then: cut the CPU into a MacLC-derived tree and bring up ROM + RAM to
   a first fetch.

**Closed by the survey, not by work:** generating a cputest 68030 corpus - it
exists upstream as packaged `68030_Basic` and `68030_ODD_IRQ` data with
`decode_cputest_dat.py` - and cross-checking the PMMU against a second
independent 030 MMU, done upstream against WinUAE's `cpummu30.cpp`.

**Also closed: the search for a better CPU.** Three further leads were
examined. `apolkosnik/before` is a NeXTcube and therefore **68040**.
`AP68040` itself is hand-written modular Verilog, iverilog-benched, with
3,776 / 3,801 cputest slices passing - but **68040-only, no 030 mode**.
`AmicableComputers/wf68k30L` is a pipelined VHDL 68030 which explicitly has
**no MMU, no caches and no coprocessor interface** ("Missing MMU operations
are: PFLUSH, PLOAD, PMOVE and PTEST"). None displaces TG68K. WF68K30L is
still worth keeping as a *readable* 030 cross-reference, which is how
upstream uses it too.

One caution about that result: it is **not** independent corroboration.
`apolkosnik` wrote the `030_mmu2` PMMU, AP68040 *and* `before` - three of the
four leads are one author. The only genuinely independent 68030 data point is
WF68K30L, and it has no MMU. The conclusion stands - TG68K's `030_mmu` line
is the only 68030 soft core with a working PMMU - but the reason is that the
field is one prolific author plus an MMU-less core, not that independent
implementations converged.

**And a caution about inheriting judgement.** danifunker states plainly that
"none of the computer cores are cycle accurate", and that his goal is "a
plug-and-play easy solution for people with MiSTerFPGA to experience the joy
of color Macintosh computers." His findings are valuable as *engineering* -
the walk-read DTACK gate and the FC=7 rule in 1.4 fixed real bugs and we
should take both - but they carry **no authenticity weight**. "The LC does X"
or "the IIvi does X" is not evidence that real hardware did X. That is the
argument for item 2 above.

---

## 1.10 Simulation strategy

**The problem, stated correctly.** Upstream's verification is **ModelSim
running VHDL testbenches** (`tests/tg68k_030/*.vhd`, driven by `make -C
tests/tg68k_030 <target>`), and the suite is substantial: `test-arch-suite`,
`test-fault`, `test-advanced`, `test-trace-suite` and `test-real` (DiagROM
MMU detection, `mmu.library`, WhichAmiga, 68030.library), gated by
`validate`. **iverilog cannot run VHDL**, so none of that investment
transfers as-is. That, not the line count, is the real finding.

The 103,693-line generated kernel is also less central than 1.6 implies.
**Quartus compiles the VHDL directly** via `TG68K.qip`; the generated `.v`
exists because upstream chose Verilator. It is a simulation artifact of
someone else's tool choice and it is not on the build path at all.

Why it is so long, since the number invites suspicion: `ghdl synth` does not
translate, it **elaborates** - generics resolved, generate statements and
loops unrolled, hierarchy flattened and sub-entities inlined, records and
enumerated types flattened to bit vectors, `case` lowered into mux trees, one
net per intermediate expression. Everything that made it maintainable is
exactly what gets spent. The ratio is milder than it looks, too: those
103,693 lines cover the inlined PMMU (5,004) and cache (376) as well as the
kernel (10,509) - 15,889 source lines, about 6.5x, which is unremarkable for
netlist-style output.

**Proposed split, by altitude.**

| altitude | language | simulator | why |
|---|---|---|---|
| CPU / PMMU verification | VHDL | ModelSim or GHDL | runs *their* suite; keeps the upstream link and their fixes |
| System benches (CPU + our GLUE + SDRAM) | Verilog, CPU as an opaque block | iverilog | we are debugging our system, not the CPU, so the generated file's unreadability costs nothing at this altitude |
| Our own RTL | Verilog | iverilog | unchanged from the MacPlus ladder |

This gets upstream's verification *and* Verilog system benches without owning
a CPU. It costs a VHDL simulator in the loop alongside iverilog.

**A hand translation of the kernel into readable Verilog was considered and
rejected.** ~15,900 lines; the errors would be silent and idiosyncratic where
a compiler's are systematic and findable; it would fork us permanently from
roughly 100 upstream fixes with two still open; and it would strand their
test suite, whose re-creation is plausibly a larger job than the translation
itself. If it is ever revisited, the only responsible route is differential
verification of both cores against the cputest corpus - which costs more than
the translation.

**Open items for 1.10.**

1. Whether the Quartus install carries a ModelSim / Questa edition that can
   take a 103k-line design. The free Starter editions have historically been
   line-limited. **Unverified - and it is a licence check, not a simulation
   run, so it is cheap and it eliminates one option outright if it fails.**
2. Whether GHDL will run upstream's benches as written, or whether they lean
   on ModelSim-specific constructs. GHDL is VHDL-only either way, so
   `tb_cpu_wrapper_pmmu.v` - the Verilog wrapper bench, and the one closest
   to what we would be re-creating - cannot run under it.
3. How the MacPlus core's existing benches handle `rtl/via6522.vhd`. That
   project already contains VHDL, so there may be a settled local precedent
   that decides this. **Unread.**

---

## Appendix - where the sources are

The two reference cores were shallow-cloned into a session scratchpad that does
not survive. Re-clone as needed:

| repo | why |
|---|---|
| `github.com/danifunker/MacIIvi_MiSTer` | **the important one.** 68030 + PMMU at 15.6672 MHz. `rtl/tg68k/TG68K_PMMU_030.vhd`, `68030_PMMU_TESTBENCH.md`, `SingleStepTests/pmmu/` |
| `github.com/danifunker/MacLCII_MiSTer` | also 68030; the qip header calls the PMMU branch "for the Mac LC II", so this may be the primary 030 target and the IIvi the follower. Not yet read |
| `github.com/danifunker/MacLC_MiSTer` | the proposed base. Already cloned at `C:/Git/MiSTer-devel/MacLC_MiSTer` |
| `github.com/danifunker/MacQuadra800_MiSTer` | 68040. Wrong MMU for us, but `rtl/ap68040/` is the only open 68k FPU found, its `tb/` is iverilog-based, and `scripts/` is a MiSTer hardware-automation harness worth taking on its own merits |
| `github.com/alanswx/AP68040`, `github.com/apolkosnik/AP68040` | AP68040 upstreams |

| `github.com/apolkosnik/Minimig-AGA_MiSTer` branch `030_mmu2` | **the PMMU's upstream**, named by danifunker. Carries the audit trail 1.7 now rests on - `030_MMU_PORT_AUDIT.md`, `MMU_AUDIT.md`, `CPU_AUDIT.md`, `REVIEW_2026-07-23_CPU_MMU_CACHE.md` - plus `tests/tg68k_030/` and the packaged cputest 030 data |
| `github.com/apolkosnik/before` | NeXTcube on MiSTer. **68040**, so not a CPU candidate, but an existence proof that a 68k core with a working MMU boots a demanding Unix on a DE10-Nano |
| `github.com/AmicableComputers/wf68k30L` | Wolfgang Foerster's pipelined VHDL 68030. **No MMU, no caches, no coprocessor interface** - useless as a CPU here, valuable as a *readable* 030 cross-reference against the generated kernel. Upstream uses it the same way |

GPLv2 or GPLv2-or-later where checked. **wf68k30L's licence has not been
checked.**

**Emulators and software references.**

| source | why |
|---|---|
| MAME, `src/mame/apple/macii.cpp` | **the SE/30 driver.** `macii_state::macse30()` is `maciicx(config)` plus "SE/30 = IIx with no slots and built-in video". Confirms M68030 @ 15.6672 MHz, ASC, SWIM1 with two 3.5" drives, NCR53C80, two VIAs @ 1.5667 MHz, RTC3430042, PDS in place of NuBus. **No GLUE device** - the decode lives in the address map, RAM sizing in `via2_out_a`. Chip models are shared devices: `devices/sound/asc.cpp`, `devices/machine/swim1.cpp`, `apple/macscsi.cpp`, `apple/macadb.cpp`, `apple/macrtc.cpp` |
| `cpummu030.c` (Previous / WinUAE / Hatari) | the canonical open 68030 MMU in C, by Andreas Grabher - the independent implementation of what `TG68K_PMMU_030.vhd` does |
| Previous, `github.com/probonopd/previous` | NeXT emulator. Emulates the original **68030** NeXT Computer, MMU working, boots every NeXTSTEP / OPENSTEP. Mach exercises an MMU far harder than System 7 does |
| Shoebill, `github.com/emaculation/shoebill` | Mac II / IIx / IIcx emulator that exists *specifically* to run A/UX. Plain C, emulates the MC68851 PMMU. The Mac-context MMU reference - A/UX is the Mac OS that actually uses one. **BSD-licensed**, so a reading reference, not a source of code for this project |

**Unrelated finding, worth keeping.** The Q800 repo documents a VIA
shift-register bug (`docs/adb-via-shift.md`): every delivered ADB byte was
shifted left one bit, losing bit 7 - the mouse button - so mouse *motion*
pressed and released it. Our `rtl/via6522.vhd:619-628` has the identical
construct, but the trigger appears absent: their `cb1_i` is tied to `1'b0`
while ours is a real `kbdclk` that idles high
(`rtl/dataController_top.sv:425`), and we have no external-completion shim
loading `shift_reg`. Code-reading only, not simulated.

Also in that repo and independent of this project: `scripts/mister_ws.py`
(keyboard/mouse injection over the MiSTer Remote websocket, including held
keys), `grab.sh` (screenshot via HTTP API), and `menubar_probe.py` /
`menuitem_probe.py` / `finder_probe.py` (read Mac UI state back out of the
screenshot pixels). That turns the game-compatibility campaign from a manual
hardware loop into a scripted one.
