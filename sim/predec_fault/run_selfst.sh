#!/usr/bin/env bash
# Run CASESET=selfst (KNOWN ISSUES 37's class, 2026-10-22: an address
# register stored through its own auto-modified EA - MOVES, MOVEM, MOVE;
# every size and alignment; resident, invalid, write-protected and across
# $70000; the manual's values checked absolutely) - 16 cases a run, the
# parts 8 at a time, each in its own copy of this directory.  Extra
# arguments are passed as environment: CACR=0x2101 the caches,
# SELFST_SANITY=1 plants a difference in every part (each must FAIL).
#   ./run_selfst.sh [CACR=0x2101] [SELFST_SANITY=1]      the log is selfst.log
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA TCMODE=aux CASESET=selfst SELFSTLIST=1 python gen_program.py | wc -l)
[ "$N" -gt 0 ] || { echo "==== selfst: the case list is empty - the generator failed"; exit 1; }
P=$(( (N + 15) / 16 ))
one() {
  k=$1; d=$HERE/../_sst_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env CASESET=selfst SELFST_PART=$k TCMODE=aux HANDLER=aux $EXTRA timeout 1200 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL)" | head -12 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((P-1)) | sweep_xargs selfst.log 'one {}' "$*"
G=$(grep -c '==== PASS' selfst.log)
cat selfst.log | cut -c1-400
echo "==== selfst${EXTRA:+ ($EXTRA)}: $G / $P parts PASS ($N cases)"
[ "$G" = "$P" ]
