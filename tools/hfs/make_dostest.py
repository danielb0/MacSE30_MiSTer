"""Build the PC Exchange lookup test floppy (SE30_PLAN.md KNOWN ISSUES 9).

A 1.44 MB HFS floppy image holding three hand-assembled applications:
  DOSTest  - finds the first mounted volume whose ioVFSID is non-zero (a File System
             Manager foreign volume: PC Exchange's DOS disk), waits up to ~120 s for one,
             then runs the File Manager calls the Finder and TeachText make, and records
             every result in the NAMES of files it creates next to itself (default volume
             and directory = the folder it was launched from):
               "DT V vvvv ffff dddd rrrr"  vRefNum, ioVFSID, drive number, PBGetCatInfo
                                           ioFDirIndex=1 result (the root's first entry)
               "DT N <name>"               the name that enumeration returned
               "DT R aaaa bbbb cccc dddd"  PBGetCatInfo by THAT name (dirID 2);
                                           PBGetCatInfo by name "NETWORKS.TXT" (dirID 2);
                                           PBHOpenDF "NETWORKS.TXT" fsRdPerm (closed if open);
                                           _HOpen "NETWORKS.TXT" fsRdPerm (closed if open)
               "DT S nnnn eeee ffff"       the number of root entries PBGetCatInfo enumerates
                                           (ioFDirIndex 1.. until an error); PBGetCatInfo by name
                                           "NETWORKS.TXT" with ioDirID 0; PBGetCatInfo by name
                                           "NOSUCH.TXT" (a control: fnfErr FFD5 expected)
               "DT C bbbb cccc"            the same GetCatInfo-by-name and HOpenDF with the
                                           68030 caches OFF (CACR $0808), then CACR $2909
                                           (both caches cleared and re-enabled, write
                                           allocate) before exit
               "DT V none"                 no foreign volume appeared
             All values are hex words (ioResult: 0000 = noErr, FFD5 = fnfErr -43,
             FFCF = opWrErr -49, FFCA = permErr -54, FFD1 = fBsyErr -47, FFC6 = extFSErr).
  CacheOff - writes CACR $0808 (both 68030 caches cleared and disabled) and exits, so a
             Finder/TeachText open can be tried with the caches off, no compile needed.
  CacheOn  - writes CACR $2909 (cleared, enabled, write allocate - the ROM's $2101 plus
             the clear bits) and exits.
68k Mac OS runs applications in supervisor mode, so MOVEC is legal (as in make_fidtest.py).

Usage: python make_dostest.py out.img [--hd source.vhd out.vhd]
  out.img  the floppy (raw 1,474,560 bytes; our core and MAME's SE/30 both take it)
  --hd     also a copy of a System 7.5.5 HD image with the three apps at the root (for a
           board without a second floppy drive: boot from it, mount the DOS disk, run
           DOSTest; the results appear at the root). --startup adds DOSTest to Startup
           Items for a MAME run with no mouse. The HFS volume is re-laid by machfs as in
           make_fidtest.py (CNIDs renumbered, Desktop DB fresh; the boot blocks kept).
The CODE 1 of DOSTest is also written beside out.img as out.img.code1 (unidasm -arch m68030).
"""
import sys, struct, machfs
from macresources import Resource, make_file

def pstr(s):
    b = s.encode("mac-roman"); assert len(b) < 32, s; return bytes([len(b)]) + b

class Asm:
    def __init__(self): self.items, self.labels, self.fix = [], {}, []
    def here(self): return sum(len(x) for x in self.items)
    def emit(self, h): self.items.append(bytes.fromhex(h.replace(" ", "")))
    def raw(self, b): self.items.append(b)
    def label(self, n): assert n not in self.labels, n; self.labels[n] = self.here()
    def ref_w(self, n): self.fix.append((self.here(), n, "w")); self.items.append(b"\0\0")
    def lea_pc(self, reg, n): self.items.append(bytes([0x41 | (reg << 1), 0xFA])); self.ref_w(n)   # LEA (d16,PC),An
    def bsr(self, n): self.items.append(b"\x61\x00"); self.ref_w(n)
    def bra(self, n): self.items.append(b"\x60\x00"); self.ref_w(n)
    def bne(self, n): self.items.append(b"\x66\x00"); self.ref_w(n)
    def beq(self, n): self.items.append(b"\x67\x00"); self.ref_w(n)
    def movb_pcidx_d2_a1inc(self, n):   # MOVE.B (d8,PC,D2.W),(A1)+
        self.items.append(b"\x12\xFB"); self.fix.append((self.here(), n, "b8")); self.items.append(b"\x20\x00")
    def link(self):
        code = bytearray(b"".join(self.items))
        for pos, n, kind in self.fix:
            d = self.labels[n] - pos
            if kind == "w": code[pos:pos + 2] = struct.pack(">h", d)
            else: assert -128 <= d < 128, (n, d); code[pos + 1] = d & 0xFF
        return bytes(code)

