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

**This document is being composed in sections, each one following its own
research pass.** Section 1 settles the CPU and the PMMU, because that was
the only open question capable of making the project impossible. **Section
2 (GLUE, the address map, RAM, clocks, video) was opened 2026-09-25 as a
first cut** with its own open-items list in 2.8. Nothing about the ASC, the
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
   one area workaround. Adopt the IIvi's sync rule: never fork the kernel.
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
   FPU forward onto the audited kernel - **upstream first**, per the sync
   rule in 1.12, since it is the same author's code; re-enable the
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
now. The IIvi's own `CLAUDE.md` states the rule they arrived at, and it is
the rule we should adopt verbatim: **kernel fixes land upstream first and
are re-copied; never fork the kernel; the bus wrapper is ours.**

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
| `$FE000000-$FEFFFFFF` | slot `$E`: video | VRAM at `$FE000000`, declaration ROM at `$FEFFE000` (MAME; the *Guide* gives the space, not the offsets - see 2.6) |

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
with `LAS*` in its term - **the OE handling of that pin is not yet
understood and is an open item.**

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

**What the declaration ROM contains is a Section-2 open item.** MAME's
`se30vrom.uk6` is 8KB at `$FEFFE000` (CRC `b74c3463`); the *Guide* only
says it holds the video driver and initialisation routines. Without it the
ROM's slot manager finds no video card. It is not in the ROMS folder; it has
to be obtained.

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

Not settled: GLUE's internal timing (there is no source; it is a contract);
the I/O block's exact mirror rule ("wraps eight times", 2.2); the
declaration ROM's contents and where to get an image; the `BERR*` term on
UI6; sheet 9; and everything on sheets 6-8 (SWIM, SCSI, SCC, ASC, power),
which are later sections. Settled since the first cut, from the *Guide*'s
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
3. **Obtain the declaration ROM** image and read its slot resources - the
   video driver in it is what the System will run.
4. **Write the GLUE specification** as a table of cycles: for each region,
   the select, the width, the wait states, the DSACK behaviour, and the
   bus-error timeout - the document the RTL and 1.10's benches are both
   written against.
5. Only then: the video PALs as RTL, from the named equations, benched
   against the *Guide*'s line and frame counts (704 x 370 at 15.6672 MHz).

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
| `HSYNC*` low | 288 px from pixel 536 | not given |

**Vertical timing - UG6 with the UF8 counter.** UG6's internal Q1-Q3 form a
mod-8 pixel phase; `VIDTIME` is *vertical-active AND phase 2* - one pulse
per byte during active lines, which is what drives `SC` and `C2M`'s
resynchronisation. Q4 is the vertical-active flag, set and cleared by
decodes of the line-pair count `VADR`. `VIDOUT` is `SERVID` registered
(one clock late). Measured:

| | measured | *Guide* 12 |
|---|---|---|
| active lines | 342 (line pairs 1-171) | 342 |
| `VSYNC*` | low 4 lines, from line 344 | not given |
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
   In this reading active video ends at line 343, `VSYNC*` falls at 344
   and the next frame's video starts at line 374, so the whole 30-line
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
The exact cycle count from `AS*` to `DSACK0*` is not extracted here; it
will be, by simulation, when the video RTL is written, and it is what
determines VRAM access speed.

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
   **between one and two line times, ~45-90 us, with no acknowledge.**
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
