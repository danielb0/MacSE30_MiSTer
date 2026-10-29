#!/usr/bin/env bash
# Run every CASESET=xsweep case (KNOWN ISSUES 23's class: an instruction's
# extension words straddling into a non-resident page; +UOK fails any user
# beat the program never named) - each in its own copy of this directory,
# 8 at a time, about 3 minutes.  Extra arguments are passed as
# environment, e.g. CACR=0x2101.  Exit status 0 when every case passes.
#   ./run_xsweep.sh [CACR=0x2101]
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(CASESET=xsweep XSWLIST=1 python gen_program.py | wc -l)
one() {
  k=$1; d=$HERE/../_xsw_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env CASESET=xsweep XSW=$k TCMODE=aux HANDLER=aux $EXTRA timeout 600 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL: an exception|FAIL: a user|FAIL: a walk|---- user beats)" | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | sweep_xargs xsweep.log 'one {}' "$*"
P=$(grep -c '==== PASS' xsweep.log)
CASESET=xsweep XSWLIST=1 python gen_program.py | paste -d'|' - <(cut -d' ' -f2- xsweep.log) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== xsweep: $P / $N PASS"
[ "$P" = "$N" ]
