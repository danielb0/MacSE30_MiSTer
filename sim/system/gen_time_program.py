#!/usr/bin/env python3
"""The system bench's timing program (SE30_PLAN.md 1.17): loops taken
from the real software, each timed through the kernel, the wrapper, GLUE
and se30_video together, for comparison with the MC68030 User's Manual's
instruction timing (Section 11; report_time.py holds that model).

Writes timetest/program.hex, timetest/stop_at.txt and timetest/windows.txt
(one line per window: index, turns, name).

THE PROGRAM (supervisor, from $1000).  Each window runs between a write to
$3000+8w (start) and one to $3004+8w (end), w < 64, CLR.L to absolute addresses so
no register is disturbed; the bench times the window and counts its bus
cycles.  Loops copied from the ROM keep the ROM's address alignment (mod 4),
which decides how the 68030 prefetches them.

    cache off (CACR $0000, as the ROM runs before $40802C88 sets EI):
      0  DBRA D6 alone (the ROM's TimeDBRA loop shape)       1000 turns
      1  the chime pass, ROM $40805F28-$40805F5F, verbatim     40 passes
         (two ASC reads, four ASC writes, a 36-turn SUBQ/BPL delay;
         A3 = $50F14000, D0 = 35, D3 = 0 as after the voices start)
    instruction cache on (CACR $0001; the data cache stays off - the bench
    has no MMU, so nothing would make the video RAM CI):
      2  DBRA D6 alone                                        1000 turns
      3  register-only: ADD.L D1,D2 / LSL.L #2,D3 / MOVE.L D2,D4 /
         SUB.L D3,D4 / DBRA                                    500 turns
      4  RAM fill   MOVE.L D0,(A0)+ / DBRA                     500 turns
      5  RAM read   MOVE.L (A0)+,D2 / DBRA                     500 turns
      6  RAM copy   MOVE.L (A0)+,(A1)+ / DBRA                  500 turns
      7  VRAM fill  MOVE.L D0,(A0)+ / DBRA (8-bit port)        500 turns
      8  VRAM byte  MOVE.B D0,(A0)+ / DBRA                     500 turns
      9  RAM->VRAM  MOVE.L (A1)+,(A0)+ / DBRA                  500 turns
     10  SCSI blind read, ROM $40826B7A-$40826B91 verbatim:
         8 x MOVE.L (A0),(A2)+ / DBRA D1 / DBRA D5,
         A0 = $50F06000 (the DRQ-handshaked DACK port)          16 turns
     11  SCSI blind write, ROM $40826BC2-$40826BD9 verbatim:
         8 x MOVE.L (A2)+,(A1) / DBRA D1 / DBRA D5              16 turns
     12  the .Sony's SWIM handshake poll, ROM $4082EAC2 verbatim:
         TST.B (A3) / DBMI D1, A3 = $50F17E00 (rHandshake; the
         bench's device port reads 0, so N stays clear)       1000 turns
     13  its VIA1 ORA read as a poll, TST.B (A5) / DBMI D1,
         A5 = $50F01E00                                       1000 turns
     14  the .Sony's GCR address field, ROM $40831C48-$40831C69
         verbatim: five MOVE.B (A4) data-register reads with table
         lookups between (A4 = $50F17800, which the bench answers
         with $FF; A3 = a table in RAM)                        500 turns
     15  SUBQ.W #1,D0 / BNE.B (a taken branch)                  500 turns
     16  TST.W D0 / BEQ.B not taken / MOVEQ #1,D0 / DBRA         500 turns
     17  MOVE.B (A3,D5.W),D1 / DBRA (an indexed RAM read)       500 turns
    then translation on, as System 7.5.5 runs (the ROM's 24-bit mode:
    CRP $7FFF0002 to a RAM copy of its table at $40800050, TC $80F84500,
    plan 1.11):
  18-33  windows 2-17 again.  On a 68030 an ATC hit costs nothing - "the
         address translation time is completely overlapped with on-chip
         cache accesses" (UM 11.2.6) - so their 68030 figures are 2-11's.
    Then STOP.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "timetest")
ORG = 0x1000
ROM = os.environ.get("SE30_ROM", r"C:\temp\Mac\ROMS\256KB ROMs\1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM")
ROM_BASE = 0x40800000
MMU_ROOT = 0x2800                       # CRP (8 bytes) then TC (4)
MMU_TABLE = 0x2840                      # the sixteen level-A descriptors


def rom_words(lo, hi):
    """The ROM's words from lo up to (not including) hi."""
    with open(ROM, "rb") as f:
        b = f.read()
    s = b[lo - ROM_BASE:hi - ROM_BASE]
    return [(s[i] << 8) | s[i + 1] for i in range(0, len(s), 2)]


