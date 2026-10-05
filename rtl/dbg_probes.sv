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
// and, since plan 3.8 item 23:
//   PREG  {D6, D7}, 64 bits, registered here on clk: the ROM's start-up
//         tests leave a failure's code in D6 and their flags in D7 when
//         they drop into the serial test manager (its command loop at
//         $40802EDC sends D6 and D7's low word to the host) - what a Sad
//         Mac would show, before there is video to show it on
// and, since plan 5.8 (the SWIM, rung 1):
//   PSWM  64 bits, registered here on clk: the SWIM's {ISM selected, L7,
//         L6, drive select, MotorOn, PH3-0, IWM mode[4:0], delayed MotorOn,
//         /ENBL1, /ENBL2, SENSE, IWM mode bit 5 (test), switch count[1:0],
//         ISM mode[7:0], ISM
//         setup[7:0], phase directions[3:0], IWM configuration[2:0], 0000}
//         and the internal drive's {motor, direction, eject latch, MFM,
//         disk in, /READY, stepping, settling, spinning up, track[6:0]}:
//         did the ROM's mode-set loop set $17, did the .Sony Open find the
//         SWIM and the SuperDrive, and where the drive is in a seek
// and, since plan 6.6 (the ADB and the clock chip):
//   PADB  64 bits, registered here on clk: the transceiver's {PIC PC[8:0],
//         W[7:0]}, {the ADB line, INT*, SCLK, DIO, ST1, ST0}, who pulls the
//         line {transceiver, keyboard, mouse}, the keyboard's and the
//         mouse's engine states[3:0] each, the last command the keyboard
//         heard[7:0], a count of the line's falling edges[15:0], 6'b0:
//         does the transceiver run its program, does the ADB Manager's
//         initialisation get its transactions
//   PRTC  32 bits: the clock chip's {seconds[7:0], last command[7:0],
//         transactions[7:0], write protect, test register[7:1]}: did
//         InitUtil talk to it, is the second ticking
// and, since plan 5.12.12 item 7 (the internal drive's disk):
//   PFLP  64 bits, registered here on clk: the loader's {disk in, loading,
//         double-sided, 800K, tags, DiskCopy, state[2:0], LBA[6:0]}, the
//         encoder's {track valid, side, state[3:0], slot[3:0], cylinder
//         [5:0]}, the disk port's words moved[15:0] and the bytes the ROM
//         has taken from the SWIM[15:0] (valid data reads): is the image
//         in, is the head's track built, is the ROM reading it
// and, since plan 5.14 (the external drive):
//   PFL2  64 bits, registered here on clk: the external drive's loader
//         and encoder as PFLP's, the drive's 16 bits as PSWM's low word,
//         and the disk-port words its loader and encoder have moved[15:0]
// and, since plan 5.15 (writing):
//   PFWR  64 bits, registered here on clk: the internal drive's decoder
//         {sectors committed[15:0], fields refused[7:0], arcs[7:0]} and
//         SD writer {blocks written[15:0], eject flushes[7:0], retries
//         [3:0], queue depth[3:0]} (all wrapping): did the writes reach
//         the image, and the card
// and, since plan 9.8 (SCSI):
//   PSCS  32 bits, registered here on clk: se30_scsi's dbg {target BSY
//         [1:0], target REQ, bus REQ, ACK, SEL, RST, ATN, MSG, C/D, I/O,
//         chip BSY, DRQ, IRQ, a target's hold-off, GLUE waiting for DRQ},
//         then the disks' io_rd[1:0], io_wr[1:0], sd_ack[1:0] and a count of
//         sectors moved [9:0]
// and, since plan 10.4 item 3 (the Disk figure):
//   PSCT  464 bits, registered here on clk, free-running counters (the
//         reader differences two reads; MacSE30.sv's meter): {clocks[39:0],
//         a target BSY[39:0], a target's hold-off[39:0], GLUE holding the
//         CPU for DRQ[39:0], commands (BSY rises)[23:0], then for HPS reads
//         {requests[23:0], clocks request to sd_ack's fall summed[39:0],
//         clocks sd_ack high[39:0], the longest request[23:0]}, then the
//         same four for writes, then the sectors the write requests carried
//         [23:0] (since compile 39's multi-block writes)}: is the time the
//         HPS round trip, the bus, or the Mac
// and, since plan 10.4 item 4 (the Math figure):
//   PFPU  408 bits, registered here on clk, free-running counters (the
//         reader differences two reads: read_probes.tcl fputime): {clocks
//         [39:0], clocks the CPU spends in bus cycles to the 68882 [39:0],
//         those cycles [31:0], command CIR writes (one a general FPU
//         instruction) [31:0], condition CIR writes (FBcc, FScc, FTRAPcc,
//         FDBcc) [23:0], clocks the 68882 is not idle [39:0], clocks its
//         APU runs [39:0], SANE calls: _FP68K ($A9EB, Pack 4) [23:0] and
//         _Elems68K ($A9EC, Pack 5) [23:0], every A-line trap [31:0], the
//         instruction fetch bus cycles (the I-cache's misses and uncached
//         fetches) [39:0], the I-cache's hits [39:0]}: is Math's time the
//         68882's, SANE's integer code, or cache misses
//   PPRF  the pace's time profile (plan 10.4 item 4): per row of the
//         instruction timing decoder (tools/time030/pace_rows.txt), while
//         enabled, the instructions released [31:0], the C16M clocks they
//         took summed [39:0] (each saturates at 511), their budgets
//         (Equation 11-2 with the wait states) summed [39:0] and their
//         instruction fetches' wait states summed [31:0], in a 256-row
//         block RAM. Source {enable, clear (a toggle), row[7:0]}: clear
//         zeroes the RAM (256 clocks), enable counts; with enable low the
//         probe reads the row selected. Probe {row[7:0], the four
//         counters, clocks enabled[39:0], enabled, clearing}. read_probes
//         .tcl profile start | stop | read
//   PSCT, PFPU and PPRF are measurement probes, their questions answered
//   (plan 10.4 items 3 and 4); they are built only with PERF_PROBES = 1
//   (MacSE30.sv's SE30_PERF_PROBES), to leave their logic to the features
//   still to build.  Without them the reader says the bitstream has none.
// and, since plan 11.3 (the ASC):
//   PASC  32 bits, registered here on clk: se30_asc's dbg {mode[1:0], $804
//         [3:0], FIFO A's count [10:0], FIFO B's count [10:0], interrupts
//         raised [3:0] (wrapping)}
// and, since plan 10.5 (the SCC):
//   PSCC  32 bits, registered here on clk: se30_scc's dbg {accesses[11:0]
//         (wrapping), the register pointer, /INT, MIE, the six visible IPs
//         {Rx A, Tx A, Ext A, Rx B, Tx B, Ext B}, RR0B}
// and, since plan 1.16.3 (the 68030's caches):
//   PCCH  64 bits, registered here on clk: {CDIS*, 0, CACR[13:0]} and the
//         hits the instruction cache [47:24] and the data cache [23:0] have
//         answered (each wraps at 2^24): is a cache on, is it hitting
// and, since plan 5.12.12 item 8 (the first boot's stop at "Welcome to
// Macintosh"), the CPU's exceptions, one pulse each from the kernel:
//   PEXC  160 bits: counts of {every exception[15:0], A-line traps[15:0],
//         interrupts (vectors 24-31)[15:0], F-line[15:0], address errors
//         [7:0], illegal instructions[7:0], bus errors[7:0], the rest
//         [7:0]} (the 8-bit ones saturate), then the last 8 vectors that
//         were neither interrupts nor A-line traps, newest in [7:0]: what
//         went wrong
//   PTRP  256 bits: the last 16 A-line trap words, newest in [15:0]: which
//         Toolbox and OS calls the machine is making
//   PFLN  192 bits: the last 4 F-line exceptions, {opcode[15:0], its
//         address[31:0]} each, newest in [47:0]: which FPU instructions the
//         software issues with no 68882 to answer them (plan 5.12.12 item 8)

