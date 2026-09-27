// iotest.v - a throwaway fitter experiment (SE30_PLAN.md 3.8 item 18).
// Run 1 (two plain input registers on two clocks): the cell took one
// (dq_b, clk_mem) as its Fast Input Register, dq_a went to the fabric.
// Run 2 (cyclonev_ddio_in with use_clkn): Error 15890, "Input port CLKN
// of DDIO_IN has invalid source" - one input clock per cell.
// Run 3: ONE cell register, its clock chosen by a clock control block
// between clk_capa and clk_mem: packs into the cell, STA times both.
// Run 4: the chip's clock on clk_mem's counter (compile 6's arrangement):
// the eye sits about 2 ns later than compile 6's.  Compile 6's own path
// (its database, 2026-09-27) says why: its fitter had put 1.5-2.5 ns of
// input delay chain on the SDRAM_DQ pins (data cell 3.9 ns against 1.4
// here), while the clock paths match this experiment within 0.1 ns.  At
// chain zero this experiment IS the core's timing.
// Run 6: the chip's clock at +1.064 ns (the outputs' setup and hold at
// the chip balanced), capture A at -0.266 (as +10.372) and B at -2.261
// (as +8.377): A inside the eye at both slow corners by >= 1.40 ns, B at
// both fast corners by >= 1.89, outputs 2.4/2.5.  A falling-edge transfer
// straight from the cell failed for A (-1.23): the cell-to-fabric path is
// longer than half a period at the slow corner.
// Run 7 (this file): a full-period register dq_w in the capture domain
// before the falling-edge transfer dq_m, as the core will have it.
// Not part of the core.

module iotest (
  input  wire        CLK_50M,
  inout  wire [15:0] SDRAM_DQ,
  output wire        SDRAM_CLK,
  input  wire        sel_in,
  output reg  [15:0] q_out
);
  wire clk_mem, clk_sdc, clk_capa, clk_capb, locked;

  altera_pll #(
    .fractional_vco_multiplier("true"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(4),
    .output_clock_frequency0("94.003200 MHz"), .phase_shift0("0 ps"),     .duty_cycle0(50),
    .output_clock_frequency1("94.003200 MHz"), .phase_shift1("1064 ps"),  .duty_cycle1(50),
    .output_clock_frequency2("94.003200 MHz"), .phase_shift2("10372 ps"), .duty_cycle2(50),
    .output_clock_frequency3("94.003200 MHz"), .phase_shift3("8377 ps"),  .duty_cycle3(50),
    .pll_type("General"), .pll_subtype("General")
  ) pll (
    .rst(1'b0), .outclk({clk_capb, clk_capa, clk_sdc, clk_mem}), .locked(locked), .fboutclk(), .fbclk(1'b0), .refclk(CLK_50M)
  );

  altddio_out #(
    .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
    .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"), .width(1)
  ) sdclk_ddr (
    .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sdc), .dataout(SDRAM_CLK),
    .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
  );

  reg [15:0] dq_out = 0;
  reg        dq_oe = 0;
  assign SDRAM_DQ = dq_oe ? dq_out : 16'hzzzz;

  // the capture clock: A or B, chosen at run time
  reg  sel = 0;
  wire clk_cap;
  altclkctrl #(
    .clock_type("Global Clock"), .intended_device_family("Cyclone V"),
    .ena_register_mode("falling edge"), .implement_in_les("OFF"),
    .number_of_clocks(4), .use_glitch_free_switch_over_implementation("OFF"),
    .width_clkselect(2), .lpm_type("altclkctrl")
  ) cap_clkctrl (
    .inclk({clk_capb, clk_capa, 2'b00}), .clkselect({1'b1, sel}), .ena(1'b1), .outclk(clk_cap)
  );

  reg [15:0] dq_q, dq_w, dq_m;
  always @(posedge clk_cap) begin dq_q <= SDRAM_DQ; dq_w <= dq_q; end
  always @(negedge clk_mem) dq_m <= dq_w;

  always @(posedge clk_mem) begin
    sel    <= sel_in;
    q_out  <= dq_m;
    dq_out <= dq_out + q_out;
    dq_oe  <= ~dq_oe;
  end
endmodule
