// tb_se30_system.v - the kernel, the wrapper and GLUE together on the
// 68030 bus, running the kernel bench's program out of RAM.
//
// WHAT THIS PROVES
//   Plan 1.13 item 4: rtl/tg68k/tg68k.v presents the kernel (32-bit shape,
//   1.15) as a 68030 on the bus of 2.11.1, and rtl/se30_glue.v answers it.
//   The program is sim/kernel_bus's (gen_program.py): every byte, word and
//   long operand at every offset written and read back into result slots,
//   the bit fields, then STOP.  With the CPU and GLUE simulated together
//   (the seam 1.7 called unmeasured):
//
//     1. the program runs to STOP and every result slot in RAM holds what
//        was written - the whole path, kernel to wrapper to GLUE to RAM
//        and back, moves the right bytes on the right lanes;
//     2. every RAM cycle, fetch or data, is the Guide's one wait state:
//        4 C16M clocks from S0 to S5, a refresh stall excepted;
//     3. cycles run back-to-back: no idle clock between one cycle's S5 and
//        the next's S0 when the kernel has a request waiting;
//     4. the control flow - subroutine, loop, branch, TRAP, and a level-1
//        interrupt raised through GLUE's IPL - lands its results, and the
//        one interrupt acknowledge is a 3-clock cycle terminated by AVEC.
//
//   THE CACHES, THE VIDEO RAM, THE SCSI HANDSHAKE - six runs, run.sh's:
//     plain    the program as above, the cache never enabled;
//     cacheon  the same program with both caches on first (gen_program.py
//              --cache 0x0101): every result and cycle as plain, and hits;
//              its operands - every size at every offset, written then read
//              back - go through the data cache's fills and write hits;
//     cachewa  the same with WA set too (--cache 0x2101): the writes
//              allocate;
//     cachetest  gen_cache_program.py's program (its header): stale code
//              after a data write, CI, CACR's read-back, FI, CEI, EI off;
//              the data cache's stale read, TAS's forced miss, a byte
//              write hit, the alias through MOVES with WA clear and set -
//              each a result slot; the bench changes RAM behind the cache
//              when the program writes $3098 or $309C.  A DBRA loop whose
//              fetch cycles the bench counts with the cache on (none after
//              the first turn) and off (one a turn), and a loop over a
//              cached operand whose data cycles it counts (the first only).
//     vramtest  gen_vram_program.py's loops into the 8-bit video RAM
//              (se30_video, wired as se30_machine wires it): a measurement,
//              each window's clocks and every video cycle's length and the
//              gap before it, against plan 2.12's 5/6/7-clock table
//              (1.16.3: the two GLUE clocks it found).
//     timetest  gen_time_program.py's windows (plan 1.17): loops from the
//              real software - the ROM's chime pass and SCSI blind loops
//              verbatim, DBRA, RAM and video-RAM moves - each timed between
//              marker writes, with its bus cycles counted, for
//              report_time.py to set against the MC68030 UM's Section 11.
//              GLUE's DRQ is held high: a target that never stalls.
//     clrtest   gen_clr_program.py's CLR, Scc and MOVE from SR/CCR to every
//              memory mode (plan 1.17.2): each a write and no read, as the
//              MC68030 UM's tables list them (a 68000 reads first).
//     berrtest  gen_berr_program.py's blind read and write at $50006060 /
//              $50006000 with GLUE's DRQ tied low: each waits for DRQ and
//              UI6 bus-errors it; a handler records the frame's format
//              word and SSW (plan 9.6 item 3: the read must be the long
//              frame, UM 8.2.2; the write's is recorded, the ROM's handler
//              assuming the long one).
//   A hit runs no cycle, so the back-to-back check (3) does not count the
//   clocks the wrapper answers a fetch from the cache.
//
//   Plusargs: +PROG=<dir> (the program.hex/stop_at.txt directory, default
//   ../kernel_bus), +CACHEON (the program enables the cache: it must hit),
//   +CACHETEST (the cache program's checks), +VRAMTEST (the video-RAM
//   measurement), +TIMETEST (the timing windows), +CLRTEST (the write-only
//   instructions), +BERRTEST (the handshake
//   bus errors); +define+VTRACE
//   prints the video trace.
//
// CLOCKING
//   clk is 2 x C16M (31.3344 MHz); phi1/phi2 mark C16M's edges.  GLUE runs
//   on clk with c16_en = phi1.  RAM is a 32-bit model that acknowledges a
//   clock after the request, as the SDRAM slot scheme does (plan 2.13).

