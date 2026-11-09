#!/usr/bin/env python3
"""mkiso_one.py - a minimal ISO 9660 image holding one file, for carrying a
NetBSD kernel to the Mac side through the core's CD-ROM (the way
NetBSD-GENERICFIX.iso was made, 2026-11-08; KNOWN ISSUES 62 and 63).

    mkiso_one.py FILE NAME.EXT VOLID out.iso

NAME.EXT is the ISO 9660 level-1 name (8.3, A-Z 0-9 _); VOLID up to 32 of
the same characters.  Layout: PVD at block 16, terminator 17, L and M
path tables 18 and 19, the root directory 20, the file from block 21.
"""
import struct, sys, time, os

def both(v, w):           # ISO 9660 both-byte-order integers
    return v.to_bytes(w, 'little') + v.to_bytes(w, 'big')

def dirrec(lba, size, flags, name, date):
    rec = bytearray()
    rec += b'\0'                       # length, filled below
    rec += b'\0'                       # extended attribute length
    rec += both(lba, 4) + both(size, 4)
    rec += date + bytes([flags, 0, 0]) + both(1, 2)
    rec += bytes([len(name)]) + name
    if len(rec) & 1:
        rec += b'\0'
    rec[0] = len(rec)
    return bytes(rec)

def main(path, name, volid, out):
    data = open(path, 'rb').read()
    name = name.upper().encode()
    isoname = name + b';1'
    t = time.localtime()
    rdate = bytes([t.tm_year - 1900, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, 0])
    vdate = time.strftime('%Y%m%d%H%M%S00', t).encode() + b'\0'
    file_blocks = (len(data) + 2047) // 2048
    total = 21 + file_blocks

    root = dirrec(20, 2048, 2, b'\0', rdate) + dirrec(20, 2048, 2, b'\1', rdate) \
         + dirrec(21, len(data), 0, isoname, rdate)
    root = root.ljust(2048, b'\0')
    ptl = (bytes([1, 0]) + (20).to_bytes(4, 'little') + (1).to_bytes(2, 'little') + b'\0\0').ljust(2048, b'\0')
    ptm = (bytes([1, 0]) + (20).to_bytes(4, 'big') + (1).to_bytes(2, 'big') + b'\0\0').ljust(2048, b'\0')

    pvd = bytearray(2048)
    pvd[0:7] = b'\x01CD001\x01'
    pvd[8:40] = b' ' * 32
    pvd[40:72] = volid.upper().encode().ljust(32)
    pvd[80:88] = both(total, 4)
    pvd[120:124] = both(1, 2)          # volume set size
    pvd[124:128] = both(1, 2)          # volume sequence number
    pvd[128:132] = both(2048, 2)
    pvd[132:140] = both(10, 4)         # path table size
    pvd[140:144] = (18).to_bytes(4, 'little')
    pvd[148:152] = (19).to_bytes(4, 'big')
    pvd[156:190] = dirrec(20, 2048, 2, b'\0', rdate)
    pvd[190:318] = volid.upper().encode().ljust(128)
    pvd[318:446] = b' ' * 128
    pvd[446:574] = b' ' * 128
    pvd[574:702] = b' ' * 128
    pvd[702:739] = b' ' * 37
    pvd[739:776] = b' ' * 37
    pvd[776:813] = b' ' * 37
    pvd[813:830] = vdate
    pvd[830:847] = vdate
    pvd[847:864] = b'0' * 16 + b'\0'
    pvd[864:881] = b'0' * 16 + b'\0'
    pvd[881] = 1
    term = b'\xffCD001\x01'.ljust(2048, b'\0')

    with open(out, 'wb') as f:
        f.write(b'\0' * (16 * 2048))
        f.write(bytes(pvd)); f.write(term); f.write(ptl); f.write(ptm); f.write(root)
        f.write(data.ljust(file_blocks * 2048, b'\0'))
    print(f"{out}: {total} blocks, {os.path.getsize(out)} bytes, {isoname.decode()} {len(data)} bytes")

if __name__ == '__main__':
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
