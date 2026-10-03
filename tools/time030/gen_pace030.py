#!/usr/bin/env python3
"""Generates rtl/tg68k/se30_pace030.v - the paced kernel's instruction
timing decoder (SE30_PLAN.md 1.17.5 item 5) - from um11.py, the MC68030
User's Manual's Section 11.6 tables.

For an opcode word the module gives the two parts of UM Equation 11-2:
the effective-address part (fea, fiea, cea, ciea or jea, by the
instruction's footnote in the manual) and the operation part, each as
(head, tail, I-cache-case clocks); a branch's taken alternative; and
MOVEM's per-register addition.  The wrapper (tg68k.v) adds the parts, the
overlaps and the wait states and holds the kernel to the total.

What is decided here, and the simplifications (all noted in the plan):
  - the EA part is the single-EA / brief-format row for the mode; a
    full-format extension word (68020 memory indirect) is charged the
    brief figure - the ROM hardly uses them;
  - "n + op head" rows (cea, ciea, jea) carry the flag ea_ophead: the
    wrapper adds the op's head to the EA's;
  - an immediate operand's row is by its size (.B/.W -> the .W row);
  - Bcc/DBcc give both outcomes (op_cc the fall-through, op_cc_t the
    taken); DBF's fall-through is "count expired", other DBcc's "cc true";
  - MUL/DIV, CHK, CAS use the manual's maxima ("+" rows); DIVx.L the
    DIVU.L row (the extension word tells them apart, this decoder has
    only the opcode); MOVEC the 6-clock row;
  - the bit field rows are the <5-byte ones; the exception rows are the
    instruction's own (TRAP, A-line, ILLEGAL); F-line (the FPU and PMMU)
    is unpaced - the coprocessor dialog's cycles are its own timing;
  - MOVEM: the row's fixed clocks (8 or 4) plus, per register, 4 (reads) or
    2 (writes) - the wrapper adds mvm per data cycle.

Run: python tools/time030/gen_pace030.py   (writes rtl/tg68k/se30_pace030.v)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import um11  # noqa: E402

OUT = os.path.join(HERE, "..", "..", "rtl", "tg68k", "se30_pace030.v")

# ---------------------------------------------------------------- the EA tables
# ea table codes
NONE, FEA, FIEA, CEA, CIEA, JEA = 0, 1, 2, 3, 4, 5
# size codes for the immediate / #data rows
SZ_OP, SZ_B, SZ_W, SZ_L, SZ_MOVE, SZ_BIT6 = 0, 1, 2, 3, 4, 5

# the Verilog EA functions: (mode, reg, lsz) -> {ophead, h[4:0], t[1:0], cc[5:0]}
# mode 7 regs: 0 (xxx).W, 1 (xxx).L, 2 (d16,PC), 3 (d8,PC,Xn), 4 #data
MODE_KEYS = {
    FEA:  {0: "Dn", 1: "An", 2: "(An)", 3: "(An)+", 4: "-(An)", 5: "(d16,An)", 6: "(d8,An,Xn)",
           (7, 0): "(xxx).W", (7, 1): "(xxx).L", (7, 2): "(d16,An)", (7, 3): "(d8,An,Xn)",
           (7, 4, "W"): "#(data).W", (7, 4, "L"): "#(data).L"},
    FIEA: {0: "#.%s,Dn", 1: "#.%s,Dn", 2: "#.%s,(An)", 3: "#.%s,(An)+", 4: "#.%s,-(An)", 5: "#.%s,(d16,An)",
           6: "#.%s,(d8,An,Xn)", (7, 0): "#.%s,(xxx).W", (7, 1): "#.%s,(xxx).L", (7, 2): "#.%s,(d16,An)",
           (7, 3): "#.%s,(d8,An,Xn)", (7, 4): "#.W,#.L"},
    CEA:  {0: "Dn", 1: "An", 2: "(An)", 3: "(An)+", 4: "-(An)", 5: "(d16,An)", 6: "(d8,An,Xn)",
           (7, 0): "(xxx).W", (7, 1): "(xxx).L", (7, 2): "(d16,An)", (7, 3): "(d8,An,Xn)"},
    CIEA: {0: "#.%s,Dn", 1: "#.%s,Dn", 2: "#.%s,(An)", 3: "#.%s,(An)+", 4: "#.%s,-(An)", 5: "#.%s,(d16,An)",
           6: "#.%s,(d8,An,Xn)", (7, 0): "#.%s,(xxx).W", (7, 1): "#.%s,(xxx).L", (7, 2): "#.%s,(d16,An)",
           (7, 3): "#.%s,(d8,An,Xn)"},
    JEA:  {2: "(An)", 5: "(d16,An)", 6: "(d8,An,Xn)", (7, 0): "(xxx).W", (7, 1): "(xxx).L",
           (7, 2): "(d16,An)", (7, 3): "(d8,An,Xn)"},
}
TABLES = {FEA: um11.FEA, FIEA: um11.FIEA, CEA: um11.CEA, CIEA: um11.CIEA, JEA: um11.JEA}


def ea_row(tbl, key, sz):
    """The table row for a mode key at immediate size sz ('W'/'L'), or None."""
    k = MODE_KEYS[tbl].get(key)
    if k is None:
        if isinstance(key, tuple) and len(key) == 2 and tbl == FEA:
            k = MODE_KEYS[tbl].get((key[0], key[1], sz))
        if k is None:
            return None
    if "%s" in k:
        k = k % sz
    return TABLES[tbl][k]


def packed(r):
    return (r["ophead"], r["head"], r["tail"], r["cc"])


def ea_function(tbl, name):
    """Verilog for one EA table function."""
    lines = ["  function [13:0] %s;   // {ophead, h[4:0], t[1:0], cc[5:0]}" % name,
             "    input [2:0] mode; input [2:0] rg; input lsz;",
             "    begin",
             "      case (mode)"]
    for m in range(7):
        rw = ea_row(tbl, m, "W"); rl = ea_row(tbl, m, "L")
        if rw is None and rl is None:
            continue
        if rw == rl or rl is None or rw is None:
            r = rw or rl
            lines.append("        3'd%d: %s = {1'b%d, 5'd%d, 2'd%d, 6'd%d};" % ((m, name) + packed(r)))
        else:
            lines.append("        3'd%d: %s = lsz ? {1'b%d, 5'd%d, 2'd%d, 6'd%d} : {1'b%d, 5'd%d, 2'd%d, 6'd%d};"
                         % ((m, name) + packed(rl) + packed(rw)))
    lines.append("        3'd7: case (rg)")
    for g in range(5):
        rw = ea_row(tbl, (7, g), "W"); rl = ea_row(tbl, (7, g), "L")
        if rw is None and rl is None:
            continue
        if rw == rl or rl is None or rw is None:
            r = rw or rl
            lines.append("          3'd%d: %s = {1'b%d, 5'd%d, 2'd%d, 6'd%d};" % ((g, name) + packed(r)))
        else:
            lines.append("          3'd%d: %s = lsz ? {1'b%d, 5'd%d, 2'd%d, 6'd%d} : {1'b%d, 5'd%d, 2'd%d, 6'd%d};"
                         % ((g, name) + packed(rl) + packed(rw)))
    lines += ["          default: %s = 14'd0;" % name,
              "        endcase",
              "        default: %s = 14'd0;" % name,
              "      endcase",
              "    end",
              "  endfunction", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------- the op patterns
# (pattern, table name, row, ea table, size code, options)
# options: alt = the taken row (Bcc/DBcc); br = 1 Bcc, 2 DBcc; mvm = per-cycle extra
T = um11.TABLES
P = []


def p(pat, tbl, row, ea=NONE, sz=SZ_OP, **kw):
    pat = pat.replace(" ", "")
    assert len(pat) == 16, pat
    if tbl is not None:
        assert row in T[tbl], (tbl, row)
    if "alt" in kw:
        assert kw["alt"] in T[tbl], kw["alt"]
    P.append((pat, tbl, row, ea, sz, kw))


# ---- 0000: immediates, bit operations, CAS/CMP2, MOVES, MOVEP
p("0000 0000 0011 1100", "CONTROL", "ORI to CCR")
p("0000 0000 0111 1100", "CONTROL", "ORI to SR")
p("0000 0010 0011 1100", "CONTROL", "ANDI to CCR")
p("0000 0010 0111 1100", "CONTROL", "ANDI to SR")
p("0000 1010 0011 1100", "CONTROL", "EORI to CCR")
p("0000 1010 0111 1100", "CONTROL", "EORI to SR")
p("0000 1000 0000 0???", "BIT", "BTST #,Dn", FIEA, SZ_W)
p("0000 1000 00?? ????", "BIT", "BTST #,Mem", FIEA, SZ_W)
p("0000 1000 0100 0???", "BIT", "BCHG #,Dn", FIEA, SZ_W)
p("0000 1000 01?? ????", "BIT", "BCHG #,Mem", FIEA, SZ_W)
p("0000 1000 1000 0???", "BIT", "BCLR #,Dn", FIEA, SZ_W)
p("0000 1000 10?? ????", "BIT", "BCLR #,Mem", FIEA, SZ_W)
p("0000 1000 1100 0???", "BIT", "BSET #,Dn", FIEA, SZ_W)
p("0000 1000 11?? ????", "BIT", "BSET #,Mem", FIEA, SZ_W)
p("0000 1110 ???? ????", "SPECIAL_MOVE", "MOVES EA,Rn", CIEA, SZ_W)
p("0000 1??0 1111 1100", "CONTROL", "CAS2 success")
p("0000 1??0 11?? ????", "CONTROL", "CAS success", CIEA, SZ_W)
p("0000 0??0 11?? ????", "ARITH", "CMP2 EA,Rn", FIEA, SZ_W)      # CMP2/CHK2
for bits, name in (("0000", "ORI"), ("0010", "ANDI"), ("0100", "SUBI"), ("0110", "ADDI"), ("1010", "EORI"), ("1100", "CMPI")):
    p("0000 %s ??00 0???" % bits, "IMMED", "%s #,Dn" % name, FIEA, SZ_OP)
    p("0000 %s ???? ????" % bits, "IMMED", "%s #,Mem" % name, FIEA, SZ_OP)
p("0000 ???1 0?00 1???", "SPECIAL_MOVE", "MOVEP.W (d16,An),Dn")   # bit 7:6 00 .W, 01 .L (mem->reg)
p("0000 ???1 1?00 1???", "SPECIAL_MOVE", "MOVEP.W Dn,(d16,An)")   # the .L rows are 14: taken as .W (10), rare
p("0000 ???1 0000 0???", "BIT", "BTST Dn,Dn")
p("0000 ???1 00?? ????", "BIT", "BTST Dn,Mem", FEA, SZ_B)
p("0000 ???1 0100 0???", "BIT", "BCHG Dn,Dn")
p("0000 ???1 01?? ????", "BIT", "BCHG Dn,Mem", FEA, SZ_B)
p("0000 ???1 1000 0???", "BIT", "BCLR Dn,Dn")
p("0000 ???1 10?? ????", "BIT", "BCLR Dn,Mem", FEA, SZ_B)
p("0000 ???1 1100 0???", "BIT", "BSET Dn,Dn")
p("0000 ???1 11?? ????", "BIT", "BSET Dn,Mem", FEA, SZ_B)
# ---- MOVE (0001 .B, 0011 .W, 0010 .L): the source's fea plus the destination's row
for sz in ("0001", "0011", "0010"):
    p("%s ???0 00?? ????" % sz, "MOVE", "MOVE EA,Dn", FEA, SZ_MOVE)
    p("%s ???0 01?? ????" % sz, "MOVE", "MOVE EA,An", FEA, SZ_MOVE)
    p("%s ???0 1000 ????" % sz, "MOVE", "MOVE Rn,(An)")
    p("%s ???0 10?? ????" % sz, "MOVE", "MOVE SOURCE,(An)", FEA, SZ_MOVE)
    p("%s ???0 1100 ????" % sz, "MOVE", "MOVE Rn,(An)+")
    p("%s ???0 11?? ????" % sz, "MOVE", "MOVE SOURCE,(An)+", FEA, SZ_MOVE)
    p("%s ???1 0000 ????" % sz, "MOVE", "MOVE Rn,-(An)")
    p("%s ???1 00?? ????" % sz, "MOVE", "MOVE SOURCE,-(An)", FEA, SZ_MOVE)
    p("%s ???1 01?? ????" % sz, "MOVE", "MOVE EA,(d16,An)", FEA, SZ_MOVE)
    p("%s ???1 10?? ????" % sz, "MOVE", "MOVE EA,(d8,An,Xn)", FEA, SZ_MOVE)
    p("%s 0001 11?? ????" % sz, "MOVE", "MOVE EA,(xxx).W", FEA, SZ_MOVE)
    p("%s 0011 11?? ????" % sz, "MOVE", "MOVE EA,(xxx).L", FEA, SZ_MOVE)
# ---- 0100: miscellaneous
p("0100 1010 1111 1100", "EXCEPTION", "Illegal instruction")
p("0100 0000 1100 0???", "SPECIAL_MOVE", "MOVE SR,Dn")
p("0100 0000 11?? ????", "SPECIAL_MOVE", "MOVE SR,Mem", CEA)
p("0100 0010 1100 0???", "SPECIAL_MOVE", "MOVE CCR,Dn")
p("0100 0010 11?? ????", "SPECIAL_MOVE", "MOVE CCR,Mem", CEA)
p("0100 0100 1100 0???", "SPECIAL_MOVE", "MOVE Dn,CCR")
p("0100 0100 11?? ????", "SPECIAL_MOVE", "MOVE EA,CCR", CEA)
p("0100 0110 11?? ????", "SPECIAL_MOVE", "MOVE EA,SR", FEA, SZ_W)
p("0100 0000 ??00 0???", "SINGLE", "NEGX Dn")
p("0100 0000 ???? ????", "SINGLE", "NEGX Mem", FEA)
p("0100 0010 ??00 0???", "SINGLE", "CLR Dn")
p("0100 0010 ???? ????", "SINGLE", "CLR Mem", CEA)
p("0100 0100 ??00 0???", "SINGLE", "NEG Dn")
p("0100 0100 ???? ????", "SINGLE", "NEG Mem", FEA)
p("0100 0110 ??00 0???", "SINGLE", "NOT Dn")
p("0100 0110 ???? ????", "SINGLE", "NOT Mem", FEA)
p("0100 1000 0000 1???", "CONTROL", "LINK.L")
p("0100 1000 0000 0???", "SINGLE", "NBCD Dn")
p("0100 1000 00?? ????", "SINGLE", "NBCD Dn", FEA, SZ_B)
p("0100 1000 0100 0???", "SPECIAL_MOVE", "SWAP Dn")
p("0100 1000 0100 1???", "EXCEPTION", "BKPT")
p("0100 1000 01?? ????", "CONTROL", "PEA", CEA)
p("0100 1000 1?00 0???", "SINGLE", "EXT Dn")
p("0100 1001 1100 0???", "SINGLE", "EXT Dn")                         # EXTB.L
p("0100 1000 1??? ????", "SPECIAL_MOVE", "MOVEM RL,EA", CIEA, SZ_W, mvm=0)
p("0100 1100 1??? ????", "SPECIAL_MOVE", "MOVEM EA,RL", CIEA, SZ_W, mvm=2)
p("0100 1010 1100 0???", "SINGLE", "TAS Dn")
p("0100 1010 11?? ????", "SINGLE", "TAS Mem", CEA)
p("0100 1010 ??00 0???", "SINGLE", "TST Dn")
p("0100 1010 ???? ????", "SINGLE", "TST Mem", FEA)
p("0100 1100 00?? ????", "ARITH", "MULS.L EA,Dn", FIEA, SZ_W)
p("0100 1100 01?? ????", "ARITH", "DIVU.L EA,Dn", FIEA, SZ_W)
p("0100 1110 0100 ????", "EXCEPTION", "TRAP #n")
p("0100 1110 0101 0???", "CONTROL", "LINK.W")
p("0100 1110 0101 1???", "CONTROL", "UNLK")
p("0100 1110 0110 0???", "SPECIAL_MOVE", "MOVE An,USP")
p("0100 1110 0110 1???", "SPECIAL_MOVE", "MOVE USP,An")
p("0100 1110 0111 0000", "EXCEPTION", "RESET instruction")
p("0100 1110 0111 0001", "CONTROL", "NOP")
p("0100 1110 0111 0010", "EXCEPTION", "STOP")
p("0100 1110 0111 0011", "SAVE_RESTORE", "RTE four word")
p("0100 1110 0111 0100", "CONTROL", "RTD")
p("0100 1110 0111 0101", "CONTROL", "RTS")
p("0100 1110 0111 0110", "EXCEPTION", "TRAPV no trap")
p("0100 1110 0111 0111", "CONTROL", "RTR")
p("0100 1110 0111 1010", "SPECIAL_MOVE", "MOVEC Cr,Rn")
p("0100 1110 0111 1011", "SPECIAL_MOVE", "MOVEC Rn,Cr-A")
p("0100 1110 10?? ????", "CONTROL", "JSR", JEA)
p("0100 1110 11?? ????", "CONTROL", "JMP", JEA)
p("0100 ???1 11?? ????", "CONTROL", "LEA", CEA)
p("0100 ???1 ?000 0???", "CONTROL", "CHK Dn,Dn")
p("0100 ???1 ?0?? ????", "CONTROL", "CHK EA,Dn", FEA)
# ---- 0101: ADDQ/SUBQ, Scc, DBcc, TRAPcc
p("0101 0001 1100 1???", "BRANCH", "DBcc expired", br=2, alt="DBcc loop")   # DBF/DBRA: the count runs out
p("0101 ???? 1100 1???", "BRANCH", "DBcc true", br=2, alt="DBcc loop")
p("0101 ???? 1111 1010", "EXCEPTION", "TRAPcc.W no trap")
p("0101 ???? 1111 1011", "EXCEPTION", "TRAPcc.L no trap")
p("0101 ???? 1111 1100", "EXCEPTION", "TRAPcc no trap")
p("0101 ???? 1100 0???", "SINGLE", "Scc Dn")
p("0101 ???? 11?? ????", "SINGLE", "Scc Mem", CEA)
p("0101 ???0 ??00 ????", "IMMED", "ADDQ #,Rn")
p("0101 ???0 ???? ????", "IMMED", "ADDQ #,Mem", FEA)
p("0101 ???1 ??00 ????", "IMMED", "SUBQ #,Rn")
p("0101 ???1 ???? ????", "IMMED", "SUBQ #,Mem", FEA)
# ---- 0110: Bcc, BRA, BSR
p("0110 0001 ???? ????", "CONTROL", "BSR")
p("0110 ???? 0000 0000", "BRANCH", "Bcc.W not taken", br=1, alt="Bcc taken")
p("0110 ???? 1111 1111", "BRANCH", "Bcc.L not taken", br=1, alt="Bcc taken")
p("0110 ???? ???? ????", "BRANCH", "Bcc.B not taken", br=1, alt="Bcc taken")
# ---- 0111: MOVEQ
p("0111 ???0 ???? ????", "IMMED", "MOVEQ #,Dn")
# ---- 1000: OR, DIV.W, SBCD, PACK, UNPK
p("1000 ???0 1100 0???", "ARITH", "DIVU.W Dn,Dn")
p("1000 ???0 11?? ????", "ARITH", "DIVU.W EA,Dn", FEA, SZ_W)
p("1000 ???1 1100 0???", "ARITH", "DIVS.W Dn,Dn")
p("1000 ???1 11?? ????", "ARITH", "DIVS.W EA,Dn", FEA, SZ_W)
p("1000 ???1 0000 0???", "BCD", "SBCD Dn,Dn")
p("1000 ???1 0000 1???", "BCD", "SBCD -(An),-(An)")
p("1000 ???1 0100 0???", "BCD", "PACK Dn,Dn,#")
p("1000 ???1 0100 1???", "BCD", "PACK -(An),-(An),#")
p("1000 ???1 1000 0???", "BCD", "UNPK Dn,Dn,#")
p("1000 ???1 1000 1???", "BCD", "UNPK -(An),-(An),#")
p("1000 ???0 ??00 0???", "ARITH", "OR Dn,Dn")
p("1000 ???0 ???? ????", "ARITH", "OR EA,Dn", FEA)
p("1000 ???1 ???? ????", "ARITH", "OR Dn,EA", FEA)
# ---- 1001: SUB, SUBA, SUBX
p("1001 ???0 1100 ????", "ARITH", "SUBA.W Rn,An")
p("1001 ???0 11?? ????", "ARITH", "SUBA.W EA,An", FEA, SZ_W)
p("1001 ???1 1100 ????", "ARITH", "SUBA.L Rn,An")
p("1001 ???1 11?? ????", "ARITH", "SUBA.L EA,An", FEA, SZ_L)
p("1001 ???1 ??00 0???", "BCD", "SUBX Dn,Dn")
p("1001 ???1 ??00 1???", "BCD", "SUBX -(An),-(An)")
p("1001 ???0 ??00 ????", "ARITH", "SUB Rn,Dn")
p("1001 ???0 ???? ????", "ARITH", "SUB EA,Dn", FEA)
p("1001 ???1 ???? ????", "ARITH", "SUB Dn,EA", FEA)
# ---- 1010: the A-line trap (the Toolbox)
p("1010 ???? ???? ????", "EXCEPTION", "A-line trap")
# ---- 1011: CMP, CMPA, CMPM, EOR
p("1011 ???0 1100 ????", "ARITH", "CMPA Rn,An")
p("1011 ???0 11?? ????", "ARITH", "CMPA EA,An", FEA, SZ_W)
p("1011 ???1 1100 ????", "ARITH", "CMPA Rn,An")
p("1011 ???1 11?? ????", "ARITH", "CMPA EA,An", FEA, SZ_L)
p("1011 ???1 ??00 1???", "BCD", "CMPM (An)+,(An)+")
p("1011 ???1 ??00 0???", "ARITH", "EOR Dn,Dn")
p("1011 ???1 ???? ????", "ARITH", "EOR Dn,EA", FEA)
p("1011 ???0 ??00 ????", "ARITH", "CMP Rn,Dn")
p("1011 ???0 ???? ????", "ARITH", "CMP EA,Dn", FEA)
# ---- 1100: AND, MUL.W, ABCD, EXG
p("1100 ???0 11?? ????", "ARITH", "MULU.W EA,Dn", FEA, SZ_W)
p("1100 ???1 11?? ????", "ARITH", "MULS.W EA,Dn", FEA, SZ_W)
p("1100 ???1 0000 0???", "BCD", "ABCD Dn,Dn")
p("1100 ???1 0000 1???", "BCD", "ABCD -(An),-(An)")
p("1100 ???1 0100 0???", "SPECIAL_MOVE", "EXG Ry,Rx")
p("1100 ???1 0100 1???", "SPECIAL_MOVE", "EXG Ry,Rx")
p("1100 ???1 1000 1???", "SPECIAL_MOVE", "EXG Ry,Rx")
p("1100 ???0 ??00 0???", "ARITH", "AND Dn,Dn")
p("1100 ???0 ???? ????", "ARITH", "AND EA,Dn", FEA)
p("1100 ???1 ???? ????", "ARITH", "AND Dn,EA", FEA)
# ---- 1101: ADD, ADDA, ADDX
p("1101 ???0 1100 ????", "ARITH", "ADDA.W Rn,An")
p("1101 ???0 11?? ????", "ARITH", "ADDA.W EA,An", FEA, SZ_W)
p("1101 ???1 1100 ????", "ARITH", "ADDA.L Rn,An")
p("1101 ???1 11?? ????", "ARITH", "ADDA.L EA,An", FEA, SZ_L)
p("1101 ???1 ??00 0???", "BCD", "ADDX Dn,Dn")
p("1101 ???1 ??00 1???", "BCD", "ADDX -(An),-(An)")
p("1101 ???0 ??00 ????", "ARITH", "ADD Rn,Dn")
p("1101 ???0 ???? ????", "ARITH", "ADD EA,Dn", FEA)
p("1101 ???1 ???? ????", "ARITH", "ADD Dn,EA", FEA)
# ---- 1110: shifts and bit fields
for bits, dn, mem in (("1000", "BFTST Dn", "BFTST Mem<5"), ("1001", "BFEXTU Dn", "BFEXTU Mem<5"),
                      ("1010", "BFCHG Dn", "BFCHG Mem<5"), ("1011", "BFEXTS Dn", "BFEXTS Mem<5"),
                      ("1100", "BFCLR Dn", "BFCLR Mem<5"), ("1101", "BFFFO Dn", "BFFFO Mem<5"),
                      ("1110", "BFSET Dn", "BFSET Mem<5"), ("1111", "BFINS Dn", "BFINS Mem<5")):
    p("1110 %s 1100 0???" % bits, "BITFIELD", dn)
    p("1110 %s 11?? ????" % bits, "BITFIELD", mem, CIEA, SZ_W)
p("1110 0000 11?? ????", "SHIFT", "ASR Mem", FEA, SZ_W)
p("1110 0001 11?? ????", "SHIFT", "ASL Mem", FEA, SZ_W)
p("1110 001? 11?? ????", "SHIFT", "LSd Mem", FEA, SZ_W)
p("1110 010? 11?? ????", "SHIFT", "ROXd Mem", FEA, SZ_W)
p("1110 011? 11?? ????", "SHIFT", "ROd Mem", FEA, SZ_W)
p("1110 ???0 ??00 0???", "SHIFT", "ASR #,Dy")
p("1110 ???1 ??00 0???", "SHIFT", "ASL #,Dy")
p("1110 ???0 ??10 0???", "SHIFT", "ASR Dx,Dy")
p("1110 ???1 ??10 0???", "SHIFT", "ASL Dx,Dy")
p("1110 ???? ??00 1???", "SHIFT", "LSd #,Dy")
p("1110 ???? ??10 1???", "SHIFT", "LSd Dx,Dy")
p("1110 ???? ??01 0???", "SHIFT", "ROXd Dn")
p("1110 ???? ??11 0???", "SHIFT", "ROXd Dn")
p("1110 ???? ??01 1???", "SHIFT", "ROd #,Dy")
p("1110 ???? ??11 1???", "SHIFT", "ROd Dx,Dy")
# ---- 1111: the coprocessors, unpaced
p("1111 ???? ???? ????", None, None)


def main():
    out = []
    w = out.append
    w("// se30_pace030.v - the paced kernel's instruction timing decoder (SE30_PLAN.md")
    w("// 1.17.5 item 5).  GENERATED by tools/time030/gen_pace030.py from um11.py, the")
    w("// MC68030 User's Manual's Section 11.6 tables: do not edit, regenerate.")
    w("//")
    w("// For the opcode word: the effective-address part (fea, fiea, cea, ciea or")
    w("// jea, by the manual's footnote) and the operation part of UM Equation 11-2,")
    w("// each as head, tail and I-cache-case clocks; op_cc_t is a branch's taken")
    w("// alternative (br 1 Bcc, 2 DBcc); mvm is MOVEM's addition per data cycle.")
    w("// ea_ophead: the EA's head includes the op's (the manual's \"n + op head\").")
    w("// The simplifications are listed in the generator's header.")
    w("")
    w("`timescale 1ns/1ps")
    w("")
    w("module se30_pace030 (")
    w("  input  [15:0] op,")
    w("  output reg        ea_on,")
    w("  output reg        ea_ophead,")
    w("  output reg  [4:0] ea_h,")
    w("  output reg  [1:0] ea_t,")
    w("  output reg  [5:0] ea_cc,")
    w("  output reg  [4:0] op_h,")
    w("  output reg  [1:0] op_t,")
    w("  output reg  [6:0] op_cc,")
    w("  output reg  [6:0] op_cc_t,")
    w("  output reg  [1:0] br,")
    w("  output reg  [1:0] mvm")
    w(");")
    w("")
    for tbl, name in ((FEA, "f_fea"), (FIEA, "f_fiea"), (CEA, "f_cea"), (CIEA, "f_ciea"), (JEA, "f_jea")):
        w(ea_function(tbl, name))
    w("  reg  [2:0] tbl;      // 0 none, 1 fea, 2 fiea, 3 cea, 4 ciea, 5 jea")
    w("  reg  [2:0] szs;      // the immediate's size: 0 from op[7:6], 1 .B, 2 .W, 3 .L, 4 MOVE's op[13:12]")
    w("  wire       lsz = (szs == 3'd0) ? (op[7:6] == 2'b10) : (szs == 3'd4) ? (op[13:12] == 2'b10) : (szs == 3'd3);")
    w("  reg [13:0] ea;")
    w("")
    w("  always @* begin")
    w("    tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd0; op_cc_t = 7'd0; br = 2'd0; mvm = 2'd0;")
    w("    casez (op)")
    for pat, tbl, row, ea, sz, kw in P:
        vpat = "16'b" + pat
        if tbl is None:
            w("      %s: ;   // the coprocessors: unpaced" % vpat)
            continue
        r = T[tbl][row]
        cc = min(r["cc"], 127)
        alt = T[tbl][kw["alt"]] if "alt" in kw else r
        fields = ["tbl = 3'd%d" % ea, "szs = 3'd%d" % sz,
                  "op_h = 5'd%d" % r["head"], "op_t = 2'd%d" % r["tail"], "op_cc = 7'd%d" % cc,
                  "op_cc_t = 7'd%d" % min(alt["cc"], 127)]
        if "br" in kw:
            fields.append("br = 2'd%d" % kw["br"])
        if "mvm" in kw:
            fields.append("mvm = 2'd%d" % kw["mvm"])
        w("      %s: begin %s; end   // %s%s" % (vpat, "; ".join(fields), row, " (%s)" % tbl.lower() if False else ""))
    w("      default: ;")
    w("    endcase")
    w("    case (tbl)")
    w("      3'd1: ea = f_fea(op[5:3], op[2:0], lsz);")
    w("      3'd2: ea = f_fiea(op[5:3], op[2:0], lsz);")
    w("      3'd3: ea = f_cea(op[5:3], op[2:0], lsz);")
    w("      3'd4: ea = f_ciea(op[5:3], op[2:0], lsz);")
    w("      3'd5: ea = f_jea(op[5:3], op[2:0], lsz);")
    w("      default: ea = 14'd0;")
    w("    endcase")
    w("    ea_on = (tbl != 3'd0);")
    w("    {ea_ophead, ea_h, ea_t, ea_cc} = ea;")
    w("  end")
    w("")
    w("endmodule")
    with open(OUT, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("%s: %d patterns" % (os.path.relpath(OUT), len(P)))


if __name__ == "__main__":
    main()
