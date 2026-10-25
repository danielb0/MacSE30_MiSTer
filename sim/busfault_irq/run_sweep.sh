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
#   ./run_sweep.sh [SET=all|bus|trap|pawn] [LEVELS="2"] [CTX="00 11"] [HPER=64]
#   CTX: MMU and CACHE per context (00 = both off, 11 = the board's 24-bit
#   row with CACR $2101; i11 = 11 on the IIcx, an empty slot the NuChip's
#   timeout - bus shapes only).  The log is sweep_<SET>.log.
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
SET=${SET:-all}; LEVELS=${LEVELS:-2}; CTX=${CTX:-"00 11"}; HPER=${HPER:-64}
for a in "$@"; do eval "$a"; done
CASES=()
for s in $(SHAPELIST=1 python gen_program.py | awk '{print $1":"$2}'); do
  shape=${s%%:*}; fam=${s##*:}
  case "$SET" in
    bus)  [ "$fam" = t ] && continue ;;
    trap) [ "$fam" != t ] && continue ;;
    pawn) [ "$shape" != r_movea_l ] && continue ;;
  esac
  case "$fam" in
    r|w|m) modes="abort rerun complete" ;;
    *)     modes="abort rerun" ;;
  esac
  for m in $modes; do for c in $CTX; do for l in $LEVELS; do
    if [ "${c:0:1}" = i ]; then
      [ "$fam" = t ] || CASES+=("$shape $m ${c:1:1} ${c:2:1} $l 1")
    else
      CASES+=("$shape $m ${c:0:1} ${c:1:1} $l 0")
    fi
  done; done; done
done
run1() {   # shape hmode mmu cache level iicx
  d=$HERE/../_bfi_$1_$2_$3$4_$5_$6
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
  r=$(PLUSARGS="+OFFS +LEVEL=$5 +HPER=$HPER" NOCOMPILE=1 RTL=$HERE/../../rtl timeout 14400 ./run.sh 2>&1 |
      grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  n=$(wc -l < offsets.txt)
  cd "$HERE"; rm -rf "$d"
  echo "$1 $2 mmu$3 cache$4 L$5 $([ "$6" = 1 ] && echo IIcx || echo SE30) ($n offsets): $r"
}
export -f run1; export HERE HPER
LOG=sweep_$SET.log
echo "==== $(date '+%F %T') SET=$SET LEVELS=$LEVELS CTX=$CTX: ${#CASES[@]} cases" > "$LOG"
printf '%s\n' "${CASES[@]}" | xargs -P 8 -I{} bash -c 'run1 {}' >> "$LOG"
echo "==== $(date '+%F %T') done: $(grep -c '==== PASS' "$LOG") PASS, $(grep -c '==== FAIL' "$LOG") FAIL of ${#CASES[@]}" >> "$LOG"
tail -1 "$LOG"
