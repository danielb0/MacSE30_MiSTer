# The MC68030's side of the M68000 coprocessor interface: an implementation specification

For the engineers adding the MPU half of the coprocessor interface to the TG68K-derived
kernel (`rtl/tg68k/TG68KdotC_Kernel.vhd`). The kernel talks to a 68882 over real
CPU-space bus cycles.

## 0. Sources, conventions, scope

- **UM** is the *MC68030 Enhanced 32-Bit Microprocessor User's Manual*, 3rd ed. (1990).
  Citations have the form `UM 10.4.9 p.10-44`. Section 10 is the primary source. Section 8
  (exceptions) and Section 9.2.1 (the MMU) are cited where Section 10 defers to them. **For
  the MPU's behaviour, the UM governs.**
- **881UM** is the *MC68881/MC68882 Floating-Point Coprocessor User's Manual* (NXP/Freescale
  reprint). It is the coprocessor's view and is used only as a secondary source. Every
  disagreement with the UM is listed in section 12.
- Figures and tables were read from the PDF page images, not from the OCR text.
- Tags used below:
  - **[UM]**: stated by the 030 manual.
  - **[881UM]**: stated only by the FPU manual.
  - **[inferred]**: follows from UM statements, but no sentence states it.
  - **[silent]**: the manual does not say. An implementation choice is required, and one is
    recommended where possible.
- **68882-used** marks the parts the 68882 actually exercises (plan §8.6.12 and 881UM
  Table 7-7). The kernel needs only these to run the FPU. The remainder is specified so that
  the core matches a real 68030. Behaviour for anything left unimplemented is covered in 11.3.
- Word and long CIRs are big-endian and MSB-aligned on D31-D0.

---

## 1. Bus level

### 1.1 CPU-space addressing of the CIRs [UM 10.1.4.2 p.10-6..10-8, Fig. 10-3 p.10-7; UM 7.4.3 p.7-74]

| signal | value during every coprocessor access |
|---|---|
| FC2-FC0 | `111` (CPU space) |
| A31-A20 | 0 |
| A19-A16 | `0010` (CPU space type $2, coprocessor access) |
| A15-A13 | CpID, copied from bits 11-9 of the F-line operation word |
| A12-A5 | 0 |
| A4-A0 | CIR offset (Fig. 10-5) |

So the CIR base for CpID *n* is `$0002_0000 + n*$2000`. For the 68882 at CpID 1 the base is
`$0002_2000`, and its registers occupy `$0002_2000-$0002_201F` (UM Fig. 10-4 p.10-8).

- The MPU never generates a coprocessor cycle with CpID 0. Those cycles can be produced only
  by MOVES [UM 10.1.3 p.10-4, 7.4.3 p.7-74].
- CIR cycles are never burst and never cached [UM p.10-7; data cache 6.1.2]. They are not
  translated by the MMU: FC=7 addresses go straight out as physical [UM 9.2.1].
- A CIR cycle may end with asynchronous (DSACKx) or synchronous (STERM) termination
  [UM 10.1.1 p.10-2, p.10-7]. The 68881/68882 use DSACKx and, on a 32-bit bus, present every
  word register on D31-D16 (DSACK1 only) regardless of A1 [881UM 7.2].

### 1.2 The CIR map [UM 10.3 p.10-29..10-33, Fig. 10-5 p.10-9]

| offset | CIR | width | MPU access | used by the MPU for |
|---|---|---|---|---|
| $00 | response | 16 | read | every primitive read (general and conditional) |
| $02 | control | 16 (bits 1-0 defined) | write | `$0002` = XA exception acknowledge, `$0001` = AB abort; bits 15-2 undefined [UM 10.3.2 p.10-30] |
| $04 | save | 16 | read | starts cpSAVE; format word |
| $06 | restore | 16 | write, then read | starts cpRESTORE; the read returns the validated format word |
| $08 | operation word | 16 | write | transfer-operation-word primitive |
| $0A | command | 16 | write | starts cpGEN |
| $0C | reserved | | never accessed | |
| $0E | condition | 16 | write | starts the conditionals |
| $10 | operand | 32 | read/write | every operand and state-frame transfer |
| $14 | register select | 16 | read | register masks and control-register select codes |
| $16 | reserved | | never accessed | |
| $18 | instruction address | 32 | write (read only by transfer-SR/scanPC with SP=1, DR=1) | the PC bit; scanPC transfers |
| $1C | operand address | 32 | write (eval-and-transfer-EA); read (take-address) | |

**Access sizes [inferred].** The UM gives register widths but no SIZ values. The inferred
rules:

- 16-bit CIRs use word cycles at their own offset.
- 32-bit CIRs use long cycles.
- Operand-CIR transfers use long cycles for each whole 4 bytes. A tail of 1, 2 or 3 bytes is
  a byte, word or 3-byte cycle at offset $10, MSB-aligned [UM 10.3.8 p.10-32, Fig. 10-21].
- Transfer-from-instruction-stream sends its last 2 bytes with a word write [UM 10.4.7
  p.10-42].

### 1.3 "No coprocessor": the initiating access [UM 10.5.2.2 p.10-68; 10.5.2.8 p.10-72; 8.1.5 p.8-10]

If BERR terminates **the CIR access that initiates a coprocessor instruction**, the MPU
assumes the coprocessor is absent and takes an **F-line emulator exception**:

- vector 11 (offset $02C)
- four-word frame, format $0: SR, then PC = the address of the F-line operation word
- **no write to the control CIR**

RTE retries the instruction. An emulating handler must advance the stacked PC itself.

The initiating access for each instruction type:

| instruction | initiating CIR access |
|---|---|
| cpGEN | write command CIR ($0A) |
| cpBcc, cpScc, cpDBcc, cpTRAPcc | write condition CIR ($0E) |
| cpSAVE | read save CIR ($04) |
| cpRESTORE | write restore CIR ($06). This follows the memory read of the format word at `<ea>`. A BERR on that memory read is an ordinary bus error. |

A BERR on any **other** CIR access, or on any memory access made during a coprocessor
instruction, is an ordinary **bus error**: vector 2, a bus-fault frame. After the handler
fixes the cause, RTE resumes inside the coprocessor instruction at the faulted point
[UM 10.5.2.8 p.10-72].

**Order of checks.** A user-mode cpSAVE or cpRESTORE takes the privilege violation *before*
any CIR access. So with no coprocessor fitted, user-mode FSAVE gives vector 8, not
vector 11 [UM 10.2.3.3.2 p.10-26, 10.5.2.3 p.10-69].

---

## 2. Decoding the F-line operation word

### 2.1 Format [UM 10.1.3 p.10-4, Fig. 10-1]

The operation word is `1111 CpID[11:9] TYPE[8:6] <type-dependent>[5:0]`.

| CpID | TYPE [8:6] | meaning |
|---|---|---|
| 000 | 000 | on-chip PMMU instructions (not this interface) |
| 000 | ≠000 | unimplemented F-line: vector 11 (8.1.5 adds a privilege case for undefined PMMU patterns in user mode) |
| 001-111 | 000 | cpGEN |
| 001-111 | 001 | cpScc, cpDBcc or cpTRAPcc, selected by bits 5-0 (below) |
| 001-111 | 010 | cpBcc.W |
| 001-111 | 011 | cpBcc.L |
| 001-111 | 100 | cpSAVE |
| 001-111 | 101 | cpRESTORE |
| 001-111 | 110, 111 | **F-line exception with no coprocessor communication** [UM 10.5.2.2 p.10-68] |

CpID 001-101 are reserved for Motorola and 110-111 for users. 001 is the MC68881/68882
[UM p.10-4].

Within TYPE 001:

| bits 5-3 | bits 2-0 | instruction |
|---|---|---|
| 001 | Dn | cpDBcc (bits 8-3 = `001001`) [UM 10.2.2.3.1 p.10-17] |
| 111 | 010 | cpTRAPcc.W: one operand word |
| 111 | 011 | cpTRAPcc.L: two operand words |
| 111 | 100 | cpTRAPcc: no operand words |
| other | other | cpScc, where bits 5-0 are an EA |

