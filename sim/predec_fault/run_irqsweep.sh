#!/usr/bin/env bash
# Scan 4 (2026-10-18): an interrupt at every clock around a page fault.  For
# each case below a baseline run gives the clocks of the first bus error's
# vector fetch (V) and of the first user fetch after it (U, the resume); then
# the case runs again with +IRQAT=t (the bench's level-1 interrupt raised at
# clock t) for every t in V-80..V+20 and U-40..U+60 - the interrupt pending
# as the fault is taken, during the frame's stacking, in the handler, at its
# RTE and through the re-run.  Each run must PASS, take the interrupt once
# and make no stray user beat (+UOK).  ~12 s a run, 8 at a time: about
# 5 minutes a case, 2 hours for the list.  STEP=n walks every n-th clock.
#   ./run_irqsweep.sh [STEP=1]        the log is irqsweep.log
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
STEP=${STEP:-1}
for a in "$@"; do eval "$a"; done
CASES=(
  "i178 CASESET=isweep ISW=178" "i181 CASESET=isweep ISW=181" "i183 CASESET=isweep ISW=183"
  "i186 CASESET=isweep ISW=186" "i187 CASESET=isweep ISW=187" "i190 CASESET=isweep ISW=190"
  "i193 CASESET=isweep ISW=193" "i195 CASESET=isweep ISW=195" "i149 CASESET=isweep ISW=149"
  "i177 CASESET=isweep ISW=177" "i0 CASESET=isweep ISW=0"
  "d32 CASESET=dsweep DSW=32" "d41 CASESET=dsweep DSW=41" "d45 CASESET=dsweep DSW=45"
  "d114 CASESET=dsweep DSW=114" "d133 CASESET=dsweep DSW=133" "d154 CASESET=dsweep DSW=154"
  "d178 CASESET=dsweep DSW=178" "d183 CASESET=dsweep DSW=183"
  "x0 CASESET=xsweep XSW=0" "x15 CASESET=xsweep XSW=15" "x17 CASESET=xsweep XSW=17"
  "x54 CASESET=xsweep XSW=54" "x116 CASESET=xsweep XSW=116"
  "r1 CASESET=rts RTSONLY=1" "r3 CASESET=rts RTSONLY=3"
)
run1() {   # name envs [plusarg]: the run's summary line
  d=$HERE/../_irq_$1_${3#+IRQAT=}
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env $2 TCMODE=aux HANDLER=aux timeout 900 ./run.sh +UOK $3 2>&1 |
      grep -E "^(==== |FAIL|---- the first)" | head -5 | tr '\n' ' ')
  rm -rf "$d"
  echo "$1 ${3:-base} $r"
}
export -f run1; export HERE
# the baselines
printf '%s\n' "${CASES[@]}" | xargs -P 8 -I{} bash -c 'c="{}"; run1 "${c%% *}" "${c#* }"' > irqsweep_base.log
# the timed runs
for c in "${CASES[@]}"; do
  n=${c%% *}; e=${c#* }
  line=$(grep "^$n base " irqsweep_base.log)
  V=$(echo "$line" | sed -n 's/.*vector fetch at clock \([0-9-]*\).*/\1/p')
  U=$(echo "$line" | sed -n 's/.*after it at \([0-9-]*\).*/\1/p')
  if [ -z "$V" ] || [ "$V" -lt 0 ]; then echo "$n: no baseline window ($line)" >&2; continue; fi
  for t in $(seq $((V-80)) $STEP $((V+20))) $(seq $((U-40)) $STEP $((U+60))); do echo "$n|$e|+IRQAT=$t"; done
done | SORTOPT= sweep_xargs irqsweep.log 'IFS="|" read -r n e p <<< "{}"; run1 "$n" "$e" "$p"' "$*"
T=$(wc -l < irqsweep.log); P=$(grep -c '==== PASS' irqsweep.log)
grep -v '==== PASS' irqsweep.log | head -40
echo "==== irqsweep: $P / $T PASS ($(grep -c '==== PASS' irqsweep_base.log) / ${#CASES[@]} baselines)"
[ "$P" = "$T" ]