`timescale 1ns/1ps

module tb_se30_system;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;
  reg pace_en = 1;                         // +NOPACE: the kernel unpaced (plan 1.17.5)
  reg post_en = 1;                         // +NOPOST: every write waited for (plan 1.17.7)
  reg ptrace = 0;                          // +PTRACE: the pace's signals every clock
  // a watchdog on the pace: the kernel takes no beat for 1000 clocks with the bus idle (plan 1.17.5)
  integer wd_idle = 0;
  always @(posedge clk) if (reset_n) begin
    if (cpu.k_clkena || cpu.s != 3'd0) wd_idle = 0; else wd_idle = wd_idle + 1;   // a cycle in progress (a DRQ wait) is not a stall
    if (wd_idle == 1000) begin
      $display("FAIL: no kernel beat for 1000 clocks - dec%b rel%b cnt%0d bud%0d stall%b bs%b s%0d op%04x pc%08x eff_req%b hit%b park%b ea_on%b ea_h%0d ea_t%0d ea_cc%0d op_h%0d op_t%0d op_cc%0d tail%0d rcr%0d wcr%0d fcr%0d taken%b",
               cpu.k_decode, cpu.p_rel, cpu.p_cnt, cpu.p_budget, cpu.pace_stall, cpu.k_busstate, cpu.s, cpu.k_opcode, cpu.k_opcode_pc, cpu.eff_req, cpu.hit_ack, cpu.park,
               cpu.r_ea_on, cpu.r_ea_h, cpu.r_ea_t, cpu.r_ea_cc, cpu.r_op_h, cpu.r_op_t, cpu.r_op_cc, cpu.p_tail, cpu.p_rcred, cpu.p_wcred, cpu.p_fcred, cpu.r_taken);
      $display("      p_op %04x p_pc %08x", cpu.p_op, cpu.p_pc);
      $finish;
    end
  end
  always @(posedge clk) if (ptrace && reset_n)
    $display("%0t %s dec%b rel%b cnt%0d bud%0d stall%b clkena%b bs%b hit%b s%0d op%04x pc%08x rcr%0d wcr%0d tail%0d fcr%0d",
             $time, phi1 ? "phi1" : "phi2", cpu.k_decode, cpu.p_rel, cpu.p_cnt, cpu.p_budget, cpu.pace_stall, cpu.k_clkena,
             cpu.k_busstate, cpu.hit_ack, cpu.s, cpu.k_opcode, cpu.k_opcode_pc, cpu.p_rcred, cpu.p_wcred, cpu.p_tail, cpu.p_fcred);

  // ------------------------------------------------------------ the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .pace_en(pace_en), .post_en(post_en), .reset_out_n(reset_out_n), .halted(halted));

  // --------------------------------------------------------------- GLUE
  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  reg  [31:0] ram_rdata = 0, rom_rdata = 0;
  reg         ram_ack = 0, rom_ack = 0;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire        vid_sel = slot_sel && (cpu_addr[31:24] == 8'hFE);   // the video card (below)
  wire  [7:0] vid_dout;
  wire        vid_dsack0_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  reg         hsync_n = 1;
  reg         timetest = 0;              // +TIMETEST (read at the start): DRQ held high
  // the device port reads 0, except the SWIM's data register ($1800, rs $C),
  // which reads $FF: a byte always there, for timetest's GCR window (plan 1.17.5)
  wire  [7:0] dev_rdata = (swim_sel && dev_addr[12:9] == 4'hC) ? 8'hFF : 8'h00;
  // VIA1's interrupt, as the program asks: raised by its write to $3080,
  // dropped by the handler's write to $3084
  reg         via1_irq_n = 1;
  always @(posedge clk) if (phi1 && !cpu_as_n && !cpu_rw_n && dsack_n != 2'b11) begin
    if (cpu_addr == 32'h3080) via1_irq_n <= 0;
    if (cpu_addr == 32'h3084) via1_irq_n <= 1;
  end

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(rom_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata), .scsi_drq(timetest),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(vid_sel ? vid_dsack0_n : 1'b1), .slot_rdata(vid_dout),
    .via1_irq_n(via1_irq_n), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  // the video card, wired as se30_machine wires it (slot $E at $FExxxxxx),
  // for the vramtest run; the other programs never reach it
  wire        vid_out, vid_hs, vid_vs, vid_hb, vid_vb, vid_irq6_n;
  se30_video video (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .declrom_we(1'b0), .declrom_waddr(13'd0), .declrom_wdata(8'h00),
    .sel(vid_sel), .as_n(cpu_as_n), .ds_n(cpu_ds_n), .rw(cpu_rw_n), .addr(cpu_addr[16:0]),
    .din(dev_wdata), .dout(vid_dout), .dsack0_n(vid_dsack0_n),
    .page(1'b1), .vsyncen_n(1'b1),
    .vidout(vid_out), .hsync_n(vid_hs), .vsync_n(vid_vs), .hblank(vid_hb), .vblank(vid_vb), .irq6_n(vid_irq6_n));

  // HSYNC* as the video PALs make it (only the UI6 timeout cares)
  integer px = 0;
  always @(posedge clk) if (phi1) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

  // ---------------------------------------------------------- RAM model
  // 64K words of program image as 32K longs, on GLUE's 32-bit port
  reg [15:0] img [0:65535];
  reg [31:0] ram [0:32767];
  integer i;
  always @(posedge clk) if (phi1) begin
    ram_ack <= 0;
    if (ram_req && !ram_ack) begin
      if (ram_we) begin
        if (ram_be[3]) ram[ram_addr[14:0]][31:24] <= ram_wdata[31:24];
        if (ram_be[2]) ram[ram_addr[14:0]][23:16] <= ram_wdata[23:16];
        if (ram_be[1]) ram[ram_addr[14:0]][15:8]  <= ram_wdata[15:8];
        if (ram_be[0]) ram[ram_addr[14:0]][7:0]   <= ram_wdata[7:0];
      end
      ram_rdata <= ram[ram_addr[14:0]];
      ram_ack <= 1;
    end
  end

  integer pass = 0, fails = 0;

  // plan 1.17.7: the wrapper posts writes only to ports that always
  // terminate, so a posted beat must never see BERR
  always @(posedge clk)
    if (phi2 && cpu.post && (cpu.s == 3'd3 || cpu.s == 3'd5) && berr) begin
      fails = fails + 1; $display("FAIL: a posted write's beat bus-errored at %08x", cpu_addr);
    end

  // ------------------------------------------------------ cycle metering
  // a cycle's length in C16M clocks: S0 is the clock before AS* asserts,
  // so it is the phi1 edges seen with AS* low, plus one
  integer as_clocks = 0, cyc_min = 1000, cyc_max = 0, cycles = 0, fetch_cycles = 0, data_cycles = 0;
  integer idle_between = 0, gaps = 0, long_cycles = 0, cpu_space_cycles = 0, hits = 0;
  reg as_q = 1; reg [31:0] first_addr; reg [2:0] first_fc;
  always @(posedge clk) if (phi1) begin
    if (!cpu_as_n) as_clocks = as_clocks + 1;
    if (!cpu_as_n && as_q) begin first_addr = cpu_addr; first_fc = cpu_fc; idle_between = 0; end
    if (cpu_as_n && !as_q) begin
      cycles = cycles + 1;
      if (first_fc == 3'd7) begin                      // CPU space: the acknowledge, terminated by AVEC in 3
        cpu_space_cycles = cpu_space_cycles + 1;
        if (as_clocks + 1 != 3) begin fails = fails + 1; $display("FAIL: a CPU-space cycle of %0d clocks, expected AVEC's 3", as_clocks + 1); end
      end else begin
        if (as_clocks + 1 < cyc_min) cyc_min = as_clocks + 1;
        if (as_clocks + 1 > cyc_max) cyc_max = as_clocks + 1;
        if (as_clocks + 1 > 4) long_cycles = long_cycles + 1;
        if (first_fc == 3'd6) fetch_cycles = fetch_cycles + 1; else data_cycles = data_cycles + 1;
      end
      as_clocks = 0;
    end
    if (cpu_as_n && as_q && cpu.k_req && !cpu.hit_ack && !cpu.f_hit) idle_between = idle_between + 1;
    if (cpu.hit_ack) hits = hits + 1;
    as_q = cpu_as_n;
  end

`ifdef DIAG
  always @(via1_irq_n) $display("t=%0t via1_irq_n=%b ipl_n=%b", $time, via1_irq_n, ipl_n);
  always @(posedge clk) if (phi1 && !cpu_as_n && (cpu_addr == 32'h3080 || cpu_addr == 32'h3084))
    $display("t=%0t bus addr=%08x rw=%b dsack=%b fc=%d", $time, cpu_addr, cpu_rw_n, dsack_n, cpu_fc);
  integer dg = 0;
  always @(posedge clk) if (phi1 && !cpu_as_n && dsack_n != 2'b11 && !via1_irq_n && dg < 40) begin
    dg = dg + 1; $display("t=%0t cycle addr=%08x fc=%d rw=%b siz=%b dout=%08x din=%08x", $time, cpu_addr, cpu_fc, cpu_rw_n, cpu_siz, cpu_dout, cpu_din);
  end
  integer dg2 = 0;
  always @(posedge clk) if (phi1 && !via1_irq_n && dg2 < 60) begin
    dg2 = dg2 + 1; $display("t=%0t busstate=%b s=%0d as=%b clkena=%b hit=%b ipl_nr=%b", $time, cpu.k_busstate, cpu.s, cpu_as_n, cpu.k_clkena, cpu.kernel.fetch_hit, cpu.kernel.IPL_nr);
  end
`endif
  reg cachetest = 0, cacheon = 0, berrtest = 0;   // the run (plusargs, read at the start)

  // ---------------------------------------------------- the loop markers
  // the cache program's writes to $3088/$308C (cache on) and $3090/$3094
  // (off) bracket a DBRA loop: the fetch cycles and clocks between them
  // ($30A0/$30A4: the data loop, its data cycles); and its writes to
  // $3098/$309C ask the bench to change X ($2800) behind the cache
  integer mk_f [0:5], mk_t [0:5], mk_d [0:5]; reg [5:0] mk_seen = 0; integer clocks = 0, mk;
  always @(posedge clk) if (phi1) begin
    clocks = clocks + 1;
    mk = (cpu_addr == 32'h3088) ? 0 : (cpu_addr == 32'h308C) ? 1 : (cpu_addr == 32'h3090) ? 2 : (cpu_addr == 32'h3094) ? 3 :
         (cpu_addr == 32'h30A0) ? 4 : (cpu_addr == 32'h30A4) ? 5 : -1;
    if (!cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && mk >= 0 && !mk_seen[mk]) begin
      mk_seen[mk] = 1; mk_f[mk] = fetch_cycles; mk_t[mk] = clocks; mk_d[mk] = data_cycles;
    end
    if (cachetest && !cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr == 32'h3098) ram[32'h2800 >> 2] = 32'h22222222;
    if (cachetest && !cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr == 32'h309C) ram[32'h2800 >> 2] = 32'h33333333;
  end

  // ------------------------------------------------- the video-RAM meter
  // vramtest: windows between writes to $30B0+8w and $30B4+8w; in each,
  // the clocks, the VRAM cycles, their lengths (S0-S5, C16M clocks) and
  // the gaps before them (clocks from the last cycle's AS* negation)
  reg vramtest = 0;
  integer vw = -1, vw_t0 [0:2], vw_t [0:2], vw_n [0:2], vw_len [0:2], vw_gap [0:2];
  integer vw_h [0:2][0:31], vw_g [0:2][0:15];
  integer vas = 0, vlast_end = 0, vk, vj; reg vas_q = 1; reg vcyc = 0;
  initial for (vk = 0; vk < 3; vk = vk + 1) begin
    vw_t[vk] = 0; vw_n[vk] = 0; vw_len[vk] = 0; vw_gap[vk] = 0;
    for (vj = 0; vj < 32; vj = vj + 1) vw_h[vk][vj] = 0;
    for (vj = 0; vj < 16; vj = vj + 1) vw_g[vk][vj] = 0;
  end
  always @(posedge clk) if (phi1 && vramtest) begin
    if (!cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr[31:4] == 28'h00030B && cpu_addr[1:0] == 0) begin
      vk = (cpu_addr[3:0] == 4'h0) ? 0 : (cpu_addr[3:0] == 4'h8) ? 1 : -1;
      if (cpu_addr == 32'h30B0) begin vw = 0; vw_t0[0] = clocks; end
      if (cpu_addr == 32'h30B4 && vw == 0) begin vw_t[0] = clocks - vw_t0[0]; vw = -1; end
      if (cpu_addr == 32'h30B8) begin vw = 1; vw_t0[1] = clocks; end
      if (cpu_addr == 32'h30BC && vw == 1) begin vw_t[1] = clocks - vw_t0[1]; vw = -1; end
    end
    if (!cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr == 32'h30C0) begin vw = 2; vw_t0[2] = clocks; end
    if (!cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr == 32'h30C4 && vw == 2) begin vw_t[2] = clocks - vw_t0[2]; vw = -1; end
    if (!cpu_as_n && vas_q) begin                                   // a cycle starts
      vcyc = (cpu_addr[31:24] == 8'hFE); vas = 0;
      if (vcyc && vw >= 0) begin
        vj = clocks - vlast_end; vw_gap[vw] = vw_gap[vw] + vj;
        vw_g[vw][(vj > 15) ? 15 : vj] = vw_g[vw][(vj > 15) ? 15 : vj] + 1;
      end
    end
    if (!cpu_as_n) vas = vas + 1;
    if (cpu_as_n && !vas_q) begin                                   // a cycle ends
      if (vcyc && vw >= 0) begin
        vw_n[vw] = vw_n[vw] + 1; vw_len[vw] = vw_len[vw] + vas + 1;
        vw_h[vw][(vas + 1 > 31) ? 31 : vas + 1] = vw_h[vw][(vas + 1 > 31) ? 31 : vas + 1] + 1;
      end
      if (vcyc) vlast_end = clocks;
    end
    vas_q = cpu_as_n;
  end

  // ---------------------------------------------------- the timing meter
  // timetest: window w runs from a write to $3000+8w to one to $3004+8w (w < 64);
  // in it, the C16M clocks, the fetch and data cycles and their lengths
  // (S0-S5, as above), and the fetches and reads the caches answered
  integer tw = -1, tw_t0 [0:63], tw_t [0:63], tw_nf [0:63], tw_lf [0:63], tw_nd [0:63], tw_ld [0:63], tw_h [0:63];
  integer tw_sg [0:63], sw_last = -1;     // the shortest gap between two SWIM strobes, in C16M clocks (9999: fewer than two)
  integer tas = 0, tk; reg tas_q = 1; reg [2:0] tfc;
  initial for (tk = 0; tk < 64; tk = tk + 1) begin
    tw_t[tk] = 0; tw_nf[tk] = 0; tw_lf[tk] = 0; tw_nd[tk] = 0; tw_ld[tk] = 0; tw_h[tk] = 0; tw_sg[tk] = 9999;
  end
  always @(posedge clk) if (phi1 && timetest) begin
    if (!cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr[31:9] == 23'h000018 && cpu_addr[1:0] == 0) begin
      tk = cpu_addr[8:3];
      if (!cpu_addr[2] && tw != tk) begin tw = tk; tw_t0[tk] = clocks; end
      if (cpu_addr[2] && tw == tk) begin tw_t[tk] = clocks - tw_t0[tk]; tw = -1; end
    end
    if (!cpu_as_n && tas_q) begin tas = 0; tfc = cpu_fc; end
    if (!cpu_as_n) tas = tas + 1;
    if (cpu_as_n && !tas_q && tw >= 0 && tfc != 3'd7) begin
      if (tfc == 3'd6) begin tw_nf[tw] = tw_nf[tw] + 1; tw_lf[tw] = tw_lf[tw] + tas + 1; end
      else             begin tw_nd[tw] = tw_nd[tw] + 1; tw_ld[tw] = tw_ld[tw] + tas + 1; end
    end
    if (tw >= 0 && cpu.hit_ack) tw_h[tw] = tw_h[tw] + 1;
    if (dev_strobe && swim_sel) begin                                  // one C16M wide: one sample here
      if (tw >= 0 && sw_last >= 0 && clocks - sw_last < tw_sg[tw]) tw_sg[tw] = clocks - sw_last;
      sw_last = clocks;
    end
    tas_q = cpu_as_n;
  end

  // ------------------------------------------------- the write-only meter
  // clrtest: the data cycles into $3100-$31FF, each counted once as it
  // starts - CLR, Scc and MOVE from SR/CCR write there and must not read
  reg clrtest = 0;
  integer cl_r = 0, cl_w = 0; reg cl_q = 1;
  always @(posedge clk) if (phi1 && clrtest) begin
    if (!cpu_as_n && cl_q && cpu_fc != 3'd6 && cpu_fc != 3'd7 && cpu_addr[31:8] == 24'h000031) begin
      if (cpu_rw_n) begin cl_r = cl_r + 1; $display("---- a read of $%08x before the write (siz %b)", cpu_addr, cpu_siz); end
      else cl_w = cl_w + 1;
    end
    cl_q = cpu_as_n;
  end

`ifdef VTRACE
  // +define+VTRACE: 60 clocks of window 1's steady state - AS*, the slot
  // select, UE7's state and both DSACKs, clock by clock (how 1.16.3's two
  // GLUE clocks were found)
  integer vt = 0;
  always @(posedge clk) if (vramtest && vw == 1 && clocks > vw_t0[1] + 1200 && vt < 60) begin
    vt = vt + 1;
    if (phi1) $display("VT clk=%0d as=%b ds=%b rw=%b fc=%0d addr=%08x bs=%b sel=%b st=%0d vdsack0=%b s=%0d dsack=%b",
             clocks, cpu_as_n, cpu_ds_n, cpu_rw_n, cpu_fc, cpu_addr, cpu.k_busstate, vid_sel, video.st, vid_dsack0_n, cpu.s, dsack_n);
  end
`endif
  // ------------------------------------------------------------ the run
  integer n, kk; reg [31:0] stop_at, v, want; integer fd, r;
  reg [8*200-1:0] prog_dir; reg [31:0] slot_want [0:31];
  reg done = 0; integer tail = -1;
  always @(posedge clk) if (phi1 && reset_n && !done) begin
    if (!cpu_as_n && cpu_fc == 3'd6 && cpu_addr[31:2] == stop_at[31:2] && tail < 0) tail = 200;
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
  end

  initial begin
    if (!$value$plusargs("PROG=%s", prog_dir)) prog_dir = "../kernel_bus";
    cachetest = $test$plusargs("CACHETEST");
    cacheon = $test$plusargs("CACHEON");
    vramtest = $test$plusargs("VRAMTEST");
    berrtest = $test$plusargs("BERRTEST");
    timetest = $test$plusargs("TIMETEST");
    pace_en  = !$test$plusargs("NOPACE");
    post_en  = !$test$plusargs("NOPOST");
    ptrace   = $test$plusargs("PTRACE");
    clrtest = $test$plusargs("CLRTEST");
    $readmemh({prog_dir, "/program.hex"}, img);
    for (i = 0; i < 32768; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    fd = $fopen({prog_dir, "/stop_at.txt"}, "r"); r = $fscanf(fd, "%h", stop_at); $fclose(fd);
    if (cachetest) $readmemh({prog_dir, "/slots.txt"}, slot_want, 0, 16);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (!done && !halted && n < (timetest ? 2000000 : 400000)) begin @(posedge clk); n = n + 1; end
    if (halted) begin fails = fails + 1; $display("FAIL: the CPU halted (double bus fault) after %0d clocks", n); end
    if (!done) begin fails = fails + 1; $display("FAIL: STOP not reached after %0d clocks", n); end
    else pass = pass + 1;
    if (berrtest) begin                                                 // the SCSI handshake bus error (plan 9.6 item 3)
      v = ram[32'h3000 >> 2]; want = ram[32'h3004 >> 2];
      $display("---- blind read  timeout: frame word %04x (format $%0h, vector offset $%03x), SSW %04x", v[31:16], v[31:28], v[27:16], v[15:0]);
      $display("---- blind write timeout: frame word %04x (format $%0h, vector offset $%03x), SSW %04x", want[31:16], want[31:28], want[27:16], want[15:0]);
      if (v[31:28] == 4'hB && v[27:16] == 12'h008) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: a data read fault builds the long frame, format $B, vector 2 (UM 8.2.2)"); end
      if ((want[31:28] == 4'hA || want[31:28] == 4'hB) && want[27:16] == 12'h008) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: the write's fault is not a bus-error frame"); end
      if (fails == 0) $display("==== PASS: %0d checks - both handshake timeouts bus-error, the frames recorded", pass);
      else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
      $finish;
    end
    if (clrtest) begin                                                  // the write-only instructions (plan 1.17.2)
      fd = $fopen({prog_dir, "/count.txt"}, "r"); r = $fscanf(fd, "%d", kk); $fclose(fd);   // the writes
      $display("---- %0d writes and %0d reads into $3100-$31FF", cl_w, cl_r);
      if (cl_w == kk) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0d writes, expected %0d", cl_w, kk); end
      if (cl_r == 0) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0d destinations read before they were written (the 68000's behaviour)", cl_r); end
      $readmemh({prog_dir, "/want.hex"}, slot_want, 0, 31);                // what was written: $3100-$317F
      for (kk = 0; kk < 32; kk = kk + 1) begin
        v = ram[(32'h3100 + 4*kk) >> 2];
        if (v === slot_want[kk]) pass = pass + 1;
        else begin fails = fails + 1; $display("FAIL: $%04x holds %08x, expected %08x", 32'h3100 + 4*kk, v, slot_want[kk]); end
      end
      if (fails == 0) $display("==== PASS: %0d checks - CLR, Scc and MOVE from SR/CCR write without reading", pass);
      else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
      $finish;
    end
    if (timetest) begin                                                 // a measurement: report and stop
      fd = $fopen({prog_dir, "/count.txt"}, "r"); r = $fscanf(fd, "%d", kk); $fclose(fd);   // the windows
      for (vk = 0; vk < kk; vk = vk + 1) begin
        $display("---- tw %0d clocks %0d fetch %0d %0d data %0d %0d hits %0d swimgap %0d", vk, tw_t[vk], tw_nf[vk], tw_lf[vk], tw_nd[vk], tw_ld[vk], tw_h[vk], tw_sg[vk]);
        if (tw_t[vk] > 0) pass = pass + 1;
        else begin fails = fails + 1; $display("FAIL: window %0d never closed", vk); end
      end
      if (fails == 0) $display("==== PASS: %0d checks - the timing windows ran", pass);
      else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
      $finish;
    end
    if (vramtest) begin                                                 // a measurement: report and stop
      for (kk = 0; kk < 3; kk = kk + 1) begin
        $display("---- window %0d (%s): %0d C16M clocks, %0d VRAM cycles = %0.2f clocks a turn; cycle length avg %0.2f, gap avg %0.2f",
                 kk, kk == 0 ? "MOVE.L D0,(A0)+" : kk == 1 ? "MOVE.B D0,(A0)+" : "MOVE.L (A0)+,D2",
                 vw_t[kk], vw_n[kk], vw_t[kk] / 1000.0,
                 vw_len[kk] / (vw_n[kk] ? vw_n[kk] * 1.0 : 1.0), vw_gap[kk] / (vw_n[kk] ? vw_n[kk] * 1.0 : 1.0));
        $write("---- lengths:"); for (vj = 0; vj < 32; vj = vj + 1) if (vw_h[kk][vj]) $write(" %0d:%0d", vj, vw_h[kk][vj]); $display("");
        $write("---- gaps:   "); for (vj = 0; vj < 16; vj = vj + 1) if (vw_g[kk][vj]) $write(" %0d:%0d", vj, vw_g[kk][vj]); $display("");
        if (vw_n[kk] == (kk == 1 ? 1000 : 4000)) pass = pass + 1;
        else begin fails = fails + 1; $display("FAIL: window %0d ran %0d VRAM cycles", kk, vw_n[kk]); end
      end
      if (fails == 0) $display("==== PASS: %0d checks - the video-RAM measurement ran", pass);
      else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
      $finish;
    end
    // 1. the result slots
    if (cachetest) for (kk = 0; kk < 17; kk = kk + 1) begin
      v = ram[(32'h3000 + 4*kk) >> 2];
      if (v === slot_want[kk]) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL cache slot %0d: %08x, expected %08x", kk, v, slot_want[kk]); end
    end
    else for (kk = 0; kk < 17; kk = kk + 1) begin
      v = ram[(32'h3000 + 4*kk) >> 2];
      want = (kk < 4) ? 32'h00000004 : (kk < 8) ? 32'h00000304 : (kk < 12) ? 32'h01020304 :
             (kk == 12) ? 32'hAAAA5555 : (kk == 13) ? 32'h00000000 : (kk == 14) ? 32'hF0F0F0F0 :
             (kk == 15) ? 32'h00005EC7 : 32'h000001E7;
      if (v === want) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL slot %0d: %08x, expected %08x", kk, v, want); end
    end
    // 2. the cycle lengths
    $display("---- %0d bus cycles (%0d fetch, %0d data, %0d CPU space): RAM %0d to %0d C16M clocks, %0d over 4 (refresh stalls); %0d idle clocks with a request waiting",
             cycles, fetch_cycles, data_cycles, cpu_space_cycles, cyc_min, cyc_max, long_cycles, idle_between);
    $display("---- %0d fetches and reads answered from the caches", hits);
    if (cpu_space_cycles == (cachetest ? 0 : 1)) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0d CPU-space cycles, expected %0d", cpu_space_cycles, cachetest ? 0 : 1); end
    if (cacheon || cachetest) begin                 // the cache was on: it must have hit
      if (hits > 0) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the cache was enabled and nothing hit"); end
    end else begin
      if (hits == 0) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0d hits with the cache never enabled", hits); end
    end
    if (cachetest) begin                                                // the DBRA loop's fetch cycles
      $display("---- DBRA x500, cache on: %0d fetch cycles, %0d C16M clocks; off: %0d fetch cycles, %0d C16M clocks",
               mk_f[1] - mk_f[0], mk_t[1] - mk_t[0], mk_f[3] - mk_f[2], mk_t[3] - mk_t[2]);
      $display("---- ADD.L (Z),D2 + DBRA x500, data cache on: %0d data cycles, %0d C16M clocks", mk_d[5] - mk_d[4], mk_t[5] - mk_t[4]);
      if (mk_seen == 6'b111111) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: loop markers seen %b", mk_seen); end
      if (mk_d[5] - mk_d[4] <= 3) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the cached operand loop ran %0d data cycles, expected only its first read", mk_d[5] - mk_d[4]); end
      if (mk_f[1] - mk_f[0] <= 6) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the cached loop ran %0d fetch cycles, expected only its first turn's", mk_f[1] - mk_f[0]); end
      if (mk_f[3] - mk_f[2] >= 500) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the uncached loop ran %0d fetch cycles, expected one a turn", mk_f[3] - mk_f[2]); end
    end
    if (cyc_min == 4) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the shortest RAM cycle is %0d clocks, expected the Guide's 4", cyc_min); end
    if (cyc_max <= 8) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: the longest RAM cycle is %0d clocks, more than a refresh stall", cyc_max); end
    if (long_cycles * 10 < cycles) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0d of %0d cycles longer than 4 - more than refresh explains", long_cycles, cycles); end
    // 3. back-to-back
    if (idle_between == 0) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0d idle clocks between cycles with a request waiting", idle_between); end
    if (fails == 0) $display("==== PASS: %0d checks - kernel, wrapper and GLUE run the program on the 68030 bus", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
