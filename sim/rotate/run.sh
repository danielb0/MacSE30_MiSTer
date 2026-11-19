#!/usr/bin/env bash
# Run tb_iici_rotate under Icarus Verilog (see the bench's header).
# Usage: bash run.sh [extra -P assignments...]   e.g. -Ptb_iici_rotate.BUSYPCT=90
# Exit status: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
TAG=${TAG:-run}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2012 "$@" -o out/$TAG.vvp tb_iici_rotate.v ../../rtl/iici_rotate.v || exit 1
"$IVERILOG/vvp.exe" -n out/$TAG.vvp | tee $TAG.log
grep -q '^==== PASS' $TAG.log
