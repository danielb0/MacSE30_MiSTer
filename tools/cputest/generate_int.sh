#!/bin/bash
# Generate and sample the 68030 integer corpus (plan 1.18.6): each preset in
# its own cputestgen run (its state carries over between presets), cpu=68030,
# no FPU, gzip off; the text records stream through a pipe into
# sample_int.py, so the tens of gigabytes never reach the disk.
#
#   generate_int.sh <build dir> <work dir> <out dir> [per]
# e.g. generate_int.sh ~/winuae_se30b ~/cpt_int /mnt/c/temp/Mac/SE30/cputest_int/full 6
set -e
B=$1; W=$2; O=$3; PER=${4:-6}; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$O"
for g in BASIC EXTSRC EXTDST; do
  rm -rf "$W/$g"; mkdir -p "$W/$g/data"; cd "$W/$g"
  python3 "$HERE/gen_ini_int.py" "$B/cputest/cputestgen.ini" cputestgen.ini $g
  mkfifo se30_vectors.txt
  ( "$B/cputestgen" > gen.log 2>&1; echo "generator exit $?" >> gen.log ) &
  python3 "$HERE/sample_int.py" se30_vectors.txt -o "$O/sampled_$g.txt" --per "$PER" > "$O/sample_$g.log" 2> "$O/progress_$g.log"
  wait
  rm -rf data se30_vectors.txt
  echo "$g: $(tail -1 "$O/sample_$g.log")"
done
