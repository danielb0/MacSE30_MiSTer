import sys, struct
img = sys.argv[1]
ROOT = 96 * 512
with open(img, 'rb') as f:
    f.seek(ROOT)
    head = f.read(16384)
# UFS (4.2 FFS): superblock at +8192, fs_magic at +1372 within it
ufs = struct.unpack('>I', head[8192 + 1372:8192 + 1376])[0]
print('UFS magic @+8192+1372: %08x (011954 = UFS)' % ufs)
# SysV: superblock at +512, s_magic near the end (0xfd187e20)
for off in range(512, 1024, 4):
    if struct.unpack('>I', head[off:off + 4])[0] == 0xfd187e20:
        print('SVFS magic at +%d' % off)
print(head[512:640].hex())
print(head[8192:8320].hex())
