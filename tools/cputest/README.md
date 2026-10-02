# WinUAE cputest for the 68882 (SE30_PLAN.md 8.9.8, item 7e-4)

WinUAE's `cputest` 6888x tests as a second check beside the model's own
vectors - **a regression against WinUAE's model, not silicon** (plan 8.6.15).

1. `build.sh <WinUAE clone> <build dir>` - WinUAE's generator built with g++
   under WSL; `se30dump.py` patches the build copy to write every stored round
   as a text record.
2. `generate.sh <build dir> <out dir>` - the FPU presets, each in its own run
   (`gen_ini.py` writes each ini).
3. Harness A - the FPU against WinUAE and against itself:
   `convert.py` (records -> vectors and FMOVEM records), `check.py` and
   `check_m.py` (against the reference model), `triage.py` (each difference's
   cause), `accuracy.py` (the transcendentals against mpmath), `remodel.py`
   (the same inputs expected by the model, for `tools/fpu_ucode/vec.py` and,
   through `rtlvec.py`, the RTL bench `sim/fpu` with `+vec=`).
4. Harness B - a sample run as programs on the 68030 kernel and the 68882
   under ModelSim: `harness_b.py` (batches) and `sim/cpfpu/run_cputest.sh`;
   `hb_report.py` names a failing round and field.
