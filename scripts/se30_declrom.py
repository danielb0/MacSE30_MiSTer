#!/usr/bin/env python3
"""Read the SE/30's video declaration ROM (UK6, Apple 341-0650) as the Slot
Manager would: format block, sResource directory, every sResource's entry
list, and the well-known structures inside them (VPBlock, driver header,
sExecBlock).  Optionally disassembles the 68k code with capstone.

WHY
    The declaration ROM is what the System actually runs against the
    pseudo-slot video (SE30_PLAN.md 2.6, 2.8 item 3).  Its VPBlock states
    the frame-buffer geometry and base offset the ROM's video driver will
    program, and the driver's code shows which hardware bits it touches -
    the slot interrupt enable, the page select - so those are facts about
    the machine, read from Apple's own code, not inferred.

FORMAT (Designing Cards and Drivers for the Macintosh Family, 3rd ed.)
    Format block, last 20 bytes of the ROM:
        DirectoryOffset  4   signed 24-bit in the low 3 bytes, relative to
                             the address of this field
        Length           4
        CRC              4
        RevisionLevel    1
        Format           1   1 = Apple format
        TestPattern      4   $5A932BC7
        Reserved         1
        ByteLanes        1   low nibble = lanes valid, high nibble = ~low
    Entry (directory and sResource lists): 1 byte id, 3 bytes signed
    offset relative to the entry's own address; id $FF ends a list.
    "Word" entries carry their value in the low 16 bits instead.

USAGE
    se30_declrom.py <se30vrom.uk6> [--dis] [--out DIR]
        --dis   disassemble PrimaryInit and the driver routines (capstone)
        --out   also write each code block as a raw .bin into DIR
"""
import argparse
import os
import struct
import sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

TEST_PATTERN = 0x5A932BC7

# sResource entry ids (universal)
UNIVERSAL = {
    0x01: "sRsrcType", 0x02: "sRsrcName", 0x03: "sRsrcIcon",
    0x04: "sRsrcDrvrDir", 0x05: "sRsrcLoadRec", 0x06: "sRsrcBootRec",
    0x07: "sRsrcFlags", 0x08: "sRsrcHWDevId", 0x0A: "MinorBaseOS",
    0x0B: "MinorLength", 0x0C: "MajorBaseOS", 0x0D: "MajorLength",
    0x0F: "sRsrcCicn", 0x10: "sRsrcIcl8", 0x11: "sRsrcIcl4",
    0x40: "sGammaDir", 0x41: "sRsrcVidNames", 0x7E: "sRsrcDrvrDir?",
}
BOARD = {
    0x20: "BoardId", 0x21: "PRAMInitData", 0x22: "PrimaryInit",
    0x23: "TimeOutConst", 0x24: "VendorInfo", 0x25: "BoardFlags",
    0x26: "SecondaryInit", 0x27: "sRsrcVidNames?", 0x28: "sRsrcVidNames?",
}
VENDOR = {1: "VendorId", 2: "SerialNum", 3: "RevLevel", 4: "PartNum", 5: "Date"}
VIDMODE = {1: "mVidParams", 2: "mTable", 3: "mPageCnt", 4: "mDevType"}
DRVR_OS = {1: "sMacOS68000", 2: "sMacOS68020", 3: "sMacOS68030", 4: "sMacOS68040"}
WORD_IDS_UNIVERSAL = {0x07, 0x08}          # value lives in the offset field
WORD_IDS_BOARD = {0x20, 0x25}
WORD_IDS_VIDMODE = {3, 4}
CATEGORY = {1: "catBoard", 3: "catDisplay", 4: "catNetwork", 6: "catCPU"}
CTYPE_DISPLAY = {1: "typeVideo", 2: "typeLCD"}
DRSW = {1: "drSwApple", 3: "drSwMacCPU"}


def s24(v):
    v &= 0xFFFFFF
    return v - 0x1000000 if v & 0x800000 else v


def be32(d, o): return struct.unpack_from(">I", d, o)[0]
def be16(d, o): return struct.unpack_from(">H", d, o)[0]
def s16(d, o): return struct.unpack_from(">h", d, o)[0]


def cstring(d, o):
    e = d.index(b"\0", o)
    return d[o:e].decode("mac-roman", "replace")


def entries(d, o):
    """Yield (id, entry_addr, target_or_value) until the $FF terminator."""
    out = []
    while True:
        w = be32(d, o)
        eid = w >> 24
        if eid == 0xFF:
            return out
        out.append((eid, o, w & 0xFFFFFF))
        o += 4


def hexdump(d, o, n, indent="      "):
    lines = []
    for i in range(o, min(o + n, len(d)), 16):
        chunk = d[i:min(i + 16, o + n)]
        hx = " ".join("%02x" % b for b in chunk)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append("%s%04x: %-48s %s" % (indent, i, hx, asc))
    return "\n".join(lines)


