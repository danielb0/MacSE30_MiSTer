#!/usr/bin/env bash
# 2026-10-20 23:35: round 3's step 8 had the supervisor random sweep and the
# page-table-compared rerun running TOGETHER, 16 sims on 8 cores - about
# seven times slower a seed than 8-wide (memory-bound sims, hyperthread
# pairs), so the rerun was killed.  This waits for the supervisor sweep to
# write its log, runs the user-mode rerun 8-wide alone (50 seeds: the
# sdram, jit and supervisor runs already compared the page-table window on
# 200 seeds), then hands over to the overnight script's regression stage.
#   bash sim/after_super.sh          the log is sim/overnight_r3.log
set -u
cd "$(dirname "$0")/.."
LOG=sim/overnight_r3.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
log "after_super: waiting for the supervisor sweep's log"
for i in $(seq 1 300); do
  [ -f sim/predec_fault_r3/rsweep_super.log ] && [ "$(tasklist | grep -ci vsimk.exe)" = 0 ] && break
  sleep 60
done
[ -f sim/predec_fault_r3/rsweep_super.log ] || { log "after_super: no supervisor log after 5 h"; exit 1; }
log "supervisor sweep: $(grep -c '==== PASS' sim/predec_fault_r3/rsweep_super.log) / $(wc -l < sim/predec_fault_r3/rsweep_super.log) PASS"
t0=$(date +%s)
( cd sim/predec_fault && ./run_rsweep.sh 0 50 > rsweep_um.out 2>&1 ); rc=$?
log "page-table rerun (user mode, 50 seeds) rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 sim/predec_fault/rsweep_um.out)"
[ $rc = 0 ] || { grep -v '==== PASS' sim/predec_fault/rsweep.log | head -5 >> $LOG; log "page-table rerun FAILED - no regression"; exit 1; }
exec bash sim/overnight_r3.sh regress
