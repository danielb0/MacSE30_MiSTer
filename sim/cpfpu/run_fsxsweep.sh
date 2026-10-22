#!/usr/bin/env bash
# Run every PROG=fsx case (the FPU sweep gap's item 1, 2026-10-22: fsw's DATA
# faults over every EA form - (d16,An), (d8,An,Xn), (xxx).W/.L, (d16,PC),
# the full formats and memory indirection, FMOVEM, FSAVE/FRESTORE, the
# control registers, packed - the operand straddling an invalid page, the
# reference run on a resident operand compared) - each in its own copy of
# this directory, 8 at a time, about 20 minutes.  Extra arguments are passed
# as environment: FSX_WP=1 makes the page write-protected (the writes only),
# B3_CACR the cache control register.  Exit status 0 when every case passes.
#   ./run_fsxsweep.sh [FSX_WP=1] [B3_CACR=0x2101]      the log is fsxsweep[_wp].log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
EXTRA="$*"
N=$(env $EXTRA FSXLIST=1 python gen_program.py fsx | wc -l)
[ "$N" -gt 0 ] || { echo "==== fsxsweep: the case list is empty - the generator failed"; exit 1; }
LOG=fsxsweep.log; case " $EXTRA " in *" FSX_WP=1 "*) LOG=fsxsweep_wp.log ;; esac
one() {
  k=$1; d=$HERE/../_fsx_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_cpfpu.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env PROG=fsx FSX=$k $EXTRA timeout 1200 ./run.sh 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA
seq 0 $((N-1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > $LOG
P=$(grep -c '==== PASS' $LOG)
env $EXTRA FSXLIST=1 python gen_program.py fsx | paste -d'|' - <(cut -d' ' -f2- $LOG) | grep -v "==== PASS" | sed 's/|/ : /'
echo "==== fsxsweep${EXTRA:+ ($EXTRA)}: $P / $N PASS"
[ "$P" = "$N" ]
