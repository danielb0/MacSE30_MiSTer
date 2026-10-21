#!/usr/bin/env bash
# 2026-10-21 ~01:00: after KNOWN ISSUES 35's fix (the supervisor random sweep
# died on every seed: a (xxx).L or (d16,An) MOVES after an (An)-form one
# fetched its address word from the base register's VALUE).  Waits for the
# user-mode page-table rerun to write its log, then the quick directed sets on
# the fixed kernel (ssweep, ssweep WP, um x2, sabs), then the supervisor
# random sweep 8-wide alone, then hands over to overnight_r3.sh's regression
# stage (which ends in the two release-form builds).  Log: sim/overnight_r3.log.
#   bash sim/night2.sh [FROM]     FROM: wait (default) | quick | super | regress
set -u
cd "$(dirname "$0")/.."
LOG=$(pwd)/sim/overnight_r3.log                    # absolute: the quick stage cds into sim/predec_fault (its lines were lost the first night)
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
STAGE=${1:-wait}
log "night2 started at stage $STAGE"
if [ "$STAGE" = wait ]; then
  for i in $(seq 1 240); do
    [ -f sim/predec_fault/rsweep.log ] && [ "$(wc -l < sim/predec_fault/rsweep.log)" -ge 50 ] && [ "$(tasklist | grep -ci vsimk.exe)" = 0 ] && break
    sleep 60
  done
  log "page-table rerun (user mode, 50 seeds): $(grep -c '==== PASS' sim/predec_fault/rsweep.log) / $(wc -l < sim/predec_fault/rsweep.log) PASS"
  STAGE=quick
fi
if [ "$STAGE" = quick ]; then
  cd sim/predec_fault
  for s in "./run_ssweep.sh" "./run_ssweep.sh SSW_WP=1"; do
    r=$($s 2>&1 | tail -1); log "quick: $r ($s)"; echo "$r" | grep -q " PASS" || { log "quick FAILED - stop"; exit 1; }
    p=$(echo "$r" | grep -oE "[0-9]+ / [0-9]+" | awk '{print ($1 == $3)}'); [ "$p" = 1 ] || { log "quick FAILED - stop"; exit 1; }
  done
  for c in 0 0x2101; do
    for cs in um sabs; do
      d=../_q_${cs}_$c; rm -rf $d; mkdir -p $d; cp gen_program.py tb_predec_fault.v run.sh $d/
      r=$(cd $d && CASESET=$cs TCMODE=aux HANDLER=aux CACR=$c ./run.sh +UOK 2>&1 | grep -E '^(====|FAIL)' | head -2 | tr '\n' ' '); rm -rf $d
      log "quick: $cs CACR=$c: $r"; echo "$r" | grep -q "==== PASS" || { log "quick FAILED - stop"; exit 1; }
    done
  done
  cd ../..
  STAGE=super
fi
if [ "$STAGE" = super ]; then
  t0=$(date +%s)
  ( cd sim/predec_fault && ./run_rsweep3.sh super 0 100 > super.out 2>&1 ); rc=$?
  log "supervisor sweep rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 sim/predec_fault/super.out)"
  [ $rc = 0 ] || { grep -v '==== PASS' sim/predec_fault/rsweep_super.log | head -5 >> $LOG; log "supervisor sweep FAILED - no regression"; exit 1; }
  STAGE=regress
fi
exec bash sim/overnight_r3.sh regress