The cpTRAPcc opmodes come from UM Table 10-1 p.10-19. Other opmodes are invalid for
cpTRAPcc [UM p.10-19]. Mode 7 with register 000 or 001 decodes as cpScc (abs.W or abs.L);
register 101-111 maps to no instruction.

**Rule [UM 10.5.2.2 p.10-68].** An operation word with TYPE 000-101 that "does not map to one
of the valid coprocessor instructions" takes an F-line exception **without any CIR access
and without a control-CIR write**. That makes the following decode-time F-lines [UM +
inferred]:

- **cpScc** whose EA is not data alterable [UM 10.2.2.2 p.10-15 calls the destination "a
  data alterable byte"]. After cpDBcc and cpTRAPcc are carved out, what remains is mode 000
  (Dn is legal), and mode 7 register 101-111.
- **cpTRAPcc** opmode 101, 110 or 111 (mode 7).
- **cpSAVE** whose EA is not control alterable or -(An) [UM 10.2.3.3.1 p.10-25].
- **cpRESTORE** whose EA is not in the allowed set. The UM says "all memory addressing modes
  except predecrement" [UM 10.2.3.4.1 p.10-27]; the 881UM says control or (An)+ only. See
  section 12, item 3.
- **cpGEN** with any EA field is legal at decode. Bits 5-0 are a don't-care unless a
  primitive asks for an EA [UM 10.2.1.1 p.10-10]. EA checks are made per primitive.
- **cpBcc**: any condition selector (bits 5-0) is legal.

**[silent]** For cpSAVE or cpRESTORE in user mode *with* an invalid EA, the UM does not say
whether F-line or privilege violation wins. UM Table 8-5 puts both in the same group, 3.0.
Recommendation: check privilege first, as 8.1.5 does for undefined PMMU words in user mode.

### 2.2 Privilege checks

- cpSAVE and cpRESTORE are privileged. If S=0, the MPU takes a privilege violation (vector 8,
  frame $0, PC = the operation word) **before any CIR access** [UM 10.2.3.3.2 p.10-26,
  10.2.3.4.2 p.10-29, 10.5.2.3 p.10-69, 8.1.6 p.8-11].
- cpGEN and the conditionals are not privileged. A coprocessor makes one of them privileged
  with the supervisor-check primitive (5.3).

---

## 3. Common machinery

### 3.1 MPU registers the dialog needs [UM 10.4.1 p.10-34]

| register | contents |
|---|---|
| **PC** | The address of the F-line operation word, held for the whole instruction. It is the value passed by the PC bit and stacked as "PC" / "program counter" in every coprocessor frame. |
| **scanPC** | Walks the instruction's remaining words. It advances by 2 per word consumed, and at completion it becomes the next PC (for general instructions). |
| **tempEA** | The last effective address evaluated by eval-and-transfer-EA, eval-EA-and-transfer-data or transfer-multiple-coprocessor-registers. Used by write-to-previous-EA and stored in the frame $9 EA field [UM 10.4.10 p.10-46/47, 10.4.19 p.10-59]. |
| **opword** | Stored in frame $9. |
| **category** | General, conditional, save or restore. |
| **trace-pending** | See 3.6. |

**scanPC when the first primitive is read** [UM 10.4.1 p.10-34]:

| instruction | scanPC points to |
|---|---|
| cpGEN | PC+4 (the word after the command word) |
| cpBcc | PC+2 (the word after the operation word) |
| cpScc, cpDBcc, cpTRAPcc | PC+4 (the word after the condition word) |
| cpSAVE, cpRESTORE | PC+2 (the EA extension words; there are no primitives) [inferred] |

**scanPC when the coprocessor ends the dialog** [UM p.10-34]:

- **General:** scanPC must point to the next instruction's operation word. The MPU copies it
  to PC.
- **Conditional:** scanPC must point to the word after the last coprocessor-defined extension
  word. The MPU then consumes the displacement, the EA extensions or the trap operand words
  itself.

### 3.2 Response-primitive word [UM 10.4.2 p.10-35, Fig. 10-22]

`CA[15] PC[14] DR[13] FUNCTION[12:8] PARAMETER[7:0]`

- **CA = 1, come again:** perform the service, then read the response CIR again.
- **PC = 1, pass PC:** write PC (the address of the F-line operation word) to the instruction
  address CIR ($18, long) **as the first operation** of servicing the primitive. This applies
  to every primitive, including undefined or illegal ones: the PC goes out *before* any
  F-line or protocol-violation processing [UM p.10-35]. (The UM text says "Bit [4]"; the
  figure and every encoding say bit 14. See section 12, item 1.)
- **DR, direction:** 0 = MPU to coprocessor (MPU writes a CIR); 1 = coprocessor to MPU (MPU
  reads a CIR). For primitives with no explicit transfer, DR is fixed by the encoding.

### 3.3 Primitive decode table (bits 13-8) [UM 10.6 p.10-73..10-75; each primitive's figure]

| bits 13-8 | primitive | fixed bits / fields | general | conditional | 68882 |
|---|---|---|---|---|---|
| $00 | — | | PV | PV | |
| $01 / $21 | transfer multiple coprocessor registers (DR=0 / 1) | 7-0 = length | yes | **PV** | **used** (`$810C`, `$A10C`) |
| $02 / $03 / $22 / $23 | transfer SR and scanPC (bit 8 = SP; DR) | 7-0 = 0 | yes | **PV** | |
| $04 | supervisor check | bit 15 shown as 1 | yes (bit 15 ignored) | yes if bit 15 = 1, else PV | |
| $05 / $25 | take address and transfer data | 7-0 = length | yes | CA=1 only (CA=0 is PV) | |
| $06 / $26 | transfer multiple main-processor registers | 7-0 = 0 | yes | CA=1 only | |
| $07 | transfer operation word | 7-0 = 0 | yes | CA=1 only | |
| $08 / $09 | null (bit 8 = IA) | bit 1 = PF, bit 0 = TF, 7-2 = 0 | yes | yes | **used** |
| $0A | evaluate and transfer EA | 7-0 = 0 | yes | **PV** | |
| $0B | reserved | | PV | PV | |
| $0C / $2C | transfer single main-processor register | bit 3 = D/A, 2-0 = register | yes | CA=1 only | **used** (`$8C0r`, `$CC0r`) |
| $0D / $2D | transfer main-processor control register | 7-0 = 0 | yes | CA=1 only | |
| $0E / $2E | transfer to/from top of stack | 7-0 = length | yes | CA=1 only | |
| $0F | transfer from instruction stream | 7-0 = length | yes | CA=1 only | |
| $10-$17 / $30-$37 | evaluate EA and transfer data (bits 10-8 = valid-EA class) | 7-0 = length | yes | **PV** | **used** |
| $18-$1B | reserved | | PV | PV | |
| $1C | take pre-instruction exception | CA shown 0; 7-0 = vector | yes | yes | **used** |
| $1D | take mid-instruction exception | CA shown 0; 7-0 = vector | yes | yes | **used** |
| $1E | take post-instruction exception | CA shown 0; 7-0 = vector | yes | yes | |
| $1F | reserved | | PV | PV | |
| $20 | write to previously evaluated EA | 7-0 = length | yes | **PV** | |
| $24 | busy | bit 15 = 1 in the encoding; 7-0 = 0 | yes | yes | (the 68882 uses null CA=1 instead) |
| $28-$2B | reserved | | PV | PV | |
| $38-$3B | reserved | | PV | PV | |
| $3F | — | | PV | PV | |
| $27, $2F, $3C-$3E | not listed anywhere | | PV (catch-all) | PV | |

PV = protocol violation (7.6). The reserved rows ($00, $3F, $0B, $18-$1B, $1F, $28-$2B,
$38-$3B) come from UM p.10-73. The final row falls under the general rule that "any response
primitive that the MC68030 does not recognize causes it to initiate protocol violation
exception processing" [UM 10.4 p.10-33]. That row is the DR=1 form of a primitive whose DR is
fixed at 0.

**Conditional-category rules** [UM Fig. 10-8 note 1 p.10-13; Table 10-6 p.10-66/67]:

- Every primitive that allows CA, except null, **must** have CA=1 in a conditional. CA=0 is a
  protocol violation.
- These primitives are protocol violations in a conditional regardless of CA: evaluate and
  transfer EA, evaluate EA and transfer data, write to previous EA, transfer multiple
  coprocessor registers, transfer SR and scanPC.

**[silent]** Several encodings are not covered: CA=0 on busy (it becomes bits 13-8 = $24 with
bit 15 clear), CA=1 on take-exception primitives, bit 15 = 0 on supervisor check in a general
instruction (the UM explicitly says this one is ignored), and nonzero values in parameter bits
drawn as 0 (for example, null bits 7-2). Recommendation: ignore CA on busy and take-exception
primitives (decode on bits 13-8), and ignore don't-care parameter bits.

### 3.4 General-category algorithm [UM 10.2.1.2 Fig. 10-7 p.10-11; 10.4.4; 10.5.2.5]

```
M1  decode (2.1). If invalid: F-line, frame $0, no CIR access.
M2  write command word (the word at PC+2) to command CIR ($0A).
    BERR here -> F-line (1.3).
    scanPC := PC+4.
M3  loop:
      p := read response CIR ($00)
      if p.PC: write PC -> instruction address CIR ($18)          [first, always]
      dispatch on p (section 5); a primitive may
        - raise an exception (ends the instruction; see 7), or
        - restart the instruction (busy), or
        - perform a service.
      after the service:
        if p.CA = 1: continue loop
        else if trace-pending and not (p is null with PF=1): continue loop
             [UM p.10-12, 10-38, 10-70]
        else: exit loop
M4  PC := scanPC; instruction complete (a pending trace or interrupt is taken now).
```

Null primitives are handled in the dispatcher, per 5.2.

### 3.5 Conditional-category algorithm [UM 10.2.2 Fig. 10-8 p.10-13]

```
M1  decode.
M2  write condition CIR ($0E):
      cpBcc:                    the operation word itself (condition = bits 5-0)  [UM p.10-14]
      cpScc, cpDBcc, cpTRAPcc:  the word at PC+2 (condition = bits 5-0;
                                bits 15-6 "should be zero")                       [UM p.10-16..19]
    BERR here -> F-line (1.3).
    scanPC := PC+2 (cpBcc) or PC+4 (the others).
M3  loop: read response; PC bit; dispatch (conditional legality, 3.3);
          until null with CA=0 arrives (5.2).
M4  complete using TF (section 4).
```

A trace-pending flag does **not** change the conditional protocol [UM 10.5.2.5 p.10-70].

### 3.6 Trace-pending [UM 8.1.7 p.8-12..14; 10.4.17 p.10-56; 10.5.2.5 p.10-70; 10.5.2.6 p.10-71]

The T1:T0 value in effect when the instruction begins decides tracing.

- **T1:T0 = 10 (trace every instruction), general category.** Trace-pending is true for the
  whole dialog. The MPU keeps reading and servicing the response CIR, even after CA=0
  primitives, until either:
  - it reads a null with CA=0 and PF=1; or
  - exception processing for a take-post-instruction primitive completes.

  It then takes the trace (vector 9, frame $2).
- **T1:T0 = 01 (trace on change of flow), general category.** A trace is taken only if a
  transfer-SR/scanPC primitive with DR=1 was serviced during the instruction. Such a trace
  "occurs when the coprocessor signals that it has completed all processing" [UM 10.4.17].
  However, 10.5.2.5 says the coprocessor "may still be executing concurrently" when the
  handler starts. See section 12, item 9.
- **Conditional, cpSAVE, cpRESTORE.** Normal trace rules apply after completion.
  - Mode 10: always traced.
  - Mode 01: traced when the instruction put a non-sequential address in the PC. That covers
    a taken cpBcc, a cpDBcc branch, and cpTRAPcc taking its trap [inferred from 8.1.7: "all
    ... instruction traps"].

### 3.7 Where the MPU services interrupts inside a coprocessor instruction [UM 10.5.2.6 p.10-71]

| point | frame | RTE resumes by |
|---|---|---|
| null CA=1, IA=1 (general or conditional) | **$9** (10 words) | re-reading the response CIR |
| trace-pending general instruction, null CA=0, IA=1, PF=0 | **$9** | re-reading the response CIR |
| busy primitive | **$0**, PC = the operation word [UM 10.4.3 p.10-36] | restarting the instruction |
| cpSAVE "not ready" format word | **$0**, PC = the operation word | restarting cpSAVE (the save CIR is read again) |
| cpRESTORE "not ready" | none: interrupts are **not** serviced [UM 10.2.3.2.2 p.10-23] | |
| null CA=1, IA=0 | none: the MPU just re-reads | |

If no interrupt is pending at a point marked "service pending interrupts", the MPU proceeds
straight on: it re-reads, or restarts in the busy case [inferred from Table 10-3 and
Fig. 10-16].

If the M bit is set, interrupt processing also builds a throwaway frame, format $1, on the
interrupt stack [UM 8.1.9 p.8-21].

### 3.8 Control-CIR writes, the complete list [UM 10.3.2 p.10-30]

| mask written | when |
|---|---|
| **XA `$0002`** | On receiving any of the three take-exception primitives, after the PC pass and before stacking [UM 10.4.18-10.4.20]. |
| **AB `$0001`** | (a) An F-line condition detected after reading a response primitive: an EA-class mismatch in eval-EA-and-transfer-data, a non-control-alterable EA in eval-and-transfer-EA, or an invalid EA in transfer-multiple-coprocessor-registers. |
| | (b) A privilege violation from the supervisor-check primitive. |
| | (c) A format error: an invalid format word ($02xx, or the reserved $03xx-$0Fxx), or a valid format word whose length is not a multiple of 4 [UM 10.2.3.2.3 p.10-23]. |

The MPU writes **nothing** to the control CIR in these cases:

- protocol violations [UM p.10-67];
- F-line exceptions found at decode, or caused by a BERR on the initiating access
  [UM 10.5.2.2 p.10-68].

---

## 4. The instructions

In every diagram the operation word is at PC. "Ext" means coprocessor-defined extension words,
which the coprocessor consumes through primitives.

### 4.1 cpGEN [UM 10.2.1 p.10-9..12, Fig. 10-6]

```
PC+0  1111 CpID 000 EA[5:0]
PC+2  command word                 -> command CIR ($0A)
PC+4  EA extension words and/or coprocessor-defined extension words, in the order the
      primitives consume them
```

- Protocol as in 3.4. Completion: PC := scanPC.
- Not privileged.
- Any EA field is legal at decode; EA legality is checked per primitive.
- 68882-used: every arithmetic, FMOVE, FMOVEM and FMOVECR instruction.

### 4.2 cpBcc.W / cpBcc.L [UM 10.2.2.1 p.10-13..15, Figs. 10-9/10-10]

```
PC+0  1111 CpID 01s cond[5:0]      the whole word -> condition CIR   (s = 0: .W, 1: .L)
PC+2  ext (0..n)
      disp16            (.W)
      disp32 hi, lo     (.L)
```

- When the dialog ends (null CA=0), scanPC points at the first displacement word.
- **TF = 1:** PC := scanPC + sign-extend(disp). scanPC must point to the displacement's
  first word when the address is computed.
- **TF = 0:** PC := scanPC + 2 (.W) or + 4 (.L), the next instruction.
- An odd target gives an address error on the prefetch [UM 10.5.2.8 p.10-72].
- 68882-used: FBcc, and FNOP (which is FBF.W with displacement 0, `$F280 $0000`).

### 4.3 cpScc [UM 10.2.2.2 p.10-15/16, Fig. 10-11]

```
PC+0  1111 CpID 001 EA[5:0]        (EA data alterable)
PC+2  0000000000 cond[5:0]         -> condition CIR
PC+4  ext (0..n)
      EA extension words (0..5)
```

After null CA=0, the MPU evaluates the EA using the extension words at scanPC (+2 per word),
then writes the byte: `$FF` if TF = 1, `$00` if TF = 0. PC := scanPC.

**[silent]** Whether the EA is evaluated only after the dialog: the text says the MPU
"evaluates the effective address" on receiving TF, and the extension words sit after the
coprocessor's words, so the EA *cannot* be evaluated earlier. For -(A7)/(A7)+ byte
destinations the usual M68000 ±2 rule applies [UM 2.x; not restated in §10]. Whether the
byte store is a plain write or a read-then-write is not stated [silent]. Recommendation:
plain write, as for Scc on the 68030.

### 4.4 cpDBcc [UM 10.2.2.3 p.10-17/18, Fig. 10-12]

```
PC+0  1111 CpID 001 001 Dn         (Dn = counter)
PC+2  0000000000 cond[5:0]         -> condition CIR
PC+4  ext (0..n)
      disp16
```

- **TF = 1:** PC := scanPC + 2.
- **TF = 0:** Dn[15:0] := Dn[15:0] - 1. Then:
  - if Dn[15:0] = $FFFF: PC := scanPC + 2;
  - otherwise PC := scanPC + sign-extend(disp16), with scanPC pointing at the displacement.

### 4.5 cpTRAPcc [UM 10.2.2.4 p.10-18..20, Fig. 10-13, Table 10-1; 10.5.2.4 p.10-69]

```
PC+0  1111 CpID 001 111 opmode     (010: 1 word, 011: 2 words, 100: 0 words)
PC+2  0000000000 cond[5:0]         -> condition CIR
PC+4  ext (0..n)
      operand words (0, 1 or 2)    never read by the MPU
```

After null CA=0 the MPU advances scanPC past the operand words.

- **TF = 0:** PC := scanPC.
- **TF = 1:** trap exception, vector 7 (offset $01C), **frame $2**:
  - scanPC field = the address of the next instruction;
  - PC field = the address of the cpTRAPcc.

  RTE continues at the next instruction.

### 4.6 cpSAVE and 4.7 cpRESTORE

Both are specified in section 8.

---

## 5. The response primitives

For every primitive, step 0 is **"if PC=1, write PC to $18"**. It is not repeated below.
"Frame $0 / $2 / $9" refers to section 7. "Abort" means writing `$0001` to control; "XA"
means writing `$0002`.

### 5.1 Busy: `1 PC 1 00100 00000000` ($A400 / $E400) [UM 10.4.3 p.10-36/37]

- Allowed in general and conditional.
- Action: service pending interrupts using **frame $0** with PC = the operation word. Then
  **restart** the instruction: rewrite the command or condition CIR and reset scanPC. RTE
  from an interrupt taken here also restarts the instruction.
- The coprocessor should issue busy only as the first primitive, before any
  program-visible change. The MPU does not check this [UM p.10-37].
- Breakpoint special case [UM p.10-37]: if the instruction was supplied by a breakpoint
  acknowledge cycle, busy comes back, and an interrupt is pending, then after the interrupt
  the MPU **re-runs the breakpoint acknowledge cycle**. (This only matters if the core
  implements BKPT replacement.)
- Not used by the 68882.

### 5.2 Null: `CA PC 0 0100 IA 000000 PF TF` ($0800 base) [UM 10.4.4 p.10-37..39, Table 10-3] — 68882-used

| CA | IA | PF | general | conditional |
|---|---|---|---|---|
| 1 | 0 | x | re-read the response, no interrupts | same |
| 1 | 1 | x | service pending interrupts (**frame $9**), then re-read | same |
| 0 | 0 | 0 | trace-pending: re-read; otherwise the instruction is done (released) | done: complete using TF |
| 0 | 1 | 0 | trace-pending: service interrupts (**frame $9**), re-read; otherwise done | done: complete using TF |
| 0 | x | 1 | done ("coprocessor instruction completed"); then pending exceptions, including trace | done: complete using TF |

- TF matters only for CA=0 in a conditional. PF is ignored in conditionals.
- The 68882 uses these encodings: `$0800`/`$0801` (FALSE/TRUE), `$0802` (idle), `$0900` and
  `$4900` (released while still executing, IA=1), `$8900` and `$C900` (come again, IA=1)
  [881UM Table 7-3, 7-7].

### 5.3 Supervisor check: `1 PC 0 00100 00000000` ($8400 / $C400) [UM 10.4.5 p.10-40]

- **General:** the result is the same whether bit 15 is 0 or 1.
- **Conditional:** bit 15 = 0 is a protocol violation.
- Action:
  - S = 0: abort, then privilege violation (vector 8, **frame $0**, PC = the operation word;
    RTE restarts the instruction) [UM 10.5.2.3 p.10-69].
  - S = 1: read the response again.
- Not used by the 68882.

### 5.4 Transfer operation word: `CA PC 0 00111 00000000` ($0700) [UM 10.4.6 p.10-40/41]

- Conditional with CA=0: protocol violation.
- Action: write the operation word (16 bits) to the operation-word CIR ($08). scanPC is
  unchanged.
- Not used by the 68882. The 68882 ignores writes to $08 [881UM 7.2.5].

### 5.5 Transfer from instruction stream: `CA PC 0 01111 length` ($0Fxx) [UM 10.4.7 p.10-41/42]

- Conditional with CA=0: protocol violation.
- Odd length: protocol violation. Length 0 is legal [Table 10-6].
- Action: copy `length` bytes starting at scanPC to the operand CIR ($10):
  - one long write per 4 bytes;
  - if length mod 4 = 2, the last 2 bytes as one **word write**.

  scanPC advances past each word or long as it is sent, finishing at scanPC + length.
- Not used by the 68882.

### 5.6 Evaluate and transfer effective address: `CA PC 0 01010 00000000` ($0A00) [UM 10.4.8 p.10-42]

- Conditional: protocol violation.
- If the operation word's EA is **not control alterable**: write `$0001` (abort), then
  F-line (frame $0).
- Otherwise evaluate the EA. The EA extension words start at scanPC, which advances by 2 per
  word. Write the 32-bit result to the operand-address CIR ($1C, long). tempEA := EA.
- Not used by the 68882. The 68882 does not implement $1C [881UM 7.2.11].

### 5.7 Evaluate EA and transfer data: `CA PC DR 1 0 class[10:8] length` [UM 10.4.9 p.10-43..45, Table 10-4] — 68882-used

**Valid-EA classes** [UM Table 10-4 p.10-43]:

| class | 000 | 001 | 010 | 011 | 100 | 101 | 110 | 111 |
|---|---|---|---|---|---|---|---|---|
| meaning | control alterable | data alterable | memory alterable | alterable | control | data | memory | any |

The categories are the M68000 ones [UM 2.x Table 2-2]:

- **data:** everything except An;
- **memory:** everything except Dn and An;
- **control:** (An), (d16,An), (d8,An,Xn)/full format, abs.W/L, PC-relative;
- **alterable:** everything except PC-relative and #imm.

**Checks.** The UM does not give an order; see the note below.

- **P1.** Conditional: protocol violation.
- **F1.** The operation word's EA is not in `class`: abort, then F-line (frame $0).
- **P2.** Register direct (Dn or An) and length ∉ {1, 2, 4}: protocol violation (length 0
  included).
- **P3.** Immediate and (DR = 1, or length odd and > 1): protocol violation. An immediate may
  only be 1 byte or an even number of bytes, and only toward the coprocessor.
- **P4.** DR = 1 and the EA is not alterable (PC-relative or #imm), even when the class
  allows it: protocol violation.
- Memory modes accept any length 0-255, including odd.

**Action.**

1. Evaluate the EA. Extension words come from scanPC, which advances by 2 per word.
   - **The calculation is repeated every time this primitive is issued**, with current
     register values and a fresh set of extension words at the current scanPC [UM p.10-45].
   - For **-(An)**, decrement An by `length` first; if n = 7 and length = 1, decrement by 2.
   - tempEA := EA (for -(An), the decremented address) [inferred; see section 12].
2. Transfer `length` bytes. DR = 0 means EA → operand CIR; DR = 1 means operand CIR → EA.
   - **Memory:** ascending addresses from the EA, long-word parts "whenever possible", with a
     1-, 2- or 3-byte tail. Tails are MSB-aligned in the CIR (Fig. 10-21).
   - **Dn, DR = 1:** a byte or word replaces only the low byte or word of Dn; a long replaces
     all of it.
   - **An, DR = 1:** a byte or word is **sign-extended to 32 bits** [UM p.10-45].
   - **Register direct, DR = 0:** the low-order `length` bytes of the register, MSB-aligned
     in the CIR [inferred].
   - **Immediate (DR = 0):** the data are the instruction words at scanPC.
     - For length 1 the byte is the low byte of a single extension word [inferred from the
       M68000 #<byte> encoding].
     - scanPC advances by 2 for length 1 and by `length` otherwise [inferred].
3. For **(An)+**, increment An by `length` after the transfer; if n = 7 and length = 1,
   increment by 2. Odd lengths > 1 with A7 can leave SP odd [UM p.10-45].
4. CA = 1: re-read the response. CA = 0: the instruction ends, unless trace-pending (3.4).

**Function codes.** Memory accesses use user or supervisor data space (FC 1 or 5) according
to S [inferred]. **[silent]** The UM does not say whether PC-relative source reads use
program space (FC 2 or 6), as ordinary 68030 PC-relative operand reads do, or data space.
Only write-to-previous-EA's FC is defined.

**Check order [silent].** The order of P1-P4 and F1 is not specified, nor which wins when
more than one applies. Recommendation: P1 first (category), then F1 (class), then P2-P4. All
checks happen before any bus cycle or register update.

**68882 encodings** [881UM Table 7-5, 7-7]:

| direction | CA=1 forms | CA=1 with PC | CA=0 forms (68882 only) |
|---|---|---|---|
| in | `$9501/$9502/$9504` (class 101); `$9608/$960C` (class 110); `$9704` (class 111, FPIAR, An legal) | `$D5xx/$D6xx` | `$1504/$1608/$160C`; with PC `$5504/$5608/$560C` |
| out | `$B101/$B102/$B104` (class 001); `$B208/$B20C` (class 010); `$B304` (class 011, FPIAR out, An legal) | | `$3104/$3208/$320C` |

**The kernel must support:**

- lengths 1, 2, 4, 8 and 12;
- immediates of 1, 2, 4, 8 and 12 bytes (FMOVE.X #, FMOVEM #,FPcr-list);
- -(A7) and (A7)+ with length 1.

### 5.8 Write to previously evaluated EA: `CA PC 1 00000 length` ($20xx) [UM 10.4.10 p.10-46/47]

- Conditional: protocol violation.
- Length 0-255.
- Action: read the operand CIR and write `length` bytes to **tempEA**, in ascending order,
  as long parts with a 1-, 2- or 3-byte tail.
  - FC = data space per S, whatever mode produced tempEA. PC-relative gets **no** check.
  - **No register update**, even when tempEA came from (An)+ or -(An).
  - The result is undefined if no EA was evaluated in this instruction, or if the last EA was
    register direct.
- The address from take-address-and-transfer-data does **not** replace tempEA.
- The bus cycles are ordinary and interruptible: this is not a locked read-modify-write.
- Not used by the 68882.

### 5.9 Take address and transfer data: `CA PC DR 00101 length` ($05xx / $25xx) [UM 10.4.11 p.10-48]

- General and conditional. Conditional with CA=0: protocol violation.
- Length 0-255.
- Action: read a 32-bit address from the operand-address CIR ($1C). Transfer `length` bytes
  between that address (ascending, long parts, 1-, 2- or 3-byte tail) and the operand CIR.
  DR = 0 means memory → CIR. FC = data space per S.
- Not used by the 68882.

### 5.10 Transfer to/from top of stack: `CA PC DR 01110 length` ($0Exx / $2Exx) [UM 10.4.12 p.10-49]

- Conditional with CA=0: protocol violation.
- Length ∉ {1, 2, 4}: protocol violation.
- Action:
  - **DR = 0:** implied (A7)+. Read `length` bytes at A7 and write them to the operand CIR.
    Then A7 += length (+2 if length = 1).
  - **DR = 1:** implied -(A7). A7 -= length (2 if length = 1). Then write the operand-CIR
    data to A7.
- A7 is the currently active stack pointer.
- Not used by the 68882.

### 5.11 Transfer single main-processor register: `CA PC DR 01100 0000 D/A reg` ($0C0r / $2C0r) [UM 10.4.13 p.10-50] — 68882-used

- Conditional with CA=0: protocol violation.
- Action:
  - **DR = 0:** write the full 32-bit Dn or An (D/A = 1 means An) to the operand CIR (long).
  - **DR = 1:** read a long from the operand CIR into the register.
- The 68882 uses `$8C0r` and `$CC0r` (Dn only, DR = 0) for a dynamic k-factor or a dynamic
  FMOVEM list [881UM 7.4.2.3].

### 5.12 Transfer main-processor control register: `CA PC DR 01101 00000000` ($0D00 / $2D00) [UM 10.4.14 p.10-50/51, Table 10-5]

- Conditional with CA=0: protocol violation.
- Action: read the select code from the register-select CIR ($14, word). Bits 15-12 are
  don't-care ("x" in the table). Valid codes for bits 11-0:

  | code | register |
  |---|---|
  | $000 | SFC |
  | $001 | DFC |
  | $002 | CACR |
  | $800 | USP |
  | $801 | VBR |
  | $802 | CAAR |
  | $803 | MSP |
  | $804 | ISP |

  Any other code: protocol violation. The PMMU registers are not reachable.
- Then DR = 0 writes the register (long) to the operand CIR; DR = 1 reads the operand CIR
  (long) into the register.
- **[silent]** The MPU makes no S check. The coprocessor is expected to use the supervisor
  check first.
- Not used by the 68882.

### 5.13 Transfer multiple main-processor registers: `CA PC DR 00110 00000000` ($0600 / $2600) [UM 10.4.15 p.10-52, Fig. 10-36]

- Conditional with CA=0: protocol violation.
- Action: read a 16-bit mask from $14 (bit 0 = D0 ... bit 7 = D7, bit 8 = A0 ... bit 15 =
  A7). For each set bit, **in the order D0-D7 then A0-A7, in both directions**:
  - DR = 0: long write of the register to $10;
  - DR = 1: long read from $10 into the register.
- Not used by the 68882.

### 5.14 Transfer multiple coprocessor registers: `CA PC DR 00001 length` ($01xx / $21xx) [UM 10.4.16 p.10-52..54, Fig. 10-38] — 68882-used

- Conditional: protocol violation.
- Odd length: protocol violation.
- **EA check:**
  - DR = 0 (memory → coprocessor): control modes or (An)+.
  - DR = 1 (coprocessor → memory): control alterable or -(An).
  - Anything else: abort, then F-line (frame $0).

  The 881UM adds that the abort comes "before reading the register select CIR". Table 10-6
  words this rule differently from the text; see section 12, item 2. **The text governs.**

**Action.**

1. Evaluate the EA (extension words at scanPC, +2 each). tempEA := EA. For -(An), which
   value is stored is [silent].
2. Read the 16-bit register-select CIR ($14). **N = the number of ones** in the mask. Bit
   positions do not matter to the MPU. N may be 0 (nothing moves) [881UM 7.5.1.5]. The total
   transfer is N × length.
3. For each operand i = 0..N-1:
   - **control mode:** operand i is at EA + i·length; bytes ascending.
   - **(An)+ (DR = 0 only):** operand at An, bytes ascending; then An += length. Final An =
     initial + N·length.
   - **-(An) (DR = 1 only):** An -= length first; then the operand's bytes go *ascending*
     from the new An. Operands therefore land at descending addresses; the first operand from
     the CIR occupies initial An - length. Final An = initial - N·length.
   - Each operand moves as long parts, with a word tail if length mod 4 = 2. DR = 1 means
     CIR read → memory write; DR = 0 means memory read → CIR write.
4. CA → re-read; otherwise end (3.4).

The 68882 uses `$810C` (in) and `$A10C` (out), with length 12, CA = 1 and PC = 0.

### 5.15 Transfer status register and scanPC: `CA PC DR 0001 SP 00000000` ($02/$03/$22/$23) [UM 10.4.17 p.10-55/56]

- Conditional: protocol violation.
- Action by case:

  | SP | DR | action |
  |---|---|---|
  | 0 | 0 | SR (16 bits) → operand CIR (word) |
  | 0 | 1 | operand CIR (16 bits) → SR |
  | 1 | 0 | scanPC (long) → instruction-address CIR ($18), **then** SR → operand CIR |
  | 1 | 1 | operand CIR (16) → SR, **then** instruction-address CIR ($18, long read) → scanPC |

- **After DR = 1:**
  - Discard prefetched words beyond scanPC and refill the pipe from scanPC, in the program
    space given by the new S.
  - If T1:T0 was 01 when the instruction began, a trace becomes pending (3.6).
  - New T bits take effect from the next instruction.
  - An odd scanPC gives an address error at the prefetch [UM 10.5.2.8 p.10-72].
- **[silent]** No privilege check (S can be changed). The coprocessor must guard with the
  supervisor check.
- Not used by the 68882.

### 5.16 Take pre-instruction exception: `0 PC 0 11100 vector` ($1Cvv / $5Cvv) [UM 10.4.18 p.10-56..58] — 68882-used

- General and conditional.
- Action: XA (`$0002` → $02), then exception processing with `vector`:
  - **frame $0**, PC = the F-line operation word;
  - RTE **re-initiates the instruction**.
- The 68882 uses it for:
  - an exception pending from an earlier concurrent instruction, `$1C3x`;
  - an illegal command word, `$1C0B` (vector 11);
  - BSUN, `$5C30` (PC = 1).

  All Motorola coprocessors report illegal command or condition words this way, with
  vector 11 [UM 10.5.1.2 p.10-63].

### 5.17 Take mid-instruction exception: `0 PC 0 11101 vector` ($1Dvv) [UM 10.4.19 p.10-58/59] — 68882-used

- Action: XA, then exception processing with **frame $9**. RTE re-reads the response CIR and
  carries on with the dialog.
- The 68882 uses it for FMOVE-out exceptions and exceptions reported by a later instruction.
  `$1D0D` is a coprocessor-detected protocol violation; vector 13 is recommended "for
  consistency" [UM 10.5.1.1 p.10-63].

### 5.18 Take post-instruction exception: `0 PC 0 11110 vector` ($1Evv) [UM 10.4.20 p.10-60/61]

- Action: XA, then exception processing with **frame $2**:
  - scanPC field = scanPC at the moment the primitive was read;
  - PC field = the operation word address.

  RTE continues at the stacked scanPC, "which should be the address of the next
  instruction". For a conditional, see section 12, item 10.
- For a trace-pending general instruction, the trace is taken after this exception
  processing completes (3.6).
- Not used by the 68882.

---

## 6. The PC bit, in one place [UM 10.4.2 p.10-35/36; 10.3.10 p.10-33]

- **When:** whenever the primitive just read has bit 14 = 1, as the **first** action, before
  any other CIR access, bus cycle, protocol check, F-line or protocol-violation processing,
  exception acknowledge, or interrupt service. This holds for every primitive type, including
  undefined and reserved encodings, busy and null (Table 10-3 row 1: "pass PC, clear PC bit,
  proceed").
- **What:** the 32-bit address of the F-line operation word of the current instruction (the
  MPU's PC, not scanPC), long-written to the instruction-address CIR ($18).
- **After RTE from frame $9** the PC is the restored value from the frame, so a later PC
  request passes the same address.
- **68882 requirement:** the 68882 raises a protocol violation if a requested PC is not
  written (the 68881 tolerates it) [881UM 7.2.10, 7.4.2]. It asks only in the first
  primitive of a dialog that can cause an exception, or in BSUN's `$5C30`.
- **Distinct from the PC bit:** transfer-SR/scanPC with SP = 1 writes or reads **scanPC**
  through the same CIR (5.15).

---

## 7. Exceptions

### 7.1 Stack frames (the format word holds format[15:12] and vector offset = vector × 4 in bits 11-0) [UM Figs. 10-41/10-43/10-45; Table 8-6 p.8-33]

The frames are built on the active supervisor stack (MSP or ISP) [UM 8.1 p.8-2].

**Format $0, four words: pre-instruction** (Fig. 10-41 p.10-57):

| offset | field |
|---|---|
| +$00 | SR (the internal copy taken at exception start) |
| +$02 | PC: the F-line operation word address (long) |
| +$06 | `0000` + vector offset |

**Format $2, six words: post-instruction, cpTRAPcc and trace** (Fig. 10-45 p.10-60):

| offset | field |
|---|---|
| +$00 | SR |
| +$02 | scanPC (Table 8-6 calls it "program counter": the next instruction) |
| +$06 | `0010` + vector offset |
| +$08 | PC: the address of the coprocessor instruction (Table 8-6: "instruction address") |

**Format $9, ten words: mid-instruction** (Fig. 10-43 p.10-59):

| offset | field |
|---|---|
| +$00 | SR |
| +$02 | scanPC: the value when the primitive was received (Table 8-6: "program counter ... next word to be fetched") |
| +$06 | `1001` + vector offset |
| +$08 | PC: the operation word address (Table 8-6: "instruction address") |
| +$0C | internal register (one word; contents not defined by Motorola) |
| +$0E | operation word (the F-line word) |
| +$10 | effective address, long: tempEA. **Undefined** if no EA was evaluated before the exception. |

Table 8-6 covers +$0C-+$13 as "internal registers, 4 words", which agrees in size. The
Section 10 figures label bits 11-0 "vector number", but Section 8 stacks the vector *offset*
(see section 12, item 4).

**Format $1, throwaway:** built on the ISP when an interrupt is taken with M = 1
[UM 8.1.9 p.8-21].

### 7.2 Which frame for which event

| event | control CIR | vector | frame | stacked PC field(s) | RTE resumes by |
|---|---|---|---|---|---|
| no coprocessor (BERR on the initiating access) | — | 11 | $0 | operation word | restarting |
| invalid operation word (2.1) | — | 11 | $0 | operation word | restarting |
| EA mismatch in a primitive (5.6, 5.7, 5.14) | abort | 11 | $0 | operation word | restarting |
| cpSAVE/cpRESTORE with S = 0 | — | 8 | $0 | operation word | restarting |
| supervisor check with S = 0 | abort | 8 | $0 | operation word | restarting |
| **protocol violation detected by the MPU** | **—** | 13 | **$9** | scanPC, PC, opword, EA | **re-reading the response** |
| take pre-instruction | XA | from primitive | $0 | operation word | restarting |
| take mid-instruction | XA | from primitive | $9 | scanPC, PC, opword, EA | re-reading the response |
| take post-instruction | XA | from primitive | $2 | scanPC, PC | continuing at scanPC |
| cpTRAPcc true | — | 7 | $2 | scanPC = next instruction, PC | the next instruction |
| format error (cpSAVE/cpRESTORE) | abort | 14 | $0 | operation word | restarting |
| interrupt at null CA=1 IA=1, or at trace-wait IA=1 PF=0 | — | the interrupt's | $9 (+$1 if M) | scanPC, PC, opword, EA | re-reading the response |
| interrupt at busy | — | the interrupt's | $0 | operation word | restarting |
| interrupt at cpSAVE not-ready | — | the interrupt's | $0 | operation word | restarting cpSAVE |
| trace | — | 9 | $2 | next instruction, instruction address | the next instruction |
| BERR on any later CIR or memory access | — | 2 | bus fault ($B mid-instruction) | | resuming at the faulted point |
| odd target or odd scanPC prefetch | — | 3 | bus fault ($A or $B) | | |

Sources: UM 10.5.1.2, 10.5.1.5 p.10-64, 10.5.2.1-10.5.2.8 p.10-65..72, 8.1.2-8.1.9, and
Table 8-6.

**Priorities** [UM Table 8-5 p.8-24]:

| group | exceptions |
|---|---|
| 2.0 (exception processing is part of the instruction) | cp mid-instruction, cp protocol violation, cpTRAPcc |
| 3.0 (before the instruction executes) | cp pre-instruction, unimplemented F-line, privilege violation |
| 4.0 | cp post-instruction |
| 4.1 | trace |
| 4.2 | interrupt |

### 7.3 RTE [UM 8.1.13 p.8-24..27]

| format | RTE action |
|---|---|
| $0 | Restore SR and PC; SP += 8. The coprocessor instruction starts again from the top (it rewrites the command or condition CIR, or re-reads the save CIR). |
| $2 | Restore SR and PC = the stacked scanPC; SP += 12. |
| $9 | Restore SR, PC, scanPC ("instruction address"), the internal register and tempEA; SP += 20. Then **read the response CIR of the coprocessor that initiated the exception** and continue the dialog. |

Notes on the frame $9 RTE:

- **[inferred]** The CpID for that read (A15-A13), and the instruction category (general or
  conditional), must come from the operation word stored at +$0E. Nothing else in the frame
  carries them.
- **[silent]** The internal register at +$0C is not defined. Our core may keep dialog state
  there that the opword and SR cannot rebuild. Recommendation: whether a trace is pending,
  and anything the conditional completion needs.

A bad format code gives a format error (vector 14) with a new four-word frame below the bad
one [UM 8.1.13 p.8-26/27].

### 7.4 Protocol violations detected by the MPU [UM 10.5.2.1 p.10-65..67, Table 10-6]

The complete list is marked PV in 3.3, 5.3-5.15 and 8. Handling:

- PC pass if requested;
- **no** control-CIR write;
- frame $9, vector 13.

RTE re-reads the response CIR. A handler can emulate the primitive after reading the response
CIR with MOVES; the RTE then re-reads it.

**Coprocessor-detected protocol violations** reach the MPU as a take-mid-instruction
primitive with vector 13 [UM 10.5.1.1 p.10-62/63]. A coprocessor cannot report a protocol
violation during cpSAVE or cpRESTORE. It reports it at the next instruction.

---

## 8. cpSAVE and cpRESTORE in detail

### 8.1 Format words [UM 10.2.3.2 Table 10-2 p.10-22]

The format word is `code[15:8] length[7:0]`. The length is in bytes, must be a multiple of 4,
and excludes the format word and its companion reserved word.

| code | meaning | MPU action |
|---|---|---|
| $00 | empty/reset | cpSAVE: store the 4-byte frame and finish. cpRESTORE: finish after the handshake. The length byte is ignored. |
| $01 | not ready, come again | cpSAVE: service pending interrupts (frame $0), then re-read the save CIR. cpRESTORE: re-read the restore CIR **without** servicing interrupts. |
| $02 | invalid format | abort, then format error |
| $03-$0F | undefined, reserved | treated as **invalid**: abort, then format error |
| $10-$FF | valid, coprocessor defined | transfer `length` bytes. If length mod 4 ≠ 0: abort, then format error [UM 10.2.3.2.4 p.10-24] |

For the 68882 the valid frames are [881UM 6.4.2, Table 6-6]:

| frame | format word | total size |
|---|---|---|
| null | `$00xx` | 4 bytes |
| idle | `$vv38` | 60 bytes |
| busy | `$vvD4` | 216 bytes |

The version byte `vv` is $1F for the initial parts.

### 8.2 State frame in memory [UM Fig. 10-14 p.10-21; 10.2.3.1 p.10-20]

```
EA+0   format word | reserved word          (save order 0, restore order 0)
EA+4   long                                  (save order n, restore order 1)
EA+8   long                                  (save order n-1, restore order 2)
 ...
EA+L   long (L = length)                     (save order 1, restore order n)
```

Here n = L/4. **cpSAVE writes the operand-CIR longs from the highest address down**: the
first long read from the CIR goes to EA+L and the last to EA+4. **cpRESTORE reads them from
EA+4 upward** and writes them to the CIR in that order.

**[silent]** What the MPU writes in the reserved word at EA+2, and whether the format word is
stored or fetched as a word or as the whole first long.

### 8.3 cpSAVE [UM 10.2.3.3 p.10-24..27, Figs. 10-15/10-16; 10.5.2.6; 10.5.2.7; 881UM 6.4.3]

```
PC+0  1111 CpID 100 EA[5:0]        (EA: control alterable or -(An); else F-line at decode)
PC+2  EA extension words (0..5)
```

```
S1  S = 0 -> privilege violation (vector 8, frame $0), no CIR access.
S2  f := read save CIR ($04).
    BERR -> F-line (vector 11, frame $0).
S3  code $01: if an interrupt is pending, take it with frame $0 (PC = cpSAVE;
    RTE restarts cpSAVE at S2); otherwise go to S2.
S4  code $02-$0F, or (code >= $10 and length mod 4 != 0):
    abort ($0001 -> control), format error (vector 14, frame $0).
S5  evaluate the EA (extension words at scanPC).
      -(An): An := An - (4 + frame bytes); the format word goes to the new An
             [881UM 6.4.3; the 030 UM is silent].
             Frame bytes = length for a valid code, 0 for $00.
      Store the format word at the EA.
S6  code $00: done (the frame is 4 bytes).
    Otherwise repeat length/4 times, top-down:
      x := read operand CIR ($10, long);
      write x at EA+length, then EA+length-4, ... down to EA+4.
S7  done. The MPU reads no other CIR. PC := scanPC.
```

- **[silent]** The order of the length check against the EA evaluation. Recommendation: run
  S4 before S5. The format-error frame restarts cpSAVE, so the instruction must not already
  have moved An.
- The 881UM says the -(An) frame is "allocated before the save operation is started". The
  frame is filled through a temporary pointer from higher to lower addresses. For control
  modes, the format word is written first, then the frame is filled downward from "the
  address of the last word" [881UM 6.4.3].
- After cpSAVE the coprocessor should be idle [UM p.10-26].

### 8.4 cpRESTORE [UM 10.2.3.4 p.10-27..29, Figs. 10-17/10-18; 10.5.2.7 p.10-71; 881UM 6.4.4]

```
PC+0  1111 CpID 101 EA[5:0]        (EA: see 2.1 and section 12, item 3)
PC+2  EA extension words (0..5)
```

```
R1  S = 0 -> privilege violation, no CIR access.
R2  evaluate the EA; f := read the format word from memory at the EA.
    Keep f.length for later [UM Fig. 10-18, note 2].
R3  write f to the restore CIR ($06).
    BERR -> F-line (this is the initiating CIR access).
R4  r := read restore CIR ($06).
    code $01: repeat R4, with no interrupt service [UM 10.2.3.2.2 p.10-23].
R5  r code $02-$0F: abort, format error (vector 14, frame $0).
    If f.code >= $10 and f.length mod 4 != 0: abort, format error. This happens AFTER
    R3/R4, even when the coprocessor accepted the word [UM 10.5.2.7 p.10-71].
R6  r code $00: done.
    Otherwise repeat f.length/4 times, ascending:
      read the long at EA+4, EA+8, ...;
      write it to the operand CIR ($10).
    (The count comes from the memory copy of f, not from r.)
R7  (An)+: An := An + 4 + f.length, updated only after the whole frame has been
    transferred [881UM 6.4.4; the 030 UM is silent].
    Done. The MPU reads no other CIR. PC := scanPC.
```

**[silent]**

- What the MPU does if the read-back r is a valid code but differs from f.
- The An increment for an empty frame. By the frame definition it would be 4.

### 8.5 Interactions

- A nested cpSAVE, one issued while the coprocessor is in the middle of another cpSAVE or
  cpRESTORE (for example after a page fault), gets $02xx. The MPU then aborts and takes a
  format error. On the 68882 this is destructive to the suspended save or restore
  [UM p.10-24, p.10-27; 881UM 7.5.4.6].
- A trace-pending flag does not change either protocol [UM 10.5.2.5].

---

## 9. What the 68882 needs from the kernel (68882-used subset)

From plan §8.6.12, 881UM Table 7-7 and 881UM 7.5:

**Instructions:**

- cpGEN;
- cpBcc.W and cpBcc.L (FBcc, FNOP);
- cpScc (FScc), cpDBcc (FDBcc), cpTRAPcc (FTRAPcc, all three opmodes);
- cpSAVE (FSAVE) and cpRESTORE (FRESTORE).

**Primitives** (full behaviour as in section 5):

| primitive | section |
|---|---|
| null (all CA/PC/IA/PF/TF combinations) | 5.2 |
| evaluate EA and transfer data (all classes, DR both ways, lengths 1/2/4/8/12, register direct, immediate, ±(An) including A7 byte, and the CA=0 forms) | 5.7 |
| transfer single main-processor register | 5.11 |
| transfer multiple coprocessor registers | 5.14 |
| take pre-instruction | 5.16 |
| take mid-instruction | 5.17 |

**Also required:** the PC bit (6); protocol-violation detection for every other code (7.4);
frames $0, $2 and $9 with RTE (7.3); the interrupt points (3.7); trace-pending (3.6); and the
F-line on BERR (1.3).

**Coprocessor-side facts the MPU must not break** [881UM]:

- Reading the response CIR **consumes** a service primitive: the 68882 turns it into null.
  The MPU must therefore read the response exactly once per loop step, and a retried response
  read (for example after a bus retry) can lose a primitive [881UM 7.2.1; 7.5.4.3: handlers
  "must not casually read the response CIR"].
- After XA the 68882 keeps reporting the same take-exception primitive until an FSAVE (or a
  null FRESTORE) [881UM 7.4.2.5]. Handler code deals with that; the MPU just re-reads after
  RTE.
- The 68882 tolerates an MPU clock up to 1.5× its own. For a non-68020/030 main processor,
  the first response read of a new instruction must come no sooner than 3 FPU clocks after the
  previous instruction's last operand transfer [881UM 7.5.1]. This is a timing constraint on
  our FPGA pairing.

---

## 10. Primitive → action cheat sheet (after the PC pass)

| primitive | CIR traffic in order |
|---|---|
| busy | (interrupts, frame $0) → restart: W cmd/cond |
| null | (interrupts, frame $9 per 5.2) → R response, or finish |
| supervisor check | S = 0: W ctl $0001 → exception. S = 1: R response |
| transfer operation word | W $08 opword |
| transfer from instruction stream | W $10 long × ⌊len/4⌋, [W $10 word] |
| evaluate and transfer EA | W $1C EA |
| evaluate EA and transfer data | (DR = 0: R mem, W $10) or (DR = 1: R $10, W mem), per long part and tail |
| write to previous EA | R $10, W mem @ tempEA … |
| take address and transfer data | R $1C addr; then as eval-EA-and-transfer-data |
| top of stack | R/W mem @ A7 ⇄ $10 |
| transfer single register | W/R $10 long |
| transfer control register | R $14 code; W/R $10 long |
| transfer multiple main registers | R $14 mask; W/R $10 long × popcount |
| transfer multiple coprocessor registers | EA eval; R $14 mask; per operand: mem ⇄ $10 in long parts |
| transfer SR and scanPC | SP = 1, DR = 0: W $18 scanPC, W $10 SR. SP = 1, DR = 1: R $10 SR, R $18 scanPC. SP = 0: SR only |
| take pre / mid / post | W ctl $0002 → exception |

---

## 11. Implementation notes for the kernel

1. **The initiating access is special** only for the F-line mapping of BERR (1.3). Every
   other BERR must produce a resumable bus-fault frame that RTE can re-enter mid-dialog
   [UM 10.5.2.8]. How the 68030 packs coprocessor dialog state into the long bus-fault frame
   ($B) is not documented. Our core needs its own internal-register usage there, which is
   acceptable because the frame's internal words are "for internal use only".
2. **Frame $9 is the resume point** for interrupts, protocol violations and mid-instruction
   exceptions. Rebuild the category and CpID from the stored operation word (7.3).
3. **Unimplemented primitives.** If the core omits the primitives the 68882 never sends
   (busy, supervisor check, transfer op word, transfer from instruction stream, eval-and-
   transfer EA, write-to-previous-EA, take address, top of stack, control register, multiple
   main registers, SR/scanPC, take post), the documented fallback is to treat them as
   **protocol violations** (frame $9, vector 13, no control write) [UM 10.4 p.10-33]. That is
   the same thing the real 68030 does for undefined codes, and a handler can emulate them.
   This departs from a real 68030 only if something issues these primitives, which the 68882
   never does.
4. **EA machinery.** Reuse the kernel's EA engine with scanPC as the extension-word pointer.
   Keep tempEA across primitives within one instruction, and stack it in frame $9.
5. **Operand-CIR traffic.** Every operand moves as big-endian long parts with an
   MSB-aligned tail, on both the CIR side and the memory side. On the memory side misaligned
   parts are ordinary (split) accesses.
6. **Coprocessor address.** CIR base = `$20000 | CpID<<13`. For the 68882 at ID 1 that is
   `$22000`.

---

## 12. Silences, ambiguities, disagreements

1. **PC bit position.** UM 10.4.2 text says "Bit [4]". Every figure and encoding says bit 14.
   Use bit 14.
2. **Transfer multiple coprocessor registers EA rule.** Table 10-6 p.10-66 reads "not
   control alterable or (An)+ for CP-to-memory; not control alterable or -(An) for
   memory-to-CP", which swaps the modes and drops "control". The text (10.4.16) and 881UM
   7.4.2.4 agree on DR = 0: control or (An)+, and DR = 1: control alterable or -(An). Use the
   text.
3. **cpRESTORE EA.** The UM says "all memory modes except predecrement", which admits #imm.
   The 881UM FRESTORE entry (and the plan) say control or (An)+ only.
4. **Frame labels.** Section 10 figures label format bits 11-0 "vector number". Section 8
   stacks the vector *offset*, as does 881UM Fig. 7-14. Frame $2/$9 fields are named
   "scanPC / program counter" in Section 10 and "program counter / instruction address" in
   Table 8-6. The layouts agree.
5. **cpSAVE -(An) and cpRESTORE (An)+ updates** (timing and amount), the reserved word's
   value, and whether the format word is moved as a word or a long: the UM is silent. The
   881UM (6.4.3/6.4.4) gives predecrement-first and increment-after-frame.
6. **"Sum of the effective address and the format word-length field multiplied by four"**
   (10.2.3.1): this conflicts with the length being in bytes. Figure 10-14 fixes the layout
   (the first long saved goes at EA+length).
7. **Check order** within a primitive (F-line versus protocol violation, length versus class),
   cpSAVE's length check against its EA evaluation, and privilege versus invalid EA for
   cpSAVE/cpRESTORE: all unspecified.
8. **Unspecified encodings:** $27, $2F and $3C-$3E; CA on busy and on take-exception
   primitives; nonzero "zero" parameter bits. The catch-all rule (10.4) makes unrecognised
   codes protocol violations.
9. **Trace on change of flow for cpGEN.** 10.4.17 says the trace comes when the coprocessor
   signals completion. 10.5.2.5 says the cpGEN may still be running when the handler starts.
10. **Post-instruction in a conditional:** the stacked scanPC would point at the
    displacement or EA words, not at the next instruction.
11. **Undocumented details:**
    - FC for PC-relative source reads in eval-EA-and-transfer-data;
    - which bytes of a register (or of a 1-byte immediate) are sent for lengths 1 and 2, and
      scanPC for a byte immediate;
    - byte transfers to An;
    - tempEA for (An)+ and -(An);
    - frame $9's internal register;
    - how RTE learns the CpID;
    - no privilege check on the SR and control-register primitives;
    - the restore read-back differing from the format word written.
12. **Stale text.**
    - Table 10-6 says "MC68020".
    - Fig. 10-18 refers to "10.6.1.5"; 10.5.1 refers to "10.2.3.4.3".
    - Table 8-6 lists format-error PCs for RTE/cpRESTORE only, not cpSAVE.
    - 8.1.4 (trace after the trap handler's RTE) conflicts with the 8.1.12 ordering.
13. **881UM FSAVE not-ready.** The 881UM lets the main processor "process interrupts and
    restart, or reread". The 030 always services pending interrupts (frame $0) and then
    re-reads.