def vpblock(d, o):
    """mVidParams points at a block: long size, then the VPBlock."""
    size = be32(d, o)
    p = o + 4
    f = {}
    f["vpBaseOffset"] = be32(d, p); f["vpRowBytes"] = be16(d, p + 4)
    f["vpBounds"] = tuple(s16(d, p + 6 + 2 * i) for i in range(4))  # top,left,bottom,right
    f["vpVersion"] = be16(d, p + 14); f["vpPackType"] = be16(d, p + 16)
    f["vpPackSize"] = be32(d, p + 18)
    f["vpHRes"] = be32(d, p + 22); f["vpVRes"] = be32(d, p + 26)
    f["vpPixelType"] = be16(d, p + 30); f["vpPixelSize"] = be16(d, p + 32)
    f["vpCmpCount"] = be16(d, p + 34); f["vpCmpSize"] = be16(d, p + 36)
    f["vpPlaneBytes"] = be32(d, p + 38)
    return size, f


def sexec(d, o):
    """sExecBlock: long size, byte revision, byte cpuID, word reserved, long codeOffset."""
    size = be32(d, o)
    rev, cpu = d[o + 4], d[o + 5]
    code_off = be32(d, o + 8)
    return size, rev, cpu, code_off, o + 4 + code_off - 4 + 4  # code addr = blockstart+4? see note


def drvr(d, o):
    """sRsrcDrvrDir entry target: long length, then a DRVR image."""
    length = be32(d, o)
    p = o + 4
    h = {}
    h["drvrFlags"] = be16(d, p); h["drvrDelay"] = be16(d, p + 2)
    h["drvrEMask"] = be16(d, p + 4); h["drvrMenu"] = be16(d, p + 6)
    for i, n in enumerate(("Open", "Prime", "Ctl", "Status", "Close")):
        h["drvr" + n] = be16(d, p + 8 + 2 * i)
    nl = d[p + 18]
    h["drvrName"] = d[p + 19:p + 19 + nl].decode("mac-roman", "replace")
    return length, p, h


