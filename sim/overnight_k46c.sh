#!/usr/bin/env bash
# 2026-10-26 (Daniel: "Yes, run the IIcx rerun in parallel with the
# regression"): overnight_k46b.sh's r_movem9 complete IIcx case hit the
# runner's 4 h timeout (the SE/30 cases passed); with run_sweep.sh's runs
# now ~2 h each under a 12 h timeout: that case alone beside the full
# regression, then - only if both passed - the k52release builds of both
# cores, then the trimmed sweeps (trimmed_k52.sh's list, ~33 h; they run
# even if a build fails).  Log: sim/overnight_k46c.log.
#   bash sim/overnight_k46c.sh
set -u
cd "$(dirname "$0")/.."
SIM=$(pwd)/sim
LOG=$SIM/overnight_k46c.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "overnight_k46c: start on $(git log --oneline -1 | cut -c1-60)"

# 1. the IIcx case beside the regression
t0=$(date +%s)
cp -n "$SIM/busfault_irq/sweep_all.log" "$SIM/busfault_irq/sweep_all_k46b.log"
(cd "$SIM/busfault_irq" && ./run_sweep.sh SET=all ONLY=r_movem9 MODES=complete CTX=i11) > "$SIM/overnight_k46c_sweep.out" 2>&1 &
SW=$!
bash "$SIM/run_regression.sh" > "$SIM/overnight_k46c_regression.out" 2>&1; rc=$?
log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 "$SIM/overnight_k46c_regression.out")"
[ $rc != 0 ] && grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$SIM/regression.log" | cut -c1-300 | head -8 >> "$LOG"
wait $SW
S=$SIM/busfault_irq/sweep_all.log
log "r_movem9 complete IIcx: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '^====' "$S" | cut -c1-300 >> "$LOG"
cp "$S" "$SIM/busfault_irq/sweep_all_k46c.log"
tail -1 "$S" | grep -qE ': ([0-9]+) / \1 PASS' || { log "overnight_k46c: the IIcx case did not pass - no builds, no sweeps"; exit 1; }
[ $rc != 0 ] && { log "overnight_k46c: the regression did not pass in full - no builds, no sweeps"; exit 1; }

# 3. the release-form builds (a subshell: a failure skips the rest of the builds, not the sweeps)
(
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "builds: tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
log "builds started on $(git rev-parse --short=8 HEAD)"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_k46c.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_k46c.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; exit 1; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_k46c.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_k46c.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 k52release -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_k52release.rbf 2>/dev/null | head -1)
  log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
done
log "overnight_k46c: both release-form builds archived"
)

# 4. the trimmed sweeps (trimmed_k52.sh's list)
log "trimmed sweeps: start"
cd "$SIM/busfault_irq"
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  ./run_sweep.sh "$@" > "$SIM/trimmed_k52_$name.out" 2>&1
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min, $S)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "${S%.log}_k52$name.log"
}
run a sweep_all.log SET=all CTX="00 11 i11"
run b sweep_all_t1.log TRACE=1 SET=all CTX=11
run c sweep_all_t0.log TRACE=0 SET=all CTX=11
run d sweep_bus.log SET=bus LEVELS=4 CTX=11
log "overnight_k46c: done"
