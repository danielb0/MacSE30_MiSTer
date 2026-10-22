#!/usr/bin/env bash
# Run PROG=frs seeds (the FPU sweep gap's item 2, 2026-10-22: the FPU's
# rsweep - a random FPU + integer program over every EA form, run twice:
# resident, then with random code/data/pointer/stack pages invalid and
# random IRQs running a context switch; registers, FPU state and the data
# windows compared) - each in its own copy of this directory, 8 at a time;
# the seed is also the IRQ timing's (+IRQSEED).  Extra arguments are passed
# as environment: FRS_WP=1 some data pages write-protected, FRS_AUX=1 A/UX's
# switch (FPCR and FP0-FP7 only; no FPSR-dependent instruction), FRS_DLG=1
# a switch at every suspended dialog, B3_CACR the cache control register.
# Exit status 0 when every seed passes.
#   ./run_frssweep.sh N [FIRST] [env...]       the log is frssweep.log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
N=${1:-50}; FIRST=${2:-0}; shift; [ $# -gt 0 ] && shift
EXTRA="$*"
one() {
  k=$1; d=$HERE/../_frs_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_cpfpu.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env PROG=frs FRS=$k $EXTRA timeout 1500 ./run.sh +IRQSEED=$(printf '%x' $((k * 2654435761 % 4294967296 | 1))) 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq $FIRST $((FIRST + N - 1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > frssweep.log
P=$(grep -c '==== PASS' frssweep.log)
grep -v "==== PASS" frssweep.log
echo "==== frssweep${EXTRA:+ ($EXTRA)}: $P / $N PASS (seeds $FIRST-$((FIRST + N - 1)))"
[ "$P" = "$N" ]
