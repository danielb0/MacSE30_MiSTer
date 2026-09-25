# The SE/30's six PALs, with their pins named

One `.pins` file per device: pin number = signal name, as wired on Apple
drawing 050-0253-01 (board 820-0260-A, the later revision - see
`SE30_PLAN.md` 1.6 and 2.1). Names come from the MIT KiCad redraw via
`scripts/kicad_nets.py`, checked against full-resolution crops of the scan;
UH7 is from the scan alone (its sheet is KiCad v6, which the extractor does
not parse).

`run.sh` disassembles Bolle's six JEDECs (read-only, CC-BY-NC-SA; not in
this repo) with these names and the GAL polarity bits applied.

Conventions in the output:

- `X := ...` registered output, `X = ...` combinatorial. A leading `/`
  means the pin is active-low: the pin goes LOW when the sum of products is
  true. No `/` means active-high (GAL XOR bit set).
- `= gnd` on a combinatorial pin means its output enable is never true:
  the pin is being used as an input, or is unused.
- Names ending in `*` are active-low nets on the schematic; the `/` on the
  left-hand side is about the PAL's polarity fuse, not the net's name, so
  read them together: `/HSYNC* := t` means the HSYNC* pin is driven low
  (asserted) when `t` is true.
- `Q?int` marks a registered output that is not wired to anything and is
  used only as internal state through feedback.
