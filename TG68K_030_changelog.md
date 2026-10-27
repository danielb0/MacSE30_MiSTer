# The SE/30 core's 68030: changes to the TG68K kernel, the PMMU, and a new 68882

Daniel Baum, 2026-10-24, updated 2026-10-27 (fixes 37-44). The CPU of the Macintosh SE/30
and IIcx MiSTer cores, measured against where it came from:

| file | baseline |
|---|---|
| `TG68KdotC_Kernel.vhd`, `TG68K_ALU.vhd`, `TG68K_Pack.vhd`, `TG68K_PMMU_030.vhd` | apolkosnik/Minimig-AGA_MiSTer, branch `030_mmu2`, commit `c3e8a0d` (2026-07-25) |
| `TG68K_ALU.vhd` | plus one hunk from danifunker/MacIIvi_MiSTer `498eb34`: the DIVU divide-by-zero CCR correction |

Everything was built to Motorola's documentation (the MC68030 User's Manual, 3rd edition;
the MC68881/MC68882 User's Manual; the M68000 Family Programmer's Reference Manual). MAME and
WinUAE were cross-checks, never the specification. Commit hashes refer to the SE/30 project's
development history.

## New hardware

- **The 68030's 32-bit bus.** The kernel's beat engine moves n bytes a beat, sizes the port
  dynamically from DSACK (UM Table 7-1), places the bytes on the lanes the address names
  (Tables 7-4, 7-7), and prefetches the aligned long with a holding register. A 16-bit shape
  remains for 16-bit hosts (`DATA_WIDTH` generic).
- **The instruction and data caches** (UM section 6; new - upstream's `TG68K_Cache_030.vhd` is
  not used): 16 lines of four longs each, entry by entry, logically tagged with the function
  code, the data cache write-through with write-allocate; CACR's enable, freeze and clear bits
  and CAAR; CDIS*. No burst fills (the SE/30 never runs bursts).
- **The coprocessor interface** (UM section 10): cpGEN, cpScc, cpDBcc, cpTRAPcc, cpBcc,
  cpSAVE and cpRESTORE, with every operand transfer and EA mode including the full extension
  format, the mid-instruction frame `$9`, and a bus error or page fault at any beat of a dialog,
  stacked in a long `$B` frame and resumed at that beat by RTE (UM 10.5.2.8).
- **A 68882** (new, `rtl/fpu`): the BIU, CU and a microcoded APU with a 67-bit datapath, written
  from the 68882 manual; the CU's concurrent FMOVEs and instruction queue; FSAVE/FRESTORE
  frames; checked against WinUAE's cputest 6888x corpus. Execution times follow the manual's
  Table 8-3.
- **Same-clock ATC hits:** a clean ATC hit answers in the clock the logical address appears,
  with four copies of the entries compared at the TC page size.
- **Optional, SE/30-specific:** a write pending buffer, and a pace that holds each instruction
  to the UM's section 11 times (so software timing loops run at the real machine's speed).

## Bug fixes (44)

### Bus and bus errors

1. MOVEM on the 32-bit port put the next register 2 bytes on (the ALU's 16-bit constants).
2. An external bus error on a data read resumed one word into the next instruction; it now
   restarts the instruction with DF set, as a PMMU data fault does (UM 8.2).
3. An external bus error on a write took the wrong path; it restarts with the instruction's
   PC in the frame (UM Table 8-6).
4. A bus error completed in software (the handler fixes the access, clears DF, RTE) was run
   again.
5. PMOVE of CRP/SRP from memory read its low long at EA + 2 on the 32-bit port.
6. CMPM.L and ADDX.L -(Ay),-(Ax) lost the first operand's upper word when the long came in
   one 32-bit beat.
7. CHK2/CMP2's step to the upper bound used the 16-bit-bus constant.
8. CLR, Scc and MOVE from SR/CCR read their memory destination (the 68000 does; the 68030's
   timing tables list no read).
9. The PMMU walker could start a cycle on a stale request after an acknowledge (wrapper).
10. A write to an invalid page reached memory before its fault dispatched (wrapper).
11. The Minimig's shared-memory window (`$00DD4000-$00DD5FFF`) bypassed the PMMU: with
    translation on, accesses there took the PMMU's last physical address. Removed for the
    Macintosh, where it is RAM. **An Amiga core needs it**; it should become a generic option.

### Exceptions, stack frames and RTE

12. A user-mode RTR popped its CCR and PC with the supervisor function code (every Unix signal
    return failed).
13. Format `$A`: the continuation PC after a write fault counted a brief-format d8(An,Xn) one
    word long.
14. Format `$A`: a split operand's later beat stacked the operand's size, not the faulted
    cycle's (UM 8.2.2: the bytes still to go, the DOB right-justified).
15. A data beat the PMMU faulted did not end its operand; the next beat ran and was stacked.
16. JSR and BSR were resumed from a short frame after their push faulted, skipping the
    subroutine; they now take the long frame and re-run.
17. A bit field's first write took the short frame; its fifth byte's SIZE was wrong.
18. A bit field's last write is replayed alone; CAS, CAS2 and TAS fault on a write-protected
    page at their read (UM 9.5.3.1).
19. An RTE back into a coprocessor dialog skipped the deferred supervisor-to-user A7 swap.
20. An exception before a handler's first instruction re-stacked the coprocessor's frame
    instead of a format `$0` at the handler.

### Instruction restart after page faults

21. A fetch fault on an instruction's own extension words was dropped when decode was idle;
    the instruction then consumed garbage. It now restarts when the word is used (UM 8.1.2).
22. A page-faulted write after a full-format EA resumed one word late.
23. Instruction-fetch page faults resumed at the wrong place for 11 instruction shapes.
24. The restart's CCR snapshot rolled back past the previous instruction's flag write.
25. A fetch-faulted instruction drained with its bus cycles live: reads, writes and jumps at
    addresses built from garbage words.
26. A restart's second rollback kept a faulted instruction's late write of A7.
27. A long branch's second displacement word was not a consumer of its fetch.
28. A DIVU/DIVS whose operand faulted took a zero-divide trap from the garbage and returned to
    user code in supervisor mode.
29. An FPU instruction's immediate long whose second word page-faulted resumed by fetching the
    first word again.
30. An F-line instruction whose second word's fetch faulted hung the CPU (cpGEN and PMOVE
    decode).

