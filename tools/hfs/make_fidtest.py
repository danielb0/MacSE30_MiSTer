"""Build a scratch test image for the orphan-file-thread bug (SE30_PLAN.md 10.4):
a copy of a System 7.5.5 disk image with two root files 'FIDTest A'/'FIDTest B' and
an application 'FIDTest' in Startup Items that, at boot, creates a file ID
reference (file thread) on both, deletes B with _HDelete, and leaves a marker
file named 'FIDTest R <cre A> <cre B> <del B>' (hex result words). Afterwards
hfs_threads.py on the image shows whether B's thread was removed with it (A's
thread is the control). The HFS volume is re-laid by machfs (CNIDs renumbered,
Desktop DB fresh, EVERY file given a thread - so the create calls return fidExists
-1303 = $FAE9); the partition map, the other partitions and the boot blocks are kept.
Usage: python make_fidtest.py source.vhd out.vhd [--markers] [--cacr HHHH]
(--cacr: the app first writes that value to the 68030 CACR, e.g. 0808 = both caches
cleared and off, 0801 = data cache off, 2108 = instruction cache off; the ROM runs $2101)  (--markers: the app writes
$F1D7E57A to $800000 (ROM, ignored) before the delete and $F1D7E57B after, for a debugger's watchpoints)"""
import sys, struct, machfs
from macresources import Resource, make_file

def pstr(s):
    b = s.encode("mac-roman"); return bytes([len(b)]) + b

def assemble(markers=False, cacr=None):
    """CODE 1: header (JT offset 0, 1 entry) then the code; PC-relative labels resolved."""
    VOL = "System 7.5.5 80MB:"
    items, labels, fix = [], {}, []
    def emit(h): items.append(bytes.fromhex(h))
    def label(n): labels[n] = sum(len(x) for x in items)
    def lea_pc(reg, n):          # LEA (d16,PC),An: 41FA/43FA + d16
        items.append(bytes([0x41 | (reg << 1), 0xFA])); fix.append((sum(len(x) for x in items), n, "w")); items.append(b"\0\0")
    def bsr(n):
        items.append(b"\x61\x00"); fix.append((sum(len(x) for x in items), n, "w")); items.append(b"\0\0")
    def movb_pcidx_d2_a1inc(n):  # MOVE.B (d8,PC,D2.W),(A1)+
        items.append(b"\x12\xFB"); fix.append((sum(len(x) for x in items), n, "b8")); items.append(b"\x20\x00")
    emit("0000 0001")                                   # jump-table offset 0, one entry
    emit("4E56 FE00")                                   # LINK A6,#-512   (-256: param block, -512: name buffer)
    if cacr is not None:
        emit("203C %08X 4E7B 0002" % cacr)              # MOVE.L #cacr,D0 ; MOVEC D0,CACR  (supervisor mode, as all 68k Mac OS code runs)
    emit("41EE FF00 703F"); label("clr"); emit("4298 51C8 FFFC")   # clear the 256-byte block
    for name, call, dreg in (("nameA", "7014 A260", 3), ("nameB", "7014 A260", 4), ("nameB", "A209", 5)):
        emit("41EE FF00"); lea_pc(1, name)              # LEA -256(A6),A0 ; LEA name(PC),A1
        emit("2149 0012 4268 0016 42A8 0030")           # ioNamePtr, ioVRefNum = 0, ioDirID/ioSrcDirID = 0
        if markers and dreg == 5: emit("203C F1D7E579 5280 23C0 0080 0000")   # MOVE.L #$F1D7E579,D0 ; ADDQ.L #1,D0 ; MOVE.L D0,($800000).L: writes $F1D7E57A to the ROM's 24-bit address (ignored by the hardware), a value an emulator's debugger can watch for (computed, so the code itself never holds it)
        emit(call)                                      # MOVEQ #$14,D0 ; _HFSDispatch (CreateFileIDRef)  |  _HDelete
        if markers and dreg == 5: emit("203C F1D7E579 5480 23C0 0080 0000")   # writes $F1D7E57B after the call
        emit("3%X28 0010" % (dreg * 2))                 # MOVE.W ioResult(A0),Dn
    emit("43EE FE00"); lea_pc(0, "prefix"); emit("701C"); label("cp"); emit("12D8 51C8 FFFC")  # copy 29 bytes (len + 28)
    for d in (3, 4, 5):
        if d > 3: emit("12FC 0020")
        emit("320%d" % d); bsr("hex4")
    emit("41EE FF00 43EE FE00 2149 0012 4268 0016 4228 001A 42A8 0030 A208")  # _HCreate the marker
    emit("41EE FF00 42A8 0012 4268 0016 A013")                                 # _FlushVol, the default volume: the catalog reaches the disk now
    emit("4E5E A9F4")                                   # UNLK A6 ; _ExitToShell
    label("hex4"); emit("7003"); label("h4l"); emit("E959 3401 0242 000F"); movb_pcidx_d2_a1inc("hextab"); emit("51C8 FFF2 4E75")
    label("hextab"); items.append(b"0123456789ABCDEF")
    label("prefix"); items.append(pstr(VOL + "FIDTest R xxxx yyyy zzzz"))
    label("nameA"); items.append(pstr(VOL + "FIDTest A"))
    label("nameB"); items.append(pstr(VOL + "FIDTest B"))
    code = bytearray(b"".join(items))
    for pos, n, kind in fix:
        d = labels[n] - pos
        if kind == "w": code[pos:pos + 2] = struct.pack(">h", d)
        else:
            assert -128 <= d < 128, d; code[pos + 1] = d & 0xFF
    return bytes(code)

