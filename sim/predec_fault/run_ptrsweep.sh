#!/usr/bin/env bash
# The directed half of class 6 of the bug-class review (2026-10-21, pointer-
# level faults; gen_program.py's DSW_PTR): dsweep and ssweep with the operand
# page behind an invalid B entry (b), an invalid B entry and page (bc), an
# invalid A entry, B entry and page (abc), and - the writes - a write-
# protected B (bw) or A (aw) entry.  Each sweep 8-wide, one after the other;
# the summary is ptrsweep[_c<CACR>].log.  Extra arguments are passed as
# environment (CACR=0x2101).
#   ./run_ptrsweep.sh [CACR=0x2101]
set -u
cd "$(dirname "$0")"
EXTRA="$*"
c=$(echo " $EXTRA " | sed -n 's/.* CACR=\([^ ]*\) .*/\1/p')
LOG=ptrsweep${c:+_c$c}.log
: > $LOG
ok=1
for args in "DSW_PTR=b" "DSW_PTR=bc" "DSW_PTR=abc" "DSW_WP=1 DSW_PTR=bw" "DSW_WP=1 DSW_PTR=aw"; do
  ./run_dsweep.sh $EXTRA $args | tail -1 | tee -a $LOG | grep -q PASS || ok=0
done
for args in "DSW_PTR=b" "DSW_PTR=bc" "DSW_PTR=abc" "SSW_WP=1 DSW_PTR=bw" "SSW_WP=1 DSW_PTR=aw"; do
  ./run_ssweep.sh $EXTRA $args | tail -1 | tee -a $LOG | grep -q PASS || ok=0
done
[ $ok = 1 ] && echo "==== ptrsweep: every sweep PASS" | tee -a $LOG || echo "==== ptrsweep: FAILURES (the per-sweep logs)" | tee -a $LOG
[ $ok = 1 ]
