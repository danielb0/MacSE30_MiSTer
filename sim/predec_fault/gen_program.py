#!/usr/bin/env python3
"""The predec_fault bench's program (tb_predec_fault.v's header; SE30_PLAN.md
KNOWN ISSUES 20): instructions page-faulting mid-instruction through the PMMU,
resumed by a handler that does what A/UX's pager does - the two loops the
board's trace caught faulting before the Mac environment's bomb.

  blockmove  the ROM's BlockMove backward loop, $4080EFFE-$4080F01F byte for
             byte: MOVE.L D0,D1; LSR.L #5,D1; 8 x MOVE.L -(A0),-(A1) under
             two DBRAs (the board: #1063-#1097)
  straddle   the BlockMove loop on word-aligned blocks: a long at $xxxFFE spans
             two pages, and the lower or the upper word's page is invalid
  dcmp       the decompressor the board faulted in at $296E5E/$296E7C
             (#1246/#1247), captured from MAME's run of the same image
             (C:\\temp\\Mac\\mame\\aux\\bp296.lua; the routine at $296DE8):
             its expansion loop $296E40-$296E8F byte for byte, entered at
             $296E48 - each flag byte's bits, MSB first, pick for each output
             word two literal bytes (MOVE.B (A0)+,(A2)+ twice, $296E5E) or a
             word from a table (MOVE.W (A1,D0.W),(A2)+, $296E7C), a zero flag
             byte eight literal pairs; D1 = the output words, D5 = 0
  aux7       the board's big move (compile 62, #1275-#1323): the BlockMove
             loop with every destination page top written by the SEVENTH
             MOVE.L ($4080F012) and the next long by the eighth
  memind     KNOWN ISSUES 25: A/UX's X11 clients' memory-indirect EAs with
             the pointer's, the operand's or the destination's page invalid
  memfull    the full extension word's every form (MIBD x IS-I/IS) under a
             LASTWRITE write fault, through the EA (MIPART=d) or after it (s)

HANDLER (the bus-error handler's flush): pflusha (default); aux = A/UX's
fl_userpg, PFLUSH #3,#4,(A0) on the fault address; auxirq = aux, run at
$2700 with VIA2 T1 started and waited for, so a level-2 interrupt is
pending at the RTE (A/UX's ret_user2; VIA2 reached through TT0); auxfull =
aux plus everything A/UX's path does on EVERY user bus error (unix.dis:
buserr% $54C08, user_buserr $54C20, hardflt $59850, hardsegflt $5A866,
ret_user2 $54A66, ret_user3 $54AE6): the whole register file saved; MOVEC
CACR with m20cache ($2101: EI, ED, WA - the SE/30's, enable_caches $5465E)
at entry; LINK/UNLK; the fresh page CLEARED through the supervisor's own
mapping by A/UX's MOVEM.L pattern (Pg_ptr $561E0: 12 then 4 x 13 registers
a 256-byte stride) before its user descriptor is written as a long;
PFLUSH #3,#4,(A0); MOVE #$2700,SR then #$2000,SR; MOVEC CACR with the
process's mode (CACRX, default $2101 - u+$530's value is unread); MOVE to
USP; MOVEM restore; RTE.  Needs TCMODE=aux (the supervisor tree is the
alias) and a destination-invalid case set (aux7).  auxfullirq = auxfull
with auxirq's pending interrupt

TCMODE (the translation): bench (default, below); aux = A/UX 3's: TC
$82C07760 (E, SRE, PS 4 KB, IS 0, TIA 7, TIB 7, TIC 6), so user accesses
walk CRP's tree and supervisor ones SRP's - two separate identity trees of
three levels (A at $4000/$4600, B $4200/$4800, the page tables $4400/$4A00,
128 pages each, U and M clear); the cases' pages are made invalid in the
USER tree only, and the handler (supervisor) repairs them through its own
identity mapping, as A/UX's hardflt does

THE PROGRAM (supervisor, from $1000)
    CACR from the CACR environment variable (default 0: caches off)
    PMOVE (A0),CRP / PMOVE (A0),TC: TC $80C84800 (E, PS 4 KB, IS 8, TIA 4,
      TIB 8); table A at $4000 (entry 0 -> table B at $4100, short format),
      table B: 256 page descriptors, identity, valid, U and M clear (the
      walker sets them, UM 9.5.3 - A/UX's pages start that way too)
    USP $9000
    each case (CASES; CASESET=blockmove|straddle|dcmp|aux7 picks one kind; moves,
      wp, jsr, bf, bfx, ifetch, memind and memfull run only alone): the case's
      pages made invalid (DT 0) and PFLUSHA; the registers; MOVE #0,SR (user
      mode, as the Mac environment runs); the loop; TRAP #0 back to
      supervisor; A0, A1, D1, the count of output longs that differ from the
      reference (the source for blockmove, the model's output for dcmp), the
      handler count and A2 to the case's slots
    STOP #$2700
    vector 2 (bus error), $1C00: count the entry ($3200), log the fault
      address, SSW and format word ($3300 on), make the faulting page's
      descriptor valid, PFLUSHA, RTE with the frame untouched (DF set: the
      faulted cycle reruns, UM 8.2.1) - more than 100 entries = a loop:
      stop at $1D80
    TRAP #0 (vector 32), $1D40: drop its frame, JMP (A5) (the case's
      continuation)
    any other exception, $1E00: its format/vector word and PC to $3F00, stop

Writes program.hex (512 KB as 16-bit words), stop_at.txt ({STOP address} {checks})
and expect.txt ({slot} {value} {what} per line).
"""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROM", "C:/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM")
CACR = int(os.environ.get("CACR", "0"), 0)
CACRX = int(os.environ.get("CACRX", "0x2101"), 0)   # auxfull: the CACR the handler leaves (ret_user3's set_cachemode)
M20CACHE = 0x2101                                    # auxfull: enable_caches' value on the SE/30 (no burst)
CASESET = os.environ.get("CASESET", "all")
HANDLER = os.environ.get("HANDLER", "pflusha")
H_ADDR = HANDLER in ("aux", "auxirq", "auxfull", "auxfullirq")   # PFLUSH by address
H_IRQ = HANDLER in ("auxirq", "auxfullirq")                       # an interrupt pending at the RTE
H_FULL = HANDLER in ("auxfull", "auxfullirq")                     # A/UX's every-fault path
IRQIN = os.environ.get("IRQIN", "0") == "1"                       # auxfullirq: lower the mask to $2000 inside the handler (LQR%9), so the interrupt is taken before the RTE
ORG, BERR, TRAP0, LOOPSTOP, EXC = 0x1000, 0x1C00, 0x1D40, 0x1D80, 0x1E00
TBL_A, TBL_B, CRP_AT = 0x4000, 0x4100, 0x3E00
TCMODE = os.environ.get("TCMODE", "bench")
# aux: (A, B, page table) for the user (CRP) and the supervisor (SRP) trees
AUX_U, AUX_S = (0x4000, 0x4200, 0x4400), (0x4600, 0x4800, 0x4A00)
PG_TBL = AUX_U[2] if TCMODE == "aux" else TBL_B  # the user tree's page descriptors, 4 bytes a page
TRAPF = 0x1F40                                   # TRAP #15 (vector 47): the rts cases' syscall return
IRQ1, IRQ1COUNT = 0x1F60, 0x320C                 # the bench's +IRQAT level-1 interrupt (scan 4): count, RTE
IRQ, VIA2 = 0x1F00, 0x50002000                   # auxirq: the level-2 handler; VIA2 (register n at +n x $200)
TT0 = 0x50008507                                 # $50xxxxxx transparent (E, CI, RWM, every FC): VIA2 untranslated
IRQCOUNT = 0x3208
TC = 0x82C07760 if TCMODE == "aux" else 0x80C84800
SLOTS, COUNT, LOGP, LOG = 0x3000, 0x3200, 0x3204, 0x3300
SIZE = 0x80000                                   # the image: 512 KB

# the decompressor's expansion loop, $296E40-$296E8F (MAME, identical in all 20 hits)
DCMP = bytes.fromhex("4A05674C149060482401028200000007E6896012780716186712D603651814D814D851CCFFF6"
                     "53816AEA601A14D814D851CCFFFA60F070001018D04034F1000051CCFFD860E0380267B6"
                     "7400161860F0")
DCMP_ENTRY = 0x08                                # $296E48

# blockmove: (source start, destination start, bytes, invalid pages, what)
BLOCKMOVE = [
    (0x20000, 0x30000, 0x2000, [0x30000, 0x31000], "destination pages invalid: the writes fault (LASTWRITE replay)"),
    (0x24000, 0x34000, 0x2000, [0x24000, 0x25000], "source pages invalid: the reads fault (rollback, re-execute)"),
    (0x28000, 0x38000, 0x2000, [0x28000, 0x29000, 0x38000, 0x39000], "both invalid: a read fault, then a write fault, in one instruction"),
    (0x2C800, 0x3C000, 0x2000, [0x2C000, 0x2D000, 0x2E000, 0x3C000, 0x3D000], "source misaligned to the pages: the faults land mid-loop"),
]
# straddle: the same loop on word-aligned blocks, so a long at $xxxFFE spans two
# pages (the board, compile 59: #1271/#1272 faulted at $33FFFE/$33BFFE, then the
# process ran on its stack) - (source, destination, bytes, invalid pages, what)
STRADDLE = [
    (0x0A002, 0x0C002, 0x2000, [0x0C000, 0x0D000], "straddling writes, the LOWER word's page invalid (the board's #1271)"),
    (0x10002, 0x14002, 0x2000, [0x10000, 0x11000], "straddling reads, the lower word's page invalid"),
    (0x16000, 0x18002, 0x2000, [0x1A000], "a straddling write, the UPPER word's page invalid: the first word lands, the second faults"),
    (0x1A802, 0x1E000, 0x1800, [0x1C000], "a straddling read, the UPPER word's page invalid"),
    (0x74000, 0x76001, 0x1000, [0x77000], "a long at $xxxFFD: 3 bytes land, the LAST byte's page invalid (SIZE byte)"),
    (0x78000, 0x7A003, 0x1000, [0x7B000], "a long at $xxxFFF: 1 byte lands, the last 3 bytes' page invalid (SIZE 3 bytes)"),
]
# aux7: the board's big move (compile 62, #1275-#1323): every page top's write
# fault on the SEVENTH MOVE.L ($4080F012), the next long by the eighth - the
# destination's end at $18 mod $20 - (source, destination, bytes, invalid pages, what)
# DSTOFF (1-3) moves the destination off long alignment, as the board's
# RTRACE showed it (compile 66: the writes after each replay at $xxxFF5,
# $xxxFF1 - A1 = 1 mod 4 - and in an earlier move at $xxxFF7, 3 mod 4), so
# every long is two beats and a page top's faults land between them
DSTOFF = int(os.environ.get("DSTOFF", "0"), 0)
AUX7 = [
    (0x20000, 0x30018 + DSTOFF, 0x4000, [0x30000, 0x31000, 0x32000, 0x33000, 0x34000],
     "destination pages invalid, each page top written by the 7th MOVE.L (the board's $4080F012)" +
     (", the destination %d off long alignment" % DSTOFF if DSTOFF else "")),
]
# moves: A/UX's copy loops through MOVES (unix.dis: copyout $556F0, copyin
# $554F0, uclear $557D0), run in SUPERVISOR mode with SFC = DFC = 1 (user
# data) on user pages invalid in the user tree, the user pointer off long
# alignment - (kind, kernel side, user side, bytes, invalid pages, what):
#   copyout  move.l -(a1),d2 / moves.l d2,-(a0): the user side written
#   uclear   moves.l a1,-(a0), A1 = 0: the user side cleared (bss at launch)
#   copyin   moves.l -(a1),d2 / move.l d2,-(a0): the user side read
MOVES = [
    ("copyout", 0x20000, 0x30001, 0x2000, [0x30000, 0x31000, 0x32000], "copyout, the user destination 1 off alignment"),
    ("copyout", 0x24000, 0x34003, 0x2000, [0x34000, 0x35000, 0x36000], "copyout, the user destination 3 off alignment"),
    ("uclear",  0x28000, 0x38001, 0x2000, [0x38000, 0x39000, 0x3A000], "uclear, the user destination 1 off alignment"),
    ("copyin",  0x3C000, 0x2C001, 0x2000, [0x2C000, 0x2D000, 0x2E000], "copyin, the user source 1 off alignment"),
]
# wp: copy-on-write, as A/UX's fork leaves a process's pages - VALID but
# write-protected (WP, bit 2) in the user tree; a write faults on a page
# the instruction may just have read, and the handler clears WP.  The
# operation runs up the block through (A0)+, user mode - (opcode, size,
# destination, bytes, what):
WP = [
    (0xD198, 4, 0x30001, 0x2000, "ADD.L D0,(A0)+, 1 off alignment: read-modify-write longs straddling WP page tops"),
    (0xD198, 4, 0x34002, 0x2000, "ADD.L D0,(A0)+, 2 off alignment"),
    (0xD158, 2, 0x38001, 0x2000, "ADD.W D0,(A0)+ at odd addresses: byte + byte words, read-modify-write"),
    (0x30C0, 2, 0x3C001, 0x2000, "MOVE.W D0,(A0)+ at odd addresses: byte + byte words, written"),
]
# jsr: a call whose return-address push faults on the user stack's fresh
# page (the board's RTRACE, compile 68: #601 at $7FCFFE just before the
# Mac environment's address error).  The subroutine adds 1 to A2 and
# RTSes; A2 = 1 says it ran once - a frame that resumes after the call
# skips it - (call words, user stack pointer, invalid pages, what):
JSR = [
    ([0x4EBA], 0x32000, [0x31000], "JSR (d16,PC): the push wholly on the invalid page"),
    ([0x4EBA], 0x36002, [0x35000], "JSR (d16,PC): the push straddles, its high word on the invalid page (the board's $7FCFFE)"),
    ([0x6100], 0x3A000, [0x39000], "BSR.W: the push wholly on the invalid page"),
    ([0x6100], 0x3E002, [0x3D000], "BSR.W: the push straddles"),
    ("link", 0x2E000, [0x2D000], "LINK A6,#-8: the push wholly on the invalid page (A2 = A7 after it)"),
    ("link", 0x26002, [0x25000], "LINK A6,#-8: the push straddles"),
]
# bf: five-byte bit fields ({4:32} from (A0): bytes A0..A0+4) across a page
# boundary, both pages valid but write-protected (copy-on-write): the read
# succeeds, the long's write faults, then the fifth byte's - (opcode,
# A0, what):
BF = [
    (0xEFD0, 0x31FFC, "BFINS D0,(A0){4:32}: the long on one page, the fifth byte on the next"),
    (0xEAD0, 0x35FFC, "BFCHG (A0){4:32}: the same - not idempotent, so never re-executed over a written long"),
    (0xEFD0, 0x39FFD, "BFINS D0,(A0){4:32}: the long itself straddling"),
]
# bfx: the restart design's known limit (KNOWN ISSUES 21): BFCHG's long
# straddles into a write-protected page after its first beat has landed on a
# writable one; the restart inverts those bytes again.  A 68030 continues
# from the faulted beat.  Expected to FAIL until the kernel continues.
BFX = [
    (0xEAD0, 0x3DFFD, "BFCHG (A0){4:32}: the long itself straddling, its first beat writable"),
]
# ifetch: instruction-fetch page faults, as A/UX demand-pages code and its
# static shared libraries (the board, compile 71: telinit and macgetty
# jumped to address 0 right after calls into the shared C library's
# branch table at $47F0xxxx).  Each case's inline code (user mode) JSRs to
# code placed on pages invalid in the user tree; every path adds to A2,
# so a skipped or misdirected jump shows - (entry, {address: words}, A2
# wanted, invalid pages, what):
IFETCH = [
    (0x41000, {0x41000: [0x528A, 0x4E75]}, 1, [0x41000],
     "JSR into a non-resident page"),
    (0x42FFE, {0x42FFE: [0x4EF9, 0x0004, 0x4000], 0x44000: [0x528A, 0x4E75]}, 1, [0x43000, 0x44000],
     "JMP (xxx).L: the opcode a resident page's last word, its address on the next, non-resident page"),
    (0x45FFC, {0x45FFC: [0x4EF9, 0x0004, 0x7000], 0x47000: [0x528A, 0x4E75]}, 1, [0x46000, 0x47000],
     "JMP (xxx).L: the address straddling (high word resident, low word not)"),
    (0x48FFE, {0x48FFE: [0x4EB9, 0x0004, 0xA000, 0x528A, 0x4E75], 0x4A000: [0x528A, 0x4E75]}, 2, [0x49000, 0x4A000],
     "JSR (xxx).L straddling, the return onto the page it straddled"),
    (0x4BFF8, {0x4BFF8: [0x4E71, 0x4E71, 0x4E71, 0x4E71], 0x4C000: [0x528A, 0x4E75]}, 1, [0x4C000],
     "straight-line code running off a resident page into a non-resident one"),
    (0x4DFFC, {0x4DFFC: [0x263C, 0x1234, 0x5678, 0x0483, 0x1234, 0x5677, 0xD5C3, 0x4E75]}, 1, [0x4E000],
     "MOVE.L #imm,D3: the immediate's low word on a non-resident page"),
    (0x4F100, {0x4F100: [0x4EF9, 0x0005, 0x0200], 0x50200: [0x528A, 0x4E75]}, 1, [0x4F000, 0x50000],
     "a shared-library call: JSR to a branch-table JMP $target.l, table and target non-resident"),
    # KNOWN ISSUES 29 (A/UX xload, compile 80: SIGILL at $2E006 every run - the
    # last extension word of CMPI.L #$200,$C(A6) at $2E000, a page's first
    # instruction, after a BTST #3,abs.l / BNE.B (not taken) ending the page
    # before): lea $63000,a6; btst #3,$63000; bne.b; cmpi.l; ble.b; illegal; addq
    (0x63FF0, {0x63FF0: [0x4DF9, 0x0006, 0x3000, 0x0839, 0x0003, 0x0006, 0x3000, 0x660A],
               0x64000: [0x0CAE, 0x0000, 0x0200, 0x000C, 0x6F02, 0x4AFC, 0x528A, 0x4E75]}, 1, [0x64000],
     "xload: BNE.B not taken in a page's last word, CMPI.L #imm,d16(An) the next (non-resident) page's first"),
]
# isweep (KNOWN ISSUES 29, the class): an instruction-fetch page fault at the
# START of a non-resident page, reached from every kind of instruction that
# can end the resident page before it - plain ones of 1-3 words, Bcc.B/.W
# taken and not, BRA.B/.W, DBRA taken and expired, Scc, JMP (xxx).L and
# (d16,PC) - into a first instruction of 1-4 words, at the page's first word
# or (branches) its second.  The code runs in user mode from ISW_E, ends
# exactly at ISW_P, and must add 1 to A2 once; a word not an instruction
# start holds ILLEGAL.  One case a run: ISW=k (ISWLIST=1 lists them).
ISW_R, ISW_P = 0x65000, 0x66000                          # the resident page, the faulting page
ISW_PRE = [0x4DF9, 0x0006, 0x5000, 0x7601, 0x7000]       # lea $65000,a6; moveq #1,d3; moveq #0,d0 (Z=1 at the branch)
ISW_FIRST = [                                            # (words, what) - ADDQ.L #1,A2; RTS follow
    ([], "ADDQ.L #1,A2 (1 word)"),
    ([0x382E, 0x000C], "MOVE.W $C(A6),D4 (2 words)"),
    ([0x283C, 0x1234, 0x5678], "MOVE.L #imm,D4 (3 words)"),
    ([0x0CAE, 0x0000, 0x0200, 0x000C], "CMPI.L #imm,$C(A6) (4 words - xload's)"),
]