def main():
    src, out = sys.argv[1], sys.argv[2]
    markers = "--markers" in sys.argv[3:]
    cacr = int(sys.argv[sys.argv.index("--cacr") + 1], 16) if "--cacr" in sys.argv[3:] else None
    img = bytearray(open(src, "rb").read())
    pm = img[512:1024]; n = struct.unpack(">I", pm[4:8])[0]
    for i in range(n):
        e = img[512 * (1 + i):512 * (2 + i)]
        if e[48:80].split(b"\0")[0] == b"Apple_HFS":
            start, cnt = struct.unpack(">II", e[8:16]); break
    base, size = start * 512, cnt * 512
    v = machfs.Volume(); v.read(bytes(img[base:base + size]))
    v.name = bytes(img[base + 1024 + 37:base + 1024 + 37 + img[base + 1024 + 36]]).decode("mac-roman")  # machfs drops it
    for nm in ("A", "B"):
        f = machfs.File(); f.type, f.creator = b"TEXT", b"ttxt"; f.data = ("FIDTest target %s\r" % nm).encode()
        v["FIDTest " + nm] = f
    code1 = assemble(markers, cacr)
    code0 = struct.pack(">IIII", 0x28, 0x100, 8, 0x20) + bytes.fromhex("0000 3F3C 0001 A9F0")
    app = machfs.File(); app.type, app.creator = b"APPL", b"FIDT"
    sizer = struct.pack(">HII", 0x4880, 0x40000, 0x20000)   # SIZE -1: suspend/resume, activate on switch, 32-bit clean; 256K / 128K
    app.rsrc = make_file([Resource(b"CODE", 0, data=code0), Resource(b"CODE", 1, data=code1), Resource(b"SIZE", -1, data=sizer)])
    v["System Folder"]["Startup Items"]["FIDTest"] = app
    for folder, name in (("Control Panels", "Extensions Manager"), ("Extensions", "EM Extension")):
        if name in v["System Folder"][folder]:
            del v["System Folder"][folder][name]          # no Extensions Manager at startup (an emulator's stuck space bar opened it)
    vol = v.write(size=size, align=512, desktopdb=True, bootable=True)
    assert len(vol) == size, (len(vol), size)
    vol = img[base:base + 1024] + vol[1024:]                      # the original boot blocks, verbatim
    img[base:base + size] = vol
    open(out, "wb").write(img)
    open(out + ".code1", "wb").write(code1)
    print("wrote %s (%d bytes); CODE 1 is %d bytes" % (out, len(img), len(code1)))

if __name__ == "__main__":
    main()
