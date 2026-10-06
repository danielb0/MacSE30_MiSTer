#!/usr/bin/env python3
"""dis8051.py - a small 8051 disassembler for reading the AppleCD SC's SCSI
firmware (SE30_PLAN.md 12.2, 12.5).

    python tools/cdrom/dis8051.py FIRMWARE.bin START [END|+COUNT] [--follow]

START and END are hex.  Without END it stops after the first unconditional
return or jump (RET, RETI, LJMP, AJMP, SJMP, JMP @A+DPTR).  --follow also
disassembles every branch target reached from START (one routine and its
local branches; calls are listed, not followed).

Operands are shown in the Intel style: #imm, direct addresses by SFR name
where the 8051 has one, @Ri, @DPTR, bit addresses as byte.bit.
"""
import sys

SFR = {0x80: "P0", 0x81: "SP", 0x82: "DPL", 0x83: "DPH", 0x87: "PCON",
       0x88: "TCON", 0x89: "TMOD", 0x8A: "TL0", 0x8B: "TL1", 0x8C: "TH0",
       0x8D: "TH1", 0x90: "P1", 0x98: "SCON", 0x99: "SBUF", 0xA0: "P2",
       0xA8: "IE", 0xB0: "P3", 0xB8: "IP", 0xD0: "PSW", 0xE0: "ACC",
       0xF0: "B"}


def direct(a):
    return SFR.get(a, "%02Xh" % a)


def bit(b):
    if b < 0x80:
        return "%02Xh.%d" % (0x20 + (b >> 3), b & 7)
    return "%s.%d" % (direct(b & 0xF8), b & 7)


def rel(pc, off):
    return (pc + (off - 256 if off & 0x80 else off)) & 0xFFFF


