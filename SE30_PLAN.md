# Plan: a Macintosh SE/30 model

Written 2026-09-21, in `MacPlus_MiSTer` on a parking branch. Transferred to
this repo the same day and revised here; work proceeds on `dev`.

**Working rule (Daniel, 2026-10-02): every test gets an estimate first.**
Before any test or bench run, state its expected wall time, the basis for
it and the confidence. **Anything estimated over 30 minutes - a parallel
batch included, if it ends later than that - waits for Daniel's go-ahead**,
with the shorter options offered, and is not started meanwhile. A run that
noticeably overruns its estimate is reported and re-estimated.

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

**Revision 2026-10-03.** **Section 9 (SCSI) is new**: from NCR's
SP-1051 manual, the *Guide*'s chapter 11, sheet 6 and the ROM's SCSI
Manager. Daniel chose our own 53C80 to the manual with the MacPlus
`scsi.v` targets, two disks first, then the CD-ROM with CD audio.

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
(Connectix - period-correct, an extension installed on the System) or a Mac
IIsi / IIfx ROM SIMM, which is a hardware modification. (Corrected
2026-10-04: this said MODE32 was "built into System 7.5.3 / 7.5.5". On the
core, System 7.5.5's Memory control panel offers no 32-Bit Addressing
setting and TattleTech reads "Machine is 32 Bit capable = No" - so 7.5.5
alone does not make an SE/30 32-bit; the extension or a clean ROM is
needed. TattleTech's whole first page otherwise reads as a real SE/30's:
Mac SE/30 (ID 9), MC68030 at 16 MHz, both caches on, MC68882, the 030's
MMU, 8 MB, VM off.) Confirmed by 68kMLA, "32-bit Addressing in SE/30"
(https://68kmla.org/bb/threads/32-bit-addressing-in-se-30.24573/, 2012):
under 7.5.5 an SE/30 runs 32-bit "using the Mode32 utility ... or source a
IIfx/IIsi ROM SIMM"; MODE32 must be installed with its own installer (its
last version covers 7.0-7.5.5); with a clean ROM it is not needed, and
32-bit is switched on in the Memory control panel. **For the 128 MB
clean-ROM option:** the poster followed "Gamba's page" (a ResEdit edit of
the System file for the IIsi/IIfx ROM in an SE/30), and changing the
Memory control panel then gave a Sad Mac and an unreadable drive until it
was restored from a DiskCopy image (a PRAM reset suggested) - so that
option's first board test is on a scratch image, PRAM reset first.

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

## 1.16 The 68030's caches (1.15 item 9; opened 2026-10-02)

**Why now.** The core runs the system and applications; it measures at
about 10 MHz in TattleTech, and a DBRA loop takes 9 clocks where the
68030's cache case is 6 (UM 11): with no caches every instruction word
comes over the bus. Daniel, 2026-10-02: the caches today, the instruction
cache first.

**What the manual says** (MC68030 UM section 6, read in full):
- Two 256-byte direct-mapped caches, instruction and data: 16 lines of
  four long-word entries, **a valid bit per entry**, each entry replaced
  on its own. Index A7-A4, entry A3-A2. **Logical addresses**: the
  instruction cache's tag is A31-A8 and FC2; the data cache's A31-A8 and
  FC2-FC0. CPU space (FC 7) is never cached.
- An access is **cachable** when the cache is enabled in CACR, CDIS* is
  negated, CIIN* is negated, CIOUT* is negated (the MMU's CI bit for the
  page, from the ATC or a TTR) and the MMU validates it. **A hit ignores
  the MMU** (and its CI): no external cycle.
- **Filling**: on the SE/30, CBACK* is pulled up and goes nowhere (2.11.1),
  so **no burst ever completes: single-entry mode**, one long word per
  miss - "an entire long word is required"; from a 32-bit port one cycle,
  from narrower ports the cycles to complete the long. Every cachable
  place on the board (RAM, ROM) is a 32-bit port; I/O, the slots and the
  video are CI by the ROM's tables (1.11, 2.11.1).
- **The data cache is write-through.** A write hit updates the entry and
  memory, even frozen. A write miss: with WA = 0 nothing in the cache
  changes; with WA = 1 an aligned long-word write replaces the tag and
  validates its entry only (the other three invalidated if the tag
  changed); a byte, word or misaligned write that misses is not written,
  the tag unchanged, the entry's valid bit cleared. CI ignores the cache
  even for writes. A misaligned operand that spans two entries is two
  independent hits or misses.
- **Read-modify-write** (TAS, CAS): the read is forced to miss, its data
  fills or updates the cache if cachable; the write is an ordinary write.
  **Table-search accesses** (the walker) never touch the data cache.
- **CACR** (MOVEC): EI (0), FI (1), CEI (2), CI (3), IBE (4); ED (8), FD
  (9), CED (10), CD (11), DBE (12), WA (13). CI/CD clear a whole cache,
  CEI/CED the entry CAAR bits 7-2 name, regardless of enable and freeze;
  those four read 0. Freeze: a miss does not replace (write hits still
  update). Disabling keeps the entries. **Reset** clears every valid bit
  and every enable, freeze, burst and WA bit.
- **CDIS*** disables both caches whatever CACR says: on the SE/30 it is
  **VIA2 PB0** (4.x's table), which the ROM drives.

**What is already there.** The kernel has CACR and CAAR (MOVEC, the
read mask `$3313`, the clear bits self-clearing one at a time) and exports
CACR, the clear request and its entry address, and the PMMU's cache
inhibit for the current translation. `rtl/tg68k/TG68K_Cache_030.vhd`
(upstream) is **not used**: it fills 16-byte lines (bursts the SE/30 never
does) and leaves WA unimplemented; it is read for engineering only.

**The design** (`rtl/tg68k/se30_cache030.v`, ours, in the wrapper):
- The wrapper sees each kernel request before it becomes a bus cycle.
  **Tags and valid bits in registers** (so a hit is known in the clock the
  request is taken), **the data in block RAM** (64 long words a cache).
  A hit acknowledges the kernel one C16M clock after the request with the
  entry as a 32-bit port's long, and runs **no bus cycle**; a miss runs the
  cycle as now, with no added clock, and a cachable read cycle answered
  by a 32-bit port fills its entry from the long latched at S5.
- The tag is the **logical address**: the kernel exports it beside the
  physical one (a new port). FC from the kernel; cachability from CACR,
  CDIS* and the PMMU's CI for the access.
- The instruction cache serves the kernel's fetches (its aligned-long
  prefetch, `busstate` 00); the data cache its data reads and writes (a
  kernel beat is one long's bytes at most, so it falls in one entry).
- **Step 1, today: the instruction cache**, with CACR's EI/FI/CEI/CI and
  CDIS*. **Step 2: the data cache**, with WA, the RMC forced miss (the
  kernel to flag TAS and CAS reads) and the walker excluded.

**The tests.** A unit bench of the cache against a reference of UM
section 6 (hits, misses, fills, freezes, clears, WA's cases, CI, CDIS,
reset), every case named; `sim/kernel_bus` (16/32/8) and `sim/system`
with the caches off and on (identical results, fewer bus cycles);
`sim/busfault`, `sim/cpfpu` (all 13), `sim/machine`; a timing check that a
cached DBRA loop takes the cache case's clocks. Then the board: TattleTech's
speed, the Finder, applications.

### 1.16.1 Step 1 as built: the instruction cache (2026-10-02)

**RTL.**
- `rtl/tg68k/se30_cache030.v`: tags {A31-A8, FC2} and the valid bits in
  registers, 64 data longs in a RAM read every clock (`i_q` follows the
  address by one clock). A fill with a new tag replaces the line and
  leaves only its own entry valid. CI and CEI (at CAAR's index) clear,
  enabled or not, and win over a fill in the same clock. Reset clears.
  EI with CDIS* negated enables it; FI stops the fills.
- The kernel: one new port, `addr_log_out`, the logical address of the
  request (with the fetch's A1 as on `addr_out`).
- `rtl/tg68k/tg68k.v`: in S0 a kernel fetch (`busstate` 00, not parked)
  that hits sets `hit_ack` and runs no cycle (no ECS, no AS*). The kernel
  is acknowledged at the next phi1 with the entry as a 32-bit port's long
  (`dsack` 00): **one C16M clock a hit**. A fetch cycle records at S1
  whether it may fill: not CI by the PMMU, not CPU space. It fills at S5
  if the port answered 32 bits (`dsack_n` 00) and there was no bus error.
- A fetch answered by an 8- or 16-bit port is not cached. The 68030 would
  complete the long with more cycles and cache it, but the SE/30 runs no
  code from such ports except the video card's declaration ROM at
  PrimaryInit (once).
- `rtl/se30_machine.v`: `cdis` = VIA2 PB0 low (CDIS* is active low on the
  pin).

**Tests (all PASS).**
- `sim/cache030`: the unit bench, 27 checks in 10 rule groups (UM 6.1-6.3)
  plus 200,000 random clocks against a reference model of the same rules.
  Three mutants are caught: FC2 dropped from the tag, no invalidation on a
  tag replacement, and FI ignored.
- `sim/system` now makes three runs, 28 s in all:
  - **plain** (the cache never enabled; 0 hits);
  - **cacheon**: the same program with EI set first. Every slot and cycle
    check passes, with 10 hits and 9 fewer fetch cycles;
  - **cachetest**: `gen_cache_program.py`, the manual's rules through the
    whole kernel-wrapper-GLUE path. Its slots check:
    - stale code runs after a data write (no coherency, UM 6.1);
    - CI clears;
    - CACR reads CI as 0;
    - a frozen cache still hits and does not fill;
    - CEI clears only CAAR's entry, its line-mate stays;
    - EI clear means no hits, and the entries survive it.
  - In cachetest, a DBRA loop of 500 turns takes **3 fetch cycles with
    the cache on, 1,001 off**.
  - Two mutants of the wrapper are caught: fills off, and hits answered
    with the bus latch.
- `sim/machine`: PASS. The ROM does not enable the cache inside the bench's
  window: CACR = $2000 at reset, and EI is set later, at $40802C88.
- `sim/kernel_bus` at ports 16, 32 and 8, and `sim/busfault`: PASS, 21 s.
  `sim/cpfpu`, all 12 programs (b1 to b5d, mmu, full): PASS, 84 s.

**Timing against the manual - DECIDED: accepted (Daniel, 2026-10-02, option 1).**
- **Cached:** UM Table 11-48 gives DBcc (cc false, count not expired) as
  **6 clocks**. The cachetest loop measures **3.0 C16M clocks a turn**.
- **Uncached:** the table gives 8 clocks with two 2-clock prefetches; on
  the SE/30's 4-clock RAM cycle that is about 12 if neither prefetch
  overlaps. We measure **9.1**.
- Cause: the kernel runs DBRA in fewer internal clocks than the 68030 does.
  The cache is not the cause; it only removed the bus time that hid this.
- The options:
  1. **Accept it.** The kernel is not cycle-exact anywhere, and the ROM
     calibrates its timing constants (TimeDBRA and the rest) at boot.
  2. **Pace the kernel to Table 11 per instruction.** This is the
     cycle-exact kernel, a project of its own.
  3. **A blanket wait per hit.** Not authentic, so not recommended.
- Daniel chose option 1, "yes, accept it": the kernel's instruction timing
  stays as it is, and the cache adds no pacing.
- Compile 26 (2026-10-02, Daniel's go): the instruction cache alone, for the
  board before the data cache is added.
  - **Tag 88f27b67, 32 min.** Archived by hand as
    `output_files/MacSE30_88f27b67_icache.rbf`. `archive_build.ps1`
    refused it, because step 2 was committed while the fitter ran. The map
    report proves the netlist is step 1: the cache has only `idat`/`i_q`
    and the 25-bit tags, with no data-cache structures.
  - **33,104 ALMs (79 %).**
  - `sta_corners.tcl`: our design meets timing at every corner, worst
    slack **1.031 ns**, the capture judged by its A/B rule.
  - The framework's HDMI scaler clock (`pll_hdmi`) misses setup by
    **-0.118 ns at slow -40C** and **-0.060 ns at slow 100C**. That is the
    framework path that missed in compile 25 (-0.016 ns at -40C), now also
    missing at 100C.
  - **On the board: it runs, and TattleTech reads 31 MHz** (compile 25,
    no cache: about 10 MHz). A real SE/30 is 15.67 MHz with a cached DBRA
    turn of 6 clocks, and 15.67 x 6 / clocks matches both readings:
    9.1 clocks -> 10.3 MHz, 3.0 -> 31.3 MHz. The cache works; what
    TattleTech sees is the kernel's own timing.
  - **Daniel, 2026-10-02: "leave it for now"**, so option 1 stands.
    Software that times itself with fixed loops runs up to about 2x fast.

### 1.16.2 Step 2: the data cache - the manual's rules and the design

**The rules** (UM 6.1.2, 6.1.2.1, 6.1.2.2, 6.1.3.1, 6.3.1.1-6; re-read
for this step):
- **Tag and size.** 16 lines of four long-word entries, a valid bit each.
  The tag is A31-A8 with **FC2-FC0**, so user data (FC 1) and supervisor
  data (FC 5) are different entries.
- **Read hit.** No bus cycle. A cachable read that misses runs its cycle;
  with BERR negated and a 32-bit termination it fills the entry. The tag
  is replaced and the other three entries invalidated if the tag differed.
  The fill does not happen if FD is set: "the indexed entry is not
  replaced".
- **Write-through.**
  - **A write hit** updates the entry's written bytes, whatever the size,
    **even frozen**. The cache is written before memory, so it keeps the
    new value even if the external cycle ends in a bus error. A write the
    MMU finds invalid invalidates its entry and takes the bus error.
  - **A write miss, WA = 0:** no change.
  - **A write miss, WA = 1,** depends on the write:
    - an aligned long-word write replaces the tag and validates only its
      entry (the other three are invalidated if the tag changed);
    - a byte, word or misaligned write is not written, the tag is unaltered,
      and the entry's valid bit is cleared.
  - "If the data cache is disabled or frozen, the WA bit is ignored".
    Frozen is therefore no-write-allocate, and disabled means nothing
    changes.
- **Uncachable.**
  - CI from the MMU (CIOUT*) makes the cache ignore the access, writes
    included.
  - CIIN* is pulled up on the SE/30 (2.11.1). The video's 8- and 16-bit
    ports are CI in the ROM's tables, so no narrow-port fill arises there.
  - CPU space (FC 7) is never cached.
  - **Table searches** (the walker) never touch the data cache.
- **Read-modify-write** (TAS, CAS, CAS2):
  - the read is **forced to miss**; its data updates a matching entry or,
    unfrozen, creates one;
  - the write is an ordinary write (a hit updates; a miss follows WA).
- **CACR.**
  - CD (bit 11) clears every entry; CED (bit 10) clears the entry CAAR names,
    whatever ED and FD say.
  - ED off keeps the entries: they are valid and used again when ED is
    set again.
  - Reset clears ED, FD, DBE, WA and the valid bits.

**The design.**
- **Where it goes.** `se30_cache030.v` gains a second, data, half beside
  the instruction half: tags {A31-A8, FC2-FC0} and valid bits in
  registers, 64 longs in RAM with byte writes.
- **Read hits.** A kernel data read (`busstate` 10, not parked, not the
  walker, not RMC) that hits is answered like a fetch hit: no cycle, the
  kernel acknowledged a C16M clock later with the long as a 32-bit port's.
  A kernel beat is one long's bytes at most (1.14), so each beat is one
  entry, and a misaligned operand is two beats, two entries.
- **Read fills.** A cachable read cycle fills at S5, as the instruction
  half does. The same goes for an RMC read, which never hits.
- **Writes.**
  - A kernel write updates the cache **at S1**, as the cycle starts, with
    the bytes its beat puts on a 32-bit port's lanes: `A1-A0` up to the
    long's end, as many as SIZ says remain.
  - "Aligned long" is SIZ = long with A1-A0 = 0.
  - A write the PMMU faults (the wrapper's `k_force`) invalidates a
    matching entry.
- **RMC.** The kernel exports `rmc_out`, its existing `pmmu_rmw` (locked
  TAS/CAS/CAS2 data cycles, never fetches).
- **Not built.** Narrow-port fills: the 68030 would run the extra cycles
  to complete a long. No cachable narrow port exists on the SE/30
  (2.11.1), so a narrow-port read is simply not cached.
- **One difference from the chip, recorded.** A hit on the real 68030
  needs no translation, so a hit on a page whose descriptor has since been
  made invalid does not fault. Here the kernel's PMMU translates (or
  faults) before the wrapper sees the request. Only software that
  invalidates a page without flushing the caches could tell, and the Mac
  OS flushes.

**The tests.**
- The unit bench gains the data half's rules against its reference:
  - read hit and fill;
  - FC2-0 in the tag;
  - write hit with every lane pattern, frozen too;
  - WA 0 and 1 with aligned, misaligned and short writes, Figure 6-4's
    five examples among them;
  - the RMC forced miss and its update or create;
  - CI, CD, CED and ED off.
- `sim/system`'s cachetest gains data slots. The bench changes RAM behind
  the cache when the program asks:
  - a stale read;
  - TAS reading memory, not the cache;
  - a byte write merged into a cached long;
  - the manual's aliasing case through MOVES to user data space, with
    WA 0 (the stale supervisor copy survives) and WA 1 (it is replaced);
  - a DBRA loop over a cached operand.
- Then the regression batch, as for step 1.

**What the ROM does with the data cache** (the 97221136 image, every
`MOVEC ...,CACR`):
- **$4083F74A:** `MOVE.W #$2909,D0; MOVEC D0,CACR`, then `MOVEC CACR,D0;
  BCLR #8,D0; BEQ; MOVEC D0,CACR`. This sets WA, CD, ED, CI and EI, then
  takes ED away again if it stuck: the 68020/68030 test (a 68020 has no
  ED). Run word for word in `sim/system` (cachetest slots 15-16), it
  leaves CACR = $2001 and D1 = 3, as on a 68030.
- **$4083F7B4: the ROM then turns the data cache ON.** It runs
  `LEA ...,A0; MOVE.L A0,$660; MOVEQ #2,D0; MOVEA.L D0,A0; _HWPriv`, which
  is HWPriv selector 2, SwapDataCache, with A0 nonzero ("enable").
  **A stock SE/30 boots with both caches on and WA set: CACR = $2101.**
  - The first reading of this section said the data cache stayed off.
    That was wrong; the board corrected it (compile 27's PCCH read $2101
    at the boot-disk search, before any system was loaded).
- **$4083F7E4: the HWPriv cache selectors.**
  - 0 SwapInstructionCache;
  - 1 FlushInstructionCache (CI);
  - 2 SwapDataCache, at $4083F828: `MOVEC CACR,D0; BFEXTU` (the old
    state, returned in A0); `BCLR #8`; if A0 is nonzero, `ORI.W #$0900`,
    so CD flushes as it enables;
  - 3 FlushDataCache (CD).
- **Elsewhere:**
  - $40803060 and $40803070: the test manager's commands $32 and $33,
    which set EI and clear it;
  - $40803B4E: `ORI #$0808`, flushing both caches;
  - $408065FA: CI;
  - $4083F862: $2000 after RESET.

### 1.16.3 Step 2 as built: the data cache (2026-10-02)

**RTL.**
- `se30_cache030.v` has a data half, to 1.16.2's rules. Tags {A31-A8,
  FC2-FC0} and the valid bits are in registers; the data is four byte RAMs
  of 64 entries.
  - **Reads:** a fill updates a matching valid entry, frozen or not, and
    otherwise, unfrozen, fills the entry and replaces the tag.
  - **Writes:** a write hit writes its bytes, even frozen. With WA set and
    FD clear, a write miss either allocates (an aligned long) or clears the
    entry's valid bit (any other write). CD, CED and reset clear.
- The kernel has one new port, `rmc_out` (its `pmmu_rmw`).
- `tg68k.v`:
  - **Read hits.** A data read (`busstate` 10) that hits, and is not RMC
    or CPU space, is answered like a fetch hit (`hit_d` selects `d_q`).
    A cachable data read cycle fills at S5.
  - **Writes.** A cachable write updates the cache at S1, with
    `d_wbe` = the beat's bytes on a 32-bit port: A1-A0 up to the long's
    end, as many as SIZ says.
  - **Faults.** A write the PMMU faults clears its matching entry. These
    are k_force's terms, spelled out because k_force is declared later.

**Tests (all PASS).**
- `sim/cache030`: 60 checks in 8 s. The data half adds D1-D14 (the five
  examples of Figure 6-4 among them) and 200,000 random clocks against a
  reference. Four mutants are caught:
  - partial write misses not clearing their valid bit;
  - FD not stopping write-allocation;
  - the tag keeping only FC2;
  - write hits writing all four bytes.
- `sim/system` now makes four runs, 48 s in all:
  - **cacheon** (CACR $0101) and **cachewa** ($2101) run the kernel_bus
    program, every size at every offset, through both caches. Every slot
    and cycle check passes, with data cycles 244 -> 160/163.
  - **cachetest** adds slots 9-14:
    - a stale read;
    - TAS reading memory ($A2222222);
    - a byte write hit merged ($A222225A, memory $3333335A);
    - the MOVES alias with WA clear (stale $AAAAAAAA) and with WA set
      ($CCCCCCCC);
    - ADD.L over a cached operand: 2 data cycles for 500 turns.
  - Three wrapper mutants are caught:
    - the RMC read not forced to miss (slot 10 = $91111111);
    - write lanes ignored;
    - data fills off.
- The regression, all PASS:
  - `sim/kernel_bus` at ports 16, 32 and 8, and `sim/busfault`: 24 s;
  - `sim/cpfpu`, all 12 programs: 94 s;
  - `sim/machine`: 80 s, with a fresh run.log.
  - **cputest harness B, all 79 batches, on the cache and GLUE RTL**
    (2026-10-02 night, 129 min): **79 of 79 PASS**.
    - Batches 17, 20, 22 and 23 were cut short when I stopped their
      ModelSim processes by mistake. Re-run apart, they PASS (5,160,
      5,176, 5,181 and 5,162 checks; `hb_c28/rerun_NN.log`).
- `sim/machine` stops in the RAM tests, before $4083F7B4, so it never
  has the data cache on.

**The probe deck's PCCH.** The ROM leaves ED off, and nothing on the board
could show whether software turns the data cache on, so PCCH was added
for compile 27 (Daniel's go, 2026-10-02). It reads:
- {CDIS*, 0, CACR[13:0]};
- the hits the instruction cache has answered [47:24];
- the hits the data cache has answered [23:0].

Each count is 24 bits and wraps; `read_probes.tcl` prints the CACR bits
and each count's change since the last sample. sim/machine and sim/system
pass with it in.

**Compile 27** (2026-10-02): both caches and PCCH.
- **Tag d2908ead, 31 min.** Archived as
  `output_files/MacSE30_d2908ead_dcache.rbf`.
- **33,975 ALMs (81 %)**: the data cache and PCCH add 871 over compile 26.
- `sta_corners.tcl`: our paths meet timing at every corner, worst
  **0.674 ns**. The capture meets its A/B rule at every corner; B's
  -0.370 ns setup at slow 100C is covered by A's 1.622 ns margin.
- **The flow's summary has no negative slack anywhere.** This time the
  framework's HDMI clock passes too.
- **On the board** (2026-10-02):
  - PCCH reads **CACR = $2101 at the boot-disk search** (the ROM's
    SwapDataCache, above). The instruction cache answers about 4.1
    million fetches a second and the data cache 0.8-1.25 million reads.
    The CPU is alive and the VBL runs.
  - TattleTech still reads **31 MHz**: its speed loop runs in registers,
    so the data cache does not change it.
  - **Speedometer 3.23** (System 6.x, both caches on; Daniel's
    screenshots, `C:\temp\Mac\Screenshots\20261002_19*`), against a real
    SE/30. The real figures are Speedometer 3.06 under System 7.5.5 (Low
    End Mac). Speedometer's algorithms changed at 3.1, so the comparison
    is rough.

    | Test (Mac Classic = 1.0) | Core | Real SE/30 | Core / real |
    |---|---|---|---|
    | CPU | 5.148 | 4.25 | 1.21 |
    | Graphics | 2.911 | 3.71 | **0.78** |
    | Math | 7.337 | 6.70 | 1.10 |
    | Disk | not run | 2.44 | - |

    - FPU Benchmarks (Mac II = 1.0): KWhetstones 1.120, Matrix 1.396,
      FFT 1.364, average 1.293. Benchmark Mix average 5.944.
    - No F-line exceptions: **the 68882's first real software ran clean**.
    - CPU and Math above real is the kernel's timing (1.16.1), diluted by
      memory traffic.
    - **Graphics below real is an open question**: QuickDraw drawing into
      the video RAM, which is uncached (CI). The suspect is our
      video-RAM cycle against the Guide's.

**The graphics finding: two GLUE clocks the board does not have**
(2026-10-02, Daniel: "look into the graphics first").

- **The measurement.** `sim/system` gained a `vramtest` run:
  `gen_vram_program.py`, with `se30_video` wired as `se30_machine` wires
  it. Three loops of 1,000 turns into the 8-bit video RAM:
  - `MOVE.L D0,(A0)+`;
  - `MOVE.B D0,(A0)+`;
  - `MOVE.L (A0)+,D2`.

  The bench times each window and every video cycle in it (its length
  S0-S5 and the gap before it). Every isolated byte took **7** clocks,
  where 2.12's table (the PALs, run) gives 5 or 6.
- **The trace** (`+define+VTRACE`) found two clocks of ours:
  1. **`NUBUS*` came a clock after AS\***. GLUE's `slot_sel` was
     `active && d_slot && !done`, and `active` registers AS\*. Plan 2.12
     drove the PALs with `NUBUS*` "at the falling edge starting S1", with
     AS\*. An AS\* landing on UE7's taking state (IDLE_A) missed it and
     waited a whole alternation.
     **Now `!cpu_as_n && d_slot && !done`**, as the other chip selects.
  2. **DSACK0\* was relayed through `done`**, so the processor saw UE7's
     ACK a clock late. On the board UE6 drives DSACK0\* onto the
     processor's bus itself.
     **Now passed through (`active && slot_ack`)**, with `done` holding it
     until AS\* rises.

  A tight loop locks to UE7's alternation, so which clock decides the
  cost depends on the loop: removing the first alone left this loop's
  numbers unchanged.
- **After both** (cycle lengths, C16M clocks):

  | Loop | Before | After |
  |---|---|---|
  | `MOVE.B` (isolated bytes) | 7 a byte, 11.30 a turn | **5** a byte, **9.28** a turn (-18 %) |
  | `MOVE.L` write / read (four bytes back to back) | 32.95 a turn | **30.92** a turn (-6 %): 5 + 7 + 7 + 7, 24-28 across the row transfer |

  2.12's table holds exactly.
- **Benches, all PASS:**
  - `sim/glue` (98);
  - `sim/system`, all five runs;
  - `sim/busfault`;
  - `sim/machine` (fresh log, 20:01);
  - `sim/video` (44);
  - `sim/cpfpu full`.

  `sim/gcrread` was not run: its quick mode runs past 30 minutes (the
  standing rule). The board's boot runs the same video PrimaryInit.
- **Compile 28** (Daniel, 2026-10-02: "if you need to compile again after
  this fix and before proceeding with SCSI, then do so"):
  - **Tag f03121d1, 33 min.** Archived as
    `output_files/MacSE30_f03121d1_vramfix.rbf`.
  - **33,755 ALMs (81 %).**
  - Met at every corner, worst **0.501 ns**; the capture meets its A/B
    rule.
  - The flow's summary has no negative slack.
  - **On the board** (Daniel's screenshot `20261002_204135`): Speedometer
    3.23 Performance Test.
    - **Graphics 2.911 -> 3.137 (+7.8 %)**; CPU 5.179 and Math 7.331
      unchanged. Against the real SE/30's 3.71: 0.78 -> 0.85.
- **What is left is not yet shown to be real.** The reference is 3.06
  under System 7.5.5 (the algorithms changed at 3.1; System 7's QuickDraw
  may draw faster).
  - **Wanted: a same-version reference.** Speedometer 3.23's `Machine
    Records` holds none: Daniel checked 2026-10-02, and the nearest is an
    LC III, a 25 MHz 68030 with other video. Low End Mac has only 3.06 (the
    IIcx's in 8-bit colour at 640x480, not comparable). **Parked:**
    Speedometer 3.23 on a real SE/30, IIx or IIcx in 1-bit would settle it.
  - If a gap remains, the lead is the kernel, not the video path. A
    68030's bus controller completes a write while execution goes on from
    the cache; our kernel waits for every beat. On a 5-7-clock video
    write the loop's instructions add instead of overlapping. That is
    1.16.1's kernel-timing question, parked by Daniel.

## 1.17 Timing against the 68030 (opened 2026-10-03)

**Why now.** Daniel, 2026-10-03, with the base machine working: "this
would be a good time to concentrate on timing. The graphics and disk are
too slow, and the CPU timing seems to impact authenticity, as with the
startup chime." This reopens 1.16.1's option 1 ("accept it"). He agreed to
measure first (step 1), then a design section, then the disk on its own
track.

**A hardware reference was looked for and not found.** The ROM's boot
calibration (`TimeDBRA` at `$0D00`, `TimeSCCDB` at `$0D02`) on a real
SE/30 would give a hardware-measured uncached figure. Daniel knows no one
with an SE/30. Searched (2026-10-03): no published SE/30 value. QEMU's
`mac_via.c` hard-codes `TimeDBRA $2A00` / `TimeSCCDB $079D` (x3 for its
host) for the Quadra 800 it emulates, a 68040 - not applicable. MAME
computes nothing it records. The only hardware-measured references in hand
are Speedometer 4.02's built-in SE/30 record (10.6) and the *Guide*'s
~1.4 MB/s blind SCSI rate (2.11.3).

### 1.17.1 Step 1: the timetest bench (built 2026-10-03)

`sim/system`, run `timetest` (`gen_time_program.py`, `report_time.py`):
twelve windows, each a loop timed between marker writes, through the
kernel, the wrapper, GLUE and `se30_video`. Loops copied from the ROM keep
its alignment mod 4. The 68030 figures are the manual's model, not a
measurement: UM 11.3's Equation 11-2 (cache case: CC less min(head, tail)
overlap) with 11.5's wait-state rules for the cached windows, and 11.5's
no-cache formula (an upper bound by the manual's own words) beside a lower
estimate (the tables' internal clocks plus the bus the core ran) for the
uncached ones. Wait states: RAM 4 clocks (W = 2 on the tables' 2-clock
base - the *Guide*'s "one wait state" is on the 68030's 3-clock
asynchronous cycle), ASC 5 read / 4 write, the SCSI DACK port 4 a byte,
the video RAM as measured (the PALs' 5/6/7, 2.12). Run time 3.5 min.

| w | loop | core clocks/turn | 68030 clocks/turn | core / 68030 |
|---|---|---|---|---|
| 0 | DBRA alone, cache off (TimeDBRA's shape) | 9.04 | 12.0 | **0.75** |
| 1 | the chime pass, ROM `$40805F28`, cache off | 446.7 | 534-697 | **0.64-0.84** |
| 2 | DBRA alone, I-cache on | 3.01 | 6.00 | **0.50** |
| 3 | ADD.L / LSL.L #2 / MOVE.L / SUB.L / DBRA (registers only) | 7.03 | 16.00 | **0.44** |
| 4 | RAM fill `MOVE.L D0,(A0)+` | 8.15 | 8.00 | 1.02 |
| 5 | RAM read `MOVE.L (A0)+,D2` | 8.16 | 13.00 | **0.63** |
| 6 | RAM copy `MOVE.L (A0)+,(A1)+` | 12.22 | 13.00 | 0.94 |
| 7 | VRAM fill `MOVE.L D0,(A0)+` (byte cycles 6.72) | 30.92 | 27.90 | **1.11** |
| 8 | VRAM byte `MOVE.B D0,(A0)+` (5.29) | 9.31 | 8.00 | **1.16** |
| 9 | RAM->VRAM `MOVE.L (A1)+,(A0)+` (6.77) | 35.10 | 32.07 | **1.09** |
| 10 | SCSI blind read, ROM `$40826B7A` (8 x `MOVE.L (A0),(A2)+`) | 173.4 | 165.0 | 1.05 |
| 11 | SCSI blind write, ROM `$40826BC2` | 173.4 | 168.0 | 1.03 |

**What it shows.**
- **The kernel is too fast wherever the 68030 works internally**: about
  2x on register and cached-branch code (0.44-0.50), 1.3x uncached.
  Speedometer's CPU 1.19 is this, diluted by memory traffic.
- **The startup chime: 0.86 s on the core, 1.02-1.33 s by the manual.**
  Its pitch is the ASC's (the phase increments, at the ASC's own sample
  clock); the CPU sets the envelope - the pass fades the four tables and
  starts a voice every 300 passes - so a fast pass is a short chime at
  the right pitch, as Daniel heard.
- **The kernel is too slow where a slow port saturates the bus**: video
  RAM 9-16 %, SCSI 3-5 %. The 68030's write-pending buffer (UM 11.2.5.2)
  lets the next instructions run under a write; the core waits for every
  byte cycle and then runs them.
- The bus cycles themselves are right: 4 clocks to RAM and the DACK port,
  the PALs' 5/6/7 to the video RAM.
- **The SCSI loop is not the Disk gap.** With a target that never stalls,
  the ROM's blind loops run 2.89 MB/s on the core against 3.0 for the
  68030 - twice the *Guide*'s ~1.4 MB/s, which is the real disk's pace.
  Speedometer's 0.84 must come from elsewhere: the target's sector
  latency, the driver's polled phases, or the File Manager's CPU time.
- **Nor do these loops explain Graphics 0.70.** The video-RAM loops are
  10-16 % slow and everything around them is fast, so QuickDraw should net
  out near 1.0. Something QuickDraw does that these loops do not is
  slower: candidates below.

### 1.17.2 Found on the way: CLR, Scc and MOVE from SR read before writing

The markers (`CLR.L` to an absolute address) showed a read before each
write. A probe of every memory mode (`sim/system/clrtest`, 27 cases:
`CLR.B/W/L` in (An), (An)+, -(An), d16(An), d8(An,Xn), abs.W, abs.L;
`ST` three modes; `MOVE SR,(An)` and abs.L; `MOVE CCR,(An)`): **every one
reads its destination, then writes it** - the 68000's behaviour. The
68030's tables say otherwise: `CLR Mem 4(0/1/1)` (p. 11-44), `Scc Mem
5(0/1/1)`, `MOVE SR,Mem 5(0/1/1)` and `MOVE CCR,Mem 5(0/1/1)` (p. 11-39)
- no operand read.

- **Timing**: a `CLR.L` to video RAM pays four extra byte reads (~26
  clocks) - a candidate for the Graphics gap, since QuickDraw erases.
- **Side effects**: a read of an I/O register is not neutral - the VIA's
  T1C-L/T2C-L and port reads clear interrupt flags, the SCC's data
  register pops its FIFO, the ASC's `$804` clears its events. The ROM has
  about 1,500 `CLR`-to-memory words, 300 `Scc` and 80 `MOVE SR` (a raw
  word scan, so approximate). A 68000 Mac's software tolerates the read;
  an SE/30's need not.
- **The regression**: `sim/system` run `clrtest` (`gen_clr_program.py`,
  `+CLRTEST`) counts the data cycles into the destinations - 27 writes and
  no read - and compares the 32 longs they leave against the program's
  model (the region pre-filled with `$A5`, so a wrong `Scc`, SR or CCR
  value shows). Before the fix: 27 writes, **27 reads**, FAIL.
- **FIXED 2026-10-03.** The kernel builds these instructions on its
  read-modify-write path (`write_back`), and rerouting them through
  MOVE's store states would touch every EA micro-state. Instead the
  kernel marks the read - new output `wronly_rd_out`: the data read state,
  the write back armed, no bus-error stacking, and the opcode CLR / MOVE
  from CCR (`$42xx`), MOVE from SR (`$40C0`-`$40FF`) or Scc - and the
  wrapper (`tg68k.v`, `z_hit`) answers it like a cache hit: no bus cycle,
  zero data (the ALU's result never uses it), not counted in PCCH. It
  waits for the PMMU's translation as any data access does; a fault there
  stacks a read where the 68030 would stack the write - accepted (the
  handler pages in and reruns either way).
- **Benches after the fix**: `clrtest` 27 writes, 0 reads, 35 checks PASS;
  `sim/system` all eight runs PASS (the timetest windows now carry one
  marker cycle, not two - `report_time.py` reads the count off window 0);
  `sim/kernel_bus` ports 16/32/8 and `sim/busfault` PASS (25 s); `sim/cpfpu`
  all 12 PASS (93 s); `sim/machine` PASS (82 s); `sim/kernel_upstream`
  verdicts identical to `ours.txt` (14 pass, the 3 known failures). Run in
  parallel, `sim/machine`'s `vlog` exited 1 with no message twice; alone it
  passed - ModelSim jobs started together can collide (the earlier
  "transient" early exit was this).

### 1.17.3 The PMMU costs a clock on every step (found 2026-10-03)

**The measurement.** Windows 2-11 were all run with translation off; System
7.5.5 runs with it on (the ROM's 24-bit mode, TC `$80F84500`, 1.11). So
`timetest` gained windows 12-21: the same loops after `PMOVE (A0),CRP;
PMOVE 8(A0),TC` with a RAM copy of the ROM's table, the video RAM at its
24-bit address `$E00000` (descriptor `$E` -> `$FE000000`). The 68030's
figures do not change: "when the physical address ... resides in the ATC,
the address translation time is completely overlapped with on-chip cache
accesses and has no effect on instruction timing" (UM 11.2.6), and the
caches are logical (UM 6.1). Run time 5.5 min.

| loop | PMMU off | **PMMU on** | 68030 | on / 68030 |
|---|---|---|---|---|
| DBRA, cached | 3.01 | **5.01** | 6 | 0.84 |
| registers + DBRA | 7.03 | **11.04** | 16 | 0.69 |
| RAM fill | 8.16 | **11.14** | 8 | **1.39** |
| RAM read | 8.15 | **11.11** | 13 | 0.85 |
| RAM copy | 12.23 | **16.30** | 13 | **1.25** |
| VRAM fill (long) | 30.92 | **35.07** | 26.0 | **1.35** |
| VRAM byte | 9.31 | **13.33** | 8 | **1.67** |
| RAM->VRAM copy | 35.12 | **39.20** | 29.2 | **1.34** |
| SCSI blind read (32 bytes) | 173.1 | **219.6** | 165 | **1.33** |
| SCSI blind write | 173.1 | **219.2** | 168 | **1.30** |

**This is the Graphics and Disk gap.** Video-RAM work under translation
runs at 0.60-0.75 of a 68030 - Speedometer's Graphics 0.70 - and the SCSI
blind loops at 0.75 - Disk 0.84 with the rest of the path. The CPU
benchmarks hide it because their loops are mostly cache hits on short
code.

**The mechanism, traced** (the RAM fill, clock by clock). Each time the
kernel's logical address changes - a fetch, a data access, even an
internal step - the PMMU's `busy` rises for one fast clock while its
translation process registers the ATC hit (`TG68K_PMMU_030.vhd`: the
22-entry compare, then `phys_base + (addr_log - log_base)`, into
`addr_phys_reg`/`translated_addr`). The kernel shows no request while
`busy` (`busstate_raw` "01"), and the wrapper's `k_internal` waits for it
too. That fast clock is always the phi2 half, the only point where the
wrapper can start a cycle or take a cache hit, so **every kernel step whose
address changes loses one whole C16M clock**. The fill's turn is three
steps (the write, two cache-hit fetches): 8 -> 11. Cache hits and internal
steps need no translation at all on the 68030.

**The options** (for Daniel):
- **A. A same-clock ATC hit (recommended).** A combinational fast path
  beside the registered one: when an entry matches and the access is clean
  (valid, not write-protected on a write, not a supervisor page in user
  mode, no fault pending), `busy` is 0 in the same clock and the physical
  address is the entry's base merged with the page offset (an OR of masked
  bits, not the 32-bit add); everything else - misses, faults, walks -
  stays on the registered path unchanged, which also completes a clock
  later as now. Removes the loss everywhere, matching UM 11.2.6. Risk:
  timing - a 22-way compare and mux now feeds the bus start in one fast
  clock (32 ns); only a compile can tell.
- **B. The ATC register on the falling edge.** The same registered path,
  clocked half a period after the kernel's address changes, so it is ready
  at phi2. Also removes the loss; halves its timing budget (16 ns).
- **C. Hits and internal steps bypass the wait.** Cache hits (logical) and
  internal steps no longer wait for `busy`; bus cycles still lose their
  clock. Least timing risk; the RAM fill would be 9, the SCSI loop about
  190. Partial.

**Option A built** (Daniel, 2026-10-03: "build option A and compile when
ready"). `TG68K_PMMU_030.vhd`, process `fast_xlat`: the registered
search's own entry choice (the last valid entry whose FC and aligned base
match, a write needing M, WP or a fault entry - BUG #410's rule), then a
clean-access test (no fault entry, no write to WP, no user access to a
supervisor page) and a quiet-MMU test (no fault latched or pending, walker
idle, no translation pending, no flush, no PLOAD, no context change, TC on,
MMUDIS off, no TTR, not CPU space). On a fast hit: `busy` low in the same
clock (one term in the busy process), `addr_phys` = the entry's base OR the
page offset (taken only when the base has no offset bits, so it equals the
registered add), CI and WP from the entry. The registered path is
untouched and lands the same result a clock later.
- **timetest windows 12-21 now equal 2-11** (RAM fill 8.16, VRAM fill
  30.94, VRAM byte 9.27, SCSI blind read 173.8): the lost clock is gone.
- **Benches**: upstream's PMMU benches (`sim/kernel_upstream/
  pmmu_suite.txt`, 63 from their Makefile; `run.sh` gained `SUITE`,
  `RESULTS`, `WORK` so two RTLs run side by side) - **identical verdicts
  before and after** (58 pass, the same 5 fail on both); `kernel_upstream`
  verdicts unchanged; `sim/system` all eight; `kernel_bus` 16/32/8 and
  `busfault`; `cpfpu` all 12 (b5a-d: page faults inside dialogs, `mmu`);
  `sim/machine` 17 checks. `sim/machine`'s start-up flake (vlog exits 1 in
  2 s with no message) recurred three times, alone too; a rerun passes -
  not the RTL.
- **Compile 32** (Daniel's go, 2026-10-03): tag `965b4146`, 35.5 min,
  archived `output_files/MacSE30_965b4146_atcfast.rbf`.
  - **37,261 ALMs (89 %)**, +633 on compile 31: the fast path's 22-way
  match, mux and offset merge. The ceiling is ~38.3k (10.4) - about 1,000
  left.
  - **Our clocks meet timing at every corner**: the CPU/system clocks
  (`general[0]`/`[1]`) worst setup **+0.497 ns** (slow 100C), worst hold
  +0.118 ns (fast -40C) - more margin than compile 31's +0.051. The SDRAM
  capture meets its A/B rule at every corner.
  - `sta_corners.tcl`'s overall verdict is NOT MET, **-0.034 ns, on the
  framework's HDMI scaler** (`ascal`, `pll_hdmi`, slow -40C) - the
  framework path that missed in compiles 25-26, not ours.
  - **On the board** (Daniel, 2026-10-03, `C:\temp\Mac\Screenshots\
  20261003_195741-screen.png`; Speedometer 4.02 Performance Test, System
  7.5.5 from SCSI, 1 bit; Quadra 605 = 1.0, its built-in SE/30 record
  beside):

    | Test | Real SE/30 | Compile 31 | **Compile 32** | 32 / real |
    |---|---|---|---|---|
    | CPU | 0.27 | 0.32 | **0.49** | 1.81 |
    | Graphics | 0.23 | 0.16 | **0.19** | 0.83 |
    | Disk | 0.57 | 0.48 / 0.38 | **0.39** | 0.68 |
    | Math | 0.97 | 1.08 | **1.29** | 1.33 |
    | PR | 0.31 | 0.27 | **0.34** | 1.10 |

    - The PMMU fix shows: CPU +53 %, Graphics +19 %, Math +19 %. With
      the translation tax gone the kernel's internal speed shows in full -
      CPU 1.8x the real machine (1.17.1's DBRA 3 against 6).
    - **Graphics is still 0.83 of the real machine with the CPU at 1.8x.**
      Drawing has a cost the timetest loops (10-16 % slow) do not show:
      the video-RAM cycle itself (2.12's 5/6/7, 7 back to back, the
      21-clock row transfer) or the missing write-pending overlap, at a
      larger share of the time than the loops suggest. Not yet located.
    - **Disk did not move** (0.39, within compile 31's two runs): the SCSI
      loop was already at the 68030's pace (1.17.1), so the gap is the
      target's sector latency or the driver's polled phases - step 3.
  - **REGRESSION, OPEN: compile 32 will not mount floppies** (Daniel,
    2026-10-03: "hung temporarily while trying to mount a floppy. This
    version will not mount floppies"). Compile 31 did. Two suspects, the
    build's two changes:
    1. **1.17.2's CLR fix.** The SWIM has no R/W pin - in the IWM set every
       access, read or write, moves a state line by its address, and a
       write with L6/L7 set writes the mode or data register
       (`rtl/se30_swim.v` header, "THE BUS"). A `CLR` of a SWIM address
       was two accesses (the 68000-style read, then the write) and is now
       one. If the ROM's .Sony (`$2D72C`) uses `CLR`/`Scc` on SWIM
       addresses, it now moves the lines once, not twice, or writes where
       it read - the first thing to check: scan .Sony for `CLR`/`ST`/
       `SF` with a SWIM base register, and compare what the real 68030's
       single write does to the IWM (the model's write path) against what
       the old read+write did.
    2. **1.17.3's PMMU fix.** Under translation the CPU now runs up to 1.5x
       faster than before; .Sony's software timeouts (TimeDBRA-calibrated
       at boot with the PMMU off) now run at the calibrated pace rather
       than slower - so less likely, but a timing-sensitive loop could
       now expire early.
    To split them: a bitstream with only one of the two changes (or the
    `gcrread` bench, which reads through the ROM's .Sony, under each).
    The probe deck was not read (Daniel stopped the read; the hang
    cleared by itself).

### 1.17.4 Next

1. ~~**The CLR/Scc/MOVE-from-SR read** (1.17.2): design and fix - a kernel
   correctness item before any pacing.~~ DONE 2026-10-03.
2. **The PMMU's lost clock** (1.17.3): option A built and benched; compile
   32 met our timing (the framework's HDMI scaler misses -0.034 ns); to the board.
3. **Re-measure** windows 12-21 after it, then Speedometer on the board:
   with the PMMU's clock gone and the CPU still 2x fast internally,
   Graphics and Disk may come out above the real machine.
4. **The design section for a paced kernel** (Daniel's step 2): instruction
   timing to Table 11 and the write-pending overlap together. **2026-10-03:
   now the fix for the floppy regression - 1.17.5 has the evidence and the
   design, for Daniel's approval; the tables are in FEA            41 rows
FIEA           75 rows
CEA            38 rows
CIEA           74 rows
JEA            34 rows
MOVE           42 rows
SPECIAL_MOVE   22 rows
ARITH          39 rows
IMMED          17 rows
BCD            13 rows
SINGLE         16 rows
SHIFT          16 rows
BIT            16 rows
BITFIELD       24 rows
BRANCH          7 rows
CONTROL        28 rows
EXCEPTION      19 rows
SAVE_RESTORE    8 rows.**
5. **The disk on its own track** (step 3): the target's latency and the
   driver's polled phases.

### 1.17.5 The floppy regression: the pace of the kernel against the SWIM (2026-10-03)

**The question.** Compile 32 will not mount floppies (1.17.3); compile 31
did. Daniel asked whether to revert to compile 31 and start the timing
work again. Answer, with the evidence below: no - the CLR fix has no
mechanism in the floppy path, and the PMMU fix is correct by the manual
and has only uncovered the kernel's internal speed, which the ROM's
floppy driver cannot tolerate. The fix is the paced kernel (1.17.4 item
4), and this section turns that item from authenticity into correctness.

**1. The CLR fix is innocent.** A disassembly of the whole ROM (capstone,
M68K_030; `scripts/se30_declrom.py` has the same loader) lists every
`CLR`, `Scc` and `MOVE from SR/CCR` with a memory destination whose
offset has a device register's shape (a multiple of `$200` up to `$1E00`,
the SWIM's and the VIAs' spacing): three in 256 KB - `clr.b $1600(a2)` at
`$40803456` and `clr.b $1800(a1)` at `$40806D98`, both in the start-up
code with A2/A1 = a VIA base (`vACR`, `vPCR`: a read of either has no
side effect, so the lost read changes nothing), and `clr.l $0(a3)` at
`$4082A208` (not a device). Inside .Sony (`$4082D72C`, header: Open
`$70`, Prime `$44A`, Control `$1C6`, Status `$34C`, Close `$18`) every
`CLR`/`Scc` targets the driver's own variables (`$100`-`$135` off A1, the
per-drive bytes `$2`-`$19` off `(A1,D1.W)`) or the stack. The IWM base
(`$1E0`, set to `$50F16000` at `$408006A0`) is loaded into A0/A3/A4 at
eleven sites; no write-only instruction uses any of them. System 7.5.5's
RAM-resident patches were not scanned (not in hand), but the ROM's own
driver is what mounts a disk, and it has nothing for the fix to change.

**2. Two places where the driver's pace matters, by the chip's rules.**
- **The read data register's 14-FCLK clear** (5.12.12 item 2, the IWM
  production spec): in asynchronous mode the latched byte is cleared 14
  FCLK after a valid data read (`/DEV` low with D7 = 1). A second read of
  the register inside that window returns the same byte again - a byte
  taken twice, which the GCR address field's checksum (`$40831C6A`) or
  the data's catches as an error, and the driver retries until it gives
  up. In C16M clocks the rule is: a strobe 15 or more after a valid read
  is safe, 14 re-reads (`se30_swim.v`: `clr_cnt` loaded at the valid
  read, the latch cleared when it reaches 1). The ROM's GCR path reads
  the data register with a table lookup and one or two register
  operations between reads - the address field `$40831C48`-`$40831C69`
  (`move.b (a4),d5 / bpl / move.b (a3,d5.w),d1 / move.b d1,d4 / ror.w #6,d1
  / move.b (a4),d5 / bpl / move.b (a3,d5.w),d2 / eor.b d2,d4 / move.b
  (a4),d5 ...`) and the data loop's `$40831D08`/`$40831D6A` shapes (a
  lookup, `rol.b #2`, `move.b`, `and.b`, the next read). Every other
  pair has a VIA1 read (16 clocks) or a RAM write between them.
  5.12.12 item 2 recorded that the bench's poller once re-read within 14
  FCLK "faster than the ROM ever does" - on a 68030.
- **The MFM read loop's 31-poll budget** (`$4082EAB6`, the ISM data read
  for a 1.44 MB disk): after each byte, `tst.b (a3)` on the handshake, a
  VIA1 PA7 poll, then `moveq #$1E,d1; tst.b (a3); dbmi d1,*` - at most 31
  handshake polls before `noNybErr`-class failure ($2EAD2). A byte comes
  every 16 us = 251 C16M clocks at 500 kbit/s (GCR's 489.6 kbit/s is the
  same 251).

**3. Measured** (`sim/system` timetest, five windows added - 12-17 and
their PMMU-on copies - the ROM's loops verbatim; the bench's device port
now answers the SWIM's data register with `$FF` so the ROM's `bpl`
polls fall through, reads everything else as 0 so `dbmi` polls loop, and
reports the shortest SWIM strobe-to-strobe gap in each window; the
markers moved to `$3000+8w` for 64 windows):

| loop | 68030 (UM 11) | core, compile 32 | core, fast path off (compile 31) |
|---|---|---|---|
| SWIM handshake poll `tst.b (a3); dbmi` | 13 | **8.01** | 12.02 |
| VIA1 ORA poll `tst.b (a5); dbmi` | 25.0 (VIA cycle 16) | 20.0 | 20.0 (VIA 13) |
| GCR address field, 5 reads + lookups | 87 | **50.3** | 66.2 |
| ... its shortest data-register gap | ~21 | **15** (14 re-reads) | **20** |
| `subq; bne` taken | 8 | 4.02 | 6.02 |
| `tst; beq` not taken; `moveq`; `dbra` | 14 | 7.04 | 10.04 |
| `move.b (a3,d5.w),d1; dbra` | 16 | 10.18 | 14.10 |

(The compile-32 column is the same with the PMMU off and on, as the manual has it - windows 2-17 equal 18-33 to 0.01; the compile-31 column is the PMMU-on set with the fast path forced off, a scratch mutant of `TG68K_PMMU_030.vhd`, `fast_hit` held low.)

- **GCR**: the kernel's shortest gap between two data-register reads is
  **15 clocks - the safe minimum with no margin at all**. Compile 31's
  lost clock on every step put it at **20**. A 68030 has about 21.
- **MFM**: 31 polls at 8.01 = 248 clocks, plus the loop's head (the
  `dbra`, the first `tst.b`, the VIA poll, ~30) = about 278 against the
  251-clock byte - an 11 % margin where a 68030 has 80 % (31 x 13 + 50 =
  453) and compile 31 had about 50 %.

**4. What this says about the board.** The two figures that moved between
compile 31 and 32 are exactly the two the driver's chip rules care about,
and both now sit at or inside the chip's limits: the GCR data-register
gap at the clear's edge (15, where 14 doubles a byte), the MFM poll
budget at 288 against 251 (a 68030: 453). Everything else in the floppy
path - the drive's step and settle polls, the power-up's /READY polls -
is Time-Manager or VBL timed (`sim/gcrread`'s `ms_wait`), not CPU-paced,
and did not move. The replay bench, `sim/gcrread` with the new `+kpace`
(the ROM's loops replayed at the kernel's measured costs instead of the
68030's: DBcc 3, a register op or rotate 1, a branch taken 3, not taken
2, the index 2), run to the first cylinder of both drives (`+quick
+stop0`), is the end-to-end check of the GCR side. **Run 2026-10-03: the
loads and both recalibrates passed at the kernel's pace, and the run was
stopped at its 40-minute limit inside the first cylinder's reads (3.25 s
simulated - the reads run at about 50 ms of disk time a minute); a run
to the first cylinder needs about 90 minutes, which is Daniel's call (the
30-minute rule). The bench's heartbeat now prints the shortest SWIM
gaps, so a rerun shows within minutes whether the replay reproduces the
kernel's 15 and what the chip makes of it.**

**5. The fix: the paced kernel (1.17.4 item 4, now a correctness item).**
Not a revert. Compile 31 masked the same two edges with a clock the
manual says does not exist (UM 11.2.6), and the kernel's 2x internal
speed remains behind everything else - the chime, Speedometer's CPU
1.81x, and every other piece of software that was tuned to a 68030's
pace. The design, for Daniel's approval before building:

- **Where.** The wrapper (`tg68k.v`), not the kernel: a budget counter
  beside the kernel's beat enable. The kernel marks each instruction's
  start (`setopcode`); the wrapper holds the kernel's internal beats at
  the next instruction boundary until the current instruction has been on
  the clock for its budget. Bus cycles are never delayed - the 68030
  issues them as early as it can, and the kernel's cycle timing is
  already the Guide's - only the step into the next instruction is.
- **The budget: UM Section 11's model, Equation 11-2.** For each
  instruction: its table's I-cache-case clocks, plus its effective
  address part's (fea, fiea, cea, ciea or jea by the instruction's
  footnote), less the overlap `min(head, tail of the previous
  instruction)`; wait states beyond the tables' two-clock cycles are
  added as the manual's 11.5 rules add them (each operand cycle's length
  less 2, so the SE/30's one wait state and the SWIM's and VIA's longer
  cycles count as they do on the real machine). Branches and DBcc take
  their taken / not-taken / expired rows from the outcome. The tables are
  transcribed from the manual's page images into
  `tools/time030/um11.py` (18 tables, 529 rows, 2026-10-03): the single
  source for the wrapper's decoder and for `report_time.py`.
- **The decoder.** The opcode word, the EA mode and size, and the
  kernel's branch outcome select the row - an opcode-class decode of a
  few hundred terms, with the tables' clock counts as constants, not a
  65,536-entry ROM. Rare rows (bit field, BCD, CAS, the full-format EA
  modes) may share a class figure. Estimate: 300-500 ALMs and no M10K,
  against the ~1,000 left (10.4).
- **What it does not do.** The write-pending overlap (UM 11.2.5.2 - the
  68030 runs the next instruction's head under a write's cycle; the
  kernel waits for the acknowledge) is not pacing but speed, the 1.09-1.16
  of the video-RAM loops; it needs a one-entry write buffer in the wrapper
  and is a separate item. The I-cache case is modelled; a fetch that
  misses costs its real cycle, as the manual's no-cache case charges it.
- **The gate.** `sim/system` timetest: every cached window within 10 % of
  the manual's figure, the SWIM poll at 13, the GCR gap at 20 or more;
  `sim/gcrread` `+kpace` at the paced costs; `sim/kernel_upstream`, the
  cputest corpus and `sim/cpfpu` unchanged (pacing changes no result);
  then the board: floppies mount, the chime 1.0-1.3 s, Speedometer CPU
  near 1.0.
- **Until it lands**, a bitstream with only the ATC fast path off would
  behave as compile 31 - a stopgap, if Daniel wants one, not the fix.

**Built 2026-10-03 (Daniel: "go ahead and build the pacing kernel"; the
disk was an 800K GCR image, so the board hit the 15-clock edge).**

- **The decoder, `rtl/tg68k/se30_pace030.v`**, generated by
  `tools/time030/gen_pace030.py` from `um11.py`: 227 `casez` patterns over
  the opcode word (the 68000/020/030 integer set, F-line unpaced), each
  naming its operation row and which EA table applies (fea, fiea, cea,
  ciea, jea - the manual's footnotes), the EA tables as five functions of
  mode, register and immediate size; outputs the two parts' head, tail and
  I-cache-case clocks, a branch's taken alternative, MOVEM's per-register
  addition, and the "n + op head" flag. Hand-checked on 40 opcodes against
  the pages (the generator's header lists the simplifications: brief-format
  figures for full-format EAs, maxima for MUL/DIV/CHK/CAS, DIVU.L for both
  long divides, DBF's fall-through "expired" and other DBcc's "cc true",
  the <5-byte bit-field rows).
- **The wrapper (`tg68k.v`, "the pace")**: at the kernel's decode beat
  (`decodeOPC`, exported) the cycle start, the cache-hit take, ECS and the
  internal beat are withheld until the running instruction's clocks reach
  its budget; the release latches the next opcode and PC, resets the
  clock count to 1 (the release clock is the new instruction's first) and
  the credits, and keeps the finished instruction's tail. The budget: EA
  clocks less min(EA head, previous tail) plus op clocks less min(op head,
  EA tail or previous tail), each overlap clamped to its part's clocks (a
  taken DBcc has 6 against the fall-through row's head of 10 - the first
  build deadlocked on the wrap), plus the credits: every cycle's clocks
  beyond two (a continuation beat through a narrow port whole), kept in
  three accounts - data reads (lengthening the EA part's tail, rule 1a),
  writes (the op's tail, rule 3a, with MOVEM's register clocks) and
  instruction fetches (budget only). A branch's outcome is the next
  opcode's PC against the fall-through address. Acknowledges are never
  held. `pace_en` (the machine's new port, the top ties it high) low runs
  unpaced; `sim/system` has `+NOPACE`, `+PTRACE` (the pace's signals every
  clock) and a watchdog that dumps them when the kernel takes no beat for
  1000 clocks. The first build's cycle start was gated on the wire but not
  in the state machine, so fetches ran during stalls and their clocks were
  credited to the wrong instruction - the trace found it.
- **timetest, paced** (`run_timetest.log`, 14 min; PMMU off and on equal):

  | window | 68030 | paced core | ratio |
  |---|---|---|---|
  | DBRA alone, cached | 6 | 6.01 | 1.00 |
  | register-only ADD/LSL/MOVE/SUB + DBRA | 16 | 16.03 | 1.00 |
  | RAM fill / read / copy | 8 / 13 / 13 | 8.17 / 13.11 / 13.12 | 1.01-1.02 |
  | VRAM fill / byte / RAM->VRAM | 27.9 / 8 / 32.1 | 31.5 / 11.1 / 35.8 | 1.11-1.38 |
  | SCSI blind read / write | 165 / 168 | 175 / 174 | 1.04-1.06 |
  | SWIM handshake poll | 13 | 15.0 | 1.15 |
  | VIA1 ORA poll | 18 | 20.0 | 1.11 |
  | GCR address field | 87 | 87.2 | 1.00 |
  | ... its shortest data-register gap | ~21 | **23** (15 is the edge) | |
  | SUBQ / BNE taken; TST / BEQ not taken / MOVEQ / DBRA | 8; 14 | 8.01; 14.04 | 1.00 |
  | MOVE.B (A3,D5.W),D1 / DBRA | 16 | 16.26 | 1.02 |
  | DBRA, cache off (TimeDBRA's shape) | 12 | 10.2 | 0.85 |
  | the chime pass, cache off | 534-697 | 542 | 0.78-1.01 |

  The chime: 1.04 s (1.02-1.33 by the manual; 0.86 before). The video-RAM
  loops keep the write-pending gap (item 5's "what it does not do") and
  the uncached DBRA runs 15 % fast (fetch misses credited their wait
  states only, not the no-cache case's extra prefetch clocks - the ROM's
  calibration loop, so TimeDBRA reads ~15 % high; accepted for now). The
  SWIM poll's 2 clocks over are margin for the driver.
- **Benches, pacing on** (2026-10-03): `sim/system` all eight programs PASS
  (plain/cacheon/cachewa 24 checks each, cachetest 28, vramtest, berrtest
  3 - the watchdog first killed it: a blind read's DRQ wait is not a
  stall, so it now counts only with the bus idle - timetest 35, clrtest
  35); `sim/machine` 17 checks (90 s); `sim/busfault` 14; `sim/cpfpu`
  all twelve programs (b1-b5d, mmu, full). `sim/kernel_upstream` and the
  cputest corpus run the kernel without the wrapper and are untouched.
- **Compile 33** (2026-10-04 00:12, tag `3a1cd700`, 48 min - the fitter 36;
  archived `output_files/MacSE30_3a1cd700_paced.rbf`): **37,936 ALMs (91 %)**,
  +675 on compile 32 - the pace's decoder, counters and comparators; 43 %
  of the block memory. **Timing NOT MET: -0.516 ns** at the slow 100C corner
  (-0.177 at slow -40C; the fast corners meet), on the system clock
  (`general[1]`), and the path is the SDRAM controller's own:
  `se30_sdram|a_written` -> `dq_out[6]`, three logic levels but 9.6 ns of
  the 11.3 ns data delay is interconnect - the fitter placed the write
  data register far from its enable on a 91 % full device (compile 29
  missed the same family by -0.109). The pace's own paths meet (the
  CPU clock `general[0]` +0.716). The SDRAM read capture meets its A/B
  rule at every corner; the framework's HDMI scaler +0.006. The remedy
  is a fit matter - a seed or effort change, or the write data register
  duplicated near the enable - not the design's; Daniel's choice (4.11
  item 8's rule): this bitstream is a timing-violated build like compile
  23 (which booted) and 29.
- **Compile 33 on the board** (2026-10-04, Daniel): **the floppy mounts
  again** (the regression of compile 32 is fixed), **the chime is longer**
  (the kernel-timing item of compile 31 closes with it), and **TattleTech
  reports a 16 MHz 68030** (compile 27 read 31 MHz - its DBRA loop now
  takes the manual's 6 clocks; the real SE/30 runs at 15.67 MHz). Still
  to hear: the boot RAM tests (where the -0.516 ns write-path miss would
  show). **Not a regression:** Speedometer 4.02 first stopped with error
  **-40** (the File Manager's posErr, a position before the start of a
  file) from one disk image and runs from another - the image is
  suspect, not the machine. **But the image was damaged on the core**
  (read 2026-10-04 against its source, the MacLC backup's `boot.vhd`;
  the damaged copy kept as `C:\temp\Mac\Test disks\Corrupted\boo_.vhd`):
  - The one damaged file is Speedometer 4.02's resource fork, modified
    2026-10-03 18:59:19 by the Mac's clock, which runs on UTC (the
    volume's last write, 23:35:33, is the 00:35 BST of the file's move) -
    so 19:59 BST, **the compile 32 session** (its Speedometer 4.02
    screenshot is 19:57:41), when Speedometer saved its results.
  - Its resources and map are intact and byte-identical apart from the
    map's runtime fields. The damage is the fork's header block only:
    the header reads `7FFF0146 FFFE8145 7FFF7FFF 00001626` for `00000100
    000786B9 000785B9 00001626` (the map's own copy of the header is
    right), and the fork was extended from 498,911 to 32,577,575 bytes
    ($01F11827, which also stands in the block's system area at $7A) -
    1,333 new blocks of stale disk, never written. Opening it gives the
    File Manager's -40.
  - The values are structured, not flipped bits (the XORs are no
    single-pin pattern; the dq_out[6] miss is compile 33's, not 32's),
    and the SCSI path was host-checked byte-exact - so the lead is a
    wrong value computed on the CPU side while the Resource Manager
    wrote the header, under compile 32 (unpaced, the same-clock ATC
    hit). Not localised.
  - The rest of the volume checks clean (catalog and extents B-trees
    walk, the bitmap matches every extent) except `Desktop DB 2`, whose
    extents cover 12 of its 28 blocks (8 orphan blocks), dated by an
    unset 1960 clock 19 s after the backup's own last write - the MacLC
    era, not ours.
  - **The Disk test** (Daniel: it writes a big file beside the app).
    The catalog's dead space holds the test file's record: `` `!@#Test
    File``, type `zzzz` creator `sPd3`, a 1 MB data fork (44 blocks at
    51377) of zeros only, created 23:30:48 UTC - Speedometer 3.23's
    test on compile 33 tonight, created, written and deleted cleanly.
    So the test's own write is 1 MB of zeros to its own file; the app's
    fork got neither zeros nor 1 MB but a 32 MB EOF and twelve non-zero
    bytes - not the test's data landing in the wrong file, but the File
    Manager's or Resource Manager's bookkeeping going wrong while the
    test ran (a wrong value, a wrong refnum/FCB).
  - **The check on compile 33**: run Speedometer 4.02's Disk test
    several times on a scratch copy of the image, quit, and compare its
    fork against the backup.
  - **Compile 33 passes it** (Daniel, 2026-10-04 00:54 BST; three runs,
    quit and relaunched between them; `Corrupted\boo_2.vhd`, from the
    restored MacLC backup). Speedometer 4.02's fork is the backup's:
    the header `00000100 000786B9 000785B9 00001626`, 498,911 bytes,
    the resource data and data fork byte-identical; the only changes
    are the map's runtime fields and four Finder-flag bytes at $44,
    $4E, $50, $5A (the same four the damaged copy had). The volume is
    clean: both B-trees walk, the bitmap equals the extents (no
    overlap, no orphan), MDB free = bitmap free. The last test file's
    record (1 MB of zeros, 23:54 UTC) shows the test completed. The
    damage stays a compile 32 event; whether the pace closed it or it
    is rare is not shown by three runs.
  **Speedometer 3.23
  runs: CPU 4.271, Graphics 3.568** (Mac Classic = 1.0) against the real
  SE/30's 4.25 / 3.71 (Low End Mac, 3.06 under System 7.5.5): **CPU 1.005,
  Graphics 0.96** of the real machine (compile 27 under 3.23: CPU 5.179,
  Graphics 3.137 = 0.85). The pace puts the CPU on the machine's speed;
  the Graphics gap is down to 4 %, which is the write-pending buffer's
  question (the version caveat of 1.16 still stands).
- **Speedometer 4.02 on compile 33** (Daniel, `C:\temp\Mac\Screenshots\
  20261004_003138-screen.png`, Comparison - Machine Records; Quadra 605 =
  1.0; the Performance Test only - the Benchmark and FPU rows are 0.00,
  not run). Two real-SE/30 references: the program's built-in record,
  and Low End Mac's own SE/30 under System 7.5.5 (four runs, all alike;
  **https://lowendmac.com/2000/mac-se30-benchmarks/** - Speedometer 4.02,
  Quadra 605 = 1.0, "tested on 1999.06.17 and 2000.11.21 under System
  7.5.5", rows for 32/64/128/256 KB disk cache all CPU 0.26, graphics
  0.16, math 0.96-0.98, disk 0.70-0.77 on the internal drive and 1.46 on
  an external ST2.1S; the same page's Speedometer 3.06 rows, 8 MHz Classic
  = 1.0, "tested on 2000.10.08 under System 7.5.5": CPU 4.24-4.25,
  graphics 3.69-3.71, disk 2.43-2.45, math 6.63-6.70 - the 4.25 / 3.71
  cited above):

  | Test | Built-in record | Low End Mac | Compile 32 | **Compile 33** | 33 / record | 33 / LEM |
  |---|---|---|---|---|---|---|
  | CPU | 0.27 | 0.26 | 0.49 | **0.27** | 1.00 | 1.04 |
  | Graphics | 0.23 | 0.16 | 0.19 | **0.16** | 0.70 | 1.00 |
  | Disk | 0.57 | 0.70-0.77 | 0.39 | **0.49** | 0.86 | 0.64-0.70 |
  | Math | 0.97 | 0.96-0.98 | 1.29 | **1.10** | 1.13 | 1.13 |
  | PR | 0.31 | - | 0.34 | **0.25** | 0.81 | - |

  - **CPU is on the real machine** by both references.
  - **The two references disagree on Graphics** (0.23 against 0.16).
    Low End Mac's machine is consistent with itself across versions
    (3.06: 3.71; 4.02: 0.16) and the core matches it on both (0.96 and
    1.00); the built-in record's conditions (System version, QuickDraw,
    screen) are unknown. On this evidence the Graphics gap may be a
    property of the record, not the core; the write-pending buffer is
    still the 68030's behaviour and is still wanted, but it should
    move Graphics only by the few per cent the 3.x figure leaves.
  - **Math is 13 % high** by both - the 68882's own time (the pace
    holds the 030's instructions, not the coprocessor's); 1.17.5's
    small corrections list.
  - **Disk** depends on the drive and the SCSI path, not the CPU.

**Added this session**: `sim/system` timetest windows 12-17 (the SWIM
and VIA polls, the GCR address field with the strobe-gap meter, a taken
branch, a not-taken branch, an indexed read) and their PMMU-on copies
18-33; the bench's device port answers the SWIM's data register with
`$FF`; the markers at `$3000+8w` (64 windows); `report_time.py` rows for
each; `sim/gcrread` `+kpace` and its gap meter; `tools/time030/um11.py`.

### 1.17.6 The SDRAM data pins loaded a clock ahead (2026-10-04)

**Daniel's rule (2026-10-04): no seed lottery.** A timing miss is fixed
in the design, never by a seed or effort re-fit ("we had that in the LC
until it was fixed") - a lucky fit is re-rolled by every later change,
and the device is 91 % full.

**The miss.** Compile 33: -0.516 ns at slow 100C on `a_written ->
dq_out[6]` (compile 29: -0.109 on the same family). `dq_out` and `dq_oe`
are I/O-cell registers at the pins, so the logic deciding their next
value must reach the die's edge in one clock; it was the sequencer's
own decision (the write issues when the request has come: `req_q`,
`a_written`, `seq`), and the fitter put it far from the pins - three
levels, 9.6 ns of the 11.3 ns in wire.

**The fix** (`rtl/se30_sdram.v`, header THE DATA PINS ARE LOADED A CLOCK
AHEAD; commit d3ecbe7): the pins take `dq_pre` and `oe_pre`, registers
loaded on the clock before from the state alone - one hop, no logic.
- The data needs no decision: while a write access is open `dq_pre`
  holds the word the next WRITE needs (the high word; the low word from
  the clock the high word's WRITE issues); the chip ignores the pins
  except on a WRITE's clock.
- The enable needs none either: on for a write access's whole length
  (the clock after its ACTIVE to two after it ends) instead of each
  WRITE's clock. Safe because the chip drives the pins only after a
  READ, and every READ's data is off the pins (tHZ) clocks before the
  next ACTIVE can issue (ACT_BUSY).
- The raw experiment port keeps its exact per-clock schedule, read a
  clock ahead from its control word (`r_kn`).

**Benches.** `sim/sdram` gains a contention monitor (our driver against
the chip's, at the chip's pins, including its tOH/tHZ tail): 195 checks
+ the three training runs, all pass, no clash. Mutants: the high/low word
choice (476 of 585 fail), the raw schedule's index (5), the download
word (56); an enable inside a read's data window clashes and corrupts
the reads; an enable from seq 6 of a read (one clock past the data) does
not clash - the real enable starts at the next access's ACTIVE + 1, at
least two clocks later. `sim/machine` 17. The gcrread real-SDRAM run
(four hours) is not run, per the test method.

**Compile 34** (2026-10-04 01:09-01:48, tag `d3ecbe7e`, 39.5 min - synthesis
10, the fitter 27; archived `output_files/MacSE30_d3ecbe7e_dqpre.rbf`):
**37,853 ALMs (90 %)**, 83 fewer than compile 33; 43 % of the block
memory. **Timing met at every corner** (`sta_corners.tcl`): worst slack
+0.027 ns (slow -40C, register to register); the SDRAM output pins
setup +2.438 / hold +2.523 at slow 100C (compile 33: -0.516 on
`a_written -> dq_out[6]`), +2.489 / +2.638 at slow -40C, +3.29 / +2.96
and +3.33 / +2.97 at the fast corners; the read capture meets its A/B
rule at every corner (best margins 1.627, 1.324, 2.015, 1.853). **On
the board, expect compile 33's behaviour exactly** (the same commands on
the same clocks; only the enable's longer window differs).
**Daniel, 2026-10-04 10:xx: compile 34 ON THE BOARD WORKS, and performs
as compile 33 did, as expected** - the SDRAM data-pin change (1.17.6) is
proven on the hardware with timing met at every corner; compile 34 is
the current good bitstream.

**Daniel, 2026-10-04 (compile 33 on the board): the chime still sounds
slightly fast.** The bench's chime pass is 542 clocks against the
manual's 534-697 (cache off, the no-cache case's range) - at the
range's bottom - and the uncached DBRA runs 15 % fast (1.17.5: a fetch
miss is credited its wait states but not the no-cache case's extra
prefetch clocks). The chime runs from ROM with the caches off, so both
point at the same correction. Wanted: a real SE/30's chime duration
(a recording) as the measured reference; then the no-cache-case fetch
charge per UM 11.3.3. **Later the same night Daniel withdrew it**: he
had been comparing with the Mac LC, whose chime is longer; a
compilation of every Mac's startup chime
(https://www.youtube.com/watch?v=fu4DTm1rQQ0) has the SE/30's shorter
than the LC's. So no board evidence of a fast chime; the uncached
fetch charge stays a correction on the bench's evidence (TimeDBRA 15 %
high), and timing the SE/30's chime in that video against the core's
would close the question. **Closed the same night (Daniel): the core's
chime lasts about 0.7 s, more or less identical to the SE/30's in the
video.** (The bench's 1.04 s is the ROM's routine run to its end,
computed from the pass count; the ear hears less of the fade's tail -
presumably why the two differ. Either way the board matches the real
machine.)

### 1.17.7 The write pending buffer (design, 2026-10-04)

**What the 68030 does** (UM 11.2.5, 11.2.5.2, 11.2.5.3): "a single write
pending buffer, allowing the microsequencer to continue execution after
the request for a write cycle proceeds to the bus controller.
Interlocks prevent the microsequencer from overwriting this buffer." A
cycle the bus controller cannot run at once "is queued and the bus
controller runs the cycle when the current cycle is complete", and the
micro bus controller "implements any dynamic bus sizing required". So
the bus controller, not the microsequencer, runs a written operand's
beats through a narrow port; the microsequencer goes on with internal
work and with cache hits, and waits only when it wants the bus again.

**What the core does now.** The kernel waits for every write's
acknowledge and runs its own dynamic sizing (a long to the video RAM's
byte port is four kernel requests). The pace (1.17.5) charges the
manual's time, but the kernel's real time is longer wherever a slow
write could have overlapped the next instruction's head: the video-RAM
loops run 1.11-1.38 of the manual (fill 31.5/27.9, byte 11.1/8,
RAM->VRAM 35.8/32.1).

**The design** (the wrapper, `tg68k.v`; the kernel untouched):
- **What is posted**: a kernel data write (not the walker's, not CPU
  space, not a read-modify-write's) to a port that always terminates and
  never bus-errors, so the early acknowledge can never be wrong:
  low space `$00000000-$3FFFFFFF` (GLUE: RAM, or the ROM with the
  overlay on - "a ROM write: acknowledged, no effect"; a 32-bit port,
  DSACK 00, one beat) and the video card `$FExxxxxx` (it answers every
  address there, VRAM and declaration ROM mirrored; the 8-bit port,
  DSACK0*). Everything else - VIAs, SCC, SWIM, SCSI, ASC, the slots,
  the FPU - stays a waited cycle, as now.
- **The buffer**: at the posted write's S1 the wrapper latches address,
  the long's lane image (the kernel's data, Table 7-5's 32-bit column:
  each byte on its own address's lane), the bytes to the long's end
  (`w_nb`, as the 32-bit port would take them) and FC, and acknowledges
  the kernel at the next phi1 with DSACK 00 - the bytes a 32-bit port
  takes, so the kernel's own split at a long boundary is unchanged. The
  bus is driven from the buffer until the operand is out.
- **The beats**: RAM one, identical on the bus to today's cycle. The
  video card one per byte, the wrapper's own (the micro bus
  controller's sizing): address +1, SIZ the bytes remaining, the byte on
  D31-D24 (the only lane an 8-bit port reads; the first beat carries the
  kernel's exact Table 7-5 image, later beats the byte on every lane -
  a simplification no device here can see).
- **The interlock**: while the buffer is busy no other cycle starts -
  the kernel's next write, a read or fetch that misses, the walker, a
  PMMU fault's forced beat all wait for it; instruction and data cache
  hits and internal beats go on. The order of bus cycles is unchanged.
- **The pace**: a posted beat's clocks beyond two are credited as now
  (continuation beats whole). If the instruction that wrote has been
  released before a beat completes, that beat's clocks are added to the
  running instruction's budget and to the tail it overlaps (Equation
  11-2's min(head, tail) with the write's wait states in the tail, rule
  3a) - the same total the manual computes, now reachable because the
  kernel's head really runs under the write.
- **Not reachable, handled anyway**: a bus error on a posted beat
  (neither region can time out) ends the operand and is held to the
  kernel as today's late BERR; a bench check makes it visible.
- **Cost**: about 75 registers and the bus muxes' third input, an
  estimated 100-150 ALMs (about 360 left under the ~38.3k ceiling).
- **Gate**: `sim/system` timetest (the VRAM windows toward the manual,
  every other window unchanged), all `sim/system` programs, `sim/machine`,
  `sim/busfault`, `sim/cpfpu`; then the board (Speedometer Graphics,
  floppy, chime, a clean disk image after the disk test).

**Built 2026-10-04** (c829a33, 243581e; Daniel: "go ahead with the
development and the compile", and compile 35 right after 34).
- **timetest** (pacing on; the manual's figure from the measured byte
  cycles):

  | window | before (compile 33) | buffer | manual | ratio |
  |---|---|---|---|---|
  | VRAM byte MOVE.B D0,(A0)+ | 11.1 | **9.07** | 8.00 | 1.13 |
  | RAM->VRAM copy | 35.8 | **33.76** | 32.21 | 1.05 |
  | VRAM fill MOVE.L D0,(A0)+ | 31.5 | 31.51 | 29.73 | 1.06 |
  | RAM fill | 8.17 | 8.03 | 8.00 | 1.00 |
  | SWIM poll / GCR field (gap) / chime pass | 15.0 / 87.2 (23) / 542 | 15.01 / 87.19 (23) / 541.75 | | |

  The fill is bus-bound - four byte beats back to back, the same cycles
  as before - so the buffer cannot shorten it; its 6 % is the video
  card's beat pattern, a question of its own. Every other window is
  unchanged, as designed.
- **The gate found one thing: sim/cpfpu b5c.** The bench bus-errors two
  RAM writes (an FMOVE.X store's third long, an FSAVE frame's write) to
  test the fault frames inside FPU dialogs; posted, the faults arrived
  late and the frames named the kernel's next access ($3300 and $36C4
  for $3308 and $36E4) - the limit the design names: an early
  acknowledge can only report a write fault late. The SE/30 cannot
  raise one there, so the wrapper gained `post_en` (the machine ties it
  high); tb_cpfpu drives it low for a run that injects any write fault
  (b5c), tb_se30_system has `+NOPOST`. The 68030 itself reports a
  posted write's fault exactly (its frame carries the data output
  buffer and the fault address); ours cannot, which is why only ports
  that never fault are posted.
- **Gate, final**: `sim/system` all eight (plain/cacheon/cachewa 24,
  cachetest 28, vramtest 4, berrtest 3, timetest 35, clrtest 35) with the
  new check that no posted beat is ever bus-errored; `sim/cpfpu` all
  twelve (b5c 26 with posting off for it, the other eleven with it on);
  `sim/busfault` 14; `sim/machine` 17.
- **Compile 35** (2026-10-04 02:02-02:52, tag `243581ed`, 49.5 min;
  archived `output_files/MacSE30_243581ed_wpb_VIOLATED.rbf`): **37,789
  ALMs (90 %)**, 64 fewer than compile 34. **TIMING NOT MET: -2.272 ns
  at slow 100C, -2.028 at slow -40C** (the fast corners meet; the SDRAM
  pins keep compile 34's +2.44). Not the buffer's logic: both failing
  paths are compile 32's same-clock ATC hit (1.17.3 option A) -
  `RDindex_A` -> the register read -> the address adder (`Add47`) ->
  `PMMU_030|fast_xlat` (the 22-way match) -> `fast_hit` -> `busy` ->
  the kernel's `fetch_ok` -> `clkena_lw` -> `setstate` -> its next state
  (`Mux456`), 34 levels, 33.4 ns against 31.9 on the CPU clock
  (`general[0]`); and the same front through `addr_out` and the
  wrapper's address mux to the SDRAM controller's `xs_addr` (17 levels,
  -1.770 on `general[1]`). The path's history: +0.497 (compile 32),
  +0.716 (33), about +0.03 (34's register-to-register worst), -2.27
  (35) - it lives at the edge, and any change to the fit moves it: the
  seed lottery Daniel ruled out, so the remedy is structural and his
  call (below). **Compiles stopped here**, as agreed for a failure.
  **Daniel, 2026-10-04 10:40, for the record: Speedometer 4.02 Graphics
  on this violated bitstream = 0.155** (compile 33: 0.16; Low End Mac's
  real SE/30: 0.16). A preview only (the timing miss is on the ATC
  path, so a figure from it is not evidence), but it says the buffer does
  not move Speedometer's Graphics: the bench's 5 % on the VRAM byte and
  copy loops is inside whatever else QuickDraw does per pixel, and the
  Graphics gap is the record's (above), not the core's.

**FOR DANIEL, MORNING OF 2026-10-04 - what is ready and what to decide.**
1. **Compile 34** - `output_files/MacSE30_d3ecbe7e_dqpre.rbf` (tag
   d3ecbe7e): timing met at every corner (+0.027 worst). Expect compile
   33's behaviour exactly: floppy, chime, Speedometer 3.23 CPU ~4.27 /
   Graphics ~3.57, 4.02 CPU 0.27 / Graphics 0.16. **The one to test.**
2. **Compile 35** - `output_files/MacSE30_243581ed_wpb_VIOLATED.rbf`:
   the write pending buffer, but -2.27 ns on the ATC path. It may run at
   room temperature (the slow-corner model is pessimistic), but a fault
   on it could not be told from the timing miss - test it only as a
   preview of Graphics (expect a few % up), never as evidence.
3. **The overnight run** - `sim/gcrread` run 2 (the real SDRAM
   controller, compile 34's data pins, on the chip model with the new
   contention check), started 02:56 from the worktree; result in
   `C:\Git\MacSE30_wpb\sim\gcrread\run_sdram.log` (28/28 passed on
   2026-10-03 with the old controller).
   **07:00 status: still running, and over my estimate.** The "about
   four hours" in run.sh's header predates the second drive; part 4 now
   reads each cylinder on both drives in turn, with a select, seek and
   power-up at every switch. So far all clean: 22 checks passed, then
   cylinder 0 of both drives - 48 sectors byte for byte, 0 bad, 0 errors,
   0 bytes taken unread or twice - at 5.54 s simulated; it simulates
   about 1.45 s an hour, with four cylinder pairs, 4b and the final
   checks (the contention check among them) to go - another 3-5 hours
   by that rate. It uses one core and blocks nothing; Daniel approved
   ~4 h, so it is his to stop: `taskkill //PID 44092` (Git Bash) or
   `Stop-Process -Id 44092` (PowerShell).
   **09:00: still clean, and much longer than that.** 8.8 s simulated;
   cylinder 0 of both drives took 3.0 s (2.52 to 5.54) and the cylinder
   16 pair is not done at 3.3 s - against 0.3 s a cylinder in the old
   single-drive runs. Every drive switch is a select and the ROM's
   power-up wait, which fits most of it; part 7's "each side inside two
   revolutions" will say whether the reads themselves slowed. At ~3.3 s
   a pair and 1.45 s an hour the run ends around 16:00-17:00, ~14 hours
   in all - far past the ~4 h Daniel approved. Left running (his rule:
   tests run to completion), for him to keep or stop.
   **09:50: STOPPED by Daniel**, clean to the end - 22 checks, then
   cylinders 0 and 16 of both drives byte for byte (92 sectors, 0 bad, 0
   errors, 0 bytes taken unread or twice) at 10.0 s simulated; parts 4b
   and 7 and the final contention check NOT reached. His reasons: the
   second drive will probably go (the logic budget, 10.4), and floppy
   support is partial anyway - it is to be tested thoroughly later, as a
   whole. So compile 34's data-pin change has the real-controller
   evidence of two cylinders, not the full 28/28 gate; the board is the
   verdict. The `wpb` worktree (dev at 243581e, scratch logs only) is
   still to be removed.
4. **To decide: the ATC fast path's structure** (it must meet timing
   by design, not by fit). Options for the morning:
   - **a. A small fast-path ATC in front of the 22 entries** (2-4 most
     recently used translations, compared in the same clock; any other
     ATC hit takes the registered path, a clock later). Same
     translations; the clock lost only when a loop touches more pages
     than the fast entries hold. Shallower compare and mux - the levels
     the path needs to lose.
   - **b. Cut the path after the match**: register `fast_hit` and the
     physical address at the half clock (1.17.3's option B in effect),
     half the budget each side - only if the halves fit, which the
     path's split (the match ends ~21 ns in) says they do not.
   - **c. Back to compile 31's registered ATC** (a clock per address
     change under the PMMU) - safe, slower; the measured loss was 8 ->
     11 on the RAM fill.
   My recommendation is **a**; it needs the PMMU bench suite, timetest
   and a compile, and should be designed with the levels counted from
   this report before it is built.

### 1.17.8 The fast set: option a built (2026-10-04)

**Daniel, 10:xx: "start on option a."** Compile 34 works on the board,
performing as compile 33 (1.17.6), so the base is sound.

**The path, from compile 35's report** (`sta_paths_..._general_0_...txt`,
slow 100C; the clock arrives at 4.60 ns, the data must be in by 35.77):

| segment | cells | from -> to (ns) | span |
|---|---|---|---|
| kernel front: `RDindex_A` -> register-file read (`Mux475`) -> address adder (`Add47`) -> wire to the PMMU | 2 | 4.60 -> 10.23 | 5.6 |
| ATC search: 4 cells of per-entry masked compare, 2 of the "last match" priority chain (`hi`), 3 of the 22:1 mux (`Mux376`), 2 of the clean test (`fast_hit`) | 11 | 10.23 -> 21.69 | 11.5 |
| tail: `busy` -> `fetch_ok` -> `clkena_lw` (fan-out 1,207) -> `setstate` -> ... -> `RDindex_A` -> `Mux456` | 20 | 21.69 -> 37.05 | 15.4 |

33.4 ns against 31.2: -2.27. The second path (`general[1]`, -1.77) shares
the front and the search to `fast_hit~12` (22.83), then `addr_out` -> the
wrapper's `cpu_addr` -> the SDRAM controller's `xs_addr` register (26.40
against 24.63). The front and the tail are the kernel's; only the search is
ours to shorten, and it has to lose 2.3 ns plus a margin that survives
the fit - say 5-6 ns of its 11.5.

**What costs the 11.5.** Each of the 22 entries keeps its own page shift
(`atc_shift(i)`), so each compare is a 32-bit variable-mask compare though
every fill uses `tc_page_shift` ("always TC.PS granularity", W_PAGE); the
hit is the *last* matching entry, a 22-deep priority chain; the physical
base and attributes come through a 22:1 mux of 36 bits; and the clean test
(fault entry, write to WP or M=0, user access to a supervisor page, base
aligned) is done after the mux, per access.

**The design** (`TG68K_PMMU_030.vhd`: `fast_xlat` rewritten, `fast_set`
added; the registered path, the 22-entry ATC and every port untouched):
- **The fast set**: `FAST_ENTRIES` = 4 copies of ATC entries, each {valid,
  FC, logical page, physical page, CI, WP, `wr_ok` = M and not WP,
  `user_ok` = U_ACC, MRU}. One **registered page mask** for all
  (`fs_page_mask`, from `tc_page_shift`).
- **The compare** (`fast_xlat`): per entry `valid and FC = fc and
  (addr_log and mask) = page and (read or wr_ok) and (supervisor or
  user_ok)` - the clean test is folded into the match as two
  precomputed bits; the set is **canonical** (one copy of a page), so at
  most one entry matches and the 32-bit physical page, CI and WP come
  through a 4-way AND-OR; `fast_phys` = page OR (addr_log and not mask);
  `fast_hit` = any match AND the same quiet-MMU test as 1.17.3's (all
  registered signals). Expected: compare 2-3 cells, match 1, AND-OR 1-2,
  OR 1 - about 5-6 cells from `addr_log` to `fast_hit` against 11, so
  `fast_hit` near 16 ns instead of 21.7 and both paths some +3 ns.
- **Loading** (`fast_set`): the registered path requests an MRU update
  the clock after every ATC hit (`atc_mru_update_req/idx`); if that entry
  is a real translation (not a cached fault) with page-aligned bases, it
  is copied into the set - over its own copy if the page is there already
  (refreshing MRU), else an empty slot, else the first not-recently-used
  (the ATC's pseudo-LRU rule). A fast hit still runs the registered path,
  so it refreshes MRU through the same request.
- **Clearing**: the whole set empties in any clock where the walker may
  write an ATC entry - `wstate /= W_IDLE`, `walk_req`, `atc_flush_req`,
  `pflush_clear_atc`, `atc_mbit_inval_req` - or the context changes
  (`xlat_cfg_seq` moved, `tc_en` = 0, MMUDIS, the page mask changed).
  Every writer of `atc_valid`/`atc_log_base`/... (reset, W_PLOAD_FLUSH,
  W_FILL, the fault fill, the M-bit invalidation, PFLUSH's three forms)
  falls in one of these clocks, so **the set is always a subset of the
  ATC's valid non-fault entries**, and a fast hit is exactly what the
  registered path lands a clock later. Over-clearing (a walk empties
  the set) costs one registered-path clock per page to refill - the
  1.17.3 loss, briefly, after each miss.
- **Semantics preserved** against 1.17.3: a write to an M=0 or WP page
  misses the set (wr_ok = 0) and takes the registered path (BUG #410's
  invalidate-and-rewalk, or the WP fault); a user access to a supervisor
  page likewise (the fault); fault entries are never loaded; TTR matches,
  CPU space, translation off and MMUDIS are decided before the set as
  before.
- **Logic**: the 22 variable-mask compares, the priority chain and the
  22:1 36-bit mux go (compile 32 cost +633 ALMs for them); 4 x 71 bits
  of state, four 32-bit fixed-mask compares and a 4-way AND-OR come.
  Expect a net saving.

**Gate** (estimates from yesterday's logs): upstream's PMMU suite
(`sim/kernel_upstream`, SUITE=pmmu_suite.txt, 63 benches, ~8 min;
baseline 58 pass / 5 fail in `results_pours`), `sim/system` all eight
(~25 min; timetest windows 12-21 must equal 2-11 as in 1.17.3),
`sim/cpfpu` mmu and b5a-d, `sim/busfault`, `sim/kernel_bus`,
`sim/machine`. Then compile 36 = dev's head: compile 35's content (the
write pending buffer, whose own gate passed and whose fit compile 35
proved) with the fast set in place of the 22-way search; compile 37
removes the second floppy drive (Daniel, 10:xx: agreed, one change per
compile). **Perceived effect on the board, as told to Daniel (10:25):
compile 34's machine with Graphics a few % up (the buffer's VRAM byte
11.1 -> 9.07, copy 35.8 -> 33.8); the fast set itself should be
invisible, except that a loop touching five or more pages between ATC
misses, or the first access to each page after a miss, pays the old one
clock again - `FAST_ENTRIES` is the lever if a Graphics figure moves.**
Corrected at 10:40 by Daniel's compile 35 preview (1.17.7: Graphics
0.155 against compile 33's 0.16): expect compile 36's Speedometer
figures to equal compile 34's, Graphics included; the buffer's gain is
real on the bench but below what Speedometer resolves.

**Gate run (2026-10-04, 10:03-10:32, all in parallel):**
- upstream's PMMU suite: **identical to the baseline** - 58 pass, the
  same 5 fail (`tb_mmu_badfeed_fault_frame`, `tb_pmmu_030`,
  `tb_pmmu_walker_comprehensive`, `tb_pmove_crp_a7_postinc`,
  `tb_pmove_pc_all_regs`) with the same failure lines; 6 min 54 s.
- `sim/system` all eight (17.5 min): plain/cacheon/cachewa 24, cachetest
  28, vramtest 4, berrtest 3, timetest 35, clrtest 35. **timetest's
  PMMU-on windows equal the PMMU-off ones**: RAM fill 8.05 / 8.03, RAM
  read 13.10 / 13.09, copy 13.10 / 13.10, VRAM fill 31.78 / 31.51, VRAM
  byte 8.83 / 9.07, RAM->VRAM 33.76 / 33.76, SCSI blind read 168.44 /
  168.00, write 173.69 / 173.75, GCR address field 87.19 / 87.19 (SWIM gap
  23) - the 1.17.3 loss stays gone; chime 1.04 s.
- `sim/cpfpu` mmu 11, b5a 15, b5b 18, b5c 26, b5d 19; `sim/busfault` 14;
  `sim/kernel_bus` 16/32/8 (338/237/520 checks); `sim/machine` 17 (91 s).
Committed `3646253`. **Compile 36 started 10:30** (tag `36462531`,
Daniel's "compile when ready"); result below when it lands.

**Compile 36** (2026-10-04 10:30-11:02, tag `36462531`, 32.5 min -
synthesis 9, the fitter **21** against compile 35's 38; archived
`output_files/MacSE30_36462531_fastset.rbf`): **37,574 ALMs (90 %)**,
215 fewer than compile 35 and 279 fewer than compile 34 (the PMMU
entity: 4,926). **TIMING MET AT EVERY CORNER** (`sta_corners.tcl`):
the design's worst slack over every corner +0.063 ns (slow -40C, a
framework path; the flow's +0.162 at slow 100C), the SDRAM outputs
+2.438 / +2.489 as compile 34, the read capture meeting its A/B rule
at every corner (best margins 1.627, 1.324, 2.016, 1.853). **The ATC
path**: the CPU clock's worst path is now +1.096 ns (a PMOVE
micro-state path, `sta_paths.tcl`), the SDRAM clock's +0.352 (inside
the SDRAM controller, `busy -> sd_addr`), and the worst path *through
the fast set* (`report_timing -through` its `fast_hit` nets) is
**+4.149 ns** against compile 35's -2.272 through the 22-way search: a
6.4 ns gain, the 5-6 ns the design counted on. The fast-set state
(`fs_*`) paths have +6.13. The fitter's routing time fell with the
congestion, as 1.17.7's note on compile times suggested it would.

**On the board (Daniel, 11:10, `C:\temp\Mac\Screenshots\
20261004_111009-screen.png`, Speedometer 4.02 Comparison against the
saved compile 34 record): runs fine, and reads as compile 34** - CPU
0.27 / 0.27, Graphics 0.16 / 0.15, Disk 0.41 / 0.43, Math 1.13 / 1.10,
PR 0.25 / 0.25 (compile 36 first). Graphics is back on Low End Mac's
0.16. **Compile 36 is the current good bitstream**: compile 35's buffer
and the fast set, timing met by design. 1.17.7's open decision is
closed by this. Next: compile 37, the second floppy drive out (10.4).

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
| `$800000-$8FFFFF` | 2 MB | the internal floppy's image (5.12.5) |
| `$900000-$9FFFFF` | 2 MB | the external floppy's image (5.14) |
| `$A00000-` | 12 MB up | reserved for the SCSI section's images |

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
| `$6` | 1 001 | `rNoWrProtectAdr` | 0 = write-protected | 1 (rung 1); **0 from rung 2** | secondary; not read without a disk; the 800K ERS (3.2.4.9) reads 0 with no diskette (5.12.3) |
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

**Read from the page images for item 3 (2026-09-28, sheets 17-28).**
Where they refine or correct the list above:

- **/STEP** (3.4.3.1, sheet 26): T2, the low time, is **0.5 us min, 72 us
  max** - the drive sets /STEP high within 72 us of the falling edge. The
  model holds it low the maximum, **72 us**. A step command while /STEP is
  still low writes a 0 over a 0: no falling edge, so no count (the ROM
  polls `$4` for the 1 before the next step).
- **/READY after a step** (3.4.3.3, sheet 27): high within 150 us of
  /STEP (T1; the model: at once); low 36 ms max after, 152 ms across a
  speed-block change, **600 ms max "for any case when step pulses are
  sent at the maximum rate"**. The model: each step sets the settle
  deadline to the later of the one pending and now + 36 ms (152 ms when
  the step crosses a group).
- **/READY for motor-on or disk-in** (3.4.4, sheet 28): T1 **600 ms max**
  from /MOTORON low; T2 0.5 us max to go high when /CSTIN goes high; **T3
  1.0 s max from a disk-in with the motor on** (the 600 ms above is
  motor-on only); T4 50 ms max to go high after /MOTORON goes high (the
  model: at once).
- **/WRTPRT** (3.2.4.9) reads **0 with no diskette** as well as with a
  protected one; rung 1's table had 1 ("not read without a disk", which
  the ROM confirms), so rung 2's constant 0 is the ERS's for both.
- **/ENBL high** (3.2.2) presets the control latches: /DIRTN to 0 and
  /MOTORON to high - **deselection stops the motor**. The ROM agrees: its
  VBL task (`$4082E444`) returns without touching the SWIM while the
  driver is busy (`$19(a1)`) or its motor-off countdown (`$1A(a1)`) is
  running, and drops MotorOn (`$1000`) only after the countdown's command
  `$9` or with the motor already off.
- **Register `$C`** is EJECT in the 800K ERS (`0011`: high from the
  command until /CSTIN rises, or 2 s). The SuperDrive's is a **latch the
  ROM resets** with command `$3` (`$4082E4E2`, only for a drive its flag
  `$5(a1,d1)` marks), which the 800K drive has no command for. The ROM
  outranks the other drive's ERS here: the model keeps rung 1's latch,
  **set by the eject command, cleared by `$3`**. What sets it on a real
  SuperDrive (the eject, or also an insertion) is not documented; both
  readings drive the ROM's VBL paths the same way.

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
  4`; 8 `0 4 1 5 2 6 3 7`. (The page image's first two lines are Apple's
  typos, not the OCR's; the ROM's formatter generates these standard 2:1
  sequences - 5.12.5b.)
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

**Read for item 5 (2026-09-28).** The donor is MacLC's `floppy_loader`
(`rtl/floppy_sd.v` at `045f896`): MacPlus's, plus the DiskCopy 4.2 strip
(a name length of 1-63 and the magic `$0100` at `$52` recognise the header;
its 84 bytes never reach SDRAM) and the medium sniff offset past it. It is
lifted with its comments; four changes, each for a reason on record:

- **A request waits for the last acknowledge to fall.** MacLC raises the
  next word as soon as its own request is low; this controller clears an
  acknowledge only once it has sampled the request low, so the next word
  could be counted written on the old acknowledge (MacPlus phase 7's
  stale-pulse trap, and the encoder's rule, 5.12.5b).
- **A mount during a load is not dropped** (MacPlus's `mount_pending`;
  MacLC accepts a mount only when idle). It takes effect between sectors,
  never inside an `hps_io` transfer; the old disk is out from the pulse.
- **The DC42 header's sizes**: data at `$40`, tags at `$44` (32 bits,
  big-endian). Tags count only when their size is exactly 12 per block of
  the data; anything else is a tagless image (MacLC phase 1: four of
  nineteen real DC42s were damaged).
- **What the SE/30 needs out**: `disk_in` (the whole image resident, a GCR
  geometry recognised), `img_ds` by the three ceilings of MacPlus phase 7
  - the SuperDrive is double-sided; an 800K file (819,200 raw, or a DC42's
  data 819,200) can be; the medium's MDB says whether it is - `img_800k`
  (the file's data region, which places a DC42's tags), `img_tags`,
  `readonly`. The drive's eject takes the disk out; the OSD mounts it again.
  **Rung 2 is GCR**: a 720K or 1440K image (raw 737,280 or 1,474,560, DC42
  format 2 or 3) loads but does not count as in (5.13).

**The disk port** (`dk_*` on `se30_sdram`): one 16-bit word read or
written, the level request and acknowledge of `dl_*`, the read's word with
the acknowledge. Below a CPU start, refresh and the download in priority,
and issued only where refresh is: **in the idle window after a CPU start**
(clocks 10-15 - an access holds the chip 8 clocks, so it ends by 23, where
refresh's 6-clock one issued by 17 does, before a back-to-back start needs
the chip) **or when no start has come for 63 clocks**. In the second case a
start that arrives during the access waits for it: GLUE waits on the
acknowledge, so that costs the cycle a wait state, never its data. The
ROM's GCR loops run from the 68030's cache polling the SWIM, which is where
the encoder's reads mostly land; `sim/sdram` counts the collisions. The
loader and the encoder share the port through a mux in the machine (item
7): the loader while loading (the disk is out, so the encoder is idle),
the encoder otherwise.

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

**Read for item 4 (2026-09-28): the ERS's sheets 39-42 from the page
images, and the ROM's own GCR formatter** (`$40831F24`, its sector
template at `$40831F08`, the header fill `$40832198`, the track loop
`$408320BC`) **and sector writer** (`$4082E518`-`$4082E65A`). The ROM is
documentation-tier for what a Mac-formatted track holds; where it is
more specific than the ERS the encoder follows it.

- **The interleave** is generated by the formatter itself (`$408321CA`):
  sector numbers alternate between 0, 1, 2 ... and (n-1)/2+1, ... - so
  0 6 1 7 ... for 12 and 11, 0 5 1 6 ... for 10 and 9, 0 4 1 5 ... for 8.
  The ERS's lines for groups 1 and 2 on the page image read "0-6-7-2-8-3-9-
  4-10-5-11" and "0-6-1-7-3-8-3-9-4-10-5": **Apple's typos, not the OCR's**
  (5.12.4's note is corrected by this).
- **The address field** (the header fill): track & `$3F`, sector, side
  (bit 5 the side, bit 0 track bit 6), format (`$22` double-sided, `$02`
  single - the formatter's own two values), checksum = the XOR of the four;
  all five through the GCR table. Then `DE AA` and one `FF` (the template).
- **The GCR table** is the ROM's at `$4082E662` and the ERS's sheet 42,
  entry for entry. `AD` in `D5 AA AD` is GCR(`$0B`) - the writer sends it
  through the table.
- **The data field**: `D5 AA AD`, GCR(sector), 699 codes, 4 checksum
  codes, **`DE AA FF FF`** (`$4082E65E`; the ERS's one "off" byte, and a
  second the IWM notes say to write before leaving write mode - the
  formatter lays both down, `$4083216C`). The nibbling is the ERS's steps
  1-9, and the writer's loop is them instruction for instruction: `add.b
  d7,d3` takes CSUMC's bit 7 into X before `rol.b`, then `addx` A, B, C in
  that order, the last carry lost; each group is [rotate, A, B, C] and
  the 175th is A and B only (NIBL4 omitted: 174 x 4 + 3 = 699 codes); the
  checksum codes are GCR({A7A6 B7B6 C7C6}), then A, B, C low bits. The
  sector number (the writer's `$2FB`) precedes the 12 tag bytes and is
  not in the checksum; checksums start at 0.
- **Sync**: the formatter writes 6-byte chunks `FF 3F CF F3 FC FF` - four
  ten-bit groups and a plain `FF`. A formatted track is: a lead-in of 200
  chunks, then per sector (`$22(a1)` - 1) chunks, the 27-byte template
  (its own chunk, `D5 AA 96`, the five, `DE AA FF`, a chunk, `D5 AA AD`,
  the sector), 703 codes and `DE AA FF FF` - the whole track in one write,
  the lead-in overrun by the end. `$22` starts at 7 and the formatter's
  timing loop (`$40832064`) moves it to fit the drive's actual track.
- **The encoder's layout**, that formatter's at the model's exact speeds:
  per sector **8 chunks** (the largest count that fits every group: a
  sector is 48 x 8 + 5,824 = 6,208 bits), 11 address bytes, a chunk,
  `D5 AA AD` and the sector, 703 codes, `DE AA FF FF` - **776 bytes**; the
  **leftover** of each revolution (group 1-5: **62, 188, 157, 82, 126
  bits**) goes at the track's start as ten-bit groups ending in `00`,
  where the formatter's overrun lead-in would be, so no sector crosses
  the wrap and every header has at least eight chunks before it.

**The encoder's shape** (`se30_flp_encoder.v`): for each side, each
sector in formatter order: **fetch** its 262 words (6 tag, 256 data)
through the disk port into a sector buffer, **nibble** them into 703 code
bytes, **emit** the 776 bytes a bit a clock into the track buffer; a
single-sided image leaves side 1 without flux. Built when `disk_in` is up
and the drive's `cyl` differs from what the buffers hold; a new `cyl`
restarts it, but **never with a memory request outstanding** (MacPlus
phase 1), and a request is not raised again until the last acknowledge
has fallen (MacPlus phase 7's stale-pulse trap in another form).
**The image in SDRAM**: word `base + k` holds image bytes 2k (high) and
2k+1 (low), the header stripped, so a DiskCopy 4.2 image's tags follow its
data: block n's data at `base + 256n`, its tag at `base + 256 x blocks +
6n`. Block n of cylinder c, side s, sector k: sides x (sectors before c)
+ s x spt + k.

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
   **Done 2026-09-28: 63 checks PASS** (`sim/fdhd/run.sh`, about 3.5
   minutes - the ERS's times run at full length: 600 ms, 1.0 s and five
   revolutions). The ERS was read from the page images first; what it
   changed is under 5.12.3 ("Read from the page images for item 3").
   The bench has ten parts (no disk; a disk in; motor-on /READY; RD's
   pulses by side; /STEP; /READY after a step, within and across a
   group; each group's revolution and /TACH; deselection; disk out and
   in; eject and the SuperDrive registers). **Against the rung-1 drive,
   given the new ports and nothing behind them, 32 of its 63 checks
   failed**; the 31 that passed are registers rung 1 already had.
   - **The encoder's side** (5.12.5b), fixed here for item 4: the drive
     shows `cyl`; the encoder answers `trk_cyl` and `trk_valid`; /READY
     and RD's data wait for `trk_valid && trk_cyl == cyl`. The cell under
     the head is `trk_addr` (0 to the group's length - 1) on `trk_side`
     (= SEL); `trk_bit` is expected a clock later. `eject` pulses one
     clock at the command, for the loader.
   - **One RTL fault found by the bench**: a disk arriving with the motor
     on loads the 1.0 s spin-up a clock after `disk_in` rises, so /READY
     read low for that clock. /READY now also waits for the registered
     `disk_in`.
   - **`sim/swim`'s rung-1 step checks** stepped back to back; with
     /STEP held low 72 us a second step inside it is (rightly) not
     counted. The bench now polls `$4` between steps as the ROM's seek
     does (`$4082E17A`); 118 PASS.
   - **Found on the way, in item 2's committed RTL**: `se30_swim.v` used
     `rd_val` before declaring it. Icarus accepts that; ModelSim does not,
     so **`sim/machine` had been failing to compile since `5ab493c`**
     (its PASS on disk was the morning's run). `rd_val` is now declared
     ahead of its use; `sim/machine` 17 PASS again. From here, a change
     to an RTL file is not done until `sim/machine` (ModelSim) has been
     rerun and its `run.log` is newer than the change.
   - **Mutation test**, all caught: the group's 152 ms not applied (2
     fail), a step's settle overwriting a longer one pending (1), RD's
     pulse 7 FCLK (2), deselection keeping the motor (2) or the direction
     (1), /TACH at 59 pulses (5), a step counted while /STEP is low (3),
     one group's revolution a cell long (1), /READY without the track
     buffers (2), no 1.0 s for a disk-in (1), the heads swapped (3), /STEP
     low 64 us (1).
4. `sim/flpenc`, failing, then `se30_flp_encoder.v`.
   **Done 2026-09-28: 26 checks PASS** (`sim/flpenc/run.sh`, about 4.5
   minutes; `MACPLUS` points at the MacPlus checkout for the second
   opinion). The ERS's sheets 39-42 and the ROM's formatter and writer
   were read first; what they settle is under 5.12.5b ("Read for item
   4"). **Against a stub with the same ports, 16 of the first 25 checks
   failed.**
   - **All 1600 sectors** of a double-sided image with tags come back byte
     for byte through the bench's reference decoder (the IWM's framing, one
     revolution only, the ERS's steps inverted); the formatter's interleave,
     `$22`, and **every cell outside the 703 codes of every side of every
     cylinder bit for bit as the formatter lays it**. Single-sided (`$02`,
     side 1 without flux) and tagless images too.
   - **MacPlus's `floppy_track_encoder.v` agrees**: 116 sectors, a track of
     every group, both sides - address fields and all 709 data-field bytes.
     A first run disagreed on every sector; the cause was the bench: it
     set MacPlus's `ready` on the edge MacPlus samples, a race that read
     image bytes twice (5.12.7's "reset deasserted on the DUT's own edge"
     in another signal, and the artifact MacPlus's own bench header
     describes). `ready` now changes on the falling edge.
   - **The disk port**: 419,200 requests, none torn, none moved, none raised
     over a stale acknowledge; a cylinder change on a request's first clock
     waits for the acknowledge. The longest build is 273,373 clocks (8.7 ms)
     with the bench's 3-12-clock memory, inside the drive's 36 ms settle.
   - **Mutation test**, all caught: the rotate's carry dropped (7 fail),
     A XORed with the unrotated CSUMC (7), the last group adding a C (7),
     no interleave (2), `$22` on a single-sided disk (1), the header
     checksum without the format (14), the header's pad `00` (1), the
     leftover ending `10` (1), tags from the wrong address (3), a request
     raised over a stale acknowledge (9), a build abandoned with a request
     out (1, after the section-7 change was moved to a request's first
     clock - at an arbitrary moment it survived), a sync chunk's `3F` as
     `7F` (15).
   - Compiles clean under ModelSim's `vlog`. The encoder is not yet in the
     machine, so Quartus has not inferred its three RAMs (the track buffer
     149,120 x 1, the sector buffer, the codes): **item 7's elaboration
     must check the fitter's M10K count** against the plan's estimate.
5. `sim/flpload` and `sim/sdram`'s disk port, failing, then
   `se30_flp_loader.v` and the port.
   **Done 2026-09-28.** What was read first is under 5.12.5 ("Read for
   item 5").
   - **`sim/flpload`** (new, 45 checks, about 9 minutes - it loads 27
     images): raw 800K and 400K; DC42 800K with tags, 400K without, a
     damaged tag size; the three ceilings; MacPlus phase 7's eleven sniff
     images; GCR only (1440K raw and 720K DC42 load but are not a disk); a
     mount during a load; a mount on the very clock a load completes;
     unmount; the drive's eject; `readonly` from the slot's own pulse; no
     sector transferred twice; the handshake; and Daniel's `Disk605.dsk`
     resident byte for byte (a smoke test: untagged, double-sided, 800K).
     **Against a stub with the same ports, 31 of the first 43 failed.**
   - **Three loader faults found on the way**, two by reading the RTL
     before trusting a green run: the drain's registered buffer read would
     have written the word before on a request raised the clock after
     `drain_idx` moved - the first data word of every DC42 (now raised
     only once the buffer's read is of this word); `loading` dipped for a
     clock between an abandoned load and its successor (it now rises at the
     pulse); and **a mount pulse on the clock `S_DONE` completes would have
     left the old image in** while the new one loaded (its assignments came
     after the pulse's). An edit of mine also turned `S_NEXT`'s end-of-image
     test into a comment, which the bench caught as every load running
     forever.
   - **`sim/sdram`** gains the port (193 checks, and the three training
     runs): words written read back as the CPU's longwords, words read (even
     and odd) are the CPU's; alongside back-to-back CPU cycles 80 words in
     84 cycles with **none late**; requests timed to arrive late in the
     window never issue outside it (a monitor on every disk ACTIVE: clocks
     10-15 after a start, or an idle bus); on an idle bus a CPU stream
     starting into the traffic loses **one wait state on its first cycle**.
     **Against a controller with the ports that never serves them, the
     bench times out.** Two faults of the BENCH, both old kinds: an
     expected value computed at 32 bits against a 16-bit word, and two fork
     branches sharing one loop counter (as `sim/swim`'s did, item 2).
   - **A finding about the controller's refresh, not the port**: after a
     long idle bus a refresh falls due and goes "at the first idle clock";
     a CPU start arriving during it waits one C16M. The bench caught it
     once its sections' timing shifted. The header's "never costs the CPU a
     wait state" holds for back-to-back streams, not after an idle bus. The
     real GLUE's own refresh stalls the CPU too (5.9's late-request case),
     but that stall is modelled separately: this one is the SDRAM's, an
     artefact on top of it - one C16M, one cycle, only after several us
     with no RAM/ROM start, the data always right. **Daniel, 2026-09-28:
     leave it unless it becomes obvious that it is harmful.** The
     alternative (holding refresh for a CPU window) risks the SDRAM's own
     refresh deadline.
   - **Mutation test.** The port: a window to clock 17 (caught by the
     monitor; it also made a CPU cycle late), no window (2 fail), an idle
     bus only (the disk starves: timeout), the second beat taken (2), a read
     without auto-precharge (the model's datasheet check), the acknowledge
     never cleared (timeout); **one equivalent**: reading the request's
     fields live rather than latched - a requester cannot change them
     before it has seen the acknowledge, and a write leaves `S_DK` before
     any change is sampled; the latch stays as defence. **The loader**, all
     caught: a request over a stale acknowledge (7 fail), no guard on the
     buffer's read (2 - the DC42 first word), a mount dropped while busy
     (MacLC's behaviour, 3), the DC42 header not skipped (1), no byte swap
     (14), the sniff ignored (5), the file ceiling dropped (1), tags
     without the size check (2), the disk in before the last acknowledge
     (a timeout), the `S_DONE` race unfixed (1 - the new check), GCR
     unchecked (3), and `sd_rd` held through the drain (16 - every sector
     transferred six times). A first form of that last, `sd_rd` dropped as
     the transfer ends rather than as it starts, survived: nearly
     equivalent, since no poll can fall in the one clock between; the
     hazard MacLC's comment names is holding it past the transfer.
   - **`sim/machine` 17 PASS** with the controller's new ports tied off
     (run.log fresh, exit 0); the top ties them off too until item 7.
     `vlog` compiles all four changed files clean.
6. `sim/gcrread`, the gate.
   **Built 2026-09-28; two machine bugs found and fixed; `+quick` result
   below.** The chain is the machine's: the HPS model -> `se30_flp_loader`
   -> `se30_flp_dkmux` (new: the port's owner follows `loading`, changing
   only while the port is quiet) -> the SDRAM -> `se30_flp_encoder` ->
   `se30_fdhd` -> `se30_swim` -> **`se30_glue`'s device port -> a 68030
   bus model**, with the real VIA1 (the head select, PA5, by the ROM's own
   `bset`/`bclr` on ORA). The bus model replays the ROM's routines
   instruction by instruction, disassembled for the purpose: Open's SWIM
   probe (`$4082E6A2`), the drive enable (`$4082E3D6`, vector `$B40`), the
   ISM entry's GCR path (`$4082E712`), the mode loop (`$4082E2F2`), the
   power-up (`$4082E376`), the recalibrate (`$4082E29E`), the seek
   (`$4082E17A`) with its settle (`$4082E1FE`), and RdAddr (`$40831BE8`)
   and RdData (`$40831CC2`) byte for byte - every SWIM, VIA1, ROM (the
   decode table at `$40831E08` and the marks) and RAM (the decoded bytes)
   access a real bus cycle through GLUE, the rest of each instruction its
   68030 cache-case time. The `.Sony` driver's timing words are Open's copy
   of `$4082D76E` to `$2A(a1)` (`$34` 300, `$38` 4000, `$3C` 120, tenths
   of a millisecond: `$4082E246` divides by ten before PrimeTime); the
   drive's `$F` reading 1 sets the flag (`$13`) that makes the ROM poll
   `/READY` every millisecond up to 1,000 times.
   - **Bug 1, the SWIM acted twice per access in the machine.** GLUE's
     `dev_strobe` is one C16M, two `clk`; the VIA qualifies it with
     `c16_en`, `se30_swim.v` did not, and `sim/swim` (clk = FCLK, `c16_en`
     tied high) could not see it. Latch accesses are idempotent; the ISM
     switch's count of `$57 $17 $57 $57` never reached four, so **Open's
     probe never found the SWIM** (`$134` clear: the ROM would drive it as
     an IWM and never try MFM). The gate failed both checks (13 of 13
     probe cycles doubled); `hit` now carries `c16_en`; 2 PASS, `sim/swim`
     118 PASS.
   - **Bug 2, the processor took bytes the SWIM never saw read.** The
     SWIM counts a valid read (which arms its 14-FCLK clear) at the strobe;
     GLUE handed the device's byte to the processor live, two C16M later.
     A byte latching in between reached the ROM uncleared and was read
     again: five duplicates in 48 bytes, `D5 AA 96` missed, 73 errors on
     cylinder 0 (`$BD`, `$BB`, `$B8`, `$B9`). A monitor proved it (bytes
     with the MSB taken with no valid read at the chip). **Daniel chose A
     (2026-09-28): GLUE registers a device's byte on the capture clock** -
     the clock the device acts on the strobe - and holds it for the
     processor (`se30_glue.v`; the device port's contract, "the device ...
     must present" at the strobe, made exact). The alternative, the
     drawing's valid read over the whole select, would clear bytes never
     taken, GLUE holding the select an FCLK past the processor's latch.
     `sim/glue`'s device model registered its answer a clock late; it now
     answers combinationally, as chips drive their pins: 97 PASS.
   - **Run time, and the split (Daniel, 2026-09-28).** With the real
     controller on the chip model the bench runs 0.44 ms of machine time a
     second; the gate is about 25 s of machine time (the ERS's times, a
     revolution a side), so 16 hours. **The gate runs on a behavioural
     clk_sys memory (`-DBEHAV_MEM`, the controller's two contracts; about
     three hours), and the real controller runs Open, the load, the
     recalibrate and a cylinder of each group (`+groups +no56`; about two
     hours).** `./run.sh quick` is the working gate; the full runs go in
     the background and do not block the board (Daniel: the board for what
     happens, the bench for why).
   - **`+quick`** (cylinders 0, 15, 16, 31, 32, 47, 48, 63, 64, 79; the
     400K and Disk605.dsk parts), 85 minutes, 9.9 s of machine time:
     **every sector the ROM read is right** - the 800K DiskCopy image's
     200 sectors of those cylinders, every speed group, tags at `$2FC` and
     data in RAM byte for byte, the address fields' cylinder, side and
     `$22`, no error code, each side inside one revolution (1.00); the
     power-up's `/READY` after 519 of the ROM's polls; `/STEP` answered
     within 6 of its 81; the 400K image's side 0 (58 sectors, `$02`) and
     its side 1 without flux (`$BE`, six of six); `Disk605.dsk`'s 84
     sectors as the file holds them; no byte taken unread, one chip access
     a SWIM cycle, the port's handshake clean. **One check failed, the
     bench's**: "no valid read inside a pending clear" counted 1,225 -
     the drive addressing's latch accesses, which with L6 and L7 clear read
     the data register too and re-arm its clear (the chip's documented
     behaviour, and Daniel's pinned reading of 5.12.12 item 2). The check
     now counts what it meant: **a byte the ROM's data-register reads took
     twice** (a second MSB byte before the shifter latched another); the
     re-arms are reported, not failed.
   - **The full gate (2026-09-29, at `93b9a4c`, `./run.sh`): PASS, both
     runs.** Run 1 (`-DBEHAV_MEM`, every cylinder), 4 h 07 min, 30.4 s of
     machine time: **31 of 31** - all 1,600 sectors of the 800K DiskCopy
     image byte for byte, tags and data (speed groups 1-5: 384, 352, 320,
     288, 256), the address fields as laid, no error code, each side
     inside two revolutions (1.01), `/STEP` within 6 of the seek's 81
     polls; the 400K image (58 sectors on side 0, `$BE` six of six on side
     1) and `Disk605.dsk`'s 84 sectors as before; no byte taken twice or
     unread, one chip access a SWIM cycle, nothing hung (2,906 re-arms
     reported, the documented behaviour). Run 2 (the real `se30_sdram` on
     `sim/sdram`'s chip model, `+groups +no56`), 1 h 55 min, 3.2 s of
     machine time: **28 of 28** - Open, the load, the recalibrate and a
     cylinder of each group (100 sectors, 1.09 revolutions a side), the
     SDRAM model without a datasheet violation, the disk port without a
     torn, moved or stale-acknowledged request. The logs are `run.log` and
     `run_sdram.log`. **Rung 2's bench is closed.**
7. The top, the machine, `PFLP`; elaboration; `sim/machine` unchanged.
   **Done 2026-09-28.** `MacSE30.sv`: an `S0,DSKIMG,Mount Floppy` slot
   (`hps_io` `VDNUM` 1, 512-byte blocks, read only), the loader, the mux
   and the encoder on the PLL's lock (a machine reset keeps the disk in),
   the controller's `dk_*` port, `LED_DISK` the drive's motor. The machine
   takes the drive's disk interface as ports; `sim/machine` ties them off.
   **`PFLP`** (64 bits): the loader's and the encoder's states, the port's
   words moved, and the bytes the ROM has taken (the SWIM's valid data
   reads, a new `dbg_vread`); `read_probes.tcl` decodes it. `sim/machine`
   17 PASS (run.log fresh); Analysis & Synthesis clean (0 errors).
   **The M10K count** (item 4's open question) waits for the fitter.
   With it, Section 7's ASC stub (Daniel: before this bitstream).
8. The compile (Daniel's go-ahead) and the board: an 800K image mounted.
   **Compile 19 (tag `9b365e8f`, `MacSE30_9b365e8f_gcrread.rbf`, md5
   `b68e60a6...`)**: 23m30s, the flow's timing met (+0.088 ns),
   `sta_corners.tcl` met at every corner with the capture excepted (0.992
   ns; the capture as in compiles 15-18); 218 of 553 RAM blocks (39%).
   **THE BOARD (2026-09-28, Daniel): the grey screen, the disk icon, the
   happy Mac with the pointer moving - then "Welcome to Macintosh". The
   SE/30 read its System from the floppy image: 5.12.10's target met.**
   A few seconds later the Welcome box redraws in a continuous loop with
   no pointer; a second disk does the same. The probes: the CPU runs (no
   halt, no bus error, the VBL at 60/s), the disk idle at cylinder 53 with
   60,000 bytes read, and 60 samples of the fetch address spread across
   QuickDraw writing the box's rows of video RAM - no device polled (not
   the SCC, SCSI, the ASC or the SWIM). The Welcome box is the System
   Error Handler's own greeting alert, so a loop re-entering that code
   fits; what re-enters it (an exception - the missing 68882's F-line, an
   address error, an illegal instruction - or a trap retried) the fetch
   address cannot say. **Daniel: build both instruments** - **`PEXC`**
   (the CPU's exceptions: counts by class and the last 8 vectors that were
   neither interrupts nor A-line) and **`PTRP`** (the last 16 A-line trap
   words), from a one-clock pulse the kernel now exports as its vector
   fetch step (`trap3`) advances (`debug_exc_take`, with `debug_trap_vector`
   and `debug_opcode`). `sim/busfault` holds the pulse: once per bus error,
   vector 2, no other exception (13 PASS); `sim/machine` 17 PASS.
   **Compile 20 (tag `51a0475b`, `MacSE30_51a0475b_exc.rbf`)**: the flow's
   timing not met by -0.220 ns in the framework's HDMI scaler
   (`sys/ascal.vhd`'s `o_div`, slow -40C, as compile 18's); the machine met
   at every corner (1.232 ns). Daniel flashed it. **THE ANSWER: F-line
   exceptions, about 35 a second** - `PEXC`'s last 8 non-interrupt,
   non-trap vectors all 11, no address error, no illegal, the bus-error
   count not climbing (the Slot Manager's boot-time 255); `PTRP` a
   QuickDraw redraw cycle around them. **The missing 68882.** Daniel: build
   the 68882 as fully as possible now ("bypassing it will not exempt us
   from implementing it"), and first a third probe, **`PFLN`**: the last 4
   F-line exceptions, opcode and address (the kernel's `opcode_pc`, the PC
   an F-line stacks, now exported), so the FPU's first instructions are
   known. `sim/busfault` 14 PASS (the exported PC is the faulting
   instruction's, as stacked); `sim/machine` 17 PASS.
9. **5.13 - the ISM's MFM read** (720K, 1.44 MB), from the ISM ASIC spec,
   written when GCR is on the board.

## 5.14 The external drive (Daniel, 2026-10-02)

**Daniel: a second floppy drive before the next compile** - testing with
one is very hard. **Decided with him: a second FDHD (SuperDrive) on the
external port**, the SWIM's `/ENBL2`.

**The evidence** (the *Guide*, 2e, ch. 9 "FDHD drive interface", pp.
343-350): the SE FDHD, SE/30, IIcx, IIci and Portable "are equipped with
an internal FDHD drive and an external disk drive connector to which you
can connect a second FDHD drive"; **Table 9-6: the SE/30 has 1 internal
and 1 external floppy drive** (its note: "on all Macintosh models that
support an external FDHD drive, you can connect an external 800KB drive
instead" - an equally authentic later option, not built now); "the SWIM
supports two drives, each with its own enable signal ... on machines with
only one internal drive, the enable signal for the internal drive is
/ENBL1 and the enable signal for the external drive is /ENBL2"; **Table
9-10**, the SE/30's external DB-19: PH0-PH3 (11-14), /WRREQ (15), SEL
(16), **/ENBL2 (17)**, RD (18), WR (19), pin 10 tied straight to +5 V -
5.3's J6. The external drive takes the same PH, SEL and WR lines as the
internal one; each drive answers only while its own enable is low.

**The design.**
- **The drive**: a second `se30_fdhd`, unchanged, on `enbl2_n` with the
  same PH pins and VIA1 PA5 for SEL. **RD**: each drive drives its line
  only while enabled (the model's `sense` is 1 otherwise, 5.5's "a line
  nothing drives reads 1"), so the SWIM's RD is the AND of the two - which
  replaces 5.5's constant 1 for the absent drive. The ROM's Open now finds
  a drive at `/ENBL2` ($D reads 0) and installs it as drive 2.
- **The image**: a second HPS slot, `S1` ("Mount External Floppy"),
  `VDNUM` 2; per slot `img_mounted`, `sd_lba`, `sd_rd`, `sd_ack`; the data
  bus shared (each loader takes `sd_buff_wr` only under its own `sd_ack`,
  as it does now). A second `se30_flp_loader` and a second
  `se30_flp_encoder` with their own track buffers - not shared, so a drive
  switch never rebuilds a track - at **word `$900000`** in SDRAM; the
  internal drive's stays at `$800000`. 2 MB each (a 1.44 MB DC42 with tags
  is under 1.5 MB); SCSI's images start at `$A00000` (3.3's map).
- **The disk port**: `se30_flp_dkmux` takes four requesters - the two
  loaders (writes), the two encoders (reads). With one drive the owner
  could follow `loading` (the loader and encoder never wanted the port at
  once); with two, drive 1's encoder can stream while drive 2's image
  loads. So the owner is chosen **round robin among the requesters, and
  changes only while the port is quiet** - the owner's request down and
  the controller's acknowledge down, the rule the mux keeps now. Every
  requester holds its request, address and data until acknowledged and
  raises the next only after the acknowledge falls (5.12.5), so a quiet
  clock comes between any two words and no requester can hold the port.
- **What stays one**: the SWIM (it already makes `/ENBL2`) and the SDRAM's
  disk port. The probe deck keeps `PSWM` and `PFLP` for the internal drive
  and gains **`PFL2`** for the external one: its loader and encoder as
  PFLP's, the drive's 16 bits as PSWM's low word, and the disk-port words
  its loader and encoder have moved (counters and status: a peek resets the
  machine, so these are what can be read during a read). The disk LED shows
  either drive's motor.

**The benches** (Daniel's standing rule: thorough, run to completion):
- `sim/flpmux` (new): the four-requester mux against a controller model -
  random request patterns, every requester's handshake (no request moved
  or dropped before its acknowledge, no acknowledge to a requester that
  does not own the port, each word's data and direction routed to and
  from its own requester), and fairness (no requester starved).
- `sim/gcrread`: both images mounted at once - both loaders through the
  mux together - Open finds both drives; the ROM's routines read drive 2
  (its own image) and drive 1 interleaved, every byte against its file.
- `sim/fdhd`, `sim/swim`, `sim/flpload`, `sim/flpenc`, `sim/sdram`: rerun
  (the units are unchanged; the loader and encoder take `BASE`).
- `sim/machine`: the machine with two drives, rerun.

**Daniel (2026-10-02): the board instead of the long gcrread runs.** The
drives are at an intermediate stage - read-only, GCR only (no 1.44 MB):
their job for now is to mount and read a disk, and the risk is low. The
board reads both disks in minutes, where the bit-level `sim/gcrread` costs
about 11 minutes a simulated second - with two drives, hours even at
`+quick`. The new part, the four-way mux, passed `sim/flpmux` (three
mutants caught); the unit benches and `sim/machine` passed; and a
`gcrread` run to cylinder 0 (stopped there, 2026-10-02) showed Open finding
both drives, both 800K images loading at once with the port passing
between the loaders, and both drives recalibrating. So: **the commit and
compile on those**; on the board Daniel mounts two 800K images, reads both
in the Finder, copies files between them and checks their contents; the
probe deck shows the external drive (`PFL2`). **The full two-drive
`gcrread` gate is deferred** to a later night as a regression, after its
real per-cylinder rate is measured - the one-drive figures in its run.sh
do not carry over, so it needs Daniel's go-ahead under the estimate rule.

**Compile 25 (2026-10-02, tag `d1873538`,
`output_files/MacSE30_d1873538_d1873538_drive2.rbf`), approved by Daniel**:
7e-4's fixes and the external drive, 30.5 minutes. `sta_corners.tcl`: the
design's worst slack over every corner 0.675 ns, the SDRAM capture met by
at least one of A and B at every corner - met; the flow's one failure is
the framework's HDMI clock, -0.016 ns at the slow -40C corner (as compiles
18 and 20). For the board: two 800K images, both read in the Finder, files
copied between them, `PFL2` on the probe deck.

**On the board (2026-10-02, Daniel): the two drives work.** The system
disk in one drive and TattleTech's in the other; TattleTech loaded and ran
from them. The probe deck, sampled while it loaded: the external drive
selected (`/ENBL2` low), its head stepping (cylinders 3, 20, 1 - settling,
spinning up), its encoder building each track and its port words
climbing; the internal drive's encoder following its head (27 to 70) and
the bytes the ROM took from the SWIM climbing; F-line 0, the bus errors
the Slot Manager's 255; `_Read` and `_GetResource` among the traps.

**The work.**
1. `se30_flp_dkmux.v` to four requesters; `sim/flpmux`.
2. `se30_machine.v`: the external drive and its disk interface; RD.
3. `MacSE30.sv`: `S1`, `VDNUM` 2, the second loader and encoder, the mux.
4. `sim/gcrread` for two drives; the full gate; the other benches.
5. 3.3's SDRAM map; then the compile (Daniel's go-ahead).

**The two-drive gate, run 2026-10-02/03 and STOPPED (Daniel: "We're not
running a test over two days").**
- **Result, cylinders 0-15 of both drives** (the first speed group):
  - 768 sectors, 0 bad, 0 errors, 0 bytes taken unread, 0 taken twice;
  - all 22 checks so far PASS: Open on both drives, the power-up,
    recalibrate to /TK0 on both, the ISM entry's GCR path, the VBL task's
    disk-in.
  - Progress saved in the session scratchpad as
    `gcrread_prog_20261003.txt`; `sim/gcrread`'s 2026-09-29 logs restored.
- **Why stopped.** Each cylinder now reads 48 sectors (two drives x two
  sides x 12): about 3.1 s simulated, about 32 minutes of wall time. The
  remaining 64 cylinders alone would have taken about 34 hours. My 10-12
  hour estimate came from the script header's single-drive figure: wrong
  by about 3x, and reported as an overrun.
- **The method from now on** is the MacPlus and LC floppy-write method,
  Daniel's (2026-10-03):
  1. **Fast unit benches**, per module and at every seam, byte-exact, in
     seconds.
  2. **Quartus analysis** as the elaboration check.
  3. **Hardware gates checked on the host:** `hfs_check`, a byte-exact
     `hfs_fork_diff` against the source, a 0xF6 census after a format, and
     the DC42 checksum recomputed.
  4. **Soaks on the board.**

  System-level runs like `gcrread` are for a localising job only, never a
  routine gate. The LC precedent: its 35-minute boot gate passed 16 times
  and never caught a regression. `gcrread`'s quick mode stays available
  for that job. SWIM rung 3 (writing) is to be gated this way.

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

# Section 7 - The ASC: a stub, until its section

Opened 2026-09-28 with rung 2 of the floppy (5.12.12 item 7) ready for its
compile. **Daniel: before the bitstream that reads a disk, a stub for the
Apple Sound Chip, so a booting System cannot hang on the missing sound
chip; "we will do more precise work when we actually implement the
ASC".** The real ASC (four voices, wavetables, the FIFOs playing, the Sony
sound chips) is its own section later.

## 7.1 What can hang, and what cannot

- **The ROM cannot.** Its `.Sound` driver (`$4082F02A`-`$4082F46C`, the
  base from `ASCBase`, `$CC0`) reads only the version register (`tst.b
  $800`: `$00` picks the original ASC's settings, `$4082F0B2`,
  `$4082F0F2`, `$4082F13A`) and the mode register it wrote (`$801`); it
  clears the FIFO by `bset`/`bclr #7,$803` and feeds the FIFO blind, 370
  bytes from a Time Manager task (`$4082F3FE`), with no status poll and no
  interrupt. The boot chime (`$40805E4A`) is software-timed (the machine bench's
  finding, 4.11 item 5). The machine has answered every ASC cycle since
  3.5: GLUE's 5-clock read and 4-clock write (2.11.3), every register `$00`
  (the version the ROM wants), `SNDINT*` idle.
- **A System can.** A Sound Manager that waits on the FIFO status (`$804`)
  for "half empty", or for the ASC's interrupt (VIA2 CB1, `SNDINT*`; the
  *Guide*, chapter 3, p. 95: the ASC interrupts "when the sound buffers
  are half empty and when they are completely empty"), would wait for ever
  on `$00` and an idle line.

## 7.2 Sources, and their standing

No Apple document of the ASC's registers was found (bitsavers
`/pdf/apple/mac/` and `ers/`, a web search, 2026-09-28: emulator code only).
The *Guide* (chapter 13, pp. 436-437) describes the chip's modes and its
2 KB of buffers, not its registers. So the stub's few facts are
**secondary, from MacLC's `rtl/asc.sv`** (Daniel's choice; itself MAME's
`asc_v8_device`, the V8's variant, and its earlier stub): `$804` bit 0 =
FIFO A half empty, bit 1 = FIFO A empty or full, bits 2-3 the same for
FIFO B; the interrupt raised at a sample tick while a FIFO is half empty,
cleared by a read of `$804` - raised every clock instead, it storms (MacLC's
finding). **Not lifted**: the V8's version `$E8` and its hardwired
readbacks; the SE/30's ROM branches on `$00`, the original ASC's, which is
this machine's (the *Guide*'s chapter 1 table of models: the SE/30 has
the ASC).

## 7.3 The stub (`rtl/se30_asc_stub.v`)

- `$800` reads `$00`; `$801`-`$80F` read back what was written (the ROM
  reads `$801` back); `$804` reads `$0F` - both FIFOs empty, which answers a
  wait for "half empty" and a wait on "empty or full" alike.
- Writes to the FIFOs (`$000`-`$7FF`) and the wavetable RAM are taken and
  dropped: no sound.
- `SNDINT*`: only while the mode register is 1 (FIFO mode), raised on a
  sample tick - every 704 C16M, 22,254.5 Hz, the Mac's rate - and cleared
  by a read of `$804`. In mode 0 (off) and 2 (wavetable: the boot chime)
  it never asserts.
- The window is GLUE's `asc_sel` ($50F14000, A11-A0 decoded); an access
  lands at the strobe on the C16M edge, as the VIA's and the SWIM's do
  (5.12.12 item 6).

## 7.4 The work

1. ~~Write this section.~~ **Done 2026-09-28.**
2. `sim/asc`, failing against an empty module, then the stub; the machine
   wiring (`dev_rdata`, VIA2 CB1); `sim/machine` unchanged.
   **Done 2026-09-28: 15 checks PASS; against an empty module 9 fail** (the
   6 that pass are what the machine already did: `$00`, `SNDINT*` idle).
   Mutants caught: the interrupt cleared by the wrong register (2 fail),
   raised every clock - the storm (2), the status `$0E` (3). Wired: GLUE's
   `asc_sel`, `dev_rdata`, VIA2 CB1, RESET* as the VIAs; `sim/machine` 17
   PASS; Analysis & Synthesis clean. (The RTL was written before its bench
   this once; the empty-module run restores the order of evidence.)

# Section 8 - The 68882

Opened 2026-09-28 by the first boot's stop (5.12.12 item 8). Plan 1.9 item
7 committed the 68882 as base-machine work "gated after first boot"; the
first boot has happened, and it is what stops it. **Daniel: build the 68882
as fully as possible now - "bypassing it will not exempt us from
implementing it at some point."**

## 8.1 Why the machine stops without it (the board, compile 21)

- `PFLN`: every F-line exception is **`$F280` at `$000131A4`** - `FNOP`
  (`FBF.W` with a zero displacement), in System code in RAM, some 30 times a
  second, each re-drawing the Welcome box.
- **This ROM declares an FPU unconditionally**: `$4080032A` writes `$DC00`
  to `HWCfgFlags` (`$B22`) in the start-up path - bit 12, `hwCbFPU`, among
  SCSI, the clock, the MMU and ADB - and nothing clears it (every access to
  `$B22` in the ROM: that write, bit tests, `bset #5` at `$4080DC88`). The
  ROM's one F-line vector swap (`$40803ACE`) guards a PMMU probe (`PMOVE
  TC`), not an FPU one. The ROM is the Mac II FDHD's, IIx's, IIcx's and
  SE/30's; all four shipped an FPU.
- The kernel behaves as a 68030 with no coprocessor: every FPU instruction
  (`$F2xx`, `$F3xx`) takes the F-line exception (vector 11) after the
  privilege check (MC68030 UM 6.5-6.6), the stacked PC the instruction's.
  An SE/30 with its 68882 removed would stop the same way.

## 8.2 Sources, and their standing

| Source | What it is | Standing |
|---|---|---|
| *MC68881/MC68882 Floating-Point Coprocessor User's Manual*, **2nd edition 1989** (NXP's `MC68881UM.pdf`, 9,440,147 bytes; `Docs\fpu\MC68881UM_NXP.pdf`, text alongside) | the programming model, data formats, instruction set, exception processing, the coprocessor interface, instruction timing, the state frames | **primary** |
| the same, **1st edition 1987** (bitsavers via the Internet Archive; `Docs\fpu\MC68881_MC68882_UM_1ed_1987.pdf`, 23,895,950 bytes, OCR text alongside) | as above | primary; for differences between the editions |
| *MC68882 Technical Data* **BR509/D Rev. 3** (Motorola, c. 1988; from Daniel 2026-09-29, `Docs\fpu\MC68882_datasheet_BR509_Rev3.pdf`, 3,923,506 bytes, text alongside) | the data sheet: signals, the DSACK table, AC timing for the 16.67-33.33 MHz grades (synchronous save/response CIR reads, 1.5-2.5 clocks); architecture text identical to the UM's; nothing on the algorithms, errata or masks. The CU is "special purpose hardware for high-speed conversion of **binary real** memory operands" - packed decimal is the APU's | primary for the pins and bus timing; its specs 8 and 8A "replace the old specifications", so **compare its AC table with UM Section 12 at item 7** |
| *MC68030 UM* 3ed, section 10 (coprocessor interface) | how the 030 and the 68882 converse; what software can and cannot see of it | primary |
| IIcx BOM, line 291 | **`337S6510` "IC,MICRO,68882,16MHZ,68P"** (21 Sep 1988) - the nearest paper for the SE/30's part: a 16 MHz 68882, PLCC; the mask is not stated | primary for the part and speed |
| *Guide* 2e, Table 3-6 and p. 107 | the SE/30 has an MC68882 as standard | primary |
| **Errata**: none found (bitsavers, a web search, 2026-09-28; the only bug lists are emulators', e.g. Musashi's `m68kfpu.c`) | - | so, by the fidelity rule, **tier 2: build to the manual**; its stated accuracy bounds are the spec for the transcendentals |
| upstream's FPU, `030_mmu2_fpu2` (`9e9a36a..bd9d8f1`, 22-23 May 2026) | nine `TG68K_FPU*.vhd` files (~9,100 lines) and ~1,270 kernel lines, ~150 in `TG68K_Pack.vhd` | **donor**, a first draft (1.12): its benches are modelled on WinUAE, its transcendentals compiled out, its tip "Perhaps this will fix it" |
| WinUAE's `cputest` 6888x corpus | test vectors whose **expected results are generated by WinUAE's own CPU core**; real hardware is the device under test, not the source (`cputest/readme.txt`: "All the CPU logic comes from UAE CPU core"). Its FPU part is incomplete by its own account ("FPU support also isn't fully implemented yet"; FSAVE/FRESTORE untested) | **a regression check against WinUAE's model, not silicon evidence** - corrected 2026-09-29 (8.6.15); it was listed here as "silicon-derived" |
| `mattuna15/68881-fpga` (GitHub, MIT; seen 2026-09-29 at Daniel's question, README only) | a VHDL 68881/68882: full instruction set, a DSP multiplier and FPSP-derived polynomials; ~60,000 LUTs on an Artix-7 (only a no-trig "lite" mode fits a DE10-Nano); mpmath golden vectors; its README quotes the 68882 idle frame as `$0038` (the manual's is `$1F38`). Its `validation/` has a KiCad board putting a **real MC68881FN** beside the FPGA - no recorded results seen | not a donor (area, architecture); **a possible source of silicon evidence for 8.6.14** if its board's results are ever published - the 68881 shares the 68882's arithmetic unit |
| Motorola's **68040 FPSP** (Linux `arch/m68k/fpsp040`, "Copyright (C) Motorola, Inc. 1990"; `decbin`/`bindec`/`binstr`/`get_op`/`res_func`/`smovecr` read 2026-09-29) | the 68040's software emulation of what it lacks from the 68881/882: FMOVE.P ("a value in 68881/882 format"; "see the 68882 manual for examples"), FMOVECR with its constant tables, the transcendentals | **Motorola's statement of an algorithm, a lead - not silicon**; the model's decimal conversions follow it (8.7.2); its constant tables corroborate 8.6.14 item 19 and err at 10^2048 (item 23) |
| WinUAE's `fpp.cpp` (tip `d42db95`, 2026-09-27) and MAME's `m68kfpu.cpp` | emulators; WinUAE's carries 6888x specifics that look measured (8.6.15) | **cross-checks and leads only**, cited where the manual is silent, never where it speaks |

**The state frames** (manual 5.2.1 Table 5-8, 6.4.2, Figures 6-4 and 6-5),
the part of the chip software reads to tell 68881 from 68882: null 4 bytes
(format `$00`), **idle 60 bytes (size byte `$38`), busy 216 (`$D4`)** -
the 68881's 28 and 184 plus 32 bytes of the conversion unit's state at the
top of the frame. The manual's own test is `CMPI #$18,D0 ; MC68881?`.

## 8.3 The approach - decided 2026-09-28: the 68882's own architecture

**Daniel: "Absolutely do the microcoded FPU. Also, aim for optimisation
while maintaining authenticity, as the microcoded FPU would. Some things
can be left out if necessary, like support for DC42 diskettes."**

**The chip as the manual describes it** (1.2, 3.x, 8.x): a bus interface
unit; on the 68882 a conversion unit (CU) that converts operands to the
internal extended format while the arithmetic unit is busy; and the
arithmetic processing unit (APU) - "a high-speed 67-bit arithmetic unit
used for both mantissa and exponent calculations, a barrel shifter that can
shift from 1 bit to 67 bits", a two-level microcoded sequencer with its
microcode ROM, and a constant ROM. There is no transcendental hardware: the
transcendentals are microcode on the one datapath, which is why the timing
table gives about 35-56 clocks for FADD, 55-76 FMUL, 87-108 FDIV, 89-110
FSQRT and 385-530 for FATAN, FETOX, FLOGN, FSINCOS and FTAN. Their accuracy
is the manual's (3.x): worst case one unit in the last place of double
precision, typically about 64 in extended - by the fidelity rule, the spec.

**So we build that**: one 67-bit datapath (adder/subtractor, a 67-bit
barrel shifter, a multiplier of a few DSP blocks over several cycles -
*superseded 2026-09-29, 8.8.7: the timing tables show a radix-8
shift-and-add on the ALU*), a
microcoded sequencer with **the microcode and the constants in block RAM**
(we use 39% of it), the CU, the register file, and the state frames as the
manual gives them. Every instruction is microcode, the transcendentals
included; their algorithms (Motorola's are unpublished) are chosen to meet
the manual's error bounds and, where they can, its cycle counts, and are
proven first in a **Python reference model** at high precision - the test
oracle the microcode must match bit for bit. Estimated 3,000-5,000 ALMs
against the donor's ~9,400; the saving is structural, and the first
synthesis replaces the estimate.

**Why area rules here**: the Quadra 800 core
(`C:/Git/MiSTer-devel/MacQuadra800_MiSTer`, its `RESUME-*` notes) fits a 68040 with its FPU, caches, SCSI, CD-ROM, Ethernet and
sound in 38,329 ALMs, timing-clean, and its fits at 39,000-41,000 failed
routing with the LABs full - the practical ceiling on this part is about
38,000-39,000, not 41,910. The complete SE/30 estimates at ~34,000 with
this FPU (~37,000 with a CD-ROM target of the Quadra's size), and ~39,000
without CD-ROM with the donor's. Its first lesson - arrays silently built
as registers (its first fit was 143%) - was checked on compile 21: every
array in our design is block RAM; the CPU holds none (its 11,586 ALMs are
the kernel 4,782, the ALU 1,834, the PMMU 4,829 with 3,278 registers - the
PMMU's 22-entry ATC data, not its tags, could move to block RAM as the
Quadra's does, behaviour unchanged, if a later fit needs it).

**The donor** stays a reference for the kernel's side - how an F-line
instruction reaches the FPU, the `FSAVE`/`FRESTORE`/`FMOVEM` memory
transfers - read against the manual before anything is taken; its decoder
is already known to differ from the manual in three ways (8.5).

## 8.4 The work

1. ~~Write this section.~~ **Done 2026-09-28.**
2. **Area first**: a standalone Quartus synthesis of the donor FPU with its
   transcendentals enabled. The machine uses 55% of the logic (23,028 of
   41,910 ALMs), 36% of the DSP blocks, 39% of the RAM blocks - it likely
   fits, and the transcendental unit is the unknown.
   **Done 2026-09-28** (a scratch `quartus_map` of the donor's nine files
   and its package, top `TG68K_FPU`, both generics 1, every port a virtual
   pin): **9,364 ALMs estimated** - 13,523 ALUTs, 4,473 registers, 8 DSP
   blocks, no block RAM. By unit: the top (control, decode, the register
   file) 4,291 ALUTs; the arithmetic unit 4,406 (no DSP: its multiply is
   logic); the transcendental unit 4,524, 8 DSP, two inferred dividers
   (683 ALUTs); the rest ~300. With the machine, **about 32,400 of 41,910
   (77%)**: it fits; the fit and its timing will be tighter, and the first
   integrated fit gives the real figure.
3. ~~Audit the donor and merge it forward~~ - **superseded 2026-09-28 by
   8.3's decision**: the FPU is ours, from the manual. What was read of the
   donor is kept as findings (8.5); its kernel hooks are still read before
   ours are written.
4. **The specification, from the manual**, before any code: the programming
   model (the registers, FPCR/FPSR/FPIAR bit by bit), the data formats and
   their conversions, the instruction set with every encoding and which are
   undefined, the exceptions (vectors 48-54, their priorities, what each
   sets), the state frames, the conditionals, and what the MPU's side of the
   coprocessor interface does that software can see (the kernel, 7.x).
   **Done 2026-09-28: 8.6**, from the whole of UM Sections 1-8 (tables and
   figures read from the page images) and 030 UM Section 10. It adds three
   things the plan did not know: **concurrency is software-visible**, not
   only in timing (8.6.1 - item 6's first decision); the CIRs are reachable
   with `MOVES` (8.6.12); and **the manual is silent or self-contradictory
   in 17 places** (8.6.14; what WinUAE and MAME say, 8.6.15) - FATANH(±1)'s sign, FLOGNP1(-1), the redundant
   opmodes and the `FMOVECR` constants among them - which need silicon
   evidence or Daniel's call before the model encodes them.
5. **The Python reference model** (`tools/fpu_model/`): the 67-bit internal
   arithmetic and rounding exactly, the conversions, packed decimal, and the
   transcendental algorithms, each checked against a high-precision library
   within the manual's bounds. It is the oracle for everything after.
   **Started 2026-09-29: 8.7** (design, switches, and 5a - the exact
   arithmetic, rounding, FPSR, traps and FMOVECR - built and checked,
   8.7.1); 5b packed decimal (8.7.2), 5c the transcendentals (8.7.3) and
   5d the test vectors (8.7.4) done the same day. **Item 5 complete
   2026-09-29.**
6. **The architecture and its microcode**: the datapath, the sequencer's
   microinstruction format, the microcode assembler (a small script that
   builds the block RAM image), the CU, the register file; area and cycle
   budgets per instruction from the manual's table.
7. **The RTL and the benches**, failing first: `sim/fpu` driven by the
   model's vectors (arithmetic, rounding modes, every data format, the
   exceptions, `FSAVE`/`FRESTORE` and the frames, `FMOVEM`, the
   conditionals) and WinUAE's `cputest` 6888x corpus as a second check -
   **a regression against WinUAE's model, not silicon** (8.6.15); a
   mismatch is a question to settle from the manual or hardware, not a
   verdict; then the kernel integration, `sim/busfault` and `sim/machine`
   unchanged. **Started 2026-09-29: 8.9** (staged 7a-7e; 7a and 7b done).
8. The compile, the fit's area against the budget, and the board: past the
   Welcome box - the first instruction is `FNOP` at `$000131A4`.

## 8.5 The donor, as far as it was read (2026-09-28)

Its instruction decoder (`TG68K_FPU_Decoder.vhd`, which steers the whole
FPU's control through `decoder_instruction_type`) differs from the manual
three ways: it executes operation-word types `110` and `111` as moves,
which the manual (4.7) lists "(Undefined, Reserved)" - all data movement is
the general type `000`, told apart by the command word's opclass (Table
4-11); it treats `FMOVE` of the control registers as privileged, where
"FSAVE and FRESTORE ... are privileged instructions; all others are
nonprivileged" (6.x) - and its privilege output is unconnected; and it finds
`FMOVEM` by two particular first-word patterns ("AmigaOS FMOVEM") rather
than by the opclass. Its `FSAVE` writes the frame's first longword as
`fsave_frame_format & X"000000"` - `$60000000` for an idle frame,
`$D8000000` for a busy one - where the manual's format word carries the
version number in its upper byte and the frame's size in its lower, `$38`
idle and `$D4` busy (6.4.2, Figure 6-5): the donor's size byte is zero,
and its version byte is the frame's length. (The lengths it transfers, 60
and 216 bytes, are the manual's.) Its comments cite WinUAE's decode table,
not the manual.

## 8.6 The specification, from the manual (8.4 item 4)

Written 2026-09-28 from a full reading of the *MC68881/MC68882 User's
Manual*, 2nd edition (1989), Sections 1-8, with every table and figure
the OCR garbles read from the page images, and the *MC68030 User's
Manual* 3ed, Section 10, for the main processor's side. Citations: **UM
p. n-m** or **UM x.y** for the 68881/68882 manual; **030 UM 10.x** for the
68030's; **Guide p. n** for the *Guide* 2e. Where this section and the
manual disagree, the manual wins and this section is wrong. Where the
manual disagrees with itself, or is silent, 8.6.14 says so and nothing
is decided until the evidence or Daniel does.

**Reading the scans.** The NXP scan prints many `+` signs so thinly that
they read as `-` (the FDIV, FMUL, FETOX and FLOGNP1 operation tables in
particular). Where a table's sign cannot be read, this section gives the
sign the IEEE rules require and says so; the 1st edition (1987) is the
second scan to check against, and it agrees wherever it was consulted
(FLOGNP1, the format words).

### 8.6.1 What software can see

The 68882 is a separate chip that software reaches in exactly three ways,
and the specification is everything visible through them:

1. **The instructions** (8.6.7-8.6.9): their results, the FPSR bits they
   set, the exceptions they raise, and which stack frame and PC those
   exceptions carry.
2. **The state frames** that `FSAVE` writes (8.6.11): their sizes, their
   format words, and the fields handlers are told to read and change - the
   exceptional operand, the operand register image, the command/condition
   image and the BIU flags (bit 27 above all).
3. **The coprocessor interface registers**, which a supervisor program can
   read and write directly with `MOVES` in CPU space - the manual's own
   protocol-violation handler reads the response CIR with `MOVES.W
   $00022000,D0` (UM 6.1.12). So the CIRs' behaviour under an unexpected
   access (reserved registers read all ones, a write to the register select
   CIR is a protocol violation, ...) is software-visible too (8.6.12).

**Concurrency is visible, not only in timing.** The 68882 runs a second
instruction in its conversion unit (CU) while the first is in the
arithmetic unit (APU) (UM 5.1.1.2). Software sees that as: an exception
from the first instruction reported *by the second* as a **mid-instruction**
exception (frame format `$9`, the second instruction's PC; UM 6.1, 7.4.2.6);
**busy** versus **idle** frames from an `FSAVE` taken mid-flight (Table
6-5); and the handler rules of 5.2.2 (the `BSET` of `EXC_PEND`), which exist
only because the CU may hold a half-done instruction. Whether our chip
models the CU's overlap, or runs one instruction at a time and never shows
a mid-instruction report from a previous instruction, is the first
decision of item 6; both are "a 68882" to software that follows the
manual's rules, and only the first is the 68882's timing.

### 8.6.2 The programming model (UM Section 2, Figures 1-1 to 1-6)

**FP0-FP7**: eight 80-bit extended-precision registers. They hold any bit
pattern (`FMOVEM` and `FRESTORE` load without checking, UM 4-74), but no
operation creates an unnormalized value (UM 3.2.2 note).

**FPCR** (32 bits; bits 31-16 read zero and ignore writes, UM 2.2):

| bits | field | |
|---|---|---|
| 15 | BSUN enable | exception enable byte, same positions as the EXC byte; a write that enables a class never traps on an exception already recorded (UM 2.2.1) |
| 14 | SNAN | |
| 13 | OPERR | |
| 12 | OVFL | |
| 11 | UNFL | |
| 10 | DZ | |
| 9 | INEX2 | |
| 8 | INEX1 | |
| 7-6 | PREC | 00 extended, 01 single, 10 double, 11 undefined/reserved |
| 5-4 | RND | 00 to nearest, 01 toward zero, 10 toward minus infinity, 11 toward plus infinity |
| 3-0 | - | not defined in Figures 1-3 or 2-3; "unimplemented bits of a control register are read as zeros and are ignored during writes" (UM 4-70) |

**FPSR** (32 bits; "all bits ... can be read or written by the user", UM
2.3; unimplemented bits read zero, UM 4-70):

| bits | byte | |
|---|---|---|
| 31-28 | condition code | 0 |
| 27, 26, 25, 24 | | **N**, **Z**, **I** (infinity), **NAN** |
| 23 | quotient | sign of the quotient (the XOR of the operand signs) |
| 22-16 | | the seven least significant bits of the quotient, unsigned; set by `FMOD` and `FREM` only, kept until the next of those or a user write (UM 2.3.2) |
| 15-8 | exception status (EXC) | BSUN, SNAN, OPERR, OVFL, UNFL, DZ, INEX2, INEX1 (same bits as the enable byte) |
| 7-3 | accrued exception (AEXC) | **IOP**, **OVFL**, **UNFL**, **DZ**, **INEX** (Figure 2-7, read from the image) |
| 2-0 | | 0 |

- **FPCC** takes only the eight combinations of Table 2-1 - `0000` +
  normalized or denormalized, `1000` -, `0100` +0, `1100` -0, `0010` +inf,
  `1010` -inf, `0001` +NaN, `1001` -NaN (N Z I NAN). A user write can load
  the other eight; the conditionals then evaluate their equations on the
  bits as written, "an unexpected branch condition" (UM 2.3.1).
- **EXC** is cleared at the start of every instruction except `FMOVEM` and
  `FMOVE` to/from a control register, which cannot raise exceptions and
  leave it alone (UM 2.3.3). A user write that sets EXC bits never traps.
- **AEXC** is ORed at the end of every instruction that clears EXC (UM
  2.3.4, 6.1.10): `IOP |= BSUN|SNAN|OPERR`, `OVFL |= OVFL`, **`UNFL |=
  UNFL & INEX2`**, `DZ |= DZ`, **`INEX |= INEX1|INEX2|OVFL`**. Only a user
  write, a reset or a null `FRESTORE` clears it.

**FPIAR** (32 bits): loaded with the address of an instruction's F-line
word, passed by the MPU when the FPU asks for it (8.6.12), "before the
instruction is executed (unless all arithmetic exceptions are disabled)"
(UM 2.4). `FMOVE` to/from a control register and `FMOVEM` never change it,
so a handler can read it undisturbed.

**Reset** - the hardware reset, and an `FRESTORE` of a null frame, which is
the same thing (UM 4-88): FP0-FP7 = positive nonsignaling NaNs; FPCR,
FPSR, FPIAR = 0; the next `FSAVE` returns a null frame (UM 6.4.2.1). The
manual does not give the NaN's bit pattern; a NaN the chip creates has an
all-ones mantissa (UM 3.2.5), so the default here is `$7FFF` /
`$FFFFFFFF FFFFFFFF` (8.6.14 item 8). **The `RESET` instruction does not
reset the FPU** - "the coprocessor should be affected by external reset
signals only" (030 UM 10.5.3).

### 8.6.3 The data formats (UM Section 3)

| format | size | in `<ea>` | notes |
|---|---|---|---|
| B, W, L | 1, 2, 4 | data modes (Dn allowed) | two's complement; converted exactly to extended |
| S | 4 | data modes (Dn allowed) | IEEE single, bias 127 |
| D | 8 | memory modes only | IEEE double, bias 1023 |
| X | 12 | memory modes only | 96 bits: sign, 15-bit exponent (bias 16383), **16 unused bits (don't care in, zero out)**, 64-bit mantissa with **explicit integer bit** |
| P | 12 | memory modes only | packed BCD, below |

**The extended format's corners** (Table 3-3, image; 3.2.2-3.2.5):
- exponent 0 with integer bit 1 is a **normalized** number (the
  "pseudo-denormal"); underflow is *not* detected for a result whose
  exponent is exactly the extended minimum (UM 6-11 footnote);
- exponent 0, integer bit 0, fraction nonzero: denormalized;
- exponent 0, mantissa 0: zero;
- exponent nonzero and below `$7FFF`, integer bit 0: **unnormalized** -
  normalized before use; an unnormalized zero (mantissa 0) becomes a true
  zero (UM 3.5.1);
- exponent `$7FFF`: the integer bit is a don't-care; fraction (bits 62-0)
  zero = infinity, nonzero = NaN; **bit 62 = 0 is a signaling NaN**.

**Conversion in** (UM 3.5.1): every external operand becomes extended;
denormalized S/D/X inputs are normalized; an extended denormal loaded into
a register by `FMOVE` "is first normalized and then denormalized", so it
stays denormal. Packed input rounds to extended **regardless of PREC**,
by RND, and sets INEX1 if inexact (UM 6.1.8).

**Packed decimal** (Table 3-4 and Figure 3-11, images). Word 5 (bits
95-80): **SM** (15), **SE** (14), **YY** (13-12, ones only for infinity and
NaN), three exponent digits (11-0). Word 4: **EXP3** (15-12, output only),
don't-cares (11-4, written zero), the integer digit (3-0). Words 3-0: 16
fraction digits.
- ±infinity: SE = YY = 1, exponent `$FFF`, fraction 0; **NaN**: the same
  with a nonzero fraction, and the 64 fraction bits move "bit-for-bit into
  the extended precision mantissa" with no conversion (so MANT15's MSB is
  a don't-care and its next bit the SNaN bit);
- zero: integer and fraction digits 0, any exponent `$000-$999`; a
  non-decimal digit in a zero's exponent still gives a true zero;
- in range: non-decimal digits in an in-range string are **not detected**
  and "converted to binary in the same manner as decimal digits" -
  repeatable nonsense, and a case the model must reproduce, not reject;
- in-range decimal strings always convert to normalized extended numbers.

**Conversion out** rounds to the destination format by RND (PREC is
ignored for memory, UM 2.2.2). Integers: an out-of-range value or an
infinity is an **operand error**, not an overflow; the result is the
largest positive or negative integer of the size; a NaN stores the top
8/16/32 bits of its significand (with OPERR for a nonsignaling NaN, Table
6-2; with the SNaN bit set and SNAN for a signaling one, UM 6.1.2); a
value too small **underflows to zero with no exception** (UM 6.1.5).
Packed output: 8.6.6.

**The intermediate result** (Figure 6-2, image): a **17-bit two's-complement
exponent** and a mantissa of overflow bit, integer bit, 63-bit fraction,
**guard, round and sticky** - the "67-bit" arithmetic. Guard and round are
exact; sticky is the OR of every bit below them (UM 6.1.7).

### 8.6.4 Rounding, range, underflow and overflow (UM 4.5.5, 6.1.4-6.1.7)

Every arithmetic result, `FMOVE` included, goes through the same
post-processing, in this order: **underflow check, round, overflow
check** (UM 4.5.5.2).

- **The rounding boundary** is PREC for a register destination (64, 24 or
  53 mantissa bits; the bits below are zero afterwards) and the format for
  a memory destination. **Range control**: in single or double PREC the
  *exponent* is also held to that format's range, the result being stored
  as extended (UM 6-16 note).
- **Rounding** (Figure 6-3): exact if G, R and S are 0 (INEX2 clear);
  otherwise INEX2, and RN adds one to the LSB if G = 1 and (R|S|LSB) = 1,
  RZ chops, RM adds one if negative, RP adds one if positive; a carry out
  shifts right and increments the exponent.
- **Underflow** (UNFL in EXC): a register result whose intermediate
  exponent is at or below the PREC format's minimum (not at extended's own
  minimum, above), or a memory result at or below the destination
  format's. Only S, D and X destinations underflow (P: operand error; B,
  W, L: zero, silently). The result is denormalized - shifted right to the
  minimum exponent, then rounded; if everything shifts out: RN and RZ give
  a signed zero; RM gives +0, or for a negative result the smallest
  negative denormal; RP gives the smallest positive denormal, or -0.
  **EXC.UNFL means "tiny"; AEXC.UNFL means tiny and inexact** (UM 6-13).
- **Overflow** (OVFL): exponent at or above the PREC (or destination)
  format's maximum after rounding; S, D and X only (B, W, L, P: operand
  error). RN gives a signed infinity; RZ the largest magnitude of the
  sign; RM +largest or -infinity; RP +infinity or -largest.
- **`FSGLMUL` and `FSGLDIV`** ignore PREC but use RND; they take their
  inputs' mantissas **truncated to 23 bits** unchecked (UM 4-17, "each
  mantissa is truncated to 23 bits"; UM 4-98 says 24 - 8.6.14 item 9),
  round the result's mantissa to single, and keep the **extended exponent
  range** for underflow and overflow, so they overflow or underflow only
  where extended would.
- **Traps**: the result written is the same whether the trap is enabled
  or not, **except** that for a register destination an enabled SNAN,
  OPERR or DZ trap **leaves the register unchanged** (UM 6.1.2, 6.1.3,
  6.1.6). OVFL, UNFL and INEX write their default result either way.
- **The inexact trap** is taken when `[(EXC.OVFL | EXC.INEX2) &
  EN.INEX2] | [EXC.INEX1 & EN.INEX1]` (UM 6.1.10) - so an overflow with
  its own trap disabled takes the inexact trap.

### 8.6.5 NaNs (UM 4.5.4, 6.1.2)

- One NaN operand: the result is that NaN. **Two nonsignaling NaNs: the
  destination's.**
- A signaling NaN sets **SNAN**; trap enabled and a register destination:
  the register is not modified; otherwise the NaN is made nonsignaling
  (bit 62 set, nothing else changed - "truncated if necessary" for a
  narrower format) and processing continues as above.
- A NaN the chip creates (an invalid operation) has an **all-ones
  mantissa**; the chip never creates a signaling NaN. Only `FMOVEM` (and
  `FRESTORE`) can put one in a register.
- `FMOVEM`, `FMOVE` of a control register, and `FSAVE` never touch the
  status, so they move SNaNs harmlessly.

### 8.6.6 Decimal conversions and packed output (UM 4.3.3, 4-66 to 4-69)

- **k-factor**, 7 bits two's complement, static in the command word or
  dynamic in the low 7 bits of a data register (the upper 25 ignored):
  **-64 to 0** = digits to the right of the decimal point (FORTRAN F);
  **+1 to +17** = significant digits (FORTRAN E); **+18 to +63** = OPERR,
  treated as +17. The manual's examples for +12345.678765 are a test
  vector: k = -5 `+1.234567877E+4`, -3 `+1.2345679E+4`, -1 `+1.23457E+4`,
  0 `+1.2346E+4`, +1 `+1.E+4`, +3 `+1.23E+4`, +5 `+1.2346E+4`.
- **A decimal exponent above 999** in magnitude: OPERR, the three low
  digits in the exponent field and the fourth in **EXP3**.
- **Accuracy**: 0.97 of a unit in the last digit (RN) or 1.47 (other
  modes), **for values in double's range**; beyond it "significantly
  larger" (software is expected to handle those). The conversions use the
  constant ROM's powers of ten, so exact powers of ten convert exactly.
  This is the bound the model's decimal conversion must meet; it is not
  bit-exactness with silicon (8.6.14 item 14).

### 8.6.7 The instruction encodings (UM 4.7-4.8, Tables 4-11 to 4-22)

**Operation word**: `1111 ccc ttt eeeeee` - `ccc` the coprocessor ID, `ttt`
the type, `eeeeee` type-dependent. **The 68882 is ID 1**; the 68030 keeps ID
0 for its PMMU (type 000) and treats any other ID-0 word as unimplemented
(030 UM 10.1.3; UM 4.8.1).

| type | instruction | who decodes |
|---|---|---|
| 000 | general: arithmetic, `FMOVE`, `FMOVECR`, `FMOVEM` (command word follows) | FPU (command word) |
| 001 | `FScc`, `FDBcc`, `FTRAPcc` (by bits 5-0, below) | MPU, then FPU (predicate) |
| 010 | `FBcc.W` | MPU, then FPU |
| 011 | `FBcc.L` | MPU, then FPU |
| 100 | `FSAVE` | MPU |
| 101 | `FRESTORE` | MPU |
| 110, 111 | undefined: **F-line with no coprocessor access at all** (030 UM 10.5.2.2) | MPU |

**The command word** (type 000): `ooo xxx yyy eeeeeee`, opclass in bits
15-13 (Table 4-11):

| opclass | RX (12-10) | RY (9-7) | extension (6-0) | instruction |
|---|---|---|---|---|
| 000 | source FPm | destination FPn | opmode | register to register |
| 001 | | | | **undefined: F-line** (UM 4.7.1.7) |
| 010 | source format 000-110 | destination FPn | opmode | `<ea>` to register |
| 010 | **111** | destination FPn | ROM offset | `FMOVECR` |
| 011 | destination format | source FPm | k-factor / `rrr0000` / 0 | `FMOVE` register to `<ea>` |
| 100 | FPcr list | 000 | 0 | `FMOVE(M)` `<ea>` to control registers |
| 101 | FPcr list | 000 | 0 | `FMOVE(M)` control registers to `<ea>` |
| 110 | `dr`=0, mode (12-11), 0 | | mask / `0rrr0000` | `FMOVEM` `<ea>` to FPn (bits 12-8 = `0mm00`) |
| 111 | `dr`=1 | | | `FMOVEM` FPn to `<ea>` |

(For opclass 11x the manual draws the word as `1 1 dr mode(2) 0 0 0
list(8)`: bit 13 is dr, bits 12-11 the mode, 10-8 zero.)

**Source/destination formats** (Tables 4-14, 4-15): `000` L, `001` S,
`010` X, `011` P (out: static k), `100` W, `101` D, `110` B, `111` (out
only) P with dynamic k. A register-to-register operation with RX = RY
takes its input from and writes its result to that one register. The
operation word's EA field "should be all zeros" when unused; **no F-line
if it is not** (UM 4-126), and likewise for the command-word fields the
manual calls "should be zero" (bits 9-0 of opclass 10x, the extension of
a non-packed opclass 011, bits 3-0 of a dynamic k).

**Opmodes** (the extension field, Table 4-13, image):

| | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| `$00` | FMOVE | FINT | FSINH | FINTRZ | FSQRT | *redundant* | FLOGNP1 | *redundant* |
| `$08` | FETOXM1 | FTANH | FATAN | *redundant* | FASIN | FATANH | FSIN | FTAN |
| `$10` | FETOX | FTWOTOX | FTENTOX | *redundant* | FLOGN | FLOG10 | FLOG2 | *redundant* |
| `$18` | FABS | FCOSH | FNEG | *redundant* | FACOS | FCOS | FGETEXP | FGETMAN |
| `$20` | FDIV | FMOD | FADD | FMUL | FSGLDIV | FREM | FSCALE | FSGLMUL |
| `$28` | FSUB | *redundant* ... | | | | | | `$2F` |
| `$30` | FSINCOS (FPc = bits 2-0) ... | | | | | | | `$37` |
| `$38` | FCMP | *redundant* | FTST | *redundant* ... | | | | `$3F` |
| `$40-$7F` | **undefined: F-line** (take pre-instruction exception, vector 11) | | | | | | | |

"Redundant" (Table 4-13 note 3: `$05, $07, $0B, $13, $17, $1B, $29-$2F,
$39, $3B-$3F`): "unspecified, are redundant with valid instructions ... and
do not cause an F-line exception if executed". Which instruction each one
duplicates is not stated - 8.6.14 item 6.

**`FMOVE(M)` of the control registers** (Table 4-17): the list is FPCR
(bit 12), FPSR (11), FPIAR (10); several are moved in that fixed order at
ascending addresses. Sizes 4, 8, 12. **List 000 is "undefined, reserved"
but on the current chip redundant with 001 - it moves FPIAR.** Addressing
(images, 4-70/71 and 4-79): one register may use Dn; **FPIAR alone may use
An**; several need memory modes; immediate is allowed for loads (one
register: `#` of 4 bytes; several: 8 or 12). Predecrement subtracts the
whole size first, then transfers ascending; postincrement adds it after.
These restrictions are enforced by the MPU against the primitive (8.6.12);
an EA that disagrees with the command word "may produce unexpected results
... the register transfer ... reversed" but never harms the system (UM
4-132 note).

**`FMOVEM` of the data registers** (Table 4-18, 4-74 to 4-79): the mode
bits 12-11 are `x0` static list (bits 7-0 of the command word), `x1`
dynamic (the data register in bits 6-4, its low 8 bits the list); `0x` for
predecrement, `1x` for control and postincrement. **The list is scanned
from its MSB**: for `-(An)` bit 7 = FP7 ... bit 0 = FP0; for the others bit
7 = FP0 ... bit 0 = FP7 - so FP0 is always at the lowest address. Each
register is 12 bytes, moved as is (no conversion, no rounding, FPSR and
FPIAR untouched, no pending exception reported). Loads: control modes or
`(An)+`; stores: control alterable or `-(An)`. **dr = 0 with a
predecrement mode (`00`/`01`) is "invalid"**: the registers move in the
predecrement order and the MPU does not allow the `-(An)` mode for a load,
so an assembler never produces it (Table 4-18 note 1).

**`FDBcc`, `FScc`, `FTRAPcc`** (type 001; Table 4-19 by bits 5-0 of the
operation word; the second word holds the predicate in bits 5-0, bits 15-6
zero without an F-line if not): `000rrr` FScc Dn; `001rrr` FDBcc Dn
(then a 16-bit displacement); `010rrr`-`110rrr` FScc to memory; `111010`
FTRAPcc.W, `111011` FTRAPcc.L, `111100` FTRAPcc with no operand; `111000`,
`111001` FScc to `(xxx).W`/`(xxx).L` per the FScc page (4-97) and the 030
UM (Table 4-19 calls them undefined - 8.6.14 item 12); `111101`-`111111`
undefined (MPU F-line).

**`FBcc`**: type 010 (16-bit displacement) or 011 (32-bit); the predicate
in bits 5-0 of the operation word (the MPU writes the whole word to the
condition CIR); the displacement is relative to **the address of the
displacement word**. **`FNOP` is `FBF.W` with displacement 0: `$F280
$0000`** - the instruction at `$000131A4` (8.1).

**`FSAVE`** `$F300|ea` - `-(An)` or control alterable. **`FRESTORE`**
`$F340|ea` - `(An)+` or control. Both are **privileged**; **every other
FPU instruction, `FMOVE` of the control registers included, is not** (UM
6.2.7).

### 8.6.8 The instructions (UM 4.6, pp. 4-18 to 4-124)

**Every arithmetic instruction** converts its source to extended, clears
EXC, computes, post-processes (8.6.4), sets FPCC from the result's data
type (Table 2-1), and updates AEXC. **INEX1** is set only for a packed
source (UM 6.1.8); **SNAN** per 8.6.5; BSUN is always cleared. "Range"
below means a normalized or denormalized input; "EXC" lists the bits the
instruction can set beyond SNAN and INEX1; a bit not listed is cleared.

**Monadic** - `F<op>.<fmt> <ea>,FPn`, `F<op>.X FPm,FPn`, `F<op>.X FPn`:

| op | | ±0 | ±inf | other special inputs | EXC | UM |
|---|---|---|---|---|---|---|
| `$00` | FMOVE | ±0 | ±inf | - | UNFL (only for an extended denormal source), INEX2 (L, D, X by PREC) | 4-64 |
| `$01` | FINT | ±0 | ±inf | rounds to an integer by RND | INEX2 | 4-50 |
| `$03` | FINTRZ | ±0 | ±inf | rounds toward zero, whatever RND | INEX2 | 4-52 |
| `$02` | FSINH | ±0 | ±inf | | OVFL, UNFL, INEX2 | 4-107 |
| `$04` | FSQRT | ±0 | +inf; -inf: NaN, OPERR | x < 0: NaN, OPERR | OPERR, INEX2 | 4-109 |
| `$06` | FLOGNP1 | ±0 | +inf; -inf: NaN, OPERR | **x = -1: NaN and DZ** (both editions); x < -1: NaN, OPERR | OPERR, DZ, UNFL, INEX2 | 4-60 |
| `$08` | FETOXM1 | ±0 | +inf; -inf: -1.0 | | OVFL, UNFL, INEX2 | 4-44 |
| `$09` | FTANH | ±0 | ±1.0 | | UNFL, INEX2 | 4-115 |
| `$0A` | FATAN | ±0 | ±π/2 | | UNFL, INEX2 | 4-26 |
| `$0C` | FASIN | ±0 | NaN, OPERR | \|x\| > 1: NaN, OPERR; result in [-π/2, π/2] | OPERR, INEX2 (UNFL cleared) | 4-24 |
| `$0D` | FATANH | ±0 | NaN, OPERR | \|x\| > 1: NaN, OPERR; **x = +1: -inf, x = -1: +inf, DZ** (as printed - 8.6.14 item 1) | OPERR, DZ, UNFL, INEX2 | 4-28 |
| `$0E` | FSIN | ±0 | NaN, OPERR | reduced to [-2π, 2π] first | OPERR, UNFL, INEX2 | 4-102 |
| `$0F` | FTAN | ±0 | NaN, OPERR | reduced to [-π/2, π/2] first | OPERR, OVFL, UNFL, INEX2 | 4-113 |
| `$10` | FETOX | +1.0 | +inf; -inf: +0 | | OVFL, UNFL, INEX2 | 4-42 |
| `$11` | FTWOTOX | +1.0 | +inf; -inf: +0 | | OVFL, UNFL, INEX2 | 4-123 |
| `$12` | FTENTOX | +1.0 | +inf; -inf: +0 | | OVFL, UNFL, INEX2 | 4-117 |
| `$14` | FLOGN | -inf, DZ | +inf; -inf: NaN, OPERR | x < 0: NaN, OPERR | OPERR, DZ, INEX2 | 4-58 |
| `$15` | FLOG10 | -inf, DZ | as FLOGN | as FLOGN | OPERR, DZ, INEX2 | 4-54 |
| `$16` | FLOG2 | -inf, DZ | as FLOGN | as FLOGN | OPERR, DZ, INEX2 | 4-56 |
| `$18` | FABS | +0 | +inf | | UNFL (extended denormal source only) | 4-18 |
| `$19` | FCOSH | +1.0 | +inf | | OVFL, INEX2 | 4-36 |
| `$1A` | FNEG | ∓0 | ∓inf | | UNFL (extended denormal source only) | 4-82 |
| `$1C` | FACOS | **+π/2** | NaN, OPERR | \|x\| > 1: NaN, OPERR; result in [0, π] | OPERR, INEX2 | 4-20 |
| `$1D` | FCOS | +1.0 | NaN, OPERR | reduced to [-2π, 2π] first | OPERR, INEX2 | 4-34 |
| `$1E` | FGETEXP | ±0 | NaN, OPERR | the unbiased exponent as an extended value (of the normalized input) | OPERR | 4-46 |
| `$1F` | FGETMAN | ±0 | NaN, OPERR | the mantissa in [1.0, 2.0) with the input's sign | OPERR | 4-48 |
| `$30-$37` | FSINCOS | sin ±0, cos +1.0 | both NaN, OPERR | FPs = RY, FPc = bits 2-0; **FPCC from the sine**; FPs = FPc keeps the sine; UNFL is the sine's (the cosine cannot underflow and is then 1) | OPERR, UNFL, INEX2 | 4-104 |
| `$3A` | FTST | FPCC only (Z, NZ) | I, NI | NaN: NAN bit; no register written | - | 4-121 |

- **The trigonometric functions lose accuracy** in range reduction, and
  above about **10^20** lose it entirely (4-34, 4-102, 4-113, 4-104).
- **The exponentials** (e^x, 2^x, 10^x, sinh, cosh, and FSCALE) can exceed
  even the 17-bit intermediate exponent - "catastrophic" overflow or
  underflow, e.g. e^x for x ≥ about 18,192 or ≤ -8,192; the exceptional
  operand's exponent is then `$0000` (UM 6-10, 6-13).
- **The transcendentals' accuracy is the manual's bound**: worst case one
  unit in the last place of *double* (4096 of extended), typically about
  64 extended units; limited special-case checks - "FTENTOX #1,FP0 does
  not produce ... exactly 10.0, and INEX2 ... may be set even if an exact
  result is produced" (UM 4.3.2). The model meets the bound; it cannot
  match silicon bit for bit (8.6.14 item 14).

**Dyadic** - `F<op>.<fmt> <ea>,FPn`, `F<op>.X FPm,FPn`; the result goes to
FPn. Signs follow the IEEE rules (XOR for multiply and divide) where the
scan's tables cannot be read:

| op | | special cases (dest op source) | EXC | UM |
|---|---|---|---|---|
| `$22` | FADD | +0 + -0 = +0 in RN, RZ, RP and **-0 in RM**; inf + finite = inf; **+inf + -inf = NaN, OPERR** | OPERR, OVFL, UNFL, INEX2 | 4-22 |
| `$28` | FSUB | FPn - src; +0 - +0 and -0 - -0 = +0 (-0 in RM); +0 - -0 = +0 and -0 - +0 = -0 (the IEEE signs - the scan prints both as -0.0); **like-signed infinities: NaN, OPERR** | OPERR, OVFL, UNFL, INEX2 | 4-111 |
| `$23` | FMUL | **0 × inf = NaN, OPERR**; otherwise signed zero or infinity | OPERR, OVFL, UNFL, INEX2 | 4-80 |
| `$20` | FDIV | FPn ÷ src; **range ÷ 0 = signed inf and DZ** (DZ only when the dividend is in range); inf ÷ 0 = signed inf, no DZ; **0 ÷ 0 and inf ÷ inf = NaN, OPERR** | OPERR, OVFL, UNFL, DZ, INEX2 | 4-40 |
| `$27` | FSGLMUL | as FMUL, single-precision mantissa (8.6.4) | OPERR, OVFL, UNFL, INEX2 | 4-100 |
| `$24` | FSGLDIV | as FDIV, single-precision mantissa | OPERR, OVFL, UNFL, DZ, INEX2 | 4-98 |
| `$21` | FMOD | FPn - src × N, **N = INT(FPn ÷ src) toward zero**; quotient byte = sign XOR and the 7 low bits of N; **src 0 or FPn inf: NaN, OPERR**; FPn in range, src inf: **FPn, re-rounded to PREC** (may be inexact or overflow); FPn 0: signed 0 | OPERR, UNFL, INEX2 | 4-62 |
| `$25` | FREM | as FMOD with **N = INT(FPn ÷ src) to nearest** (the IEEE remainder) | OPERR, UNFL (**INEX2 "cleared"**) | 4-86 |
| `$26` | FSCALE | FPn × 2^INT(src), the source **chopped toward zero** and added to the exponent; \|src\| ≥ 2^14 always overflows or underflows; src 0: FPn re-rounded; FPn 0 or inf: unchanged sign and kind; **src inf: NaN, OPERR** | OPERR, OVFL, UNFL (**INEX2 "cleared"**) | 4-93 |
| `$38` | FCMP | FPn - src sets FPCC, the difference is discarded; **I is always cleared**; table below | - | 4-32 |

**FCMP's condition codes** (the image, 4-32; `{NZ}` means computed from
the subtraction, a letter means set, "none" all clear; the NAN bit per
8.6.5):

| dest \ src | +range | -range | +0 | -0 | +inf | -inf |
|---|---|---|---|---|---|---|
| +range | {NZ} | none | none | none | N | none |
| -range | N | {NZ} | N | N | N | none |
| +0 | N | none | Z | Z | N | none |
| -0 | N | none | NZ | NZ | N | none |
| +inf | none | none | none | none | Z | none |
| -inf | N | N | N | N | N | NZ |

**The moves:**
- **`FMOVE <ea>,FPn`** rounds to PREC and RND. Inexact is possible only
  for (PREC single) L, D, X, P; (double) X, P; (extended) P. **OVFL is
  listed as "cleared"** and UNFL is set only for an extended denormal
  source (4-65) - 8.6.14 item 3.
- **`FMOVE FPm,<ea>`** does not change FPCC (UM 2.3.1). Integer
  destinations: OPERR for infinity or out of range, INEX2 (8.6.3). S, D,
  X: OVFL, UNFL, INEX2. P: OPERR for k > 17 or an exponent beyond 999,
  INEX2. Any exception is reported as a **mid-instruction** exception
  after the store (8.6.10).
- **`FMOVECR #ccc,FPn`** loads a ROM constant rounded to PREC and RND;
  INEX2 only (4-72). The documented offsets (4-73): `$00` π, `$0B`
  log10(2), `$0C` e, `$0D` log2(e), `$0E` log10(e), `$0F` 0.0, `$30`
  ln(2), `$31` ln(10), `$32` 10^0, `$33` 10^1, `$34` 10^2, `$35` 10^4,
  `$36` 10^8, `$37` 10^16, `$38` 10^32, `$39` 10^64, `$3A` 10^128, `$3B`
  10^256, `$3C` 10^512, `$3D` 10^1024, `$3E` 10^2048, `$3F` 10^4096. **The
  others are "reserved ... and may be different on various mask sets"**
  (8.6.14 item 7). The ROM holds more precision than extended, so the
  rounding mode changes the result (the model must carry the constants
  beyond 64 bits).
- **`FMOVE`/`FMOVEM` of the control registers and `FMOVEM` of the data
  registers** raise no exception and report none pending (except a
  protocol violation), and change FPSR only when FPSR is a destination
  (4-70, 4-74, 4-78).
- **`FNOP`** does nothing but synchronize: the MPU waits until the FPU
  (both units, on the 68882) has finished, and any pending exception is
  taken here (4-84).

### 8.6.9 The conditionals (UM 4.4, Tables 4-20 and 4-22, images)

A conditional is evaluated only when every earlier instruction has
finished and no exception is pending (a pending one is taken first, and
the conditional is restarted after it; UM 6.1.1). The predicate's bit 5
is ignored (`1xxxxx` = `0xxxxx`, no F-line; Table 4-20 note 3). **BSUN is
set - and trapped, if enabled - when NAN is set and the predicate is one
of `$10-$1F`**; with the trap enabled the FPU returns the BSUN exception
*instead of* the true/false answer, and the instruction is re-executed
after the handler, which must change something (UM 6.1.1). Setting BSUN
also sets AEXC.IOP; nothing else in the FPSR changes.

| pred | | equation | pred | | equation |
|---|---|---|---|---|---|
| `$00` | F | 0 | `$10` | SF | 0 |
| `$01` | EQ | Z | `$11` | SEQ | Z |
| `$02` | OGT | ¬(NAN ∨ Z ∨ N) | `$12` | GT | ¬(NAN ∨ Z ∨ N) |
| `$03` | OGE | Z ∨ ¬(NAN ∨ N) | `$13` | GE | Z ∨ ¬(NAN ∨ N) |
| `$04` | OLT | N ∧ ¬(NAN ∨ Z) | `$14` | LT | N ∧ ¬(NAN ∨ Z) |
| `$05` | OLE | Z ∨ (N ∧ ¬NAN) | `$15` | LE | Z ∨ (N ∧ ¬NAN) |
| `$06` | OGL | ¬(NAN ∨ Z) | `$16` | GL | ¬(NAN ∨ Z) |
| `$07` | OR | ¬NAN | `$17` | GLE | ¬NAN |
| `$08` | UN | NAN | `$18` | NGLE | NAN |
| `$09` | UEQ | NAN ∨ Z | `$19` | NGL | NAN ∨ Z |
| `$0A` | UGT | NAN ∨ ¬(N ∨ Z) | `$1A` | NLE | NAN ∨ ¬(N ∨ Z) |
| `$0B` | UGE | NAN ∨ Z ∨ ¬N | `$1B` | NLT | NAN ∨ Z ∨ ¬N |
| `$0C` | ULT | NAN ∨ (N ∧ ¬Z) | `$1C` | NGE | NAN ∨ (N ∧ ¬Z) |
| `$0D` | ULE | NAN ∨ Z ∨ N | `$1D` | NGT | NAN ∨ Z ∨ N |
| `$0E` | NE | ¬Z | `$1E` | SNE | ¬Z |
| `$0F` | T | 1 | `$1F` | ST | 1 |

(The right half is the left half with BSUN. The 4.4.2 table misprints
ULT's predicate as `001101`; Tables 4-20 and 4-22 give `001100`.)

`FBcc`, `FDBcc` (decrements the low 16 bits of Dn when the condition is
false, branches unless it reaches -1), `FScc` (all ones or all zeros to a
byte) and `FTRAPcc` (a true condition takes the TRAPcc exception, vector 7,
post-instruction frame) do the rest in the MPU; to the FPU they are one
instruction (UM 4-135).

### 8.6.10 Exceptions (UM Section 6, 7.4.2.5-7.4.2.6)

| vector | offset | exception | detected by |
|---|---|---|---|
| 7 | `$01C` | FTRAPcc true | MPU (post-instruction frame, format `$2`) |
| 8 | `$020` | privilege violation (`FSAVE`/`FRESTORE` in user mode) | MPU, before any CIR access |
| 11 | `$02C` | F-line: undefined command word or opclass (FPU); undefined type, bad EA for the primitive, or **a bus error on the initiating CIR access - no coprocessor** (MPU) | both |
| 13 | `$034` | coprocessor protocol violation | both |
| 14 | `$038` | format error (`FSAVE`/`FRESTORE`) | MPU, on the FPU's `$02xx` |
| 48 | `$0C0` | BSUN | FPU |
| 49 | `$0C4` | INEX1 or INEX2 (one vector) | FPU |
| 50 | `$0C8` | DZ | FPU |
| 51 | `$0CC` | UNFL | FPU |
| 52 | `$0D0` | OPERR | FPU |
| 53 | `$0D4` | OVFL | FPU |
| 54 | `$0D8` | SNAN | FPU |

- **Priority**, when several enabled exceptions occur at once: BSUN,
  SNAN, OPERR, OVFL, UNFL, DZ, INEX2/INEX1 - only the highest traps; the
  handler looks for the others (UM 6.1.9). The possible pairs are SNAN +
  INEX1, OPERR + INEX2, OPERR + INEX1, OVFL or UNFL + INEX2 and/or INEX1,
  INEX2 + INEX1.
- **When it is reported.** An arithmetic exception found while the FPU
  computes is **held pending** and reported when the MPU next writes the
  command or condition CIR - as a **pre-instruction** exception (frame
  `$0`, the PC of the *new* instruction, which RTE restarts). On the
  68882 it may instead be reported by an instruction already in the CU as
  a **mid-instruction** exception (frame `$9`, that instruction's PC,
  effective address undefined unless it had evaluated one). `FMOVE
  FPm,<ea>` reports its own exceptions as mid-instruction exceptions
  after the store, with the destination's address at frame offset `$10`
  (UM 6.1, 7.4.2.6). BSUN, an illegal command word and a protocol
  violation are reported at once. FPIAR always holds the address of the
  instruction that caused the exception.
- **The 68882 does not clear a pending exception on the MPU's
  acknowledge** (the 68881 does). It keeps returning the take-exception
  primitive until an `FSAVE` (or a null `FRESTORE`) - so a 68882 handler
  must `FSAVE`, set bit 27 of the BIU flags in the frame, and `FRESTORE`
  before its RTE, even if it uses no FPU instruction (UM 5.2.2, Figure
  5-6). Without the `FSAVE` the next FPU instruction takes the same
  exception again (or a protocol violation); without the bit, the
  restored frame re-arms it.
- **An illegal command word written while an exception is pending**: the
  pending exception is reported first; after its handler, the restarted
  instruction reports the F-line (UM 6.1.11).
- **The exceptional operand** (idle frame `$28`): for SNAN, OPERR and DZ
  with a register destination, the source converted to extended; for OVFL
  and UNFL with a register destination, the intermediate result rounded
  to extended with its exponent **wrapped by ∓$6000** (OVFL: bias
  `$3FFF-$6000`, normal range `$1FFF-$7FFF`; UNFL: `$3FFF+$6000`, range
  `$0000-$5FFF`) and `$0000` for a catastrophic over- or underflow; with a
  memory destination, the mantissa rounded to the destination precision
  with a normal extended exponent; **for an inexact-only exception it is
  undefined** (UM 6.1.3-6.1.8).

### 8.6.11 `FSAVE`, `FRESTORE` and the state frames (UM 6.4, Figures 6-4 to 6-6, images)

**The format word** (the frame's first word; the second is reserved): the
version number in bits 15-8, the size of the internal state **in bytes,
excluding this first long word**, in bits 7-0 (UM 6-32 note).

| format word | meaning | frame |
|---|---|---|
| `$00xx` | null (reset state); version 0 is a wild card | 4 bytes; the size byte is undefined and ignored on restore |
| `$01xx` | not ready, come again (save only) | - |
| `$02xx` | invalid: format error | - |
| **`$1F38`** | **idle, 68882** (version `$1F`, the initial production value) | **60 bytes** |
| **`$1FD4`** | **busy, 68882** | **216 bytes** |
| `$1F18`, `$3F18`; `$xxB4` | idle and busy, 68881 | 28, 184 |

The 68030 treats format codes `$03-$0F` as invalid and a size that is not
a multiple of four as a format error (030 UM 10.2.3.2). **The FSAVE page
(4-90) lists the 68881's sizes only** (`$xx18`, `$xxB4`); Section 6 and
Table 6-6 give the 68882's.

**The 68882's idle frame** (Figure 6-5, image):

| offset | contents |
|---|---|
| `$00` | version `$1F`, size `$38`, reserved word (the 68881's is written `$FFFF`, ignored on restore) |
| `$04` | the command/condition register image (upper word); reserved (lower) |
| `$08-$27` | 32 bytes of **CU internal registers** (the 68882's addition; contents not documented) |
| `$28-$33` | **the exceptional operand**, 12 bytes (8.6.10) |
| `$34` | **the operand register image** |
| `$38` | **the BIU flags** |

Handlers find these from the end - `MOVE.B 1(SP),D0` gives the size, then
`-16(SP,D0)` is the exceptional operand and `-4(SP,D0)` the operand
register, the same on both chips (UM Figure 5-7). The busy frame is the
format word and 212 bytes of undocumented internal state; it "should not
be modified in any way" (UM 6.4.2.3).

**The BIU flags** (Figure 6-6, image; bits 15-0 undefined, written as ones,
ignored on restore; only bit 27 may be changed by software):

| bit | meaning |
|---|---|
| 31 | protocol violation pending (1 = pending) |
| 30 | 0: a command word or predicate has been received but not started (it is in the image at `$04`) |
| 29 | the type of the pending operand access or operation (with 30 and 28, Table 6-4) |
| 28 | 0: an access of the operand CIR is expected |
| **27** | **EXC_PEND - 0: a floating-point exception is pending** (its type is EXC AND ENABLE) |
| 26 | 0: an operand transfer to memory is pending |
| 25-24 | CU internal state (68882 only) |
| 23-20 | the operand register image's bytes valid (from the figure: 20 = bits 31-24 ... 23 = bits 7-0) |
| 19-16 | CU internal state (68882 only) |

Table 6-4, bits 30-28: `001` conditional instruction pending, `011`
general instruction pending, `100` write of the operand CIR pending, `110`
read of the operand CIR pending, `111` nothing pending; the others
reserved. A program may clear a pending exception (bit 27 → 1), create one
(→ 0, with the EXC and ENABLE images deciding its type), or change its
type; the change takes effect at the `FRESTORE` (UM 6-35).

**The phases** (Table 6-5): **reset** - null frame at once; **idle** - idle
frame at once; **initial** (receiving the instruction and its operands) -
busy frame at once; **middle** (only the long instructions: remainder,
transcendentals, BCD conversions) - come-again until the next microcode
checkpoint, then busy; **end** (roughly the time a busy save would take
from the finish) - come-again until the instruction completes, then idle.
Most instructions go straight from initial to end, so most frames are
idle (UM 6.4.3). After an `FSAVE` the FPU is idle with nothing pending.

**The transfers.** `FSAVE`: the MPU reads the save CIR (come-again: it
takes any interrupt, with a pre-instruction frame, and re-reads);
it writes the format word at the effective address - for `-(An)` after
subtracting the frame size from An - and then fills the frame **from the
highest address down**, four bytes at a time from the operand CIR, and
does not read the response CIR afterwards. `FRESTORE`: the MPU reads the
format word, writes it to the restore CIR (which aborts whatever the FPU
was doing), reads the restore CIR back - the same word if valid, `$02xx`
if not (then the MPU writes the abort mask and takes a format error) -
and transfers the frame **from the lowest address up**; `(An)+` is updated
only after the whole frame, so a fault leaves the frame intact (UM 6.4.3,
6.4.4). A second `FSAVE` while an `FSAVE` or `FRESTORE` is suspended (a
page fault) gets `$02xx` from the save CIR and destroys the FPU's
context; reading the save CIR with `MOVES` first is the documented guard
and is not destructive (UM 7.5.4.6).

### 8.6.12 The coprocessor interface (UM Section 7; 030 UM Section 10)

**Selecting the chip.** A coprocessor access is an MPU bus cycle with
**FC = 7, A19-A16 = `0010`, A15-A13 = the ID**, A4-A0 the register, the
other address bits zero: the 68882's registers are at CPU-space
**`$00022000-$0002201F`** (030 UM 10.1.4). On the SE/30 "the GLUE decodes
the address and asserts the device select to the FPU", which runs on the
**same 16 MHz clock as the main processor** (Guide p. 107). With no
coprocessor at an ID, the initiating access bus-errors and the MPU takes
an F-line - which is how the machine stops today (8.1).

**The registers** (Table 7-2; word registers on D31-D16 whatever A1):

| offset | register | access | 68882 behaviour |
|---|---|---|---|
| `$00` | response | read | the current primitive; always legal to read; reading a service primitive consumes it (it becomes null) |
| `$02` | control | write | bit 1 **XA** (exception acknowledge, mask `%10`), bit 0 **AB** (abort, `%01`); the 68882 honours AB only inside the "abort window" of the last instruction received (outside it the result is undefined) and aborts only that instruction; XA alone does not clear a floating-point exception (UM 7.2.2) |
| `$04` | save | read | starts an `FSAVE`; returns a format word |
| `$06` | restore | read/write | a write starts an `FRESTORE`; the read returns the verified format word |
| `$08` | operation word | write | not used: a write is ignored, no violation |
| `$0A` | command | write | starts a general instruction |
| `$0C` | reserved | | |
| `$0E` | condition | write | starts a conditional instruction |
| `$10` | operand | read/write, 32 bits | the operand port, legal only after a transfer primitive or a valid format word; data MSB-aligned; a shorter tail is MSB-aligned |
| `$14` | register select | read | the `FMOVEM` mask in bits 15-8, bits 7-0 zero; legal only right after the transfer-multiple primitive |
| `$16` | reserved | | |
| `$18` | instruction address | write, 32 bits | the PC the FPU asked for; **the 68882 requires it when asked** (else a protocol violation) and keeps one per pipeline stage (BIU, CU, APU - the APU's is FPIAR); reads all ones |
| `$1C` | operand address | read/write | not implemented: reads all ones, writes ignored, no violation |

Reads of reserved or write-only registers return **all ones**; writes to
read-only ones are ignored; neither is a violation - **except a write to
the register select CIR, which is** (UM 6-21). Reads of save and response
and writes of restore and control are always legal (UM 6.1.12).

**The primitives the 68882 uses** (Table 7-7, image; bit 15 CA come again,
14 PC pass the program counter, 13 DR direction):

| primitive | encodings | use |
|---|---|---|
| null | `$0800` (CA=0: conditional false), `$0801` (true), **`$0802`** (CA=0, PF=1: idle, instruction complete), **`$0900`** (CA=0, IA=1, PF=0: released, still executing), **`$4900`** (the same, pass PC), **`$8900`** (CA=1, IA=1: wait, interrupts allowed), **`$C900`** (the same, pass PC) | synchronization, release, conditional result |
| evaluate `<ea>` and transfer data | `$9501/$9502/$9504` B, W, L/S/FPCR/FPSR; `$9608` D or two FPcr; `$960C` X, P or three FPcr; `$9704` FPIAR (any EA); `$D5xx`/`$D6xx` the same with PC; out: `$B101/$B102/$B104/$B208/$B20C`, `$B304` FPIAR; **68882 CA=0 forms** `$1504/$1608/$160C` (in), `$5504/$5608/$560C` (in, PC), `$3104/$3208/$320C` (out) | bits 10-8 the valid EA class (Table 7-4: 000 control alterable ... 101 data, 110 memory, 111 any), bits 7-0 the length |
| transfer single main processor register | `$8C0r`, `$CC0r` (with PC) | the dynamic k-factor or dynamic `FMOVEM` list, from Dr |
| transfer multiple coprocessor registers | `$810C` (to the FPU), `$A10C` (from it) | `FMOVEM`; length 12 per register |
| take pre-instruction exception | `$1Cvv`; `$5C30` BSUN (with PC) | vector vv |
| take mid-instruction exception | `$1Dvv` (`$1D0D` protocol violation) | vector vv |

(Table 7-7's comment for `$3104-$320C` says PC = 1; the encodings have PC
= 0, as Table 7-5 says.)

**The dialogs** (UM 7.5; the timing assumes the idle FPU):
- **Register to register** and `FMOVECR`: command → first read: null
  (`$0900`/`$4900`, released at once, PC passed if any arithmetic
  exception is enabled) → the FPU computes concurrently.
- **`<ea>` to register**: command → evaluate-`<ea>`-and-transfer (PC if
  enabled) → operand written → null release. The 68882 uses the CA=0
  form for S, D and X, releasing the MPU as soon as the operand is written.
- **Register to `<ea>`**: command → (dynamic k: transfer-single-register
  first) → null CA=1 while it converts, interrupts allowed → evaluate-
  `<ea>`-and-transfer (DR=1) → the operand read → null release, **or take
  mid-instruction exception**. The 68882's CA=0 form for S, D, X skips
  the final read, except for a NaN/unnormal/denormal source, a single or
  double overflow or underflow, or INEX2 enabled.
- **Control registers**: one evaluate-and-transfer, then release; never a
  PC request.
- **`FMOVEM`**: (dynamic: transfer-single-register) → transfer-multiple →
  the MPU reads the register select CIR, counts its ones, moves 12 bytes
  each (`-(An)`: registers at descending addresses, bytes ascending within
  each) → release; never a PC request. A mask of zero moves nothing.
- **Conditionals**: predicate → null CA=1 while anything is busy (a
  pending exception may be taken during this) → null CA=0 with TF.
- **A new instruction while busy**: the command or predicate is latched and
  `$8900` returned until the FPU can start it; the 68882 accepts the
  second general instruction into the CU and waits only on a third.

**The MPU's side** (030 UM 10.4-10.5; our kernel implements it):
- It passes the PC (the F-line word's address) to the instruction address
  CIR **first**, whenever a primitive has PC = 1.
- It checks a primitive's valid-EA class against the operation word's EA;
  a mismatch **writes the abort mask and takes an F-line** (pre-instruction
  frame). A register-direct transfer must be 1, 2 or 4 bytes; an immediate
  must be 1 or even and toward the coprocessor; a write to a
  non-alterable address, an odd transfer-multiple length, an unknown
  primitive (bits 13-8 = `$00` or `$3F` among them), or a primitive
  illegal in a conditional (evaluate-and-transfer, transfer-multiple, CA=0
  forms of the others) is a **protocol violation**: mid-instruction frame,
  vector 13, **no write to the control CIR**. `-(A7)`/`(A7)+` with length 1
  move A7 by 2. A byte or word to An is sign-extended; to Dn it replaces
  only the low byte or word.
- **Take pre-instruction**: exception acknowledge to control, frame format
  `$0` (SR, PC = the F-line word's address, `$0`+vector offset), RTE
  restarts the instruction. **Take mid-instruction**: acknowledge, frame
  format `$9` (10 words: SR, scanPC, `$9`+offset, PC, internal register,
  the operation word, the effective address), RTE reads the response CIR
  and continues. **FTRAPcc true**: format `$2` (SR, scanPC = the next
  instruction, `$2`+offset, PC), vector 7.
- **Interrupts** are taken on null CA=1 IA=1 with a format `$9` frame
  (RTE re-reads the response), and during an `FSAVE`'s come-again with a
  format `$0` frame (RTE restarts the `FSAVE`).
- **Trace**: with a trace pending, the MPU keeps reading until null CA=0
  PF=1 (servicing interrupts on `$0900`), then traces.
- `FSAVE`/`FRESTORE` in user mode: privilege violation before any CIR
  access. Their EA checks are the MPU's: `FSAVE` control alterable or
  `-(An)`, `FRESTORE` control or `(An)+`, else F-line.

**Protocol violations the 68882 detects** (UM 6.1.12): an access that does
not fit the dialog - the command or condition CIR written while it expects
the operand, register select or instruction address CIR, or those
accessed while it expects a command or predicate - makes the response
**take mid-instruction, vector 13**; the acknowledge aborts everything and
leaves the chip idle. One documented hole: reading the operand CIR
**before** the evaluate-and-transfer (DR=1) or transfer-multiple (DR=1)
primitive has been issued is ignored entirely - the access never
terminates and only a bus-error watchdog ends it (reachable only by
`MOVES` misuse).

### 8.6.13 Timing (UM Section 8)

The manual's clocks are **the FPU's clock**, measured with a 68020 on the
same clock, no wait states, long-aligned operands, the default FPCR, and
**11 clocks of interface overhead** included (2 if perfectly overlapped);
"the MC68030 ... always yields better values" (UM 8.5.1). On the SE/30
both run at 15.6672 MHz (Guide p. 107).

**Table 8-3, the 68882** (read from the image, 8-15): head H (overlappable
with the previous instruction), tail T (overlappable with the next),
total, for a register source, and the totals for an extended and a packed
memory source; add the MPU's effective-address time (Table 8-1) for
memory sources; integer and single sources from Dn are 5 clocks less:

| | H | T | FPm | .X | .P | | H | T | FPm | .X | .P |
|---|---|---|---|---|---|---|---|---|---|---|---|
| FABS, FNEG | 17 | 17 | 38 | 63 | 893 | FLOGN | 17 | 507 | 528 | 553 | 1383 |
| FACOS | 17 | 607 | 628 | 653 | 1483 | FLOGNP1 | 17 | 553 | 574 | 599 | 1429 |
| FADD, FSUB | 17 | 35 | 56 | 81 | 909 | FLOG10, FLOG2 | 17 | 563 | 584 | 609 | 1439 |
| FASIN | 17 | 563 | 584 | 609 | 1439 | FMOD | 17 | 54 | 75 | 100 | 928 |
| FATAN | 17 | 385 | 406 | 431 | 1261 | FMUL | 17 | 55 | 76 | 101 | 929 |
| FATANH | 17 | 675 | 696 | 721 | 1551 | FREM | 17 | 84 | 105 | 130 | 958 |
| FCMP | 17 | 17 | 38 | 63 | 891 | FSCALE | 17 | 25 | 46 | 71 | 899 |
| FCOS | 17 | 373 | 394 | 419 | 1249 | FSGLDIV | 17 | 53 | 74 | 99 | 927 |
| FCOSH | 17 | 589 | 610 | 635 | 1465 | FSGLMUL | 17 | 43 | 64 | 89 | 917 |
| FDIV | 17 | 87 | 108 | 133 | 961 | FSIN | 17 | 373 | 394 | 419 | 1249 |
| FETOX | 17 | 479 | 500 | 525 | 1355 | FSINCOS | 17 | 433 | 454 | 479 | 1309 |
| FETOXM1 | 17 | 527 | 548 | 573 | 1403 | FSINH | 17 | 669 | 690 | 715 | 1545 |
| FGETEXP | 17 | 27 | 48 | 73 | 903 | FSQRT | 17 | 89 | 110 | 135 | 965 |
| FGETMAN | 17 | 13 | 34 | 59 | 889 | FTAN | 17 | 455 | 476 | 501 | 1331 |
| FINT, FINTRZ | 17 | 37 | 58 | 83 | 913 | FTANH | 17 | 643 | 664 | 689 | 1519 |
| FMOVECR | 10 | 0 | 32 | | | FTENTOX, FTWOTOX | 17 | 549 | 570 | 595 | 1425 |
| FTST | 17 | 15 | 36 | 61 | 891 | | | | | | |

`FMOVE` to FPn: 21 (register), 34 (.S), 40 (.D), 46 (.X), 48 (integer),
891 (.P) - fully concurrent when there is no register conflict (H =
total, no tail). `FMOVE` to memory: 38 (.S), 44 (.D), 50 (.X), 110
(integer), **2006 (.P)**. Conditionals (Table 8-7, worst case):
`FBcc.W` 23 taken / 19 not, `FNOP` 19, `FScc Dn` 21, `FTRAPcc` 47 / 22.
`FSAVE` null / idle / busy: 18 / 102 / 336; `FRESTORE`: 22 / 106 / 340
(Table 8-8, worst case, plus the EA time). The 68881 detail tables (8.5.2)
give the data-dependent parts (operand types, rounding precision,
exceptions) and are where item 6's per-instruction budgets come from.

### 8.6.14 Where the manual is wrong, contradicts itself, or is silent

Numbered so the model, the RTL and the benches can cite them. Nothing
here is decided; each needs evidence - results from a real 68882 - or
Daniel's call. (Written first as "the `cputest` corpus where its data
came from hardware"; the corpus's expected results come from WinUAE's
core, so it is not that evidence - 8.6.15. What WinUAE and MAME say on
each item is in 8.6.15.)

1. **FATANH(±1)**: +1 gives -infinity and -1 gives +infinity, stated
   twice (4-28, 6.1.6) - the opposite of atanh. A real 68882 quirk to
   replicate, or a documentation error? Silicon evidence decides; the
   manual as printed is the fallback. **Not an OCR or print error**
   (checked 2026-09-29, Daniel's question): both passages read cleanly
   in the page images at 300 dpi, and the 1st edition prints the same
   words in both places. The scan's fault - a faded vertical stroke
   turning `+` into `-` in the operation tables' small type, confirmed at
   400 dpi in FETOX and FDIV - can only turn `+` into `-`, and each
   sentence pairs a clear "+infinity" with "-1" and "-infinity" with
   "+1", so it cannot produce the reversal. What stays open is whether
   Motorola's text is wrong: its 68040 FPSP returns sign(x) × infinity.
2. **FLOGNP1(-1)**: 4-60 (both editions) returns a **NaN** with DZ; 6.1.6
   says "for the FLOGx instructions, return minus infinity". Same test.
3. **`FMOVE <ea>,FPn` in single or double PREC**: OVFL is "cleared" and
   UNFL set only for an extended denormal (4-65), yet range control (6-16)
   and 6.1.4-6.1.5 say a result outside the PREC range overflows or
   underflows. Default: 6.1.4-6.1.5 (the post-processing every other
   instruction documents); test on silicon.
4. **FSCALE and FREM "INEX2 cleared"** (4-94, 4-87), while their own
   notes say a re-rounded FPn may be inexact; FMOD says "refer to 6.1.7".
   Likewise FMOD's OVFL is "cleared" though its note 2 says a re-rounded
   FPn may overflow. **Decided (Daniel, 2026-09-29): 6.1.7 decides**, as
   for item 3 - the flags report the rounding or overflow that happened.
5. **FMOD/FREM's quotient byte** for the special cases (source infinity,
   destination zero, NaN) is not stated.
6. **The redundant opmodes** `$05, $07, $0B, $13, $17, $1B, $29-$2F, $39,
   $3B-$3F`: no F-line, "redundant with valid instructions", which ones not
   said. Silicon evidence, or a documented source, before anything is
   built; until then the model marks them unknown rather than guessing.
   WinUAE's answer (8.6.15) - each is its neighbour with opmode bit 0
   cleared, and `$38-$3F` split by bit 1 into FCMP and FTST - is the
   leading candidate.
7. **`FMOVECR`'s undocumented offsets** (`$01-$0A`, `$10-$2F`, `$40-$7F`):
   internal constants, "may be different on various mask sets". A
   silicon dump of the SE/30's mask is the only evidence that counts.
8. **The reset NaN's bit pattern**: "positive nonsignaling NaNs"; default
   the chip's own NaN, `$7FFF FFFFFFFF FFFFFFFF`.
9. **`FSGLMUL`/`FSGLDIV` input truncation**: "truncated to 23 bits"
   (4-17) against "more than 24 bits of mantissa" (4-98, 4-100) - 24 bits
   with the integer bit is the likely reading.
10. **The 68882's version number**: `$1F` is "the initial production"
    value (6-34); the SE/30's mask is not stated (the IIcx BOM gives only
    `337S6510`, 16 MHz). Mac OS reads only the size byte (the manual's
    identification test compares it with `$18`). Default `$1F`.
11. **The frames' undocumented contents** - the CU's 32 bytes and the busy
    frame's 212 - are ours to define. Software is told not to touch them;
    nothing needs to restore a frame saved by real silicon.
12. **`FScc` to `(xxx).W`/`(xxx).L`**: Table 4-19 lists operation-word
    bits `111000`/`111001` as undefined; the FScc page and the 68030 allow
    them. It is the MPU's decision; the kernel follows the 030 UM.
13. **The FDBcc displacement base**: "the address of the displacement
    word" (4-38) against "the instruction plus two" (4-39, which is the
    FBcc wording copied); the 68030's scanPC rule (030 UM 10.2.2.3.2)
    decides: the displacement word.
14. **Bit-exactness**: the transcendentals and the decimal conversions are
    specified only by error bounds (4.3.2, 4.3.3); Motorola's algorithms
    are unpublished. Our results will differ from silicon in the last
    bits within those bounds (fidelity tier 2). The arithmetic functions,
    moves, rounding and every special case are exact and must match.
15. **Misprints, for the record**: Table 3-3's smallest denormal is 10^-4952
    (printed 10^4952); 4.4.2's ULT predicate (`001100`, printed `001101`);
    Table 7-7's PC comment on `$3104-$320C` and its TF comment on `$0801`
    (the encoding has TF = 1); 7.5.4.4 says the BSUN dialog
    needs "the SNAN enable bit" (it is the BSUN bit); 6-16's range-control
    example calls the largest single's exponent "unbiased $00FF"; the
    FSAVE page's format words are the 68881's.
16. **Concurrency** (8.6.1) - whether the CU overlap is modelled - is item
    6's first decision, with its software-visible consequences listed
    there.
17. **The eight FPCC combinations the chip never produces** (a user can
    write them to FPSR): the manual says only that a conditional "may
    produce an unexpected branch condition" (2.3.1). 8.6.9's default
    evaluates the equations on the bits as written; WinUAE's 6888x truth
    table disagrees with that for some of them (8.6.15). **The model's
    default is WinUAE's table** (the rule of 8.6.15 for a silence; the
    equations are the other setting), and the BIU implements it (8.8.19).

Found while specifying the BIU (8.9, item 7b); **each default accepted by
Daniel, 2026-09-30**:

18. **The illegal command word's PC bit**: 7.4.2.5's text says the take
    pre-instruction primitive has PC = 1 "if the exception is due to an
    illegal command word"; Table 7-7 lists the F-line primitive as `$1C0B`
    (PC = 0); 030 UM 10.5.1.2 is silent. Default: **Table 7-7's `$1C0B`**
    (the encodings are the table's to give; 15 above treats its comments,
    not its encodings, as misprints).
19. **Which instructions report a pending exception**: 7.4.2.5 lists them -
    "an arithmetic (OPCLASS 000, 010, and 011) or conditional instruction
    is initiated" - so FMOVEM and FMOVE of the control registers do not
    report it; 7.5.4.1 says "any floating-point instruction other than an
    FSAVE (or an FRESTORE of the null state) reports the same exception
    again". Default: **7.4.2.5's list**, the specific statement. (A
    handler that begins with FSAVE, as 5.2.2 requires, cannot tell.)
20. **FMOVEM of the control registers with an empty list** (command bits
    12-10 = 000): the manual gives no primitive for it. Default: **an
    illegal command word** (F-line, `$1C0B`).
21. **An early read of the operand CIR** (before the evaluate-and-transfer
    DR = 1 or transfer-multiple DR = 1 primitive of an FMOVE or FMOVEM
    out): documented as "ignores the access completely" - no DSACK, the
    system's bus-error watchdog ends it (6.1.12). Replicated (the rule for
    documented behaviour).
22. **When an integer source and FMOVECR release the MPU** (found by 7e-3,
    2026-10-01). Figures 7-17 and 7-18 show the release ($0900) at once -
    after the operand transfer for B, W, L, at the first read for
    FMOVECR. Table 8-3 says otherwise, systematically: every integer row
    has total = head + tail + 19 (FADD.L 21 + 54 + 19 = 94, FMOVE.L
    21 + 8 + 19 = 48, FABS.L 21 + 28 + 19 = 68), and FMOVECR has tail 0
    (head 10, total 32) - the MPU held while the APU converts the integer
    (which the CU cannot, 5.1.1.2's minimum concurrency) and through
    FMOVECR's run. A held null ($8900) is legal protocol; the figures
    show only the final encoding. **Daniel (2026-10-01): Table 8-3 - hold.**

### 8.6.15 What WinUAE and MAME say (read 2026-09-29)

Daniel asked whether the emulators hold anything useful. Read: WinUAE
`fpp.cpp`, `fpp_softfloat.cpp`, `softfloat/softfloat_fpsp.cpp` and
`cputest/readme.txt` at tip `d42db95` (2026-09-27), and MAME
`src/devices/cpu/m68000/m68kfpu.cpp` at its tip, both sparse-cloned into
a session scratchpad (not kept). By the standing rule they are
cross-checks, not evidence: **where the manual speaks, it wins; where it
is silent, an emulator's specific answer is a lead, cited as such, until
hardware confirms it.**

**The `cputest` corpus is not silicon data.** Its readme: the tester "is
based on UAE CPU core ... All the CPU logic comes from UAE CPU core"; real
hardware is what the generated tests are *run on*. So a vector's expected
result is WinUAE's prediction, confirmed on real hardware to an extent the
corpus does not record, and the FPU part is incomplete by the readme's own
account ("Working FPU support. Not all tests work correctly yet", "FPU
FSAVE/FRESTORE, FPU support also isn't fully implemented yet"). 8.2 and
8.4 item 7 are corrected accordingly. (The same holds for the 030 integer
corpus Section 1 relies on, where the readme claims near-completeness on
real hardware; that use is unchanged, but its standing is the same kind.)

**WinUAE's 6888x specifics** - none cite a source, several are commented
as undocumented, and some read as measured:

| 8.6.14 | WinUAE | standing |
|---|---|---|
| 6 | "6888x undocumented but existing opmodes": **`$05` FSQRT, `$07` FLOGNP1, `$0B` FATAN, `$13` FTENTOX, `$17` FLOG2, `$1B` FNEG, `$29-$2F` FSUB, `$39/$3C/$3D` FCMP, `$3B/$3E/$3F` FTST** | the pattern - opmode bit 0 not decoded, and in `$38-$3F` bit 1 choosing FTST - is what a decoder that ignores those bits does, and fits the manual's "redundant with valid instructions"; MAME agrees for `$29-$3F` and has no entry for the first six; the leading candidate |
| 7 | "68881 and 68882 have identical undefined fields": a table for offsets `$01-$0A`, and **`$4000 00000000 00000000`** for "most undefined fields" (`$10-$2F`); **offsets `$40-$7F` take the F-line on a 6888x** ("6888x and ROM constant 0x40 - 0x7f: f-line" - corrected 2026-09-29, this row first listed them with `$10-$2F`); a comment that PREC and RND affect them "very strangely", with per-offset adjustments | looks measured; mask dependence unknown; MAME stops with an error on any undefined offset |
| 1, 2 | FATANH(±1) = ±inf and FLOGNP1(-1) = -inf, both with DZ - the mathematical answers, **against the manual as printed** | its transcendentals are Andreas Grabher's (Previous) port of Motorola's 68040 FPSP, not a 68882 measurement; the manual stands until hardware says otherwise. Motorola's own FPSP source is Motorola's statement for a different chip and worth reading for these two |
| 8 | reset and null restore: FPn = `$7FFF FFFFFFFF FFFFFFFF` | agrees with the default (MAME too) |
| 9 | FSGLMUL/FSGLDIV mask the inputs to `$FFFFFF0000000000` - 24 bits with the integer bit (**corrected 2026-10-02, 7e-4: only FSGLMUL masks; `floatx80_sgldiv` truncates neither operand**) | supports the likely reading for FSGLMUL |
| 10 | version `$1F` for both 68881 and 68882 | agrees; MAME writes a 68881 idle frame (`$1F18`, 28 bytes) whatever the chip, which is wrong for a 68882 |
| 17 | a 16 × 32 truth table for the 6888x that differs from the equations, and from its own 68040 table, for combinations such as Z with NAN (e.g. OR true) | reads as tabulated from hardware; unsourced |

**Frame details the manual leaves open** (WinUAE; WinUAE never writes a
busy frame and ignores a restored one):
- the **null frame's format word is `$0038`** on a 68882 (`$0018` on a
  68881) - the manual calls the size byte undefined, "consistent" per
  version (Table 6-6 footnote);
- **BIU flags `$5C0EFFFF`** in an idle frame with nothing pending and
  **`$740EFFFF`** with an exception pending (bit 27 clear, bit 29 set);
- the **command/condition image** at `$04` is `command<<16 | command` for
  opclass 011 and `(opword | $0080)<<16 | command` for opclasses 000 and
  010;
- the **exceptional operand** after an OPERR on a move to an integer or
  packed destination keeps only the sign and exponent (`& $4FFF0000`,
  lower longs zero);
- the CU's 32 bytes are written as zeros.

**MAME's one Mac-specific claim does not apply here.** Its CIR handler
says pre-1992 Mac ROMs detect the FPU by reading its interface registers
and catching the bus error. The SE/30's ROM (97221136) never loads SFC or
DFC (no `MOVEC` to either anywhere in it), so it cannot reach CPU space
with `MOVES`; 8.1's reading - the ROM declares the FPU unconditionally -
stands.

**What would settle 8.6.14**, in order of value: a small test program run
on a real 68882 (all seventeen items at once - any 68882 machine would
do, not only an SE/30; **none is available, Daniel 2026-09-29**, so this
waits); Toni Wilen's own hardware-test posts (English Amiga Board), which
would make WinUAE's answers citable; Motorola's FPSP source for items 1
and 2. **Decided (Daniel, 2026-09-29):** until one of them arrives, the
model (item 5) builds every
8.6.14 item as a **switchable choice** with the manual's reading as the
default, so settling one later is a one-line change, not a redesign.
Where the manual is silent (items 6, 7, 17 and the frame details
above), the default is WinUAE's answer, labelled as a lead. The FPGA is
built for one setting per item; the switches exist only in the model.

**More silences, found writing the model (2026-09-29):**

18. **FPCC after an enabled SNAN, OPERR or DZ trap with a register
    destination.** The register "is not modified" and "instruction execution
    is terminated" (6.1.2, 6.1.3, 6.1.6); whether FPCC is set from the
    result that was not written is not said. Default: FPCC unchanged (the
    instruction terminated before its result existed); the other setting
    sets it from the default result.
19. **The documented constants' ROM precision.** 4-72: the chip "fetches an
    extended precision constant ... rounds it to the precision specified in
    the FPCR" - once, from an extended value, which would make RND
    irrelevant in extended precision and INEX2 impossible there; yet INEX2
    "refer to 6.1.7". Default: the constant carries the 67-bit datapath's
    guard, round and sticky, which is rounding the exact value once by PREC
    and RND. WinUAE's table (a lead) differs in two ways: it rounds to
    extended by RND and then, in single or double PREC, rounds that again;
    and it treats **log10(e) as exact** (no INEX2, no RND effect) - the
    other twenty-one it treats like the default.
    **Measured in the model (2026-09-29): WinUAE's table is a 64-bit ROM,
    not an exact one.** Its images are the correctly rounded constants
    except **log10(2) and e, which are truncated** (`$3FFD 9A209A84
    FBCFF798` and `$4000 ADF85458 A2BB4A9A`; the exact values' guard bits
    are 1, so correct RN rounding gives `...799` and `...A9B`), with RP
    stepping up where the image lies below the true value and RZ/RM down
    where it lies above - a 64-bit constant and a flag for the side of it
    the true value lies, which is what 4-72's "fetches an extended
    precision constant ... rounds it to the precision specified" describes.
    Nobody would write those two images by computing the constants, so
    they read as measured. Against the exact rounding, this reading differs
    in six cells of 264 (log10(2) and e in extended RN; log10(e) in every
    extended mode) and in none in single or double. WinUAE's own PREC step
    differs in 44 more: it keeps the extended exponent range, so `10^64`
    does not overflow in single - against 2.2.2's range control. **The
    model's default is therefore `rom64`**: WinUAE's 64-bit images and
    directions (a lead, the manual being silent on the ROM's bits - Daniel's
    rule of 8.6.15), then the manual's post-processing. **Decided (Daniel,
    2026-09-29): `rom64`** - the FPGA's constant ROM holds these 64-bit
    images and a direction bit per constant; Motorola's FPSP tables
    corroborate them (8.7.2).
20. **FINT and FINTRZ in single or double PREC.** 4-50 rounds "the extended
    precision number to an integer"; 2.2.2 rounds every register result to
    PREC. Default: both, in that order (two roundings); the others: one
    rounding to the coarser quantum, or the integer alone (WinUAE ignores
    PREC here).
21. **FGETMAN in single or double PREC.** 4-48 lists INEX2, OVFL and UNFL as
    "cleared", so the mantissa is not rounded to PREC (WinUAE agrees).
    Default: the mantissa unrounded; the other setting rounds it.
22. **FCMP with a NaN operand: N.** Table 2-1 sets N for a negative NaN
    result; FCMP's page says nothing. WinUAE clears the sign for the 6888x
    and keeps it for the 68040 - the kind of distinction a measurement
    makes. Default: N clear (the lead).
23. **The powers of ten the decimal conversions use** (found writing 5b).
    UM 4.3.3: the conversions "utilize the on-chip ROM values of powers of
    10" - the FMOVECR constants `$33-$3F`. Motorola's 68040 FPSP carries
    its own RN/RM/RP tables of them (`get_op.sa`), identical to the ROM's
    of item 19 except **10^2048's RM and RP entries, each one unit high**
    (`...C53D5DE5`/`...5DE6`; the true neighbours are `...5DE4`/`...5DE5`,
    as WinUAE has them). Default: the ROM's (one ROM in the chip); the
    other setting FPSP's verbatim. It shows only for values beyond 10^2048
    (4 strings in 900 directed conversions there), outside double's range.
24. **FMOVE.P of a zero, infinity or NaN.** The FMOVE page: SNAN "refer to
    4.5.4" and OPERR for any k-factor above +17. FPSP's `p_move` stores the
    register's image unchanged and says "Per the manual, status bits are
    not set" and "Operr is not signalled if the k-factor is greater than
    18". Default: the manual's page; the other setting FPSP's.
25. **Directed decimal-to-binary conversions on the wrong side of the
    value.** IEEE 754-1985 5.6, the source of 4.3.3's 0.97/1.47 bound, also
    asks a directed conversion to err in its direction; the manual states
    only the magnitude. FPSP's `decbin` (5b's algorithm) leaves the
    extended result on the wrong side in a few per cent of directed
    conversions (2-9% in the samples measured) and, after rounding to
    double, about 1 in 20,000 (3 of some 59,000 measured) - always inside
    the magnitude bound. Not a switch: it is what
    the algorithm does; whether the 68882 does the same is a question for
    silicon, with the rest of this list.
26. **Trigonometric results near their zeros** (found writing 5c). Within
    [-2pi, 2pi] the quadrant step subtracts multiples of pi/2 held to the
    datapath's 67 bits, so sin, cos and tan just beside k pi/2 carry that
    constant's error (about 2^-66 times k) as an *absolute* error: a result
    of 2^-30 there has lost some 36 of its bits. The manual's bound is
    stated "in general"; any 67-bit pi does this. Not a switch; reported by
    the checks.

Item 3 widens with the same reading: **FABS and FNEG** list INEX2 and OVFL
as "cleared" (4-18, 4-82) exactly as FMOVE does, against 2.2.2 - so the
`fmove_in_range` switch covers all three. WinUAE rounds all three to PREC
with the full flags, which is the default. FSCALE's "|src| >= 2^14: an
overflow or underflow always results" (4-93) is built as the manual says
it, the scale pushed past either end; the exceptional operand in that
corner is ours. Two rules the model takes from 8.6.4 that no table pins:
an integer store out of range after rounding gets OPERR **and** INEX2 when
the rounding was inexact (the OPERR + INEX2 pair of 6.1.9), and FCMP of
equal nonzero operands sets Z alone in every RND (the zero rows of 4-32
follow the destination's sign, not a subtraction; WinUAE agrees).

## 8.7 The reference model (8.4 item 5)

Started 2026-09-29. The model is the oracle for everything after it: the
microcode (item 6) and the RTL (item 7) must match it bit for bit, and it
must itself match the manual. **Daniel's decisions (2026-09-29):**
**mpmath** (1.4.1, installed with `pip --user`) is the independent
high-precision reference for the checks - the model itself uses only the
Python standard library; and **the transcendentals are CORDIC and shift-add
pseudo-division** - the algorithms an adder, a barrel shifter and a constant
ROM compute (UM 1.2: "a high-speed 67-bit arithmetic unit ... a barrel
shifter that can shift from 1 bit to 67 bits in one machine cycle, and ROM
constants (for use by the internal algorithms ...)"), whose iteration
counts sit near the manual's clocks. That the 6888x itself used CORDIC is
commonly said and is not sourced; the choice rests on the datapath.

**Two layers.**
- **The specification layer** says what every instruction must produce,
  from the manual. Operands are exact integers (a value is `m x 2^e`), and
  every result is rounded once from the exact value by 8.6.4's rules -
  which is what the 67-bit intermediate computes, its sticky bit being the
  OR of everything below (UM 3.x: "as if to infinite precision and then
  round"). It covers the data formats, the post-processing (underflow,
  round, overflow; PREC range control; the exceptional operand), FPSR
  (FPCC, EXC, AEXC, the quotient byte), every special case of 8.6.8, the
  arithmetic instructions, `FMOVECR`, the conditionals, and which trap is
  taken with what left in the register. For every instruction whose result
  the manual defines exactly - all but the transcendentals and the decimal
  conversions - this layer is the answer, and the microcode must equal it.
- **The algorithm layer** is the microcode's own arithmetic on a model of
  the datapath - 67-bit registers, the shifter, the constant ROM at its
  stored precision - for the transcendentals and the decimal conversions,
  whose results the manual bounds instead of defining (8.6.14 item 14).
  Its results are the microcode's to match bit for bit; it is checked
  against mpmath within the manual's bounds (1 ulp of double worst case,
  8.6.8; 0.97/1.47 of a decimal digit, 8.6.6).

**The switches** (`switches.py`; 8.6.14's items by number; the default is
the manual's reading, or where it is silent WinUAE's answer, marked as a
lead):

| item | switch | default | other setting |
|---|---|---|---|
| 1 | `fatanh_one` | as printed: +1 gives -inf, -1 gives +inf, DZ | sign(x) x inf, DZ (WinUAE; the 040 FPSP) |
| 2 | `flognp1_minus_one` | NaN and DZ (4-60) | -inf and DZ (6.1.6; WinUAE) |
| 3 | `fmove_in_range` (FMOVE, FABS, FNEG) | 6.1.4-6.1.5: overflows and underflows at the PREC range (WinUAE agrees) | the tables literally: the mantissa to PREC, the exponent range extended's |
| 4 | `rem_scale_inex` | 6.1.7 (INEX2 when re-rounding is inexact; FMOD's OVFL likewise) | the tables' "cleared" |
| 5 | `quotient_special` | the manual is silent: WinUAE's lead - NaN and invalid cases 0 and sign 0; source infinity or destination zero 0 with the sign XOR | the byte left unchanged |
| 6 | `redundant_opmodes` | WinUAE's lead (8.6.15) | unknown: the model refuses them |
| 7 | `fmovecr_undefined` | WinUAE's table (8.6.15), with its PREC/RND adjustments | unknown: the model refuses them |
| 8 | `reset_nan` | `$7FFF FFFFFFFF FFFFFFFF` | - |
| 9 | `sgl_truncate_bits` | 24 with the integer bit (4-98, 4-100; WinUAE) | 23 (4-17) |
| 10 | `version` | `$1F` | - |
| 11 | frames' CU and busy contents | zeros (WinUAE) | ours when the microcode defines them |
| 17 | `fpcc_table` | WinUAE's 6888x truth table (lead) | 8.6.9's equations on the bits as written |
| 18 | `fpcc_on_trap` | unchanged | set from the unwritten result |
| 19 | `fmovecr_documented` | `rom64`: WinUAE's 64-bit images and directions (lead), then the manual's post-processing | `exact` (rounded once from the true value); `winuae` (its whole procedure, no range control) |
| 20 | `fint_prec` | `twice`: to an integer, then to PREC | `once`; `int_only` (WinUAE) |
| 21 | `fgetman_prec` | `exact` (4-48; WinUAE) | `rounded` |
| 22 | `fcmp_nan_sign` | `winuae`: N clear | `sign` |
| 23 | `pten_tables` | `rom`: the ROM's powers of ten (4.3.3) | `fpsp`: FPSP's tables verbatim |
| 24 | `packed_out_special` | `manual`: SNAN, and OPERR for k > 17, for any source | `fpsp`: the image, no status |

Items 12 and 13 are the MPU's (the kernel's decode), 14 is what the
algorithm layer is, 15 records misprints, and 16 is item 6's decision: none
is a switch in the model, which executes one instruction at a time and
reports what it raised; the dialog and the frames' timing belong to the RTL.

**The checks** (`run.sh`, printing `pass`/`FAIL` lines and `==== PASS: n
checks` like the benches; exit status the verdict), from three sources, the
first two independent of the model's code: **the manual's own tables and
examples** transcribed by hand (8.6.8's special cases, FCMP's table, the
conditionals, the `FMOVECR` offsets, the k-factor examples of 8.6.6);
**mpmath** - every rounding of add, subtract, multiply, divide, square root,
the integer rounds, the format conversions and the constants, in each PREC
and RND, compared with mpmath's own correctly rounded result at the same
precision and exponent range (its denormal and overflow handling written
separately in the check, from 8.6.4); and **consistency** (FMOVE out and in
again, FNEG twice, FCMP against FSUB's sign).

**The work:**
- **5a** the specification layer's core: the formats but packed, the
  post-processing, FPSR, the arithmetic instructions, `FMOVECR`, the
  conditionals, the traps. **Done 2026-09-29** (`tools/fpu_model/`, below).
- **5b** packed decimal, in and out, on the algorithm layer (the constant
  ROM's powers of ten, UM 4.3.3), with the manual's k-factor vectors.
  **Done 2026-09-29** (8.7.2).
- **5c** the transcendentals on the algorithm layer: CORDIC for sin, cos,
  tan, atan, asin, acos and the hyperbolics, shift-add pseudo-division for
  e^x, 2^x, 10^x and the logarithms; each checked against mpmath within the
  manual's bound, with its iteration count set against Table 8-3.
  **Done 2026-09-29** (8.7.3).
- **5d** the vector export for `sim/fpu` (item 7): instruction, FPCR,
  operands, and the expected register, FPSR and trap, one line each.
  **Done 2026-09-29** (8.7.4) - **item 5 complete.**

### 8.7.1 5a as built (2026-09-29)

`tools/fpu_model/` - the model in five files, standard library only:
`xreal.py` (the extended value, one formula for every exponent below
`$7FFF` - value = m x 2^(e - 16446), since the 68882's denormals share the
normalized bias - and the B/W/L/S/D/X conversions in), `rounding.py` (the
post-processing of 8.6.4 on an exact intermediate: tininess before
rounding, the denormal LSB, overflow after, 6.1.4's default results, the
exceptional operand with its wrap and catastrophic cases), `constants.py`
(the documented constants from integer series to 256 bits; WinUAE's two
tables, as leads), `fpu.py` (the registers, FPSR, the traps, decode, the
instructions) and `switches.py` (8.7's table).

**In the model now:** FMOVE in and out (B, W, L, S, D, X), FINT, FINTRZ,
FSQRT, FABS, FNEG, FGETEXP, FGETMAN, FADD, FSUB, FMUL, FDIV, FSGLMUL,
FSGLDIV, FMOD, FREM (with the quotient byte), FSCALE, FCMP, FTST,
FMOVECR, the conditionals with BSUN, FMOVE(M) of the control registers,
FMOVEM of the data registers, the redundant opmodes, reset. EXC cleared
and AEXC accrued per 6.1.10; FPIAR loaded when an arithmetic exception is
enabled; the trap by 6.1.9's priority with the inexact trap on an
overflow; the register left alone under an enabled SNAN, OPERR or DZ; the
exceptional operand. **Not yet:** packed decimal (5b; it raises
`Unmodelled`), the transcendentals (5c), the frames' contents.

**The checks** (`run.sh`, 20 s): **`check_tables.py` 115 PASS** - every
special case of 8.6.8 for these instructions in every RND, the NaN rules,
FCMP's 36 cells, the conditionals (the equations and WinUAE's table agree
on the eight FPCC values the chip produces; they differ in 16 cells of the
other eight, item 17), FMOVECR's 22 constants against mpmath in every PREC
and RND, AEXC, the traps, reset, the control registers, FMOVEM's list
order, decode; **`check_rounding.py` 182 PASS** - every rounding of FADD,
FSUB, FMUL, FDIV, FSQRT, FMOVE, FINT, FINTRZ, FMOD, FREM, FSCALE,
FSGLMUL, FSGLDIV and the S/D/X/L/W/B stores, 400 operands a range across
the three formats' extremes (denormals, overflow, ties), in every PREC and
RND, against mpmath's rounding and exact rationals, plus the cases random
operands never reach (a tie broken by a sticky tail: 1/(2^p - 1); the
integer ranges' ends). **`mutate.py`: 32 of 32 documented faults caught**
(its first run caught 12 of 15 and showed three holes - the sticky tie, the
FMOVEM order, FREM's ties - which the checks now close).

**For Daniel:** item 4's default (6.1.7 decides FSCALE's and FREM's INEX2
and FMOD's OVFL, as item 3's precedent) is a reading of a
self-contradiction, not the manual's text - **confirmed by Daniel
2026-09-29**; and item 19's default moved to
`rom64` by the rule of 8.6.15 - **confirmed by Daniel 2026-09-29**.

### 8.7.2 5b as built: packed decimal (2026-09-29)

**The algorithm is Motorola's own statement of it.** The manual gives the
format, the k-factor, the bound and the use of the ROM's powers of ten,
not the algorithm. Motorola's 68040 Floating-Point Software Package
(Linux `arch/m68k/fpsp040`; `decbin.sa` 3.3 12/19/90, `bindec.sa` 3.4
1/3/91, `binstr.sa`, `get_op.sa`, `res_func.sa`, `smovecr.sa`; fetched to
the session scratchpad with Daniel's OK, not kept) emulates FMOVE.P for
the 68040, which has none, converting "a value in 68881/882 format", and
`bindec` sends its reader to "the 68882 manual for examples". It is
Motorola's software statement of the 68882's conversions - a lead, not
silicon - and **the model follows it step for step** (`packed.py`; FPSP's
step names A1-A16 kept), each FPSP floating-point instruction replaced by
the exact core rounding in the mode FPSP set for it:
- **In (`decbin`):** the 17 digits as an exact integer, the exponent less
  16; for |exponent| > 27 zeros appended or stripped to pull it toward
  zero (exact); 10^|exponent| by binary powering from the RN/RM/RP table
  that a 16-entry table picks from {RND, SM, SE}, each multiply in that
  mode; one multiply or divide in that mode; **INEX1 is that last
  operation's inexactness only**. Special forms as `get_op` has them: `$FFF`
  with SE and YY set is an infinity or NaN whose 96-bit image *is* the
  extended one; a zero integer digit and fraction is a signed zero
  whatever the exponent; non-decimal digits are used as their values.
- **Out (`bindec`, `binstr`):** ILOG from e + 0.f times log10(2) in RM; LEN
  from k; 10^|ISCALE| in the directed mode a second table picks from {RND,
  LAMBDA, sign}; the scale in RZ with the lost bits ORed into the LSB; FINT
  in the user's mode; one retry if the digit count is off; the digits by
  `binstr` from a 64-bit fraction rounded at bit 7 ("strip off lsb not
  used by 882"); the exponent's four digits the same way, the thousands in
  EXP3 with OPERR. Zero, infinity and NaN store the register image (item
  24).
- **Where FPSP cannot be followed literally**, the model takes its intent:
  a denormal's multiply by SCALE uses the true value (FPSP overwrites the
  operand's exponent with a masked negative one before handing it to the
  FPU in a busy frame, and at k = 0 divides the corrupted operand); a
  pseudo-denormal is a denormal with its true value (FPSP's normalizing
  loop shifts once before testing, dropping the integer bit). A13's
  second-pass carry ("and inc LEN", which would leave a leading zero digit)
  is kept as written and **never reached** (0 of 16,000; A3's estimate can
  be one low only just above a power of ten, which cannot round up to the
  next).

**Motorola's `smovecr` corroborates 8.6.14 item 19** independently of
WinUAE: its RN tables hold log10(2) and e truncated (`...FBCFF798`,
`...A2BB4A9A`, the RP tables one unit up), log10(e) is exact ("if 3, it is
exact"), and single/double PREC re-rounds the 64-bit entry "unchecked for
overflow" (as WinUAE's procedure does - the model's default keeps the
manual's range control). WinUAE's tables are FPSP's, bit for bit, except
10^2048's directions, where WinUAE is right (item 23).

**The checks** (`check_packed.py`, 49 PASS at 2,000 operands): the seven
k-factor examples of 4-69 digit for digit (static and dynamic k); Table
3-4's forms in (infinity, NaN bit for bit with and without SNAN, a zero
with non-decimal exponent digits, non-decimal digits in range); **decimal
to double within 0.97/1.47 of a unit** (worst 0.500 in RN, 1.001
directed); INEX1 exactly when inexact; **doubles to decimal within
0.97/1.47 of a unit in the last digit** (worst 0.501 RN, 1.025 directed),
always on the directed side, INEX2 exact; every denormal source in every k
and RND within a unit (worst 1.000); 10^0-10^27 exact both ways; OPERR for
k = +18..+63 (the k = +17 string: 2/3 gives `+6.6666666666666667E-001`)
and for a four-digit exponent (EXP3); the special forms out under both
item-24 settings. Reported: item 25's wrong-side count, item 23's
differences, the extended intermediate's worst error (about 7 units of
extended in directed modes).

**An independent audit** (a separate agent read `packed.py` against the
FPSP sources line by line) confirmed both 16-entry tables, every
comparison of A6-A16, the digit positions, the special forms and INEX1's
source, and found one real fault: **`bindec` crashed on most denormal
sources** (a tiny intermediate tripped an assertion) - fixed, and the
denormal check added; and one order difference in A9 for denormals
(FPSP multiplies by SCALE first, then 10^8 and 10^16 unconditionally) -
made literal, though no input was found where it matters.
**`mutate.py` (at 5b): 48 of 48 caught, 3 known survivors** with their reasons -
the reversed RZ table in `decbin` (a few units of extended, below the
manual's double-precision bound: only bit-exactness to FPSP, which the
audit covers, would see it), LOG2 for negative logs (A13 re-derives ILOG;
no output differed in 20,000), and the denormal A9 order (no difference
in 68,327).

### 8.7.3 5c as built: the transcendentals (2026-09-29)

`transcend.py` is the microcode's arithmetic, written down: **fixed-point
registers of 67 bits** (two's complement, 64 fraction bits, Q2.64) with
truncating arithmetic shifts - the adder and the barrel shifter; **I67**,
the internal floating format the compositions use (a 67-bit mantissa, an
unbounded exponent), every operation *truncating* its exact result - no
rounding hardware between steps; **constants as a ROM holds them**, 67-bit
words. The final result is post-processed (8.6.4) from its 67 bits with the
sticky bit set, so every computed result sets INEX2 (UM 4.3.2: "INEX2 ...
may be set even if an exact result is produced"; its FTENTOX #1 example is
checked).

**The manual fits this design closely.** 4.3.2 attributes the error to
"the highly recursive nature of the algorithms used" on "an ALU with a
finite precision of 67 bits", and 67 iterations of truncation on 64
fraction bits leave about 64 units of extended - its "typical" figure.
Table 8-3's times read as compositions of four cores, which is how the
algorithms are built:

| core (67 iterations) | functions | Table 8-3 (tail) |
|---|---|---|
| circular CORDIC, rotation | FSIN, FCOS, FSINCOS; FTAN = sin/cos | 373, 373, 433; 455 = 373 + a divide |
| circular CORDIC, vectoring | FATAN; FASIN = atan(x/sqrt((1-x)(1+x))); FACOS = 2 atan(sqrt((1-x)/(1+x))) | 385; 563 = sqrt + div + 385; 607 |
| shift-add e^r (factors 1 + 2^-i) | FETOX (x = n ln2 + r); FTWOTOX, FTENTOX (+ a multiply); FETOXM1; FCOSH = (t + 1/t)/2; FSINH, FTANH from e^x - 1 (the FPSP's formulas) | 479; 549; 527; 589 = 479 + div; 669, 643 = 527 + div + adds |
| shift-add ln (y driven to 1) | FLOGN; FLOG2, FLOG10 (+ a multiply); FLOGNP1; FATANH = ln(1 + 2x/(1-x))/2 | 507; 563 = 507 + 56; 553; 675 |

**Two things the plain algorithms get wrong, and the fixes:**
- **Small arguments.** Fixed point keeps *absolute* precision, so sin x,
  atan x, e^x - 1 and ln(1 + x) for small x would lose their relative
  precision. Each core has a **scaled** form: for |x| < 2^-s the registers
  hold y 2^s and z 2^s and the iterations run from i = s, 67 of them - the
  same adder and shifter, a different shift schedule - so the result keeps
  about 60 relative bits at any size down to where it equals x.
- **Range limits.** The sticky bit says "a little above", so a result whose
  true value lies just *below* a bound (tanh of a large argument, cos of a
  tiny one, sin at pi/2) must never be computed as the bound itself:
  `bounded()` returns 1 - 2^-67 for them, and no rounding mode carries sin,
  cos or tanh past 1 (checked in every mode).

**The ROM**: 34 words each of atan(2^-i), ln(1 + 2^-i) and ln(1 - 2^-i),
and 34 CORDIC gain corrections; beyond i = 33 the shifter synthesizes the
table entry (2^-i, or +/-2^-i - 2^-(2i+1)), the dropped term under 2^-4 of
the last bit even at the largest scaling. pi, ln 2, ln 10 and log10(e) at
67 bits.

**The documented loss is replicated.** FSIN reduces an argument outside
[-2pi, 2pi] by an exact remainder against **the 67-bit 2pi** (4-102); its
error n(C - 2pi) grows with the argument - median absolute error 1.8e-17
near 2^14, 1.5e-9 near 2^40, 1.5e-3 near 2^60, **all accuracy gone near
2^66-2^70 = "approximately 10^20"** - and both ends are checked, so a more
accurate (unauthentic) reduction would fail. Near k pi/2 inside the range
the same 67-bit pi limits small results (8.6.14 item 26, reported).

**The checks** (`check_transcend.py`, 44 PASS at 1,000 operands a
function): every special case of 8.6.8 for the eighteen functions in every
RND; items 1 and 2 in both settings; FLOGN(0) with DZ enabled leaves the
register; **accuracy against mpmath over each function's domain, every one
within the manual's 4096 units of extended** (log-uniform magnitudes from
2^-80 up, the edges near 1 for asin, acos, atanh and the logarithms):

| | median | worst | | median | worst |
|---|---|---|---|---|---|
| FSIN | 0.0 | 21 | FETOXM1 | 22 | 2373 |
| FCOS | 0.0 | 52 | FSINH | 17 | 1708 |
| FTAN | 0.0 | 25 | FCOSH | 0.0 | 1752 |
| FATAN | 0.7 | 8 | FTANH | 16 | 39 |
| FASIN | 0.4 | 12 | FLOGN | 0.4 | 124 |
| FACOS | 2.7 | 12 | FLOG2 | 0.5 | 91 |
| FETOX | 7.3 | 1151 | FLOG10 | 0.5 | 110 |
| FTWOTOX | 6.9 | 20 | FLOGNP1 | 2.1 | 73 |
| FTENTOX | 7.4 | 1575 | FATANH | 26 | 162 |

(units of extended; the large worst cases are the exponentials at large
|x|, where the 67-bit ln 2 in x = n ln 2 + r costs n x 2^-67);
INEX2 on every computed result; the ranges in every RND; UNFL for FSIN of a
denormal; OVFL for e^12000 with its exceptional operand wrapped, and
**e^60000 catastrophic (exponent `$0000`, 6-10)**; e^-11400 a denormal;
single PREC; FSINCOS's two registers, FPs = FPc keeping the sine, NaN and
OPERR for infinity; the documented loss at both ends.

**`mutate.py`: 61 of 61 caught, 5 known survivors** (about 5 minutes).
Among the new mutants, an *accurate* reduction (a 256-bit 2pi) is caught by
the documented-loss check - the point of making it a check. The two new
survivors are below anything the manual specifies: e^x - 1 without its final
residual (under 2^-66 of the result) and asin's 1 - x^2 unfactored (an
extended x has 64 bits, so the 67-bit square keeps 1 - 2d exactly). A
mutant that hung a check in an endless loop for 80 minutes - a precedence
slip in the mutant, not the model - led to a 300 s limit per check, a hang
now reported as one.

### 8.7.4 5d as built: the test vectors (2026-09-29)

The RTL's interface does not exist yet (item 6), so a vector describes the
*instruction*, not a bus protocol: what the bench loads, what it executes,
what it must find. `vectors.py` writes one vector a line, 17 fixed-width
hex fields: a group word; G (a command word) or C (a predicate); the
command; FPCR and FPSR before; FP1 (the source register), FP2 (the
destination) and FP5 (FSINCOS's cosine register) before, as 80-bit images;
an opclass-010 operand right-aligned in 96 bits (B W L S D X P as the
command's format says); Dn for a dynamic k-factor - then expected: FP2 and
FP5 after, FPSR after, the exception vector (`0B` for an F-line), whether
it is taken pre- or mid-instruction, a stored value (opclass 011, or a
conditional's answer), and the exceptional operand. FPIAR is left out (the
model has no program counter to load it with). The file's header records
the seed and the model's switches; **the file is generated, not kept** (a
4.5 MB `out/fpu.vec` at scale 1, `.gitignore`d) - item 7's bench
regenerates it.

**What is in it** (19,484 vectors at scale 1, in a second): `rounding`
3,000 register-to-register arithmetic, every PREC and RND, traps enabled
at random, a prior FPSR the instruction must clear or keep; `convert`
3,000 - `<ea>` in from every format (the extended's unused bits random:
don't-cares) and out to every format, packed with static and dynamic k;
`packed` 800 decimal strings in, specials and non-decimal digits among
them; `fmovecr` 1,536 - all 128 offsets in every PREC and RND; `transcend`
3,000 - bit-exact to the model, which is what the microcode must match;
`special` 6,016 - every operation on every pair of 16 special operands
(zeros, infinities, NaNs, a signaling NaN, denormals, a pseudo-denormal, an
unnormal, the largest numbers), all traps on and off; `cond` 2,048 - every
FPCC value, all 64 predicate codes, BSUN enabled and not; `decode` 84 -
opmodes `$40-$7F`, opclass 001, the redundant opmodes. **Added
2026-09-29 (8.9.1): `ties` 352** - exact halfway cases at every rounding
boundary in every mode, which random operands almost never make; 19,836 in
all.

**Proved readable both ways.** `replay.py` parses every line and runs it
back through the model to the identical line; `vecread.v` reads every field
of every line through `$fscanf` into registers of its width under Icarus,
and its per-field checksums equal the Python parser's (`vecsum.py`) - so the
format item 7's bench will use is known to work before any RTL depends on
it. `run.sh` does all of it: the four check suites, the vectors, the
replay, the Verilog read - **six `==== PASS` lines in 29 seconds**.

**The vectors found a model bug on their first run:** FSCALE by an enormous
source (around 2^16383 - the random checks stopped at 2^14) asked Python for
an exponent with 2^16383 digits. The scale is now held to +/-2^16 once past
2^14 - beyond the 17-bit intermediate's catastrophic limit, so nothing a
program can see changes - and the exponentials' overflow shortcut likewise;
two checks pin it (FSCALE by +/-2^16383: OVFL or UNFL, the catastrophic
exceptional operand `$0000`). `check_tables.py` is at 117.

## 8.8 The architecture and its microcode (8.4 item 6)

Opened 2026-09-29.

### 8.8.1 The first decision: the conversion unit's overlap

**Daniel (2026-09-29): the 68882 as built - full overlap, staged.** The
68882 has three units (UM 1.x): the bus interface unit, the conversion
unit (CU, "special purpose hardware for high-speed conversion of binary
real memory operands" - BR509) and the arithmetic unit (APU). The CU takes
the next general instruction and converts its operand while the APU is
still working on the previous one; only a third instruction makes the MPU
wait (UM 7.5). Software sees it (8.6.1): an enabled exception from the
first instruction can be reported *mid-instruction* by the second (frame
`$9`, the second's PC); FSAVE finds more in-flight states (busy frames);
the 5.2.2 handler rules exist for it; and Table 8-3's head/tail timing is
it. Our chip is built with that structure from the start - a CU datapath
of its own for the binary formats (packed decimal stays the APU's
microcode, 8.7.2), a two-deep instruction queue, register-conflict checks,
the mid-instruction report - and **brought up in two steps**: first the
controller runs one instruction at a time (the MPU still released while
the FPU computes, as on both chips), then the overlap is enabled, before
the design is called done. The rejected alternatives: one instruction at a
time for good (a 68881 in 68882 frames, which Motorola never made), and a
fully synchronous FPU (the MPU waiting on every instruction, losing even
the 68881's concurrency).

### 8.8.2 The second decision: the real coprocessor protocol

**Daniel (2026-09-29): the 68030's coprocessor protocol, as real bus
cycles.** The kernel runs the MPU's side of 030 UM Section 10 (8.6.12):
it writes the command or condition CIR, reads the response CIR, and acts
on the primitives - evaluate the effective address and transfer, transfer
multiple registers, transfer a main-processor register, pass the PC, take
a pre- or mid-instruction exception, come again (with interrupts) - as
CPU-space cycles (FC = 7, `$00022000-$0002201F`). GLUE decodes them and
selects the FPU, which terminates its own cycles (Guide p. 107), with the
data sheet's DSACK timing (BR509: save and response reads synchronous,
1.5-2.5 clocks). So MOVES to the CIRs, the bus timing, and "no coprocessor:
the first access bus-errors, the MPU takes an F-line" (030 UM 10.5) all
behave as documented. The rejected alternative - the FPU wired into the
kernel through a private port - would have lost exactly those.

**What the kernel has today** (surveyed 2026-09-29, `TG68KdotC_Kernel.vhd`,
10,780 lines, 127 micro-states): every F-line opcode except the PMMU's goes
to vector 11 *at decode*, with no bus cycle (kernel:7534-7623; FSAVE and
FRESTORE after their privilege check, "No external coprocessor",
kernel:7590/7610); `fline_is_fpu` is declared and never set; RTE already
accepts a format `$9` frame (kernel:8838, 8908-8914) but nothing builds
one. MOVES with SFC/DFC = 7 does make a real CPU-space cycle, which the
wrapper bus-errors (`tg68k.v`:208-211 - everything in CPU space but
interrupt acknowledge), and GLUE refuses all of CPU space (glue:150-165).
The wrapper's comment that its CPU-space bus error "is what makes an F-line
instruction trap" (tg68k.v:32-35) is wrong - the kernel traps at decode -
and goes when the protocol arrives. What the protocol can build on: the
shared EA states, the MOVEM loop (`movem1`/`movem2`, a mask encoder
clearing a bit per transfer), dynamic bus sizing, and MOVES. **An external
bus error at FC = 7 does not qualify for the restartable-read path** (only
FC = 1 data reads do, kernel:4483-4502), so the no-coprocessor F-line must
be taken on the initiating CIR access by the protocol's own rule, not by
the generic bus-error frame. The kernel side is about a thousand lines
(the donor's was ~1,270), specified in 8.8 and built in item 7.

### 8.8.3 The third decision: Table 8-3's clocks

**Daniel (2026-09-29): each instruction takes the manual's documented
time.** The FPU runs on the C16M clock enable, the SE/30's 15.6672 MHz
(Guide p. 107: the same clock as the MPU), and every instruction occupies
the units for the clocks Table 8-3 gives (8.6.13) - head, tail and total -
padding where the microcode finishes early, so floating-point software runs
at a real SE/30's speed. The counts are part of the specification; the
bench measures them. (The datapath fits every budget: FADD about 5 of its
35 tail clocks, a radix-4 multiply about 34 of FMUL's 55, a nonrestoring
divide about 67 of FDIV's 87, CORDIC on one adder about 200 of FSIN's
373.) Where Table 8-3 is a single figure for a data-dependent time (FREM,
FMOD, the reductions of large arguments), 8.8 derives the rule from the
68881's detail tables (UM 8.5.2), as 8.6.13 foresaw.

**What "the manual's clocks" can mean** (UM 8.0-8.2, read 2026-09-29).
The manual calls its times "reasonably accurate execution timing
guidelines, but not exact timings for every possible circumstance" - worst
cases measured with a 68020 on the same clock, no wait states, the response
and save CIRs read in five clocks - and "highly dependent on ... input
operand values". It splits an instruction into a **start-up phase** (the
dialog: the command, the PC, the operand), a **conversion phase** (Table
8-13, by format and data type), a **calculation phase** (Tables 8-14 and
8-15, by operation and operand types, with footnoted data-dependent parts)
and a **round/store phase** (by PREC, more for an overflow or underflow).
So a single number per instruction is not what the chip does. The design:
the FPU's **internal phases take the detail tables' times** (conversion,
calculation, round/store, each by the case the tables distinguish); the
**start-up phase is the dialog itself**, whose length the bus and the
kernel's protocol produce; head and tail follow from which unit is busy
when. The check: with the manual's reference conditions the end-to-end
totals reproduce Table 8-3. The detail tables are the 68881's (UM 8.5.2); the
68882's summary (Table 8-3) calibrates them where the CU changes the
picture. The tables are being transcribed from the page images (the OCR
garbles them) to `Docs\fpu\UM_section8_timing_tables.md`.

### 8.8.4 What the chip is made of (UM Figure 1-9), and the work

**Figure 1-9** (the 68882's simplified block diagram, read from the page
image) is the architecture to mirror:
- **APU control**: a clock generator; the **µPC**, a **µPC stack**
  (microcode subroutines) and a **µPC multiplexer**; the **µPC select PLA**
  fed by the **instruction decode PLA(s)** and the **instruction decode
  register**; and two ROMs, **µROM and nROM** - the 68000 family's two-level
  micro/nanocode, which is what "a two-level microcoded sequencer" (UM 1.2)
  means; built-in self-test registers (not reachable outside test mode).
- **APU datapath**: the floating-point data registers (exponent and
  mantissa halves), the constant ROM, the **barrel shifter**, a second plain
  **shifter** beside the ALU (the one-bit steps of shift-and-add multiply and
  divide), temporary registers, the **ALU**, **round logic**, and FPCR,
  FPSR and FPIAR. (A ⊗ between the barrel shifter and the temporaries is a
  junction or a multiplier; the figure does not say which, and nothing here
  depends on it.)
- **BIU**: CIR select and DSACK control; a box per CIR (control, restore,
  save, response with its **response PLA** and **status flags**,
  command/condition, instruction address, register select, operand).
- **CU**: an **"S, D, X conversion execution unit"** and a **conversion
  control unit**. So the CU converts single, double and extended only;
  integers and packed decimal are the APU's - which Table 8-3 shows (FMOVE
  .S/.D/.X in and out are the fast ones), and UM 1.2 says what it is for:
  "execute FMOVE instructions concurrently with arithmetic or transcendental
  operations".

**The work** (item 6, in order):
- **6a** (drafted 2026-09-29: 8.8.9-8.8.17) the architecture, written from UM Sections 1, 5 (the 68882's
  concurrency, Figures 5-2 and 5-3), 7 (the 68882's own dialogs, Figures
  7-19, 7-21, 7-28, 7-35) and 8 (interface overhead, the head/tail model,
  the 68881 detail tables): the units and their interfaces; the datapath's
  widths and registers; the microinstruction and nanoinstruction formats and
  the sequencer; the CU; the BIU and its dialog state machines; the frames;
  the timing budgets per instruction; the area estimate against 8.3's.
- **6b** (built 2026-09-29: 8.8.18, `tools/fpu_ucode/`) the microcode assembler (Python): source to the µROM/nROM images.
- **6c** (opened 2026-09-29: 8.8.19, `tools/fpu_ucode/sim.py`, `vec.py`, `ucode/`) an architectural simulator (Python) running the microcode on a
  bit-exact model of the datapath, checked against the reference model on
  all of 8.7.4's vectors and against Table 8-3's clocks.
- **6d** the MPU side of the protocol, specified for the kernel (item 7).

### 8.8.5 The pipeline: what the CU does (UM 5.1.1.2, Tables 5-1 to 5-6)

The BIU hands an instruction that arrives while the APU is busy to the CU,
which by the instruction's class does one of three things:
- **Minimum concurrency** (Table 5-1): B, W, L or P operands, FMOVECR,
  FMOVEM, FMOVE of the control registers, FTST of B/W/L/P, FSINCOS of
  B/W/L/P. For B, W, L the CU has the BIU fetch the operand, then waits for
  the APU and hands the instruction over; **a packed operand is not even
  fetched** until the APU is idle.
- **Partial concurrency** (Table 5-4): the arithmetic operations (monadic
  Table 5-2, dyadic Table 5-3, FTST, FSINCOS) with S, D or X sources or a
  register source: the CU prefetches the operand (the evaluate-and-transfer
  primitive with **CA = 0**, releasing the MPU as soon as the operand is
  written), converts S/D to the internal format, **tags its type** (normal,
  unnormal, denormal, zero, infinity, NaN), and waits to hand off.
- **Full concurrency** (Table 5-5): FMOVE FPm,FPn (X); FMOVE `<ea>`,FPn (S,
  D, X); FMOVE FPm,`<ea>` (S, D, X). The CU does these **entirely itself**,
  writing the register or the memory operand without the APU - except that
  it waits for, or hands off to, the APU when (a) FPm is the previous
  instruction's destination, (b) the data is a NaN, unnormal or denormal,
  (c) PREC is single or double, (d) INEX2 is enabled (stores), (e) the
  store overflows or underflows, (f) FPn is the previous instruction's
  destination. Stores use CA = 0 too, releasing the MPU when the operand
  has been read.
- **A third instruction** arriving while the APU is busy and the CU busy or
  waiting gets null CA = 1, IA = 1 until the CU is free - the 68881 waits
  on the APU, the 68882 on the CU.
- **Register conflicts** (5.1.2.2) are only: the previous instruction's
  destination is the next *fully-concurrent* instruction's source or
  destination.
- **The conditionals** (Table 5-6: FBcc, FDBcc, FNOP, FScc, FTRAPcc) run
  only with both units idle and every exception flag clear. With an
  exception pending in each unit the chip reports them one at a time, the
  conditional restarted after each handler - "a sequential execution model
  can be guaranteed".
- **The floating-point registers are "accessible to both the CU and APU
  simultaneously"** - a register file with two ports, which is what the
  FPGA's block RAM is.
- The effect (Figure 5-3, FMUL, FMUL, FMOVE): three instructions in the
  time of the first plus the second's computation; the FMOVE hidden
  entirely.

**The BIU's exception rule** (UM 7.5.4.2, read 2026-09-29): once an
instruction has made an exception pending, **every** later read of the
response CIR reports it - as a take pre-instruction exception when the read
starts an instruction, as a take mid-instruction exception once the
current instruction has issued its first real response (not the CA = 1
null a busy CU answers with). The acknowledge written to the control CIR
does **not** clear it (the 68881's does); only FSAVE, or FRESTORE of a
null frame, returns the chip to idle. So the response logic is: a pending
exception overrides whatever the current dialog would answer, from its
first real response on.

### 8.8.6 The units (a first draft)

**Register file**: FP0-FP7 in one dual-port block RAM (8 x 80 bits: sign,
15-bit exponent, 64-bit mantissa), port A the APU's, port B the CU's - UM
5.1.1.2's "accessible to both the CU and APU simultaneously". FPCR, FPSR,
FPIAR in flip-flops (the BIU reads and writes them for FMOVE of the control
registers and the frames; the APU updates FPSR at every round/store).

**The APU datapath** (Figure 1-9): 67-bit working registers (the
temporaries) in flip-flops; one **67-bit ALU** - add, subtract, the logic
operations masks need, compare - "used for both mantissa and exponent
calculations" (UM 1.2), so exponents are small integers held in the same
registers, not a second adder; the **67-bit barrel shifter** (any shift,
one clock); the **small shifter** at the ALU's output for the shift-and-
add steps - one bit a clock for divide and square root, three for the
**radix-8 multiply** (8.8.7); the **round logic** (G, R, S at the PREC or destination boundary,
the increment decision of Figure 6-3, the overflow/underflow detection of
8.6.4); the **constant ROM** in block RAM (the 22 FMOVECR constants with
their direction bits - 8.6.14 item 19 - the powers of ten, the CORDIC and
logarithm tables of 8.7.3, pi, ln 2 and the rest, about 200 words of 67 bits
plus exponent); a loop counter for the iterative algorithms. The algorithms
are 8.7.2's and 8.7.3's, already written in exactly these operations; the
exact arithmetic of 8.7.1 is the round logic applied to exact shift-and-add
results.

**The sequencer** (Figure 1-9): a µPC with a small µPC stack (subroutines -
the rounding tail, the conversions, the CORDIC cores are shared); a **µROM**
of next-address and nanoword-select words and an **nROM** of wide control
words, both in block RAM - the two-level scheme that deduplicates the
control words; an entry-point table (the "µPC select PLA") indexed by the
opmode, the opclass, the source format and the CU's operand tags;
conditional branches on the ALU's flags, the loop counter, the tags, FPCR
bits and the exception state; the checkpoints where an FSAVE may take a busy
frame (Table 6-5's middle phase).

**The CU** (Figure 1-9: "S, D, X conversion execution unit" and "conversion
control unit"): unpacks S, D and X into the internal format and tags the
type; packs S and D out with their own rounding at bit 23 or 52 and their
overflow/underflow detection (8.8.5's hand-off conditions); does the fully
concurrent FMOVEs on its own register-file port; holds a converted operand
for the APU; checks register conflicts against the APU's destination.
Integers and packed decimal are not the CU's.

**The BIU**: the CIRs of Table 7-2 at CPU space `$22000`, DSACK timing per
BR509 (the response and save reads synchronous), the response logic (the
"response PLA": a state machine per dialog of UM 7.5 producing the
primitives of Table 7-7, the pending-exception override above, protocol
violation detection per 6.1.12), the operand CIR's assembly of 32-bit
transfers into operands and frames, the register select CIR for FMOVEM,
an instruction address per pipeline stage (BIU, CU, APU - the APU's is
FPIAR), and the save/restore sequencing of the state frames (8.6.11).

### 8.8.7 The timing tables, and what they say the datapath is

**Transcribed 2026-09-29** from the page images to
`C:\temp\Mac\SE30\Docs\fpu\UM_section8_timing_tables.md` (by an agent;
all 25 tables of Section 8, every cell checked against the 1st edition, no
cell unreadable; the three edition differences and four printed oddities
noted there - Table 8-5's worked example is wrong in the 2nd edition and
right in the 1st; Table 8-14's operation notes exist only in the 2nd).
These are the 68881's phase times (UM 8.5.2); the 68882 summary (Table 8-3)
calibrates them. What they show about the machine:
- **Divide and square root: one bit a clock.** FDIV's calculation 78+
  clocks (64 bits and overhead), FSGLDIV 44, FSQRT 76+ - nonrestoring
  shift-and-subtract on the one ALU.
- **Multiply: about three bits a clock.** FMUL 46+ against FSGLMUL 34:
  radix-8 recoding fits both (22 steps for 64 bits, 8 for 24, about 25
  clocks of fixed work each); radix-4 would need 32 steps and leave 14.
  **So the multiplier is a radix-8 shift-and-add on the ALU** - Figure
  1-9's second shifter, three times the multiplicand prepared once - not
  the DSP blocks 8.3 first assumed; it is the chip's structure, costs no
  DSP, and fits the budget with margin. (8.3's "a multiplier of a few DSP
  blocks" is superseded.)
- **The transcendentals** (Table 8-15): FSIN and FCOS 360+, FTAN 442+,
  FSINCOS 420+, FATAN 372+, FASIN 550+, FACOS 594+, FETOX 466+, FTWOTOX and
  FTENTOX 536+, FETOXM1 514+, FLOGN 494+, FLOG2 and FLOG10 550+, FLOGNP1
  540+, FSINH 656+, FCOSH 576+, FTANH 630+, FATANH 662+ ("+" adds the
  rounding time, Table 8-18) - room for 8.7.3's 67-iteration cores on one
  ALU (about 200 clocks of CORDIC) and its compositions. **FSIN, FCOS, FTAN
  and FSINCOS assume "the source operand is in the range (-9 ... +9)";
  outside it "the appropriate REM calculation time required to perform the
  argument reduction must be added"** - the reduction is a remainder, as
  8.7.3 does it, and its time grows with the argument.
- **The simple ones**: FMOVE to a register 2+, FABS and FNEG 4+, FADD and
  FSUB 24+ (the exponents equal and the mantissa smaller), FINT 30 (8 for a
  zero fraction), FGETMAN 6; the special operand types their own small
  numbers (Tables 8-14/8-15, NAN1-NAN7 and IOP in Table 8-19).
- **Conversions**: input by format and type (Table 8-13: extended 8-26,
  double 14-48, single 16-48, integers 22-38); output S/D 38-80 by the
  overflow/underflow case (Table 8-17), integers 50-66 (Table 8-16);
  **packed decimal in 822 typical, 954 at most; out 1,942 typical, 3,674 at
  most** - 8.7.2's algorithm (up to thirteen multiplies of the powers of
  ten, a divide, a FINT) fits.
- **Rounding** (Table 8-18) by PREC, and the exception handling times
  (Table 8-19), the conditionals (8-7, 8-20), FSAVE/FRESTORE (8-8, 8-22),
  FMOVEM (8-6, 8-21), the start-up, null and operand-transfer times of the
  dialog (8-9 to 8-12) and the overlap-allowed times (8-25) complete the
  set the microcode and the BIU are timed against.

### 8.8.8 The MPU's side (6d): `docs/cp030_mpu_protocol.md`

**Written 2026-09-29** from the MC68030 User's Manual 3ed Section 10 (with
Section 8's frames and RTE; figures and tables read from the page images)
and the 68882 manual's Section 7 for the coprocessor's view: 1,170 lines,
every rule tagged [UM] (the 030 manual states it), [881UM] (only the FPU
manual), [inferred] or [silent]. It covers the CPU-space addressing and
the CIR map; decoding the F-line word; the general and conditional
algorithms, trace-pending, the interrupt points and every control-CIR
write; each instruction (cpGEN, cpBcc.W/.L, cpScc, cpDBcc, cpTRAPcc, cpSAVE,
cpRESTORE); all eighteen primitives, the 68882's six marked; the PC bit;
frames `$0`, `$2`, `$9` and RTE; protocol violations; cpSAVE and cpRESTORE
in detail; the subset the kernel needs; a primitive-to-bus-traffic table.
(Drafted by an agent from the manuals; its central rule checked here
against the text: a bus error on the *initial* CIR access is the F-line, on
any later coprocessor or memory access an ordinary resumable bus error -
030 UM 10.5.2.8, verbatim.)

**What the kernel needs** (its section 9): cpGEN, cpBcc, cpScc, cpDBcc,
cpTRAPcc, cpSAVE, cpRESTORE; the primitives null (every CA/PC/IA/PF/TF
form), evaluate-EA-and-transfer-data (every class, both directions,
lengths 1-12, register direct, immediate, the predecrement/postincrement
rules), transfer single main-processor register, transfer multiple
coprocessor registers, take pre- and mid-instruction exception; every other
primitive a protocol violation (what the 68030 does with an undefined code,
030 UM 10.4 - the 68882 never sends them). Two coprocessor-side facts the
MPU must respect: reading the response CIR **consumes** a service primitive
(read it exactly once per step), and after the acknowledge the 68882 keeps
answering the same take-exception primitive until an FSAVE.

**The manual's silences** (its section 12) are item 7's to settle as the
kernel is written; the evident defaults: the text over a contradicting
table (the transfer-multiple EA classes, 10.4.16 over Table 10-6); the
figures' bit 14 for the PC bit over the text's "Bit [4]"; the vector
*offset* in the format word (Section 8, and the 68882 manual's Figure 7-14)
over Section 10's "vector number" labels; for FRESTORE's modes the 68030's
own rule (it is the MPU's check). A bus error inside a dialog needs a
resumable fault frame whose internal words are ours (the 030's are "for
internal use only").

### 8.8.9 The clock and the pipeline (6a, 2026-09-29)

**The FPU clock is C16M**, the SE/30's 15.6672 MHz (8.8.3), which the core
makes as `c16_en`, an enable every second `clk_sys` (31.3344 MHz, `rtl/pll.v`).
One FPU clock is therefore two system clocks, and the design spends them so
that **one microinstruction completes every FPU clock with no delay slots and
no forwarding**:

| system clock | what happens |
|---|---|
| first half (p0) | the next-address logic reads the current microword (the register µIR) and the flags the *previous* microinstruction left; the µROM address, the nROM address and the operand addresses (temporaries, constant ROM, FP register) are registered into their block RAMs at its end |
| second half (p1) | the nanoword and the operands are out of their RAMs; the datapath computes (source muxes, barrel shifter, ALU, output shifter); at its end the result, the flags and the next microword (into µIR) are registered |

So a microinstruction may branch on, or take its add/subtract direction
from, the result of the one immediately before it - what the CORDIC and
nonrestoring loops need every step - and reads any temporary the previous
one wrote (written at the end of the previous FPU clock, read at the end of
p0 of this one). The combinational datapath gets a whole system clock
(31.9 ns) from block-RAM output to register, where a 67-bit barrel shift and
add take roughly half that on this part; the paths are single-cycle at
`clk_sys` and need no multicycle exceptions. The BIU and the CU run on the same
enable.

### 8.8.10 The datapath (6a)

**The internal format** is the manual's intermediate result (6.1, Figure
6-2): a **67-bit mantissa** - bit 66 the integer bit, bits 65-3 the fraction,
bit 2 guard, bit 1 round, bit 0 sticky - with the ALU's carry out as the
overflow bit above it; a sign; and an exponent held **biased** (extended's
bias, 16383) in **two's complement**. The manual's intermediate exponent is
17 bits; the stored field is **18**, so that FSCALE's clamped scale (8.7.1,
held to +/-2^16 past the 17-bit catastrophic limit) and every product and
quotient exponent (-16,507 to +49,211 before rounding) are represented
without wrap; the round stage forms the exceptional operand's 15 bits from
it as the model does. The same 67 bits serve the transcendentals' Q2.64
fixed point (two's complement, 64 fraction bits, 8.7.3). A **temporary word**
is therefore 86 bits: sign, 18-bit exponent, 67-bit mantissa.

| unit | what it is | built as |
|---|---|---|
| **temporaries** T0-T31 | the APU's working registers (Figure 1-9's "temporary registers"), 86 bits | two copies of a 32 x 86 simple-dual-port block RAM, one per read port (A, B), written together: 6 M10K |
| **FP0-FP7** | 80 bits each (sign, 15-bit biased exponent, 64-bit mantissa); port A the APU's, port B the CU's (8.8.6) | a true-dual-port block RAM, 4 M10K |
| **A source** | T[ra], FP[sel], the CU's converted operand, zero | mux, 86 bits |
| **B source** | T[rb], CONST[rb (+ LC)], FP[sel], the BIU operand (as a sign-extended B/W/L integer, or raw), the CU operand, the Booth multiple (+/-MD, +/-2MD, +/-3MD, +/-4MD), the round increment, the round mask, the square-root trial value (2Q with a one at the LC position), Q, SC, LC, zero | mux, 86 bits |
| **barrel shifter** | on B's mantissa: left, right logical, right arithmetic, 0-127 places (67 and more clears or sign-fills); amount from a nanoword literal, SC, LC or the leading-zero count; the bits shifted out right OR into the sticky flag | 7-stage log shifter, 67 bits |
| **ALU** | 67 bits and the overflow bit: A+B, A-B, B-A, A, B, AND, OR, XOR, A AND NOT B, with carry in; **add or subtract chosen by a flag** (the previous result's sign - nonrestoring divide and square root, CORDIC's direction - or the Booth digit's); flags Z, N, C (overflow bit), V | carry chain, 68 bits |
| **exponent mode** | a nanoword bit routes the 18-bit exponents into the ALU's low bits (sign-extended) and its result back to an exponent field - UM 1.2's one ALU "used for both mantissa and exponent calculations"; there is no second adder | muxes |
| **output shifter** | at the ALU's output: none, left 1 (divide, square root: the quotient bit into Q), right 1, right 3 (radix-8 multiply: the three low bits into Q's top) | Figure 1-9's second shifter |
| **Q** | the multiplier/quotient register, 67 bits, shifting with the output shifter; its low four bits give the radix-8 Booth digit | flip-flops |
| **MD, MD3** | the multiplicand and three times it (one ALU add at the start of a multiply); 2MD and 4MD are wiring | flip-flops |
| **LZC** | leading zeros of the ALU result's mantissa, 0-67, into SC or the shift amount | priority encoder |
| **round logic** | the boundary by mode (extended: least significant bit 3; double: 14; single: 43; and the integer boundary for FINT and integer stores, reached by first shifting the value there); guard, round and sticky below it (with the sticky flag); the increment decision of Figure 6-3 by RND and sign; outputs the increment and the truncation mask as B sources and the flags *inexact* and *carry* (round overflow) | logic |
| **SC, LC** | shift count (7 bits) and loop counter (8 bits: CORDIC's i, the divide and multiply steps, the digit loops); LC also indexes the constant ROM and places the square-root trial bit | counters |
| **constant ROM** | 256 x 86 bits (with spare bits for FMOVECR's direction flags, 8.6.14 item 19): the 22 FMOVECR constants, the powers of ten, the CORDIC and logarithm tables (34 words each, 8.7.3), pi and 2pi to 67 bits, ln 2, ln 10, log10(e), the CORDIC gains, each format's exponent limits | 3 M10K |
| **FPSR, FPCR, FPIAR** | flip-flops; the nanoword updates FPSR (8.8.11), the BIU reads and writes all three | registers |
| **exceptional operand, output buffer** | the 12-byte exceptional operand of the frames (8.6.11) and the 96-bit buffer the BIU reads stores from | registers |

**What the algorithms need, checked against it.** Addition: exponent
difference (exponent mode), alignment (barrel right with sticky), add,
normalise (LZC, shift, exponent adjust) - about ten clocks of FADD's 24.
Multiplication: MD3 = MD + 2MD, then 22 radix-8 steps (P = (P + d x MD) >> 3,
d in -4..4 from Q) for 64 bits and 8 for FSGLMUL's 24 - the 12-clock
difference Table 8-14 shows between FMUL 46 and FSGLMUL 34 is 14 steps
here. Division: 67 nonrestoring steps (R = 2R -/+ D, one quotient bit a clock
into Q, the remainder's nonzero into sticky) - FDIV's 78. Square root: the
same recurrence with the trial value - FSQRT's 76. FMOD and FREM: the divide
step in 64-bit chunks, the quotient's low seven bits kept - Table 8-14's
"40 + 70 x INT((1 + Ed - Es)/64)". CORDIC: per iteration X' = X -/+ (Y >> i),
Y' = Y +/- (X >> i), Z' = Z -/+ CONST[i], the direction from the previous
Z's (rotation) or Y's (vectoring) sign: **three clocks an iteration**, the
temporaries' roles alternating between unrolled pairs so no copy is needed
- 67 iterations about 200 clocks, inside FSIN's 360. The I67 operations of
8.7.3 are these with the result truncated at 67 bits; the rounded ones of
8.7.2 (packed decimal) are the same routines ending in the round logic in
the mode FPSP's step uses.

### 8.8.11 The microword and the nanoword (6a)

The 68000 family's two levels (UM Figure 1-9): the **µROM** says what
happens next and which nanoword to use; the **nROM** holds the distinct
datapath control words, shared by every microinstruction that does the same
thing to different registers. **The register addresses are in the
microword**, not the nanoword (the 68000 takes them from the instruction
register for the same reason), so one nanoword - "T[ra] - (T[rb] >> LC)
into T[rd]" - serves every routine; and the operand reads start in the same
half-clock as the nanoword read (8.8.9).

**The microword, 48 bits** (µROM 2,048 x 48, 10 M10K):

| field | bits | meaning |
|---|---|---|
| `nano` | 10 | the nanoword address (1,024) |
| `ra` | 5 | temporary on port A |
| `rb` | 8 | temporary on port B, or the constant ROM address when the nanoword selects a constant |
| `rd` | 5 | destination temporary |
| `seq` | 3 | next address: `next` (µPC + 1), `jump`, `call`, `return`, `branch if`, `branch unless`, `dispatch`, `wait` |
| `cond` | 6 | the condition tested, or the dispatch key (below) |
| `target` | 11 | the jump, call or branch target; for `wait`, the number of clocks to hold |

`wait n` runs its nanoword once and then holds the sequencer for n clocks:
**the padding** that makes each path take the manual's clocks (8.8.3), at no
cost in µROM.

**The nanoword, about 72 bits** (nROM 1,024 x 72, 8 M10K):

| field | bits | meaning |
|---|---|---|
| A source, B source | 2 + 4 | 8.8.10's lists |
| FP select | 2 | FP[source field], FP[destination field], FP[the FMOVEM iterator], FP[ra] |
| shift | 3 + 2 + 7 | kind; amount from literal, SC, LC or LZC; the literal |
| exponent mode | 2 | mantissa, exponent, both (a copy) |
| ALU | 4 + 2 + 1 | operation; add/subtract by flag (none, previous N, the B operand's sign, the Booth digit); carry in |
| output shifter and Q | 3 + 3 | the shift; Q hold, load, shift left with the quotient bit, shift right 3, load from B |
| destination | 3 | T[rd], FP[select], MD/MD3, the output buffer (high, low, extended), the exceptional operand, SC, LC, none |
| sign | 3 | the result's sign: A's, B's, their XOR, the ALU's N, 0, 1, inverted |
| sticky | 2 | hold, clear, accumulate from the shifter, accumulate a nonzero ALU result |
| round | 3 | none, extended, double, single, integer, by PREC, by the destination format |
| FPSR | 4 + 8 | the action (clear EXC at the start; set FPCC from the result; OR a literal into EXC; OR INEX2 from the round logic; set the quotient byte from Q and a sign; accrue AEXC at the end) and its literal |
| LC | 2 | hold, load the literal, decrement, load from the ALU |
| control | 4 | signals to the BIU and CU: release the MPU, operand wanted, result stored, exception pending, **checkpoint**, end of instruction |

**The conditions** (`cond`, 64): the flags Z, N, C, V of the last ALU
result; sticky, inexact and round carry; LC = 0; Q's low bit; the source and
destination tags one by one; FPCR's RND and PREC values; any enabled
exception (EXC AND ENABLE); a trap-enable bit by name; the command's
direction and format bits; the BIU's requests (FSAVE waiting, abort); the
CU's hand-off requests. **Dispatch keys** OR a field into the target's low
bits: the source/destination tag pair (5 x 5 of Table 8-13/8-14's classes,
in a 32-entry block per operation), RND, PREC, the source format.

**The entry table** (Figure 1-9's "µPC select PLA"): indexed by the command
word's opclass, opmode and format, it gives the first microword of each
instruction; 1,024 x 11 bits, 2 M10K.

### 8.8.12 The sequencer (6a)

µPC (11 bits), a **four-deep µPC stack** (Figure 1-9's; the rounding
tail, the conversions, the multiply, divide and CORDIC cores and the special
operand handlers are subroutines, the deepest nesting a transcendental's
composition calling a core calling the round), the `wait` counter, and the
next-address mux of 8.8.9. An instruction starts at the entry table's
address when the BIU (or the CU, handing over) starts it, and ends at a
microword whose control field says so; the sequencer then idles at a fixed
address until the next start.

**Checkpoints** (Table 6-5's "middle" phase): a microword marked checkpoint
is where a waiting FSAVE is let in (the BIU answers come-again until one is
reached, then takes a busy frame, 8.8.15). They sit at the loop heads of the
long instructions - each FREM/FMOD chunk, between the transcendentals' core
calls and at every 16th CORDIC iteration, between the packed-decimal
algorithm's steps - so none is more than about 70 clocks from the next. At a
checkpoint **only T0-T10 are live** and Q, MD and MD3 are dead: the
assembler (6b) proves it, and it is what lets a busy frame hold the whole
APU. A restore resumes at the checkpoint's successor with the µPC stack,
LC, SC and the flags as saved.

### 8.8.13 The CU (6a)

Figure 1-9's "S, D, X conversion execution unit" and "conversion control
unit", on FP port B, doing 8.8.5's three classes:
- **Unpack** an S, D or X operand from the BIU into the internal format:
  field routing, the exponent rebias (a 15-bit adder: -127 or -1023, +16383),
  the implicit integer bit, and the **tag** - normalised, zero, infinity,
  quiet or signalling NaN, denormal, unnormal (Table 8-13's classes). A
  denormal or unnormal is not normalised here: it is handed over tagged, and
  the APU's input conversion normalises it (the "not normalized" times of
  Table 8-13 are the APU's). **The same tag logic** sits on the APU's FP
  port A read, for register operands.
- **Execute the fully concurrent FMOVEs** (Table 5-5) itself, writing FPn
  through port B, or packing FPm into S, D or X for the BIU with its own
  rounding at bit 43 or 14 (a 53-bit incrementer and the guard/round/sticky
  decision) and overflow/underflow detection - handing over to the APU in
  each of 8.8.5's conditions (a) to (f).
- **Hold** a converted operand and its command for the APU (partial
  concurrency), and check register conflicts against the APU's destination
  (5.1.2.2).

**Program order is kept at retirement** (our reading of UM 5.1.1.2's
"sequential execution model", to be confirmed against its text in item 7):
an instruction the CU finishes while the APU is still busy on the one
before it does not touch FPSR until that one has retired; its FPCC and
EXC then replace the older ones and both accrue into AEXC, and an exception
it raises is reported after the older one's. **This gives the bench a
strong invariant**: with the overlap off (the first bring-up step, 8.8.1)
and on, every program leaves identical registers, FPSR and memory - only the
clocks, and the documented mid-instruction reporting, differ.

About 350 ALMs: the unpack and pack paths, the incrementer, the tag logic,
the CU's registers (its command, operand, tags and instruction address,
which are the idle frame's 32 bytes, 8.8.15), the control.

### 8.8.14 The BIU and its dialogs (6a)

The CIRs of 8.6.12 at CPU space `$22000-$2201F`, selected by GLUE; the
FPU terminates its own cycles (DSACK timing per the data sheet BR509, item
7). **The dialog state machine's states are Table 6-4's codes**, so the
idle frame's BIU flags (bits 30-28) are the state register itself:

| state (bits 30-28) | expecting | response CIR answers |
|---|---|---|
| `111` nothing pending | a command or condition write | null: `$0802` all idle; `$0900` released and still executing |
| `011` general instruction pending (bit 30 = 0: received, not started) | the unit to accept it | `$8900`/`$C900` come again until the CU (or the APU) takes it |
| `100` operand write pending | 4, 8 or 12 bytes to the operand CIR (bits 23-20 track the bytes) | the evaluate-and-transfer primitive of 8.6.12, CA = 0 forms for S, D, X |
| `110` operand read pending | the operand CIR read | the transfer primitive with DR = 1, after null CA = 1 while converting |
| `001` conditional pending | nothing: the BIU evaluates it when both units are idle | `$8900` while busy; `$0800`/`$0801` with TF |
| (internal) | the instruction address write; the register select read; a frame's words | the PC-pass forms first when asked; transfer multiple |

Across all states: **the pending exception overrides** (8.8.5: once an
instruction has made one pending, every response from the next real one on
takes it - pre-instruction when the read starts an instruction,
mid-instruction after); **protocol violations** (6.1.12) set bit 31 and
answer `$1D0D`; the control CIR's AB aborts only inside the abort window and
XA does not clear an exception; the save CIR starts an FSAVE (8.8.15), a
restore write an FRESTORE. One instruction address register per stage (BIU,
CU, APU - the APU's is FPIAR). The BIU also runs the conditionals (the
predicate against FPCC, 8.6.9, and BSUN) and FMOVE/FMOVEM of the control
registers directly - they never enter the APU. About 400 ALMs.

### 8.8.15 The frames, as we define them (6a; 8.6.14 item 11)

Staged through a 64-longword frame buffer (1 M10K): the FSAVE fills it,
then the BIU streams it to the operand CIR from the highest address down;
an FRESTORE fills it from the lowest address up, then unloads it.

**Idle, `$1F38`** (60 bytes, 8.6.11's documented layout): `$04` the
command/condition image; **`$08-$27` the CU's registers** (its command
word, instruction address, converted operand - sign, exponent and 64-bit
mantissa - and tag, the rest zero), restored verbatim; `$28` the
exceptional operand; `$34` the operand register image; `$38` the BIU flags.

**Busy, `$1FD4`** (216 bytes), taken at once in the initial phase and at a
checkpoint in the middle one (8.8.12). It keeps the idle frame's documented
positions **measured from the end** (the exceptional operand at `$C4`, the
operand register at `$D0`, the BIU flags at `$D4` - UM Figure 5-7's
handler arithmetic finds them on both), and in between:

| offset | contents |
|---|---|
| `$04` | the command/condition image |
| `$08-$27` | the CU's registers, as in the idle frame |
| `$28-$33` | the APU's control state: the resume µPC, the µPC stack, LC, SC, the flags (Z, N, C, V, sticky, inexact), the APU's command and register fields |
| `$34-$37` | the BIU stage's instruction address |
| `$38-$BB` | temporaries T0-T10, three longwords each (sign, exponent and the mantissa's top 13 bits; 32 bits; the last 22 bits) |
| `$BC-$C3` | reserved, written zero |
| `$C4-$D7` | as the idle frame's end |

The busy frame is ours, as the manual allows ("should not be modified in any
way", 6.4.2.3); nothing needs to restore a frame from real silicon.
FSAVE's clocks (Table 8-8: 102 idle, 336 busy) include the microcode's copy
of the temporaries into the buffer.

### 8.8.16 The timing budgets (6a)

Each instruction's path through the microcode, for each case the detail
tables distinguish, **takes exactly the table's clocks** (8.8.3): conversion
(Table 8-13, by format and both operands' classes), calculation (8-14,
8-15, by operation, classes, signs and the notes' conditions), rounding
(8-18, by PREC and outcome), output (8-16, 8-17) and the special operands
(8-19); the paths are shorter, and `wait` pads each to its figure. The
assembler (6b) computes every path's length and the simulator (6c) checks
the total for each vector's case against the tables, and with the manual's
reference conditions the end-to-end totals against Table 8-3. Three
figures need a rule:
- **Packed decimal** is "~822" in and "1,942 typical" out (maxima 954 and
  3,674): a typical figure for a data-dependent time. Default: the path
  pads to the typical figure and, where our algorithm's own time for an
  operand exceeds it, takes that time, capped at the maximum. **Confirmed by Daniel 2026-09-29.**
- **FMOD's formula** is printed without FREM's "/64": default, the same
  64-bit chunks as FREM (a missing line of type, not a different
  algorithm; the chunked divide makes 70 clocks per 64 quotient bits). **Confirmed by Daniel 2026-09-29.**
- **FSIN, FCOS, FTAN, FSINCOS outside (-9, +9)** add "the appropriate REM
  calculation time": the reduction is FREM's routine, and takes its clocks.

The 68882's own head and tail (Table 8-3) come from the CU's overlap, not
from the detail tables (which are the 68881's): 6c measures them from the
simulated dialog and compares.

### 8.8.17 The area (6a estimate, against 8.3's 3,000-5,000 ALMs)

| unit | ALMs | M10K |
|---|---|---|
| temporaries, FP registers | ~40 (read-write collision muxes) | 10 |
| A and B source muxes | ~300 | |
| barrel shifter with sticky | ~350 | |
| ALU, exponent mode, output shifter | ~250 | |
| Q, MD, MD3, Booth recoding | ~150 | |
| LZC, round logic | ~200 | |
| FPSR/FPCR/FPIAR, flags, exceptions | ~150 | |
| sequencer, µPC stack, entry, µROM, nROM | ~200 | 20 |
| constant ROM | | 3 |
| CU | ~350 | |
| BIU, dialogs, frame buffer | ~400 | 1 |
| **the FPU** | **~2,400 (+30% margin: ~3,100)** | **34** |
| the kernel's protocol (item 7) | ~400 | |

With the machine's 23,118 ALMs and 218 of 553 RAM blocks (compile 21):
about **26,600 ALMs (63%) and 252 blocks (46%)**, well under the ~38,000
ceiling of 8.3; the donor's 9,364 ALMs would have been three times this.
The first synthesis of the RTL (item 8) replaces the estimate, and checks
that every array here infers to M10K.

### 8.8.18 6b as built: the microcode assembler (2026-09-29)

`tools/fpu_ucode/`, Python, standard library only (it imports the reference
model from `tools/fpu_model/`); `run.sh` runs it all in a few seconds.

| file | what it is |
|---|---|
| `fields.py` | **the one definition of the formats**: every microword and nanoword field, its width, its values; the condition and dispatch-key lists; the constant ROM word; the entry-table index; and `verilog_header()`, which writes the same positions as `` `define``s for the RTL (item 7) - so the assembler, the simulator (6c) and the RTL cannot disagree |
| `consts.py` | **the constant ROM, built from the model's own tables**: FMOVECR's 64 rows by offset (`rom64` images and directions, 8.6.14 items 7 and 19), the atan, ln(1 + 2^-i) and ln(1 - 2^-i) tables and the CORDIC gains (34 words each), and 26 named constants (pi to 67 bits, ln 2, the format limits ...) |
| `asm.py` | the assembler: source to the µROM, nROM, entry and constant images (`$readmemh` hex), a listing, a symbol file and `fpu_ucode.vh`, with the checks below |
| `disasm.py` | images back to source; the listing uses it, and 6c's traces will |
| `test_asm.py` | 40 checks; `tests/sample.uc` is a program using every construct |

**The source** is one microinstruction a line, register-transfer clauses
then the sequencing: `d=T9 a=T7 b=T8>>>LC+SC alu=subadd dir=dflag | unless LCZ
goto cordic`. Directives give dispatch tables (`.table NAME KEY`, entries by
key with wildcards and a default), the entry table (`.entry reg,S,X $22
fadd`, `.entry cr`, `.entry out.X`, `.entry default`; `.redundant model`
fills 8.6.14 item 6's opmodes from the model's own `REDUNDANT` map),
`.org`, `.align`, `.export` (an address the RTL needs, into
`fpu_ucode.vh`) and `.include`. The code is laid out from 0 in source order,
the tables above it, aligned to their size, largest first. Nanowords are
deduplicated (the sample's 84 microinstructions use 39).

**The checks**, each shown failing on a source made to break it: capacity
(µROM, nROM, temporaries, constant names); every target defined; dispatch
tables complete and aligned, and dispatched by their own key; no
fall-through off the code or into a table; **the µPC stack** - no recursion,
calls at most four deep; **the checkpoints** - only T0-T10 live after one,
Q, MD and MD3 dead, by liveness over the whole program with calls and
returns (context-insensitive, so it can only over-report); the entry table
filled; and, per word, **one FP register a clock** (the port's one address,
8.8.9 - `d=FP[dst] b=FP[src]` is refused) and **one literal a word** (the
shift amount, the LC load and the EXC bits share it). Also checked: the
constant ROM against the model bit for bit - every table word, shifted into
place by i - s, equals `transcend.rom_fixed` for all i < 34 and s <= i - and
the sample's disassembly reassembles to the same words field for field.

**Refinements to 8.8.10-8.8.11 that writing it forced:**
- **Every field's code 0 is "nothing"** - a zero operand, `alu=nop` (no
  operation and *no flag change*), nothing written - so the all-zero
  nanoword is the NOP and an unmentioned field is inert. Any other
  operation sets the flags; a compare is one with no destination; a
  destination with no operation is refused.
- **The shift amount** adds two sources, **LC+SC and LC-SC**: CORDIC's
  shifts are i + s and i - s (8.7.3's scaled form), and the ROM tables'
  placement is i - s.
- **The ROM tables are two's complement, floor(v x 2^(64+i))**, so an
  arithmetic right shift by i - s gives the model's truncation toward minus
  infinity exactly, negative entries (ln(1 - 2^-i)) included.
- **A latched direction flag** (DFLAG, set by `dl=1` from a result's N):
  CORDIC's three words an iteration all need the direction the *third*
  word of the previous iteration computed, which the previous-result flags
  no longer hold by the second.
- **Two B sources, CMD and ZERO**, and **LZC also copies the amount into
  SC**, so the exponent is adjusted by it on the next clock.
- The nanoword is **57 bits** (8.8.11 estimated about 72); the nROM is
  1,024 x 57.

**Not done here:** path clocks. Paths through the microcode depend on the
data (the tags, the loops, the round outcome), so 6c's simulator measures
each vector's clocks against the tables instead of the assembler counting
them statically.

### 8.8.19 6c: the simulator and the microcode (opened 2026-09-29)

**The simulator** (`tools/fpu_ucode/sim.py`) runs the assembled images on a
bit-exact model of 8.8.10's datapath, one microinstruction a clock, and is
**the definition of what each field does** - the RTL (item 7) is written
against it, field by field. Its docstrings state the semantics; the ones a
reader of the RTL needs first:
- The next address is chosen from the flags the *previous* word left
  (8.8.9); the datapath then runs A source, the round logic on A, B
  source, the barrel shifter on B's mantissa, the ALU, the output shifter,
  then the writes. `wait n` runs its nanoword once and holds n clocks.
- The ALU computes exactly and keeps 67 bits (18 in exponent mode): **C is
  bit 67 of the result** - the carry of an add, the borrow of a subtract;
  N bit 66; V the signed overflow. `alu=nop` changes nothing.
- The round logic works on A with the sticky flag: the boundary (bit 3,
  43 or 14; RPREC's), guard, round and sticky below it, Figure 6-3's
  decision by RND and A's sign; B = RINC is the increment (or 0), B = RMASK
  the mask clearing the bits below; INEX is latched.
- R3Q shifts the exact signed sum right three places, the three bits into
  Q's top and Q's old bit 2 into QX; the Booth digit is -4q2 + 2q1 + q0 +
  QX. L1Q shifts left with the quotient bit (1 - N) into Q.
- SC is written saturated to 0-127; a shift by LZC also copies the count
  into SC.
- FPCC is set from the result word's class and sign (Table 2-1); an FP
  write takes exponent bits 14-0 and mantissa bits 66-3, and refuses an
  exponent outside 0-$7FFF (a microcode error).

Around it, the parts that are logic, not microcode, as the hardware will
have them: the BIU's decode (F-line for opmodes and FMOVECR offsets
`$40-$7F` and opclass 001), **the conditionals** (a 512-bit truth table -
the model's default for 8.6.14 item 17, WinUAE's, imported from the model
- plus BSUN), the CU's unpacking of S, D and X (8.8.13; B, W, L as
magnitude and sign), the tag logic, and the pending exception at END
(6.1.9's priority; pre-instruction for a register destination,
mid-instruction for a store).

**The harness** (`vec.py`) runs the model's vectors (8.7.4) through it and
compares all seven results of each; an instruction whose entry is still
`unimpl` is counted, not failed. `run.sh` runs the assembler's checks, the
assembly and the vectors.

**Added to the formats while writing the first microcode** (8.8.11): the
**rounding-precision register** RPREC (loaded by `ctl=rp_prec/rp_sgl/
rp_dbl/rp_ext/rp_dfmt`; `rnd=rprec` rounds by it; a dispatch key), so one
post-processing subroutine serves PREC, FSGLMUL/FSGLDIV's single mantissa
and the stores; `rnd=trunc` (bit 3, toward zero); the flag **S**, the last
result's sign; the dispatch key **OPMODE**; the FP selector C (FSINCOS's
cosine register - FMOVEM is the BIU's and CU's). Codes a dispatch key never
produces are filled with a word that jumps to itself. The assembler also
refuses, per word, what the datapath has only one of (a Q-shifting output
shift with a Q load; a shift by LZC with d=SC; an output shift in exponent
mode; RINC/RMASK without a round mode).

**The microcode** (`ucode/fpu.uc`), first part: the prologues by source kind
(register, S/D/X from the CU, B/W/L), dispatching on the opmode; **`pp`,
the post-processing of 8.6.4** - normalize, the underflow check, round, the
overflow check at RPREC, 6.1.4's infinity-or-largest by RND and sign,
6.1.5's denormalization with the sticky bit, and the exceptional operand
(rounded to 64 bits at its own exponent, wrapped by `$6000`, or exponent 0
past the catastrophic limits) when the trap is enabled; the monadic NaN
path (4.5.4, 8.6.14 item 18); FMOVE, FABS, FNEG, FTST and FCMP.

**Result, 2026-09-29: 4,578 vectors pass, none fail** - every `rounding`,
`convert` and `special` vector of those five instructions (their
underflow, overflow, trap and exceptional-operand cases included), all
2,048 conditionals, and every decode vector; 14,906 wait for instructions
not yet written. 262 microinstructions, 45 nanowords.

**Found on the way:** the model cleared EXC before taking FMOVECR's F-line
for offsets `$40-$7F` (every other F-line leaves the FPU untouched); fixed
in `fpu.py` to decode it first, the model's checks rerun clean, and the
vectors regenerated. And 8.6.14 item 17's text above says the equations are
the default, but the model's default is WinUAE's table (Daniel's rule of
8.6.15 for what the manual leaves silent); the BIU follows the model.

**The rest of 6c, in order:** the arithmetic (FADD/FSUB, FMUL/FSGLMUL,
FDIV/FSGLDIV, FSQRT, FINT/FINTRZ, FGETEXP/FGETMAN, FSCALE, FMOD/FREM, the
dyadic NaNs); the stores (B/W/L, S, D, X, with their own post-processing);
FMOVECR; the transcendentals; packed decimal; then the clocks - each path
padded to the timing tables (8.8.16) and measured per vector.

**2026-09-29, later: the arithmetic, the stores and FMOVECR done - 14,702
vectors pass, none fail**; 4,782 wait (the transcendentals and their
special operands 3,612, packed decimal 1,170). 1,036 microinstructions, 153
nanowords.

**The clocks forced a decision (Daniel, 2026-09-29: "add it").** Measured
against the detail tables (`clocks.py`: Table 8-13's FPm conversion + 8-14/
8-15's calculation + 8-18's rounding, extended, normal operands), the first
microcode was over by 2-18 clocks and FSQRT could not run a bit a clock:
exponents on the one ALU cost a compare and a branch for every range check,
three words for every normalization, and the post-processing 15 clocks
where Table 8-18 allows extended rounding 6. Added to 8.8.10's datapath,
about 100 ALMs, none of it software-visible:
- **TINY and HUGE**: comparators on each result's exponent against the
  rounding precision's limits - 8.6.4's range checks become conditions;
- **`osh=norm`**: normalize in one clock (the shift by the leading zeros
  and the exponent lowered by the count - a small exponent subtractor);
- **FSQRT's step**: `a2` (A's mantissa doubled before the ALU), SQT redefined
  as the nonrestoring root's trial `(Q << 1) | (11 or 01) << LC` by the
  direction flag, `osh=qbit` (Q |= the root bit at LC), and in exponent mode
  `osh=r1` (halving an exponent). The recurrence - radicand in [1/4, 1), 63
  steps to 2^-64, guard and sticky from the remainder - was checked against
  an exact integer square root on 20,000 cases before it was written;
- **`bx`**: an exponent into B's mantissa (FGETEXP) or a mantissa into its
  exponent (FSCALE);
- the rounding precision's fourth code **SGLX** (single mantissa, extended
  range: FSGLMUL/FSGLDIV, UM 6.1.4's note);
- **END accrues AEXC** (the BIU, as it takes the pending exception), and a
  dispatch table's slot may hold a microinstruction ending in goto or
  dispatch, not only a jump - two clocks off every instruction.
With them the post-processing is five clocks, and **every instruction
written is within the tables' budget** (FDIV 88-98 of 98; FSQRT up to 90 of
96; FSGLDIV takes FDIV's full quotient when the result may over- or
underflow - the exceptional operand is rounded to 64 bits - which the
manual's own FSGLDIV times show, 44 against 62 and 90). The nanoword is 60
bits.

**Found on the way, recorded rather than changed:** the model gives a
store's exceptional operand for any trap (an inexact trap that came with an
overflow reports it), a register destination's only for the OVFL/UNFL
vectors (`fpu.py` `fmove_out` against `_finish_reg`); the microcode follows
the model, and the difference is a question for silicon with 8.6.14's.

**The transcendentals' arithmetic redefined (Daniel, 2026-09-29: "Redefine
I67 ops").** 8.7.3's model computed its I67 values - 67 significant bits -
exactly and chopped each result; the datapath cannot at speed (FMUL's
radix-8 multiplier takes 64-bit significands, FDIV's divider and FSQRT's
recurrence 65 and 64, an exact add needs guard bits below 67). The
operations in `transcend.py` are now what the datapath computes, each by the
instruction whose machinery it uses: `i_mul` the 64-bit significands' exact
product, its fixed 67-bit window; `i_div` the operands chopped to 65 bits,
67 quotient bits; `i_sqrt` the 64-bit radicand, a 64-bit root; `i_add` the
smaller operand aligned by chopping; FSIN's reduction FMOD's loop with 2pi
to 65 bits (the documented loss near 10^20 begins a factor of four sooner).
The first measurement found FETOX, FETOXM1, FSINH and FCOSH at 10,000-
12,000 units of extended against the 4,096 bound - n up to 16,000 times ln
2's chopped bits - so their range reductions became **Cody-Waite** (ln 2
and, for FTENTOX, which now reduces x directly, log10 2 split into a short
high part - n times it exact on the multiplier - and a low one), after
which the exponentials are better than before: worst FETOX 21 units (was
1,150), FTENTOX 18 (1,575), FETOXM1 81 (2,373), FSINH 43 (1,707), FCOSH 17
(1,751); FCOS near its zeros 562 (52). `check_transcend` 44 PASS, the
model's suite clean, `mutate.py` 61 of 61 (the reduction mutant retargeted).
The vectors were regenerated.

**The microcode's helpers** (`ucode/transcend.uc`): `iadd`/`isub`, `imul`,
`idiv`, `isqrt`, `tofix`, `fromfix` - operands in T11/T12, the result in
T11 - checked by **`unit.py`**, which calls a subroutine directly on the
simulator and compares it with the model's function: 13,897 operand sets,
all bit-exact on the first run. Added for them: `lc=inc` and the conditions
LCEQ (LC = the literal) and LCSCEQ (LC - SC = the literal) - the CORDIC
loops count i upward - and the constant ROM's words shared between an
exponent-only and a mantissa-only constant (the assembler refuses a shared
constant read by the wrong field); the ROM ends at `$F0` with the
transcendentals' constants in.

**2026-09-29, end of the day: THE MICROCODE IS FUNCTIONALLY COMPLETE - all
19,484 vectors pass, none fail, none unwritten** (commit `86cdbab`): every
instruction the model executes, bit for bit - the arithmetic, the stores,
FMOVECR, the eighteen transcendentals (each also checked directly against
its `transcend.py` function by `unit.py`, 6,206 cases, bit-exact) and
packed decimal in and out (Motorola's FPSP decbin/bindec, A1-A16, step for
step). 2,289 microinstructions, 273 nanowords.

**Added on the way**, none of it software-visible: the **rounding-mode
register** RMODE (`ctl=rm_*`; FPCR's RND until set - packed decimal's steps
round in the modes FPSP sets, and quietly: `ppq`, `qmul`, `qdiv`, `qadd`,
`qint` leave FPSR alone), conditions RMRM/RMRP and a dispatch key on it;
**`ctl=retag`** (a packed source's tags from its converted value - the CU
cannot classify packed); the **µROM grown to 4,096 words** (a 12-bit
target, a 49-bit microword - 25 M10K where 8.8.17 counted 10); the
nanoword at 62 bits (ctl 5 bits); the constant ROM full, 256 words (FMOVECR's
32 repeated undocumented rows `$10-$2F` now hold named constants - the
microcode reads row `$10` for those offsets); and the assembler's
**checkpoint liveness made context-sensitive** (per-subroutine use/must-def
summaries, each checkpoint judged per call chain - the merged analysis let
a return reach callers that never made the call, and flagged registers the
busy frame need not hold).

**Clocks, measured against the detail tables** (`clocks.py`; normal
operands, extended): the arithmetic, the stores, FMOVECR and the
trigonometric group are inside their budgets (FSIN 349 of 380, FTAN 427 of
462, FASIN 523 of 570, FDIV 98 of 98); packed decimal too (in: 807 at
most against 954; out: 1,723 against 3,674). **Over**: the logarithms
(FLOGN 732 against 514, FLOG10/FLOG2 about 765 against 570, FLOGNP1 746
against 560, FATANH 787 against 682) and some exponentials (FETOX 558
against 486, FTENTOX 615 against 556, FCOSH 632 against 596, FETOXM1 566
against 534). Their shift-add loops spend 4-5 clocks a step, most of it
copying registers.

**The rest of 6c: the timing pass.** (1) Speed the shift-add loops -
unrolled pairs with the registers' roles alternating (no copies), as the
CORDIC loops already do - until every instruction is inside its table
figure; (2) pad every path to the tables with `wait` (8.8.16: the packed
typical figures; FMOD/FREM's per-chunk formula; the trigonometric
reduction's added REM time), `clocks.py` extended to check each vector's
case against its figure; (3) checkpoints in the long loops (8.8.12: every
~70 clocks - CORDIC, the shift-add loops, packed decimal; today only
FMOD/FREM's chunks have them) with the liveness check holding. Then item 6
is done and item 7 (the RTL, written against `sim.py`) begins.

**2026-09-29: the timing pass, step (1) done - every instruction inside
its table figure.** The four shift-add loops (`log1pf`, `log1ps`,
`expfrac`, `expm1s`) rewritten; the model's arithmetic unchanged, so all
19,484 vectors and `unit.py`'s cases still pass bit for bit. What made them
fast:
- **No copies**: the loop state (R/U or V, and Y/D or L) lives in two
  register pairs by turns (T8/T9 and T4/T10 or T4/T6); a taken step writes
  the other pair and control moves to the other pair's block.
- **Constants read where they are used**: `P = 2^(64+s-i)` and the table's
  word come straight from the constant ROM through the shifter in the word
  that needs them, instead of being staged in registers each i.
- **A retry needs no reload**: where SC is free (`log1pf`, `expfrac`) a
  step's last word advances LC, and a taken step retries the same i
  shifting by LC - SC (SC = 1) and reading the table one entry behind -
  **the assembler's new `K[name-n+LC]`** (the constant ROM's address is
  the field plus LC, so this is only a different field value). A step
  costs 3 clocks in `log1pf` and 2 in `expfrac`, taken or not.
- **The synthesized terms folded**: `C = floor(-2^(63+s-2i))` is kept as
  `-C - 1` (it shifts right by two each i and becomes 0 exactly when C is
  -1), so `P - C` and `-(P + C)` are one word, and none once C is -1 - the
  carry-in supplies the 1. For `expm1s` with u < 0, R is kept as its one's
  complement, so `R - (P + 1)` becomes `~R + P + 1`.
- **One new condition, LE** (N or Z: the last result <= 0): `log1ps`'s
  u < 0 steps are taken while `U + step <= 0`, which took two words.
- **Four blocks that fall through in a cycle** (fresh X, retry Y, fresh Y,
  retry X) cannot all be laid out straight; one edge is a copy of its
  target's first word jumping to the second, at no cost in clocks.

| instruction | before | now | figure |
|---|---|---|---|
| FLOGN | 732 | 456 | 514 |
| FLOG2, FLOG10 | 762, 769 | 488 | 570 |
| FLOGNP1 | 778 | 445 | 560 |
| FATANH | 787 | 540 | 682 |
| FETOX | 574 | 433 | 486 |
| FTWOTOX | 448 | 313 | 556 |
| FTENTOX | 615 | 472 | 556 |
| FETOXM1 | 586 | 439 | 534 |
| FSINH | 689 | 549 | 676 |
| FCOSH | 632 | 509 | 596 |
| FTANH | 680 | 541 | 650 |

(`clocks.py` now covers the transcendentals: Table 8-13's FPm conversion
14 + Table 8-15 + extended rounding 6, sources in (-9, +9) for the
trigonometric four; `profile.py OPMODE` charges an instruction's clocks to
the microcode's labels, averaged and for the slowest vector.) The one
figure `clocks.py` still flags, FSGLDIV's 104 against 58, is **the manual's
own case**: Table 8-14's SGLDIV note gives 44 clocks, 62 with an extended
overflow and 90 with an extended underflow - 14 + 90 = 104 exactly. So
step (2) needs the per-case figures, not one per instruction.
2,409 microinstructions, 278 nanowords.

**2026-09-29: the timing pass, step (2) done - every path takes its case's
figure.** Of the 19,484 vectors, the 16,596 the tables time (the rest are
the conditionals and the F-line decodes: the BIU's) take **exactly** the
detail tables' clocks for their case, 136 of them their own time over a
floor (below); all still pass bit for bit. `timing.py` is the specification: Tables 8-13 to 8-19
transcribed, and each vector's case chosen from the operands' classes (a
single or double source classed in its own format - a denormal there is
"not normalized") and from **the model's own rounding outcomes**
(`rounding.TRACE`: tiny, carried, overflowed, the overflow made by the
carry - changing nothing the model computes). `vec.py` checks every
vector's clocks against it.

**The mechanism** (hardware, none of it software-visible; about 40 ALMs):
- a **budget register** and the instruction's elapsed count, both 0 at its
  start: `ctl=budget` adds 2 x lit on any word (every figure in the
  tables is even), the WAIT sequencer op's cond field now picks **HOLD n**,
  **ADD n** (the large figures, 822 and 1,942) or **UNTIL** the budget; and
  **END holds until the elapsed clocks reach the budget** - so no path
  changes where it ends;
- **`ctl=rtime`: Table 8-18 as a lookup** beside the round logic - the
  microcode names the outcome's row (normal, carried, tiny, tiny and
  carried, overflow, overflow carried, overflow made by the carry, an exact
  zero) and the table gives the clocks by the rounding precision and mode.
  Its SGLX rows are FSGLMUL/FSGLDIV's notes less their base (18 overflow,
  46 underflow), so those two need no path of their own;
- **RB** (with `norb`/`rbon`) gates `rtime` and `rbudget` for the figures
  that already include their rounding (FINT, FGETEXP, FMOVECR, FATAN of an
  infinity, FACOS of 0, the X store) and for FSINCOS, whose one "+" is the
  sine's rounding.

**Where the figures ride.** Table 8-13: each prologue's first word
dispatches on the tag pair (`cv_*`, 25 slots) and the slot that reads the
destination adds the conversion; a monadic operation's memory source has
its own entries (`pro_xm`, `pro_sm`, `pro_dm`, `pro_intm`: the in-memory
monadic figures); the packed source's table follows its retag. Tables 8-14
and 8-15: on the operations' dispatch slots (a slot's jump word carries its
budget for nothing), the handlers adding the splits by sign (small branch
words where the slack is), the NaN identifiers NAN1-NAN6 and IOP. FSUB has
its own table (Table 8-14 prices five of its special cells 2 above
FADD's). Table 8-18: `pp`'s outcome words; `pp_md` is `pp` for FMUL and
FDIV, whose tiny intermediate takes 2 more (MUL 48+, DIV 80+). The tiny
result's carry into a new binade is detected ((rounded XOR chopped) >
chopped). Tables 8-16 and 8-17: the store slots and `ppm`'s outcome words.

**Changed on the way:** FSGLDIV takes FDIV's full quotient only when its
OVFL or UNFL trap is enabled and the result really over- or underflows (or
sits at the largest exponent, where the rounding may carry it over): the
exceptional operand is the only thing that needs 64 bits - otherwise the
27 quotient bits round the result, denormalized or not, and give its flags
exactly, in 44/62/90. FINT at extended precision writes its exact integer
without `pp`. `timing.py`'s S/D class fix found no microcode error.

**Readings of the tables** (none changes a result; each is `timing.py`'s
docstring too) - **all six accepted by Daniel, 2026-09-29**:
1. FPm and packed sources take the "Monadic or Dyadic" tables' row by the
   destination register's class for a monadic operation too.
2. FDIV's "denormalized" and FMUL's "not normalized" intermediate: the
   result tiny.
3. A domain error from a normalized source where Table 8-15 names no
   exception (FASIN, FACOS, FATANH beyond 1, FATANH at +/-1): IOP, as its
   note 4 does for FLOGNP1 at or below -1.
4. Table 8-18's extended "round overflow (not caused by rounding)" is an
   overflow whose rounding also carried; "(caused by rounding)" an overflow
   only the carry made; a tiny result rounded to zero is an underflow, "Result
   is Zero" an exact zero.
5. FSIN, FCOS, FTAN, FSINCOS from 9 up add FREM's time by 2pi (exponent
   2): 40 + 70 INT((1 + E - 2)/64).
6. FSINCOS's one "+": the sine's rounding.

**Own time over a floor - Daniel's packed-decimal rule (8.8.16) carried to
the other figures our algorithm cannot always meet - accepted by Daniel,
2026-09-29:**
- **FMOD, FREM, the large trigonometric reduction** (35 + 3 vectors, up to
  32 clocks over): the formula counts whole 64-bit chunks of quotient and
  gives the last, partial chunk nothing; our divider takes it a bit a clock
  (as the 68881's own 70 per 64 bits says it did). Meeting it would take a
  radix-4 divider the chip did not have.
- **FSGLDIV with its OVFL or UNFL trap enabled and the result over- or
  underflowing** (44 vectors, up to 40 over): the exceptional operand is
  FDIV's 64-bit quotient, which no path fits into 62 or 90.
- **FINT, FINTRZ whose result overflows the rounding precision** (54, up to
  11 over): Table 8-15's FINT figures carry no rounding time at all.
- Packed decimal, in and out: the typical figures, as ruled.

2,927 microinstructions, 391 nanowords; `test_asm` 54, `unit.py` 30,899.

**2026-09-29: the timing pass, step (3) done - the checkpoints.**
`cpgap.py` measures, over every vector, the longest run of clocks in which
a waiting FSAVE could not be let in (start to the first checkpoint, between
checkpoints, the last to END - END's padding excluded: the instruction is
finished and the BIU cuts the pad short); `cpcand.py` lists where the
assembler's context-sensitive liveness allows one (`asm.check.live_out`).
Before: transcendentals 300-580 clocks, packed decimal 800-1,726, with no
checkpoint at all. Now **every gap is at most 123 clocks**, and the ones
over about 90 are a single atomic step: a loop whose state is in Q, MD or
MD3 (FDIV's and the helpers' divides, FSQRT's root, the multiplies, FMOD's
last chunk), which cannot hold a checkpoint, with its setup and the
instruction's ending - 8.8.12's "about 70" where the loops allow. Where:
- every iteration of CORDIC rotation and vectoring (their state is in
  T5-T9), every fresh step of `log1pf` and `expfrac`, every i of `log1ps`
  and `expm1s` (their phase-B constant moved from T12 to T5);
- between the compositions' helper calls, a helper's result **parked** in
  T0-T10 for a word where no legal place existed (FASIN, FACOS, FSINH,
  FCOSH, FTANH, FLOG2, FLOG10: a word or two each, inside the budgets);
- packed decimal: `decbin`'s digit loop with its accumulator and source
  moved to T0 and T5 (free there), `bindec`'s digit count to T0 (unused by
  it), `pow10`'s loop, each quiet operation's end (`ppq`), the steps
  between `p10`'s powers (one parked).
The busy frame (8.8.15) therefore also holds **the budget, the elapsed
count and RB** beside the µPC stack, LC, SC and the flags. `run.sh` runs
`cpgap.py` (limit 125) after the vectors. 2,940 microinstructions, 399
nanowords.

**Item 6 is complete** (6a the architecture, 6b the assembler, 6c the
simulator and the microcode: all 19,484 vectors bit for bit, every timed
vector at its figure, the checkpoints). The six table readings and the
own-time floors above were accepted by Daniel on 2026-09-29. **Next: item 7 - the RTL, written
against `sim.py`** (fields.py's `verilog_header()` gives the formats).

## 8.9 The RTL and the benches (8.4 item 7)

Opened 2026-09-29 (Daniel: "start item 7"). Staged so that each step is
benched before the next depends on it:
- **7a the APU**: the sequencer, the datapath and the ROMs
  (`rtl/fpu/se30_fpu_apu.v`), with the CU's unpacking
  (`se30_fpu_unpack.v`) and the BIU's conditional predicate
  (`se30_fpu_cond.v`) as small modules; `sim/fpu` does the rest of the
  BIU's part as `vec.py` does. The gate: **all 19,484 vectors bit for bit
  and every one at the simulator's clocks**.
- **7b the CU and the BIU**: the CIRs, the dialogs of 8.8.14 as bus
  cycles, one instruction at a time (8.8.1's first step); the bench drives
  CPU-space cycles and the vectors run through them. **Also FMOVEM, FMOVE
  of the control registers and the null FRESTORE** (moved from 7c,
  2026-09-30: the bench can load and read the registers only through them).
- **7c the frames**: FSAVE and FRESTORE of the idle and busy frames
  (8.8.15), the checkpoints.
- **7d the kernel's side** of the protocol (8.8.8, `docs/cp030_mpu_protocol.md`),
  GLUE's CPU-space decode, `sim/busfault` and `sim/machine` unchanged.
- **7e the overlap** (8.8.1's second step) and the cputest corpus (8.4 item 7).

### 8.9.1 7a as built (2026-09-29)

**The clock** is 8.8.9's: two `clk` periods an FPU clock, `ce` (C16M) high
on the second. At the p0 edge the µROM (next address), T (ra, rb), K (rb,
or rb + LC) and FP port A (the nanoword's FP select) addresses are
registered; at the p1 edge the datapath's results, the flags and the next
microword, and the next nanoword's address (from the µROM's output, so the
nanoword is out for the whole of the next clock - the FP select it holds
must address port A at p0). Starting takes two FPU clocks before the first
microinstruction (the entry table and the destination's tags from FP[RY];
then the first microword), not counted in the instruction's clocks - 7b's
dialog accounts for them.

**The temporaries are not cleared at start** - block RAM cannot be, and
need not: every vector passes on the simulator with T0-T31 poisoned at
each start (a scratch copy of `sim.py`, 2026-09-29), so the microcode never
reads a temporary it has not written. Every flip-flop sim.py resets is
reset.

**Added to the tools for it:** `rtlvec.py` - the model's vectors with the
simulator's clocks as an 18th field (`out/fpu_rtl.vec`), and `--trace N`,
the state each microinstruction of vector N leaves, in the format the
bench prints with `+trace=N` (the first differing line is the first wrong
microinstruction); `fpu_ucode.vh` now also carries the wait modes, the
tags, Table 8-18 (`FPU_RTIME_TABLE`, from `fields.rtime`), the range
comparators' limits (`sim.RANGE`) and the conditionals' 512-bit table
(`sim.predicate`), so the RTL takes nothing from the Python by hand; the
assembler refuses a holding `wait` with `ctl=end` (sim.py counts END's hold
from the word's first clock, the RTL from its last; the microcode has
none), `test_asm` 55. The images the RTL reads are
`rtl/fpu/ucode/` (committed); `sim/fpu/run.sh` reassembles and fails if
they are stale.

**Result: the first full run passed - all 19,484 vectors bit for bit, every
one at the simulator's clocks** (13 minutes under Icarus, 8.9 million FPU
clocks), and the trace of a 285-microinstruction transcendental identical
to `rtlvec.py --trace`'s line for line. A first-time pass proves little
until the bench is seen to fail, so six one-line mutants of the APU were
run on two slices (400 `rounding`, 60 `transcend`): a clock short at END
(446 clock mismatches), SUB without its carry-in (43 fail), the shifter's
sticky dropped (76), the Booth digit without QX (35), DFLAG never latched
(64) - all caught - and **round-to-nearest with ties away from zero
instead of to even, which passed**. Over whole groups it failed only 4
vectors of 13,552: random operands almost never make an exact halfway case.

**So the vectors gained a `ties` group** (`vectors.py`, 8.7.4; appended
last, so every earlier vector is byte-identical): 352 exact halfway cases
in all four modes - a register rounded to single and double, half an ulp
added and subtracted at extended, single and double, FINT of n + 1/2, an
integer in rounded to single, stores of n + 1/2 to B/W/L and of halfway
mantissas to S/D. The model's suite passes (19,836 vectors), the microcode
passes all 352 on the simulator at the tables' clocks (`fpu_ucode/run.sh`
clean: 19,836, 16,948 timed, no checkpoint gap over 125), the ties-away
mutant now fails 50 of them, and **the RTL passes all 19,836 vectors bit
for bit at the simulator's clocks** (`sim/fpu/run.sh`, 13 minutes). **7a
is done; next 7b, the CU and the BIU.**

### 8.9.2 7b as built (2026-09-30)

`rtl/fpu/se30_fpu.v`: the chip, its BIU and CU around the APU, one
instruction at a time; its header is the contract. What was settled
writing it:

**The pins** are the MC68882's (BR509): the chip select as GLUE will drive
it (FC = 7, A19-A16 = `0010`, the ID) qualified by the strobe - the access
starts when it rises ("START", BR509 note 8) and ends when it falls - A4-A0,
R/W, D31-D0, DSACK1/0. A 32-bit port: the word CIRs answer DSACK1 alone
with their data on D31-D16, `$10-$1F` both (BR509 Table 5). **Timing:**
asynchronous accesses are acknowledged at the first `clk` edge that sees
them (within the data sheet's 50 ns); the response and save reads are
synchronous (note 3) - START sampled at a rising FPU clock edge, DSACK at
the falling edge a clock and a half later, 1.5-2.5 clocks from START
(specification 27); the FPU holds DSACK off only while a null restore
clears the registers and while FMOVEM fetches a register (UM 6.1.12: it
"synchronizes ... by delaying the assertion of DSACKx"). 7d fits this to
the kernel's bus cycle.

**The dialogs** are UM Figures 7-17 to 7-24, read from the page images (the
text copy garbles them): register to register and FMOVECR `$0900`/`$4900`;
`<ea>` to register - the CA = 0 forms `$1504/$1608/$160C` for S, D, X
(Figure 7-19, no final read) and `$9501/$9502/$9504/$960C` then `$0900` for
B, W, L, P (Figure 7-18); stores - `$8900`/`$C900` while converting (a
dynamic k-factor first asks for Dn, `$8C0r`), then `$B101-$B20C`, or the
CA = 0 forms `$3104/$3208/$320C` for S, D, X under 7.5.1.3's conditions,
and a CA = 1 store's final read gives `$0802` or take mid-instruction
(Figures 7-20, 7-21, 7-31); FMOVE of the control registers Table 7-5's
encodings then `$0802` (Figure 7-22); FMOVEM `$8C0r` for a dynamic list,
`$810C`/`$A10C`, the register select read, 12 bytes a register, `$0802`
(Figure 7-23) - the predecrement mode sends FP7 first, the others FP0
(bit n is FPn in the one, bit 7 is FP0 in the others, UM 4-79);
conditionals `$8900` while busy, then `$0800/$0801` or BSUN's `$5C30`
(Figures 7-24, 7-37). Execution starts at the first response read after
the command write (UM 7.2.1); the PC is requested in the first primitive
of an arithmetic instruction when any exception is enabled (Table 7-5's
note), and becomes FPIAR.

**Exceptions** (8.6.14 items 18-21, Daniel's defaults): the APU's end leaves
EXC AND ENABLE's exception pending; an arithmetic or conditional
instruction started with one pending gets `$1Cvv`, and a store reports its
own as `$1Dvv` at its end; XA does not clear it - the primitive stays in
the response register and is reported again - until a null restore (FSAVE
in 7c); an illegal command gets `$1C0B` after any pending exception, and XA
clears it; a protocol violation answers `$1D0D` until XA, which aborts
everything (the APU gained an `abort` input); the early operand read of an
FMOVE or FMOVEM out is never acknowledged; AB aborts the dialog in progress.
The null restore resets the registers to the NaN and FPCR/FPSR/FPIAR to
zero (6.4.4), as the reset does; the idle and busy formats read back as
invalid (`$0200`) until 7c.

**The bench** (`sim/fpu/tb_se30_fpu.v`, `BENCH=chip ./run.sh`, the default)
is the 68030's side of the protocol (`docs/cp030_mpu_protocol.md` sections
3-5 and 10): 36 directed checks of the dialogs, the reset state, the
exception rules, the violations, AB and the DSACK timing; then every vector
through bus cycles - a null restore, FMOVEM of FP0-FP7 and of FPCR/FPSR in,
the instruction with its primitives serviced, an FNOP to catch a pending
exception, FMOVEM of FP2 and FP5 and FMOVE of FPSR out - its seven results
against the model (the exceptional operand still read from the APU until
FSAVE shows it) and the APU's clocks against the simulator's.

**Found on the way:** a one-clock race - a conditional's response read
could land on the clock the APU went idle, before the pending exception
was registered from its end, so an FNOP missed an inexact trap (10 of the
first 1,350 sampled vectors); the BIU now counts the APU idle only the
clock after its end.

**Mutants** (each one line of `se30_fpu.v`, run on the directed checks and a
slice of vectors): no PC request (6 directed, 96 vectors fail), no CA = 0
input forms (1 directed - the results cannot tell), XA clearing the
exception (2 directed), no predecrement order (1 directed), a store's CA
ignoring INEX2 enabled (11 store vectors: the missing final read turns the
store's mid-instruction exception into a pre-instruction one), a byte
operand from D7-D0 (89 vectors) - all caught.

**Result: all 36 directed checks, and all 19,836 vectors through the pins
bit for bit, every one at the simulator's clocks** (14 minutes under
Icarus). **7b is done; next 7c, FSAVE and FRESTORE of the idle and busy
frames and the checkpoints.**

### 8.9.3 7c: the frames and the checkpoints (design, 2026-09-30)

Written before the RTL; UM 6.4.2-6.4.4, 7.5.3 and 7.5.4.6-7.5.4.7 read
again for it. This replaces 8.8.15's first draft where they differ.

**The phases (Table 6-5) as the chip decides them**, at the save CIR read:
- **reset** - no command or condition word accepted since the reset or a
  null restore (8.6.14 item 28): the null word at once, no frame.
- **the APU running** (starting, computing, or in its END padding): the
  come-again word, and a save request is latched. The APU stops at its
  next checkpoint (the middle phase), or finishes (the end phase: the BIU
  cuts the END padding short, as cpgap.py assumed); the next read then
  finds one of the two below. This is 6.4.3.4-6.4.3.5 with "the end phase"
  being wherever no checkpoint remains.
- **the APU stopped at a checkpoint, or the BIU receiving an
  instruction's operands** (expecting the instruction address, an operand
  write, Dn, the register select read, FMOVEM or control registers in -
  6.4.3.3's initial phase, where a page fault lands): **busy** at once.
- otherwise (idle, or an instruction received but not started, a
  conditional pending, a store's or FMOVEM's operand waiting to be read,
  a take primitive posted): **idle** at once - Table 6-4's codes and the
  operand register image are what the idle frame exists to carry.

After the last longword the chip is idle with nothing pending (7.5.3.1):
a stopped APU is dropped (its state is in the frame), the dialog and the
pending exception cleared. A command or condition written while a save is
still being waited for abandons it (the MPU took an interrupt and ran
something else): a stopped APU carries on - ours; the manual has the
interrupted FSAVE restarted by its RTE and says nothing of this.

**The format words**: null `$0038`, come-again `$0138`, invalid `$0238`,
idle `$1F38`, busy `$1FD4` (item 27: the size byte of the first three).
A save CIR read while a save or restore transfer is in progress returns
the invalid word and changes nothing (6.2.8, 7.5.4.6 - "not destructive");
the MPU's abort that follows ends the transfer, and the rest of the
suspended one's operand accesses are then acknowledged and ignored, as
7.5.4.6 describes, until the next instruction, save or restore. A restore
CIR write always aborts what is in progress (6.4.4, 7.5.4.7); the word is
valid if null (any version), `$1F38` or `$1FD4`; anything else reads back
`$0238`.

**The frame** is read from the chip's registers as it streams (the state
is frozen while it does) and written back into them as it arrives - no
frame buffer. Longword k at offset 4k:

| k | idle (14) | busy (53) |
|---|---|---|
| 1 | command/condition image: the last command or condition word, reserved half zero | the same |
| 2-4 | the CU's registers, ours: the dialog's data - the operand being received, the FMOVEM register being received, or the store's output buffer | the same |
| 5 | the dialog's state: BIU state, the state after the PC pass, longwords to move and moved, the store's CA and special-source bits, the control and FMOVEM masks, the F-line flag | the same |
| 6 | the take primitive posted (upper half) | the same |
| 7-9 | zero (7e's CU queue) | the same |
| 10-15 | - | the APU: stopped (1 bit), the resume µPC, the µPC stack and its pointer, LC, SC, the flags (Z N C V S, sticky, inexact, DFLAG, TINY, HUGE), LZC, the constant's direction, RPREC, the rounding-mode override, RB, the budget, the elapsed clocks, the command, both operands' tags |
| 16-48 | - | T0-T10, three longwords each: {sign, 18-bit exponent, mantissa 66-54}, mantissa 53-22, {mantissa 21-0, ten zeros} |
| N-4 to N-2 | the exceptional operand ({sign, exponent, zero}, mantissa high, low) | the same |
| N-1 | the operand register image: the next longword a pending operand read will take, else zero | the same |
| N | the BIU flags | the same |

The BIU flags (Figure 6-6): bit 31 a protocol violation posted; 30-28
Table 6-4's code from the state (011 a command received not started, 001
a conditional, 100 an operand write expected - operand, Dn, FMOVEM or
control registers in - 110 an operand read, 111 otherwise); 27 clear when
an exception is pending; 26 clear when an operand read is pending; 23-20
set with the operand register image; the CU's bits 25-24 and 19-16 `00`
and `1110` and bits 15-0 ones (WinUAE's idle words, the lead of 8.6.15).
**A restore uses bit 27 alone** of them - the type from EXC AND ENABLE as
FMOVEM left them (6-35) - and takes the rest from longword 5.

**What a checkpoint must hold**, measured: the assembler's liveness
(extended in a scratch run to the CU's operand, the raw operand and the
store buffer) finds no read of the converted or raw operand live at any of
the 84 checkpoints; the store buffer can be (packed decimal out), and
travels in longwords 2-4, which no dialog uses while the APU runs. The
operand tags are live at 12 (the packed store's rounding direction follows
the source's sign after `bd_6`'s checkpoint; FATANH) and travel in the
context. Q, MD, MD3 and T11-T31 are dead (the assembler's proof). Under `SIMULATION` a
restore that resumes the APU **poisons** T11-T31, Q, MD, MD3, QX and both
operand registers, so the vectors prove the claim rather than assume it.

**The APU** gains a stop state: a CHECKPOINT word executed with the save
request set completes and the sequencer stops, its next word's address
kept as the resume point; a restore loads the context and restarts
fetching there (the two fetch clocks are not counted, as at a start); T0-
T10 are read and written through the temporaries' ports while it is
stopped or idle.

**The bench** (`sim/fpu`): directed checks of every rule above; the
vectors read the exceptional operand from an idle FSAVE after the FNOP
(and bit 27 against the exception taken) instead of peeking the APU; and
`+detour` runs every vector with a context switch (UM Figure 6-7) at a
point chosen from the vector's index - any CIR access of its dialogs, the
loading FMOVEMs, or the APU's run - FSAVE, FMOVEM of everything out, a
null restore, an FSIN to disturb the temporaries, FMOVEM back in,
FRESTORE, and the dialog continued: every result bit for bit and the
clocks unchanged (at most the simulator's where the save cut the END
padding).

**As built (2026-09-30)** - `rtl/fpu/se30_fpu.v`, `se30_fpu_apu.v`, the
bench as above. The directed checks number 80 (44 of them the frames').
All 19,836 vectors pass bit for bit at the simulator's clocks with the
exceptional operand and bit 27 read from the idle frame. **Under
`+detour` all 19,836 pass too**, with every result and clock unchanged.
The context switches landed as 2,059 busy frames at a checkpoint, 2,239
busy in the initial phase, 2,086 idle, and 9,852 idle after a come-again
(the instruction finished first). **Fifteen one-line
mutants** of the RTL are all caught: T0-T10, bit 27, the output buffer,
the data slot's order, DFLAG, the µPC stack, LC, SC, the budget, the tags
not restored, FSAVE keeping the exception, the initial phase taken idle,
checkpoints never stopping, the resume fetching the entry, and an
abandoned save never resuming. Three survived at first and each showed a
hole in the bench, now closed:
- `check` passed on X, and `prims[nprim-1]` indexed past the 16 primitives
  kept, so a hung dialog read as a pass. X now fails, and `last_prim` is
  kept apart.
- The store test restored its frame over an undisturbed APU. An
  instruction now runs in between.
- No slice landed a detour on the checkpoints where the tags are live. A
  directed sweep now puts a busy save at 42 points of a positive FMOVE.P
  rounded toward plus, and the detour's FSIN now leaves a negative
  denormal's tags behind.

8.6.14 gains, with defaults for Daniel:

27. **The size byte of the null, come-again and invalid words** is
    "undefined" and "consistent" per version (Table 6-6). WinUAE writes
    the null word as `$0038`; default: `$38` in all three, the chip's
    idle size (a lead extended by its own logic).
28. **What leaves the reset phase**: "no FPCP instructions have been
    executed" (6.4.3.1). A null frame tells the handler the programmer's
    model need not be saved (6.4.5), so anything that can change it must
    count - FMOVE and FMOVEM of the registers included. Default: **any
    command or condition word accepted** (WinUAE: its arithmetic and
    conditional paths; its FMOVEM path could not be read with
    certainty).

### 8.9.4 7d: the MPU's side (opened 2026-09-30)

**Stage A, the bus - built 2026-09-30.** GLUE decodes CPU space type 2,
coprocessor ID 1 (FC = 7, A19-A13 = `0010 001`, 030 UM 10.1.4) as the
FPU's device select (`fpu_sel`, with AS*), and routes the FPU's DSACKs and
data onto the bus; the chip terminates its own cycles as on the board
(Guide p. 107). The wrapper (`tg68k.v`) now runs ID-1 cycles on the bus
like any other and bus-errors every other non-acknowledge CPU-space cycle
as before - a coprocessor ID with no chip, so its instructions take the
F-line (030 UM 10.5.2.8). (On the board nothing answers such a cycle and
UI6 never times FC = 7 out, so it would hang; the wrapper's rule is ours
and older than this section.) `se30_machine.v` instantiates the chip on
C16M, reset with the system - the RESET pin, which the RESET instruction
also drives. **The kernel still takes the F-line for ID 1 at decode**, so
no CIR cycle happens yet and the machine behaves as before: `sim/glue`
(98: ID 1 selected and answered, ID 2 no answer, no bus error), `sim/system`,
`sim/busfault` and `sim/machine` pass. ModelSim (the machine bench) caught
a use-before-declaration in `se30_fpu.v` that Icarus accepts.

**Stage B, the kernel - a structural choice for Daniel.** The protocol of
`docs/cp030_mpu_protocol.md` (its section 9's subset: cpGEN, cpBcc, cpScc,
cpDBcc, cpTRAPcc, cpSAVE, cpRESTORE; the null, evaluate-and-transfer,
transfer-single, transfer-multiple and take-exception primitives; frames
$0, $2, $9 and RTE of $9; the interrupt points; trace-pending; the F-line
on a bus error of the initiating access) can be built two ways:

- **(a) in the kernel's own micro-states**, as the 68030 does it in
  microcode: a dialog loop of new states (write command/condition, read
  response, pass PC, dispatch), the evaluate-and-transfer primitive
  re-entering the kernel's existing EA sequencing with the F-line word's
  EA field and the transfer length as the operand size - the kernel's PC
  advancing through the extension words is then scanPC for free - and
  MOVEM-style address stepping for 8, 12 and FMOVEM's N x 12 bytes;
  CIR cycles through the FC override MOVES already uses. Smallest, and
  the authentic shape; but every step touches the decoder, the address,
  data and FC muxes of a kernel that is a mesh of numbered upstream fixes
  (`BUG #nnn FIX`), and the EA sequencing assumes one operand per
  instruction. There is a precedent in this kernel: upstream added the
  PMMU's F-line instructions (PMOVE, PTEST, PLOAD, PFLUSH, CpID 0) this
  way - an F-line context latch (`fline_opcode_latch`,
  `fline_context_valid`), a decode state (`pmove_decode`) and EA
  micro-states of their own (`pmmu_ld_nn`, `pmmu_ld_dAn1`,
  `pmmu_ld_AnXn1/2`, `pmmu_ld_229_1-4`); the coprocessor's would sit
  beside them, CpID 1.
- **(b) a coprocessor engine beside the kernel**: its own state machine
  for the dialog and its own EA calculator (extension words fetched at
  scanPC through the kernel's bus path, so the PMMU still translates;
  registers through a port on the register file), taking the bus while
  the kernel waits, and handing the kernel only exception entry (vector,
  frame format, the frame $9 fields) and RTE of $9. Testable on its own,
  and it cannot disturb the existing instructions; it costs a second EA
  unit (some 300-500 ALMs by estimate) and is less the 68030's shape.

Recommendation: **(a)**, by the rule of 8.3 (authentic when smaller), with
the kernel's existing ModelSim benches (`kernel_bus`, `system`, `busfault`,
`machine`) as the regression gate on every step, and a new bench first -
`sim/cpfpu`: kernel, wrapper, GLUE and the chip on the bus with RAM,
running the model's vectors as 68030 programs (a small assembler of the
FPU instruction forms), failing today on the F-line. **Decided (Daniel,
2026-09-30): (a)**, in the kernel's micro-states.

**The bench is built** (2026-09-30): `sim/cpfpu` (ModelSim) - kernel,
wrapper, GLUE and the chip on the bus with RAM - runs `gen_program.py`'s
program, one instruction for each dialog stage B must carry (FNOP; FMOVE
to FPCR from an immediate; FMOVE in from Dn and from an immediate, the
CA = 0 form; register to register; stores to memory, to Dn and to an
absolute address after the command word; FMOVEM both ways; FTST and a
taken FBGT; FSAVE and FRESTORE) and checks 14 results in RAM, the end
marker and that CIR cycles happened. **Today it fails as it must**: the
F-line (`$DEAD000B`) at the first instruction, no CIR cycle.

**Stage B, as it is built (2026-09-30, Daniel's choice (a)).** In steps,
each behind the kernel's gate: `kernel_bus` at 8, 16 and 32 bits,
`system`, `busfault`, `machine`, and upstream's suite
(`sim/kernel_upstream`: 14 of 17 pass). Its three failures -
`tb_stack_frame_push`, `tb_odd_exc_flags` and `tb_basic_exception_flags` -
predate this work: `ours.txt` records them, and HEAD's kernel fails them
the same way.
- **B1** (built): cpGEN and cpBcc.W. The null primitive in every form
  (CA = 1 re-reads, CA = 0 ends, TF for a conditional), the PC pass, and
  take pre-instruction (XA, then frame $0 at the operation word, its
  vector from the primitive). Every other primitive takes the F-line for
  now.
  - **How:** decode sends CpID 1's cpGEN and cpBcc.W through the PMMU's
    F-line context, so the second word is fetched and latched
    (`fline_brief_latch`), and then into `cp_decode`. Each CIR access is
    one beat, scheduled by the state before it: `cp_cir_next` puts CPU
    space $22000 + the register on the address chain (absolute,
    `use_base` 0) and the data at the head of the `data_write_tmp` chain,
    and `cp_cir` follows the beat to drive FC and the PMMU's FC to 7
    (untranslated). The response word is `cp_prim`, latched at the read's
    completion.
  - **Retiring:** schedule a fetch and retire in `nop`, on the fetch beat.
    Retiring on an idle beat takes the next opcode from the prefetch
    buffer, which still holds the second word the instruction consumed.
    The first run showed exactly this: FNOP's $0000 was decoded as
    ORI.B.
  - **cpBcc taken:** `fline_opcode_pc`, the displacement word's address,
    plus the displacement, through the PC adder.
  - **Test:** `sim/cpfpu` `PROG=b1` (the default) passes, 101 CIR cycles:
    FNOP, FMOVECR, FTST, FBGT and FBEQ taken, FBNE not taken, FSIN's
    come-again loop, and an illegal command word taken through `$1C0B`,
    XA and the F-line, stacked as format $0, vector offset $2C, PC the
    operation word. `+trace` prints every bus cycle and micro-state.
- **B2** (built): the operand transfers.
  - **What:** evaluate EA and transfer data (5.7) in every mode but the
    full extension format, all lengths, both directions; transfer single
    main-processor register (5.11, to the coprocessor); transfer multiple
    (5.14, FMOVEM), static and dynamic.
  - **The effective address** is computed in the dialog (`cp_eat`,
    `cp_ea1`) from the register file and the extension words it fetches:
    the kernel's PC is scanPC, so a word fetched is a word consumed. The
    kernel's own EA sequencing is not used - it assumes one operand per
    instruction, fetched at decode, and the primitive asks later. The
    PMMU's instructions have their own EA states for the same reason.
  - **The operand** moves a part at a time (a long, or a tail of 2 or 1)
    between memory at `cp_ea` and the operand CIR. Memory beats go on the
    address chain as the CIR beats do, first beat only, so a split
    (misaligned) operand's later beats take the adder's address.
  - **Registers:** a write port on the register file (`cp_reg_we`) serves
    -(An) before the transfer, (An)+ after it (a byte through A7 moves
    it by 2), FMOVEM's final An, and a register destination (Dn's low
    byte or word, An sign-extended).
  - **Checks:** an EA outside the primitive's class writes AB and takes
    the F-line (5.7 F1, 5.14). The protocol violations (P2-P4, an odd
    FMOVEM length) and the full extension format (bd, od, memory
    indirect) take the F-line for now; B3 gives the violations their
    frame $9.
  - **Test:** `sim/cpfpu` `PROG=b2` passes 27 results and the end marker
    (849 CIR cycles). It covers (d16,An), (An)+ and -(An) with a word and
    a byte, a misaligned double through (d8,An,Xn.W*2), (xxx).L, (d16,PC),
    byte and word immediates, a byte into Dn, a dynamic FMOVEM list,
    FMOVEM of FPCR/FPSR/FPIAR to memory, packed decimal with a static and
    a dynamic k-factor, and an An destination refused with AB and the
    F-line. `PROG=full` passes all but FSAVE and FRESTORE (B4), and
    `PROG=b1` still passes. The gate is unchanged.
- **B3** (built 2026-09-30, after B4): the conditionals' completion,
  frame $9 and its RTE, take mid-instruction, the MPU's protocol
  violations, and the interrupt points. There are three benches, each
  written first and failing first (the F-line at the first instruction
  concerned).
  - **B3a, the conditionals:**
    - cpScc, cpDBcc and cpTRAPcc (001) and cpBcc.L (011) take cpGEN's
      decode path, their second word latched. The condition word goes to
      the condition CIR; cpBcc sends the operation word, as before.
    - Scc's EA must be data alterable and TRAPcc's opmode 2-4; anything
      else takes the F-line at decode.
    - The dialog's final null gives TF, and `cp_cond` completes:
      - cpBcc.W as in B1.
      - cpBcc.L fetches the displacement's second word, and the branch uses
        both.
      - cpDBcc fetches its displacement. True: the next instruction.
        False: Dn.W - 1 at this edge, then the branch unless the count was
        0 - from the displacement word, through the PC adder with base
        `fline_opcode_pc` + 2.
      - cpTRAPcc skips its 0, 1 or 2 operand words. True: vector 7 with
        frame $2 (trap00), the PC field the next instruction (`cp_npc`),
        the instruction-address field this one (exe_pc).
      - cpScc evaluates its EA after the dialog, as UM 4.3 has it
        (extension words at scanPC), and writes the byte through B2's
        transfer loop: all ones for TF = 1, else zero. -(A7)/(A7)+ move A7
        by 2. Dn takes the low byte only.
    - **Test:** `PROG=b3a` passes 20 checks: FScc to Dn, (An), (An)+,
      -(An), (d16,An), (xxx).W, (xxx).L and -(A7); FDBEQ looping three
      times to D3.W = -1 and FDBGT falling through; FTRAPcc with no
      operand, .W and .L, false and true (frame $2's fields); FBGT.L taken
      and FBEQ.L not.
  - **B3b, frame $9:**
    - Stacked by `cp9a-c` (tempEA; the internal register with the
      operation word; the instruction's address), then trap0-2 (the format
      word "1001", scanPC, SR) - `cp_f9` selects the format and scanPC.
    - The internal register is ours to define (UM Table 8-6: "internal
      registers"). It holds the word after the operation word, so an RTE
      can rebuild the dialog's context from the frame alone.
    - scanPC is TG68_PC when the primitive came, except for cpBcc, where it
      is the displacement's first word (UM 10.4.1). The kernel's own PC is
      past that word, so an RTE into a cpBcc fetches it once more.
    - tempEA (`cp_tea`) is the EA the last primitive evaluated, before any
      transfer moved `cp_ea`.
    - **Take mid-instruction** ($1Dvv) writes XA, then frame $9 with the
      primitive's vector.
    - **The MPU's protocol violations** write no control CIR and take frame
      $9 with vector 13. That covers:
      - 5.7's P2-P4 and 5.14's odd length;
      - a conditional's primitive outside its category, or transfer single
        register with CA = 0;
      - every primitive the kernel does not carry: busy, supervisor check,
        take post-instruction and the rest, which the 68882 never sends
        (`docs/cp030_mpu_protocol.md` 11.3).
    - **RTE of $9** reads the frame as before (rte5) and keeps its three
      high longs. When the operation word is an F-line word, it goes to
      `cp_rte` instead of fetching at the restored PC:
      - the F-line context comes back from the frame - the operation word,
        the internal register, the second word's address;
      - so do `opcode`, `opcode_pc` and `exe_pc`;
      - the PC is scanPC from the frame;
      - then the response CIR is read again (UM 8.1.13).
    - The CIR address now carries the operation word's CpID (UM 10.1.4.2),
      so a frame naming another coprocessor reads that one's response CIR.
      Only ID 1 answers; the others' bus error is B5's.
    - **Test:** `PROG=b3b` passes 15 checks:
      - take-mid from an FMOVE.B of 1000 with OPERR enabled: vector 52,
        every field of frame $9 checked, tempEA the destination (A0). The
        handler FSAVEs to clear the exception, and the RTE ends the dialog
        on $0802.
      - a protocol violation. The 68882 sends nothing the MPU refuses:
        FMOVE.D to Dn gets class 010 (memory alterable), so it takes AB and
        the F-line (F1 before P2), as it should. So the bench answers an
        FNOP's first response read with the reserved $0B00: vector 13,
        scanPC the displacement word, and the RTE back into the cpBcc.
  - **B3c, the interrupt points** (UM 10.5.2.6):
    - A pending interrupt (the boundary's test) is taken in two places:
      - at a null primitive with CA = 1 and IA = 1 whose PC request has
        been served: frame $9;
      - at cpSAVE's not-ready: frame $0 at the operation word, so the RTE
        starts cpSAVE again.
    - `cp_irq_take` raises `setinterrupt`, so the boundary's own dispatch
      runs: IACK in int1, then cp9a, or trap0 for cpSAVE.
    - For interrupts, trap1's `writePC` branch now stacks frame $9's scanPC,
      or cpSAVE's operation word, instead of the boundary latch.
    - cpRESTORE's not-ready services nothing, as before.
    - **Test:** `PROG=b3c` passes 13 checks. The bench raises VIA1's IRQ
      at the first come-again (the FSIN's, the FMOVECR before it still
      running) and at an FSAVE's not-ready:
      - the frames' fields are checked;
      - FBGT after the interrupted FSIN is taken;
      - the restarted FSAVE's frame is valid;
      - sin(1.0) comes through the save and restore bit-exact in single
        precision.
  - **Not in B3** (B5, with trace): the trace-pending cases - the null
    primitive with CA = 0, IA = 1 and PF = 0 as an interrupt point, and
    reading on after CA = 0. With tracing on, an interrupt inside a dialog
    would take the trace frame's path; that is not handled yet.
- **B4** (built 2026-09-30): cpSAVE and cpRESTORE (030 UM 10.2.3,
  Figs. 10-16 and 10-18; 881UM 6.4.3-6.4.4; `docs/cp030_mpu_protocol.md`
  section 8).
  - **Decode:** CpID 1, supervisor, and an EA in the instruction's class
    (cpSAVE: control alterable or -(An); cpRESTORE: control or (An)+) take
    cpGEN's path - the word after the operation word is fetched and latched
    - into `cp_decode`. The privilege check comes first, as before; any
    other EA, and every other CpID, still takes the F-line at decode.
  - **The extra word:** that word is the first extension word when the EA
    has one, so it becomes `cp_w` and is not fetched again; PC-relative
    modes take their base from its address (`fline_opcode_pc`). With no
    extension word - (An), (An)+, -(An) - it is the next instruction's
    first word. The instruction then ends through `cp_bcc` with a zero
    displacement: the PC goes back to that word, and the fetch starts
    again from it.
  - **cpSAVE:** it reads the save CIR ($04). If the answer is $01 (come
    again), it reads again; servicing pending interrupts first is B3's.
    $02-$0F, or a valid code whose length is not a multiple of four, gets
    AB and then the format error. Otherwise the EA is evaluated: -(An)
    drops by 4 + length (4 for the empty frame) and An is written before
    the frame, as 881UM 6.4.3 says. The format word is written at the EA,
    and then `length / 4` longs are read from the operand CIR and written
    from EA + length down to EA + 4.
  - **cpRESTORE:** the EA is evaluated and the format long is read from
    it. Its word goes to the restore CIR ($06), which is then read back;
    $01 means read again, with no interrupt service (10.2.3.2.2). A
    returned $02-$0F, or a valid memory copy whose length is not a multiple
    of four (checked after the read-back, 10.5.2.7), gets AB and then the
    format error. A returned $00 ends the instruction. Otherwise the memory
    copy's length (Fig. 10-18 note 2) is moved as longs from EA + 4 upward
    to the operand CIR. (An) + gets 4 + length only after the whole frame.
  - **The frame** moves through B2's transfer loop (`cp_xfr`); `cp_frcp`
    gives the direction, and a save's address steps down by 4.
  - **The format error:** vector 14 with frame $0 at the operation word,
    so an RTE restarts the instruction. It is `trap_cp` with
    `trap_cpfmt`. The RTE format error's own path (`trap_format_error`)
    is not used.
  - **Readings where the manuals are silent** (protocol doc 8.2, 8.4):
    - The format word is stored and fetched as the whole first long, with
      the reserved word written 0. Fig. 10-14 draws the frame as longwords.
    - FRESTORE (An)+ of the empty frame adds 4, the frame's size.
    - A cpSAVE whose EA is in the full extension format (not carried yet,
      as in B2) writes AB before the F-line, because the chip has already
      begun the save.
  - **Test:** `sim/cpfpu` `PROG=b4` passes 24 checks, 115 CIR cycles. It
    runs:
    - the reset phase's null frame through (An): $0038, reserved word 0,
      and the next long untouched;
    - an FDIV by zero with DZ enabled, saved through -(An): 60 bytes, the
      command image $0420 first after the format word, EXC_PEND active at
      +$38. The FNOP after it takes nothing;
    - an idle frame through (d16,An);
    - FRESTORE (An)+ bringing the exception back, taken by the next FNOP
      (vector 50, frame $0 at the FNOP). The handler resets the chip with a
      null frame through (xxx).W;
    - FRESTORE through (d8,An,Xn), then an FSAVE of what it restored
      (idle);
    - an invalid format word through (An)+: the format error, at the
      FRESTORE, with An not moved;
    - a null FRESTORE through (d16,PC), then null FSAVEs through (xxx).W
      and (xxx).L.

    **`PROG=full` now passes whole** (15 checks, 140 CIR cycles), and
    `b1` and `b2` still pass. It failed first, as it must: the F-line at
    the first FSAVE with no CIR cycle. A test-layout slip on the first run
    (null frames placed inside the 60 bytes of an idle frame) was the
    bench's, not the kernel's.
  - **Seen in passing:** the chip's idle frames carry X in simulation at
    longwords 5 and 6. These are CU registers that only mean something
    mid-instruction (`n_long`, `i_long`, `st_ca0`, `st_special`,
    `mm_mask`, `take_prim`) and have no reset. They are harmless: the
    FPGA powers them up at 0 and the next command loads them. Giving them
    a reset would make every frame deterministic under simulation; that
    is 7c's code, left for Daniel.
- **B5**: a bus error inside a dialog, and trace. Three parts, each test
  first.
  - **B5a (built 2026-09-30): no coprocessor.**
    - Decode now starts the dialog for every CpID but 0, the PMMU's. The
      MPU does not know which coprocessors exist: UM 10.5.2.2 reserves the
      decode F-line for bits 8-6 = 110/111 and invalid forms, and 10.5.2.8
      has a bus error on the initiating access mean "not present".
    - The initiating access is cpGEN's command write, a conditional's
      condition write, cpSAVE's first save CIR read, or cpRESTORE's restore
      write. While it is on the bus (`cp_init`), a bus error does not reach
      the kernel's bus error processing (`berr_k` masks it). `cp_nocp`
      marks it, the new kernel output `cp_berr_ack` clears the wrapper's
      hold, and the state after the beat takes the F-line: frame $0 at the
      operation word, no control CIR write, nothing after the access.
    - Only ID 1 answers in this machine; the wrapper bus-errors IDs 2-7, as
      before.
    - **Test:** `PROG=b5a` passes 15 checks. cpGEN, cpBcc, cpScc, cpSAVE
      and cpRESTORE with ID 2 each take the F-line at their own operation
      word, with exactly five CPU-space cycles (one each: no response read
      follows the failed write; the bench now checks that count), and the
      68882 runs as before afterwards.
    - **Upstream's suite:** `tb_stack_frame_push` fails two more lines
      (5 for 3). Its TEST 10 expects `$F800` (cpGEN, ID 4) to take the
      F-line at decode, in a bench whose BERR is tied to 0. By 10.5.2.2 that
      is a valid cpGEN form, so the 68030 writes the command CIR; with no
      bus error the write "succeeds" and the dialog reads what the bench's
      bus returns. The test's premise is the emulator's model, not the
      manual's. The same three benches fail as before (`ours.txt` updated).
  - **B5b (built 2026-09-30): trace** (UM 8.1.7, 10.5.2.5).
    - With T1 set when a general instruction began, a null with CA = 0 and
      PF = 0 is read past (`cp_twait`) until PF = 1, so the trace comes
      after the 68882 is done. While it waits, IA = 1 makes it an interrupt
      point (frame $9).
    - An interrupt taken inside a dialog now wins over the pending trace in
      the boundary chain (`cp_irq_take`), which used to turn it into the
      trace.
    - An exception taken inside a dialog (frame $9, or cpSAVE's not-ready
      interrupt) clears the pending trace for its own stacking - the
      instruction has not ended. RTE back into the dialog (`cp_rte`)
      re-latches T1/T0 from the SR it restores; there is no `setopcode`
      there to do it.
    - A taken cpBcc and a cpDBcc branch count as a change of flow for T0
      (`cp_cof`). cpTRAPcc's trap already gets group 2's stacked trace
      through trap00.
    - **Test:** `PROG=b5b` passes 18 checks.
      - Under T1, FMOVECR, FSIN, FTST, FBGT and the MOVE to SR that turns
        on T0 are each traced once, with the instruction's address in frame
        $2.
      - An FSAVE in the FSIN's trace handler finds the chip idle ($1F38).
        It found it busy ($1FD4) before the change.
      - The bench's IRQ at the FSIN's first $0900 is taken there with frame
        $9: scanPC FSIN + 4, one IACK.
      - Under T0, FBGT taken and the FDBEQ's branch are traced; FBEQ not
        taken, the expired FDBEQ and a MOVEQ are not; the closing MOVE to
        SR is traced.
  - **B5c: a bus error after the initiating access** (UM 10.5.2.8: bus
    error processing, then "return to the point in the coprocessor
    instruction at which the fault occurred").
    - **The problem:** the kernel's own model for a data fault is to let
      the instruction run on, dispatch at its end, roll the registers back
      and re-execute on RTE. For a dialog that is wrong. The garbage
      operand has already reached the 68882 (FADD (A0),FP0 adds it into
      FP0), and re-executing writes the command again in the middle of the
      chip's dialog.
    - **What B5c needs:**
      - stop the dialog at the faulted beat, and suppress that beat's
        register updates;
      - dispatch the bus error from there, as B3's interrupts do;
      - no register rollback;
      - a long $B frame, with the dialog's state in the frame's internal
        words ($38-$57): the resume state, `cp_prim`, `cp_ea`, `cp_len`,
        `cp_data`, `cp_anew`, `cp_mmbase` and count, the F-line context,
        scanPC and tempEA, and a marker;
      - RTE of such a frame restores them and resumes by issuing the
        faulted beat again.
    - **Tests:** first a bus error the bench injects on a memory operand,
      then a PMMU page fault, then an instruction-stream fault inside a
      dialog.
    - **Built 2026-09-30 for external bus errors.**
      - **Recording:** every beat a dialog state schedules is recorded
        (`cp_bk_*`): the state it goes to, one of 18 in-flight states
        encoded by `cp_st_enc`; its setstate and datatype; CIR or memory;
        the CIR register; the write data; TG68_PC.
      - **Detection:** `cp_bf_now` is a bus error (`berr_k`) as such a
        state's beat ends, outside the initiating access. On that edge:
        - after the state CASE, the decode sends the state to `cp_bf` with
          no new beat and no trap;
        - the dialog's registered process and register-write port change
          nothing;
        - the kernel's restart arming (`mmu_restart_pending`) is skipped,
          so there is no rollback.
      - **Dispatch:** `cp_bf` raises `setinterrupt`, and the boundary chain
        dispatches the bus error from there. The frame is forced long, its
        PC the faulted fetch's address or scanPC, which is what RTE's PC pop
        restores.
      - **The frame:** the berr states write the dialog into its internal
        words (`cp_bfr`):
        - $14 the PC-relative base;
        - $1C tempEA;
        - $20 the instruction's address;
        - $28 the extension words;
        - $30 the primitive, count and flags;
        - $38 the marker (`1100`) with the recorded beat;
        - $3C its write data;
        - $40 `cp_ea`, $44 `cp_data`, $48 `cp_anew`, $4C `cp_mmbase`;
        - $50 the F-line context's two words;
        - $54 scanPC.

        The SSW, fault address, stage B address, data input buffer and
        version stay the kernel's.
      - **RTE:** RTE of a long frame keeps those words (rte5). With the
        marker, it goes to `cp_rsm` instead of fetching:
        - the dialog's registers, the F-line context, the opcode and the
          trace bits load back;
        - `cp_rsm2` issues the recorded beat again and goes to its state.

        That is the 68030's "return to the point ... at which the fault
        occurred": the faulted cycle runs again (DF set). A handler that
        clears DF, completing the cycle itself, is not yet honoured for a
        dialog's frame.
      - **Test:** `PROG=b5c` passes 26 checks. The bench bus-errors the
        first access to six addresses:
        - the second long of FADD (A0)'s operand: the sum is 1 + 2, where a
          re-execution would have added the operand twice or broken the
          chip's dialog - the unfixed kernel took a protocol violation;
        - the third long an FMOVE.X store writes;
        - FMOVEM's second register through (A2)+ (A2 ends at +24);
        - a second FADD's extension word, fetched inside its dialog: the
          frame's PC is that fetch's address;
        - a long of an FSAVE -(A3) frame written;
        - a long of the FRESTORE (A3)+ read (A3 back where it was).

        Each gets a long frame, vector 2, the right fault address.
    - **The PMMU half.** `PROG=b5d` is its test: 4 KB pages
      identity-mapped, pages 4 and 5 invalid, an FADD reading page 5 and an
      FMOVE.X storing to page 4, the handler validating the faulted page
      and PFLUSHAing.
      - It stopped before any FPU instruction, on three bugs outside the
        dialog, all fixed 2026-09-30 (each with a failing test first):
        1. **PMOVE of CRP/SRP from memory read the low long at EA + 2** on
           the 32-bit port (EA + 5 on an 8-bit one) - the ROM's own
           `_SwapMMUMode` form, `PMOVE (A0),CRP`, so the walk started at a
           wrong root. Not the ALU (the suspicion here before): the
           kernel's BUG #390 line in `pmove_mem_to_mmu_hi` set the low
           long's address to `addr + 2`, the 16-bit shape's last beat
           (EA + 2) plus 2. Now `addr + beat_step`, 1.15 item 4's rule, as
           3.8 item 23 did for MOVEM. `sim/kernel_bus` gains PMOVE of CRP
           and SRP both ways in every control alterable mode ((An),
           misaligned by 2, (d16,An), (d8,An,Xn), (xxx).W, (xxx).L -
           (An)+ and -(An) are the F-line, which the kernel already did):
           before the fix ports 32 and 8 failed at the first low long,
           after it port 16 338 checks, 32 237, 8 520, all PASS. The
           writes to memory were already right.
        2. **The wrapper started a walker cycle on a stale request.** The
           walker's `mem_req` is registered and drops at the edge that
           takes `w_ack`, so the clk after an acknowledge `tg68k.v`
           started a cycle at the walker's old address and R/W (the next
           access's address arriving mid-cycle): B[0] was read as A[0]'s
           data and A[0]'s U-bit write landed on B[0]. The kernel's side
           had this guard already (`ecs` waits out `ack_pending`); the
           walker is now not selected while `w_ack` is high.
        3. **A write to an invalid page reached memory before its fault.**
           The wrapper parked the kernel's cycle while the PMMU was busy
           but not once the translation had faulted, so the access went out
           at the untranslated address, then the fault dispatched; the
           kernel gates its own strobes on `pmmu_fault` (`nUDS`/`nLDS`),
           which this bus does not use. The 68030 runs no cycle for an
           invalid page; `park` now includes `k_pmmu_fault`. Under VM this
           is a write to whatever the logical address names physically.
        `PROG=mmu` is the test of 2 and 3, no dialog faulting: b5d's
        tables, a three-level walk with its U-bit writes, an FPU
        instruction fetched translated, a plain MOVE reading page 5 and one
        writing page 4, each faulted and re-run, the handler turning
        translation off to read physical $4000 (still $A5A5A5A5 at the
        write's fault). 11 checks PASS; without 2 it double-faults in the
        walk, without 3 physical $4000 holds the new data. Items 1-3 are
        in every board build so far; whether the boot's own walks meet 2
        (two walker accesses back to back, e.g. a descriptor read and its
        U-bit write) is not established - 32-bit mode and VM certainly
        would.
      - **The PMMU term, as built (2026-09-30).** With the three fixed,
        b5d walked, ran FMOVE.L #1, faulted on the FADD's operand at $5000
        and then took a protocol violation (vector 13): the missing term.
        A page fault in a dialog is `pmmu_fault` force-releasing the beat,
        with no `berr`. Two changes:
        - `cp_bf_now` takes `berr_k` **or** `cp_pmmu_f`, the condition
          make_berr and the boundary's live dispatch use for a new PMMU
          fault (TC enabled, the fault not a DIB substitution, not yet
          dispatched or cleared and re-raised, no bus error trap pending).
          Everything after is the external case's: cp_bf, the long frame
          with the dialog in it, RTE through cp_rsm.
        - The first-fire restart arming (`mmu_restart_pending`) skips a
          dialog, as the external case's does. A data read's fault
          otherwise arms it and the dispatch rolls the register file back
          to the instruction's start, undoing what the dialog already
          wrote. The live rollback term (`pmmu_fault_restart_live`) needs
          no change: the first fire marks the fault dispatched, and cp_bf
          dispatches later.
        - A write fault arms nothing (the kernel's LASTWRITE rule), and
          cp_bf forces the long frame over LASTWRITE's short one.

        `PROG=b5d` is now 19 checks: the FADD's read on page 5 (1 + 2.0,
        once), the FMOVE.X store to page 4, a store through -(A3) to page
        8 (A3 decremented once), and a read through -(A4) from page 9 -
        four long frames at the right fault addresses. Before the change
        it failed 8 of its first 11 checks. **Mutant:** with the arming not
        skipped, only the -(A4) read fails - A4 is back at $900C, the
        predecrement undone by the rollback - which is why that case is
        there (the first three touch no register before their fault).
        A handler that completes the cycle itself (DF cleared) is still
        not honoured for a dialog's frame. Gate: all twelve cpfpu
        programs, kernel_bus 16/32/8, system, busfault, machine; upstream's
        suite as `ours.txt`. **One unexplained result:** the first
        kernel_bus PORT=16 run of the gate failed 318 of 338 checks (38 in
        the five-byte bit fields); it passed alone right after, and twice
        more beside a cpfpu run as the first had been. Nothing shares its
        files (every bench has its own work library, nothing else wrote
        the tree). Not reproduced; recorded in case it returns.

### 8.9.5 The first synthesis (item 8, begun 2026-09-30)

The chip alone (`se30_fpu` as top, virtual pins, the machine's device and
clk_sys) in a scratch Quartus project, before it joins the machine:

- **Two arrays were not block RAM** - what Daniel's rule says to check
  (8.3, the Quadra's 143% fit). The FP register file (a read at p0 and a
  write at p1 on two different addresses of one port - three ports as
  written) and the nROM (read under the sequencer's reset) were built as
  logic: 6,009 ALMs estimated. Now the FP file's port A takes one muxed
  address a clk with the M10K's write-through read (its true dual port
  has no old-data read during a write), and the nROM is read in a block
  of its own without a reset **and** marked `romstyle = "M10K"` - unmarked,
  Quartus judges its ~400 used words cheaper as ~400 ALMs of logic. All
  seven arrays infer; the benches are unchanged (behaviour identical).
- **The fit: 5,002 ALMs, 2,109 registers, 47 RAM blocks** (of 41,910 and
  553). Against 8.8.17's estimate of ~3,100 + the frames: the datapath's
  muxes are larger than estimated. With the machine's ~23,100 ALMs that
  is about 28,100 (67%), under the ~38,000 ceiling.
- **Timing is not met: -9.3 ns setup at the slow corners** on clk_sys's
  31.9 ns. The failing paths start at the operand RAMs (T, FP, K), read
  at the p0 edge, and end at the p1 edge a clk later: RAM -> source mux ->
  67-bit barrel shifter -> ALU -> normalise (a leading-zero count and a
  shift) -> the result's own leading-zero count, flags and range
  compares - about 41 ns, where 8.8.9 estimated "roughly half" of 31.9.
  The paths from the nROM show the same length but are really two clks
  (the nanoword is launched at p1 and the datapath's registers capture
  only at p1). **The fix keeps the microcode's semantics and clocks:**
  register the next word's operand addresses at the p1 edge that loads
  it into uir - from the µROM output already there, with the K address's
  LC the next one and the FP select from a small table of the nanowords'
  select fields - with a bypass for a temporary or FP register written at
  the same edge; the datapath then has a whole FPU clock (two clk_sys,
  63.8 ns), and a multicycle constraint says so for the APU's p1-to-p1
  paths. Only the sequencer's next address (p1 flags to the p0 µROM read)
  stays a one-clk path, and it has 11 ns to spare.

**The retiming, as built (2026-09-30).** `se30_fpu_apu.v`: T[ra], T[rb],
K and FP are read at the p1 edge that loads their word into uir, from
the µROM's output (or uir while a word holds); the K address takes the LC
that edge leaves; `nsel`, a 1,024 x 3 table the assembler now writes
(`ucode.nsel.hex`: each nanoword's FP select and whether its constant is
indexed by LC), gives what the nanoword would say before it is out. A T
or FP register written at the same edge is taken from a result register
(`byp_a`, `byp_b`, `byp_f`). The FP file's port A only reads, and the
APU writes through port B, the BIU's only while the unit is idle. Abort is
held to a p1 edge, so every register the datapath writes changes only at
p1. `MacSE30.sdc` (and the scratch project's) gives the APU's registers
two clk among themselves, leaving out the p0 edge's µROM and entry reads,
`ua` and the abort latch. The standalone fit: **5,251 ALMs, 47 RAM
blocks; timing met at all four corners - setup +14.4 ns, hold +0.16 ns -
with no combinational loop (Quartus 332125: none)**. Behaviour unchanged:
the 80 directed checks, all 19,836 vectors plain and under `+detour`
(the same 2,059 busy saves at a checkpoint), the 7a APU bench, the
machine bench. Mutants: without the T bypass 3 directed checks fail;
with the K address on the old LC, 28 packed and 35 transcendental
vectors fail. **Without the FP bypass all 19,836 still pass**: no word of
the microcode reads an FP register the word before it wrote (they write FP
at their ends). The bypass is kept as a guard, about 80 ALMs. The other
choice is an assembler rule forbidding the pattern, which is how the
assembler already enforces the datapath's limits (8.8.18); that is for
7e to settle. 7e must also settle port B: it is the APU's for writes now,
and the CU's overlap wants it too (8.8.13). **Both settled in 8.9.6**
(2026-09-30): the assembler rule, and port B split by phase.

**Compile 22, the machine with the FPU (2026-09-30, Daniel's go-ahead
for the night; not flashed).** `ed7e677`, tag `ed7e6772`, archived as
`output_files/MacSE30_ed7e6772_fpubus.rbf` (md5 `d715409f...`); 27
minutes. The chip is in the fit, reachable from the bus through GLUE
(7d stage A), though the kernel sends it nothing yet:
- **28,982 ALMs (69%), 29,098 registers, 265 of 553 RAM blocks (48%), 40
  DSP blocks.** The FPU is **5,728** of those ALMs (the APU 4,429, the BIU
  and CU 1,142); compile 21 was 23,118 without it. This leaves some 9,000
  ALMs below the ~38,000 routing ceiling of 8.3 for the kernel's
  protocol (7d), the overlap (7e), SCSI, the SCC and sound.
- **Timing met at every corner**: the flow's summary +0.117 ns; and
  `scripts/sta_corners.tcl` gives a worst slack of +0.781 ns at every
  corner outside the SDRAM read capture, where at each corner one of the
  two capture clocks meets (A at the slow corners by >= 1.335, B at the
  fast ones by >= 1.854 ns). The kernel's known 4-node combinational
  loop (Quartus 332125, the carry item of 3.8) is still reported; the
  APU has none.
- The machine benches (`sim/machine`, `system`, `busfault`, `glue`) pass
  on this RTL. The prediction for a board run is the previous build's:
  the ROM boots from floppy to "Welcome to Macintosh", then loops on the
  F-line at $131A4, because the kernel still takes the F-line for ID 1 at
  decode.

### 8.9.6 7e: the overlap (opened 2026-09-30)

8.8.1's second step: the CU converts the next general instruction's
operand while the APU still works on the one before, with 8.8.13's queue,
register-conflict checks and the mid-instruction report. **First, the
chip's groundwork** (Daniel, 2026-09-30: "start 7e, beginning with those
two"), as built:

- **The CU's frame fields reset.** The idle frame's longwords 5 and 6
  (8.8.15: the BIU state's control word and the take primitive) showed X
  in simulation - `pc_next`, `n_long`, `i_long`, `st_ca0`, `st_special`,
  `cr_mask`, `mm_mask`, `take_prim` and `pend_vec` had no reset, and an
  instruction that never used them left them unset (seen in 7d's B4).
  They are now cleared by the reset and by the null restore (which is the
  reset state, `cu_clear`), so every frame the chip saves is defined. On
  the board they powered up 0 anyway; this is for the benches, and for a
  frame saved after a null restore to equal one saved after a reset.
  `sim/fpu`'s directed frames gain the check (every longword of the first
  idle frame defined): it failed before, passes now.
- **FP register-file port B, split by phase (Daniel's choice).** Port A
  is the APU's reads; port B was the APU's writes at p1 edges and
  otherwise the BIU's, used only while the unit was idle. Under the
  overlap the CU writes and reads FP registers while the APU runs, and
  the old mux would drop a CU write landing on an APU write's edge. Now
  the p1 edges are the APU's and the **p0 edges the CU's**, a read or a
  write each - one access per FPU clock for each unit, with no
  arbitration, and each unit's timing its own. A CU write request stands
  until a p0 edge takes it (`fpb_we` is cleared only at p0 edges; one set
  at a p0 edge waits a clock); a CU read's address, set by a p1 edge, is
  read at the p0 edge after it and taken at the next p1 edge (the CU's
  source fetch, `cu_step`, and FMOVEM out's, `mm_step`); the null
  restore's clearing writes one register at each p1 edge. A
  simulation-only guard reports a standing write whose address or data
  changes before its edge (`SIMERR port B`). The rejected choices: the
  APU first with the CU retrying on a grant (a path from nanoword decode
  into the CU's control, and a variable latency), and a second copy of
  the file (4 M10K more, and the writes would still share one port).
- **The FP bypass replaced by an assembler rule (Daniel's choice).** 8.9.5's
  `byp_f` (about 80 ALMs) served a word that reads FP after one that writes
  it, which no microcode does. `asm.py`'s `check` now refuses it: a word
  with `d=FP` (not `ctl=end`, after which nothing follows) whose possible
  next words - fall-through, branch target, dispatch table, callee, every
  return point - read FP on A or B, whatever the selects (src and dst are
  the command's and may name one register). The whole microcode passes
  it; `test_asm.py` gains two rejections (the next word; a branch
  target). `byp_f` and its register are gone from `se30_fpu_apu.v`.
- **The cost:** the CU's source fetch now waits for its p1 edges, so an
  instruction's APU starts up to 2 clk later after its command write than
  before (the microcode's own clocks, counted from its first word, are
  unchanged). Seen in the detour sweep: 2,061 busy saves land at a
  checkpoint where 8.9.5 had 2,059, the bench's saves falling on
  different microwords. The overlap's queue should hide it (the CU
  fetching while the APU runs); to be measured against 8.8.16's budgets
  when it is built.
- **Verified:** `sim/fpu` - the directed checks; all 19,836 vectors plain
  and under `+detour` (busy at a checkpoint 2,061, busy initial 2,239,
  idle 2,075, idle after a come-again 9,868; the FMOVE.P sweep's 11 busy
  frames right); the 7a APU bench, all 19,836 vectors at their clocks
  (its port B tasks now wait for a p0 edge); `tools/fpu_ucode/run.sh`
  whole; `sim/cpfpu` - all ten programs, no SIMERR; `sim/machine`.
  **Mutants:** port B's write request cleared every clock (a write set at
  a p0 edge is lost) - 8 directed checks fail, FMOVEM's registers first;
  the CU's source fetch not waiting for p1 edges (it takes the APU's read)
  - 5 directed checks and 5 of the first 300 vectors fail. No compile yet
  (the ALMs `byp_f` saves are 8.9.5's estimate until one).

**The overlap: the design (2026-09-30, before the RTL).** UM 5.1.1.2
(Tables 5-1 to 5-6, Figures 5-2 and 5-3), 5.2.3.6 (Figure 5-8), 6.x's
EXC PEND text, 7.2.6, 7.5's Figures 7-32 to 7-34 and 8.4 read again for
it. What the manual fixes:
- **The CU takes the next general instruction while the APU runs.** By
  class (8.8.5): the partial-concurrency instructions (Table 5-4:
  arithmetic with an S, D or X memory source or an FP register source)
  release the MPU - the evaluate-and-transfer with CA = 0, or the null
  with CA = 0 for a register source - and wait in the CU for the APU;
  the minimum-concurrency ones with a B, W or L source (Table 5-1) have
  their operand transferred and then hold the MPU with the null CA = 1,
  IA = 1 until the hand-off ("since the CU cannot convert the byte
  operand ..."); packed sources are not even fetched; FMOVECR, FMOVEM,
  the control registers, integer and packed stores wait for the APU
  before their dialog starts; the fully concurrent FMOVEs (Table 5-5)
  the CU does itself, with conditions (a)-(f) handing them over.
- **A third instruction** (the CU busy or waiting) has its command
  latched and answers the null CA = 1, IA = 1 until the CU is free; it
  starts at the next response read after that (7.2.6, 8.4).
- **The conditionals** wait for both units and no exception pending
  (Table 5-6); an exception pending in each unit is reported one at a
  time, the conditional restarted after each handler.
- **An exception from the APU's instruction** while the CU holds the next
  one: **the CU's instruction is not allowed to continue** until a
  FRESTORE with BIU flag bit 27 set marks the exception serviced
  (5.2.3.6's task-switch example: otherwise the FADD would overwrite FP0).
  It is reported as a **take mid-instruction** when the MPU is still in
  the CU instruction's dialog (the B/W/L case, a store converting - 7.5,
  Figures 7-32/7-33), else as a take pre-instruction when the next
  instruction starts. Only FSAVE removes the primitive (7.5.4; "the state
  of the CU must be saved because a second instruction, in the CU, may be
  partially executed"). The 68882's idle frame is 32 bytes longer than
  the 68881's for the CU's state (6.4).

**Ours, where the manual stops:**
- **The CU slot**, separate from the BIU's dialog registers: the waiting
  instruction's command (`cu_cmd`), the address the MPU passed for it
  (`cu_iar`, FPIAR's value once it is handed off - FPIAR keeps the APU
  instruction's address, which its exception handler needs), its state,
  and its operand in the dialog's operand register (a prefetched FP
  register is kept there too, so the CU's whole state fits the idle
  frame's CU area). The APU takes its command from the slot at the
  hand-off, so the BIU can latch the third instruction's word meanwhile.
- **Register conflicts** (5.1.2.2, Table 5-5 notes a and f) are the APU
  instruction's destination against the CU instruction's FP source
  (FPm) or destination (FPn); a conflict makes the CU wait for the APU
  before it prefetches or writes.
- **Retirement in program order** (8.8.13): a fully concurrent FMOVE
  writes its register (or its memory operand) as the manual says, as
  soon as no conflict stops it, but **its FPSR effect** (FPCC, EXC, the
  accrual) is held until the APU's instruction has ended - so the older
  instruction's EXC is what a pending exception's vector and handler see
  - and while an exception is pending it stays held, in the frame, and
  applies when the CU continues. The CU's own FMOVEs never raise an
  exception (every exceptional case is handed to the APU).
- **The hand-off** happens when the APU is idle, no exception is
  pending and no save is awaited; FSAVE then finds the CU's instruction
  still in the slot (an idle frame when the APU had finished, a busy one
  when it stopped at a checkpoint), and FRESTORE puts it back.
- **The frame's CU area** (longwords 2-9): 2-4 the operand register (the
  dialog's data or the slot's operand), 5 the dialog's state with the
  CU's state in its four spare bits, 6 the take primitive and `cu_cmd`,
  7 `cu_iar`, 8 the held FPSR effect, 9 zero.
- **The invariant stays the bench's** (8.8.13): the same programs leave
  the same registers, FPSR and memory with the overlap as without it;
  only the clocks and the mid-instruction reports differ.

**Stages:**
- **7e-1 the queue**: the CU slot, the classes above with the fully
  concurrent FMOVEs still handed to the APU (partial concurrency for
  them - right results, less overlap), the third instruction's wait,
  the conflicts, the exception rules, FSAVE/FRESTORE of the slot. Bench:
  pairs and triples of instructions issued without waiting, against the
  model run sequentially, and the frames with an instruction in the CU.
- **7e-2 the CU's datapath**: FMOVE FPm,FPn, FMOVE `<ea>`,FPn (S, D, X)
  and FMOVE FPm,`<ea>` (S, D, X, with the CU's rounding) done without the
  APU, conditions (a)-(f), the held FPSR effect.
- **7e-3 the clocks**: the heads and tails against Table 8-3 (8.8.3).
- **7e-4 the cputest corpus** (8.4 item 7).

**The order after 7e-2 (Daniel, 2026-09-30 19:29, relayed from a side
session):** "I would like to see the board get further. If the timing
tests and the deferred test runs can go ahead after a full compile then
that is what I would like to do." So:
1. 7e-2 committed (`bad8592`).
2. **Item 8 now**: the full compile with the kernel's protocol (7d) and
   the overlap (7e-1, 7e-2) - the build ritual, `sta_corners.tcl` at
   every corner, the fit's area - for Daniel to flash. The target: past
   the FNOP at $131A4 where compile 21's board stopped (the kernel then
   took the F-line for ID 1; now it runs the dialog).
3. After it: 7e-3 (the clocks against Table 8-3, the CU's moves' clocks
   included), 7e-4 (the cputest corpus), and the deferred full runs
   (7e-1's five sweeps at `7d51f88`, 7e-2's full pairs, triples and
   detour pairs at `bad8592`).
Nothing in 7e-3 must precede a board run: it changes when an instruction
ends, not what it leaves, and the ROM does not time the FPU.

**Compile 23 (2026-09-30, Daniel's go-ahead): `fc5aaaa`, tag `fc5aaaa4`,
archived as `output_files/MacSE30_fc5aaaa4_cumoves.rbf`; 30 minutes.
TIMING NOT MET: -1.152 ns setup at the slow 100C corner, -0.521 at slow
-40C (the fast corners and every SDRAM path met; `sta_corners.tcl`).**
Every clk_sys path within 0.5 ns of failing passes through the kernel's
`cp_bf_now` (7d B5c): the PMMU's fault term (`cp_pmmu_f`, combinational
from the current address through the PMMU's compares) forces
`next_micro_state` to `cp_bf`, so every bit of the next state - and
`pmmu_reg_sel_int`, the PMMU's register read, OP2out and the ALU behind
it - waits on the address translation's fault. **Daniel flashed it anyway
(for curiosity): THE MACHINE BOOTS TO THE DESKTOP** - past the FNOP at
$131A4, where compile 21 stopped on the F-line. A violated build, so the
evidence is "it works despite -1.15 ns", not "it works"; the fix to the
path comes before the next compile.

**The fix (2026-09-30, for compile 24).** The next-state process drives
`next_micro_state_c`; a concurrent line applies the dialog's fault
override (`next_micro_state <= cp_bf WHEN cp_bf_now = '1' ELSE
next_micro_state_c`); what only asks whether the next state is a PMOVE
state - `pmmu_reg_sel_int`, `pmove_mmu_read_active`, `data_write_tmp`'s
PMMU source, the `pmove_dn_lo` select - reads `next_micro_state_c`. The
same answer everywhere: `cp_bf_now` needs a coprocessor state, and no
PMOVE state follows one; a simulation-only assertion says so on every
clock (SIMERR, never fired). 389 assignments renamed, the process's reads
unchanged (they read the final value, as before). Gate: `sim/kernel_bus`
16/32/8 (338, 237, 520), `system` 23, `busfault` 14, `sim/cpfpu` all 13,
`sim/machine`; `sim/kernel_upstream` verdicts identical to `ours.txt`.

**Compile 24 (2026-09-30): `b9d94be`, tag `b9d94be1`, archived as
`output_files/MacSE30_b9d94be1_cumoves_tfix.rbf` (md5 `481ce66a...`); 30
minutes. TIMING MET at every corner**: the flow's summary +0.098 ns;
`sta_corners.tcl` worst slack outside the SDRAM capture +1.085 ns, and at
every corner one of the capture's two clocks meets (the design lines'
-0.361 setup at slow 100C and -0.139 hold at fast -40C are the other
capture clock's, as in every compile since item 18). For Daniel to flash.

**On the board, compile 23 (2026-09-30, Daniel's screenshots):** System
6.0.5 / Finder 6.1.5 from the System Tools disk, **8,192K**; TattleTech's
General Hardware: **"Machine = Mac SE/30 (ID=9g)"** - the shared
IIx/IIcx/SE/30 ROM identified the machine from our hardware; **"FPU =
MC68882, Hardware FPU = Yes"** (software tells a 68882 from a 68881 by its
FSAVE frame); 32-bit capable No, booted 24-bit (the dirty ROM, as it
should). **"CPU Speed = 10 MHz"** where a real SE/30 is 15.67: most likely
the 68030's caches, not built (`tg68k.v`: plan 1.15 item 9) - a speed
loop runs from the real chip's 256-byte instruction cache but fetches
every word from RAM here (with the Guide's one wait state); TattleTech
shows the caches "enabled" because the kernel keeps CACR as a register.
Also possible: the kernel's clocks per instruction (not cycle-exact) and
the time base (VBL ~61/s against 60.15 measured at compile 16). To
measure: a known loop's clocks in `sim/machine` against the 030 UM's
cache and no-cache times. Also: the 7.1 800K set's Disk Tools boots
System 6.0.7 (its System's `vers` is 6.0.7, Finder 6.1.7) and its
Install disk has no boot blocks and no System Folder - neither is a core
fault.
**The deferred full runs (the night of 2026-09-30, from worktrees; logs in
`sim/fpu/out/night_0930/`).** 7e-1 at `7d51f88`: every vector plain and
under `+detour` (19,836 each, 0 fail, 0 other clocks), all pairs, all
detour pairs (CU 10,478, mid 295, a context switch in 16,449) PASS. 7e-2
at `bad8592`: every vector plain (the CU's 453 moves, 0 wrong routes), all
pairs, all detour pairs PASS. **All triples FAILED, 25 of 19,836 on both
commits** (so 7e-1's, inherited): every one an older instruction, a second
taken into the CU's slot, then a conditional on a NaN raising BSUN - and
in the BSUN handler FPIAR was the second instruction's PC, not the
conditional's. BSUN's take ($5C30) passes the conditional's PC, and the
instruction address write routes by `pc_apu`, which the second
instruction's dialog had left 0 - so the PC went to `cu_iar` (with a stray
`cu_pcv` that a later direct start could have stamped into FPIAR). The
pairs never meet it (no instruction between the older one and the
conditional); the first 5,000 triples had no vector with BSUN enabled
before a NaN conditional. **Fix: the BSUN take sets `pc_apu`.** Directed
regression (FDIV, FADD of a NaN into the slot, FBSF: FPIAR the FBSF's) -
fails without the fix, passes with it. **On the fix (the night of
2026-10-01), every full run: every vector plain, all pairs, all triples,
all detour pairs - 19,836 each, 0 fail, 0 other clocks; directed 143;
`sim/cpfpu` all 13; `sim/machine`.** 7e-1 and 7e-2 are now verified in
full on their final RTL; nothing deferred remains.

**The ADB keyboard works** (Daniel, 2026-09-30, the first time it could be
tried: typing at the desktop) - with compile 18's mouse, the ADB section's
devices are both confirmed on the board.

**The 10 MHz, measured (2026-09-30, compile 24 on the board).** A JTAG
peek of low memory: the ROM's own start-up calibration left **TimeDBRA
($0D00) = $06D0 = 1,744** DBRA iterations a millisecond (TimeSCCDB $019D
= 413; TimeSCSIDB $FFFF, not calibrated with no SCSI chip): **9.0 clocks
an iteration** at 15.6672 MHz. The 030 UM, Table 11.6.15 (read from the
page image, p. 11-48): DBcc, cc false and count not expired, **6 clocks
from the instruction cache, 8 (0/2/0) without** at two-clock memory - 10
with the SE/30's one RAM wait state on the two prefetches. So the kernel
runs the loop about as a 68030 without its cache would (~1,570 a ms),
the time base is right (a wrong VIA clock would scale every row), and the
missing factor is the cache (~2,610 a ms): 1,744 / 2,610 x 15.67 = 10.5
MHz, TattleTech's "10 MHz". Not a fault; the 68030's caches (plan 1.15
item 9) are the remedy, and software can see them anyway (CACR, the
clears, burst fills).

**The order from here (Daniel, 2026-09-30, "Agreed"):** 7e-3 (the clocks
against Table 8-3), 7e-4 (the cputest corpus) and the deferred full runs;
then **the 68030's instruction and data caches (1.15 item 9), built as
the chip builds them**, so everything after runs at the machine's speed;
then SCSI (the 53C80, whose donor survey is done). The ISM's MFM read
(5.13, 1.44 MB disks) is not yet placed.

**7e-1 as built (2026-09-30).** `se30_fpu.v`:
- **The slot**: `cu_v`, `cu_cmd`, `cu_iar`/`cu_pcv` (a passed PC waits
  with its instruction and becomes FPIAR when it starts in the APU - at
  the dialog's own start, or the hand-off), `pc_apu` (the dialog's
  instruction already started: its PC goes straight to FPIAR). The APU
  and the unpacking take their command from `acmd`, loaded by
  `start_apu` with the word it starts, so `cmd` is free for the BIU.
- **The classes**: a general instruction's first response read, the APU
  running and the slot free, no exception pending: from a register,
  `$0900` (`$4900` with the PC) and the slot filled; from memory (not
  packed), the operand's primitive as before, and the last operand write
  fills the slot - `B_IDLE` for S, D, X (CA = 0), else **`B_HOLD`**:
  `$8900` while the slot is full, then `$0900`, or the take
  mid-instruction `$1Dvv` when an exception is pending (after XA back to
  `B_HOLD`). Every other case while the APU runs or the slot is full
  answers `$8900` - the packed source, FMOVECR, stores, FMOVEM, the
  control registers, a third instruction; conditionals wait for both
  units, a pending exception reported first.
- **The hand-off**: the APU idle, the slot full, no exception pending,
  no save awaited or frame moving, the slot's PC not still to come
  (`B_PCW`), and no save or restore access on that edge.
- **The frame**: longwords 2-4 the slot's operand when the slot is full;
  longword 5's four low bits `cu_v`, `cu_pcv`, `pc_apu`, `take_hold`;
  longword 6's low half `cu_cmd`; longword 7 `cu_iar`. FSAVE's end
  empties the slot (it is in the frame), FRESTORE fills it, a restore
  write and a protocol violation's XA abort it, AB aborts it when the
  dialog is its own (`B_PCW`, `B_HOLD`).
- **Waiting while an exception holds the slot**: FMOVEM and FMOVE of the
  control registers do not report a pending exception (8.6.14 item 19),
  so with one holding the slot they wait - only a program that never
  takes its exception meets that; a handler's FSAVE empties the slot
  first (5.2.2).

**Benches.** `sim/fpu` directed `overlap` (8 checks, and the FSIN
directed check now expects the CU to take the FADD and a third to wait):
three in a row against one at a time; the FDIV's DZ as the FADD.B's take
mid-instruction, kept after XA, the idle frame with the FADD.B, its
command, PC and operand in the CU area, FPIAR the FDIV's, FRESTORE with
bit 27 letting it go on; a released FADD's pre-instruction case. **+pairs**
(`+pairs=3` triples): each vector, then one or two picked from the file,
issued without waiting, against the same with an FNOP after each, with a
handler for every take (FSAVE, bit 27, FRESTORE, then on or started
again; F-line and BSUN skip) - registers, FPSR, FPIAR, stores, answers
and the exceptions in order must agree. `sim/cpfpu PROG=b7e` (15 checks)
the same through the kernel with UM 5.2.2's handler: frame `$9` from the
FADD.B #3 (scanPC past its immediate), frame `$0` at the FNOP, FPIAR the
FDIV's in each handler and the instruction's own after - it fails on the
chip before 7e (both reported pre-instruction, the second at the FADD).
**b3c** moved: its come-again was the FSIN's, which now goes to the CU
and is released; an FMOVECR after it (waiting for both units) takes the
interrupt instead.

**Found by `+pairs=2 +detour`** (2,355 of 19,836 failing before):
- **A restored busy frame's instruction overwritten by the hand-off.**
  FRESTORE of a busy frame loads the stopped instruction's context while
  the APU is idle and resumes it a clock or two later (`go_pend`,
  `apu_go`); with the slot restored full, the hand-off saw the APU idle
  in between and started the slot's instruction on top of it (group 58:
  FMOD, then FADD.D into its destination - the FADD.D computed from the
  unfinished FMOD). `apu_idle` now excludes the resume in progress, which
  also closes the same window for a direct start at `B_CMD` (possible
  before 7e, never met).
- **A bench bug**: a context switch landing inside the bench's exception
  handler (between its FSAVE and FRESTORE) overwrote the handler's saved
  frame, and the handler restored the detour's instead - an FNOP then met
  a latched command, a protocol violation. The detour now keeps its
  caller's frame buffer.
- **An instruction started over a pending exception** (7 groups still
  failing after the first fix): an operand whose transfer began while the
  APU ran can end after the APU has finished with an exception; its last
  write took the direct start (APU idle, slot empty) without asking for
  one pending, so the instruction ran and FPIAR moved on before the
  exception was reported. It now waits in the slot. Directed check: the
  second long of an FMOVE.D written after the FDIV's DZ is pending - in
  the slot, the FNOP reports it, FPIAR the FDIV's.
- **Found by `+pairs=3`** (48 of 19,836): the APU takes the slot's
  operand from `opnd` a few clocks after the hand-off (the start sequence,
  `cu_busy`); a third instruction's dialog starting in that window clears
  `opnd` for its own operand, and the second computes from it (group 2578:
  FDIV, FSUB.D, FMUL.X - the FSUB.D's result a bit off). No new dialog now
  starts in the CU while `cu_busy`.
- **Verification as committed** (Daniel, 2026-09-30: accept these, full
  reruns overnight): on the final RTL - `sim/fpu` directed 104; the
  first 5,000 triples (the CU took an instruction in 3,649, take
  mid-instruction in 101); each of the 7 detour-pair and 8 triple groups
  that had failed; `sim/cpfpu` all 13 programs; `sim/machine`. On the RTL
  before the last two fixes (which change only the two cases above):
  every vector plain and under `+detour` (19,836 each, 0 with other
  clocks), all 19,836 pairs (CU 10,702, mid 296). **Still to run on the
  final RTL**: all pairs, all triples, all pairs under `+detour`, and the
  two vector sweeps.
- **Mutants** (3,000 each): the last operand's start without the pending
  check - 2 directed checks fail; no `cu_busy` gate - 8 triples fail.
- **Mutants** (3,000 pairs each): the hand-off ignoring a pending
  exception - 8 directed checks and 43 pairs fail; a passed PC going
  straight to FPIAR - 2 directed and 98 pairs (the handler now records
  FPIAR too, which the pairs first lacked); FRESTORE not refilling the
  slot - 3 directed and 98 pairs.
- **The full sweeps** started at 18:12 on 2026-09-30 were stopped at
  once (Daniel: run them at night, fix what they find then, press on
  meanwhile). They run tonight from a worktree at `7d51f88`, so 7e-2's
  microcode and vectors cannot leak into them (the compiled bench reads
  the microcode at start and plain/detour stream the vector file).

**7e-2: the design (2026-09-30, before the RTL).** Read for it: UM Table
5-5 from the **1987 first edition's page image** (p. 5-5; the NXP text
copy scrambles its columns), 5.1.2.2, 5.1.2.3, Table 5-7, Table 8-3's
FMOVE rows; the model's FMOVE (`fpu.py` `arith`, `_op_fmove`,
`fmove_out`, `_to_ieee`; `rounding.py` `post_process`); the microcode's
register reads. Table 5-5 as printed:

| FMOVE | format | no concurrency | partial concurrency |
|---|---|---|---|
| FPm,FPn | X | a | b, c, f |
| `<ea>`,FPn | S, D | | b, c, f |
| `<ea>`,FPn | X | | b, c, f |
| FPm,`<ea>` | S, D | a | b, d, e |
| FPm,`<ea>` | X | a | b |

(a) FPm is the preceding instruction's destination, (b) a NaN, unnormal
or denormal, (c) PREC single or double, (d) INEX2 enabled, (e) an
overflow or underflow, (f) FPn is the preceding instruction's
destination. What the model fixes as the result the CU must equal:
- **To a register** (FPm,FPn and `<ea>`,FPn): FPCC from the result, EXC
  cleared, the quotient byte and AEXC unchanged (nothing to accrue),
  FPIAR the instruction's when the PC is passed. With PREC extended and
  a normalised, zero or infinite source the value is exact: S and D are
  widened, X copied; a zero is written with exponent 0, whatever the
  source's (`zero(s)`).
- **To memory**: FPCC and the quotient byte **unchanged**, EXC cleared
  then INEX2 if the rounding was inexact, AEXC's INEX accrued from it.
  The rounding is FPCR's RND to the destination's precision; **PREC is
  ignored**. UNFL is judged **before** rounding (the exponent below the
  format's minimum, exact or not), OVFL after it. X is exact: `{s, e,
  16'd0, m}`.
- **The APU reads its source register only in its first microword**
  (`pro_reg`, and `pro_st` for stores); every later read is FP[dst] or
  FP[c], which (a) and (f) protect. So a CU write to the APU
  instruction's source is safe once the APU has started, which the
  existing "no CU dialog while `cu_busy`" already guarantees - to be
  checked directly (below).

**Ours, where the manual stops:**
- **The CU does the FMOVEs itself whenever the conditions allow - with
  the APU busy or idle** (the chip's: Table 8-3 gives FMOVE to FPn 21
  clocks on the 68882 against 33 on the 68881, Table 5-7 the same 21).
  Every FMOVE vector in the sweep then runs through the CU's datapath
  and is held to the model's result, which is the strongest check the
  rounding can get. Its clocks become the CU's, counted apart in the
  bench (`by the CU`) until 7e-3 sets them against Table 8-3.
  **Confirmed by Daniel 2026-09-30 ("always")**; the rejected
  alternative, the CU only while the APU is busy, kept every vector's
  clocks but tested the CU's rounding only in the pairs.
- **What counts as (b)**: the tags the unpacker already makes (NaN,
  unnormal, denormal), plus any encoding the model normalises rather
  than copies - an X zero with a non-zero exponent, an infinity with a
  non-zero mantissa. Handing over more than the chip might costs only
  overlap; the APU's result is the model's in every case.
- **What counts as (e)**: the rounded exponent above the format's
  maximum, or the exponent before rounding below its minimum (the
  model's UNFL, which is set with or without inexactness). The CU never
  denormalises.
- **The conflicts** are against the APU's instruction while it runs:
  its FP[dst] if it writes one (not FCMP, FTST), and FP[c] too for
  FSINCOS. (a) makes the CU wait for the APU to end, then do the move;
  (f), (b) and (c) put a move to a register in the slot, handed to the
  APU as 7e-1 does; (b), (d) and (e) send a store back to 7e-1's path
  (wait for both units, the APU converts), found at the first response
  read for (d), after the CU has read FPm for (b), after its rounding
  for (e).
- **The datapath** (8.8.13's estimate, about 350 ALMs with the slot):
  the widening of S and D (the unpacker's fields, a second instance on
  the BIU's `cmd` - the APU's is on `acmd`); FPm read through port B at
  a p0 edge; the store's rounding - the mantissa's top 24 or 53 bits, G,
  R and S from the rest, RN ties-to-even, RZ, RM, RP by the sign, a
  53-bit incrementer whose carry bumps the exponent; the exponent range
  checks; the S, D or X image. FPn written through port B at a p0 edge.
  The store's image goes into `opnd` (the CU's register, free: the CU
  moves only with the slot empty), and the store's operand reads take
  it from there.
- **The dialogs**: FPm,FPn answers `$0900` (`$4900` with the PC) at
  once, as 7e-1 does; `<ea>`,FPn is 7e-1's CA = 0 transfer, the move
  made at the last operand write; FPm,`<ea>` answers `$8900` while the
  CU reads and rounds (a few clocks), then the CA = 0 transfer
  (`$3104`, `$3208`, `$320C`), released after the last read.
- **Retirement in program order** (8.8.13, as agreed): the move's
  register or memory operand is written at once; its FPSR effect - the
  new FPCC (moves in only), the EXC byte, the AEXC bits - and its passed
  PC (FPIAR) are **held** while the APU runs an older instruction, and
  applied at that instruction's end, after its own FPSR write. Several
  moves in a row compose: the last FPCC and EXC, the AEXC bits ORed,
  the last PC. With an exception pending they stay held until the
  FRESTORE with bit 27 set (as the slot does), so the handler sees the
  APU instruction's FPSR and FPIAR. With the APU idle they apply at
  once.
- **Busy**: a move in progress is the CU busy - a third instruction and
  the conditionals wait for it (Table 5-6: both units idle), FSAVE
  answers come again until it ends (a few clocks), so no frame holds a
  move half done.
- **The frame**: longword 8 the held effect `{valid, FPCC valid, FPCC,
  EXC, AEXC}` and a flag for a CU store's image in `opnd` (longwords
  2-4 then carry it, and a restore puts it back), longword 9 the held
  PC. Both were zero.

**7e-2's benches:**
- `sim/fpu` plain and `+detour`: every FMOVE vector through the CU where
  the conditions allow, against the model; the count by the CU and by
  the APU reported, and a check that the degraded cases (each of b-f)
  went to the APU.
- `+pairs=2|3`, `+pairs=2 +detour`: moves overlapped with everything,
  the held effect against the one-at-a-time run (FPSR, FPIAR after each
  handler).
- Directed: (a) and (f) each way; FSINCOS's FP[c]; a move in right after
  the APU started on the register it reads (the first-word read); a
  held effect across a pending exception, FSAVE, FRESTORE without and
  with bit 27; FSAVE during a CU store's conversion and after it; a
  conditional straight after a move; three moves behind one FDIV.
- **Mutants**: no (a) check; no (f) check; the held effect applied at
  once; RN rounding ties away; the UNFL test after rounding; FSINCOS's
  FP[c] left out of the conflicts.

**7e-2 as built (2026-09-30).** `se30_fpu.v`:
- **The peek** (`pk`): in `B_CMD`, an FPm,FPn with PREC extended or an
  S, D or X store without (d), the slot and the CU free, nothing
  pending and no (a), reads FPm through port B into `cu_fp` (the
  address, then two p1 edges). The first response read answers `$8900`
  until it is in - usually it already is: the command write and the
  synchronous response read leave it the time. (a) answers `$8900`
  until the APU ends.
- **The commit**, at that read: FPm,FPn with a class the CU takes
  (`fcls`: normalized, zero with exponent 0, infinity with mantissa 0)
  and no (f): FPn written (a port B write standing to its p0 edge),
  `$0900`/`$4900`. A store whose image the CU can make (`st_ok`: the
  class, not tiny before rounding, not over after): the image into
  `opnd`, `cu_st`, `$8900`/`$C900`, then at `B_CONV` the CA = 0
  transfer at once. Anything else takes 7e-1's path unchanged.
- **A move in** (`mi`): at the last operand write of an S, D or X FMOVE
  with PREC extended, the slot free and nothing pending, the CU takes
  the command (`cu_cmd`) and releases the MPU; a clock later the operand
  is widened (`widen`), the next FPn written - or, for (b), (f) or an
  exception pending by then, the command goes into the slot for the
  APU. A third instruction, a conditional and FSAVE (come again) wait
  while `mi` runs.
- **The store's rounding**: the top 24 or 53 bits, G and S from the
  rest, RN to even, RZ, RM, RP by the sign, a 54-bit sum whose carry
  bumps the exponent; tiny is the exponent before rounding below 16257
  (S) or 15361 (D), overflow the biased exponent after it 255 or 2047
  and above; the X image is the register with 16 zero bits.
- **The held effect** (`hv`, `h_ccv`/`h_cc`, `h_exc`, `h_aexc`,
  `h_iarv`/`h_iar`): `h_rec` at each commit composes it; the move's PC
  arrives after its primitive (`mv_pcw` routes the instruction address
  write into `h_iar`), or is already in `cu_iar` for a move in. Applied
  when the APU is idle, nothing is pending, no PC is awaited and no
  frame moves: FPCC if a move in set it, EXC replaced, AEXC ORed, FPIAR.
  The hand-off and the direct starts wait for it, so the next APU
  instruction sees the move's FPSR; FMOVE of the control registers waits
  for it even with an exception pending (as for the slot, 7e-1).
- **Found while writing the rules**: a CU store whose transfer is not
  yet read when an older instruction's exception becomes pending
  reports it there as take mid-instruction (UM 7.5.4.2, the store's
  first real response), and after XA returns to `B_CONV` (`take_cst`),
  as 7e-1's `B_HOLD` does.
- **The frame**: longword 8 `{hv, h_ccv, h_iarv, mv_pcw, cu_st,
  take_cst, 0, h_cc, h_exc, h_aexc}`, longword 9 `h_iar`; a CU store's
  image in longwords 2-4. FSAVE's end, a save's AB, a restore write and
  a protocol violation's XA clear them; FRESTORE reinstates them.
- **The conflicts** use the APU's own copy of its command (`ctx_q`'s
  `cmd_r`, which a restored busy frame reloads) or `acmd` while it is
  being started.

**Benches.** `sim/fpu`: every FMOVE vector's route checked against
Table 5-5 (`exp_cu`: b and c from the vector, d from FPCR, (e) from the
model's own OVFL/UNFL), the CU's counted apart with their clocks not
compared (7e-3); directed `moves` (36 checks): FMOVE FP3,FP2 behind an
FDIV released, FP2 written while it runs, FPSR held; (a) waiting; (f)
to the slot; FSINCOS's FPc as (a); a move in overwriting the running
FDIV's source; S (RM, inexact), D and X stores and an X move in behind
the FDIV, all four the CU's; (d) to the APU with INEX2 mid-instruction;
(e) at 2^-126 less an ulp (the APU's, UNFL); the held effect across a
DZ - the handler's FPSR and FPIAR the FDIV's, FRESTORE without bit 27
reporting again, with it the move's FPSR and FPIAR; FSAVE between a CU
store's image and its transfer (come again, the image in the frame,
restored and transferred); the FDIV's DZ pending before a CU store's
transfer ($1D32, the frame, then the transfer after FRESTORE); FBEQ
straight after a CU move. Each compared with the same program with an
FNOP after every instruction.

**Verified.** On the final RTL: `sim/fpu` directed 140; every vector
under `+detour`, 19,836 by group (the CU did 453 moves - convert 349,
rounding 52, ties 32, special 20 - 0 wrong routes, 0 other clocks); the
first 3,000 pairs (the slot took an instruction in 2,036, take mid in
20), triples (2,244, 34) and pairs under `+detour` (1,986, 20); `sim/cpfpu`
all 13 programs; `sim/machine`. On the RTL before the detour guards
(which change only the clock after a busy FRESTORE and a peek meeting a
conflict): every vector plain, the same 453 CU moves. **Still to run**,
tonight with 7e-1's full sweeps: all pairs, triples and detour pairs.
**Mutants**: (a) off - 3 directed fail; (f) off
- 2; the held effect at once - 7; FSINCOS's FPc left out - 1; RN ties
away - 7 of the ties group's vectors; UNFL after rounding - no vector
meets it (it needs a value just under the least normal rounding up),
the (e) directed check added for it fails; neither detour guard (below)
- the regression fails.
- **A bench fix on the way**: a move in finishes a clock or two after
  its dialog, so the bench now decides "the CU's clocks" after the FNOP
  that follows (11 convert vectors had been compared as the APU's).
- **Found by `+pairs=2 +detour`** (1 of the first 3,000, group 1764: an
  FMOD into FP2, then FMOVE.X FP2,`<ea>` waiting on (a), a context switch
  between): FRESTORE of the busy frame loads the APU's context at the
  clock after the frame's end, and in that clock the APU's own command
  was still the detour's FSIN - no conflict seen, the peek read FP2
  before the resumed FMOD wrote it, and the store sent the old value.
  Two guards: the conflict takes the frame's command while its context
  is being loaded (`rs_ctx`), and a conflict seen during a peek drops it
  (read again after). Either alone passes; both kept. Directed
  regression: the same sequence by hand (FSAVE under the waiting store,
  an FSIN, the registers back, FRESTORE) - fails before, passes after.

### 8.9.7 7e-3: the clocks against Table 8-3 (design, 2026-10-01)

**What the manual fixes** (UM 8.1, 8.2, 8.4, read again for it). The
overall times include the coprocessor interface: **11 clocks** when the
FPU is idle (Figure 8-2: a three-clock prefetch, the command write, a
five-clock response read), measured with an MC68020 on the same clock.
The tail is the time after the MPU is released while the FPU still
works; the head "begins when the instruction is initiated by the MPU,
and ends when [it] can no longer operate under the tail of a previous
instruction" - on the 68882 the time the CU spends fetching and
converting the operand. Head + tail need not equal the total.

**The measurement** (`sim/fpu/tb_fpu_timing.v`, committed `188a9f5`): an
MC68020 on the same clock - three-clock cycles, DSACK sampled at the
falling edges (the chip's synchronous reads come out at the manual's five
clocks), a prefetch before each instruction; total, tail, and head (the
same instruction behind an FSIN: total less what it adds after the FSIN
ends). 57 rows, against `sim/fpu/table8_3.csv` (Table 8-3 from the page
images). Operands: FP1 = 0.75 (source), FP2 = 2.25, memory sources 3.0.

**The reading (2026-10-01), ours minus the table:**

| source | head | tail | total |
|---|---|---|---|
| register, every operation | -8 | +10 | +1 (FADD/FSUB +7, FMUL/FDIV +5, FGETEXP +3, FREM -30) |
| single | -16 | +16 | +1 |
| double | -18 | +14 | -3 |
| extended | -20 | +8 | -11 |
| integer (B, W, L) | -7 | 0 | -18 |
| packed | -9 | +25 | -27 |
| FMOVE to FPn S / D / X (the CU's) | -19 / -21 / -23 | 0 | -18 / -20 / -22 |
| FMOVE to memory S / D / X (the CU's) | -17 / -19 / -21 | 0 | -16 / -18 / -20 |
| FMOVE to memory L / P | | | -28 / -26 |
| FMOVECR | -6 | +21 | +1 |

**What it says.** The tails are long by **Table 8-13's conversion time**
for a normalized operand - extended (and a register) 10, single 18,
double 16 - and by nothing for an integer, the one format UM 5.1.1.2
leaves to the APU ("the CU cannot convert the byte operand"). Our APU
budgets (8.8.16) are the 68881's phases, conversion included; on the
68882 the CU converts during the head, so the heads are short by about
as much. The totals are already within a few clocks except where the
dialog differs (extended's three-longword transfer, the integer hold),
the data-dependent figures (FREM's quotient, FADD's exponent alignment:
our operands are not the table's "typical" ones), and the CU's own moves,
which take only a few clocks where the chip spends the conversion.

**The design (for Daniel to settle):**
1. **The conversion phase moves from the APU to the CU.** The CU spends
   Table 8-13's input-conversion time (by the source's format and type,
   the destination's type) before the hand-off; each APU entry's budget
   loses the same time. Integers and packed stay the APU's. This is UM
   5.1.1.2's picture, and the 68881's own phase times still decide every
   case's length - only which unit spends them changes.
2. **The CU's moves take their time too**: FMOVE to FPn the input
   conversion, FMOVE to memory the output conversion (Table 8-17's S/D
   times, X's), so FMOVE.S/D/X to and from a register land on Table
   8-3's 34/40/46 and 38/44/50.
3. **Calibrated to Table 8-3 exactly** for the table's typical operands
   (normalized, the operations' typical cases), under the reference
   harness: whatever the phases leave over - the dialog's own clocks,
   the hand-off - is a small constant per format in the CU, set so head,
   tail and total all equal the table. Other operand types then differ
   from the typical by the detail tables' differences, as on the chip.
   The rejected alternative: accept a few clocks' difference as the
   manual's "guidelines, not exact timings" - but 8.8.3 chose the
   table's clocks.
4. **The integer hold**: Table 8-3's FADD.L (H 21, T 54, total 94) has
   the MPU held while the APU converts (minimum concurrency, Table 5-1);
   ours releases it 18 clocks sooner. To be checked against UM 7.5's
   dialog for B, W, L before changing the release.
5. **FMOVECR** (H 10, T 0, total 32): T = 0 says the MPU is held until it
   ends; ours releases it with $0900. To be read in UM 7.5 first.
6. **The measurement's operands** become the detail tables' typical cases
   (FADD with equal exponents, FREM and FMOD with a one-chunk quotient,
   the transcendentals inside (-9, 9)), so a residual is a design
   difference, not an operand.
7. **The vector bench**: the APU's clocks per vector change with (1), so
   `sim.py`'s timing and `rtlvec.py`'s clocks follow the new budgets; the
   CU's clocks become comparable too (no longer "not compared").

**Daniel's choices (2026-10-01): (1) the conversion moves to the CU;
(3) exactly, for the typical operands; (4) and (5) Table 8-3 - an integer
source and FMOVECR hold the MPU ($8900) until the APU has converted (and,
for FMOVECR, finished), against Figures 7-17/7-18 (8.6.14 item 22).**
(2), (6) and (7) follow.

**7e-3 as built so far (2026-10-01).**
- **The measurement, corrected twice.** (i) The tail runs from the
  instruction's *release* as UM 8.2 means it on the 68882 - the later of
  the MPU's release and the CU's hand-off, since the next instruction, FP
  or MPU, can begin only then; with that reading Table 8-3 is
  self-consistent (every FPm row frees the CU at total - tail = 21, S at
  31, D at 37, X at 43, the integers at 40). (ii) The operands are the
  typical ones: source 3.0 into 2.25 (FADD's equal exponents), 2.5 for
  FINT/FINTRZ, 0.5 for FASIN/FACOS/FATANH, 7.25 for FMOD/FREM. `+matrix`
  runs every operation in FPm, S, D, X and L.
- **The conversion moved** (`asm.py`: `.table NAME TAGPAIR cu|hold`).
  The `cu` tables' (register, X, S, D, dyadic and in-memory monadic)
  budgets leave the microwords for `ucode.cvt.hex`, which `ucode.cvsel.hex`
  indexes by entry; 388 nanowords, from 399. The CU: every register or
  S/D/X instruction goes through the slot, APU idle or not; the slot reads
  FPm (or widens the operand) and FPn through port B, classes them as the
  APU's tag logic does, looks up the time and spends it from the operand's
  arrival before the hand-off; FSAVE answers come again meanwhile; a
  restored slot's time was spent before its save.
- **The integers** (`hold` tables, which keep their budgets in the APU):
  through the slot too, the MPU held in `B_HOLD`; their table time plus a
  constant is a wait *after* the APU is free (the APU converts: the head
  is 21 behind another instruction, then the hold, then the release).
  **FMOVECR** holds the MPU to its end.
- **The constants** (`se30_fpu.v`, against the heads): K_REG -8, K_S -2,
  K_D +2, K_X +10, K_MONO +2 (monadic memory figures are 2 below the
  dyadic, the 68882's heads are not), K_INT -12, K_INTM +6; D_REG 4 (a
  register source's hand-off: total = H + T + 4). The CU's own moves: in
  FPm 11, S 19, D 21, X 23 clocks of the CU busy; out S 20, D 24, X 22.
- **The per-operation calibration** (`ucode/t882.uc`, `.tadj KINDS
  OPMODE N | cr N | out.F N`, `ucode.tadj.hex`): N < 0 starts the APU's
  elapsed count at -N; N > 0 is added at END to whichever ends the
  instruction, its path or its budget (looked up again at END from
  `cmd_r`, so a busy frame keeps it). `sim.py` does the same, so the
  vectors' clocks follow; `vec.py`'s check against `timing.py` now
  subtracts the CU's conversion (`timing.cu_conv`) and adds N > 0;
  `cpgap.py` measures from the count's start.
- **The reading (+matrix, typical operands, 37 operations x FPm/S/D/X/L
  = 185 rows): 129 exact in head, tail and total; 165 exact in total and
  tail** (the 36 others of those are integer rows whose heads read 20
  against 21); 168 within one clock. Exact everywhere: every
  transcendental, FADD, FSUB, FMUL, FMOD, FREM, FINT, FINTRZ, FTST,
  FGETEXP, FSGLMUL. The CU's moves in (FPm, S, D, X) exact in total, their
  heads total - 1 (the harness's end waits for the FSIN).
- **What is left:**
  1. **Path-bound operations**: with the conversion gone from the budget,
     the microcode's own path is longer than the 68882's tail - FCMP 28
     clocks against a budget of 10 (+8 FPm, +5 S/D/X), FSGLDIV +5/+2,
     FDIV +7/+4, FSQRT +4/+1, FABS and FNEG +2 (FPm), FSCALE +2 (FPm),
     FMOVE.L +7. A budget cannot shorten a path; the microcode would have
     to be faster (8.8.16 assumed every path fits its figure: true of the
     68881's, not of the 68882's shorter tails). **For Daniel.**
  2. **Instructions the MPU waits on** (stores, FMOVECR, the integer
     hold): the MPU sees the FPU ready only at its next response read, five
     clocks apart, so a total moves in steps (a store's 2 clocks less moved
     it 6). The manual's figures assume the read "at exactly the moment"
     (8.4). To measure them as the manual does, the harness would take the
     FPU's ready time plus the ideal dialog. **For Daniel** (the stores sit
     at -2..+2 now, FMOVECR +4).
  3. **Packed** (FADD.P -27, FMOVE.P -33, stores -2): not yet calibrated.
  4. FATANH from an integer: an operand artefact (no integer is a typical
     atanh argument).
- **Verified on this build:** `sim/fpu` directed 143 (eight checks
  needed `wait_apu`: they meant the APU busy when the next instruction
  came, and an instruction now spends its conversion in the CU first);
  every vector plain, 19,836, results and clocks (the CU's 453 moves'
  clocks not compared); the first 2,000 pairs, triples and detour pairs;
  the 7a APU bench, the first 3,000; `tools/fpu_ucode/run.sh` 57 PASS, the
  clocks check 13,853 against the restated figures and 3,095 over them
  (all the path-bound operations above); `sim/cpfpu` all 13 (b3c's
  interrupt now lands in the first FMOVECR, which holds the MPU: its
  expectation moved there); `sim/machine`. ModelSim found a use-before-
  declare Icarus hides (the APU's END lookup above `cmd_r`): moved.

**Daniel's choices on what was left (2026-10-01, "OK. We will go with your
recommendations"):** (1) measure the instructions the MPU waits on with
ideal response reads, as UM 8.4 means them; (2) make the path-bound
microcode faster rather than accept it; (3) packed last; (4) then the full
gate, the commit, and 7e-4.

**7e-3 completed (2026-10-02).**
- **Ideal response reads** (`tb_fpu_timing.v`): the harness's MPU reads
  the response at the clock the FPU is ready for it (the chip's own state:
  B_REL, B_HOLD, B_CONV), not at its next 5-clock poll; `+poll` restores
  the polling. Every total that moved in 5-clock steps now reads exactly.
- **The CU hands the APU what it has** (UM 5.1.1.2: the CU fetches and
  tags the operands). At the hand-off the slot's source - FPm as port B
  read it, or the widened S/D/X operand - goes in with the command, and
  the APU skips its fetch (`start_apu_f`); FPn's tags, when nothing could
  have written FPn since the CU read it (`cv_dstok`), go in on `cu_dt`
  and the APU skips S_ENT. Both are clocks the 68882 does not spend in
  its tail.
- **The path-bound microcode made faster** (the typical NORM NORM paths;
  every other case keeps its own): FCMP's normalized pair goes straight to
  the signs and exponents, and each cc word ends the instruction itself
  (`cmp_fn`); FDIV compares the mantissas in the table's word and takes
  one more quotient step when the dividend's is the smaller, so the
  quotient comes out normalized and rounds without pp's normalize
  (`div_c`, `pp_md1`), the sticky bit taken on the remainder's add
  itself; FSGLDIV the same, its source truncated inline (`sgd_n`); FSQRT's
  normalized operand skips the shift (`sq_n`, `pp1`); FMOVE, FABS and FNEG of a normalized
  value round without the normalize (`mv_fn`, `pp1`); FMOVECR's constant
  is normalized (`cr_pp`, `pp1`), its below-the-true-value case to nearest
  goes straight on (`cr_dn`), and an ulp added or taken calls pp from the
  same word; **FMOVE from an integer** has its own entry (`pro_imv`,
  table `cv_imv`): an integer is exact, never tiny or huge, and has no
  exceptional operand, so no destination read, no T9 copy, no OPMODE and
  STAG dispatches - 9 words where it was 13. The CU's per-table constant
  covers `cv_imv` as it does `cv_intm` (`cvk`).
- **Packed** (`se30_fpu.v`): every P row of Table 8-3 has total = H + T +
  69, the integers' H + T + 19 - the MPU held while the APU converts, as
  8.6.14 item 22 rules for the integers. A packed source now holds the
  MPU ($8900 in B_REL) for `P_HOLD` = 54 clocks from the APU's start
  (calibrated: the operand's own dialog lies inside it). The hold timer
  this uses replaces a dead one (the earlier integer hold's `hold_T`,
  `cvt_h`, `cvsel_h`: `hold_on` was only ever set with `hold_end`, and
  `hold_t` was never cleared) - two ROM copies fewer.
- **The calibration** (`tools/fpu_ucode/t882cal.py`, new; `ucode/t882.uc`
  its output): `zero` (every N 0), measure; `set` (N = minus each row's
  tail error), measure; `refine` (a row still too long there is
  path-bound by that much: N = -d0 + d1, the least shortening that has
  effect, and it is reported) - so a negative N never goes past where it
  acts and shortens an operation's other cases. By operation and source
  class: register, S/D/X, B/W/L, P. FATANH's integer row borrows FASIN's
  (no integer is a typical atanh argument); the CU's own moves have no APU
  time to adjust. The `cr` and `out.F` lines are set by hand: FMOVECR -6,
  stores L/W/B +29, P +25.
- **The reading** (`+matrix`: 38 operations x FPm, S, D, X, L, P = 228
  rows, typical operands): **185 exact in head, tail and total; 227 exact
  in tail and total** - the 42 heads off are FMOVE FPm/S/D/X at total - 1
  (the harness: the CU's moves finish under the FSIN, and its end waits
  for the FSIN) and every packed row at 9 against 13 (the dialog before
  packed's wait for both units: nothing in the manual says what the
  68882's 4 clocks are); the one row off in tail and total is FATANH from
  an integer (atanh(3) is an operand error, not the table's case).
  **FMOVECR 32** (head 9 against 10); **FMOVE to memory L 110, S 38, D 44,
  X 50, P 2006** - all exact in total.
- **What the typical calibration leaves in other cases** (`vec.py`'s
  clocks check, the 68881's per-case figures restated for the 68882):
  14,190 of the 16,948 vectors with a per-case figure match it, 2,758
  run over it (3,095 at `b53c2b0`) - all atypical cases: the special
  operands, zeros, infinities, NaNs and denormals (1,697 of 5,888), the
  rounding group's carries, overflows and underflows (755), unnormalized
  and denormal sources (200), FMOVECR in the other rounding modes (57),
  the transcendentals' special arguments (43); by at most 13 clocks, nearly
  all at most 10. Table 8-3 gives the 68882 only for the typical case; the
  per-case figures are the 68881's less the CU's conversion. A negative N
  shortens every case of an operation alike, and where an atypical case's
  own path is longer than its shortened figure it runs over it. No document
  gives the 68882's atypical figures, so there is nothing to chase.
- **Verified on this build:** `tools/fpu_ucode/run.sh` 57 PASS and every vector
  (results); `sim/fpu` (out/fpu_rtl.vec regenerated) directed 143, every
  vector plain and under `+detour` (19,836 each, results and clocks), the
  first 2,000 pairs, triples and detour pairs; the 7a APU bench, every
  vector; `sim/cpfpu` all 13 (ModelSim: no use-before-declare); `sim/machine`.
  Logs in sim/fpu/out/gate3 (ignored). **The full runs on `aedbea2`
  (the night of 2026-10-02, worktrees): all pairs, all triples, all
  detour pairs - 19,836 each, 0 fail** (logs in sim/fpu/out/night_1002).

### 8.9.8 7e-4: the cputest corpus (design, 2026-10-02)

**What it is for** (8.4 item 7): WinUAE's `cputest` 6888x tests as a
second check beside the model's vectors - **a regression against WinUAE's
model, not silicon** (8.6.15); a mismatch is a question for the manual or
hardware, not a verdict.

**Where the data comes from.** Nothing on disk: the PMMU upstream's clones
hold only the integer `68030_Basic`/`68030_ODD_IRQ` data, and WinUAE
publishes no prebuilt sets (`cputest/readme.txt`: generate locally with
`cputestgen` and `cputestgen.ini`). The Quadra core's `data040` corpus is
a 68040's. So the corpus is ours to generate: WinUAE's source at a pinned
tip, its `cputestgen` built with Visual Studio 2022 (installed on this
box), an ini for a 68030 with a 68882 (`CPU=68030`, the FPU groups; the
readme's FPU mode runs every FPCC x precision x rounding combination, 256
per test), the generator's own limits recorded with the data ("Not all
tests work correctly yet"; FSAVE/FRESTORE not implemented). The Quadra
core's report on that generator (`rtl/ap68040/doc/CPUTEST_UPSTREAM_REPORT.md`)
names two generator defects with memory-source operands (16-bit index
scaling; `-(A7)` byte decrement) - expect them here too.

**The harness - two ways:**
- **A. Convert and drive the chip.** Decode each test (`decode_cputest_dat.py`,
  extended for the FPU data), turn it into our vector form (instruction,
  FPCR/FPSR, FP registers, the memory operand; expected FPn, FPSR, the
  exception, a store's memory) and run it through `tb_se30_fpu` and the
  Python model, as the model's vectors are run. Iverilog-fast; the whole
  corpus. It tests the FPU, not the 030's side (the effective address, the
  dialog, the frames), which `sim/cpfpu` covers.
- **B. Run the tests as programs** on the kernel and the FPU under ModelSim
  (`sim/cpfpu`), with a runtime doing what cputest's `main.c` does (load
  the registers, run, capture the exception, restore memory). Tests the
  whole path; ModelSim Starter's speed makes the whole corpus days, so a
  sample per instruction and addressing mode.

**For Daniel:**
1. Clone WinUAE (github `tonioni/WinUAE`) and build its `cputestgen`
   here - a download and a build on this machine.
2. The harness: **recommended A for the whole corpus and B for a sample**
   (A's breadth at iverilog speed; B for the 030's half).
3. The groups: the FPU's own (basic arithmetic, the FMOVE formats including
   packed, FMOVEM, the conditionals) at the ini's defaults, the 68030's
   integer groups left to Section 1.

**Daniel's choices (2026-10-02): all three recommendations** - WinUAE
cloned and its generator built here; harness A for the whole corpus and B
for a sample; the FPU's own groups at the ini's defaults.

**7e-4 as built (2026-10-02).**
- **The generator.** WinUAE `12ad6ac` (2026-09-30) cloned shallow at
  `C:/Git/MiSTer-devel/WinUAE`. Visual Studio 2022 here has no C++ toolset,
  so `cputestgen` is built with g++ under WSL Ubuntu (`tools/cputest/
  build.sh`): the Windows project's sources, the `od-unix` port's headers,
  `od-win32`'s `machdep/m68k.h` (the tester's flag layout), `wprintf` and
  `_wmkdir` mapped, `gencpu` with `CPU_TESTER` for the test cores
  (`cpudefs.cpp` is in the tree). `tools/cputest/se30dump.py` patches the
  build copy (never the clone) so each stored round is also written as one
  text line - the instruction, the state before and after, every data read
  and write in order, the exception - which is what harness A reads.
  `generate.sh` runs each FPU preset (FBASIC, FCPX, FINT, FPACK, FILLG) in
  its own `cputestgen` run, `cpu=68030 fpu=68882`, gzip off, the ini's
  defaults otherwise (`gen_ini.py`). **A group generated after others comes
  out wrong** - empty, or with their settings - so each runs alone. Its
  `.dat` files differ between runs only in the header's timestamp.
- **The corpus** (`C:\temp\Mac\SE30\cputest`, 100 MB of `.dat`, 3.6 GB of
  records in WSL): FBASIC 1,353,296 rounds, FCPX 852,828, FINT 1,877,120,
  FPACK 81,756, FILLG 153,324 - 4,318,324.
- **Harness A** (`convert.py`): each round on the bench's registers (FP1
  source, FP2 destination, FP5 FSINCOS's cosine), the operand as the round
  read it, WinUAE's results as the expectation, xop not compared (WinUAE
  records none); identical vectors once: **924,464 distinct vectors**
  (general, conditionals) and **24,128 FMOVEM / FMOVE-control records**
  (`M` form, `check_m.py`). Left out, counted: what the 030 itself F-lines
  (an effective address the instruction may not use: 722,314 rounds),
  FSINCOS with one register for both (160), and FMOVE of two control
  registers from an immediate (1,536 - the generator writes one longword
  and the 030 takes the next instruction's words as the second).
- **FMOVEM's order** (`check_m.py`): where the list's mode field and the
  effective address disagree (a predecrement list with a control address,
  ...), the FPU transfers in the mode's order and the 030 addresses in the
  EA's, so the registers land reversed - which WinUAE does and the model,
  seeing only the FPU, cannot; the checker applies the protocol. All 24,128
  agree.

**What the corpus found in our design (fixed):**
1. **FCOSH of |x| above about 45,400** (microcode): `iadd`'s 18-bit
   exponent difference of e^|x| and its reciprocal wrapped, the result came
   out +0 with UNFL (208 vectors, the microcode against the model).
   Above t = 2^41 the reciprocal is now not formed (`ch_big`: the model's
   `i_add` chops it whole there; constant `b40`); the budget moved onto
   the test, the clocks unchanged. Swept: 12,108 vectors against the model.
2. **FMOVE to FPCR and FPSR kept the bits that read zero** (RTL, harness B):
   `5D401D00` read back as written, not `0D401D00`; FPCR's upper word and
   FPSR's bits 2-0 likewise. Now masked as the model does (UM 4-70).

**WinUAE against our model** (`check.py`, `triage.py`, `accuracy.py`):
739,925 of 924,464 agree; every one of the 184,539 others has a named
cause:

| cause | vectors | the manual | standing |
|---|---|---|---|
| FPCR PREC = 11 | 60,295 | "undefined, reserved" (8.6.2) | WinUAE rounds as double (a `default:` in its code, no claim); ours extended. **Open: 7e-4 item A** |
| a NaN converted from S or D: the integer bit | 17,616 | extended NaN: integer bit "don't care" | WinUAE clears it (Previous's 68K softfloat, deliberately); ours sets it. **Open: 7e-4 item B** |
| transcendentals, last bits to large | 78,530 | 4.3.2: ~64 units typical; 4,096 the bound; 4-102 the 2pi reduction | ours by design (8.7.3): 67-bit algorithms, every result here within 94 units of extended inside the documented range; WinUAE runs Motorola's 68040 FPSP and is more accurate than the 68882. Trig beyond ~10^20 (288 here, signs too) is the documented loss |
| overflow in FETOX/FTWOTOX/FTENTOX/FSINH/FCOSH: INEX2 | 7,986 | 6.1.4/6.1.7 | WinUAE's FPSP path sets OVFL alone; its FMUL/FADD overflows set INEX2 as ours do everywhere. Ours consistent |
| FSGLDIV operand truncation | 8,508 | 4-98: beyond 24 bits "the accuracy ... is not guaranteed" | switch `sgl_truncate_bits` (8.6.14 item 9): **WinUAE truncates neither operand for FSGLDIV, only FSGLMUL's** (8.6.15's row 9 said both - corrected); ours both. Either within the manual |
| FSGLDIV overflow | 848 | 6.1.4's note: the mantissa rounded to single | WinUAE gives the extended maximum; ours the single-mantissa one. Ours per the manual |
| FINT/FINTRZ in S or D PREC | 3,848 | switch `fint_prec` | WinUAE does not round to PREC at all - a third reading beside 'twice' and 'once' |
| FREM/FMOD in S or D PREC | 2,260 | FREM's note 2: "processed by the normal instruction termination procedure to round it" | ours rounds; WinUAE does not. Ours per the manual |
| FATANH(+/-1), FLOGNP1(-1) | 1,328, 656 | 8.6.14 items 1, 2 | as known |
| FMOVECR | 480, 240 | switches `fmovecr_documented`, `fmovecr_undefined` | as decided; WinUAE's undefined offsets also set INEX2 in S/D PREC |
| FLOGN/FLOG10 of 1: INEX2 | 1,136 | 4.3.2: INEX2 "may be set even if an exact result is produced" | WinUAE sets it on the exact zero; ours not. **Open, minor: 7e-4 item C** |
| FSINCOS: only the cosine differs | 220 | | the transcendental row |
| FREM/FMOD: UNFL on an exact zero | 148 | 6.1.5 | WinUAE sets it; ours not. Ours per the manual |
| FMOVE.B/W/L out of range: INEX2 | 112 | 4-66: OPERR, INEX2 "refer to 6.1.7" | ours sets INEX2 for a source with a fraction; WinUAE OPERR alone. **Open, minor: 7e-4 item D** |
| FSCALE with \|scale\| >= 2^14 | 40 | 4-102: "an overflow or underflow always results" | ours per the manual; WinUAE scales |

**Open for Daniel** (from the table, and one the corpus found in our own
spec): 7e-4 items A-D above, and **8.6.14 item 20 against 8.6.8**: the
spec's 8.6.8 quotes Table 4-17's note - an empty control-register list
"on the current chip ... moves FPIAR" - and the model does so (as WinUAE);
item 20's default (the F-line) is what the RTL does. Harness B leaves those
rounds out until it is settled. **Recommended: FPIAR** (the documented
behaviour, the standing rule for it).

**Our three against each other, on the corpus's inputs** (`remodel.py`:
the same inputs, the model's expectations): the microcode simulator, all
924,464 (after the FCOSH fix; before it the 208 above); **the RTL bench, all
924,464 - results and clocks, 0 fail** (`sim/fpu` with `+vec=`, eight
shards). The clocks against the restated 68881 per-case figures
(`vec.py`): 80,348 vectors over by less than 20 clocks - atypical operands
whose path is longer than the typical-case calibration (8.9.7), as before.

**Harness B** (`harness_b.py`, `sim/cpfpu/run_cputest.sh`): rounds where
the model and WinUAE agree, up to 4 per instruction and addressing mode,
run on the 68030 kernel and the 68882 (ModelSim) - each round's operand
bytes stored at its address's alias in the bench's 128 KB, its base
register moved (or its absolute address rewritten) to a free slot, FP0-FP7,
FPCR/FPSR/FPIAR and D0-A7 loaded, the instruction and an FNOP run, all of it
stored and compared. **9,392 rounds of 40 instructions in 79 batches:
405,813 checks, 1,453,299 coprocessor cycles, all pass** on the fixed
design. Every addressing mode but PC-relative: Dn 768, An 8, (An), (An)+,
-(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L about 1,080 each, #imm
1,040. Left out: branches (FBcc, FDBcc), trapping FTRAPcc, traced rounds,
PC-relative, an empty control list. Its first run found item 2 above and
nothing else (and item 1, on the microcode before its fix).

**Verified on this build:** `tools/fpu_ucode/run.sh` 57 and every vector,
clocks as before; `sim/fpu` directed 143, every vector plain and +detour,
2,000 pairs, triples and detour pairs, the APU bench; the timing matrix
unchanged (8.9.7's reading); `sim/cpfpu` all 13; `sim/machine`. Logs:
`sim/fpu/out/gate4`, `out/cpt_rtl`, `C:\temp\Mac\SE30\cputest`.

---

# Section 9 - SCSI (opened 2026-10-03)

Daniel, 2026-10-03:
- **"start on SCSI".**
- **Targets:** two hard disks (IDs 0 and 1), the CD-ROM (ID 3) and CD
  audio into the core's sound.
- **Staging:** disks first, the CD-ROM after.
- **Design: "go with option A"**. That is our own 53C80, written to NCR's
  manual, and the MacPlus `scsi.v` targets.

## 9.1 Sources, and their standing

| Source | What it gives | Standing |
|---|---|---|
| **NCR SP-1051, *NCR 5380-53C80 SCSI Interface Chip Design Manual*, Mar 1986** (`C:\temp\Mac\SE30\Docs\scsi\`, bitsavers, 3,176,025 B, downloaded with Daniel's OK; text extract `NCR5380_53C80.txt`) | the chip: pins, registers, modes, DRQ, interrupts, reset | **primary for the chip** - the document the *Guide* itself defers to ("described in detail in NCR's documentation for the 5380") |
| *Guide* 2e ch. 11, pp. 375-394 | the SE/30's SCSI as a system: normal and pseudo-DMA modes, polling and blind transfers, GLUE's DRQ handshake and its bus error, IRQ and DRQ to VIA2, longword moves as four byte cycles, ~1.4 MB/s blind | **primary for the system** |
| `se30.pdf` sheet 6 "SWIM & SCSI interface" | the wiring (9.2) | **primary for the wiring** |
| The ROM (97221136), disassembled 2026-10-03 (`audit_se30_rom_scsi.md` and `romscsi\` beside the manual) | what the SE/30's own software does with the chip (9.3) | **evidence of use** |
| MacLC `rtl/ncr5380.sv` (3017ba7), audited against the manual (`audit_lc_ncr5380_vs_datasheet.md`) | engineering only; not taken (9.4) | donor, rejected for the chip |
| MacPlus `rtl/scsi.v`, `master` `e5e54c7`, 1,757 lines, sha256 `5ac14cad35ae40a2...` | the drives: a SCSI target speaking only bus signals, with a CD-ROM mode and CD audio | **donor for the targets**, hardware-proven on the MacPlus (the 62 MB byte-exact soak) |

## 9.2 The wiring (sheet 6, UI12 = 53C80)

| 53C80 | SE/30 |
|---|---|
| D7-D0 | **D31-D24**: an 8-bit port, `DSACK0*` only |
| A2-A0 | **A6-A4**: register *n* at offset `$10 x n` |
| /CS | GLUE `SCSI*`: the `$50010000` window (2.11.3 row 7) |
| /DACK | GLUE `SCSIDACK*`: `$50012000` (no wait, row 8) and `$50006000` (`DSACK0*` held until DRQ, row 5) |
| /IOR, /IOW | GLUE `IOR*`, `IOW*` |
| DRQ | `SCSIDRQ`: GLUE's handshake and VIA2 CA2 |
| IRQ | `SCSIIRQ`: VIA2 CB2 |
| /EOP | `PU`, **pulled up: never asserted** |
| READY | **not connected** |
| /RESET | `RESET*` (the CPU's RESET instruction resets it, as the VIAs) |
| the bus | J5 (internal 50-pin) and J4 (external DB-25) in parallel; TERMPWR through D3/F3 |

So the SE/30 uses the chip's CPU-paced modes only. There is no end of
process, no block-mode DMA and no READY handshake; GLUE does the
handshake from DRQ. IRQ and DRQ are both active high (no slash on pins
9 and 10).

## 9.3 What the ROM does with it

From the disassembly (`audit_se30_rom_scsi.md`, every address there):

- **Bases (`$40800634`):** SCSIBase `$0C00` = `$50F10000`, SCSIDMA `$0C04`
  = `$50F12000`, SCSIHsk `$0C08` = `$50F06000`. The 24-bit MMU table's
  entry 15 maps `$F00000` to `$50F00000`, CI.
- **Commands, arbitration, selection and status** go through the
  register window, byte by byte.
- **Polled transfers** use `$50F12000` (write) and `$50F12060` (read),
  byte moves, each byte waiting for **DRQ in register 5 bit 6**. The end
  is **phase match (register 5 bit 3) going clear** (error 5). There is
  no software timeout.
- **Blind transfers** use `$50F06000` and `$50F06060` with **longword**
  moves, eight a pass. Only the first byte waits for DRQ; every later byte
  rides GLUE's held `DSACK0*`.
- **No interrupts:** VIA2's IER only ever gets `$7F`, `$02` and `$82`
  (slots), and the 53C80's interrupt enables are never set. The ROM never
  uses IRQ or DRQ as interrupts. (A/UX, per the *Guide*, may.)
- **Timeouts** are scaled from TimeSCSIDB (`$0DA6`), calibrated against a
  1 ms VIA1 timer by reading register 4 at `$50F10040`. They hold whatever
  the core's access time is, but that read must answer. Arbitration and
  REQ waits are 256 ms, selection 250 ms.
- **Bus reset (`$40826C7C`):** RST held ~125 us with interrupts masked,
  IRQ cleared, then ~275 ms. Done once at boot unless an XPRAM bit says
  not to.
- **Boot (`$4080151C`):**
  1. Drivers are loaded from IDs 7 down to 0.
  2. Then it waits **up to 20 s from boot** for the internal disk (ID in
     `$0C2F`, from XPRAM; 0 by default), retrying every 15 ticks.
  3. A disk needs block 0 with `'ER'`, then block 1's partition map with
     an `"Apple_Driver"` entry (or `"Apple_HFS"`).
  4. Every read is a READ(6) through the polled path, with a 60-tick
     completion timeout.

  At 20 s of uptime the ROM sends TEST UNIT READY once and records in
  PRAM whether the drive answered. **With our volatile PRAM every boot
  without an internal disk pays the 20 s**, as a real SE/30 with a fresh
  PRAM would.
- **The board's loop at `$408268F4`** (compiles 26-28, no SCSI) is the
  arbitration wait reading ICR at `$50F10010`. Our `$00` has AIP clear, so
  each attempt gives up after 256 ms; an open-bus `$FF` would hang it.
- **A hazard to check, not to fix:** the bus-error handler at `$40826B26`
  always discards a 92-byte format `$B` frame. A blind **write** that
  times out may build the short `$A` frame on a 68030 (UM 8.2: the short
  frame when the fault falls at an instruction boundary). Whatever the
  68030 does, we do; the bench checks that our kernel picks the frame the
  UM's rule picks.

## 9.4 The LC donor, audited and rejected for the chip

`audit_lc_ncr5380_vs_datasheet.md` (2026-10-03).

**Right:**
- the register map and read/write split;
- the bit order of the Current SCSI Bus Status and Bus and Status
  registers;
- phase match as a continuous compare;
- Start DMA requiring DMA MODE;
- a read of register 7 clearing IRQ.

**Wrong in ways the SE/30 sees:**
- End of DMA reads 1 outside a data phase; with /EOP tied high it should
  never set.
- Bus and Status bit 6 is not the DRQ pin.
- DRQ is not gated by phase match, so a waiting `$50006000` access
  completes in the status phase instead of ending in GLUE's bus error.
- A bus reset clears IRQ instead of raising it.
- The phase-mismatch interrupt is LC/System-7-specific.
- A "deferred REQ" workaround hides each new REQ.
- ACK is not tied to REQ, so blind transfers can ACK early or return a
  stale byte.
- ASSERT DATA BUS ignores I/O.
- Arbitration ignores a busy bus.
- An ICR RST clears only DMA MODE.

On top of that it carries the LC's 16-bit pseudo-DMA plumbing. Its
targets (`scsi.v`) also watch the LC chip's host-side reads, so they
only work beside it.

**So the chip is ours, written to SP-1051.** It is small: the LC's whole
chip model is ~390 ALMs.

## 9.5 The design

1. **`rtl/se30_ncr53c80.v`, ours.**
   - The registers of SP-1051 section 6.
   - The initiator role.
   - Arbitration on a bus that can be busy.
   - Selection, normal-mode handshaking through ICR and TCR.
   - **Pseudo-DMA as section 7 defines it.**
     - DRQ asserts on REQ with phase match.
     - On a read, the byte is **latched on REQ** and ACK is asserted.
     - ACK releases after /DACK and REQ are both false.
     - DRQ falls with /DACK.
     - Phase mismatch stops recognising REQ.
   - The interrupts of section 8 that the SE/30's wiring can raise: bus
     reset (always), parity, phase mismatch, loss of BSY, and selection if
     enabled. Not EOP.
   - Reset per section 9.
   - **The target role and block mode are not built:** the SE/30 is
     always the initiator, and READY and /EOP are unwired.
   - The CPU side is GLUE's existing strobes: one access per byte cycle,
     /CS or /DACK, data on `D31-D24`.
2. **The SCSI bus** inside the core: an 8-bit data bus plus BSY, SEL,
   ATN, ACK, RST, MSG, C/D, I/O, REQ, wired-OR (active-high internally),
   between the chip and the targets.
3. **The targets:** the MacPlus `scsi.v` at `e5e54c7`, byte-exact, two
   instances (IDs 0 and 1).
   - Its Plus-only `data_holdoff` stall is unused. The SE/30 waits on DRQ,
     which follows REQ.
   - **To verify at the RTL step:** that its REQ is withheld until each
     byte is really there (an SD read in flight). The handshake depends
     on it.
   - Stage 2 adds the CD-ROM at ID 3 from the same file's CD mode. The
     `sound-phase` branch's later CD fixes are decided then.
4. **Images:** two `S` mounts (`S2`, `S3`), `VDNUM` 4, through `hps_io`'s
   SD block interface as on the MacPlus. 3.3's SDRAM map reserved
   `$A00000` up for SCSI, which this design does not need: the targets
   buffer in block RAM.
5. **The machine:** GLUE's `scsi_drq` from the chip; VIA2 CA2 = DRQ, CB2 =
   IRQ (4.x's table already names them); `dev_rdata` from the chip for
   both windows; the chip's reset from `via_reset_n`'s source.
6. **The budget.** Compile 28 is 33,755 ALMs; the practical ceiling is
   about 38-39k.
   - Stage 1 (chip plus two disks) is about +1,800, judged from the LC's
     targets.
   - Stage 2's CD-ROM with audio is about +5,800 in the LC (audio ~3,000),
     which is at or over the ceiling. It is measured at stage 2.
   - The probe deck (1,314 ALMs plus ~300 of JTAG hub) can be left out of
     release builds.

## 9.6 The tests (the standing method: seam benches, then the board)

1. **`sim/ncr53c80`:** the chip against SP-1051, register by register, and
   the pseudo-DMA protocol against a scripted target. It checks:
   - DRQ on REQ with phase match only;
   - the latched read byte;
   - ACK release;
   - DRQ falling with /DACK;
   - phase mismatch;
   - each interrupt and its clear by a register 7 read;
   - the ICR RST reset;
   - arbitration against a busy bus.
2. **`sim/scsi_seam`:** chip and two real `scsi.v` targets on the bus,
   driven by **the ROM's own sequences**: SCSIReset, arbitration,
   selection, a READ(6) through the polled path, a blind read and write
   through the handshake window, with longword moves as four byte cycles.
   The image data comes back byte-exact.
3. **`sim/system` or `sim/machine`:**
   - GLUE's handshake window waits on DRQ;
   - the bus error when DRQ never comes, inside 2.11.4's window;
   - **the frame the kernel builds for a blind-write timeout, against UM
     8.2's rule**.
4. **Quartus analysis**, then a compile with Daniel's go-ahead.
5. **The board**, each step checked on the host:
   - boot System 6 and 7 from an ID 0 image;
   - a second disk at ID 1;
   - `hfs_check` and byte-exact `hfs_fork_diff` after a Finder copy;
   - a soak (a large folder copied, byte-identical);
   - Speedometer's Disk test and full Performance Rating, as Daniel's
     forum comparison wants.

## 9.7 Open

- **GLUE's handshake timeout** is not given for the SE/30. Row 5 of
  2.11.3 uses UI6's 18.4-63.3 us window until a document says otherwise.
- **The bus-error frame** for a blind-write timeout (9.3).
- **Persistent PRAM** would spare the 20 s wait without an internal disk
  (a convenience, Daniel's call; plan 6 keeps PRAM volatile).

## 9.8 As built

**Step 1, the chip (2026-10-03, Daniel: "go ahead").**
- **`rtl/se30_ncr53c80.v`**, to 9.5 item 1. Its header lists what is
  built, what is not, and four readings where SP-1051 is silent:
  - Start DMA Send raises DRQ at once.
  - A bus reset holds the chip cleared while RST is on the bus, ICR bit 7
    still writable.
  - Resetting DMA MODE releases a DMA-held ACK.
  - The selection interrupt is taken as written.

  REQ is taken as a level for DRQ and ACK ("REQ true", T7/T9), because a
  Mac's target is usually already requesting when Start DMA is written.
  Only the phase-mismatch interrupt is on the edge, as 8.5 words it.
- **`sim/ncr53c80`: 85 checks PASS in under a second**, sections 6-9 and
  11.4/11.6 by name. Five mutants are caught, each a deviation the LC
  audit found:
  - DACK not clearing DRQ (6 checks fail);
  - the Input Data Register read live (1);
  - REQ recognised against a mismatched phase (1);
  - send-ACK released without DACK cycling (4);
  - a bus reset not interrupting (2).
- **GLUE: `SCSIDACK*` at `$50006000` now asserts only from the strobe,**
  which GLUE gives once DRQ is seen. Before, it asserted from AS*.
  - SP-1051 4.1: DACK "resets DRQ" (T1 "DRQ false from DACK true"). A DACK
    raised while GLUE waits for DRQ would clear the DRQ it waits for, and
    every blind transfer would bus-error.
  - GLUE's internals are undocumented; this is the reading under which
    NCR's chip works.
  - `sim/glue` 98 PASS.

**Step 2, the drives and the seam (2026-10-03).**
- **`rtl/scsi.v`:** the MacPlus core's `master` `e5e54c7`, **byte-exact**
  (sha256 `5ac14cad35ae40a2b56d98da297b73452f633f6e915f7e90c889dff3072136e9`,
  CRLF/LF as in the blob; `core.autocrlf` false). Never edited here.
- **`rtl/se30_scsi.v`:** the chip, the bus, and two `scsi` targets (IDs 0
  and 1, `CDROM` 0).
  - The bus is composed as the MacPlus core composes it: the target
    holding BSY drives the phase lines, REQ and its data; the data bus is
    the chip's drive OR the target's in an I/O phase; `din` is the bus.
  - The disks' `io_ack` is framed by BSY, and `sd_buff_wr` by the slot's
    ack (the MacPlus core's corruption fix).
- **The seam's one adaptation: REQ's deskew.** A SCSI target sets its data
  and waits a deskew delay before REQ; the 53C80 latches on REQ.
  - `scsi.v`'s REQ is combinational (`!ack && ...`) and rises the clock
    ACK falls, while its byte arrives two to three clocks later through a
    registered strobe and buffer read.
  - So the bus REQ rises only once the target's has held for `DESKEW` = 4
    clocks (128 ns), and falls at once. Measured: 0 or 1 clock gives
    nearly every byte stale, 2 half of them, and 3 is the minimum that
    passes.
- **A chip bug the seam found, fixed in `se30_ncr53c80.v`:** in a send
  with the target already requesting (the ROM waits for REQ before Start
  DMA Send), ACK and REQ's fall come while DACK is still active, and DRQ
  for the next byte was never raised.
  - SP-1051's T2, "DACK false to DRQ true": DRQ now waits for DACK to go
    false (`drq_due`).
  - `sim/ncr53c80` gained case 8b, which fails on the old chip.
  - **106 checks PASS.**
- **`sim/scsi_seam`: 58 checks PASS in 6 s.** It replays the ROM's
  SCSIReset, SCSIGet, SCSISelect, SCSICmd, SCSIRead/RBlind,
  SCSIWrite/WBlind and SCSIComplete sequences, with a model `hps_io` at
  10 us and 100 us a sector:
  - TEST UNIT READY;
  - READ(6) polled and blind (per-block ops, as the driver's TIBs), byte-
    exact;
  - WRITE(6) polled and blind, the image byte-exact after the flush, and
    read back;
  - ID 1's own image;
  - an absent ID timing out;
  - one byte too many ending on PHASE MATCH (the ROM's error 5).

**Step 3, the machine and the top (2026-10-03).**
- **`se30_machine.v`:**
  - `se30_scsi` on GLUE's `scsi_sel`/`scsi_dack`, with one strobe per
    access (`dev_strobe && phi1`), `rs` = `dev_addr[6:4]` (A6-A4) and
    `dev_wdata`;
  - its read into `dev_rdata`;
  - DRQ into GLUE's handshake and VIA2 CA2, IRQ into VIA2 CB2;
  - the chip's reset is `RESET*` (`via_reset_n`, which includes the CPU's
    RESET instruction); the drives' is the core's reset only.
  - The image ports are packed vectors (`{disk 1, disk 0}`), because
    plain Verilog has no array ports.
- **`MacSE30.sv`:**
  - `SC2,IMGVHD,Mount SCSI-0` and `SC3,IMGVHD,Mount SCSI-1`, the MacPlus
    core's form;
  - `hps_io` `VDNUM` 4: slots 2 and 3 with `sd_wr`, `img_size[40:9]` as
    blocks.
- **Probe deck PSCS:** the bus (`se30_scsi`'s `dbg`), the disks'
  `io_rd`/`io_wr`/`sd_ack` and a 10-bit count of sectors moved;
  `read_probes.tcl` decodes it with the bus phase by name.
- **ModelSim and `scsi.v`:** ModelSim's `vlog` rejects `scsi.v`'s forward
  references (vlog-2730, `data_cnt` before its declaration) in Verilog and
  SystemVerilog mode alike; Quartus and Icarus accept them.
  `sim/machine`, which mounts no disk, compiles `sim/machine/scsi_idle.v`,
  an idle stand-in. The real target is benched in `sim/scsi_seam` and
  elaborated by Quartus.
- **Benches:**
  - `sim/ncr53c80` 106 and `sim/scsi_seam` 58 PASS;
  - `sim/glue` 98 PASS;
  - `sim/machine` PASS (fresh log 10:42).
- **Quartus analysis and elaboration: 0 errors**, 129 s. From our files
  only `mr_block` is unused (block mode, not built); the rest are
  `scsi.v`'s own unused CD wiring in disk mode.
- **9.6 item 3, the handshake bus errors (`sim/system` `berrtest`):** a
  blind read at `$50006060` and a blind write at `$50006000`, with GLUE's
  DRQ tied low. Each waits for DRQ and UI6 bus-errors it.
  - A handler records the frame's format word and SSW.
  - **Both are the long frame, format `$B`, vector offset `$008`.** The
    read's SSW is `0145` (RW read), the write's `0105` (RW write).
  - The read is the UM's explicit rule (8.2.2, "data read faults only
    generate the long bus fault frame").
  - For the write, the UM allows either frame (8.1.2: short at an
    instruction boundary, long during an instruction). Our kernel builds
    the long one, which **the ROM's handler at `$40826B26` (always
    discarding 92 bytes) survives**.
  - All six `sim/system` runs PASS in 197 s.
- **Compile 29** (Daniel's go-ahead, 2026-10-03): stage 1 for the board.
  - **Tag 903df2c5, 37 min.** Archived as
    `output_files/MacSE30_903df2c5_scsi1.rbf`.
  - **34,959 ALMs (83 %), 327 RAM blocks**: stage 1 added 1,204 ALMs, under
    9.5's estimate of 1,800.
  - **NOT met at every corner.** `se30_sdram`'s
    `state.S_DL~DUPLICATE -> dq_out[8]` on `clk_mem` (`general[1]`, 10.63
    ns) fails setup by **-0.109 ns at slow 100C only**. That is our
    controller, not SCSI logic, placed worse in a fuller chip.
  - **`sta_corners.tcl` missed it.** Its verdict line covers only the
    capture chain and the SDRAM pins. The design's own worst setup per
    corner includes the capture (-0.370 at slow 100C) and so hid the
    -0.109. The flow summary, with the capture cut, shows it.
  - **Daniel, 2026-10-03: "A, I'll flash it now"**: flashed for the
    functional SCSI test. The fix goes into the next compile:
    - the script to report the design excluding only the capture;
    - the `dq_out` path shortened.
- **On the board (2026-10-03): SCSI boots, then hangs.**
  - `I:\games\MACSE30\mac_80mb-restored.vhd` as SCSI-0 (System 7.5.5)
    hangs at the 7.5.5 boot screen with the progress bar ~10 %.
    `boo_.vhd` (1.5 GB, renamed by Daniel to stop autobooting) hung with
    nothing on screen.
  - Both carry the same layout: block 0 `'ER'`, an `Apple_Driver43`
    partition (19 blocks at 64, "Macintosh", 68000) and one HFS partition.
  - **The probe deck at the hang:**
    - PSCS: 672 sectors moved, the bus idle, the chip's IRQ latched (not
      enabled at VIA2: IER `$12`, IFR `$49`).
    - The CPU is alive in a tight loop at **`$000EA938` (RAM)**: no new
      traps, VBL running, caches on.
    - The last traps: `_InsTime`/`_RmvTime`/`_PrimeTime` repeated, then
      `_VInstall`.
    - VIA1: IER `$27` (T1 interrupt not enabled), IFR `$40` (T1's flag
      set).
  - **Next:**
    - read the hung loop's RAM with the JTAG peek (`read_probes.tcl peek`
      takes a longword address: `$EA938` is longword `3AA4E`). The peek
      holds the CPU in reset but SDRAM keeps its contents.
    - Disassemble the loop and the driver (`Apple_Driver43`, block 64 of
      the image).
    - Decide whether it is our VIA1 T1/Time Manager path, the 53C80, or
      something else.
  - **Reproduced and read (2026-10-03, same image): the cause is the
    missing SCC, not SCSI.**
    - Same state: PC `$EA934`/`$EA938`, last trap `_VInstall` (A033).
      PEXC's bus-error count is saturated at 255, but PSTA's bus BERR count
      is 0 and neither moves at the hang; the source of those vector-2
      exceptions is not yet named.
    - The peek of `$EA800-$EABFF` disassembles as the **LocalTalk (LAP)
      transmit path**:
      - it loads the low-memory globals SCCRd (`$1D8`) and SCCWr (`$1DC`);
      - it writes SCC registers (WR14 `$41`, WR10, WR5 `$62`/`$05`);
      - `$EA950` sets a busy byte `$63E(a2)`; `$EA9B0` parks the
        continuation at `$634(a2)` and returns early, so only the
        interrupt-driven completion clears `$63E`;
      - `$EA934: TST.B $63E(A2) / BNE $EA934` waits for it with no timeout.
    - The SCC is unbuilt: `se30_machine.v` ties `scc_irq_n` high, so the
      transmit completion (an SCC level-4 interrupt) never comes. The
      System is loaded from SCSI (672 sectors) and AppleTalk's driver is
      started; the floppy Systems tried so far did not start it.
    - **The peek releases the machine at its end.** A second peek reset it
      mid-reboot (Daniel saw it crash), so the low-memory dump taken then is
      not the hang's state. For a multi-region read of a hang, read every
      region in one `quartus_stp` session.
    - **Next: the SCC section** (Z85C30, from Zilog's SCC manual and Guide
      2e), before the board gates of 9.6 item 5. Daniel's call.
    - **Corrected by the software audit (10.4):** the wait is not for an
      interrupt that never comes. The code is `'ltlk' 0` ("SCC LocalTalk B
      v58.5") from the System file, loaded at `$EA340`. All 1024 dumped
      bytes match it.
      - Its carrier sense reads the line as busy: RR0 bit 4 (Sync/Hunt) is
        0 with no SCC. It then defers (`$EA9F0`) and never counts a retry,
        so `$63E` is never cleared.
      - A real 8530 on an empty port never sees a clock edge, so the DPLL
        keeps the receiver hunting: Sync/Hunt reads 1 and the line is free.
        The enquiries go out unanswered; after 32 retries per enquiry the
        address is taken and the boot goes on.
      - The part is the NMOS 8530, not the Z85C30.
  - **First host-checked gate (2026-10-03): SCSI reads and writes are
    byte-exact.**
    - Daniel booted System 6.0.8 from floppy with the image as SCSI-0. The
      disk mounted and files read.
    - MacWrite 4.5 and Speedometer 4.02, launched from the disk, both stop
      with system error 85 (`dsMBarNFnd`), every time.
    - Daniel duplicated Speedometer 4.02 (692 KB) in the Finder. On the PC,
      from a copy of the image:
      - `hfs_check` reports the volume consistent: 862 catalog records, every
        fork readable.
      - The duplicate's data fork (193,396 bytes) is identical to the
        original's.
      - The resource fork (498,911 bytes) differs only in 38 bytes inside
        `$30-$63`, the TN-74 header window the Resource Manager writes.
    - So the ID 85 is not corrupt data. The lead is System 6's
      switch-launch: the disk carries a System 7.5.5 System Folder, and
      launching an application from it would make that System the active
      one. To be tested under MultiFinder (which does not switch-launch),
      and on the MacPlus core.
    - **The MacPlus core fails the same launch** (same floppy, same image):
      no dialog, but the CPU loops in the Plus ROM's Resource Manager
      (`$413EDA-$414024`, the open-map chain walk with ResErr `$0A60`), still
      hunting a resource. Both machines fail the launch with intact files,
      so it is not ours.
- **Then:** the board gates of 9.6 item 5.

---

# Section 10 - the SCC (opened 2026-10-03)

Daniel, 2026-10-03: **"Yes. We need the SCC to proceed."** System 7.5.5
from SCSI stops in LocalTalk's transmit wait for want of the SCC's
interrupt (9.8). The SCC is built the way the other chips were: our own
8530, written to Zilog's manual, its use read from the ROM and the System,
tested by seam benches and then the board.

## 10.1 Sources, and their standing

| Source | What it gives | Standing |
|---|---|---|
| **Zilog 00-2057-03, *Z8030 Z-BUS SCC / Z8530 SCC Serial Communications Controller Technical Manual*, Sept 1986** (`C:\temp\Mac\SE30\Docs\scc\`, bitsavers mirror, 13,081,094 B, downloaded with Daniel's OK; text extract beside it) | the chip | **primary for the chip**: the SE/30's part is the NMOS 8530 (*Guide* "SCC (8530)"; IIcx BOM "IC,8530,SERIAL COMM CNTRLR") |
| Zilog UM0109 (UM010904), *SCC/ESCC User Manual* (zilog.com, 19,480,742 B, same folder) | clarifications, errata, NMOS/CMOS differences | **secondary**; its 85C30/ESCC-only features are excluded |
| *Guide* 2e, the serial I/O chapter and the SE/30 chapters | the SCC as a system: addresses, clocks, ports, LocalTalk | **primary for the system** |
| `se30.pdf` and `se30schems` (Apple sheets, BOMARC redraws); the IIcx schematic as proxy | the wiring | **primary for the wiring** |
| The ROM (97221136), and the System 7.5.5 image's AppleTalk | what the software does with the chip | **evidence of use** |
| MacLC `docs/SCC_gaps.md`, IIvi `rtl/scc.v`, IIgs `rtl/scc8530.v` | engineering leads | **leads only** |

## 10.2 The work

1. Extraction (running 2026-10-03), into `C:\temp\Mac\SE30\Docs\scc\`:
   the chip specification (`spec_z8530.md`), the SE/30 wiring
   (`se30_scc_wiring.md`) and the software audit
   (`audit_se30_scc_software.md`: the ROM, and LocalTalk's SCC
   programming including the hung wait at `$EA934`).
2. The design and its budget (34,959 ALMs at compile 29; the CD-ROM is
   still to come), for Daniel.
3. Our 8530 and its unit bench, then the seam with GLUE (the window, the
   2.2 us recovery and `C3M`, already built: 2.11.4), then the machine.
4. The board: System 7.5.5 boots from SCSI with AppleTalk active; then
   SCSI's own board gates (9.6 item 5).

## 10.3 Decisions

- **An empty port reads idle (1)** on RxD: Daniel, 2026-10-03, "Use idle
  (1) for an empty port". The SN75175 receivers are indeterminate with
  open inputs (TI: no fail-safe), so the documents leave the choice to
  us (`se30_scc_wiring.md` OPEN 5).
- **/CTS and /DCD held inactive (high)** on an empty port (Daniel,
  2026-10-03): as undefined as RxD, so steady levels, no transitions.
- **The whole 8530** (Daniel, 2026-10-03): asynchronous and SDLC, both
  directions, the DPLL, the baud-rate generators, the full interrupt
  system, two channels; the module's own synthesis measured before it
  goes into the machine (estimate 1,200-1,800 ALMs).
- **The outside world later** (Daniel, 2026-10-03): the chip's port pins
  are brought out now; the modem port (channel A) reaches the MiSTer UART
  (USER_IO) as an OSD option after the boot works.

## 10.4 The machine's logic budget (2026-10-03)

Measured at compile 29 (34,959 ALMs; the fit report's per-entity table):
CPU 15,094, 68882 6,365, the probe deck 1,334 plus its JTAG hub 327, SCSI
838 (our 53C80 67, each `scsi.v` target ~340), each floppy drive ~830
(loader ~300, track encoder ~390, drive model ~138), the SWIM 123, the MiSTer
framework ~5,000 (scaler 1,982, audio 883, OSDs 1,032, HDMI PLL 718).

| Still to build | Estimate (ALMs) |
|---|---|
| SCC, the whole 8530 | **1,073, measured (compile 30)** |
| ASC (logic; its buffers in M10K) | **447, measured (compile 31)** |
| CD-ROM target and CD audio | 600-900 |
| Modem port to the UART | < 100 |
| Floppy writing and formatting (GCR) | 800-1,200 |
| 1.4 MB MFM: the ISM's machinery and an MFM track engine | 800-1,400 |
| **Sum** | **3,800-6,100**: the machine at ~38,800-41,100 |

**The ceiling, from the Quadra 800 core** (`MacQuadra800_MiSTer` `a0b3072`,
`RESUME-timing-closure-20260925.md`): timing closed at **38,329 ALMs** with
every feature and no floppy at all. A 40,651-ALM build fitted (4,182 of
4,191 LABs) but missed the CPU by 2.4 ns. Another needed ~40,200 and failed
routing. The second integer pipeline was removed to close.

**The levers, in order:**
1. The probe deck out of release builds: -1,660.
2. One track engine shared by the two drives (the SWIM talks only to the
   selected drive; each drive keeps its own mechanism): -500 to -800,
   provided the ROM never reads straight after changing drives.
3. **The second floppy drive removed once SCSI is fully up** (Daniel,
   2026-10-03: "The LC only has one and it is not really necessary"): -830
   now, -1,300 to -1,600 once writing and 1.4 MB are built.
   **Done 2026-10-04 as a build option, for compile 37** (Daniel, 10:50:
   agreed, after the fast set, one change per compile; he recalls the
   second drive as over 1,000 ALMs - this compile measures it). Not
   deleted: `MacSE30.sv` has `` `define SE30_EXT_DRIVE `` commented out,
   which sets `EXT_DRIVE` = 0; without it the OSD's "Mount External
   Floppy" line, the external drive's loader and encoder (`generate`) and
   its hps_io reads are gone, and `se30_machine` (new parameter
   `EXT_DRIVE`, passed from the top, default 1 for the benches) generates
   no `fdhd_ext`: its RD reads 1 as an absent drive's, so the ROM's
   drive-2 probes find nothing on /ENBL2, as on an SE/30 with the DB-19
   empty. The disk-port mux keeps its four ways with two requests tied
   low (the fitter trims them); hps_io keeps VDNUM = 4 with slot 1 idle,
   so the SCSI slots stay 2 and 3; the PFL2 probe word reads 0. The
   benches are untouched: `sim/machine` passes 17 checks with the
   default (two drives) and with `EXT_DRIVE` forced to 0 (`vsim
   -g/tb_se30_machine/machine/EXT_DRIVE=0`, under `MSYS_NO_PATHCONV=1` in
   Git Bash); `sim/gcrread` keeps both drives for the full floppy test
   later (1.17.7: the overnight run was stopped for this reason).
   Found on the way: `build_only.sh --check` (Analysis & Synthesis alone)
   writes the framework's sourced assignments (`sys/sys.tcl`'s pins and
   more, ~250 lines) back into `MacSE30.qsf`, which the full flow does
   not; `git checkout MacSE30.qsf` before stamping and compiling, or the
   stamp warns "design files are dirty" and the compile's settings are
   not the committed ones. Compile 37 started 11:29 (tag `e749a396`).
   **Compile 37** (2026-10-04 11:29-12:02, tag `e749a396`, 33.7 min -
   synthesis 9, the fitter 22; archived `output_files/
   MacSE30_e749a396_noext.rbf`): **36,997 ALMs (88 %), 577 fewer than
   compile 36** - the second drive's measured cost (10.4's ~830 per
   drive counted the internal one's share of the SWIM-side logic too;
   the fitter's per-entity figures move with packing, so the total is
   the number). **Our paths meet timing at every corner**
   (`sta_corners.tcl` plus a per-clock report at slow -40C: the CPU
   clock +2.548, the SDRAM controller's clock +0.684, `sdram_clk`
   +2.409, the SDRAM outputs +2.4, the capture meeting its A/B rule at
   every corner). **The flow reports -0.087 ns at slow -40C, which is
   the framework's HDMI scaler** - four `ascal|o_vpix_inner -> o_poly_lum`
   paths on `pll_hdmi`'s clock, the same path class accepted on compiles
   18, 20 and 25 (-0.016 then) and not ours to fix; at slow 100C the
   whole design meets with +0.241. **For the board**: expect compile 36's
   machine with the "Mount External Floppy" line gone from the OSD and
   the ROM finding no second drive. Budget after this: ~1,300 ALMs to
   the ~38.3k ceiling, for the floppy writing (800-1,200) and the rest
   of 10.4's table.
   **On the board (Daniel, 12:20): runs; Speedometer 4.02 identical to
   compile 36 except Disk, 0.34 against 0.41.** Nothing in this change
   touches the SCSI path or the HPS's disk slots (slot 1 was idle before
   too, no external image being mounted), and the Disk figure has moved
   between builds that did not touch it either: compile 32 0.39, 33
   0.49, 34 0.43, 36 0.41, 37 0.34 - a spread of 0.34-0.49 across five
   builds, three of which changed nothing on the disk's path. So the
   reading is the measurement's spread, not the drive's removal, until a
   repeat says otherwise; the spread itself says the Disk rate is set by
   something that varies run to run - the HPS side's block round trip
   (Linux's file I/O on the SD card, its caching), which is where
   1.17.1's open Disk question already points. To settle it: the Disk
   test two or three times more on compile 37, quitting between runs,
   and once more on compile 36 the same way.
   **Repeat runs (Daniel, 2026-10-04 afternoon): compile 37 now gives
   Disk ~0.43; the figure fluctuates, possibly lower on the first run
   after a boot.** That settles it: 0.34 was the spread (a first run's
   reading), not the drive's removal. A slower first run fits a cache
   warming on the HPS side (Linux's page cache over the SD card image),
   which is more evidence that the Disk rate is the HPS block round trip
   (item 3 below). For comparisons between builds, quote the Disk figure
   from a second or later run.
   **Daniel: ~0.43 is still far below the real machine's 0.70-0.77, so
   the Disk gap is investigated (2026-10-04 afternoon).**
   - **What the code says.** Speedometer's Disk test writes a 1 MB file
     (1.17.5's catalog record: 2,048 blocks), and probably reads it back
     (not yet seen - the meter's read and write counts will say). Our target
     (`rtl/scsi.v`, MacPlus/LC's) asks the HPS for ONE 512-byte block per
     request (`sd_blk_cnt` tied 0 for every slot, `MacSE30.sv`) with one
     request in flight. Its 32-sector read ring hides the first block's
     wait, not the rate: a read runs at 512 bytes per round trip however
     deep the ring. Writes flush through a two-slot buffer, one block per
     round trip. The framework's `hps_io` moves up to 32 blocks (16 KB)
     per request (`sd_blk_cnt`, "blocks - 1"); no Mac core on this
     hardware uses it for a disk (the Quadra 800's only for CD-DA frames).
   - **Not known**: the round trip's length, and whether the bus is the
     test's time at all (the File Manager and the driver run on the Mac
     between commands). Multi-block requests cannot help with the part
     that is the Mac's. So measure first (Daniel agreed).
   - **The meter, compile 38** (`65f8a27`): PSCT, 440 bits of
     free-running counters (rtl/dbg_probes.sv's header): clocks; a target
     BSY; a target's hold-off (a data phase whose next byte the HPS has
     not delivered); GLUE holding the CPU at `$50006000` for DRQ;
     commands; and for HPS reads and writes the requests, the round trip
     (io_rd/io_wr rising to sd_ack falling) summed, sd_ack's high time
     summed (the block's transfer; the rest is Linux's response) and the
     longest. `quartus_stp -t scripts/read_probes.tcl scsitime` prints
     them and their differences from the previous `scsitime`. Benches:
     sim/scsi_seam 58, sim/glue 98, sim/machine 17 PASS.
     **Compiled** (tag `65f8a27f`, 33 min): 37,775 ALMs, 778 more than
     compile 37 (above the few hundred estimated: thirteen wide counters
     plus the 440-bit probe's capture and shift registers - probe-only,
     gone in a build without USE_DBG_PROBES); timing met at every corner
     (`sta_corners.tcl`: worst +0.105 ns, the capture met by A or B at
     each); archived `output_files/MacSE30_65f8a27f_psct.rbf`. The
     machine is compile 37's otherwise (no external drive).
   - **ON THE BOARD (Daniel, 2026-10-04 18:19-18:24; `scsitime` either
     side of two Disk tests, the windows a few seconds wider than the
     tests):**

     | | run 1: Disk 0.438 | run 2: Disk 0.330 |
     |---|---|---|
     | window / bus busy / commands | 63.7 s / 22.3 s / 395 | 71.3 s / 29.4 s / 268 |
     | target waiting on the HPS | 16.7 s | 24.0 s |
     | GLUE holding the CPU for DRQ | 1.09 s | 1.07 s |
     | HPS reads | 7,678 blocks, 134 us each (30 Linux + 104 moving), 1.03 s | 7,235, 139 us (34 + 104), 1.00 s |
     | **HPS writes** | **8,960 blocks, 2,213 us each (2,065 Linux + 148 moving), 19.8 s** | **8,961, 3,030 us (2,882 + 148), 27.2 s** |
     | longest write | 34.6 ms | 201.6 ms |

     **The Disk gap is the HPS's writes**: 90-95 % of the bus's time,
     ~2-3 ms of Linux per 512-byte block. The test writes 4.4 MB and reads
     3.6-3.8 MB (not the 1 MB file alone). Reads are already fast (the
     ring, and Main's own 16 KB read cache: 30 us). **The score's spread
     (0.33-0.49) is the SD card's write latency** - run 2's writes 37 %
     slower, a 200 ms stall - not a first-run cache (the reads are equal).
   - **Why 2 ms (Main_MiSTer `user_io.cpp`, master of 2026-10-01):**
     writable images are opened `O_RDWR | O_SYNC` (line 2224) and each
     write request is one synchronous `FileWriteAdv` of the request's
     whole size, `(blk_cnt + 1) x blksz` up to its 16 KB buffer (3380-
     3555): one SD card write per request. A 512-byte request pays it per
     block; a 16 KB request pays it once per 32 blocks.
   - **Daniel's decisions (2026-10-04 18:25)**: build multi-block writes;
     **full speed, no pacing to a period drive** ("today you can connect
     an SD card to a real Mac, and that is not considered non-authentic") -
     a Disk figure above the real SE/30's 0.70-0.77 is not a regression.
   - **Built (`6ca438b`, compile 39)**: `rtl/scsi.v`'s writes move to the
     32-sector ring. `wr_fill` counts the sectors the Mac has delivered,
     `wr_done` those the HPS has taken; whenever no request is in flight
     and sectors are filled and unsent, ONE request goes out for all of
     them (`io_blk_cnt` = sectors - 1 -> `sd_blk_cnt`, at most 32 = Main's
     16 KB), read over hps_io's 13-bit word address; `lba` advances by the
     request's sectors. Adaptive, no threshold: a command's first sector
     goes alone and each later request carries what the Mac wrote while
     the previous one was out (at ~2.5 ms a request and the Mac's ~1.4-2.9
     MB/s, ~7-14 sectors). The Mac stalls only on a full ring; the status
     byte waits for the last request (GOOD still means the HPS has the
     data); only filled sectors are sent, so a zero-length or rejected
     WRITE sends nothing (the old `data_in_seen` guard is now structural);
     an aborted command arms no new request. Reads unchanged. The meter
     gains the written sector count (PSCT 464 bits; `scsitime` decodes
     both widths). The file's inherited mixed line endings are kept (the
     first commit of it normalised them; amended).
   - **Benches**: `sim/scsi_seam` test 10 (97 checks, 46 s): the hps_io
     model takes `sd_blk_cnt` as Main does; 40 blocks at 1.3 ms a request
     (6 requests, the largest 8) read back byte-exact; 33 blocks from LBA 7
     at 9.6 ms (the ring fills: 1, 31, 1) read back, LBA 6 and 40
     untouched; the image checked the moment the status arrives; 1 block
     at the last LBA; reads one sector a request. Mutants (lba +1 a
     request; `sd_blk_cnt` tied 0): FAIL 2 and 6 checks. `sim/machine` 17
     PASS (its idle stub target gains the port).
   - **Compile 39** (tag `6ca438bc`, 36 min): 37,579 ALMs (compile 38
     37,775: the two-slot write logic and its edge latches gone, the ring
     counters added); archived `output_files/MacSE30_6ca438bc_mbwrite.rbf`.
     **Our paths meet at every corner** (per-clock report, the four
     corners): clk_sys setup +1.799 worst (slow 100C), clk_mem +0.372,
     the capture clocks +2.04, SDRAM pins +2.3 or more, every hold
     positive; the capture met by A or B at each corner. **The flow
     reports -0.313 ns at slow -40C (-0.065 at slow 100C): every failing
     path is the framework's HDMI scaler** (`ascal|o_h_lum_pix` ->
     `o_poly_lum` on `pll_hdmi`), the class accepted on compiles 18, 20,
     25 and 37 (-0.087 there) - larger this fit, still not ours.
   - **ON THE BOARD (Daniel, 2026-10-04 ~19:30): Speedometer 4.02 Disk
     1.133** (compile 37/38: 0.33-0.49; the real SE/30's internal drive
     0.70-0.77, Daniel's decision makes the excess fine). PBLD `6ca438bc`.
     PSCT since configuration (boot + that one Disk test, 207 s): 871
     write requests carrying 9,020 sectors (10.4 a request), round trips
     5.66 s = **627 us a sector** (compile 38: 2,213-3,030), a request 6.5
     ms of which 5.0 ms Linux (the SD write cost grows with size, but
     far slower than per request); 24,001 reads at 154 us; bus busy 16.0
     s, hold-off 2.65 s, GLUE's DRQ wait 1.75 s, 6,153 commands; the
     longest write request 18.8 ms. The integrity checks below are next.
     **Second run, `scsitime` either side (19:26:38-19:27:18): Disk
     1.115.** Window 42.4 s: bus busy 8.47 s (compile 38: 22.3 / 29.4),
     261 commands; hold-off 1.76 s (16.7 / 24.0); GLUE's DRQ wait 0.76 s;
     writes 809 requests carrying 8,961 sectors (11.1 a request), 5.70 s,
     636 us a sector (2,213 / 3,030), a request 7.0 ms = 5.4 Linux + 1.6
     moving; reads 7,228 at 207 us (102 Linux + 104 moving; compile 38
     134-139, 30 Linux) - Main drops its 16 KB read cache on every write
     request (`buffer_lba[disk] = -1`), so reads after writes miss it;
     1.50 s against 1.0. Longest write 49.4 ms, read 56.3 ms. **Two runs
     1.133 and 1.115: the spread is now small.** What is left of the bus
     time is the SD card's write (bounded by Main's O_SYNC) and the reads;
     multi-block READ requests would take most of the 102 us Linux wait
     (under a second a run) - not needed, an option.
     **Integrity (Daniel, ~19:30): the QuarkXPress folder duplicated in the
     Finder; Get Info identical to the original. QuarkXPress launched from
     the copy opened a document that was itself copied with the folder -
     loaded OK. Disk First Aid after a reboot: the disk is OK.**
     **Compile 39 (`MacSE30_6ca438bc_mbwrite.rbf`) is the current good
     bitstream; the Disk item is CLOSED** (1.115-1.133 against 0.33-0.49;
     data intact). The same `scsi.v` target is MacPlus's and MacLC's: the
     multi-block write would carry over to those cores (Daniel's call,
     once it has run a while here).

**10.4 item 4: the Math figure (opened 2026-10-04 evening, Daniel).**
Speedometer 4.02's Math reads 1.10-1.13 against the real SE/30's 0.96-0.98.
- **What is known.** The 68882's own clocks already match the manual: its
  timing bench (8.9.7, an ideal MPU) reproduces Table 8-3 in 227 of 228
  rows. The MPU's side of a coprocessor instruction is unpaced (the
  decoder leaves F-line out, 1.17.5) - and the 030 UM gives no timing for
  it at all; Table 8-3's totals were measured with a 68020 ("the MC68030
  ... always yields better values"), ~11 clocks of interface overhead in
  each. Compile 30's Speedometer had the FPU benchmarks *slower* than the
  real machine (0.78-0.92) while Math was faster (1.11): Math may be
  mostly integer code (SANE), not the 68882.
- **Daniel's question: can it ever match exactly?** No - the CPU is paced
  per instruction, not cycle-exact, and the dialog's MPU side is
  undocumented. But the undocumented part is a few clocks of 38-700, so a
  benchmark heavy in FPU work can land within a few per cent; 13 % is too
  large to come from the dialog alone.
- **A pacing correction proposed and WITHDRAWN (the same evening).** The
  uncached fetch charge (1.17.5: an uncached DBRA 10.2 clocks against the
  NCC formula's 12) was put forward as documented and 15 % fast. On
  reading UM 11.3.3 and report_time.py again: the NCC formula is the
  manual's own upper estimate ("equal to or greater than the actual" -
  averaged alignments, no overlap), the lower estimate (the tables'
  internal clocks plus the bus the loop runs) is ~10, and the core's 10.2
  sits inside the documented range at its bottom. The one hardware
  comparison agrees: the chime (ROM, caches off - exactly this path) was
  timed by Daniel as more or less identical to a real SE/30's. No real
  SE/30 TimeDBRA has been found. So there is no documented basis for it;
  not applied. (The other listed simplifications - MUL/DIV/CHK/CAS at their
  maxima, brief-format figures for full-format EAs - stand as they are.)
- **Measure first (Daniel: "build just the probe")**: PFPU, 408 bits of
  free-running counters in `rtl/dbg_probes.sv` (its header has the
  layout): clocks; the CPU's clocks in bus cycles to the 68882 and those
  cycles; command CIR writes (a general FPU instruction each) and
  condition CIR writes; the 68882 not idle and its APU running (new
  `se30_fpu` output `dbg_busy`); SANE's `_FP68K` ($A9EB) and `_Elems68K`
  ($A9EC) traps and every A-line trap; instruction fetch bus cycles (the
  I-cache's misses and uncached fetches) beside the I-cache's hits.
  `read_probes.tcl fputime` prints them and their differences, as
  `scsitime` does. Nothing else changes. The reading decides: the 68882's
  busy time a large share of the Math test -> the FPU's side; SANE calls
  and little FPU time -> integer code (the pacing); many fetch misses ->
  the cache's share.
- **ON THE BOARD (compile 40, Daniel, 2026-10-04 21:07-21:08): Speedometer
  4.02 Math 1.151.** `fputime` either side (66.7 s window): 273,898 FPU
  instructions (command CIR writes) and 10,346 conditionals, 1,429,855 CIR
  cycles; **the CPU in bus cycles to the 68882 0.27 s (0.4 %), the 68882
  busy 0.09 s (0.1 %)**; SANE `_FP68K` 30,977, `_Elems68K` 0, every A-line
  trap 1,093,348; **instruction fetches 93.7 M from the bus against 27.5 M
  I-cache hits - 77 % missed the cache**. (Since boot before the test:
  112 FPU instructions, 8 `_FP68K`.) **So Math is not the 68882**: even at
  60 clocks an FPU instruction it would be under 2 % of the test. It is
  integer code - SANE and a million Toolbox traps - running mostly from
  outside the 256-byte I-cache.
- **The withdrawn fetch correction, revisited on this evidence**: Math
  core/real 1.151 / 0.96-0.98 = 1.17-1.20, in the uncached regime; the
  core's uncached DBRA against the manual's NCC formula 12 / 10.2 = 1.18;
  CPU (cached loops) 1.00-1.04. The core charges a miss at the bottom of
  the manual's documented range; a real SE/30's Speedometer, in that
  regime, says the machine runs near the top. Against it only the chime
  by ear (~0.7 s, both; 18 % would be ~0.13 s). To check before building:
  `fputime` around Speedometer's CPU test - few misses there predicts the
  correction leaves CPU and brings Math down.
- **Speedometer 3's FP Matrix** (compile 40, 21:09-21:13; Daniel: 6.559,
  apparently the Benchmark Mix scale, Mac Classic = 1.0 - no real SE/30
  figure for it alone in hand). `fputime` (217 s, the shareware dialog
  inside it): 2,244,163 FPU instructions over 264,201 `_FP68K` calls
  (~8.5 a call: one operation and the moves around it), **the CPU in
  bus cycles to the 68882 1.99 s (0.9 %)**, the APU 0.38 s; 2,916,372
  A-line traps; **255 M fetches from the bus against 133 M I-cache hits
  (66 % missed)**. Even a floating-point benchmark is integer-bound
  through SANE. (PFPU's "not idle" leaves out the CU's own moves - it is
  the APU's and the hand-off's time only.)
- **Speedometer 4.02's CPU test alone** (compile 40, 21:16:32-21:16:58,
  28.5 s; Daniel: **0.267**, real 0.26-0.27): 1,751 FPU instructions, 188
  `_FP68K`, 439,236 A-line traps (~15,400 a second, Math ~16,400); **25.0 M
  fetches from the bus against 31.0 M hits - 44.6 % missed** (Math 77.3 %).
  The prediction ("few misses") was wrong. Estimate of the fetch
  correction at the NCC formula's level (~0.9 clock a missed fetch, the
  DBRA gap 1.8 over two fetches): Math +~9 % of its time (93.7 M misses,
  ~5.4 s of ~60), CPU +~5 % (25.0 M, ~1.4 s of ~28) - Math 1.151 -> ~1.06,
  CPU 0.267 -> ~0.254. It would close about half of Math's gap and take
  CPU slightly below the real machine: **not the whole answer; not
  applied.** Settled: not the 68882 (under 1 % in every test). Left: what
  in SANE's integer code (multi-word ADDX/ROXR, long shifts, MULU.L/
  DIVU.L - the decoder charges MUL/DIV at their maxima, which errs the
  other way) runs faster than a 68030; a per-instruction-class time
  profile (core clocks against the budget, by the decoder's row) would
  show it - another compile, Daniel's call.
- **Compile 40** (tag `f7c95109`, 33 min): 37,953 ALMs (+374 on compile
  39: PFPU's counters and its 408-bit capture); our clocks meet at every
  corner (clk_sys +1.183 worst, clk_mem +0.815, the capture clocks +2.29,
  SDRAM pins +2.3 or more, holds positive; the capture by A or B); the
  flow's -0.042 ns at slow -40C is the framework's HDMI scaler again.
  Archived `output_files/MacSE30_f7c95109_pfpu.rbf`. It carries compile
  39's multi-block writes - see the next item before using it on a
  valued image.

**10.4 item 3, reopened: Disk First Aid after a 16 MB deletion (Daniel,
2026-10-04 ~20:25, compile 39).** "System 7.5.5 80MB" reports three
"Missing file record for file thread" (1990, 338 / 2968, 367 / 3154,
401 - file ID, leaf node), the same when booted from MacPack. Daniel
copied the image (`C:\temp\Mac\Test disks\Corrupted\mac_80mb-restored.vhd`,
md5 e6764bf4..., identical to the card's) beside the backup taken before
compile 39 (`MiSTer SE30 Backup\mac_80mb-restored.vhd`, 18:39). A
read-only checker (scratch `hfs_vol.py`: the catalog's parents and
threads, every fork's extents including the overflow tree against the
bitmap, the MDB's counts):
- **Backup: 0 problems** (871 files, 139 folders, 18 file threads,
  38,950 blocks in use = the bitmap's). **Now: 3 problems, exactly the
  three orphans** - 642 files, 74 folders, 21 file threads, 33,749 blocks
  in use = the bitmap's, MDB free = bitmap free, no overlap, no missing
  parent, every folder thread right. The deletion freed 5,201 blocks and
  every one is accounted for.
- **The orphans are systematic, not random**: each is the file thread of
  an APPLICATION whose whole folder was deleted - Speedometer 4.02 (1990,
  its thread already in the backup), Microsoft Word (2968, no thread in
  the backup: made this evening, presumably by launching it - System
  7.5's Recent Applications aliases give an application a file ID) and
  the QuarkXPress copy (3154, made this evening). Their file records,
  their folders and the folders' threads were all removed; only the file
  threads stayed. A misplaced or stale sector would damage whatever its
  node held, not exactly these.
- **The same signature predates compile 39**: the MacPack backup (18:39)
  has five orphan file threads - "Dark Dungeon v1", "DD lib", "DD
  SaveData", "DD Stack2" (their folder deleted) and "Royal Game of Ur"
  (in the Trash).
- **Reading**: most likely the software (deleting a file that has a file
  ID leaves its thread), not the write path - but not proven. A web
  search found no statement either way. **The decisive test** (Daniel's
  go): a scratch copy of the clean backup on compile 38 (single-block
  writes): launch an application, quit, delete its folder, empty the
  Trash, Disk First Aid from MacPack. An orphan there clears the
  multi-block writes; then compile 39/40 the same way for symmetry.
- **DONE (Daniel, ~20:55): the same delete on a scratch copy of the clean
  backup under COMPILE 38 (single-block writes) - the same result, "many
  missing file records".** The image (`Test disks\Corrupted\mac_80mb-
  restored-backup.vhd`): 17 orphan file threads, the volume otherwise
  consistent (548 files, 78 folders, 28,584 blocks in use = the bitmap's,
  MDB free = bitmap free). Against the backup: **every deleted file with a
  thread left it behind - none of the backup's threads was removed**
  (905 EfiColor XTension Help, 1604 QuarkXPress, 1680 Newspaper, 1990
  Speedometer 4.02); eight more files gained threads during the session
  and kept them after deletion (Microsoft Word and its ReadMe twice, the
  sample documents, the MS-Word and WordPerfect filters), and so did five
  files created in it (the new copies, IDs >= 3083). **The multi-block
  writes are cleared**: compile 39 is the current good bitstream again.
- **But Inside Macintosh: Files says the File Manager removes the
  thread**: FSpDelete "both forks of the file are deleted. The file ID
  reference, if any, is removed" (Files-55/193); PBHDelete "if a file ID
  reference for the specified file exists, that file ID reference is also
  removed" (Files-236); the file ID reference is the file thread record
  (Files-282). On the core 0 of 21 were removed, compiles 38 and 39 alike.
  **So this is most likely a fault in the core, older than today** - the
  CPU running the File Manager's delete (in the IIx ROM, as patched by
  7.5.5) wrongly, e.g. the test of the file record's thread-exists flag
  (filFlags bit 1) or the thread key's B-tree delete - unless System 7.5.5
  itself departs from Inside Macintosh. MacPack's five orphans (before
  compile 39) fit the same fault. Harmless to the data (Disk First Aid
  removes orphan threads), but a fidelity bug. Next: Daniel's choice of a
  cross-check (the same delete on an emulator running 7.5.5, or on the
  MacLC core, whose CPU shares the TG68K lineage) and/or localising it
  (the ROM's delete path, a PC probe on the board).
- **The MacLC core (Daniel, 2026-10-04 ~21:40): Disk First Aid clean
  after a deletion there.** The same sequence as on our core: a copy of
  the QuarkXPress folder made, Quark launched from it, the folder
  deleted (on our core that left the copy's thread, 3146 / 3154).
  Supports a fault in our core, with two qualifications: (1) it assumes
  the launch gave the copy a thread on the LC too (Recent Applications) -
  the LC image through the checker would confirm; (2) the File Manager is largely in ROM, and the LC's ROM is
  newer than the SE/30's (the IIx/IIcx ROM, 97221136) and patched
  differently by 7.5.5 - so the LC runs a different delete path than a
  real SE/30 would. The clean proof: the same delete on a different CPU
  implementation running the IIx/IIcx/SE/30 ROM (an emulator in IIx or
  IIcx mode). Still parked behind the Math profile (Daniel).
  **Checked (the LC's image, `Test disks\Corrupted\mac_80mb-restored-
  LC.vhd`, from the same backup): 0 problems, the volume consistent;
  Speedometer 4.02 (1990) deleted with its thread - the very thread our
  core left; Disk First Aid v7.2.2 (3029) and TattleTech (3037) deleted
  with theirs; Sound (1128) and Newspaper (1680) kept, their threads
  removed and the thread-exists flags cleared (the System's own ID
  housekeeping - working there too).** So on the same starting image the
  LC removes threads as Inside Macintosh says and our core never does:
  **treated as a bug in our core** (the ROM difference the only caveat).
- Daniel then let Disk First Aid repair the boot volume: clean after the
  repair (2026-10-04 ~21:10). The damaged images stay on the PC for the
  cross-check (`Test disks\Corrupted\mac_80mb-restored.vhd`, compile 39;
  `...-backup.vhd`, compile 38).
   - **The board test (compile 39)**: FIRST on a scratch copy of the boot
     image (a write-path change): boot; copy a folder of a few MB to a
     new folder and Finder-compare it (or Get Info sizes), duplicate a
     large file; HD SC Setup's Test Disk if available; Speedometer's Disk
     test twice with `scsitime` either side; reboot and check the volume
     mounts clean (Disk First Aid). Then the usual image. (Daniel backed
     up the SD card's images before compile 39, 18:50.)
   - Also on compile 38 (Daniel, 2026-10-04 ~18:55): **Arkanoid plays
     very nicely; Prince of Persia starts and plays its music with no
     extra noise.**
   - **The board test**: Speedometer open, `scsitime` just before the
     Disk test is started and again just after it ends; twice, to see the
     first run against a later one. The window includes the seconds
     around the test, so read the absolute times and the per-block
     figures, not only the percentages.
   - **What decides what**: HPS round trip a large share of the test's
     time -> multi-block requests (reads: fetch up to 32 blocks per
     request into the ring; writes: flush several blocks per request),
     the per-block Linux wait saying how much they can save. Bus busy a
     small share -> the time is the Mac's (driver, File Manager), and the
     target is not the lever. GLUE's DRQ wait shows how much of the
     bus time the CPU actually spends held.

**END OF SESSION 2026-10-04 (evening) - READ THIS TO RESUME** (supersedes
the 12:30 block below). Branch `dev`, nothing pushed (Daniel pushes).
1. **Current good bitstream: compile 40**, `output_files/MacSE30_f7c95109_
   pfpu.rbf` (compile 39's multi-block SCSI writes + the PFPU probe; our
   clocks meet at every corner, the framework's HDMI scaler -0.042).
   Compile 39 (`..._6ca438bc_mbwrite.rbf`) is the same machine without
   PFPU.
2. **Closed today**: the Disk figure (multi-block writes: Speedometer Disk
   0.33-0.49 -> 1.115-1.133, integrity checked; Daniel: full speed, never
   paced); TattleTech's first page matches a real SE/30 on 7.5.5; MODE32
   is not built into 7.5.5 (plan 1.5 corrected).
3. **Built, NOT yet compiled: the PPRF time profile** (`3fa0bf7`) for the
   Math figure (10.4 item 4: Math 1.151 against the real 0.96-0.98; not the
   68882 - under 1 % in every test; SANE and Toolbox code missing the
   I-cache 45-77 %; the fetch correction would close only half and take
   CPU below real). Its benches (21:41): sim/system all eight PASS, the
   34 timetest windows IDENTICAL clock for clock to the 10:29 log (the
   pace unchanged); sim/machine 17 PASS; the PPRF RAM bench PASS.
   **Compiled: compile 41** (tag `e98c4ef3`, 35 min,
   `output_files/MacSE30_e98c4ef3_pprf.rbf`): 38,758 ALMs (+805 on compile
   40 - at the practical ceiling, but PPRF is probe-only), 313 RAM blocks;
   **timing met at every corner with no exception** (clk_sys +2.137 worst,
   clk_mem +0.536, the framework's HDMI scaler +0.140; the capture by A or
   B). **Next: on the board, the profile around Math. (Was: compile it (stamp, build, sta_corners, archive),
   then on the board `profile start` before Speedometer's Math test and
   `profile stop` + `profile read` after; the rows with the biggest share
   and their clocks against budget say where Math's time is too short.)**
4. **Open bug, parked by Daniel behind the Math profile: deleting a file
   never removes its file thread** (Disk First Aid "Missing file record
   for file thread"; 0 of 21 removed on compiles 38 and 39, so not the
   write path; the MacLC core, from the same image, removes them as Inside
   Macintosh says). Treated as a bug in our core - likely the CPU running
   the IIx ROM's File Manager delete wrongly. The images are in `C:\temp\
   Mac\Test disks\Corrupted` (`mac_80mb-restored.vhd` compile 39,
   `-backup.vhd` compile 38, `-LC.vhd` the LC; the clean backup in
   `MiSTer SE30 Backup`). The checkers are in `tools/hfs/` (read-only):
   `hfs_vol.py image` (the whole volume's consistency), `hfs_threads.py
   image [--dump ID...]` (orphan file threads), `cmp_threads.py before
   after` (each orphan against the before image).
5. Then: the FUTURE BOARD TESTS list (below), floppy writing.

**FUTURE BOARD TESTS (the list, opened 2026-10-04 by Daniel; add to it,
strike what is done).** Each on a scratch copy of the image unless noted.
1. **32-bit mode with MODE32** (Daniel, 2026-10-04): install MODE32 with
   its own installer (copying the extension does not work - 68kMLA,
   plan 1.5 addendum; **the installer is on Daniel's MacPack disk**), switch 32-Bit Addressing on in the Memory control
   panel, restart. Exercises the ROM's and MODE32's 32-bit translation
   tables and the core's full 32-bit decode, paths 24-bit mode never
   touches; a prerequisite in practice for the 128 MB option. Check:
   boots, TattleTech reads "Booted in 32-Bit mode = Yes", Speedometer and
   a few applications run, back to 24-bit and restart cleanly. With 8 MB
   it brings no other benefit (Daniel asked; answered 2026-10-04).
2. **The 128 MB clean-ROM option** (when built): a IIsi/IIfx ROM file,
   the System edited per "Gamba's page"; PRAM reset first; watch for the
   68kMLA poster's Sad Mac and unreadable drive after a Memory control
   panel change (plan 1.5 addendum).
3. **The floppy, as a whole** (Daniel, 2026-10-04 morning: "tested
   thoroughly later, as a whole"): reading on both drives, and writing
   and formatting once built (10.4) - the full `sim/gcrread` gate with
   `EXT_DRIVE` = 1 is its bench side.
4. **HD SC Setup's Test Disk** on a SCSI image, if the tool is to hand
   (compile 39's integrity checks were the copy, the launch from the copy
   and Disk First Aid - all clean).
5. **The orphan file threads - PARKED by Daniel 2026-10-04, after Math**
   (10.4 item 4's end): the same delete under System 7.5.5 on an
   independent machine (an emulator such as Basilisk II, or the MacLC
   core) - leftovers there = 7.5.5's own behaviour; clean there = our
   core's fault, then localise it (the ROM's delete path, a PC probe).

**END OF SESSION 2026-10-04 (12:30) - READ THIS TO RESUME.** Branch `dev`
at the commit after this one, tree clean, 65 commits since `903df2c`
unpushed (Daniel pushes).
1. **The current good bitstream is compile 37**, `output_files/
   MacSE30_e749a396_noext.rbf`: the fast set (1.17.8), the write pending
   buffer (1.17.7), no external drive (10.4 item 3). 36,997 ALMs; our
   paths met at every corner; the framework's HDMI scaler -0.087 at slow
   -40C (precedent). On the board it reads as compile 36 on Speedometer
   4.02 but Disk (0.34 against 0.41) - the measurement's spread, SETTLED
   by repeat runs (~0.43, above). Compile 36 (`..._36462531_fastset
   .rbf`) is the fallback with the drive in.
2. **Closed today**: the ATC path (1.17.7's decision -> 1.17.8, +4.149 ns
   through the fast set, timing met by design); compile 34 proven on the
   board; the Graphics figure (0.16 = Low End Mac's real SE/30, 1.17.5;
   the buffer's bench gain is below what Speedometer resolves); the
   overnight floppy run stopped by Daniel (clean as far as it got).
3. **Open, in order of Daniel's interest**:
   - **Disk** (Speedometer 0.34-0.49 against the real machine's 0.70-0.77):
     the SCSI loops already run at the 68030's speed (1.17.1), so the
     lead is the HPS block round trip behind the 53C80 and whether the
     target fetches a multi-block read one block at a time; measure
     first (a probe counting clocks from command to first and last DRQ,
     or the SCSI seam bench with the HPS latency modelled), then
     read-ahead in the target if that is it. 1.17.5's "the disk on its
     own track".
   - **Math 13 % high** (1.10-1.13 against 0.96-0.98): the 68882's own
     execution time is not held to its manual's figures; the pace covers
     the 030 only. Build to the MC68881/MC68882 UM's timing tables, with
     the coprocessor dialog's timing unchanged (sim/cpfpu is the gate).
   - The small pacing corrections of 1.17.5 (TimeDBRA ~15 % high; the
     taken-branch heads; MUL/DIV maxima).
   - Floppy writing and formatting (10.4: 800-1,200 ALMs; ~1,300 free).
   - The full floppy test, as a whole, later (sim/gcrread with both
     drives, `EXT_DRIVE` = 1 in the benches).
   - Options when the base is done: the colour card, the 128 MB clean
     ROM, an OSD "unpaced" switch (`pace_en`).
4. **Housekeeping**: the `wpb` worktree at `C:\Git\MacSE30_wpb` (branch
   `wpb` = dev at 243581e, scratch logs only) is still to be removed -
   `git worktree remove --force C:/Git/MacSE30_wpb && git branch -d wpb`;
   the session's scratch outputs in the tree root (`compile36.out`,
   `compile37.out`, `check37.out`, `sta_*36.out`, `sta_*37.out`) and in
   `sim/*/fast_*.out`, `sim/*/ext1_run.out`, `sim/machine/run_noext.log`
   are untracked and can go.
4. DC42 support: -150 to -250.

Options (the colour card, the 128 MB clean ROM) are decided when the base
machine's real numbers are in. Each section's measured cost replaces its
estimate here.

## 10.5 The design (2026-10-03)

The documents are the three extractions in `C:\temp\Mac\SE30\Docs\scc\`:
- `spec_z8530.md`, the chip, cited to the 1986 manual (TM86) and UM0109;
- `se30_scc_wiring.md`, the board, from Apple's sheet 7 (UG12 "8530");
- `audit_se30_scc_software.md`, the ROM and `'ltlk' 0`.

Their open items are settled below, by document where one speaks and by
the software's use where none does. Engineering choices are marked as
such.

### 10.5.1 The board (sheet 7)

| 8530 | SE/30 |
|---|---|
| D7-D0 | D31-D24, `DSACK0*` (8-bit port) |
| A/B, D/C | **A1** (1 = channel A), **A2** (1 = data): B control +0, A control +2, B data +4, A data +6, repeating every 8 bytes through `$50004000-$50005FFF`. SCCRd = SCCWr = `$50F04000` (ROM `$40800780`) |
| /CE, /RD, /WR | GLUE `SCCENN`, `SCCRDN`, `SCCWRN` |
| /INT | GLUE `SCCIRQN`, **level 4**, autovector `$1C` (*Guide* Table 3-5; its ch. 10 "level 2" is the 68000 machines') |
| /INTACK, IEI | tied high (PU): **no acknowledge ever**, so no IUS is ever set |
| IEO, /SYNCA, /SYNCB | not connected |
| PCLK, /RTxCB | GLUE `C3M`, 3.672 MHz |
| /RTxCA | `SYNC3M`: C3M while VIA1 PA3 `vSync` = 0; GPiA inverted (a 75175 enabled by vSync) while 1 |
| /CTS and /TRxC (each channel, tied) | HSKi, uninverted |
| /DCD | GPi, inverted |
| RxD | RxD+/- through a 75175 |
| TxD | a 26LS30 enabled only while /RTS is low |
| /DTR | HSKo, inverted |
| /W//REQA, /W//REQB | wired together to VIA1 PA7 `vSCCWrReq` (nothing else: Wait has no bus effect) |
| reset | **no pin**: only the WR9 commands (the ROM uses channel resets) |

**The plan's own errors, corrected here:** SYNC is VIA1 PA3's output and
GLUE's input, not a GLUE output (2.3's pin list); SCCWREQ\* has no
pull-up on sheets 4, 7 or 8 (4.5 and 4.7 say "pulled up"): with both channels
disabled (the reset state, open-drain Wait) the core reads 1, as the
wired-AND of two floating outputs (engineering).

**The empty port** (10.3): RxD = 1. The 75175's output with open inputs is
indeterminate (TI), so the handshake inputs are also a choice: **/CTS and
/DCD held high** (HSKi high, GPi low), steady, so they make no
transitions and no Ext/Status interrupts.

### 10.5.2 The modules

- **`rtl/se30_scc.v`**, the chip:
  - the bus side: the pointer (one for both channels), WR2 and WR9
    (shared), the resets;
  - the interrupt system: six IPs in priority Rx A > Tx A > Ext A > Rx B >
    Tx B > Ext B, MIE, RR2A/RR2B/RR3A, /INT;
  - two channel instances;
  - the board's input mux (RTxCA from vSync), the wired W/REQ.
- **`rtl/se30_scc_chan.v`**, one channel: its registers; RR0, RR1, RR10;
  the BRG, the DPLL, the transmitter, the receiver, the Ext/Status latches,
  W/REQ and DTR/REQ.
- **Clocks.** Everything runs on `clk` with enables. PCLK is `c16_en &&
  c3m_en` (15 in every 64 C16M clocks). The serial clocks (RTxC, TRxC,
  the BRG output, the DPLL outputs) are levels inside the channel, and
  each consumer acts on the edge the manual names (TM86 Fig 6-1).
  - RTxC = C3M has a rising edge at each PCLK tick and a falling edge two
    C16M clocks later (engineering: the averaged clock's other half).
  - External clocks (TRxC from HSKi, RTxCA from GPi) are sampled at PCLK.
    The NMOS limit for an external clock is PCLK/4, so nothing is lost.
- **Bus cycle.** GLUE's strobe (`dev_strobe`, with `scc_sel`) is the
  coincidence of /CE with /RD or /WR. On it the chip:
  - latches A2, A1, R/W and the data;
  - does the access's side effects once: a FIFO pop, the pointer's return
    to 0, a command;
  - registers the read byte, which GLUE takes two clocks later.

  The 4-PCLK recovery (6 in TM86 ch. 8, O-1) and the reset stretch are not
  modelled: GLUE's 2.2 us hold-off (about 8 PCLKs) always covers them.

### 10.5.3 The open items, settled

| Spec item | Settled as | Basis |
|---|---|---|
| O-2 RR0 CTS/DCD/Sync polarity | **bit = NOT pin** (1 when the pin is low) | UM p.176: "A High on the /SYNC pin holds the Sync/Hunt bit in the reset condition", and the CTS and DCD bits are said to work the same way |
| O-3, O-23 TBE around the CRC | TBE = 0 from the CRC's load until the flag after it is loaded, **then 1**, with TxIP | **use**: `'ltlk' 0` polls TBE after EOM with no timeout (`$EADFA`) and worked on real 8530s; UM p.50 agrees; TM86 4.2.2's "not set" is read as "not set early" |
| O-9 DPLL 010 (Reset Missing Clock) | clears the RR10 latches and puts the DPLL **in search, still enabled** | **use**: LocalTalk sends `WR14=$41` before and after every frame and never re-issues Enter Search, yet it receives |
| O-4 reset values | TM86 Fig 3-8 (RR0 D7, RR10 D6 = 0) | TM86 governs the NMOS part |
| O-5 sync-character inhibit in async | **strips** characters equal to WR6 | the NMOS Q&A (UM p.380) |
| O-6 WR11 after hardware reset | Rx clock = /RTxC | TM86 Fig 3-8 and UM |
| O-10 IP update | every second PCLK, **frozen while the pointer is 2 or 3** | TM86 3.2.3 |
| O-12 RR2B | encodes the IPs whatever MIE is (IPs set with MIE = 0) | TM86 4.2 |
| O-13 overrun | a 3-byte FIFO plus the shift register; a character finished while both are full replaces the shift register's and is flagged | UM-QA "the fifth character ... causes an overrun"; the slot is engineering |
| O-14 Error Reset on a locked, unread character | pops it ("the data is lost") | TM86 7.1.1; **use**: the LAP flushes the FIFO with reads and Error Resets |
| O-15 Reset EOM with the transmitter disabled | literal: the latch stays 1 and the Ext/Status interrupt fires | TM86 7.1.1 |
| O-16 the CRCs | CRC-CCITT x^16+x^12+x^5+1 and CRC-16 x^16+x^15+x^2+1, LSB first, inverted on transmit in SDLC, residue `$1D0F` | the CCITT and IBM standards (outside the manuals); the residue is TM86's |
| O-17 async start bit | a falling edge, confirmed low at mid-cell (count 8 of 16, 16 of 32, 32 of 64) or abandoned as a false start; data sampled mid-cell; x1 per UM p.84 | engineering, around UM-QA's "samples on count 8" |
| O-22 abort on underrun | eight 1s, then a flag | as Send Abort (TM86 5.3.2) |
| O-24 one-byte frames | not replicated | a user's observation, not a specification |
| O-25 NV/VIS at power-on | 0 | engineering |
| O-27 All Sent | async: 1 whenever the transmitter is completely empty; sync/SDLC: always 1 | TM86 7.2.2 |
| O-18 latencies | the Rx 3-bit delay is built (it is why the last two CRC bits never reach the FIFO); the buffer-to-shift transfer at the character boundary | TM86 2.2.2, UM-QA |

The 85C30/ESCC-only features (WR7', the status FIFO, software INTACK, the
deeper FIFOs, RR0 latched during a read) are left out.

### 10.5.4 The tests

1. **`sim/scc`, the chip** (Icarus):
   - every register's read and write, the images (RR4-7, 9, 11, 14), the
     reset tables, the pointer;
   - the interrupt system: priority, RR2B's status, MIE, the IP freeze,
     the first-character Tx rule, the Ext/Status latches (the double reset);
   - the transmitter bit-exact on TxD, in async and SDLC, with each
     encoding, CRC and zero insertion, idle, abort and underrun;
   - the receiver from the transmitter through local loopback (async, and
     SDLC with address search, CRC check and EOF);
   - the DPLL from an FM0 stream fed to RxD;
   - **the ROM's init and `'ltlk' 0`'s enquiry replayed register by
     register** (10.5.1's empty port): every poll ends, at the real bit
     rate.
2. **The seam with GLUE:** the window, A1/A2, the 2.2 us hold-off, a word
   access hitting one register twice, the read capture.
3. **`sim/system`:** a program running the ROM's SCC init and an enquiry
   on the real CPU (a few seconds).
4. **The board:** System 7.5.5 boots from SCSI with AppleTalk active.
   Then SCSI's gates (9.6 item 5).

## 10.6 As built (2026-10-03)

- **`rtl/se30_scc_chan.v`**, one channel, and **`rtl/se30_scc.v`**, the
  chip and the board, as 10.5. **Engineering readings** beyond 10.5.3:
  - the transmitter's 5-bit zero-inserter delay is not modelled (it only
    delays TxD);
  - asynchronous data goes through the encoder as NRZ (non-NRZ is legal
    only at x1);
  - the SDLC receiver holds data bits in an eight-bit queue: the CRC
    checker takes a bit six bits late, the assembler eight. At a flag the
    queue is dropped, which loses exactly the last two CRC bits, as UM-QA
    reports; the residue code is the assembler's count bit-reversed, which
    reproduces Tables 7-9/7-10;
  - the closing flag always follows the CRC (or an underrun's abort), even
    with data waiting or mark idle selected.
- **In the machine:** `/INT` to GLUE (level 4); /W//REQ A and B wired to
  VIA1 PA7; vSync from VIA1 PA3; GLUE's strobe with `SCCEN*`; A1/A2. The
  hardware reset is the core's power-on, never `RESET*` (the 8530 has no
  reset pin). The ports are `scc_port_in/out`; the top holds them empty.
- **Probe PSCC** (32 bits): accesses, the pointer, /INT, MIE, the six
  visible IPs and RR0B. `read_probes.tcl` decodes it.
- **Benches:**
  - `sim/scc`: **148 checks** (Icarus, 4 s). The register file and its
    images; the interrupt system; asynchronous transmit on TxD and receive
    through local loopback (FIFO, overrun, parity, the receive modes).
    SDLC/FM0 at 229.5 kbit/s on the wire, decoded by the bench's own
    decoder: flags, zero insertion, and the FCS of "123456789" = `$906E`,
    CRC-16/X.25's published check value. SDLC receive with address search,
    EOF, CRC and residue, and the two lost CRC bits. The DPLL recovering a
    bench-made FM0 stream; two missing clocks returning it to search.
    External/Status latching, re-interrupt and the IP freeze. **The SE/30's
    own sequence:** the ROM's init, `'ltlk' 0`'s init (which leaves one
    External/Status interrupt, from Sync/Hunt changing source with the
    mode, handled as `$EABB4` does) and a whole lapENQ: the line free, EOM
    and TBE arriving 135 us after the last byte, the frame correct on the
    wire, no interrupt afterwards.
  - `sim/scc_seam`: **13 checks**, GLUE and the chip: the window, A1/A2,
    the shared pointer, the 8-byte repeat, a word write as two byte cycles
    to one register, the 2.2 us hold-off (35 clocks), one pop per read,
    /INT at level 4.
  - `sim/machine`: PASS with the SCC in (ModelSim, 78 s).
  - **10.5.4 item 3 (a `sim/system` program) is not run:** under the
    standing test method (benches, then the board) a system sim localises a
    failure; the seam bench already drives 68030-shaped byte cycles
    through GLUE. It is the tool if the board shows a fault.
- **Compile 30** (Daniel's go-ahead, 2026-10-03: "You can compile if you
  reach that stage"): tag `24a1c9a2`, 34 min 33 s,
  `output_files/MacSE30_24a1c9a2_scc1.rbf` (md5
  `d1de71f009225d21e76a1c7b73525082`).
  - **36,022 ALMs** (86 %), 327 RAM blocks (unchanged), 34,652 registers.
    **The SCC measured: 1,073 ALMs** (channel A 503, B 502), no block RAM;
    the PSCC probe 29.
  - **Timing met at every corner** (`sta_corners.tcl`): worst +0.076 ns,
    register to register, slow -40C; the capture has A or B met at every
    corner. Compile 29's -0.109 ns SDRAM `dq_out` path is met this time by
    placement, not by a fix: its options stay with Daniel (drop the raw
    experiment port `S_RAW`, two of the mux's six sources; or choose the
    outgoing word a clock earlier).
- **On the board (2026-10-03): System 7.5.5 boots from SCSI to the
  desktop** (`mac_80mb-restored.vhd` as SCSI-0; Daniel). The first attempt
  "hung at the same place" because the card still had compile 29 (PBLD
  `903df2c5`, no PSCC); with compile 30 (PBLD `24a1c9a2`) it boots.
  - PSCC at the desktop: 2,189+ SCC accesses, MIE = 1 (LocalTalk's
    driver running), no IP pending, /INT inactive; RR0B `$D4`:
    Sync/Hunt 1 (the line free), TBE 1, EOM 1, and Break/Abort 1 - the
    abort the receiver saw while it ran on RTxC before WR11 moved it to
    the DPLL (as the chip bench's init replay showed); no 0 ever arrives
    to end it, as on a real chip with an idle port.
  - PSCS: 823+ sectors moved.
- **Speedometer 4.02 Performance Test** (System 7.5.5 from SCSI, Daniel,
  `C:\temp\Mac\Screenshots\20261003_143202-screen.png`; Quadra 605 =
  1.0): CPU 0.322, Graphics 0.159, Disk 0.379, Math 1.054, PR 0.267. The
  first Disk figure (the whole SCSI path: blind transfers through GLUE, our
  53C80, the target on the SD image). No real-SE/30 4.02 figures are in
  hand to compare; the 3.x figures of 1.16.3 are another scale.
- **Speedometer 4.02's own SE/30 record, against the core** (Daniel,
  `C:\temp\Mac\Screenshots\20261003_155220-screen.png`, Comparison -
  Machine Records: the built-in "Mac SE/30" against This Machine, System
  7.5.5 from SCSI; relayed by a side session, read off the screenshot
  here). The first same-version reference; Quadra 605 = 1.0; two decimals,
  so the small FPU rows carry +-5-7%. A different run from the entry
  above (Disk 0.48 here, 0.379 there).

  | Test | Real SE/30 | Core | Core/real |
  |---|---|---|---|
  | CPU | 0.27 | 0.32 | 1.19 |
  | Graphics | 0.23 | 0.16 | **0.70** |
  | Disk | 0.57 | 0.48 | **0.84** |
  | Math | 0.97 | 1.08 | 1.11 |
  | PR | 0.31 | 0.27 | 0.87 |
  | KWhet / Dhry / Towers | 0.21 / 0.22 / 0.24 | 0.23 / 0.20 / 0.20 | 1.10 / 0.91 / 0.83 |
  | Quicksort / Bubble / Queens | 0.25 / 0.26 / 0.24 | 0.32 / 0.33 / 0.27 | 1.28 / 1.27 / 1.13 |
  | Puzzle / Permute / Int. Matrix / Sieve | 0.24 / 0.24 / 0.23 / 0.28 | 0.31 / 0.22 / 0.33 / 0.28 | 1.29 / 0.92 / 1.43 / 1.00 |
  | Bench. Ave. | 0.24 | 0.27 | 1.13 |
  | FPU FFT / KWhet / Matrix / Ave. | 0.09 / 0.19 / 0.10 / 0.12 | 0.07 / 0.17 / 0.09 / 0.11 | 0.78 / 0.89 / 0.90 / 0.92 |

  Readings (to be checked, not settled):
  - **Graphics 0.70** is further from the real machine than the 3.x
    comparison suggested (0.78, then 0.85 after compile 28's GLUE fix):
    1.16.3's video-RAM cycle question stays open. **The run was at 1 bit**
    (Daniel, 2026-10-03), as the SE/30's built-in screen always is - so
    the gap is the core's timing, not the depth.
  - **Disk 0.84** from an SD image: the SCSI path (blind transfers through
    GLUE, our 53C80, the target's sector fetches) is slower than the real
    disk; a lead for Section 9's tuning.
  - CPU and integer above the real machine: the kernel's own timing
    (1.16.1, DBRA 3 clocks against the 030's 6; Daniel kept it).
  - The FPU at about 0.9: within rounding at these magnitudes; low
    priority.
- **A crash at the desktop (2026-10-03, compile 30), idle, after the
  Speedometer run, while Daniel took a MiSTer screenshot.** Garbage on the
  screen in repeating patterns, coloured (our video is R = G = B, so the
  colour is outside the Mac - most likely a MiSTer filter; asked).
  - Probes: PBLD `24a1c9a2`; illegal, address and bus-error counts
    saturated, the last eight vectors 4 (illegal); 22,679 F-lines on
    `$FEA1` at `$01784EFA`; the last 16 traps `_DTInstall` (A08F);
    caches off (CDIS\* asserted), both VIAs' IER `$52`, RAMSIZ 11, SCC:
    /INT on, an External/Status IP on channel A, RR0B Sync/Hunt 0 - all
    read as damage, not cause.
  - **The peek** (`read_probes.tcl peeks`, new: several regions in one
    session; 524,800 longwords in 33 min - the estimate of 15 was wrong):
    RAM is overwritten throughout by one exception frame, `2404 002C001C
    0010` (SR `$2404`: supervisor, **interrupt mask 4**; format 0, vector
    4, illegal), and low memory by a 28-byte record; the crashed code and
    the F-line site hold frames too. **An illegal-instruction exception
    whose own vector was already garbage recursed, and the stack swept the
    whole 24-bit space**, video RAM included (the screen's pattern). The
    first event happened at **interrupt level 4, the SCC's**, which with
    the `_DTInstall` run points at LocalTalk's External/Status path; the
    evidence itself is overwritten.
  - LC records with the same fingerprint (`MacLC_MiSTer` memory):
    `restart-after-speedometer-hang` (a heap header overwritten after a
    Speedometer 4.02 run, SCSI pseudo-DMA suspected; open there),
    `quark-hang-80mb-image-forensics` (F-line = fetching non-code; the
    fit-dependent SDRAM capture), `tg68-comb-loop-plan` (a kernel loop; ours
    is the carry item of 3.8, 4-8 nodes at `exec`, in every compile).
  - ~~Next: an A/B with AppleTalk inactive~~ - **superseded: the cause is
    the ASC stub** (below).
  - **The second crash names it (2026-10-03).** The peek's release
    restarted the machine; it stopped at the "not shut down properly"
    dialog - which beeps - with the mouse frozen. Probes: the CPU halted
    (a double fault, vectors 2 then 3, fetching `$50FFF0E4`); the trap
    ring again 16 x `_DTInstall`, new ones (A-line count +24,655);
    **level-2 acknowledges 57,609 against 24,709 VBLs** (a normal boot
    runs about half the VBL rate); **VIA2 IER `$12` with CB1 (SNDINT\*)
    enabled and IFR `$5B` with CB1 pending**; the SCC idle (no IP, the
    line free).
  - **Cause: the stub's `SNDINT*` fires on every sample tick in FIFO mode,
    22,254 a second** (7.3), where the chip interrupts "when the sound
    buffers are half empty and when they are completely empty" (*Guide*
    ch. 3, p. 95): with 512-byte halves at 22 kHz, about 43 a second. The
    Sound Manager's handler (refill, `_DTInstall`) cannot keep up; the
    deferred tasks pile up and the stack runs away - the frames of the
    first crash, whose first event was at an elevated mask. The SCC only
    made it visible: System 7.5.5 now gets far enough to make a sound.
  - **Daniel, 2026-10-03: "I suggest we go on and implement the ASC. We
    will need it anyway ... I don't see much point investing time in a
    better stub."** Section 11.
  - **Confirmed on the board (Daniel, 2026-10-03):** with the speaker
    volume set to 0 (System 6 floppy's Control Panel, kept in PRAM across a
    Mac restart), System 7.5.5 boots from SCSI and stays up - the Sound
    Manager flashes the menu bar instead of feeding the ASC, so the stub's
    storm never starts. The volume-0 setting is the workaround until the
    ASC is built.
- **Next:** SCSI's board gates (9.6 item 5) - System 6 and 7 from SCSI
  (7 done), ID 1, `hfs_check` and `hfs_fork_diff` after a Finder copy, a
  soak, Speedometer's disk test - after the ASC (a beep crashes the
  machine until then).

---

# Section 11 - the ASC (opened 2026-10-03)

Daniel, 2026-10-03: implement the Apple Sound Chip now; no better stub
(10.6: the stub's interrupt storm crashes System 7.5.5 at its first
beep). It replaces Section 7's stub. The method is the SCC's: documents
first, the chip's use read from the ROM and the System, our own chip
written to the documents, seam benches, then the board.

## 11.1 Sources (to be gathered)

Section 7.2 found no Apple register document (2026-09-28: bitsavers
`/pdf/apple/mac/`, `ers/`, one web search). This time the search is
wider (developer notes, ERS documents, technotes, period magazines,
archived Apple FTP and developer CDs), and the chip's use is read from:
- the SE/30 ROM's `.Sound` driver (`$4082F02A`-`$4082F46C`, 7.1);
- System 7.5.5's Sound Manager and its ASC synthesizer resources (from
  the image's System file, as `'ltlk'` was read for the SCC);
- sheet 7 ("Serial Interface & Sound Interface"): the ASC's pins, the Sony
  sound chips, `SNDINT*` to VIA2 CB1, its clocks.

Emulators and other cores (MAME's `asc.cpp`, MacLC's `rtl/asc.sv`, the
Quadra's `easc.sv`) are leads only.

**Found (2026-10-03, searched directly):**

| Source | What it gives | Standing |
|---|---|---|
| Apple, *Macintosh Hardware Overview*, Feb 1991 ("Registered Confidential"; bitsavers `functionalTechnologies/`, 4,245,384 B, `C:\temp\Mac\SE30\Docs\asc\`, downloaded with Daniel's OK) | the ASC ("Foley Sound Chip"): 1 KB FIFOs, one per channel; the four-voice wavetable mode; "the hardware and software interface to the ASC is described in its spec (Apple part number 344S0053 for the original version and 344S0063 for the cost reduced version)"; the Sony chip's spec 343-0045-01 / Sony CX1063AP | **primary**, but no register map |
| *Arioso Macintosh I/O Systems Architecture* 1.0, Jan 1992 (same folder, 10,540,056 B) | nothing on the ASC (an I/O software architecture) | not relevant |
| **Doug Brown's ASCTester** (github.com/dougg3/ASCTester, `tests.c`; the README's per-machine results) and its 68kmla thread "Would someone with a Quadra 700/900/950 be willing to test a program for me?" (Jan 2026) | **measurements on real machines, including an SE/30 (Callan's) and a IIci (Doug's), ASC version `$00`**. Doug's conclusion: "Original ASC interrupts on FIFO full and FIFO half empty, no repeats. Clears register $804 on read." With the FIFO B write back-to-back after FIFO A's, "your SE/30 responds just like my IIci". IIci: `$804` idle `$00`; no IRQ while idle; about 1,119 samples written before "full" in stereo (1 KB plus what drains meanwhile) | **measured hardware behaviour** - third-party tests on real chips: above any emulator, below an Apple document; the tests' code is published, so the measurements can be read exactly |
| The same thread, Arbee (R. Belmont, MAME's ASC author): "There are ERSes for ASC and EASC but they're much less helpful than you'd think, which is why ASCTester is necessary" | the Apple ERS exists; not found publicly (bitsavers, archive.org, web searches) | to keep looking for |
| MAME `src/devices/sound/asc.cpp` (header: a full register map for the original ASC, $800-$82F; "Big thanks to Doug Brown for the ASCTester utility"; TODO: "some weirdness with the FIFO full IRQ on the original ASC") | the register map, built on ASCTester's results | **lead** |
| MacLC `rtl/asc.sv` (MAME's `asc_v8_device`), Quadra `rtl/easc.sv`, the MESS EASC page, QEMU's 2023 ASC patches | other variants | **leads**; no core records an Apple document |

The specification: `C:\temp\Mac\SE30\Docs\asc\spec_asc.md`, every line
tagged HW (ASCTester), G, HO, S7, SW (the ROM's and System 7.5.5's use,
`audit_se30_asc_software.md`) or M (MAME, lead).

## 11.2 What the software settles (SW)

- **System 7.5.5** plays through `'sdev' 'asc '`: `$801 = 1`, `$802 = 2`
  (stereo), `$807 = 0` at start-up, `$806 = vol<<5`; it never writes `$803`
  and never leaves FIFO mode. Its CB1 handler (`lpch 28`, CB1 on the
  falling edge) reads `$804` once and refills only on bit 2; the refill
  writes 512 frames blind, then polls bit 3 before each further frame
  until it reads 1. A frame is one misaligned word write to `$3FF` (left
  to FIFO A, right to FIFO B). After a sound, CB1 stays enabled and FIFO
  mode stays on - so a chip that interrupts while idle storms for ever (the
  crash of 10.6).
- **The ROM**: the chime is wavetable mode (four voices, tables at n x
  `$200`, increments at `$814+8n`; `$800 = $00` selects its path); the
  `.Sound` driver feeds FIFO A 370 bytes a VBL and never reads `$804`.
- **The CPU's half is already proven:** `sim/kernel_bus` PORT=8 (520
  checks, rerun 2026-10-03) holds the kernel to UM 7.2 for every operand
  at every offset on an 8-bit port, the odd word included: `move.w x,$3FF`
  is a byte cycle at `$3FF`, then one at `$400`.

## 11.3 The design (2026-10-03)

**`rtl/se30_asc.v`**, replacing `se30_asc_stub.v` in the same place
(GLUE's `asc_sel`, the 5/4-clock cycle, `RESET*`, VIA2 CB1):

- **The buffer:** 2 KB in one M10K pair (2048 x 8, dual port). Port A is
  the CPU's: in FIFO mode a write appends at the FIFO's own write pointer
  (A for `$000-$3FF`, B for `$400-$7FF`); in modes 0 and 2 it writes the
  addressed byte; a read returns the addressed byte. Port B is the
  playback engine's.
- **The FIFOs:** per channel a 10-bit read and write pointer and an 11-bit
  count (0-1,024). A write to a full FIFO is dropped and sets the full bit
  again (engineering, after Doug Brown's repeated "full" interrupts). A
  change of `$801` or `$803` bit 7 empties both; the clear also sets bits 1
  and 3 (M; it explains snth 2053's discarded read).
- **$804:** four latched bits - 0 A half empty, 1 A full, 2 B half empty,
  3 B full. Set: full when a write leaves the count at 1,023 or more;
  half empty when playback takes the count from 511 to 510 (M's point);
  cleared by a write that takes the count to 512 or more (M). A read
  returns them and clears all four; a write ORs bits in. **`SNDINT*` is
  low while any bit is set**: one falling edge per event, none at idle.
- **Playback:** a sample tick from C16M - every 704 C16M for `$807 = 0`
  (22,254.5 Hz), a fractional divider for 3 (44.1 kHz) and 2 (22,050).
  At each tick a small sequencer, sharing one read port, takes:
  - FIFO mode: a byte from A (and from B in stereo; mono plays A on both);
    an empty FIFO holds its last sample (engineering);
  - wavetable mode: for each voice, phase += increment (24 bits; one adder
    used four times in turn), byte = voice n's table at phase[23:15]; mono
    sums all four, stereo {0,1} left and {2,3} right, unsigned and
    unscaled, saturated at `$FF` (engineering: SW shows the software keeps
    the sum in range).
- **Registers:** `$800` reads `$00`; `$801-$80F` read back what was written
  (`$801` bits 1-0; `$802` bit 7 reads 0); `$810-$82F` the voices' phases
  (live) and increments; `$830-$837` stored (SW writes them; G describes
  no per-voice level - OPEN).
- **Out:** each channel's 8-bit offset-binary sample, minus `$80`, times
  the volume (`$806` bits 7:5, linearly 0-7 of 7: no Sony datasheet), as
  signed 16-bit to the MiSTer's `AUDIO_L/R` (`AUDIO_S = 1`). The Sony
  chips' filter (G: about 7.5 kHz of bandwidth) is left to the MiSTer's
  audio filter.
- **Probe PASC:** mode, `$804`, both counts, interrupts raised.

**Estimate:** 300-500 ALMs and two M10Ks (the stub was 54).

## 11.4 The tests

1. `sim/asc` (Icarus), rewritten for the chip:
   - registers, the version, read-back;
   - FIFO mode at the true rate: a fill gives one "full" interrupt, the
     drain one "half empty", none at idle, none repeated (HW's results);
     `$804` cleared by a read, ORed by a write;
   - **System 7.5.5's refill replayed**: CB1-style handler, blind 512
     frames as word writes at `$3FF` (two byte cycles), then the bit-3
     poll - for several seconds of simulated sound: the interrupt rate
     about 43 a second, never a storm, the FIFO never empty mid-sound;
   - the ROM chime replayed: the right voices and pitches on the output;
   - volume, mono/stereo, the clear.
2. The machine bench; then the board: the 7.5.5 boot with the volume up,
   the alert beep, the chime, and sound out of the MiSTer.

## 11.5 As built (2026-10-03)

- **`rtl/se30_asc.v`** as 11.3, replacing `se30_asc_stub.v` and its bench
  (both removed). In the machine: GLUE's `asc_sel`, `RESET*`, VIA2 CB1;
  its two channels to the MiSTer's `AUDIO_L/R` (signed, `AUDIO_S = 1`) -
  the core's first sound. Probe **PASC** (mode, `$804`, both counts,
  interrupts raised); `read_probes.tcl` decodes it.
- **`sim/asc`: 746 checks** (Icarus, 2 min 16 s):
  - registers; idle (`$804` `$00`, no interrupt over 300 ticks);
  - ASCTester's fill-and-drain in stereo: full after 1,039 frames (1 KB
    plus the drain; the IIci 1,105-1,119 with slower writes), half empty
    0 while full, full 0 while half empty, no "empty" bit; one CB1 edge
    for full, one for half empty, no repeats; read clears, write ORs;
  - **System 7.5.5's path replayed** (`sdev 'asc '` +$A28, `lpch 28`):
    11,127 frames over 0.465 s by its handler - read `$804` once, refill
    on bit 2, 512 frames blind as byte pairs `$3FF`/`$400`, then frames
    while bit 3 is 0: **21 refills, 45.1 a second; FIFO B never below 510
    mid-sound; every frame out in order, left and right; after the sound,
    FIFO mode and CB1 still on, no interrupt in 4,000 ticks** (where the
    stub stormed);
  - wavetable: the four voices stepped and summed, the stereo pairs,
    saturation; `$18000` is 3 samples a tick, 130.4 Hz;
  - mono FIFO (A on both), the volume, the mode change, address-direct
    writes outside FIFO mode, the tick (44,937 ns = C16M/704) and 44.1 kHz.
  - A mutant that re-flags half empty on every sample below the midpoint
    fails 3 checks.
- `sim/kernel_bus` PORT=8 (the odd word write): 520 checks PASS.
- `sim/machine`: PASS (81 s).
- **Compile 31** (Daniel's go-ahead, 2026-10-03: "You can also compile
  when ready"): tag `48ba4df9`, 32 min 18 s,
  `output_files/MacSE30_48ba4df9_asc1.rbf` (md5
  `450ef47798b8881662ce99d2cf537011`).
  - **36,628 ALMs** (87 %), 331 RAM blocks. **The ASC measured: 447 ALMs**
    (the stub 54) and 4 M10Ks (Quartus duplicates the buffer for its
    third read port); PASC 28.
  - **Timing met at every corner** (`sta_corners.tcl`): worst +0.051 ns
    (hold, slow -40C); the capture A or B met at every corner.
- **On the board (Daniel, 2026-10-03): "Sound works. I am running Prince
  of Persia with perfect sound."** Compile 31, System 7.5.5 from SCSI,
  the volume back up: the beep that crashed compile 30 plays, and a game's
  sampled sound runs through the FIFOs, the interrupts and the output -
  the core's first sound.
- **The startup chime plays** (Daniel, 2026-10-03: "the same chime as on
  the LC, but for some reason it seems shorter") - the wavetable mode works
  on the board. Its length is the CPU's, not the ASC's: the ROM fades the
  four tables over 30,000 passes of a loop (`$40805F28`-`$40805F5C`: two
  reads and four writes of the ASC's RAM, then `subq.w #1,d4 / bpl` 35
  times; a voice starts every 300 passes), run before the ROM turns the
  caches on. A faster pass is a shorter chime - the kernel's instruction
  timing (1.16.1; Speedometer CPU 1.19 x the real SE/30). **OPEN:** this
  loop's clocks on a real 68030 (UM tables, uncached ROM fetches, the ASC's
  4/5-clock cycles) against the core's, measured.
- **QuarkXPress runs "quite stably"** (Daniel, 2026-10-03, compile 31,
  System 7.5.5 from SCSI) - the program whose F-line crash on the LC core
  was its fit-dependent SDRAM capture (`MacLC_MiSTer` memory,
  `quark-hang-80mb-image-forensics`).
- **Still to hear:** the alert sounds from the Sound control panel.
- **Open after compile 31**, for Daniel to order:
  1. the chime loop's clocks, real 68030 against the core (above);
  2. SCSI's board gates (9.6 item 5): a Finder copy checked on the PC
     (`hfs_check`, `hfs_fork_diff`), ID 1, a soak;
  3. the SDRAM `dq_out` path (compile 29's -0.109 ns, met since by
     placement only): drop the raw experiment port, or choose the word a
     clock earlier - Daniel's choice;
  4. the Graphics gap (0.70 of the real SE/30 in Speedometer 4.02, at 1
     bit): the video-RAM cycle (1.16.3);
  5. the floppy: writing and formatting (GCR), 1.4 MB MFM (budget 10.4);
  6. the CD-ROM and CD audio (Section 9 stage 2); the modem port to the
     MiSTer UART (10.3).

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
