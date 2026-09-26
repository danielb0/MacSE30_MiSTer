#!/usr/bin/env bash
# Run tb_se30_video under Icarus Verilog.  See the header of
# tb_se30_video.v for what it proves.
#
#   IVERILOG  the iverilog bin directory (default: C:\iverilog\bin)
#   DECLROM   the 8KB video declaration ROM image, Apple 341-0650, MAME's
#             se30vrom.uk6 (default: the ROMS folder).  Converted to
#             declrom.hex here for $readmemh; neither file is in the repo.
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

IVERILOG=${IVERILOG:-/c/iverilog/bin}
DECLROM=${DECLROM:-/c/temp/Mac/ROMS/MacSE30/se30vrom.uk6}

python -c "import sys; d=open(sys.argv[1],'rb').read(); assert len(d)==8192, len(d); open('declrom.hex','w').write(''.join('%02x\n' % b for b in d))" "$DECLROM" || exit 1
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_video.vvp tb_se30_video.v ../../rtl/se30_video.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_video.vvp | tee run.log
grep -q '^==== PASS' run.log
