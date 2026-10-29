#!/usr/bin/env bash
# Run every CASESET=dsweep case (KNOWN ISSUES 29's data side: an instruction's memory operand
# on a non-resident page, faulting run against a resident reference) - each in its own copy of
# this directory, 8 at a time, about 4 minutes.  Extra arguments are passed as
# environment, e.g. CACR=0x2101.  Exit status 0 when every case passes.
# DSW_PTR=b|bc|abc (or bw|aw with DSW_WP=1): the operand page behind a pointer-level
# fault (gen_program.py's DSW_PTR); the log is then dsweep_ptr_<v>[_c<CACR>].log.
#   ./run_dsweep.sh [CACR=0x2101] [DSW_WP=1] [DSW_PTR=b]
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA TCMODE=aux CASESET=dsweep DSWLIST=1 python gen_program.py | wc -l)
[ "$N" -gt 0 ] || { echo "==== dsweep${EXTRA:+ ($EXTRA)}: the case list is empty - the generator failed"; exit 1; }
LOG=dsweep.log
case " $EXTRA " in *" DSW_PTR="*) v=${EXTRA##*DSW_PTR=}; LOG=dsweep_ptr_${v%% *}; c=$(echo " $EXTRA " | sed -n 's/.* CACR=\([^ ]*\) .*/\1/p'); LOG=$LOG${c:+_c$c}.log ;; esac
one() {
  k=$1; d=$HERE/../_dsw_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env CASESET=dsweep DSW=$k TCMODE=aux HANDLER=aux $EXTRA timeout 600 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL: an exception|FAIL: a user|FAIL: a walk)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | sweep_xargs $LOG 'one {}' "$*"
P=$(grep -c '==== PASS' $LOG)
env $EXTRA TCMODE=aux CASESET=dsweep DSWLIST=1 python gen_program.py | paste -d'|' - <(cut -d' ' -f2- $LOG) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== dsweep${EXTRA:+ ($EXTRA)}: $P / $N PASS"
[ "$P" = "$N" ]
