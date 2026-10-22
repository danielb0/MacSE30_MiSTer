#!/usr/bin/env bash
# Run every PROG=fif case (KNOWN ISSUES 38/39, 2026-10-21: the FETCH of an
# FPU instruction's extension words or immediate data page-faulting during
# its dialog, every split point, the FPU idle or busy; the reference run on
# resident code compared) - each in its own copy of this directory, 8 at a
# time, about 10 minutes.  Extra arguments are passed as environment:
# FIF_IRQ=1 adds A/UX's context switch at the suspended dialog, B3_CACR the
# cache control register; FIF_SUPER=1 runs only the supervisor block (the
# PMMU forms, KNOWN ISSUES 40/41) - its cases tagged [deferred: KI n] are
# expected failures, reported but outside the verdict.  Exit status 0 when
# every other case passes.
#   ./run_fifsweep.sh [FIF_IRQ=1] [B3_CACR=0x2101] [FIF_SUPER=1]   the log is fifsweep[_super].log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA FIFLIST=1 python gen_program.py fif | wc -l)
[ "$N" -gt 0 ] || { echo "==== fifsweep: the case list is empty - the generator failed"; exit 1; }
FIRST=0; LOG=fifsweep.log
case " $EXTRA " in *" FIF_SUPER=1 "*) FIRST=$(FIFLIST=1 python gen_program.py fif | wc -l); LOG=fifsweep_super.log ;; esac
one() {
  k=$1; d=$HERE/../_fif_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_cpfpu.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env PROG=fif FIF=$k $EXTRA timeout 1200 ./run.sh 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq $FIRST $((N-1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > $LOG
LIST=$(env $EXTRA FIFLIST=1 python gen_program.py fif | sed -n "$((FIRST+1)),\$p" | paste -d'|' - <(cut -d' ' -f2- $LOG))
echo "$LIST" | grep -v "==== PASS" | sed 's/|/ : /'
P=$(echo "$LIST" | grep -v "\[deferred" | grep -c '==== PASS')
T=$(echo "$LIST" | grep -vc "\[deferred")
D=$(echo "$LIST" | grep -c "\[deferred")
DP=$(echo "$LIST" | grep "\[deferred" | grep -c '==== PASS')
echo "==== fifsweep${EXTRA:+ ($EXTRA)}: $P / $T PASS${D:+$( [ "$D" -gt 0 ] && echo " (+ $D deferred, $DP of them passing)")}"
[ "$P" = "$T" ]