### MOVES and the PMMU

31. MOVES Rn,(d16,An) / (xxx) whose write page-faulted resumed one word early.
32. A (xxx).L or (d16,An) MOVES after an (An)-form one took its address from the base
    register.
33. MOVES.L An,(An)+ / -(An) stored the old An in the long's first beat (PRM: the updated one).
34. The PMMU's EA path's own extension-word fetches armed no restart (a faulted d16 stored TC
    at the wrong address).
35. PMOVE's FD came from a register a clock or more stale: a PMOVE read just before
    PMOVE (An),CRP loaded the root pointer without flushing the ATC, and the next process ran
    on the previous one's translations.
36. The coprocessor's EA lacked the full extension format (an F-line on `FMOVE ([bd],od)`).

### Since 2026-10-24: bus errors with interrupts, completion and trace

37. An external bus error on a data read was lost when an interrupt arrived during the cycle:
    the read completed with the bus's junk, the interrupt was taken, and the bus error surfaced
    at the handler's first instruction with the mask left raised. The bus error now wins on the
    edge it arrives (group 0 before group 1, UM 8.1). Found on the board: the game The Pawn
    (1986) reads an empty slot with interrupts open.
38. The same read's frame stacked condition codes computed from the junk operand; the CCR is
    now restored to its value before the instruction (UM 8.2.2).
39. A handler that completes a faulted access (DF cleared, UM 8.2.1) hung any instruction
    whose later access also faulted (MOVEM, a read-modify-write): the kernel re-executes the
    instruction, so its earlier accesses went out again and faulted again. Each data operand
    now has an ordinal within its instruction; reads are logged, and the re-execution takes
    the operands before the fault from the log, the faulted one from the DIB (sign-extended),
    and runs only the later ones on the bus.
40. CAS, CAS2 and TAS (locked cycles, RM set) took a bus error with the prefetch pointer in the
    frame, resumed past the instruction under a rerun handler, and kept junk in CAS's compare
    register. They now restart with the instruction's PC and their registers rolled back; an
    RTE of an RM=1, DF=0 frame resumes after the instruction (the handler emulated it, UM
    8.2.2), CAS2's six bytes counted.
41. A handler that completes a split operand's later cycle (a long across a bus-error
    boundary, a bit field's fifth byte) lost the bytes the first cycle had read; the DIB holds
    only the bytes remaining, right-justified (UM 8.2.2), and they are now joined.
42. PACK and UNPK -(Ax),-(Ay) read their destination before writing it (the timing table's
    11(1/0/1): one read, one write); a fault on the write reported a read in the SSW. As 8.
43. With the PMMU on, the destination read that 8 and 42 answer without a bus cycle was still
    translated: on an invalid page CLR, Scc, MOVE from SR/CCR and PACK/UNPK faulted as a READ.
    The read is now untranslated and the write faults as a write.
44. A traced instruction lost its trace across a bus error in three ways (UM 8.1.7: the trace
    follows the resumed instruction's completion): a MOVE to a register completed by the
    handler skipped it and traced the next; a CAS/TAS the handler completed was not traced; and
    a traced JMP/JSR into an empty slot let the target's fetch fault win over the trace. A
    prefetch fault is now taken only when the word is used (UM 8.1.2), after the trace.

## Known open (deferred)

- A PMMU instruction's full-format EA is wrong when no fault occurs.
- `PMOVE.W (xxx).L,MMUSR` reads the word at the operand + 2.
- The kernel accepts PMOVE with a Dn or An operand, which the 68030 has no form for.
- CAS/CAS2/TAS set the M bit at the write, not at the RMC read as UM 9.5.3.1 says.

No known software uses these forms.

- A bus-error frame's pipe stage words (stage B, the DOB on a read) are not the UM's; nothing
  reads them on the way back.
- Completion (fix 39) holds 32 operands an instruction; a bus error inside the handler loses
  the outer instruction's log; DF set still re-runs the whole instruction.
- A five-byte bit field whose first (long) cycle is completed by the handler gets its fifth
  byte from the replay instead of a second bus cycle.

## How it was tested

Seam benches in ModelSim and Icarus Verilog: the bus beats at every port size and alignment;
the ROM's MMU contract on the PMMU alone; generated sweeps of fault transparency (every split
point of every extension-word and operand shape faulted, user and supervisor, caches on and
off, interrupts at every clock around a fault, copy-on-write straddles, page-table pointers
invalid or write-protected, random programs compared run against run; an interrupt at every
clock of every external bus-error and trap shape, under handlers that abort, rerun and
complete, with trace on and off, on the SE/30 and the IIcx's NuBus timeout); the 68882 against
WinUAE's corpus and a bit-exact model. On the board: Mac OS 6.0.5-7.5.5 and A/UX 3.1 with its
X11 clients, for days under load; The Pawn's empty-slot read (fix 37) on both cores. The
benches belong to the SE/30 project and can be shared.

## Licence

LGPL-3.0-or-later, as the TG68K files' headers. The 68882 is GPL-2.0-or-later with the rest of
the core.
