# iotest - the SDRAM read-capture calibration experiment

A Quartus project of the SDRAM data pins alone: the core's PLL phases, the
clock control block, the I/O-cell capture register and the transfer chain
of `rtl/se30_sdram.v`, and nothing else. It fits in about a minute and its
STA reproduces the core's capture timing at chain zero (the clock paths
match the core's within 0.1 ns; SE30_PLAN.md 3.8 item 18 has the
comparison), so a change to the capture phases is tried here first, not in
a twenty-minute compile of the core. Its table is the plan's table.

Not part of the core's build. Run from this directory:

```bash
export PATH=/c/intelFPGA_lite/17.0/quartus/bin64:$PATH
quartus_map iotest && quartus_fit iotest && quartus_sta -t sta.tcl
```

`sta.tcl` prints, per timing corner, the capture register's setup and
hold under capture A and under capture B, the transfer chain's slacks, and
the outputs' setup and hold at the chip. The reading is that at every
corner one capture is inside the eye and the other is not; which one, and
by how much, is the design.

The pin locations are the DE10-Nano's (from `sys/sys.tcl`); the delay
chains are pinned to zero as in the core's qsf; the two capture clocks are
an exclusive clock group as in the core's sdc. The header of `iotest.v`
keeps the log of what each earlier run of this experiment established.
