# Macintosh SE/30 for the [MiSTer Board](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

A Macintosh SE/30, built from the machine's documentation - the *Guide to
the Macintosh Family Hardware*, Apple's schematic 050-0253-01, the chips'
own manuals and the SE/30 ROM - with emulators used only as cross-checks.
It runs at the real machine's speed.

## The machine

- **68030 at 15.6672 MHz** with its PMMU and on-chip caches, timed to the
  MC68030 User's Manual
- **68882 floating-point coprocessor**, microcoded
- **8 MB or 16 MB of RAM** (OSD option)
- **Built-in video**: 512 x 342, one bit
- **SWIM floppy controller and SuperDrive**: 400K and 800K (GCR), 720K and
  1.44 MB (MFM) disks, read and write
- **SCSI**: two hard disks (IDs 0 and 1) and an AppleCD SC CD-ROM (ID 3)
- **Apple Sound Chip**
- **ADB**: Apple Extended Keyboard and mouse, through Apple's own
  transceiver program
- **Clock chip and PRAM**, with the PRAM kept in an image file
- System 6 and System 7, in 24-bit or 32-bit mode

## ROMs

Copies are in `releases/`. Put them in the core's folder on the SD card
(`games/MACSE30`):

| file | what | size |
|---|---|---|
| `boot0.rom` | the SE/30 ROM (checksum `97221136`, shared with the IIx, IIcx and II FDHD) | 256 KB |
| `boot1.rom` | the video declaration ROM, Apple 341-0650 | 8 KB |
| `boot2.rom` | the ADB transceiver's program, Apple 342S0440-B (MAME's `342s0440-b.bin`) | 1 KB |

Without `boot2.rom` the keyboard and mouse do not work.

## Using the core

### Disks

- **Mount Internal Floppy**: raw `.dsk`/`.img` images or DiskCopy 4.2
  images. Changes are written back to the image.
- **Mount SCSI-0 / SCSI-1**: hard disk images (`.img`, `.vhd`), read and
  written.
- **Mount CD-ROM**: data CDs as ISO or Toast images. There is no CD audio.

Mounting a floppy while another is mounted is like ejecting a real disk
with a paperclip: anything the Mac had not yet written to the old disk is
lost. Eject it in the Finder first.

### Memory and 32-bit mode

**Memory** selects 8 MB or 16 MB; **Reset & Apply Memory** restarts the
Mac with it. In 24-bit mode the Mac uses 8 MB at most. The SE/30 ROM is not
32-bit clean, so 32-bit mode needs Apple's **MODE32** extension (use its
installer), then 32-Bit Addressing on in the Memory control panel. Much
software from before 1988 does not run in 32-bit mode, on a real SE/30 or
here.

### PRAM

The Mac's settings (startup disk, 32-bit addressing, volume, mouse and
keyboard settings, and so on) live in the clock chip's 256 bytes of PRAM.
Mount a PRAM image (`MacSE30.nvr`, 512 bytes; an empty file is fine) in the
**Mount PRAM** slot to keep them:

- the image is read when it is mounted, and the Mac waits for it before
  starting, so start-up takes a moment longer;
- changes are saved about two seconds after the Mac makes them, and when
  the OSD opens;
- **Mount PRAM** and **Wipe PRAM** restart the Mac at once; after a wipe
  the ROM writes its defaults, as after a battery change;
- with no image mounted, settings last until the core is reloaded.

The clock is set from MiSTer's time when the core loads.

### Notes

- Holding **Shift** right after the startup chime starts System 7 with its
  extensions off. As in the period, extensions conflict with some games.
- Disk access is faster than on a real SE/30; the CPU, graphics and FPU
  run at its speed.

## Not included

Serial ports and LocalTalk, the external floppy drive, CD audio, the
programmer's switch (NMI), and expansion cards.

## Building

Intel Quartus Prime 17.0.2 Lite Edition: open `MacSE30.qpf` and compile.

The 68882's microcode (`rtl/fpu/ucode`) is assembled from
`tools/fpu_ucode/ucode/*.uc` with `tools/fpu_ucode/asm.py` (Python 3):

```bash
cd tools/fpu_ucode
python asm.py ucode/fpu.uc -o out/ucode
```

then the `.hex` files and `fpu_ucode.vh` in `out/` are copied to
`rtl/fpu/ucode`.

## Lineage and thanks

The MiSTer framework (`sys/`) is Sorgelig's, from
[Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer). The CPU
is the TG68K.C kernel by Tobias Gubener, with the 68030 PMMU by apolkosnik
([Minimig-AGA_MiSTer](https://github.com/apolkosnik/Minimig-AGA_MiSTer),
branch `030_mmu2`), by way of Dani Sarfati's
[MacIIvi_MiSTer](https://github.com/danifunker/MacIIvi_MiSTer); see
`rtl/tg68k/README.md`. The SCSI target comes from Sorgelig's
[MacPlus_MiSTer](https://github.com/MiSTer-devel/MacPlus_MiSTer), which
descends from Steve Chamberlin's [Plus Too](http://www.bigmessowires.com/plus-too/),
and lessons from Dani Sarfati's [MacLC_MiSTer](https://github.com/MiSTer-devel/MacLC_MiSTer)
shaped the rest. Bolle's reproduction of the SE/30 video PALs and the
`macse30mlb` schematic redraw made the video and GLUE readable.

## Licence

GPL-2.0-or-later, as the framework and the donor cores are. The TG68K
kernel, ALU and PMMU are LGPL-3.0-or-later.
