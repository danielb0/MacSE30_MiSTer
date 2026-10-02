#!/bin/bash
# Generate the 68882 corpus (plan 8.9.8): the FPU presets of the shipped
# cputestgen.ini, each in its own run (a group generated after others can
# come out empty or with their settings: the generator's state carries
# over), cpu=68030 fpu=68882, gzip off, otherwise the ini's defaults.
#
#   generate.sh <build dir> <out dir>
set -e
B=$1; G=$2; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$G"; mkdir -p "$G/data"; cd "$G"
for g in FBASIC FCPX FINT FPACK FILLG; do
  python3 "$HERE/gen_ini.py" "$B/cputest/cputestgen.ini" cputestgen_$g.ini $g
  cp cputestgen_$g.ini cputestgen.ini
  "$B/cputestgen" > gen_$g.log 2>&1
  mv se30_vectors.txt se30_$g.txt
  echo "$g: $(find data/3_$g -name '*.dat' | wc -l) .dat, $(wc -l < se30_$g.txt) records"
done
rm cputestgen.ini
