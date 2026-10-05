#!/usr/bin/env bash
# Run tb_se30_mfmread (the MFM read seam) under Icarus Verilog.  See the
# header of tb_se30_mfmread.v for what it proves.  IVERILOG: the iverilog
# bin directory.  Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
R=../../rtl
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_mfmread.vvp tb_se30_mfmread.v \
  $R/se30_swim.v $R/se30_fdhd.v $R/se30_flp_encoder.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_mfmread.vvp | tee run.log
grep -q '^==== PASS' run.log
