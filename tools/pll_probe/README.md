# pll_probe - a PLL placement probe for the IIcx build

A Quartus project holding only the IIcx build's PLLs and the framework's two clock
switches, so the fitter answers a placement question in 20-80 s instead of a 35-minute
core compile. It reproduces the core's periphery errors exactly. Built for KNOWN ISSUES 24
(SE30_PLAN.md: the IIcx HDMI fix, E2), 2026-10-23.

`probe.v` instantiates, with the same primitives as the core:

- `pll` - the main PLL from FPGA_CLK2_50 (clk_sys, clk_mem, clk_sdc, clk_capa, clk_capb)
- `cap_clkctrl` - se30_sdram's read-capture select between two counters of that PLL
- `pll_vid` - the card's dot clock from clk_mem, the arrangement before E2
- `pll_hdmi` + `pll_cfg_hdmi`, `pll_audio` - `sys/`'s, used from `../../sys`
- `hdmi_clk_sw`, `vga_clk_sw` - sys_top's `cyclonev_clkselect` switches

With `VID_FROM_MAIN` (the `pll6*.qsf` fragments) the dot clock is the main PLL's sixth
output instead, as E2 built it.

`pre_e2/` holds the main PLL and `pll_vid` as the tree had them before E2 (from 32c5fa0^);
the probe runs against those, not against today's `rtl/pll`.

## Running

    bash run.sh v2_hdmiY1_cntY5 e6c_dot846ph

Each variant's `probe.qsf` is `base.qsf` + the PLL fragment (`pll5.qsf`, or `pll6a/b/c.qsf`
for the `e6*` variants) + `variants/<v>.qsf`. The summary of the fit - the fitter's
numbered errors, the PLL and counter locations, the clock switches and global buffers - goes
to `results/<v>.txt`; the full map and fit logs go beside it and are not kept. Quartus comes
from `scripts/local.env`'s `QUARTUS_BIN`. Unnumbered errors (an illegal counter frequency)
appear only in the fit log.

## Results (2026-10-23; v2 and e6b rerun from this folder 2026-10-24, identical)

| variant | placement asked | result |
|---|---|---|
| v0_free | nothing pinned | fits |
| v1_hdmiY1, v2_hdmiY1_cntY5 | pll_hdmi at X0_Y1 (v2: output on C5) | fails: another PLL is held to the bottom edge (0,0)-(89,8) and its only other place, X89_Y1, is the main PLL's |
| v3_hdmiY1_vidY15 | pll_hdmi X0_Y1, pll_vid at X0_Y15 | fails: no path from pll_vid to the HDMI switch's global clock driver at X42_Y0 |
| v3_hdmiY1_vidY32/56/74 | pll_hdmi X0_Y1, pll_vid at Y32/56/74 | fails: conflicting region assignments for a global clock driver |
| v4_mainY15 | main PLL to strip X0_Y15 | fails: its output counter cannot route to the capture select's global clock driver (wrong region) |
| v5_hdmiY32_cntY34 | pll_hdmi X0_Y32, output on counter Y34 (C5) | fails: a global clock driver cannot be placed (205 locations tried) |
| v6_hdmiY15 | pll_hdmi at X0_Y15 | fails: no path from pll_hdmi to a global clock driver |
| v6_hdmiY56*, v6_hdmiY74 | pll_hdmi at Y56/Y74 (counters, pll_vid moved) | fails: the reference clock pin cannot reach that PLL |
| e6a_dot940 | dot clock from the main PLL, VCO 940.032 MHz (E1) | fits |
| e6b_dot846 | the same at VCO 846.0288 MHz, old capture phases | fails: an illegal counter frequency (fit log) |
| e6c_dot846ph | VCO 846.0288 MHz, capture phases re-quantised (E2, shipped) | fits; pll_hdmi at X0_Y1, output on C5 |
