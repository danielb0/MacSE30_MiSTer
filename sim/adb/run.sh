#!/usr/bin/env bash
# Run tb_se30_adb under Icarus Verilog.  See the header of tb_se30_adb.v for
# what it proves.
#
#   IVERILOG  the iverilog bin directory
#   ADBROM    the ADB transceiver's program, Apple 342S0440-B (MAME's
#             342s0440-b.bin, CRC32 cffb33eb; not in the repository)
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
ADBROM=${ADBROM:-/c/temp/Mac/ROMS/MacSE30/342s0440-b.bin}
mkdir -p out
if [ ! -r "$ADBROM" ]; then echo "==== SKIP: no transceiver program at $ADBROM"; exit 1; fi
python - "$ADBROM" <<'PY' || exit 1
import struct, sys, zlib
d = open(sys.argv[1], 'rb').read()
assert len(d) == 1024 and zlib.crc32(d) == 0xcffb33eb, 'not the 342S0440-B program'
open('out/adb.hex', 'w').write(''.join('%03x\n' % w for w in struct.unpack('<512H', d)))
PY
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_adb.vvp tb_se30_adb.v \
  ../../rtl/se30_via.v ../../rtl/se30_pic1654.v ../../rtl/se30_adb_xcvr.v ../../rtl/se30_adb_dev.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_adb.vvp | tee run.log
grep -q '^==== PASS' run.log
