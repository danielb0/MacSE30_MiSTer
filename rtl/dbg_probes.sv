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
//          reset released, cap_sel, cap_fail, cap_ok[1:0], 1'b0,
//          bus-error count[15:0]} - the cap_* bits are the SDRAM read-
//          capture training's verdict (plan 3.8 item 18): which capture
//          it chose (0 = A, 1 = B), whether neither was clean, which were
//          ({A, B}); PCAP has the failure counts behind them
//   PACT  the bus-cycle count: is the CPU alive at all?
// and, since Section 4 (plan 4.8):
//   PVIA  {overlay, ramsiz[1:0], vsyncen_n, VIA1 IER[6:0], VIA1 IFR[6:0],
//          VIA2 IER[6:0], VIA2 IFR[6:0]}: did the ROM clear overlay, what
//          size did it set, is the VBL armed and firing
//   PIRQ  {level-2 acknowledges[15:0], level-1 acknowledges[15:0]}: the
//          FC = 7 cycles by A3-A1; 60 a second on level 1 if the VBL works
// and, since plan 3.8 items 18 and 19 (the SDRAM read capture, the peek
// and poke):
//   PCAP  the training's failure counts; PMEM the machine's last read
//   PPEK  the peek/poke: source {go, hold, we, raw, 5'b0, longword
//         address}, probe {operations done[7:0], data[31:0]}
//   PPOK  source only: {27'b0, odd, byte enables, write data}
//   PRAW  source only: the controller's raw experiment schedule word
//   PPKS  the poke's status

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
	input  wire  [3:0] sdram_cap,          // {cap_sel, cap_fail, cap_ok[1:0]} from se30_sdram
	input  wire [31:0] cap_detail,         // PCAP: {the same four, failures through A[13:0], through B[13:0]} of 65,536 reads each
	input  wire [31:0] mem_last,           // PMEM: the data of the machine's last acknowledged memory read
	output wire [31:0] peek_src,           // PPEK's source: {go, hold, we, raw, 5'b0, longword address[22:0]} from the host
	input  wire [39:0] peek_data,          // PPEK: {operations done[7:0], the longword read (or written; a raw READ's words after a raw experiment)}
	input  wire [15:0] peek_stat,          // PPKS: {operations done[7:0], 2'b0, raw_ack, hold, req, state[2:0]}
	output wire [63:0] poke_src,           // PPOK's source: {27'b0, odd, byte enables[3:0], write data[31:0]}
	output wire [63:0] raw_src,            // PRAW's source: the SDRAM controller's raw experiment schedule word
	input  wire        rom_loaded,
	input  wire [31:0] via_state          // se30_machine's dbg_via (plan 4.8)
);

	reg        as_q = 1;
	reg [31:0] pifa_r = 0, plas_r = 0, pact_r = 0;
	reg  [2:0] fc_r = 0;
	reg        rw_r = 1, berr_seen = 0, berr_q = 0;
	reg  [1:0] dsack_r = 2'b11;
	reg [15:0] berr_cnt = 0, irq1_cnt = 0, irq2_cnt = 0;

	always @(posedge clk) if (phi1) begin
		as_q <= cpu_as_n;
		if (!cpu_as_n && as_q) begin                       // a cycle begins
			plas_r <= cpu_addr; fc_r <= cpu_fc; rw_r <= cpu_rw_n;
			pact_r <= pact_r + 1'd1;
			if (cpu_fc == 3'd6) pifa_r <= cpu_addr;
			if (cpu_fc == 3'd7 && cpu_addr[3:1] == 3'd1) irq1_cnt <= irq1_cnt + 1'd1;
			if (cpu_fc == 3'd7 && cpu_addr[3:1] == 3'd2) irq2_cnt <= irq2_cnt + 1'd1;
		end
		if (!cpu_as_n && dsack_n != 2'b11) dsack_r <= dsack_n;
		if (berr) berr_seen <= 1;
		if (berr && !berr_q) berr_cnt <= berr_cnt + 1'd1;   // once per assertion
		berr_q <= berr;
	end

	wire [31:0] psta = {fc_r, rw_r, dsack_r, berr_seen, halted, sdram_ready, rom_loaded, reset_n, sdram_cap, 1'b0, berr_cnt};

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

	altsource_probe #(
		.instance_id ("PVIA"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pvia (.probe(via_state), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIRQ"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pirq (.probe({irq2_cnt, irq1_cnt}), .source(), .source_clk(clk), .source_ena(1'b1));

	// since plan 3.8 item 18: the read-capture training's counts, and what
	// the machine last read from memory
	altsource_probe #(
		.instance_id ("PCAP"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pcap (.probe(cap_detail), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PMEM"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pmem (.probe(mem_last), .source(), .source_clk(clk), .source_ena(1'b1));

	// the JTAG memory peek and poke (MacSE30.sv, plan 3.8 items 18 and
	// 19): the host writes the sources, the top runs the operation, PPEK
	// returns the count and the data together
	altsource_probe #(
		.instance_id ("PPEK"), .probe_width (40), .source_width (32),
		.sld_auto_instance_index ("YES")
	) cp_ppek (.probe(peek_data), .source(peek_src), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PPOK"), .probe_width (1), .source_width (64),
		.sld_auto_instance_index ("YES")
	) cp_ppok (.probe(1'b0), .source(poke_src), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PRAW"), .probe_width (1), .source_width (64),
		.sld_auto_instance_index ("YES")
	) cp_praw (.probe(1'b0), .source(raw_src), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PPKS"), .probe_width (16), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_ppks (.probe(peek_stat), .source(), .source_clk(clk), .source_ena(1'b1));

endmodule
