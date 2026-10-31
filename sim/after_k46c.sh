#!/usr/bin/env bash
# 2026-10-27 (Daniel: "Yes, queue it for after the chain"): waits for
# overnight_k46c.sh to end (48 h at most), then installs _stage14's
# gen_program.py (m_add_wp with the MMU off: the empty slot faults ADD's
# read, the SSW says read) and reruns sweep (a)'s three failing cases:
# m_add_wp abort/rerun/complete, MMU and cache off, the SE/30.
# Log: sim/after_k46c.log.
#   bash sim/after_k46c.sh
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/after_k46c.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "after_k46c: waiting for overnight_k46c"
n=0
until grep -q 'overnight_k46c: done' "$SIM/overnight_k46c.log" 2>/dev/null; do
  n=$((n + 1)); [ $n -gt 576 ] && { log "after_k46c: overnight_k46c not done after 48 h - nothing run"; exit 1; }
  sleep 300
done
cp "$SIM/_stage14/gen_program.py" "$SIM/busfault_irq/gen_program.py"
log "after_k46c: m_add_wp fix installed; rerun start"
cd "$SIM/busfault_irq"
t0=$(date +%s)
./run_sweep.sh SET=all ONLY=m_add_wp CTX=00 > "$SIM/after_k46c_sweep.out" 2>&1
log "m_add_wp mmu0: $(tail -1 sweep_all.log) ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '^====' sweep_all.log | cut -c1-300 >> "$LOG"
cp sweep_all.log sweep_all_k52fix.log
log "after_k46c: done"