def main():
    w = []
    names = []
    def pc(): return ORG + 2 * len(w)
    def clr_l(a): w.extend([0x42B9, a >> 16, a & 0xFFFF])            # CLR.L (a).L
    def lea(n, a): w.extend([0x41F9 | (n << 9), a >> 16, a & 0xFFFF])  # LEA (a).L,An
    def movew_d(n, v): w.extend([0x303C | (n << 9), v & 0xFFFF])      # MOVE.W #v,Dn
    def moveq(n, v): w.append(0x7000 | (n << 9) | (v & 0xFF))
    def cacr(v):                                                       # MOVE.L #v,D7; MOVEC D7,CACR
        w.extend([0x2E3C, v >> 16, v & 0xFFFF, 0x4E7B, 0x7002])
    def timed(name, turns, setup, loop_words, m=0):
        k = len(names)
        names.append((k, turns, name))
        setup()
        # pad so that the loop (after the 6-byte marker) lands at pc % 4 == m
        while (pc() + 6) % 4 != m:
            w.append(0x4E71)
        clr_l(0x3000 + 8 * k)
        assert pc() % 4 == m
        w.extend(loop_words)
        clr_l(0x3004 + 8 * k)

    dbra_d6 = lambda disp: [0x51CE, disp & 0xFFFF]

    cacr(0x0008)                                                       # CI: the instruction cache empty, disabled
    # 0: DBRA alone, uncached
    timed("DBRA alone, cache off", 1000, lambda: movew_d(6, 999), dbra_d6(-2))
    # 1: the chime pass, verbatim from the ROM (entered at its top; the ROM
    #    enters through the BRA at $40805F26 to $40805F4C, the same loop)
    chime = rom_words(0x40805F28, 0x40805F60)
    def chime_setup():
        lea(3, 0x50F14000)
        w.append(0x204B)                                               # MOVEA.L A3,A0
        w.extend([0x43EB, 0x0200])                                     # LEA $200(A3),A1
        moveq(0, 35)                                                   # the ROM table's delay count
        movew_d(2, 39)                                                 # 40 passes
        moveq(3, 0)                                                    # every voice started: BEQ taken
        moveq(5, 0)
    timed("chime pass (ROM $40805F28), cache off", 40, chime_setup, chime, m=0x40805F28 % 4)

    cacr(0x0001)                                                       # EI
    def cached_windows(sfx, vram):
        timed("DBRA alone, I-cache on" + sfx, 1000, lambda: movew_d(6, 999), dbra_d6(-2))
        timed("register-only ADD/LSL/MOVE/SUB + DBRA, I-cache on" + sfx, 500,
              lambda: movew_d(6, 499), [0xD481, 0xE58B, 0x2802, 0x9883] + dbra_d6(-10))
        def ram_setup():
            movew_d(6, 499); lea(0, 0x8000); lea(1, 0xC000)
            w.extend([0x203C, 0x5555, 0xAAAA])                         # MOVE.L #$5555AAAA,D0
        timed("RAM fill MOVE.L D0,(A0)+, I-cache on" + sfx, 500, ram_setup, [0x20C0] + dbra_d6(-4))
        timed("RAM read MOVE.L (A0)+,D2, I-cache on" + sfx, 500, ram_setup, [0x2418] + dbra_d6(-4))
        timed("RAM copy MOVE.L (A0)+,(A1)+, I-cache on" + sfx, 500, ram_setup, [0x22D8] + dbra_d6(-4))
        def vram_setup():
            movew_d(6, 499); lea(0, vram); lea(1, 0x8000)
            w.extend([0x203C, 0x5555, 0xAAAA])
        timed("VRAM fill MOVE.L D0,(A0)+, I-cache on" + sfx, 500, vram_setup, [0x20C0] + dbra_d6(-4))
        timed("VRAM byte MOVE.B D0,(A0)+, I-cache on" + sfx, 500, vram_setup, [0x10C0] + dbra_d6(-4))
        timed("RAM->VRAM copy MOVE.L (A1)+,(A0)+, I-cache on" + sfx, 500, vram_setup, [0x20D9] + dbra_d6(-4))
        blind_r = rom_words(0x40826B7A, 0x40826B92)
        def blind_r_setup():
            lea(0, 0x50F06000); lea(2, 0x8000); moveq(1, 15); moveq(5, 0)
        timed("SCSI blind read 8 x MOVE.L (A0),(A2)+ (ROM $40826B7A), I-cache on" + sfx, 16,
              blind_r_setup, blind_r, m=0x40826B7A % 4)
        blind_w = rom_words(0x40826BC2, 0x40826BDA)
        def blind_w_setup():
            lea(1, 0x50F06000); lea(2, 0x8000); moveq(1, 15); moveq(5, 0)
        timed("SCSI blind write 8 x MOVE.L (A2)+,(A1) (ROM $40826BC2), I-cache on" + sfx, 16,
              blind_w_setup, blind_w, m=0x40826BC2 % 4)
        # the .Sony's handshake poll, ROM $4082EAC2 (plan 1.17.5): TST.B (A3)
        # / DBMI D1, up to 31 polls a byte in the driver; here 1000, the
        # handshake never ready (the bench's device port reads 0, N clear)
        def poll_setup(): movew_d(1, 999); lea(3, 0x50F17E00)
        timed("SWIM handshake poll TST.B (A3)/DBMI D1 (ROM $4082EAC2), I-cache on" + sfx, 1000,
              poll_setup, [0x4A13, 0x5BC9, 0xFFFC], m=0x4082EAC2 % 4)
        # the same loop's VIA1 ORA read ($4082EABC, tst.b (a5)), as a poll
        def via_setup(): movew_d(1, 999); lea(5, 0x50F01E00)
        timed("VIA1 ORA poll TST.B (A5)/DBMI D1 (ROM $4082EABC), I-cache on" + sfx, 1000,
              via_setup, [0x4A15, 0x5BC9, 0xFFFC], m=0x4082EABC % 4)
        # the .Sony's GCR address field, ROM $40831C48-$40831C69 verbatim
        # (plan 1.17.5): five reads of the SWIM's data register with only a
        # table lookup and a register op or two between them - the ROM's
        # shortest gap between two data-register reads, which the chip
        # clears 14 FCLK after a valid read (5.12.12 item 2).  The bench
        # answers the data register ($1800) with $FF, so each BPL falls
        # through; the table is in RAM (the bench has no ROM).  The bench
        # reports the shortest SWIM strobe-to-strobe gap in the window.
        gcr = rom_words(0x40831C48, 0x40831C6A)
        def gcr_setup(): movew_d(6, 499); lea(4, 0x50F17800); lea(3, 0x4000)
        timed("GCR address field, 5 x MOVE.B (A4) + table (ROM $40831C48), I-cache on" + sfx, 500,
              gcr_setup, gcr + dbra_d6(-(2 * len(gcr) + 2)), m=0x40831C48 % 4)
        # three costs the replay bench (sim/gcrread) models as constants: a
        # taken branch, a not-taken one, an indexed read
        timed("SUBQ.W #1,D0 / BNE.B taken, I-cache on" + sfx, 500, lambda: movew_d(0, 500), [0x5340, 0x66FC])
        def nt_setup(): movew_d(6, 499); movew_d(0, 1)
        # (BEQ.B skips a MOVEQ: a byte displacement of 0 would be the word form)
        timed("TST.W D0 / BEQ.B not taken / MOVEQ / DBRA, I-cache on" + sfx, 500, nt_setup, [0x4A40, 0x6702, 0x7001] + dbra_d6(-8))
        def ix_setup(): movew_d(6, 499); lea(3, 0x4000); moveq(5, 0x7F)
        timed("MOVE.B (A3,D5.W),D1 / DBRA, I-cache on" + sfx, 500, ix_setup, [0x1233, 0x5000] + dbra_d6(-6))
    cached_windows("", 0xFE000000)
    # 18-33: the same with translation on, as System 7.5.5 runs: the ROM's
    # 24-bit mode (plan 1.11) - CRP $7FFF0002 to a RAM copy of its sixteen
    # early-terminating page descriptors, TC $80F84500 - loaded as
    # _SwapMMUMode loads it (PMOVE (A0),CRP; PMOVE 8(A0),TC)
    lea(0, MMU_ROOT)
    w.extend([0xF010, 0x4C00])                                         # PMOVE (A0),CRP
    w.extend([0xF028, 0x4000, 0x0008])                                 # PMOVE 8(A0),TC
    cached_windows(", PMMU on (24-bit)", 0x00E00000)   # the video RAM at its 24-bit address (descriptor $E)

    stop_at = pc()
    w.extend([0x4E72, 0x2700])                                         # STOP #$2700
    mem = [0x4E71] * 65536
    mem[0], mem[1] = 0x0000, 0x0800
    mem[2], mem[3] = 0x0000, ORG
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    # the 24-bit root pointer, TC and table (the ROM's, from $40803B86 and
    # $40800050, the table moved to RAM)
    tbl = rom_words(0x40800050, 0x40800090)
    mmu = [0x7FFF, 0x0002, MMU_TABLE >> 16, MMU_TABLE & 0xFFFF, 0x80F8, 0x4500]
    for i, x in enumerate(mmu):
        mem[MMU_ROOT // 2 + i] = x
    for i, x in enumerate(tbl):
        mem[MMU_TABLE // 2 + i] = x
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "program.hex"), "w", newline="\n") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(OUT, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n%d\n" % (stop_at, len(w)))
    with open(os.path.join(OUT, "windows.txt"), "w", newline="\n") as f:
        for k, turns, name in names:
            f.write("%d %d %s\n" % (k, turns, name))
    with open(os.path.join(OUT, "count.txt"), "w", newline="\n") as f:
        f.write("%d\n" % len(names))
    print("time program: %d words, %d windows, STOP at $%X" % (len(w), len(names), stop_at))


if __name__ == "__main__":
    main()
