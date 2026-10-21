#!/usr/bin/env bash
# Run every CASESET=ssweep case (the third round's scan 1, 2026-10-20: A/UX's
# kernel-side MOVES - copyin/copyout/uclear/sendsig - page-faulting in
# SUPERVISOR mode on a user page, every size, direction and EA, the operand
# straddling the page top; the faulting run compared with a resident one) -
# each in its own copy of this directory, 8 at a time, a few minutes.  Extra
# arguments are passed as environment: SSW_WP=1 makes the page write-protected
# (copy-on-write) instead of invalid, CACR=0x2101 the caches.  Exit status 0
# when every case passes.
# DSW_PTR=b|bc|abc (or bw|aw with SSW_WP=1): the user page behind a pointer-level
# fault (gen_program.py's DSW_PTR); the log is then ssweep_ptr_<v>[_c<CACR>].log.
#   ./run_ssweep.sh [SSW_WP=1] [CACR=0x2101] [DSW_PTR=b]      the log is ssweep[_wp].log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA TCMODE=aux CASESET=ssweep SSWLIST=1 python gen_program.py | wc -l)
[ "$N" -gt 0 ] || { echo "==== ssweep${EXTRA:+ ($EXTRA)}: the case list is empty - the generator failed"; exit 1; }
LOG=ssweep.log; case " $EXTRA " in *" SSW_WP=1 "*) LOG=ssweep_wp.log ;; esac
case " $EXTRA " in *" DSW_PTR="*) v=${EXTRA##*DSW_PTR=}; LOG=ssweep_ptr_${v%% *}; c=$(echo " $EXTRA " | sed -n 's/.* CACR=\([^ ]*\) .*/\1/p'); LOG=$LOG${c:+_c$c}.log ;; esac
one() {
  k=$1; d=$HERE/../_r3w_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env CASESET=ssweep SSW=$k TCMODE=aux HANDLER=aux $EXTRA timeout 900 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL: an exception|FAIL: a user|FAIL: a walk|FAIL: the CPU|FAIL: STOP)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > $LOG
P=$(grep -c '==== PASS' $LOG)
env $EXTRA TCMODE=aux CASESET=ssweep SSWLIST=1 python gen_program.py | paste -d'|' - <(cut -d' ' -f2- $LOG) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== ssweep${EXTRA:+ ($EXTRA)}: $P / $N PASS"
[ "$P" = "$N" ]