def disassemble(d, start, end, base=0, label=""):
    try:
        import capstone
    except ImportError:
        return "      (capstone not installed: pip install capstone)"
    md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_030)
    out = []
    pc = start
    while pc < end:
        got = False
        for ins in md.disasm(bytes(d[pc:end]), pc):
            out.append("      %04x:  %-24s %s %s" % (ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str))
            pc = ins.address + ins.size
            got = True
        if pc >= end:
            break
        # capstone stops at what it cannot decode - A-line traps above all.
        w = be16(d, pc)
        note = "_Trap" if (w & 0xF000) == 0xA000 else "?"
        out.append("      %04x:  %-24s dc.w    $%04x   ; %s" % (pc, "%04x" % w, w, note))
        pc += 2
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom")
    ap.add_argument("--dis", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    d = open(a.rom, "rb").read()
    n = len(d)
    print("ROM: %s, %d bytes" % (a.rom, n))

    fb = n - 20
    dir_off = s24(be32(d, fb))
    length = be32(d, fb + 4); crc = be32(d, fb + 8)
    rev, fmt = d[fb + 12], d[fb + 13]
    tp = be32(d, fb + 14); lanes = d[fb + 19]
    print("Format block @%04x: DirectoryOffset=%d -> %04x  Length=%d  CRC=%08x  Rev=%d  Format=%d  TestPattern=%08x %s  ByteLanes=%02x"
          % (fb, dir_off, fb + dir_off, length, crc, rev, fmt, tp, "ok" if tp == TEST_PATTERN else "BAD", lanes))
    if lanes != 0x0F:
        print("  NOTE: not all byte lanes valid; offsets below assume the image is the packed lane data")
    # CRC per Designing Cards: sum of all bytes with the CRC field as zeros, rotated left each byte
    c = 0
    for i, b in enumerate(d):
        if fb + 8 <= i < fb + 12:
            b = 0
        c = ((c << 1) | (c >> 31)) & 0xFFFFFFFF
        c = (c + b) & 0xFFFFFFFF
    print("  CRC recomputed: %08x %s" % (c, "matches" if c == crc else "DOES NOT MATCH"))

    code_blocks = []  # (name, start, end)
    diro = fb + dir_off
    print("\nsResource directory @%04x" % diro)
    for sid, ea, off in entries(d, diro):
        so = ea + s24(off)
        print("\n== sResource id $%02x @%04x" % (sid, so))
        is_board = sid == 1
        stype = None
        for eid, ea2, off2 in entries(d, so):
            tgt = ea2 + s24(off2)
            name = (BOARD if is_board else {}).get(eid) or UNIVERSAL.get(eid, "?")
            wordy = eid in WORD_IDS_UNIVERSAL or (is_board and eid in WORD_IDS_BOARD)
            if wordy:
                print("  $%02x %-14s = $%04x" % (eid, name, off2 & 0xFFFF))
                continue
            print("  $%02x %-14s -> %04x" % (eid, name, tgt))
            if eid == 0x01:
                cat, ct, sw, hw = (be16(d, tgt + 2 * i) for i in range(4))
                stype = (cat, ct, sw, hw)
                print("      Category=%d %s  cType=%d %s  DrSW=%d %s  DrHW=%d"
                      % (cat, CATEGORY.get(cat, ""), ct, CTYPE_DISPLAY.get(ct, "") if cat == 3 else "",
                         sw, DRSW.get(sw, ""), hw))
            elif eid == 0x02:
                print("      \"%s\"" % cstring(d, tgt))
            elif eid in (0x0A, 0x0B, 0x0C, 0x0D):
                print("      long = $%08x (%d)" % (be32(d, tgt), be32(d, tgt)))
            elif is_board and eid == 0x24:
                for vid, vea, voff in entries(d, tgt):
                    vt = vea + s24(voff)
                    print("      %d %-9s \"%s\"" % (vid, VENDOR.get(vid, "?"), cstring(d, vt)))
            elif is_board and eid in (0x22, 0x26):
                size = be32(d, tgt); r, cpu = d[tgt + 4], d[tgt + 5]; co = be32(d, tgt + 8)
                code = tgt + 8 + co
                print("      sExecBlock size=%d rev=%d cpuID=%d codeOffset=%d -> code @%04x..%04x"
                      % (size, r, cpu, co, code, tgt + 4 + size))
                code_blocks.append((name, code, tgt + 4 + size))
            elif eid == 0x04:
                for oid, oea, ooff in entries(d, tgt):
                    ot = oea + s24(ooff)
                    if stype and stype[2] != 1:
                        # not an Apple DRVR: treat the block as an sExecBlock
                        size = be32(d, ot); r, cpu = d[ot + 4], d[ot + 5]; co = be32(d, ot + 8)
                        code = ot + 8 + co
                        print("      %d %s -> %04x: sExecBlock size=%d rev=%d cpuID=%d codeOffset=%d -> code @%04x..%04x"
                              % (oid, DRVR_OS.get(oid, "?"), ot, size, r, cpu, co, code, ot + 4 + size))
                        code_blocks.append(("%s(DrSW=%d)" % (name, stype[2]), code, ot + 4 + size))
                        continue
                    ln, p, h = drvr(d, ot)
                    print("      %d %s -> %04x: driver length=%d" % (oid, DRVR_OS.get(oid, "?"), ot, ln))
                    print("        drvrFlags=$%04x drvrDelay=%d drvrEMask=$%04x drvrMenu=%d name=\"%s\""
                          % (h["drvrFlags"], h["drvrDelay"], h["drvrEMask"], h["drvrMenu"], h["drvrName"]))
                    print("        entry offsets: Open=$%04x Prime=$%04x Ctl=$%04x Status=$%04x Close=$%04x"
                          % tuple(h["drvr" + k] for k in ("Open", "Prime", "Ctl", "Status", "Close")))
                    code_blocks.append(("%s DRVR @%04x (base)" % (name, p), p, ot + 4 + ln))
                    for k in ("Open", "Prime", "Ctl", "Status", "Close"):
                        print("          %-6s @%04x" % (k, p + h["drvr" + k]))
            elif eid == 0x40:
                for gid, gea, goff in entries(d, tgt):
                    gt = gea + s24(goff)
                    print("      gamma %d -> %04x" % (gid, gt))
                    print(hexdump(d, gt, 32))
            elif eid >= 0x80 and stype and stype[0] == 3:
                # a video mode sResource
                print("      video mode $%02x:" % eid)
                for mid, mea, moff in entries(d, tgt):
                    mt = mea + s24(moff)
                    mname = VIDMODE.get(mid, "?")
                    if mid in WORD_IDS_VIDMODE:
                        print("        %d %-10s = %d" % (mid, mname, moff & 0xFFFF))
                    elif mid == 1:
                        size, f = vpblock(d, mt)
                        print("        %d %-10s -> %04x (block size %d)" % (mid, mname, mt, size))
                        for k, v in f.items():
                            if k == "vpBounds":
                                print("            %-13s top=%d left=%d bottom=%d right=%d" % ((k,) + v))
                            elif k in ("vpHRes", "vpVRes"):
                                print("            %-13s $%08x = %.2f dpi" % (k, v, v / 65536))
                            else:
                                print("            %-13s %s" % (k, v))
                    else:
                        print("        %d %-10s -> %04x" % (mid, mname, mt))
                        print(hexdump(d, mt, 32, "            "))
            else:
                print(hexdump(d, tgt, 32))

    if a.out:
        os.makedirs(a.out, exist_ok=True)
    for name, s, e in code_blocks:
        print("\n---- %s: %04x..%04x (%d bytes)" % (name, s, e, e - s))
        if a.out:
            fn = os.path.join(a.out, "%s_%04x.bin" % (name.split()[0], s))
            open(fn, "wb").write(d[s:e])
            print("     written %s" % fn)
        if a.dis:
            print(disassemble(d, s, e))


if __name__ == "__main__":
    main()