def isw_cases():
    out = []
    plain = [([0x4E71], "NOP"), ([0x4A40], "TST.W D0"), ([0x283C, 0x0000, 0x0001], "MOVE.L #imm,D4"),
             ([0x47F9, 0x0006, 0x5000], "LEA (xxx).L,A3"), ([0x57C5], "SEQ D5")]
    for pw, pn in plain:
        for fw, fn in ISW_FIRST:
            out.append((pw, None, 0, fw, pn + " -> " + fn))
    # multi-cycle and memory-reading last instructions (the Bcc.B lesson: one
    # that runs on after its decode cycle prefetched the next word)
    more = [([0xC8C3], "MULU.W D3,D4"), ([0x88FC, 0x0003], "DIVU.W #3,D4"), ([0xE18C], "LSL.L #8,D4"),
            ([0xE7BC], "ROL.L D3,D4"), ([0xE664], "ASR.W D3,D4"), ([0x4844], "SWAP D4"), ([0xC945], "EXG D4,D5"),
            ([0x48C4], "EXT.L D4"), ([0x4284], "CLR.L D4"), ([0x4484], "NEG.L D4"), ([0x0104], "BTST D0,D4"),
            ([0x3816], "MOVE.W (A6),D4"), ([0x281E], "MOVE.L (A6)+,D4"), ([0x528B], "ADDQ.L #1,A3"),
            ([0x0284, 0x00FF, 0x00FF], "ANDI.L #imm,D4"), ([0xC8FC, 0x0003], "MULU.W #3,D4"),
            ([0x4A96], "TST.L (A6)"), ([0x0C56, 0x1234], "CMPI.W #imm,(A6)"),
            ([0xCB04], "ABCD D4,D5"), ([0x8B04], "SBCD D4,D5"), ([0xDB84], "ADDX.L D4,D5"), ([0x4084], "NEGX.L D4"),
            ([0x4AC4], "TAS D4"), ([0x4684], "NOT.L D4"), ([0xB184], "EOR.L D0,D4"), ([0xE394], "ROXL.L #1,D4"),
            ([0x4884], "EXT.W D4"), ([0xB880], "CMP.L D0,D4"), ([0xD7C4], "ADDA.L D4,A3"), ([0x97C4], "SUBA.L D4,A3"),
            ([0x2646], "MOVEA.L A6,A3"), ([0xB7C6], "CMPA.L A6,A3"), ([0x47D6], "LEA (A6),A3"),
            ([0x4CD6, 0x0030], "MOVEM.L (A6),D4/D5"), ([0x090E, 0x0000], "MOVEP.W 0(A6),D4"),
            ([0xE9C4, 0x5008], "BFEXTU D4{0:8},D5"), ([0x4C03, 0x4004], "MULS.L D3,D4"),
            ([0x4C43, 0x4004], "DIVU.L D3,D4"), ([0x44FC, 0x0004], "MOVE #4,CCR"), ([0x4E5D], "UNLK A5 (after LINK)"),
            ([0x2C84], "MOVE.L D4,(A6)"), ([0x4256], "CLR.W (A6)"), ([0x5256], "ADDQ.W #1,(A6)"),
            ([0x3D44, 0x0020], "MOVE.W D4,$20(A6)"), ([0x2CC4], "MOVE.L D4,(A6)+"), ([0x4AD6], "TAS (A6)"),
            ([0x48D6, 0x0030], "MOVEM.L D4/D5,(A6)"), ([0x0956], "BCHG D4,(A6)"),
            ([0x4E75], "RTS (to the next page)")]
    for pw, pn in more:
        for fw, fn in (ISW_FIRST[0], ISW_FIRST[3]):
            out.append((pw, None, 0, fw, pn + " -> " + fn))
    # (words with the displacement to fill, kind, what): the branch is the page's last instruction
    nottaken = [([0x660A], "b8", "BNE.B not taken"), ([0x6600, 0], "w16", "BNE.W not taken"),
                ([0x51CB, 0], "dbx", "DBRA D3 expiring (D3 0)")]
    for pw, kind, pn in nottaken:
        for fw, fn in ISW_FIRST:
            out.append((pw, kind, 0, fw, pn + " -> " + fn))
    taken = [([0x6700], "b8", "BEQ.B taken"), ([0x6700, 0], "w16", "BEQ.W taken"),
             ([0x6000], "b8", "BRA.B"), ([0x6000, 0], "w16", "BRA.W"),
             ([0x51CB, 0], "dbt", "DBRA D3 taken (D3 1)"),
             ([0x4EF9, 0, 0], "abs", "JMP (xxx).L"), ([0x4EFA, 0], "w16", "JMP (d16,PC)")]
    for pw, kind, pn in taken:
        for off in (0, 2):
            if kind == "b8" and off == 0:
                continue                                 # Bcc.B cannot reach the next word (disp 0 = .W)
            for fw, fn in ISW_FIRST:
                out.append((pw, kind, off, fw, pn + " to the page's %s word -> %s" % ("first" if off == 0 else "second", fn)))
    # instructions whose own words cross into the non-resident page (KNOWN
    # ISSUES 22's side): (words, words on the resident page, what); a branch's
    # displacement is filled in by isw_build ("S" kind)
    straddle = [([0x0CAE, 0x0000, 0x0200, 0x000C], 1, "CMPI.L #imm,$C(A6)"),
                ([0x0CAE, 0x0000, 0x0200, 0x000C], 2, "CMPI.L #imm,$C(A6)"),
                ([0x0CAE, 0x0000, 0x0200, 0x000C], 3, "CMPI.L #imm,$C(A6)"),
                ([0x283C, 0x1234, 0x5678], 1, "MOVE.L #imm,D4"), ([0x283C, 0x1234, 0x5678], 2, "MOVE.L #imm,D4"),
                ([0x47F9, 0x0006, 0x5000], 1, "LEA (xxx).L,A3"), ([0x47F9, 0x0006, 0x5000], 2, "LEA (xxx).L,A3"),
                ([0x382E, 0x000C], 1, "MOVE.W $C(A6),D4"), ([0x4CD6, 0x0030], 1, "MOVEM.L (A6),D4/D5"),
                ([0xE9C4, 0x5008], 1, "BFEXTU D4{0:8},D5"), ([0x4C03, 0x4004], 1, "MULS.L D3,D4"),
                ([0x6600, None], 1, "BNE.W not taken"), ([0x6700, None], 1, "BEQ.W taken"),
                ([0x51CB, None], 1, "DBRA D3 expiring"),
                ([0x6000, None], 1, "BRA.W"), ([0x6100, None], 1, "BSR.W"), ([0x51CB, None, "T"], 1, "DBRA D3 taken"),
                ([0x67FF, None, None], 1, "BEQ.L taken"), ([0x67FF, None, None], 2, "BEQ.L taken"),
                # the paired isweep's case 196 (2026-10-19): the rest of the long-branch family
                ([0x60FF, None, None], 2, "BRA.L"), ([0x66FF, None, None], 2, "BNE.L not taken"),
                ([0x61FF, None, None], 1, "BSR.L"), ([0x61FF, None, None], 2, "BSR.L"),
                # MacX on the IIcx (2026-10-19, the branch trace): startmac's ADDA.W #$C,A7 at
                # $5FFE, its immediate on the faulting page, then MOVE.L (A7)+ x3 / RTS popped
                # garbage - A7 forms (the bench first moves A7 down by the amount) and An's
                ([0xDEFC, 0x000C], 1, "ADDA.W #imm,A7"), ([0xDFFC, 0x0000, 0x000C], 1, "ADDA.L #imm,A7"),
                ([0xDFFC, 0x0000, 0x000C], 2, "ADDA.L #imm,A7"), ([0x4FEF, 0x000C], 1, "LEA $C(A7),A7"),
                ([0xDDFC, 0x0000, 0x000C], 1, "ADDA.L #imm,A6"), ([0xDCFC, 0x000C], 1, "ADDA.W #imm,A6"),
                ([0x9EFC, 0xFFF4], 1, "SUBA.W #imm,A7"), ([0xD7FC, 0x0000, 0x000C], 1, "ADDA.L #imm,A3")]
    for ws, k, sn in straddle:
        out.append((ws, "S%d" % k, 0, [], "%s straddling (%d word%s resident)" % (sn, k, "" if k == 1 else "s")))
    return out


def isw_build_straddle(case):
    ws, kind, off, fw, what = case
    ws = list(ws)
    k = int(kind[1:])
    at = ISW_P - 2 * k                                   # the instruction's address
    after = at + 2 * len(ws)                             # where the ADDQ goes (on the next page)
    trap = ISW_R + 0x10
    pre = list(ISW_PRE)
    if ws[0] == 0x51CB:
        pre[3] = 0x7600                                  # moveq #0,d3: expires
    if ws[0] in (0xDEFC, 0xDFFC, 0x4FEF, 0x9EFC):
        pre = pre + [0x9EFC, 0x000C]                     # suba.w #12,a7: the straddling one moves A7 back up
    tail = [0x528A, 0x4E75, 0x4AFC]
    if len(ws) > 2 and ws[2] == "T":                     # DBRA taken: D3 1
        ws = ws[:2]
        after = at + 4
        pre[3] = 0x7601
    if ws[0] in (0x67FF, 0x60FF):                        # BEQ.L taken / BRA.L to the ADDQ
        d = (after - (at + 2)) & 0xFFFFFFFF
        ws[1], ws[2] = d >> 16, d & 0xFFFF
    elif ws[0] == 0x66FF:                                # BNE.L not taken (Z=1): the trap if it were
        d = (trap - (at + 2)) & 0xFFFFFFFF
        ws[1], ws[2] = d >> 16, d & 0xFFFF
    elif ws[0] == 0x61FF:                                # BSR.L to an RTS after the tail; it returns to the ADDQ
        d = (after + 4 - (at + 2)) & 0xFFFFFFFF
        ws[1], ws[2] = d >> 16, d & 0xFFFF
        tail = [0x528A, 0x4E75, 0x4E75]
    elif ws[1] is None:
        if ws[0] == 0x6100:                              # BSR.W to an RTS after the tail; it returns to the ADDQ
            dest = after + 4
            tail = [0x528A, 0x4E75, 0x4E75]
        elif ws[0] in (0x6700, 0x6000) or ws[0] == 0x51CB and pre[3] == 0x7601:
            dest = after                                 # taken to the ADDQ
        else:
            dest = trap                                  # never taken
        ws[1] = (dest - (at + 2)) & 0xFFFF
    code = pre + ws[:k]
    entry = ISW_P - 2 * len(code)
    return entry, {trap: [0x4AFC], entry: code, ISW_P: ws[k:] + tail}, what


def isw_build(case):
    if case[1] and str(case[1]).startswith("S"):
        return isw_build_straddle(case)
    pw, kind, off, fw, what = case
    pw = list(pw)
    br_at = ISW_P - 2 * len(pw)                          # the last instruction's address
    target = ISW_P + off
    trap = ISW_R + 0x10                                  # an ILLEGAL: where a not-taken branch points
    pre = list(ISW_PRE)
    taken = kind in ("abs", "dbt") or (kind in ("b8", "w16") and (pw[0] >> 8) in (0x60, 0x67, 0x4E))
    dest = target if taken else trap
    if kind == "dbx":
        pre[3] = 0x7600                                  # moveq #0,d3: the DBRA expires
    if kind == "b8":
        pw[0] = (pw[0] & 0xFF00) | ((dest - (br_at + 2)) & 0xFF)
    elif kind in ("w16", "dbt", "dbx"):
        pw[1] = (dest - (br_at + 2)) & 0xFFFF
    elif kind == "abs":
        pw[1], pw[2] = target >> 16, target & 0xFFFF
    if pw == [0x4E75]:
        pre = pre + [0x2F3C, ISW_P >> 16, ISW_P & 0xFFFF]   # MOVE.L #ISW_P,-(A7): the RTS returns there
    if pw == [0x4E5D]:
        pre = pre + [0x4E55, 0x0000]                     # LINK A5,#0 for the UNLK
    code = pre + pw
    entry = ISW_P - 2 * len(code)
    page_b = ([0x4AFC] if off else []) + fw + [0x528A, 0x4E75, 0x4AFC]
    return entry, {trap: [0x4AFC], entry: code, ISW_P: page_b}, what


# xsweep (KNOWN ISSUES 23's class, 2026-10-18): an instruction whose EXTENSION
# words straddle from a resident page into a non-resident one - an absolute
# address, a displacement, a full extension word, an immediate - for JMP/JSR
# in every addressing mode with an extension and for data instructions whose
# operand address is in the words that fault.  A 68030 takes the fetch fault
# before it computes the EA (UM 8.1.2), so the program's only user beats are
# its code, its operands and its stack: the bench's +UOK check (uok.hex)
# fails any other - a junk jump target or a stray operand read.  Each case
# also checks its result and adds 1 to A2.  Operands: XSW_A (high word $0006)
# or XSW_B (high word $0007, odd: a junk {0, high word} target is odd); the
# absolute short form uses XSW_W.  One case a run: XSW=k (XSWLIST=1 lists
# them); XSW_SANITY=1 plants a read of $00000004 (must fail).
XSW_A, XSW_B, XSW_W, XSW_PTR = 0x67100, 0x71100, 0x7100, 0x67200
XSW_VAL = {XSW_A: 0x11223344, XSW_B: 0x55667788, XSW_W: 0x99AABBCC}
XSW_D4 = 0xCAFEF00D                                      # D4 before (a store's value)
# PAIR (default on for isweep and xsweep, 2026-10-19 - KNOWN ISSUES 31 hid from
# the sweeps because they checked A2, A0, A1 and D1 only): each case runs twice,
# first with every page resident (the reference), then with the faulting page
# invalid; both start from the same registers (PAIR_INIT, USP $9000) and the
# same memory (the windows restored from a pristine copy), and each ends by
# dumping D0-D7/A0-A4/A6, A7 and the CCR (user mode) and the windows to
# PAIR_DUMP + $400 x run; the program compares the two dumps (slot PAIR_SLOT,
# the count of differing longs, wanted 0).  PAIR=0: the single faulting run;
# PAIR_SANITY=1 plants a difference in D7 (must fail).
PAIR_INIT, PAIR_DUMP, PAIR_PRIST, PAIR_SLOT = 0x6DF00, 0x6C000, 0x6E000, 0x3700
PAIR_STRIDE = 0x400                                      # one run's dump
if CASESET == "rsweep":                                  # its windows are bigger (rsweep below)
    PAIR_INIT, PAIR_DUMP, PAIR_PRIST, PAIR_STRIDE = 0x6FF00, 0x70000, 0x76000, 0x3000
PAIR_WIN = {"isweep": [(0x65000, 0x100)],
            "xsweep": [(0x65000, 0x100), (0x67100, 0x120), (0x71100, 0x20), (0x7100, 0x20)]}
XSW_OD = 0x10                                            # the memory-indirect forms' outer displacement


def xsw_cases():
    """(words, kind, operand, what): kind j = JMP to the operand, s = JSR,
    l = a long loaded into D4, w = a word loaded into D4, m = the long at
    the operand checked after, p = PEA (the stack's long), c = CMPI (Z), n =
    no result check (BTST), a = MOVEA into A3."""
    out = []
    for X in (XSW_A, XSW_B):
        h, l = X >> 16, X & 0xFFFF
        d6 = (X - ISW_R) & 0xFFFFFFFF                    # from A6
        v = XSW_VAL[X]
        nm = "A" if X == XSW_A else "B (odd high word)"
        out += [([0x4EF9, h, l], "j", X, "JMP (xxx).L, operand " + nm),
                ([0x4EB9, h, l], "s", X, "JSR (xxx).L, operand " + nm),
                ([0x4EF6, 0x0130, d6 >> 16, d6 & 0xFFFF], "j", X, "JMP (bd.L,A6,D0.W), operand " + nm),
                ([0x4EB6, 0x0130, d6 >> 16, d6 & 0xFFFF], "s", X, "JSR (bd.L,A6,D0.W), operand " + nm),
                ([0x4EF6, 0x0133, 0, XSW_PTR - ISW_R, 0, XSW_OD], "j", X, "JMP ([bd.L,A6,D0.W],od.L), operand " + nm),
                ([0x2839, h, l], "l", X, "MOVE.L (xxx).L,D4, operand " + nm),
                ([0x23C4, h, l], "m", X, "MOVE.L D4,(xxx).L, operand " + nm),
                ([0x23FC, 0x1357, 0x9BDF, h, l], "m", X, "MOVE.L #imm,(xxx).L, operand " + nm),
                ([0x0CB9, v >> 16, v & 0xFFFF, h, l], "c", X, "CMPI.L #imm,(xxx).L, operand " + nm),
                ([0x06B9, 0, 1, h, l], "m", X, "ADDI.L #1,(xxx).L, operand " + nm),
                ([0x42B9, h, l], "m", X, "CLR.L (xxx).L, operand " + nm),
                ([0x23F9, h, l, h, l + 8], "m", X + 8, "MOVE.L (xxx).L,(xxx).L, operands " + nm),
                ([0x0839, 0x0003, h, l], "n", X, "BTST #3,(xxx).L, operand " + nm),
                ([0x4CF9, 0x0030, h, l], "l", X, "MOVEM.L (xxx).L,D4/D5, operand " + nm),
                ([0xE9F9, 0x4000, h, l], "l", X, "BFEXTU (xxx).L{0:32},D4, operand " + nm),
                ([0x2679, h, l], "a", X, "MOVEA.L (xxx).L,A3, operand " + nm),
                ([0x4879, h, l], "p", X, "PEA (xxx).L, operand " + nm),
                ([0x2836, 0x0130, d6 >> 16, d6 & 0xFFFF], "l", X, "MOVE.L (bd.L,A6,D0.W),D4, operand " + nm),
                ([0x2836, 0x0133, 0, XSW_PTR - ISW_R, 0, XSW_OD], "l", X, "MOVE.L ([bd.L,A6,D0.W],od.L),D4, operand " + nm)]
    dA = XSW_A - ISW_R
    out += [([0x4EF8, XSW_W], "j", XSW_W, "JMP (xxx).W"), ([0x4EB8, XSW_W], "s", XSW_W, "JSR (xxx).W"),
            ([0x3838, XSW_W], "w", XSW_W, "MOVE.W (xxx).W,D4"),
            ([0x4EEE, dA], "j", XSW_A, "JMP (d16,A6)"), ([0x4EAE, dA], "s", XSW_A, "JSR (d16,A6)"),
            ([0x282E, dA], "l", XSW_A, "MOVE.L (d16,A6),D4"),
            ([0x4EFA, None], "j", XSW_A, "JMP (d16,PC)"), ([0x4EBA, None], "s", XSW_A, "JSR (d16,PC)"),
            ([0x283A, None], "l", XSW_A, "MOVE.L (d16,PC),D4"),
            ([0x4EF6, 0x0040], "j", ISW_R + 0x40, "JMP (d8,A6,D0.W)"),
            ([0x4EFB, 0x0040], "j", None, "JMP (d8,PC,D0.W)")]
    cases = []
    for ws, kind, X, what in out:
        for k in range(1, len(ws)):
            cases.append((ws, kind, X, k, "%s straddling (%d word%s resident)" % (what, k, "" if k == 1 else "s")))
    return cases