def decode(m, pc):
    """Return (length, text, targets, ends) for the instruction at pc."""
    op = m[pc]
    b1 = m[pc + 1] if pc + 1 < len(m) else 0
    b2 = m[pc + 2] if pc + 2 < len(m) else 0
    lo = op & 0x0F
    hi = op >> 4
    rn = "R%d" % (op & 7)
    ri = "@R%d" % (op & 1)

    # the regular columns: x6/x7 = @Ri, x8-xF = Rn
    def reg_operand():
        return ri if lo in (6, 7) else rn

    if (op & 0x1F) == 0x01:                       # AJMP
        t = ((pc + 2) & 0xF800) | ((op >> 5) << 8) | b1
        return 2, "AJMP %04X" % t, [t], True
    if (op & 0x1F) == 0x11:                       # ACALL
        t = ((pc + 2) & 0xF800) | ((op >> 5) << 8) | b1
        return 2, "ACALL %04X" % t, [], False
    if lo >= 6:
        r = reg_operand()
        table = {
            0x0: ("INC %s" % r, 1), 0x1: ("DEC %s" % r, 1),
            0x2: ("ADD A,%s" % r, 1), 0x3: ("ADDC A,%s" % r, 1),
            0x4: ("ORL A,%s" % r, 1), 0x5: ("ANL A,%s" % r, 1),
            0x6: ("XRL A,%s" % r, 1), 0x7: ("MOV %s,#%02Xh" % (r, b1), 2),
            0x8: ("MOV %s,%s" % (direct(b1), r), 2), 0x9: ("SUBB A,%s" % r, 1),
            0xA: ("MOV %s,%s" % (r, direct(b1)), 2), 0xC: ("XCH A,%s" % r, 1),
            0xE: ("MOV A,%s" % r, 1), 0xF: ("MOV %s,A" % r, 1),
        }
        if hi == 0xB:
            t = rel(pc + 3, b2)
            return 3, "CJNE %s,#%02Xh,%04X" % (r, b1, t), [t], False
        if hi == 0xD:
            if lo in (6, 7):
                return 1, "XCHD A,%s" % r, [], False
            t = rel(pc + 2, b1)
            return 2, "DJNZ %s,%04X" % (r, t), [t], False
        txt, n = table[hi]
        return n, txt, [], False

    # the irregular columns 0-5
    d = direct(b1)
    T = {
        0x00: (1, "NOP"),
        0x02: (3, "LJMP %04X" % ((b1 << 8) | b2)),
        0x03: (1, "RR A"), 0x04: (1, "INC A"), 0x05: (2, "INC %s" % d),
        0x10: (3, "JBC %s,%04X" % (bit(b1), rel(pc + 3, b2))),
        0x12: (3, "LCALL %04X" % ((b1 << 8) | b2)),
        0x13: (1, "RRC A"), 0x14: (1, "DEC A"), 0x15: (2, "DEC %s" % d),
        0x20: (3, "JB %s,%04X" % (bit(b1), rel(pc + 3, b2))),
        0x22: (1, "RET"), 0x23: (1, "RL A"),
        0x24: (2, "ADD A,#%02Xh" % b1), 0x25: (2, "ADD A,%s" % d),
        0x30: (3, "JNB %s,%04X" % (bit(b1), rel(pc + 3, b2))),
        0x32: (1, "RETI"), 0x33: (1, "RLC A"),
        0x34: (2, "ADDC A,#%02Xh" % b1), 0x35: (2, "ADDC A,%s" % d),
        0x40: (2, "JC %04X" % rel(pc + 2, b1)),
        0x42: (2, "ORL %s,A" % d), 0x43: (3, "ORL %s,#%02Xh" % (d, b2)),
        0x44: (2, "ORL A,#%02Xh" % b1), 0x45: (2, "ORL A,%s" % d),
        0x50: (2, "JNC %04X" % rel(pc + 2, b1)),
        0x52: (2, "ANL %s,A" % d), 0x53: (3, "ANL %s,#%02Xh" % (d, b2)),
        0x54: (2, "ANL A,#%02Xh" % b1), 0x55: (2, "ANL A,%s" % d),
        0x60: (2, "JZ %04X" % rel(pc + 2, b1)),
        0x62: (2, "XRL %s,A" % d), 0x63: (3, "XRL %s,#%02Xh" % (d, b2)),
        0x64: (2, "XRL A,#%02Xh" % b1), 0x65: (2, "XRL A,%s" % d),
        0x70: (2, "JNZ %04X" % rel(pc + 2, b1)),
        0x72: (2, "ORL C,%s" % bit(b1)), 0x73: (1, "JMP @A+DPTR"),
        0x74: (2, "MOV A,#%02Xh" % b1), 0x75: (3, "MOV %s,#%02Xh" % (d, b2)),
        0x80: (2, "SJMP %04X" % rel(pc + 2, b1)),
        0x82: (2, "ANL C,%s" % bit(b1)), 0x83: (1, "MOVC A,@A+PC"),
        0x84: (1, "DIV AB"), 0x85: (3, "MOV %s,%s" % (direct(b2), d)),
        0x90: (3, "MOV DPTR,#%04Xh" % ((b1 << 8) | b2)),
        0x92: (2, "MOV %s,C" % bit(b1)), 0x93: (1, "MOVC A,@A+DPTR"),
        0x94: (2, "SUBB A,#%02Xh" % b1), 0x95: (2, "SUBB A,%s" % d),
        0xA0: (2, "ORL C,/%s" % bit(b1)), 0xA2: (2, "MOV C,%s" % bit(b1)),
        0xA3: (1, "INC DPTR"), 0xA4: (1, "MUL AB"), 0xA5: (1, "DB A5h"),
        0xB0: (2, "ANL C,/%s" % bit(b1)), 0xB2: (2, "CPL %s" % bit(b1)),
        0xB3: (1, "CPL C"),
        0xB4: (3, "CJNE A,#%02Xh,%04X" % (b1, rel(pc + 3, b2))),
        0xB5: (3, "CJNE A,%s,%04X" % (d, rel(pc + 3, b2))),
        0xC0: (2, "PUSH %s" % d), 0xC2: (2, "CLR %s" % bit(b1)),
        0xC3: (1, "CLR C"), 0xC4: (1, "SWAP A"), 0xC5: (2, "XCH A,%s" % d),
        0xD0: (2, "POP %s" % d), 0xD2: (2, "SETB %s" % bit(b1)),
        0xD3: (1, "SETB C"), 0xD4: (1, "DA A"),
        0xD5: (3, "DJNZ %s,%04X" % (d, rel(pc + 3, b2))),
        0xE0: (1, "MOVX A,@DPTR"), 0xE2: (1, "MOVX A,@R0"),
        0xE3: (1, "MOVX A,@R1"), 0xE4: (1, "CLR A"), 0xE5: (2, "MOV A,%s" % d),
        0xF0: (1, "MOVX @DPTR,A"), 0xF2: (1, "MOVX @R0,A"),
        0xF3: (1, "MOVX @R1,A"), 0xF4: (1, "CPL A"), 0xF5: (2, "MOV %s,A" % d),
    }
    n, txt = T[op]
    targets, ends = [], False
    if op == 0x02:
        targets, ends = [(b1 << 8) | b2], True
    elif op == 0x80:
        targets, ends = [rel(pc + 2, b1)], True
    elif op in (0x22, 0x32, 0x73):
        ends = True
    elif op in (0x10, 0x20, 0x30, 0xB4, 0xB5, 0xD5):
        targets = [rel(pc + 3, b2)]
    elif op in (0x40, 0x50, 0x60, 0x70):
        targets = [rel(pc + 2, b1)]
    return n, txt, targets, ends


def listing(m, start, end=None, follow=False):
    todo, done, out = [start], set(), {}
    while todo:
        pc = todo.pop()
        while pc < len(m) and pc not in done:
            if end is not None and pc >= end:
                break
            n, txt, targets, ends = decode(m, pc)
            done.add(pc)
            out[pc] = "%04X  %-9s %s" % (pc, " ".join("%02X" % b for b in m[pc:pc + n]), txt)
            if follow:
                todo.extend(t for t in targets if t not in done)
            pc += n
            if ends and end is None:
                break
        if not follow:
            break
    return [out[k] for k in sorted(out)]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    follow = "--follow" in sys.argv
    m = open(args[0], "rb").read()
    start = int(args[1], 16)
    end = None
    if len(args) > 2:
        end = start + int(args[2][1:], 16) if args[2].startswith("+") else int(args[2], 16)
    print("\n".join(listing(m, start, end, follow)))


if __name__ == "__main__":
    main()