# Frame (A6-relative): -$100 param block (256 B), -$140 name buffer (64 B), -$180 marker
# name (64 B), -$200.. result words. Registers: D3 vRefNum, D4 drive, D5 FSID, D6 counters.
def assemble_dostest():
    a = Asm(); E = a.emit
    E("0000 0001")                        # CODE 1 header: jump-table offset 0, one entry
    E("4E56 FC00")                        # LINK A6,#-$400
    E("A063 486D FFFC A86E A8FE A912 A930 42A7 A97B A9CC A850")   # _MaxApplZone ; InitGraf(&thePort) ; _InitFonts ; _InitWindows ; _InitMenus ; InitDialogs(nil) ; _TEInit ; _InitCursor (GetNextEvent needs the Toolbox up)
    E("7600 7800 7A00")                   # MOVEQ #0,D3/D4/D5
    E("426E FDF0")                        # CLR.W -$210(A6)  retry counter
    # ---- volume scan: PBHGetVInfo ioVolIndex 1.., first with ioVFSID != 0
    a.label("vretry")
    E("7C01")                             # MOVEQ #1,D6
    a.label("vscan")
    a.bsr("clrpb")                        # A0 = cleared PB
    E("43EE FEC0 2149 0012")              # LEA -$140(A6),A1 ; MOVE.L A1,ioNamePtr($12,A0)
    E("3146 001C")                        # MOVE.W D6,ioVolIndex($1C,A0)
    E("A207")                             # _HGetVInfo
    E("4A68 0010"); a.bne("vend")         # TST.W ioResult ; BNE vend (end of the volume list)
    E("3228 0046"); a.beq("vnext")        # MOVE.W ioVFSID($46,A0),D1 ; BEQ vnext (HFS)
    E("3A01")                             # MOVE.W D1,D5
    E("3628 0016")                        # MOVE.W ioVRefNum($16,A0),D3
    E("3828 0042")                        # MOVE.W ioVDrvInfo($42,A0),D4
    a.bra("found")
    a.label("vnext")
    E("5246 0C46 0010"); a.bne("vscan")   # ADDQ.W #1,D6 ; CMPI.W #16,D6 ; BNE vscan
    a.label("vend")
    E("558F 3F3C FFFF 486E FDC0 A970 548F")   # GetNextEvent(everyEvent, &event at -$240): the Event Manager mounts an inserted disk here
    E("701E 2040 A03B")                   # MOVEQ #30,D0 ; MOVEA.L D0,A0 ; _Delay (0.5 s)
    E("526E FDF0 0C6E 00F0 FDF0"); a.bne("vretry")   # ADDQ.W #1,retry ; CMPI.W #240,retry ; BNE vretry (120 s)
    a.lea_pc(1, "mnone"); a.bsr("mkmark"); a.bra("fin")
    # ---- index 1 of the root
    a.label("found")
    a.bsr("clrpb")
    E("43EE FEC0 2149 0012")              # ioNamePtr = name buffer
    E("3143 0016")                        # ioVRefNum = D3
    E("317C 0001 001C")                   # ioFDirIndex = 1
    E("217C 0000 0002 0030")              # ioDirID = 2
    E("7009 A260")                        # _GetCatInfo
    E("3E28 0010")                        # MOVE.W ioResult,D7
    a.lea_pc(1, "tmplV"); a.bsr("cptmpl")
    E("3203"); a.bsr("hex4"); E("5289")   # vRefNum
    E("3205"); a.bsr("hex4"); E("5289")   # FSID
    E("3204"); a.bsr("hex4"); E("5289")   # drive
    E("3207"); a.bsr("hex4")              # index-1 result
    E("43EE FE80"); a.bsr("mkmark")
    # ---- "DT N <name>"
    E("41EE FEC0 7000 1018")              # LEA name,A0 ; MOVEQ #0,D0 ; MOVE.B (A0)+,D0
    E("0C00 001A 6302 701A")              # CMPI.B #26,D0 ; BLS.S +2 ; MOVEQ #26,D0
    E("43EE FE80")                        # LEA marker,A1
    E("1400 5A02 12C2")                   # MOVE.B D0,D2 ; ADDQ.B #5,D2 ; MOVE.B D2,(A1)+
    a.items.append(b"\x45\xFA"); a.ref_w("pfxN")   # LEA pfxN(PC),A2
    E("7204"); a.label("cpn1"); E("12DA 51C9 FFFC")           # 5 bytes of "DT N "
    E("5340 6B06"); a.label("cpn2"); E("12D8 51C8 FFFC")      # SUBQ.W #1,D0 ; BMI.S +6 ; copy the name
    E("43EE FE80"); a.bsr("mkmark")
    # ---- lookups with the caches as found
    E("43EE FEC0 7402"); a.bsr("gciname"); E("3D40 FE00")     # by the enumerated name, dirID 2
    a.lea_pc(1, "netname"); E("7402"); a.bsr("gciname"); E("3D40 FE02")
    a.lea_pc(1, "netname"); E("7402"); a.bsr("opendf");  E("3D40 FE04")
    a.lea_pc(1, "netname"); E("7402"); a.bsr("hopen");   E("3D40 FE06")
    a.lea_pc(1, "tmplR"); a.bsr("cptmpl")
    for off in ("FE00", "FE02", "FE04"): E("322E " + off); a.bsr("hex4"); E("5289")
    E("322E FE06"); a.bsr("hex4")
    E("43EE FE80"); a.bsr("mkmark")
    # ---- how many root entries enumerate, a dirID-0 lookup, and a name that does not exist
    E("7C01")                             # MOVEQ #1,D6
    a.label("cnt")
    a.bsr("clrpb")
    E("43EE FEC0 2149 0012 3143 0016 3146 001C 217C 0000 0002 0030 7009 A260")
    E("4A68 0010"); a.bne("cntend")       # TST.W ioResult ; BNE cntend
    E("5246 0C46 03E8"); a.bne("cnt")     # ADDQ.W #1,D6 ; CMPI.W #1000,D6 ; BNE cnt
    a.label("cntend")
    E("5346 3D46 FE0C")                   # SUBQ.W #1,D6 ; the count
    a.lea_pc(1, "netname"); E("7400"); a.bsr("gciname"); E("3D40 FE0E")   # dirID 0 (the volume's root)
    a.lea_pc(1, "noname"); E("7402"); a.bsr("gciname"); E("3D40 FE10")    # NOSUCH.TXT: fnfErr FFD5 expected
    a.lea_pc(1, "tmplS"); a.bsr("cptmpl")
    E("322E FE0C"); a.bsr("hex4"); E("5289")
    E("322E FE0E"); a.bsr("hex4"); E("5289")
    E("322E FE10"); a.bsr("hex4")
    E("43EE FE80"); a.bsr("mkmark")
    # ---- the same with the caches off
    E("203C 0000 0808 4E7B 0002")         # MOVE.L #$0808,D0 ; MOVEC D0,CACR
    a.lea_pc(1, "netname"); E("7402"); a.bsr("gciname"); E("3D40 FE08")
    a.lea_pc(1, "netname"); E("7402"); a.bsr("opendf");  E("3D40 FE0A")
    E("203C 0000 2909 4E7B 0002")         # CACR = clear both, enable both, WA
    a.lea_pc(1, "tmplC"); a.bsr("cptmpl")
    E("322E FE08"); a.bsr("hex4"); E("5289")
    E("322E FE0A"); a.bsr("hex4")
    E("43EE FE80"); a.bsr("mkmark")
    a.label("fin")
    a.bsr("clrpb"); E("A013")             # _FlushVol, default volume
    E("4E5E A9F4")                        # UNLK A6 ; _ExitToShell
    # ---- subroutines
    a.label("clrpb")                      # A0 = the 256-byte PB, cleared (D0 used)
    E("41EE FF00 703F"); a.label("clr1"); E("4298 51C8 FFFC"); E("41EE FF00 4E75")
    a.label("mkmark")                     # A1 = Pascal name: _HCreate on the default volume/dir
    E("2F09"); a.bsr("clrpb"); E("225F 2149 0012 A208 4E75")
    a.label("cptmpl")                     # copy the template at (A1) to the marker; A1 = marker+6
    E("41EE FE80 7000 1011"); a.label("cpt1"); E("10D9 51C8 FFFC"); E("43EE FE86 4E75")
    a.label("gciname")                    # A1 name, D2 dirID -> D0 = PBGetCatInfo ioResult
    E("2F09 2F02"); a.bsr("clrpb"); E("241F 225F")
    E("2149 0012 3143 0016 2142 0030 7009 A260 3028 0010 4E75")
    a.label("opendf")                     # A1 name, D2 dirID -> D0 = PBHOpenDF result (closed again)
    E("2F09 2F02"); a.bsr("clrpb"); E("241F 225F")
    E("2149 0012 3143 0016 2142 0030 117C 0001 001B 701A A260"); a.bra("openx")
    a.label("hopen")                      # the same through _HOpen
    E("2F09 2F02"); a.bsr("clrpb"); E("241F 225F")
    E("2149 0012 3143 0016 2142 0030 117C 0001 001B A200")
    a.label("openx")
    E("3028 0010 4A40"); a.bne("openr")   # MOVE.W ioResult,D0 ; TST.W D0 ; BNE openr
    E("3E28 0018"); a.bsr("clrpb"); E("3147 0018 A001 7000")   # refnum -> _Close ; D0 = 0
    a.label("openr"); E("4E75")
    a.label("hex4"); E("7003"); a.label("h4l"); E("E959 3401 0242 000F"); a.movb_pcidx_d2_a1inc("hextab"); E("51C8 FFF2 4E75")
    a.label("hextab"); a.raw(b"0123456789ABCDEF")
    a.label("tmplV"); a.raw(pstr("DT V xxxx xxxx xxxx xxxx"))
    a.label("tmplR"); a.raw(pstr("DT R xxxx xxxx xxxx xxxx"))
    a.label("tmplC"); a.raw(pstr("DT C xxxx xxxx"))
    a.label("tmplS"); a.raw(pstr("DT S xxxx xxxx xxxx"))
    a.label("noname"); a.raw(pstr("NOSUCH.TXT"))
    a.label("mnone"); a.raw(pstr("DT V none"))
    a.label("pfxN"); a.raw(b"DT N ")
    a.label("netname"); a.raw(pstr("NETWORKS.TXT"))
    return a.link()