def xsw_build(case):
    ws, kind, X, k, what = case
    ws = list(ws)
    at = ISW_P - 2 * k                                   # the instruction's address
    pre = list(ISW_PRE) + [0x283C, XSW_D4 >> 16, XSW_D4 & 0xFFFF]   # move.l #$CAFEF00D,d4
    if os.environ.get("XSW_SANITY") == "1":
        pre += [0x4AB9, 0x0000, 0x0004]                  # tst.l $4: a beat the check must catch
    if ws[1] is None:                                    # (d16,PC): from the extension word
        ws[1] = (X - (at + 2)) & 0xFFFF
    if X is None:                                        # (d8,PC,D0.W): the target beside the extension word
        X = at + 2 + 0x40
    vals = dict(XSW_VAL)
    ind = X if X in (XSW_A, XSW_B) else XSW_A            # the memory-indirect pointer: operand - od
    put = {XSW_PTR: [((ind - XSW_OD) >> 16) & 0xFFFF, (ind - XSW_OD) & 0xFFFF]}
    for a_, v in vals.items():
        put[a_] = [v >> 16, v & 0xFFFF]
    ok = [0x528A, 0x4E75]                                # addq.l #1,a2; rts

    def chk_m(a_, v):                                    # cmpi.l #v,(a_).l; bne.s; ok
        return [0x0CB9, v >> 16, v & 0xFFFF, a_ >> 16, a_ & 0xFFFF, 0x6602] + ok
    if kind == "j":
        tail = [0x4AFC]
        put[X] = ok
    elif kind == "s":
        tail = [0x4E75]                                  # the subroutine adds; back here, return
        put[X] = ok
    elif kind == "l":
        tail = [0x0C84, vals[X] >> 16, vals[X] & 0xFFFF, 0x6602] + ok   # cmpi.l #v,d4
    elif kind == "w":
        tail = [0x0C44, vals[X] >> 16, 0x6602] + ok      # cmpi.w #v,d4
    elif kind == "a":
        tail = [0xB7FC, vals[X] >> 16, vals[X] & 0xFFFF, 0x6602] + ok   # cmpa.l #v,a3
    elif kind == "p":
        tail = [0x0C9F, X >> 16, X & 0xFFFF, 0x6602] + ok               # cmpi.l #X,(a7)+
    elif kind == "c":
        tail = [0x6602] + ok                             # Z from the CMPI
    elif kind == "n":
        tail = ok
    else:                                                # m: the long at X after
        want = {0x23C4: XSW_D4, 0x23FC: 0x13579BDF, 0x06B9: vals.get(X, 0) + 1, 0x42B9: 0,
                0x23F9: vals.get(X - 8, 0)}[ws[0]]
        tail = chk_m(X, want)
    code = pre + ws[:k]
    entry = ISW_P - 2 * len(code)
    blobs = {ISW_R + 0x10: [0x4AFC], entry: code, ISW_P: ws[k:] + tail}
    for a_, ws_ in put.items():
        blobs.setdefault(a_, ws_)
    return entry, blobs, what


def uok_ranges():
    """The user beats a case may make (the bench's +UOK check): the inline
    program, the case's code pages and the operand pages, the user stack."""
    return [(ORG, BERR), (ISW_R, ISW_P + 0x2000), (XSW_B & ~0xFFF, (XSW_B & ~0xFFF) + 0x1000),
            (XSW_W & ~0xFFF, (XSW_W & ~0xFFF) + 0x1000), (0x8000, 0x9000)]


# rsweep (scan 2 of the second round, 2026-10-19 - "fault transparency"): a
# random user-mode program (RSW=seed) of ~700 instructions from a broad mix -
# register arithmetic, logic, shifts, BCD/X arithmetic, bit operations, Scc,
# every memory EA ((An), (An)+, -(An), d16(An), d8(An,A4.W) with A4 = 0,
# (xxx).L) for MOVE, ADD/SUB/AND/OR both ways, ADDQ/SUBQ, NEG/NOT/CLR/TST,
# memory shifts, bit ops, MOVEM, MOVEP, bit fields, CAS, TAS, CMPM, ADDX
# -(An); balanced stack traffic incl. A7 arithmetic, LINK/UNLK, PEA; forward
# Bcc, DBRA loops, a BSR to a local stub - its code across the page
# boundaries $65000 and $66000, its data across $6A000.  Run twice (PAIR):
# all resident, then with a random set of code, data and stack pages
# invalid or write-protected; registers, CCR, the data pages and the stack
# compared.  A memory instruction's pointer is set by a LEA (xxx).L just
# before it, so a wrong pointer cannot drift.  RSWLIST=n lists n seeds.
RSW_CODE, RSW_DATA, RSW_DLEN, RSW_STK = 0x64C00, 0x69000, 0x2000, 0x8C00
PAIR_WIN["rsweep"] = [(RSW_DATA, RSW_DLEN), (RSW_STK, 0x3FC)]   # (not $8FFC: the harness's JSR return address, a different caller per run)
RSW_SUPER = os.environ.get("RSW_SUPER") == "1"      # the third round's scan 1: the program in supervisor mode, MOVES the faulting accesses
if RSW_SUPER:                                        # the supervisor stack carries the fault and interrupt frames below SP, so only the data is compared
    PAIR_WIN["rsweep"] = [(RSW_DATA, RSW_DLEN)]
# RSW_UM=1 (the third round's scan 3, default on; TCMODE=aux): the user tree's
# page descriptors for the program's pages are in the compare too - the
# walker's U (bit 3) and M (bit 4) write-back (UM 9.5.3) must leave the same
# bits whether a page was resident from the start or made resident by the
# handler (which touches DT and WP only): U on every touched page, M on every
# written one.  The windows are restored from their pristine copies BEFORE the
# case's pages are made invalid.  PAIR_SANITY=2 clears page $69000's U after
# the faulting run (must FAIL).
RSW_UM = os.environ.get("RSW_UM", "1") == "1" and TCMODE == "aux"
if RSW_UM and CASESET == "rsweep":
    PAIR_WIN["rsweep"] += [(PG_TBL + 4 * 0x64, 4 * 7), (PG_TBL + 4 * 0x8, 4)]   # pages $64000-$6A000 and $8000


def rsw_build(seed):
    rnd = random.Random(seed)
    w = []
    sz = lambda: rnd.randrange(3)                        # 0 B, 1 W, 2 L
    dn = lambda: rnd.randrange(7)                        # D0-D6 (D7 is the loops')
    def ptr_off(span):                                   # an offset in the data, often near the page boundary
        if rnd.random() < 0.5:
            o = 0x1000 + rnd.randrange(-12, 9)
        else:
            o = rnd.randrange(64, RSW_DLEN - 64 - span)
        return o
    def lea(an, addr):                                   # LEA addr.L,An
        w.extend([0x41F9 | an << 9, addr >> 16, addr & 0xFFFF])
    def mem_ea(span=4, modes=(2, 3, 4, 5, 6, 7)):
        """A memory EA: (ea field, extension words), its pointer set up first."""
        an = rnd.choice((0, 1, 2, 3, 6))
        m = rnd.choice(modes)
        o = ptr_off(span)
        if m == 7:
            a_ = RSW_DATA + o
            return 0x39, [a_ >> 16, a_ & 0xFFFF]
        lea(an, RSW_DATA + o + (span if m == 4 else 0))
        if m == 5:
            return 0x28 | an, [rnd.randrange(-16, 17) & 0xFFFF]
        if m == 6:
            return 0x30 | an, [0xC000 | (rnd.randrange(-16, 17) & 0xFF)]   # d8(An,A4.W), A4 = 0
        return (m << 3) | an, []
    def ctl_ea(span=5):                                  # control modes only (bit fields, MOVEM to memory)
        return mem_ea(span, (2, 5, 7))
    MOVE_SZ = (1, 3, 2)
    ops = []
    def op(f, wt=1):
        ops.append((f, wt))
    # register forms
    op(lambda: w.append(0x7000 | dn() << 9 | rnd.randrange(256)), 3)                                      # MOVEQ
    op(lambda: w.append(rnd.choice((0xD000, 0x9000, 0xC000, 0x8000)) | dn() << 9 | sz() << 6 | dn()), 4) # ADD/SUB/AND/OR Dm,Dn
    op(lambda: w.append(0xB000 | dn() << 9 | (4 + sz()) << 6 | dn()))                                    # EOR
    op(lambda: w.append(0xB000 | dn() << 9 | sz() << 6 | dn()))                                          # CMP
    op(lambda: w.append(rnd.choice((0x5000, 0x5100)) | (rnd.randrange(8)) << 9 | sz() << 6 | dn()), 2)   # ADDQ/SUBQ
    op(lambda: w.append(rnd.choice((0x4400, 0x4600, 0x4200, 0x4A00, 0x4000)) | sz() << 6 | dn()))        # NEG/NOT/CLR/TST/NEGX
    op(lambda: w.append(rnd.choice((0x4880, 0x48C0, 0x4840)) | dn()))                                   # EXT.W/L, SWAP
    op(lambda: w.append(0xE000 | rnd.randrange(8) << 9 | rnd.randrange(2) << 8 | sz() << 6 | rnd.randrange(4) << 3 | dn()), 2)  # shifts #
    op(lambda: w.append(rnd.choice((0xC0C0, 0xC1C0)) | dn() << 9 | dn()))                                # MULU/MULS.W
    op(lambda: w.append(rnd.choice((0xD100, 0x9100)) | dn() << 9 | sz() << 6 | dn()))                    # ADDX/SUBX Dn
    op(lambda: w.append(rnd.choice((0xC100, 0x8100)) | dn() << 9 | dn()))                                # ABCD/SBCD Dn
    op(lambda: w.append(0x50C0 | rnd.randrange(16) << 8 | dn()))                                         # Scc
    op(lambda: w.append(0x0100 | dn() << 9 | rnd.randrange(4) << 6 | dn()))                              # BTST/BCHG/BCLR/BSET Dm,Dn
    op(lambda: w.extend([0x44FC, rnd.randrange(32)]))                                                    # MOVE #,CCR
    # memory forms
    def mv_to():
        s_ = sz(); e, x = mem_ea(4)
        w.extend([MOVE_SZ[s_] << 12 | (e & 7) << 9 | (e >> 3) << 6 | dn()] + x)
    def mv_from():
        s_ = sz(); e, x = mem_ea(4)
        w.extend([MOVE_SZ[s_] << 12 | dn() << 9 | e] + x)
    def mv_mm():
        s_ = sz(); e1, x1 = mem_ea(4, (2, 3, 4, 5)); e2, x2 = mem_ea(4, (2, 3, 4, 5, 7))
        w.extend([MOVE_SZ[s_] << 12 | (e2 & 7) << 9 | (e2 >> 3) << 6 | e1] + x1 + x2)
    def alu_mem():
        e, x = mem_ea(4); w.extend([rnd.choice((0xD000, 0x9000, 0xC000, 0x8000)) | dn() << 9 | (rnd.randrange(2) * 4 + sz()) << 6 | e] + x)
    def q_mem():
        e, x = mem_ea(4); w.extend([rnd.choice((0x5000, 0x5100)) | rnd.randrange(8) << 9 | sz() << 6 | e] + x)
    def u_mem():
        e, x = mem_ea(4); w.extend([rnd.choice((0x4400, 0x4600, 0x4200, 0x4A00, 0x4000)) | sz() << 6 | e] + x)
    def sh_mem():
        e, x = mem_ea(2); w.extend([0xE0C0 | rnd.randrange(4) << 9 | rnd.randrange(2) << 8 | e] + x)
    def bit_mem():
        e, x = mem_ea(1); w.extend([0x0800 | rnd.randrange(4) << 6 | e, rnd.randrange(8)] + x)
    def movem():
        lst = rnd.randrange(1, 128)                          # D0-D6
        if rnd.random() < 0.5:                               # registers to memory
            if rnd.random() < 0.5:
                an = rnd.choice((0, 1, 2, 3)); lea(an, RSW_DATA + ptr_off(0) + 32)
                rev = int('{:016b}'.format(lst)[::-1], 2)    # -(An): D0 = bit 15
                w.extend([0x48E0 | an, rev])
            else:
                e, x = ctl_ea(28); w.extend([0x48C0 | e, lst] + x)
        else:
            e, x = mem_ea(28, (2, 3, 5, 7)); w.extend([0x4CC0 | e, lst] + x)
    def movep():
        an = rnd.choice((0, 1, 2, 3)); lea(an, RSW_DATA + ptr_off(8))
        w.extend([0x0108 | dn() << 9 | rnd.randrange(4) << 6 | an, rnd.randrange(8)])
    def bitfield():
        e, x = ctl_ea(5)
        t = rnd.randrange(8)                                 # TST EXTU CHG EXTS CLR FFO SET INS
        ext = dn() << 12 | rnd.randrange(8) << 6 | rnd.randrange(32)
        w.extend([0xE8C0 | t << 8 | e, ext] + x)
    def cas():
        e, x = mem_ea(4, (2, 5, 7)); s_ = sz()
        w.extend([0x08C0 | (s_ + 1) << 9 | e, dn() << 6 | dn()] + x)
    def tas():
        e, x = mem_ea(1); w.extend([0x4AC0 | e] + x)
    def cmpm():
        a1, a2 = rnd.sample((0, 1, 2, 3), 2)
        lea(a1, RSW_DATA + ptr_off(8)); lea(a2, RSW_DATA + ptr_off(8))
        w.append(0xB108 | a1 << 9 | sz() << 6 | a2)
    def addx_m():
        a1, a2 = rnd.sample((0, 1, 2, 3), 2)
        lea(a1, RSW_DATA + ptr_off(8) + 8); lea(a2, RSW_DATA + ptr_off(8) + 8)
        o_ = rnd.choice((0xD108, 0x9108, 0xC108, 0x8108))           # ADDX/SUBX -(An) any size; ABCD/SBCD bytes only
        w.append(o_ | a1 << 9 | ((sz() << 6) if o_ in (0xD108, 0x9108) else 0) | a2)
    # the stack (balanced)
    def stack():
        k = rnd.randrange(5)
        if k == 0:
            w.extend([0x2F00 | dn(), 0x201F | dn() << 9])                    # MOVE.L Dn,-(A7); MOVE.L (A7)+,Dm
        elif k == 1:
            n = rnd.randrange(1, 9) * 2
            w.extend([0x9EFC, n, 0xDEFC, n])                                  # SUBA.W #n,A7; ADDA.W #n,A7
        elif k == 2:
            w.extend([0x4FEF, 0xFFF0, 0x4FEF, 0x0010])                         # LEA -16(A7),A7; LEA 16(A7),A7
        elif k == 3:
            w.extend([0x4E53, 0xFFF8, 0x4E5B])                                 # LINK A3,#-8; UNLK A3
        else:
            a_ = RSW_DATA + ptr_off(4)
            w.extend([0x4879, a_ >> 16, a_ & 0xFFFF, 0x201F | dn() << 9])      # PEA (xxx).L; MOVE.L (A7)+,Dn
    # control flow
    def bcc():
        w.extend([0x6002 | rnd.randrange(2, 16) << 8, 0x7000 | dn() << 9 | rnd.randrange(256)])   # Bcc.S over a MOVEQ
    def dbra():
        w.extend([0x7E00 | rnd.randrange(1, 4), 0x5280 | dn(), 0x51CF, 0xFFFC])   # MOVEQ #n,D7; L: ADDQ.L #1,Dm; DBRA D7,L
    def bsr():
        w.extend([0x6004, 0x5280 | dn(), 0x4E75, 0x6100, 0xFFFA])               # BRA.S +4; stub: ADDQ; RTS; BSR.W stub
    # RSW_SUPER=1 (the third round's scan 1): the program runs in SUPERVISOR
    # mode, so its ordinary accesses walk the resident supervisor tree and only
    # these fault - MOVES through SFC = DFC = 1, every size, both directions,
    # Dn or An (not A4, the zero index; not bytes into An), the kernel's
    # copyin/copyout/uclear/sendsig shapes among random kernel work
    def moves():
        s_ = sz(); e, x = mem_ea(4)
        an = s_ and rnd.random() < 0.3
        r = (0x8000 | rnd.choice((0, 1, 2, 3, 6)) << 12) if an else dn() << 12
        w.extend([0x0E00 | s_ << 6 | e, r | rnd.randrange(2) << 11] + x)
    for f, wt in ((mv_to, 4), (mv_from, 4), (mv_mm, 2), (alu_mem, 3), (q_mem, 2), (u_mem, 2), (sh_mem, 1),
                  (bit_mem, 1), (movem, 2), (movep, 1), (bitfield, 2), (cas, 1), (tas, 1), (cmpm, 1), (addx_m, 1),
                  (stack, 3), (bcc, 2), (dbra, 1), (bsr, 1)) + (((moves, 8),) if RSW_SUPER else ()):
        op(f, wt)
    total = sum(wt for _, wt in ops)
    w.append(0x99CC)                                         # SUBA.L A4,A4: the index register is 0
    while 2 * len(w) < 0x2000 - 0x60:                        # ~8 KB: across $65000 and $66000
        r = rnd.randrange(total)
        for f, wt in ops:
            if r < wt:
                f(); break
            r -= wt
    w.append(0x4E75)                                         # RTS (to the harness's JSR)
    data = bytes(rnd.randrange(256) for _ in range(RSW_DLEN))
    # the faulting run's pages: code, data, stack - invalid or write-protected
    pages, wp = [], []
    for pg in (0x64000, 0x65000, 0x66000):
        if rnd.random() < 0.6:
            pages.append(pg)
    for pg in (0x69000, 0x6A000, 0x8000):
        r_ = rnd.random()
        if r_ < 0.45:
            pages.append(pg)
        elif r_ < 0.8:
            pages.append(pg); wp.append(pg)
    if not pages:
        pages.append(0x65000)
    return w, data, pages, wp

