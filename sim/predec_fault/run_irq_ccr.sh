#!/usr/bin/env bash
# KNOWN ISSUES 59 (2026-11-05): the cc-shape CCR case (DSW_CCRSET, the BEQ case DSW=1, copy-on-write,
# the arming external bus error first) with the bench's level-1 interrupt raised at every clock
# of a window around the case's page fault (+IRQAT, scan 4's mechanism): an interrupt pending on
# the fault's edge is dispatched first and the fault then dispatches deferred (make_berr latched),
# the path KNOWN ISSUES 46's CCR restore gates on.  LO..HI the window (clocks), 8 at a time.
#   ./run_irq_ccr.sh LO HI [extra env]      the log is irq_ccr_pb.log
set -u
cd "$(dirname "$0")"; HERE=$(pwd)
LO=$1; HI=$2; shift 2; EXTRA="$*"
LOG=irq_ccr_pb.log; : > $LOG
one() {
  t=$1; d=$HERE/../_irqccr_$t
  rm -rf "$d"; mkdir -p "$d"; cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env PREBERR=1 DSW_CCRSET=1 DSW_WP=1 DSW=${DSWK:-1} CASESET=dsweep TCMODE=aux HANDLER=aux CACR=0x2101 $EXTRA timeout 900 ./run.sh +UOK +IRQAT=$t 2>&1 |
      grep -E "^(==== |FAIL|---- \+IRQAT)" | head -4 | tr '\n' ' ')
  rm -rf "$d"; echo "$t $r"
}
export -f one; export HERE EXTRA
seq $LO $HI | xargs -P 8 -I{} bash -c 'one {}' | sort -n > $LOG
grep -c "==== PASS" $LOG; grep -v "==== PASS" $LOG | head -20
