#!/usr/bin/env bash
# Run every PROG=fsw case (scan 3, 2026-10-18: an FPU instruction's memory
# operand page-faulting part way through its dialog, user mode; the
# reference run on resident pages compared) - each in its own copy of this
# directory, 8 at a time, about 10 minutes.  Extra arguments are passed as
# environment: FSW_WP=1 makes the page write-protected (copy-on-write)
# instead of invalid.  Exit status 0 when every case passes.
#   ./run_fsweep.sh [FSW_WP=1]
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA FSWLIST=1 python gen_program.py fsw | wc -l)
one() {
  k=$1; d=$HERE/../_fsw_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_cpfpu.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env PROG=fsw FSW=$k $EXTRA timeout 1200 ./run.sh 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | sweep_xargs fsweep.log 'one {}' "$*"
P=$(grep -c '==== PASS' fsweep.log)
env $EXTRA FSWLIST=1 python gen_program.py fsw | paste -d'|' - <(cut -d' ' -f2- fsweep.log) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== fsweep: $P / $N PASS"
[ "$P" = "$N" ]
