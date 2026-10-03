#!/usr/bin/env bash
# Run tb_scsi_seam under Icarus Verilog - the 53C80 and the MacPlus targets
# at the bus, driven by the ROM's sequences (SE30_PLAN.md 9.6 item 2).
# Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
R=../../rtl
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb.vvp tb_scsi_seam.v $R/se30_scsi.v $R/se30_ncr53c80.v $R/scsi.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