# dsweep (the data side of KNOWN ISSUES 29's class; MacX's colour start-up on
# the IIcx, 2026-10-18): an instruction's MEMORY operand on a page that is not
# resident.  Each case runs one instruction twice in user mode with the same
# registers (INIT) and the same bytes: first on resident pages at DSW_RB (the
# reference, no fault), then with its operand at DSW_P + off, the page at DSW_P
# invalid (a fault, the pager handler, RTE).  The program compares the two -
# D0-D7/A0-A4, A5 and A6 relative to their bases, the CCR, 64 bytes around the
# operand - and sets A2 1 (equal) or 2 (different).  One case a run: DSW=k
# (DSWLIST=1 lists them).  A5 = A6 + 8 for every case (the second operand of
# the memory-to-memory forms).
DSW_CODE, DSW_P, DSW_RB = 0x60000, 0x68000, 0x6B000
DSW_OUT1, DSW_OUT2, DSW_INIT, DSW_RES = 0x6C000, 0x6C100, 0x6C200, 0x6C300
DSW_INITV = [13, 25, 0x2468ACE1, 0x13579BDF, 0x89ABCDEF, 0x01234567, 0x7FFF0003, 0x80000005,   # D0 (bit offset) D1 (width) D2-D7
             0x6C400, 0x6C440, 0x6C480, 0x6C4C0, 0x6C500, 0x6C540]                            # A0-A5
# (words, A6 = operand start + adj, footprint start (from the operand start), footprint length, what)
DSW_INSN = [
    ([0x4A16], 0, 0, 1, "TST.B (A6)"), ([0x4A56], 0, 0, 2, "TST.W (A6)"), ([0x4A96], 0, 0, 4, "TST.L (A6)"),
    ([0x1816], 0, 0, 1, "MOVE.B (A6),D4"), ([0x3816], 0, 0, 2, "MOVE.W (A6),D4"), ([0x2816], 0, 0, 4, "MOVE.L (A6),D4"),
    ([0xD896], 0, 0, 4, "ADD.L (A6),D4"), ([0xB856], 0, 0, 2, "CMP.W (A6),D4"),
    ([0xC8D6], 0, 0, 2, "MULU.W (A6),D4"), ([0x88D6], 0, 0, 2, "DIVU.W (A6),D4"), ([0x89D6], 0, 0, 2, "DIVS.W (A6),D4"),
    ([0x0116], 0, 0, 1, "BTST D0,(A6)"),
    ([0x4CD6, 0x00F0], 0, 0, 16, "MOVEM.L (A6),D4-D7"), ([0x094E, 0x0000], 0, 0, 7, "MOVEP.L 0(A6),D4"),
    ([0x281E], 0, 0, 4, "MOVE.L (A6)+,D4"), ([0x2826], 4, 0, 4, "MOVE.L -(A6),D4"),
    ([0x04D6, 0x4000], 0, 0, 8, "CMP2.L (A6),D4"),
    ([0x4C16, 0x4000], 0, 0, 4, "MULU.L (A6),D4"), ([0x4C16, 0x4C05], 0, 0, 4, "MULS.L (A6),D5:D4"),
    ([0x4C56, 0x4004], 0, 0, 4, "DIVU.L (A6),D4"), ([0x4C56, 0x4C05], 0, 0, 4, "DIVS.L (A6),D5:D4"),
    ([0xE9D6, 0x40D4], 0, 0, 3, "BFEXTU (A6){3:20},D4"), ([0xEBD6, 0x40D4], 0, 0, 3, "BFEXTS (A6){3:20},D4"),
    ([0xE9D6, 0x4821], 0, 1, 4, "BFEXTU (A6){D0:D1},D4"), ([0xEDD6, 0x4000], 0, 0, 4, "BFFFO (A6){0:32},D4"),
    ([0xE8D6, 0x01DC], 0, 0, 5, "BFTST (A6){7:28}"),
    ([0x1C84], 0, 0, 1, "MOVE.B D4,(A6)"), ([0x3C84], 0, 0, 2, "MOVE.W D4,(A6)"), ([0x2C84], 0, 0, 4, "MOVE.L D4,(A6)"),
    ([0x4216], 0, 0, 1, "CLR.B (A6)"), ([0x4296], 0, 0, 4, "CLR.L (A6)"),
    ([0x2CC4], 0, 0, 4, "MOVE.L D4,(A6)+"), ([0x2D04], 4, 0, 4, "MOVE.L D4,-(A6)"),
    ([0x48D6, 0x00F0], 0, 0, 16, "MOVEM.L D4-D7,(A6)"), ([0x09CE, 0x0000], 0, 0, 7, "MOVEP.L D4,0(A6)"),
    ([0x2D56, 0x0004], 0, 0, 8, "MOVE.L (A6),4(A6)"), ([0x3CAE, 0x0002], 0, 0, 4, "MOVE.W 2(A6),(A6)"),
    ([0xD996], 0, 0, 4, "ADD.L D4,(A6)"), ([0x5656], 0, 0, 2, "ADDQ.W #3,(A6)"), ([0x4496], 0, 0, 4, "NEG.L (A6)"),
    ([0x4656], 0, 0, 2, "NOT.W (A6)"), ([0xE1D6], 0, 0, 2, "ASL.W (A6)"), ([0xE4D6], 0, 0, 2, "ROXR.W (A6)"),
    ([0x01D6], 0, 0, 1, "BSET D0,(A6)"), ([0x0196], 0, 0, 1, "BCLR D0,(A6)"), ([0x0156], 0, 0, 1, "BCHG D0,(A6)"),
    ([0x08D6, 0x0009], 0, 0, 1, "BSET #9,(A6)"), ([0x4AD6], 0, 0, 1, "TAS (A6)"),
    ([0xEFD6, 0x4154], 0, 0, 4, "BFINS D4,(A6){5:20}"), ([0xEED6, 0x01DC], 0, 0, 5, "BFSET (A6){7:28}"),
    ([0xECD6, 0x01DC], 0, 0, 5, "BFCLR (A6){7:28}"), ([0xEAD6, 0x01DC], 0, 0, 5, "BFCHG (A6){7:28}"),
    ([0xEAD6, 0x0821], 0, 1, 4, "BFCHG (A6){D0:D1}"),
    ([0x0ED6, 0x0144], 0, 0, 4, "CAS.L D4,D5,(A6)"), ([0x0CD6, 0x0144], 0, 0, 2, "CAS.W D4,D5,(A6)"),
    ([0x0AD6, 0x0144], 0, 0, 1, "CAS.B D4,D5,(A6)"),
    ([0xDB8E], 4, 0, 12, "ADDX.L -(A6),-(A5)"), ([0xCB0E], 1, 0, 9, "ABCD -(A6),-(A5)"),
    ([0x8B0E], 1, 0, 9, "SBCD -(A6),-(A5)"), ([0x8B4E, 0x1234], 2, 0, 9, "PACK -(A6),-(A5),#$1234"),
    ([0x8B8E, 0x1234], 1, 0, 9, "UNPK -(A6),-(A5),#$1234"), ([0xBB8E], 0, 0, 12, "CMPM.L (A6)+,(A5)+"),
    # A7 as the destination (MacX, 2026-10-19: the restart's second rollback kept a faulted
    # instruction's late A7 write): A7 saved in A4, the instruction, A7 to D6, A7 back
    ([0x284F, 0x2E56, 0x2C0F, 0x2E4C], 0, 0, 4, "MOVEA.L (A6),A7 (A7 via D6)"),
    ([0x284F, 0x3E56, 0x2C0F, 0x2E4C], 0, 0, 2, "MOVEA.W (A6),A7 (A7 via D6)"),
    ([0x284F, 0xDFD6, 0x2C0F, 0x2E4C], 0, 0, 4, "ADDA.L (A6),A7 (A7 via D6)"),
    ([0x284F, 0x9FD6, 0x2C0F, 0x2E4C], 0, 0, 4, "SUBA.L (A6),A7 (A7 via D6)"),
    ([0x284F, 0xDED6, 0x2C0F, 0x2E4C], 0, 0, 2, "ADDA.W (A6),A7 (A7 via D6)"),
]
DSW_OFFS = [0, -1, -2, -3, -4, -6]
# DSW_WP=1 (scan 2, 2026-10-18: copy-on-write, as A/UX's fork leaves pages):
# the page at DSW_P VALID but write-protected instead of invalid - the reads
# succeed, a write faults, and a straddling operand's first part may already
# have landed on the writable page below when its second part faults; the
# restart must not apply the operation twice (KNOWN ISSUES 21 is that limit
# for BFCHG and CAS2).  Only the instructions that write, and these more
# read-modify-write forms (handler entries are not counted: a write wholly
# below the page never faults).
DSW_WPX = [
    ([0x5696], 0, 0, 4, "ADDQ.L #3,(A6)"), ([0x5796], 0, 0, 4, "SUBQ.L #3,(A6)"),
    ([0xD956], 0, 0, 2, "ADD.W D4,(A6)"), ([0x8996], 0, 0, 4, "OR.L D4,(A6)"),
    ([0xC996], 0, 0, 4, "AND.L D4,(A6)"), ([0xB996], 0, 0, 4, "EOR.L D4,(A6)"),
    ([0x4096], 0, 0, 4, "NEGX.L (A6)"), ([0x4696], 0, 0, 4, "NOT.L (A6)"), ([0x4816], 0, 0, 1, "NBCD (A6)"),
    ([0x0696, 0x1234, 0x5678], 0, 0, 4, "ADDI.L #imm,(A6)"), ([0x0496, 0x1234, 0x5678], 0, 0, 4, "SUBI.L #imm,(A6)"),
    ([0x0A96, 0x5A5A, 0xA5A5], 0, 0, 4, "EORI.L #imm,(A6)"), ([0x57D6], 0, 0, 1, "SEQ (A6)"),
    ([0xE2D6], 0, 0, 2, "LSR.W (A6)"), ([0xE7D6], 0, 0, 2, "ROL.W (A6)"),
    ([0x2D16], 0, 0, 4, "MOVE.L (A6),-(A6)"), ([0x48E6, 0x0F00], 16, 0, 16, "MOVEM.L D4-D7,-(A6)"),
    ([0x0CFC, 0xE144, 0xD144], 0, 0, 10, "CAS2.W D4:D4,D5:D5,(A6):(A5) (A5 = A6 + 8)"),
    # (KNOWN ISSUES 21's CAS2 case: the compares made to succeed, so both writes happen)
    ([0x3816, 0x3C15, 0x0CFC, 0xE144, 0xD1C6], 0, 0, 10, "MOVE.W (A6),D4; MOVE.W (A5),D6; CAS2.W D4:D6,D5:D7,(A6):(A5)"),
    ([0x2816, 0x2C15, 0x0EFC, 0xE144, 0xD1C6], 0, 0, 12, "MOVE.L (A6),D4; MOVE.L (A5),D6; CAS2.L D4:D6,D5:D7,(A6):(A5)"),
    ([0x4E56, 0xFFF8], 0, 0, 0, "(no memory: LINK on the stack - a control)"),
]
DSW_WP = os.environ.get("DSW_WP") == "1"

# ssweep (the third round's scan 1, 2026-10-20: SUPERVISOR-side faults): A/UX's
# kernel touches user pages with MOVES - copyin $554F0, copyout $556F0, uclear
# $557D0 (MOVES.L -(An)), sendsig's signal frame, the exec loader - and the
# bench had four directed MOVES.L cases.  Every MOVES form: byte, word and
# long, memory to Dn and to An (An: the word sign-extended, uclear's source
# register) and register to memory, through (A6), (A6)+, -(A6), (d16,A6) and
# (d8,A6,D0.W) (D0 = 13, d8 = -13: the operand at A6), the operand straddling
# the page top at DSW_OFFS.  dsweep's pair pattern, run in supervisor mode with
# SFC = DFC = 1 (set at the program's start), the page invalid or (SSW_WP=1,
# the writes only: write() into a forked child's copy-on-write page) write-
# protected in the USER tree.  One case a run: SSW=k (SSWLIST=1 lists them).
SSW_WP = os.environ.get("SSW_WP") == "1"


def ssw_insns():
    out = []
    eas = [(0x16, [], 0, "(A6)"), (0x1E, [], 0, "(A6)+"), (0x26, [], None, "-(A6)"),
           (0x2E, [0x0000], 0, "0(A6)"), (0x36, [0x00F3], 0, "-13(A6,D0.W)")]
    for sz, sn, sl in ((0, "B", 1), (1, "W", 2), (2, "L", 4)):
        for ea, ext, adj, en in eas:
            a = sl if adj is None else adj
            for rn, rbit, rname in ((4, 0, "D4"), (4, 1, "A4")):
                if rbit and sz == 0:
                    continue                                 # MOVES.B An: not a form the kernel uses
                r = rbit << 15 | rn << 12
                out.append(([0x0E00 | sz << 6 | ea, r] + ext, a, 0, sl, "MOVES.%s %s,%s" % (sn, en, rname)))
                out.append(([0x0E00 | sz << 6 | ea, r | 0x0800] + ext, a, 0, sl, "MOVES.%s %s,%s" % (sn, rname, en)))
    return out


def ssw_cases():
    out = []
    for ws, adj, fs, fl, what in ssw_insns():
        if SSW_WP and not (ws[1] & 0x0800):
            continue                                         # write-protected: the writes only
        for off in DSW_OFFS:
            lo, hi = off + fs, off + fs + fl
            if hi <= 0 or lo < -32 or hi > 32:
                continue
            out.append((ws, adj, off, what + (" at P%+d" % off)))
    return out


def dsw_cases():
    out = []
    insns = DSW_INSN
    if DSW_WP:
        first = [x[4] for x in DSW_INSN].index("MOVE.B D4,(A6)")
        insns = [x for x in DSW_INSN[first:] if not x[4].startswith("CMPM")] + DSW_WPX[:-1]
    for ws, adj, fs, fl, what in insns:
        for off in DSW_OFFS:
            lo = off + fs
            hi = lo + fl
            if hi <= 0 or lo < -32 or hi > 32:
                continue                                 # the page not touched, or outside the compared window
            out.append((ws, adj, off, what + (" at P%+d" % off)))
    return out


def dsw_build(case):
    """The case's code at DSW_CODE: save everything, the reference run, the
    faulting run, the comparison, the result to A2 (via DSW_RES)."""
    ws, adj, off, what = case
    w, lab, fix = [], {}, []
    def here(): return DSW_CODE + 2 * len(w)
    def L(v): return [(v >> 16) & 0xFFFF, v & 0xFFFF]
    def br(op, t): w.append(op); fix.append((len(w), t)); w.append(0)
    def run(base, out):
        w.extend([0x4DF9] + L(base + adj))               # lea base+adj,a6
        w.extend([0x4CF9, 0x3FFF] + L(DSW_INIT))         # movem.l INIT,d0-d7/a0-a5
        w.extend([0x4BEE, 0x0008])                       # lea 8(a6),a5
        w.extend([0x44FC, 0x001F])                       # move #$1F,ccr, then
        w.extend([0x44FC, 0x0000])                       # move #0,ccr: the same flags (X!) for both runs - a restart's CCR rollback taken too early shows as $1F
        w.extend(ws)                                     # THE INSTRUCTION
        w.extend([0x42F9] + L(out + 0x80))              # move.w ccr,out+$80
        w.extend([0x48F9, 0x7FFF] + L(out))              # movem.l d0-d7/a0-a6,out
    w.extend([0x48E7, 0xFFFE])                           # movem.l d0-d7/a0-a6,-(a7)
    run(DSW_RB + off, DSW_OUT1)                          # the reference
    run(DSW_P + off, DSW_OUT2)                           # the faulting run
    w.extend([0x41F9] + L(DSW_OUT1) + [0x43F9] + L(DSW_OUT2) + [0x700C])   # lea; lea; moveq #12,d0
    lab['r'] = here(); w.append(0xB388); br(0x6600, 'Fr'); br(0x51C8, 'r')  # cmpm.l (a0)+,(a1)+; bne Fr; dbra
    for o in (52, 56):                                   # A5 and A6, each relative to its run's base
        w.extend([0x2239] + L(DSW_OUT1 + o) + [0x92BC] + L(DSW_RB + off))   # move.l; sub.l #ref,d1
        w.extend([0x2439] + L(DSW_OUT2 + o) + [0x94BC] + L(DSW_P + off))    # move.l; sub.l #faulting,d2
        w.append(0xB481); br(0x6600, 'Fa')               # cmp.l d1,d2; bne Fa
    w.extend([0x3239] + L(DSW_OUT1 + 0x80) + [0xB279] + L(DSW_OUT2 + 0x80))   # the CCRs
    br(0x6600, 'Fc')
    w.extend([0x41F9] + L(DSW_RB - 32) + [0x43F9] + L(DSW_P - 32) + [0x700F])   # 64 bytes around each operand
    lab['m'] = here(); w.append(0xB388); br(0x6600, 'Fm'); br(0x51C8, 'm')
    w.extend([0x23FC] + L(1) + L(DSW_RES)); br(0x6000, 'E')   # move.l #1,RES; bra E
    # a failure: RES = (which compare << 16) | the loop's D0 - 2 registers (D0 = 12 - index of D0-D7/A0-A4),
    # 3 A5/A6, 4 the CCR, 5 memory (D0 = 15 - the long's index from operand - 32)
    for k, code in (('Fr', 2), ('Fa', 3), ('Fc', 4), ('Fm', 5)):
        lab[k] = here(); w.extend([0x33C0] + L(DSW_RES + 2) + [0x33FC, code] + L(DSW_RES)); br(0x6000, 'E')
    lab['E'] = here(); w.extend([0x4CDF, 0x7FFF] + [0x2479] + L(DSW_RES) + [0x4E75])   # restore; movea.l RES,a2; rts
    for i, t in fix:
        w[i] = (lab[t] - (DSW_CODE + 2 * i)) & 0xFFFF
    return w, what

