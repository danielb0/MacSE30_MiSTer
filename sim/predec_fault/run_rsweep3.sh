#!/usr/bin/env bash
# The third round's scan 5 (2026-10-20): the random fault-transparency sweep
# (run_rsweep.sh's seeds, the same programs, pages and interrupt periods) off
# the bench's ideal RAM:
#   sdram   the board's memory path - rtl/se30_sdram.v and the chip model
#           (run.sh's SDRAM=1); the refresh phase against the program is the
#           jitter
#   jit     the bench RAM with a random per-access latency, +RAMJIT=6 (0..6
#           extra ticks an access, as refresh and page misses cost on the
#           board), +RAMSEED = the seed
# 8 at a time, in this directory's own scratch copies (_r3s_/_r3j_), the log
# rsweep_<mode>.log; extra arguments are passed as environment (CACR=0x2101).
#   super   scan 1: the program in SUPERVISOR mode (RSW_SUPER=1), its faulting
#           accesses the kernel's MOVES through SFC = DFC = 1 among random
#           kernel work, the interrupt landing at the handler's RTE back to
#           supervisor
#   ptr     class 6 of the bug-class review (2026-10-21): pointer-level
#           faults (RSW_PTR=1) - per seed, A entry 0 and the B entries
#           invalid (the table lazily built from junk) or WP, on top of the
#           seed's pages; ptrsuper the same in supervisor mode (RSW_SUPER=1)
#   ./run_rsweep3.sh sdram|jit|super|ptr|ptrsuper FIRST COUNT [CACR=0x2101]
set -u
. "$(dirname "$0")/../sweep_lib.sh"   # results to disk per case; RESUME=1 (sweep_lib.sh)
cd "$(dirname "$0")"
HERE=$(pwd)
MODE=${1:?sdram, jit, super, ptr or ptrsuper}; FIRST=${2:-0}; COUNT=${3:-16}; shift 3 2>/dev/null
EXTRA="$*"
case $MODE in
  sdram) PFX=_r3s_; RUNENV="SDRAM=1";     PLUS="" ;;
  jit)   PFX=_r3j_; RUNENV="";            PLUS="+RAMJIT=6" ;;
  super) PFX=_r3u_; RUNENV="RSW_SUPER=1"; PLUS="" ;;
  ptr)   PFX=_r6p_; RUNENV="RSW_PTR=1";   PLUS="" ;;
  ptrsuper) PFX=_r6q_; RUNENV="RSW_PTR=1 RSW_SUPER=1"; PLUS="" ;;
  *) echo "mode: sdram, jit, super, ptr or ptrsuper" >&2; exit 2 ;;
esac
one() {
  k=$1; d=$HERE/../${PFX}$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  ie="+IRQEVERY=$((300 + (k * 7919) % 1701))"           # as run_rsweep.sh: a level-1 interrupt every 300-2000 clocks, by seed
  rs=""; [ "$MODE" = jit ] && rs="+RAMSEED=$k"
  r=$(cd "$d" && env CASESET=rsweep RSW=$k TCMODE=aux HANDLER=aux $RUNENV $EXTRA timeout 5400 ./run.sh +UOK +MAXCLK=80000000 $ie $PLUS $rs 2>&1 | grep -E "^(==== |FAIL|---- \+RAMJIT|---- the SDRAM model)" | head -5 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA MODE PFX RUNENV PLUS
LOG=rsweep_$MODE.log
seq $FIRST $((FIRST+COUNT-1)) | sweep_xargs $LOG 'one {}' "$*"
P=$(grep -c '==== PASS' $LOG)
grep -v '==== PASS' $LOG
echo "==== rsweep $MODE: $P / $COUNT PASS (seeds $FIRST-$((FIRST+COUNT-1)))"
[ "$P" = "$COUNT" ]
