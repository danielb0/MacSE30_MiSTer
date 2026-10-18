#!/usr/bin/env bash
# Run every CASESET=dsweep case (KNOWN ISSUES 29's data side: an instruction's memory operand
# on a non-resident page, faulting run against a resident reference) - each in its own copy of
# this directory, 8 at a time, about 4 minutes.  Extra arguments are passed as
# environment, e.g. CACR=0x2101.  Exit status 0 when every case passes.
#   ./run_dsweep.sh [CACR=0x2101]
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA CASESET=dsweep DSWLIST=1 python gen_program.py | wc -l)
one() {
  k=$1; d=$HERE/../_dsw_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env CASESET=dsweep DSW=$k TCMODE=aux HANDLER=aux $EXTRA timeout 600 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL: an exception|FAIL: a user|FAIL: a walk)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > dsweep.log
P=$(grep -c '==== PASS' dsweep.log)
env $EXTRA CASESET=dsweep DSWLIST=1 python gen_program.py | paste -d'|' - <(cut -d' ' -f2- dsweep.log) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== dsweep: $P / $N PASS"
[ "$P" = "$N" ]