# rts: an RTS whose pop page-faults (the board, compile 73: macgetty's
# rename() returned to address 0 - its RTS loaded PC 0 with $10DC on the
# stack and SP advanced by 4).  The return address is already on the user
# stack, on a page invalid in the user tree; the return stub at RTS_RET adds
# to A2.  "sys" cases are libc's stub (moveq / TRAP #15 / bcs.w / rts), the
# TRAP's handler a bare syscall return (MOVEQ #0,D0; RTE) - (code, usp,
# invalid pages, what):
RTS_RET = 0x53000
SYS_STUB = [0x707B, 0x4E4F, 0x6500, 0x0004, 0x4E75, 0x4E40]   # moveq #$7b,d0; trap #15; bcs.w +4; rts; trap #0
RTS = [
    ([0x4E75], 0x56F00, [0x56000], "RTS: the pop wholly on the invalid page"),
    ([0x4E75], 0x58FFE, [0x59000], "RTS: the pop straddles, its low word on the invalid page"),
    ([0x4E75], 0x5AFFE, [0x5A000], "RTS: the pop straddles, its high word on the invalid page"),
    (SYS_STUB, 0x5CF00, [0x5C000], "a syscall stub's RTS after TRAP #15/RTE, the pop on the invalid page (macgetty's rename)"),
    (SYS_STUB, 0x5EFFE, [0x5F000], "the same, the pop straddling"),
]
# ctx: A/UX's context switch (resume030, the board, compile 75: init's RTS
# read its return address through startmsg's stack translation - an ATC entry
# that survived the PMOVE (A2),CRP).  Needs TCMODE=aux.  A second user tree
# (CTX_U) is the first with page CTX_P mapped to CTX_Q; MOVES.L (A0) loads the
# ATC entry through tree 1, resume030's sequence switches to tree 2, and the
# same MOVES must read CTX_Q's long - (extra words before the CRP load, the
# CRP load's extension word, the long wanted, what):
CTX_U, CTX_CRP = (0x4C00, 0x4E00, 0x5000), 0x3E18
CTX_P, CTX_Q, CTX_PV, CTX_QV = 0x2C000, 0x2D000, 0x11111111, 0x22222222
CTX = [
    ([], 0x4C00, CTX_QV, "resume030: PFLUSH #5,#7,(u-area), MOVEC CACR, PMOVE (A2),CRP"),
    ([0xF013, 0x4E00], 0x4C00, CTX_QV, "the same after a PMOVE CRP,(A3) (an MMU register read just before)"),
    ([0xF013, 0x6200], 0x4C00, CTX_QV, "the same after a PMOVE MMUSR,(A3)"),
    ([], 0x4D00, CTX_PV, "PMOVEFD (A2),CRP: no flush, the old entry still translates (UM 9.8)"),
]
# memind: memory-indirect full-format EAs page-faulting (KNOWN ISSUES 25: A/UX's
# X11 clients die on an F-line at an extension word of MOVE.L ([8,A6],$B4),D0 -
# xclock - and MOVE.L ([-4,A6],$2E),D2 - xeyes).  User mode; the pointer's page,
# the operand's page, the destination's or several invalid; the result to A2 -
# (code, registers, {address: long}, A2 wanted, invalid pages, what):
MI_X = [0x2036, 0x0162, 0x0008, 0x00B4, 0x2440]          # MOVE.L ([8,A6],$B4),D0; MOVEA.L D0,A2
MI_A6 = [(0x2C7C, 0x60100), (0x267C, 0x62000)]           # A6 the frame, A3 the xeyes source
MI_D = {0x60108: 0x61000, 0x610B4: 0x12345678}           # [8,A6] -> $61000; the operand at $610B4
MEMIND = [
    (MI_X, MI_A6, MI_D, 0x12345678, [0x60000], "xclock's MOVE.L ([8,A6],$B4),D0: the pointer's page invalid"),
    (MI_X, MI_A6, MI_D, 0x12345678, [0x61000], "the same, the operand's page invalid"),
    (MI_X, MI_A6, MI_D, 0x12345678, [0x60000, 0x61000], "the same, both invalid"),
    ([0x2476, 0x0162, 0x0008, 0x00B4], MI_A6, MI_D, 0x12345678, [0x60000, 0x61000],
     "MOVEA.L ([8,A6],$B4),A2: both invalid"),
    # xeyes: MOVE.L $5E(A3),([-4,A6],$5E) then MOVEA.L ([-4,A6],$5E),A2 reads it back
    ([0x2DAB, 0x005E, 0x0162, 0xFFFC, 0x005E, 0x2476, 0x0162, 0xFFFC, 0x005E], MI_A6,
     {0x600FC: 0x63000, 0x6205E: 0xCAFEF00D, 0x6305E: 0xDDDDDDDD}, 0xCAFEF00D, [0x63000],
     "xeyes' MOVE.L $5E(A3),([-4,A6],$5E): the destination's page invalid (the write faults)"),
    ([0x2DAB, 0x005E, 0x0162, 0xFFFC, 0x005E, 0x2476, 0x0162, 0xFFFC, 0x005E], MI_A6,
     {0x600FC: 0x63000, 0x6205E: 0xCAFEF00D, 0x6305E: 0xDDDDDDDD}, 0xCAFEF00D, [0x60000, 0x62000, 0x63000],
     "the same, the pointer's, the source's and the destination's pages invalid"),
]
# straddles: the pointer, then the operand, across a page top; the long od and bd sizes
MEMIND += [
    (MI_X, [(0x2C7C, 0x64FF6), (0x267C, 0)], {0x64FFE: 0x66000, 0x660B4: 0x0BADCAFE}, 0x0BADCAFE, [0x65000],
     "the pointer straddling $64FFE, its low word's page invalid"),
    (MI_X, [(0x2C7C, 0x66F00), (0x267C, 0)], {0x66F08: 0x67F4A, 0x67FFE: 0x5A5AA5A5}, 0x5A5AA5A5, [0x68000],
     "the operand straddling $67FFE, its low word's page invalid"),
    ([0x2036, 0x0163, 0x0008, 0x0001, 0x00B4, 0x2440], [(0x2C7C, 0x69100), (0x267C, 0)],
     {0x69108: 0x69000, 0x790B4: 0x77665544}, 0x77665544, [0x69000, 0x79000],
     "MOVE.L ([8,A6],$100B4.L),D0 - long od: both pages invalid"),
    ([0x2036, 0x0172, 0x0000, 0x0008, 0x00B4, 0x2440], MI_A6, MI_D, 0x12345678, [0x60000, 0x61000],
     "MOVE.L ([$8.L,A6],$B4),D0 - long bd: both pages invalid"),
]
# memfull: the full extension word's every form (UM 2.2: BD SIZE x IS x I/IS)
# under a LASTWRITE write fault - the format $A frame's continuation PC counts
# the instruction's stream words.  MIPART=d: MOVE.L D0,<ea> faults on <ea>'s
# page, then MOVEA.L <ea>,A2 reads it back; MIPART=s: MOVE.L <ea>,(A3) faults
# on (A3)'s page after reading <ea>, then MOVEA.L (A3),A2.  MIBD = 1 (null bd),
# 2 (word), 3 (long).  Index D2.L = 8.  Each case's 256-byte slice of the
# frame page $60000 (A6, the pointers), the target page $62000 and the (A3)
# page $63000 - (IS, I/IS) pairs:
MF_IIS = [(1, 0), (1, 1), (1, 2), (1, 3), (0, 0), (0, 1), (0, 2), (0, 3), (0, 5), (0, 6), (0, 7)]
MF_P0, MF_P2, MF_P3 = 0x60000, 0x62000, 0x63000


# um (the third round's scan 3, 2026-10-20): the walker's U and M write-back
# against MC68030 UM 9.5.1.1 and 9.5.2 ("the U bit in each descriptor that is
# encountered is checked and set if it is not already set ... when the table
# search is for a write access and the M bit of the page descriptor is clear,
# the processor sets the bit if the table search does not encounter a set WP
# bit"; "an access is considered to be a write for updating purposes if
# either the R/W or RMC signal is low"), 9.6 (an ATC hit for a write with the
# entry's M clear aborts the cycle, a table search sets M in the descriptor
# and the entry) and 9.8 (PLOADW updates the history as a write, PLOADR as a
# read; PTEST level 7 reports M).  A/UX's pager is the first user: it judges
# dirty pages by M (PTEST 7, vtopte_sr) and ages them by U.  Each case
# touches fresh pages of the user tree (U and M clear) - from supervisor mode
# through MOVES (FC 1) or in user mode (MOVE #0,SR ... TRAP #14 back) - then
# copies the descriptors and PTEST's MMUSR to UM_OBS + $40 x case; the
# expectations are the manual's.  Needs TCMODE=aux.  One run, all cases.
UM_P, UM_OBS, TRAPS = 0x50000, 0x3800, 0x1F80       # the pages (one a case, more for the straddles), the observations, TRAP #14 (vector 46: back to supervisor)
UM_U, UM_M, UM_WP = 8, 16, 4


def um_cases():
    """(code words, invalid pages, write-protected pages, [(slot, value, what)], what)."""
    out = []
    L = lambda v: [(v >> 16) & 0xFFFF, v & 0xFFFF]
    desc = lambda p: PG_TBL + 4 * (p >> 12)
    base = lambda p: p | 1
    pg = [UM_P + 0x1000 * i for i in range(24)]
    def lea3(a): return [0x47F9] + L(a)              # LEA a,A3
    # the walker writes descriptors on the bus, past the data cache (UM 6.1.2: a
    # stale cached copy is the chip's behaviour, the OS's problem), so every
    # read of one here clears the data cache first: MOVE.L #CACR|CD,D0; MOVEC D0,CACR
    CD = [0x203C] + L(CACR | 0x0800) + [0x4E7B, 0x0002]
    def rd(p, slot):                                 # MOVE.L desc(p).L,slot.L: page p's descriptor
        return CD + [0x23F9] + L(desc(p)) + L(slot)
    def rdat(a, slot):                               # MOVE.L a.L,slot.L: a pointer descriptor at a
        return CD + [0x23F9] + L(a) + L(slot)
    def ptest(p, slot):                              # LEA p,A3; PTEST #1,(A3),#7; LEA slot,A4; PMOVE MMUSR,(A4)
        return lea3(p) + [0xF013, 0x9E11, 0x49F9] + L(slot) + [0xF014, 0x6200]
    MR, MW = [0x0E13, 0x3000], [0x0E93, 0x3800]      # MOVES.B (A3),D3; MOVES.L D3,(A3)
    USER, SUPER = [0x46FC, 0x0000], [0x4E4E]         # MOVE #0,SR; TRAP #14
    FLUSH = [0xF000, 0x2400]
    mmusr = lambda m, wp=0: (0x200 if m else 0) | (0x800 if wp else 0) | 3   # M, W, N = 3 levels
    k = 0
    def case(code, bad, wps, obs, what):
        nonlocal k
        s = UM_OBS + 0x40 * k
        ex = [(s + 4 * i, v, "um %d %s: %s" % (k, what, w)) for i, (v, w) in enumerate(obs)]
        out.append((code, bad, wps, ex, what)); k += 1
        return s
    # 0: a read sets U, not M; the pointer descriptors' U too; a flush and a re-read change nothing
    s = UM_OBS
    p = pg[0]
    case(lea3(p) + MR + rd(p, s) + rdat(AUX_U[0], s + 4) + rdat(AUX_U[1] + 4, s + 8) + FLUSH + MR + rd(p, s + 12) + ptest(p, s + 16),
         [], [], [(base(p) | UM_U, "the page: U"), (AUX_U[1] | 2 | UM_U, "table A entry 0: U"), ((AUX_U[2] + 0x100) | 2 | UM_U, "table B entry 1: U"),
                  (base(p) | UM_U, "after PFLUSHA and a re-read: unchanged"), (mmusr(0) << 16, "PTEST 7: M clear, N 3")],
         "a read (MOVES.B)")
    # 1: a write sets U and M
    p = pg[1]; s = UM_OBS + 0x40
    case(lea3(p) + MW + rd(p, s) + ptest(p, s + 4), [], [], [(base(p) | UM_U | UM_M, "U and M"), (mmusr(1) << 16, "PTEST 7: M")], "a write (MOVES.L)")
    # 2: a read (an ATC entry with M clear), then a write: the hit must re-walk to set M (UM 9.6)
    p = pg[2]; s = UM_OBS + 0x80
    case(lea3(p) + MR + rd(p, s) + MW + rd(p, s + 4), [], [], [(base(p) | UM_U, "after the read: U"), (base(p) | UM_U | UM_M, "after the write on the ATC hit: M")],
         "a read then a write")
    # 3: a write to a write-protected page: the fault, the handler clears WP, the re-run sets M
    p = pg[3]; s = UM_OBS + 0xC0
    case(lea3(p) + MW + rd(p, s) + ptest(p, s + 4), [p], [p], [(base(p) | UM_U | UM_M, "repaired and re-run: U and M"), (mmusr(1) << 16, "PTEST 7: M")],
         "a write to a WP page (fault)")
    # 4: a read of a write-protected page: no fault, U set, M clear
    p = pg[4]; s = UM_OBS + 0x100
    case([0x00B9] + L(UM_WP) + L(desc(p)) + lea3(p) + MR + rd(p, s) + ptest(p, s + 4), [], [],
         [(base(p) | UM_WP | UM_U, "U, WP kept, M clear"), (mmusr(0, 1) << 16, "PTEST 7: W, M clear")], "a read of a WP page")
    # 5: TAS in user mode on a clean page: an RMC access is a write for the history (UM 9.5.1.1)
    p = pg[5]; s = UM_OBS + 0x140
    case(lea3(p) + USER + [0x4AD3] + SUPER + rd(p, s) + ptest(p, s + 4), [], [], [(base(p) | UM_U | UM_M, "U and M"), (mmusr(1) << 16, "PTEST 7: M")],
         "TAS (user mode)")
    # 6: TAS on a WP page: the fault at the locked read (KNOWN ISSUES 21), repaired, re-run: M
    p = pg[6]; s = UM_OBS + 0x180
    case(lea3(p) + USER + [0x4AD3] + SUPER + rd(p, s), [p], [p], [(base(p) | UM_U | UM_M, "repaired and re-run: U and M")], "TAS on a WP page (fault)")
    # 7: a long write straddling two pages: both U and M
    p = pg[7]; s = UM_OBS + 0x1C0
    case(lea3(p + 0xFFE) + MW + rd(p, s) + rd(pg[8], s + 4), [], [], [(base(p) | UM_U | UM_M, "the low page"), (base(pg[8]) | UM_U | UM_M, "the high page")],
         "a long write straddling (MOVES.L)")
    # 8: the stale-ATC rule, as the manual has it: M cleared in memory with the ATC entry still M, a write re-walks NOTHING (U/M unchanged); after a flush it does
    p = pg[9]; s = UM_OBS + 0x200
    case(lea3(p) + MW + [0x02B9] + L(~UM_M & 0xFFFFFFFF) + L(desc(p)) + MW + rd(p, s) + FLUSH + MW + rd(p, s + 4), [], [],
         [(base(p) | UM_U, "M cleared in memory, the ATC's M set: no walk, M stays clear"), (base(p) | UM_U | UM_M, "after PFLUSHA: the walk sets M")],
         "the ATC's M against memory's")
    # 9: user mode, plain instructions: a read then a write
    p = pg[10]; s = UM_OBS + 0x240
    case(lea3(p) + USER + [0x1613] + SUPER + rd(p, s) + USER + [0x2683] + SUPER + rd(p, s + 4), [], [],
         [(base(p) | UM_U, "after MOVE.B (A3),D3: U"), (base(p) | UM_U | UM_M, "after MOVE.L D3,(A3): M")], "user-mode read then write")
    # 10: PLOADR sets U; PLOADW sets U and M (UM 9.8)
    p = pg[11]; s = UM_OBS + 0x280
    case(lea3(p) + [0xF013, 0x2211] + rd(p, s) + lea3(pg[12]) + [0xF013, 0x2011] + rd(pg[12], s + 4), [], [],
         [(base(p) | UM_U, "PLOADR: U"), (base(pg[12]) | UM_U | UM_M, "PLOADW: U and M")], "PLOADR and PLOADW")
    # 11: MOVEM.L across two pages in user mode: both U and M
    p = pg[13]; s = UM_OBS + 0x2C0
    case(lea3(p + 0xFFC) + USER + [0x48D3, 0x0018] + SUPER + rd(p, s) + rd(pg[14], s + 4), [], [],
         [(base(p) | UM_U | UM_M, "the low page"), (base(pg[14]) | UM_U | UM_M, "the high page")], "MOVEM.L D3/D4,(A3) straddling (user mode)")
    # 12: a write to an invalid page: the fault, the handler makes it valid (U and M as they were: clear), the re-run sets both
    p = pg[15]; s = UM_OBS + 0x300
    case(lea3(p) + MW + rd(p, s) + ptest(p, s + 4), [p], [], [(base(p) | UM_U | UM_M, "repaired and re-run: U and M"), (mmusr(1) << 16, "PTEST 7: M")],
         "a write to an invalid page (fault)")
    # 13: a byte write at a page's last byte: that page only
    p = pg[16]; s = UM_OBS + 0x340
    case(lea3(p + 0xFFF) + [0x0E13, 0x3800] + rd(p, s) + rd(pg[17], s + 4), [], [],
         [(base(p) | UM_U | UM_M, "the page"), (base(pg[17]), "the next page untouched")], "a byte write at the last byte")
    # 14: a write hit after a read in user mode with the caches on the way (same as 2, user mode, two writes: the second hits with M set, no walk needed)
    p = pg[18]; s = UM_OBS + 0x380
    case(lea3(p) + USER + [0x1613, 0x2683, 0x2683] + SUPER + rd(p, s) + ptest(p, s + 4), [], [],
         [(base(p) | UM_U | UM_M, "U and M"), (mmusr(1) << 16, "PTEST 7: M")], "user-mode read, write, write")
    return out


