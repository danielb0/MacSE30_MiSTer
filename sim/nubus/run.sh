#!/usr/bin/env bash
# Run tb_iicx_nubus under Icarus Verilog.  See the header of tb_iicx_nubus.v
# for what it proves.  IVERILOG: the iverilog bin directory; CARD_ROM: the
# Macintosh II Video Card's declaration ROM (342-0008-a.bin, plan 14.2 item 5).
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
CARD_ROM=${CARD_ROM:-"/c/temp/Mac/ROMS/Mac IIcx/342-0008-a.bin"}
mkdir -p out
python -c "import sys; d=open(sys.argv[1],'rb').read(); assert len(d)==4096; open('out/card.hex','w').write(''.join('%02x\n' % b for b in d))" "$CARD_ROM" || exit 1
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -o out/tb_iicx_nubus.vvp tb_iicx_nubus.v \
  ../../rtl/se30_glue.v ../../rtl/iicx_nuchip.v ../../rtl/nubus_tfb.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_iicx_nubus.vvp | tee run.log
grep -q '^==== PASS' run.log
