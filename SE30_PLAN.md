# Plan: a Macintosh SE/30 model

Written 2026-09-21, in `MacPlus_MiSTer` on a parking branch. Transferred to
this repo the same day and revised here; work proceeds on `dev`.

**Revision 2026-09-21b.** Section 1 has been revised after reading the
upstream audit documents named in 1.2 and surveying the emulator and CPU-core
field. 1.5, 1.6 and 1.8 gained addenda; **1.7 was rewritten**; 1.9 was
re-ordered and two of its items closed; 1.10 is new. The original text of 1.1
to 1.4 stands.

**Revision 2026-09-25.** 1.9 item 2 is done: the SE/30 ROM has been read.
**1.11 is new** and records what the ROM asks of the PMMU. 1.7's risk item 1
is withdrawn (its premise was a 68040 fact), 1.8's first bullet is answered,
and 1.5's claim that 24-bit mode is the PMMU's work now rests on the ROM's
own tables rather than on another project's prose.

**Revision 2026-09-26.** 1.13 item 1 is done: **1.14 is new** and records
UM 7.2 as one rule, checked against its four tables, with the kernel's
byte mask read against it; the oracle for the kernel's 32-bit bus exists.
Later the same day: the kernel is imported (`rtl/tg68k/`), and the
kernel-alone bench of 1.13 item 3 runs on it - the 16-bit kernel already
matches the manual for every CPU operand; the five-byte bit field is the
first failing test of item 2.

**Revision 2026-09-26, later.** 1.13 is complete: the kernel has the
68030's bus (1.15's steps 2a-2c), GLUE is re-cut to 2.11.1 and the two
are benched together (`sim/system/`). **Section 3 is new**: the tree -
framework, clocks, the SDRAM controller and map, the ROM images, the
top and the machine module, and the bring-up ladder to the first fetch -
written before the cut, which is its item 2.

**This document is being composed in sections, each one following its own
research pass.** Section 1 settles the CPU and the PMMU, because that was
the only open question capable of making the project impossible. **Section
2 (GLUE, the address map, RAM, clocks, video) was opened 2026-09-25 as a
first cut** with its own open-items list in 2.8, and is complete. **Section 3
(the tree) was opened 2026-09-26**, **Section 4 (the VIAs) 2026-09-27**, and
**Section 5 (the SWIM and the floppy drives) 2026-09-27**, its rung 1
designed in full and rungs 2-3 mapped to their sources, and **Section 6
(the ADB and the RTC) 2026-09-28**. Nothing about the ASC, the SCC, SCSI
or power should be inferred from what is written here - those sections
do not exist yet, and the facts they need have not been read.

**Revision 2026-09-27.** **Section 5 is new**: the SWIM from Apple's
documents (the 343S0061-A drawing, the chip spec, the User's Reference,
the ISM spec), the schematic's sheet 6 and the ROM's `.Sony` driver.
Daniel decided the data path is bit-level, not MacLC's byte-level
replica, and that the SWIM reaches the board in three rungs.

**Revision 2026-09-28.** **Section 6 is new**: the ADB and the RTC, from
the schematic's sheet 4, the *Guide*'s chapter 8, *Inside Macintosh*'s
hardware chapter, General Instrument's PIC manual and the ROM's ADB
Manager and clock code. Daniel decided the transceiver (UL11, a PIC1654S)
runs its own dumped program, the keyboard and mouse speak bit cells on
a modelled wire, and PRAM is volatile for now.

## Why this is a new core, not a `mac_model.v` entry

Adding the 512Ke was seven lines in `rtl/mac_model.v` because a 512Ke is a
Plus with two straps changed. An SE/30 shares almost nothing structural with
this core:

| this core | SE/30 |
|---|---|
| `cpuAddr` is `[23:0]` throughout (`MacPlus.sv:508`) | 32-bit machine |
| Plus/SE decode: ROM $400000, VIA $EFE1FE, IWM $DFE1FF (`rtl/addrDecoder.v`) | GLUE, I/O in the $5000_xxxx block |
| PWM sound buffer scanned out of RAM | ASC - no scan, no phase; `SOUND_PHASE_PLAN.md`'s entire problem space is absent |
| video scanned out of main RAM, contending with the CPU | **pseudo-slot video**: private 64K VRAM, a declaration ROM, no main-bus fetch. See 1.6 |
| IWM / GCR | SWIM / FDHD |
| 68000 (fx68k) or the fantasy 020 | 68030 + PMMU + 68882 |

The base to build on is **`MacLC_MiSTer`**, not this repo. It already carries
32-bit CPU address plumbing (`rtl/addrController_top.v:18`), `asc.sv`,
`swim.v` with the MFM encoder/decoder pair, and a TG68K it already knows how
to regenerate. What this repo contributes is the **1-bit video output
stage** and the VIA-shift-register ADB the SE/30 uses (`rtl/adb.sv`), which
is the SE's mechanism, not the LC's Egret.

**Be precise about the video, because the resemblance is superficial.** The
SE/30's display looks identical to a Plus - 512x342, 1bpp, 60.15 Hz, two
buffers - but only the *output* is shared. What transfers from here is sync
and blanking generation and the pixel shifter. What does not: the framebuffer
location, the fetch mechanism, the address map, and the declaration ROM,
which has no donor in this repo at all. A Plus scans video out of main RAM
and contends with the CPU for it; an SE/30 does neither (1.6). One useful
consequence: **the video fetch is not a main-bus master**, so it cannot
collide with the PMMU table walker - one contender fewer for 1.9 item 4.

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

**Confirmed from the ROM itself, 2026-09-25 - see 1.11.** The "translation
tables" are one sixteen-entry table at `$40800050`, and its eight RAM entries
are the 8MB ceiling described below, stated in hardware terms.

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
unread. Two facts toward it from the ROM read (1.11): MAME's pointer checks
out - `$4080366E` holds `01 02 04 05 08 10 11 14 20 40 41 44 50 80`, sizes in
MB, so the ROM's own table goes to 128MB - and the cold-start memory sizing at
`$40802BBC` runs with the 32-bit MMU row loaded, so the 8MB window is not what
bounds the sizing pass.

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
colour complex. An SE/30 needs neither, and its 1-bit 512x342 framebuffer is
far smaller than the colour one the LC spends ~384 RAM blocks on - **but it
is not free, and it does not live in main RAM; see the correction below.** Their own per-entity audit (`MacIIvi.qsf:57-60`) found
every family-shared entity at or below the MacLC numbers - the IIvi's
overflow is device fullness, not a port regression. **Area looks survivable,
but it is not yet proven for our configuration and must not be treated as
settled.**

**CORRECTED from Apple's documentation. The framebuffer is NOT in main RAM.**
*Guide to the Macintosh Family Hardware*, 2nd ed., Chapter 12, "Video display
in the Macintosh SE/30 computer":

> "The main logic board of the Macintosh SE/30 contains a **separate 64 KB
> video display RAM** and a **separate 8192-byte video declaration ROM**. The
> video display RAM occupies physical address space **$FE00 0000 to $FEFF
> FFFF**. This address space was chosen because it is the same as the address
> space used by expansion slot $E in the Macintosh II family."
>
> "The video buffer occupies RAM that is **separate from the main memory**."
>
> "independent RAM: 64 KB of RAM containing **two screen buffers**"

This is **pseudo-slot video**: the SE/30's video hardware deliberately
simulates a Macintosh II Video Card in a NuBus slot, so that the machine can
share the common MC68030 system ROM with the NuBus Macs. 512x342, 60.15 Hz,
no CLUT and no programmable timing controller, because it drives only the
built-in mono monitor.

**MAME was right and this plan was wrong.** `macii.cpp`'s map corroborates
exactly, including the arithmetic: `$FEFFE000`-`$FEFFFFFF` is `$2000` = the
8192-byte declaration ROM the Guide specifies.

```cpp
map(0xfe000000, 0xfe00ffff).ram().share("vram");
map(0xfee00000, 0xfee0ffff).ram().share("vram");
map(0xfeffe000, 0xfeffffff).rom().region("se30vrom", 0x0);
```

**Area consequence, and it is real.** We owe **64KB of VRAM** (~52 M10K
blocks) plus an **8KB declaration ROM** (~7 blocks) - roughly 59 blocks
against MacPlus's current 135/553. Affordable, but it is not the "free"
framebuffer this section previously assumed, and it must be carried in the
budget. The IIvi already does this with `rtl/vram_bram.sv`.

**And it is a requirement, not an implementation choice.** A declaration ROM
is how a NuBus card identifies itself; the ROM's video driver and
initialisation routines live in it. Section 2 must treat pseudo-slot video as
a structural feature of the machine, not as a video detail.

**Sources for that logic, and which board revision to target.** Apple's
*Guide* Table 3-7 gives the SE/30's general logic as "GLUE and video PALs".
The programmable half is six small parts - UI6, UH7, UG6, UG7, UE6, UE7 - and
**there are two board revisions with different parts in them.** Only UI6
(`341-0665-A`) and UH7 (`341S0689-C`) are common to both:

| posn | earlier board (bitsavers `se30_pals.jpg`) | later board (Bolle) |
|---|---|---|
| UI6 | 341-0665-A | **341-0665-A** |
| UH7 | 341S0689-C | **341S0689-C** |
| UG6 | 341-0635-A | 341-0747-A |
| UG7 | 341-0633-A | 341-0746-A |
| UE6 | 341-0637-A | 341-0754-A |
| UE7 | 341-0688-A (AMD) | 341-0755-A |

(2026-09-25: BOMARC's 1992 drawings, 2.1, are of a board marked
**820-0260-A** carrying the right-hand column's parts - so that is the
later board's number, and the VLSI part is confirmed as GLUE.)
bitsavers carries Apple fuse maps for only four of the earlier board's six
(Al Kossow's, read from "an SE/30 with unprotected PALs" - 68kmla thread
45231; the later board's parts are read-protected, which is why Bolle's set
is a behavioural rewrite), and **two of those four are bad dumps**: `3410635A` and `3410637A`
disassemble to degenerate nonsense - `vcc` repeated eight times, terms that
can never be true, five distinct rows in sixty-four.
`github.com/TheRealBolle/SE30`, a logicboard recreation, carries a complete
set of six for the later board, reverse-engineered rather than dumped.

**Decided: target the better-preserved revision - Bolle's complete six.**
Both boards are SE/30s running the same ROM, so both implement the same
machine; a coherent complete set beats a partial one spanning two respins.
And his work is trustworthy where it can be checked: his `UI6` is
**bit-for-bit identical to Apple's `3410665A`**, 0 of 2048 array fuses
differing.

**`scripts/jedec_dis.py`** recovers equations from any of these. Its fuse
conventions are *derived, not assumed* - it reproduces National's JED2EQN
output exactly on `3410633A`, which its `validate` subcommand re-proves on
demand. Two cautions it encodes:

- **Device type must be established per part.** Every bitsavers `.EQN` claims
  `PAL16R8`, but UI6's GAL config bits imply a **16R4**. A combinatorial
  output spends its first product term on the output enable, so assuming the
  wrong type silently misreads half the equations.
- **A fuse map carries no signal names.** The logic is exact and the pins are
  anonymous; `se30.pdf` must name them before any equation means anything.

Bolle's repo is **CC-BY-NC-SA**, incompatible with the GPLv2 this core must
carry. Read it and derive behaviour from it; incorporate none of it. This is
a real incompatibility, not the settled MiSTer-fork licensing question.

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

**The kernels have diverged, and ours is the fork.** ~~Superseded 2026-09-25
by 1.12: the IIvi re-synced to upstream's tip on 2026-08-15 and the kernel
is now byte-identical; the Mac-specific handling moved into the wrapper.
What follows is kept as the record of what was believed and why.~~
danifunker states the
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
| **16-bit external data bus** (2.13). The kernel moves a longword as two 16-bit beats; the real 68030 moves it in one 32-bit cycle. GLUE hides the cost for RAM and ROM (a beat flagged `lw` is 2 clocks, so the pair is the real 4) and the 8-bit peripherals never had a 32-bit path; instruction fetch is where it is most exposed, since the 68030 fetches longwords and the kernel fetches words | **open, measure**: the gap the wrapper leaves between the two beats is unmeasured until the CPU and GLUE are simulated together (1.10); if it is nonzero, longword RAM traffic is slower than the *Guide*'s 15.67 MB/s by that gap. Added 2026-09-26. **Decided the same day: fixed in the kernel, not worked around - 1.13** |

**Host obligations the contract in 1.4 does not yet carry.**

- **Walker timeout**: BERR after ~503 busy cycles, and "host clock must not
  stall during active walks without asserting external DTACK." A hard number
  our SDRAM design has to respect.
- **ATC coherency is manual**: a CACR writeback does not flush the ATC;
  `PFLUSH` / `PFLUSHA` only.
- **Vector 2 only** for internal PMMU faults, not the 68851's vector 61.

**Deviations from the MC68030 UM that could bite a Mac ROM.** Six intentional
ones are documented. Three matter to us:

1. **PMMU registers are PMOVE-only.** ~~The UM lists TC/TT0/TT1/MMUSR as
   MOVEC-accessible~~ - **withdrawn 2026-09-25; that list is the 68040's.**
   The MC68030 UM's MOVEC description names SFC, DFC, CACR, USP, VBR, CAAR,
   MSP and ISP and says all other codes take an exception, so PMOVE-only is
   the correct 68030 behaviour, not a deviation. And the ROM agrees: its 40
   MOVEC instructions touch only VBR, USP and CACR (1.11). Not a risk.
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

- ~~Whether the SE/30 ROM's demands on the PMMU are the same as the IIvi's.~~
  **Answered 2026-09-25 from the ROM, in 1.11.** The demands are small and
  are enumerated there; the comparison with the IIvi's ROM is no longer
  needed, because ours are known directly.
- The FPU. **Reframed 2026-09-25 - see 1.12: TG68K *does* have a
  68881/68882 FPU, with transcendentals, on upstream's `*_fpu2` branches;
  the open question is now the merge onto the audited kernel, not the
  search for an FPU.** The original text follows.
  Every SE/30 shipped a 68882 - **sourced 2026-09-25: *Guide* 2e Table
  3-6 lists the SE/30's auxiliary processor as "MC68882", unqualified,
  beside "None" for the SE** - TG68K has none and the IIvi
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
2. ~~**Read the SE/30 ROM's `StartBoot` / MMU path**~~ **Done 2026-09-25 -
   1.11.** No MOVEC reaches a PMMU register, the 1.1 premise holds from the
   ROM's own tables, and the ROM's entire PMMU contract fits in one bench,
   proposed there. `scripts/se30_rom_mmu.py` reproduces the reading.
3. ~~**Diff danifunker's kernel against `030_mmu2`**~~ **Done 2026-09-25 -
   1.12.** The kernel is byte-identical to upstream's tip; the Mac-specific
   set is the wrapper `tg68k.v` plus one silicon-adjudicated ALU hunk and
   one area workaround. ~~Adopt the IIvi's sync rule: never fork the
   kernel.~~ **Not adopted - owner's decision 2026-09-26, see 1.12.**
4. **Enumerate our bus masters** against the RMC obligation in 1.7 and design
   the arbitration. Promoted from a check to design work.
5. **Reproduce the IIvi's claim**: build their core, boot it, confirm the
   PMMU is live in practice. **Narrowed** - most of this item turned out to
   be answerable by reading the code, and is closed below.
6. Only then: cut the CPU into a MacLC-derived tree and bring up ROM + RAM to
   a first fetch.
7. **The 68882 - decided 2026-09-25, committed base-machine work, gated
   after first boot.** The SE/30 shipped one as standard (*Guide* 2e Table
   3-6), so the finished core has one; the ROM boots without it, so it is
   not on the first-boot critical path. Sequence: merge the `030_mmu2_fpu2`
   FPU forward onto the audited kernel - ~~upstream first, per the sync
   rule in 1.12~~ **in this tree, tested here** (1.12's decision); re-enable the
   transcendentals; verify under ModelSim against the MC68881/68882 User's
   Manual and an independent corpus (WinUAE's `cputest` covers the 6888x),
   with MAME/WinUAE as cross-checks only; then a Quartus fit, which is the
   real unknown. **Fidelity rule (owner's decision):** replicate the real
   68882's documented bugs and limitations where the evidence exists -
   mask errata, the manual's stated transcendental error bounds, frame
   formats per mask revision - and where it does not, build to the spec.
   Research items that follow from the rule: locate the MC68881/68882
   errata sheets, and establish which 68882 mask the SE/30 shipped with
   (the IIcx BOM is the nearest paper). Bit-identity to silicon is not
   claimed unless captures from a real 68882 exist to claim it against.
8. **CPU cycle fidelity - raised 2026-09-26, gated after first boot, measure
   before deciding.** TG68K is not cycle-identical to a 68030 and no open
   core is (1.9 above: the field is one author's line plus an MMU-less
   core; the cycle-exact 68000, fx68k, rests on a microcode recovery that
   has no public 68030 counterpart). The rule is the same as the 68882's:
   documented behaviour is the spec, the *MC68030 UM* section 11
   (instruction execution timing) and section 6 (the on-chip caches), and
   emulators are cross-checks. In order of value for cost:
   1. ~~**Measure the beat gap**~~ and ~~**a 32-bit bus mode for the
      kernel**, scoped only if the gap is real~~ - **superseded the same
      day: the 32-bit bus is decided and scoped as 1.13, on the path to
      first boot, not gated behind a measurement.** What remains here is
      the timing that is not the bus's:
   2. (merged into 1.13)
   3. **An instruction-timing audit**: run the cputest corpus (1.10) with
      a cycle counter and tabulate against UM section 11, so the size of
      the gap is known per instruction class before anyone proposes to
      close it. The result is a table in this section, not a rewrite.
   4. **The cache**: hold `TG68K_Cache_030` to UM section 6 - 256-byte
      direct-mapped instruction and data caches, the `CI` and `CACR`
      rules 1.11 and 2.11.1 already depend on - in the same corpus.
   A cycle-exact rewrite of the execution unit is out of scope: it is a
   new CPU core, and there is nothing to write it from but the manual.

**Answered from the code, not by a build.** Item 5 previously also asked
whether the IIvi runs 24-bit or 32-bit, because danifunker said "I think this
core is only 24-bit right now but I will verify with you later." Reading
`MacIIvi.sv` settles it:

- It declares `wire [31:0] cpuAddr;` with `assign cpuAddr[0] = 1'b0;` and
  **no truncation or masking anywhere**. The decode is a full 32-bit decode -
  which confirms 1.5 from RTL rather than from `VASP_RETARGET.md`'s prose.
- Its RAM menu offers 8 / 20 / 36 / 48 / 68MB, clamped by a `mem_cap` against
  the fitted SDRAM "to prevent address wrapping into ROM/VRAM regions". The
  default is 8MB.
- The CPU strap is hardwired: `.cpu ( 2'b10 ),  // 68030 (Mac LC II)` - the
  68030-with-PMMU selection described in 1.4.

His own post carries the contradiction: 24-bit addressing spans 16MB, so
"unlocked to 48MB" and "only 24-bit" cannot both be true. The hardware is
32-bit; whichever mode the *OS* runs in is a software setting, and 48MB is
reachable only in 32-bit mode. **This does not transfer to us** - the IIvi
has a 32-bit clean 1993 ROM, where 1.5 establishes the SE/30's is dirty.

What still needs a build and a boot is only the narrow claim that the PMMU is
live and translating in practice. Note also that at top level `MacIIvi.sv`
sees only the debug probes (`dbg_walk_cycle_o`, `dbg_pmmu_*`); the walker bus
plumbing lives one level down in `rtl/tg68k/tg68k.v`, exactly as 1.4 records.

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

1. Which simulator the Quartus install carries. **ANSWERED, and better than
   expected.**

   `C:\intelFPGA_lite\17.0\modelsim_ase` - **ModelSim ALTERA Starter Edition
   10.5b**, already installed with Quartus Prime Lite 17.0. It compiles
   MacPlus's `rtl/via6522.vhd` with 0 errors, and - the part that matters -
   **it does mixed-language simulation.** Proven, not assumed: a Verilog
   testbench instantiating that VHDL entity elaborated and ran clean.

   ```
   M=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
   $M/vlib.exe work
   $M/vcom.exe -work work rtl/via6522.vhd     # VHDL   -> 0 errors
   $M/vlog.exe -work work tb_mixed.v          # Verilog TB instantiating it
   $M/vsim.exe -c -do "run -all; quit -f" work.tb_mixed
   #  -> "Loading work.via6522(gideon)" ... Errors: 0
   ```

   **This is the capability 1.10 needs and the one iverilog cannot provide.**
   It means upstream's VHDL bench suite can run *and* we can write Verilog
   system benches with the VHDL CPU instantiated inside them - so the
   103,693-line generated kernel may never be needed at all, and no new
   tooling has to be installed.

   **The Starter Edition's size limit, and what it actually counts.** Not in
   the install's readme or release notes; the PDF manuals under
   `docs/pdfdocs/` match on the terms and were not opened. From Intel's
   community answers and the Verification Academy discussion:

   - The limit is **10,000 "executable lines"**, where an executable line is
     one you could set a breakpoint on - statements only, not comments,
     blank lines, declarations or port maps.
   - It counts **the design elaborated into the simulator**, at load time -
     *not* the repository's size and *not* lines exercised during a run.
   - Exceeding it does **not refuse**. It warns, then runs at roughly **40%
     of full ModelSim PE/DE speed**.
   - There is a **second, separate instance limit** beyond which simulation
     drops to about **1%** of full speed. That is the real cliff; its numeric
     value was not found.

   So the cost scales per bench, not per project:

   | bench | loads | outlook |
   |---|---|---|
   | our own RTL units | one module | unaffected (and can stay on iverilog) |
   | CPU / PMMU suite | kernel + PMMU + cache, ~15,900 VHDL lines | over the line limit; expect ~2.5x slower, survivable |
   | full system | CPU + GLUE + SDRAM + video | worst case, and the one 1.10 wants - **may trip the instance limit** |

   **The measurement that matters is therefore the full-system bench, not the
   CPU alone**, and it needs the TG68K sources cut into a tree first.

4. **Can it be split?** Yes, with one hard limit: **the CPU cannot be split.**
   It is a single elaboration unit of ~15,900 VHDL lines, over the limit by
   itself. Everything else splits naturally, which is the MacPlus ladder
   unchanged - GLUE, SDRAM, video, SWIM, ASC and SCSI each get a small bench
   on iverilog. The exposure is the *combination*, and the technique for that
   is a **bus-functional model**: a few hundred lines of Verilog impersonating
   the 030 on the bus - FC codes, MOVES probes at FC=7, walker-style cycles,
   the walk-read DTACK gate, `beat_valid`. Then:

   - our RTL + BFM -> pure Verilog, iverilog, fast, covers the risky seams
     daily;
   - real CPU + upstream's VHDL suite -> ModelSim, over the line limit but
     only ~2.5x slower;
   - real CPU + our system -> occasional, to confirm the BFM still tells the
     truth.

   This fits where the work actually is: the CPU is fixed inherited code
   while our RTL iterates. **The BFM's risk is that it encodes our *belief*
   about the CPU** - if the belief is wrong the benches pass and the hardware
   fails, which is the unowned seam relocated rather than removed. Derive it
   from the integration contract in 1.4, and validate it by capturing real
   bus traces from the CPU under ModelSim and replaying them through it.

5. **Is there an open-source mixed-language simulator?** Not a mature one, as
   of 2026-09. GHDL is VHDL; its Verilog work targets *synthesis* via
   `ghdl-yosys-plugin`, not simulation. **NVC** is the promising trajectory -
   near-complete VHDL-2008, LLVM-compiled, fast, with experimental Verilog
   under development - but not there yet. **Pulse** (MIT, C++) appeared this
   month with mixed-language *planned*; far too new to depend on.

   So the mature open-source answer is the old one: **convert the VHDL to
   Verilog and stay in one language** - which is exactly what the
   103,693-line generated kernel is, produced by the same GHDL machinery.
   The two options are therefore not independent: ModelSim buys true
   mixed-language at a speed penalty, the generated kernel buys the same
   destination on free tools at a readability penalty. With a BFM in the
   ladder, either is needed far less often than the earlier framing assumed.
2. Whether GHDL will run upstream's benches as written, or whether they lean
   on ModelSim-specific constructs. GHDL is VHDL-only either way, so
   `tb_cpu_wrapper_pmmu.v` - the Verilog wrapper bench, and the one closest
   to what we would be re-creating - cannot run under it.
3. How the MacPlus core's benches handle `rtl/via6522.vhd`. **ANSWERED, and
   it argues against reusing the same strategy here.**

   The MacPlus practice is that **iverilog never touches the VHDL at all**.
   Across 33 benches in `sim/`, not one elaborates `rtl/via6522.vhd`, nor
   `dataController_top.sv` which instantiates it - the three benches that
   mention `dataController_top` do so only in comments. Testable logic is
   instead factored *out* into standalone Verilog modules.
   `MAC128K_PLAN.md:984` states it plainly:

   > "`rtl/disk_pwm_duty.v` ... is a **separate module on purpose**:
   > `dataController_top.sv` instantiates VHDL and cannot be elaborated by
   > iverilog, so anything buried in it is untestable -- and every bug in
   > this project has been in exactly that kind of unowned seam."

   **So a precedent exists, and it decides against itself for this core.** On
   MacPlus the VHDL is one peripheral, and you can factor around a VIA. On
   the SE/30 the VHDL is **the CPU**: every system-level bench has it at the
   centre and nothing can be factored around it. Applying the MacPlus
   strategy here would make the entire machine the unowned seam - exactly
   the region that quote identifies as where every bug in that project has
   lived.

   This retires the hope that local precedent settles 1.10 cheaply. It does
   the opposite, and is the strongest argument yet that we must **buy**
   system-level simulation: either the generated Verilog kernel as an opaque
   block under iverilog, or a mixed-language simulator. Doing neither means
   accepting that the CPU, the PMMU and every bus interaction with them are
   untestable.

---

## 1.11 What the SE/30 ROM asks of the PMMU

Read 2026-09-25 from the ROM image itself - `$97221136`, the 256KB ROM the
II FDHD, IIx, IIcx and SE/30 share; MAME's `macse30` loads the same file -
with `scripts/se30_rom_mmu.py`. Every claim about the 68030 below is checked
against the MC68030 User's Manual, 3rd edition (1990), section 9. Nothing
here comes from an emulator.

**The MOVEC question is closed, and its premise was wrong.** The ROM holds
40 MOVEC instructions; every one names VBR, USP or CACR. None touches an MMU
register, and none could: the UM's MOVEC description lists the 68030's
control registers as SFC, DFC, CACR, USP, VBR, CAAR, MSP and ISP, "all other
codes cause an exception". MOVEC access to TC, TT0/TT1 and MMUSR is a
**68040** feature. So upstream's PMOVE-only whitelist is the correct 68030
behaviour, and 1.7's risk item 1 is withdrawn.

**The ROM executes exactly five PMMU instructions.** Scanning every even
offset for a coprocessor-0 F-line word finds nine candidates; four are data
or the middle of another instruction. The five real ones:

| where | instruction | role |
|---|---|---|
| `$4083F872` | `PMOVE (a0),TC`, TC = 0 | reset path: disables translation before anything else runs, straight after the CACR probe that identifies a 68030 |
| `$40803AE0` | `PMOVE TC,-(sp)` under an F-line trap handler | MMU-type probe, taken only on the 68020 path, to tell a 68851 from Apple's AMU |
| `$40803B32` | `PMOVE $CB1.w,TC` | clears TC.E before a reload - the longword at `$CB1` has bit 31 clear |
| `$40803B38` | `PMOVE (a0),CRP` | root pointer for the selected mode |
| `$40803B3C` | `PMOVE 8(a0),TC` | TC for the selected mode |

There is **no PFLUSH, PFLUSHA, PLOAD or PTEST** in executed code, no PMOVE to
SRP, TT0 or TT1, and no MMUSR read. The ROM relies on a PMOVE with FD=0 to
flush the ATC when it loads CRP and TC, which the UM specifies (9.5.3, the
ATC entry's V bit: cleared by "a PMOVE instruction with the FD bit equal to
zero that loads a value into the CRP, SRP, TC, TT0, or TT1 register").
Upstream honours it: `TG68K_PMMU_030.vhd:1358-1406` invalidates the ATC on
TC, SRP and CRP writes unless `reg_fd`.

**24-bit mode is a sixteen-entry table in the ROM.** `_SwapMMUMode` (trap
`$A05D`, vectored through `$DBC`, body at `$40803A8A`) picks one of two
twelve-byte rows - CRP then TC - from a table at `$40803B7A`, indexed by MMU
type and by the mode asked for. The 68030 rows:

| mode | CRP | TC | decoded |
|---|---|---|---|
| 24-bit | `7FFF0002 40800050` | `80F84500` | E=1, PS=15 (32KB pages), **IS=8**, TIA=4, TIB=5; limit suppressed (L/U=0, `$7FFF`); short-format table at `$40800050` |
| 32-bit | `7FFF0002 4083F5A0` | `80F04D00` | E=1, PS=15, IS=0, TIA=4, TIB=13; short-format table at `$4083F5A0` |

Both field sums are 32 (15+8+4+5 and 15+0+4+13), as the TC consistency check
in UM 9.7 requires. The two 68851 rows beside them differ only in setting CRP
bit 9 (SG), which the 68030 reserves - Apple kept the parts distinct.

The 24-bit table at `$40800050` - it sits in the ROM header, straight after
the reset vectors - is sixteen 4-byte descriptors, every one a **page
descriptor (DT=1) at level A**: early termination, UM 9.5.3.1. Each covers a
1MB logical block directly, and the 32KB page size never produces a second
level:

| logical (24-bit) | physical | bits |
|---|---|---|
| `$0-$7` | `$00000000-$007FFFFF` | U M |
| `$8` | `$40800000` (ROM) | U M |
| `$9-$E` | `$F9000000-$FE000000` (slots 9-E; **`$E` is the SE/30's internal video**, 1.6) | U M CI |
| `$F` | `$50F00000` (I/O) | U M CI |

**This is the 8MB ceiling of 1.5 stated in hardware terms: eight RAM
entries.** It is also, from Apple's own code rather than from
`VASP_RETARGET.md`, the confirmation that 24-bit mode is the PMMU's work and
none of the decoder's.

The 32-bit table at `$4083F5A0` has the same shape: sixteen early-terminating
descriptors of 256MB each, identity-mapped, `$0-$4` cacheable and `$5-$F`
cache-inhibited. So translation is *enabled* in 32-bit mode too, and the
table exists to set CI over I/O and slot space. The TT registers could have
done that; the ROM never touches them.

**U and M are pre-set in every descriptor, and the tables are in ROM.** The
68030 sets U on any descriptor it finds with U clear, and M on a write to a
page whose M is clear (UM 9.5.3). Had Apple left them clear, the walker would
issue writes into ROM address space. Upstream's walker gates the same way
(`TG68K_PMMU_030.vhd:4463-4478` - writeback only when U is clear, or on a
write with M clear and no write protection), so with this ROM it never
writes. That is a bench assertion, not an assumption: **any `mem_we` from
the walker while the stock ROM is running is a bug.**

**Reset ordering.** UM 9.2.2: RESET clears TC.E and the TTx E bits and does
not flush the ATC. The ROM's first act after the CACR probe at `$4083F856`
is `PMOVE TC` with zero regardless, so translation is off while the ROM sets
up. The first table load is the *32-bit* row, at the end of the MMU
initialisation at `$40803AA8-$40803B54`; `_SwapMMUMode` moves between rows
thereafter, and the cold-start memory sizing at `$40802BBC` is bracketed by a
switch to 32-bit and back (`$4083F880`). Where the ROM settles into 24-bit
before handing over to the System is not traced; a dirty ROM stays there
(1.5).

**CPU identification depends on CACR readback.** The ROM tells a 68030 from
a 68020 by writing CACR and reading it back: `$4083F85C` writes `$2000` (WA,
bit 13) and tests for non-zero; `$4083F74A` writes `$2909` and tests bit 8
(ED). A kernel that masked either bit on read would be taken for a 68020, and
the ROM would then probe for a 68851 and find none. Upstream stores bits 13
to 8 (`TG68KdotC_Kernel.vhd:9902`), so the probe works - but it belongs in
the bench, because the whole MMU path hangs off it.

The low-memory cells the ROM uses, by address rather than by name since the
names have not been checked against Apple's equates: `$12F` CPU type, `$CB1`
MMU type, `$CB2` current mode (0 = 24-bit), `$CB4` and `$CB8` pointers to the
24-bit and 32-bit rows, `$DBC` the `_SwapMMUMode` vector.

**What this settles for 1.8.** The SE/30 ROM's demands on the PMMU are now
known and small: short-format descriptors only; one level-A table; early
termination at level A; PS=15; IS=8 and 0; TIA=4; TIB=5 and 13; CRP with the
limit suppressed; no SRP, FCL or TT; no PFLUSH; ATC flush on PMOVE; no
history-bit writes. Each has a code path in upstream's walker
(`calc_effective_page_shift`, `tc_config_invalid`, the DT=1-at-level-A branch
at `:3096`). What it does not settle is the *System's* use of the PMMU:
virtual memory under System 7 builds real multi-level tables in RAM, and that
is where U/M writeback, RMC and the walker timeout of 1.7 become live. Per
1.5, that is the enhancement path, not the base machine.

**The bench exists and passes: `sim/pmmu_rom_contract/`.** Written and run
2026-09-25, the first use of 1.10's ModelSim path: a Verilog bench
instantiating the VHDL `TG68K_PMMU_030` from the IIvi tree, serving both
tables from the real ROM image. It loads the two 68030 rows as
`_SwapMMUMode` does (CRP high, CRP low, TC; FD=0), presents one bus cycle
per block in each mode, and checks 67 things: all sixteen translations and
CI bits in both modes; the named addresses (ROM, VIA2, video slot `$E`, top
of the 8MB window); that IS=8 makes the top byte irrelevant to the
*translation*; that the walker issued exactly one descriptor read per
early-terminating entry, **62 reads in all, zero writes, zero outside the
ROM**; that both TC geometries were accepted without an MMU configuration
exception; that a reload with FD=0 re-walks (the ATC was flushed); and that
TC=0 returns to identity. **It runs in well under a second - the PMMU alone
is ~5,000 VHDL lines, under the Starter Edition's speed limit.**

One expectation of mine was wrong, and the manual corrected it rather than
the bench. I had assumed a second access to a block with junk in the top
byte would hit the ATC, since IS=8 ignores it. It walked again - and UM
9.7.3 says it must: "all 32 bits of the address are compared during address
translation, bits ignored due to initial shift cannot have random values."
The ATC tag also carries the function code (UM 9.4). So a 24-bit System
that leaves flag bits in the top byte of an address gets the correct
translation every time, at the cost of one ATC entry per distinct value -
real-silicon behaviour, and upstream reproduces it. The bench now asserts
it.

**Still owed:** the CACR readback the ROM uses to identify a 68030 lives in
the kernel, not the PMMU, so it needs a kernel-level bench; that is the
natural second bench once the tree exists, and it is the one that will
measure the Starter Edition against the full ~15,900-line CPU.

**Noted for Section 2, not read further.** The same reset path identifies
the machine from VIA1 PA6 and VIA2 PB3 (`$4083F76A-$4083F79C`, a six-entry
table at `$4083F79E`), and MAME's remark about the RAM-size table checks out:
`$4080366E` holds `01 02 04 05 08 10 11 14 20 40 41 44 50 80`, sizes in MB.

---

## 1.12 The kernel diff: there is one kernel, and the Mac lives in the wrapper

Done 2026-09-25 (1.9 item 3). Both trees are now cloned durably beside
MacLC (appendix). The diff was made with CR/LF normalised, because the IIvi
tree is CRLF throughout and upstream is LF.

**The kernels have not diverged. They did, and danifunker re-converged
them.** `TG68KdotC_Kernel.vhd`, `TG68K_PMMU_030.vhd`'s logic,
`TG68K_Cache_030.vhd`, `TG68K_CacheCtrl_030.vhd`, `TG68K_Pack.vhd` and
`TG68K.vhd` in `MacIIvi_MiSTer` are **byte-identical** to
`apolkosnik/Minimig-AGA_MiSTer@030_mmu2` at its tip `c3e8a0d`
(2026-07-25). The IIvi commit that did it, `ad23427` (2026-08-15), is
explicit: a "wholesale LF-normalized import ... the kernel our old LCII pin
forked from, now ~40 audited bugs ahead". The "Mac-specific kernel changes
for BERR and STOP" that 1.7 set out to recover **no longer exist as kernel
changes** - the same commit says the new kernel "drops the LCII in-kernel
walk-hold latch gates for a wrapper-side contract (their `cpu_wrapper.v`),
which `tg68k.v` now implements". So 1.7's "at least two kernels, diverged,
neither a superset" was true when danifunker wrote his post and is false
now. The IIvi's own `CLAUDE.md` states the rule they arrived at: kernel
fixes land upstream first and are re-copied; never fork the kernel; the
bus wrapper is ours. This section first recommended adopting it verbatim.

**DECIDED 2026-09-26 (owner): not adopted.** In Daniel's words: "This is
an independent core. We should do the testing ourselves and not be
dependent on other developers. If, once we have it working, we can
benefit other cores, then that is the time to share code." So: **the
kernel in this tree is ours to change**; every kernel change is verified
here, against the cputest corpus and the silicon captures (1.10), by us;
upstream is a source to read and to diff against, never a gate; and
sharing is a decision taken after the core works, not before. What
survives from the IIvi's practice is the engineering, not the rule: keep
the kernel's delta from `030_mmu2@c3e8a0d` small and listed (the table
below is that list), so a later re-sync or a contribution back is a
mechanical diff. The bus wrapper remains the home of everything
Mac-specific because that is the cleaner design, not because the kernel
is off limits.

**The whole local delta is two hunks.**

| file | delta | nature |
|---|---|---|
| `TG68K_ALU.vhd` | one hunk, DIVU-by-zero | **A real-silicon correction.** The 68030 leaves the CCR unchanged on an unsigned divide by zero; the imported WinUAE-derived model set N/Z/V. Adjudicated against a Macintosh IIcx capture (`SingleStepTests`, 2026-06-13) and landed upstream first as `bfd3428` - which is on **no pushed upstream branch tip** as of today; the IIvi copy (`498eb34`) is the surviving artifact. With it the silicon corpus scores 720/721. **Take it.** |
| `TG68K_PMMU_030.vhd` | `ATC_ENTRIES` 22 -> 8, plus zero-padding of the debug ports | **An area workaround**, not a fix: "reduced 22 -> 8 to relieve a 98%-ALM fit whose STA-met builds misbehaved on hardware ... a smaller ATC walks more, never translates differently. RE-APPLY ON EVERY re-sync." The IIvi's fabric is full of colour video; ours will not be. **Do not take it** unless our own fit forces it - and 1.11's finding that every distinct top byte in 24-bit mode costs an ATC entry argues for keeping the full 22. `sim/pmmu_rom_contract` passes on both (run against upstream's file with `TG68K_SRC=`). |
| `TG68K.qip` | build list | Builds `tg68k.v` in place of upstream's `TG68K.vhd` top; `CacheCtrl_030` kept as reference only. |

**Our own kernel changes since** are recorded where they were made: the
32-bit bus (1.15), MOVEM's step on the 32-bit port (3.8 item 23), and the
restart for an external bus error on a data read (5.11 item 6).

**The Mac-specific content is `rtl/tg68k/tg68k.v`** - 1,370 lines of
danifunker's own Verilog, 13 commits, against upstream's 4,545-line Amiga
`cpu_wrapper.v` for the same job. It is where 1.4's integration contract
actually lives, and `ad23427`'s message enumerates the terms it implements
on the Mac's phi grid. They belong in 1.4, and are recorded here until it is
revised:

- `clkena` held across the **whole** walker-request window
  (`pmmu_walker_req`), not just the borrowed transfer, and while the PMMU
  is busy translating (upstream BUG #407: the one-cycle ATC-miss gap);
- `clkena` force-released on `pmmu_fault` so the exception dispatches,
  with `beat_valid` low on that beat - the kernel advances but consumes no
  bus data (upstream's hardware capture: `$1B00`/`$FFFF` junk retired as
  opcodes without this);
- the bus FSM parks at `s_state 0` while busy or faulted, never mid-cycle,
  so no Mac bus cycle launches with a stale or untranslated physical
  address - the mirror of upstream's `pmmu_suppress_bus`;
- BERR held across the cycle, and **only for the kernel's own cycle**: a
  BERR during a walker or cache-fill transfer belongs to the walker, not
  to whatever instruction is in flight (`berr & ~walk_cycle &
  ~fill_active`);
- auto-vectoring, E-clock/VMA and BR/BG/BGACK arbitration in their
  MacIIvi-proven form.

The pre-2026-08 MacLCII pin (`a254a02`, the in-kernel walk-hold gates) is
history. **Consequence for 1.9 item 6 and for the MacLC question in the
memory notes:** whatever CPU MacLC carries is the *old* pin; the CPU comes
from the IIvi tree or from upstream directly, never from MacLC.

**Upstream is healthier and busier than 1.7 recorded.** Its
`tests/tg68k_030/` holds 167 files against the 129 the IIvi copied; the 38
newer ones include ATC stress and timing, cache-controller units, STOP/M-bit
stack cases, and a family of **MMU fault-restart tests written to
NetBSD/amiga's demand-paging contract** (`tb_mmu_restart_netbsd.vhd`: fix
the PTE, `PFLUSH`, plain `RTE` with an unmodified frame, and the faulted
instruction must re-execute exactly once - including `MOVEM` crossing into
an invalid page and `CAS` under a Format `$B` frame). The `030_mmu2` tip
commit reports NetBSD reaching `/etc/rc` on hardware. That is an MMU being
driven far harder than System 7 will drive it; the SE/30 ROM's demands
(1.11) are a small subset, and System 7 virtual memory sits between the
two.

**And upstream has a 68881/68882 FPU - which changes 1.8.** Branches
`030_mmu2_fpu2`, `030_mmu_fpu`, `030_mmu_fpu2` and `fpu` carry
`TG68K_FPU*.vhd`: nine files, ~9,100 lines, "TG68K MC68881/68882 Compatible
Floating Point Unit", LGPL-3 like the kernel, with an `Enable_Transcendental`
generic (so the trig/log/exp unit the 040 lacks is present, which was the
whole objection to `ap040_fpu.v`), a packed-decimal unit, and
68882-format `FSAVE`/`FRESTORE` frames (NULL 4 bytes, IDLE 60 bytes). It is
integrated through the kernel's F-line decode - which is how a 68882 looks
to software anyway; the coprocessor bus is invisible above the chip. **The
cost is that the FPU branch is stale**: `030_mmu2_fpu2`'s tip is 2026-05-23
and its kernel is 3,004 lines and its PMMU 304 lines behind `030_mmu2`, so
it predates most of the BUG #371-#470 audit. The `030_mmu2` kernel has no
`FPU_Enable` hook. Bringing the FPU forward onto the audited kernel is a
merge, not a port, and it is the same author's code on both sides. **1.8's
FPU bullet is reframed accordingly; it is no longer "the only open FPU is
an 040 one".**

**But its state is "first draft", and the branch says so itself.** The
FPU work is three commits on 22-23 May 2026 - "first steps with FPU,
correct frame reported by modified DiagROM", "FPU second try", "enable the
FPU, but compile out transcendental functions for now" - and then nothing.
Two benches: `tb_fpu_shell` (69 asserts: null FSAVE frame id, FRESTORE
post-increment, FMOVE control registers, all "WinUAE-compatible" - modelled
on an emulator, not silicon) and `tb_fpu_core_smoke` (22 asserts). No FPU
audit document; the three audit files on the branch are MMU/CPU. The only
hardware claim is that DiagROM *reports the correct frame* - detection, not
computation. The transcendental unit is compiled out at the tip. So:
structurally the whole chip, barely exercised, and "does it work" is
unanswered. Answering it is the FPU work item: merge forward, re-enable the
transcendentals, and drive it against the MC68881/68882 manual and a
silicon corpus - SANE and MathLib being what a Mac actually exercises. The
68882 is standard on the SE/30 (*Guide* 2e Table 3-6), so this is base
machine work, not enhancement.

**Licences, corrected.** The appendix said "GPLv2 where checked". The
kernel, ALU, PMMU and FPU headers all say **LGPL-3 or later** - TG68K.C's
original licence. Same family throughout; no combination problem.

## 1.13 The 32-bit bus: decided, and what the job is

**Decided 2026-09-26 (owner).** The kernel's 16-bit external data bus
(1.7) is not to be worked around in GLUE; it is to be fixed in the
kernel. Daniel: a cycle-exact 68030 is not currently possible for lack of
documentation, but "I see no reason to use workarounds such as a 16-bit
bus when this is a well-defined job and will allow the other parts of the
core to be more authentic." So the 32-bit port with the 68030's dynamic
bus sizing is **base-machine work, on the path to first boot**, and 2.13's
two decisions - GLUE on the 16-bit wrapper bus doing the sizing itself,
and the 2 + 2 longword - are **interim scaffolding** that the GLUE
rewrite of item 4 below retires. This is the first kernel change under
1.12's decision: made here, verified here.

**What is well defined.** The bus side is entirely specified: *MC68030 UM*
7.2.1 (dynamic bus sizing: `SIZ1-0` Table 7-2, the address offset `A1-A0`
Table 7-3, the `DSACK` codes Table 7-1, what the port must drive on a read
Table 7-4, and the internal-to-external multiplexer Table 7-5, which says
for every size, offset and port width which bytes ride which lanes), 7.2.2
(misaligned operands, Figures 7-9 to 7-13), 7.2.3 (Table 7-6: the number
of bus cycles per operand by alignment and port size), Table 7-7 (the
byte write enables a 32-bit port derives from `SIZ` and `A1-A0`, Figure
7-18), and 7.2.5 (the 030 differs from the 020 only for cachable
accesses; 7.2.6 cache filling). Every cycle count 2.11 holds GLUE to
assumes this CPU behaviour.

**What the kernel does today, read from `TG68KdotC_Kernel.vhd` (10,509
lines, `030_mmu2@c3e8a0d`).** Operand size and alignment are one six-bit
byte mask, `memmask`, set per access from size and `A1-A0` (`set_memmask`,
the table at ~5096: `101111` byte, `100111` word, `100011`/`100001`/
`100000` the misaligned and long cases) and **consumed two bytes per
beat**: on every `clkena_in` edge `memmask <= memmask(3 downto 0) & "11"`
(~3830) and `memread` records what came in. `nUDS`/`nLDS` are the top two
bits of the mask (`memmaskmux`, ~1630-1635); read data is assembled from a
32-bit shift-in of previous beats' `data_in` plus the current one
(`data_read`, `last_data_in`, ~1904-1950); write data is a 16-bit slice of
a 48-bit `data_write_mux` chosen by the mask (~2296-2325), a lone byte
duplicated on both halves. `long_start`/`long_done` are derived from the
same mask and feed the ALU, so the beat sequence is interleaved with the
microcode's address arithmetic (post-increment across the halves, ~2280).
The mask, `long_*` and `data_in` are touched on 137 lines of the kernel
and 33 in the ALU, PMMU and cache files; `longword` is exported for the
Minimig's SDRAM burst and the IIvi wrapper passes it through. So: **the
design is already a byte-mask sequencer, which is the right shape for the
030's rules - the job is to consume the mask by the port width the
`DSACK` pair reports (1, 2 or 4 bytes a beat) instead of always 2, widen
the data paths, and derive `SIZ`, `A1-A0` and the lane multiplexer of
Table 7-5 from it.** It is not a new bus unit bolted on; it is the
existing one taught the 030's width rules.

**The job, in order.**

1. ~~**Read** 7.2 in full and write the beat contract as a table: for each
   (size, `A1-A0`, port width) the number of beats, the bytes of each
   beat and their lanes (Tables 7-5, 7-6, 7-7), and the `memmask`
   consumption that produces it. That table is the bench oracle and it
   exists before any VHDL changes.~~ **Done 2026-09-26 - 1.14.**
   `scripts/se30_bus_beats.py` holds the four tables and the rule;
   `sim/kernel_bus/beats.txt` is the oracle, 142 beats over 63 cases.
2. **The kernel**: a third bus shape selected by a generic beside
   `CPU="10"` - `data_in`/`data_write` 32 bits, `SIZ1-0` and `A1-A0` out,
   `DSACK1-0` in (or the wrapper's equivalent), mask consumption by the
   acknowledged width, the read assembly and write multiplexer per Table
   7-5, `long_start`/`long_done` meaning "first/last beat of the operand"
   as now. The 16-bit shape stays selectable so the corpus runs both.
   Cache fills (7.2.6) and the PMMU walker's port follow the same width.
   **Designed 2026-09-26 - 1.15**, as one engine consuming n bytes a
   beat, in four sub-steps 2a-2d with the 1.14 bench as acceptance.
   **2a, 2b and 2c done the same day: the kernel has the 68030's bus** -
   data operands at the port's width on 8-, 16- and 32-bit ports, the
   prefetch as the aligned long with a holding register. 2d (breadth)
   and item 3's corpus remain; item 4 (the wrapper and GLUE) is next
   to build.
3. **Verify** under ModelSim (1.10): the beat table of item 1 as a bench
   on the kernel alone, then the cputest 030 corpus and the silicon
   captures in both shapes - identical architectural results, and the
   beat counts of Table 7-6 in the 32-bit shape. **The bench exists
   (2026-09-26, `sim/kernel_bus/`, 1.14): it passes on the 16-bit shape
   for everything but the five-byte fields, and is item 2's acceptance
   test at `PORT=32` and `PORT=8`.** The corpus part remains.
4. **The wrapper and GLUE**: `tg68k.v` presents the 68030 bus; GLUE is
   re-cut to 2.11.1 verbatim - `DSACK0*` alone for 8-bit ports, both for
   RAM and ROM, the CPU splitting operands itself - which removes the byte
   sequencer and the `lw` fast path from `rtl/se30_glue.v` and leaves the
   decode, the timings, the VIA and SCC machines, UI6, refresh and the
   encoder as they are. The bench's cycle counts do not change; its bus
   model does. **Both done 2026-09-26.** GLUE: 2.13 records it (91
   checks, and a clock found). The wrapper: `rtl/tg68k/tg68k.v`, ours,
   runs the kernel's beats as 68030 cycles on the C16M half-clock grid -
   `AS*` at S1, `DSACK*` and `BERR` sampled at each falling edge from
   S3, data latched at the end of S4, strobes negated at S5, the kernel
   acknowledged at the next S0 so cycles run back-to-back; parks the
   kernel while the PMMU translates and runs the walker's descriptor
   accesses as its own long cycles at the physical address (FC = 5, in
   the beats the port needs); holds a bus error to the kernel until it
   takes the exception, the IIvi's contract; autovectors internally
   (`AVEC` is grounded). No caches yet (1.15 item 9), and internal beats
   advance once per C16M clock. **`sim/system/tb_se30_system.v` is the
   first bench with the CPU and GLUE together**: the kernel bench's
   program out of a 32-bit RAM model behind GLUE, 17 checks - the
   program runs to STOP, every result slot holds what was written, and
   of 177 bus cycles (82 fetches, 95 data) every one is the Guide's 4
   clocks but two refresh stalls of up to 8, with no idle clock between
   cycles. The seam 1.7 called unmeasured is measured: nothing between
   the beats. Passed at the first run.

   *The cheap half of 2d, the same day (owner's ruling: extend our own
   benches now, port the corpora after first boot).* The bench program
   gained control flow after its operands: a subroutine call and return,
   a counted loop, a forward branch, `TRAP #0` with a handler and `RTE`,
   and a level-1 interrupt the bench raises when the program writes a
   marker and drops when the handler clears it, five more result slots.
   The kernel bench passes on all three ports with it, and the system
   bench with the interrupt raised through GLUE's `IPL`. It found one
   thing: **the kernel runs the interrupt-acknowledge bus cycle even
   when autovectoring internally**, so the wrapper terminates it as the
   board's grounded `AVEC` does (a 3-clock cycle, its data unused), and
   bus-errors any other CPU-space cycle - the coprocessor interface,
   which nothing answers until the 68882 exists (1.9 item 7), and which
   is how an F-line instruction traps instead of hanging. The system
   bench now meters that cycle separately: 240 cycles, 239 at the
   Guide's 4 but three refresh stalls, the acknowledge at 3.

**Cost.** Item 2 touches the kernel's central sequencing, not a corner:
weeks, not days, with the corpus as the safety net. The alternative -
first boot on the 16-bit scaffolding, then convert - would cut the MacLC
tree and write the wrapper twice, so the order is: this section, then the
tree cut (2.8 item 8), then the peripherals.

## 1.14 The beat table: MC68030 UM 7.2, run

Done 2026-09-26 (1.13 item 1). Read: 7.2 in full - 7.2.1 dynamic bus
sizing with Tables 7-1 to 7-5 and Figures 7-3 to 7-8, 7.2.2 misaligned
operands with Figures 7-9 to 7-17, 7.2.3 Table 7-6, 7.2.4 Table 7-7 and
Figure 7-18, 7.2.5 (the 030 differs from the 020 only for cachable
accesses), 7.2.6 and 7.2.7 (cache fills); 6.1.3 for what a cachable read
demands of a port; the note to 11.6.14 for bit fields spanning five
bytes. Tables 7-4, 7-5 and 7-6 were confirmed against the page images
because the PDF's text layer garbles them. Everything below is from the
manual; nothing from an emulator or another core.

**The rule, and that it is the whole of it.** A beat moves the most the
port can take from the current address to the port's own boundary,

> n = min(bytes remaining, port width in bytes - (A mod port width)),

the next beat starts n bytes on, `SIZ1-0` reports what remains (Table
7-2: 01 one, 10 two, 11 three, 00 four), `A1-A0` the current offset, and
the port names its width on `DSACK1-0` (Table 7-1: `HL` 8-bit, `LH`
16-bit, `LL` 32-bit). The lanes a port takes are, from the top lane
`D31:24` = 0: a 32-bit port lanes `A1A0` onward, a 16-bit port lane `A0`
onward within `D31:16`, an 8-bit port lane 0 only. `scripts/se30_bus_beats.py`
holds Tables 7-4, 7-5, 7-6 and 7-7 transcribed literally and runs the
rule against all of them - 151 table entries, every one reproduced: Table
7-6's cycle counts, Table 7-7's lane enables, the `OPn` positions of
Table 7-4, and that every lane Table 7-7 says a port reads carries the
byte Table 7-5 drives there - plus the manual's five worked examples
(Figures 7-5, 7-7, 7-9, 7-12, 7-15). So the four tables are one rule,
and the kernel implements the rule, not the tables.

**Table 7-6, the counts (32:16:8-bit port):**

| operand | A1A0 = 00 | 01 | 10 | 11 |
|---|---|---|---|---|
| instruction prefetch | 1:2:4 | - | - | - |
| byte | 1:1:1 | 1:1:1 | 1:1:1 | 1:1:1 |
| word | 1:1:2 | 1:2:2 | 1:1:2 | 2:2:2 |
| long | 1:2:4 | 2:3:4 | 2:2:4 | 2:3:4 |

Every cycle count in 2.11 that involves an operand wider than its port
rests on this row: a longword to a VIA is four beats, a word two.

**Table 7-5, what the processor drives on a write - verbatim, because the
kernel will drive exactly this.** `OP0` is the most significant byte of a
long, `OP3` the least; a word is `OP2 OP3`, a byte `OP3` (Figure 7-3).
The processor always drives all four lanes (7.1.4); the starred bytes are
"output but never used".

| SIZ | A1A0 | D31:24 | D23:16 | D15:8 | D7:0 |
|---|---|---|---|---|---|
| byte 01 | xx | OP3 | OP3 | OP3 | OP3 |
| word 10 | x0 | OP2 | OP3 | OP2 | OP3 |
| word 10 | x1 | OP2 | OP2 | OP3 | OP2 |
| 3-byte 11 | 00 | OP1 | OP2 | OP3 | OP0* |
| 3-byte 11 | 01 | OP1 | OP1 | OP2 | OP3 |
| 3-byte 11 | 10 | OP1 | OP2 | OP1 | OP2 |
| 3-byte 11 | 11 | OP1 | OP1 | OP2* | OP1 |
| long 00 | 00 | OP0 | OP1 | OP2 | OP3 |
| long 00 | 01 | OP0 | OP0 | OP1 | OP2 |
| long 00 | 10 | OP0 | OP1 | OP0 | OP1 |
| long 00 | 11 | OP0 | OP0 | OP1* | OP0 |

Within the lanes a port reads, this is the rule above (the byte at
`A+k` on lane `A1A0+k` for a 32-bit port, `A0+k` for a 16-bit port, lane
0 for an 8-bit port); outside them it is replication, so that a 16- or
8-bit port finds its bytes on `D31:16` / `D31:24` whatever the offset.
On a read the same lanes carry the operand bytes in (Table 7-4); the
bytes Table 7-4 marks `PRn`/`Nn` are don't-cares for an uncached read.
Table 7-7's enables (which GLUE will derive for RAM, Figure 7-18) are
the lane rule for the port's width.

**The kernel's mask, read against this.** `memmask` is one bit per byte
of the operand, active low, counted from its address `A`: **bit 4 is the
byte at `A`, bit 3 at `A+1`, ... bit 0 at `A+4`; bit 5 (`A-1`) is never
used and starts at 1.** That is what the `memmaskmux` line means -
`memmask when addr(0)='1' else memmask(4 downto 0)&'1'`: a word beat's
strobes are the two bytes of the word containing `A`, so an even `A`
shifts the window up one; the `nUDS`/`nLDS` pair is then bits 5:4 for
either parity. The operand masks - `101111` byte, `100111` word,
`100001` long, `100011` and `100000` for bit fields of three and five
bytes - are this mapping exactly. Today every beat consumes two bits
(`memmask <= memmask(3 downto 0)&"11"`) because every beat is a word,
and "last beat" is `memmaskmux(3)`, "no byte in the next word", known
before the beat starts. The 030 contract is the same mask consumed by
the width the port answers:

> `memmask <= memmask(5-n downto 0) & ones(n)`, n from `DSACK`; the
> operand is done when bits 4:0 are all ones; `SIZ` = min(zeros in bits
> 4:0, 4).

The consumed byte shifts into bit 5, so a finished operand reads
`011111` - the kernel's own comment at the longword mask gives its
sequence as `100001 -> 000111 -> 011111`, and the oracle's `mask'`
column reproduces it for a long to a 16-bit port. One nuance, found by
the bench below: at an **odd** address the kernel's first beat moves one
byte but its mask still shifts two and its address steps to `A+2`, so
from then on bit 5 stands for the byte at `addr-1` and `memmaskmux`
reads it as `nUDS`. The oracle's mask advances by the bytes consumed,
with bit 4 always the byte at the beat's own address. The two describe
the same beats and agree on every operand-start mask and every
even-address beat; they differ by one bit position after an odd first
beat. The 030 shape adopts the oracle's convention (the address steps by
n), which is one of the things `memmaskmux` stops doing.

**What this fixes for item 2, the kernel change:**

- *The last beat is known only at acknowledge.* A long at `A1A0 = 00` is
  one beat if the port is 32-bit and two if 16-bit. So `clkena_lw`,
  `long_done` and everything that keys on `memmaskmux(3)` - the address
  arithmetic's zero-delta guards, the PMOVE and RTE frame sequencing
  (137 lines, 1.13) - move from "mask says more follows" to "mask after
  this acknowledge says nothing follows". That is the substantive part
  of the job.
- *`memmaskmux`'s parity shift becomes the lane multiplexer.* On the
  030 bus there are no byte strobes; `SIZ`, `A1-A0` and Table 7-5's
  drive pattern replace `nUDS`/`nLDS` and the 16-bit `data_write` slice,
  and the read assembly takes lanes `A1A0`.. (or `A0`.. on `D31:16`,
  or lane 0) by the acknowledged width instead of `last_data_in`'s
  16-bit shift-in.
- *The instruction prefetch is an aligned longword* (Table 7-6's
  footnote; 6.1.1: "the word selected by address bit A1 is supplied to
  the instruction pipe"). The kernel fetches a word per opcode beat
  today (`100111` at PC). The bus contract is the long at `PC & ~3`,
  1:2:4 beats; how the kernel holds the other word is its cache-holding
  register's business, not the bus's. **Adopted by the owner
  2026-09-26: the bus contract is the aligned long.**
- *A five-byte bit field is two operand cycles* (11.6.14's note: "may
  span 5 bytes that require two operand cycles"). The manual does not
  say which comes first; the oracle takes the long at `A` then the byte
  at `A+4` and says so - **an assumption, not 7.2; adopted by the owner
  2026-09-26 ("go ahead with whatever you think is better")**. The mask
  `100000` consumed by width would instead merge the long's tail with
  the fifth byte into one beat where the offset allows (`A1A0 = 01`: 3
  + 2 rather than 3 + 1 + 1). 1.15 step 2a bounds it: one mask, no beat
  across the fourth byte.
- *A three-byte operand start* (`SIZ = 11` on a first beat) occurs only
  for bit fields; 7.2 defines the beat the same way and the oracle
  carries it.
- *Cachable reads are a separate rule* (7.2.5, 7.2.7, 6.1.3): the port
  must supply its full width regardless of `SIZ` and `A1-A0`, and a
  misaligned operand fills both cache entries it spans (Figure 6-8's
  order for an 8-bit port: b6 b7 b4 b5, then the next long). On this
  board every 8-bit port is cache-inhibited by the ROM's PMMU tables
  (2.11.1) and RAM and ROM are 32-bit, so **a cachable read here is
  always whole aligned longs, one beat each**; the oracle's rows are the
  uncached and write cases, which is what 7.2 specifies. The kernel's
  cache fill follows the same width (1.13 item 2) and is benched in item
  3 against RAM's port only.

**The oracle.** `sim/kernel_bus/beats.txt`, one line per beat: case,
operand offset, port; the `SIZ` and `A1-A0` driven, the bytes and lanes
moved, Table 7-5's four lanes with the beat's own byte names, the
`DSACK` pair, and `memmask` before and after. 63 cases - the prefetch
and the byte, word, long, three- and five-byte operands at every offset
to every port - 142 beats. The kernel bench of item 3 reads it; nothing
in it is derived from the kernel. `python scripts/se30_bus_beats.py
check` is the self-test, `emit` regenerates the file, `md` prints it for
reading.

**The bench on the kernel alone, and what it found (2026-09-26, the
same day).** The kernel is now in the tree: `rtl/tg68k/`, five files
from `030_mmu2@c3e8a0d` with the one ALU hunk 1.12 says to take, the
provenance in its README. `sim/kernel_bus/tb_kernel_bus.v` runs it
under ModelSim as upstream's own kernel benches do - `clkena_in` high, a
combinational 64K-word memory, one beat a clock - on a program
`gen_program.py` writes together with the beats it must produce, looked
up in the oracle: D0 = `$01020304` written and read back as a byte, a
word and a long at each of the four offsets, each read stored to a
result slot; three- and five-byte bit fields (`BFINS`/`BFEXTU` at bit
offset 4, widths 16 and 32) at each offset; the reset SSP read. Every
data beat is checked for its word address, its strobes, its direction,
the bytes on the strobed lanes on a write, and `memmask` before the
beat; the result slots are checked at the end. Fetches are not checked
(the prefetch contract is the adopted change). Results on the unmodified
16-bit kernel, the oracle's 16-bit-port rows:

| run | result |
|---|---|
| `BF5=0 sim/kernel_bus/run.sh` (everything but the five-byte fields) | **PASS, 103 checks, 90 beats.** The oracle and the kernel agree on every byte, word and long operand at every offset, read and written, on the three-byte fields, and on the reset read - beat counts, addresses, strobes, data, masks. Every result slot holds what was written. |
| `sim/kernel_bus/run.sh` (with them) | FAIL on exactly the five-byte rows, and six beats short. **The kernel does a five-byte field as one operand cycle**, mask `100000` consumed two bytes a beat: 2+2+1 beats at an even offset, **1+2+2 at an odd one** - where the adopted contract (two operand cycles, long then byte) gives 1+2+1+1. The merge 1.14 predicted from the mask, now observed. This is the first failing test of 1.13 item 2. |

So on a 16-bit port the kernel already does what UM 7.2 says for every
CPU operand; the change of item 2 is the width (`n` from `DSACK`, the
lanes of Table 7-5, the aligned-long prefetch) and the five-byte
split, and this bench with `PORT=32` and `PORT=8` is its acceptance
test. The corpus part of item 3 (cputest, the silicon captures) is
separate and still to do; note that the IIvi's silicon harness is
Verilator under WSL, not ModelSim, so those rows will be replayed
through a bench of ours.

## 1.15 The 32-bit shape: the design, before the VHDL

Written 2026-09-26 from reading the kernel's bus path end to end
(`TG68KdotC_Kernel.vhd` at `c3e8a0d`, `TG68K_ALU.vhd`), with the bench of
1.14 as the instrument. This is 1.13 item 2 turned into a change list,
so that the VHDL is written against a design and not discovered.

**What the kernel's beat engine actually is.** One `clkena_in` edge is
one acknowledged beat. Around it:

- `memmask` (1.14) names the operand's bytes; it is set at operand
  start from the size (`101111` byte, `100111` word, `100001` long,
  `100011`/`100000` bit fields) and shifted two bits at every beat.
- `memmaskmux` is the **beat descriptor** the rest of the kernel reads:
  bits 5:4 are this beat's strobes (`nUDS`, `nLDS`), bit 3 is "this is
  the last beat of the operand". It is `memmask` shifted by the address
  parity. **57 sites read it, almost all as bit 3**, and `clkena_lw`
  (`clkena_in AND memmaskmux(3)`) is the "operand complete" edge that
  94 sites key on: the register file write, the PC redirect of
  RTS/RTE/JMP, the PMMU register commits, the frame sequencing.
- `data_read` is the operand assembled so far: previous beats' data in
  `last_data_in`, this beat's `data_in` appended - 16 bits when `LDS` is
  active, 8 when only `UDS` is - and sign-extended by `memread`, a
  two-beat history of the strobes.
- `data_write` is a 16-bit slice of a 48-bit `data_write_mux` that
  holds the operand (`data_write_muxin`, plus `bf_ext_out` for a
  five-byte field) placed by `oddout` and `addr(0)`; the slice is
  chosen by mask bits, a lone byte replicated on both halves.
- The address of beat k+1 is `addr + 2`, computed by the ALU: when
  `long_start` (`NOT memmaskmux(3)`, "more follows") is set its
  add/subtract operand is 2 (TG68K_ALU ~689) and the sum is latched into
  `memaddr_delta_rega` at the beat's edge (~3427). On the last beat the
  same ALU path yields the register post-increment (+1/+2/+4/+8 by
  size), which is why the two are interleaved.
- Fetches (`state = "00"`) read a word at `TG68_PC`, which advances by 2
  a beat (`TG68_PC_add`); `opcode`, `brief`, `rte_format_word` and the
  F-line brief take the word from `data_read(15 downto 0)` or straight
  from `data_in`.
- The PMMU walker (`pmmu_walker_*`, 32-bit) and the caches
  (`TG68K_Cache_030`, in the wrapper) are outside this engine; the
  wrapper runs their beats.

**The design: one engine, n bytes a beat.** Every beat consumes n bytes,
1 to 4, and everything that today assumes "two, at a word address" is
made to follow n:

1. **`beat_off`**: a new counter, the bytes of the operand cycle consumed
   so far (0..4), reset at operand start, advanced by n at each
   acknowledged beat. `rem` = zeros in `memmask(4:0)` (bytes remaining).
2. **n**, combinational in the beat: the port rule of 1.14, n =
   min(rem, cycle_rem, width - (addr mod width)), with cycle_rem = 4 -
   `beat_off` while `beat_off` < 4 and 1 after - **that is the five-byte
   split**: a field of five bytes is a long at A then a byte at A+4 in
   both shapes, 3+1+1 at an odd offset where today's engine merges to
   1+2+2. In the 16-bit shape width is 2 and n needs no input; in the
   32-bit shape width comes from `DSACK` and n is valid only in the
   acknowledge cycle, which is also when it is used.
3. **`memmaskmux` recomputed, same meaning**: bits 5:4 the strobes this
   beat needs (16-bit: from n and `addr(0)`; 32-bit: kept as the
   16-bit-equivalent pair for `memread`'s benefit), bit 3 = `(rem = n)`.
   The 57 readers and `clkena_lw` do not change. `longword` (an Amiga
   burst hint) keeps `NOT memmaskmux(3)`.
4. **The mask shifts by n**; the address steps by n. The ALU gets one
   input, `beat_step` (n), used in place of the constant 2 when
   `long_start` is set - the ELSE branch at ~689 is reached with
   `long_start = '1'` only for that step, so this is equivalent today.
   With the address stepping by n, `memmask` bit 4 is always the byte
   at the beat's own address and bit 5 is never read: the oracle's
   convention (1.14's nuance goes away, and `gen_program.py`'s
   restatement with it).
5. **Read assembly by n**: `last_data_in <= last_data_in << 8n | the n
   bytes from the lanes`, lanes being (16-bit) `D15:8` then `D7:0` from
   `addr(0)`, or (32-bit) lanes `A1A0`.. of a 32-bit port, `A0`.. on
   `D31:16` of a 16-bit one, `D31:24` of an 8-bit one - Table 7-4's
   `OPn` positions. `bf_ext_in` (the fifth byte) is the byte that
   overflows the 32-bit accumulator, in both shapes. `memread` keeps its
   meaning from the recomputed strobes.
6. **Write placement by `beat_off`**: the operand as a byte array -
   `bf_ext_out` then `data_write_muxin`'s low `size` bytes, most
   significant first - and this beat drives bytes `beat_off ..
   beat_off+n-1` on the lanes: 16-bit as today (first byte `D15:8`,
   second `D7:0`, a lone byte on both); 32-bit as Table 7-5 verbatim.
   The 48-bit `data_write_mux`, `oddout` and `set_oddout` go; `mem_byte`
   (MOVEP) stays a byte operand.
7. **The 32-bit shape's ports**, by a generic `DATA_WIDTH` (16 today,
   32): `data_in`/`data_write` sized by it; `siz(1:0)` out = min(rem,4)
   encoded per Table 7-2; `dsack(1:0)` in, defaulted so existing
   instantiations compile; `addr_out(1:0)` is `A1A0` already;
   `nUDS`/`nLDS` still driven (GLUE derives byte enables from `SIZ` and
   `A1A0`, Table 7-7, and ignores them). VHDL-93 allows generic-sized
   ports; upstream's benches instantiate the entity directly with the
   defaults and keep compiling.
8. **The prefetch as an aligned long** (32-bit shape): a fetch beat
   requests the long at `PC AND NOT 3`, `SIZ = 00`; the beat delivers
   the word at `PC` (lanes by `A1`) to a new `bus_word(15:0)`, which
   replaces the raw `data_in` at the four fetch consumers and feeds
   `data_read(15:0)` on fetch beats; the other word and its address go
   to a **holding register**, and a later fetch whose `PC` matches is
   served from it with `busstate = "01"` (no bus cycle; the wrapper
   acknowledges an internal beat in one clock, as it does for every
   no-access cycle) - the 030's cache holding register, 6.1.1. On an
   8-bit port the same fetch is four beats, as Table 7-6 says. The
   16-bit shape keeps its word fetch.
9. **Not in the kernel**: cache fills and the walker's beats are the
   wrapper's (1.13 item 4); `TG68K_Cache_030` takes 32-bit fills
   already.

**The order, each step green on the 1.14 bench before the next:**

- ~~**2a - the engine in the 16-bit shape**: items 1-6 with width fixed
  at 2. Acceptance: `sim/kernel_bus/run.sh` at `PORT=16` with the
  five-byte fields in and the oracle's own masks (the restatement
  removed) - every row, including 1+2+1+1 at the odd offsets; then
  upstream's regression targets, which need a runner here (their suite
  is `make`-driven, and there is no `make` on this machine).~~
  **Done 2026-09-26.** The bench passes in full: 145 checks, 132 beats,
  the oracle's own masks, the five-byte fields 1+2+1+1 at the odd
  offsets. Three things learned on the way, each now in the code:
  - **the five-byte field is one mask, bounded**, not two masks: the
    kernel keeps `100000` and no beat crosses the boundary after the
    fourth byte (`op5`, `cycle_rem`); the oracle now says the same, its
    `oc` column marking the second cycle's beat. The bus beats are what
    two operand cycles would produce; the mask is internal.
  - **"the previous beat had no LDS" was three sites' proxy for "first
    beat of the operand"** (`memread(0)`: the start-address latch for
    the RMW write, the sign extension, the unaligned-MOVEM guard). It
    held because a UDS-only beat was always an operand's last; the
    boundary beat of an odd five-byte field is UDS-only mid-operand,
    and BFINS then wrote at A+4. Now "the previous beat strobed
    nothing" (`memread(1:0) = "11"`), which is what the reset to `1111`
    at operand start means. That class of proxy - a bus pattern
    standing in for a sequencing fact - is what to look for in 2b.
  - **the runner exists**: `sim/kernel_upstream/run.sh` replays
    upstream's `make` recipe (compile the four files `-93`, the bench,
    run for the Makefile's time) for the 17 benches of their
    `test-arch-suite` and `test-basic-cputest` that the tree holds
    (`suite.txt`; one the Makefile names is absent). Pristine kernel
    and ours give **identical verdicts on 15**: `tb_stack_frame_push`
    fails on both (MMU-configuration frame, pre-existing, 1.7's "not
    green"), and `tb_odd_exc_flags` / `tb_basic_exception_flags` fail
    on ours only in **"DIVU divide-by-zero saved SR mismatch"** - which
    is the ALU hunk 1.12 took, the IIcx-adjudicated CCR against the
    WinUAE model those two benches encode (UM: N, Z, V *undefined* on
    divide by zero). Confirmed by running both with upstream's ALU under
    our kernel: pass. The engine change itself regresses nothing there.
- ~~**2b - the 32-bit port**: item 7 and the width rule of item 2 for
  data operands. Acceptance: the bench at `PORT=32` and `PORT=8`, data
  beats; `PORT=16` unchanged.~~ **Done 2026-09-26.** `DATA_WIDTH` (16
  today, 32) sizes `data_in`/`data_write`; `dsack(1:0)` in, as the
  pins read in the acknowledge clock (`"10"` 8-bit, `"01"` 16-bit,
  `"00"` 32-bit, `"11"` taken as 32); `siz(1:0)` out. The port's room
  and first lane come from `dsack` and `A1A0` (Tables 7-1, 7-4, 7-7);
  the read assembly takes n bytes from the lanes; the write drives all
  four lanes as Table 7-5 says for `SIZ` and `A1A0`, the same pattern
  whatever the port answers, since the processor cannot know the width
  before `DSACK`. **The bench passes on all three ports**: 16 (145
  checks, 132 beats), 32 (109 checks, 96 beats), 8 (178 checks, 165
  beats); upstream's 17 benches unchanged from 2a. Two more things
  learned:
  - **the fetch pipeline is "one beat, one word"** - it advances the PC
    by two and reads its word from `data_read(15:0)` on every fetch
    beat - so a 32-bit port delivering a long extension word in one
    beat handed it the wrong word. Until 2c, fetch beats are capped at
    a word in the 32-bit shape (`room := 2` when `state = "00"`), and
    code on an 8-bit port is unsupported (the SE/30 has none: ROM and
    RAM are 32-bit). The `PORT=8` bench is arranged as the machine is,
    code in 32-bit memory and the operand area the 8-bit device.
  - **the sign extension used the strobe history as the operand's
    size** ("first beat" or "an odd word's two single-byte beats"),
    true on a 16-bit port only: a long in one 4-byte beat, or in four
    1-byte beats at an odd offset, came back as a word. The size is
    now latched at the operand's first beat (`op_size`). The second
    proxy of the kind 2a found.

  *A contract for the wrapper (item 4):* the kernel's `SIZ`, address
  and write lanes depend only on the operand and the address, so they
  are stable through a cycle; what depends on `dsack` (the mask shift,
  the address step, `clkena_lw`, `memmaskmux(3)`) commits in the
  acknowledge clock. The wrapper presents `dsack` with `clkena_in` and
  latches address, `FC`, `SIZ` and data at the start of its cycle, as
  the 68030 holds them from S0/S1.
- ~~**2c - the prefetch**: item 8. Acceptance: the bench's fetch beats
  checked against the `instr` rows at all three widths.~~ **Done
  2026-09-26.** A **fetch unit** between the pins and the core, in the
  32-bit shape only. The core still asks for one word at the PC and
  sees one acknowledge per word; the unit answers from a **holding
  register** when it holds that long (no bus cycle: `busstate = "01"`,
  the wrapper's one-clock internal beat), else it runs the bus beats of
  the aligned long - `A1A0 = 00`, `SIZ = 00`, then the long's next
  byte and the bytes remaining, one beat on a 32-bit port, two on 16,
  four on 8 - accumulating it, and acknowledges the core only on the
  last beat (`clkena_core = clkena_in AND fetch_ok`; the core's 37
  uses of the acknowledge now read `clkena_core`, the unit alone reads
  the pin). The core's fetch beat stays a word; its data comes from the
  unit (`lane_in` on a fetch). The long fetched goes to the holding
  register with its address; a write into that long invalidates it, as
  does reset. Not covered: an MMU remap under a held long (the 68030's
  own holding register is logical-tagged and not snooped either).
  **The bench passes on every arrangement**: 16-bit 145 checks; 32-bit
  110 checks, 96 data beats, **81 long fetches in 81 bus beats for 157
  program words**; 8-bit with code in 32-bit memory 179 checks; all on
  the 8-bit device (`CODE8=1`) 218 checks, 204 data beats, 81 longs in
  324 beats. The bench checks every bus fetch against Table 7-6's
  instruction row - start at `A1A0 = 00` with `SIZ = 00`, walk the long
  in the port's beats with `SIZ` counting down - and that the longs
  fetched are well under the words the program holds, which is the
  holding register serving. Upstream's 17 benches: verdicts unchanged.
  Item 2 of 1.13 is complete: the kernel has the 68030's bus.
- **2d - breadth**: upstream's suite in both shapes through the runner;
  the cputest corpus; the silicon rows replayed (the IIvi's harness is
  Verilator under WSL, so a bench of ours reads its captures).

**Cost, revised.** The central change is items 1-6, one afternoon's
VHDL (it was: 2a, 2b and 2c all landed the day this was designed) and
a week of watching the 57 + 94 sites behave through the suite;
2b is small once 2a holds; 2c is the one genuinely new piece of
sequencing. Weeks in total, as 1.13 said - but most of the risk sits in
2a, which is testable today.

---

# Section 2 - GLUE, the address map, RAM, clocks and the video PALs

Opened 2026-09-25. This is the first cut from one research pass; it records
what was read and where, and it is deliberately blunt about what is
inference. Every claim below is either from Apple's documentation, from the
schematic, from the ROM, or is marked as a reading of a secondary source.

## 2.1 Sources, and their standing

| source | what it is | standing |
|---|---|---|
| *Guide to the Macintosh Family Hardware*, 2e (1990) | Chapters 3 (processor and general logic), 4 (VIAs), 5 (memory), 12 (displays) | **primary**. Text extracted with `pdftotext`; the page images are JBIG2 and cannot be rendered here, so tables come from the OCR text, which runs words together but is legible |
| `se30.pdf` (bitsavers) | **Apple drawing 050-0253-01, "Schematic, Main Logic Board, Mac SE/30", Engineering Release** - 9 D-size sheets, of which the scan holds 8 (sheets 1-8; sheet 9 is missing). Raster only, ~3500 px wide per sheet | **primary**. Read as images; crops at full resolution are legible to the pin |
| `mishimasensei/macse30mlb` | a **KiCad redraw of 050-0253-01**, all 9 sheets plus a pin-matrix "Tables" sheet, **MIT licence**. Snapshot at `C:/Git/MiSTer-devel/macse30mlb` (tarball, because one file's name has a colon and cannot exist on NTFS) | **secondary** - someone's transcription of the scan. `scripts/kicad_nets.py` reads its v5 sheets and prints pin-to-net tables; where checked against the scan (UI6, UG7, UE7, UE6, UH7) it agrees, with one bus-label ambiguity noted in 2.6 |
| Bolle's six JEDECs | reverse-engineered, rewritten equations for the later board's PALs, CC-BY-NC-SA | **behavioural reference, read-only**; see 1.6. `scripts/jedec_dis.py` recovers their equations |
| **BOMARC Services, 1992** (`se30schems.zip` from Macintosh Repository item 875, extracted to `C:\temp\Mac\SE30\Docs\se30schems\BOMARC`) | nine hand-drawn sheets reverse-engineered from a board marked **820-0260-A**: CPU/FPU/PDS; RAM SIMMs and GLU; video RAM and PAL chips; serial/SCSI/clock/PRAM/ADB; floppy/SWIM/audio; PSU plug/ROM SIMM/clock/battery; plus the ASTEC power supply, the fan and CRT board, and the Sony floppy drive - the analogue boards Apple's set does not cover | **secondary, independent of Apple's drawing** - a second transcription of the same hardware. It names GLUE as `VGC7219A0669 (344S0602-A)`, which settles the "probably GLUE" of 1.6; its PALs are `341-0746-A`, `-0747-A`, `-0754-A`, `-0755-A`, `-0665-A` - **Bolle's set, so the "later board" of 1.6 is 820-0260-A**; and it gives the VRAM as TMS4461-15NL or uPD41264-15. The same zip's `Apple/SE30_P1-P8.GIF` are pixel-identical to `se30.pdf`'s pages; still no sheet 9 |
| the `$97221136` ROM | | **primary** for what software expects of the hardware (1.11) |
| MAME `macii.cpp` | | cross-check only |

The sheets of 050-0253-01, from their title boxes: 1 CPU and FPU; 2 ROM and
RAM address muxes; 3 GLUE and RAM SIMMs; 4 VIA1, VIA2, RTC, ADB; 5 video
interface; 6 SWIM and SCSI; 7 serial and sound; 8 power connector, pull-ups
and pull-downs; 9 not in the scan (the redraw titles it "Unknown").

## 2.2 The address map

**32-bit physical map** (*Guide* Figure 3-6 and Table 3-8, and the ROM's
own 32-bit translation table, 1.11 - the three agree):

| range | what | notes |
|---|---|---|
| `$00000000-$3FFFFFFF` | RAM | *Guide* 5: "reserved for RAM"; contents repeat through the unused space. Populated sizes in Table 5-2: 1, 2, 4, 5, 8, 16, 32, 64, 128 MB, top address `$007FFFFF` for 8MB, `$07FFFFFF` for 128MB. "You must use a 32-bit operating system to make use of system memory beyond 8 MB" |
| `$40000000-$4FFFFFFF` | ROM | the 256KB image repeats. Table 3-8 maps 24-bit `$800000` to `$40000000`; the ROM's own table maps it to `$40800000` and the reset PC is `$4080002A` - both are the same ROM through the mirror. GLUE has no A18, A19, A21 or A23 pins (2.3), so the mirroring is structural |
| `$50000000-$50FFFFFF` | I/O | GLUE-decoded, one device per `$2000`; see the DSACK table below. MAME mirrors it with mask `$00F00000`, which is what the 24-bit `$F00000 -> $50F00000` mapping needs |
| `$51000000-$5FFFFFFF` | undecoded | Figure 3-6: "no DSACKx" - a bus error by timeout, which GLUE generates (2.3) |
| `$60000000-$EFFFFFFF` | nothing on an SE/30 | NuBus super-slot space on a II; the SE/30 has no NuBus. Bus error |
| `$F1000000-$FEFFFFFF` | slot space, 16MB per slot | slots `$9-$E` in the II family; **on the SE/30 only `$E` exists, and it is the internal video** (2.6) |
| `$FE000000-$FEFFFFFF` | slot `$E`: video | VRAM at `$FE000000`, declaration ROM at `$FEFFE000` (MAME; the *Guide* gives the space, not the offsets - see 2.6). **The System's ScrnBase is `$FEE08040`** - the driver's own constant (2.10), an alias of the same VRAM through the A16-only decode |

**24-bit map**, which is what the machine runs in (1.5): *Guide* Table 3-8
and the ROM table at `$40800050` are identical - `$0-$7` MB RAM, `$8` ROM,
`$9-$E` the slots, `$F` I/O at `$50F00000`. The PMMU does this (1.11); the
decoder sees only 32-bit addresses.

**The ROM overlay.** *Guide* 3: "The ROM overlay address map, used when the
Macintosh SE/30 is turned on or reset, maps addresses from `$00000000` to
`$3FFFFFFF` to locations in ROM rather than to RAM. The RAM cannot be
addressed at all when the ROM overlay address map is being used. The startup
or Reset handler software switches from the ROM overlay address map to the
normal address map by setting low the Overlay signal from VIA1." The signal
is VIA1 PA4 `OVERLAY`, wired to GLUE pin 49 (sheet 3, sheet 4). This is how
the reset vector at `$00000000` is fetched from ROM.

**DSACK and wait states** (*Guide* Figure 3-6 and the text under it, which
is the SE/30's own):

| device | wait states | DSACK |
|---|---|---|
| RAM, ROM | **one** ("in contrast to the Macintosh II, in which there are two") | GLUE |
| SWIM | one | DSACK0 |
| SCSI, non-handshake | one | DSACK0 |
| ASC | two on reads, one on writes | DSACK0 |
| SCC, VIAs, SCSI with handshake | "special control of the /DSACK0 signal" | GLUE holds off: the SCC needs 2.2 us between accesses and GLUE enforces it for back-to-back cycles; the VIAs are 6800-bus synchronous devices clocked by E; SCSI handshaking holds DSACK until the transfer completes |

GLUE "responds to any I/O device address with a /DSACK0 signal" and "the
/DSACK0 and /DSACK1 signals ... indicate to the MC68030 the size of a
device's data bus" - so the I/O devices are 8-bit ports and RAM/ROM are
32-bit. **The I/O map, read from Figure 3-6's page image (2026-09-25,
poppler render), bottom to top:**

| range | device | DSACK |
|---|---|---|
| `$50000000-$50002000` | VIA1 | special |
| `$50002000-$50004000` | VIA2 | special |
| `$50004000-$50006000` | SCC | special |
| `$50006000-$50008000` | SCSI (handshake) | special |
| `$50008000-$50010000` | expansion address space | **no DSACK** |
| `$50010000-$50012000` | SCSI | one wait state, DSACK0 |
| `$50012000-$50014000` | SCSI (pseudo-DMA) | one wait state, DSACK0 |
| `$50014000-$50016000` | Sound (ASC) | two wait states, DSACK0 |
| `$50016000-$50018000` | SWIM | one wait state, DSACK0 |
| `$50018000-$50020000` | expansion address space | one wait state, DSACK0 |
| `$50020000-$51000000` | "reserved for future expansion (presently wraps `$50000000-$5001FFFF` eight times)" | |
| `$51000000-$5FFFFFFF` | undecoded | **no DSACK** |

"Wraps eight times" is the figure's phrase; the *decoded* block is 128KB
(`$20000`), and GLUE's missing A18/A19 pins explain a wrap, but eight
repeats over 16MB do not follow from the pin list alone - **the exact
mirror rule is an open item for the GLUE specification (2.8).** MAME's map
agrees on every device address; it mirrors on `$00F00000`, which is a
different, coarser statement.

The same figure's **standard slot space**, `$F1000000-$FFFFFFFF` at 16MB
per slot: three **"pseudo-slots"** at `$F9000000`, `$FA000000` and
`$FB000000` - the PDS, which presents expansion cards as slots 9-B - a gap
at `$FC-$FD`, and at `$FE000000` **"Video: RAM `$FE000000-$FEFF0000`, ROM
`$FEFF0000-$FF000000`"** - so the declaration ROM occupies the top 64KB of
slot `$E`'s space, and MAME's 8KB at `$FEFFE000` is the top of that, where
a NuBus declaration ROM's directory is expected. `$F0000000-$F1000000` is
reserved; `$60000000-$F0000000` is drawn as NuBus super-slot space, which
the SE/30 does not have.

## 2.3 GLUE

**What it does** (*Guide* 3, the SE/30 / II / IIx GLUE section, in full):
decodes addresses and asserts device selects; sends the acknowledge signals
that also specify the device's bus width; generates `/RAS`, `/CAS` and
controls the RAM address multiplexers; refreshes DRAM; generates the
15.6672 MHz processor clock, the 3.672 MHz SCC clock (also used by the ADB
transceiver's microcontroller) and the 783.36 kHz E clock for the VIAs;
monitors data transfers and generates Bus Error when one fails to complete;
handles SCSI hardware handshaking; ORs the six slot interrupts into VIA2;
and prioritises the interrupts from the VIAs, the SCC, the power switch and
the NMI switch onto the IPL lines, passing only the highest.

**What it is connected to** - sheet 3, `UI8`, an 84-pin part, by the
redraw's netlist (`kicad_nets.py ... UI8`), checked against the scan:

| group | pins |
|---|---|
| address in | `A31 A30 A29 A28 A27 A26 A25 A24 A22 A20`, `LA17 LA16 LA13`, `A16 A15 A14 A13`, `A1 A0`. **No A18, A19, A21, A23, and nothing between A2 and A12** - the decode is coarse, and I/O device selection is on A13-A17 |
| CPU control | `ASN DSN` in; `FC0-2`; `SIZ0 SIZ1`; `WRITEN` (R/W); `DSACK0N DSACK1N` out; `BERRN` out; `IPL0-2N` out |
| clocks | `C32M` in (from UH7, 2.5); `C16M` out (the net is `C16G`); `C3M`, `SYNC`, `SYNC3M`, `E` out |
| RAM | `RASA RASB`, `CASLL CASLM CASUM CASUU` (four byte lanes), `RCMUX` (row/column mux select), `RAMSIZ0 RAMSIZ1` in |
| selects out | `ROMN`, `SCSIN`, `IWMN` (the SWIM), `VIA1CSN VIA2CSN`, `SCCENN SCCRDN SCCWRN`, `IORN IOWN`, `SNDN` (ASC), `FPUN`, **`NUBUSN`** (the pseudo-slot, 2.6), `SCSIDRQ SCSIDACKN` |
| interrupts in | `SLTIRQ1-6N` (the six slot lines - on the SE/30 only 6 = slot `$E` is driven, by UI6), `SLTIRQN` (the OR, to VIA2 CA1), `NMIN`, `PWRIRQN`, `SCCIRQN`, `VIAIRQ1N VIAIRQ2N` |
| misc | `OVERLAY` in (VIA1 PA4), `TESTN` / `TSTOEN` (test) |

The two-bank RAM (`RASA`/`RASB`) and the four CAS lanes are the shape of the
RAM controller we must build; `RAMSIZ` is not a strap but **two VIA2 output
bits** (PA7 `v2RAM1`, PA6 `v2RAM0` - *Guide* Table 4-9, and sheet 4). *Guide*
Table 4-10 gives their meaning: `00` = 256 Kbit, `01` = 1 Mbit, `10` = 4
Mbit, `11` = 16 Mbit RAM ICs in bank A, and the text: "set at system
startup by the firmware to indicate the size of the RAM ICs being used in
the RAM SIMMs in bank A ... The RAM-size bits determine the physical
address at which the GLUE IC stops selecting bank A and starts selecting
bank B." So the ROM sizes bank A, tells GLUE its IC size, and GLUE places
bank B immediately after it - at 1, 4, 16 or 64 MB - which is what MAME's
remark about `via2_out_a` means, and is the bank-boundary rule the RAM
controller implements.

**GLUE is not documented internally anywhere found**, and the VLSI part on
the board (1.6) is not the kind of thing a fuse map exists for. Everything
above is its *contract*: the *Guide*'s function list, the pin list, the
wait-state table, and the ROM's expectations. That is the specification
Section 2's GLUE has to be written to, and 1.10's benches are how it is
held to it.

## 2.4 RAM

Two banks of four 30-pin SIMMs, 32 bits wide, byte-lane CAS (sheet 3). Row
and column addresses are multiplexed by eight 74F258s (sheet 2) under
`RCMUX` from GLUE, with the mux outputs `RAAF*`/`RABF*` fed to the SIMMs
through series resistors. One wait state per access (*Guide*, 2.2). Refresh
is GLUE's. The ROM's size table is `01 02 04 05 08 10 11 14 20 40 41 44 50
80` MB (1.11), i.e. every combination of two banks each of 1MB or 4MB
SIMMs... plus 16MB SIMMs, which is where 32/64/128 come from.

**`UH7` (16L8, sheet 2) makes the RAM write strobes.** Named from the scan
crop and from Bolle's equations: inputs `RCMUX`, `RASA`, `WR*`, `RASB`,
`CASLL`, `C32G`; outputs `RCMUX*` (= `/RCMUX`, to the muxes' select),
`WR` (= `/WR*`), `C32M` (= `/C32G`, to GLUE through 47 ohms), and two
latched strobes `RAMRWA` and `RAMRWB`, each set from its bank's RAS with
`CASLL` and the CPU's R/W and held by feedback until RAS releases. The exact
equations are in Bolle's `UH7` (read only); the *function* - a per-bank
early-write strobe latched for the RAS cycle - is what we implement.

## 2.5 Clocks

One oscillator: `Y2`, **31.3344 MHz** (sheet 2), buffered through UH7 as
`C32M` into GLUE. GLUE divides: `C16M` 15.6672 MHz to the CPU, the FPU, the
PDS and the video sheet (where it is the **pixel clock** - *Guide* 12:
"the pixel clock rate is 15.6672 MHz"); `C3M` 3.672 MHz to the SCC and ADB
transceiver; `E` 783.36 kHz to the VIAs; `SYNC`/`SYNC3M`. `UI6` (16R4, CPU
sheet) re-registers `C16G` on `C32M` (Bolle's `/o17 := i2`) to make a
phase-aligned 16 MHz, and also holds the small CPU-side glue: `AS*` to the
system is the CPU's `LAS*` **suppressed when FC=7** (`/AS* = /LAS* * (/FC0 +
/FC1 + /FC2)`) - the FC=7 rule of 1.4 exists in hardware, so CPU-space
cycles never reach GLUE; `IRQ*(6)`, the slot-`$E` interrupt, is
`VSYNC*` gated by `VSYNCEN*` (VIA1 PB6) and latched; `BERR*` is on pin 12
with `LAS*` in its term - ~~the OE handling of that pin is not yet
understood and is an open item~~ read in 2.9 item 4 and timed in 2.11.4:
a bus-cycle timeout of 18.4-63.3 us, phase-locked to `HSYNC*`.

## 2.6 Video: the pseudo-slot

*Guide* 3: the video PALs "perform the video functions handled by the BBU
in the Macintosh SE, plus the video functions performed by a NuBus video
card ... they generate the vertical and horizontal blanking interrupt
signals ... implement the frame buffer controller (FBC) functions of a NuBus
video card ... implement the declaration ROM functions of a NuBus video
card", and no CLUT. *Guide* 12: 512 x 342, one bit per pixel, 1 = black;
15.6672 MHz pixel clock; 512 active + 192 blanking = 704 pixel times per
line, 44.93 us, **22.25 kHz**; 342 active + 28 blanking = 370 lines,
16.626 ms, **60.15 Hz**; 21,888 bytes per frame; two screen buffers, the
alternate at `ScrnBase - $8000`, selected by VIA1 PA6 (`ALTVID` on the
schematic).

**The hardware, from sheet 5 and the netlist.** Now settled, and it is not
what 1.6 assumed about "fetch":

- **VRAM is two NEC 41264 dual-port DRAMs** (`UC6`, `UC7`, 64K x 4 each =
  64KB), on the CPU side through their parallel port to **byte lane
  `D(31:24)` only** - an 8-bit device, which is why it takes the "special"
  `DSACK*(0)` from `UE6` - with their own `VIDRAS*`/`VIDCAS*` and address
  muxes (`UA8-UD8`, 74F253, selecting CPU address or the video counters
  under `VIDMUX*`).
- **Scan-out uses the VRAMs' serial ports.** `SO(0:3)` of both parts form
  `VID(0:7)`, clocked by `SC` (from `UG7`) with `DT/OE*` transferring a row
  into the serial register; `VID(0:7)` loads a **74LS166 shift register
  `UE8`** on `SREGLD`, clocked at `C16M`, whose `Qh` is `SERVID` into `UG6`,
  which produces `VIDOUT`. **So video never reads the CPU-side port and
  never contends with the bus.** 1.6 said "no main-bus fetch"; it is
  stronger than that - no *bus* fetch at all.
- **Timing counters**: `UG8` (two LS393 halves, `CNT0-7`) clocked by `C2M`
  (`C16M/8` from `UG7`, one count per byte of pixels) and reset by
  `HCTRRST`; `UF8` (`VADR0-7`) clocked by **`TWOLINE`** and reset by
  `LCTRRST` - the line counter counts *pairs* of lines (370/2 = 185 fits
  eight bits), and `VADR` is what the VRAM address muxes see.
- **`UG7`** (registered): in `CNT0-6`, `VIDTIME`; out `HCTRRST`, `HSYNC*`,
  `SREGLD`, `SC`, `C2M`, `TWOLINE`, and a 3-bit internal counter on its
  unconnected pins 16-18. The horizontal timing generator.
- **`UG6`** (registered): in `VADR0-5`, `VADR7`, `SERVID`; out `VIDTIME`,
  `VIDOUT`, `VSYNC*`, `LCTRRST`. The vertical timing generator and the
  final pixel gate.
- **`UE7`** (registered): in `HSYNC*`, `SLTE-F`, `A(24)`, `NUBUS*`,
  `VIDTIME`; out a five-bit state `VIDS0-4`, `VR*`, `VIDREQ`, `VID-V`.
  The CPU-access state machine: it arbitrates a CPU cycle into the VRAM
  between the display's own row transfers.
- **`UE6`** (16L8): in `VIDREQ`, `C16M`, `VIDS0-4`, `VID-V`, `R/W*`,
  `A(16)`; out `VIDROM*`, `VC*`, `DSACK*(0)`, `DOE*`, `VIDMUX*`, `VIDW*`.
  The decoder for the slot: `A(16)` splits VRAM from declaration ROM
  within the slot, `VIDROM*` enables `UK6`, a **2764 8KB EPROM** on
  `D(31:24)` - the declaration ROM - and `DSACK*(0)` is the slot's
  acknowledge.
- **Slot decode**: `UJ6` (74LS30) NANDs `A(31:25)` - all ones means
  `$FE000000` or `$FF000000` - into `SLTE-F`; `UE7` then takes `A(24)` to
  pick `$FE`, and `NUBUS*` from GLUE qualifies the cycle. GLUE's `NUBUSN`
  is therefore the pseudo-slot's select, which is exactly how a II's GLUE
  would select real NuBus space.

**Interrupts, two of them.** `VSYNC*` from `UG6` goes (a) to `UI6`, which
raises **`IRQ*(6)` = slot `$E`'s interrupt** when `VSYNCEN*` (VIA1 PB6) is
low - the *Guide* 4 table: PB6 "`vSyncEnA` 0 = vertical synchronization
interrupt enabled (Macintosh SE/30 only)" - through GLUE's slot-interrupt OR
into VIA2 CA1; and (b) the classic VBL on **VIA1 CA1**, which is **not the
video's at all**: `VBLK*` is VIA2 PB7, and *Guide* Table 4-15 says "`v2VBL`
... 60.15 Hz interrupt request to VIA1 ... driven by timer T1 to send the
60.15 Hz interrupt request to VIA1 once every 16.63 ms". So the VBL that
System software sees on VIA1 is **VIA2's timer 1 free-running with PB7
toggle**, programmed by the ROM, and *Guide* 12's "driven by a 60.15 Hz
clock and is not synchronous with the blanking of the screen" is exactly
that. Software that wants the real retrace uses the slot-`$E` interrupt
through the Vertical Retrace Manager's per-slot queue. MAME's
`se30_vbl_enable` on VIA1 PB6 and `nubus_irq_w<0xe>` are the slot path.
**Consequence for the core:** the VIA2 T1/PB7 mechanism must be modelled
faithfully, because the 60.15 Hz the OS runs its VBL tasks on comes from a
timer the ROM programs, not from the video counters.

**What the declaration ROM contains: read, 2.10.** It is Apple part
341-0650, 8KB, MAME's `se30vrom.uk6` (CRC `b74c3463`, now at
`C:\temp\Mac\ROMS\MacSE30\`). One video mode, two pages, ScrnBase
`$FEE08040`, the driver's whole hardware contract is VIA1 PB6 and PA6, and
it settles the interrupt latch, the `$FEE0xxxx` aliasing and the `$40` row
offset. Without it the ROM's Slot Manager finds no video card.

**Cross-check note.** The redraw labels UI6 pin 13 with a bus (`IRQ*(1:6)`);
the scan says `IRQ*(6)` and so does the logic. Trust the scan.

## 2.7 VIAs

Both are 65C22s at `E` (783.36 kHz), 6800-bus, `PH0 = E`, chip selects from
GLUE (sheet 4, netlist confirmed). The bit assignments as wired, against
*Guide* Tables 4-5, 4-14 and the VIA2 tables:

| VIA1 | wired to | VIA2 | wired to |
|---|---|---|---|
| PA0-2 | `V1PA0-2` (to the PDS/ID straps, 1.11's box-ID read uses PA6) | PA0-5 | `IRQ*(1:6)` - the slot interrupt lines, readable |
| PA3 | `SYNC` | PA6, PA7 | **`RAMSIZ(0:1)` out, to GLUE** |
| PA4 | `OVERLAY` out, to GLUE | PB0 | `CDIS*` (cache disable) |
| PA5 | `HDSEL` (floppy head select) | PB1 | `BUSLOCK*` |
| PA6 | `ALTVID` (alternate screen buffer) | PB2 | `PWROFF` |
| PA7 | `SCCWREQ*` in | PB3, PB6 | `SNDEXT*` / `V2PB3` (the redraw ties both; 1.11's box-ID read tests PB3 as an input - **verify on the scan**) |
| PB0-2 | RTC data, clock, `CS*` | PB4, PB5 | `TM1A*`, `TM0A*` (to the PDS) |
| PB3-5 | `ADB-INT*`, `ADB-ST0`, `ADB-ST1` | PB7 | `VBLK*` |
| PB6 | **`VSYNCEN*`** out | CA1 | `SLOTIRQ*` (GLUE's OR of the slots) |
| PB7 | `V1PB7` | CA2 | `SCSIDRQ` |
| CA1 | `VBLK*` | CB1 | `SNDINT*` (ASC) |
| CA2 | `RTC-1HZ` | CB2 | `SCSIIRQ` |
| CB1, CB2 | `ADB-SCLK`, `ADB-DIO` (the shift-register ADB of 1.6) | | |

**The *Guide*'s tables, now read from the page images** (Tables 4-5, 4-9,
4-10, 4-14, 4-15), correct and complete the wiring column:

- VIA1 A: 7 `vSCCWrReq` in (SCC W/REQ A and B wire-ORed); **6 `vPage2` out
  (SE/30: 0 = alternate screen buffer, 1 = main)** - on the II/IIx this pin
  is `CPU.ID1` in, which is what the ROM's box-ID probe of 1.11 reads; 5
  `vHeadSel`; 4 `vOverlay` (1 = ROM overlay map); 3 `vSync` (SCC channel A
  clock select); 0-2 reserved.
- VIA1 B: 7 `vSndEnb`; **6 `vSyncEnA`, "0 = vertical synchronization
  interrupt enabled (Macintosh SE/30 only)"**; 5, 4 ADB state ST1, ST0; 3
  `vFDBInt` ADB interrupt in; 2 `rTCEnb`; 1 `rtcCLK`; 0 `rtcData`.
- VIA2 A: 7, 6 `v2RAM1`, `v2RAM0` out (2.4); 5-0 `v2IRQ6`-`v2IRQ1` in, the
  slot `$E`-`$9` interrupt lines, readable so the handler can find the slot.
- VIA2 B: **7 `v2VBL` out, the 60.15 Hz to VIA1 (2.6)**; 6 `v2SNDEXT`
  **tied low on the SE/30** ("so that the Sound Manager always operates in
  stereo mode"; the SE/30's sound circuit mixes to mono for the speaker); 5,
  4 `v2TM0A`, `v2TM1A` NuBus transfer-mode acknowledge, "available to an
  expansion card in the processor-direct slot"; **3 `vFC3` tied low on the
  SE/30** - the `V2PB3` net, which resolves the box-ID probe's PB3 read to
  a constant 0; 2 `v2PowerOff`; 1 `v2BusLk`; 0 `v2CDis`, "0 = disable main
  processor's instruction and data caches".

Interrupt levels, *Guide* Table 3-4 (the Macintosh II's, which shares this
GLUE; nothing SE/30-specific contradicts it): **level 1 VIA1 (autovector
`$19`), 2 VIA2 (`$1A`), 4 SCC (`$1C`), 6 power switch (early II only), 7
the interrupt switch (`$1F`)**; all autovectored. The six slot lines are
ORed by GLUE into VIA2 CA1 and are also readable on VIA2 PA0-5; on the SE/30
"an expansion card in the processor-direct slot can be addressed like a
NuBus card in slot `$9`, `$A`, or `$B`, and can generate the corresponding
interrupt. Also ... the interrupt for slot `$E` can be generated by the
video logic circuits on the logic board" (Table 4-10's text).

**Interrupt acknowledge, and why it never reaches the bus.** *Guide* 3
(p. 98): the processor acknowledges by "asserting all three function-code
signals (FC2 through FC0) to indicate the main processor address space, and
by putting an address in the range `$FFFFFFF0` through `$FFFFFFFF` on the
address bus"; it "checks the /AVEC signal, which is permanently asserted
(tied low)" and autovectors. Sheet 1 shows the 68030's `AVEC` pin grounded
on the SE/30 too. And UI6 (2.5) suppresses `AS*` for FC=7, so the
acknowledge cycle is invisible to GLUE and every device. **For the core:**
tie `AVEC` low in the wrapper, never generate a vector, and expect FC=7
cycles to complete without any bus activity - the same FC=7 exclusion 1.4
already records for the walker.

## 2.8 What Section 2 does not settle, and the work

Not settled: ~~GLUE's internal timing (there is no source; it is a
contract)~~ (written as a contract with envelopes, 2.11; the open cells
there are the VIA alignment, the SCC's own wait-state count, the SCSI
handshake timeout and the `C3M` pattern); ~~the I/O block's exact mirror
rule ("wraps eight times", 2.2)~~ (a rule chosen and its residual risk
stated, 2.11.2); ~~the declaration ROM's contents and where to get an
image~~ (read, 2.10); ~~the `BERR*` term on UI6~~ (2.11.4); sheet 9; and
everything on sheets 6-8 (SWIM, SCSI, SCC, ASC, power), which are later
sections. Settled since the first cut, from the *Guide*'s
page images (poppler under WSL renders the JBIG2 pages): Figure 3-6's I/O
rows, the interrupt levels and autovectoring, the VIA bit tables, the
RAM-size bits and bank rule, and the VBL's origin in VIA2 T1.

Proposed work, cheap and decisive first:

1. ~~**Name every PAL pin and re-derive the six equations with names**~~
   **Done 2026-09-25 - 2.9.** New open item from it: **372 or 370 lines
   per frame** (2.9), which needs a good dump of Apple's UG6, Bolle's
   account of how his was derived, or a measurement on hardware with
   Apple's PALs (provenance checked 2026-09-25, in 2.9).
2. ~~**Re-read Figure 3-6's I/O rows and the interrupt section**~~ **Done
   2026-09-25** - `pdftoppm` (poppler-utils under WSL) renders the JBIG2
   pages; results folded into 2.2, 2.4, 2.6 and 2.7.
3. ~~**Obtain the declaration ROM** image and read its slot resources~~
   **Done 2026-09-26 - 2.10.** Daniel supplied MAME's image;
   `scripts/se30_declrom.py` reads it. It settles the interrupt latch, the
   `$FEE0xxxx` screen address, the `$40` row offset and PA6's polarity,
   and hands 2.8 item 5 its bench oracles.
4. ~~**Write the GLUE specification** as a table of cycles: for each
   region, the select, the width, the wait states, the DSACK behaviour,
   and the bus-error timeout~~ **Done 2026-09-26 - 2.11.** Seventeen
   rows, the bus-error window corrected to 18.4-63.3 us, the cache-inhibit
   finding (no `CIIN` on the board; the PMMU tables do it), and a bench
   list in 2.11.7.
5. ~~Only then: the video PALs as RTL, from the named equations, benched
   against the *Guide*'s line and frame counts (704 x 370 at 15.6672 MHz),
   and now also extracting row 15's cycle count for 2.11.~~ **RTL and
   bench done 2026-09-26: `rtl/se30_video.v`, `sim/video/tb_se30_video.v`
   (36 checks pass under iverilog; `sim/video/run.sh`).** Written from the
   numbers in 2.6, 2.9 and 2.10, not from the equations; standalone, one
   clock per pixel, dual-ported VRAM, the declaration ROM loaded from the
   image. Held to: 704 x 370, active lines 2-343 with 64 bytes each,
   `HSYNC*` 288 from 536, `VSYNC*` 4 from 344, row 1 first and PA6 = 1 the
   upper 32KB, black blanking, `DSACK0*` only during an access, the ROM
   half byte-exact and mirrored, the `IRQ6*` latch's whole cycle, and
   PrimaryInit's 43,776-byte fill. The frame length is the `V_TOTAL`
   parameter (370), so the 372 question is one number in the DUT. Not
   yet done: a `cep` enable for running at a core clock above `C16M`, and
   the GLUE-side decode (A23-A17 ignored, 2.10 item 2), which belongs
   with GLUE.
6. ~~Read UE7/UE6 as a state machine (a small equation simulator over
   Bolle's JEDECs, behaviour only) to close the slot access length~~
   **Done 2026-09-26 - 2.12, `scripts/se30_pals/palsim.py`.** The RTL now
   carries UE7's machine state for state; the bench has 44 checks
   including the 5/6/7-clock accesses, the pixel-560 acknowledge and the
   20.14 ms fill. The pixel/line numbering of 2.9 was off by one and is
   corrected there and in 2.12.
7. ~~Next: the GLUE RTL against 2.11, bench first.~~ **Done 2026-09-26:
   `rtl/se30_glue.v`, `sim/glue/tb_se30_glue.v` (86 checks pass under
   iverilog; `sim/glue/run.sh`).** Bench first (`6d085c0`, failing), then
   the RTL; the two decisions the bench forced are 2.13. Held to: the
   cycle counts of every row of 2.11.3, the 12-32 VIA envelope, the SCC
   hold-off, the DRQ handshake, UI6's three-phase timeout to the pixel,
   the bank rule, overlay, the byte-lane and bus-sizing rules, the
   interrupt encoder, refresh and C3M. Three bench-model corrections were
   needed on the way (the ROM model's slice, the slot model's own `$FE`
   decode, DRQ up for the handshake decode check); no cell of 2.11 moved.
   Open, as before: the SCC's own wait count (built as one), E's duty,
   the A17 = 1 windows.
8. Next: **first the kernel's 32-bit bus (1.13), then** cut the MacLC tree
   and write the ASC, SWIM, SCC and SCSI sections from their documentation
   (Daniel's ordering of 2026-09-26: no 16-bit workaround; the tree is cut
   once, on the real bus). **1.13 done the same day; the tree cut is
   Section 3, written 2026-09-26 (3.8 is its work list).**

## 2.9 The PALs, named and read

Done 2026-09-25 (2.8 item 1). `scripts/se30_pals/` holds one `.pins` file
per device - pin number to schematic signal, from `kicad_nets.py` and the
scan crops - and `run.sh` disassembles Bolle's six JEDECs with those names.
Three things had to be fixed in `jedec_dis.py` first, each a way the earlier
positional reading was silently wrong:

- **Polarity.** A GAL16V8 has a per-output XOR fuse; five of the six files
  use it. The tool now applies it (an output with XOR=1 is rendered `X :=`
  rather than `/X :=`), taking the bits pin 19 first. Evidence for that
  order: read so, UG6's `VSYNC*` decodes active-low and its `LCTRRST` - an
  LS393's active-high CLR - decodes active-high, both as the board needs;
  the reverse order breaks `VSYNC*`.
- **Product-term enables** (one fuse per row) are honoured; in UI6 the
  unused rows are exactly the disabled ones.
- **16L8 columns.** In a 16L8 - and a GAL in complex mode - pins 1 and 11
  are inputs and take the two array columns that a registered part gives
  to pins 19 and 12's feedback. Found because `A16`, UE6's pin 11, appeared
  in none of its equations; with the map corrected it is the RAM/ROM
  split, exactly where it should be.
- **Output-enable terms** are now printed for combinatorial pins, which is
  where UI6's `BERR*` logic actually lives.

`validate` still reproduces National's reference disassembly exactly after
all of this.

**Standing.** Bolle's equations are a behavioural rewrite under
CC-BY-NC-SA (1.6): they were *read* to get the behaviour below, and the
behaviour is recorded as timings and functions. The RTL will be written
from those numbers and the *Guide*, not from the equations. Where a number
below disagrees with the *Guide*, the *Guide* is the specification until
silicon evidence says otherwise ([[feedback-replicate-bugs-else-spec]]).

**Horizontal timing - UG7 with the UG8 counter.** Clocked by the 15.6672
MHz pixel clock. A 2-bit internal phase counter, resynchronised by
`VIDTIME`, divides it to `C2M` = C16M/8 - one count per byte of pixels -
which clocks UG8. UG8 counts 0-87 and `HCTRRST` clears it at 88: **88
counts x 8 = 704 pixels per line**, the *Guide*'s figure exactly. `SC`,
the VRAMs' serial clock, pulses once per byte for counts 0-63 - **64 bytes
= 512 pixels** - and `SREGLD` (one clock behind `SC`) loads each byte into
the LS166; for counts 64-87 nothing is loaded and the shifter clocks in
ones from its pulled-up serial input, which is black (1 = black), so
**horizontal blanking is implicit** - 192 pixels, as the *Guide* says. The
counter also makes `TWOLINE`, which toggles at every `HCTRRST` and clocks
the vertical counter every two lines. `HSYNC*` is low from count 67 (pixel
536) to count 15 of the *next* line (pixel 120): **288 pixels, 18.4 us,
overlapping the first 120 active pixels.** That is not a blanking gate; it
is the horizontal drive waveform the analogue board wants, and the
display's left edge is set by the deflection, not by this signal. The
timing measured by simulating the named equations pixel by pixel:

| | measured | *Guide* 12 |
|---|---|---|
| pixels per line | 704 | 704 (512 + 192) |
| bytes fetched per active line | 64 | 512 pixels |
| `HSYNC*` low | 288 px from pixel ~~536~~ 535 (numbering fixed in 2.12) | not given |

**Vertical timing - UG6 with the UF8 counter.** UG6's internal Q1-Q3 form a
mod-8 pixel phase; `VIDTIME` is *vertical-active AND phase 2* - one pulse
per byte during active lines, which is what drives `SC` and `C2M`'s
resynchronisation. Q4 is the vertical-active flag, set and cleared by
decodes of the line-pair count `VADR`. `VIDOUT` is `SERVID` registered
(one clock late). Measured:

| | measured | *Guide* 12 |
|---|---|---|
| active lines | 342 (~~line pairs 1-171~~ lines 1-342 on 2.12's numbering) | 342 |
| `VSYNC*` | low 4 lines, from line ~~344~~ 343 (2.12) | not given |
| **lines per frame** | **372** (`LCTRRST` at pair 186) | **370** |
| frame rate | 59.82 Hz | 60.15 Hz |

**The 372-versus-370 discrepancy is a new open item, and it matters.**
Either Bolle's rewrite differs from Apple's PAL by one line pair - invisible
on a CRT, which is all he needed - or the *Guide* reused the Plus's 370 for
the SE/30, or the reading here is off by a pair (it was checked: 342 active
lines and `VSYNC*` at 344 both come out right, which they would not if the
pair mechanism were misread). The only Apple fuse map of a vertical PAL,
bitsavers' `3410635A`, is a bad dump (1.6). **Resolution needs either a
good dump of Apple's UG6 (`341-0747-A` or `341-0635-A`) or a measurement on
a real SE/30. Until then the core is built to the *Guide*'s 370 and this
note is the record of the doubt.**

*Provenance, checked 2026-09-25 - it sharpens the question without closing
it:*

- **bitsavers' four fuse maps are Al Kossow's**, from "an SE/30 with
  unprotected PALs" (68kmla thread 45231, Aug 2023) - the earlier board.
  In that thread Bolle confirms "the UG6 dump is broken" and describes his
  own set as "the equations I worked out for the newer revision PAL set".
  His README: "reverse-engineered and equations were rewritten to match the
  behaviour of the originals - the provided JEDEC files are not dumps".
  So the later board's parts were not readable, and **his 372 comes from
  observing a working chip**, by a method he does not state. It is not
  copied from the *Guide* - that would have given 370 - but it is not a
  fuse map either.
- **Where an Apple fuse map can be set beside him, his counts agree.**
  Apple's earlier-board UG7 (`3410633A`, a good dump) clears the horizontal
  counter at count 88 = 704 pixels, exactly as his later-board UG7 does,
  with quite different equations; his UI6 is bit-identical to Apple's
  (1.6). The horizontal count survives the respin and the rewrite; that is
  the pattern the vertical count would be expected to follow.
- The bad `3410635A` is unusable for this specifically: `LCTRRST := gnd`,
  five distinct rows in sixty-four.
- **Community figures are not measurements.** The RGBtoHDMI SE/30 profile
  (Mu0n, tinkerdifferent, Sept 2023) carries 370 lines, but its author does
  not say it was measured and RGBtoHDMI locks to sync whatever the number.
  Trammell Hudson's scope figures - 60.10 Hz, 16.64 ms, `VSYNC` 180 us low
  - are from a Mac SE, not an SE/30; the 180 us is four lines, which
  matches the four-line `VSYNC*` read here.

*The decode itself, so the arithmetic can be re-checked without the
tools.* Bolle's UG6 has `LCTRRST := VADR1 * VADR3 * VADR4 * VADR5 * VADR7`
(qualified by the mod-8 pixel phase). Bits 7, 5, 4, 3 and 1 are 128 + 32 +
16 + 8 + 2 = **186**; `VADR0` and `VADR2` are don't-cares in that term and
`VADR6` is not wired to the chip at all (`UG6.pins`), so 186 is the first
count the term is true at, and the LS393's asynchronous CLR fires within a
byte of the counter reaching it. The counter therefore lives through pairs
0 to 185 = **372 lines**. The same reading gives `VSYNC*` set at
`/VADR1 * VADR2 * VADR3 * /VADR4 * VADR5 * VADR7` = 172, line 344, held for
two pairs = four lines. An off-by-one-pair misreading would need a bit of
the product term to be misread, and the two decodes were checked against
each other; 342 active is the *Guide*'s number and a four-line `VSYNC` is
what Trammell measured on his SE. A 370-line frame would need
`LCTRRST` at 185 = `VADR7 * VADR5 * VADR4 * VADR3 * VADR0`, a different
term.

*What the number affects (2.7).* Almost nothing a program can see. The VBL
the System runs on - Ticks, `Delay`, cursor, ordinary VBL tasks - is VIA2
T1 toggling PB7 into VIA1 CA1 at a rate the ROM programs, "not synchronous
with the blanking of the screen" (*Guide* 12); the time of day comes from
the RTC's one-second interrupt. Neither moves with the line count. The
real retrace reaches software only as the slot-`$E` interrupt (VIA1 PB6
enable), so the sole observable is the rate of slot VBL tasks installed on
the internal video: 59.82 Hz against 60.15 Hz, one frame in ~185. No
register exposes the counters; sound is on its own clock and the *line*
rate is the same in both cases. No program is known to depend on the exact
count; the only conceivable one is a diagnostic counting retraces against
Ticks or the RTC, and 0.5% is inside any sane tolerance. So the cost of
being wrong is half a percent on one interrupt rate, and the cost of the
core's video output being 59.82 Hz or 60.15 Hz is nil either way (the Plus
core already runs 60.15 Hz into the same scaler).

*Why 370 is the default (decided 2026-09-25, Daniel: leave open, build to
the* Guide*).* Evidence tier, not likelihood
([[feedback-se30-specs-from-documentation]],
[[feedback-replicate-bugs-else-spec]]). The *Guide* is Apple's
documentation of the hardware; Bolle's PAL is a third party's behavioural
rewrite of a chip he could not read, by an unstated method, and not a fuse
map. As of this date the likelihood favours 372 - his 372 must come from a
real later-board chip and his other counts agree with Apple's maps - but
that does not change the tier. Switching to 372 on this evidence is a
decision to reweigh the tiers, and it is Daniel's, not the plan's.

*What closes it.* Any one of:

1. Bolle's account of how UG6 was derived (68kmla, or an issue on
   `TheRealBolle/SE30`). If it was a truth-table or logic-analyser capture
   of `LCTRRST` against the counter, that is a measurement of the later
   board and closes it as 372.
2. A good fuse map of Apple's UG6 - `341-0747-A` (later board) or
   `341-0635-A` (earlier board, bitsavers' copy being bad).
3. A counter or scope on `VSYNC*` of an SE/30 running Apple's PALs.
   `VSYNC*` is on the internal video connector to the analogue board (the
   pins Trammell Hudson tapped on his SE). 16.62 ms / 60.15 Hz is 370;
   16.71 ms / 59.82 Hz is 372. A second, easier reading on the same
   probe: the gap from `VSYNC*`'s falling edge to the first line of video.
   In this reading (2.12's numbering) active video ends at line 342, `VSYNC*` falls at 343
   and the next frame's video starts at line 373, so the whole 30-line
   blanking sits after the `VSYNC*` edge: **1.35 ms means 372, 1.26 ms
   (28 lines - Trammell's SE figure exactly) means 370.** Take the period
   as well, since the gap alone assumes the trailing gap is zero. Record
   the board number and the UG6 part number with the reading: **the two board revisions carry different UG6
   parts and are not known to agree with each other**, so a reading from
   one does not automatically speak for the other. A measurement on a
   Bolle board only re-reads Bolle's PAL.

When it closes, the changes are: the constant in the vertical timing
generator (2.8 item 5), its bench's expected frame count, and the table
above.

**Slot-E access - UE7 with UE6.** UE7 is a five-bit registered state
machine (`VIDS0-4`) on the pixel clock, with two more registered outputs,
`VR*` and `VID/V`. It is entered from GLUE's `NUBUS*` qualified by
`SLTE/F` (A31-A25 all ones) and `A24` = 0 - i.e. a CPU cycle into slot
`$E` - and it sequences that cycle around the display's own use of the
VRAMs, taking `HSYNC*` and `VIDTIME` as its phase references. UE6 turns the
state into strobes: `VIDROM*` = access AND `A16` (the declaration ROM is
the `A16 = 1` half of every 128KB of the slot, so it appears at
`$FEFF0000`-`$FEFFFFFF` as the *Guide* shows, and at every other
`A16 = 1` mirror); `VIDW*` = write AND `A16 = 0` AND the muxes pointed at
the CPU; `DOE*` = read AND `A16 = 0` at the right state; `VC*` (the VRAM
CAS) and `VIDMUX*` (address mux select) per state; and `DSACK0*`, driven
**only while an access is in progress** (its output enable is an internal
"access active" term) and asserted at a fixed state - the "special
`/DSACK0`" of Figure 3-6 for the video, done in a PAL rather than in GLUE.
~~The exact cycle count from `AS*` to `DSACK0*` is not extracted here; it
will be, by simulation, when the video RTL is written, and it is what
determines VRAM access speed.~~ Extracted in 2.12 by running the
equations: 5, 6 or 7 clocks, up to 27 across the once-per-line row
transfer.

**UI6 - CPU-side glue, four functions.**

1. `AS*` = `LAS*` gated by FC != 7 - the FC=7 rule (1.4, 2.7).
2. `C16M` = `C16G` re-registered on `C32M`: the phase-aligned 16 MHz for
   the CPU sheet.
3. `IRQ6*` = **`VSYNC*` latched while `VSYNCEN*` is low, released when
   `VSYNCEN*` goes high.** So the slot-`$E` interrupt is level-held until
   software deasserts `vSyncEnA` (VIA1 PB6) - the driver acknowledges the
   VBL by toggling that bit. The core must model the latch, or the
   interrupt will either be missed or never clear.
4. **`BERR*` is a bus-cycle timeout clocked by `HSYNC*`.** Two internal
   flip-flops watch `HSYNC*` while `LAS*` is asserted; `BERR*` is driven
   low once the cycle has seen `HSYNC*` high, then low, then high again -
   ~~between one and two line times, ~45-90 us~~ **between 18.4 and 63.3
   us after `AS*`, with no acknowledge (re-timed in 2.11.4: the first
   phase may already be satisfied when the cycle starts).**
   This is what turns "no DSACK" in Figure 3-6 into a bus error, for slot
   space and the PDS as well as for GLUE's own undecoded ranges (GLUE's
   `BERRN` is a second source on the same net).

**UH7 - RAM write strobes and the clock buffer.** `RCMUX*` = `/RCMUX`
(the 74F258 select), `WR` = `/WR*`, `C32M` = `/C32G` (the oscillator
buffered into GLUE), and two per-bank write strobes: `RAMRWA` asserts when
`RASA` is active and `CASLL` low and the cycle is a write, and holds itself
until `RASA` releases; `RAMRWB` the same for bank B. DRAM early-write
semantics, one strobe per bank.

---

## 2.10 The declaration ROM, read

Done 2026-09-26 (2.8 item 3). The image is
`C:\temp\Mac\ROMS\MacSE30\se30vrom.uk6`, 8,192 bytes, CRC32 `b74c3463` -
the same image MAME's `macse30` set loads. `scripts/se30_declrom.py` reads
it as the Slot Manager would (format block, directory, every sResource,
VPBlock, driver header) and disassembles the code with capstone, stepping
over the A-line traps capstone cannot decode. Everything below is read from
Apple's own code in that image, which puts it in the documentation tier
([[feedback-se30-specs-from-documentation]]): this is what the System runs.

**It is intact, and it is Apple part 341-0650.** The format block sits in
the last 20 bytes: test pattern `$5A932BC7` present, length 8192, revision
1, format 1, and the ROM's own CRC recomputes correctly, so the dump is
byte-exact. `ByteLanes = $0F` - all four lanes - so the chip's bytes are
consecutive bus bytes and every offset in the ROM is a chip offset; that is
the 8-bit `DSACK0*` port with the CPU's dynamic bus sizing doing the
lane work (2.6). Vendor info: "Apple Computer", revision "MacSE/30-1.0",
part number **341-0650**. Board name "Macintosh SE/30 Internal Video",
Board ID `$000C`. A credits block names the video software as David Fung's
and the hardware as Jim Stockdale's.

**The sResources.**

| id | what | contents |
|---|---|---|
| `$01` | board | `sRsrcType` catBoard; **PrimaryInit** (sExecBlock, 68020 code, 136 bytes); VendorInfo. No PRAMInitData, no TimeOutConst |
| `$80` | video | `sRsrcType` Category 3 display, cType 1 video, **DrSW 1 Apple, DrHW 9**; name `Display_Video_Apple_MacSE/30 Video`; `sRsrcHWDevId` 1; **`MinorBaseOS $00000000`, `MinorLength $0000D5C0`**; driver for `sMacOS68020`, 1,204 bytes, `.Display_Video_Apple_MacSE/30 Video`, `drvrFlags $4C00`; **one mode, `$80`**: VPBlock `vpBaseOffset $8040`, `vpRowBytes 64`, bounds (0,0,342,512), 72 dpi both ways, `vpPixelSize 1`, `vpCmpCount 1`; **`mPageCnt 2`**; `mDevType 1` |
| `$A0` | second driver | same type words but **DrSW 3**; a 116-byte `sMacOS68030` code block that takes a function code on the stack and hits VIA1 at the absolute 24-bit address `$50F00000` |

**PrimaryInit's first act is to delete `$A0`**: `_SlotManager` selector
`$31` (sDeleteSRTRec) with `spID = $A0` on its own slot, so under Mac OS
that sResource is gone from the slot resource table before the System can
see a second display. (DrSW 3 is `drSwMacsBug` in Apple's ROMDefs as I
remember it - MacsBug's own console driver - but verify the name before
relying on it; the code's four functions do the same VIA1 bit operations
as the main driver, at the 24-bit VIA address.) `$D5C0` = `$8040` + 342 x
64: `MinorLength` covers exactly the two pages, and the 64KB of VRAM above
it is not declared.

**What PrimaryInit does at boot, before the System exists.** Through the
low-memory VIA pointer (`$1D4`): DDRA bit 6 output, DDRB bit 6 output,
ORA bit 6 = 1, ORB bit 6 = 1. Then it fills page 0 at **`$FEE08040`** and
page 1 at **`$FEE00040`**, 342 rows of 16 longwords each, rows alternating
`$AAAAAAAA` and `$55555555`: the 50% grey of the boot screen, both pages.
That is 10,944 `move.l`s into an 8-bit port, 43,776 byte cycles through
UE7's state machine, and it is the first thing the core's video path will
be asked to do - the bench for 2.8 item 5 should time it.

**The driver's whole hardware contract.** These are the only things the
code touches; there are no other video registers.

| what | where | how |
|---|---|---|
| retrace interrupt enable | **VIA1 PB6** (`vSyncEnA`), ORB via `VIA+0`, DDRB6 forced output | **0 = enabled**: Open and SetInterrupt(enable), after `_SIntInstall` (sqType 6, on `dCtlSlot`). **1 = disabled**: PrimaryInit, Close and SetInterrupt(disable), before `_SIntRemove` |
| retrace interrupt acknowledge | the same bit | the slot ISR does `bset #6` then `bclr #6` on ORB - disable, re-enable - then jumps through `JVBLTask` (`$D28`) with the slot number in D0 (derived from `dCtlDevBase` by `rol.l #8; and #$F` = `$E`) and returns 1 |
| page select | **VIA1 PA6**, ORA via `VIA+$1E00`, DDRA6 forced output | **1 = page 0 at slot offset `$8040`; 0 = page 1 at `$0040`** (SetPage, from Reset and SetMode; GetBaseAddr reports the same two addresses) |
| frame buffer | `$FEE08040` / `$FEE00040`, 342 rows x 64 bytes | GrayPage and Reset fill it; **ScrnBase is reported as `$FEE08040`** |
| everything else | Slot Manager, Memory Manager, `_GetCTSeed` | GetEntries returns a fixed two-entry black-and-white table; SetEntries, SetGamma and SetGray return `ctlErr` (no CLUT); GetPages 2; GetMode `$80`; GetInterrupt reports the stored flag. Control 1 (KillIO) is a no-op |

**What this settles for the core.**

1. **The interrupt latch is confirmed from both ends.** UI6's equation
   (2.9 item 3) holds `IRQ6*` while `VSYNCEN*` is low and releases it when
   `VSYNCEN*` goes high; the driver's ISR is exactly that disable-enable
   pulse. So: `IRQ6*` sets on `VSYNC*` while PB6 = 0, clears when PB6 goes
   to 1, and re-enabling must not re-fire until the next `VSYNC*`.
2. **The System's screen address is `$FEE08040`, not `$FE008040`.**
   `$FEE08040` is the 24-bit slot window `$E08040` written as a 32-bit
   address, and the driver uses it in both modes. 2.6's decode - video
   selected by A31-A25 all ones, A24 = 0, then A16 alone splitting VRAM
   from ROM, everything between ignored - makes `$FEE0xxxx` and
   `$FE00xxxx` the same VRAM, which is what MAME's `$FE000000` placement
   relies on too. The core must decode it that way; a decoder that
   demanded A23-A17 = 0 would boot to a grey screen the System could not
   draw on.
3. **The first visible byte of each page is offset `$40`, one 64-byte row
   in.** So the display's first active line reads VRAM row 1, not row 0,
   and PA6 = 1 selects the *upper* 32KB - PA6 is VRAM A15 uninverted.
   Both are constraints on how the 74F253 address muxes are wired (sheet
   5) and both are bench oracles for 2.8 item 5: write rows 0 and 1
   differently and see which one the scan shows.
4. **Nothing else is programmable.** No mode register, no CLUT, no
   timing register: the PALs are the whole video controller, and the
   *Guide*'s "no CLUT" (2.6) is now read from the driver that would have
   used one.
5. **The floppy dialogs depend on this ROM too.** Open stores a pointer
   to a 32 x 32 icon with mask - the compact Mac with an arrow to a
   floppy, the "where is the disk?" picture - into `SonyVars + $130`
   unless bit 9 of `HWCfgFlags` is set. Not video, but a reason the core
   cannot leave the declaration ROM out and still look right.

The declaration ROM itself is read at the top of slot `$E`'s standard
space: the Slot Manager walks down from `$FEFFFFFF`, and with the ROM's
A0-A12 on the bus and A16 = 1 selecting it, the 8KB appears at
`$FEFFE000`-`$FEFFFFFF` and at every 8KB mirror below within the A16 = 1
half - MAME's `$FEFFE000` is the top one.

## 2.11 The GLUE specification: a table of cycles

Done 2026-09-26 (2.8 item 4). This is the contract the GLUE RTL and 1.10's
benches are both written to. GLUE has no internal documentation (2.3), so
every number here is either (a) Apple's, from the *Guide* - the wait-state
text under Figure 3-6 (p. 133-134), the GLUE function list (p. 112-113),
the SCSI handshaking section (ch. 11, p. 393), the RAM access rate (ch. 5),
the PDS tables (ch. 14, Tables 14-5 to 14-7); (b) Motorola's, from the
MC68030 UM 3ed, section 7 (bus operation: Table 7-1, 7.3.1, 7.3.3, Table
7-8) and 5.7 (cache inhibit); (c) the schematic's, from the redraw's
netlist checked against the scan (2.1); (d) the ROM's own tables; or (e) a
timing read from Bolle's UI6 (2.9, behaviour only). Where a number is not
in any of those it is marked **open** and given an envelope the bench can
hold the RTL to, rather than a value invented to fill the cell.

### 2.11.1 The bus, as the 68030 defines it

The clock is `C16M`, 15.6672 MHz, **63.83 ns per clock**. Every cycle on
this board is an *asynchronous* 68030 cycle terminated by `DSACK`: `STERM*`
and `CBACK*` are pulled up (RP8, sheet 8) and reach only the PDS (Table
14-5), so nothing on the logic board ever terminates a cycle synchronously
or bursts. The UM's rules that the contract rests on (7.3.1, Table 7-1,
Table 7-8):

- A cycle is states S0-S5, **three clocks with no wait state**. `AS*` and
  `DS*` assert in S1. `DSACK` must be recognised by the falling edge that
  ends S2 (setup #47A) for the cycle to finish at S5; otherwise the
  processor inserts wait states, sampling `DSACK` on every falling edge.
  **One wait state is one clock**: a one-wait-state cycle is four clocks
  (255.3 ns), two wait states five (319.2 ns).
- Read data is latched at the end of S4; on a write the processor holds
  data through S5. The device must negate `DSACK` and release data within
  about one clock of `AS*`/`DS*` negating, or the next cycle terminates
  early.
- `DSACK1 DSACK0` = `H L` says **8-bit port, data on D31-D24**; `L L` says
  32-bit. The processor breaks a longword to an 8-bit port into four
  cycles itself (dynamic bus sizing, 7.2.1); the device never sees the
  operand size. Every I/O device on the board is on `D(31:24)` (netlist:
  both VIAs, the SCC, the 53C80, the SWIM, the VRAM port and the
  declaration ROM) and gets `DSACK0*` only; RAM, ROM and the FPU are
  32-bit and get both.
- `BERR*` asserted instead of, with, or after `DSACK` (and `HALT*`
  negated) terminates the cycle with a bus error exception (Table 7-8
  cases 3-4). `HALT*` is pulled up and reaches only the PDS, so the board
  never retries a cycle.
- A read-modify-write (TAS, CAS, and **every MMU table-search access**,
  7.3.3) is two ordinary `AS*` cycles with `RMC*` held between them
  (Figure 7-30: `AS*` negates between the read and the write). `RMC*` is
  pulled up and goes only to the PDS; GLUE does not see it and needs no
  special case.
- `CIIN*` is pulled up (RP8) and goes nowhere else - not to GLUE, not to
  the PDS (it is absent from Table 14-5, which lists `/CIOUT`, `/CBREQ`,
  `/CBACK` and `/STERM`). **The SE/30 never inhibits caching in hardware.**
  What keeps VIA, SCSI and SCC reads out of the data cache is the ROM's
  PMMU tables (1.11, re-read for this): the 32-bit table sets `CI` on
  every 256MB from `$50000000` up, the 24-bit table sets it on `$F00000`
  (I/O) and on `$900000`-`$E00000` (the slots, including the video), and
  RAM and ROM are cacheable in both. **For the core:** the CPU's cache
  must honour the descriptor `CI` bit (the 68030 does this internally;
  `CIOUT*` is its report of it), and nothing in GLUE drives `CIIN`.
  A core whose cache ignored `CI` would cache VIA reads and hang the ADB
  and RTC polling loops.
- Interrupt acknowledge: `AVEC` is grounded (sheet 1), and UI6 suppresses
  `AS*` for FC=7 (2.9), so the acknowledge cycle autovectors at its
  earliest and no device sees it (2.7).

### 2.11.2 The address decode

What GLUE can see (2.3, pin list): `A31-A24`, `A22`, `A20`, `A17-A13`,
`A1-A0`, `FC2-FC0`, `SIZ1-SIZ0`, `R/W`, `AS*`, `DS*`, `OVERLAY`,
`RAMSIZ1-0`. Not `A23`, `A21`, `A19`, `A18`, nor anything from `A12` down
to `A2`. Two consequences fall straight out of that list:

- **The RAM bank boundary.** *Guide* Table 4-10 puts the boundary between
  bank A and bank B at the size of bank A: 1MB, 4MB, 16MB or 64MB for
  `RAMSIZ` = 00, 01, 10, 11 (256 Kbit, 1 Mbit, 4 Mbit, 16 Mbit ICs, four
  SIMMs of eight per bank). Those four boundaries are address bits `A20`,
  `A22`, `A24`, `A26` - exactly the even bits GLUE has and the odd ones
  (`A21`, `A23`) it lacks. The ROM's own size table (1.11: `01 02 04 05
  08 10 11 14 20 40 41 44 50 80` MB) is every sum of two banks drawn from
  {0, 1, 4, 16, 64} MB, which confirms the bank sizes. (MAME's
  `via2_out_a` places bank B at 1, 2, 8 and 32 MB; that disagrees with
  both the *Guide* and the ROM's table and is not used.)
- **The I/O decode is on `A17-A13`** and cannot distinguish anything
  finer than `$2000`; the devices use the low bits themselves (VIAs
  `RS3-0` = `A12-A9`; SWIM `A3-A0` = `A12-A9`; SCC `D/C`, `A/B` = `A2`,
  `A1`; 53C80 `A2-A0` = `A6-A4`). Within `$50000000-$50FFFFFF` the bits
  `A23`, `A21`, `A19`, `A18` are physically ignored, so the 128KB device
  block repeats at least 16 times in the 16MB. **Whether `A22` and `A20`
  take part is open**, but they cannot be required to be zero: the
  24-bit map needs `$50F0xxxx`-`$50F1xxxx` (`A23-A20` = 1111) to decode,
  and the 32-bit map needs `$5000xxxx`-`$5001xxxx` (all zero). The
  figure's "presently wraps eight times" cannot be reproduced from the
  pins either way. **Rule for the RTL:** decode I/O on `A31-A24` = `$50`
  and `A17-A13`, ignoring `A23-A18`. It serves every address the ROM
  uses - the `$50xxxxxx` constants in the ROM (start-up code and machine
  tables, ROM offsets `$00BC`-`$07B6`, plus a few register offsets in the
  drivers) are `$50F00000`, `$50F02000`, `$50F04000`, `$50F06000`,
  `$50F08000`, `$50F10000`, `$50F12000`, `$50F14000`, `$50F16000`,
  `$50F18000`, `$50F1C000` and offsets inside those windows, nothing
  outside them - and it is the most permissive rule the pins allow. Residual risk: the real GLUE may bus-error some mirror
  this rule accepts; no software is known to depend on that.

The regions, in the order the CPU's address bits select them
(*Guide* Figure 3-6 and Table 3-8; 2.2):

| region | select | condition |
|---|---|---|
| RAM | `RASA`/`RASB`, `CASxx`, `RCMUX` | `A31-A30` = 00 and `OVERLAY` = 0. Bank A below the `RAMSIZ` boundary, bank B above it; bits above the two banks are ignored ("contents repeat through the unused space", *Guide* ch. 5) |
| ROM | `ROMN` | `A31-A28` = `$4`, or `A31-A30` = 00 with `OVERLAY` = 1 ("the RAM cannot be addressed at all" under overlay, *Guide* ch. 3). The 256KB image repeats through the whole `$4` space: GLUE has no `A18`, `A19`, `A21`, `A23` and the ROM sees `A17-A2` |
| I/O | one of the selects below | `A31-A24` = `$50`, then `A17-A13` |
| FPU | `FPUN` | FC = 7 and `A17` = 1, `A16` = 0, `A15-A13` = 001 (CPU-space type `0010` on `A19-A16` is coprocessor communication, UM 7.4; the *Guide* says "A19-A16 plus the function codes, and the coprocessor ID on A15-A13"; GLUE lacks `A19-A18`, so it can only test `A17-A16`, which still separates it from the interrupt acknowledge's `1111` and the breakpoint's `0000`) |
| slot space | `NUBUSN` | `A31-A29` >= 011, i.e. `$60000000`-`$FFFFFFFF` (Table 14-7: "indicates address in the memory range $60000000 to $FFFFFFFF ... active when the CPU addresses the built-in video display"). GLUE gives no `DSACK` here; the video PALs or a PDS card do |
| everything else | nothing | `$51000000-$5FFFFFFF` and `$50008000-$5000FFFF`: no select, no `DSACK` |

### 2.11.3 The cycles

Clocks are `C16M` periods from S0 of the cycle, assuming the device's own
timing fits the wait states Apple states, which it must since Apple chose
them. "Envelope" means the bench asserts the cycle ends inside the range
and the exact value is open.

| # | region | select | width | DSACK | wait states | clocks | source |
|---|---|---|---|---|---|---|---|
| 1 | RAM read/write | `RASx`, `CASLL/LM/UM/UU` per byte lane, `RCMUX` | 32 | both, GLUE | **1** | **4** | *Guide* p. 134 note: "each access of RAM or ROM involves one wait state ... in contrast to the Macintosh II, in which there are two". Cross-check: the *Guide*'s "average RAM access rate" figures are 15.67 MB/s for the SE/30 and 12.53 MB/s for the II, which are exactly 4 bytes every 4 and every 5 clocks at 15.6672 MHz |
| 2 | ROM read | `ROMN` | 32 | both, GLUE | 1 | 4 | same note. Writes: no source says; treat as a normal cycle with `DSACK` and no effect, which is what a ROM does |
| 3 | VIA1 `$50000000`, VIA2 `$50002000` | `VIA1CSN`, `VIA2CSN` | 8 | `DSACK0*`, GLUE, **E-synchronous** | variable | **envelope 12-32** | Figure 3-6 "special"; "the VIAs are MC6800-compatible peripheral devices that require synchronous communication with the MC68030". Detail below |
| 4 | SCC `$50004000` | `SCCENN` + `SCCRDN`/`SCCWRN` from `R/W` | 8 | `DSACK0*`, GLUE | **open** (>= 1) | >= 4, **plus the hold-off** | Figure 3-6 "special"; "the SCC requires 2.2 us between accesses for its internal lines to stabilize; in the case of back-to-back accesses to the SCC, the GLUE holds off the second access for that amount of time". 2.2 us = **34.5 clocks** from the end of the previous SCC cycle to the start of the next select |
| 5 | SCSI handshake `$50006000` | `SCSIDACKN` | 8 | `DSACK0*`, GLUE, **held until `SCSIDRQ`** | until DRQ | until DRQ, else `BERR` | Figure 3-6 "special"; *Guide* ch. 11: the general logic "does not complete each byte transfer until the SCSI controller's DRQ line goes high", and "if the read or write operation over the SCSI bus is not completed within certain time (different for different machines), the general logic IC asserts a bus error". The time is not given for the SE/30: **open**, bounded by 2.11.4 |
| 6 | expansion `$50008000-$5000FFFF` | none | - | **none** | - | timeout -> `BERR` | Figure 3-6 "Expansion address space (No DSACKx)" |
| 7 | SCSI `$50010000` | `SCSIN` + `IORN`/`IOWN` | 8 | `DSACK0*`, GLUE | 1 | 4 | Figure 3-6; "one wait state for SWIM accesses and for SCSI accesses that do not involve hardware handshaking" |
| 8 | SCSI pseudo-DMA `$50012000` | `SCSIDACKN` + `IORN`/`IOWN` | 8 | `DSACK0*`, GLUE | 1 | 4 | Figure 3-6 "SCSI (pseudo-DMA)", one wait state: the 53C80's DMA data path (`/DACK` instead of `/CS`) without the DRQ wait |
| 9 | ASC `$50014000` | `SNDN` | 8 | `DSACK0*`, GLUE | **2 read, 1 write** | **5 read, 4 write** | Figure 3-6; "two wait states for reads from the ASC and one for writes" |
| 10 | SWIM `$50016000` | `IWMN` | 8 | `DSACK0*`, GLUE | 1 | 4 | Figure 3-6 |
| 11 | expansion `$50018000-$5001FFFF` | none on the board | - | `DSACK0*`, GLUE | 1 | 4 | Figure 3-6 "Expansion address space (One wait state)" - GLUE acknowledges an 8-bit port that is not there; reads return the floating bus |
| 12 | `$50020000-$50FFFFFF` | as 3-11 | | | | | mirrors, per 2.11.2 |
| 13 | `$51000000-$5FFFFFFF` | none | - | none | - | timeout -> `BERR` | Figure 3-6 "Undecoded address space (No DSACKx)" |
| 14 | FPU, FC = 7 | `FPUN` | 32 | **both, from the 68882** (its `DSACK0/1` pins are on the bus, sheet 1) | the FPU's | the FPU's | GLUE only decodes; "the FPU communicates directly with the main processor without further intervention of the memory management unit or GLUE IC". UI6 suppresses `AS*` for FC = 7, so GLUE's acknowledge and timeout logic never see the cycle - and neither does the bus-error timeout (2.11.4) |
| 15 | slot `$E` video `$FE000000-$FEFFFFFF` | `NUBUSN`, then UE7/UE6 | 8 | `DSACK0*`, **from UE6**, one clock wide | 2 or 3 isolated, 4 back-to-back, up to 24 during the once-per-line row transfer | **5, 6, 7; up to 27** | **read 2.12** by running the PALs; the fill of 2.10 takes 20.14 ms |
| 16 | PDS pseudo-slots `$F9`-`$FB`, and `$60000000`-`$F8FFFFFF`, `$FC`-`$FD`, `$FF` | `NUBUSN` | card's | card's, or none | card's | timeout -> `BERR` when empty | Figure 3-6, Table 3-9: "an access to any address range to which no device is assigned results in a bus error" |
| 17 | RAM, ROM in any of the above during a refresh | | | | +1 RAM cycle at most | | *Guide* ch. 5: "except for memory refresh, which takes one access cycle every 15.6 us, the main processors in those computers have uninterrupted access to RAM". 15.6 us = **244 clocks**; 256 rows in 4 ms |

**The VIA cycle (row 3).** **Corrected 2026-09-27 by 4.4:** the *Guide*
(p. 149) says the SE/30's GLUE synchronizes the VIA clock to the access,
averaging 0.5 us, with E's *average* frequency 783.36 kHz; the envelope
below is the 68000 machines' scheme and stands only as 4.4's bound.
`E` is 783.36 kHz = `C16M/20`, period 1.2766
us (20 clocks); the *Guide* gives its frequency and nothing about its duty
cycle (**open**; the 68000's E was 6 low : 4 high, and a 10 : 10 split is
the other candidate). A 65C22 is a Phi2 device: `CS`, `RS` and `R/W` must
be valid before the rising edge of `E`, read data is valid a part of a
phase after that edge, and write data is latched at the falling edge. So a
VIA access waits for the next `E`-high phase in which the select can be
presented, and `DSACK0*` is timed so the processor latches read data at,
or just after, the falling edge of `E` that ends that phase. The length of
the cycle therefore depends on where `AS*` fell within the `E` period:
about one `E` phase at best, one full period plus a phase at worst - **12
to 32 clocks** as an envelope. There is no SE/30 source for the exact
state machine. The nearest Apple document is the VIA Cell spec of Nov 1989
(the ASIC re-implementation of the same 6522 contract, "synchronized to
the internal C783K clock in order to make operation identical to the 6523
VIA which is required for some time-critical software"), whose own bus
timing is **CS to DSACK low 590-1870 ns = 9.25 to 29.25 C16M cycles** (its
spec 6). That is the envelope above to within the sync stages; it is
Apple's design of the mechanism, not the SE/30's chip, and is cited as a
cross-check only. The bench holds the RTL inside the envelope and, more
importantly, checks that the VIA's timers count `E` correctly (the
60.15 Hz VBL and the ADB timeouts depend on that, 2.6, 2.7) - which
depends only on `E`'s frequency, not on the access alignment.

**The SCC cycle (row 4).** Two mechanisms: the access itself (an 8530 read
or write strobe of at least one wait state; the *Guide* gives no count -
open, bench to >= 4 clocks) and the **2.2 us recovery**. The recovery is a
timer that starts when an SCC cycle ends and, while running, holds the
next SCC select and its `DSACK0*` off. Only SCC-to-SCC back-to-back
accesses are delayed; a VIA or RAM access in between is not. The SCC's own
PCLK is `C3M`, 3.672 MHz: not an integer division of 15.6672 (the ratio is
exactly **15/64**, or 15/128 of `C32M`), so GLUE makes it as an averaged
clock. **How is open**; the MacLC core's `v8_clocks.sv` makes its 3.672
MHz the same way (a phase accumulator) and is the engineering precedent,
not evidence of GLUE's pattern. `SYNC3M`, the SCC's channel-A `RTxC`, is
`C3M` gated or selected under VIA1 PA3 `vSync` ("1 = synchronous modem
support, channel A", Table 4-5) - the exact function belongs to the SCC
section.

**The SCSI cycles (rows 5, 7, 8).** Three windows, one chip. `$50010000`
is the 53C80's register file through `/CS` with `/IOR`/`/IOW` from `R/W`
and `DS*`. `$50012000` and `$50006000` both assert `/DACK` instead - the
DMA data register - and differ only in that `$50006000` makes GLUE wait
for `DRQ` before `DSACK0*`, with a bus error if `DRQ` never comes, and
`$50012000` does not wait. The *Guide* (ch. 11) describes the CPU doing
longword moves through the 8-bit port, four `DSACK0`-terminated byte
cycles per longword, each held by the handshake, and gives the resulting
rate as about 1.4 MB/s for blind transfers - a figure the bench can
reproduce with a target that raises `DRQ` immediately. `DRQ` also goes to
VIA2 CA2 and `IRQ` to VIA2 CB2 (2.7). MAME maps `$50006000` and
`$50012000` to the same handler; the *Guide* distinguishes them and so
does this table.

### 2.11.4 The bus-error timeout, from UI6

2.9 item 4 read the mechanism; here is its timing, corrected. UI6 (clock
`C32M`) has two internal flip-flops, `nc14` and `nc15`, both cleared while
`LAS*` is negated. While `LAS*` is asserted: the first sets when `HSYNC*`
is **high**; the second sets when the first is set and `HSYNC*` is
**low**; and `BERR*` is driven low when both are set, `HSYNC*` is high
again, and `AS*` (the system strobe, i.e. FC != 7) is asserted. The cycle
must therefore witness `HSYNC*` high, then low, then high - three
successive phases of the horizontal drive, whose period is one line
(44.93 us) with `HSYNC*` low for 288 pixels (18.38 us) and high for 416
(26.55 us) (2.9). Counting from `AS*`:

| `AS*` falls ... | wait for high | wait for low | wait for high | `BERR*` after |
|---|---|---|---|---|
| just before `HSYNC*` falls | 0 | ~0 | 18.38 us | **18.4 us (min)** |
| just after `HSYNC*` rises | 0 | 26.55 | 18.38 | 44.9 us |
| just after `HSYNC*` falls | 18.38 | 26.55 | 18.38 | **63.3 us (max)** |

So **a cycle with no acknowledge is bus-errored between 18.4 and 63.3 us
after `AS*`** - 288 to 992 clocks - not the "one to two line times,
45-90 us" that 2.9 first said; that reading missed that the first phase
can already be satisfied when the cycle begins. The timeout is
phase-locked to the video, so it is not a constant; the bench asserts the
window, not a value. Two corollaries: coprocessor cycles (FC = 7) cannot
time out, because `AS*` is in the enable term; and the video PALs' own
cycles are timed off the same `HSYNC*`, so a slot-`$E` access that UE7
never acknowledges dies inside this window like any other. GLUE's `BERRN`
is a second driver of the same net for "a transfer that fails to complete"
(2.3) - the SCSI handshake timeout of row 5 is the case the *Guide* names.
Its value is **open**; if GLUE is faster than UI6 for some region, the
core's single timeout is the slow one and software sees only a later
exception. The 68030 requires `BERR*` to be negated after `AS*` negates
(Table 7-8 text), which the `AS*` term guarantees.

### 2.11.5 Interrupts

GLUE's encoder (*Guide* Table 3-4, the II's; the SE/30 pin list has every
input it names): `VIAIRQ1N` -> level 1, `VIAIRQ2N` -> 2, `SCCIRQN` -> 4,
`PWRIRQN` -> 6 (pulled up on the SE/30, RP8; "early Macintosh II only"),
`NMIN` -> 7; `IPL2-0N` carry the highest asserted level and nothing else,
all autovectored (2.7). The six `SLTIRQxN` are ORed to `SLTIRQN` = VIA2
`CA1`, and are also readable on VIA2 `PA5-0`; on this board `SLTIRQ6N` is
UI6's latched `VSYNC*` (2.9, 2.10) and `SLTIRQ1-3N` come from the PDS
(Table 14-7). Levels are level-sensitive: the encoder follows its inputs
combinationally, and the sources (VIA `IRQ`, SCC `INT`) hold until
serviced.

### 2.11.6 Reset, overlay and RAM sizing at start-up

`RESET*` is pulled up (RP7) and shared by the CPU, FPU, VIAs, SWIM and
53C80 (the 8530 has no reset pin); its driver is on sheet 7 (the switch)
and in the power section, later. At reset a 65C22's `DDRA` is zero, so
`OVERLAY` (VIA1 PA4) is undriven and must read high for **overlay to be
on** and the reset vector at `$00000000` to come from ROM (2.2); the
*Guide* says only that the ROM "switches ... by setting low the Overlay
signal", and neither `OVERLAY` nor `RAMSIZ` has an external pull-up (sheet 8's
packs RP7-RP9 checked), so the high state is the 65C22's own undriven
port-A level - the mechanism the Plus and SE overlay bits rely on too.
**The core's VIA model must read an undriven port-A output bit as 1.**
The ROM clears PA4 to switch the map. VIA2 PA7-PA6 (`RAMSIZ`) start the
same way, so GLUE starts with 64MB banks until the ROM sizes bank A and
writes the bits; the ROM's sizing probes RAM for aliases, which is where the mirror
rule of 2.11.2 is tested for real - **the ROM reporting the installed
size correctly is the acceptance test for that rule.**

### 2.11.7 What the benches hold the RTL to

From this section, in the order 1.10's benches will want them:

1. Cycle lengths in clocks, per row of the table: RAM 4, ROM 4, ASC 5
   read / 4 write, SWIM 4, SCSI 4, expansion-with-DSACK 4; the VIA
   envelope 12-32 with `E` = `C16M/20` (**7-14 with the mean held, and E
   re-phased, since 4.4**); SCC >= 4 and the 34.5-clock
   hold-off between consecutive SCC cycles only.
2. `DSACK` encoding per row: `DSACK0*` alone for every I/O device, both
   for RAM and ROM, none from GLUE for the FPU, slot space or the
   no-DSACK regions.
3. Data lane: I/O reads and writes on `D(31:24)` only; a longword move to
   a VIA is four cycles.
4. The bus-error window: `BERR*` within 18.4-63.3 us of `AS*` for rows 6,
   13, 16 and for row 5 without `DRQ`; never for FC = 7.
5. SCSI handshake: `DSACK0*` follows `DRQ`; the *Guide*'s ~1.4 MB/s blind
   rate with an instant target.
6. Decode: every address in the ROM's base-address table (2.11.2) reaches
   the device Figure 3-6 puts there, in both the 24-bit and the 32-bit
   map; `$FEE08040` reaches VRAM (2.10).
7. The RAM bank rule: bank B starts at 1, 4, 16 or 64 MB by `RAMSIZ`; the
   ROM's sizing pass reports the configured size.
8. Overlay: with `OVERLAY` high, reads at `$00000000` return ROM and no
   `RAS` is issued; after the ROM clears it, RAM.
9. Refresh: one RAM-cycle stall at most every 244 clocks, never a
   corrupted access.
10. Cache: no cycle asserts `CIIN`; the CPU-side check is that a VIA
    register read is never served from the data cache (a `CI` descriptor
    test, in the PMMU bench of 1.10).

## 2.12 The slot-E access, read by running the PALs

Done 2026-09-26 (2.8 item 6). `scripts/se30_pals/palsim.py` compiles the
equations `jedec_dis.py` recovers from Bolle's UG7, UG6, UE7 and UE6 into
a clock-by-clock simulation - the three registered parts on the pixel
clock with feedback from their own pins, UE6 combinatorial to a fixpoint
in both halves of the clock (its `VIDMUX*` uses `C16M` as a level), the
two LS393 counters on the falling edges of `C2M` and `TWOLINE` with their
asynchronous clears - and drives a 68030-shaped slot cycle into it:
address from S0, `NUBUS*` at the falling edge starting S1, `DSACK0*`
sampled at each following falling edge, negation at the edge starting S5.
It is behaviour read from a rewrite (1.6); the RTL is written to the
numbers, not the equations.

**Numbering, fixed here for everything that follows.** Pixel 0 is the
clock after `HCTRRST` is high; line 0 is the first full line after
`LCTRRST` fires (it is a decode of the pair counter and fires inside a
line). On that convention the run gives: 704 clocks per line; **`HSYNC*`
low 288 clocks from pixel 535**; **lines 1-342 active** (`VIDTIME` pulses
88 times per active line, at pixels 5, 13, ...); **`VSYNC*` low four
lines from line 343**; 372 lines per frame from Bolle's UG6. 2.9's 536,
344 and "lines 2-343" came from an earlier one-off script whose pixel
origin was one later; the structure is identical and the RTL and bench now
use these figures. The 370-versus-372 question is unchanged.

**UE7, as the CPU sees it.** A five-bit machine that idles by alternating
between two states every clock. A request is taken only from one of
them; from there it runs four more states and `DSACK0*` is low during
**one clock, the third after the request was taken**, which the 68030
samples at that clock's falling edge. So:

| access | clocks | wait states |
|---|---|---|
| isolated, request lands on the taking state | **5** | 2 |
| isolated, request lands on the other | **6** | 3 |
| back-to-back (the 68030's next AS* one clock after the last) | **7** | 4 - the machine passes through both idle states before it can take again |
| request during the row transfer (below) | 7 to **27** | up to 24 |

Read and write, VRAM and declaration ROM, active and blank lines: the
same table. Data enable on a read is asserted for the two clocks ending
with the `DSACK0*` clock; the VRAM strobe and the write strobe span three
clocks around it.

**The row transfer.** Once per line, when `HSYNC*` falls, the machine
leaves the idle loop (from the non-taking state, so one clock later on
alternate lines) and runs a fixed **21-clock** sequence - the VRAMs'
serial-register load for the next line, `VID/V` low for 20 of them -
during which requests wait; an access already in flight finishes first
and delays it. On exit a waiting request is taken through one extra
state, so **every request made during the window is acknowledged in the
same clock: pixel 560**, whether it arrived at 535 or at 556. The window
is 21 clocks, odd, which is why the idle alternation's phase flips every
line. It runs in blank lines too.

**What it costs.** Back-to-back writes across active lines average
**7.21 clocks**; PrimaryInit's 43,776-byte grey fill (2.10) takes **20.14
ms**, which is the number 2.11 row 15 needed. The RTL (`rtl/se30_video.v`)
implements this machine state for state, and the bench's test 11 holds
it to the 5/6/7 clocks, the pixel-560 acknowledge, the transfer in a
blank line, and the fill time within 0.3%.

## 2.13 The GLUE RTL: two decisions the bench made, and their conventions

Recorded 2026-09-26, from writing `sim/glue/tb_se30_glue.v` (2.8 item 7).
Neither decision is in 2.11, which is the 68030's view of the board; both
are about the difference between that view and the bus the core's CPU
actually presents.

**RETIRED 2026-09-26 - GLUE is re-cut to 2.11.1 (1.13 item 4).** The
kernel has the 68030's bus (1.15), and `rtl/se30_glue.v` now takes it
verbatim: `AS*`, `DS*`, `SIZ`, `A1A0`, 32-bit data, `DSACK1/0*`; RAM and
ROM are 32-bit ports with Table 7-7's byte enables, one access a cycle,
and every I/O device an 8-bit port on `D31-D24` answering `DSACK0*`
alone, one device cycle per bus cycle - the processor issues the byte
cycles of a word or a longword. The byte sequencer of decision 1, the
2 + 2 beat of decision 2, `lw`, `slot_a0` and `VPA*` are gone; `AVEC` is
grounded on the board, so an interrupt acknowledge gets nothing from
GLUE and the processor autovectors. The decode, every timing, the VIA,
SCC, UI6, refresh and interrupt logic and the bench's cycle counts are
unchanged: `sim/glue/tb_se30_glue.v` passes 91 checks with its bus model
rewritten to the 68030's cycle (`DS*` with `AS*` on a read, a clock
later on a write; write data on the lanes of Table 7-5). The conventions
below that survive are the cycle count, `HSYNC*`, `E`'s duty, the RAM
port's flat address (now a longword address), the SCC hold-off, refresh,
the `A17` = 1 windows and the acknowledge decode. The text below is
kept as the record of the interim RTL (`86169e7`).

**And one clock found, the same day.** The bench's count - "AS* low to
the acknowledge inclusive, plus one for S4/S5" - understated the
68030's cycle by a clock: the processor asserts `AS*` at S1, half a
clock after S0, so GLUE first sees it a full clock in, and a cycle the
bench called 4 was 5 in 68030 states, two wait states, not the Guide's
one. That is the gap 1.7's row said was unmeasured until the CPU and
GLUE met. The bench now counts the cycle as the processor runs it (S0
to S5 in C16M clocks), and GLUE acknowledges a clock earlier: memory on
the port's acknowledge itself, a fixed-latency device from the clock
`AS*` is first seen, and a device's read byte passed through
combinationally for the processor to latch at the end of S4 (a clock
after it takes `DSACK*`), since a registered capture in the
acknowledge clock is what the old count had been paying for. A write's
strobe does not wait for `DS*`: the write data is valid from S2, the
clock GLUE first sees `AS*`. RAM, ROM, SWIM, SCSI, the DMA port and the
expansion window are 4 clocks, the ASC 5/4, as 2.11.3 says; the VIA
envelope, E-bound, reads 12-34 true clocks (it was 11-32 on the old
count); the slot's 5/6/7 of 2.12 were true clocks already. 91 checks.

**1. GLUE is written to the TG68K wrapper's bus, not the 68030's pins.**
The kernel (1.12) has a 16-bit data bus and moves a 32-bit operand as two
16-bit beats; the wrapper (`tg68k.v`, ours) presents a 68000-shaped bus:
`A31-A0`, `D15-D0`, `AS*`, `UDS*`/`LDS*`, `R/W*`, `FC2-0`, `DTACK*`,
`VPA*`, `BERR`, `IPL2-0`, plus one flag, `lw`, that the wrapper raises on
both beats of a longword. There is no `SIZ1-0`, no `DSACK1-0` encoding, no
port-width negotiation. So the 68030's dynamic bus sizing (2.11.1: every
I/O device is an 8-bit port on `D31-D24` and the processor splits a word
or longword into byte cycles itself) has to be done by GLUE, because the
kernel cannot: **for an 8-bit port, GLUE runs one device cycle per byte
of the beat, high byte (`UDS*`, `D15-D8`) first at address A, then the
low byte (`LDS*`) at A+1.** A longword move to a VIA is still four device
cycles (2.11.7 item 3), two per beat. Devices sit on `D15-D8` as they sit
on `D31-D24` in the real machine; on a single-byte beat GLUE returns the
byte on both lanes, so the wrapper finds it on whichever lane its size
and `A0` select. The RAM and ROM ports are 16-bit word ports with byte
enables, one beat per access.

**2. RAM and ROM: a word or byte beat is 4 clocks; the two beats of a
longword total 4.** Row 1's one-wait-state 32-bit access is four clocks
for four bytes, 15.67 MB/s; two 4-clock beats would halve that. So a beat
flagged `lw` acknowledges as soon as the memory does, two clocks, and the
pair costs what the real access costs; a word or byte beat is the same
access padded to the 68030's count. The 2-clock beat requires a memory
port that acknowledges one clock after the request - the guarantee the
donor cores' SDRAM slot scheme gives (`MacPlus.sv`'s `cpuBusControl`, the
`dtack_en` idiom of 1.4) - and the RTL follows the acknowledge rather than
assuming it, so a slower port costs clocks, never data.

**Conventions fixed by the bench**, so they are written down once:

- *Cycle count*: from the first clock in which `AS*` is low to the clock
  in which `DTACK*` is first low, inclusive, plus one for S4/S5. A
  one-wait-state 68030 cycle reads as 4; the shortest possible beat as 2.
  The wrapper latches read data the clock after `DTACK*` and negates
  `AS*` in the same clock; GLUE releases `DTACK*`, `BERR` and `VPA*` with
  `AS*` combinationally (UM Table 7-8: negate within a clock of `AS*`).
- *`HSYNC*`* for the UI6 timeout is the video RTL's own: a 704-clock
  line, low 288 clocks from pixel 535 (2.12).
- *`E`* is `C16M/20` with a **10 : 10 duty cycle assumed** (row 3 leaves
  the duty open; the 68000's was 6 : 4). Only the frequency is
  load-bearing; a VIA access is timed from `E`'s edges either way.
- *RAM port*: a 26-bit flat word address, bank B packed immediately after
  bank A at the `RAMSIZ` boundary (2.11.2) - up to 128MB, which is what
  GLUE decodes, although the ROM can use 8MB (1.5).
- *SCC hold-off*: a timer loaded when an SCC cycle releases its select;
  the next SCC select is held off until it expires, whatever accessed the
  bus in between. Measured strobe-to-previous-select it is 35 clocks
  (2.23 us) against the *Guide*'s 2.2.
- *Refresh*: a pulse every 244 clocks at fixed phase; a RAM request that
  arrives in the four clocks after it waits, so the stall is at most one
  access (row 17). The core's SDRAM does its own refresh; the pulse is
  the pacing GLUE would have imposed.
- *I/O windows with `A17` = 1* (`$50020000`-`$5003FFFF` and mirrors) get
  nothing - a bus error. Figure 3-6 lists only the `A17` = 0 windows and
  the ROM addresses nothing there; **open** whether the real GLUE mirrors
  them.
- *Interrupt acknowledge* is decoded on `A17-A16` = 11 with FC = 7, the
  bits GLUE has (2.11.2); everything else in CPU space gets no answer
  and no timeout (1.4 item 4, 2.11.4).

# Section 3 - The tree: the framework, the clocks, the memory and the top

Opened 2026-09-26, after 1.13 closed (the kernel has the 68030's bus and
GLUE answers it, `sim/system/` green). This is 2.8 item 8's first half -
"cut the MacLC tree" - written down before a file moves
(`plan-doc-before-implementation`). The peripheral sections that follow it
(VIAs, ASC, SWIM, SCC, SCSI, ADB/RTC, power) are still unwritten and
nothing here infers them.

The section's job is narrow: get the CPU, GLUE and video that already pass
their benches onto the DE10-Nano, in the MiSTer framework, with a real
SDRAM behind GLUE's memory ports and the real ROM in it, to the point where
the first instructions fetch. What it settles: where every inherited file
comes from, the clock plan, the SDRAM controller's contract and the memory
map, how the two ROM images arrive, what the top and the machine module
are, and the bring-up ladder.

## 3.1 What the cut is, and where each piece comes from

**"Cut the MacLC tree" does not mean copy `MacLC_MiSTer` and edit it.** The
survey (2026-09-26, this section) found that what the SE/30 can take from
the LC's shell is its *framework* - which is not the LC's at all but the
MiSTer template's - its build flow, and a handful of lessons its top
encodes. The LC's own logic (the V8 decode in `addrController_top.v` /
`dataController_top.sv`, the 16-bit SDRAM controller, the PLL, the Egret,
the 020 wrapper) is either the wrong machine or the wrong bus. The
peripherals the plan expects to lift (`via6522.sv`, `asc.sv`, `swim.v`,
`scc.v`, `scsi.v`/`ncr5380.sv`) are real candidates, but each one is
assessed against its documentation in its own section
(`feedback-se30-specs-from-documentation`) and copied then, byte-exact,
with its source hash recorded there. So the cut is:

| what | from | how |
|---|---|---|
| `sys/` - the MiSTer framework, whole directory | `MiSTer-devel/Template_MiSTer@69b8a2a` (2026-07-16) | byte-exact, line endings as they are. **Never edited** (MacLC's `CLAUDE.md` law, learned there 2026-07-17: a night of framework edits produced STA-met builds with dead video); updated only wholesale from the template, as one revertible commit |
| project files: `MacSE30.qpf`, `MacSE30.qsf`, `MacSE30.sdc`, `MacSE30.srf`, `files.qip`, `clean.bat`, `.gitignore` | the template's `Template.*` at the same commit | renamed and edited: the qsf keeps the template's global settings and `source sys/sys.tcl` (device and pins come from the framework, not inline as MacLC's older qsf carries them); `LAST_QUARTUS_VERSION` is MacLC's "17.0.2 Lite Edition"; the sdc is the template's two lines plus ours (3.2). `jtag.cdf` is Quartus's own and gitignored (`*.cdf`), as in the template |
| `.gitattributes` | MacLC's idea | pins the three project files Quartus rewrites with CRLF on every compile (`.qpf`, `.qsf`, `.sdc`) to `eol=lf`, and nothing else - a broad pattern would renormalise inherited blobs |
| build flow: `scripts/build_only.sh`, `scripts/setup_env.sh`, `scripts/local.env.sample` | `MiSTer-devel/MacLC_MiSTer@045f896` | byte-exact bar the sample's core section (`RBF_NAME`, the seed paths), which is the documented porting edit. `045f896` is the upstream tip and carries Daniel's stabilisation work (checked 2026-09-26: the local clone, `origin` `danielb0/MacLC_MiSTer` and `upstream` `MiSTer-devel/MacLC_MiSTer` are at the same commit) |
| the shell's lessons: hold the machine in reset until `boot0.rom` has been streamed (`rom_loaded`); never feed the CPU's RESET instruction back into the system reset (the ROM executes RESET during boot - an infinite reset loop); release the HPS download on the memory controller's own acknowledge, not on a slot edge | `MacLC.sv` | re-implemented in `MacSE30.sv`, not copied - the LC's shell is 3,010 lines of another machine |

**Not taken, and why.** `rtl/sdram.v` (Harbaum's, with Daniel's demand-start
and download-port work): a 16-bit-data, 24-bit-word-address, one-word-per-
access controller built around a floppy-window slot scheme; the SE/30 needs
a 32-bit port with byte enables and the acknowledge budget of 3.3 - a new
controller, with MacLC's file kept as the reference for the DE10-Nano's
SDRAM and for its read-capture lesson (3.2). `rtl/pll*`: 65/32.5 MHz.
`rtl/tg68k/`: the old pin (1.12). `verilator/`: 1.10. `rtl/egret*`: the
LC's system controller; the SE/30's ADB is the VIA shift register and the
transceiver (`MacPlus_MiSTer/rtl/adb.sv`), later. `rtl/pds/`, `cd_audio.sv`,
the MT32-pi wiring, the HUD: later or never.

**Line endings by provenance** (`scripted-edits-mangle-line-endings`). The
donors are mixed and stay mixed: in the template `Template.sv`,
`Template.qsf`, `files.qip`, `clean.bat`, `sys/sys_top.sdc` and
`sys/sys.tcl` are CRLF while `sys_top.v`, `hps_io.sv`, `ascal.vhd` and
`Template.sdc` are LF; in MacLC `swim.v`, `floppy.v` and `pll.v` are CRLF
and the rest LF. An inherited file keeps what it came with; a file we write
is LF; a file we rename-and-edit from the template (the qsf, `clean.bat`)
keeps the template's endings unless `.gitattributes` says otherwise. The
check is `tr -cd '\r' | wc -c` per file, never `grep -c`.

**Why this template commit and not the tip.** The template's tip on
2026-09-26 is `3ea1134` (2026-08-26); between `69b8a2a` and it the scaler's
output handshake was rewritten twice and partly reverted (`0874acd`,
`54ac838`, `f38ab86`, `baaeff6`). `69b8a2a`'s `sys_top.v` and `ascal.vhd`
are byte-identical to what `MacPlus_MiSTer` runs on Daniel's board today,
so they are proven with his Main. The delta MacPlus and MacLC carry in
`hps_io.sv` is one commit older than `69b8a2a` (`3dcffc4`, the upload fix);
we take the template's. The newer template is a wholesale update to take
later, on its own, when there is a booting machine to A/B it against.

**Attribution.** The core is Daniel's own (the 2026-09-22 decision in the
project note); the README credits the lineage - the MiSTer framework by
Sorgelig, the MacLC and MacPlus cores whose files are lifted (Dani Sarfati,
Sorgelig, the Plus Too project), TG68K (Tobias Gubener) and its 68030 work
(apolkosnik) - and the licence is GPL-2-or-later for the core with the
kernel's LGPL-3 as its headers say (1.12).

## 3.2 Clocks

**One PLL, ours.** The board has one oscillator, `Y2` at 31.3344 MHz
(2.5), and the core's clock is that oscillator: `clk_sys` = **31.3344 MHz**
= 2 x `C16M`, which is what the wrapper already runs on (`tg68k.v`: the
68030's states are half-clocks of `C16M`, marked by `phi1`/`phi2`). GLUE
takes `c16_en = phi1`; the video (2.8 item 5's deferred `cep`) takes the
same enable and becomes a pixel every other clock, so `CLK_VIDEO` =
`clk_sys` and `CE_PIXEL` = `phi1`: 704 x 370 pixels at 15.6672 MHz,
60.15 Hz, the *Guide*'s numbers unchanged. `E`, `C3M` and refresh are
GLUE's divisions of `C16M` as 2.11 has them. Nothing in the machine runs
on any other clock.

**The SDRAM clock is an integer multiple of `clk_sys` from the same PLL**,
so the two are related clocks that STA times exactly, with no multicycle
guesses across them - the lesson MacLC paid for (its `MacLC.sdc` "Phase C"
block: a multicycle credit across the clk_sys -> clk_64 hand-off hid a
6.7 ns violation that corrupted memory and bombed the guest). Which
multiple is set by the RAM cycle's budget:

The contract GLUE holds (2.13's conventions, `sim/system/`): the 68030
puts the address on the bus at S0 and asserts `AS*` at S1, half a clock
later; GLUE sees `AS*` at the next `C16M` edge, one clock after S0, and
requests the memory port; the port acknowledges **with its data one `C16M`
later**, two clocks after S0; GLUE asserts `DSACK*` in that clock and the
processor latches the data at the end of S4 and finishes the cycle at S5 -
four clocks, the *Guide*'s one wait state. So the SDRAM has **127.7 ns
from address-valid at S0 to data at GLUE**, provided it starts at S0. It
cannot start from GLUE's request - that leaves 63.8 ns, which no SDRAM
read fits - so the controller starts speculatively **from the address at
S0**, exactly as the 68030 offers it: `ECS*` (external cycle start, UM
5.6.2 and 7.1.1: "the earliest indication that the processor is
initiating a bus cycle ... ECS can be used to initiate various timing
sequences that are eventually qualified with AS") is a real pin the
wrapper can present, and RAM/ROM is decided by `A31-A28` and `OVERLAY`
(2.11.2), which need no `AS*`. A cycle the processor starts and does not
run (7.1.1: "in the case of an internal cache hit, an ATC miss, or an MMU
fault, a bus cycle may be aborted after ECS has been asserted") costs the
controller an ACTIVE it precharges after `tRAS`, and nothing else.

A 32-bit read on the 16-bit part is ACTIVE, `tRCD` (20 ns), READ with
auto-precharge, CAS latency, two data words (burst length 2), then the
capture register and its retiming stage - the two falling-edge stages
MacLC found necessary to make the read eye fit-invariant (its 2026-09-12
work; the same chips: `AS4C32M16SB-7` on the 64/128 MB modules,
`W9825G6KH-6` on the 32 MB, `tAC` 6.0 ns at CL2, `tOH` 2.5 ns):

| SDRAM clock | period | clocks in 127.7 ns | read: data at GLUE | spare | read eye (`tCK` - `tAC` + `tOH`) |
|---|---|---|---|---|---|
| 2 x = 62.6688 MHz | 15.96 ns | 8 | ACT 0, READ 2, CL2: D0 4, D1 5, capture 5.5/6.5, present 7 - the second word lands at 8-9 | none | 12.5 ns |
| **3 x = 94.0032 MHz** | 10.64 ns | 12 | ACT 0, READ 2, CL3: D0 5, D1 6, capture 6.5/7.5, present 8 | 3-4 | 7.1 ns |
| 4 x = 125.3376 MHz | 7.98 ns | 16 | ACT 0, READ 3, CL3: D0 6, D1 7, capture 7.5/8.5, present 9 | 6 | 4.5 ns |

**Decision: 3 x, 94.0032 MHz, burst 2.** It closes the budget with
margin and keeps a 7 ns read eye; 4 x buys three more clocks at the cost
of a 4.5 ns eye, the fit-sensitive class MacLC fought at 65 MHz with a
15 ns one. Back-to-back 68030 RAM cycles are 24 clocks apart, so a
refresh fits between two of them and the controller's refresh never has
to stall a request - a design goal the bench holds (3.6).

**The datasheets, read 2026-09-26** (Winbond `W9825G6KH` rev. A04, Mar
2017, and Alliance `AS4C32M16SB` rev. 1.4, June 2024, both in
`C:\temp\Mac\SE30\Docs`; the controller is written to the worse of the
two at every row, in clocks of 10.64 ns):

| parameter | W9825G6KH-6 | AS4C32M16SB-7 | design | clocks |
|---|---|---|---|---|
| `tCK` min at CL2 / CL3 | 7.5 / 6 ns | 10 / 7 ns | **CL2 at 10.64 ns is legal for both** | - |
| `tRCD` | 15 ns | 21 ns | 21 | 2 (21.28) |
| `tRP` | 15 ns | 21 ns | 21 | 2 |
| `tRAS` min | 42 ns | 42 ns | 42 | 4 |
| `tRC` (ACTIVE to ACTIVE, same bank) | 60 ns | 63 ns | 63 | 6 |
| `tRFC` (refresh to next command) | `tRC`, 60 ns | 63 ns | 63 | 6 |
| `tMRD` / `tRSC` | 2 `tCK` | 14 ns | 14 | 2 |
| `tWR` | 2 `tCK` | 14 ns | 14 | 2 |
| `tAC` max at CL2 / CL3 | 6 / 5 ns | 6 / 5.4 ns | 6.0 | - |
| `tOH` min | 3 ns | 2.5 ns | 2.5 | - |
| `tDS`, `tAS`, `tCMS` / `tIS` | 1.5 ns | 1.5 ns | 1.5 | - |
| `tDH`, `tAH`, `tCMH` / `tIH` | 0.8 ns | 0.8 ns | 0.8 | - |
| refresh | 8192 cycles / 64 ms | 8192 / 64 ms, `tREFI` 7.8 us | one AUTO REFRESH per 7.8125 us | 734 |
| power-up | 200 us pause, PRECHARGE ALL, MRS, **8** AUTO REFRESH (before or after MRS) | 200 us, PRECHARGE ALL, MRS, **>= 2** AUTO REFRESH | 200 us, PRECHARGE ALL, 8 refreshes, MRS | - |
| organisation | 4 banks x 8192 rows x **512** columns (`A0-A8`) | 4 x 8192 x **1024** (`A0-A9`) | 4 x 8192 x 512, row on `A0-A12`, column on `A0-A8`, `A10` = auto-precharge | 32 MB |
| mode register | `A9` write burst (0 = burst, 1 = single-location writes), `A8-A7` = 00, `A6-A4` CL (010 = 2), `A3` = 0 sequential, `A2-A0` burst length (001 = 2) | the same | `$0221`: CL2, sequential, BL2 reads, single-location writes (3.8 item 19; `$0021` until compile 9) | - |

So the read of 3.2's table runs (as revised after the first compile, 3.8
item 9): the S0 address is sampled at clock 2, ACTIVE at 3, READ at 5;
CL2 makes the first word **valid at** the chip's second edge after the
READ, 7.5, launched from the edge before it, 6.5, and the second word
valid at 8.5 (the AS4C32M16SB datasheet's definition: CAS latency is
"the number of clock cycles from the assertion of the Read command to
the first read data", `tCAC(min) <= CL x tCK`; each subsequent element
"valid by the next positive clock edge") - the chip's edges being the
FPGA's falling edges plus the clock's delay to the pin, 4 ns (the second
compile's STA, below); each word is at the FPGA's pin from 10.5 ns after
its launch edge (skew + `tAC` 6.0 + 0.5 of trace) to 17.1 ns after it
(skew + the period + `tOH` 2.5), a 6.6 ns eye. The words are captured in
the I/O cell on the FPGA's **rising** edges at 8 and 9, 15.96 ns after
their launch edges: 5.4 ns of setup and 1.1 ns of hold inside the eye.
The falling edge a period after the launch (MacLC's choice, and this
plan's until the second compile) is 0.1 ns into the eye - the -2.49 ns
of the second compile. The capture is then taken into the read-data
register a full period later, presented with the acknowledge at 10 - two
clocks before GLUE's sampling edge at 12. **Until the first board
reading (3.8 item 15) this paragraph, the model and the controller had
the launches one clock later, at 7.5 and 8.5 - MacLC's reading of CL2,
inherited with its capture work - and the board showed the chip keeping
to the datasheet.** `SDRAM_CLK` is the inverted `clk_mem` (MacLC's `altddio_out`), so the
chip's rising edges are the FPGA's falling ones; the sdc constraints are
MacLC's 2026-09-12 set with the same chip numbers, plus a two-cycle setup
multicycle on the capture registers that states the rising-edge capture
(and deliberately no hold multicycle: the default hold check that comes
with it is the next word's arrival, the real requirement). The benches
model the 4 ns on the chip's clock; without it the model's eye misses the
capture edge, and the bench's passing window (2.9 to 5.3 ns, the top
being the bench's zero-delay command pins) is written in
`sim/sdram/tb_se30_sdram.v`.
A write issues WRITE at clock 6, once `AS*` has confirmed the cycle (the
request is sampled at 5), with the first word and its `DQM` from
`be[3:2]`, the second word at 7. A read is issued speculatively at 5 - a
RAM read has no side effect and auto-precharge closes the row - which is
what makes the budget close.

**Why the sample is at clock 2, not 1 (the first compile, 2026-09-27).**
The request bundle the controller samples - start, address, R/W, byte
enables, write data - is not a register's output but the kernel's address
adder and the beat engine's byte routing: 12 logic levels, 15.1 ns of
data delay, against the 10.6 ns single-cycle window STA sees between the
two related clocks (-5.7 ns, 29.7 million paths). Sampling on the second
edge gives the cone 21.3 ns, stated to STA as a two-cycle multicycle on
exactly those registers (`xs_*` in `rtl/se30_sdram.v`; `MacSE30.sdc`),
with the hold check on the default edge. The controller's outputs back to
GLUE stay honest single-cycle paths (+2.9 ns). It costs one of the two
clocks in hand, and a request that GLUE's refresh window delays is now
acknowledged one C16M later for a read as for a write (the bench's
late-request rows read 6). Registering the bundle in `clk_sys` first, as
MacLC does, would cost three clocks and miss the cycle; this is the
alternative the related-clock arrangement allows.

**What the bench decided (`sim/sdram/`, 165 checks, 2026-09-26; the
controller is `rtl/se30_sdram.v`, the chip model ours,
`sim/sdram/sdram_model.v`, written from the two datasheets because
Micron's carries no redistribution terms).** Three things the first run
found: (1) the start must act on the clock it is registered, not a clock
later through a pending flag, or the two clocks in hand become one; (2)
after an aborted cycle - a start with no `AS*` - the next cycle's start
must open its row directly from the holding state, or it is acknowledged a
clock late; a write with no request five clocks after its ACTIVE is
treated as aborted and its row precharged (`tRAS` met), and a request that
GLUE's refresh window has delayed then re-opens the row from idle, so a
write in that window costs one C16M more than a read there; (3) refresh
cannot simply go when due, because due can fall in the last clocks before
a back-to-back start: from 6.4 us it takes the idle window right after a
cycle (clocks 10-17 from that cycle's start, where it completes before the
next start needs the chip), from 7.45 us it goes at the first idle clock,
and only at 10.9 us does it outrank a start. Under 100 us of back-to-back
cycles the longest interval was 6.6 us and no cycle waited. The
acknowledge is a level held while the request is up; a read's data waits
in the controller for a late request or is discarded by the next start.

The PLL is written by hand as the MiSTer cores' `pll_0002.v` shape - an
`altera_pll` instance with `fractional_vco_multiplier("true")` and the two
output frequencies as strings; Quartus computes M, N and the counters -
because there is no GUI in the loop and the file is 60 lines. VCO
940.032 MHz (x30 / x10) is inside Cyclone V's 600-1600 MHz range.
`derive_pll_clocks` in the template's sdc picks both clocks up.

**The kernel's timing credit.** MacLC closes its kernel at 32.5 MHz with a
two-period multicycle on kernel-internal paths, on the argument that the
kernel only advances on `clkena` pulses at least two `clk_sys` apart. The
same argument holds here - the wrapper advances the kernel at most once
per `C16M`, two `clk_sys` - and the same caution: MacLC's SDC records four
months of "STA met, hardware corrupt, differs per seed" that turned out to
be a structural combinational loop *in MacLC's own kernel edit*
(`42ae7a6`, the cmp.l fix), invisible to STA under the credit. Our kernel
is upstream's `c3e8a0d` plus 1.15's beat engine; the first compile checks
for Quartus warning 332125/332081 before any credit is applied, and the
credit goes in `MacSE30.sdc` with the argument written next to it.

## 3.3 Memory: the SDRAM controller and the map

**Geometry.** The controller addresses the module as 4 banks x 8192 rows
x 512 columns x 16 bits = 16M words = 32 MB, the subset every MiSTer SDRAM
module (32, 64, 128 MB) presents identically; refresh is one AUTO REFRESH
per 7.8 us (8192 rows in 64 ms). MacLC's controller uses 12 row bits
(16 MB); we use 13 because the SE/30's RAM alone is 8 MB.

**The map, in 16-bit SDRAM words:**

| words | bytes | what |
|---|---|---|
| `$000000-$3FFFFF` | 8 MB | RAM - the stock SE/30's maximum (1.5, `se30-32bit-dirty-rom-8mb`). GLUE's `ram_addr` is a 25-bit longword address over 128 MB (2.13); the controller takes what the installed size needs and the rest is 3.7's open item |
| `$400000-$41FFFF` | 256 KB | ROM, `boot0.rom`, written by the HPS download at core start. GLUE's `rom_addr` is a 16-bit longword address (the image repeats through `$4xxxxxxx`, 2.2) |
| `$420000-$7FFFFF` | | free |
| `$800000-` | 16 MB up | reserved for disk images (the SWIM and SCSI sections) |

The 8 KB declaration ROM is **not** in SDRAM: the video reads it per slot
access at its own pace and it fits in seven M10Ks, so it is a BRAM in the
machine, written by the download of `boot1.rom` (3.4) and read by
`se30_video`, whose internal `$readmemh` array becomes that BRAM with a
write port (the simulation preload stays).

**Ports.** One CPU port, 32-bit with four byte enables, serving GLUE's RAM
and ROM ports through a mux in the machine (a cycle is one or the other):
`start` (the S0 speculative start, from `ECS*` and the RAM/ROM decode),
`req` (GLUE's `ram_req`/`rom_req`, the confirmation), `we`, longword
address, `be[3:0]`, `wdata`, `rdata`, `ack` - **`ack` means "the data is
on `rdata` now"** (a read) or "the write is posted" (a write), and GLUE's
one-clock-after-request contract is what it is held to. One download
port, 16-bit words, the HPS's `ioctl` handshake (request held until the
controller's own acknowledge, MacLC's lesson). The floppy loader and
committer ports come with the SWIM section, on MacLC's pattern (a level
request with values frozen by the requester until the level acknowledge,
never touching the CPU's `ack`). Refresh is the controller's own,
scheduled into the idle clocks between cycles (3.2); GLUE's `ram_refresh`
pulse (row 17) is the pacing the real GLUE imposed and stays what it was
in the bench - a stall window - not a command to the controller. Write
data lanes: word 0 (the lower address) is `D31-D16`, word 1 `D15-D0`;
`be[3:2]` mask word 0's DQM, `be[1:0]` word 1's. Init is JEDEC's: 100 us
of NOPs after the clock starts, PRECHARGE ALL, eight AUTO REFRESH, LOAD
MODE (MacLC's ladder, whose comment records the cold-load flakiness the
short sequence caused).

**The walker.** The PMMU's table-search reads and writes are ordinary bus
cycles of the wrapper (1.4 item 2, `tg68k.v`), so they go through GLUE and
this port like any other and get the same acknowledge-with-data. The
IIvi's special case - a walk read that had to wait for real SDRAM data
because every other access took a fast slot-start acknowledge - does not
arise: nothing here acknowledges before the data.

## 3.4 The ROM images and the download

Two images, neither in the repo (Apple's; `.gitignore` already covers the
simulation copies), supplied by the user in the core's folder as
`boot0.rom` and `boot1.rom`:

| file | what | size | identity |
|---|---|---|---|
| `boot0.rom` | the SE/30 ROM (shared with the II FDHD, IIx, IIcx) | 256 KB | checksum `$97221136` at offset 0 (1.11) |
| `boot1.rom` | the video declaration ROM, Apple 341-0650 | 8 KB | CRC32 `b74c3463` (2.10) |

Main sends `bootN.rom` as one download each, with `ioctl_index = N << 6`
(`user_io.cpp:1638-1642`; MacPlus decodes `dio_index[7:6]` as the slot,
MacLC gates on `dio_index == 0`). So `boot0` arrives with index `$00`,
`boot1` with `$40`. The words come 16-bit, byte 0 in the low half
(`hps_io` `WIDE=1`), so the shell swaps into big-endian words and writes
`boot0` to SDRAM words `$400000 + ioctl_addr[18:1]` and `boot1` to the
declaration BRAM at `ioctl_addr[12:0]`.

**Reset.** The machine is held in reset from configuration until `boot0`
has been seen (`rom_loaded`, MacLC's latch: without it the CPU runs
whatever the previous core left at the ROM window), while any download is
in progress, while the PLL is unlocked, and on the framework's `RESET`,
the OSD reset and the user button. `boot1` is optional to the reset
logic: without it the ROM's slot manager finds no card and the screen
stays dark, but the machine boots - the download of 8 KB ends
milliseconds after `boot0`'s, long before the ROM's slot scan. The CPU's
RESET instruction (`reset_out_n`) resets the peripherals and never the
CPU or the system reset (2.11.6: `RESET*` is shared by the VIAs, SWIM and
53C80; the CPU is its source when it executes RESET).

## 3.5 The top and the machine module

Two modules, on purpose:

- **`MacSE30.sv`, module `emu`** - the framework shell, written from the
  template's `Template.sv`: the PLL, `hps_io`, the reset logic, the two
  downloads and the SDRAM controller (the SDRAM pins are the shell's),
  and the framework outputs. `CONF_STR` starts minimal - the core name,
  aspect ratio, reset, the build date - and grows with the peripheral
  sections (disk images, memory size, serial). Video: `VGA_R/G/B` =
  `{8{~vidout}}` (`se30_video`'s `vidout` is 1 = black), `VGA_DE` =
  `~(hblank | vblank)`, syncs from the video RTL, `CLK_VIDEO`/`CE_PIXEL`
  as 3.2. **Aspect: 256:171**, the 512 x 342 image at square pixels, as
  MacPlus has it (MacLC's 4:3 is the LC's monitors; its note that 256:171
  overflows V-Integer on 5:4 panels is a scaler-menu matter and is kept
  in mind, not acted on). Audio silent until the ASC section; UART and
  the user port parked at the template's defaults. `LED_USER` = a download
  in progress, later disk activity.
- **`rtl/se30_machine.v`** - the logic board: the wrapper, GLUE, the
  video, and in their sections the VIAs, ASC, SWIM, SCC, SCSI, ADB and
  RTC. Its ports are the memory port to the controller, the declaration
  BRAM's write port, video out, later audio and the peripherals'
  host-side ports (keyboard, mouse, disk images, serial), `clk`, `phi1`,
  `phi2`, `reset_n`.

The split exists for 1.10's sake: the machine module is what the
full-system bench instantiates - with our SDRAM controller and a
behavioural SDRAM model and the real ROM image, under ModelSim (the kernel
is VHDL; mixed-language is proven, 1.10 item 1) - without `hps_io`, the
scaler or anything the framework owns, none of which simulates and none
of which is ours. It is the same seam the MacPlus ladder factors out of
`dataController_top.sv`, at the altitude where it matters here.

A probe deck (`rtl/dbg_probes.sv`, ours, under `USE_DBG_PROBES`, which
**`MacSE30.qsf` must define** - it did not until 2026-09-27, so compiles
1-3 carried no probes) exposes to ISSP what the bring-up needs read back
over JTAG, which is the one hardware access permitted
(`feedback_merge_compile_gate`): the fetch address, the last `AS*`
address and FC, cycle and bus-error counters, `halted`, and `PBLD`, the
bitstream's git SHA. `PBLD` is MacPlus's build-tag practice, ported
whole: `rtl/build_tag.v` is committed as 0 and stamped from HEAD by
`scripts/stamp_build_tag.ps1` immediately before a compile;
`scripts/archive_build.ps1 <label>` copies the fresh `.rbf`/`.sof` to
`output_files/MacSE30_<sha>_<label>` named by that tag, refusing an
unstamped tag or a design that moved since it; `scripts/read_probes.tcl`
reads the deck and prints `bitstream=<sha>` or `UNSTAMPED`, and declares
absent probes rather than printing zeros. Both PowerShell scripts need
`-ExecutionPolicy Bypass` on this machine.

## 3.6 The bring-up ladder and its benches

Cheapest first, each rung a gate for the next; the first three need no
permission, the fourth always does (`macplus-core-conventions`):

1. **The existing benches stay green** after the RTL changes this section
   makes - `sim/glue`, `sim/video` (with `c16_en` and the BRAM write
   port), `sim/system` (with `ecs`), `sim/kernel_bus` and
   `sim/kernel_upstream` untouched.
2. **`sim/sdram/`, iverilog**: `rtl/se30_sdram.v` against a behavioural
   SDRAM model - Micron's `mt48lc16m16a2` Verilog model if its terms
   allow it in the repo, otherwise ours from the datasheet - holding: the
   4-clock RAM cycle from an S0 start, back to back, with the data on
   `rdata` at the acknowledge; every byte-enable pattern of Table 7-7 on
   writes; an aborted start (ECS without AS) leaves the next cycle intact;
   refresh meets 7.8 us and never delays a request in the back-to-back
   pattern; the download port interleaves with CPU cycles without loss;
   the init ladder's command sequence and its 100 us.
3. **`sim/machine/`, ModelSim**: the machine module, the controller, the
   SDRAM model and the ROM image, from reset: (a) the first fetch is the
   reset vector from ROM through the overlay - `SP` from `$00000000`,
   `PC` from `$00000004`, then the first instruction at the ROM's reset
   PC (2.2: `$4080002A` in the ROM's own table); (b) the ROM runs until
   its first I/O access (a VIA, by 2.11.6's start-up: the ROM clears
   `OVERLAY`), which is reported and is where Section 4 begins. This is
   also the measurement 1.10 asked for: the Starter Edition's wall-clock
   on the full machine, so the instance-limit question gets a number.
4. **`quartus_map --analysis_and_elaboration MacSE30`**: 0 errors; the
   warning count is the baseline to record.
5. **Full compile - ask first, every time.** STA met with the constraints
   of 3.2; no 332125/332081; the fit recorded against 1.6's table. The
   ritual is MacPlus's (3.5): `stamp_build_tag.ps1`, then
   `bash scripts/build_only.sh`, then `archive_build.ps1 <label>` while
   the tag is still stamped, then `git checkout -- rtl/build_tag.v`
   (and `MacSE30.qsf` if Quartus rewrote it). A build whose tag was not
   stamped reads `UNSTAMPED` on `PBLD` and the archive script refuses
   it.
6. **Hardware - Daniel flashes, always.** The probes say the CPU fetched
   from ROM, ran, and stopped where the machine bench said it would.

Then each peripheral section repeats rungs 1, 4, 5, 6 with its own bench
at rung 2 and the machine bench extended at rung 3, and the ROM gets one
step further each time: the VIAs and RAM sizing (the mirror rule's
acceptance test, 2.11.6), the boot chime (ASC), the disk (SWIM, SCSI), the
desktop (ADB). **Section 4 is the VIAs' (4.9 is its rung list).**

## 3.7 Risks and open items

- **The SDRAM read eye at 94 MHz** and the S0 speculative start are the
  section's engineering risk; the bench of 3.6 item 2 catches logic, not
  I/O timing - the sdc constraints (MacLC's 2026-09-12 set, re-derived for
  the new period) and the first fit's STA are the only evidence before
  hardware. **Realised 2026-09-27 (4.11 item 8): the capture has -0.128
  ns of hold at the fast -40C corner, which the compile flow never
  analyses (`TIMEQUEST_MULTICORNER_ANALYSIS OFF`, the template's), and
  the board's reads are a per-boot lottery. The remedy is chosen there.** **The first fit met the I/O constraints (+1.7 ns) and failed
  the `clk_sys -> clk_mem` crossing instead (3.8 item 10; fixed in 3.2).**
  One clock now in hand rather than two. Fallback if a later fit shows
  the 21 ns cone short: 4 x (3.2's table), then the split acknowledge
  (DSACK from a promise, data by the end of S4, a further 1.5 clocks) - a
  workaround, listed as one.
- **A 4-node combinational loop in the kernel** (3.8 item 10): attribute
  it (ours or upstream's) before any kernel timing credit is considered.
- **How an empty RAM bank reads.** The ROM sizes RAM by writing and reading
  bank boundaries (2.11.6); on the board an unpopulated SIMM socket reads
  a floating bus. The core's installed size (an OSD option later, 8 MB
  now) has to make absent addresses fail that test the way the board's
  do, and what the ROM's sizing code tolerates is read from the ROM
  (1.11's tooling), not guessed. Open until then.
- **RAM to 128 MB with a 32-bit clean ROM - a wanted option (Daniel,
  2026-09-27).** With a IIsi / IIfx ROM file (32-bit clean) the machine
  addresses RAM to the *Guide*'s Table 5-2 ceiling of 128 MB, and the
  core is to offer that as an OSD option, the stock 8 MB staying the
  default (1.5). Nothing changes now; it lands when RAM sizing is done
  (this list's previous item, and Section 4's VIA2 `RAMSIZ`). It fixes
  what the SDRAM map has to grow to: the ROM image at word `$400000`
  (3.3) sits at the 8 MB mark and must move above the largest RAM, and
  the DE10-Nano's 32 MB SDRAM caps what one module can offer, so 128 MB
  needs the 64 MB or 128 MB modules or a smaller top step; the strap
  combinations the ROM accepts (`$4080366E`, 1.5) decide the steps.
- ~~**ModelSim's limits** on the full machine (1.10): measured at rung 3.~~
  Measured: 9 s for 215 us of the whole machine (3.8 item 8). Closed.
- **The declaration BRAM's write port** changes `se30_video`'s internal
  ROM; the video bench keeps the preload, the machine bench loads it the
  hardware way.
- **Template drift.** `69b8a2a` is a deliberate pin (3.1); the newer
  template is a later wholesale update, A/B'd on hardware.
- **The 030 caches** are still absent (1.15 item 9); the ROM's start-up
  will exercise `CACR` and the kernel must take it. Not this section's.
- **The Memory option, the 1-5 MB configurations and 16 MB SIMMs** wait
  on the empty-bank question and are not in the first cut.

## 3.8 The work

1. ~~Write this section.~~ **Done 2026-09-26.**
2. **The cut**: `sys/` from `Template_MiSTer@69b8a2a`; the project files
   and `.gitignore`/`.gitattributes` (3.1); the build scripts from
   `MacLC_MiSTer@045f896`; the README's attribution. Byte-exact where
   inherited, endings checked per file.
3. **`rtl/pll/`**: the hand-written `altera_pll` wrapper, 31.3344 and
   94.0032 MHz, and its qip.
4. ~~**`rtl/se30_video.v`**: `c16_en`; the declaration ROM as a BRAM with a
   write port; `sim/video` green.~~ **Done 2026-09-26** (44 checks).
5. ~~**`rtl/tg68k/tg68k.v`**: `ecs` (the 68030's `ECS*`, asserted for S0);
   `sim/system` green and unchanged in its counts.~~ **Done 2026-09-26**
   (23 checks, the same 240 cycles); GLUE gained `mem_early`/`rom_early`,
   its decode without `AS*`, for the start (91 checks unchanged).
6. ~~**`rtl/se30_sdram.v`** and `sim/sdram/` (3.3, 3.6 item 2), datasheets
   read first.~~ **Done 2026-09-26**: both datasheets read (the table in
   3.2), CL2 taken, 165 checks; the bench's three findings are in 3.2.
7. ~~**`rtl/se30_machine.v`**, **`MacSE30.sv`**, `MacSE30.sdc`, `files.qip`,
   `rtl/dbg_probes.sv`.~~ **Done 2026-09-26.**
8. ~~**`sim/machine/`** (3.6 item 3): first fetch, first I/O access, the
   ModelSim measurement.~~ **Done 2026-09-26 - and it found the section's
   one real bug.** The ROM runs from reset: the vector reads at `$0` and
   `$4` in supervisor program space (FC 6, UM 4.2: "the reset vector ...
   is located in supervisor program space"), the fetch at `$40800028`,
   and 71 cycles later the first I/O access: a **write to `$50F00600`**,
   VIA1's DDRA (RS = 3 on A12-A9) - the ROM setting the direction of the
   port that carries `OVERLAY`, which is where 2.11.6 said it would go and
   where Section 4 begins. Every memory cycle was 4 clocks bar one in
   GLUE's refresh window. **The bug:** the wrapper's first `ECS` asserted
   whenever it was idle with a request pending, which includes the window
   from S5 to the kernel's acknowledge, where the kernel still presents
   the request just completed - so the controller opened a speculative
   read at the *old* address and the second of two back-to-back fetches
   came back with the first one's data (the PC read at `$4` returned the
   checksum at `$0`). The 68030 asserts `ECS` only at S0 with the new
   address; the wrapper now does too (`!ack_pending`, and never in
   reset). No other bench could have seen it: `sim/system` does not use
   `ECS`, `sim/sdram` drove it correctly by construction. **Kernel quirk
   recorded:** TG68K prefetches the long at `$8` between the PC read and
   the first fetch at the new PC, one 4-clock cycle a 68030 does not run
   at reset; harmless, noted for 1.9 item 8's timing audit. **The ModelSim
   measurement (1.10):** the whole machine - kernel, PMMU, wrapper, GLUE,
   video, the controller and the chip model with a 32 MB array - runs 215
   us of simulated time (the SDRAM's 200 us power-up included) in 9 s of
   wall clock. The Starter Edition's limits are not a problem at this
   altitude.
   **Run on past the VIA write (2026-09-27), the prediction for the first
   hardware run:** with the VIAs answering $00 the ROM writes DDRA, then
   reads and writes ORA (`$50F01E00`, RS = 15) six times - it is driving
   `OVERLAY` and looking for the result - and settles into a
   three-instruction polling loop at `$408036FC`/`$40803700`/`$40803704`,
   never halting and never bus-erroring; 3,109 cycles to the loop's
   detection. **So the probe deck should read PIFA in that triple, PLAS
   the same, PACT counting, halted 0, bus errors 0.** Anything else on
   the board means the SDRAM path, not the ROM, is the question. 45 s of
   ModelSim for the run.
9. ~~Elaboration (3.6 item 4).~~ **Done 2026-09-26: 0 errors, 85 warnings
   (84 name our tree; all but three are the inherited kernel's and
   PMMU's - VHDL sensitivity lists, unused signals - and the three of ours
   were cosmetic and are fixed), 1 min 37 s.** Quartus rewrites
   `MacSE30.qsf` with the framework's pin assignments inlined on every
   run; the short form is kept in git and the rewrite reverted.
10. **The first compile, 2026-09-27, with Daniel's go-ahead: 18 min, an RBF
    produced, fit healthy, timing NOT met.** Fit: 18,291 ALMs of 41,910
    (44%), 18,817 registers, 160 of 553 M10Ks (22% of the bits), 3 PLLs.
    STA: every domain met except `clk_mem`, -5.657 ns, all on the
    `clk_sys -> clk_mem` crossing into the SDRAM controller's input
    registers (the analysis and the fix are in 3.2: sample on the second
    edge, a two-cycle multicycle on those registers); the SDRAM I/O
    constraints themselves met (+1.7 ns), the kernel closed at 31.3 MHz
    with no credit (+2.9 ns worst in `clk_sys`). **Two things to carry:**
    (a) Quartus reports **a 4-node combinational loop in the kernel**
    (`TG68KdotC_Kernel.vhd` line 7768, nodes `exec~6` and `Selector121`,
    warning 332125) - the class MacLC's SDC history warns about; our delta
    does not touch that region (the nearest hunk is a comment), so it is
    probably upstream's, to be confirmed by elaborating upstream's kernel
    alone, and then either fixed here or credited honestly; (b) the PMMU's
    `atc_shift` registers draw "Ignored Power-Up Level" critical warnings
    (they power up high), upstream's, harmless while `nReset` initialises
    the ATC - to be checked in the PMMU source. `scripts/sta_paths.tcl`
    (ours) prints the worst paths per domain from a compiled design.
11. **The second compile, 2026-09-27, with Daniel's go-ahead, the
    sample-on-the-second-edge fix in: 17 min, an RBF produced, fit 43%,
    timing NOT met, -2.491 ns.** The `clk_sys -> clk_mem` paths are gone
    (the multicycle did its job) and the one violation left is the SDRAM
    read capture, `SDRAM_DQ -> dq_q`: relationship 10.6 ns, clock skew
    -3.97 ns (the clock's delay through the DDR cell to the pin, which the
    chip's launch inherits), input delay 6.5, pin-to-register 2.35. Hold
    met everywhere. **Fixed (this item): the capture moves to the rising
    edge** (3.2's revised timeline), one register fewer, the same
    sequence numbers; `MacSE30.sdc` gains a two-cycle setup multicycle on
    `dq_q` and no hold credit; both benches model the 4 ns on the chip's
    clock (the range they pass over is in the bench). SDRAM bench 165
    checks, machine bench 12 with the same probe prediction. The -2.5 ns
    RBF was not flashed.
12. **The third compile, 2026-09-27, with Daniel's go-ahead: 17 min, an
    RBF produced, fit 44% (18,427 ALMs, 18,725 registers, 22% of the
    block memory), TIMING MET in every domain.** The read capture
    `SDRAM_DQ -> dq_q` now times at the 15.95 ns relationship (the
    multicycle took), +0.91 ns of setup at the slow corner (skew -3.48,
    the I/O cell's own delay 3.9 ns - the register is in the DDIO input
    cell, `DDIOINCELL_X32_Y81`), and +3.23 ns of hold on the real 5.32 ns
    relationship. It is the worst setup path in `clk_mem`; `clk_sys`'s
    worst is +1.95 (the kernel, still no credit), `sdram_clk`'s outputs
    +1.75, the framework's HDMI +0.40, worst hold anywhere +0.25 (the
    framework's). The 332125 4-node kernel loop is still reported and
    still unattributed. The PMMU's 18061 power-up warnings are closed
    from the source: the ATC reset value 12 needs an asynchronous set on
    two bits of each entry, which Cyclone V implements by inverting the
    register, so those bits power up at the reset value; upstream's code,
    harmless. This RBF is the first fit to flash: **the probe deck should
    read the prediction in item 8** (PIFA in `$408036FC/$40803700/
    $40803704`, PLAS the same, PACT counting, halted 0, bus errors 0).
    Quartus did not rewrite `MacSE30.qsf` this run. **Archived by hand
    as `output_files/MacSE30_069d417_dqrise.rbf` / `.sof`** (md5
    `364645220e5e39f26bddbb25fc6da342`), named by the design commit,
    which git confirms unchanged to the commits after it; it predates the
    build tag, so it has no `PBLD`. **And it has no probe deck at all:**
    `USE_DBG_PROBES` was never defined in `MacSE30.qsf` (found 2026-09-27
    while porting the archive practice; the fitter report has no probe
    instance), so this RBF proves the fit and the timing but cannot be
    read against item 8's prediction.
13. **The archive practice ported from MacPlus (2026-09-27), and the deck
    switched on.** `rtl/build_tag.v` + `PBLD` in the deck, `files.qip`,
    `scripts/stamp_build_tag.ps1`, `scripts/archive_build.ps1`,
    `scripts/read_probes.tcl` (all three exercised: the refusal, a stamp,
    a stamped archive), `USE_DBG_PROBES=1` in `MacSE30.qsf`. Compile 3's
    bitstream, flashed by Daniel: a white screen (as predicted: VRAM
    never written) and, on the reader, no ISSP instance - the missing
    define, confirmed from the board.
14. **The fourth compile, 2026-09-27, with Daniel's go-ahead, the first
    by the ritual: tag `7785248e` stamped, 17 min, TIMING MET (read
    capture +0.91 as before, `clk_sys` +3.05, worst hold +0.25), fit 44%
    (18,571 ALMs, 19,261 registers), all five probes in the fitter
    report; archived by the script as
    `output_files/MacSE30_7785248e_probes.rbf` / `.sof` (md5
    `ba7a7e8a7dd0977ad774fc71da027262`), tag restored to 0.**
15. **The first board reading, 2026-09-27, Daniel having flashed compile
    4 (a white screen): not item 8's prediction.** `PBLD 7785248e`;
    `PACT` 53 and frozen; `halted` 1; bus errors 0; `PIFA $002A0030`;
    `PLAS $0000000C`, a supervisor data read. Read together: the ROM's
    reset vector at `$4` is `4080 002A`, and a program counter of
    `$002A002A` puts the last fetch at exactly `$002A0030`; a longword
    read that returns the burst's **second word in the high half and the
    floating bus (still holding it) in the low half** gives that vector,
    and it also makes the address-error vector at `$C` read
    `$00840084`, an odd handler address - so the CPU halted on the double
    fault without a bus error and without ever fetching the handler,
    which is why `PLAS` stops at `$C`. Reads were delivering the data one
    clock earlier than the model launched it. **The cause is the model's
    reading of CAS latency, MacLC's, inherited with its capture work: it
    launched the first word from the second chip edge after the READ,
    where the datasheet (AS4C32M16SB 1.4, quoted in 3.2 and in the
    model) has it valid AT that edge, launched from the first.** Fixed
    in `sim/sdram/sdram_model.v` (the launch index) and
    `rtl/se30_sdram.v` (the words consumed at sequence 6 and 7, the
    acknowledge a clock earlier, two clocks in hand at GLUE); 3.2's
    timeline rewritten; the sdc unchanged (the launch-to-capture relation
    is the same edge pair). The corrected model fails the previous
    controller on "read data matches" and passes the corrected one: SDRAM
    bench 165 checks, the clock-to-pin window 2.9-5.3 ns as before,
    machine bench 12 with the same prediction.
16. **The fifth compile, 2026-09-27, with Daniel's go-ahead, by the
    ritual: tag `2654faeb`, TIMING MET (the read capture +0.91 as
    before, worst setup the framework's HDMI at +0.17, worst hold
    +0.25), fit 45%, five probes; archived as
    `output_files/MacSE30_2654faeb_cl2edge.rbf` / `.sof` (md5
    `726df519e7f815e0dcce6a21edd5a41b`), tag restored to 0.**
17. **The second board reading, 2026-09-27, compile 5 flashed by Daniel:
    the SDRAM path works; the machine stops where a machine with no VIAs
    and no writable RAM must.** `PBLD 2654faeb`; `PACT` **728,640** and
    frozen; `halted` 1; bus errors 0; `PIFA $0075D1F4`; `PLAS
    $0000000C`. **Item 8's prediction was misread by the session that
    wrote it:** `$408036FC/$3700/$3704` are not a VIA1 poll but the
    fetches of the ROM's **checksum loop** (`$408036F0`: `LEA
    $40800000,A0; MOVE.L (A0)+,D4; MOVE.L #$1FFFE,D3; loop: MOVE.W
    (A0)+,D0; ADD.L D0,D1; SUBQ.L #1,D3; BNE.S loop; EOR.L D4,D1; BEQ.S
    ok; MOVE.W #$FFFF,D6; ok: JMP (A6)`), which reads every word of the
    ROM: 131,070 iterations of three longword fetches (the 030's cache is
    off at reset) and one data read = 524,280 bus cycles, about 130 ms -
    the bench's 215 us saw the first 3,000 of them and called it a poll.
    So the board ran the whole checksum loop through the SDRAM path and
    then 204,360 cycles more, against compile 4's 53. Where it stopped:
    with `OVERLAY` tied to 1 (the machine module's Section 4 stand-in)
    the ROM's RAM tests and its exception stack fall on the read-only ROM
    window, so an exception during exception processing - the halt, with
    the address-error vector at `$C` the last read - is the expected end,
    and the last fetch in the RAM window (`$0075D1F4`) says the ROM had
    already moved on to RAM. **Section 3's rung 6 is therefore met as far
    as this machine can show it: the CPU fetched from ROM and ran the
    ROM's own 256 KB read test to its end. Whether the checksum PASSED
    is not observable without the VIAs (the verdict goes to D6 and the
    Sad Mac code).** Two things carried into Section 4: the machine
    bench's prediction is only good for the first 130 ms of machine time
    (make the next prediction from the ROM's code path, not from where
    a short run happens to sit); and a probe on the checksum verdict
    (e.g. a fetch seen at `$4080370E`, with the prefetch caveat, or
    better the sum GLUE hands back over the loop) is cheap insurance
    before trusting the SDRAM path with RAM.

18. **The read capture made corner-proof (decided 2026-09-27, the design
    in 4.11 item 8): two phase-shifted capture clocks from the PLL, a
    training read at the end of the power-up ladder choosing between
    them, multicorner analysis on.** ~~Not started.~~ **Built 2026-09-27;
    benches green, elaboration clean; the seventh compile needs Daniel's
    go-ahead.** Nothing else moves until the board reads the ROM
    reliably, and Section 4's result (its VIAs, never yet written on the
    board) is read only after it. What was built differs from 4.11 item
    8's sketch in four places, each forced by a fact found on the way;
    the sketch stands there with a pointer here.

    - **One I/O-cell register, not two.** A Cyclone V I/O cell has one
      input clock: two registers on two clocks left the second in the
      fabric through a feeder (a throwaway fit of the SDRAM pins alone,
      `iotest` run 1, one minute), and the cell's DDIO atom with
      `use_clkn` and a second clock on `clkn` is refused outright (Error
      15890, run 2). So `dq_q` is one cell register whose clock a clock
      control block selects between the two capture clocks (`altclkctrl`,
      the PLL outputs on its inputs 2 and 3 - Quartus 15836 - so the
      select is `{1, cap_sel}`); it packs as the cell's Fast Input
      Register with that clock (run 3) and STA times it under both. The
      training switches it, with sixteen clocks of settling.
    - **The phases come from the experiment, not from compile 6's table.**
      The table's eye was not the silicon's: compile 6's own capture
      path (its database, read 2026-09-27 with its own sdc) carries 1.5
      to 2.5 ns of input delay chain on the SDRAM_DQ pins - D1 settings
      up to 14 of 15, the data cell 3.9 ns against 1.4 with no chain -
      the fitter's hold optimiser ("Optimize Hold Timing: All Paths",
      "Optimize Multi-Corner Timing: On", both already on) tuning a
      single capture as far as it could go, and -0.128 was as far as it
      went. That is why the eye sat where the table said and why it
      would move between compiles. The experiment's clock paths match
      the core's within 0.1 ns (PLL counter through the clock control to
      the cell: 4.87 against 4.75 ns; through the DDIO cell to the
      SDRAM_CLK pin: 8.39 against 8.33), so at chain zero it IS the
      core's capture timing, and a phase pair costs a minute to test
      instead of twenty. **The arrangement** (rtl/pll.v): the chip's
      clock on its own PLL output at +1.064 ns, balancing our outputs'
      setup and hold at the chip; capture A at -0.266 ns (as +10.372)
      for slow silicon, capture B at -2.261 (as +8.377) for fast; all in
      whole VCO-phase steps of 132.98 ps. The slacks at chain zero, run
      8, the worst SDRAM_DQ pin at each corner:

      | corner | capture A setup / hold | capture B setup / hold | outputs at the chip |
      |---|---|---|---|
      | slow 100C | **1.34 / 1.83** | -0.66 / 3.83 | 2.40 / 2.50 |
      | slow -40C | **1.81 / 1.56** | -0.19 / 3.56 | 2.50 / 2.63 |
      | fast 100C | 3.86 / 0.41 | **1.86 / 2.40** | 3.30 / 2.94 |
      | fast -40C | 4.27 / -0.03 | **2.28 / 1.97** | 3.36 / 2.95 |

      At every corner one capture is inside the eye by at least 1.3 ns
      and the other fails by design; the training tells them apart (a
      wrong capture cannot return the pair, 4.11 item 8). Separate PLL
      counters for the chip's clock and the captures cost about 0.35 ns
      of analysed eye against a shared one (STA applies the PLL's
      min/max spread between counters); the freedom to place three
      phases is worth it.
    - **The transfer into the clk domain takes no credit.** A falling-
      edge register straight from the cell failed for A by 1.2 ns: the
      cell-to-fabric path is most of a period at the slow corner (run
      6). So `dq_q` -> `dq_w` (a full period on the capture clock) ->
      `dq_m` (clk_mem's falling edge: 5.6 ns from A's edge, 7.6 from
      B's) -> `cpu_rdata` (half a period), every hop single-cycle and
      met at every corner (run 8: 3.5, 2.1, 3.1 ns at the slow corner).
      Any consumer clocked on clk_mem's rising edge would have needed a
      multicycle with a 2 ns hold check behind it for B. The cost is
      one clock: the words reach `cpu_rdata` at 7 and 8 after ACTIVE
      (were 6 and 7), the acknowledge at 8, GLUE samples at 12 with one
      clock in hand instead of two; the contract (ack at two C16M) is
      unchanged and the benches hold it.
    - **The fitter and the flow's STA do not see the capture; the corner
      script does.** A fitter asked to meet both captures at every
      corner can meet neither and would chase the pair with the delay
      chains; so MacSE30.sdc gives the flow a false path on the capture
      and the two-cycle setup multicycle only when `se30_time_capture`
      is set, which scripts/sta_corners.tcl does before reading it; the
      qsf pins `D1_DELAY 0` on SDRAM_DQ (the assignment verified in run
      8: a 5 shows as chain 5) and has multicorner analysis ON; the two
      capture clocks are an exclusive clock group, or STA times the
      phantom crossing between them through `dq_q` (-4.4 ns, run 7).
      The corner script's verdict is two lines: every SDRAM path but the
      capture met at every corner, and at every corner at least one
      capture met. `build_only.sh`'s "timing met" no longer covers the
      capture at all.
    - **The training** as sketched, with 32 reads per capture (not 8)
      and the pair $A5C3 / $5A3C (complementary in every bit, not
      $3C5A); A when both pass, because a cold board warms and slows,
      widening A's margin and narrowing B's. `cap_sel`, `cap_fail` and
      `cap_ok` are PSTA bits 20-17; read_probes.tcl prints them.
    - **The benches.** sim/sdram: 169 checks at the default pin delays
      (both captures inside the eye, A chosen; the first CPU read
      returns the pair), then the training alone at three settings that
      move the eye - only B inside, only A, neither - each choosing as
      it must; the bench now delays our outputs to the chip like the
      clock (OUT_TO_PIN) and the chip's data to the register
      (DQ_TO_REG), so CLK_TO_PIN no longer collides with the command
      sampling. sim/machine: 17 checks, the same prediction, 116 s, the
      training before the machine leaves reset. Both benches make the
      shifted clocks with transport delays (`<= #d` in an always block):
      an `assign #d` is inertial and a delay longer than half a period
      swallowed the capture clock entirely, every read X - an hour
      found and fixed. Elaboration: 0 errors, 82 warnings, as before.
    - **The gate:** compile 7 with Daniel's go-ahead, by the ritual;
      `quartus_sta -t scripts/sta_corners.tcl` on it against the table
      above (the flow's summary is no longer the capture's verdict); the
      board: PSTA's capture bits say which capture it chose and which
      passed - the expectation for this board, which showed hold margin
      near zero at room temperature on compile 6's single capture, is B.

    **Compile 7, 2026-09-27, Daniel's go-ahead, tag `eaadecec`, 19m43s,
    NOT a board build.** The capture came out as the experiment said, to
    the tenth: A 1.63/1.65 and 2.08/1.35 at the slow corners, B 2.00/2.30
    and 2.40/1.86 at the fast ones, the transfer chain 1.5 ns and better
    everywhere, every SDRAM_DQ delay chain 0, `dq_q` packed as the Fast
    Input Register. **What failed was the outputs to the chip: -1.44 ns
    of setup at slow 100C on SDRAM_DQ's output enable, -0.22 on SDRAM_A.**
    The fitter had put clk_mem on a REGIONAL clock network (RCLK76, one
    quadrant) where compile 6 had it on a global (GCLK10); its automatic
    periphery placement then confined every clk_mem register to that
    quadrant, so `dq_out` and `dq_oe` could not pack into the I/O cells of
    the DQ pins outside it (Warning 176229, "conflicting location
    assignments"), a fabric copy of `dq_oe` drove ten pins through 4 ns of
    routing, and the hold optimiser answered with the maximum output-
    enable delay chain (D5 OE 31) on every DQ pin. Not a shortage: 12 of
    the 16 globals were in use. The fix is to say it: `GLOBAL_SIGNAL
    "GLOBAL CLOCK"` on the three PLL outputs in MacSE30.qsf (the capture
    clock is global by its clock control block's setting). Not archived;
    the tag restored.

    **The board on compile 7 (Daniel flashed it anyway, 2026-09-27):**
    `PBLD eaadecec`, sdram ready, **the training passed BOTH captures and
    chose A**, and the machine halted at 53 cycles with `PIFA $002A0030`,
    `PLAS $C` - compile 4's and 6's picture to the digit. Its outputs to
    the chip were 1.4 ns short of setup at the slow corner, so it is a
    poor witness; but it says one thing clearly: **a training that passes
    both captures does not by itself protect the ROM read.** The likely
    reading: on this silicon both edges are inside the eye at power-up,
    A by very little (STA's fast-corner hold for A is -0.13 to +0.30),
    32 reads passed on jitter's good side, and the CPU's hundreds of
    thousands of reads found the bad side - the crossover case of the
    "A preferred" rule, on the wrong side of it. Two probes added for
    compile 8 so that the reading can be made: `PCAP`, the training's
    counts per capture (a marginal 32 of 32 against a solid one is still
    invisible; the counts tell whether a capture failed outright), and
    `PMEM`, the data of the machine's last acknowledged memory read (the
    reset vector's PC is `$4080002A`; `$002A002A` is the late capture).
    If compile 8 repeats the picture, the decision rule is the work: the
    training must measure margin, not pass/fail - the PLL's dynamic phase
    shift sweeping one capture clock across the eye is the instrument that
    does, and 4.11 item 8's (b) option list should have had it. **Compile
    8 with Daniel's go-ahead (given with the board reading).**

    **Compile 8, 2026-09-27, tag `31f122a8`, 21m37s, A BOARD BUILD,
    archived as `output_files/MacSE30_31f122a8_twocap.rbf` / `.sof`.**
    The global-clock lines took: clk_sys GCLK7, clk_mem GCLK6, the chip's
    clock GCLK11, the capture clock GCLK9; no packing conflict, every DQ
    delay chain 0, `dq_oe` and `dq_out` in their cells. The flow: met,
    +0.115 (the framework's HDMI, as every compile). The corner script:
    outputs at the chip 2.32/2.53 at slow 100C and 3.27/3.01 at fast -40C;
    the capture A 1.63/1.62 and 2.09/1.34 at the slow corners, B 2.00/2.28
    and 2.40/1.85 at the fast ones (the experiment's table within 0.05
    ns; its "design setup -0.363" line is capture B at the slow corner,
    which the script times on purpose and the flow does not); every other
    SDRAM path met at every corner, the least being 0.94 ns of hold on
    `dq_q -> dq_w` at fast -40C. Fit 46%. The board is next: PSTA's
    capture bits, PCAP's counts, PMEM's reset vector.

    **The board on compile 8 (Daniel, 2026-09-27): the training passed A
    32 of 32 and B 32 of 32, chose A, and the machine halted at 151
    cycles** - no bus error, the last cycle a supervisor data read at $C
    (the address-error vector) that returned `$4A6B4A6B`, the last fetch
    at `$4EFA4EFC`. Against the ROM file (its checksum recomputed and
    matching, version $178): the long at $C is `$00844EFA`, `$4A6B` first
    occurs at offset $4620, `$4EFC` occurs nowhere in the ROM, and
    `$4EFA4EFC` is `$4EFA` doubled with bits 1 and 2 flipped - DQ[1] and
    DQ[2], two of the three DQ pins on the chip's top edge. After an OSD
    reset (the SDRAM image kept, the training not rerun) the machine did
    not halt: ten million cycles and counting, executing from
    `$8EDAxxxx` with reads returning the address plus two, an unmapped
    region's echo. So the reads are nondeterministic, the image is not
    simply corrupt, and a training that passes 32 reads through A is
    blind to a failure the CPU meets within a hundred: **the crossover
    case, with A the capture STA puts at -0.14 to +0.29 ns of hold on
    fast silicon, and the errors on the pins with the longest paths.**

    **Two changes, built 2026-09-27, for compile 9:**
    - **The training counts.** 65,536 reads per capture on the board (a
      parameter; the benches set 32), the failures counted, saturating
      at 16,383; A if clean, else B if clean, else the fewer failures;
      PCAP carries both counts. A capture one read in a hundred from the
      edge shows some 650, one in ten thousand about six, a capture with
      half a nanosecond in hand none: the count is the margin, coarsely,
      and it is what the rule needed. (The match is counted, not the
      mismatch: in simulation a wrong capture reads X, and a mismatch
      test on X is X, which an `if` treats as false - the first form of
      this counted nothing and called every capture clean.)
    - **A JTAG memory peek**, because Daniel's question - is it reading
      the ROM correctly at all? - has never been answered: compile 5's
      checksum loop ran to its end but its verdict was not captured, and
      the training proves only that two words the controller wrote come
      back. `read_probes.tcl peek <longword> [count]` holds the machine
      in reset, reads consecutive longwords through the controller's own
      CPU port (the same path, without the CPU), and prints them; the
      image is at longword $200000; `scripts/peek_diff.py` classifies
      each wrong longword as doubled (the capture), a neighbour (an
      address bit) or bit errors (which name DQ pins), and reading a
      range twice tells a varying read from a stable image. Its first
      use answers whether the boot0.rom on the card is the 97221136
      image at all.
    - The benches: sim/sdram 170 checks and the three moved-eye
      trainings, now with the counts checked against the verdict.
    **Compile 9 DONE (Daniel's go-ahead, 2026-09-27): tag `1812d325`,
    22 min, 0 errors, archived as `MacSE30_1812d325_countpeek.rbf`
    (md5 0ac7d7aa...).** The fit is compile 8's again: D1 input chains 0
    on every DQ pin, input/output/OE registers all in their cells, the
    chip's clock on GCLK11 and the capture clock on GCLK9, and
    `sta_corners.tcl` reads the same table to the hundredth - A 1.63/1.62
    and 2.09/1.34 (setup/hold) at the slow corners, B 2.00/2.28 and
    2.40/1.85 at the fast ones, the outputs 2.32/2.53 to 3.27/3.01, every
    other SDRAM path met at every corner (worst 0.97, `dq_q -> dq_w`
    hold at fast -40C). So compile 9 changes only what it meant to: the
    counting training and the peek. **Next: Daniel flashes; then
    `read_probes.tcl peek 200000 64` twice and `peek_diff.py` before
    anything else** (is boot0.rom the 97221136 image, and does this path
    read it), then the deck for PCAP's two counts and where the CPU got.

    **The board on compile 9 (Daniel flashed, 2026-09-27) - THE ROM IN
    THE SDRAM IS DOUBLED; THE READ IS NOT.** The peek of longwords
    $200000-$20003F, twice: every longword is the true image's SECOND
    word in both halves (62 of 64 wrong; the two "right" are pairs whose
    words are equal) - `1136 1136`, `002A 002A`, `4EFA 4EFA` for
    `9722 1136`, `4080 002A`, `0178 4EFA` - so the card's boot0.rom IS the
    97221136 image, and every pair holds its odd word twice. The read
    path is exonerated by three peeks the same session: the training
    pair at longword $7FFFFF reads `A5C3 5A3C` (two distinct words, the
    pair the controller's own two-beat burst wrote), unwritten RAM at
    $000100-$00010F reads sixteen distinct random longwords (`049A A40A`,
    `869A A68A`, ...), and unwritten bank-1 memory at $3F0000 shows
    unequal halves too. The deck: the training 0 of 65,536 failed through
    A and 0 through B, chose A; the CPU halted (double fault, PLAS $C).
    **The signature is a write mask that fails on the second beat**: the
    download writes one word per BL2 burst with the second beat masked
    (S_DL, DQM=11 at seq 3); if that beat is not masked, the even word
    fills its pair, then the odd word (burst order {c+1, c}) fills it
    again - every pair = its odd word twice. The bench model with ONE
    line changed (the second write beat ignores DQM, scratch copy only)
    reads back exactly the board's pattern (`8101 8101` for `8000 8101`)
    and fails the byte-enable checks too. What was ruled out: the RTL
    (the unmutated bench passes: the model honours a zero-latency write
    mask and the download test reads both words back); the FPGA-side
    timing (per-pin STA: DQMH/DQML setup 2.62/hold 2.60 at slow 100C,
    3.39/3.05 at fast -40C, data delay 3.34/3.17 ns against DQ's
    3.06-3.13 and nWE's 3.19 - the mask reaches the pins in the same
    window as data and command); the pins (AG13/AF13, byte-identical to
    MacPlus's and MacLC's sys.tcl); a burst-length or address-bit fault
    (BL4's arithmetic gives `{w2,w3}` for longword 0, an A0 fault gives
    the pair swapped, neither seen; the reads' two distinct beats say
    BL2 and A0 are right). What remains is the chip's side of the pins:
    the mask on a beat AFTER the WRITE command. MacPlus and MacLC never
    ask for that: both load the mode register with A9 = 1 (single-location
    writes, `NO_WRITE_BURST`) and carry the byte mask on the WRITE
    command's own clock (`sd_dqm = sd_addr[12:11]`), so their working
    byte writes prove the DQM traces and beat-0 masking, not beat-1.
    Compile 5's 728K-cycle run is NOT evidence the contents were ever
    right: compile 8's OSD reset ran ten million cycles in an unmapped
    region's echo, so a long run proves nothing about the image, and
    the doubled contents may date from the first download.
    **Also seen, unexplained:** the CPU's halting read of vector $C
    returned `$2F2B2F2B` (compile 8: `$4A6B4A6B`) where the peek reads
    `$4EFA4EFA`; both words occur at dozens of odd positions in the ROM
    and name no neighbour. The CPU's address path deserves its own
    look once the contents are right. **The peek instrument** is usable
    but its handshake is one read behind in some calls (the first line
    of a call can be stale, and one call printed "no acknowledge" and
    stayed two behind): a sequence tag in PPKS would make it exact.

    **Next (Daniel's choice):** the write mask must be made to work for
    the CPU's byte and word writes regardless of the download, so the
    question is the chip's, not the download's. The candidates: (a) a
    JTAG poke beside the peek with a PROGRAMMABLE mask schedule (which
    of seq 2..5 carry DQM=11) so one compile tests beat-0 masking,
    beat-1 masking, a mask held two clocks, and a mask a clock early -
    the instrument that finds where the chip samples DQM; (b) load the
    mode register with A9 = 1 (single-location writes, as MacPlus and
    MacLC do) and mask bytes on the command clock only, writing a
    longword as two single writes - the design the working cores prove
    on this board, at one more clock per longword write; (c) both: (b)
    for the machine, (a) to learn why. Section 3's contract (a 32-bit
    write per bus cycle) is met by either. **Daniel chose (c), 2026-09-27:
    "since the CPU is not going to be cycle-accurate anyway ... it would
    be good to know what the problem is, in case we can find another
    solution later on."** He also asked whether the 68040 cores had been
    checked first: the Quadra 800 core (danifunker's, now cloned beside
    the other cores) is Sorgelig's controller with `NO_WRITE_BURST`, the
    byte mask on the WRITE command's clock through `A12:A11`, and "writes
    still take two accesses" for a 32-bit beat - the same answer as
    MacPlus, MacLC and MacIIvi. No working core on this hardware masks a
    beat after the command.

19. **Single-location writes, and the write-mask instrument (built
    2026-09-27, plan 3.8 item 18's board reading on compile 9).**
    - **The design:** the mode register loads `$0221` (A9 = 1). A CPU
      write is two WRITE commands a clock apart - the high word to the
      even column with DQM from be[3:2] and no auto-precharge, the low
      word to the odd column with DQM from be[1:0] and auto-precharge -
      on the same clocks the two beats used, so the acknowledge, `busy`,
      tWR and tRP are as they were; the download word is one WRITE; the
      training pair two. `rtl/se30_sdram.v`'s header has THE WRITE. The
      benches: sim/sdram 177 checks (the byte-enable patterns and the
      download read back as before), sim/machine 17 into the boot chime;
      and the one-line model mutant that reproduced the board's doubled
      pairs now PASSES the bench, which is the point - nothing in the
      design depends on a masked later beat any more. Two commits:
      `82ec3e8` (the writes), `d355142` (the port below).
    - **The instrument, the raw experiment port** (`raw_*` on the
      controller; its header has the field map): while the JTAG poke
      holds the machine in reset, one request runs one experiment -
      ACTIVE, a WRITE at clock 2 to a given word, and on clocks 2-5 a
      programmable schedule of which word the pins drive, whether they
      drive at all, and DQM; optionally a second WRITE at clock 3 to the
      odd column; auto-precharge or the port's own PRECHARGE at clock 7 -
      or a PRECHARGE ALL and a LOAD MODE with a given value, so the chip
      can be put back in burst-write mode (`$0021`) for the experiments
      and returned. The bench's section 9 drives it against the model:
      in burst-write mode a masked second beat stays unwritten and an
      unmasked one takes clock 3's word, the two-WRITE form lands both
      words, the LOAD MODE round trip leaves the CPU port intact, and an
      experiment without auto-precharge is precharged by the port. (The
      model also taught the instrument something on its first run: in
      burst-write mode a second WRITE starts its own two-beat burst whose
      second beat wraps to the EVEN column - clock 4 must be masked in
      that form, or the floating bus is written over the first word.)
    - **The poke** (`MacSE30.sv`, `rtl/dbg_probes.sv`, under
      `USE_DBG_PROBES`): the peek's FSM also runs CPU-port writes with
      byte enables (PPOK's source: data, be, the odd-word bit) and raw
      experiments (PRAW's source: the schedule word), one per toggle of
      go. **PPEK's probe is now 40 bits, {operations done, data}**: the
      reader waits for the count to change and takes the data from the
      same word, which closes item 18's one-behind reading for good
      (count and data were in two probes, read by two JTAG scans).
    - **The reader** (`scripts/read_probes.tcl`): `peek` as before;
      `poke <lw> <data> [be]`; `mode <hex>`; `raw <word> <w0> <w1> <dqm>
      <oe> <sel> [ap] [second]` (per-clock fields written as
      `00.11.00.00` and `1100`, clock 2 first); and **`dqmtest [word]`**,
      the experiment set: rows 0a-0d the design's own CPU-port writes with
      byte enables (must all read as the datasheet), rows 1-9 in
      burst-write mode - compile 8's download shape (clock 3 masked, w0
      still driven), the same with the bus released, clock 3 unmasked,
      the mask held over 3 and 4, the FIRST beat masked, both masked, a
      mask a clock late, the two-WRITE form masked and unmasked - and
      rows 10-13 the same shapes in single-location mode (must all read
      as the datasheet). Each row prints the longword read beside what a
      chip that masks as the datasheet says would hold, and a verdict.
      The board's rows 1 and 2 are predicted to DIFFER (`11111111`); which
      of 3-9 differ says where the chip takes DQM. Every operation was run
      once off the board against stubbed probes (Python's Tcl), and the
      reader was run against compile 9 on the board, where it reports the
      missing probes and stops.
    - **Compile 10 DONE (Daniel's go-ahead, 2026-09-27): tag `9e268c3b`,
      23 min, 0 errors, archived as `MacSE30_9e268c3b_singlewr.rbf` (md5
      90d42175...).** The fit is compiles 8 and 9's again: D1 chains 0 on
      every DQ pin, the sixteen cells packed, GCLK11/GCLK9, and
      `sta_corners.tcl` reads the same capture table to the hundredth (A
      1.63/1.62 and 2.09/1.34 at the slow corners, B 2.00/2.28 and
      2.40/1.85 at the fast ones; outputs 2.31/2.53 to 3.27/3.01; the
      worst other SDRAM path 0.94 ns, met at every corner). On the board,
      in order:
      `read_probes.tcl 3 1.0` (PBLD, the training's counts, the CPU's
      state - with the download now single writes the ROM image should be
      right and the machine should get past the reset vector);
      `read_probes.tcl peek 200000 64` and `scripts/peek_diff.py` (the
      image); `read_probes.tcl dqmtest` (the chip's answer); then the
      Section 4 reading the VIAs were waiting for.
    - **The board on compile 10 (Daniel flashed, 2026-09-27).** THE IMAGE
      IS RIGHT AND THE MACHINE RUNS: the deck reads PBLD 9e268c3b, the
      training 0 of 65,536 failed through either capture, the CPU alive
      at some three million bus cycles a second with no halt and no bus
      error, **overlay 0 - the ROM's first VIA write landed and RAM is at
      0** - and the peek of the ROM's first 64 longwords matches the file
      (with two exceptions explained under item 20). The CPU sits in a
      loop at `$408032A0-$40803304` polling the SCC at `$50F04000` for a
      received character behind a flag bit in D7: the ROM's serial test
      manager, where the start-up code goes after a failed test, before
      the video card is set up (Daniel: no code on the screen; the
      screen flickers at every probe operation because the peek holds
      the machine in reset). **`dqmtest` (its coherent second run, after
      the reader's flush below): THE CHIP NEVER HONOURS DQM ON A WRITE.**
      Rows 0b-0d, the design's own byte-enable writes, wrote every byte;
      rows 5, 6, 9, 11 and 12 (the mask on the WRITE's own clock, in
      burst-write and in single-location mode) wrote everything; rows 1
      and 2 (compile 8's download shape) doubled the word as the ROM
      was doubled; rows 3, 7, 8, 13 (no mask) read as the datasheet;
      rows 8 and 9 read `22222222` - the second WRITE's own second beat
      wrapping to the even column with the floating bus, unmasked, just
      as the model warned. Everything else the chip does is textbook:
      `mode 0020` (burst length 1) doubled the first word of every read
      and `mode 0221` restored it, single writes land, two WRITEs land
      both words. So the ROM's RAM test, which writes bytes, fails, and
      the loop above follows. The FPGA's side of the DQM pins is built
      like the command pins (the fit packs `sd_dqm` and `cmd` alike,
      both as inverted fast output registers because both reset to
      ones - the command pins work), timed like them (setup 2.6 / hold
      2.6 ns at the slow corner, data delay 3.34 / 3.17 against nWE's
      3.19) and placed on the template's pins (AF13/AG13, the same as
      MacPlus, MacLC and the Quadra 800, whose `sdram_beat32` says a
      32-bit write is two accesses and whose 128 MB module selects its
      second chip through nCS as an address bit - DQM is wired normally
      on every module). MacLC masks bytes through these two pins and
      boots System 7 on this board. Nothing in the reports separates
      "the pin never goes high" from "the chip does not act on it";
      item 20's masked read does.

20. **The controller's done state, and the masked read (built 2026-09-27,
    from compile 10's board reading).**
    - **The one-behind peek, explained and fixed.** The first peek of
      a session, and the descending peeks, read one longword behind (the
      first value a word of ROM code: the machine's own last read). The
      mechanism, reproduced in the bench: a read whose request never
      arrives waited in S_DONE indefinitely, S_DONE issues no refresh,
      after 10.9 us the overdue flag blocked every new start, and the next
      request was acknowledged with the old data; the start then ran and
      parked its data in the same state. The hold cuts the running
      machine's cycle short, which is how every session began that way;
      a write's acknowledge cleared it, which is why `dqmtest` (a write
      first) was mostly aligned, and the reader now writes a scratch
      longword first (`005c1ed`). The machine was exposed too: an aborted
      start followed by a refresh-delayed start and a quick request would
      have been acknowledged with the aborted read's data, and an aborted
      start on a machine that then went quiet starved refresh. Two rules
      in S_DONE: a request after a new start belongs to the start; data
      nobody asked for by 63 clocks after its start is dropped. Bench
      section 9 (an abandoned read, 20 us of nothing, peek-shaped reads)
      fails on the old controller in exactly the board's way and passes
      on the new; the model's refresh-gap check catches the starvation.
    - **The masked read.** The raw port's command at clock 2 can be a
      READ (schedule bit 47; the data captured as a CPU read's and
      returned by the poke). DQM asserted on the READ's own clock blanks
      the burst's second beat two clocks later (the model's alignment:
      DQM on clock 2 blanks the second word, on clock 3 nothing), which
      the capture sees as the floating bus. `read_probes.tcl dqmread
      [word]` runs it unmasked and with four masks and says, per word,
      whether DQM blanked anything. **If every row reads both words, DQM
      never reaches the chip** and the pins or the module are the
      question (the emu port list is the template's `emu_ports.vh`, so a
      pin read-back is not ours to add); **if the masked rows are
      blanked, the chip sees DQM and it is the write mask alone that it
      ignores.** Bench section 10 proves the schedule against the model.
    - Benches: sim/sdram 184 checks, sim/machine 17; the reader's every
      operation run off the board against stubbed probes. **Compile 11
      DONE (Daniel's go-ahead, 2026-09-27): tag `5d502bf6`, 23 min,
      archived as `MacSE30_5d502bf6_dqmread.rbf` (md5 7991da3f...); the
      fit and the every-corner table as compiles 8-10 (capture A 1.63/
      1.62, 2.09/1.34; B 2.00/2.28, 2.40/1.85; outputs 2.31/2.53; worst
      other path 0.95; D1 chains 0, cells packed, GCLK11/GCLK9).** On the
      board: the deck, `dqmread`, and `dqmtest` once more with the fixed
      controller.
    - **The board on compile 11 (Daniel flashed, 2026-09-27): DQM NEVER
      REACHES THE CHIP.** The deck as on compile 10 (the machine alive in
      the SCC loop, overlay 0). `dqmread` at word $400000: unmasked and
      under every mask - clocks 2 and 3, clock 2, clock 3, clocks 3 and
      4 - the raw READ captured `97221136`, both words, every time; a
      chip that saw DQM would have blanked the second beat under the
      clock-2 masks (the model's alignment). `dqmtest` on the fixed
      controller repeated compile 10's table row for row (0b now
      `33334444`: every byte written, as 0c and 0d), so the earlier 0b
      was the instrument. Conclusion: the chip's DQM inputs are never
      high while this bitstream runs; every other behaviour is by the
      datasheet. On the FPGA side the two pins are built, timed and
      placed as the working command pins are; the template's pins are
      MacPlus's and MacLC's, and both of those cores mask bytes through
      them from the CPU's data strobes (MacLC: `sdram_ds = {!_memoryUDS,
      !_memoryLDS}`) and boot System on this board. The one construction
      difference found: `sd_dqm` resets to 11 (DQM high through the
      power-up pause), an asynchronous preset, which the fitter packs
      into the I/O cell as an INVERTED register (the cell has only a
      clear); `cmd` is packed the same way and works, but never has to
      hold a lone one-clock high on a normally-low pin. The "Missing
      slew rate" note on the pins is generic (81 pins). The reader's
      `dqmread` was missing from its operation list on the first run and
      looped as a sample count (killed; fixed).

21. **The DQM pins: the reset-value experiment and the hardware
    cross-check (2026-09-27).** `sd_dqm` now resets to 00 and S_INIT
    raises it on its first clock (the chip's 200 us pause wants DQM high;
    one clock of low at the very start, under INHIBIT, is nothing). This
    removes the inverted packing and is the only FPGA-side change left to
    try; benches 184 / 17. **Daniel was asked, in parallel, to run his
    MacPlus core on this board now** (it masks bytes through the same
    pins and boots System only if they work) **and to say which SDRAM
    module is fitted.** If MacPlus runs and compile 12 still shows every
    `dqmread` row unblanked, the remaining suspects are outside this
    repository's reasoning so far (the pin assignment as the board
    actually has it, a module whose DQM traces differ from the working
    cores' assumptions, the I/O cell) and the next instrument is a
    bitstream that drives the two pins from a plain counter, read by a
    meter.
    - **Daniel's answers (2026-09-27): MacPlus runs as usual on this
      board, and the last time the SDRAM was suspected he ran the Ramtest
      core, which found nothing.** The module and the traces are good;
      our bitstream is what leaves the pins low. The differences between
      what the working cores put on those two pins and what we do, each
      checked: (1) their DQM register (the address register's bits 12:11)
      resets synchronously and packs plain, ours resets asynchronously
      to 11 and packs inverted - compile 12's change; (2) theirs also
      drives A12:A11, ours is dedicated - no reason known; (3) theirs
      holds the level for several clocks after the WRITE, ours one -
      **tested on compile 11 with the raw port: DQM held high on clocks
      2-5 (42 ns) around a single WRITE still wrote the word, and around
      a READ still returned both words; closed**; (4) the chip's clock
      edge relative to the launch differs - cannot single out DQM on its
      own; (5) drive strength and slew - identical in the fit (16 mA,
      slew 1, on DQMH, DQML and nWE alike); closed.
    - **The meter's test, built:** `dbg_dqm_force` on the controller holds
      both DQM pins high; the poke's PPOK bit 37 drives it while the
      machine is held; `read_probes.tcl dqmforce 1` sets it and leaves the
      hold up, `dqmforce 0` releases. With it on, the chip's LDQM and UDQM
      pins (15 and 39 of the TSOP-54; the datasheet's pin table) read 3.3
      V if the FPGA drives them and near 0 V if it does not - the one
      measurement no report can substitute. Benches 184 / 17; the reader's
      operations run off the board. (A reader gotcha, twice now: a new
      operation's name must be in the `lsearch` list at the top of
      read_probes.tcl or the script takes it for a sample count and loops.)
    - **The module (Daniel, 2026-09-27): 128 MB** - two AS4C32M16SB, the
      second chip selected through nCS as an address bit (the Quadra 800
      core's `SDRAM_nCS = chip`); DQML/DQMH reach both chips. Our
      controller holds nCS low and so initialises and uses chip 0 alone,
      the 32 MB the design assumes; chip 1 is untouched until the 128 MB
      option of 1.5 and 1.11 is built. MacPlus and Ramtest run clean on
      it, so its DQM traces are good.
    - **Compile 12 needs Daniel's go-ahead.** On the board: `dqmread`
      first (the reset-value change alone may end this); if still
      unblanked, `dqmforce 1` and the meter on pins 15 and 39.
    - **Compile 12 (Daniel's go-ahead, tag `01dc958e`, archived
      `MacSE30_01dc958e_dqmreset.rbf`):** every corner met as compile 9
      (worst non-capture path 0.749); `sd_dqm` packed plain in the DQML/DQMH
      output cells. The fit also shows `cmd[3:0]` and `dq_oe` packed
      inverted and working, so the inversion was never a sufficient
      explanation. **On the board: PBLD 01dc958e, the CPU in the serial
      test loop as on compile 11, and every `dqmread` row unblanked.** No
      meter is available (Daniel, 2026-09-27); item 22 made one unnecessary.

22. **The mask is on A12/A11 (2026-09-27).** Item 21's difference (2) was
    the answer. **The MiSTer SDRAM modules wire each chip's UDQM/LDQM to
    the A12/A11 traces** - Sorgelig shorted them to save two pins (MiSTer
    forum thread "For the SDRAM add on, why DQMH and DQML connected to A11
    and A12?"; the module's own design files are not in
    `MiSTer-devel/Hardware_MiSTer`) - so the chip's mask on every clock
    is whatever A12:11 carry, and the FPGA's DQM pins reach nothing. Every
    working core's code says the same: MacPlus, MacLC and MacIIvi
    `assign sd_dqm = sd_addr[12:11]`, the Quadra 800 and the IIgs
    `{SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11]`, and Minimig, whose
    `sd_dqm` is a register of its own, also loads the mask into
    `sd_addr[12:11]` at its column command. Our controller drove A12:11 =
    00 on every READ and WRITE, which explains every DQM reading on the
    board at once: compile 9's doubled ROM (the burst's masked second beat
    written), compile 10's ignored byte masks, item 21's held mask, and
    compiles 11 and 12's masked reads returning both words - while the FPGA's
    DQM pins did exactly as told. (Item 21's note that DQML/DQMH "reach
    both chips" was an assumption, and wrong.)
    - **The controller:** the mask rides A12:11 - `~be` on each CPU WRITE's
      clock, 00 on the download's and the training's WRITEs and on every
      READ, 00 on NOPs by default, 11 through the power-up pause (LOAD
      MODE's value overrides it on its clock); the raw port's per-clock
      schedule goes out on A12:11; `dbg_dqm_force` holds A12:11 high except
      into a mode register (every write ignored, every read blanked, so a
      peek under it reads the floating bus - the electronic version of the
      meter). `sd_dqm` copies A12:11, as the other cores' does, for a
      module that uses the DQM pins. A column address is ten bits at most,
      so A12:11 are free on a column command; on an ACTIVE they are row
      bits, and no data beat here is under an ACTIVE's clock (a read's
      beats take their mask from the READ's clock and the next, a
      single-location write from its own).
    - **The benches model the board:** the chip model's DQM input is now
      `addr_c[12:11]` in both benches. Doing that exposed **a model bug**:
      a read word took its mask from the clock two before its LAUNCH edge,
      i.e. one clock before the datasheet's ("the read data appears on the
      DQs subject to the values on the DQM inputs two clocks earlier",
      AS4C32M16SB; W9825G6KH: "Hi-Z (with latency of 2)"). It was right
      until item 15 moved the launch one edge earlier and nothing had put a
      mask near a read since; with the board's wiring an ACTIVE's row bits
      on the clock before a READ blanked the first word. Fixed: the word
      launched at edge e takes the mask sampled at e-1. **The fixed,
      board-wired model against the committed controller fails exactly the
      board's three ways and nothing else** - the byte-enable writes (5),
      the burst's masked second beat and the masked clock-4 write (2), the
      masked READ (1): 8 of 184 - while the training, the reads, the
      download and the timing checks pass, as on the board. The new
      controller: sdram 184 + the three trainings, machine 17 (the ROM into
      the boot chime; prediction PIFA/PLAS 40805f48, PACT 9139 and counting).
    - **Compile 13 needs Daniel's go-ahead.** On the board, expect:
      `dqmread` rows 2 and 3 blanked (the READ's clock masks the first word,
      the next the second; the "clocks 3 and 4" row the second word only),
      `dqmtest` byte masks honoured, and the machine past the serial test
      loop - the ROM's byte-write RAM test (`$408032A0-3304`) passing.
    - **Compile 13 (Daniel's go-ahead, tag `b9e9d6a1`, archived
      `MacSE30_b9e9d6a1_dqma12.rbf`):** every corner met (worst non-capture
      path 1.022; the capture as compile 9); `sd_addr[11]`/`[12]` duplicated
      into the A and DQM output cells. **THE BOARD: THE CHIP SEES THE MASK.**
      `dqmread`: unmasked `97221136`; clocks 2 and 3 `FFFFFFFF`; clock 2
      `FFFF1136`; clock 3 `97229722`; clocks 3 and 4 `97229722` - each row as
      predicted. `dqmtest`: rows 0a-0d (the CPU port's byte enables) and
      10-13 (single-location mode) all as the datasheet. Rows 5 and 6
      (burst-write mode, first beat masked) read `5555` where the datasheet
      column says `AAAA`: the instrument, not the chip - in burst mode the
      CPU port's pre-write of `AAAA5555` is two WRITEs whose second's own
      second beat wraps onto the even column on a clock whose A12:11 are 00,
      writing the bus's `5555` there (the wrap the model taught in item 19);
      rows 5 and 6 are the only ones that read the even word's old value.
      **But the machine still ends in the serial test manager** - after a
      fresh reset, PIFA/PLAS in `$40803200-$40803304`, no halt, no bus
      error, overlay 0. The code (disassembled): `$40802EDC` is the test
      manager's command loop, polling the SCC at `$50F04000` for a command
      (the "*APPLE*" greeting at `$40803288`), entered after a failed
      start-up test with the failure in D6 and the flags in D7 - the Sad
      Mac's code, which nothing here can show yet (no video before the
      test passes; the machine bench stops at its first loop, cycle 9139,
      with unwritten RAM reading X). So the byte mask was a real fault and
      is fixed, and a different test fails on the board. **Next: read D6
      and D7** - the failure code names the test.

23. **D6/D7, and the two faults the ROM's RAM test found (2026-09-27).**
    Daniel's go-ahead: build the D6/D7 probe, compile when ready.
    - **The probe:** the kernel already had `debug_regfile_d6/d7` (the
      register file is flip-flops, not block RAM - the map report infers
      no RAM for it - so the tap is wiring); `tg68k.v` brings them out as
      `dbg_d6/dbg_d7`, the machine as `dbg_regs` {D6, D7}, the deck as
      **PREG** (64 bits, one register stage on clk_sys), and
      `read_probes.tcl` prints `PREG D6=... D7=...`. The machine bench
      prints them with its prediction.
    - **The bench said D6 = X.** The ROM had put a value read from never-
      written RAM into D6, where the board reads real bits - so the bench
      had been passing the RAM tests on X. The chip model gained
      `FILL_UNWRITTEN` (a never-written word reads as a fixed pseudo-
      random value chosen on its first read and kept, as a real chip's
      power-up contents; the machine bench sets it, the SDRAM bench keeps
      X). With it the bench failed as the board does: D6 = `7D3DD59F` in
      the RAM data-bus test at `$408036D2` (`MOVEM.L D0-D1,(A0)`, then
      `EOR.L` each register back into memory and `OR` the result into D6,
      256 patterns). A trace of the bus cycles at `$0` found two faults:
    - **Fault 1: every RAM write was a read.** `se30_machine.v` had
      `mem_we = ram_req && ram_we`; the controller decides read or write at
      the cycle's START (ECS, S0) - `a_we <= we_q` - where R/W is valid
      but `ram_req` (AS*, S1) is not yet, so `mem_we` was always 0 there:
      the controller ran a READ, acknowledged the cycle, and the data was
      lost (the trace: `we 1` requests, `cmd 0101` at the chip). Since the
      tree was cut (`e6e2edb`). Fixed: `mem_we = !rom_early && ram_we` - a
      ROM write stays a no-op (GLUE acknowledges it). The SDRAM bench never
      saw it: it drives the controller's port directly, with R/W valid at
      the start.
    - **Fault 2: MOVEM on the 32-bit port.** With writes landing, the trace
      showed `MOVEM.L D0-D1,(A0)` writing D1 at A+2 (a long at 2, then a
      word at 4). In the ALU (`TG68K_ALU.vhd`) the step to the next
      register, taken on a register's LAST beat (`long_start = '0'` there
      is `NOT memmaskmux(3)`), was +2 up and -6 for a long down: right for
      the 16-bit shape, whose long ends with two bytes at A+2, wrong on the
      32-bit port, where the long is one beat at A. The rule, in the ALU
      now: **up, the bytes the last beat moved (`beat_step`); predecrement,
      2 x size - those bytes** - the 16-bit constants are its special case,
      and odd addresses need nothing more. mikej's unaligned-MOVEM patch
      (the 68000 shape's hold on a one-byte beat) stays for CHK2
      (`check_aligned`) only. `sim/kernel_bus` had no MOVEM; it now has
      MOVEM.L and MOVEM.W up, MOVEM.L -(An) and (An)+, at offsets 0-3,
      against the same UM 7.2 oracle. **Before the fix the 32-bit run
      failed at the first MOVEM.L's second register (`$2002` for `$2004`)
      and the 16-bit run at odd offsets; after it: port 32 181 checks, port
      16 200 (242 with the five-byte fields), port 8 328, all PASS.**
      `sim/kernel_upstream`: the same verdicts as before (14 pass;
      `tb_stack_frame_push`, and the two DIVU saved-SR rows of 1.12's
      hunk).
    - **The machine bench** (fill on, both fixes): 804 RAM writes, D6 = 0,
      the run ending in the data-bus test's loop at cycle 3815 (its loop
      detector's 3000 cycles; the RAM tests run far longer than the bench
      can). Its last check was "the loop is the chime's" - true only
      because X let the ROM past its failed tests; it is now "D6 = 0: no
      start-up test has failed". 17 checks PASS; sdram 184 + trainings.
      Prediction: PIFA/PLAS in the RAM tests, PREG D6 00000000.
    - **Compile 14 (Daniel's go-ahead given with the probe):** on the
      board, PREG first - D6 = 0 and the CPU past the serial test manager
      is the fix confirmed; D6 nonzero names the next failing test.
    - **Compile 14 (tag `045df9e6`, archived `MacSE30_045df9e6_preg.rbf`):
      every corner met (worst non-capture path 0.687; the capture as
      compiles 12-13). THE BOARD: THE RAM TESTS PASS.** PREG D6 = 0,
      D7 = 0; no halt, no bus error; **the ROM re-sized RAM (PVIA
      `ramsiz` 01, from the 11 of its prelude)**; VIA1 IFR bit 1 set (the
      60 Hz CA1 flag; IER still 0 - the VIA initialisation at `$408006F2`
      comes next). The CPU loops at `$408006C0-$408006E0` touching
      `$50F17000`/`$50F17C00`/`$50F17E00`: the **SWIM's mode-set loop**
      (`$408006AA`: the SWIM at `$50F1C000` or `$50F16000`; `$1000` motor
      off, `$1A00`, read the status at `$1C00` - loop while bit 5 (enable)
      is set, done when `status & $17 = $17`, else write `$17` to the mode
      register at `$1E00` and try again). With no SWIM the status never
      reads the mode back, so this is where a machine without its floppy
      controller must stop - not a fault. **Section 3.8's SDRAM work is
      done; the next device the ROM needs is the SWIM**, which (like the
      ASC, SCC, SCSI, ADB and RTC) is unwritten and is written from its
      documentation first.

Then Section 4, the VIAs, documentation first: Apple's VIA cell
specification (Nov 1989), the R65C22 data sheet, the *Guide*'s bit tables
(2.7), and only then the donor `via6522.sv` (MacLC) and `via6522.vhd`
(MacPlus, Gideon's) assessed against them. **Written 2026-09-27.**

# Section 4 - The VIAs

Opened 2026-09-27, after 3.8 item 17 (the ROM's checksum loop ran to its end
on the board through the SDRAM path; the machine then halted where a
machine with no VIAs and no writable RAM must). This is the first
peripheral section, and 3.6's ladder says what it owes: its own bench at
rung 2, the machine bench extended at rung 3, and the ROM one step further
on the board - the VIAs and RAM sizing, with the mirror rule's acceptance
test (2.11.6) inside it. Written before any RTL, documentation first, as
item 17 asked: Apple's VIA Cell specification, the Rockwell 6522 data sheet,
the *Guide*'s chapter 4, the schematic, and the ROM itself; the donor VIAs
(MacLC's `via6522.sv`, MacPlus's `via6522.vhd`, both Gideon Zweijtzer's)
were read only after those and are cross-checks, not sources
(`feedback-se30-specs-from-documentation`). Nothing here infers the ASC,
SWIM, SCC, SCSI, ADB transceiver or RTC; where the ROM's start-up needs a
level from one of them, 4.7 says what the level is and why.

## 4.1 Sources, and their standing

| source | what it is | standing |
|---|---|---|
| *Guide to the Macintosh Family Hardware* 2e, chapter 4 (pp. 148-186) and p. 149's paragraph on VIA timing | the bit tables (4-5, 4-9, 4-10, 4-14, 4-15, 4-18, 4-20 to 4-27), the timers' rate and use, the interrupt lists, and the one sentence anyone has on how GLUE times a VIA access | **primary** |
| *VIA Cell Preliminary Specification*, Apple IC Technology, 29 Nov 1989 (`VIA_Cell_Preliminary_Specification_Nov1989.pdf`, 25 pp., OCR text in `VIA_Cell.txt`) | Apple's gate-array re-implementation of its own **6523** VIA for later ASICs. Its overview says: "Much of the text of this document is identical to that found in the original 6523 VIA spec. All ways in which the VIA Cell differs from the 6523 VIA have been noted ... by enclosing the descriptions in a box." So the un-boxed text **is the 6523's specification**, and each box says what the 6523 does that the cell dropped | **primary for the 6523**, read with the boxes inverted |
| Rockwell *R6522 Versatile Interface Adapter* data sheet, Oct 1978 (`R6522_..._Oct1978.pdf`, 6 pp., scanned; page images in `Docs/r6522/`) | the register-select and timer read/write tables, the T1 mode table, the PCR CA2/CB2 mode table, the ACR shift-register mode table, and the NMOS part's timings | **primary for the 6522 baseline** the 6523 is compatible with; its tables fill what the cell spec's boxes only name |
| `se30.pdf` sheet 4 "VIA1 & VIA2 (65C22), RTC, Apple Desktop Bus" (`se30schems/Apple/SE30_P4.GIF`) | UK12 = VIA1, UK11 = VIA2, both drawn as **65C22** in the 44-pin (PLCC) pinout; every net name of 2.7's table; the RTC (UK4, 32.768 kHz) and the ADB transceiver (UL11, clocked by `C3M`) | **primary for the wiring** |
| `Mac_IICX_BOM.pdf` line 296 | `338S6523 ... IC,CUSTOM,65C22 VIA,PLCC`, quantity 2 | the IIcx's BOM (a proxy, 2.1), naming the part the schematic draws: Apple's custom 6523 is a 65C22-class part in PLCC |
| the ROM (`97221136`), disassembled by `scripts/se30_rom_mmu.py dis` | every VIA register the start-up code touches, in what order, and what it expects back | **primary for what the machine must do**; 4.6 |
| MacLC `rtl/via6522.sv`, MacPlus `rtl/via6522.vhd` | Gideon's 6522, ported and patched by other projects | cross-checks for corner cases the documents leave to the reader; **no line is lifted** (`feedback-independent-core-own-the-kernel`, `never-cite-own-output-as-precedent`) |

What is *not* in hand: a 65C22 or 6523 data sheet with the CMOS part's
own numbers (bitsavers has no Rockwell R65C22, no VTI, no GTE sheet); the
1978 sheet is the 1 MHz NMOS part. Where a number below depends on that
(only the E phase widths in 4.4) it is marked OPEN and bounded by the
*Guide*'s own figure.

## 4.2 The chip: Apple's 6523, a 65C22

The *Guide* (p. 148): "The classic Macintosh computers use a Rockwell or
VTI 6522 Versatile Interface Adapter integrated circuit. Other Macintosh
computers use an Apple custom version of that IC. The Apple custom VIA is
fully software compatible with the standard Rockwell or VTI 6522 VIA. The
Macintosh SE/30 and Macintosh II family use two Apple custom VIAs called
VIA1 and VIA2." The custom part is the **6523** (the cell spec's name for
it; the IIcx BOM's `338S6523`, "65C22 VIA, PLCC"); the schematic draws
both as 65C22s. So the SE/30's VIA is a **full 6522** in every feature the
cell spec's boxes say the cell dropped: CA1/CB1 input latching, the CA2/CB2
handshake and pulse output modes, Timer 2's PB6 pulse counting, Timer 1's
PB7 output, all four T1 modes, and the internal shift-register clocks - and
the cell's un-boxed text is the 6523's own description of the rest. The
cell spec's overview also says which of those the Macintosh software base
uses ("all 6523 VIA features which have been used on Macintoshes from the
SE onward"): the cell kept T1 one-shot and free-run, T2 one-shot, the two
external-clock shift modes, and the four control lines as edge inputs. The
SE/30's VIA2 additionally uses T1's PB7 output (4.6: the ROM sets ACR
`$C0` on VIA2 and the *Guide*'s Table 4-15 names PB7 `v2VBL`, "driven by
timer T1"), which the cell dropped because the machines it went into
emulate VIA2 elsewhere.

### 4.2.1 Reset

Cell spec 3.0, un-boxed: `Reset_` "clears all registers ... and
initializes all state machines. The Shift Register counter is initialized
but the actual shift register itself is not reset ... The T1 and T2
counters and latches are also not cleared upon reset. All internal
registers (ACR, PCR, DDRA, DDRB, ORA, ORB, IER, IFR) are all cleared to 0.
All chip operations are disabled while Reset_ is low." The only boxed
difference is the cell clearing the shift register's ninth bit. For the
RTL: those eight registers reset to `$00`; the shift register and both
timers' counters and latches have no documented reset value, so they take
an FPGA power-on value (`$FFFF` for the timers, `$00` for SR - a choice,
unobservable: the ROM loads every timer before it reads one, 4.6).

**DDRA = 0 at reset is what makes overlay and the box ID work** (2.11.6,
4.5): every port-A line is an input until the ROM says otherwise, and an
undriven line reads high.

### 4.2.2 Registers

Cell spec Figure 2 and the R6522 operation summary; `RS3-0` are `A12-A9`
on the SE/30 (sheet 4: `RS0` = `A(9)` ... `RS3` = `A(12)`), so register n
is at base + `$200 * n` - the `$50F00000 + $1E00` the ROM uses for ORA is
register 15. The 8-bit data bus is `D31-D24` (2.11.1; the *Guide* p. 158
says "upper byte" for the 68000 machines and GLUE puts the SE/30's devices
on the same lane).

| RS | write | read |
|---|---|---|
| 0 | ORB; clears IFR4, and IFR3 unless CB2 is an "independent" input (PCR) | IRB: pins for input bits, ORB for output bits; same flag clears |
| 1 | ORA; clears IFR1, and IFR0 unless CA2 independent; the CA2 handshake/pulse output responds | IRA; same |
| 2 | DDRB (1 = output) | DDRB |
| 3 | DDRA | DDRA |
| 4 | T1LL (a write to T1CL "is effectively a load to T1LL") | T1CL, the low counter; **clears IFR6** |
| 5 | T1LH := data, then **both latches into the counter, count starts, IFR6 cleared**, the one-shot re-armed | T1CH |
| 6 | T1LL | T1LL |
| 7 | T1LH; clears IFR6; **no** transfer | T1LH |
| 8 | T2LL | T2CL; **clears IFR5** |
| 9 | T2CH := data, T2LL into T2CL, count starts, IFR5 cleared, the one-shot re-armed | T2CH |
| 10 | SR; clears IFR2, resets the shift counter | SR; same |
| 11 | ACR | ACR |
| 12 | PCR | PCR |
| 13 | IFR: each 1 clears that flag; bit 7 ignored | IFR; bit 7 = IRQ (any flag with its enable) |
| 14 | IER: bit 7 = 1 sets each 1 in bits 6-0, bit 7 = 0 clears them; 0s untouched | IER; **bit 7 reads 1** |
| 15 | ORA, "no effect on handshake" and no flag clears | IRA, the same |

### 4.2.3 Ports

Cell spec 6.0-6.4 (un-boxed = 6523): a DDR bit of 1 makes the line an
output driven by the OR flip-flop; **"Upon a write operation to one of the
ports, data is written into only those port bit positions which have been
programmed as outputs. Should data be written into bit positions
corresponding to lines which have been programmed as inputs, the Output
Register flip-flops will be unaffected."** A read returns the pin for an
input bit and the OR flip-flop for an output bit (the 6523's only
ambiguity, per the box, is that a *loaded* output line may read its
actual level; a model has no loading, so OR it is). That write rule is
the one place this section has a single documentary source for a
behaviour software could see; 4.10 records it, and 4.6 shows the ROM's
sequences do not depend on it either way.

Input latching (ACR0 for A, ACR1 for B; a 6522 feature the cell's box
says it dropped): with the latch enabled, IRA holds the pins as they were
at CA1's active edge (IRB at CB1's) until the next such edge; disabled,
IRA is the live pins. From the R6522 sheet's feature list and T_IL
("peripheral data valid to CA1 or CB1 active transition"); the mechanism
is the 6522's and the ROM never enables it (its ACR writes are `$00` and
`$C0`, 4.6), so it is implemented as stated and benched lightly.

CA1 and CB1 are edge inputs; CA2 and CB2 are edge inputs or outputs by
PCR (R6522 CA2 table, CB2 the same at bits 7-5):

| PCR 3-1 | CA2 |
|---|---|
| 000 | input, negative edge sets IFR0; a read or write of ORA clears it |
| 001 | independent input, negative edge; ORA access does not clear |
| 010 | input, positive edge |
| 011 | independent input, positive edge |
| 100 | handshake output: low on a read or write of ORA, high on CA1's active edge |
| 101 | pulse output: low for one E cycle after an ORA access |
| 110 | manual output, low |
| 111 | manual output, high |

The SE/30 uses CA2 as an input on both VIAs (RTC 1 Hz; SCSI DRQ) and CB2
as VIA1's ADB data line under the shift register, VIA2's SCSI IRQ input
(4.5). The output modes are implemented from the table because the chip
has them; nothing on this board exercises them.

### 4.2.4 Timers

Both count `E` (the *Guide*, p. 182: "the timer counter is decremented
once every 1.2766 µs"; cell spec 7.0: "decrements at the C783K clock
rate").

**T1** (cell spec 7.0-7.2, R6522 tables). Two latches and a 16-bit counter.
A write to T1CH loads both latches into the counter and starts it; the
counter decrements once per E cycle; on passing zero it reads `$FFFF`, and
that is the time-out: IFR6 is set (if armed), and one E cycle later the
latches are transferred back into the counter, which continues - "T1 is
always running". So the first time-out comes N+1 cycles after the load
and, in free-run, each following one **N+2** after the last, the cycle
spent at `$FFFF` included (the bench found this in the text, 4.11 item
2). In one-shot mode (ACR6 = 0) only the first time-out after
a T1CH write sets IFR6; in free-run (ACR6 = 1) every time-out does. "Timer
1 times out N+1 cycles after loading with the value N ... loaded with
$0003, it will set the interrupt flag 4.5 C783K cycles later" - the half
is the write landing in the middle of an E cycle. PB7 (ACR7 = 1; the
R6522 T1 mode table): one-shot gives "a single interrupt and an output
pulse on PB7 for each T1 load operation", free-run "a square wave output
on PB7" - PB7 goes low at the T1CH write and high at the time-out in
one-shot, and inverts at every time-out in free-run. **The ROM sets DDRB7
itself before using this** (4.6), so whether ACR7 alone would turn PB7
into an output is unobservable here and DDRB7 governs in the RTL.

**T2** (cell spec 8.0-8.2, R6522 tables). A write-only low latch, a
16-bit counter. A write to T2CH loads the counter from the latch and the
data and arms it; the counter decrements per E cycle (ACR5 = 0) or per
negative edge on PB6 (ACR5 = 1, the pulse-count mode - unusable on the
SE/30, where PB6 is an output, *Guide* p. 181, but implemented); on
passing zero it sets IFR5 once, then "simply rolls over from $FFFF to
$FFFE, and then $FFFD, etc." until re-armed by another T2CH write. Same
N+1.5 rule.

The *Guide* (p. 182) on who uses what: VIA1 T1 is the Sound Driver /
Sound Manager's, VIA1 T2 the Disk Driver's (through the Time Manager),
**VIA2 T1 generates the VBL to VIA1**, VIA2 T2 unused. The ROM's numbers
are in 4.6.

### 4.2.5 The shift register

Cell spec 9.0-9.3 and Figures 14-15 (the external-clock modes, un-boxed
detail); the R6522 ACR table for the others. Nine flip-flops: SR[7:0] and
a ninth, SR[8], that is what CB2 shows when shifting out; "SR[7] is
shifted into SR[8] upon a shift clock (CB1) active edge. Thus, after
parallel loading the Shift Register with data, one shift must be done
before any of the just-loaded data will appear on CB2out", and bit 7 "is
simultaneously rotated back into bit 0". Shifting out (ACR 4-2 = 111)
happens on CB1's **falling** edge, shifting in (011) on CB1's **rising**
edge, bits entering at bit 0. An 8-count modulo counter sets IFR2 after
eight shifts and does not stop the shifting; reading or writing SR clears
IFR2 and restarts the count. Mode 000: disabled, SR readable and
writable, IFR2 never set (but not cleared). The cell's box says the 6523
sampled CB1 on E's edges - a rate limit the FPGA can ignore, since the
ADB transceiver's clock is tens of kHz.

The five internal-clock modes (001 in under T2, 010 in under E, 100
free-running out under T2, 101 out under T2, 110 out under E) exist in
the 6522 and have one line each in the R6522 table. They are implemented
to that line - the shift clock is T2's low-byte time-out or E, CB1 is
driven as the clock output in the out modes, 100 never sets IFR2 - and
recorded as datasheet-summary only: no Macintosh from the SE on uses
them (the cell spec's rationale for dropping them), and the bench holds
them only to the table.

### 4.2.6 Interrupts

Cell spec 10.0 and Figures 9-10, all un-boxed: IFR bits 0-6 are CA2, CA1,
SR, CB2, CB1, T2, T1; bit 7 = OR of (IFRn AND IERn), not a flag, "the
value of bit 7 on writes to the IFR has no effect"; IER read gives bit 7
= 1; `IRQ_` is low while bit 7 is 1. The cell's box: the 6523 sets the
flags asynchronously and the cell takes up to 210 ns; the RTL sets them
on the C16M grid, well inside either. To GLUE, `VIAIRQ1*` and `VIAIRQ2*`
are the level-1 and level-2 requests (2.11.5), held until the flag is
cleared.

## 4.3 The bit assignments, with 2.7's open cells closed

2.7's table stands. The *Guide*'s tables close what it left to "verify
on the scan": **VIA2 PB3** (`vFC3`) is "tied low (Macintosh SE/30)" and
**VIA2 PB6** (`v2SNDEXT`) is "tied low (Macintosh SE/30)" (Table 4-15);
VIA1 PB6 is `vSyncEnA`, "0 = vertical synchronization interrupt enabled
(Macintosh SE/30 only)", an output (Table 4-14); VIA1 PA6 is `vPage2`, an
output on the SE/30 and `CPU.ID1` in on the II/IIx (Table 4-5). The
consequence for the box ID is in 4.6.

The lines with nothing on the board to drive them - VIA1 PA0-2 and PB7 to
the PDS, VIA2 PB4-5 (`TM0A*`, `TM1A*`) to the PDS, VIA2 PA0-4 (`IRQ*(1:5)`)
to the PDS - and the ones whose driver is a later section (VIA1 PA7
`SCCWREQ*`, PB0 RTC data, PB3 `ADB-INT*`, CA2 `RTC-1HZ`, CB1/CB2 the ADB
pair; VIA2 CA2 `SCSIDRQ`, CB1 `SNDINT*`, CB2 `SCSIIRQ`) all read the
levels of 4.7.

## 4.4 The bus: how GLUE times a VIA access - 2.11 row 3 corrected

The *Guide*, p. 149, on the SE/30 and the II family specifically: "the
general logic circuits synchronize the VIA clock signal with the accesses
of the main processor so that the main processor can make VIA accesses
without any delay. As a result, a VIA access for these computers takes an
average of 0.5 µs as compared to 1.0 µs for the Macintosh SE and classic
Macintosh. The general logic circuits maintain an average frequency for
the E clock of 783.36 kHz." And p. 148: the SE/30's GLUE generates "both
the clock signal to the VIAs and the VIA device-enable signals".

That is not the mechanism 2.11 row 3 built. Row 3 has the access wait for
the next E-high phase of a free-running E - the 68000 machines' scheme,
"12 to 32 clocks by alignment", 1.4 µs on average. The *Guide* says the
SE/30's GLUE moves **E** to the access instead, and gives two numbers
that constrain any implementation: an access averages **0.5 µs**, and E
**averages** 783.36 kHz - the word "average" being the admission that E
is not a clean divider on this machine. There is still no SE/30 source
for GLUE's state machine (2.11's standing caveat), so what follows is a
contract that meets both numbers and the 6522's own requirements, marked
OPEN where a number is chosen.

**The 6522's requirements** (R6522 read/write timing): `CS` and `RS`
valid before E rises (T_ACR, 180 ns on the NMOS part), read data valid
T_CDR after the rise, write data latched at the fall (T_DCW before it),
and a minimum E-high width T_C. The NMOS 1 MHz part needs 470 ns high;
a 0.5 µs *average access* is only possible with a part rated well above
that, which the 65C22 pinout and the "65C22" label say this is. **The
minimum phase width used below, 4 C16M clocks (255 ns), is OPEN**: it is
what makes the *Guide*'s average come out, and no data sheet in hand
gives the 6523's figure.

**The contract.** GLUE keeps a free-running **reference** - a 20-clock
counter, E nominally high for 10 and low for 10 - and the E it actually
drives is that reference displaced by a bounded phase shift:

1. A VIA access is seen at the clock GLUE first samples `AS*` low with a
   VIA decode (clock A). The select rises with it (`CS` is up before any E
   rise that follows).
2. If E is low at A, having been low for L clocks: E rises at the first
   clock at or after A+1 by which the low phase has lasted at least 4;
   stays high for 4 clocks; the device strobe is the last of them; E falls;
   `DSACK0*` follows the strobe as row 3 has it. If E is high at A, having
   been high for H clocks: E falls at the first clock by which the high
   phase has lasted at least 4, then low for 4, then the same 4-clock
   high phase. Cycle lengths in the GLUE bench's convention (AS* low to
   DSACK* inclusive, plus S4/S5): **7 clocks when E was low with room,
   up to 16 when it was high and had just risen**, a mean of 10 over a
   uniform phase sweep (4.11 item 3) = 0.64 µs, against the *Guide*'s
   "average of 0.5 µs" - the 4-clock phase minimum, OPEN, is most of the
   gap.
3. **Each reference period has exactly one E rise**, nominally at its
   midpoint. An access may take it early - any time from the period's
   start, once E has been low 4 clocks - and a period whose rise has been
   taken does not rise again: after the access's 4-clock high phase E
   stays low until the next period's rise, which comes at its nominal
   time. So the phase shift is never more than half a period and is
   repaid by the very next rise, with no bookkeeping. A forced fall (E
   high at A) likewise only ends the current high phase early; the rise
   that follows is the next period's, taken at its earliest. (Written
   first as a shift counter worked off one clock per phase; replaced by
   this before the RTL, 4.11 item 3.)
4. **The bound follows:** over any window of 20N clocks E rises N ± 1
   times whatever the VIA traffic - the timers' rate is exactly C16M/20,
   which is what "maintain an average frequency of 783.36 kHz" has to
   mean for the Time Manager to keep time. A run of back-to-back accesses
   gets one access per period, the SE's rate, rather than E running fast.

Both VIAs share one E (sheet 4: `E` to both `PH0` pins), so a phase shift
for VIA1's access is seen by VIA2's timers too, and the bound is what
keeps VIA2 T1's 60.15 Hz honest.

What this changes: `rtl/se30_glue.v`'s E generator and VIA cycle
(`ecnt`, `via_armed`, `e_rise_next`, `e_fall_next`), 2.11 row 3's envelope
(now 7-14 clocks with the mean held, the old 12-32 kept only as the bound
of item 4), 2.11.7 item 1's "VIA envelope 12-32", and `sim/glue`'s item 5.
The device strobe and the byte lane are unchanged: one device cycle per
bus cycle, the byte on `D31-D24`, the strobe on E's last high clock, the
write latched there and the read captured there.

## 4.5 The wiring, as the RTL sees it

The pin of a port line is the OR flip-flop when its DDR bit is 1 and the
external driver when it is 0; with no external driver the pin is high
(the 65C22's undriven level - the mechanism 2.11.6 already relies on for
`OVERLAY`, and which 4.6 shows the box ID relies on too). The machine
module computes each pin that way and hands it back to the VIA as its
input, so a read of an input bit is the pin and a read of an output bit
is the OR - exactly 4.2.3 - and the consumers of a VIA output (GLUE's
`OVERLAY` and `RAMSIZ`, the video's `page` and `VSYNCEN*`, VIA1's CA1 from
VIA2's PB7) read the pin, never the register.

| VIA1 | pin | source / sink |
|---|---|---|
| PA7 | in | `SCCWREQ*`: 1 until the SCC section (open-drain, pulled up) |
| PA6 | out (page) | `ALTVID` to the video: pin, 1 undriven = main buffer (2.10) |
| PA5 | out | `HDSEL` to the SWIM section |
| PA4 | out (overlay) | `OVERLAY` to GLUE: pin, 1 undriven = ROM at 0 |
| PA3 | out | `SYNC` to the SCC section |
| PA2-0 | in/out | `V1PA0-2` to the PDS: undriven, read 1 |
| PB7 | in/out | `V1PB7` to the PDS: undriven, read 1 (the *Guide*'s `vSndEnb` "for software compatibility") |
| PB6 | out | `VSYNCEN*` to the video: pin, 1 undriven = disabled |
| PB5, PB4 | out | `ADB-ST1`, `ADB-ST0` to the ADB section |
| PB3 | in | `ADB-INT*`: 1 until the ADB section |
| PB2, PB1 | out | `RTC-CS*`, `RTC-CLK` to the RTC section |
| PB0 | in/out | RTC data: 1 until the RTC section |
| CA1 | in | `VBLK*` = VIA2's PB7 pin |
| CA2 | in | `RTC-1HZ`: held 1 until the RTC section (no edges, no 1 s interrupt) |
| CB1 | in | `ADB-SCLK`: 1 until the ADB section |
| CB2 | in/out | `ADB-DIO`: 1 in until the ADB section |
| IRQ | out | `VIAIRQ1*` to GLUE, level 1 |

| VIA2 | pin | source / sink |
|---|---|---|
| PA7, PA6 | out (ramsiz) | `RAMSIZ(1:0)` to GLUE: pins, 11 undriven |
| PA5 | in | `IRQ*(6)`: the video's slot-E interrupt latch (2.10, `irq6_n`) |
| PA4-0 | in | `IRQ*(5:1)` from the PDS: undriven, 1 |
| PB7 | out | `VBLK*`: T1's output under ACR7, else ORB7; to VIA1 CA1 |
| PB6 | in | `SNDEXT*`: **tied low** |
| PB5, PB4 | in | `TM0A*`, `TM1A*` from the PDS: undriven, 1 |
| PB3 | in | `V2PB3`: **tied low** |
| PB2 | out | `PWROFF` to the PDS (and the power section) |
| PB1 | out | `BUSLOCK*` to the PDS |
| PB0 | out | `CDIS*` to the CPU: the caches (1.15 item 9) - not wired until the caches exist |
| CA1 | in | `SLOTIRQ*` = GLUE's `slot_irq_or_n` |
| CA2 | in | `SCSIDRQ`: 0 until the SCSI section (active high) |
| CB1 | in | `SNDINT*`: 1 until the ASC section |
| CB2 | in | `SCSIIRQ`: 0 until the SCSI section (active high) |
| IRQ | out | `VIAIRQ2*` to GLUE, level 2 |

## 4.6 What the ROM does with the VIAs at start-up

Read from the disassembly (`scripts/se30_rom_mmu.py dis`; addresses are
the ROM's, base `$40800000`; the 24-bit addresses `$50F0xxxx` reach the
VIAs through 2.11.2's decode). In the order the machine meets them:

1. **The test manager** (`$40802A14`, reached from the reset entry
   `$4083F856` via `$40800096`): sets its own VBR (`$40802806`), reads
   `$58000000` (a bus error on this board, taken by its handler) and
   starts the tests. **First VIA access** (`$40802A52`): VIA1 **DDRA :=
   `$3D`** (PA5, 4, 3, 2, 0 out; PA6, PA7, PA1 in), then ORA read, bits 4
   and 3 cleared, written back: **overlay off, `SYNC` low**. This is the
   `wr $50F00600 3D` / `rd`/`wr $50F01E00` the machine bench logged as
   cycles 70-93 (3.8 item 8); after it RAM is at `$0`.
2. `$40802A76`: ORA bit 0 cleared and bit 1 read, then bit 0 set and bit
   1 read again - a strap test between PA0 and PA1 on the PDS ID lines. With
   PA1 undriven (reads 1 both times) it takes the normal path. **PA1 must
   read 1.**
3. `$40802AB0`: the ROM checksum (3.8 item 17's loop, `$408036EC`), then
   reads of the SCSI (`$50F10000`) and SWIM (`$50F16000` / `$50F1C000`)
   windows, whose bytes do not gate anything here.
4. **RAM sizing prelude** (`$4083F634` -> `$4083F8C8`): VIA2 DDRA read into
   D0, **DDRA |= `$C0`, ORA |= `$C0`** (`RAMSIZ` = 11: 64 MB banks), 128
   longword reads at 1 MB steps from `$00000000` (all inside the RAM
   region, so on this board they alias inside the 8 MB), DDRA restored to
   D0 (0 - the pins go undriven and still read 11), then the RAM tests
   proper. The test manager's timing base for the tests (`$40803456`):
   VIA1 **ACR := 0, IER := `$20`** (T2 disabled), **T2 := `$FFFF`**, then
   polls IFR bit 5 (`$40803478`).
5. `$40803502`: the RTC read by bit-banging VIA1 ORB (PB0 data, PB1 clock,
   PB2 `CS*`) - PRAM's start-up bytes. With PB0 reading 1 (4.7) the bytes
   come back `$FF`, which the ROM treats as an uninitialised PRAM.
6. **`RAMSIZ` from the sizing result** (`$408035B2`): VIA2 DDRA |= `$C0`,
   ORA := (ORA & `$3F`) | the table byte - the bits the *Guide*'s Table
   4-10 defines, so GLUE's bank rule is set from here on. **This write,
   and the size the ROM then records, is the acceptance test of 2.11.2's
   mirror rule** (2.11.6) and of 3.7's empty-bank question.
7. **The box ID** (`$4083F74A-$4083F79C`): `BTST #6, $50F01E00` (VIA1
   PA6), then VIA2 DDRB read, **bit 3 cleared** (PB3 made an input), `BTST
   #3, $50F02000` (PB3), DDRB restored; the index is 2 + 2*PA6 + PB3 into
   the table at `$4083F79E` = `FF 04 01 00 03 02`. With **PA6 undriven
   (1) and PB3 tied low (0)** the index is 4 and the box flag is **3**;
   the II/IIx wiring (`CPU.ID1` low, PB3 not tied) gives index 3 and flag
   0. So the SE/30 is identified by exactly the two levels 4.3 and 4.5
   record - a second witness, with `OVERLAY`, that an undriven port-A
   line reads 1.
8. **The VIA initialisation** (`$408006F2`, from the main start-up chain at
   `$4080009A`): VIA1 **ORA(15) := `$01`; DDRA := `$3F`; ORB := `$07`** (the
   RTC lines idle high, `CS*` off); **DDRB := `$87`** (PB7, PB2-0 out); **IER
   := `$7F`** (all disabled). VIA2: ORA read as a long and written back
   (four byte cycles at `$1E00-$1E03`, all register 15); **DDRA := `$C0`;
   ORB := `$05`** (`CDIS*` high = caches allowed, `PWROFF` high); **DDRB :=
   `$80`** (PB7 out); **IER := `$7F`**. The ORA-before-DDRA order on VIA1
   is where 4.2.3's write rule could show: PA0 ends up 0 under the
   documented rule, 1 under a store-everything rule; PA0 goes to an
   unread PDS strap, so nothing here sees the difference.
9. **The VBL** (`$4080074C`): VIA2 **ACR |= `$C0`** (T1 free-run with PB7
   output), **DDRB bit 7 set**, **T1 := `$196E`** (low byte first, then
   high - the *Guide*'s "write to the high-order byte last"). `$196E` =
   6510: the first time-out 6511 E cycles after the load, then one every
   N+2 = 6512 (8.313 ms, 4.2.4); PB7 inverts at each, and VIA1's CA1 sees
   its active edge every 13024 E cycles = 16.626 ms: the *Guide*'s
   "16.63 ms", 60.15 Hz. Then VIA1 **PCR &= `$F0`**
   (CA1 and CA2 negative-edge inputs, the CB bits kept) and **IER :=
   `$83`**: the VBL (bit 1) and the one-second (bit 0) interrupts enabled.
   From here the machine takes a level-1 interrupt 60 times a second.
10. **`TimeDBRA`** (`$40800560`): VIA1 **ACR bit 5 cleared** (T2 timed),
    **T2CH := `$FF`**, **IER := `$A0`** (T2 enabled), the level-1 vector
    (`$64`) pointed at `$408005A4`, interrupts opened, then **T2LL :=
    `$0F`, T2CH := `$03`** (783 counts, 1.0 ms) and a `DBRA` loop until the
    interrupt lands; the handler reads T2CL (clearing IFR5) and stores the
    loop count at `$D00` - the ROM's measurement of the machine's speed,
    which the Sony driver's delays use later. The same is done against the
    SCC window for `TimeSCCDB`. **VIA1 T2 and the level-1 path through
    GLUE must work by here**, and the number stored depends on E's rate
    and the CPU's, not on anything else.
11. Later, and not this section's concern: the interrupt dispatcher
    (`$40806244`: VIA2 IFR & IER, bit 7 forced, shifted to find the
    source), the power-off (`$408062EE`: `PWROFF` low), the shift-register
    ADB transactions, the RTC's clock.

**Where the machine bench found the ROM after all this (4.11 item 5).**
Steps 1-4 happen by bus cycle 152; the test manager's first RAM test
(`$40802B28`, over `$0-$400`) writes RAM at cycle 802; then the ROM
returns to the main start-up chain and, at `$408000D0`, calls the **boot
chime** (`$40805E4A`): the ASC's registers and wavetable are written
(`$50F14801`, `$807`, `$806`, `$802`, `$810-$81F`, the four channel
buffers) and a 30,001-sample tune is played by **software timing** - a
36-iteration delay loop per sample at `$40805F46-$40805F4A`, about 0.7 s
of machine time (the table at `$40805F78`). With no ASC the chime is
silent and harmless, and it is where the bench's loop detector stops:
`PIFA` sits at `$40805F48`/`$40805F4C` for the first second after boot.
The main RAM sizing (`$40802BBC`, which reads `RAMSIZ` back from VIA2 ORA
to index the size table at `$408036BA`), the VIA initialisation of step 8
and the VBL of step 9 all come after the chime, so they are the board's
to show, through `PVIA` and `PIRQ`.

**What the machine bench can reach.** Steps 1-4 happen within a few ms
of machine time; the RAM tests over 8 MB take of the order of a second,
and steps 6-10 lie beyond them. ModelSim gives 215 µs in 9 s (3.7), so
the bench holds steps 1-4 and the start of the RAM tests, and predicts the
probes there; the rest is the board's (4.9).

**The screen is the board's verdict.** Once RAM is up the ROM draws: the
Sad Mac with its code if a test fails (the ROM's code table for this test
manager is at `$4083F8FC`; to be read when a code appears, not guessed),
the flashing question-mark disk when it finds no boot device. Both go
through the video of Section 2 and the slot driver 2.10 already benched.
So the target for rung 6 is a picture - and with the VBL running, a
question mark that flashes.

## 4.7 The stand-ins: what is not there yet, and how it reads

Each of these is a later section's; here only its idle level, chosen so
the ROM's start-up sees an absent, not a broken, device:

| line | level | why |
|---|---|---|
| VIA1 PA7 `SCCWREQ*` | 1 | open-drain from the 8530, pulled up; no request |
| VIA1 PB0 RTC data | 1 | open-drain line, pulled up; the ROM reads PRAM as `$FF` and re-initialises it |
| VIA1 CA2 `RTC-1HZ` | 1, no edges | no one-second interrupt; the clock does not tick (the RTC section) |
| VIA1 PB3 `ADB-INT*` | 1 | no ADB service request |
| VIA1 CB1 `ADB-SCLK` | 1, no edges | the transceiver never clocks the shift register: an ADB command times out in the driver |
| VIA1 CB2 `ADB-DIO` (in) | 1 | idle |
| VIA2 CA2 `SCSIDRQ` | 0 | no DMA request (active high) |
| VIA2 CB2 `SCSIIRQ` | 0 | no SCSI interrupt (active high) |
| VIA2 CB1 `SNDINT*` | 1 | no ASC interrupt |
| VIA2 PB6, PB3 | 0 | tied low on the board (4.3) |
| PDS lines (VIA1 PA0-2, PB7; VIA2 PA0-4, PB4-5) | 1 | nothing in the slot |
| the other devices' bytes (`dev_rdata` for SCC, SCSI, ASC, SWIM) | `$00` | as the machine module has had them since 3.5; a read of a 53C80 or 8530 register as `$00` is what the ROM's probes of step 3 already see |

## 4.8 The RTL

**`rtl/se30_via.v`**, one module, instanced twice - the 6523 of 4.2 as a
Verilog register file on `clk` with `c16_en`, everything timed from
GLUE's `e_clk` (the timers count its falling edges; the strobe is its
last high clock):

```
module se30_via (
  input        clk, c16_en, reset_n,
  input        e_clk,                 // GLUE's E, 4.4
  // GLUE's device port (2.11.1, 2.13)
  input        sel,                   // the chip select, follows AS*
  input        strobe,                // E's last high clock while selected
  input  [3:0] rs,                    // A12-A9
  input        rw,                    // 1 = read
  input  [7:0] wdata,
  output [7:0] rdata,                 // the register, while selected
  output       irq_n,
  // the ports: what the pin reads, what the chip drives, and whether
  input  [7:0] pa_in,  output [7:0] pa_out, output [7:0] pa_oe,
  input  [7:0] pb_in,  output [7:0] pb_out, output [7:0] pb_oe,
  input        ca1,
  input        ca2_in, output ca2_out, output ca2_oe,
  input        cb1_in, output cb1_out, output cb1_oe,
  input        cb2_in, output cb2_out, output cb2_oe);
```

A write lands at `strobe`; a read's side effects (the flag clears of
4.2.2, the handshake) land at `strobe` too; `rdata` is combinational from
the selected register, valid through the E-high phase. `pb_out[7]` is
T1's output when ACR7 is set. The IRQ is the IFR's bit 7, inverted.

**`rtl/se30_glue.v`**: the E generator and VIA cycle of 4.4; nothing else
moves.

**`rtl/se30_machine.v`**: the two instances, the pin functions of 4.5
(`pin = oe ? out : ext`, `ext` the 4.7 level or the real driver), the
device read mux (`dev_rdata` = VIA1's, VIA2's or `$00` by select), VIA2
PB7 pin to VIA1 CA1, GLUE's `slot_irq_or_n` to VIA2 CA1 and the video's
`irq6_n` to VIA2 PA5, the pins to GLUE (`overlay`, `ramsiz`) and to the
video (`page`, `vsyncen_n`), and the two `IRQ*` to GLUE. The 3.5 tie-offs
go. `files.qip` gains the file.

**`rtl/dbg_probes.sv`**: two more 32-bit probes. `PVIA`: `{overlay,
ramsiz[1:0], vsyncen_n, via1 IER[6:0], via1 IFR[6:0], via2 IER[6:0], via2
IFR[6:0]}` - whether the ROM got as far as clearing overlay, what size it
set, whether the VBL is armed and firing. `PIRQ`: `{level-2 acknowledges
[15:0], level-1 acknowledges[15:0]}`, the FC = 7 cycles by `A3-A1`; level
1 advances 60 a second if the VBL works and not at all if it does not.
`scripts/read_probes.tcl` decodes both. Item 17's checksum-verdict probe:
not added; the screen (4.6) is the verdict.

## 4.9 The benches

Rung 1 first (3.6): `sim/glue`, `sim/video`, `sim/system`, `sim/kernel_bus`,
`sim/kernel_upstream`, `sim/sdram` unchanged and green, `sim/glue` then
extended. Then:

**`sim/via/tb_se30_via.v`, iverilog** (rung 2) - the chip alone behind a
bench-made 10/10 E and GLUE-shaped strobes, held to 4.2:

1. reset: the eight registers `$00`, IER reads `$80`, IFR `$00`, ports all
   inputs, IRQ high;
2. ports: DDR gates the pin; a read gives the pin for an input bit and OR
   for an output bit; a write to an input bit leaves OR unchanged
   (4.2.3's rule); register 15 is register 1 without the flag clears;
3. T1 one-shot: written N, IFR6 sets N+1 E cycles (±½) after the T1CH
   write, once; T1CL read clears it; the latches reload and it keeps
   counting; T1LH write clears the flag without a transfer;
4. T1 free-run: IFR6 at N+1 then every N+2 cycles; with ACR7 PB7 inverts
   at each time-out, and 4.6's `$196E` gives a PB7 edge every 6512 cycles;
5. T2: one-shot, IFR5 once at N+1, then free roll-over, T2CL read clears;
   re-armed by T2CH; pulse-count mode on PB6 falling edges;
6. CA1/CA2/CB1/CB2: the PCR edge selects; IFR set on the active edge;
   cleared by the port access unless independent; the CA2/CB2 handshake,
   pulse and manual outputs to the table;
7. the shift register, external clock: out mode presents SR[8] on CB2,
   the first shift brings bit 7 out, eight CB1 falling edges send a byte
   MSB first and rotate it back; in mode takes CB2 on eight CB1 rising
   edges into bit 0 upward; IFR2 after eight, cleared and re-counted by an
   SR access; mode 000 never sets IFR2; the internal modes to their one
   line;
8. IFR/IER: bit 7 the AND-OR, IFR write clears by 1s, IER set/clear by
   bit 7, IRQ follows;
9. input latching (ACR0/1): IRA frozen at CA1's edge while enabled;
10. the ROM's sequences of 4.6 replayed as register traffic: the overlay
    write, the box-ID probe with PA6 undriven and PB3 low reading index 4,
    the VBL programming and its first CA1 edge on the other instance.

**`sim/glue/tb_se30_glue.v`** item 5 rewritten to 4.4: the select is high
before every E rise that serves an access and through the high phase; the
access lengths over a sweep of phases sit in 7-14 clocks with a mean of
8-10; E's phases are never shorter than 4 clocks; E rises 1000 ± 1 times
in 20,000 clocks with sparse accesses, and again with back-to-back
accesses (the bound); the strobe is still one device cycle per bus cycle
with the byte on `D31-D24` (item 6 unchanged).

**`sim/machine/tb_se30_machine.v`, ModelSim** (rung 3), extended past its
"first I/O access" stop: with the VIAs answering, the ROM (a) writes DDRA
`$3D`, which drives PA4 low from the reset OR flip-flop - overlay off at
cycle 70, RAM at `$0` from then on; (b) passes the PA0/PA1 strap test
(cycles 76-87, ORA reading `$C2` as 4.2.3 says it must); (c) runs the
checksum loop - **shortened in the bench's copy of the image** (run.sh:
two iterations, verdict forced to "passed"; the real loop is 130 ms of
machine time, an hour and more of ModelSim, and the board has already
run it, 3.8 item 17); (d) writes `$C0` to VIA2 DDRA and ORA (cycles
149-152) and reads its 128 longwords a megabyte apart; (e) writes RAM in
the test manager's first RAM test (cycle 802) - and then plays the boot
chime, where the run ends (4.6). 16 checks, 102 s of ModelSim: no bus
error, no halt, the SDRAM model clean, and the prediction **`PIFA
$40805F48`/`$40805F4C`, `PVIA $70000000`** (overlay 0, `RAMSIZ` 11,
`VSYNCEN*` 1, both IERs 0 - nothing enabled yet) for the first second
after boot. The empty-bank behaviour (3.7) is beyond the bench's reach:
the main sizing runs after the chime.

**The board** (rung 6, Daniel flashes): in the first second `PIFA` in the
chime loop and `PVIA $70000000`; then, once the main start-up chain has
run, `PVIA` with overlay 0, `RAMSIZ` as the sizing set it and VIA1's IER
bit 1 (`$83` written, 4.6 item 9); `PIRQ` level 1 counting at 60 a
second; and the screen - a Sad Mac code (read back through `$4083F8FC`)
or the flashing question mark.

## 4.10 Risks and open items

- **The E phase widths and the re-phasing mechanism** (4.4) are a contract
  meeting the *Guide*'s two numbers, not GLUE's design; the 4-clock minimum
  is OPEN for want of a 6523 data sheet. Every choice is in one place in
  `se30_glue.v` and one bench item; a real SE/30 on a scope would settle
  it in an afternoon.
- **The port write rule** (4.2.3): a write to an input bit does not reach
  the OR flip-flop, on the strength of the cell spec's un-boxed text. The
  6522 sheet in hand does not say; if a fuller 6522 description
  contradicts it, the change is one line and one bench check. The ROM's
  sequences (4.6 items 1, 4, 6, 8) are insensitive to it.
- **The ROM's ADB and RTC waits.** With no transceiver and no RTC (4.7),
  the ADB driver's transactions must time out and the PRAM read must
  tolerate `$FF`; the Plus's ROM does both (the MacPlus store) and the
  II-family ROM has the same drivers, but the SE/30 has not been seen to
  reach the disk icon without them. If the board stops in the ADB
  initialisation, that is the ADB section brought forward, not a VIA
  fault; `PIFA` will say which.
- **The one-second interrupt** is enabled (4.6 item 9) and never fires;
  the ROM's clock does not advance. Harmless until the RTC section.
- **The SCSI and SWIM probes** of 4.6 item 3 read `$00` bytes; they gate
  nothing at start-up, but the boot-device search later reads the 53C80's
  status and the SWIM's handshake registers, and `$00` there means "bus
  free" and "no disk" respectively - the search should fall through to the
  question mark. If instead it spins, the trace says where, and it is the
  SCSI or SWIM section's first item. **(The SWIM's is Section 5; the board
  stopped first in its start-up mode-set loop, 3.8 item 23.)**
- **Sad Mac codes** are read from the ROM's table when one appears; none
  is asserted from memory here.
- **VIA2 PB0 `CDIS*`** is an output with nowhere to go until the caches
  exist (1.15 item 9); it is left unconnected and noted.
- **The empty-bank question** (3.7) is not answered by this section, only
  observed: the machine bench and the board show what the sizing does with
  aliasing above 8 MB.

## 4.11 The work

1. ~~Write this section, and mark 2.11 row 3, 2.11.7 item 1 and 3.6's
   ladder with pointers to 4.4 and 4.9.~~ **Done 2026-09-27.**
2. ~~**`sim/via/tb_se30_via.v`** and `run.sh` (4.9 items 1-10), failing,
   then **`rtl/se30_via.v`** to 4.2 until it passes.~~ **Done 2026-09-27:
   93 checks.** The bench corrected the plan on T1's free-run period
   (N+2, 4.2.4) and found one model artifact (a control line tied low
   read as a "negative edge" out of reset; the edge registers now start
   from the pins).
3. ~~**`sim/glue`** item 5 rewritten to 4.4, failing, then the E generator
   and VIA cycle in **`rtl/se30_glue.v`** until the whole GLUE bench
   passes.~~ **Done 2026-09-27: 97 checks.** Measured in the bench's
   convention (AS* low to DSACK* inclusive, plus S4/S5): **7 clocks best,
   16 worst, 10 mean** over a 40-phase sweep; E's rise count clocks/20
   exactly under idle, sparse and 900 back-to-back accesses, the latter
   running one a period (17,995 clocks for 900); no phase under 4. The
   mechanism as simplified in 4.4 item 3.
4. ~~**`rtl/se30_machine.v`** to 4.8; `files.qip`; `sim/system` and
   `sim/video` still green.~~ **Done 2026-09-27.** The VIAs' reset is
   `reset_n` and the RESET instruction's `reset_out_n` together, as
   RESET* is shared on the board; the ROM executes RESET at `$4083F85A`.
5. ~~**`sim/machine`** extended to 4.9's (a)-(e); the prediction recorded
   here.~~ **Done 2026-09-27: 16 checks, 102 s**; the result and the
   prediction are in 4.6 and 4.9. The boot chime was the surprise: a
   software-timed tune on the absent ASC, 0.7 s, between the quick tests
   and the main sizing.
6. ~~**`rtl/dbg_probes.sv`**: `PVIA` and `PIRQ`; `scripts/read_probes.tcl`
   reads them.~~ **Done 2026-09-27.**
7. ~~Elaboration~~ **done 2026-09-27: 0 errors, 82 warnings (85 at 3.8
   item 9; none in the new files).** ~~Then the compile, **with Daniel's
   go-ahead**, the ritual of 3.6 item 5; the archive.~~ **The sixth
   compile, 2026-09-27, with Daniel's go-ahead, by the ritual: tag
   `df8ce0ce`, 20m52s, TIMING MET (the read capture +0.91 as before,
   `sdram_clk` +1.74, worst setup the framework's HDMI at +0.26, worst
   hold +0.26), fit 48% (45% before the VIAs), the known 4-node kernel
   loop (3.7) the only 332125, all seven probes in the fit; archived as
   `output_files/MacSE30_df8ce0ce_vias.rbf` / `.sof` (md5
   `b7bfdccda677f918ccc27795a8d6fdb6`), tag restored to 0.**
8. The board: Daniel flashes; the probes and the screen against the
   prediction; the reading recorded here. Then the empty-bank and 128 MB
   items of 3.7 have their first data, and Section 5 is whichever device
   the ROM stops at.

   **The third board reading, 2026-09-27, compile 6 flashed by Daniel:
   NOT the prediction, and not a Section 4 picture at all - it is
   compile 4's (3.8 item 15) to the digit.** `PBLD df8ce0ce`; `PACT` 53
   and frozen; `halted` 1; bus errors 0; `PIFA $002A0030`; `PLAS $C`;
   `PVIA $F0000000` (overlay 1, `RAMSIZ` 11, both IERs 0: the VIAs at
   reset, never written); `PIRQ` 0. The reset vector came out
   `$002A002A` = the long at `$4` (`4080 002A`) read as its second word
   twice, the CL2 symptom whose fix (`2654fae`) is in this build and
   worked on compile 5 (item 17: 728,640 cycles through the same path).
   What the desk could check, all identical between compiles 5 and 6:
   the SDRAM data-capture paths (`dq_q` in the I/O cell, setup +0.906,
   hold +3.232 to three decimals, as compile 3), every SDRAM port
   constrained (`report_ucp`: only the framework's I2C and audio pins
   unconstrained), the 44 registers that power up High (all the
   kernel's), the warning sets (one connectivity count differs), the
   controller and download RTL untouched since `2654fae`; the download
   holds the HPS per word until the controller acks, so no init race.
   Nothing in the Section 4 RTL touches a memory cycle.

   **The second reading of compile 6, after a core reload: a different
   picture** - `PACT` 484 and frozen, halted, `PIFA $4EFA4EFC` (a PC made
   of ROM instruction words), `PLAS $C`, no bus error. So the reads are
   not wrong deterministically: **the read path is a lottery**, per
   boot and per access.

   **The cause, found by asking STA about the corners the flow never
   analysed.** The MiSTer template's qsf (ours too, line 27) sets
   `TIMEQUEST_MULTICORNER_ANALYSIS OFF`: the compile's STA, and the
   "timing met" `build_only.sh` prints from its summary, is the **slow
   100C model only**. At every corner (`scripts/sta_corners.tcl`,
   written for this):

   | corner | read capture setup | read capture hold |
   |---|---|---|
   | slow 100C | +0.906 | +3.232 |
   | slow -40C | +1.403 | +2.779 |
   | fast 100C | +4.148 | +0.569 |
   | fast -40C | +4.829 | **-0.128** |

   **The next word reaches `dq_q` before the capture edge at the fast
   corner** - which is exactly a burst's second word captured in the
   first word's place, the `$002A002A` vector of item 15 and of this
   morning. The 3.9 ns the capture point moves between the slow and fast
   corners (the SDRAM clock's path out through the DDIO cell and the
   data's path in through the input cell do not track) leaves an
   intersection of only 0.78 ns in which a fixed capture edge is valid at
   every corner; ours sits 0.13 ns outside it, and the real silicon sits
   near enough that boot conditions and the fractional PLL's jitter
   decide each read. **Compile 5's 728,640 good cycles were the same
   margin on a kinder hour; compiles 3-5 were never "timing met" in the
   sense that matters.** 3.7's first risk, realised. The command and
   address outputs are fine at every corner (+1.73 setup, +3.64 hold at
   worst).

   **What follows is Section 3's to fix, and Daniel's to choose** (no
   compile until then): (a) the honest gate first - `sta_corners.tcl`
   after every compile, or `TIMEQUEST_MULTICORNER_ANALYSIS ON` in the
   qsf at the cost of compile time; (b) the capture itself, at 94 MHz:
   a phase-shifted SDRAM clock from a third PLL output can centre the
   0.78 ns window but cannot widen it; a run-time choice between two
   captures picked once at reset by reading back a pattern written to
   RAM is robust to the corner spread and is what the width of the eye
   at this clock demands; a slower SDRAM clock (5 x C16M = 78.336 MHz is
   still an integer divide of the VCO) widens the eye to 8.8 ns but
   breaks the 3:1 slot scheme. Section 4's own result stands unread: the
   VIAs were never written on either boot.

   **DECIDED by Daniel, 2026-09-27: the run-time choice between two
   captures, and multicorner analysis ON.** The design, as far as it got
   before the session closed (3.8 item 18 is the work, **and records what
   was built later that day and where it departs from this sketch: one
   cell register on a clock control block, the phases from a one-minute
   experiment rather than this table - compile 6's fitter had delay
   chains on the DQ pins - and a transfer chain with no multicycle**):

   - **Two capture clocks, not the input cell's two edges.** The cell's
     rising and falling edges are 5.32 ns apart, and with 4.1-4.7 ns
     windows that leaves a worst-case margin of 0.6-0.8 ns. Two
     phase-shifted copies of `clk_mem` from the PLL's spare outputs,
     **capture A at -1.0 ns and capture B at +2.5 ns** from the present
     edge, cover the four corners with **at least 1.6 ns** each (from
     the table above: A serves the slow corners with 1.9/2.2 and
     2.4/1.8 setup/hold, B the fast ones with 1.6/2.1 and 2.3/2.4). The
     PLL is fractional but its output phase shifts are ordinary
     (VCO-phase steps of 0.13 ns at 940 MHz).
   - **The registers**: `dq_a` on `clk_capa`, `dq_b` on `clk_capb`, both
     I/O-cell input registers as `dq_q` is now; the controller consumes
     `cap_sel ? dq_b : dq_a` where it consumes `dq_q` today (sequence 6
     and 7), a full period on. Constraints: for each capture clock the
     same two-cycle setup multicycle from `sdram_clk` that `dq_q` has,
     with the default hold; from `clk_capa` to the consumer a two-cycle
     setup multicycle with hold end 1 (its edge sits 1 ns before
     `clk_mem`'s); from `clk_capb` the natural single cycle (8.1 ns).
     `derive_pll_clocks` names the new clocks.
   - **The training**, at the end of the power-up ladder, before
     `ready`: write two distinct words (`$A5C3`, `$3C5A`) to the top two
     words of the 32 MB (word `$FFFFFE`, above the 8 MB RAM image and the
     ROM at `$400000`; reserved from now on), then read them back eight
     times capturing through A and B; a capture that returns the pair
     every time is chosen, A preferred; neither matching picks A and
     raises `cap_fail`. `cap_sel` and `cap_fail` go to `PSTA`'s spare
     bits 20 and 19 so the board says which edge it chose.
   - **The benches**: `sim/sdram`'s `CLK_TO_PIN` sweep widened to cover
     both captures (today 2.9-5.3 ns; the model drives data with the
     datasheet's tAC and tOH and X between, so a wrong capture reads X
     and the training must reject it); a check that the training picks A
     at one end of the sweep and B at the other, and that `ready` waits
     for it; the machine bench's `sd_clk`, `clk_capa`, `clk_capb` made in
     the bench from `clk_mem` by the same offsets.
   - **The files**: `rtl/pll/pll_0002.v` and `rtl/pll.v` (two more
     outputs, `number_of_clocks` 4), `MacSE30.sv` (the wiring),
     `rtl/se30_sdram.v` (ports `clk_capa`/`clk_capb`, the registers, the
     training, `cap_sel`/`cap_fail` outputs), `MacSE30.sdc`, `MacSE30.qsf`
     (`TIMEQUEST_MULTICORNER_ANALYSIS ON`; the flow's "timing met" then
     means every corner, and `sta_corners.tcl` stays as the readout),
     `rtl/dbg_probes.sv` (the two bits), `scripts/read_probes.tcl`.
   - **The gate**: benches green, elaboration, then the compile with
     Daniel's go-ahead, `sta_corners.tcl` on it, the board.

# Section 5 - The SWIM and the floppy drives

Opened 2026-09-27, after 3.8 item 23: compile 14 ran the ROM through its
RAM tests to the SWIM's mode-set loop at `$408006C0`, where a machine
without its floppy controller must stop. Written before any RTL,
documentation first: Apple's SWIM documents, the schematic, and the ROM's
own start-up code and `.Sony` driver. The donor (MacLC's `swim.v` and
`floppy.v`) was read after those, as a cross-check.

**Two decisions by Daniel, 2026-09-27, frame the section.**

- **The data path is bit-level.** The IWM's data separator and write
  shifter, and the ISM's parameter-RAM-driven read and write machines, are
  modelled from Apple's specifications, and the drive gives them a flux
  stream built from the disk image. MacLC's floppy is, in its own header's
  words, a "synchronous 8-bit replica" - a byte-level model, not a
  bit-level one - and much of its fix history is byte-level re-creations of
  timing the real chip produces from bit cells. The chip is documented to
  the clock, so this is `feedback-independent-core-own-the-kernel`'s "no
  workarounds for well-defined jobs". From MacLC we take the image handling
  and use its bug history as test cases (5.7).
- **Three rungs on the board.** Rung 1: both register sets and the
  internal FDHD drive **with no disk** - the ROM gets past the mode-set loop
  and its driver finds an empty SuperDrive, which should take the machine
  to the question-mark disk (or show which of the ADB, RTC and SCSI waits
  stops it first, 4.10). Rung 2: reading 800K GCR and 1.4MB MFM images.
  Rung 3: writing. **Only rung 1 is designed here in full.** Rungs 2 and 3
  have their sources mapped (5.2.4) and are written in detail when they
  open.

## 5.1 Sources, and their standing

All in `C:\temp\Mac\SE30\Docs\swim`, from bitsavers
`/pdf/apple/disk/sony/` (the `trailing-edge` mirror), downloaded
2026-09-27 with Daniel's OK and size-checked against the listing; the
`.txt` beside each is `pdftotext -layout` output (OCR, so the scanned
drawings are partly garbled - quote from the page image when a number
matters).

| source | what it is | standing |
|---|---|---|
| **`SWIM_343S0061-A_1988.pdf`** (55 sheets) | Apple drawing 343S0061-A, "IC custom gate array, MFM/GCR disc controller, SWIM 44 pin PLCC", production release: the part's parametrics, then section 6 "supplementary information" - the ISM's theory of operation (6.1-6.4), **its register set (6.5)** and **the IWM's specification (6.6-6.7)** | **primary**; the highest standing we have for the part the SE/30 carries. Section 6 is marked "not to be used for acceptance nor rejection" - it describes, it does not certify |
| `SWIM_chip_spec_198707.pdf` (3 pp.), "SWIM Chip Specification", 29 Sep 1987 | **the combination logic**: how the IWM and the ISM share the pins, the mode-switch rules, the three extra IWM bits (OVERRIDE, M16/M8, MODIFY) | **primary**, and the only hardware document for the switching |
| `SWIM_Chip_Users_Ref_198801.pdf` (35 pp.), Rev 1.5, 11 Jan 1988 | Apple's programmer's guide: pinouts, GCR and MFM formats, the IWM state/register tables, the ISM's registers, parameter-RAM arithmetic with a 15.6672 MHz worked example, the address map of both sets, code examples | **primary for behaviour as software sees it**; a software guide, so where it and the hardware documents disagree the hardware documents win (5.10) |
| `ISM_ASIC_spec_198707.pdf` (56 pp.), rev 4.1, 2 Jul 1987 | the ISM alone, before it was combined: pins, MFM write (FIFO, shift register, CRC, trans-space, pre-compensation), MFM read (half read, correction machine, error correction, post-compensation, data transformation), GCR, time-out, registers | **primary for rungs 2-3's ISM machinery** |
| `IWM_undoco_features.pdf` (1984) and `Software_control_of_IWM.pdf` (1984) | Apple II-era notes: the write latch's 9-FCLK reload lock after a shift-register load, reads only from bit-clearing locations; the Disk II/IWM soft switches, sync bytes, self-sync | **primary for IWM corners**; written for the Apple II, so only the chip facts carry over |
| `IOP_SWIM_Driver_ERS_199001.pdf`, `Hand_notes_on_floppy_stuff.pdf`, `Apple_3.5_Drive_Schematic.pdf` | the IIfx's IOP driver ERS; handwritten notes; the 800K drive's schematic (raster) | background; not read for rung 1 |
| `Apple_drive_command_and_status_codes.pdf` | a modern table of the Sony drives' 16 status and 8 command addresses with Apple's source names (`rNoDriveAdr`, `wMotorOnAdr`, ...), built from a SWIM3 driver | **secondary** - reverse-engineered ("seems", "apparently"). Used only where the ROM confirms it (5.5) |
| *Guide* 2e, chapter 9 (pp. 329-356) and pp. 80-81 | the drive connectors, the circuit diagrams of the older machines, FCLK = 15.6672 MHz halved "for the 800K drive or the HD20", the SE/30's one internal FDHD and external port | **primary for the machine level**; it disclaims the chips' internals ("This chapter does not contain information about the internal operation of the disk interface ICs") |
| `se30.pdf` sheet 6 "SWIM & SCSI interface" (`se30schems/Apple/SE30_P6.GIF`) | UJ11 = the SWIM, 44-pin; J8 the internal ribbon, J6 the external DB-19 | **primary for the wiring** (5.3) |
| The SE/30 ROM, `.Sony` (DRVR header `$4082D72C`) and the start-up code | what the machine actually does with the chip and the drives | **documentation tier** (1.11's rule): it is what the machine ran |

`SWIM_regs.txt` in the same bitsavers directory describes the **SWIM III**
(Power Macintosh) and is not ours. The same directory holds the 400K
drive's specification (`699-0285-A`) and Sony drive photographs, not
fetched.

## 5.2 The chip: an IWM and an ISM in one package

"The SWIM chip is a combination of an IWM and an ISM. It should be
considered as two separate chips, with minor variations" (chip spec).
Only one register set is selected at a time; each has its own `/DEV`,
`/WRREQ`, `RDDATA` and clock logic behind the switch. **There is no R/W
pin**: the address decides whether an access reads or writes the chip -
in the IWM set, A0 = 0 reads and A0 = 1 writes (and only when L6 and L7 are
set, below); in the ISM set, **A3 = 0 writes and A3 = 1 reads** (User's
Ref p. 4). On the SE/30 A3-A0 are the CPU's A12-A9 (5.3), so a register
`n` is at offset `n << 9` in the `$50F16000` window.

### 5.2.1 The IWM set

**Eight state latches**, addressed by A3-A1 with A0 as the new value
(User's Ref p. 10; production 6.7.1), reset to 0 by `/RESET`:

| n | offset | effect | n | offset | effect |
|---|---|---|---|---|---|
| 0 | `$0000` | PH0 = 0 | 8 | `$1000` | MotorOn = 0 |
| 1 | `$0200` | PH0 = 1 | 9 | `$1200` | MotorOn = 1 |
| 2 | `$0400` | PH1 = 0 | 10 | `$1400` | drive select = 0: `/ENBL1`, internal |
| 3 | `$0600` | PH1 = 1 | 11 | `$1600` | drive select = 1: `/ENBL2`, external |
| 4 | `$0800` | PH2 = 0 | 12 | `$1800` | L6 = 0 |
| 5 | `$0A00` | PH2 = 1 | 13 | `$1A00` | L6 = 1 |
| 6 | `$0C00` | PH3 = 0 | 14 | `$1C00` | L7 = 0 |
| 7 | `$0E00` | PH3 = 1 | 15 | `$1E00` | L7 = 1 |

The PHx latches drive the phase pins; drive select picks which `/ENBLx`
goes low when the (delayed) MotorOn is set. **L7, L6 and MotorOn select
the register**, and "if an operation occurs that changes the state of one
of these bits, the new state will select the register to be accessed"
(User's Ref p. 10) - so the register an access reaches is decided by the
latches *as that access leaves them*:

| L7 L6 MotorOn | register | |
|---|---|---|
| 0 0 0 | read all ones (`$FF`) | |
| 0 0 1 | read data | |
| 0 1 x | read status | bit 7 SENSE; bit 6 reserved, reads 0 (the MZ bit, production 6.7.3); bit 5 = an `/ENBLx` is active; bits 4-0 = mode bits 4-0 |
| 1 0 x | read write-handshake | bit 7 write buffer empty; bit 6 = 1 while writing, 0 after an underrun until L7 is cleared or reset; bits 5-0 read 1 |
| 1 1 0 | **write mode** (A0 = 1) | reset to 0 |
| 1 1 1 | write data (A0 = 1) | |

**The mode register** (User's Ref p. 12, production 6.7.2): bit 0 latch
mode; 1 asynchronous handshake; **2 timer disable** (0: `/ENBLx` held for
2^23 + 100 FCLK after MotorOn clears); 3 fast (2 µs cell descriptor) /
slow; **4 the 8 MHz descriptor** (FCLK divided by 8, not 7, for 1 µs
internal timing); 5 test mode; **6 the ISM select** (5.2.3); 7 reserved.
"The mode register is not accessible for up to one second when the timer
is enabled and counting down", because it is selected through the
*delayed* MotorOn, which the timer holds high: while the timer runs, a
write at L6 = L7 = 1 reaches the data register instead. At FCLK =
15.6672 MHz the timer is **2^23 + 100 clocks = 535 ms** (the documents'
"about 1 second" is at the IWM's original 7-8 MHz); the combination
logic's M16/M8 bit doubles it (5.2.3).

**The SE/30's clocking.** FCLK is C16M (5.3), twice the IWM's historical
clock. The *Guide* (p. 345): "during the startup sequence, software sets a
bit in the SWIM to divide the clock by two when reading and writing to
the 800K drive". The ROM's start-up value is mode `$17` (5.6 item 1):
latch, asynchronous, timer disabled, **8 MHz descriptor, slow**. The
production drawing's paragraph on cell times per mode (6.6: "... in 8M
and slow mode ... periods, and in 8M and fast mode the cell time will be
16 periods") is **garbled in the OCR** and is read from the page image
when rung 2 builds the data separator; rung 1 does not depend on it.

**Reset** (`/RESET` low): all eight latches 0, the mode register 0 (so the
timer is *enabled* out of reset), the handshake's underrun flag clear.

### 5.2.2 The ISM set

Sixteen registers, A3 the read/write bit (User's Ref pp. 20-26; production
6.5, which numbers them by A2-A0 with the direction implied):

| write (A3 = 0) | offset | read (A3 = 1) | offset |
|---|---|---|---|
| 0 data (FIFO) | `$0000` | 8 data (FIFO) with ACTION; **correction** pair without | `$1000` |
| 1 mark | `$0200` | 9 mark | `$1200` |
| 2 CRC with ACTION; **IWM configuration** without | `$0400` | 10 error (clears on read) | `$1400` |
| 3 parameter RAM, auto-increment | `$0600` | 11 parameter RAM, auto-increment | `$1600` |
| 4 phases | `$0800` | 12 phases | `$1800` |
| 5 setup | `$0A00` | 13 setup | `$1A00` |
| 6 mode, **write zeros** (clears the bits set in the byte) | `$0C00` | 14 status (the mode register) | `$1C00` |
| 7 mode, **write ones** | `$0E00` | 15 handshake | `$1E00` |

- **Phases** (reset `1111 0000`): bits 7-4 each phase line's direction, 1
  = output (production 6.5.6: "the phase lines default to outputs on
  reset"); bits 3-0 the level driven, or read, per line. A read returns
  the whole byte, direction bits included.
- **Setup** (reset 0): 0 Q3/HDSEL pin as output; 1 the 3.5SEL pin; 2 GCR;
  3 FCLK/2; 4 error correction; 5 pulses/transitions (production: "IBM
  type drive"); 6 bypass trans-space (set for GCR); 7 the MotorOn
  time-out (1/2 s at 16 MHz). Production 6.5.7: bits 2 and 4 together
  are a test mode "that should always be avoided".
- **Mode** (reset 0): 0 clear FIFO (toggle); 1 enable drive 1; 2 enable
  drive 2; 3 ACTION; 4 write (1) / read; 5 HDSEL; **6 ISM/IWM: "reserved
  ... will always read back a 1"** in the ISM (production 6.5.9), and
  clearing it through write zeros returns to the IWM (User's Ref p. 23);
  7 MotorOn (the enables).
- **Parameter RAM**: 16 bytes through one register, an auto-incrementing
  index "set to zero after any access is made to the Mode 0 register
  (register 6) or the chip is reset" (User's Ref p. 21; production 6.5.5:
  "any time that a write to the Write Zeroes ($6) location occurs"). Its
  reset contents are not specified.
- **Handshake**: 0 mark next; 1 CRC nonzero; 2 RDDATA; **3 SENSE**; 4
  MotorOn or its timer; 5 an error is latched; 6 two bytes ready/free; 7
  one or more.
- **Error** (reset 0; the first error freezes the rest until read): 0
  underrun/overrun; 1 mark read from the data register; 2 the processor
  too fast; 3 correction overflow; 4 cell too narrow; 5 too wide; 6
  unresolved transitions.

**The access rule**: "the time between successive chip accesses must be
no less than 4 FCLKs (if the Setup register's FCLK/2 bit is 0) or 8 FCLKs"
(User's Ref p. 13). GLUE's SWIM cycle (2.11.3 row 10) is 4 clocks with
one wait state, and consecutive CPU bus cycles are further apart than
that; the bench checks it rather than assuming it (5.9 item 14).

### 5.2.3 The switch between them, and the three extra bits

From the chip spec (the combination logic), confirmed by User's Ref p. 12:

1. **MOTOREN must be low** to switch.
2. **IWM to ISM**: four consecutive writes to the IWM mode register with
   data bit 6 = 1, 0, 1, 1. (Our reading of "consecutive": four
   successive *mode-register writes*; a mode write out of sequence starts
   the count again. Accesses to other addresses between them are not
   addressed by any document; the ROM makes none, 5.6.)
3. **ISM to IWM**: a write to write-zeros with data bit 6 = 1.
4. "After mode switching from ISM to IWM, the very first command must be
   a clear L7."
5. The phase lines keep their levels across a switch ("no glitches").
6. **Three bits the IWM gains**, written through the ISM's register 2
   with ACTION low, cleared by `/RESET`: bit 7 OVERRIDE (MotorOn low plus
   a toggle of the drive select kills the IWM timer), bit 6 M16/M8 (the
   IWM timer takes twice as long), bit 5 MODIFY (with ASYNC, D7 latched as
   in port mode).

**One disagreement between the documents.** The chip spec says the ISM's
phase-direction bits "are not changed by a mode switch. They now control
the direction of the Phase pins in both the IWM and the ISM mode." The
User's Ref (p. 4) says that in the IWM set the phase lines "are forced to
be outputs regardless of how the direction was set". The production
drawing does not address it. **We follow the chip spec** - the hardware
document of the combination logic, against a programmer's guide - and
record it in 5.10. The ROM sets every line to an output (`$F5`-`$F7`,
5.6 item 3), so nothing it does can tell the two apart.

### 5.2.4 The data path, for rungs 2 and 3 (sources mapped, not yet designed)

- **IWM read**: production 6.6 - "a falling transition within a bit cell
  window is considered to be a one"; the digital one-shot data recovery,
  every transition re-establishing the windows; revision B's windowing
  after a transition (6 FCLK in 8 MHz fast mode, 5 in 7 MHz fast, twice
  that slow); the shift register filling LSB-first until a one reaches the
  MSB, then latched into the read data register and cleared; in
  asynchronous mode the latched byte "cleared 14 FCLK periods (about 2 µs)
  after a valid data read" (`/DEV` low with D7 = 1 for at least one FCLK).
  GCR's self-sync (ten-bit sync bytes, a five-byte lock) from `Software
  control of IWM`.
- **IWM write**: production 6.6 - asynchronous mode's buffer, the
  handshake's buffer-empty bit, the underrun that raises `/WRREQ` and
  clears handshake bit 6; the 9-FCLK reload lock after each shift-register
  load (`IWM_undoco_features`).
- **ISM read and write**: the ISM spec's sections 3-5 (FIFO, CRC
  CCITT-16 from all ones, trans-space encoding, pre-compensation, half
  read, the correction machine, post-compensation, data transformation,
  GCR bypass) and the User's Ref's parameter arithmetic (pp. 13-17), whose
  15.6672 MHz worked example gives the values the ROM's table should hold
  (5.6 item 5).
- **The drive's flux**: 800K GCR at 2 µs cells over five speed zones (12
  down to 8 sectors, User's Ref p. 6); MFM 720K/1.44MB with the index
  pulse; the SuperDrive's GCR/MFM mode register (5.5).

## 5.3 The wiring (sheet 6, UJ11)

| SWIM pin | net | |
|---|---|---|
| `/DEV` (43) | `SWIM*` from GLUE | the chip select; GLUE's `swim_sel` |
| A0-A3 (37, 40, 41, 42) | `A(9)`-`A(12)` | |
| D0-D7 (4, 5, 8, 9, 13, 14, 15, 18) | `D(24)`-`D(31)` | the top byte lane: an 8-bit port acknowledged with `DSACK0*` (2.11.3 row 10) |
| `/RESET` (25) | `RESET*` | shared with the CPU, VIAs and SCSI (2.11.6): the RESET instruction resets it, as it does the VIAs (`via_reset_n` in `se30_machine.v`) |
| FCLK (26) | `C16M` | 15.6672 MHz |
| Q3 (27) | `AS*` | the IWM's data-latch clock in systems whose data is not valid at `/DEV`'s rise (User's Ref p. 4); Setup bit 0 is never set by the ROM, so the pin stays an input |
| SENSE (21) | tied to RDDATA (24) | the drive's status bit and its read data share one line, as on every Sony-drive Mac |
| PH0-PH3 (35, 32, 36, 31) | `FPH0`-`FPH3` | to J8 pins 2, 4, 6, 8 and through RP10 to J6 |
| `/ENBL1` (20) | `ENABL1*` | **J8 pin 14: the internal drive** |
| `/ENBL2` (19) | `ENABL2*` | **J6: the external DB-19** |
| WRDATA (2), `/WRREQ` (3) | `WR*`, `WRREQ` | to both connectors |
| HEDSEL (38) | TP3 only | **not the drives' SEL** |
| 3.5SEL (16), DAT1BYTE (33), `/MOTOEN` (10) | unconnected | |

**The drives' SEL line is `HDSEL` from VIA1 PA5** (sheet 4 via the `(4)`
off-sheet connector; 4.3's table), to J8 pin 12 and J6. So the
`{CA1, CA0, SEL, CA2}` drive-register address of 5.5 is set partly
through the SWIM and partly through VIA1.

## 5.4 The bus

Nothing new: GLUE already decodes the window (`d_swim`, `win == $B`,
`$50016000-$50018000` and its mirrors), gives it one wait state and
`DSACK0*` (2.11.3 row 10; `rtl/se30_glue.v`), and presents the device port
the VIAs use - `swim_sel`, `dev_strobe` (one C16M clock: the device
latches or must present), `dev_addr[12:9]`, `dev_wdata` (D31-24) and
`dev_rdata`. The SWIM answers on that port. Because the chip has no R/W
pin, **its behaviour follows the address, not the CPU's R/W**: a CPU
write to a read address performs the chip's read (its side effects
included - a FIFO pop, the error register's clear), and a CPU read of a
write address performs the chip's write with whatever the data lanes
hold, which on a read is undefined (5.10). The ROM does the first
routinely - `move.b #$80, $0C00(a0)` in IWM mode is a PH3-low access
(5.6 item 4) - and never the second. **A read of an IWM address with A0
= 1** when L6 and L7 are not both set is neither: the IWM reads only
"during any operation in which A0 is a zero" (production 6.7.1), so the
chip does not drive the lanes and the CPU reads whatever they hold. The
ROM does this constantly (`tst.b $1200(a0)`, MotorOn on) and discards the
byte; the model returns the register the latches select, and 5.10
records it as a modelling choice.

## 5.5 The drive: registers, and the empty FDHD of rung 1

The *Guide* gives the drive's pins but not its registers; Apple's own
description of the Sony drives' registers is not in hand. What we have is
**the ROM's driver**, which fixes the address encoding and the meaning of
every register it reads at start-up, and the secondary table, which the
ROM confirms at every point it reaches.

**The address.** `$4082E0EC` sets CA0 and CA1 high, then takes the
register number's bits in order: bit 0 -> **CA2** (PH2 at `$0A00`/`$0800`),
bit 1 -> **SEL** (VIA1 ORA bit 5, `bset`/`bclr #5, $1E00(VIA1)`), bit 2 ->
**CA0** (cleared at `$0000` if 0), bit 3 -> **CA1** (cleared at `$0400` if
0). So **the ROM's register number is `{CA1, CA0, SEL, CA2}`**. A read
(`$4082E12E`) sets L6 and reads status at `$1C00` (bit 7 = SENSE), then
clears L6; a write (`$4082E150`) pulses PH3 (`$0E00`, two NOPs, `$0C00`)
with CA2 as the value. With the ISM selected (`$135(a1)` set) the same
reads go through the ISM's phase register and handshake bit 3
(`$4082E8E0`, `$4082E916`) - rung 2.

**Status registers** (read; "ROM" = read by the ROM on rung 1's path;
level = rung 1's internal FDHD with no disk):

| ROM no. | SEL CA2 CA1 CA0 | name (secondary) | meaning | level | evidence |
|---|---|---|---|---|---|
| `$0` | 0 000 | `rDirPrevAdr` | step direction, 1 = outward | as last written, 0 at power-up | secondary; power-up chosen |
| `$4` | 0 001 | `rStepOffAdr` | 1 = no step in progress | 1 | secondary |
| `$8` | 0 010 | `rMotorOffAdr` | 0 = spindle on | 1 until a motor-on command | secondary |
| `$C` | 0 011 | `rEjectOnAdr` | eject latch | 0 | **ROM** (VBL task) + secondary |
| `$1` | 0 100 | `rRdData0Adr` | read data, lower head (selects it) | 1 (no flux) | secondary; level chosen |
| `$5` | 0 101 | `rMFMDriveAdr` | 1 = SuperDrive (or no drive) | **1** | **ROM** (Open) + secondary |
| `$9` | 0 110 | `rDoubleSidedAdr` | 1 = double-sided drive | **1** | **ROM** (Open) + secondary |
| `$D` | 0 111 | `rNoDriveAdr` | 0 = drive present | **0** | **ROM** (Open) + secondary |
| `$2` | 1 000 | `rNoDiskInPlAdr` | 1 = no disk | **1** | **ROM** (VBL task) + secondary |
| `$6` | 1 001 | `rNoWrProtectAdr` | 0 = write-protected | 1 | secondary; not read without a disk |
| `$A` | 1 010 | `rNotTrack0Adr` | 0 = head at track 0 | 0 at power-up | secondary; power-up chosen |
| `$E` | 1 011 | `rNoTachPulseAdr` | GCR tach (60 per turn) / MFM index | 1 while stopped | secondary |
| `$3` | 1 100 | `rRdData1Adr` | read data, upper head (selects it) | 1 | secondary; level chosen |
| `$7` | 1 101 | `rMFMModeOnAdr` | 1 = MFM mode | 0 (GCR) at power-up | secondary; power-up chosen |
| `$B` | 1 110 | `rNotReadyAdr` | 0 = ready | 1 | secondary |
| `$F` | 1 111 | `r1MegMediaAdr` / REVISED | 0 = HD medium | **1** | **ROM** (Open) + secondary |

**Commands** (a PH3 pulse; CA2 = the value):

| ROM no. (CA2 = 0 / 1) | SEL CA1 CA0 | command | evidence |
|---|---|---|---|
| `$0` / `$1` | 0 00 | direction inward / outward | secondary |
| `$4` / `$5` | 0 01 | step / (unused) | secondary |
| `$8` / `$9` | 0 10 | motor on / **off** | **ROM** (`$9`, VBL task) + secondary |
| `$C` / `$D` | 0 11 | - / eject | secondary |
| `$2` / `$3` | 1 00 | - / **reset the eject latch** | **ROM** (`$3`, VBL task) + secondary |
| `$6` / `$7` | 1 01 | MFM / GCR mode | secondary |

**The absent external drive** reads SENSE = 1 for every register: the
ROM's Open takes a 1 at `$D` as "no drive" and skips it. What makes the
line read 1 with nothing driving it is not traced on sheet 6 (RP10 is the
connector's RC network); rung 1 models the level the ROM requires and
5.10 carries the mechanism as open. The same level is read when no drive
is enabled at all.

## 5.6 What the ROM does with the SWIM

In the order the machine meets it:

1. **The mode-set loop** (`$408006AA`, from the main start-up chain; the
   base from `$4080073E`, which always returns Z on this ROM, so
   **`$50F16000`**): `$1000` MotorOn off, `$1A00` L6 on, read status at
   `$1C00` (L7 off); loop while bit 5 (an enable active) is set; done when
   `status & $17 = $17`; else write `$17` at `$1E00` (L7 on: L7 L6 MotorOn
   = 110, the mode register), read `$1C00` again and loop. Leaves with
   `$1800` (L6 off). From reset (mode 0, nothing enabled) it takes two
   passes. **This is where compile 14 stopped** (3.8 item 23).
2. The test manager's reads of the SWIM windows (4.6 item 3) - no gate.
3. **The `.Sony` Open** (`$4082D79C`, when the ROM installs its drivers):
   allocates its variables (pointer at `$134`), installs a VBL task every
   30 ticks (`$4082E444`), then the **SWIM probe** `$4082E6A2`: drive 1,
   L7 off, MotorOn off, L6 on, then **`$57`, `$17`, `$57`, `$57` to
   `$1E00`** (the switch of 5.2.3); in the ISM, **`$F5`, `$F6`, `$F7`
   written to the phase register (`$0800`) and each read back whole at
   `$1800`**; all three echoed -> `$134(a1)` = `$FF` (a SWIM); then `$F8`
   to write-zeros (`$0C00`, bit 6: back to the IWM), **L7 cleared first**
   (`$1C00`), L6 off (`$1800`), MotorOn **on** (`$1200`). Then for drives 1
   and 2: select and enable, read `$D` (**present?** - absent: skip), `$9`
   (sides), `$F`, `$5` (SuperDrive: flags it, and with the SWIM flag
   marks the drive MFM-capable). An empty internal SuperDrive and an
   absent external drive pass straight through.
4. **The VBL task** (`$4082E444`, every 30 ticks): a motor-off countdown
   that ends in command `$9`; for each installed drive, read `$2` (disk in
   place) and on a 0 post a disk-inserted event (rung 2); the eject latch
   at `$C` and its reset `$3`. It ends `move.b #$80, $0C00(a0)` (in IWM
   mode a PH3-low access) and `$1000` (MotorOn off).
5. **Rung 2's**: the ISM entry for a disk (`$4082E712`) and the
   parameter-RAM check (`$4082E7CC`, sixteen reads at `$1600` against a
   table chosen by drive kind), the IWM configuration write `$C0` at
   `$0400` and the setup write/readback at `$0A00`/`$1A00`. Read when rung
   2 opens.

**The machine after rung 1.** Past the loop, the start-up chain goes on
to the VIA initialisation and the VBL (4.6 items 8-9), `TimeDBRA`, the ADB
and RTC work, the SCSI probe and the drivers - the risks of 4.10 in order
- and then the boot search. With an empty internal drive and nothing on
SCSI, the target is **the flashing question-mark disk**; if the board
stops earlier, `PIFA` says where and the next section is whichever device
that is.

## 5.7 The donor: MacLC's `swim.v` and `floppy.v`

Upstream `MacLC_MiSTer` at `045f896`, which includes Daniel's floppy-write
work (PR #7). Read after 5.1-5.6. Findings:

- **The register semantics agree with the documents** at every point
  checked: the IWM status byte `{SENSE, 0, enable, mode[4:0]}`; the ISM
  numbering with A3 as the direction; mode bit 6 reading 1 in the ISM
  (`ism_mode_reg <= 8'h40` on the switch); write-zeros resetting the
  parameter index (its comment cites MAME; the User's Ref and production
  6.5.5 say the same); the phase read `{direction, PH3-0}`.
- **Its drive register table** (`floppy.v` header, MAME-derived, with
  "??" where unsure) numbers registers `{CA2, CA1, CA0, SEL}`, a relabelling
  of the ROM's `{CA1, CA0, SEL, CA2}`; mapped across, it agrees with 5.5.
- **Its data path is byte-level** ("Synchronous 8-bit replica of 3.5 inch
  floppy disk drive ... True interface does not have newByteReady"), so by
  Daniel's decision it is not lifted.
- **What rung 2 takes from it**: the image handling (DC42 and raw
  images, the mount-time sniff of sidedness and density, the SD/SDRAM
  loading), the GCR and MFM track layout knowledge
  (`floppy_track_encoder.v`: sector interleave, zones), and **its fix
  history as test cases** - each fix names a behaviour the ROM depends on
  (the Sony driver polling VIA1 PA7 in every MFM loop, already 1 here
  (4.7); the ONE handshake sample that decides a field; SWITCHED and the
  eject latch; the 2:1 interleave behind a copy error), and the bit-level
  model must pass them by construction, not by special case. Rung 3 adds
  its SD write-back (`floppy_sd_writer`/committer lineage) on the host
  side.

## 5.8 The RTL for rung 1

Two modules, Verilog, on `clk` with `c16_en` = FCLK (C16M), each one
C16M period two `clk` cycles - the half-clock resolution the ISM's
parameters are specified in (User's Ref p. 15), ready for rung 2.

**`rtl/se30_swim.v`** - the chip:

```
module se30_swim (
  input        clk, c16_en, reset_n,
  // GLUE's device port (5.4); no R/W: the address decides
  input        sel,                   // /DEV
  input        strobe,                // the access's one-clock latch point
  input  [3:0] rs,                    // A12-A9
  input  [7:0] wdata,                 // D31-24
  output [7:0] rdata,
  // the drive side (5.3)
  output [3:0] ph_out, output [3:0] ph_oe, input [3:0] ph_in,
  output       enbl1_n, enbl2_n,
  input        sense,                 // = RDDATA on this board
  output       wrdata, wrreq_n,
  output       hdsel,                 // TP3 only
  output [xx:0] dbg                   // PSWM
);
```

- The IWM latches, register select from the latches **as the access
  leaves them**, the mode register, status, handshake (writing idle:
  buffer empty 1, bit 6 as 5.2.1), read-all-ones, the read data register
  (its shift register fed from RDDATA; with no flux it stays 0 - the
  separator's timing is rung 2's), and the MotorOn timer with its delayed
  MotorOn in the register select.
- The ISM registers of 5.2.2 with their resets, the parameter RAM and its
  index, the error register's read-clear, the FIFO's flags idle (ACTION
  never set on rung 1's path).
- The switch of 5.2.3 (the four-write counter, MOTOREN low, write-zeros
  bit 6 back), the shared phase lines with the ISM's direction bits in
  force in both sets, the three extra IWM bits.
- `/ENBLx`: drive select and delayed MotorOn in the IWM; mode bits 7, 1,
  2 in the ISM.

**`rtl/se30_fdhd.v`** - one Sony FDHD drive, instanced for the internal
position (the external is absent and costs no instance: its SENSE is the
pulled-up 1):

```
module se30_fdhd (
  input        clk, c16_en, reset_n,
  input        enbl_n,
  input  [3:0] ph,                    // CA0, CA1, CA2, LSTRB
  input        sel,                   // VIA1 PA5
  output       sense,                 // the addressed register while enabled
  input        disk_in,               // 0 on rung 1
  output [xx:0] dbg
);
```

The 16 registers of 5.5 and the commands, taken on the **rising edge of
PH3** while enabled (5.10): direction, step (a track counter 0-79, track 0
sensed; the step's settle time is rung 2's), motor on/off, eject latch
and its reset, MFM/GCR mode. `sense` is 1 when not enabled.

**The machine**: `se30_swim` on the device port (`dev_rdata` gains the
SWIM, the VIAs' convention), reset by `via_reset_n`; `sense` = the enabled
drive's register or 1; the drive's SEL = `via1_pa_pin[5]` (VIA1's `pa_ext`
bit 5 stays 1: the pin is an output after the VIA initialisation, and
undriven before it reads 1 as the other port lines do). A new probe
**`PSWM`** in `rtl/dbg_probes.sv` and `read_probes.tcl`: the IWM latches
and mode, the ISM flag, mode and setup, the phases, both enables, SENSE,
and the drive's motor, track and mode.

## 5.9 The benches

**`sim/swim/`** (iverilog), the chip and the drive together behind a
device-port driver that replays the ROM's own access sequences:

1. Reset values: latches, IWM mode 0, ISM mode/setup/error 0, phases
   `$F0`, handshake idle.
2. The sixteen IWM latch addresses, each setting or clearing its latch,
   seen on the pins.
3. The IWM register table: each of the six by {L7, L6, MotorOn}, with the
   new-state rule (a read at `$1C00` from L7 = 1 reads status, not
   handshake), and writes only at L6 = L7 = 1 with A0 = 1.
4. **The mode-set loop of 5.6 item 1**, replayed: it exits with mode `$17`
   in two passes from reset.
5. The MotorOn timer: with mode bit 2 = 0, `/ENBLx` held 2^23 + 100 FCLK
   after MotorOn clears, status bit 5 with it, and a write at L6 = L7 = 1
   reaching the data register while it runs; with bit 2 = 1, released at
   once; M16/M8 doubling it.
6. The switch: `$57/$17/$57/$57` enters the ISM; a wrong fourth write, or
   MotorOn set, does not; write-zeros bit 6 returns.
7. The phase register: `$F5/$F6/$F7` read back whole; direction bits
   honoured in both sets (the chip spec's reading, 5.2.3).
8. Mode write-zeros/write-ones, bit 6 reading 1, status = mode.
9. Parameter RAM: sixteen writes and reads auto-incrementing, the index
   reset by a write-zeros write.
10. Setup readback; the IWM configuration bits through register 2 with
    ACTION low.
11. The drive through the ROM's encoding (`$4082E0EC`/`$4082E12E`): the
    empty internal FDHD reads `$D` = 0, `$9` = 1, `$5` = 1, `$F` = 1,
    `$2` = 1, `$C` = 0; the absent external reads 1 at every register.
12. Drive commands (`$4082E150`'s PH3 pulse): motor on/off (`$8`/`$9`
    and `$8` reading back), direction and step to and from track 0,
    eject-latch reset `$3`, MFM/GCR `$6`/`$7`.
13. **The Open probe of 5.6 item 3, replayed end to end**: all three
    echoes match, the exit leaves the IWM selected with L7 clear, then
    Open's drive reads as item 11.
14. The access rule: consecutive SWIM accesses are 4 FCLK or more apart
    (`/DEV` high that long, chip spec rule 5). **Corrected while building:
    the gap is the CPU's instruction timing as much as GLUE's, so it is a
    monitor in `sim/machine`, not a `sim/glue` check, and it can only run
    once that bench reaches the SWIM (5.11 item 4).** The model does not
    depend on it either way.

**`sim/machine`**: the bench ends in the RAM tests (3.8 item 23), well
before the loop. A **bench-only ROM patch that skips the RAM tests** (as
`run.sh` already shortens the checksum) would let it run through the
loop and out; it is proposed, not assumed - it trades a patched ROM for
reach, and the board is the verdict either way (5.11 item 4).

## 5.10 Risks and open items

- **Phase direction in IWM mode**: the chip spec against the User's Ref
  (5.2.3); we follow the chip spec. Invisible to the ROM; one line to
  change.
- **"Four consecutive writes"**: our reading (successive mode-register
  writes) is not stated in so many words; the ROM's sequence works under
  any reading.
- **The absent drive's SENSE level** (5.5): the ROM requires 1; the
  pull-up is not traced on sheet 6.
- **Drive levels without ROM evidence** (5.5, "chosen"): power-up
  direction, head position, GCR mode, the read-data registers' idle.
  None is read on rung 1's path.
- **The drive's command edge**: taken on PH3 rising; the ROM's pulse
  (high, two NOPs, low) works on either edge.
- **A CPU read of a chip-write address** latches undefined data (5.4).
  The ROM never does it. **A read of an undriven IWM address** (A0 = 1,
  not writing) returns floating lanes on the machine; the model returns
  the selected register. The ROM discards every such byte on rung 1's
  path.
- **The IWM's cell-time paragraph** is garbled in the OCR (5.2.1); rung
  2 reads the page image.
- **The timer at C16M** is 535 ms, not "about 1 second"; the ROM's mode
  `$17` disables it at start-up anyway.
- **The boot beyond the loop** runs into 4.10's risks (ADB, RTC, SCSI
  probes) before it reaches the SWIM's Open; the board may stop at one of
  those first.

## 5.11 The work

1. ~~Write this section.~~ **Done 2026-09-27.**
2. ~~**`sim/swim/`** items 1-13, failing, then **`rtl/se30_swim.v`** and
   **`rtl/se30_fdhd.v`** to 5.2 and 5.5 until they pass.~~ **Done
   2026-09-27: 92 checks** (the empty stubs fail 59 of them; the rest are
   levels a do-nothing chip happens to share). Both timers measure exactly
   2^23 + 100 and twice that FCLK. Two things the bench made concrete: the
   "MOTOREN must be low" rule for entering the ISM is structural - with
   the delayed MotorOn up, L6 = L7 = 1 selects the data register, so the
   four mode writes cannot happen; and leaving the ISM, the ROM's `$F8`
   clears MotorOn and bit 6 in one write, so MOTOREN is judged as the
   write leaves it. Item 14 moved to `sim/machine` (5.9).
3. ~~**The machine**: the instances and wiring of 5.8, `dev_rdata`, SENSE,
   SEL from VIA1 PA5; `PSWM` in the deck and `read_probes.tcl`.~~ **Done
   2026-09-27.** The SWIM is reset by `via_reset_n` (the RESET
   instruction too), the drive by `reset_n` only. `sim/machine` still 17
   PASS with the same prediction (it ends in the RAM tests, before the
   loop); elaboration 0 errors, 82 warnings (the count before the SWIM).
4. **`sim/machine`**: Daniel's call on the bench-only RAM-test skip
   (5.9); with it, the bench's prediction moves past `$408006E6`.
5. Elaboration (done, item 3); then the compile - **Daniel's go-ahead
   given 2026-09-27** - the 3.6 ritual and `sta_corners.tcl`; the board: `PIFA` out of the loop, `PSWM` mode
   `$17`, then wherever the start-up goes next - the question mark is the
   target.
   **Compile 15 (tag `60481ce0`, archived `MacSE30_60481ce0_swim1.rbf`,
   md5 `c2f6aeb6...`): 21m41s, the flow's worst slack +0.065 ns;
   `sta_corners.tcl`: every corner met with the capture excepted (worst
   1.065 ns, up from compile 14's 0.687), and at every corner one of the
   two captures met on setup and hold (A's hold -0.141 at fast -40C, B's
   1.853 there - the two-capture design of 3.8 item 18 doing its job).
   Waiting for the board: `read_probes.tcl`, `PSWM` and the screen.**

   **THE BOARD (compile 15, 2026-09-28): RUNG 1'S JOB IS DONE; THE NEXT
   STOP IS THE KERNEL'S BUS-FAULT RETURN, NOT THE SWIM.** `PSWM`: IWM mode
   `$17`, the loop left; the start-up chain went on (`$4080066C`,
   `$40800532` - three level-1 acknowledges: `TimeDBRA` - VIA1 IER `$03`)
   and ended in the serial test manager with **D6 = 3, D7 = `$0002000F`**.
   Read from the ROM, not assumed:
   - D7 = `$F` is not a start-up test: `$408021D4` is the System Error
     path when the alert tables (`$2BA`) do not exist yet - D6 =
     DSErrCode (`$AF0`), D7 = `$F`, into the test manager.
   - Code 3 is the stub for vector 4: the early vector stubs at
     `$408020FA + 2n` are `bsr $408020B8`, which recovers n from its
     return address; vector 4 points at `$408020FE`, n = 3. **An illegal
     instruction.** The handler saves D0-A7 at `$C30`, SR at `$C74` and
     **the PC at `$C70`**.
   - A JTAG peek of `$C30-$C7F` (after the crash recurred - a peek resets
     the machine, so each peek needs a fresh crash): **PC `$408043F8`**,
     SR `$2700`, A7 `$0003FF5E`. `$408043F8` is the middle of `move.l
     (a2), $8.w` (`21D2 0008`): the `$0008` extension word ran as an
     opcode (ORI.B to An, illegal).
   - The code there is the Slot Manager's probe of the empty slots
     (`$408043C4`...): `move.b (a5), d1` at `$408043F4` reads
     `$F9FFFFFF` (slot 9, then `$A`-`$E`) with vector 2 pointed at
     `$40804F28`. That handler counts D7 down from 100 (`$64`) and **RTEs,
     re-running the faulted read**; at 0 it **discards `$5C` = 92 bytes -
     the MC68030's long bus-fault frame, format `$B`** - builds a format-0
     frame to the continuation `$40804484` (slot empty, next slot) and
     RTEs.
   - Ours resumed at `$408043F8`, four bytes past the faulting
     instruction. So the kernel's frame for an external `BERR*` on a data
     read, or its RTE of that frame, is not the 68030's. **This belongs to
     the kernel (Section 1, `cpu-bus`)**, documentation first: MC68030 UM
     section 8 (the bus-fault frames, which one a data fault takes, what
     RTE does with a format `$B` frame - re-run the cycle), then a bench
     that does what the ROM does (BERR on a data read, RTE 100 times,
     unwind `$5C`) before any change. The SWIM's rungs 2-3 wait behind
     it: the `.Sony` Open comes after the Slot Manager.
6. **The kernel's external bus error on a data read, fixed (2026-09-28,
   Daniel's go-ahead).**
   - **The manual** (MC68030 UM 3rd ed., section 8): "data read faults
     only generate the long bus fault frame" (8.2.2); the frame's PC is
     "the logical address of the instruction that was executing at the
     time the fault was detected" (8.1.2); "if the DF bit is set when the
     processor reads the stack frame, it reruns the faulted data access",
     and a fault on the rerun deallocates the frame and builds a new one
     (8.2.1, 8.2.3); "when a bus error exception occurs while accessing a
     data item, the exception is taken immediately after the bus cycle
     terminates" (8.2).
   - **The bench first: `sim/busfault/`** (ModelSim; `tg68k.v` and GLUE,
     whose UI6 timeout raises the BERR as on the board). The program is
     the ROM's probe (`$408043EA-F6`) and its handler (`$40804F28`) byte
     for byte, with an entry counter and end markers; the bench captures
     the first frame as the kernel writes it. 11 checks. **On the
     committed kernel it failed as the board did**: the run ended in the
     illegal-instruction stub after one handler entry; the frame was
     right in format (`$B`, 92 bytes, vector `$008`), SSW (`$0155`: DF,
     byte read, supervisor data) and fault address (`$F9FFFFFF`), but
     **its PC was `$102E` for a faulting instruction at `$102A`** - the
     kernel's own report: `exe_pc` `$102A`, `tg68_pc` `$102E` stacked.
   - **The cause**: the kernel implements "rerun the faulted access" for
     PMMU data faults by instruction restart - the register file rolled
     back to the instruction's start and the frame carrying `exe_pc`, so
     a plain RTE re-executes it (`mmu_restart_pending`, the "MMU RESTART"
     design) - but an **external** BERR never armed it, and its frame
     stacked `TG68_PC`, the prefetch pointer.
   - **The change** (`TG68KdotC_Kernel.vhd`, one `IF` after the no-fault
     clear in the first-fire block): an external BERR on a data read
     (`fc_internal(1:0) = 01`, `pmmu_rw = 1`, not locked) arms the same
     restart (`mmu_restart_pending`, `berr_restart_pc <= exe_pc`).
     Writes and locked cycles keep the old path: the bench covers reads
     only, and the ROM's need is a read.
   - **After**: `sim/busfault` 11 PASS at N = 3 and at the ROM's N = 100
     (100 entries, 100 bus errors, the SP back where it was after the
     92-byte unwind); `sim/kernel_bus` ports 32/16/8 PASS (181/242/328);
     `sim/system` 23 PASS; `sim/kernel_upstream` verdicts unchanged (14
     pass, the three known), and upstream's `tb_berr_frame`,
     `tb_rte_stress`, `tb_rte_format_a_replay`, `tb_mmu_fault_recovery`,
     `tb_mmu_user_data_fault_recovery` pass before and after (none of
     them takes an external data-read BERR: `tb_berr_frame` is PMMU
     write-protect faults). `sim/machine` 17 PASS, **one bus cycle
     fewer**: traced, the committed kernel ran a stray prefetch
     (`$40802A3C`) between the ROM's faulted read of `$58000000` and the
     frame; now the frame follows the faulted cycle at once, as 8.2 says.
     The prediction's `PACT` moves 3815 -> 3814 and nothing else.
   - **Compile 16 (Daniel's go-ahead; tag `91f56454`, archived
     `MacSE30_91f56454_berr.rbf`, md5 `798607f4...`)**: 21m11s, the flow's
     worst slack +0.068 ns; `sta_corners.tcl`: every corner met with the
     capture excepted (worst 0.906 ns), one of the two captures met at
     every corner. (Its slow-100C line shows capture B's setup at -0.335
     ns - as in compile 15, identical: capture A serves the slow corners,
     1.6 ns, and the training picks it.) For the board: past the Slot
     Manager to the `.Sony` Open (`PSWM` PH = 7), the target the
     question-mark disk.
   - **THE BOARD (compile 16, 2026-09-28): THE GREY DESKTOP PATTERN ON
     THE SCREEN.** The ROM got past the Slot Manager, drew the desktop
     through the video of Section 2, and runs normal code: no test
     manager, no bus errors, the VBL at ~61/s (`PIRQ` level 1 3183 ->
     3367 over three samples). **It now waits in the ADB Manager's
     initialisation**, as 4.10 foresaw: at `$40806D94` it makes VIA1
     PB4/PB5 outputs (DDRB `|= $30`: the ADB state lines), clears the
     PCR, enables the shift-register interrupt (IER `$84` - `PVIA` VIA1
     IER `$07`), sets bit 5 of the ADB flags (`$15D(a3)`), starts the
     first transaction (`bsr $40806DEA`), opens interrupts and loops at
     **`$40806DD8`** until the shift-register interrupt's handler clears
     that bit. With no ADB transceiver nothing clocks the shift register
     (CB1 idle, 4.7), so no interrupt comes. The `.Sony` Open comes after
     it (`PSWM` PH still 0). **Next: the ADB section (with the RTC), from
     its documentation first**; the SWIM's rungs 2-3 after it.
7. **Rung 2** (read) and **rung 3** (write): written as 5.12 and 5.13
   when rung 1 is on the board, from 5.2.4's sources. **5.12 written
   2026-09-28 (GCR first; MFM becomes 5.13, and rung 3 follows it).**

## 5.12 Rung 2: reading - GCR first

Opened 2026-09-28, after compile 18 put the flashing question-mark disk on
the screen with a working mouse (6.12 item 7). Written before any RTL,
documentation first; the donors were read after the documents, as
cross-checks and for their bug histories.

**Daniel's decisions, 2026-09-28.**

- **The whole image lives in SDRAM**, loaded from the card when it is
  mounted - the MacPlus design (`FLOPPY_WRITE_PLAN.md` phase 1), which
  MacLC took over - through a new disk port on `se30_sdram` in the region
  3.3 reserved for it. **The drive plays each track as a bitstream held in
  BRAM**, built by an encoder when the head arrives - the structure of the
  Apple-IIgs core's flux path. Seeks read SDRAM in a burst; the rest of
  the time the drive touches nothing but its own BRAM.
- **GCR first, then MFM.** 800K and 400K GCR, which the ROM reads through
  the IWM (5.12.6), are built, benched and put on the board first; the
  ISM's MFM read (720K and 1.44 MB) is 5.13, from the ISM ASIC spec, after
  that. Nothing here is fitted to a particular image: Daniel's first test
  disk is a raw 819,200-byte 800K image, and it is a test, not a target.

### 5.12.1 Sources, and their standing

New in `C:\temp\Mac\SE30\Docs\swim`, downloaded 2026-09-28 with Daniel's
OK and size-checked:

| source | what | standing |
|---|---|---|
| **`IWM_Spec_Rev19_1982.pdf`** (18 pp.; brutaldeluxe.fr, also archive.org), Apple's *Integrated Woz Machine Device Specification*, revision 19, 24 Sep 1982 | the IWM's registers, modes, timing, and **page 10's "Read data bit cell windows" table** - the data separator's windows by mode, which the SWIM drawing's section 6.6 refers to ("the data patterns noted above") and does not carry | **primary for the IWM's read path**; the SWIM drawing (343S0061-A) outranks it where they differ (the B revision's blanking, 5.12.2) |
| **`669-0452-A_800K_Double-Sided_ERS_Sep86.pdf`** (47 pp., bitsavers `sony/MP-F51_specs/`), Apple's engineering requirement specification for the 800K double-sided drive; and its earlier revision `699-0321_800K_Double-Sided_ERS_Aug85.pdf` (46 pp.) | the drive's interface: the register and command table, every signal's meaning, **the timing** (step, settle, motor start, READY, RD pulses), **the zone speeds and the 489.6 kbit/s data rate**, the tach, and the **track format** (sector layout, fields, GCR table, checksum, interleave) | **primary for the drive in GCR mode.** The SE/30's drive is a Sony MP-F75W-01G SuperDrive (the BOMARC set names it); in GCR mode it presents the 800K drive's interface, and its MFM additions are 5.5's and 5.13's |
| The SWIM drawing's sheets 52-53 (page images; the OCR garbles them) | the cell time per mode ("in 8M and slow mode the cell time will be 32 periods"), the read rules, the B revision's blanking window | primary |
| The ROM: the `.Sony` power-up, recalibrate and seek (`$4082E17A`-`$4082E3CA`), the ISM entry (`$4082E712`), **the GCR read routines** (`$40831BE8` address field, `$40831CC2` data field) | what the machine does with the chip and the drive | documentation tier (1.11) |
| `Mac_v_IIgs_sectors.pdf`, `superdriveDD.png`, `superdriveHD.png` | a two-page sector note; two screenshots of a modern analysis tool | background; the images are not Apple documents and are not used |
| MacPlus `FLOPPY_WRITE_PLAN.md`, `rtl/floppy_loader.v`, `floppy_track_encoder.v`, `floppy_track_decoder.v`, `floppy.v` | our own lineage: the block-device loader, the byte-level GCR encoder and its decoder, phases 0-8 and the defects each hardware run found | donor for image handling; its bug history becomes bench checks |
| MacLC `floppy-write` branch: `docs/floppy_write_plan.md`, `docs/findings_mame_floppy_groundtruth_2026-07-02.md` (F1-F12), `docs/swim_ism_read_reference.md`; `rtl/floppy_sd.v` | the same lineage moved to a SWIM machine, with a register-by-register comparison against MAME traces of the LC ROM | donor and bug list; the findings are **MAME-derived (secondary)** and are used as test cases, not as evidence |
| Apple-IIgs core `rtl/flux_drive.v`, `iwm_flux.v`, `woz_floppy_controller.sv` (GPLv3, Alan Steremberg, "Reference: MAME iwm.cpp") | a bit-level IWM and a drive that plays per-track bitstreams from BRAM and loads tracks on seek | the architecture only; its behaviour is MAME's reading and carries no weight |

### 5.12.2 The IWM's read path

From the IWM spec (pp. 2-4, 10) and the SWIM drawing (sheets 52-53):

- **The read state** is L6 = L7 = 0. "A falling transition within a bit
  cell window is considered to be a one, and no falling transition within
  a bit cell window is considered to be a zero." RDDATA is synchronised to
  CLK (FCLK in fast mode, FCLK/2 in slow).
- **The windows** (IWM spec p. 10). *Nclks* is the number of CLK periods
  between one synchronised falling transition and the next; "each falling
  transition resets the read data windows for subsequent data to be
  relative to that transition":

  | mode | CLK | Nclks | shifted in |
  |---|---|---|---|
  | slow, 8M | FCLK/2 | 8-23 | `1` |
  | | | 24-39 | `01` |
  | | | 40-55 | `001` |
  | | | (window 16 clks) | |
  | fast, 8M | FCLK | 8-23 / 24-39 / 40-55 | the same |
  | slow, 7M | FCLK/2 | 7-20 / 21-34 / 35-48 | (window 28 FCLK) |
  | fast, 7M | FCLK | 7-20 / 21-34 / 35-48 | (window 14 clks) |

  **The ROM's mode is `$17`: slow and 8M** (5.6 item 1), so CLK is FCLK/2
  = 7.8336 MHz and the window is 16 CLK = **32 FCLK = 2.0425 us** - the
  drawing's "in 8M and slow mode the cell time will be 32 periods" - and
  the 800K drive's data rate is **489.6 kbit/s = one bit per 32 FCLK
  exactly** (ERS p. 39). The machine's clock was chosen for the drive.
  Past 55 the table stops (GCR never writes three zeros); the model goes
  on shifting a zero at each further window boundary (72, 88, ...), the
  one-shot's natural continuation, and records it as an extrapolation.
- **The B revision's blanking** (drawing sheet 53): "after falling
  transition of RDDATA there is a window during which subsequent falling
  transitions are ignored. In 8M FAST mode this window is 6 FCLK periods
  ... For SLOW mode the windowing is twice as long" - **12 FCLK** here.
  The SWIM is the later part, so this applies. The same passage states
  the edge's uncertainty: RDDATA is synchronised to CLK, so in slow 8M a
  transition under 12 FCLK after the last is always ignored, one between
  12 and 14 FCLK "sometimes", and one over 14 always taken (7M slow: 10,
  12). The RTL ignores Nclks 6 and takes Nclks 7 (14 FCLK) and up, as `1`
  until the table's first band.
- **The shift register**: data enters at the LSB; "a full data nibble is
  considered to be shifted in when a one shifted into the MSB"; it is then
  latched into the read data register and the shift register cleared.
- **Asynchronous mode** (the ROM's mode has bit 1 set): "the data register
  will latch the shift register when one is shifted into the MSB and will
  be cleared 14 FCLK periods (about 2 us) after a valid data read takes
  place (a valid data read being defined as both /DEV being low and D7
  (the msb) outputting a one from the data register for at least one FCLK
  period)". Latch mode (bit 0, set) is what makes the register hold until
  that read. The synchronous mode's stall rule is not used by the ROM and
  is built only as far as the spec states it.
- **Where it is read**: the data register is selected at L7 = 0, L6 = 0,
  MotorOn = 1 (5.2.1); the ROM reads it at `$1800` (L6 cleared by the
  access itself, 5.12.6).
- **RDDATA and SENSE** are one line on this board (5.3): the drive's RD
  output carries either a status bit or, when the drive is addressed to
  register `$1`/`$3`, the read data of the head SEL picks (5.5).

### 5.12.3 The drive, as the 800K ERS specifies it

Sheet numbers are the ERS's (669-0452-A); the rung 1 table of 5.5 stands,
and three of its "chosen" entries are now documented.

- **RD in data mode** (3.2.4.5, 3.4.1.2): the data from the side SEL
  selects. Each flux transition is a low pulse of **0.3-0.8 us** (T4),
  spaced 2, 4 or 6 us nominally (T5); data is valid **100 us at most**
  after SEL changes (T2). The model: a low pulse of 8 FCLK (0.51 us) at
  each `1` of the track bitstream, the bitstream advancing one cell per
  32 FCLK; a head switch takes effect at once (inside T2).
- **Rotation** (2.4 and p. 39): five speed groups, **394, 429, 472, 525
  and 590 rpm** for tracks 0-15, 16-31, 32-47, 48-63, 64-79, "± 2.5%" -
  with the data rate fixed at 489.6 kbit/s, so the cells per revolution
  are **74,558 / 68,476 / 62,237 / 55,954 / 49,790**. The model runs at
  the nominal speeds exactly.
- **/TACH** (3.2.4.11): **60 pulses per rotation**. None of the ROM's
  drive-register reads that load a constant register number reads it
  (5.12.6); others take the number from a register, so it is built to the
  ERS regardless.
- **/STEP** (3.2.4.2): "At the falling edge of this signal the destination
  track counter is counted up or down depending on the /DIRTN level. After
  the destination counter in the drive received the falling edge of
  /STEP, the drive sets /STEP to high" - the ROM polls register `$4`
  until it reads 1. **LSTRB acts on its rising edge** (3.2.3: "At the
  rising edge of LSTRB the level of CA2 will be set into the latch") - the
  edge rung 1 already takes (5.10).
- **/READY** (3.2.4.12): "a zero when the head position is settled on
  desired track, motor is at the desired speed, and a diskette is in the
  drive". Its times are the ERS's **maxima**, as the timing that any drive
  the ROM was written for would meet: after a step **36 ms** in the same
  speed group, **152 ms** across a group change (3.4.3.3 T2; the settling
  table gives 30 ms track-to-track); after motor-on or disk-in **600 ms**
  (3.4.4 T1). These are "build to spec" values (`feedback-replicate-bugs-
  else-spec`, tier 2), not measurements of a drive.
- **/CSTIN** (3.2.4.8): 0 when a diskette is in. **/WRTPRT** (3.2.4.9): 0
  for a write-protected diskette or none - **rung 2 reports every disk
  write-protected**, so the Mac never writes (the MacPlus and MacLC
  starting point, and the handshake a write needs is rung 3's).
- **/TK0** (3.2.4.10): 0 at track 0.
- **/DIRTN** (3.2.4.1): 0 = toward the centre; "When /ENBL is high /DIRTN is
  set to zero". **/MOTORON** (3.2.4.3): "When /ENBL is high, /MOTORON is set
  to high" - the drive's latches return to their idle states when it is
  deselected, which rung 1's model does not yet do.
- **EJECT** (3.2.4.4): set by the command, cleared at the rising edge of
  /CSTIN or 2 s after.
- **The SuperDrive's own** (5.5, the ROM and MacLC's F3/F4/F12, which
  agree): `$5` reads 1 (a SuperDrive); `$F` reads **1 for a double-density
  medium, 0 for high density** - so an 800K disk reads 1; `$7` (MFM mode
  on) follows commands `$6` (MFM) and `$7` (GCR) and the ROM reads it
  back (`$4082E386`); RD at `$1`/`$3` reads 1 with the motor off or no
  disk.

### 5.12.4 The track, as the ERS formats it

"Sector Format" (pp. 40-42) and the User's Ref (pp. 5-6):

- **Header sync**: at least 5 self-sync bytes - each an `FF` followed by
  two zero bits, a ten-bit group (the byte-level `FF 3F CF F3 FC FF`); the
  formatter "should make this field as large as possible".
- **Header field** (11 bytes): `D5 AA 96`, track (low 6 bits), sector,
  side (bit 5 the side, bit 0 the track's high bit), **format** ("decoded
  bits 0-4 define the format interleave: standard 2:1 interleave formats
  have a 2 in the field"; bit 5 the double-sided flag - `$22` for an 800K
  disk, `$02` for 400K, the value MacPlus and MacLC emit and the LC ROM
  was traced accepting), checksum (the XOR of the four), `DE AA`, and a pad
  byte "where the write electronics were turned off".
- **Data sync**: at least 5 self-sync bytes.
- **Data field** (710 bytes): `D5 AA AD`, sector, the 524 bytes (12 tag,
  512 data) nibblised into 699 codes, the 24-bit checksum in 4 codes,
  `DE AA`, a pad. The checksum and the 6-and-2 split are the ERS's steps
  1-9 (p. 42); the codeword table is the ERS's (p. 42) and the User's
  Ref's.
- **Interleave** (p. 40), 2:1: 12 sectors `0 6 1 7 2 8 3 9 4 10 5 11`; 11
  `0 6 1 7 2 8 3 9 4 10 5`; 10 `0 5 1 6 2 7 3 8 4 9`; 9 `0 5 1 6 2 7 3 8
  4`; 8 `0 4 1 5 2 6 3 7`. (The OCR garbles the first two lines; these
  are the standard 2:1 sequences the others follow.)
- **Spacing**: "the sectors are written so that they are spaced evenly
  around each track" (User's Ref p. 6). The encoder divides the zone's
  cells per revolution among its sectors and fills each sector's header
  sync to its share, so the track is exactly one revolution long.
- **Blocks and sides** (p. 39): block *n* is side 0 then side 1 of each
  cylinder ("blocks 0-11 will be on side 0, track 0, blocks 12-23 will be
  on side 1 track 0"); a 400K (single-sided) image is side 0 only, 800
  blocks.
- **The bitstream**: bits as they pass the head, 1 = a transition, one per
  32 FCLK. The self-sync groups are ten bits, not eight - the reason the
  IWM's shift-until-MSB rule locks onto them.

### 5.12.5 The image, the loader and the disk port

- **Formats**: raw sector images (819,200 bytes = 800K double-sided,
  409,600 = 400K single-sided) and **DiskCopy 4.2** (an 84-byte header -
  name, data size, tag size, checksums, the disk-format byte at offset
  `$50`: 0 = 400K, 1 = 800K, 2 = 720K, 3 = 1440K - then the data, then 12
  tag bytes per sector). The DC42 layout is from MacLC's reference
  appendix and MacPlus's loader (secondary; Apple's own description is in
  the Apple II file-type note for `$E0/$0005`, not on hand). A DC42's size
  never matches a raw size test once its tags are present (MacLC's
  838,400-byte payload lesson); geometry comes from its format byte.
- **The loader** (MacPlus `floppy_loader.v`, as MacLC carried it): on the
  slot's `img_mounted`, stream every 512-byte block through `sd_rd` into a
  staging BRAM and out to SDRAM at word `$800000`, the header stripped;
  **the disk counts as inserted only when the load is complete** (MacPlus
  phase 1: the Mac must never see a partial image); clear-on-mount; the
  read-only flag latched at the slot's own mount pulse.
- **Sidedness** (MacPlus phase 7): the medium's own volume says whether
  it is 400K or 800K - the MDB at file sector 2, `drNmAlBlks x drAlBlkSiz`
  against 1200 blocks - under two ceilings: the drive (the SuperDrive is
  double-sided) and the file (a 409,600-byte file is never double-sided).
  The encoder's format byte and the geometry both come from that one
  verdict.
- **The disk port** on `se30_sdram`: 16-bit words, a level request with
  address, write flag and data frozen by the requester until the level
  acknowledge (3.3's contract, and MacPlus phase 1's two bugs - a request
  torn down before the column was sampled, and a data mux keyed on a
  pulse - are exactly what a level handshake held to the acknowledge
  prevents); reads return the word with the acknowledge. Scheduled like
  the download port, in idle windows between CPU cycles. The loader
  writes through it at mount; the encoder reads through it at a seek.
- **The HPS side**: one `S` mount slot for the internal drive (`VDNUM` 1,
  `BLKSZ` 512 bytes, `WIDE` 1) - the external drive stays absent (5.5).

### 5.12.5b The encoder

When the head settles on a cylinder (or a disk is inserted), the encoder
reads that cylinder's sectors for both sides from SDRAM - 12 x 524 bytes
a side at most, tags included when the image has them, zeros when it has
none - and writes the two sides' bitstreams into two BRAM track buffers
(74,558 bits each at most, fifteen M10Ks for the pair). At the machine's
clock this takes a few milliseconds, inside the settle time /READY
already covers; **/READY stays high until both buffers are written**, so
the ROM can never read a half-built track. The drive's playback position
is a cell counter modulo the zone's cells per revolution, running
whenever the motor turns, carried across a step (the disk keeps
spinning; a zone change rescales it).

### 5.12.6 What the ROM does to read a GCR disk

1. **Insertion**: the VBL task (`$4082E444`, every 30 ticks) reads `$2`
   (disk in place) and, on a 0, posts a disk-inserted event; the File
   Manager mounts through the `.Sony` driver.
2. **The ISM entry** (`$4082E712`): probes the ISM's phase register; for
   a GCR disk (`$17(a1,d1)` clear) it returns to the IWM (`$F8` to
   write-zeros, L7 cleared) and re-runs the mode `$17` loop (`$4082E2F2`).
   Nothing new for the chip: rung 1 handles every step.
3. **Power-up** (`$4082E376`): read `$7` (MFM mode), command `$7` (GCR,
   or `$6` for MFM), read `$8` (motor), command motor on when it was off
   or the mode changed, then poll `$B` (/READY) up to 1000 delays of the
   ROM's timer.
4. **Recalibrate** (`$4082E29E`): direction outward (`$1`), then step
   (`$4` strobed) until `$A` (/TK0) reads 0, at most 80 times.
5. **Seek** (`$4082E17A`): direction, steps, `$4` polled until the step
   is taken, then the settle wait on `$B`; with the ISM present, the
   parameter check `$4082E7CC` first.
6. **The read** (`$40831BE8`): the drive addressed to `$1` or `$3` (the
   head), `a4` = the SWIM base + `$1800`, **`move.b (a4),d5 / bpl`** until
   a byte with the MSB set; `D5 AA 96` sought within `$5DC` bytes
   (`$5BC` for one drive kind), the header's five nibbles through the
   decode table at `$40831E08`, the checksum, `DE AA`; the data field
   (`$40831CC2`) the same way. Between bytes it polls VIA1 PA7 for the SCC
   (`$50F01E00`, reads 1 with no SCC - harmless). The error codes it
   returns (`noNybErr` `$BE`, `noAdrMkErr` `$BD`, `badCksmErr` `$BB`,
   `badBtSlpErr` `$BA`, `noDtaMkErr` `$B9`) name each stage for the
   probes.

### 5.12.7 The donors' bugs, carried as checks

From MacPlus's plan and MacLC's findings, each already paid for once:

- **Loader**: a request torn down before the SDRAM sampled its column;
  a data mux keyed on a pulse (MacPlus phase 1); the DC42 tag payload
  that passes no raw size test; four damaged DC42s among nineteen real
  ones - **verify a fixture before gating on it** (MacLC phase 1).
- **Encoder**: the nibbler's one-group lookback (both); a stream that
  must be generated with sparse fetches, not every clock (MacPlus phase
  0); negative tests on **one revolution only** - a capture of two holds
  every sector twice and "recovers" a corrupted one from the other copy
  (MacLC phases 0 and 2).
- **Sidedness**: the format byte from the file size (MacPlus phase 7);
  a latch that outlives its disk.
- **Drive** (MacLC F3, F4, F12): `$F` inverted; `$7` constant instead of
  following its commands; RD at `$1`/`$3` not 1 with the motor off.
- **Benches**: an uninitialised `integer` that makes the DUT look dead
  (MacLC phase 2); a `wait (done)` that falls through on the previous
  pulse (MacPlus phase 7); a reset deasserted on the DUT's own edge.

### 5.12.8 The RTL

- **`rtl/se30_swim.v`**: the IWM read path of 5.12.2 - RDDATA
  synchronised, the 12-FCLK blanking, the window counter and shifter, the
  read data register with the asynchronous latch-and-clear, the mode's
  fast/slow and 7M/8M bits choosing the counts.
- **`rtl/se30_fdhd.v`**: the drive of 5.12.3 - disk in, motor with its
  start time, rotation and /TACH by zone, step with the destination
  counter and /STEP, /READY by its three conditions and times, /TK0,
  /WRTPRT (always 0 on rung 2), EJECT, the SuperDrive registers, the latch
  reset on deselection, and **RD in data mode played from the BRAM
  bitstream of the head SEL picks**.
- **`rtl/se30_flp_encoder.v`** (new): SDRAM sectors -> the two track
  bitstreams, 5.12.4 and 5.12.5b; the GCR table, checksum and nibbling
  written from the ERS, with MacPlus's `floppy_track_encoder.v` as the
  cross-check its bench compares against.
- **`rtl/se30_flp_loader.v`** (new): the loader and sidedness sniff,
  lifted from MacPlus/MacLC's `floppy_loader` and adapted to the disk port.
- **`rtl/se30_sdram.v`**: the disk port (5.12.5).
- **The top and the machine**: the `S` slot and `hps_io`'s block-device
  signals, the loader and encoder beside the controller, the drive's disk
  interface into the machine; a probe `PFLP` (the drive's track, side,
  motor, READY, the encoder's state, the loader's progress, the sectors
  the IWM has delivered).

### 5.12.9 The benches

1. **`sim/swim`** gains the read path: each band of the window table
   (Nclks 7, 8, 23, 24, 39, 40, 55, 56) shifting what p. 10 says; the
   12-FCLK blanking; the latch and its clear 14 FCLK after a valid read,
   and not after an invalid one; self-sync groups locking the shifter
   within five of them from any bit offset.
2. **`sim/fdhd`** (new): the zone lengths and /TACH at 60 per revolution
   for each group; /STEP and the destination counter; /READY's three
   conditions and times; the SuperDrive registers (MacLC F3, F4, F12);
   RD's data pulses 8 FCLK wide on the bitstream's ones; the latches reset
   on deselection.
3. **`sim/flpenc`** (new): a synthetic self-identifying image (MacLC's
   pattern: bytes 0-2 of each sector are its track, side and sector), every
   track of both sides encoded, and **a reference decoder in the bench**
   recovering all 1600 sectors byte for byte, their tags, the interleave
   and the format byte - plus MacPlus's encoder run on the same image as a
   second opinion; negative cases on one revolution only.
4. **`sim/flpload`** (new): raw 800K and 400K, DC42 with and without tags,
   the sidedness sniff's cases (MacPlus phase 7's eleven), the disk counted
   in only at the end of the load, a remount.
5. **`sim/sdram`**: the disk port against the real controller with the CPU
   port running - reads and writes interleaved, nothing lost or torn.
6. **`sim/gcrread`** (new, the gate): image -> loader -> SDRAM model ->
   encoder -> drive -> SWIM, and a driver that replays the ROM's own
   sequences (the power-up of 5.12.6 item 3, a recalibrate, seeks, and the
   read loops of item 6 byte for byte) - every sector of the synthetic
   image recovered through the ROM's decode table, at every zone.

### 5.12.10 The board

With an 800K image mounted in the slot: the flashing question mark gives
way to the disk being read - the happy Mac and a boot attempt. How far
the boot goes then depends on the machine beyond the floppy (4.10, the
ASC, SCC and SCSI still absent), and that is the next section's to find.
The probes say where it stops.

### 5.12.11 Risks and open items

- **The window table's upper end** (beyond Nclks 55) is extrapolated
  (5.12.2); GCR never exercises it.
- **/READY's times** are the ERS's maxima (5.12.3); a real drive is
  faster, and a slower boot is the cost of not guessing.
- **Rotation at exact nominal speed**, no jitter and no peak shift: the
  IWM's windows have margin to spare for a perfect stream; the timing
  margin the ERS specifies (2.10) is a drive property this model does not
  need to reproduce to read.
- **The self-sync count** per sector is set by spacing the sectors
  evenly; the ERS gives only minimums. The ROM searches `$5DC` bytes for
  an address mark - more than a whole sector's length - so any even
  spacing is found.
- **DiskCopy 4.2's layout** comes from secondary sources; the loader's
  header checks (name length, the `$0100` magic) and the fixtures'
  checksums guard it.
- **The SDRAM disk port** is new traffic on a controller that took five
  board rounds to get right; its bench runs the CPU port alongside, and
  `sta_corners.tcl` judges the compile as always.
- **Eject**: the command ejects the image logically (/CSTIN high); the OSD
  remount is the next insertion. A mount under a live volume is hostile
  on a real Mac too (MacLC's note); tested guest-eject first.

### 5.12.12 The work

1. ~~Write this section.~~ **Done 2026-09-28.**
2. `sim/swim` items (5.12.9 item 1), failing, then the IWM read path in
   `se30_swim.v`.
   **Done 2026-09-28: 118 checks PASS.** The bench's item 15 (the window
   bands at Nclks 7/8/23/24/39/40/55/56, the blanking at 10, 11 and 14
   FCLK, the latch, its clear and what is not a valid read, self-sync from
   three offsets, the fast 8M and slow 7M bands) **failed all its checks
   against the rung-1 chip first, as it should**. The read path in
   `se30_swim.v`: CLK = FCLK or FCLK/2, RDDATA sampled on it, a
   window-boundary counter shifting 0s and each accepted transition a 1,
   the B-revision blanking, the latch into the data register, the
   asynchronous clear 14 FCLK after a valid read, and synchronous mode's
   live register with its stall. Three bench faults found on the way,
   none the chip's:
   - rung 1's item 3 check assumed a zero data register out of reset; mode
     0 is synchronous, where the data register is the live shift register
     (`q == swim.sr`).
   - the poller re-read `$1800` within 14 FCLK of a valid read, faster than
     the ROM ever does (after a byte it does table lookups and a VIA1 PA7
     poll, `$40831C48`-`$40831C70`; 14 FCLK = 0.89 us at C16M, the
     documents' "about 2 us" is at 7 MHz); `poll_byte` now waits 20 clocks
     after a byte.
   - `sync_test`'s player and poller shared one loop counter across the
     `fork`, so the poller cut the five sync groups to three: enough to
     lock from offset 0, not from 1 or 2. A trace showed the chip decoding
     exactly what it was given. Each branch has its own counter now.

   **Mutation test** (a scratch copy of the RTL each, the whole bench):
   caught - the first window boundary one CLK late (5 fail), the window
   one CLK short (2), the blanking removed (2), the blanking one CLK short
   (1: the edge at 11 FCLK, which sheet 53 says is always ignored), any
   register read counted as a valid read (1: a status read with a byte
   latched), a one before the zero on a boundary transition (8).
   **Two cases the documents leave open**, pinned as OUR READING by
   Daniel 2026-09-28 (three checks, 118 PASS): the clear counts from the
   latest valid read (a second one re-arms it), and a byte latching while
   a clear is pending cancels it. The drawing says only "cleared 14 FCLK
   periods ... after a valid data read", and the ROM reaches neither case
   (it reads each byte once, 256 FCLK apart). Without the checks both
   mutants survived; with them each fails exactly its own check.
3. `sim/fdhd`, failing, then `se30_fdhd.v`'s drive of 5.12.3.
4. `sim/flpenc`, failing, then `se30_flp_encoder.v`.
5. `sim/flpload` and `sim/sdram`'s disk port, failing, then
   `se30_flp_loader.v` and the port.
6. `sim/gcrread`, the gate.
7. The top, the machine, `PFLP`; elaboration; `sim/machine` unchanged.
8. The compile (Daniel's go-ahead) and the board: an 800K image mounted.
9. **5.13 - the ISM's MFM read** (720K, 1.44 MB), from the ISM ASIC spec,
   written when GCR is on the board.

# Section 6 - The ADB and the RTC

Opened 2026-09-28, after 5.11 item 6: compile 16 drew the grey desktop and
then waited in the ADB Manager's initialisation at `$40806DD8` for a
shift-register interrupt that only the ADB transceiver can cause. Written
before any RTL, documentation first: the schematic's sheet 4, the *Guide*'s
chapter 8 and pp. 143-145, *Inside Macintosh*'s hardware chapter, General
Instrument's PIC manual, and the ROM's own ADB Manager and clock code. The
donors (MacPlus's `adb.sv` and `rtc.v`) and the emulators were read after
those, as cross-checks.

**Three decisions by Daniel, 2026-09-28, frame the section.**

- **The transceiver runs its own firmware.** UL11 is Apple's 342S0440-B, a
  General Instrument PIC1654S microcontroller with Apple's mask program
  (6.3). That program has been dumped (MAME's `342s0440-b.bin`), so the
  transceiver is built as a PIC1654S core in RTL running the dump. It is
  the program the machine ran, so what `ADB-INT*` means in each state, the
  timeouts, the auto-poll and the service-request handling come from it,
  not from our reading. This is `feedback-independent-core-own-the-kernel`'s
  "no workarounds for well-defined jobs": the CPU is documented in full, and
  a hand-written transceiver would be a guess at a program we can run.
- **The keyboard and mouse speak bit cells on a modelled wire.** An
  open-collector ADB line joins the transceiver and the device models, which
  keep the *Guide*'s Table 8-14 timing (attention, sync, bit cells, stop
  bit, stop-to-start, service request) and the register contents of Tables
  8-4 and 8-7 to 8-11, fed from MiSTer's PS/2 keyboard and mouse. The
  devices had microcontrollers of their own, which we do not run: they are
  built to the *Guide*'s specification (`feedback-replicate-bugs-else-spec`,
  tier 2).
- **PRAM is volatile for now.** The RTC keeps its 256 bytes in block RAM
  and takes the time from the HPS when the core loads. The ROM
  re-initialises PRAM on each cold start (6.7). Keeping PRAM on the SD card
  is a later item (6.12).

## 6.1 Sources, and their standing

The ADB and PIC documents are in `C:\temp\Mac\SE30\Docs\adb`, downloaded
2026-09-28 with Daniel's OK from the bitsavers `trailing-edge` mirror and
size-checked. The `.txt` beside each is `pdftotext -layout`; all three are
scans, so quote from the page image (`pdftoppm`, WSL) when a number
matters.

| source | what it is | standing |
|---|---|---|
| `se30.pdf` sheet 4 "VIA1 & VIA2 (65C22), RTC, Apple Desktop Bus" (`se30schems/Apple/SE30_P4.GIF`) | UL11 "ADB" with its pin numbers; UK4 "RTC" with its crystal; the bus driver Q3, R31-R33, the connectors | **primary for the wiring** (6.2), read from the scan and checked against the KiCad redraw |
| BOMARC's redraw of board 820-0260-A (`se30schems/BOMARC/Serial, SCSI, Clock, PRAM, ADB.jpg`) | names the parts: **UL11 = 342S0440-B**, **UK4 = 344S0042-B** | secondary, independent of Apple's set; gives the part numbers the scan does not |
| `IICX_BOM.txt` (the IIcx BOM) | `342S0440` "IC, MICRO-CONT, MAC ADB XCVR" and `341S0440`; `343-0042` / `344-0042` "IC, RAM, 256 BYTE SERIAL CLOCK", and a `062-0217` "SPEC, BI&T, MAC CLOCK CHIP" that has not surfaced | the IIcx as proxy (Section 2's rule); corroborates the part numbers |
| *Guide* 2e, chapter 8 (pp. 289-326) | the ADB: the SE/SE/30 interface circuit (Figure 8-2), the transaction states (Table 8-12), commands (8-13), signals, **timing (Table 8-14)**, error conditions, device registers, addresses, handler IDs, collisions, polling; the Apple Standard Mouse (Table 8-4), the Apple Standard and Extended Keyboards (Figures 8-9 and 8-10, Tables 8-6 to 8-11) | **primary for the bus and the devices**; it does not describe the transceiver's program |
| *Guide* 2e, pp. 143-145 | the RTC: 4-byte seconds counter, the one-second interrupt, **256 bytes of parameter RAM** on the SE, SE/30 and II family, the three VIA1 port-B lines (Table 3-11); it defers the command set to *Inside Macintosh* | **primary**, as far as it goes |
| `Inside_Macintosh_Hardware_198502.pdf` (38 pp.), "Macintosh Hardware", 2/11/85, pp. 27-30 | the RTC's serial protocol and **command table**: seconds registers, test register, write-protect register, the 20 bytes of the original parameter RAM | **primary for the RTC's original command set**. It predates the 256-byte chip: the extended commands are not in it |
| `1983_PIC_Series_Microcomputer_Data_Manual.pdf` (226 pp.), General Instrument | the PIC1650 family: the register file, the ALU and status word, the two-level stack, the RTCC counter, the I/O port structure (Figure 7), the **instruction set** (chapter 3, pp. 46-66), and the PIC1654 (section 2.3, pin assignments Fig. 15) | **primary for the CPU**. It covers the PIC1654 (18 pins), not the "S" part by name, and does not state the 1654's clock divider (6.3.1) |
| `FDB_Specification_Rev_B_Proposal_19850613.pdf` (12 pp.) | Apple's ADB specification under its development name, Front Desk Bus | **primary, pre-release**; where it and the *Guide* differ, the *Guide* (1990, describing shipped hardware) wins |
| **`342s0440-b.bin`**, the transceiver's mask program | 0x400 bytes, CRC32 `cffb33eb`, SHA1 `4a35a44605073ae6076a0292e2056ee4d938d1bd` (MAME's `adbmodem` device) | **documentation tier** (1.11's rule): it is what the transceiver ran. **Not yet on hand**: Daniel's MAME `MacSE30` set is older and lacks it (6.10) |
| The SE/30 ROM: the ADB Manager (`$40806D80`-`$408077F4`) and the clock code (`$4080DBE8`-`$4080DE66`, the test manager's `$40803502`-`$408035A2`) | how the machine drives the transceiver and the clock | **documentation tier**; the only source for the RTC's extended commands (6.5) |
| `macseadb88.asm` (github `lampmerchant/macseadb88`, 2025), Tashtari | an annotated disassembly of the 342S0440-B program, ported to the PIC16F87/88 as a drop-in replacement that works in real SEs; the annotation is "only partially complete" by its author's account | **secondary**: a reading aid for the firmware and a witness to the pin assignments. It is a port, not the dump - its oscillator set-up and `TRIS` writes are the new part's, not the old |
| MAME `src/mame/apple/adbmodem.cpp`, `src/devices/cpu/pic16c5x/pic16c5x.cpp` | R. Belmont's device around the dump, with a pin table; MAME's PIC1654S core | cross-check only; an emulator's model (`feedback-se30-specs-from-documentation`) |
| MacPlus `rtl/adb.sv`, `rtl/rtc.v` | a behavioural transceiver-plus-devices, and a 20-byte RTC | donors, read last (6.8) |

**Fetched 2026-09-28 with Daniel's OK: Microchip's PIC1654S data sheet**
(DS33013A, 1990, 16 pp., as page images from `alldatasheet.com`, in
`adb\PIC1654S_datasheet\`). **Primary for the part**, over the family
manual where they differ (6.3.1). And **the program itself**, supplied by
Daniel as `C:\temp\Mac\ROMS\MacSE30\342s0440-b.bin` - CRC32 and SHA1
match MAME's (6.3.3).

## 6.2 The wiring (sheet 4)

Read from the scan at full resolution; the KiCad redraw agrees except that
it names UL11's pin 2 `FDBO` on the `ADBO` net where the scan's symbol has
`FDBO` and `FDBI` on pins 2 and 3 - the nets are the same, only the redraw's
symbol label differs.

**UL11, "ADB" (342S0440-B):**

| pin | symbol | net | to |
|---|---|---|---|
| 14 | DIO | `ADB-DIO` | VIA1 CB2 |
| 13 | SCLK | `ADB-SCLK` | VIA1 CB1 |
| 27 | ST0 | `ADB-ST0` | VIA1 PB4 |
| 28 | ST1 | `ADB-ST1` | VIA1 PB5 |
| 16 | INT | `ADB-INT*` | VIA1 PB3 |
| 4 | RST | `RESET*` | the system reset, as the VIAs' |
| 26 | CLK | `C3M` | GLUE's 3.672 MHz (2.5; the *Guide*'s Figure 8-2 "osc 3.672MHz") |
| 3 | FDBI | `ADBO` | the ADB line |
| 2 | FDBO | `ADBO` | the ADB line |
| 1 | FDBO* | `ADBO*` | R32 (4.7 k) to Q3's base |
| 11, 12, 17, 18, 19 | P0, P1, P5, P6, P7 | - | unconnected |

**The line.** `ADBO` is pulled up to +5 V by R31 (470 ohms, the *Guide*'s
Table 8-1 "pulled up to +5V through a 470 ohm resistor") and pulled down by
Q3 (2N3904) through R33 (27 ohms) when pin 1 is high. It leaves through the
filter L1 as `ADBF` to both connectors J9 and J10 (mini-DIN 4, in parallel:
"The two ADB ports on the back of the Macintosh are connected in parallel
to the same ADB", p. 289). So the transceiver pulls the line low by raising
pin 1, and senses it on pins 2 and 3. The SE/30 has no keyboard power-on
wiring (Figure 8-2 against 8-3): pin 2 of the connectors, `POWER.ON` on
the II family, is not connected here.

**The pin names on the chip.** The GI manual's Fig. 15 gives the 18-pin
PIC1654: 1 RA2, 2 RA3, 3 RTCC, 4 MCLR, 5 Vss, 6-9 RB0-RB3, 10-13 RB4-RB7,
14 Vdd, 15 OSC2, 16 OSC1, 17 RA0, 18 RA1. UL11 is a 28-pin package whose
pins 1-4 and 27-28 carry the same functions as the 18-pin part's 1-4 and
17-18, with port B at 11-14 and 16-19. So:

| PIC | UL11 pin | net |
|---|---|---|
| RA0 | 27 | ST0 (in) |
| RA1 | 28 | ST1 (in) |
| RA2 | 1 | `ADBO*`: 1 pulls the line low |
| RA3 | 2 | the line (in) |
| RTCC | 3 | the line (the counter's input) |
| MCLR | 4 | `RESET*` |
| RB0, RB1 | 11, 12 | unconnected |
| RB2 | 13 | SCLK (out) |
| RB3 | 14 | DIO (in/out) |
| RB4 | 16 | INT* (out) |
| RB5-RB7 | 17-19 | unconnected |
| OSC1 | 26 | `C3M` |

The 28-pin assignment is inferred from the pin numbers. It is corroborated
twice, independently: Tashtari's replacement (RA0 = ST0, RA1 = ST1, RB4 =
INT, RB3 = DIO, RB2 = SCLK, RA2 = ADB drive, RA3 and the counter input =
ADB sense) runs in real SEs, and MAME's pin table says the same. The
PIC1654S data sheet would make it primary (6.11).

**UK4, "RTC" (344S0042-B):** pin 1 `1HZ` -> `RTC-1HZ` -> VIA1 CA2; pin 5
`CS*` <- `RTC-CS*` = VIA1 PB2; pin 6 `D` <-> `RTC-D` = VIA1 PB0; pin 7
`SK` <- `RTC-CLK` = VIA1 PB1; pins 2-3 a 32.768 kHz crystal (Y1, C44 33
pF, C45 10 pF); pin 8 `+5V-RTC`, fed from +5 V through D2 or from the
battery through D1 and R27; pin 4 ground. **There is no reset pin**: the
clock and its RAM are battery-backed and see no machine reset.

## 6.3 The transceiver: a PIC1654S running the 342S0440-B program

### 6.3.1 The CPU (the GI manual, sections 2 and 3)

A Harvard machine, 512 x 12 program ROM, 32 x 8 register file:

- **The file.** F0 indirect through the FSR; F1 the RTCC; F2 the PC's
  low eight bits; F3 the status word; F4 the FSR; F5 port A (4 bits); F6
  port B (8 bits); F7-F37 (octal) general registers. The FSR is five bits
  and "the three high order bits are read as 111" (2.1.4). The PC is nine
  bits; bits 0-7 are readable as F2, and when F2 is a destination "bit 8
  will always be zero" (2.1.2). The stack holds two return addresses
  (2.1.3).
- **The status word** (2.1.7): C, DC, Z, and **OV in bit 3** ("set if the
  carry out from the MSB is opposite to the carry out from MSB-1") - the
  1650 family's, not the later 16C5x's layout (which puts PA/TO/PD above Z
  and has no OV). Bits 7-4 unused.
- **The instruction set** (chapter 3): 12-bit words - byte-oriented file
  operations `NOP MOVWF CLRW CLRF SUBWF DECF IORWF ANDWF XORWF ADDWF MOVF
  COMF INCF DECFSZ RRF RLF SWAPF INCFSZ`, bit operations `BCF BSF BTFSC
  BTFSS`, literal and control `RETLW CALL GOTO MOVLW IORLW ANDLW XORLW`.
  **No `TRIS`, `OPTION`, `SLEEP` or `CLRWDT`** - the 1650 family has no
  direction registers, no option register and no watchdog. `CALL`'s
  literal is eight bits (its target is in the first 256 words), `GOTO`'s
  nine. The binary table is on p. 48.
- **Timing**: "All instructions, except for subroutine calls and
  conditional skips and branches, are executed during one machine cycle.
  The exceptions are executed in two machine cycles" (p. 47) - a skip
  costs its second cycle only when it skips (a NOP replaces the skipped
  instruction, 2.1.2), and a write to the PC is a branch (the manual's own
  RTCC timing example counts `ADDWF PC` as "Two Cycles"). The bench holds
  the per-instruction counts to the chapter 3 entries.
- **The I/O lines** (2.1.9, Figure 7): each line is a latch driving a
  pull-down, and a pull-up transistor Q1 ("Pull-up resistor may be deleted
  via a mask option"); a read returns the pin, not the latch; to use a line
  as an input "the latch must be set to a logic 1". So every line is an
  open-drain output with a pull-up, read back as the wired-AND of its latch
  and whatever else drives it. The firmware must see the unconnected RB0
  and RB1 as 1 (Tashtari's reading of its INT path tests them) - so on this
  part the pull-ups were not deleted, at least on port B, and the model
  keeps Q1 on every line. Also: "Any output line sinking more than 5mA
  could be read as a logic 1" - not modelled (no line here sinks that).
- **The RTCC** (2.1.8): an eight-bit counter, presettable, incremented on
  the **falling edge** of the RTCC pin, wrapping without setting carry.
  Its pin is the ADB line.
- **Reset**: MCLR (`RESET*`) low holds the chip. The manual's timing figure
  (Fig. 9) is for the PIC1650A/1655A; where the 1654 starts after reset is
  not stated for it in the manual - **the reset vector is read from the
  dump** (its first instructions), not assumed (6.11).
- **SETTLED BY THE DATA SHEET (2026-09-28)**, which differs from the
  family manual in two places the core follows: **status bits 3-7 "are
  defined as logic ones"** - the PIC1654S has no OV - and **port A's
  "four MSB's are always read as logic 0's"**. It confirms the rest: the
  FSR's high bits read as ones, the reset to **777 octal** with every
  latch high, a read-modify-write taking the pins (note 2), a store to F1
  winning over an edge, the two-cycle list (GOTO, CALL, RETLW, MOVWF F2,
  ADDWF F2, a true skip), and **"The frequency of oscillation is 8 times
  the instruction cycle frequency"**. Two mask options it names: the
  RTCC counting the instruction clock instead of its pin, and open-drain
  lines without the pull-up. The first cannot matter (the program never
  touches F1); the second is 6.3.2's reading (the unconnected RB0/RB1
  read 1). It lists a PLCC package - UL11's 28 pins.
- **The clock divider - was OPEN; the dump decided it.** The manual gives
  divide-by-4 for the PIC1650A and PIC1655A (2.1.12) and divide-by-16 for
  the PIC1656 (2.6.6); for the PIC1654 it gives only "2 us" in the family
  table (1.2), against the 1650A's "4 us" at its 1 MHz maximum. Tashtari
  states the PIC1654S "divided ~4 MHz oscillator by 8". **The *Guide*
  settles it without trusting either**: the firmware's bit-cell loops,
  counted in instruction cycles, must give Table 8-14's 100 us bit cell and
  800 us attention within the host's +/-3% at `C3M` = 3.672 MHz. At /8 an
  instruction is 2.179 us; Tashtari's cycle counts for a "1" bit (about 16
  cycles low, 46 per cell) give 35 us and 100 us - the table's figures.
  At /4 or /16 every ADB timing would be off by a factor of two. This is
  checked on the dump itself (6.9 item 3), and the data sheet would make
  it primary.

### 6.3.2 The pins, as the model drives them

| line | inside | outside |
|---|---|---|
| RA0, RA1 | read ST0, ST1 | VIA1 PB4, PB5 pins (push-pull outputs after `$40806DA2`) |
| RA2 | latch -> 1 pulls the ADB line low through Q3 | the line |
| RA3 | reads the line (AND its own latch) | the line |
| RTCC | counts the line's falling edges | the line |
| RB2 | SCLK: latch, pulled up | VIA1 CB1 (input in the external-clock shift modes) |
| RB3 | DIO: latch AND the VIA's CB2 | VIA1 CB2: the VIA drives it in shift-out mode (`sr[8]`, 4.2.5), releases it in shift-in |
| RB4 | INT*: latch, pulled up | VIA1 PB3 (input) |
| RB0, RB1, RB5-RB7 | read 1 (pull-up) | nothing |

**The ADB line** = the wired-AND of: NOT RA2's pin (Q3), RA3's latch, and
every device's pull-down, pulled up by R31. **DIO** = RB3's latch AND (the
VIA's CB2 when it drives). A cycle in which the VIA drives CB2 high while
the PIC's latch is 0 is a contention on the real board; the model resolves
it as the AND and the bench flags it (6.9 item 4), since the firmware and
the ROM between them should never cause one.

### 6.3.3 The program

**Read 2026-09-28** (`scripts/pic_dis.py`, which prints the program in
the data sheet's mnemonics with sheet 4's wiring beside each port bit).
512 words, low byte first, twelve bits used; **`GOTO 0` at 777 octal**,
the reset address. What it uses, counted: no RTCC (F1 never read or
written), status only as C and Z, port A always masked (`ANDLW 03`) or
bit-tested on RA3, no unused opcodes; the line pulled by writing `F7` to
port A (RA3 low **and** RA2 high) and released by `FB`; its RAM cleared
and its receive buffer (F30-F37) walked by `INCFSZ FSR` loops that end
on the FSR's high bits reading as ones. Its structure is the one
Tashtari's port describes, which stands as the map to it
(secondary):

- A main loop reads ST1-ST0 and, on a change, dispatches on {last command
  type, new state}: in **state 0** it clocks a command byte out of the VIA
  (eight SCLK pulses, reading DIO after each rising edge) and, for a
  command with no data phase (SendReset, Flush), sends it on the bus at
  once; in **states 1 and 2** it either clocks a data byte out of the VIA
  (Listen) or clocks a buffered reply byte into it (Talk); entering
  **state 3** with a Listen pending sends the command and its data on the
  bus; entering state 3 after a Talk sends the Talk and collects the
  reply.
- **INT\*** (RB4) is pulled low in the even/odd states to say "error" (in
  state 1: the device did not answer, or the frame was bad) or "service
  request seen" (in state 2), and when a reply is exhausted - the
  distinctions the ADB Manager's handler reads at `$40807040`-`$4080711A`
  (6.7).
- **On the bus**: attention (a count of 360 cycles, about 785 us at /8),
  sync, eight command bits, stop; a service request is seen as the line
  still low after the stop bit (it counts up to 26 polls); a reply is taken
  bit by bit by a run of `BTFSC RA3` samples that times each cell's low
  phase; SendReset holds the line low for about 1460 cycles (3.2 ms,
  Table 8-14's "3 ms minimum") and restarts the program.
- **Auto-poll**: two countdown registers (initial `$73` and `$54`) run
  while the state lines are still, and in state 3 re-issue the last Talk -
  the *Guide*'s "the ADB transceiver automatically repeats the last Talk
  command every 11 ms" (p. 314). The period comes out of the loop's cycle
  count, which 6.9 item 3 measures against the *Guide*'s 11 ms.

### 6.3.4 The image and how it reaches the core

Apple's program, so like the ROMs it is not in the repository: the user
supplies it as **`boot2.rom`** in the core's folder, which Main sends with
`ioctl_index` = `$80` (3.4's `bootN.rom` rule; `boot0.rom` is the main ROM,
`boot1.rom` the declaration ROM). 0x400 bytes = 512 words of two bytes;
the byte order and the unused top four bits of each word are read from
the file when it arrives (MAME's PIC program space is 16-bit little-endian,
so the expected layout is low byte first, top nibble zero - checked, not
assumed). The core holds it in one M10K as 512 x 12. **With no `boot2.rom`
the program memory reads zero** - all `NOP`s: the PIC runs through its
memory forever, never touching a pin, and the machine waits in the ADB
initialisation exactly as compile 16 does. That is the right failure: an
absent file leaves the machine where it was, not broken.

## 6.4 The bus and the devices

### 6.4.1 The line

One bit in the model: 1 unless someone pulls it low (R31's pull-up). The
transceiver pulls it through Q3 (RA2 = 1) or through RA3's latch; each
device pulls it through its own open-drain output. The line's rise and
fall times (470 ohms against the cable and device capacitance, Table 8-2's
150 pF per device) are sub-microsecond against a 100 us bit cell and are
not modelled.

### 6.4.2 A device

A common engine, instanced per device, built to the *Guide* (pp. 311-326)
and Table 8-14, with the FDB specification as a cross-check:

- **Receiving**: an attention is a low of about 800 us (the host sends it
  within +/-3%, a device accepts it - the engine takes 560 us or more,
  "remains low for at least 3.0 ms" being a global reset); sync; eight
  command bits, each decided by its low time against its cell ("0" 65%,
  "1" 35% of the cell, +/-5%); the stop bit.
- **Commands** (Table 8-13): Talk and Listen to its current address,
  register 0-3; SendReset (address ignored) and global reset (line low 3
  ms or more): back to power-on state; Flush to its address:
  device-defined (keyboard: clear its buffered keys).
- **Talk**: if the register has data (register 3 always has), the device
  sends a start bit ("1"), the register's two bytes MSB first, and a stop
  bit, beginning 140-260 us after the command's stop bit ("Stop-bit-to-
  start-bit time", Table 8-14), at nominal timing. With nothing to send it
  stays silent and the transceiver times out.
- **Listen**: receives the start bit, the data bytes and the stop bit;
  register 3's reserved handler IDs act as Table 8-17 says (`$FE` move
  address if no collision, `$FD` move if the activator is pressed, `$00`
  set address and enable, `$FF` self-test) and are not stored; another ID
  is stored only if the device supports it (keyboard 2 and 3, mouse 1 and
  2); an unknown ID is ignored.
- **Service request**: a device with data that is not being addressed
  holds the line low during the stop bit of any command to another device,
  extending it to about 300 us (140 us or more beyond the normal stop,
  Figure 8-15), if register 3 bit 13 enables it.
- **Collisions** (p. 324): a device that sees the line low when it meant
  it to be high, or another device's start bit first, stops, keeps its
  data and sets its collision flag; the flag disables its address move
  under `$FE`. With one keyboard and one mouse at their distinct default
  addresses the start-up never collides; the logic is there for when a
  second device of a kind is added.
- **Register 3** (Table 8-15): bit 14 exceptional event (1 if unused), bit
  13 SRQ enable (1 at reset), bits 11-8 the address, 7-0 the handler ID.

### 6.4.3 The keyboard

**Proposed: the Apple Extended Keyboard** (Figure 8-10, Tables 8-9 to
8-11) - a PS/2 keyboard has its function keys, navigation cluster and
right-hand modifiers, all of which the Extended Keyboard has and the
Standard Keyboard lacks. Address 2, handler ID 2 at reset, 3 on request
(then right Shift, Option and Control send `$7B`, `$7C`, `$7D`). Register
0: two key transitions per Talk, bit 7 of each byte set on release, `$FF`
filling an empty second slot; register 2: the modifiers and the LEDs (Num
Lock, Caps Lock, Scroll Lock, set by Listen register 2). The PS/2 set-2
codes map to Figure 8-10's transition codes through a table built from
the figure. Caps Lock is a locking key on the real keyboard: its register
0 code goes down on one press and up on the next. **Daniel decided
2026-09-28: the Extended Keyboard, with the PC modifiers mapped by
position** (6.12 item 4).

### 6.4.4 The mouse

**The Apple Standard Mouse** (Table 8-4): address 3, handler ID 1 (100
counts per inch) at reset, 2 (200) on request. Register 0: bit 15 the
button (0 = down), bits 14-8 Y, bit 7 always 1, bits 6-0 X, each a 7-bit
two's-complement count (negative is up, left). Motion from the PS/2 mouse
accumulates between Talks and is sent clamped to -64..+63 per axis, the
remainder kept; with no motion and no button change the mouse has no
data and does not answer Talk register 0.

## 6.5 The RTC (344S0042-B)

### 6.5.1 The protocol (*Inside Macintosh*, p. 28-29, and the ROM)

`CS*` (PB2) low for the whole transaction ("if you set it to 1, you'll
abort the transfer"); every transfer is whole eight-bit bytes, MSB first.
The **host sends** a bit by setting `D` (PB0 as an output) while the clock
(PB1) is low and raising the clock: the chip takes it on the **rising
edge**. The ROM's routines do exactly that (`$4080DE32`: data and clock
low in one write, then `BSET` of the clock; the test manager's
`$40803502` the same). The **chip sends** a bit after the clock falls:
*Inside Macintosh*, "lower the data-clock (rTCClk) and read the first
(high-order) bit ... Then raise the data-clock, lower it again, and read
the next bit"; the ROM's read (`$4080DE44`) makes PB0 an input, then per
bit writes the clock low, writes it high, and reads - so the chip drives
each bit from the falling edge and holds it through the rising edge, and
both readings see it.

**The commands** (*Inside Macintosh* p. 29; `z` is 1 for a read):

| command | register |
|---|---|
| `z00x0001`, `z00x0101`, `z00x1001`, `z00x1101` | seconds 0 (lowest) to 3 - *Inside Macintosh* gives x = 0; **the ROM reads the time with x = 1** (`$9D`, `$99`, `$95`, `$91` at `$4080DCAE`) and writes it with x = 0 (`$4080DCEA`), so the chip ignores x (found by `sim/rtc`, 6.12 item 5) |
| `00110001` (`$31`) | test register, write only |
| `00110101` (`$35`) | write-protect register, write only |
| `z010aa01` | RAM `$10`-`$13` of the original 20 bytes |
| `z1aaaa01` | RAM `$00`-`$0F` of the original 20 bytes |

and the **extended command** the 256-byte chip adds, read from the ROM
(`$4080DD8E`-`$4080DDC2` builds it; `$4080DDEE` tells it apart by `(cmd &
$78) = $38`): **byte 1 `z0111aaa`** (address bits 7-5), **byte 2
`0aaaaa00`** (address bits 4-0), then the data byte. The test manager
writes that way too (`$40803528`: `$3F`, `$40` + 4n = xPRAM `$F0` + n).

**Where the original 20 bytes live in the 256.** The command bits 6-2 of
the original forms, read as an address, are `1aaaa` = `$10`-`$1F` and
`010aa` = `$08`-`$0B`. The ROM corroborates: when it finds xPRAM invalid
(`$4080DC20`-`$4080DC58`) it writes the signature `'NuMc'` at `$0C`-`$0F`
and then clears every byte from `$20` round to `$07` - everything except
`$08`-`$1F`, which is exactly the original 20 bytes and the signature. So
the model aliases: original `z1aaaa01` = xPRAM `$10`+a, `z010aa01` = xPRAM
`$08`+a. (The seconds and the two special registers decode to `$00`-`$07`
and `$0C`/`$0D` by the same reading; they are not RAM, and the extended
command reaches the RAM there.)

**Write protect** (*Inside Macintosh*): bit 7 set "prevents writing into
any other register on the clock chip (including parameter RAM)". The
model follows it for both command forms. A reverse-engineering note
(quantulum.co.uk, secondary) says the real chip's extended window wrote
through the protect bit; the ROM clears the bit before every write
(`$4080DD1A`, `$35` <- `$55`) and sets it after (`$4080DD12`, `$35` <-
`$D5`), so the difference is invisible to it. **Recorded as an open
question** (6.11) - if Apple's own documentation or a silicon test turns
up, `feedback-replicate-bugs-else-spec` applies.

**The test register**: bits 7-6 "should always be set to 0 during normal
operation. Setting them to anything else will interfere with normal clock
counting". The ROM writes `$00` (`$4080DBEE`). The model stores it and
does nothing else with it: what "interfere" means is not documented.

### 6.5.2 The clock

A 32-bit seconds counter, incremented once a second (the chip from its
32.768 kHz crystal; the model from `clk_sys` = 31,334,400 per second, 3.2),
**loaded when the core loads** from the HPS's `TIMESTAMP` plus 2,082,844,800
(Unix to Macintosh epoch, 1904 - the MacPlus donor's conversion). Not reset
by the machine's reset: the chip is battery-powered and has no reset pin
(6.2). Writes to the seconds registers change it (low byte first, as *Inside
Macintosh* asks of software). **`1HZ`**: "Each time the counter is
incremented, the RTC sends an interrupt request signal to the VIA" (*Guide*
p. 143); VIA1 CA2 is a negative-edge input (4.6 item 9: PCR `&= $F0`). The
model makes `1HZ` a square wave falling at each increment and rising half
a second later; the duty cycle is not documented (tier 2).

### 6.5.3 The RAM

256 bytes in block RAM, zero when the core loads (a battery-less chip's
contents are undefined; zero makes the ROM's validity tests fail cleanly
and re-initialise, 6.7). Kept across machine resets, lost at core load -
Daniel's "volatile for now".

## 6.6 The machine

- **The transceiver**: `se30_adb_xcvr` = the PIC1654S core, its 512 x 12
  program RAM (written by the `boot2.rom` download), the pins of 6.3.2, the
  line of 6.4.1; clocked by `clk` with GLUE's `c3m_en` as OSC1 (15 pulses in
  64 C16M, 3.672 MHz average - 2.11.3; the PIC's phase counter divides it
  by 8 per 6.3.1, so an instruction is 32-33 C16M periods, 2.179 us on
  average); MCLR = `via_reset_n` (sheet 4's `RESET*`, which the RESET
  instruction pulses - the transceiver restarts when the ROM executes
  RESET, as the VIAs do).
- **VIA1**: `pb_ext[3]` = INT*; `pb_ext[0]` = the RTC's `D` while the chip
  drives it, else 1 (4.5's undriven level); `cb1_in` = SCLK; `cb2_in` =
  DIO (the wired-AND of 6.3.2); `ca2_in` = `1HZ`. PB4, PB5 (ST0, ST1) and
  PB2, PB1 (`CS*`, clock) are read as pins, as every consumer of a VIA
  output is (4.5).
- **The devices**: the keyboard and mouse engines on the line, fed from
  `hps_io`'s `ps2_key` and `ps2_mouse`.
- **The RTC**: `se30_rtc` on PB0-PB2, CA2; `hps_io`'s `TIMESTAMP`.
- **The top**: `hps_io` gains `ps2_key`, `ps2_mouse` and `TIMESTAMP`; the
  download block gains `boot2 = (ioctl_index[7:0] == 8'h80)` into the
  transceiver's program RAM; the README's table gains `boot2.rom`.
- **Probes**: **`PADB`** - the PIC's PC, W, port A and B pins, the line,
  ST1-ST0, INT*, the last command byte seen on the bus, and a count of
  transactions; **`PRTC`** - the seconds counter's low byte, the last
  command, write-protect, and a count of transactions. Both in
  `rtl/dbg_probes.sv` and decoded by `read_probes.tcl`.

## 6.7 What the ROM does with them

Read from the disassembly (`scripts/se30_rom_mmu.py dis`; VIA1 registers
at the offsets of 4.2.2 from `$50F00000`, which the ROM keeps in `$1D4`).

**The ADB.**

1. **Initialisation** (`$40806D80`, the routine compile 16 waits in):
   VIA1 **PCR := 0** (`$40806D98`), **IER := `$84`** (the shift-register
   interrupt), **DDRB |= `$30`** (PB5, PB4 = ST1, ST0 outputs); the ADB
   Manager's flags (`$15D(a3)`) get bit 2 and bit 5 set, the reply queue
   is initialised, and **`$40806DEA` starts the first transaction**.
   Interrupts open (`$40806DD4`) and the loop at **`$40806DD8`** waits for
   bit 5 to clear.
2. **Sending a byte** (`$408073E6`): with interrupts masked, **ACR &=
   `$E3`, then ACR |= `$1C`** - shift mode 111, out under the external
   clock on CB1 - then **SR := the byte**. **Setting a state**
   (`$408073A2`/`$AA`/`$B2`/`$BA` for states 0/1/2/3, `$408073C0`): ORB :=
   (ORB & `$CF`) | state << 4, interrupts masked. A transaction loads the
   command into SR and sets state 0, in either order (`$40806E0C` sends
   first, `$40807354` sets the state first) - the *Guide*'s "sends the
   command byte to the VIA's Shift register, then sets the ADB transceiver
   to state 0" is one of them.
3. **The shift-register interrupt** (`$40807002`): **IFR := `$04`**
   (clears SR), then a dispatch on the command's type (`$15C(a3)` bits 3-2:
   `$8` Listen, `$C` Talk) and on the state it last set (`$15F(a3)`, one
   bit per state). It reads **PB3 (INT\*)** after state 0 (`$40807040`),
   after state 1 (`$408070CA`) and after state 2 (`$40807116`); it takes a
   byte in by clearing **ACR bit 4** (mode 011, in under CB1) and reading
   SR (`$40807064`-`$4080706A`, `$40807092`-`$40807098`), gives one out by
   writing SR (`$408070A6`), and steps the state (`$408073AA`, `$408073B2`,
   `$408073BA`). What a low INT\* *means* in each state is the
   transceiver program's to define, and the *Guide* gives only its outline
   (a service request "sets bit 3 in Data register B to 0", p. 312); the
   ROM's branches are the other half. **The ROM's reading of INT\* is
   fixed by the ROM, the transceiver's meaning of it by the dump, and the
   bench checks that they agree (6.9 item 5)** - nothing here is designed
   from an interpretation of either.
4. **ADBReInit** (`$40806DEA`-`$40806EDA`): **Talk register 3 to each
   address `$0`-`$F`** (`$40806F7A`: command = addr << 4 | `$0F`), noting
   which answer; then, for each address that answered, **Listen register
   3** with the data `$FE`-and-a-free-address (`$40806F9E`: command = addr
   << 4 | `$0B`, `$165` = `$FE`) and a Talk register 3 at the new address,
   to find duplicates, up to `$32` tries; then the devices' table entries
   (`$40806E24`-`$40806E62`: the keyboard's handler at `$4080753A` for
   address 2, the mouse's at `$408074CE` for address 3); finally
   **`$15C` := `$3C`** (Talk register 0, address 3: the mouse as the
   active device) and **bit 5 of `$15D` cleared** (`$40806EDA`) - which
   releases the loop at `$40806DD8`.
5. With **no** device the Talks all time out, the table stays empty, and
   the loop is released just the same: an ADB with nothing on it is a
   working ADB. With the keyboard at 2 and the mouse at 3, both are found
   and neither moves.

**The RTC.**

1. **The test manager** writes only: `$40803576` clears write protect
   (`$35` <- `$55`), `$40803528` writes test results into xPRAM `$F0`-`$FF`
   through the extended command (6.5.1) - not on a normal start-up's
   path, only when a test fails.
2. **InitUtil** (`$4080DBE8`, from the start-up chain): write protect off,
   **test register := 0**, write protect on; read the original 20 bytes
   into `SysParam` (`$1F8`); read the seconds (`$4080DCA6`: commands `$9D`,
   `$99`, `$95`, `$91` - seconds 3 to 0 - twice until two reads agree, into
   `Time` at `$20C`); if `SysParam`'s first byte is not **`$A8`** (the
   validity byte), write the ROM's 20 defaults (`$4080DBD4`: `A8 00 00 00
   CC 0A CC 0A 00 00 00 00 00 02 63 00 03 88 00 4C`) through the original
   commands (`$41` x 16, `$21` x 4, `$4080DD22`); then, if the machine has
   extended PRAM (flag bit 6 of `$B22`), **`_ReadXPRAM` 4 bytes at `$0C`**
   and compare with **`'NuMc'`**; if it differs, write `'NuMc'`, clear
   `$20`-`$07` (wrapping; 6.5.1), and write 20 bytes of defaults at `$76`
   (`$4080DC92`).
3. From then on the OS reads and writes PRAM through `$4080DD52` (the
   routine at `$54C`, `$4080DDD6` in ROM) and takes the one-second
   interrupt (VIA1 IER bit 0, enabled at 4.6 item 9) to advance `Time`.

With zero PRAM at core load, every cold start takes both re-initialise
paths; a warm reset (the RESET instruction, the OSD reset) keeps PRAM, so
the second start finds `$A8` and `'NuMc'` and takes neither.

## 6.8 The donors

**MacPlus `rtl/adb.sv`** is a behavioural transceiver and device pair in
one module - its own reading of what the transceiver does in each state,
the thing the first decision replaces. **Not lifted.** Two parts are
engineering and worth reading when the devices are written: the PS/2
set-2 to ADB key-code table (checked entry by entry against Figure 8-10
before use) and the PS/2 mouse packet decode. The appendix records a
VIA shift-register bug found in the Quadra 800 core's ADB path whose
construct also sits in MacPlus's VIA; ours is `se30_via.v`, written from
the cell spec (4.2.5), and 6.9 item 5 exercises its external-clock modes
end to end for the first time.

**MacPlus `rtl/rtc.v`** implements the original 20 bytes and the seconds,
without the extended command, write protect, the test register or the
one-second output. **Lifted: the epoch conversion** (Unix seconds +
2,082,844,800). The rest is written from 6.5.

**MAME** (`adbmodem.cpp`) runs the same dump on its PIC1654S core. Its
comment records a race it had to work around: on a fast CPU the ROM
rewrote the ACR (so CB2 stopped being driven) before the PIC sampled the
last bit. In the machine the sample is a few microseconds after the eighth
SCLK edge and the ROM's interrupt latency is longer; the model is cycle-
driven and should not need the workaround. The bench watches for it (6.9
item 5) rather than assuming.

## 6.9 The benches

**`sim/pic/`** (iverilog) - the CPU against the GI manual, no firmware:

1. Every instruction of the p. 48 table: its result, its destination bit,
   the status bits it affects and those it must not (OV included), from
   hand-written programs with expected values from the chapter 3 entries.
2. Cycle counts: one machine cycle, two for `CALL`, `GOTO`, `RETLW`, a
   write to F2 and a taken skip; the divider: one instruction per eight
   OSC1 pulses.
3. The file's corners: the FSR's high bits reading 111, indirect through
   F0, F2 as a destination clearing PC bit 8, `CALL`'s 8-bit target, the
   two-level stack, the RTCC counting falling edges on its pin and
   wrapping without carry.
4. The ports: a read returns the pin; a latched 0 pulls the pin low
   against the pull-up; a latched 1 lets an external 0 through.

**`sim/adb/`** (iverilog) - the dump in the PIC, `se30_via.v` as VIA1,
the line, the two device engines, and a driver that **replays the ROM's
own VIA sequences** from 6.7 (`$408073E6`, the state writes, the handler's
reads of PB3 and SR, the ACR changes), not a paraphrase of them. It needs
`342s0440-b.bin`, found as the ROM is (a path in `scripts/local.env`); it
skips with a message if the file is absent.

3. **The timing on the wire, measured**: the attention 800 us +/-3%, the
   bit cell 100 us +/-3%, "0" and "1" low times 65% and 35% +/-5%, the
   stop bit 70 us, the SendReset low of 3 ms or more - Table 8-14. This is
   the check that decides 6.3.1's divider.
4. No contention on DIO (6.3.2) in any transaction.
5. **ADBReInit replayed**: Talk register 3 to all sixteen addresses; with
   no devices, sixteen timeouts and INT\* where the ROM expects it; with
   the keyboard and mouse, their register 3 (`$62 02`-style: bit 14 1,
   SRQ-enable bit 13 1, address, handler) read back through SR, byte for
   byte; the Listen register 3 `$FE` move and the Talk that confirms it;
   the final Talk register 0 to address 3 and the transceiver's auto-poll
   repeating it every 11 ms (+/- the *Guide*'s tolerance, measured).
6. A key press and release through Talk register 0 at address 2; mouse
   motion and the button through address 3; a service request from the
   keyboard while the mouse is the active device, seen by the ROM's handler
   as INT\* in state 2 - the *Guide*'s polling protocol (p. 325) end to end.
7. SendReset and Flush; Listen register 2 setting the keyboard's LEDs.

**`sim/adbdev/`** (iverilog; added 2026-09-28, 6.12 item 4) - the keyboard
and mouse alone, with a bench host that speaks Table 8-14 at its nominal
timing: item 6's device half and item 7, runnable before the dump.

**`sim/rtc/`** (iverilog) - the chip behind a driver that replays the
ROM's bit-bang routines (`$4080DE32`, `$4080DE44`, `$40803502`) exactly:

8. Every command of *Inside Macintosh*'s table, read and write; the
   extended command at the four corners of the address space; the
   aliasing of 6.5.1 (a byte written through one form read back through
   the other).
9. Write protect: set, a write refused through each form; cleared, the
   write lands.
10. InitUtil (6.7 RTC item 2) replayed from zero RAM: the defaults written,
    `'NuMc'` written, `$20`-`$07` cleared; replayed again: neither path
    taken.
11. The seconds: loaded from a `TIMESTAMP`, incremented once per
    31,334,400 clocks, `1HZ` falling at each increment; a read spanning an
    increment disagreeing once and the ROM's read-twice loop settling.
12. `CS*` high mid-byte aborting the transfer (no write lands).

**`sim/machine`**: unchanged in reach (it ends in the RAM tests, 3.8
item 23); elaboration with the new modules, 0 errors.

## 6.10 The board: two rungs

**Rung 1 - the transceiver, the devices and the clock.** With
`boot2.rom` in place, the ADB initialisation finds the keyboard and
mouse and releases the loop at `$40806DD8` (`PADB`: the transactions of
6.7 item 4, then the auto-poll's Talk `$3C` repeating); InitUtil runs
against the clock (`PRTC`); the start-up goes on toward the `.Sony` Open
(`PSWM` PH = 7, 5.11 item 6) and, with no disk, the question mark. With
no `boot2.rom`, the machine stops at `$40806DD8` as compile 16 did.

**Rung 2 - input.** Keys and the mouse reach the ROM: the mouse moves the
pointer wherever the ROM shows one, and keys reach the event queue - which
this ROM cannot show much of without a boot device, so the fuller test
waits for a disk (SWIM rung 2) or SCSI.

## 6.11 Risks and open items

- **`342s0440-b.bin` is not on hand.** Daniel's MAME `MacSE30` set predates
  it (MAME's `adbmodem` device carries it). Everything in 6.3.3 is
  secondary until it is read. Its CRC and SHA1 (6.1) identify it.
- **The PIC1654S data sheet** (Microchip, 16 pp., about 502 KB, only found
  on `alldatasheet.com`): would make the divider, the 28-pin assignment,
  the pull-ups and the reset vector primary. Needs Daniel's OK to fetch.
  Until then: the divider from the *Guide*'s timings (6.3.1), the pins from
  the scan plus two independent witnesses (6.2), the reset vector from the
  dump.
- **The pull-ups**: kept on every line (6.3.1); the unconnected RB0/RB1
  read 1 because of them.
- **DIO contention** and **MAME's race** (6.3.2, 6.8): watched on the
  bench, not assumed away.
- ~~**The keyboard model** (6.4.3): Extended proposed, Daniel's choice; and
  the modifier mapping by position (6.12 item 4).~~ **Decided 2026-09-28:
  the Extended Keyboard, modifiers by position.**
- **Talk register 3's address field**: the real address (Table 8-15), not
  the FDB proposal's random one (6.12 item 4).
- **Write protect and the extended command** (6.5.1): the manual's rule
  followed; the secondary claim recorded.
- **`1HZ`'s duty cycle** and **the test register's effect**: undocumented,
  tier 2 (6.5.1-6.5.2).
- **The time zone**: `TIMESTAMP` is what Main sends; Main's DST handling
  for the MacPlus core (fixed upstream in Main #1321) applies unchanged.
- **PRAM persistence**: later, by decision.
- **C3M's pattern**: GLUE's 15-in-64 accumulator (2.11.3, "pattern OPEN")
  makes the PIC's instruction period vary by one C16M period in 32. ADB's
  tolerances (+/-3% host) are 30 times wider.

## 6.12 The work

1. ~~Write this section.~~ **Done 2026-09-28.**
2. ~~**Obtain `342s0440-b.bin`** (Daniel) and, with his OK, the PIC1654S
   data sheet. Read the dump: its layout, its reset vector, its use of
   RTCC, and its loops against 6.3.3 - the dump replaces the port as the
   map, and this section is corrected where they differ.~~ **Done
   2026-09-28** (6.1, 6.3.1, 6.3.3): the file matches; the data sheet
   removes OV and makes port A's high bits 0, and the core and `sim/pic`
   follow it.
3. ~~**`sim/pic/`** items 1-4, failing, then **`rtl/se30_pic1654.v`** until
   they pass.~~ **Done 2026-09-28: 88 checks** (iverilog, a few seconds),
   failing against an empty stub first, and mutation-tested (a /4 divider,
   a one-level stack, F2 reading the current address, no OV, a skip that
   does not discard, an inverted BTFSC - each caught). The manual leaves
   five things open, and the core's choices are **checks to make on the
   dump** (item 2): the reset address (a parameter, 777 octal, MAME's and
   the 16C5x's); status bits 7-4 and the unused high bits of port A read
   as 1 (the FSR's documented rule, generalised - MAME agrees); OV (bit 3)
   set by ADDWF and SUBWF only, per 2.1.7's definition (MAME's PIC1654S
   has no OV); an FSR of 0 through F0 reads 0 and writes nothing; the
   unused words 0001-0037 octal run as NOP. The dump shows whether it
   ever reads status bits 3-7, port A's high bits or F0 with FSR 0, or
   uses those words - if it does not, the choices cannot matter.
4. **`sim/adb/`** items 3-7 with the device engines stubbed silent (the
   no-device ReInit first), then **`rtl/se30_adb_xcvr.v`** (the PIC, its
   program RAM, the pins and the line) and **`rtl/se30_adb_dev.v`** with
   the keyboard and mouse until they pass.
   **Done 2026-09-28.** First the part that needs no dump:
   `rtl/se30_adb_dev.v` (the device engine, the Extended Keyboard, the
   Standard Mouse) against a new bench, **`sim/adbdev/`: 54 checks**
   (iverilog, seconds) with a host that speaks Table 8-14 at its nominal
   timing - Talk register 3, the reply's timing measured on the wire (140-
   260 us to the start bit, 35/65 us lows, the 100 us cell, the 70 us stop),
   key transitions two to a reply, Caps Lock locking, the Service Request
   (300 us) and its absence for the device being addressed, the mouse's
   clamp and remainder with Y inverted, Listen register 3 ($FE move,
   handlers stored or ignored, handler 3's right-hand codes, handler 2's
   doubled counts), Listen register 2's LEDs, Flush, SendReset, Global
   Reset, and a collision between two keyboards at one address (the loser
   keeps its key for the next Talk). Mutation-tested (no collision
   detection, no SRQ, no $FE move, Y not inverted, a reply at 300 us - each
   caught). `rtl/se30_adb_xcvr.v` (the PIC, its 512 x 12 store, the pins of
   6.3.2) is written and elaborates.
   **Then `sim/adb/` with the dump: 31 checks, all passing on the first
   run** (iverilog, a minute), mutation-tested (the PIC at /4, VIA1's CB2
   not reaching the PIC - each fails the first Talk). Apple's program on
   the core, behind the real `se30_via.v`, with the devices on the line,
   driven by the ROM's own VIA sequences (the transaction mechanics of
   the handler at `$40807002`, the send at `$408073E6`, the state writes
   at `$408073C0`; the ADB Manager's table and queue are not replayed):
   the command's timing on the wire **Attention 795 us, "0" 65 us, "1" 34
   us, the cell 101 us** - Table 8-14 from the program's own loops at C3M
   / 8; Talk register 3 to all sixteen addresses, **$6202 from 2 and
   $6301 from 3, INT\* low after state 1's first byte everywhere else**
   (the ROM's time-out, `$408070DA`), never in state 0; the Listen
   register 3 `$FE` move to 15 and back, each confirmed; Listen register
   2's LEDs; the auto-poll's entry and the transceiver polling on its own
   in state 3; the mouse's motion delivered through it (**$8085**, INT\*
   low after the pair); and a key pressed while the mouse is polled: INT\*
   low in state 1's first byte and in state 2 (the ROM's "no data" and
   its service-request flags, `$408070DA`, `$4080711C`), then the ROM's
   Talk to the keyboard bringing **$00FF**. No contention on DIO.
   **One number differs from the Guide:** the auto-poll repeats every
   **10.2 ms** against the Guide's "every 11 ms" (p. 314) - the program's
   own countdowns at C3M; recorded, not adjusted.
   Two choices made here, for Daniel: PC modifiers map **by key position**
   onto Figure 8-10 (Alt = Command, the Windows key = Option - the MacPlus
   donor maps Alt the same way), and Talk register 3 returns the device's
   real address (the Guide's Table 8-15), not the random one the FDB
   specification's pre-release text describes (the ROM does not read the
   field).
5. ~~**`sim/rtc/`** items 8-12, failing, then **`rtl/se30_rtc.v`**.~~
   **Done 2026-09-28: 59 checks.** Two things the bench found, both read
   from the ROM: the seconds decode ignores command bit 4 (the table in
   6.5.1, corrected), and the ROM makes PB0 an output again before it
   raises CS* - one VIA access in which both drive, the ROM's own order;
   the machine's pin takes the VIA's (4.5). *Inside Macintosh*'s reader
   (clock low) runs beside the ROM's (clock high): only it can tell a
   falling-edge chip from a rising-edge one, and the mutation proves it.
6. ~~**The machine and the top** (6.6): the wiring, `boot2.rom`, `hps_io`'s
   PS/2 and `TIMESTAMP`, `PADB` and `PRTC`, the README; elaboration.~~
   **Done 2026-09-28.** The transceiver on `c3m_en` and `via_reset_n`, the
   line the wired-AND of the three, the devices on no reset (the line's
   Global Reset reaches them: RESET* holds the PIC's latches high, RA2 turns
   Q3 on); the clock chip on PB2-PB0 and CA2, on no reset. `boot2.rom`
   (index `$80`) into the store, low byte first, twelve bits; the README's
   table. Probes `PADB` (64) and `PRTC` (32) in `dbg_probes.sv`, decoded
   by `read_probes.tcl`. **Analysis & Synthesis: 0 errors**, the RTC's RAM
   and the transceiver's store inferred as block RAM; one Quartus internal
   error on the way (the RTC's RAM read inside a function has no single
   read port - restructured to one registered read port and one write
   port, the byte loaded two clocks after the command, long before the
   first falling edge; the bench's mutation of that pipeline fails 3
   checks). **`sim/machine`: 17 PASS unchanged**, the same prediction, 59 s.
   With no `boot2.rom` the store is all NOPs and RA2's reset latch holds
   the line low: the machine waits at `$40806DD8` as compile 16 did, and
   `PADB` says so (W 0, the line low, no falls).
7. The compile (Daniel's go-ahead), the 3.6 ritual and `sta_corners.tcl`;
   the board: rung 1 (6.10).
   **Compile 17 (Daniel's go-ahead 2026-09-28; tag `90fe5b5b`, archived
   `MacSE30_90fe5b5b_adb.rbf`, md5 `e2ff23d8...`)**: 22m15s, the flow's
   worst slack +0.086 ns; 21,177 ALMs (51%), 196 RAM blocks (35%);
   `sta_corners.tcl`: every corner met with the capture excepted (worst
   0.964 ns), one of the two captures met at every corner (A's hold
   -0.141 ns at fast -40C and B's setup -0.335 ns at slow 100C, both as
   in compiles 15 and 16 - the training picks the one that works).
   **For the board:** `342s0440-b.bin` in the core's folder as
   `boot2.rom`. The prediction: past `$40806DD8`; `PADB` with W changing,
   the line released, falls climbing by about a thousand a second and
   last command `3C`; `PRTC` with transactions counted and the seconds'
   low byte ticking; `PSWM` PH = 7 (the `.Sony` Open reached); the screen,
   the flashing question-mark disk.
   **THE BOARD (compile 17, 2026-09-28): THE FLASHING QUESTION-MARK DISK -
   Section 5's rung 1 target - and a mouse cursor on the screen, but the
   mouse does not move it.** Start-up now runs past the ADB initialisation
   and the `.Sony` Open to the question mark. The frozen cursor had one
   cause, found before any probe was read: **GLUE's `c3m_en` is updated
   only on C16M's enable, so it is high for a whole C16M period - two
   `clk_sys` - and the transceiver took it unqualified**: the PIC counted
   each C3M pulse twice and ran at 7.3 MHz, halving every ADB timing. The
   devices decoded nothing, answered nothing, and the ROM's ReInit
   completed with an empty bus - which is why the start-up went on (6.7:
   "an ADB with nothing on it is a working ADB"). `sim/adb` had not seen
   it because its bench made its own one-clock C3M; **with GLUE's C3M
   modelled exactly it fails as the board did** (Attention 397 us, the
   cell 50 us, no device answers). The fix: the transceiver takes
   `c16_en` and `c3m_en` and runs on both, GLUE's convention for its
   clock enables. `sim/adb` 31 PASS again, `sim/machine` 17 PASS. Lesson
   for every bench: a clock enable comes from the module that makes it,
   or from an exact copy of it - a bench's idealised enable hid a factor
   of two.
   **Compile 18 (Daniel's go-ahead; tag `c9b1e0eb`, archived
   `MacSE30_c9b1e0eb_adbclk.rbf`, md5 `7b700080...`)**: 20m34s. **The
   flow reports timing NOT met: worst slack -0.186 ns, TNS -0.378 ns, in
   the framework's HDMI domain** (`pll_hdmi`, 148.5 MHz, 6.732 ns) at the
   slow -40C corner only: six paths inside `sys/ascal.vhd`, the scaler's
   polyphase luminance arithmetic (`o_vpix_inner`/`o_h_lum_pix` ->
   `o_poly_lum`). None is the machine's: `sta_corners.tcl` has every
   corner met with the capture excepted (worst 0.952 ns) and one capture
   met at every corner (A's hold -0.141 at fast -40C, B's setup -0.337 at
   slow 100C, as in compiles 15-17). The same domain passed in compile
   17 (the flow's worst there +0.086 ns): placement noise on a framework
   path that sits at the edge. By the standing rule this bitstream is
   **not timing-met**; whether to test it, re-seed the fit, or trim the
   scaler is Daniel's call.
   **THE BOARD (compile 18, 2026-09-28, flashed by Daniel knowing the
   scaler path): THE MOUSE MOVES THE CURSOR** at the flashing
   question-mark disk. Rung 1 of 6.10 is met: Apple's transceiver
   program, on the PIC1654S core, finds the mouse through the ROM's
   ReInit and delivers its motion through the auto-poll. The keyboard
   waits for a boot device to show itself (rung 2).
8. Rung 2 when a boot device exists; PRAM persistence (Daniel's call on
   how: the framework's file interface to a `.sav` beside the ROMs is the
   usual MiSTer way).

---

## Appendix - where the sources are

The IIvi core is now cloned durably at `C:/Git/MiSTer-devel/MacIIvi_MiSTer`
beside MacLC (2026-09-25); `sim/pmmu_rom_contract/run.sh` compiles the PMMU
from there by default. The others were shallow-cloned into a session
scratchpad that does not survive; re-clone as needed:

| repo | why |
|---|---|
| `github.com/danifunker/MacIIvi_MiSTer` | **the important one.** 68030 + PMMU at 15.6672 MHz. `rtl/tg68k/TG68K_PMMU_030.vhd`, `68030_PMMU_TESTBENCH.md`, `SingleStepTests/pmmu/`, and **upstream's whole ModelSim suite in `tests/tg68k_030/`** (129 files, `Makefile`, `run_tests.do`) - so the VHDL benches of 1.10 are already on disk |
| `github.com/danifunker/MacLCII_MiSTer` | also 68030; the qip header calls the PMMU branch "for the Mac LC II", so this may be the primary 030 target and the IIvi the follower. Not yet read |
| `github.com/danifunker/MacLC_MiSTer` | the proposed base. Already cloned at `C:/Git/MiSTer-devel/MacLC_MiSTer` |
| `github.com/danifunker/MacQuadra800_MiSTer` | 68040. Wrong MMU for us, but `rtl/ap68040/` is the only open 68k FPU found, its `tb/` is iverilog-based, and `scripts/` is a MiSTer hardware-automation harness worth taking on its own merits |
| `github.com/alanswx/AP68040`, `github.com/apolkosnik/AP68040` | AP68040 upstreams |

| `github.com/apolkosnik/Minimig-AGA_MiSTer` branch `030_mmu2` | **the PMMU's upstream**, named by danifunker. Carries the audit trail 1.7 now rests on - `030_MMU_PORT_AUDIT.md`, `MMU_AUDIT.md`, `CPU_AUDIT.md`, `REVIEW_2026-07-23_CPU_MMU_CACHE.md` - plus `tests/tg68k_030/` (167 files) and the packaged cputest 030 data. **Cloned shallow at `C:/Git/MiSTer-devel/Minimig-AGA_MiSTer_030_mmu2`** (tip `c3e8a0d`, 2026-07-25), with the `030`, `030_mmu`, `030_mmu_fpu`, `030_mmu_fpu2` and `fpu` tips fetched shallow into it |
| same repo, branch `030_mmu2_fpu2` | **the 68881/68882 FPU** (1.12): `rtl/tg68k/TG68K_FPU*.vhd`. Tip `bd9d8f1`, 2026-05-23 - older than `030_mmu2`. **Cloned shallow at `C:/Git/MiSTer-devel/Minimig-AGA_MiSTer_030_mmu2_fpu2`** |
| `github.com/apolkosnik/before` | NeXTcube on MiSTer. **68040**, so not a CPU candidate, but an existence proof that a 68k core with a working MMU boots a demanding Unix on a DE10-Nano |
| `github.com/AmicableComputers/wf68k30L` | Wolfgang Foerster's pipelined VHDL 68030. **No MMU, no caches, no coprocessor interface** - useless as a CPU here, valuable as a *readable* 030 cross-reference against the generated kernel. Upstream uses it the same way |

~~GPLv2 or GPLv2-or-later where checked.~~ **Corrected 2026-09-25:** the
TG68K kernel, ALU, PMMU and FPU headers all say LGPL-3 or later (1.12).
**wf68k30L's licence has not been checked.**

**Primary documents and the ROM.**

| source | where |
|---|---|
| **MC68030 User's Manual, 3rd edition (1990)** | bitsavers `components/motorola/68000/68030/MC68030_Users_Manual_3ed_1990.pdf` (20MB, use the `trailing-edge` mirror); copied to `C:\temp\Mac\SE30\Docs`. `pdftotext -layout` gives a greppable text; section 9 is the MMU |
| **The SE/30 ROM** | `C:\temp\Mac\ROMS\256KB ROMs\1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM`. There is no file named SE/30: this is the SE/30's ROM, shared with those three machines (MAME's `macse30` loads the same image). Physical base `$40800000` |
| **The video declaration ROM** | `C:\temp\Mac\ROMS\MacSE30\se30vrom.uk6` - MAME's `macse30` set (the folder also holds that set's NuBus and PDS card ROMs and a copy of the main ROM). 8KB, CRC32 `b74c3463`, Apple part 341-0650. Read in 2.10 by `scripts/se30_declrom.py` |
| **`se30.pdf`** in `C:\temp\Mac\SE30\Docs` | **Apple drawing 050-0253-01, the SE/30 main logic board schematic**, 8 of 9 D-size sheets, raster scan. Sheet titles in 2.1. Read by extracting the page images with pypdf/PIL and cropping at full resolution |
| `github.com/mishimasensei/macse30mlb` | **KiCad redraw of 050-0253-01, MIT.** All 9 sheets plus a pin-matrix sheet, and per-sheet PDF exports with real text. Snapshot at `C:/Git/MiSTer-devel/macse30mlb` (tarball - a filename with a colon defeats `git clone` on NTFS). `scripts/kicad_nets.py` prints pin-to-net tables from its v5 sheets; `ROM+RAM Muxes.kicad_sch` is v6 and is not parsed (UH7 was read from the scan) |
| **The SWIM documents** (Section 5) | `C:\temp\Mac\SE30\Docs\swim`, from bitsavers `/pdf/apple/disk/sony/` (`trailing-edge` mirror): `SWIM_343S0061-A_1988.pdf` (the production drawing), `SWIM_chip_spec_198707.pdf`, `SWIM_Chip_Users_Ref_198801.pdf`, `ISM_ASIC_spec_198707.pdf`, `IWM_undoco_features.pdf`, `Software_control_of_IWM.pdf`, `IOP_SWIM_Driver_ERS_199001.pdf`, `Hand_notes_on_floppy_stuff.pdf`, `Apple_3.5_Drive_Schematic.pdf`, `Apple_drive_command_and_status_codes.pdf` (secondary), `SWIM_regs.txt` (SWIM III, not ours); `.txt` beside each is `pdftotext -layout`. Standing in 5.1 |
| **The ADB and RTC documents** (Section 6) | `C:\temp\Mac\SE30\Docs\adb`, from the bitsavers `trailing-edge` mirror: `1983_PIC_Series_Microcomputer_Data_Manual.pdf` (`components/gi/PIC/`), `Inside_Macintosh_Hardware_198502.pdf` (`pdf/apple/mac/`), `FDB_Specification_Rev_B_Proposal_19850613.pdf` (`pdf/apple/adb/fdb/`); and `macseadb88.asm` (github `lampmerchant/macseadb88`, secondary). The transceiver's program `342s0440-b.bin` (CRC32 `cffb33eb`) is MAME's `adbmodem` device ROM, not yet on hand. Standing in 6.1 |
| Macintosh Repository, item 875 | "Macintosh SE/30 Schematics and Repair": `se30schems.zip` (4.1MB) and `Repair_Macintosh_SE30.zip`. Downloads sit behind an HTML interstitial; not fetched. The redraw's notes point to the same scans' origin at `museo.freaknet.org` (Andreas Kann) |

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
