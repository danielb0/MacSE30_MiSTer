#!/usr/bin/env bash
# 2026-10-31 (Daniel: "Trimmed, ~12 h"): class 7's rest, one sweep at a
# time - (1) busfault_irq SET=c7 TRACE=1 CTX="00 11" (138 cases, ~9 h),
# then (2) TRACE=0 on the flow and push shapes only (62 cases, ~3 h).
# Each runs even if the other fails; each sweep's log records every case as
# it ends (RESUME=1 continues it).  Log: sim/class7_queue.log.
#   bash sim/class7_queue.sh
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/class7_queue.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "class7_queue: start on $(git log --oneline -1 | cut -c1-60)"
t0=$(date +%s)
(cd busfault_irq && ./run_sweep.sh SET=c7 TRACE=1 "CTX=00 11") > class7_t1.out 2>&1
S=busfault_irq/sweep_c7_t1.log
log "(1) SET=c7 TRACE=1 CTX=00 11: $(tail -1 $S) ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '==== PASS' $S | grep -v '^====' | cut -c1-300 >> "$LOG"
FLOW=$(cd busfault_irq && TRACE=0 SHAPELIST=1 python gen_program.py | awk '$2 == "o" {print $1}' | tr '\n' ' ')
t0=$(date +%s)
(cd busfault_irq && ./run_sweep.sh SET=c7 TRACE=0 "CTX=00 11" "ONLY=$FLOW w_jsr_wp w_bsr_wp w_jsr_a_wp") > class7_t0.out 2>&1
S=busfault_irq/sweep_c7_t0.log
log "(2) SET=c7 TRACE=0 CTX=00 11, flow and push shapes: $(tail -1 $S) ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '==== PASS' $S | grep -v '^====' | cut -c1-300 >> "$LOG"
log "class7_queue: done"