module dbg_probes #(
	parameter PERF_PROBES = 0             // PSCT, PFPU, PPRF: MacSE30.sv's SE30_PERF_PROBES (plan 10.4)
) (
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
	output wire [63:0] poke_src,           // PPOK's source: {26'b0, DQM force, odd, byte enables[3:0], write data[31:0]}
	output wire [63:0] raw_src,            // PRAW's source: the SDRAM controller's raw experiment schedule word
	input  wire        rom_loaded,
	input  wire [31:0] via_state,         // se30_machine's dbg_via (plan 4.8)
	input  wire [63:0] cpu_regs,          // PREG: {D6, D7} from the kernel's register file (plan 3.8 item 23)
	input  wire [63:0] swim_state,        // PSWM: se30_machine's dbg_swim (plan 5.8)
	input  wire [63:0] adb_state,         // PADB: se30_machine's dbg_adb (plan 6.6)
	input  wire [31:0] rtc_state,         // PRTC: se30_machine's dbg_rtc (plan 6.6)
	input  wire [63:0] flp_state,         // PFLP: the floppy's (plan 5.12.12 item 7)
	input  wire [63:0] flp2_state,        // PFL2: the external drive's (plan 5.14)
	input  wire [63:0] fwr_state,         // PFWR: the internal drive's writing (plan 5.15)
	input  wire [56:0] exc_state,         // PEXC, PTRP, PFLN: {an exception taken, its vector, the opcode, its PC} (item 8)
	input  wire [55:0] berr_state,        // PBER: the PMMU's last fault (tg68k.v's dbg_mmuf)
	input  wire [63:0] cache_state,       // PCCH: the 68030's caches (plan 1.16.3)
	input  wire [31:0] scsi_state,        // PSCS: the SCSI bus and the disks' slots (plan 9.8)
	input  wire [463:0] scsi_meter,       // PSCT: the SCSI disk's time (plan 10.4 item 3)
	input  wire [31:0] scc_state,         // PSCC: the SCC (plan 10.5)
	input  wire [31:0] asc_state,         // PASC: the ASC (plan 11.3)
	input  wire  [1:0] fpu_state,         // PFPU: {the 68882 not idle, its APU running} (plan 10.4 item 4)
	input  wire [35:0] pace_ev            // PPRF: {release, decoder row[7:0], clocks[8:0], budget[9:0], fetch wait states[7:0]} (plan 10.4 item 4)
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

	// the test manager's registers (the header's PREG): one register stage
	// off the kernel's register file
	reg [63:0] preg_r = 0;
	always @(posedge clk) preg_r <= cpu_regs;

	altsource_probe #(
		.instance_id ("PREG"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_preg (.probe(preg_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the SWIM and its drive (the header's PSWM): one register stage
	reg [63:0] pswm_r = 0;
	always @(posedge clk) pswm_r <= swim_state;

	altsource_probe #(
		.instance_id ("PSWM"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pswm (.probe(pswm_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the ADB and the clock chip (the header's PADB, PRTC)
	reg [63:0] padb_r = 0;
	reg [31:0] prtc_r = 0;
	always @(posedge clk) begin padb_r <= adb_state; prtc_r <= rtc_state; end

	altsource_probe #(
		.instance_id ("PADB"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_padb (.probe(padb_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PRTC"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_prtc (.probe(prtc_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the CPU's exceptions (the header's PEXC, PTRP): one pulse per
	// exception from the kernel, with its vector number and the opcode
	wire        exc_take = exc_state[56];
	wire  [7:0] exc_vec  = exc_state[55:48];
	wire [15:0] exc_opc  = exc_state[47:32];
	wire [31:0] exc_pc   = exc_state[31:0];
	wire       exc_irq  = (exc_vec >= 8'd24) && (exc_vec <= 8'd31);   // spurious and the autovectors
	reg [15:0] n_exc = 0, n_aline = 0, n_irq = 0, n_fline = 0;
	reg  [7:0] n_addr = 0, n_ill = 0, n_berr = 0, n_other = 0;
	reg [63:0] exc_ring = 0;                  // the last 8 vectors, not interrupts or A-line, newest [7:0]
	reg [255:0] trp_ring = 0;                 // the last 16 A-line trap words, newest [15:0]
	reg [191:0] fln_ring = 0;                 // the last 4 F-line exceptions {opcode, PC}, newest [47:0]
	always @(posedge clk) if (exc_take) begin
		n_exc <= n_exc + 1'd1;
		if (exc_vec == 8'd10) begin
			n_aline  <= n_aline + 1'd1;
			trp_ring <= {trp_ring[239:0], exc_opc};
		end else if (exc_irq) n_irq <= n_irq + 1'd1;
		else begin
			exc_ring <= {exc_ring[55:0], exc_vec};
			case (exc_vec)
				8'd11:   begin n_fline <= n_fline + 1'd1; fln_ring <= {fln_ring[143:0], exc_opc, exc_pc}; end
				8'd3:    if (n_addr  != 8'hFF) n_addr  <= n_addr  + 1'd1;
				8'd4:    if (n_ill   != 8'hFF) n_ill   <= n_ill   + 1'd1;
				8'd2:    if (n_berr  != 8'hFF) n_berr  <= n_berr  + 1'd1;
				default: if (n_other != 8'hFF) n_other <= n_other + 1'd1;
			endcase
		end
	end

	altsource_probe #(
		.instance_id ("PEXC"), .probe_width (160), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pexc (.probe({n_exc, n_aline, n_irq, n_fline, n_addr, n_ill, n_berr, n_other, exc_ring}),
	           .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PTRP"), .probe_width (256), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_ptrp (.probe(trp_ring), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PFLN"), .probe_width (192), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pfln (.probe(fln_ring), .source(), .source_clk(clk), .source_ena(1'b1));

	// PBER (KNOWN ISSUES 8, 2026-10-05): the last four bus-error exceptions,
	// newest in [103:0], each {opcode[15:0], PC[31:0], tg68k.v's dbg_mmuf
	// as the exception is taken[55:0]} - the PMMU's fault address, its
	// MMUSR-coded status, FC, read/write, an instruction fetch, and which
	// kind of bus error was pending - then a 16-bit count of them (wraps)
	reg [415:0] ber_ring = 0;
	reg  [15:0] n_ber = 0;
	always @(posedge clk) if (exc_take && exc_vec == 8'd2) begin
		ber_ring <= {ber_ring[311:0], exc_opc, exc_pc, berr_state};
		n_ber    <= n_ber + 1'd1;
	end

	altsource_probe #(
		.instance_id ("PBER"), .probe_width (432), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pber (.probe({n_ber, ber_ring}), .source(), .source_clk(clk), .source_ena(1'b1));

	// the floppy (the header's PFLP)
	reg [63:0] pflp_r = 0;
	always @(posedge clk) pflp_r <= flp_state;

	altsource_probe #(
		.instance_id ("PFLP"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pflp (.probe(pflp_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// SCSI (the header's PSCS)
	reg [31:0] pscs_r = 0;
	always @(posedge clk) pscs_r <= scsi_state;

	altsource_probe #(
		.instance_id ("PSCS"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pscs (.probe(pscs_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the SCSI disk's time (the header's PSCT): one probe, so one read is
	// one moment's counters
	generate if (PERF_PROBES) begin : g_psct
	reg [463:0] psct_r = 0;
	always @(posedge clk) psct_r <= scsi_meter;

	altsource_probe #(
		.instance_id ("PSCT"), .probe_width (464), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_psct (.probe(psct_r), .source(), .source_clk(clk), .source_ena(1'b1));
	end endgenerate

	// the ASC (the header's PASC)
	reg [31:0] pasc_r = 0;
	always @(posedge clk) pasc_r <= asc_state;

	altsource_probe #(
		.instance_id ("PASC"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pasc (.probe(pasc_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the SCC (the header's PSCC)
	reg [31:0] pscc_r = 0;
	always @(posedge clk) pscc_r <= scc_state;

	altsource_probe #(
		.instance_id ("PSCC"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pscc (.probe(pscc_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the Math figure (the header's PFPU): the CPU's cycles to the 68882
	// (CPU space, A19-A13 = 0010 001, the CIRs at A4-A0), the 68882's busy
	// time, the SANE packages' traps, and the instruction fetches that went
	// to the bus beside the I-cache's hits (PCCH's 24-bit count, accumulated)
	generate if (PERF_PROBES) begin : g_pfpu_pprf
	reg         pf_as_q = 1'b1;
	wire        pf_fpu  = !cpu_as_n && (cpu_fc == 3'd7) && (cpu_addr[19:13] == 7'b0010_001);
	wire        pf_as_f = !cpu_as_n && pf_as_q;                     // AS* asserted this clock
	reg  [39:0] pf_clk = 0, pf_fclk = 0, pf_busy = 0, pf_apu = 0, pf_fetch = 0, pf_ihit = 0;
	reg  [31:0] pf_cir = 0, pf_cmd = 0, pf_aline = 0;
	reg  [23:0] pf_cond = 0, pf_fp68k = 0, pf_elems = 0, pf_ihit_q = 0;
	always @(posedge clk) begin
		pf_as_q <= cpu_as_n;
		pf_clk  <= pf_clk + 1'd1;
		if (pf_fpu) pf_fclk <= pf_fclk + 1'd1;
		if (pf_as_f) begin
			if (pf_fpu) begin
				pf_cir <= pf_cir + 1'd1;
				if (!cpu_rw_n && cpu_addr[4:0] == 5'h0A) pf_cmd  <= pf_cmd + 1'd1;
				if (!cpu_rw_n && cpu_addr[4:0] == 5'h0E) pf_cond <= pf_cond + 1'd1;
			end
			if (cpu_fc == 3'd2 || cpu_fc == 3'd6) pf_fetch <= pf_fetch + 1'd1;
		end
		if (fpu_state[1]) pf_busy <= pf_busy + 1'd1;
		if (fpu_state[0]) pf_apu  <= pf_apu + 1'd1;
		if (exc_take && exc_vec == 8'd10) begin
			pf_aline <= pf_aline + 1'd1;
			if (exc_opc[15:11] == 5'b10101 && exc_opc[9:0] == 10'h1EB) pf_fp68k <= pf_fp68k + 1'd1;
			if (exc_opc[15:11] == 5'b10101 && exc_opc[9:0] == 10'h1EC) pf_elems <= pf_elems + 1'd1;
		end
		pf_ihit_q <= cache_state[47:24];
		pf_ihit   <= pf_ihit + {16'd0, cache_state[47:24] - pf_ihit_q};
	end
	reg [407:0] pfpu_r = 0;
	always @(posedge clk) pfpu_r <= {pf_clk, pf_fclk, pf_cir, pf_cmd, pf_cond, pf_busy, pf_apu,
	                                 pf_fp68k, pf_elems, pf_aline, pf_fetch, pf_ihit};

	altsource_probe #(
		.instance_id ("PFPU"), .probe_width (408), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pfpu (.probe(pfpu_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the pace's time profile (the header's PPRF). A release comes at most
	// every other clk (on phi1): the row is read on the release's edge and
	// written back, the event added, on the next - so the following
	// release's read sees it.
	wire  [9:0] pr_src;
	reg   [2:0] pr_en_s = 0;                    // enable, synchronised
	reg   [2:0] pr_clr_s = 0;                   // the clear toggle, synchronised (and its last value)
	reg   [7:0] pr_sel = 0, pr_sel_q = 0;       // the row to read, and the row pr_q holds
	reg         pr_clearing = 0;
	reg   [7:0] pr_clr_a = 0;
	reg  [39:0] pr_clk = 0;                     // clocks counted while enabled
	reg [143:0] pr_ram [0:255];
	reg [143:0] pr_q;
	reg         pr_v = 0;                       // a release's row in pr_q: add it back
	reg   [7:0] pr_row = 0;
	reg   [8:0] pr_cnt = 0;
	reg   [9:0] pr_bud = 0;
	reg   [7:0] pr_fc = 0;
	wire        pr_en  = pr_en_s[1] && !pr_clearing;
	wire        pr_ev  = pace_ev[35] && pr_en;
	wire  [7:0] pr_ra  = pr_en ? pace_ev[34:27] : pr_sel;
	wire [143:0] pr_sum = {pr_q[143:112] + 32'd1,
	                       pr_q[111:72] + {31'd0, pr_cnt},
	                       pr_q[71:32]  + {30'd0, pr_bud},
	                       pr_q[31:0]   + {24'd0, pr_fc}};
	always @(posedge clk) pr_q <= pr_ram[pr_ra];
	always @(posedge clk) begin
		if (pr_clearing) pr_ram[pr_clr_a] <= 144'd0;
		else if (pr_v)   pr_ram[pr_row] <= pr_sum;
	end
	always @(posedge clk) begin
		pr_en_s  <= {pr_en_s[1:0], pr_src[9]};
		pr_clr_s <= {pr_clr_s[1:0], pr_src[8]};
		pr_sel   <= pr_src[7:0];
		pr_sel_q <= pr_sel;
		pr_v     <= pr_ev;
		if (pr_ev) begin
			pr_row <= pace_ev[34:27]; pr_cnt <= pace_ev[26:18]; pr_bud <= pace_ev[17:8]; pr_fc <= pace_ev[7:0];
		end
		if (pr_en) pr_clk <= pr_clk + 1'd1;
		if (pr_clr_s[2] != pr_clr_s[1]) begin pr_clearing <= 1'b1; pr_clr_a <= 8'd0; pr_clk <= 40'd0; end
		else if (pr_clearing) begin
			pr_clr_a <= pr_clr_a + 1'd1;
			if (pr_clr_a == 8'hFF) pr_clearing <= 1'b0;
		end
	end
	reg [193:0] pprf_r = 0;
	always @(posedge clk) pprf_r <= {pr_sel_q, pr_q, pr_clk, pr_en_s[1], pr_clearing};

	altsource_probe #(
		.instance_id ("PPRF"), .probe_width (194), .source_width (10),
		.sld_auto_instance_index ("YES")
	) cp_pprf (.probe(pprf_r), .source(pr_src), .source_clk(clk), .source_ena(1'b1));
	end endgenerate

	// the caches (the header's PCCH)
	reg [63:0] pcch_r = 0;
	always @(posedge clk) pcch_r <= cache_state;

	altsource_probe #(
		.instance_id ("PCCH"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pcch (.probe(pcch_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the internal drive's writing (the header's PFWR)
	reg [63:0] pfwr_r = 0;
	always @(posedge clk) pfwr_r <= fwr_state;

	altsource_probe #(
		.instance_id ("PFWR"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pfwr (.probe(pfwr_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// the external drive (the header's PFL2)
	reg [63:0] pfl2_r = 0;
	always @(posedge clk) pfl2_r <= flp2_state;

	altsource_probe #(
		.instance_id ("PFL2"), .probe_width (64), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pfl2 (.probe(pfl2_r), .source(), .source_clk(clk), .source_ena(1'b1));

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
