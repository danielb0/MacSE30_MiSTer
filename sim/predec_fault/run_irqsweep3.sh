#!/usr/bin/env bash
# The third round's scan 1, the interrupt side (2026-10-20): an interrupt at
# every clock around a SUPERVISOR-mode MOVES fault - run_irqsweep.sh's method
# on ssweep cases.  For each case a baseline run gives the clocks of the first
# bus error's vector fetch (V); the resume is a supervisor fetch like the
# handler's own, so the window is V-80..V+600, past the handler's RTE: the
# interrupt pending as the fault is taken, during the stacking, in the handler,
# at its RTE back to SUPERVISOR mode and through the re-run.  Each run must
# PASS, take the interrupt once and make no stray user beat (+UOK).  ~12 s a
# run, 8 at a time: about 9 minutes a case at STEP=2 (the default; STEP=n
# walks every n-th clock).
#   ./run_irqsweep3.sh [STEP=2] [SSW_WP=1]        the log is irqsweep3.log
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
STEP=${STEP:-2}
for a in "$@"; do eval "$a"; done
WP=${SSW_WP:-0}
# the cases: copyout's MOVES.L D4,-(A6) and uclear's MOVES.L A4,-(A6) straddling, copyin's MOVES.L -(A6),D4,
# a word and a byte each way, the indexed form - by name, resolved to numbers below
NAMES=("MOVES.L D4,-(A6) at P-2" "MOVES.L A4,-(A6) at P-2" "MOVES.L -(A6),D4 at P-2" "MOVES.W D4,(A6)+ at P-1"
       "MOVES.W (A6)+,A4 at P-1" "MOVES.B D4,(A6) at P+0" "MOVES.B (A6),D4 at P+0" "MOVES.L D4,-13(A6,D0.W) at P-3")
LIST=$(env SSW_WP=$WP CASESET=ssweep SSWLIST=1 python gen_program.py)
CASES=()
for n in "${NAMES[@]}"; do
  k=$(echo "$LIST" | grep -F " $n" | head -1 | awk '{print $1}')
  [ -n "$k" ] && CASES+=("s$k CASESET=ssweep SSW=$k SSW_WP=$WP") || echo "no case '$n'" >&2
done
run1() {   # name envs [plusarg]: the run's summary line
  d=$HERE/../_r3i_$1_${3#+IRQAT=}
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env $2 TCMODE=aux HANDLER=aux timeout 900 ./run.sh +UOK $3 2>&1 |
      grep -E "^(==== |FAIL|---- the first|---- \+IRQAT)" | head -5 | tr '\n' ' ')
  rm -rf "$d"
  echo "$1 ${3:-base} $r"
}
export -f run1; export HERE
printf '%s\n' "${CASES[@]}" | xargs -P 8 -I{} bash -c 'c="{}"; run1 "${c%% *}" "${c#* }"' > irqsweep3_base.log
for c in "${CASES[@]}"; do
  n=${c%% *}; e=${c#* }
  line=$(grep "^$n base " irqsweep3_base.log)
  V=$(echo "$line" | sed -n 's/.*vector fetch at clock \([0-9-]*\).*/\1/p')
  if [ -z "$V" ] || [ "$V" -lt 0 ]; then echo "$n: no baseline window ($line)" >&2; continue; fi
  for t in $(seq $((V-80)) $STEP $((V+600))); do echo "$n|$e|+IRQAT=$t"; done
done | SORTOPT= sweep_xargs irqsweep3.log 'IFS="|" read -r n e p <<< "{}"; run1 "$n" "$e" "$p"' "$*"
T=$(wc -l < irqsweep3.log); P=$(grep -c '==== PASS' irqsweep3.log)
grep -v '==== PASS' irqsweep3.log | head -40
echo "==== irqsweep3: $P / $T PASS ($(grep -c '==== PASS' irqsweep3_base.log) / ${#CASES[@]} baselines)"
[ "$P" = "$T" ]