# sabs (the third round, 2026-10-21 00:10): MOVES through an ABSOLUTE address,
# (xxx).L and (xxx).W, every size, Dn and An, both directions, in supervisor
# mode with SFC = DFC = 1 - the supervisor random sweep's every seed died on
# a MOVES.L A3,(xxx).L: the kernel jumped to A3's VALUE instead of writing it
# (the pair pattern of ssweep cannot hold an absolute address, so these forms
# were never swept).  Each case writes into and reads from a 64-byte window
# (the loaded registers stored back into it with plain MOVEs), compared
# against the expected bytes at ref; resident, invalid (the restart) and
# write-protected (the writes' restart) - (window, invalid, wp, what).
SABS_SRC = bytes.fromhex("DEADBEEF CAFE1234 0BADF00D 8001ABCD".replace(" ", ""))   # the window's +$20..+$2F, read by the MOVES loads
SABS = [(0x6A000, [], False, "(xxx).L, resident"), (0x7F00, [], False, "(xxx).W, resident"),
        (0x6C000, [0x6C000], False, "(xxx).L, the page invalid (restart)"), (0x6E000, [0x6E000], True, "(xxx).L, the page write-protected (the writes' restart)"),
        (0x6A100, [], False, "(xxx).L, every operand MISALIGNED (+1/+5/+9, reads +$21/+$25/+$29)"),
        (0x6A200, [], False, "the sweep's pair: MOVE.L (-$E,A2,A4.W),D6 (misaligned), then MOVES.L A3,(odd xxx).L"),
        (0x6A300, [], False, "a (An)+ MOVES, then MOVES.L A3,(xxx).L (the register-mode latch's previous value)"),
        (0x6A400, [], False, "a (d16,An) MOVES, then MOVES.L A3,(xxx).L (the use-base latch's previous value)")]


def sabs_case(win):
    """The code, the window's initial bytes and the bytes expected after it."""
    L = lambda v: [(v >> 16) & 0xFFFF, v & 0xFFFF]
    absw = win < 0x8000                                 # (xxx).W (sign-extended word) or (xxx).L
    mis = (win & 0xF00) == 0x100                        # the misaligned case: every operand one byte up
    def ea(off):                                        # (ea field, extension words)
        a = win + off + (1 if mis else 0)
        return (0x38, [a & 0xFFFF]) if absw else (0x39, L(a))
    def moves(size, reg_a, reg, dr, off):               # size 0/1/2, reg_a 1 = An, dr 1 = register to memory
        e, x = ea(off)
        return [0x0E00 | size << 6 | e, reg_a << 15 | reg << 12 | dr << 11] + x
    def store(reg_a, reg, off):                         # MOVE.L Rn,(win+off).L - plain, supervisor
        return [0x23C0 | reg_a << 3 | reg] + L(win + off)
    if (win & 0xF00) == 0x200:                          # the sweep's pair (seed 0 at $64D34: 2C32 C0F2 / 0EB9 B800 0006 A005)
        code = ([0x267C] + L(0x89ABCDEF) +              # MOVEA.L #$89ABCDEF,A3
                [0x9DCE, 0x99CC, 0x7C00] +              # SUBA.L A6,A6; SUBA.L A4,A4; MOVEQ #0,D6
                [0x247C] + L(win + 0x2F) +              # MOVEA.L #win+$2F,A2
                [0x2C32, 0xC0F2] +                      # MOVE.L (-$E,A2,A4.W),D6: the long at +$21 (misaligned)
                [0x0EB9, 0xB800] + L(win + 0x05) +      # MOVES.L A3,(win+5).L: misaligned, through DFC
                store(0, 6, 0x10))                      # D6 stored at +$10
        init = bytearray(((win >> 4) + i * 0x11) & 0xFF for i in range(0x40))
        init[0x20:0x30] = SABS_SRC
        exp = bytearray(init)
        exp[0x05:0x09] = bytes.fromhex("89ABCDEF")
        exp[0x10:0x14] = init[0x21:0x25]
        return code, bytes(init), bytes(exp)
    if (win & 0xF00) in (0x300, 0x400):                 # a simple or a (d16,An) MOVES first, then the absolute one
        first = [0x0E9A, 0x3800] if (win & 0xF00) == 0x300 else [0x0EAA, 0x3800, 0x0004]   # MOVES.L D3,(A2)+ / MOVES.L D3,4(A2)  ($0E80 | mode<<3 | reg)
        code = ([0x263C] + L(0x11223344) +              # MOVE.L #$11223344,D3
                [0x267C] + L(0x89ABCDEF) +              # MOVEA.L #$89ABCDEF,A3
                [0x247C] + L(win + 0x30) +              # MOVEA.L #win+$30,A2
                first +                                 # the first MOVES, through DFC, to +$30 or +$34
                [0x0EB9, 0xB800] + L(win + 0x08))       # MOVES.L A3,(win+8).L
        init = bytearray(((win >> 4) + i * 0x11) & 0xFF for i in range(0x40))
        exp = bytearray(init)
        o = 0x30 if (win & 0xF00) == 0x300 else 0x34
        exp[o:o + 4] = bytes.fromhex("11223344")
        exp[0x08:0x0C] = bytes.fromhex("89ABCDEF")
        return code, bytes(init), bytes(exp)
    code = ([0x263C] + L(0x12345678) +                  # MOVE.L #$12345678,D3
            [0x267C] + L(0x89ABCDEF) +                  # MOVEA.L #$89ABCDEF,A3
            [0x7800, 0x7A00, 0x7C00, 0x9DCE] +          # MOVEQ #0,D4/D5/D6; SUBA.L A6,A6
            moves(2, 0, 3, 1, 0x00) + moves(1, 0, 3, 1, 0x04) + moves(0, 0, 3, 1, 0x06) +     # D3 -> +0 .L, +4 .W, +6 .B
            moves(2, 1, 3, 1, 0x08) + moves(1, 1, 3, 1, 0x0C) + moves(0, 1, 3, 1, 0x0E) +     # A3 -> +8 .L, +C .W, +E .B
            moves(2, 0, 4, 0, 0x20) + moves(1, 0, 5, 0, 0x24) + moves(0, 0, 6, 0, 0x26) +     # +20.L -> D4, +24.W -> D5, +26.B -> D6
            moves(2, 1, 6, 0, 0x28) + store(1, 6, 0x1C) +                                     # +28.L -> A6, stored at +1C
            moves(1, 1, 6, 0, 0x2C) + store(1, 6, 0x30) +                                     # +2C.W -> A6 (sign-extended), stored at +30
            store(0, 4, 0x10) + store(0, 5, 0x14) + store(0, 6, 0x18))                        # D4, D5, D6 stored at +10, +14, +18
    init = bytearray(((win >> 4) + i * 0x11) & 0xFF for i in range(0x40))
    init[0x20:0x30] = SABS_SRC
    exp = bytearray(init)
    o = 1 if mis else 0                                                   # the misaligned case: every MOVES operand one byte up
    exp[o + 0x00:o + 0x04] = bytes.fromhex("12345678"); exp[o + 0x04:o + 0x06] = bytes.fromhex("5678"); exp[o + 0x06] = 0x78
    exp[o + 0x08:o + 0x0C] = bytes.fromhex("89ABCDEF"); exp[o + 0x0C:o + 0x0E] = bytes.fromhex("CDEF"); exp[o + 0x0E] = 0xEF
    src = bytes(init[o + 0x20:o + 0x30])                                 # what the loads read (the stores land aligned at +$10..)
    exp[0x10:0x14] = src[0:4]                                            # D4
    exp[0x14:0x18] = bytes([0, 0]) + src[4:6]                            # D5: the word
    exp[0x18:0x1C] = bytes([0, 0, 0, src[6]])                            # D6: the byte
    exp[0x1C:0x20] = src[8:12]                                           # A6: the long
    w = (src[12] << 8) | src[13]                                         # A6: the word, sign-extended
    exp[0x30:0x34] = (w | (0xFFFF0000 if w & 0x8000 else 0)).to_bytes(4, "big")
    return code, bytes(init), bytes(exp)


def memfull_cases(part, bds):
    out = []
    for k, (is_, iis) in enumerate(MF_IIS):
        o = 0x100 * k
        ext = 0x2800 | 0x0100 | (is_ << 6) | (bds << 4) | iis       # D2.L, full format
        bd = {1: 0, 2: 0x40, 3: 0x80}[bds]
        bdw = {1: [], 2: [bd], 3: [bd >> 16, bd & 0xFFFF]}[bds]
        ods = iis & 3 if iis else 0                                  # 0 none, 1 null, 2 word, 3 long
        od = {0: 0, 1: 0, 2: 0x30, 3: 0x50}[ods]
        odw = {0: [], 1: [], 2: [od], 3: [od >> 16, od & 0xFFFF]}[ods]
        x = 0 if is_ else 8                                          # the index's value, if not suppressed
        data = {}
        if iis == 0:                                                 # no memory indirection: the target is the EA
            a6 = MF_P2 + o + 0x10
            target = a6 + bd + x
        else:
            a6 = MF_P0 + o + 0x10
            pre = iis < 4
            pa = a6 + bd + (x if pre else 0)
            ptr = MF_P2 + o + 0x10
            data[pa] = ptr
            target = ptr + od + (0 if pre else x)
        v = 0xC0DE0000 | (part == "s") << 12 | bds << 8 | k
        ea = [ext] + bdw + odw
        a3 = MF_P3 + o + 0x10
        if part == "d":
            data[target] = 0xDDDDDDDD
            code = [0x2D80] + ea + [0x2476] + ea                     # MOVE.L D0,(ea); MOVEA.L (ea),A2
            bad = [MF_P2]
        else:
            data[target] = v
            data[a3] = 0xDDDDDDDD
            code = [0x26B6] + ea + [0x2453]                          # MOVE.L (ea),(A3); MOVEA.L (A3),A2
            bad = [MF_P3]
        regs = [(0x2C7C, a6), (0x267C, a3), (0x243C, 8), (0x203C, v)]   # A6, A3, D2, D0
        what = "%s ext $%04X (BD SIZE %d, IS %d, I/IS %d%d%d)" % (
            "MOVE.L D0,<ea>" if part == "d" else "MOVE.L <ea>,(A3)", ext, bds, is_, iis >> 2, (iis >> 1) & 1, iis & 1)
        out.append((code, regs, data, v, bad, what))
    return out


# dcmp: (table, source, destination, reference, output words, seed, which pages invalid, what)
DCMP_CASES = [
    (0x40000, 0x41000, 0x48F00, 0x50000, 0x2000, 1, "dst", "destination pages invalid: the byte and word writes fault, as on the board"),
    (0x40000, 0x55000, 0x5A000, 0x60000, 0x1000, 2, "src", "source pages invalid: the (A0)+ reads fault"),
    (0x65000, 0x66000, 0x6AF00, 0x70000, 0x1000, 3, "tbl+dst", "the table and the destination invalid: the indexed read and the writes fault"),
]


