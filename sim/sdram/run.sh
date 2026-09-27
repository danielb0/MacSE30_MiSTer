#!/usr/bin/env bash
# Run tb_se30_sdram under Icarus Verilog.  See the header of tb_se30_sdram.v
# for what it proves.  IVERILOG: the iverilog bin directory.
#
# Five runs: the full bench at the default pin delays (both captures inside
# the eye, A chosen), then the training alone at three settings that move
# the read-data eye (the bench's header): only B inside, only A, neither.
# Exit status is the verdict: 0 when every run prints "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -o out/tb_se30_sdram.vvp tb_se30_sdram.v sdram_model.v ../../rtl/se30_sdram.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_sdram.vvp | tee run.log
ok=0; grep -q '^==== PASS' run.log || ok=1

# the training alone: CLK_TO_PIN, DQ_TO_REG, the expected verdict {A,B}, the expected choice
for cfg in "1.0 0.0 1 1 only-B" "4.0 3.5 2 0 only-A" "5.0 4.5 0 0 neither"; do
  set -- $cfg
  "$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -o out/tb_train.vvp \
    -P tb_se30_sdram.CLK_TO_PIN=$1 -P tb_se30_sdram.DQ_TO_REG=$2 \
    -P tb_se30_sdram.EXPECT_OK=$3 -P tb_se30_sdram.EXPECT_SEL=$4 -P tb_se30_sdram.TRAIN_ONLY=1 \
    tb_se30_sdram.v sdram_model.v ../../rtl/se30_sdram.v || exit 1
  echo "---- training with the eye moved: $5"
  "$IVERILOG/vvp.exe" -n out/tb_train.vvp | tee -a run.log | grep -E '^(FAIL|====|      ready)'
  grep -q "^==== PASS" <("$IVERILOG/vvp.exe" -n out/tb_train.vvp) || ok=1
done
exit $ok
