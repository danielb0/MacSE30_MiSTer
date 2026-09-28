#!/usr/bin/env bash
# Run tb_se30_flp_encoder under Icarus Verilog.  See the header of
# tb_se30_flp_encoder.v for what it proves.  IVERILOG: the iverilog bin
# directory; MACPLUS: the MacPlus core's checkout, for the second opinion
# (rtl/floppy_track_encoder.v).  Exit status is the bench's verdict.
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
MACPLUS=${MACPLUS:-/c/Git/MiSTer-devel/MacPlus_MiSTer}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_flp_encoder.vvp tb_se30_flp_encoder.v \
  ../../rtl/se30_flp_encoder.v "$MACPLUS/rtl/floppy_track_encoder.v" || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_flp_encoder.vvp | tee run.log
grep -q '^==== PASS' run.log