def dcmp_stream(nwords, seed):
    """A compressed stream, the table and the output the loop must produce."""
    rnd = random.Random(seed)
    table = [0x7000 | (i * 0x35 + 0x11) & 0x0FFF for i in range(256)]
    src, out = bytearray(), bytearray()
    assert nwords % 8 == 0
    for _ in range(nwords // 8):
        flag = 0 if rnd.random() < 0.15 else rnd.randrange(1, 256)
        src.append(flag)
        for bit in range(7, -1, -1):
            if flag & (1 << bit):
                i = rnd.randrange(256)
                src.append(i)
                out += table[i].to_bytes(2, "big")
            else:
                a, b = rnd.randrange(256), rnd.randrange(256)
                src += bytes((a, b))
                out += bytes((a, b))
    return bytes(src), table, bytes(out)


def pages(lo, hi):
    return list(range(lo & ~0xFFF, hi, 0x1000))


def main():
    rom = open(ROM, "rb").read()
    assert len(rom) == 262144 and rom[0:4] == bytes.fromhex("97221136"), "not the 97221136 ROM"
    blockmove = rom[0xEFFE:0xF020]                  # MOVE.L D0,D1 ... the second DBRA
    assert blockmove[:6] == bytes.fromhex("2200EA896012") and blockmove[-4:] == bytes.fromhex("51C9FFE6")
    words = lambda b: [int.from_bytes(b[i:i + 2], "big") for i in range(0, len(b), 2)]

    mem = [0] * (SIZE // 2)
    touched = set()                                  # the pages a case's code or data is put in (+UOK)
    rec = [True]

    def put32(a, v):
        mem[a // 2], mem[a // 2 + 1] = (v >> 16) & 0xFFFF, v & 0xFFFF
        if rec[0]:
            touched.update((a >> 12, (a + 3) >> 12))

    def putbytes(a, b):
        assert a % 2 == 0
        b = b + b"\0" * (len(b) & 1)
        if rec[0] and b:
            touched.update(range(a >> 12, ((a + len(b) - 1) >> 12) + 1))
        for i in range(0, len(b), 2):
            mem[(a + i) // 2] = (b[i] << 8) | b[i + 1]

    # the cases as (registers, code, entry offset, reference, destination, bytes, invalid pages, A2 wanted, what)
    cases = []
    bm = (BLOCKMOVE if CASESET in ("all", "blockmove") else []) + (STRADDLE if CASESET in ("all", "straddle") else []) + (AUX7 if CASESET in ("all", "aux7") else [])
    if bm:
        for src, dst, n, bad, what in bm:
            for a in range(src, src + n, 4):
                put32(a, 0xC0000000 | a)             # the source: every long distinct
            for a in range((dst - 0x40) & ~3, dst + n + 0x40, 4):
                put32(a, 0xDD000000 | a)             # the destination before: marked
            regs = [(0x207C, src + n), (0x227C, dst + n), (0x203C, n)]      # A0, A1, D0
            cases.append((regs, words(blockmove), 0, src, dst, n, bad, None,
                          {"A0": src, "A1": dst}, "blockmove: " + what))
    if CASESET == "moves":
        loops = {"copyout": [0x2421, 0x0EA0, 0x2800],    # MOVE.L -(A1),D2 / MOVES.L D2,-(A0)
                 "uclear":  [0x0EA0, 0x9800],            # MOVES.L A1,-(A0)
                 "copyin":  [0x0EA1, 0x2000, 0x2102]}    # MOVES.L -(A1),D2 / MOVE.L D2,-(A0)
        for kind, kern, user, n, bad, what in MOVES:
            src, dst = (user, kern) if kind == "copyin" else (kern, user)
            ref = 0x2A000 if kind == "uclear" else src   # uclear: a page of zeros nothing writes
            if kind != "uclear":
                for a in range(src & ~3, src + n + 4, 4):
                    put32(a, 0xC0000000 | a)
            for a in range((dst - 0x40) & ~3, dst + n + 0x40, 4):
                put32(a, 0xDD000000 | a)
            body = loops[kind]
            code = body + [0x51C9, (-(2 * len(body) + 2)) & 0xFFFF, 0x4E40]   # DBRA D1,loop; TRAP #0
            a1 = 0 if kind == "uclear" else (kern + n if kind == "copyout" else user + n)
            a0 = user + n if kind != "copyin" else kern + n
            regs = [(0x207C, a0), (0x227C, a1), (0x223C, 0xFFFF0000 | (n // 4 - 1))]   # A0, A1, D1: DBRA's count
            want = {"A0": a0 - n, "A1": 0 if kind == "uclear" else a1 - n, "super": True}
            cases.append((regs, code, 0, ref, dst, n, bad, None, want, "moves: " + what))
    if CASESET == "wp":
        for k, (op, sz, dst, n, what) in enumerate(WP):
            ref = 0x20000 + 0x4000 * k
            init = bytearray((dst + i * 7 + (i >> 8)) & 0xFF for i in range(n + 8))
            out = bytearray(init)
            for i in range(0, n, sz):
                v = int.from_bytes(out[i:i + sz], "big")
                v = (0x0101 if op == 0x30C0 else (v + 0x01010101) & (1 << 8 * sz) - 1)
                out[i:i + sz] = v.to_bytes(sz, "big")
            # the destination's bytes: from the long below dst, so putbytes stays even
            base = dst & ~3
            putbytes(base, bytes((0xDD,) * (dst - base)) + bytes(init))
            putbytes(ref, bytes(out))
            regs = [(0x207C, dst), (0x227C, 0), (0x203C, 0x01010101), (0x223C, 0xFFFF0000 | (n // sz - 1))]
            code = [op, 0x51C9, 0xFFFC, 0x4E40]           # op; DBRA D1,op; TRAP #0
            cases.append((regs, code, 0, ref, dst, n, pages(dst, dst + n), None,
                          {"A0": dst + n, "A1": 0, "wp": True}, "wp: " + what))
    if CASESET == "jsr":
        for k, (call, usp, bad, what) in enumerate(JSR):
            touched.update(((usp - 12) >> 12, usp >> 12))   # the user stack around USP (+UOK)
            # call sub; TRAP #0; sub: ADDQ.L #1,A2; RTS - the displacement from the call's extension word
            if call == "link":                       # LINK A6,#-8; MOVEA.L A7,A2; TRAP #0
                code, a2 = [0x4E56, 0xFFF8, 0x244F, 0x4E40], usp - 4 - 8
            else:
                code, a2 = call + [0x0004, 0x4E40, 0x528A, 0x4E75], 1
            regs = [(0x207C, usp), (0x4E60, None),          # MOVE.L A0,USP: the user stack
                    (0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, bad, a2,
                          {"A0": 0x77, "A1": 0x55}, "jsr: " + what))
    if CASESET in ("bf", "bfx"):
        for k, (op, a0, what) in enumerate(BF if CASESET == "bf" else BFX):
            lo = (a0 & ~0xF) - 0x10                  # the 64 bytes around the field, checked whole
            ref = 0x20000 + 0x100 * k
            init = bytearray(((lo + i) * 13 + 0x5A) & 0xFF for i in range(0x40))
            out = bytearray(init)
            o = a0 - lo
            v = int.from_bytes(out[o:o + 5], "big")  # 40 bits; the field is bits 4..35 from the top
            m = 0xFFFFFFFF << 4
            v = (v & ~m) | ((0x12345678 << 4) & m) if op == 0xEFD0 else v ^ m
            out[o:o + 5] = v.to_bytes(5, "big")
            putbytes(lo, bytes(init))
            putbytes(ref, bytes(out))
            regs = [(0x207C, a0), (0x227C, 0), (0x72FF, None), (0x203C, 0x12345678)]   # A0, A1, MOVEQ #-1,D1, D0
            cases.append((regs, [op, 0x0100, 0x4E40], 0, ref, lo, 0x40, [a0 & ~0xFFF, (a0 & ~0xFFF) + 0x1000], None,
                          {"A0": a0, "A1": 0, "wp": True}, "bf: " + what))
    if CASESET == "ifetch":
        sel = os.environ.get("IFONLY")                # one case alone: an exception stops the run
        for k, (entry, blobs, a2, bad, what) in enumerate(IFETCH):
            if sel is not None and k != int(sel):
                continue
            for a, ws in blobs.items():
                putbytes(a, b"".join(x.to_bytes(2, "big") for x in ws))
            code = [0x4EB9, entry >> 16, entry & 0xFFFF, 0x4E40]   # JSR entry.L; TRAP #0
            regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, bad, a2,
                          {"A0": 0x77, "A1": 0x55}, "ifetch: " + what))
    if CASESET == "dsweep":
        allc = dsw_cases()
        if os.environ.get("DSWLIST"):
            for k, c in enumerate(allc):
                print("%3d %s" % (k, c[3]))
            raise SystemExit(0)
        code_w, what = dsw_build(allc[int(os.environ["DSW"])])
        putbytes(DSW_CODE, b"".join(x.to_bytes(2, "big") for x in code_w))
        rnd = random.Random(29)
        window = bytes(rnd.randrange(1, 256) for _ in range(128))   # nonzero: the divisors
        putbytes(DSW_P - 64, window)
        putbytes(DSW_RB - 64, window if not os.environ.get("DSW_SANITY") else window[:64] + bytes([window[64] ^ 0x5A]) + window[65:])   # DSW_SANITY=1: a planted difference must FAIL
        putbytes(DSW_INIT, b"".join(v.to_bytes(4, "big") for v in DSW_INITV))
        code = [0x4EB9, DSW_CODE >> 16, DSW_CODE & 0xFFFF, 0x4E40]   # JSR DSW_CODE.L; TRAP #0
        regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
        cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, [DSW_P], 1,
                      {"A0": 0x77, "A1": 0x55, "wp": DSW_WP, "nocount": DSW_WP}, "dsweep: " + what))
    if CASESET == "ssweep":                          # dsweep's pattern in supervisor mode (MOVES, SFC = DFC = 1)
        allc = ssw_cases()
        if os.environ.get("SSWLIST"):
            for k, c in enumerate(allc):
                print("%3d %s" % (k, c[3]))
            raise SystemExit(0)
        code_w, what = dsw_build(allc[int(os.environ["SSW"])])
        putbytes(DSW_CODE, b"".join(x.to_bytes(2, "big") for x in code_w))
        rnd = random.Random(29)
        window = bytes(rnd.randrange(1, 256) for _ in range(128))
        putbytes(DSW_P - 64, window)
        putbytes(DSW_RB - 64, window if not os.environ.get("DSW_SANITY") else window[:64] + bytes([window[64] ^ 0x5A]) + window[65:])
        putbytes(DSW_INIT, b"".join(v.to_bytes(4, "big") for v in DSW_INITV))
        code = [0x4EB9, DSW_CODE >> 16, DSW_CODE & 0xFFFF, 0x4E40]   # JSR DSW_CODE.L; TRAP #0 - in supervisor mode
        regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
        cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, [DSW_P], 1,
                      {"A0": 0x77, "A1": 0x55, "wp": SSW_WP, "nocount": SSW_WP, "super": True}, "ssweep: " + what))
    if CASESET == "isweep":
        allc = isw_cases()
        if os.environ.get("ISWLIST"):
            for k, c in enumerate(allc):
                print("%3d %s" % (k, c[4]))
            raise SystemExit(0)
        entry, blobs, what = isw_build(allc[int(os.environ["ISW"])])
        for a_, ws in blobs.items():
            putbytes(a_, b"".join(x.to_bytes(2, "big") for x in ws))
        regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
        if os.environ.get("PAIR", "1") == "1":
            wins = PAIR_WIN["isweep"]
            for run, badp in ((0, []), (1, [ISW_P])):
                dump = PAIR_DUMP + PAIR_STRIDE * run
                code2 = [0x4EB9, entry >> 16, entry & 0xFFFF,          # JSR entry.L
                         0x48F9, 0x5FFF, dump >> 16, dump & 0xFFFF,    # MOVEM.L D0-D7/A0-A4/A6,dump
                         0x23CF, (dump + 0x38) >> 16, (dump + 0x38) & 0xFFFF,   # MOVE.L A7,dump+$38
                         0x42F9, (dump + 0x3C) >> 16, (dump + 0x3C) & 0xFFFF,   # MOVE CCR,dump+$3C
                         0x4E40]                                       # TRAP #0
                cases.append((regs, code2, 0, 0x2A000, 0x2A000, 4, badp, 1,
                              {"A0": 0x77, "A1": 0x55, "pair": (run, wins)},
                              "isweep%s: " % (" (reference)" if run == 0 else " (faulting)") + what))
            putbytes(PAIR_DUMP, bytes(2 * PAIR_STRIDE))
        else:
            code = [0x4EB9, entry >> 16, entry & 0xFFFF, 0x4E40]   # JSR entry.L; TRAP #0
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, [ISW_P], 1,
                          {"A0": 0x77, "A1": 0x55}, "isweep: " + what))
    if CASESET == "xsweep":
        allc = xsw_cases()
        if os.environ.get("XSWLIST"):
            for k, c in enumerate(allc):
                print("%3d %s" % (k, c[4]))
            raise SystemExit(0)
        entry, blobs, what = xsw_build(allc[int(os.environ["XSW"])])
        for a_, ws in blobs.items():
            putbytes(a_, b"".join(x.to_bytes(2, "big") for x in ws))
        regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
        if os.environ.get("PAIR", "1") == "1":
            wins = PAIR_WIN["xsweep"]
            for run, badp in ((0, []), (1, [ISW_P])):
                dump = PAIR_DUMP + PAIR_STRIDE * run
                code2 = [0x4EB9, entry >> 16, entry & 0xFFFF,          # JSR entry.L
                         0x48F9, 0x5FFF, dump >> 16, dump & 0xFFFF,    # MOVEM.L D0-D7/A0-A4/A6,dump
                         0x23CF, (dump + 0x38) >> 16, (dump + 0x38) & 0xFFFF,   # MOVE.L A7,dump+$38
                         0x42F9, (dump + 0x3C) >> 16, (dump + 0x3C) & 0xFFFF,   # MOVE CCR,dump+$3C
                         0x4E40]                                       # TRAP #0
                cases.append((regs, code2, 0, 0x2A000, 0x2A000, 4, badp, 1,
                              {"A0": 0x77, "A1": 0x55, "pair": (run, wins)},
                              "xsweep%s: " % (" (reference)" if run == 0 else " (faulting)") + what))
            putbytes(PAIR_DUMP, bytes(2 * PAIR_STRIDE))
        else:
            code = [0x4EB9, entry >> 16, entry & 0xFFFF, 0x4E40]   # JSR entry.L; TRAP #0
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, [ISW_P], 1,
                          {"A0": 0x77, "A1": 0x55}, "xsweep: " + what))
    if CASESET == "rsweep":
        if os.environ.get("RSWLIST"):
            for k in range(int(os.environ["RSWLIST"])):
                w_, d_, pg_, wp_ = rsw_build(k)
                print("%3d %d words, faulting pages %s (write-protected %s)" % (k, len(w_), " ".join("%X" % x for x in pg_), " ".join("%X" % x for x in wp_) or "-"))
            raise SystemExit(0)
        seed = int(os.environ["RSW"])
        cw, dd, pgs, wps = rsw_build(seed)
        if RSW_SUPER:                                     # supervisor mode: only the DATA pages can fault (the code and the stack go through the
            pgs = [p for p in pgs if p in (0x69000, 0x6A000)]   # supervisor tree), so only they are made invalid or WP - an invalid code page would
            wps = [p for p in wps if p in pgs]                  # never be repaired and its descriptor would differ in the page-table window
            if not pgs:
                pgs = [0x69000]
        putbytes(RSW_CODE, b"".join(x.to_bytes(2, "big") for x in cw))
        putbytes(RSW_DATA, dd)
        putbytes(RSW_STK, bytes(0x400))
        regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
        for run, badp in ((0, []), (1, pgs)):
            dump = PAIR_DUMP + PAIR_STRIDE * run
            code2 = [0x4EB9, RSW_CODE >> 16, RSW_CODE & 0xFFFF,          # JSR RSW_CODE
                     0x48F9, 0x5FFF, dump >> 16, dump & 0xFFFF,          # MOVEM.L D0-D7/A0-A4/A6,dump
                     0x23CF, (dump + 0x38) >> 16, (dump + 0x38) & 0xFFFF,   # MOVE.L A7,dump+$38
                     0x42F9, (dump + 0x3C) >> 16, (dump + 0x3C) & 0xFFFF,   # MOVE CCR,dump+$3C
                     0x4E40]                                             # TRAP #0
            cases.append((regs, code2, 0, 0x2A000, 0x2A000, 4, badp, None,
                          {"A0": None, "A1": None, "pair": (run, PAIR_WIN["rsweep"]), "wp_pages": wps, "nocount": True,
                           "noregs": True, "super": RSW_SUPER},
                          "rsweep %d%s%s" % (seed, " (supervisor, MOVES)" if RSW_SUPER else "", " (reference)" if run == 0 else " (faulting)")))
        putbytes(PAIR_DUMP, bytes(2 * PAIR_STRIDE))
    if CASESET == "rts":
        sel = os.environ.get("RTSONLY")               # one case alone, as IFONLY
        putbytes(RTS_RET, bytes.fromhex("528A4E40"))  # ADDQ.L #1,A2; TRAP #0
        for k, (code, usp, bad, what) in enumerate(RTS):
            if sel is not None and k != int(sel):
                continue
            put32(usp, RTS_RET)                       # the return address, on the stack already
            regs = [(0x207C, usp), (0x4E60, None),    # MOVE.L A0,USP: the user stack
                    (0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, bad, 1,
                          {"A0": 0x77, "A1": 0x55}, "rts: " + what))
    if CASESET == "ctx":
        assert TCMODE == "aux", "ctx needs TCMODE=aux (the user trees)"
        sel = os.environ.get("CTXONLY")
        put32(CTX_P, CTX_PV); put32(CTX_Q, CTX_QV)
        l32w = lambda v: [(v >> 16) & 0xFFFF, v & 0xFFFF]
        for k, (pre, crpx, want_v, what) in enumerate(CTX):
            if sel is not None and k != int(sel):
                continue
            code = ([0x0E90, 0x2000,                          # MOVES.L (A0),D2: the ATC entry, tree 1
                     0xF011, 0x38F5,                          # PFLUSH #5,#7,(A1): resume030's u-area flush
                     0x203C] + l32w(CACR | 0x0808) +          # MOVE.L #cacr|CD|CI,D0
                    [0x4E7B, 0x0002] + pre +                  # MOVEC D0,CACR (+ the case's extra)
                    [0x45F9] + l32w(CTX_CRP) +                # LEA ctx_crp,A2
                    [0xF012, crpx,                            # PMOVE (A2),CRP: tree 2 (PMOVEFD: $4D00)
                     0x0E90, 0x3000,                          # MOVES.L (A0),D3: must be CTX_Q's
                     0x45F9] + l32w(CRP_AT) +                 # LEA crp,A2
                    [0xF012, 0x4C00,                          # PMOVE (A2),CRP: tree 1 back
                     0x2443, 0x4E40])                         # MOVEA.L D3,A2; TRAP #0
            regs = [(0x207C, CTX_P), (0x227C, 0x3000), (0x267C, 0x3E30), (0x72FF, None)]   # A0, A1, A3, MOVEQ #-1,D1
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, [], want_v,
                          {"A0": CTX_P, "A1": 0x3000, "super": True}, "ctx: " + what))
    if CASESET in ("memind", "memfull"):
        sel = os.environ.get("MIONLY")                # one case alone, as IFONLY
        mi = MEMIND if CASESET == "memind" else memfull_cases(os.environ.get("MIPART", "d"), int(os.environ.get("MIBD", "2")))
        for k, (code, mregs, data, a2, bad, what) in enumerate(mi):
            if sel is not None and k != int(sel):
                continue
            for a, v in data.items():
                put32(a, v)
            regs = mregs + [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
            cases.append((regs, code, 0, 0x2A000, 0x2A000, 4, bad, a2,
                          {"A0": 0x77, "A1": 0x55}, CASESET + ": " + what))
    um_extra = []
    if CASESET == "um":
        assert TCMODE == "aux", "um needs TCMODE=aux (the user tree's descriptors)"
        for p in range(UM_P, UM_P + 24 * 0x1000, 0x1000):
            putbytes(p, bytes((0x5A, 0xA5)) * 8)     # every page named (+UOK) and nonzero at its start
        for code, bad, wps, ex, what in um_cases():
            regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0), (0x263C, 0x33333333)]   # A0, A1, MOVEQ #-1,D1, A2, D3
            cases.append((regs, code + [0x4E40], 0, 0x2A000, 0x2A000, 4, bad, None,
                          {"A0": 0x77, "A1": 0x55, "super": True, "wp_pages": wps}, "um: " + what))
            um_extra += ex
    if CASESET == "sabs":
        assert TCMODE == "aux", "sabs needs TCMODE=aux (the user tree's pages)"
        for k, (win, bad, wp, what) in enumerate(SABS):
            code, init, exp = sabs_case(win)
            putbytes(win, init)
            ref = 0x2A000 + 0x100 * k
            putbytes(ref, exp)
            regs = [(0x207C, 0x77), (0x227C, 0x55), (0x72FF, None), (0x247C, 0)]   # A0, A1, MOVEQ #-1,D1, A2
            cases.append((regs, code, 0, ref, win, 0x40, bad, None,
                          {"A0": 0x77, "A1": 0x55, "super": True, "wp": wp}, "sabs: " + what))
    if CASESET in ("all", "dcmp"):
        for tbl, src, dst, ref, n, seed, which, what in DCMP_CASES:
            s, table, out = dcmp_stream(n, seed)
            for i, t in enumerate(table):
                mem[tbl // 2 + i] = t
            putbytes(src, s)
            putbytes(ref, out)
            for a in range(dst - 0x40, dst + len(out) + 0x40, 4):
                put32(a, 0xDD000000 | a)
            bad = []
            if "src" in which: bad += pages(src, src + len(s))
            if "tbl" in which: bad += pages(tbl, tbl + 512)
            if "dst" in which: bad += pages(dst, dst + len(out))
            assert ref + len(out) <= SIZE and src + len(s) < dst
            regs = [(0x207C, src), (0x227C, tbl), (0x247C, dst), (0x223C, n), (0x7A00, None)]   # A0, A1, A2, D1, MOVEQ #0,D5
            cases.append((regs, words(DCMP) + [0x4E40], DCMP_ENTRY, ref, dst, len(out), bad, dst + len(out),
                          {"A0": src + len(s), "A1": tbl}, "dcmp: " + what))

    w, at, fix = [], {}, []

    def here():
        return ORG + 2 * len(w)

    def emit(*ws):
        w.extend(ws)

    def l32(v):
        emit((v >> 16) & 0xFFFF, v & 0xFFFF)

    def absref(name):
        fix.append((len(w), name))
        emit(0, 0)

    emit(0x203C); l32(CACR)                          # MOVE.L #CACR,D0
    emit(0x4E7B, 0x0002)                             # MOVEC D0,CACR
    emit(0x41F9); l32(CRP_AT)                        # LEA CRP_AT,A0
    emit(0xF010, 0x4C00)                             # PMOVE (A0),CRP
    if TCMODE == "aux":
        emit(0x41F9); l32(CRP_AT + 16)               # LEA CRP_AT+16,A0
        emit(0xF010, 0x4800)                         # PMOVE (A0),SRP
    emit(0x41F9); l32(CRP_AT + 8)                    # LEA CRP_AT+8,A0
    emit(0xF010, 0x4000)                             # PMOVE (A0),TC
    if H_IRQ:
        emit(0x41F9); l32(CRP_AT + 12)               # LEA CRP_AT+12,A0
        emit(0xF010, 0x0800)                         # PMOVE (A0),TT0
    emit(0x41F9); l32(0x9000)                        # LEA $9000,A0
    emit(0x4E60)                                     # MOVE.L A0,USP
    emit(0x7001)                                     # MOVEQ #1,D0
    emit(0x4E7B, 0x0000)                             # MOVEC D0,SFC: user data, A/UX's copy loops'
    emit(0x4E7B, 0x0001)                             # MOVEC D0,DFC
    expect = []
    handled = 0
    pair_wins = None
    for c in cases:
        if c[8].get("pair"):
            pair_wins = c[8]["pair"][1]
    if pair_wins:
        rec[0] = True
        for i in range(14):                           # PAIR_INIT: D0-D7/A0-A4/A6, distinct
            put32(PAIR_INIT + 4 * i, (0x1000 * (i + 1) + 0x01010101 * (i + 3)) & 0xFFFFFFFF)
        # (the windows' pristine copies are taken at the end of main, after the
        # translation tables are built: a page-table window copied here was
        # zeros, and every run's start wrote them over the descriptors - the
        # third round's first "latency" failures, 2026-10-20)
    for k, (regs, code, entry, ref, dst, n, bad, a2_want, want, what) in enumerate(cases):
        if want.get("pair"):
            po = 0
            for a_, n_ in want["pair"][1]:           # the windows from their pristine copies (the page table among them: before the pages are made invalid)
                emit(0x41F9); l32(PAIR_PRIST + po)   # LEA prist,A0
                emit(0x43F9); l32(a_)                # LEA window,A1
                emit(0x303C, n_ // 4 - 1)            # MOVE.W #n/4-1,D0
                emit(0x22D8, 0x51C8, 0xFFFC)         # MOVE.L (A0)+,(A1)+; DBRA D0,*-2
                po += n_
        for p in bad:
            if want.get("wp") or p in want.get("wp_pages", ()):
                emit(0x00B9); l32(0x00000004); l32(PG_TBL + 4 * (p >> 12))  # ORI.L #4,desc: WP
            else:
                emit(0x02B9); l32(0xFFFFFFFC); l32(PG_TBL + 4 * (p >> 12))  # ANDI.L #~3,desc: DT 0
        emit(0xF000, 0x2400)                         # PFLUSHA
        if want.get("pair"):
            emit(0x41F9); l32(0x9000)                # LEA $9000,A0
            emit(0x4E60)                             # MOVE.L A0,USP
            emit(0x4CF9, 0x5FFF); l32(PAIR_INIT)     # MOVEM.L INIT,D0-D7/A0-A4/A6
            if os.environ.get("PAIR_SANITY") == "1" and want["pair"][0] == 1:
                emit(0x5287)                         # ADDQ.L #1,D7: a planted difference (must FAIL)
        emit(0x4BF9); absref("cont%d" % k)           # LEA cont,A5
        for op, v in regs:
            emit(op)
            if v is not None:
                l32(v)
        if not want.get("super"):
            emit(0x46FC, 0x0000)                     # MOVE.W #0,SR: user mode
        else:
            emit(0x46FC, 0x2000)                     # MOVE.W #$2000,SR: supervisor, interrupts unmasked (the third round's +IRQAT / +IRQEVERY)
        if entry:
            emit(0x6000 | entry)                     # BRA.B the loop's entry
        emit(*code)
        if code[-1] != 0x4E40:
            emit(0x4E40)                             # TRAP #0
        at["cont%d" % k] = here()
        s = SLOTS + 0x20 * k
        emit(0x23C8); l32(s + 0)                     # MOVE.L A0,s
        emit(0x23C9); l32(s + 4)                     # MOVE.L A1,s+4
        emit(0x23C1); l32(s + 8)                     # MOVE.L D1,s+8
        emit(0x23CA); l32(s + 20)                    # MOVE.L A2,s+20
        if want.get("pair"):
            run, wins = want["pair"]
            if os.environ.get("PAIR_SANITY") == "2" and run == 1 and RSW_UM:
                emit(0x02B9); l32(0xFFFFFFF7); l32(PG_TBL + 4 * 0x69)   # ANDI.L #~8,desc($69000): U cleared - a planted difference (must FAIL)
            if RSW_UM and CASESET == "rsweep":
                emit(0x203C); l32(CACR | 0x0800); emit(0x4E7B, 0x0002)   # MOVEC #CACR|CD,CACR: the page table read past any stale data-cache line (the walker writes on the bus)
            po = 0x40
            for a_, n_ in wins:                      # the windows to the run's dump
                emit(0x41F9); l32(a_)                # LEA window,A0
                emit(0x43F9); l32(PAIR_DUMP + PAIR_STRIDE * run + po)   # LEA dump,A1
                emit(0x303C, n_ // 4 - 1)            # MOVE.W #n/4-1,D0
                emit(0x22D8, 0x51C8, 0xFFFC)         # MOVE.L (A0)+,(A1)+; DBRA D0,*-2
                po += n_
        emit(0x45F9); l32(ref)                       # LEA ref,A2
        emit(0x47F9); l32(dst)                       # LEA dst,A3
        emit(0x243C); l32(n // 4 - 1)                # MOVE.L #n/4-1,D2
        emit(0x7600)                                 # MOVEQ #0,D3
        cmp = here()
        emit(0x281A)                                 # MOVE.L (A2)+,D4
        emit(0xB89B)                                 # CMP.L (A3)+,D4
        emit(0x6702)                                 # BEQ.S +2
        emit(0x5283)                                 # ADDQ.L #1,D3
        emit(0x51CA, (cmp - (here() + 2)) & 0xFFFF)  # DBRA D2,cmp
        emit(0x23C3); l32(s + 12)                    # MOVE.L D3,s+12
        emit(0x2038, COUNT)                          # MOVE.L COUNT.W,D0
        emit(0x23C0); l32(s + 16)                    # MOVE.L D0,s+16
        handled += len(bad)
        if want.get("noregs"):
            expect += [(s + 12, 0, "case %d no output long differs from the reference" % k)]
            continue
        expect += [(s + 0, want["A0"], "case %d A0 at its end (%s)" % (k, what)),
                   (s + 4, want["A1"], "case %d A1 at its end" % k),
                   (s + 8, 0xFFFFFFFF, "case %d D1 = -1 (the loop ran out)" % k),
                   (s + 12, 0, "case %d no output long differs from the reference" % k),
                   (s + 16, handled, "case %d handler entries so far = the invalid pages" % k)][:4 if want.get("nocount") else 5]
        if a2_want is not None:
            expect.append((s + 20, a2_want, "case %d A2 at the output's end" % k))
    expect += um_extra                               # the um cases' descriptor and MMUSR observations
    if pair_wins:                                    # the two runs' dumps compared
        nl = (0x40 + sum(n_ for _, n_ in pair_wins)) // 4
        emit(0x41F9); l32(PAIR_DUMP)                 # LEA dump0,A0
        emit(0x43F9); l32(PAIR_DUMP + PAIR_STRIDE)   # LEA dump1,A1
        emit(0x343C, nl - 1)                         # MOVE.W #n-1,D2
        emit(0x7600)                                 # MOVEQ #0,D3
        emit(0x42B8, PAIR_SLOT + 4)                  # CLR.L PAIR_SLOT+4.W
        emit(0xB388, 0x6708, 0x5283,                 # CMPM.L (A0)+,(A1)+; BEQ.S +8; ADDQ.L #1,D3
             0x2208, 0x21C1, PAIR_SLOT + 4,          # MOVE.L A0,D1; MOVE.L D1,PAIR_SLOT+4.W: just past the last difference
             0x51CA, 0xFFF0)                         # DBRA D2,*-14
        emit(0x23C3); l32(PAIR_SLOT)                 # MOVE.L D3,PAIR_SLOT
        expect.append((PAIR_SLOT, 0, "the reference and faulting runs' registers, CCR and memory the same (differing longs)"))
        expect.append((PAIR_SLOT + 4, 0, "the address in the reference dump just past the last differing long (0: none)"))
    at["fin"] = here()
    emit(0x4E72, 0x2700)                             # STOP #$2700
    for i, name in fix:
        w[i], w[i + 1] = at[name] >> 16, at[name] & 0xFFFF
    assert here() <= BERR, "main program overruns the handler"
    assert len(cases) * 0x20 <= COUNT - SLOTS

    berr = []
    def b(*ws):
        berr.extend(ws)
    if H_FULL:
        assert TCMODE == "aux" and CASESET == "aux7", "auxfull needs TCMODE=aux (the supervisor tree is the page clear's alias) and CASESET=aux7"
        SAVE = 60
        b(0x48E7, 0xFFFE)                            # MOVEM.L D0-D7/A0-A6,-(A7): buserr%'s save
        b(0x203C, M20CACHE >> 16, M20CACHE & 0xFFFF) # MOVE.L #m20cache,D0
        b(0x4E7B, 0x0002)                            # MOVEC D0,CACR: user_buserr's
        b(0x4E56, 0xFFD8)                            # LINK A6,#-40: hardflt's frame
    else:
        SAVE = 8
        b(0x48E7, 0x8080)                            # MOVEM.L D0/A0,-(A7)
    FA, SSW, FMT = SAVE + 0x10, SAVE + 0x0A, SAVE + 0x06   # the frame's fault address, SSW and format word from A7
    if H_FULL:
        FA, SSW, FMT = FA + 44, SSW + 44, FMT + 44   # ... below LINK's saved A6 and its 40-byte frame
    if H_IRQ:
        # A/UX's ret_user2 runs at $2700 and RTEs to mask 0: an interrupt
        # that came in meanwhile is pending at the RTE (VIA2 T1, level 2)
        b(0x46FC, 0x2700)                            # MOVE #$2700,SR
        for reg, v in ((11, 0x00), (14, 0xC0), (4, 0x02), (5, 0x00)):   # ACR one-shot, IER T1, T1 count 2: started
            b(0x13FC, v); b((VIA2 + reg * 0x200) >> 16, (VIA2 + reg * 0x200) & 0xFFFF)
    b(0x52B8, COUNT)                                 # ADDQ.L #1,COUNT.W
    b(0x0CB8, 0x0000, 0x0064, COUNT)                 # CMPI.L #100,COUNT.W
    b(0x6200, 0)                                     # BHI.W LOOPSTOP (fixed below)
    bhi = len(berr) - 1
    b(0x202F, FA)                                    # MOVE.L FA(A7),D0: the fault address
    b(0x2078, LOGP)                                  # MOVEA.L LOGP.W,A0
    b(0x20C0)                                        # MOVE.L D0,(A0)+
    b(0x30EF, SSW)                                   # MOVE.W SSW(A7),(A0)+: the SSW
    b(0x30EF, FMT)                                   # MOVE.W FMT(A7),(A0)+: the format word
    b(0x21C8, LOGP)                                  # MOVE.L A0,LOGP.W
    if H_FULL:
        # hardsegflt: the fresh page cleared through the kernel's own mapping
        # (the SRP tree here) by Pg_ptr's MOVEM.L pattern, then its descriptor
        # written as a long
        b(0x2F0E)                                    # MOVE.L A6,-(A7): Pg_ptr saves what it clobbers
        b(0x2200)                                    # MOVE.L D0,D1
        b(0x0281, 0xFFFF, 0xF000)                    # ANDI.L #$FFFFF000,D1: the page
        b(0x2041)                                    # MOVEA.L D1,A0
        b(0x7000)                                    # MOVEQ #0,D0
        for r in (0x2200, 0x2400, 0x2600, 0x2800, 0x2A00, 0x2C00, 0x2E00):   # MOVE.L D0,D1..D7
            b(r)
        for r in (0x2240, 0x2440, 0x2640, 0x2840, 0x2A40, 0x2C40):           # MOVEA.L D0,A1..A6
            b(r)
        b(0x303C, 0x000F)                            # MOVE.W #15,D0: 16 x 256 bytes
        clr = len(berr)
        b(0x48D0, 0x7CFE)                            # MOVEM.L D1-D7/A2-A6,(A0): 48 bytes
        for off in (0x30, 0x64, 0x98, 0xCC):
            b(0x48E8, 0x7EFE, off)                   # MOVEM.L D1-D7/A1-A6,off(A0): 52 bytes (A1 = 0 too)
        b(0x41E8, 0x0100)                            # LEA $100(A0),A0
        b(0x51C8, (BERR + 2 * clr - (BERR + 2 * len(berr) + 2)) & 0xFFFF)   # DBRA D0,clr
        b(0x2C5F)                                    # MOVEA.L (A7)+,A6
        b(0x202F, FA)                                # MOVE.L FA(A7),D0: the fault address again
    b(0xE088)                                        # LSR.L #8,D0
    b(0xE888)                                        # LSR.L #4,D0: the page
    b(0xE588)                                        # LSL.L #2,D0
    b(0x0680, PG_TBL >> 16, PG_TBL & 0xFFFF)         # ADDI.L #PG_TBL,D0
    b(0x2040)                                        # MOVEA.L D0,A0
    if H_FULL:
        b(0x202F, FA)                                # MOVE.L FA(A7),D0
        b(0x0280, 0xFFFF, 0xF000)                    # ANDI.L #$FFFFF000,D0
        b(0x0080, 0x0000, 0x0001)                    # ORI.L #1,D0: DT 1, a page
        b(0x2080)                                    # MOVE.L D0,(A0): the descriptor, a long store
    else:
        b(0x0290, 0xFFFF, 0xFFFB)                    # ANDI.L #~4,(A0): WP clear (CASESET=wp's copy-on-write)
        b(0x0090, 0x0000, 0x0001)                    # ORI.L #1,(A0): DT 1, a page
    if H_ADDR:
        b(0x206F, FA)                                # MOVEA.L FA(A7),A0: the fault address
        b(0xF010, 0x3893)                            # PFLUSH #3,#4,(A0): A/UX's fl_userpg ($550A8)
    else:
        b(0xF000, 0x2400)                            # PFLUSHA
    if H_IRQ:
        ifr = VIA2 + 13 * 0x200
        b(0x0839, 0x0006, ifr >> 16, ifr & 0xFFFF)   # BTST #6,IFR: T1 has fired
        b(0x67F6)                                    # BEQ.S the BTST
    if H_FULL:
        b(0x4E5E)                                    # UNLK A6
        b(0x46FC, 0x2700)                            # MOVE #$2700,SR: ret_user2
        if IRQIN:
            b(0x46FC, 0x2000)                        # MOVE #$2000,SR: LQR%9's reschedule path - a pending interrupt is taken HERE, inside the handler
        b(0x203C, CACRX >> 16, CACRX & 0xFFFF)       # MOVE.L #CACRX,D0
        b(0x4E7B, 0x0002)                            # MOVEC D0,CACR: ret_user3's set_cachemode
        b(0x4E68)                                    # MOVE USP,A0
        b(0x4E60)                                    # MOVE A0,USP
        b(0x4CDF, 0x7FFF)                            # MOVEM.L (A7)+,D0-D7/A0-A6
    else:
        b(0x4CDF, 0x0101)                            # MOVEM.L (A7)+,D0/A0
    b(0x4E73)                                        # RTE
    berr[bhi] = (LOOPSTOP - (BERR + 2 * bhi)) & 0xFFFF   # BHI.W: displacement from its extension word
    assert BERR + 2 * len(berr) <= TRAP0, "the bus-error handler overruns TRAP0's stub"
    trap0 = [0x4FEF, 0x0008,                         # LEA 8(A7),A7
             0x4ED5]                                 # JMP (A5)
    ifr = VIA2 + 13 * 0x200
    irq = [0x13FC, 0x0040, ifr >> 16, ifr & 0xFFFF,  # MOVE.B #$40,IFR: T1's flag cleared
           0x52B8, IRQCOUNT,                         # ADDQ.L #1,IRQCOUNT.W
           0x4E73]                                   # RTE
    loopstop = [0x33FC, 0xBBBB, 0x0000, 0x3F00,      # MOVE.W #$BBBB,$3F00: the handler looped
                0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]
    exc = [0x33EF, 0x0006, 0x0000, 0x3F02,           # MOVE.W 6(A7),$3F02
           0x23EF, 0x0002, 0x0000, 0x3F04,           # MOVE.L 2(A7),$3F04
           0x33FC, 0x0001, 0x0000, 0x3F00,           # MOVE.W #1,$3F00
           0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]

    mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]         # SSP, PC
    for v in range(2, 64):
        t = BERR if v == 2 else TRAP0 if v == 32 else IRQ if v == 26 else TRAPF if v == 47 else IRQ1 if v == 25 else TRAPS if v == 46 else EXC
        mem[2 * v], mem[2 * v + 1] = t >> 16, t & 0xFFFF
    trapf = [0x7000, 0x4E73]                         # TRAP #15: MOVEQ #0,D0; RTE - a syscall's return (rts cases)
    irq1 = [0x52B9, IRQ1COUNT >> 16, IRQ1COUNT & 0xFFFF, 0x4E73]   # ADDQ.L #1,IRQ1COUNT; RTE
    traps = [0x0057, 0x2000, 0x4E73]                 # TRAP #14: ORI.W #$2000,(A7); RTE - back to supervisor mode (the um cases)
    for base, code in ((ORG, w), (BERR, berr), (TRAP0, trap0), (LOOPSTOP, loopstop), (EXC, exc), (IRQ, irq), (TRAPF, trapf), (IRQ1, irq1), (TRAPS, traps)):
        for i, x in enumerate(code):
            mem[base // 2 + i] = x
    rec[0] = False                                   # the tables and the handler's words are not the cases'
    for c in cases:
        touched.update(pg >> 12 for pg in c[6])      # every invalid page is one the case names
    put32(LOGP, LOG)
    put32(CRP_AT + 8, TC); put32(CRP_AT + 12, TT0)
    if TCMODE == "aux":
        put32(CRP_AT, 0x7FFF0002); put32(CRP_AT + 4, AUX_U[0])
        put32(CRP_AT + 16, 0x7FFF0002); put32(CRP_AT + 20, AUX_S[0])
        for ta, tb, tp in (AUX_U, AUX_S):
            put32(ta, tb | 2)                        # A entry 0 ($0-$1FFFFFF): table B
            for i in range(2):                       # B entries 0-1 ($0-$7FFFF): 64 pages each
                put32(tb + 4 * i, (tp + 0x100 * i) | 2)
            for p in range(128):
                put32(tp + 4 * p, (p << 12) | 1)     # identity pages, valid, U and M clear
        if CASESET == "ctx":                        # the second user tree: CTX_P -> CTX_Q
            ta, tb, tp = CTX_U
            put32(CTX_CRP, 0x7FFF0002); put32(CTX_CRP + 4, ta)
            put32(ta, tb | 2)
            for i in range(2):
                put32(tb + 4 * i, (tp + 0x100 * i) | 2)
            for p in range(128):
                put32(tp + 4 * p, ((CTX_Q if p << 12 == CTX_P else p << 12)) | 1)
    else:
        put32(CRP_AT, 0x7FFF0002); put32(CRP_AT + 4, TBL_A)
        put32(TBL_A, TBL_B | 2)                      # entry 0: table B, short descriptors
        for p in range(256):
            put32(TBL_B + 4 * p, (p << 12) | 1)      # identity pages, valid, U and M clear

    if pair_wins:                                    # the pristine copies of the windows, the tables included
        po = 0
        for a_, n_ in pair_wins:
            mem[(PAIR_PRIST + po) // 2:(PAIR_PRIST + po + n_) // 2] = mem[a_ // 2:(a_ + n_) // 2]
            po += n_
    with open(os.path.join(HERE, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    # the +UOK ranges, 64 pairs: the inline program, the user stack, every page
    # the cases put code or data in or make invalid (xsweep: its own list)
    rng = uok_ranges() if CASESET == "xsweep" else [(ORG, BERR), (0x8000, 0x9000)]
    for pg in sorted(touched):
        lo, hi = pg << 12, (pg + 1) << 12
        if rng and rng[-1][1] == lo and rng[-1][0] >= 0x9000:
            rng[-1] = (rng[-1][0], hi)
        else:
            rng.append((lo, hi))
    assert len(rng) <= 64, len(rng)
    with open(os.path.join(HERE, "uok.hex"), "w") as f:
        for lo, hi in (rng + [(0, 0)] * 64)[:64]:
            f.write("%08x\n%08x\n" % (lo, hi))
    with open(os.path.join(HERE, "stop_at.txt"), "w") as f:
        f.write("%x %d\n" % (at["fin"], len(expect)))
    with open(os.path.join(HERE, "expect.txt"), "w") as f:
        for a, v, what in expect:
            f.write("%08x %08x %s\n" % (a, v, what))
    with open(os.path.join(HERE, "listing.bin"), "wb") as f:
        f.write(b"".join(x.to_bytes(2, "big") for x in mem[ORG // 2:(EXC + 0x40) // 2]))
    print("predec_fault: %d cases (%s), %d invalid pages, CACR $%X, handler %s%s, TC $%08X, STOP at $%X" % (len(cases), CASESET, handled, CACR, HANDLER, (" (exit CACR $%X)" % CACRX) if H_FULL else "", TC, at["fin"]))


if __name__ == "__main__":
    main()
