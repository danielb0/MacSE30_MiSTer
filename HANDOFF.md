# Handoff (2026-10-31)

**For the next Claude session on this PC:** read this file, then the
memory index, then the newest END OF SESSION block in `SE30_PLAN.md`.

- **Memory index:** the local memory of this PC's Claude Code installation,
  `C:\Users\User\.claude\projects\C--Git-MacSE30-MiSTer\memory\MEMORY.md`.
  It is kept on the machine, not in this public repo.
- **Plan:** search `SE30_PLAN.md` for `END OF SESSION 2026-10-31`.

The work moved to a new Claude account on 2026-10-31. Claude Code keys
its notes by project folder, not by account, so the new account reads the
same local memory. A backup of every memory store, the settings and the
session transcripts is in `C:\temp\Mac\claude_handoff\`.

## Where things are

| What | Where |
|---|---|
| Plan, history, status: the source of truth | `SE30_PLAN.md`. The newest END OF SESSION block is near the end; KNOWN ISSUES, FUTURE BOARD TESTS, FUTURE ADDITIONS and the application table are sections in it. |
| User documentation | `README.md` (dev's full README; the MiSTer-devel README is the lean public one) |
| CPU/MMU/FPU changes for other cores | `TG68K_030_changelog.md` |
| Kernel and machine RTL | `rtl/`; `MacSE30.sv` is the top; `sys/` is the MiSTer framework |
| Benches, sweeps, chain scripts and their logs | `sim/`. Sweep runners source `sim/sweep_lib.sh`: each case's result goes to disk as it ends, and `RESUME=1` continues after a restart. |
| Tools (HFS, timing, probes, builds) | `tools/`, `scripts/` |
| Builds | `output_files/`; release `.rbf`s in `releases/` on `main` |
| Documentation, disk images, MAME, screenshots (outside the repo) | `C:\temp\Mac\` (SE/30 docs in `C:\temp\Mac\SE30\Docs`; MAME in `C:\temp\Mac\mame`) |

## Branches and remotes

- `dev`: all work happens here. It is pushed to `origin`
  (github.com/danielb0/MacSE30_MiSTer, **public**).
- `main`: the public release, pushed to `origin` and to `mister`
  (MiSTer-devel/MacSE30_MiSTer, `master`) only at a release.
- Worktrees: `C:\Git\MacSE30_release` (`main`) and `C:\Git\MacSE30_rc`
  (`release`).

## State at the handoff

- **Released:** 20261024 (A/UX). **Release freeze:** no release until every
  open sweep class is done.
- **Done since the release:**
  - KNOWN ISSUES 46-53, fixed in the kernel on `dev`;
  - the trimmed chain;
  - classes 4 and 4b (160/160 and 236/236).
- **Next**, from the plan's "LEFT before the release freeze lifts":
  - class 2's directed part;
  - class 7's T0 flow with an interrupt at every clock;
  - classes 8 and 9;
  - the rest of classes 10 and 12;
  - then the full chain on the frozen kernel;
  - then release builds.
- **Open on the board:** KNOWN ISSUES 54 (HyperCard under VM, possibly
  intermittent), plus the deferred items in KNOWN ISSUES and FUTURE BOARD
  TESTS.

## Working rules

The working rules for this project live in the local memory files named in
`MEMORY.md`'s "Standing rules" and "Lessons" sections. They are not copied
here. Older general rules live in the MacPlus project's memory store, which
`memory-split-macplus-store.md` names one by one. The ones that matter most
for long runs:

- `lesson-one-sweep-at-a-time.md`
- `lesson-kill-sims-by-pid.md`
- `lesson-never-edit-a-running-script.md`
- `feedback-long-runs-record-and-resume.md`
- `feedback-estimate-tests-consult-over-30min.md`
- `feedback-batch-low-priority-fixes.md` (the release freeze)
