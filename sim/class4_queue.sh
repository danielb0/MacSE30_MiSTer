#!/usr/bin/env bash
# 2026-10-28 (Daniel: "yes please"): the rest of class 4, one sweep at a
# time - (1) busfault_irq SET=bus LEVELS=1 CTX=11 (160 cases, ~5 h; level 4
# ran in trimmed sweep (d)), then (2) class 4b, cpfpu run_fswisweep.sh
# (236 FPU fault cases, an interrupt every 2nd clock around each, ~40 h).
# Each runs even if the other fails.  Log: sim/class4_queue.log.
#   bash sim/class4_queue.sh
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/class4_queue.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "class4_queue: start on $(git log --oneline -1 | cut -c1-60)"
t0=$(date +%s)
(cd busfault_irq && ./run_sweep.sh SET=bus LEVELS=1 CTX=11) > class4_l1.out 2>&1
S=busfault_irq/sweep_bus.log
log "(1) SET=bus LEVELS=1 CTX=11: $(tail -1 $S) ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '==== PASS' $S | grep -v '^====' | cut -c1-300 >> "$LOG"
cp $S busfault_irq/sweep_bus_l1.log
t0=$(date +%s)
(cd cpfpu && ./run_fswisweep.sh) > class4b.out 2>&1
log "(2) class 4b: $(tail -1 class4b.out) ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '==== PASS' cpfpu/fswisweep.log | cut -c1-300 >> "$LOG"
log "class4_queue: done"
