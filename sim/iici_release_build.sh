#!/usr/bin/env bash
# Compile the IIci release tree (C:/Git/MacIIci_release) and check timing at every corner.
# Logs in that tree's output_files/: build_release.log, sta_corners_release.log; progress in sim/iici_build.log here.
set -u
DEV=/c/Git/MacSE30_MiSTer
R=/c/Git/MacIIci_release
QB=/c/intelFPGA_lite/17.0/quartus/bin64
LOG=$DEV/sim/iici_build.log
log() { echo "[$(date '+%m-%d %H:%M')] release: $*" >> "$LOG"; }
cd "$R" || exit 1
mkdir -p output_files
log "start (release tree)"
t0=$(date +%s)
"$QB/quartus_sh" --flow compile MacIIci > output_files/build_release.log 2>&1; rc=$?
log "compile rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -aE 'Logic utilization|Error' output_files/build_release.log | head -3 | tr '\n' ' ' | cut -c1-200)"
[ $rc != 0 ] && { log "done (FAILED)"; exit 1; }
"$QB/quartus_sta" -t $DEV/scripts/sta_corners_iici.tcl MacIIci > output_files/sta_corners_release.log 2>&1
log "sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_release.log | tr '\n' ' ' | cut -c1-300)"
log "done; rbf md5 $(md5sum output_files/MacIIci.rbf | cut -c1-32)"
