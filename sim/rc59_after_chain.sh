#!/usr/bin/env bash
# rc59_after_chain.sh (2026-11-06, Daniel: "Once the chain is finished, assuming there are
# no errors, please prepare the release and compile both cores"): waits for night59b's
# "done", checks that (a)-(d) and the regression all passed, waits for the simulators to
# end, then compiles both revisions in the release tree (C:\Git\MacSE30_rc), runs
# sta_corners over each and archives the rbf as output_files/<rev>_<hash>_rc.rbf.
# Launched through the Windows Task Scheduler (an app update kills the app's children).
# Log: sim/rc59.log.  Nothing is pushed.
set -u
SIM=/c/Git/MacSE30_MiSTer/sim
CHAIN=$SIM/night59.log
LOG=$SIM/rc59.log
RC=/c/Git/MacSE30_rc
QB=/c/intelFPGA_lite/17.0/quartus/bin64
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "rc59: waiting for night59b's done"

# 1. the chain's end, bounded (60 h from now)
deadline=$(( $(date +%s) + 60 * 3600 ))
until grep -q 'night59b: done' "$CHAIN"; do
  [ $(date +%s) -gt $deadline ] && { log "rc59: STOPPED - no 'night59b: done' within 60 h"; exit 1; }
  sleep 120
done
log "rc59: the chain is done"

# 2. the verdict: every line after the last restart is a full pass
verdict=$(python - "$CHAIN" <<'EOF'
import re, sys
lines = open(sys.argv[1], encoding='latin-1').read().split('\n')
start = max(i for i, l in enumerate(lines) if 'night59b: restart on' in l)
seen, bad = set(), []
for l in lines[start + 1:]:
    if not l.strip(): continue
    m = re.match(r'\[[^]]*\] \(([abcd])\) .*: ==== .* done: (\d+) / (\d+) PASS', l)
    if m and m.group(2) == m.group(3): seen.add(m.group(1)); continue
    m = re.match(r'\[[^]]*\] regression rc=0 .*: ==== regression: (\d+) / (\d+) lines pass', l)
    if m and m.group(1) == m.group(2): seen.add('r'); continue
    if 'night59b: done' in l: continue
    bad.append(l[:200])
if seen == set('abcdr') and not bad: print('PASS')
else: print('FAIL stages=%s other=%s' % (''.join(sorted(seen)), bad[:5]))
EOF
)
log "rc59: verdict $verdict"
case "$verdict" in PASS) ;; *) log "rc59: STOPPED - not every stage passed; no builds"; exit 1;; esac

# 3. no simulator left running (the fitter needs the memory), bounded at 2 h
for i in $(seq 1 60); do
  n=$(tasklist 2>/dev/null | grep -ci vsimk)
  [ "$n" = 0 ] && break
  sleep 120
done
[ "$n" != 0 ] && log "rc59: $n vsimk still running after 2 h; building anyway"

# 4. the builds, in the release tree
cd "$RC" || { log "rc59: no release tree"; exit 1; }
[ -n "$(git status --porcelain | grep -v '^??')" ] && { log "rc59: STOPPED - the release tree has uncommitted changes"; exit 1; }
H=$(git rev-parse --short=7 HEAD)
log "rc59: builds start on release $H ($(git log --oneline -1 | cut -c1-70))"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  "$QB/quartus_sh" --flow compile $rev > output_files/${rev}_rc59_build.log 2>&1; rc=$?
  log "$rev: compile rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -E 'Logic utilization' output_files/$rev.fit.summary 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
  [ $rc != 0 ] && { log "$rev: compile FAILED: $(grep -E '^Error' output_files/${rev}_rc59_build.log | head -3 | tr '\n' ' ' | cut -c1-300)"; continue; }
  "$QB/quartus_sta" -t /c/Git/MacSE30_MiSTer/scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_rc59.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_rc59.log | tr '\n' ' ' | cut -c1-300)"
  cp output_files/$rev.rbf output_files/${rev}_${H}_rc.rbf
  log "$rev: archived output_files/${rev}_${H}_rc.rbf md5 $(md5sum output_files/${rev}_${H}_rc.rbf | cut -c1-8)"
done
git checkout -- MacSE30.qsf MacIIcx.qsf 2>/dev/null
log "rc59: done; release tree status: $(git status --porcelain | grep -v '^??' | tr '\n' ' ')"
