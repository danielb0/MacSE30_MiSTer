# KNOWN ISSUES 66: pmap_enter's "same physical page" test without PG_V (m68k pmap_motorola.c).
# In: netbsd-WSFBSBC-nopoke-mono (the Booter-poke and mono-console fixes).  Out: ...-pa0 (+ .gz)
import gzip, hashlib
src = 'C:/temp/Mac/netbsd-WSFBSBC-nopoke-mono'; dst = src + '-pa0'
b = bytearray(open(src, 'rb').read())
assert hashlib.md5(b).hexdigest() == '2f3dc6317f702a118173e51a74405e90'
FO = 0x26198 - 0x26118            # file offset - address, pmap_enter's section
def put(addr, old, new):
    old = bytes.fromhex(old); new = bytes.fromhex(new); assert len(old) == len(new)
    o = addr + FO; assert bytes(b[o:o+len(old)]) == old, 'unexpected bytes at %x' % addr
    b[o:o+len(new)] = new
# 261b0: pte = pm_ptab + (va >> 13) * 4; opa = *pte & PG_FRAME; if (opa == pa) same-page path
put(0x261b0, '2002' '720d' 'e2a8' 'e588' '2652' 'd7c0' '2613' '2003' '0240e000' 'b084' '6660' '602e',
             'e9c20013'             # bfextu d2{0:19},d0     va >> 13 (two bytes shorter; d1 is dead here)
             'e588'                 # lsl.l #2,d0
             '2652' 'd7c0'          # movea.l (a2),a3 ; adda.l d0,a3
             '2613' '2003'          # move.l (a3),d3 ; move.l d3,d0
             '0240e001'             # andi.w #$e001,d0       PG_FRAME | PG_V
             '5380'                 # subq.l #1,d0           valid: the frame; invalid (0): $FFFFFFFF
             'b084'                 # cmp.l d4,d0            same page AND valid
             '6660' '602e')         # bne $26228 ; bra $261f8  (as before)
# 26228: if (opa) remove the old mapping  ->  if (the old pte was valid)
put(0x26228, '4a80', '5280')        # tst.l d0 -> addq.l #1,d0   (0 only for the invalid pte)
open(dst, 'wb').write(b)
with open(dst + '.gz', 'wb') as f:
    with gzip.GzipFile(filename='', mode='wb', fileobj=f, compresslevel=9, mtime=0) as g: g.write(b)
print('written', dst, hashlib.md5(b).hexdigest(), len(b))
