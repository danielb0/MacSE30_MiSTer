// dbg_probes.sv - JTAG In-System Probes for the bring-up (SE30_PLAN.md 3.5).
//
// WHY PROBES: the first hardware question is "did the CPU fetch from ROM,
// run, and stop where the machine bench said it would?"  A live probe holds
// the last latched values and is read while the machine sits there, with
// nothing to trigger in advance - the MacPlus and MacLC practice, and the
// same primitive and reader (quartus_stp -t scripts/read_probes.tcl).
// Reading over JTAG is the one hardware access the standing rules allow.
//
// FPGA-ONLY: instantiated from MacSE30.sv behind USE_DBG_PROBES (set in
// MacSE30.qsf), so altsource_probe never reaches a simulator.
//
// The deck, five 32-bit probes:
//   PBLD  the git SHA of the bitstream: rtl/build_tag.v, stamped from HEAD
//         by scripts/stamp_build_tag.ps1 before every compile and committed
//         as 0, so a capture names its build or says UNSTAMPED (MacPlus's
//         practice: two builds once gave identical captures and nothing
//         said which was on the board).  scripts/archive_build.ps1 names
//         the archived .rbf by the same tag.
//   PIFA  the last instruction-fetch address (FC = 6, AS* falling)
//   PLAS  the last bus-cycle address, any FC
//   PSTA  {FC, R/W*, DSACK*, berr seen, halted, sdram ready, rom loaded,
//          reset released, 5'b0, bus-error count[15:0]}
//   PACT  the bus-cycle count: is the CPU alive at all?

module dbg_probes (
	input  wire        clk,
	input  wire        phi1,
	input  wire        reset_n,
	input  wire [31:0] cpu_addr,
	input  wire  [2:0] cpu_fc,
	input  wire        cpu_as_n,
	input  wire        cpu_rw_n,
	input  wire  [1:0] dsack_n,
	input  wire        berr,
	input  wire        halted,
	input  wire        sdram_ready,
	input  wire        rom_loaded
);

	reg        as_q = 1;
	reg [31:0] pifa_r = 0, plas_r = 0, pact_r = 0;
	reg  [2:0] fc_r = 0;
	reg        rw_r = 1, berr_seen = 0, berr_q = 0;
	reg  [1:0] dsack_r = 2'b11;
	reg [15:0] berr_cnt = 0;

	always @(posedge clk) if (phi1) begin
		as_q <= cpu_as_n;
		if (!cpu_as_n && as_q) begin                       // a cycle begins
			plas_r <= cpu_addr; fc_r <= cpu_fc; rw_r <= cpu_rw_n;
			pact_r <= pact_r + 1'd1;
			if (cpu_fc == 3'd6) pifa_r <= cpu_addr;
		end
		if (!cpu_as_n && dsack_n != 2'b11) dsack_r <= dsack_n;
		if (berr) berr_seen <= 1;
		if (berr && !berr_q) berr_cnt <= berr_cnt + 1'd1;   // once per assertion
		berr_q <= berr;
	end

	wire [31:0] psta = {fc_r, rw_r, dsack_r, berr_seen, halted, sdram_ready, rom_loaded, reset_n, 5'b0, berr_cnt};

	// which bitstream this is (the header's PBLD)
	wire [31:0] build_tag_w;
	build_tag build_tag_inst (.tag(build_tag_w));

	altsource_probe #(
		.instance_id ("PBLD"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pbld (.probe(build_tag_w), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIFA"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pifa (.probe(pifa_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PLAS"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_plas (.probe(plas_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PSTA"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_psta (.probe(psta), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PACT"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pact (.probe(pact_r), .source(), .source_clk(clk), .source_ena(1'b1));

endmodule
