# Shared by the sweep runners (2026-10-29, Daniel: results must survive a
# restart).  sweep_xargs LOG TEMPLATE [CONFIG]: the case keys come on stdin,
# one a line; each runs as `bash -c TEMPLATE` with {} the key, 8 at a time
# (PAR=n); each case's result line goes to LOG.part the moment the case
# ends, so a restart loses only the cases running then.  RESUME=1: the keys
# whose line is already in LOG.part (a line's first word is its key) are
# skipped - only when LOG.part was written with the same CONFIG (the
# runner's arguments), else it starts afresh.  Last, LOG = LOG.part sorted
# (SORTOPT, default -n).
#   . ../sweep_lib.sh;  seq 0 9 | sweep_xargs fsweep.log 'one {}' "$*"
sweep_xargs() {
  local log=$1 tmpl=$2 cfg="#cfg ${3:-} $(basename "$0")"
  if [ "${RESUME:-0}" = 1 ] && [ "$(head -1 "$log.part" 2>/dev/null)" = "$cfg" ]; then
    echo "sweep_xargs: resuming $log - $(grep -vc '^#cfg' "$log.part") cases already done" >&2
    awk 'NR == FNR { if ($0 !~ /^#cfg/) done[$1] = 1; next } !($1 in done)' "$log.part" -
  else
    echo "$cfg" > "$log.part"; cat
  fi | xargs -d '\n' -P "${PAR:-8}" -I{} bash -c "$tmpl" >> "$log.part"
  grep -v '^#cfg' "$log.part" | sort ${SORTOPT--n} > "$log"
}
