#!/usr/bin/env bash
# 2026-11-05 (Daniel: "Please run the benches and do the fix. Compile both cores ... If it
# turns out that the fix is wrong we'll stop the sweep"): KNOWN ISSUES 59's night.  On the
# committed tree: the release-form builds of both cores (stamp, build_only, sta_corners,
# archive "ki59"), then the trimmed chain - every sweep the fix's diff touches, one at a
# time, each case to disk as it ends (RESUME=1 continues a sweep): the predec_fault sweeps
# with the arming external bus error first (PREBERR=1), busfault_irq (a)-(d) as
# trimmed_k52.sh ran them, then the regression.  Every sweep runs even if one fails.
# Log: sim/night59.log.  Stop it: kill the script, then the simulators by PID
# (lesson-kill-sims-by-pid).
#   bash sim/night59.sh
set -u
cd "$(dirname "$0")/.."
SIM=$(pwd)/sim
LOG=$SIM/night59.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "night59: start on $(git log --oneline -1 | cut -c1-60)"

# 1. the builds
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "builds: tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
log "builds started on $(git rev-parse --short=8 HEAD)"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_ki59.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_ki59.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; continue; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_ki59.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_ki59.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 ki59 -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_ki59.rbf 2>/dev/null | head -1)
  log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
done
log "builds: done"

# 2. the predec_fault sweeps, the latches armed (PREBERR=1), both CACRs
pf() {   # the sweep's arguments; its summary line to the log
  local t0=$(date +%s)
  local r=$(cd "$SIM/predec_fault" && ./run_dsweep_any.sh "$@" 2>&1 | tail -1)
  log "(pf) $*: $r ($(( ($(date +%s) - t0) / 60 )) min)"
}
cat > "$SIM/predec_fault/run_dsweep_any.sh" <<'EOF'
#!/usr/bin/env bash
# night59's helper: ./run_<sweep>.sh with the rest as its arguments
s=$1; shift; exec "./run_$s.sh" "$@"
EOF
chmod +x "$SIM/predec_fault/run_dsweep_any.sh"
for c in 0x2101 0; do
  pf dsweep CACR=$c DSW_CCRSET=1 PREBERR=1
  pf dsweep CACR=$c DSW_CCRSET=1 DSW_WP=1 PREBERR=1
  pf dsweep CACR=$c PREBERR=1
  pf dsweep CACR=$c DSW_WP=1 PREBERR=1
  pf isweep CACR=$c PREBERR=1
  pf xsweep CACR=$c PREBERR=1
  pf ssweep CACR=$c PREBERR=1
  pf ssweep CACR=$c SSW_WP=1 PREBERR=1
  pf selfst CACR=$c PREBERR=1
done
log "predec_fault sweeps: done"

# 3. busfault_irq (a)-(d), as trimmed_k52.sh
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  (cd "$SIM/busfault_irq" && ./run_sweep.sh "$@") > "$SIM/night59_$name.out" 2>&1
  S=$SIM/busfault_irq/$S
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min, $S)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "${S%.log}_ki59$name.log"
}
run a sweep_all.log SET=all CTX="00 11 i11"
run b sweep_all_t1.log TRACE=1 SET=all CTX=11
run c sweep_all_t0.log TRACE=0 SET=all CTX=11
run d sweep_bus.log SET=bus LEVELS=4 CTX=11

# 4. the regression
t0=$(date +%s)
bash "$SIM/run_regression.sh" > "$SIM/night59_regression.out" 2>&1; rc=$?
log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 "$SIM/night59_regression.out")"
[ $rc != 0 ] && grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$SIM/regression.log" | cut -c1-300 | head -8 >> "$LOG"
log "night59: done"
