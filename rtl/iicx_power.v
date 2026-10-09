// iicx_power.v - the IIcx's soft power, as MiSTer can have it (SE30_PLAN.md
// 14.2 item 9, the Guide's chapter 6).
//
// Shut Down drives /POWEROFF (VIA2 PB2) low and the supply goes off 2 ms
// later.  Off: `off` holds the machine and darkens the screen until the
// keyboard's Power key or the OSD's reset (the IIcx's /POWERON).  With the
// rear switch locked on (`locked`, the OSD's "Power switch"), the supply
// comes straight back - the IIcx restarts: `restart` is one clock, which
// the top folds into its reset.  The clock chip and its PRAM run on, as the
// battery keeps them.

`timescale 1ns/1ps

module iicx_power #(
  parameter DELAY = 62669              // 2 ms of clk_sys (31.3344 MHz)
) (
  input      clk,
  input      running,                  // the machine out of reset
  input      poweroff_req,             // VIA2 PB2 driven low
  input      locked,                   // the rear switch locked on
  input      power_key,                // one clock: the Power key pressed
  input      reset_req,                // the OSD's or the button's reset
  output reg off = 0,
  output reg restart = 0
);
  reg [16:0] dly = 0;
  always @(posedge clk) begin
    restart <= 0;
    if (poweroff_req && running && !off) begin
      if (dly == DELAY) begin
        if (locked) restart <= 1; else off <= 1;
        dly <= 0;
      end else dly <= dly + 1'd1;
    end else dly <= 0;
    if (off && (power_key || reset_req)) off <= 0;
  end
endmodule
