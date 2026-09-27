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
(the tree) was opened 2026-09-26.** Nothing about the ASC, the
SWIM, the SCC, SCSI or power should be inferred from what is written here -
those sections do not exist yet, and the facts they need have not been
read.

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

**The VIA cycle (row 3).** `E` is 783.36 kHz = `C16M/20`, period 1.2766
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
   envelope 12-32 with `E` = `C16M/20`; SCC >= 4 and the 34.5-clock
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
| mode register | `A9` write burst (0 = burst), `A8-A7` = 00, `A6-A4` CL (010 = 2), `A3` = 0 sequential, `A2-A0` burst length (001 = 2) | the same | `$0021`: CL2, sequential, BL2, burst writes | - |

So the read of 3.2's table runs (as revised after the first compile, 3.8
item 9): the S0 address is sampled at clock 2, ACTIVE at 3, READ at 5;
CL2 gives the first word after the chip's edge at 7.5 and the second at
8.5 - the chip's edges, which are the FPGA's falling edges plus the
clock's delay to the pin, 4 ns (the second compile's STA, below); each
word is at the FPGA's pin from 10.5 ns after the fabric's falling edge
(skew + `tAC` 6.0 + 0.5 of trace) to 17.1 ns after it (skew + the period
+ `tOH` 2.5), a 6.6 ns eye. The words are captured in the I/O cell on the
FPGA's **rising** edges at 9 and 10, 15.96 ns after the falling edge:
5.4 ns of setup and 1.1 ns of hold inside the eye. The falling edge at
10.64 ns (MacLC's choice, and this plan's until the second compile) is
0.1 ns into the eye - the -2.49 ns of the second compile. The capture is
then taken into the read-data register a full period later, presented
with the acknowledge at 11 - one clock before GLUE's sampling edge at
12. `SDRAM_CLK` is the inverted `clk_mem` (MacLC's `altddio_out`), so the
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

A probe deck (`rtl/dbg_probes.sv`, ours, under a define) exposes to
SignalTap/ISSP what the bring-up needs read back over JTAG, which is the
one hardware access permitted (`feedback_merge_compile_gate`): the fetch
address, the last `AS*` address and FC, cycle and bus-error counters,
`halted`.

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
   of 3.2; no 332125/332081; the fit recorded against 1.6's table.
6. **Hardware - Daniel flashes, always.** The probes say the CPU fetched
   from ROM, ran, and stopped where the machine bench said it would.

Then each peripheral section repeats rungs 1, 4, 5, 6 with its own bench
at rung 2 and the machine bench extended at rung 3, and the ROM gets one
step further each time: the VIAs and RAM sizing (the mirror rule's
acceptance test, 2.11.6), the boot chime (ASC), the disk (SWIM, SCSI), the
desktop (ADB).

## 3.7 Risks and open items

- **The SDRAM read eye at 94 MHz** and the S0 speculative start are the
  section's engineering risk; the bench of 3.6 item 2 catches logic, not
  I/O timing - the sdc constraints (MacLC's 2026-09-12 set, re-derived for
  the new period) and the first fit's STA are the only evidence before
  hardware. **The first fit met the I/O constraints (+1.7 ns) and failed
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
    RBF was not flashed. **Next: the third compile, with Daniel's
    go-ahead given for it.**

Then Section 4, the VIAs, documentation first: Apple's VIA cell
specification (Nov 1989), the R65C22 data sheet, the *Guide*'s bit tables
(2.7), and only then the donor `via6522.sv` (MacLC) and `via6522.vhd`
(MacPlus, Gideon's) assessed against them.

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
