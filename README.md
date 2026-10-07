# Macintosh SE/30 for the [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

An authentic Macintosh SE/30: a 68030 with its PMMU at 15.6672 MHz, GLUE,
the pseudo-slot 512 x 342 one-bit video, and the SE/30's peripherals, built
from the machine's documentation - the *Guide to the Macintosh Family
Hardware*, Apple's schematic 050-0253-01, the video PAL equations and the
ROM itself - rather than from other emulators. Stock ROM, 24-bit
addressing, 8 MB; enhancements, when they come, as menu options.

> **Work in progress - it does not boot yet.** The CPU (with the 68030's
> dynamic bus sizing), GLUE and the video pass their benches; the tree is
> being assembled around them. [SE30_PLAN.md](SE30_PLAN.md) is the source
> of truth for where things stand, what has been decided and why.

## What you will need

Apple's ROM images are not in this repository. Put them in the core's
folder on the SD card:

| file | what | size |
|---|---|---|
| `boot0.rom` | the SE/30 ROM - the image shared with the Macintosh II FDHD, IIx and IIcx, checksum `97221136` | 256 KB |
| `boot1.rom` | the video declaration ROM, Apple part 341-0650 | 8 KB |
| `boot2.rom` | the ADB transceiver's program, Apple part 342S0440-B (a PIC1654S; MAME's `342s0440-b.bin`, CRC32 `cffb33eb`). Without it the keyboard and mouse do not work and start-up waits in the ADB initialisation | 1 KB |

## Using the core

### PRAM (parameter RAM)

The SE/30 keeps its settings in the clock chip's 256 bytes of PRAM: the
startup disk, 32-bit addressing, the sound volume, the mouse and keyboard
settings, and so on. The core keeps them in a PRAM image, `MacSE30.nvr`
(512 bytes; a blank image is all zeros), in the OSD's **Mount PRAM** slot:

- **Load:** the image is read when it is mounted. MiSTer mounts it again
  each time the core starts, and the Mac waits for it before booting, so
  start-up takes a moment longer than without one.
- **Save:** a change the Mac makes is written back about two seconds
  later, and again whenever the OSD opens.
- **Mount PRAM restarts the Mac at once**, so that it comes up on the
  settings it has just loaded.
- **Wipe PRAM (erases settings!)** zeroes the PRAM, saves the zeros to
  the image and restarts the Mac at once. The ROM then writes its
  defaults, as on a real SE/30 after a battery change.
- **With no image mounted** the Mac starts at once. Its settings last
  until the core is reloaded, as if the battery were flat.

The clock is set from MiSTer's time each time the core loads; it is not
kept in the image.

### Floppy disks

Mounting a floppy image in the OSD while another is still mounted is the
same as ejecting a real disk with a paperclip: the old disk leaves the
drive without the Mac being told. A disk the Mac had finished with comes
to no harm, but anything the Mac had not yet written to it is lost. Eject
the disk in the Finder first, then mount the next one.

## Building

Intel Quartus Prime 17.0.2 Lite Edition. Open `MacSE30.qpf` in the GUI, or
use the scripted flow:

```bash
bash scripts/setup_env.sh     # once: creates scripts/local.env, then set QUARTUS_BIN in it
bash scripts/build_only.sh    # full compile -> output_files/MacSE30.rbf and a status summary
```

`build_only.sh --check` runs Analysis & Synthesis only. The build never
touches a MiSTer; copying the `.rbf` is a separate, manual step.

## Simulation

Every module has a bench under `sim/`, each with a `run.sh` whose exit
status is the verdict. Our own RTL runs under
[Icarus Verilog](http://iverilog.icarus.com/); anything that includes the
CPU (whose kernel is VHDL) runs under the ModelSim Starter Edition that
ships with Quartus, mixed-language. The plan's section 1.10 explains the
split.

## Lineage and thanks

The MiSTer framework (`sys/`) is Sorgelig's, taken verbatim from
[Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer). The
CPU is the TG68K.C kernel by Tobias Gubener, with the 68030 PMMU and audit
work by apolkosnik ([Minimig-AGA_MiSTer](https://github.com/apolkosnik/Minimig-AGA_MiSTer),
branch `030_mmu2`), which reached the Macintosh through Dani Sarfati's
[MacIIvi_MiSTer](https://github.com/danifunker/MacIIvi_MiSTer); the
kernel in this tree carries its own bus work and is documented in
`rtl/tg68k/README.md`. The build scripts, and peripheral modules as they
are adopted, come from Dani Sarfati's
[MacLC_MiSTer](https://github.com/MiSTer-devel/MacLC_MiSTer) and
Sorgelig's [MacPlus_MiSTer](https://github.com/MiSTer-devel/MacPlus_MiSTer),
which descends from Steve Chamberlin's
[Plus Too](http://www.bigmessowires.com/plus-too/); each file records
where it came from. Bolle's reproduction of the SE/30 video PALs and the
`macse30mlb` schematic redraw made the video and GLUE readable.

## Licence

GPL-2.0-or-later for the core, as the framework and the donor cores are.
The TG68K kernel, ALU and PMMU are LGPL-3.0-or-later, per their headers.
