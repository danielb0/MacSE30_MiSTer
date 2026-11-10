# NetBSD problem-report drafts (three kernel findings from the SE/30 core)

Daniel, 2026-11-10: "We should definitely file reports on all three patches."
Drafts for the NetBSD send-pr form (https://www.netbsd.org/support/send-pr.html);
each becomes one PR. Facts from SE30_PLAN.md KNOWN ISSUES 62, 63, 64. All
three were found on an FPGA SE/30 and IIcx (independent 68030 core) running
NetBSD 11.1 release kernels; none is machine-specific.

---

## PR 1 - kern: mac68k ncrscsi (ncr5380 PDMA) hangs at sd0 attach - finish_req marks the xfer done before scsipi_done

**Synopsis:** mac68k GENERIC (ncrscsi) hangs at "waiting for devices: scsibus0 sd0"; GENERICSBC boots. The driver completes INQUIRY and never issues another command.

**Environment:** NetBSD 11.1 mac68k, kernel GENERIC (ncrscsi attached), Macintosh SE/30 and IIcx (FPGA reimplementation; the same hang is seen on both).

**Description:** In sys/arch/mac68k/dev/ncr5380.c (mac68k's copy), `finish_req()` sets `xs->xs_status |= XS_STS_DONE` and then calls `scsipi_done(xs)`. scsipi_done() sees XS_STS_DONE already set and skips the periph release path, so the periph keeps PERIPH_UNTAG and the next command for the target (sd0's TEST UNIT READY) waits forever. The atari copy of the driver does not set XS_STS_DONE there. Observed with a hardware probe of the bus: after INQUIRY the 5380 bus is free, no command phase ever follows, no driver timeout fires. Same in netbsd-9, -10, -11 sources.

**How to repeat:** Boot GENERIC on an SE/30 or IIcx with a SCSI disk at ID 0 or 1; the boot stops at "waiting for devices: scsibus0 sd0". Boot GENERICSBC on the same machine: it boots.

**Fix:** Do not set XS_STS_DONE in finish_req(); let scsipi_done() do it (as the atari ncr5380 driver does).

---

## PR 2 - port-mac68k/booter: BSD/Mac68k Booter 2.0.0 pokes mac68k_vrsrc_vec/_cnt at the ELF symbol's st_name, not st_value, overwriting kernel text

**Synopsis:** The Booter's "Set _mac68k_vrsrc_vec" writes land at the string-table offset of the symbol instead of its address; with the WSFB/WSFBSBC kernels that corrupts two bytes of readdisklabel() and the kernel panics 6 s into the boot (MMU fault v=0xffffffe8 in dk_getdisklabel). GENERIC survives only because its st_name values happen to point at harmless bytes.

**Environment:** BSD/Mac68k Booter 2.0.0 (from the NetBSD 11.1 mac68k ISO), kernels netbsd-WSFBSBC and netbsd-GENERICSBC (11.1 release), SE/30 and IIcx.

**Description:** For ELF kernels the Booter looks up `mac68k_vrsrc_vec` and `mac68k_vrsrc_cnt` in the symbol table and writes the console video sRsrc word ((sRsrc id << 8) | slot, e.g. 0x800E on an SE/30, 0x8009 on a IIcx) and the count 1 into the loaded image. It takes the first field of the Elf32_Sym (st_name, the .strtab offset) as the address instead of st_value. In netbsd-WSFBSBC the symbol has st_name 0x1D607 and st_value 0x376C58: RAM at 0x1D607-0x1D608 reads 80 0E after the Booter (file: 2E 2C, the `lea` in readdisklabel), verified by reading RAM over JTAG at the panic. mac68k_vrsrc_cnt lands at 0x2F434 (sendsig_siginfo). Renaming the two symbols in the kernel's .strtab so the lookup fails makes the kernel boot and run X, which confirms the writer.

**How to repeat:** Boot netbsd-WSFBSBC with Booter 2.0.0 on an SE/30 (1-bit) or a IIcx with a Toby card; panic at ~5.8 s in dk_getdisklabel. Compare bytes at 0x1D607 of the loaded kernel.

**Fix:** In the Booter's ELF symbol lookup use st_value (offset 4 of Elf32_Sym), not st_name (offset 0). Workaround for users: rename the two symbols in .strtab (same length), or use an a.out kernel.

---

## PR 3 - kern: rasops monochrome attributes draw every character as a space since the 256-colour change (1-bit/2-bit/4-bit consoles blank)

**Synopsis:** On depth < 8 rasops consoles (mac68k WSFB kernels in 1-bit, with RASOPS_APPLE_PALETTE depth < 4; any port using rasops_allocattr_mono) NetBSD 11.1 draws no text at all - only the cursor cell is visible, as an inverted glyph.

**Environment:** NetBSD 11.1 mac68k, kernel WSFBSBC (genfb + wsdisplay, FONT_QVSS8x15, RASOPS_APPLE_PALETTE), SE/30 internal 512x342 1-bit video and IIcx Toby card in 1-bit. 8-bit on the same IIcx is fine.

**Description:** sys/dev/rasops/rasops.c `rasops_allocattr_mono()` sets fg = 0xff, bg = 0. Before rasops.h 1.52 / rasops.c 1.129 (256-colour VT100 support, PR kern/59544; pulled up to netbsd-11 in ticket #81) ATTR_FG/ATTR_BG masked the index with 0xf, so 0xff selected ri_devcmap[15] (all ones). The change widened the masks to 0xff and ri_devcmap to 256 entries, but rasops_init_devcmap() still fills only entries 0..15 for depth 1 (and 2, 4), so fg = ri_devcmap[255] = 0 == bg. Every putchar then takes the "fg == bg: this becomes a space" path (rasops1_putchar_width.h, rasops_putchar.h) and draws only the background. The cursor still shows because wsdisplay_vcons's noread cursor redraws the cell with attr ^ 0x0f0f0000 (indices 240 and 15). Confirmed by disassembly of the 11.1 kernel (rasops1_putchar8: bfextu {8:8} / lsr #24 indices, equal, space path) and by a two-byte binary patch of the constants 0xff000000 / 0x00ff0000 in rasops_allocattr_mono to 0x0f000000 / 0x000f0000, after which the console draws normally (verified on the SE/30 in 1-bit, 2026-11-10).

**How to repeat:** Boot WSFBSBC on any 1-bit mac68k (SE/30 in Black & White): the kernel boots to multi-user with a blank screen and a visible cursor; typing moves the cursor and draws nothing.

**Fix:** Either make rasops_allocattr_mono use fg = 15 (the last of the 16 mono map entries), or have rasops_init_devcmap fill entries 16..255 for depth 1/2/4 (e.g. ri_devcmap[i] = -1 for i >= 1), or mask the index to 0xf when ri_depth < 8. The first is a one-line fix.
