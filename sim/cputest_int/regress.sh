#!/usr/bin/env bash
# The corpus's regression rounds (SE30_PLAN.md 1.18.6): records that once
# failed, kept as a one-batch run (about a minute). regress_chk2.txt: CHK2.W/.L
# with the bound pair at an address = 3 mod 4 (the upper bound was read one
# byte low, 2026-10-07). Exit status 0 when the batch passes.
set -u
cd "$(dirname "$0")"
D=$(pwd)/regress_out
rm -rf "$D"
python ../../tools/cputest/harness_i.py regress_*.txt -o "$D" > /dev/null || exit 1
bash run.sh "$D" 1