def cacr_app(value):
    return bytes.fromhex("0000 0001 203C %08X 4E7B 0002 A9F4".replace(" ", "") % value)

def make_app(code1, creator):
    code0 = struct.pack(">IIII", 0x28, 0x100, 8, 0x20) + bytes.fromhex("0000 3F3C 0001 A9F0".replace(" ", ""))
    app = machfs.File(); app.type, app.creator = b"APPL", creator
    sizer = struct.pack(">HII", 0x4880, 0x40000, 0x20000)
    app.rsrc = make_file([Resource(b"CODE", 0, data=code0), Resource(b"CODE", 1, data=code1), Resource(b"SIZE", -1, data=sizer)])
    return app

def main():
    out = sys.argv[1]
    code1 = assemble_dostest()
    open(out + ".code1", "wb").write(code1)
    v = machfs.Volume(); v.name = "DOSTest"
    v["DOSTest"] = make_app(code1, b"DOST")
    v["CacheOff"] = make_app(cacr_app(0x0808), b"CAC0")
    v["CacheOn"] = make_app(cacr_app(0x2909), b"CAC1")
    img = v.write(size=1474560, align=512, desktopdb=True, bootable=False)
    open(out, "wb").write(img)
    print("wrote %s (%d bytes); DOSTest CODE 1 is %d bytes" % (out, len(img), len(code1)))
    if "--hd" in sys.argv:
        i = sys.argv.index("--hd"); src, dst = sys.argv[i + 1], sys.argv[i + 2]
        img = bytearray(open(src, "rb").read())
        pm = img[512:1024]; n = struct.unpack(">I", pm[4:8])[0]
        for k in range(n):
            e = img[512 * (1 + k):512 * (2 + k)]
            if e[48:80].split(b"\0")[0] == b"Apple_HFS":
                start, cnt = struct.unpack(">II", e[8:16]); break
        base, size = start * 512, cnt * 512
        hv = machfs.Volume(); hv.read(bytes(img[base:base + size]))
        hv.name = bytes(img[base + 1024 + 37:base + 1024 + 37 + img[base + 1024 + 36]]).decode("mac-roman")
        hv["DOSTest"] = make_app(code1, b"DOST")
        hv["CacheOff"] = make_app(cacr_app(0x0808), b"CAC0")
        hv["CacheOn"] = make_app(cacr_app(0x2909), b"CAC1")
        if "--startup" in sys.argv:              # the MAME run: no mouse, so DOSTest runs itself at boot
            hv["System Folder"]["Startup Items"]["DOSTest"] = make_app(code1, b"DOST")
            for folder, name in (("Control Panels", "Extensions Manager"), ("Extensions", "EM Extension")):
                if name in hv["System Folder"][folder]: del hv["System Folder"][folder][name]
        vol = hv.write(size=size, align=512, desktopdb=True, bootable=True)
        vol = img[base:base + 1024] + vol[1024:]
        img[base:base + size] = vol
        open(dst, "wb").write(img)
        print("wrote %s" % dst)

if __name__ == "__main__":
    main()
