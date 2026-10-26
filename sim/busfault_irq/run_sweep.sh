#!/usr/bin/env bash
# KNOWN ISSUES 46's class sweep: an interrupt at every clock around an
# exception that is not a page fault (tb_busfault_irq.v).  For each case a
# reference run (+EVT) gives its events; the interrupt is placed on every
# second clock (the kernel samples IPL on phi1) from 40 before each bus
# error to 60 after, from 20 before each exception to 250 after (the
# stacking and the handler's entry), from 30 before the continuation to 60
# after it (traps: the whole iteration), every 16th clock elsewhere; then
# one run takes them all, one iteration each.  HSYNC* at HPER clocks (64:
# UI6's wait ~150 clocks).  8 cases at a time.
#   ./run_sweep.sh [SET=all|bus|trap|pawn|c13|c12|flow] [ONLY=shape] [MODES="..."] [TRACE=1|0] [LEVELS="2"] [CTX="00 11"] [HPER=64]
#   CTX: MMU and CACHE per context (00 = both off, 11 = the board's 24-bit
#   row with CACR $2101; i11 = 11 on the IIcx, an empty slot the NuChip's
#   timeout - bus shapes only).  The log is sweep_<SET>.log.
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
SET=${SET:-all}; LEVELS=${LEVELS:-2}; CTX=${CTX:-"00 11"}; HPER=${HPER:-64}
for a in "$@"; do printf -v "${a%%=*}" '%s' "${a#*=}"; done   # NAME=value, spaces kept
CASES=()
export TRACE=${TRACE:-}                                       # class 7: 1 (T1) or 0 (T0)
for s in $(SHAPELIST=1 python gen_program.py | awk '{print $1":"$2}'); do
  shape=${s%%:*}; fam=${s##*:}
  [ -n "${ONLY:-}" ] && [ "$shape" != "$ONLY" ] && continue    # ONLY=shape: one shape
  case "$SET" in
    bus)  [ "$fam" = t ] && continue ;;
    trap) [ "$fam" != t ] && continue ;;
    pawn) [ "$shape" != r_movea_l ] && continue ;;
    c13)  case "$shape" in m_cas2|m_cas2a|m_cas_wp|m_tas_wp) ;; *) continue ;; esac ;;   # class 13's new locked shapes
    c12)  [ "${shape:0:2}" != c_ ] && continue ;;                                         # class 12's Nth-access shapes
    flow) [ "$fam" != o ] && continue ;;                                                  # class 7's changes of flow (TRACE)
  esac
  case "$fam" in
    r|w|m) modes="abort rerun complete" ;;
    o)     modes="abort" ;;                                  # class 7's flow shapes: no exception
    *)     modes="abort rerun" ;;
  esac
  [ -n "${MODES:-}" ] && modes=$MODES                          # MODES="complete": those handler modes only
  for m in $modes; do for c in $CTX; do for l in $LEVELS; do
    # class 12's shapes need the MMU (the RAM below slot 9)
    if [ "${shape:0:2}" = c_ ] && [ "${c:0:1}" = 0 ]; then continue; fi
    if [ "${c:0:1}" = i ]; then
      [ "$fam" = t ] || CASES+=("$shape $m ${c:1:1} ${c:2:1} $l 1")
    else
      CASES+=("$shape $m ${c:0:1} ${c:1:1} $l 0")
    fi
  done; done; done
done
if [ "${DRY:-0}" = 1 ]; then echo "${#CASES[@]} cases"; exit 0; fi   # DRY=1: the count only
run1() {   # shape hmode mmu cache level iicx
  d=$HERE/../_bfi_$1_$2_$3$4_$5_$6${TRACE:+_t$TRACE}
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_busfault_irq.v" "$HERE/run.sh" "$d/"
  cd "$d"
  export SHAPE=$1 HMODE=$2 MMU=$3 CACHE=$4 IICX=$6
  PLUSARGS="+EVT +LEVEL=$5 +HPER=$HPER" RTL=$HERE/../../rtl timeout 3600 ./run.sh > evt.out 2>&1
  python - <<'EOF' > offsets.txt
ev = [l.split() for l in open("evt.out") if l.startswith("EVT ")]
berr = [int(e[2]) for e in ev if e[1] == "berr"]
exc = [int(e[2]) for e in ev if e[1] == "exc"]
c = [int(e[2]) for e in ev if e[1] == "c"]
end = (c[0] if c else 3000) + 60
dense = set()
if not berr:
    dense |= set(range(0, end, 2))
for b in berr: dense |= set(range(b - 40, b + 61, 2))
for x in exc:  dense |= set(range(x - 20, x + 251, 2))
for x in c:    dense |= set(range(x - 30, x + 61, 2))
offs = sorted(o for o in dense | set(range(0, end, 16)) if 0 <= o < end)
print("\n".join(map(str, offs)))
EOF
  # runs of 1600 offsets at most: the bench's record table holds 1663 iterations
  n=$(wc -l < offsets.txt); mv offsets.txt all_offsets.txt; split -l 1600 -d all_offsets.txt part_
  r=""
  for f in part_*; do
    cp "$f" offsets.txt
    o=$(PLUSARGS="+OFFS +LEVEL=$5 +HPER=$HPER" NOCOMPILE=1 RTL=$HERE/../../rtl timeout 14400 ./run.sh 2>&1 |
        grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
    case "$o" in "==== PASS"*) ;; *) r="$r[$f] ${o:-FAIL no result (timeout?)} " ;; esac
  done
  [ -z "$r" ] && r="==== PASS: $n iterations, every one as the reference"
  cd "$HERE"; rm -rf "$d"
  echo "$1 $2 mmu$3 cache$4 L$5 $([ "$6" = 1 ] && echo IIcx || echo SE30) ($n offsets): $r"
}
export -f run1; export HERE HPER
LOG=sweep_$SET${TRACE:+_t$TRACE}.log
echo "==== $(date '+%F %T') SET=$SET LEVELS=$LEVELS CTX=$CTX: ${#CASES[@]} cases" > "$LOG"
printf '%s\n' "${CASES[@]}" | xargs -P 8 -I{} bash -c 'run1 {}' >> "$LOG"
echo "==== $(date '+%F %T') SET=$SET CTX=$CTX done: $(grep -c '==== PASS' "$LOG") / ${#CASES[@]} PASS" >> "$LOG"
tail -1 "$LOG"
