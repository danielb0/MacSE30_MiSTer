// tb_se30_gcrread.v - the GCR read gate: SE30_PLAN.md 5.12.9 item 6, and
// with two drives 5.14.
//
// WHAT THIS PROVES
//   Disk images mounted in the two slots are read back by the SE/30 ROM's
//   own .Sony code, byte for byte, through every part of rung 2 as the
//   machine wires it - the internal drive on /ENBL1 and the external one on
//   /ENBL2 (plan 5.14), each with its own loader and encoder, the four
//   sharing the SDRAM's disk port:
//
//     HPS block device (two slots) -> se30_flp_loader x2 -> se30_flp_dkmux
//     -> se30_sdram (on sim/sdram's chip model) -> se30_flp_encoder x2 ->
//     se30_fdhd x2 (RD, ANDed) -> se30_swim -> se30_glue's device port ->
//     the 68030's bus
//
//   The processor is a bus model replaying the ROM's routines instruction
//   by instruction (disassembled from the 97221136 ROM with
//   scripts/se30_rom_mmu.py): every access the ROM makes to the SWIM, to
//   VIA1 (the head select, PA5, by bset/bclr on ORA; the SCC's PA7 poll),
//   to the ROM (the GCR decode table at $40831E08, the marks) and to RAM
//   (the decoded bytes) is a real bus cycle through GLUE, in the ROM's
//   order; the rest of each instruction is time (below).  The ROM image
//   is in SDRAM where the machine keeps it, so the ROM's table reads
//   share the controller with the encoders' disk reads.  The driver's
//   per-drive variables ($12A and $13 of (a1,d1)) are kept per drive, and
//   its drive enable is the ROM's ($4082E3D6): drive select 1 for the
//   internal drive, for the external one CA2-CA0 high, SEL low, then drive
//   select 2.
//
//     1. Open ($4082D79C): the SWIM probe ($4082E6A2) finds a SWIM - the
//        ISM switch ($57 $17 $57 $57) and the three phase echoes - and
//        each SWIM bus cycle is ONE chip access (GLUE's strobe is one
//        C16M, two clk_sys); Open's reads find both drives, no disk in
//     2. both slots mounted at once - a DiskCopy 4.2 800K image with tags
//        in each, different data - both loaders on the port together; each
//        drive reads its disk in ($2)
//     3. each drive's recalibrate ($4082E29E): the ISM entry's GCR path
//        ($4082E712), the mode $17 loop ($4082E2F2), the power-up
//        ($4082E376: GCR mode, motor on, /READY within the ROM's polls),
//        steps out to /TK0
//     4. every cylinder, a drive at a time in turn: the drive selected
//        (its enable and power-up check), the seek ($4082E17A: /STEP
//        polled, the settle polls of /READY), then each side read the ROM's
//        way - RdAddr ($40831BE8) and RdData ($40831CC2) until every sector
//        of the side is in: the address field's cylinder, side and format
//        ($22), the tags at $2FC and the 512 bytes in RAM as the ROM leaves
//        them, each against ITS drive's image (byte 3 of every block names
//        the drive), no error code, inside two revolutions - all 1600
//        sectors of each, every speed group
//     4b. drive 2 loads a raw 400K image while the ROM reads drive 1: drive
//        1 byte for byte, the port passing between its encoder and drive
//        2's loader
//     5. raw 400K images (single-sided) in each drive: side 0 of a cylinder
//        of every group reads with format $02; side 1 has no flux and
//        RdAddr returns noNybErr ($BE)
//     6. Daniel's Disk605.dsk if present, in drive 1: a smoke test, some
//        cylinders read back against the file - nothing is fitted to it
//     7. the disk port's handshake (no request torn, moved or raised over
//        a stale acknowledge), the SDRAM model's datasheet checks, no
//        byte taken twice by the ROM's data-register reads (a second
//        before the shifter latched another), every byte the ROM took one
//        the chip saw validly read (GLUE takes a device's byte on the
//        clock the device acts); the drives never both enabled, a drive
//        not enabled never pulling RD low
//
// THE MEMORY (Daniel, 2026-09-28: the split)
//   -DBEHAV_MEM: a behavioural memory on clk_sys to the controller's two
//   contracts - the whole gate, about three hours.  Without it: the real
//   se30_sdram on sim/sdram's chip model, about six times slower, run with
//   +groups +no56.  run.sh runs both.
//
//   +quick     part 4 reads cylinders 0, 15, 16, 31, 32, 47, 48, 63, 64, 79
//   +groups    part 4 reads cylinders 0, 16, 32, 48 and 64
//   +no56      skips parts 5 and 6
//   +stop0     ends after cylinder 0 (for debugging)
//   +rom=PATH  the 97221136 ROM image (a default path otherwise)
//
// THE CLOCKS
//   clk is clk_sys (31.3344 MHz), phi its toggle and phi1 = C16M's enable
//   for GLUE, the VIA, the SWIM and the drive, as in se30_machine.v; the
//   SDRAM runs on its 94 MHz clock and phase copies as in sim/sdram.
//
// THE PROCESSOR'S TIME
//   A bus cycle is what GLUE makes it (the SWIM 4 C16M, the VIA
//   E-synchronous, RAM and ROM the controller's acknowledge).  Between bus
//   cycles an instruction costs its MC68030 instruction-cache-case time
//   (UM 11.6, "two-clock reads" aside): a register operation 2, a shift or
//   rotate by an immediate 4 (the ROd row is illegible in the text copy;
//   LSd's 4 is used), Bcc 6 taken / 4 not, DBcc 6 looping / 10 expired;
//   an indexed operand adds 2.  The driver's own variables in RAM
//   ($134, $12C, the stack) are time only (4 each), not bus cycles.  The
//   Time Manager's waits are the time asked: the driver's counts are
//   tenths of a millisecond ($4082E246 divides by ten before PrimeTime -
//   inferred from the code, the trap vector itself not traced).

`timescale 1ns/1ps

module tb_se30_gcrread;

  // ------------------------------------------------------------ clocks
  reg clk = 0;
  always #15.957 clk = ~clk;
`ifndef BEHAV_MEM
  reg clk_mem = 0;
  always #5.319 clk_mem = ~clk_mem;
  reg clk_sdc = 0, clk_capa = 0, clk_capb = 0;
  always @(clk_mem) begin
    clk_sdc  <= #(1.064)  clk_mem;
    clk_capa <= #(10.372) clk_mem;
    clk_capb <= #(8.377)  clk_mem;
  end
`endif
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi;                                    // C16M's enable: the edges GLUE and the devices act on
  reg reset_n = 0;

  localparam real CLK_TO_PIN = 4.0, OUT_TO_PIN = 4.0, DQ_TO_REG = 2.0;   // sim/sdram's defaults
  localparam [23:0] BASE  = 24'h800000;                // the internal drive's image in SDRAM (word address)
  localparam [23:0] BASE2 = 24'h900000;                // the external drive's (plan 5.14)
  localparam integer MAXF = 1474560 + 84 + 512;

  // ------------------------------------------------------------ the 68030's bus
  reg  [31:0] cpu_addr = 0, cpu_dout = 0;
  reg         cpu_as_n = 1, cpu_ds_n = 1, cpu_rw_n = 1, ecs = 0;
  reg   [1:0] cpu_siz = 2'b01;
  reg   [2:0] cpu_fc = 3'd5;
  wire [31:0] cpu_din;
  wire  [1:0] dsack_n;
  wire        berr;
  wire  [2:0] ipl_n;

  // ------------------------------------------------------------ GLUE
  wire        mem_early, rom_early, ram_req, ram_we, rom_req, ram_refresh;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata, via1_rdata, swim_rdata;
  wire [31:0] mem_rdata;
  wire        mem_ack;
  wire        via1_irq_n;
  wire  [7:0] dev_rdata = via1_sel ? via1_rdata : swim_sel ? swim_rdata : 8'h00;

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .mem_early(mem_early), .rom_early(rom_early),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(mem_rdata), .ram_ack(mem_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(mem_rdata), .rom_ack(mem_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'hFF),
    .via1_irq_n(via1_irq_n), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(via1_pa_pin[4]), .ramsiz(2'b00), .hsync_n(1'b1));

  // ------------------------------------------------------------ VIA1
  wire  [7:0] via1_pa_out, via1_pa_oe, via1_pb_out, via1_pb_oe;
  wire  [7:0] via1_pa_pin = (via1_pa_oe & via1_pa_out) | ~via1_pa_oe;   // PA7 SCCWREQ* idle: 1
  wire  [7:0] via1_pb_pin = (via1_pb_oe & via1_pb_out) | ~via1_pb_oe;

  se30_via via1 (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n), .e_clk(e_clk),
    .sel(via1_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via1_rdata), .irq_n(via1_irq_n),
    .pa_in(via1_pa_pin), .pa_out(via1_pa_out), .pa_oe(via1_pa_oe),
    .pb_in(via1_pb_pin), .pb_out(via1_pb_out), .pb_oe(via1_pb_oe),
    .ca1(1'b1), .ca2_in(1'b0), .ca2_out(), .ca2_oe(),
    .cb1_in(1'b1), .cb1_out(), .cb1_oe(), .cb2_in(1'b1), .cb2_out(), .cb2_oe(),
    .dbg_ifr(), .dbg_ier());

  // ------------------------------------------------------------ the SWIM and the drive
  wire  [3:0] swim_ph, swim_ph_oe;
  wire        enbl1_n, enbl2_n, fdhd_sense, fdhd_eject, fdhd2_sense, fdhd2_eject;
  wire [47:0] swim_dbg;
  wire [15:0] fdhd_dbg, fdhd2_dbg;
  wire  [3:0] swim_ph_pin = (swim_ph_oe & swim_ph) | ~swim_ph_oe;
  wire        swim_sense  = fdhd_sense & fdhd2_sense;    // RD: each drive's while enabled, 1 otherwise (5.14)

  wire  [6:0] cyl, trk_cyl, cyl2, trk2_cyl;
  wire        trk_valid, trk_side, trk_bit, trk2_valid, trk2_side, trk2_bit;
  wire [16:0] trk_addr, trk2_addr;
  wire        disk_in, img_ds, img_800k, img_tags, readonly, loading;
  wire        disk2_in, img2_ds, img2_800k, img2_tags, readonly2, loading2;

  se30_swim swim (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .sel(swim_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .wdata(dev_wdata), .rdata(swim_rdata),
    .ph_out(swim_ph), .ph_oe(swim_ph_oe), .ph_in(swim_ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(swim_sense),
    .wrdata(), .wrreq_n(), .hdsel(), .dbg(swim_dbg));

  se30_fdhd fdhd (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
    .sense(fdhd_sense), .disk_in(disk_in), .eject(fdhd_eject),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .dbg(fdhd_dbg));

  se30_fdhd fdhd2 (                                    // the external drive (plan 5.14)
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .enbl_n(enbl2_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
    .sense(fdhd2_sense), .disk_in(disk2_in), .eject(fdhd2_eject),
    .cyl(cyl2), .trk_cyl(trk2_cyl), .trk_valid(trk2_valid), .trk_addr(trk2_addr), .trk_side(trk2_side), .trk_bit(trk2_bit),
    .dbg(fdhd2_dbg));

  // ------------------------------------------------------------ the loader, the encoder, the port
  reg         img_mounted = 0, img_mounted2 = 0, img_readonly = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba, sd_lba2;
  wire        sd_rd, sd_rd2;
  reg         sd_ack = 0, sd_ack2 = 0;
  reg   [7:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         sd_buff_wr = 0;
  wire        ld_req, ld_ack, en_req, en_ack, ld2_req, ld2_ack, en2_req, en2_ack;
  wire [23:0] ld_addr, en_addr, ld2_addr, en2_addr;
  wire [15:0] ld_wdata, en_rdata, ld2_wdata, en2_rdata;
  wire        dk_req, dk_we, dk_ack;
  wire [23:0] dk_addr;
  wire [15:0] dk_wdata, dk_rdata;

  se30_flp_loader #(.BASE(BASE)) loader (
    .clk(clk), .reset_n(reset_n),
    .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
    .eject(fdhd_eject),
    .disk_in(disk_in), .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags),
    .readonly(readonly), .loading(loading), .dbg());

  se30_flp_encoder #(.BASE(BASE)) encoder (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .img_ds(img_ds), .img_tags(img_tags), .img_800k(img_800k),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
    .dbg());

  se30_flp_loader #(.BASE(BASE2)) loader2 (
    .clk(clk), .reset_n(reset_n),
    .img_mounted(img_mounted2), .img_size(img_size), .img_readonly(img_readonly),
    .sd_lba(sd_lba2), .sd_rd(sd_rd2), .sd_ack(sd_ack2),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .mem_req(ld2_req), .mem_addr(ld2_addr), .mem_wdata(ld2_wdata), .mem_ack(ld2_ack),
    .eject(fdhd2_eject),
    .disk_in(disk2_in), .img_ds(img2_ds), .img_800k(img2_800k), .img_tags(img2_tags),
    .readonly(readonly2), .loading(loading2), .dbg());

  se30_flp_encoder #(.BASE(BASE2)) encoder2 (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk2_in), .img_ds(img2_ds), .img_tags(img2_tags), .img_800k(img2_800k),
    .cyl(cyl2), .trk_cyl(trk2_cyl), .trk_valid(trk2_valid),
    .trk_addr(trk2_addr), .trk_side(trk2_side), .trk_bit(trk2_bit),
    .mem_req(en2_req), .mem_addr(en2_addr), .mem_rdata(en2_rdata), .mem_ack(en2_ack),
    .dbg());

  se30_flp_dkmux dkmux (
    .clk(clk), .reset_n(reset_n),
    .ld0_req(ld_req), .ld0_addr(ld_addr), .ld0_wdata(ld_wdata), .ld0_ack(ld_ack),
    .en0_req(en_req), .en0_addr(en_addr), .en0_rdata(en_rdata), .en0_ack(en_ack),
    .ld1_req(ld2_req), .ld1_addr(ld2_addr), .ld1_wdata(ld2_wdata), .ld1_ack(ld2_ack),
    .en1_req(en2_req), .en1_addr(en2_addr), .en1_rdata(en2_rdata), .en1_ack(en2_ack),
    .dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack));

  // ------------------------------------------------------------ the SDRAM, as the machine drives it
  wire        sd_ready, cap_sel;
  wire  [1:0] cap_ok;
  wire        mem_start = ecs && mem_early;                                 // se30_machine.v
  wire        mem_req   = ram_req || rom_req;
  wire        mem_we    = !rom_early && ram_we;
  wire [22:0] mem_addr  = rom_early ? {2'b01, 5'b00000, rom_addr} : {2'b00, ram_addr[20:0]};
`ifdef BEHAV_MEM
  // a behavioural memory on clk_sys, to the controller's two contracts:
  // the CPU's acknowledge two clk_sys after the request, held while it is
  // up (a write lands with it); the disk port's in 3 to 12 clocks, held
  // until the request drops (sim/flpenc's memory)
  reg  [15:0] bmem [0:(1 << 24) - 1];
  reg  [31:0] b_rdata = 0;
  reg         b_ack = 0, bd_ack = 0;
  reg  [15:0] bd_rdata = 0;
  integer     b_cnt = 0, bd_lat = 0, bd_cyc = 0;
  assign sd_ready = 1'b1;
  assign mem_rdata = b_rdata;
  assign mem_ack   = b_ack;
  assign dk_rdata  = bd_rdata;
  assign dk_ack    = bd_ack;
  always @(posedge clk) begin
    bd_cyc <= bd_cyc + 1;
    if (!mem_req) begin b_ack <= 0; b_cnt <= 0; end
    else if (!b_ack) begin
      if (b_cnt == 1) begin
        b_ack <= 1;
        b_rdata <= {bmem[{mem_addr, 1'b0}], bmem[{mem_addr, 1'b1}]};
        if (mem_we) begin
          if (ram_be[3]) bmem[{mem_addr, 1'b0}][15:8] <= ram_wdata[31:24];
          if (ram_be[2]) bmem[{mem_addr, 1'b0}][7:0]  <= ram_wdata[23:16];
          if (ram_be[1]) bmem[{mem_addr, 1'b1}][15:8] <= ram_wdata[15:8];
          if (ram_be[0]) bmem[{mem_addr, 1'b1}][7:0]  <= ram_wdata[7:0];
        end
      end
      b_cnt <= b_cnt + 1;
    end
    if (!dk_req) bd_ack <= 0;
    else if (!bd_ack) begin
      if (bd_lat == 0) bd_lat <= 3 + (bd_cyc % 10);
      else if (bd_lat == 1) begin
        bd_ack <= 1; bd_lat <= 0;
        if (dk_we) bmem[dk_addr] <= dk_wdata; else bd_rdata <= bmem[dk_addr];
      end else bd_lat <= bd_lat - 1;
    end
  end
  `define MEM bmem
`else
  `define MEM chip.mem
  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;

  se30_sdram #(.TR_READS_LOG2(5)) sdram (
    .clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(reset_n),
    .ready(sd_ready), .cap_sel(cap_sel), .cap_ok(cap_ok), .cap_fail_a(), .cap_fail_b(),
    .cpu_start(mem_start), .cpu_req(mem_req), .cpu_we(mem_we), .cpu_addr(mem_addr),
    .cpu_be(ram_be), .cpu_wdata(ram_wdata), .cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
    .dl_req(1'b0), .dl_addr(24'd0), .dl_data(16'd0), .dl_ack(),
    .dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
    .raw_req(1'b0), .raw_ctl(64'd0), .raw_addr(24'd0), .raw_ack(), .dbg_dqm_force(1'b0),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq),
    .sd_dqm(sd_dqm), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));

  wire        sd_clk_chip, cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, oe_c;
  wire [12:0] addr_c;
  wire  [1:0] ba_c, dqm_c;
  wire [15:0] dq_out_c, dq_chip;
  assign #(CLK_TO_PIN) sd_clk_chip = sd_clk;
  assign #(OUT_TO_PIN) {cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, addr_c, ba_c, dqm_c} =
                       {sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_addr, sd_ba, sd_dqm};
  assign #(OUT_TO_PIN) oe_c     = sdram.dq_oe;
  assign #(OUT_TO_PIN) dq_out_c = sdram.dq_out;
  assign dq_chip = oe_c ? dq_out_c : 16'hzzzz;
  assign #(DQ_TO_REG) sd_dq = sdram.dq_oe ? 16'hzzzz : dq_chip;

  sdram_model chip (
    .clk(sd_clk_chip), .cke(cke_c), .cs_n(cs_n_c), .ras_n(ras_n_c), .cas_n(cas_n_c), .we_n(we_n_c),
    .ba(ba_c), .addr(addr_c), .dqm(addr_c[12:11]), .dq(dq_chip));
`endif

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  integer pf;                                          // progress, flushed (Icarus buffers stdout)
  task check(input cond, input [8*96-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
      if (cond) $fdisplay(pf, "pass %0s: %0d", what, got);
      else       $fdisplay(pf, "FAIL %0s: got %0d, want %0d", what, got, want);
      $fflush(pf);
    end
  endtask
  task progress(input [8*96-1:0] what);
    begin $fdisplay(pf, "%0d us: %0s", $time / 1000, what); $fflush(pf); end
  endtask
  // a heartbeat every 50 ms of simulated time, with the wall clock's pace
  // readable from the file's own timestamps
  initial begin : beat
    reg [8*96-1:0] hb;
    #1;
    forever begin
      #50000000;
      $sformat(hb, ". SWIM gaps: access %0d, valid reads %0d", hit_gap, vr_gap); progress(hb);
    end
  end

  // ------------------------------------------------------------ the HPS (sim/flpload's model)
  // two slots (plan 5.14): S0 the internal drive's image (file), S1 the
  // external drive's (file2); one transfer at a time, the slots served in
  // turn, the data bus shared - as hps_io does
  reg  [7:0] file  [0:MAXF - 1];
  reg  [7:0] file2 [0:MAXF - 1];
  integer    fsize = 0, fsize2 = 0;
  reg        hps_turn = 0;
  function [7:0] fb(input integer which, input integer idx);
    fb = which ? (idx < fsize2 ? file2[idx] : 8'hEE) : (idx < fsize ? file[idx] : 8'hEE);
  endfunction
  always begin : hps
    integer w, lba, which;
    repeat (40) @(posedge clk);
    which = -1;
    if (sd_rd && (!sd_rd2 || !hps_turn)) which = 0;
    else if (sd_rd2) which = 1;
    if (which >= 0) begin
      hps_turn = !which;
      lba = which ? sd_lba2 : sd_lba;
      repeat (3) @(posedge clk);
      #1 if (which) sd_ack2 = 1; else sd_ack = 1;
      for (w = 0; w < 256; w = w + 1) begin
        @(posedge clk); #1
        sd_buff_addr = w;
        sd_buff_dout = {fb(which, lba * 512 + 2 * w + 1), fb(which, lba * 512 + 2 * w)};
        sd_buff_wr = 1;
        @(posedge clk); #1 sd_buff_wr = 0;
      end
      repeat (2) @(posedge clk); #1 if (which) sd_ack2 = 0; else sd_ack = 0;
    end
  end

  // ------------------------------------------------------------ monitors
  // the disk port's handshake (sim/flpenc's), at the controller
  integer torn = 0, moved = 0, early = 0, dk_words = 0;
  reg     dreq_d = 0, dack_d = 0;
  reg [23:0] daddr_d = 0;
  always @(posedge clk) begin
    dreq_d <= dk_req; daddr_d <= dk_addr; dack_d <= dk_ack;
    if (dk_ack && !dack_d) dk_words <= dk_words + 1;
    if (dreq_d && !dk_req && !dk_ack) torn <= torn + 1;
    if (dreq_d && dk_req && !dk_ack && dk_addr != daddr_d) moved <= moved + 1;
    if (dk_req && !dreq_d && dk_ack) early <= early + 1;
  end
  // the two drives (plan 5.14): never both enabled; a drive not enabled
  // holds its RD high; the requesters' words on the shared port, and the
  // owner passing between them while both loads, or a load and a read, run
  integer both_en = 0, idle_rd = 0, ov_loads = 0, ov_ld_en = 0, sw_ld = 0, sw_ld_en = 0;
  integer dk_by [0:3];
  reg [1:0] last_owner = 0;
  initial begin dk_by[0] = 0; dk_by[1] = 0; dk_by[2] = 0; dk_by[3] = 0; end
  always @(posedge clk) begin
    if (!enbl1_n && !enbl2_n) both_en = both_en + 1;
    if ((enbl1_n && !fdhd_sense) || (enbl2_n && !fdhd2_sense)) idle_rd = idle_rd + 1;
    if (loading && loading2) ov_loads = ov_loads + 1;
    if (loading2 && disk_in && trk_valid !== 1'bx && en_req) ov_ld_en = ov_ld_en + 1;
    if (dk_ack && !dack_d) begin
      dk_by[dkmux.owner] = dk_by[dkmux.owner] + 1;
      if (dkmux.owner != last_owner) begin
        if ({dkmux.owner, last_owner} == 4'b0010 || {dkmux.owner, last_owner} == 4'b1000) sw_ld = sw_ld + 1;
        if ({dkmux.owner, last_owner} == 4'b0110 || {dkmux.owner, last_owner} == 4'b1001) sw_ld_en = sw_ld_en + 1;
      end
      last_owner = dkmux.owner;
    end
  end
  // the SWIM's accesses: clk edges on which the chip acts, per bus cycle
  // (one is the device port's contract: "one C16M clock"), and valid
  // data reads landing inside a pending clear (a byte read twice)
  integer swim_hits = 0, swim_cycles = 0, swim_double = 0, reread = 0;
  reg     swim_sel_d = 0;
  integer hits_this = 0;
  always @(posedge clk) begin
    swim_sel_d <= swim_sel;
    if (swim.hit) hits_this = hits_this + 1;
    if (swim.vread && swim.clr_cnt != 0) reread = reread + 1;
    if (swim_sel_d && !swim_sel) begin
      swim_cycles = swim_cycles + 1;
      if (hits_this != 1) swim_double = swim_double + 1;
      swim_hits = swim_hits + hits_this;
      hits_this = 0;
    end
  end

  // ------------------------------------------------------------ the bus cycle
  // S0 is the clk_sys in which C16M rises (ECS, the address, R/W); AS* at
  // S1; GLUE first sees it at the next C16M edge and answers; the
  // processor latches at the end of S4, a C16M after DSACK*, and negates
  // AS* (tb_se30_glue's cycle, on C16M edges; tb_se30_sdram's S0/S1).
  task c16;                                            // to just after the next C16M edge
    begin @(posedge clk); #1; while (!phi) begin @(posedge clk); #1; end end
  endtask
  task cpu(input integer n);                           // n C16M of the processor's own time
    integer i;
    begin for (i = 0; i < n; i = i + 1) c16; end
  endtask
  task ms_wait(input integer tenths);                  // the Time Manager: tenths of a millisecond
    begin #(tenths * 100000); c16; end
  endtask

  reg [31:0] rd;
  reg  [1:0] port;
  integer    bus_timeouts = 0;
  task bus(input read, input [31:0] a, input [1:0] siz, input [31:0] wd);
    integer k;
    begin
      @(posedge clk); #1; while (phi) begin @(posedge clk); #1; end       // the next edge is a C16M edge: S0
      cpu_addr = a; cpu_rw_n = read; cpu_siz = siz; cpu_dout = wd; cpu_fc = 3'd5; ecs = 1;
      @(posedge clk); #1;                                                  // S1
      ecs = 0; cpu_as_n = 0; cpu_ds_n = !read;
      c16; k = 1; cpu_ds_n = 0;                                            // GLUE sees AS*
      while (dsack_n == 2'b11 && k < 400) begin c16; k = k + 1; end
      if (k >= 400) bus_timeouts = bus_timeouts + 1;
      port = dsack_n;
      c16; rd = cpu_din;                                                   // the end of S4
      cpu_as_n = 1; cpu_ds_n = 1;
    end
  endtask
  reg [7:0] rb;                                        // the byte a byte read returned
  task rdb(input [31:0] a);
    begin
      bus(1, a, 2'b01, 32'h0);
      rb = (port == 2'b10) ? rd[31:24] : (rd >> (8 * (3 - a[1:0])));
    end
  endtask
  task wrb(input [31:0] a, input [7:0] d);
    begin bus(0, a, 2'b01, {d, d, d, d}); end
  endtask

  // ------------------------------------------------------------ the ROM's time
  // the 68030's costs (UM Section 11): a register op, a rotate, a branch
  // taken and not, DBcc looping and expiring, the index of an indexed read,
  // a d16(An) variable access the bench does not run as a cycle.  +kpace
  // puts OUR kernel's measured costs in their place (sim/system timetest,
  // plan 1.17.5) - the ROM's loops at the pace the core really runs them
`ifndef KP_R
  // our kernel's costs, sim/system timetest 2026-10-03 (plan 1.17.5): DBcc
  // 3, a register op or rotate 1, a branch taken 3, not taken 2, the index
  // 2, DBcc expiring 4, a d16(An) variable read 5 (a 4-clock cycle and a step)
  `define KP_R 1
  `define KP_ROT 1
  `define KP_BT 3
  `define KP_BN 2
  `define KP_DB 3
  `define KP_DBX 4
  `define KP_IDX 2
  `define KP_VAR 5
`endif
  integer T_R = 2, T_ROT = 4, T_BT = 6, T_BN = 4, T_DB = 6, T_DBX = 10, T_IDX = 2, T_VAR = 4;
  initial if ($test$plusargs("kpace")) begin
    T_R = `KP_R; T_ROT = `KP_ROT; T_BT = `KP_BT; T_BN = `KP_BN; T_DB = `KP_DB; T_DBX = `KP_DBX; T_IDX = `KP_IDX; T_VAR = `KP_VAR;
  end
  localparam [31:0] SW   = 32'h50F16000;               // the SWIM ($1E0)
  localparam [31:0] ORA  = 32'h50F01E00;               // VIA1 register 15 (a5 in the read loops)
  localparam [31:0] DDRA = 32'h50F00600;
  localparam [31:0] TBL  = 32'h40831E08;               // the GCR decode table (a3)
  localparam [31:0] AMK  = 32'h40831B98;               // D5 AA 96 DE AA FF
  localparam [31:0] DMK  = 32'h40831CA6;               // D5 AA AD DE AA
  localparam [31:0] TAGS = 32'h000002FB;               // the sector number, then the 12 tags
  localparam [31:0] BUF  = 32'h00020000;               // the bench's buffers: sector k at BUF + 512k

  // the bytes the data register gave the ROM (MSB set), for the first error's dump
  reg  [7:0] ring [0:47];
  integer    ring_t [0:47];
  integer    ring_n = 0, dumped = 0;
  // a byte the processor took with its MSB set must be one the chip saw
  // validly read, or its clear never comes and the next poll takes it again
  // and a byte the ROM took twice: a second one with the MSB set before
  // the shifter latched another (the latch accesses of the drive's
  // addressing also read the data register - L6 and L7 clear - and re-arm
  // its clear; that is the chip's documented behaviour, not a double take)
  integer    vreads = 0, unseen = 0, latches = 0, last_latch = -1, twice = 0;
  // the shortest gap between two accesses of the SWIM, and between two
  // valid data reads, in C16M clocks (plan 1.17.5: the chip clears a byte
  // 14 clocks after a valid read, so a second read 15 or more later is safe)
  integer    c16n = 0, hit_last = -1, hit_gap = 9999, vr_last = -1, vr_gap = 9999;
  always @(posedge clk) if (phi1) begin
    c16n = c16n + 1;
    if (swim.hit) begin
      if (hit_last >= 0 && c16n - hit_last < hit_gap) hit_gap = c16n - hit_last;
      hit_last = c16n;
    end
    if (swim.vread) begin
      if (vr_last >= 0 && c16n - vr_last < vr_gap) vr_gap = c16n - vr_last;
      vr_last = c16n;
    end
  end
  always @(posedge clk) begin
    if (swim.vread) vreads = vreads + 1;
    if (swim.lat0 || swim.lat1) latches = latches + 1;
  end
  task swim_rd(input [15:0] off);
    integer v0;
    begin
      v0 = vreads;
      rdb(SW + off);
      if (off == 16'h1800 && rb[7] && !swim.ism && swim.async_m) begin
        if (latches == last_latch) twice = twice + 1;
        last_latch = latches;
      end
      if (off == 16'h1800 && rb[7]) begin
        ring[ring_n % 48] = rb; ring_t[ring_n % 48] = $time / 64; ring_n = ring_n + 1;
        if (vreads == v0 && !swim.ism && !swim.l6 && !swim.l7 && swim.motor_d && swim.async_m) begin   // the data register was read
          unseen = unseen + 1;
          if (unseen <= 5) begin $fdisplay(pf, "       byte %02h taken, no valid read at the chip (FCLK %0d)", rb, $time / 64); $fflush(pf); end
        end
      end
    end
  endtask
  task dump_ring;
    integer j;
    begin
      if (!dumped) begin
        dumped = 1;
        for (j = ring_n - 48; j < ring_n; j = j + 1)
          if (j >= 0) $fdisplay(pf, "       byte %0d: %02h at FCLK %0d", j, ring[j % 48], ring_t[j % 48]);
        $fdisplay(pf, "       swim: ism %0d l7 %0d l6 %0d motor %0d mode %02h enbl1_n %0d sense %0d; drive %04h, SEL %0d, trk_valid %0d trk_cyl %0d",
                  swim.ism, swim.l7, swim.l6, swim.motor, swim.iwm_mode, enbl1_n, swim_sense, fdhd_dbg, via1_pa_pin[5], trk_valid, trk_cyl);
        $fflush(pf);
      end
    end
  endtask
  task swim_wr(input [15:0] off, input [7:0] d); begin wrb(SW + off, d); end endtask
  // tst.b (a5); bmi.b; move.b (a6),-(a7): the SCC's PA7, idle here
  task via_poll;
    begin rdb(ORA); if (rb[7]) cpu(T_BT); else cpu(T_BN + 8); end
  endtask
  // move.b (a4),dN; bpl.b *-2 - the tight poll, with a guard the ROM does not have
  integer hung = 0;
  task poll(output [7:0] v);
    integer n;
    begin
      swim_rd(16'h1800); n = 0;
      while (!rb[7] && n < 200000) begin cpu(T_BT); swim_rd(16'h1800); n = n + 1; end
      if (!rb[7]) hung = hung + 1;
      cpu(T_BN); v = rb;
    end
  endtask
  // the ROM's table and marks: bus reads of the ROM
  task rom_rd(input [31:0] a); begin rdb(a); end endtask

  // ------------------------------------------------------------ the drive's registers
  // $4082E0BA and friends: the driver's variables - time only
  task e0ba; begin cpu(6 + 2 * T_VAR + 4 * T_R + 8); end endtask
  // $4082E0EC: register n onto CA2, SEL, CA0, CA1 ({CA1,CA0,SEL,CA2})
  task drv_addr(input [3:0] n);
    begin
      cpu(6); e0ba; cpu(T_VAR + T_BN);                   // bsr; tst.b $135(a1); bmi
      swim_rd(16'h0200); swim_rd(16'h0600);              // CA0, CA1 high
      cpu(T_ROT + (n[0] ? T_BN : T_BT));                 // lsr.b; bcc
      swim_rd(n[0] ? 16'h0A00 : 16'h0800);               // CA2
      if (n[0]) cpu(T_BT);
      cpu(T_ROT + (n[1] ? T_BN : T_BT));
      rdb(ORA); wrb(ORA, n[1] ? (rb | 8'h20) : (rb & 8'hDF));   // bset/bclr #5,$1e00(a2): SEL
      if (n[1]) cpu(T_BT);
      cpu(T_ROT + (n[2] ? T_BT : T_BN));
      if (!n[2]) swim_rd(16'h0000);                      // CA0 low
      cpu(T_ROT + (n[3] ? T_BT : T_BN));
      if (!n[3]) swim_rd(16'h0400);                      // CA1 low
      cpu(8);                                            // rts
    end
  endtask
  // $4082E12E: the register's bit on SENSE, through the status register
  reg sns;
  task drv_read(input [3:0] n);
    begin
      cpu(6); drv_addr(n); cpu(T_VAR + T_BN + 12);       // bsr; tst $135; bmi; move sr; ori
      swim_rd(16'h1A00); swim_rd(16'h1C00); sns = rb[7]; swim_rd(16'h1800);
      cpu(12 + T_R + 8);                                 // move sr; tst.b d0; rts
    end
  endtask
  // $4082E152: LSTRB pulsed at the register the lines already address
  task drv_strobe;
    begin
      cpu(T_VAR + T_BN + 12);
      swim_rd(16'h0E00); cpu(2 * T_R); swim_rd(16'h0C00);  // PH3 high, nop, nop, PH3 low
      cpu(12 + 8);
    end
  endtask
  task drv_cmd(input [3:0] n); begin cpu(6); drv_addr(n); drv_strobe; end endtask

  // ------------------------------------------------------------ the driver
  // the driver's per-drive variables, (a1,d1): drv 0 the internal drive
  // (d1 = $4A), 1 the external (plan 5.14)
  integer    drv = 0;
  reg        flag13_d [0:1];                           // $13(a1,d1): the drive's $F read 1 at Open
  reg        found_swim;                               // $134: the probe's verdict
  integer    cur_trk_d [0:1];                          // $12A(a1,d1): where the driver thinks the head is
  wire [6:0] cyl_drv = drv ? cyl2 : cyl;               // the selected drive's head
  integer    ready_polls, mode_loops;

  // $4082E2F2: the mode register to $17
  task mode_loop(output integer ok);
    integer d2;
    begin
      ok = 0; mode_loops = 0;
      swim_rd(16'h1A00); swim_rd(16'h1C00); rb = rb & 8'h1F; cpu(T_R);
      d2 = rb; swim_rd(16'h1800); cpu(4 + T_BN);
      if (d2 == 8'h17) ok = 1;
      else begin
        d2 = 32'h80000;
        while (!ok && d2 > 0) begin
          mode_loops = mode_loops + 1; d2 = d2 - 1; cpu(3 * T_R);
          swim_rd(16'h1000); swim_rd(16'h1A00); swim_rd(16'h1C00);
          cpu(2 * T_R + 4);
          if (rb[5]) cpu(T_BT);                           // bclr #5: still busy
          else if ((rb & 8'h1F) == 8'h17) ok = 1;
          else begin swim_wr(16'h1E00, 8'h17); swim_rd(16'h1C00); cpu(T_BT); end
        end
        if (ok) swim_rd(16'h1800);
      end
      cpu(8);
    end
  endtask

  // $4082E6A2: the SWIM probe of Open
  task swim_probe;
    reg [7:0] e1, e2, e3;
    begin
      cpu(T_VAR + 12 + T_VAR);
      swim_rd(16'h1400); swim_rd(16'h1C00); swim_rd(16'h1000); swim_rd(16'h1A00);
      cpu(T_R);
      swim_wr(16'h1E00, 8'h57); swim_wr(16'h1E00, 8'h17); swim_wr(16'h1E00, 8'h57); swim_wr(16'h1E00, 8'h57);
      found_swim = 0;
      cpu(T_R); swim_wr(16'h0800, 8'hF5); swim_rd(16'h1800); e1 = rb; cpu(T_BN);
      if (e1 == 8'hF5) begin
        cpu(T_R); swim_wr(16'h0800, 8'hF6); swim_rd(16'h1800); e2 = rb; cpu(T_BN);
        if (e2 == 8'hF6) begin
          cpu(T_R); swim_wr(16'h0800, 8'hF7); swim_rd(16'h1800); e3 = rb; cpu(T_BN);
          if (e3 == 8'hF7) begin
            found_swim = 1; cpu(T_VAR);                                        // st.b $134(a1)
            swim_wr(16'h0C00, 8'hF8);
          end
        end
      end
      swim_rd(16'h1C00); swim_rd(16'h1800); swim_rd(16'h1200);
      cpu(12 + 8);
    end
  endtask

  // $4082E3D6 (vector $B40, through $4082E3CC): the drive enabled - the
  // internal one (d1 = $4A) by drive select 1 and the enable; the external
  // one ($4082E408) first puts CA2, CA1, CA0 high and SEL low, then drive
  // select 2 and the enable
  task drv_enable;
    begin
      cpu(6 + 8 + T_VAR + T_BT + T_VAR + T_VAR + T_BN + 4);
      if (drv == 0) begin cpu(T_BN); swim_rd(16'h1400); swim_rd(16'h1200); end
      else begin
        cpu(T_BT);
        swim_rd(16'h0A00); swim_rd(16'h0600); swim_rd(16'h0200);
        rdb(ORA); wrb(ORA, rb & 8'hDF);                  // bclr #5,$1e00(a2): SEL low
        swim_rd(16'h1600); swim_rd(16'h1200);
      end
      cpu(8);
    end
  endtask

  // $4082E1FE: the settle - with $13 set, /READY ($B) polled every
  // millisecond up to 1000 times after a first wait of d2; without it,
  // the wait d0 alone
  task settle(input integer d0, input integer d2, output integer polls, output integer ok);
    integer d5;
    begin
      polls = 0; ok = 0;
      cpu(6 + T_VAR + T_BN);
      if (!flag13_d[drv]) begin if (d0 != 0) ms_wait(d0); ok = -1; end
      else begin
        cpu(6 + 4 + T_R);
        if (d2 != 0) ms_wait(d2);
        d5 = 1000;
        drv_read(4'hB); polls = 1;
        while (sns && d5 > 0) begin                     // dbra d5 from 1000: 1001 reads in all
          cpu(T_R + T_DB); ms_wait(10); d5 = d5 - 1;
          drv_read(4'hB); polls = polls + 1;
        end
        ok = !sns;
        cpu(T_VAR + 6);
      end
    end
  endtask

  // $4082E376: the power-up (d0 = $38(a1) = 4000)
  integer pu_polls, pu_ok;
  task power_up;
    reg m7;
    begin
      cpu(T_VAR + T_R); drv_enable;
      cpu(T_VAR + T_BN);                                 // move.b $16(a1,d1),d5: a SuperDrive
      drv_read(4'h7); m7 = sns; cpu(T_VAR + T_R + T_VAR + T_BT);
      drv_cmd(4'h7);                                     // GCR ($6 for MFM)
      cpu(T_VAR + T_R);                                  // d5 = $17 (GCR, 0) eor the $7 read
      drv_read(4'h8); cpu(T_R);                          // /MOTORON
      pu_polls = 0; pu_ok = 1;
      if (sns || m7) begin
        cpu(T_BN); drv_strobe;                           // command $8: the motor on
        cpu(T_R + 4 + T_VAR);
        settle(4000, 750, pu_polls, pu_ok);
        cpu(T_VAR + 4 + T_BN);
        ms_wait(6000);                                   // $33(a1) is 0, not 2: another 600 ms ($4082E3C2)
      end else cpu(T_BT);
      cpu(8);
    end
  endtask

  // $4082E712: the ISM entry, its GCR path
  integer ism_ok;
  task ism_entry;
    begin
      cpu(6); e0ba; cpu(T_VAR);
      if (found_swim) begin
        cpu(T_BN + 12 + T_R + T_VAR);
        swim_wr(16'h0C00, 8'h38); cpu(T_R); swim_wr(16'h0800, 8'hF5); swim_rd(16'h1800);
        if (rb == 8'hF5) begin                           // already in the ISM (it never is on this path)
          swim_wr(16'h0800, 8'hF6); swim_rd(16'h1800); swim_wr(16'h0800, 8'hF7); swim_rd(16'h1800);
          cpu(T_VAR + T_BN); swim_wr(16'h0C00, 8'hF8); swim_rd(16'h1C00);
        end else cpu(T_BT);
        cpu(T_VAR);                                      // clr.b $135(a1)
      end else cpu(T_BT);
      mode_loop(ism_ok);
      cpu(T_BN + T_VAR + T_BT + 12 + T_R + 8);
    end
  endtask

  // $4082E29E: the recalibrate
  integer recal_err, recal_steps;
  task recal;
    integer d7;
    reg done;
    begin
      cpu(6); e0ba; cpu(6 + 3 * T_VAR + 8);             // bsr $4082E362
      ism_entry;
      recal_err = ism_ok ? 0 : 8'hB3;
      recal_steps = 0;
      if (ism_ok) begin
        power_up;
        d7 = 80; cpu(T_R + T_R);
        drv_cmd(4'h1);                                   // direction: out
        done = 0;
        while (!done) begin
          cpu(T_VAR + T_VAR + T_BN + T_ROT); ms_wait(60); // $3C = 120, halved with $13: 6 ms
          cpu(T_R); drv_read(4'hA);                      // /TK0
          if (!sns) begin done = 1; recal_err = 0; end
          else begin
            cpu(T_BN + T_R); drv_read(4'h4);             // /STEP
            if (!sns) begin done = 1; recal_err = 8'hB5; end
            else begin
              cpu(T_BN + T_R + T_R); d7 = d7 - 1;
              if (d7 == 0) begin done = 1; recal_err = 8'hB4; end
              else begin drv_strobe; recal_steps = recal_steps + 1; cpu(T_BT); end
            end
          end
        end
        cur_trk_d[drv] = 0;
      end
      cpu(T_VAR + 6);
    end
  endtask

  // $4082E17A: the seek to cylinder `to`
  integer seek_err, seek_polls, seek_ok, step_polls_max;
  task seek(input integer to);
    integer d5, d2, p2, k2;
    begin
      seek_err = 0; cpu(6 + 6); e0ba; cpu(T_VAR + T_BN + T_R + T_R + T_R);
      d5 = to - cur_trk_d[drv];
      if (d5 != 0) begin
        cpu(T_BN + T_BT + T_R);
        drv_cmd(d5 > 0 ? 4'h0 : 4'h1);                  // $0 in, $1 out
        if (d5 < 0) d5 = -d5;
        cpu(T_R + T_R);
        while (d5 > 0 && seek_err == 0) begin
          cpu(T_R); drv_read(4'h4);
          if (!sns) seek_err = 8'hB5;
          else begin
            cpu(T_BN); drv_strobe;                       // step
            cpu(6 + T_VAR + 6 + T_VAR + T_BN + 8);       // $4082E1DC: $13 set, no wait
            d2 = 80; p2 = 0;
            cpu(T_R); drv_read(4'h4); p2 = 1;
            while (!sns && d2 > 0) begin cpu(T_DB); d2 = d2 - 1; drv_read(4'h4); p2 = p2 + 1; end
            if (p2 > step_polls_max) step_polls_max = p2;
            cpu(8 + T_DB); d5 = d5 - 1;
          end
        end
        cur_trk_d[drv] = to;
        cpu(T_R + 6); e0ba; cpu(T_VAR + T_VAR + T_BN);
        cpu(T_VAR + T_R);
        settle(300, 5, seek_polls, seek_ok);
      end else begin cpu(T_BT); seek_polls = 0; seek_ok = 1; end
      cpu(T_VAR + T_R);
      settle(0, 0, p2, k2);
      if (k2 != 1) seek_ok = 0;
      seek_polls = seek_polls + p2;
      cpu(T_R + 8);
    end
  endtask

  // ------------------------------------------------------------ RdAddr, $40831BE8
  integer    err;
  reg  [7:0] h_sec, h_side, h_fmt;
  integer    h_cyl;
  function [15:0] ror16(input [15:0] v, input integer n); ror16 = (v >> n) | (v << (16 - n)); endfunction
  function [15:0] rol16(input [15:0] v, input integer n); rol16 = (v << n) | (v >> (16 - n)); endfunction
  function [7:0]  rol8 (input [7:0]  v, input integer n); rol8  = (v << n) | (v >> (8 - n));  endfunction

  // $40831BBE: the head (register $1 or $3) and the vectors, then RdAddr
  task rd_addr(input integer side);
    integer d3, n, mk;
    reg [15:0] d2w, d0w, d1w;
    reg  [7:0] b, t, d4b;
    reg [31:0] a0;
    reg        found;
    begin
      err = 0;
      cpu(T_R + 6); cpu(6 + 6 + 12 + 8 + 8 + 8);          // moveq #8; bsr $40831B9E: $23A -> $40831BA4
      cpu(T_R + T_VAR + T_BT);                           // moveq #1; btst #3,$16(a1); beq
      cpu(6 + 6 + 6); drv_addr(side ? 4'h3 : 4'h1);      // bsr $40831B44 -> $4082EFB8 -> $4082E0EC
      cpu(6 + 6 + 6); e0ba; cpu(T_VAR + 4 + 4 + T_VAR + 8);   // bsr $40831B4A -> $4082E0C2
      cpu(T_VAR + T_BN + T_R + T_VAR + 8 + 6 + 6);      // tst $17; lea; move.l $22a.w; rts -> $40831B20
      // $40831BE8
      cpu(4 * T_R + T_VAR + T_R + 2 * T_VAR);
      d3 = 3; d2w = 16'h0200; found = 0;
      while (!found && err == 0) begin                   // $40831BFE: three nibbles within 513 polls
        via_poll;
        swim_rd(16'h1800); b = rb;
        d2w = d2w - 1;
        if (d2w == 16'hFFFF) begin cpu(T_DBX + T_R + 6); err = 8'hBE; end
        else begin
          cpu(T_DB);
          if (!b[7]) cpu(T_BT);
          else begin
            cpu(T_BN + T_R); d3 = d3 - 1;
            if (d3 == 0) begin cpu(T_BN); found = 1; end else cpu(T_BT);
          end
        end
      end
      if (err == 0) begin                                // $40831C16: D5 AA 96 within $5BC/$5DC bytes
        cpu(T_R + 4 + T_VAR + (flag13_d[drv] ? T_BN + 4 : T_BT) + T_R);
        d0w = flag13_d[drv] ? 16'h05BC : 16'h05DC;
        found = 0; a0 = AMK; mk = 0; cpu(T_R + T_R);
        while (!found && err == 0) begin
          poll(b); via_poll;
          d0w = d0w - 1;
          if (d0w == 16'hFFFF) begin cpu(T_DBX + T_R + T_BT); err = 8'hBD; end
          else begin
            cpu(T_DB); rom_rd(a0); a0 = a0 + 1;
            if (b != rb) begin cpu(T_BT + T_R + T_R); a0 = AMK; mk = 0; end
            else begin
              cpu(T_BN + T_R); mk = mk + 1;
              if (mk == 3) begin cpu(T_BN); found = 1; end else cpu(T_BT);
            end
          end
        end
      end
      if (err == 0) begin                                // $40831C48: track, sector, side, format, checksum
        d1w = 16'h0000;
        poll(b); rom_rd(TBL + b); cpu(T_IDX); d1w[7:0] = rb; d4b = rb; cpu(T_R); d1w = ror16(d1w, 6); cpu(T_ROT);
        poll(b); rom_rd(TBL + b); cpu(T_IDX); h_sec = rb; d4b = d4b ^ rb; cpu(T_R);
        poll(b); rom_rd(TBL + b); cpu(T_IDX); d1w[7:0] = rb; h_side = rb; d4b = d4b ^ rb; cpu(T_R);
        d1w = rol16(d1w, 6); cpu(T_ROT);
        via_poll;
        poll(b); rom_rd(TBL + b); cpu(T_IDX); h_fmt = rb; d4b = d4b ^ rb; cpu(T_R);
        poll(b); rom_rd(TBL + b); cpu(T_IDX); d4b = d4b ^ rb; cpu(T_R);
        h_cyl = {d1w[6], d1w[5:0]};
        if (d4b != 0) begin cpu(T_BT + T_R + T_BT); err = 8'hBB; end
        else begin
          cpu(T_BN + T_R);
          for (n = 0; n < 2 && err == 0; n = n + 1) begin    // DE AA
            poll(b); via_poll; rom_rd(a0); a0 = a0 + 1;
            if (b != rb) begin cpu(T_BT + T_R + T_BT); err = 8'hBA; end
            else cpu(T_BN + (n == 1 ? T_DBX : T_DB));
          end
        end
      end
      cpu(6 + 6 + 8);                                    // bra.w $40831B56 -> $4082E43C, the return
    end
  endtask

  // ------------------------------------------------------------ RdData, $40831CC2
  task rd_data(input [31:0] dbuf);
    integer d2, mk, g;
    reg [15:0] d4w;
    reg  [7:0] b, d1, db2, d5, d6, d7;
    reg        x, found;
    reg [31:0] a1, a2, a0;
    begin
      err = 0;
      cpu(6 + 6); e0ba; cpu(T_VAR + T_BN + T_R + T_VAR + 8 + 6 + 6);   // $40831CAC: bsr; tst $17; lea; vector $22E
      cpu(2 * T_VAR + 3 * T_R + 6 + 3 * T_R);           // move.l (a7)+,$124.w; moveq x3; move.l #; moveq x3
      d2 = 8'h30; d5 = 0; d6 = 0; d7 = 0; d4w = 16'h000A; x = 0;
      found = 0; a2 = DMK; mk = 0; cpu(T_R + T_R);
      while (!found && err == 0) begin                   // $40831CDC: D5 AA AD within 49 bytes
        poll(b); via_poll;
        d2 = d2 - 1;
        if (d2 < 0) begin cpu(T_DBX + T_R + T_BT); err = 8'hB9; end
        else begin
          cpu(T_DB); rom_rd(a2); a2 = a2 + 1;
          if (b != rb) begin cpu(T_BT + T_R + T_R); a2 = DMK; mk = 0; end
          else begin
            cpu(T_BN + T_R); mk = mk + 1;
            if (mk == 3) begin cpu(T_BN); found = 1; end else cpu(T_BT);
          end
        end
      end
      if (err == 0) begin
        poll(b); a1 = TAGS; cpu(T_R);                    // $40831CF6: the sector's own number
        rom_rd(TBL + b); cpu(T_IDX); wrb(a1, rb); a1 = a1 + 1;
        // the tags ($40831D02) and the data ($40831D64): three bytes a group,
        // the data's last group two
        a0 = dbuf;
        for (g = 0; g < 4 + 171; g = g + 1) begin
          // the first code: its loop polls VIA1 too
          via_poll; swim_rd(16'h1800);
          while (!rb[7]) begin cpu(T_BT); via_poll; swim_rd(16'h1800); end
          cpu(T_BN); b = rb;
          rom_rd(TBL + b); cpu(T_IDX); d1 = rol8(rb, 2); cpu(T_ROT);
          db2 = d1 & 8'hC0; cpu(2 * T_R);
          poll(b); rom_rd(TBL + b); cpu(T_IDX); db2 = db2 | rb;
          x = d7[7]; cpu(2 * T_R);                       // move.b d7,d3; add.b d7,d3: X
          d7 = rol8(d7, 1); cpu(T_ROT);
          db2 = db2 ^ d7; cpu(T_R);
          wrb(g < 4 ? a1 : a0, db2); if (g < 4) a1 = a1 + 1; else a0 = a0 + 1;
          {x, d5} = {1'b0, d5} + {1'b0, db2} + x; cpu(T_R);
          d1 = rol8(d1, 2); cpu(T_ROT); db2 = d1 & 8'hC0; cpu(2 * T_R);
          poll(b); rom_rd(TBL + b); cpu(T_IDX); db2 = db2 | rb;
          db2 = db2 ^ d5; cpu(T_R);
          wrb(g < 4 ? a1 : a0, db2); if (g < 4) a1 = a1 + 1; else a0 = a0 + 1;
          {x, d6} = {1'b0, d6} + {1'b0, db2} + x; cpu(T_R);
          if (g >= 4) begin
            cpu(T_R);                                    // tst.w d4
            if (d4w == 0) cpu(T_BT);                     // beq $40831E22: the last group is two bytes
          end
          if (!(g >= 4 && d4w == 0)) begin
            if (g >= 4) cpu(T_BN);
            d1 = rol8(d1, 2); cpu(T_ROT); d1 = d1 & 8'hC0; cpu(T_R);
            via_poll;
            poll(b); rom_rd(TBL + b); cpu(T_IDX); d1 = d1 | rb;
            d1 = d1 ^ d6; cpu(T_R);
            wrb(g < 4 ? a1 : a0, d1); if (g < 4) a1 = a1 + 1; else a0 = a0 + 1;
            {x, d7} = {1'b0, d7} + {1'b0, d1} + x; cpu(T_R);
            d4w = d4w - 3; cpu(T_R);
            if (g < 4) begin
              if (g < 3) cpu(T_BT);
              else begin cpu(T_BN + T_R + T_VAR + T_BT); d4w = 16'h01FE; end   // swap; tst.b $12c.w (read); beq
            end else cpu(T_BT);
          end
        end
        // the checksum ($40831E22): four codes, an invalid one fails
        via_poll; swim_rd(16'h1800);
        while (!rb[7]) begin cpu(T_BT); via_poll; swim_rd(16'h1800); end
        cpu(T_BN); b = rb;
        rom_rd(TBL + b); cpu(T_IDX); d1 = rb;
        if (d1[7]) err = 8'hB8;
        if (err == 0) begin
          cpu(T_BN); d1 = rol8(d1, 2); cpu(T_ROT); db2 = d1 & 8'hC0; cpu(2 * T_R);
          poll(b); rom_rd(TBL + b); cpu(T_IDX);
          if (rb[7] || (db2 | rb) != d5) err = 8'hB8;
          cpu(T_BN + 3 * T_R + T_BN);
        end
        if (err == 0) begin
          d1 = rol8(d1, 2); cpu(T_ROT); db2 = d1 & 8'hC0; cpu(2 * T_R);
          poll(b); rom_rd(TBL + b); cpu(T_IDX);
          if (rb[7] || (db2 | rb) != d6) err = 8'hB8;
          cpu(T_BN + 3 * T_R + T_BN);
        end
        if (err == 0) begin
          d1 = rol8(d1, 2); cpu(T_ROT); d1 = d1 & 8'hC0; cpu(T_R);
          via_poll;
          poll(b); rom_rd(TBL + b); cpu(T_IDX);
          if (rb[7] || (d1 | rb) != d7) err = 8'hB8;
          cpu(T_BN + 3 * T_R + T_BT);
        end
        if (err == 0) begin                              // $40831E80: DE AA
          cpu(T_R);
          for (g = 0; g < 2 && err == 0; g = g + 1) begin
            poll(b); via_poll; rom_rd(a2); a2 = a2 + 1;
            if (b != rb) err = 8'hB7;
            else cpu(T_BN + (g == 1 ? T_DBX : T_DB));
          end
        end
        if (err != 0) cpu(T_R + T_BT);
      end
      cpu(T_R + 6 + 6 + 8);
    end
  endtask

  // ------------------------------------------------------------ the image
  function integer spt(input integer c); spt = 12 - c / 16; endfunction
  function integer secs_before(input integer c);     // sectors on one side before cylinder c
    integer g;
    begin
      secs_before = 0;
      for (g = 0; g < c / 16; g = g + 1) secs_before = secs_before + 16 * (12 - g);
      secs_before = secs_before + (c % 16) * spt(c);
    end
  endfunction
  function integer revcells(input integer c);
    case (c / 16)
      0: revcells = 74558; 1: revcells = 68476; 2: revcells = 62237; 3: revcells = 55954; default: revcells = 49790;
    endcase
  endfunction
  function integer blockno(input integer c, input integer s, input integer k, input integer ds);
    blockno = ds ? 2 * secs_before(c) + s * spt(c) + k : secs_before(c) + k;
  endfunction
  // the synthetic image (MacLC's self-identifying pattern): data bytes 0-2
  // are the block's cylinder, side and sector, byte 3 the drive (5.14),
  // the rest a pattern that differs between the drives' images
  function [7:0] dbyte(input integer w, input integer n, input integer c, input integer s, input integer k, input integer i);
    case (i)
      0: dbyte = c; 1: dbyte = s; 2: dbyte = k; 3: dbyte = 8'hD0 + w;
      default: dbyte = (n * 7 + i * 13 + (i >> 5) + w * 8'h5B) & 8'hFF;
    endcase
  endfunction
  function [7:0] tbyte(input integer w, input integer n, input integer j); tbyte = (n * 5 + j * 31 + 1 + w * 8'h3D) & 8'hFF; endfunction

  integer img_kind [0:1];                              // 0 synthetic DC42 800K tagged, 1 synthetic raw 400K, 2 a file
  integer img_off [0:1];                               // where the data starts in the file
  integer img_tagoff [0:1];                            // where the tags start (-1 none)
  task fput(input integer w, input integer idx, input [7:0] v);
    begin if (w) file2[idx] = v; else file[idx] = v; end
  endtask
  task build_dc42_800k(input integer w);
    integer c, s, k, n, i;
    begin
      for (i = 0; i < 84; i = i + 1) fput(w, i, 8'h00);
      fput(w, 0, 8'd7); for (i = 1; i < 8; i = i + 1) fput(w, i, "a" + i + w);
      fput(w, 64, 8'h00); fput(w, 65, 8'h0C); fput(w, 66, 8'h80); fput(w, 67, 8'h00);   // 819,200
      fput(w, 68, 8'h00); fput(w, 69, 8'h00); fput(w, 70, 8'h4B); fput(w, 71, 8'h00);   // 19,200
      fput(w, 80, 8'd1); fput(w, 81, 8'h22); fput(w, 82, 8'h01); fput(w, 83, 8'h00);
      for (c = 0; c < 80; c = c + 1)
        for (s = 0; s < 2; s = s + 1)
          for (k = 0; k < spt(c); k = k + 1) begin
            n = blockno(c, s, k, 1);
            for (i = 0; i < 512; i = i + 1) fput(w, 84 + 512 * n + i, dbyte(w, n, c, s, k, i));
            for (i = 0; i < 12; i = i + 1)  fput(w, 84 + 819200 + 12 * n + i, tbyte(w, n, i));
          end
      if (w) fsize2 = 84 + 819200 + 19200; else fsize = 84 + 819200 + 19200;
      img_kind[w] = 0; img_off[w] = 84; img_tagoff[w] = 84 + 819200;
    end
  endtask
  task build_raw_400k(input integer w);
    integer c, k, n, i;
    begin
      for (c = 0; c < 80; c = c + 1)
        for (k = 0; k < spt(c); k = k + 1) begin
          n = blockno(c, 0, k, 0);
          for (i = 0; i < 512; i = i + 1) fput(w, 512 * n + i, dbyte(w, n, c, 0, k, i));
        end
      if (w) fsize2 = 409600; else fsize = 409600;
      img_kind[w] = 1; img_off[w] = 0; img_tagoff[w] = -1;
    end
  endtask

  // ------------------------------------------------------------ RAM as the ROM leaves it
  function [7:0] ram_byte(input [31:0] a);
    reg [15:0] w;
    begin
      w = `MEM[{a[20:2], 1'b0} + a[1]];
      ram_byte = a[0] ? w[7:0] : w[15:8];
    end
  endfunction

  // ------------------------------------------------------------ reading a side
  integer    got [0:11];
  integer    side_bad_hdr, side_bad_data, side_errs, side_secs;
  time       side_time;
  integer    tot_secs = 0, tot_bad_hdr = 0, tot_bad_data = 0, tot_errs = 0, max_revs_x100 = 0, revs_x100;
  integer    grp_secs [0:4];
  integer    err_seen [0:255];
  task read_side(input integer c, input integer s, input integer ds, input [7:0] want_fmt);
    integer k, i, n, tries, mism;
    time    t0, limit;
    reg [7:0] v;
    begin
      for (k = 0; k < 12; k = k + 1) got[k] = 0;
      side_bad_hdr = 0; side_bad_data = 0; side_errs = 0; side_secs = 0;
      t0 = $time;
      limit = 3 * revcells(c) * 32 * 64;                 // three revolutions, in ns (a cell is 32 FCLK of 63.8 ns)
      tries = 0;
      while (side_secs < spt(c) && $time - t0 < limit) begin
        rd_addr(s); tries = tries + 1;
        if (err != 0 && side_errs < 4) begin
          $fdisplay(pf, "     c%0d s%0d RdAddr $%0h at %0d us (hung %0d)", c, s, err, $time / 1000, hung); $fflush(pf);
          dump_ring;
        end
        if (err == 0 && (h_cyl != c || h_side[5] != s || h_fmt != want_fmt) && side_bad_hdr < 4) begin
          $fdisplay(pf, "     c%0d s%0d header cyl %0d side %0h fmt %0h sec %0d", c, s, h_cyl, h_side, h_fmt, h_sec); $fflush(pf);
        end
        if (err != 0) begin side_errs = side_errs + 1; err_seen[err] = err_seen[err] + 1; end
        else if (h_cyl != c || h_side[5] != s || h_fmt != want_fmt || h_sec >= spt(c)) side_bad_hdr = side_bad_hdr + 1;
        else if (!got[h_sec]) begin
          k = h_sec;
          cpu(60);                                       // the caller between the two (the sector is wanted)
          rd_data(BUF + 512 * k);
          if (err != 0 && side_errs < 4) begin
            $fdisplay(pf, "     c%0d s%0d sector %0d RdData $%0h", c, s, k, err); $fflush(pf);
            dump_ring;
          end
          if (err != 0) begin side_errs = side_errs + 1; err_seen[err] = err_seen[err] + 1; end
          else begin
            cpu(8);                                      // the last write lands
            n = blockno(c, s, k, ds); mism = 0;
            if (ram_byte(TAGS) != k) mism = mism + 1;
            for (i = 0; i < 12; i = i + 1) begin
              v = (img_tagoff[drv] >= 0) ? fb(drv, img_tagoff[drv] + 12 * n + i) : 8'h00;
              if (ram_byte(TAGS + 1 + i) !== v) mism = mism + 1;
            end
            got[k] = 1; side_secs = side_secs + 1;
            if (mism != 0) side_bad_data = side_bad_data + 1;
          end
        end
      end
      side_time = $time - t0;
      // the data, as the ROM left it in the buffers
      for (k = 0; k < spt(c); k = k + 1) if (got[k]) begin
        n = blockno(c, s, k, ds); mism = 0;
        for (i = 0; i < 512; i = i + 1) if (ram_byte(BUF + 512 * k + i) !== fb(drv, img_off[drv] + 512 * n + i)) mism = mism + 1;
        if (mism != 0) side_bad_data = side_bad_data + 1;
      end
    end
  endtask

  // ------------------------------------------------------------ mounting
  // mount_start: the slot's mount pulse only (the load runs on); mount: and
  // wait for it
  task mount_start(input integer w, input integer size);
    begin
      @(posedge clk); #1 img_size = size; img_readonly = 0;
      if (w) img_mounted2 = 1; else img_mounted = 1;
      @(posedge clk); #1 img_mounted = 0; img_mounted2 = 0; img_size = 64'hDEAD;
      repeat (4) @(posedge clk);
    end
  endtask
  task mount(input integer w, input integer size);
    begin
      mount_start(w, size);
      while (w ? loading2 : loading) @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------ the drive switch, a cylinder
  // select: the driver's drive for the next request - its enable and the
  // power-up check (the motor already on: no wait)
  task select(input integer w);
    begin drv = w; power_up; end
  endtask
  // read_cyl: the seek and both sides of cylinder c on the selected drive,
  // tallied (secs_d per drive)
  integer secs_d [0:1];
  integer cyl_ok;
  task read_cyl(input integer c, input integer ds, input [7:0] fmt);
    integer s;
    begin
      seek(c);
      cyl_ok = 1;
      if (seek_err != 0 || !seek_ok || cyl_drv != c) begin
        cyl_ok = 0; $display("     drive %0d cylinder %0d: seek error %0h, /READY %0d after %0d polls, head at %0d", drv + 1, c, seek_err, seek_ok, seek_polls, cyl_drv);
      end
      for (s = 0; s < 2; s = s + 1) begin
        read_side(c, s, ds, fmt);
        tot_secs = tot_secs + side_secs; tot_bad_hdr = tot_bad_hdr + side_bad_hdr;
        tot_bad_data = tot_bad_data + side_bad_data; tot_errs = tot_errs + side_errs;
        secs_d[drv] = secs_d[drv] + side_secs - side_bad_data;
        grp_secs[c / 16] = grp_secs[c / 16] + side_secs - side_bad_data;
        revs_x100 = side_time * 100 / (revcells(c) * 32 * 64);
        if (revs_x100 > max_revs_x100) max_revs_x100 = revs_x100;
        if (side_secs != spt(c) || side_bad_hdr != 0 || side_bad_data != 0 || side_errs != 0)
          $display("     drive %0d cylinder %0d side %0d: %0d of %0d sectors, %0d bad headers, %0d bad data, %0d errors",
                   drv + 1, c, s, side_secs, spt(c), side_bad_hdr, side_bad_data, side_errs);
      end
    end
  endtask

  // ------------------------------------------------------------ the run
  integer i, c, s, k, n, fd, r, quick, ok, e, list_n, w;
  integer cyls [0:79];
  reg [7:0] romimg [0:262143];
  reg [8*200-1:0] rompath;
  reg [8*96-1:0] line;

  initial begin
    for (i = 0; i < 256; i = i + 1) err_seen[i] = 0;
    for (i = 0; i < 5; i = i + 1) grp_secs[i] = 0;
    step_polls_max = 0;
    pf = $fopen("prog.txt", "w");
    quick = $test$plusargs("quick");
    if (!$value$plusargs("rom=%s", rompath)) rompath = "C:/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM";

    // the ROM, into SDRAM where the machine keeps it (word $400000)
    fd = $fopen(rompath, "rb");
    if (fd == 0) begin $display("FAIL the ROM file is not there: %0s", rompath); $finish; end
    r = $fread(romimg, fd, 0, 262144); $fclose(fd);
    check(r == 262144 && {romimg[0], romimg[1], romimg[2], romimg[3]} == 32'h97221136,
          "the ROM is the 97221136 image", r, 262144);
    for (i = 0; i < 131072; i = i + 1) `MEM[24'h400000 + i] = {romimg[2 * i], romimg[2 * i + 1]};

    repeat (10) @(posedge clk); #1 reset_n = 1;
    while (!sd_ready) @(posedge clk);
    progress("SDRAM ready");

    // ---- 1. the start-up's VIA1 set-up, then Open: the probe, both drives
    $display("---- 1. Open: the SWIM probe and both drives' reads");
    wrb(ORA, 8'h01); wrb(DDRA, 8'h3F);                   // $4080009A: ORA $01, DDRA $3F (PA5 an output)
    swim_probe;
    check(found_swim, "Open's probe finds a SWIM: the ISM switch and three phase echoes ($134 set)", found_swim, 1);
    check(swim_double == 0, "every SWIM bus cycle is one chip access (the strobe's one C16M)", swim_double, 0);
    for (w = 0; w < 2; w = w + 1) begin
      drv = w; cpu(T_R); drv_enable;
      drv_read(4'hD); $sformat(line, "Open: drive %0d is there ($D)", w + 1); check(sns == 0, line, sns, 0);
      drv_read(4'h9); $sformat(line, "Open: drive %0d double-sided ($9)", w + 1); check(sns == 1, line, sns, 1);
      drv_read(4'hF); flag13_d[w] = sns;
      drv_read(4'h5); $sformat(line, "Open: drive %0d a SuperDrive ($5)", w + 1); check(sns == 1, line, sns, 1);
      drv_read(4'h2); $sformat(line, "drive %0d: no disk yet ($2 reads 1)", w + 1); check(sns == 1, line, sns, 1);
    end

    // ---- 2. both images load at once
    $display("---- 2. both drives' images load at once: an 800K DiskCopy 4.2 with tags in each");
    build_dc42_800k(0); build_dc42_800k(1);
    mount_start(0, fsize); mount_start(1, fsize2);
    while (loading || loading2) @(posedge clk);
    progress("both 800K images loaded");
    check(disk_in && img_ds && img_tags && img_800k, "drive 1's disk is in: double-sided, 800K, tags", {disk_in, img_ds, img_tags, img_800k}, 15);
    check(disk2_in && img2_ds && img2_tags && img2_800k, "drive 2's disk is in: double-sided, 800K, tags", {disk2_in, img2_ds, img2_tags, img2_800k}, 15);
    check(ov_loads > 0 && sw_ld > 0, "the two loads ran at once, the port passing between the loaders", sw_ld, 1);
    for (w = 0; w < 2; w = w + 1) begin
      drv = w; cpu(T_R); drv_enable;
      drv_read(4'h2); $sformat(line, "drive %0d: the VBL task's $2 (/CSTIN) reads the disk in", w + 1); check(sns == 0, line, sns, 0);
    end

    // ---- 3. the recalibrate of each drive, with the ISM entry and the power-up
    $display("---- 3. each drive's recalibrate: the ISM entry, the mode loop, the power-up");
    for (w = 0; w < 2; w = w + 1) begin
      drv = w;
      recal;
      $sformat(line, "drive %0d recalibrated", w + 1); progress(line);
      $sformat(line, "drive %0d: the ISM entry's GCR path: the mode $17 loop exits", w + 1); check(ism_ok == 1, line, ism_ok, 1);
      $sformat(line, "drive %0d: the power-up: /READY within the ROM's polls", w + 1); check(pu_ok == 1, line, pu_polls, 1000);
      $sformat(line, "drive %0d: the recalibrate ends on /TK0 at cylinder 0", w + 1); check(recal_err == 0 && cyl_drv == 0, line, recal_err, 0);
    end

    // ---- 4. every cylinder of both drives, interleaved
    $display("---- 4. the ROM reads every sector of both drives, a cylinder of each in turn (%0s)", $test$plusargs("groups") ? "+groups: a cylinder of each group" :
             quick ? "+quick: both edges of each group" : "all 80 cylinders");
    if ($test$plusargs("groups")) begin
      cyls[0] = 0; cyls[1] = 16; cyls[2] = 32; cyls[3] = 48; cyls[4] = 64; list_n = 5;
    end else if (quick) begin
      cyls[0] = 0; cyls[1] = 15; cyls[2] = 16; cyls[3] = 31; cyls[4] = 32;
      cyls[5] = 47; cyls[6] = 48; cyls[7] = 63; cyls[8] = 64; cyls[9] = 79; list_n = 10;
    end else begin
      for (i = 0; i < 80; i = i + 1) cyls[i] = i; list_n = 80;
    end
    ok = 1; secs_d[0] = 0; secs_d[1] = 0;
    for (i = 0; i < list_n; i = i + 1) begin
      c = cyls[i];
      for (w = 0; w < 2; w = w + 1) begin
        select(w);
        read_cyl(c, 1, 8'h22);
        if (!cyl_ok) ok = 0;
      end
      $sformat(line, "cylinder %0d: %0d sectors so far, %0d bad, %0d errors, %0d bytes taken unread, %0d twice", c, tot_secs, tot_bad_data, tot_errs, unseen, twice);
      progress(line);
      if ($test$plusargs("stop0")) begin
        $display("---- the shortest SWIM access gap %0d C16M, the shortest between valid data reads %0d (15 or more cannot re-read a byte)", hit_gap, vr_gap);
        if (fails == 0) $display("==== PASS: %0d checks (stop0)", checks); else $display("==== FAIL: %0d failures, %0d checks (stop0)", fails, checks);
        progress("stop0"); $finish;
      end
    end
    check(ok, "every seek, both drives: /STEP handshakes, /READY within the ROM's polls, the head where asked", ok, 1);
    n = 0; for (i = 0; i < list_n; i = i + 1) n = n + 2 * spt(cyls[i]);
    check(secs_d[0] == n, "drive 1: every sector read back byte for byte (tags at $2FC, data in RAM)", secs_d[0], n);
    check(secs_d[1] == n, "drive 2: every sector read back byte for byte - its own image, not drive 1's", secs_d[1], n);
    check(tot_secs == 2 * n && tot_bad_data == 0, "both drives: no sector read wrong", tot_secs - tot_bad_data, 2 * n);
    for (e = 0; e < 5; e = e + 1) begin
      n = 0; for (i = 0; i < list_n; i = i + 1) if (cyls[i] / 16 == e) n = n + 4 * spt(cyls[i]);
      $sformat(line, "speed group %0d (%0d sectors a side): every sector of both drives", e + 1, 12 - e);
      check(grp_secs[e] == n, line, grp_secs[e], n);
    end
    check(tot_bad_hdr == 0, "every address field: cylinder, side and format $22 as laid", tot_bad_hdr, 0);
    check(tot_errs == 0, "no error code from RdAddr or RdData", tot_errs, 0);
    for (i = 0; i < 256; i = i + 1) if (err_seen[i] != 0) $display("     error $%0h seen %0d times", i, err_seen[i]);
    check(max_revs_x100 <= 200, "each side read inside two revolutions (x100)", max_revs_x100, 200);
    check(step_polls_max <= 81, "/STEP read 1 within the seek's 81 polls", step_polls_max, 81);

    // ---- 4b. a load while the other drive reads
    $display("---- 4b. drive 2 loads a raw 400K image while the ROM reads drive 1");
    build_raw_400k(1);
    mount_start(1, fsize2);
    tot_secs = 0; tot_bad_data = 0; tot_errs = 0; tot_bad_hdr = 0; n = 0; ok = 1; secs_d[0] = 0; sw_ld_en = 0;
    for (i = 0; i < 3 && (loading2 || i == 0); i = i + 1) begin
      c = (i == 0) ? 8 : (i == 1) ? 24 : 40;
      select(0); read_cyl(c, 1, 8'h22); if (!cyl_ok) ok = 0;
      n = n + 2 * spt(c);
    end
    while (loading2) @(posedge clk);
    check(ok && secs_d[0] == n && tot_bad_data == 0 && tot_errs == 0 && tot_bad_hdr == 0,
          "drive 1 reads byte for byte while drive 2's image loads", secs_d[0], n);
    check(sw_ld_en > 0, "the port passed between drive 1's encoder and drive 2's loader", sw_ld_en, 1);
    check(disk2_in && !img2_ds && !img2_800k, "drive 2's 400K disk is in, single-sided", {disk2_in, img2_ds, img2_800k}, 4);

    if ($test$plusargs("no56")) $display("---- 5, 6. (+no56: skipped)");
    else begin : parts56
    // ---- 5. raw 400K images: single-sided, on each drive
    $display("---- 5. raw 400K images: side 0 reads, side 1 has no flux - drive 2's, then drive 1's");
    build_raw_400k(0);
    mount(0, fsize);
    check(disk_in && !img_ds && !img_800k, "drive 1's 400K disk is in, single-sided", {disk_in, img_ds, img_800k}, 4);
    for (w = 1; w >= 0; w = w - 1) begin
      tot_secs = 0; tot_bad_data = 0; tot_errs = 0; tot_bad_hdr = 0; n = 0; ok = 0;
      for (i = 0; i < 6; i = i + 1) begin
        c = (i == 5) ? 79 : 16 * i;
        select(w); seek(c);
        read_side(c, 0, 0, 8'h02);
        n = n + spt(c); tot_secs = tot_secs + side_secs; tot_bad_data = tot_bad_data + side_bad_data;
        tot_errs = tot_errs + side_errs; tot_bad_hdr = tot_bad_hdr + side_bad_hdr;
        rd_addr(1); if (err == 8'hBE) ok = ok + 1;
      end
      $sformat(line, "drive %0d's 400K: side 0 of a cylinder in every group, format $02, byte for byte", w + 1);
      check(tot_secs == n && tot_bad_data == 0 && tot_bad_hdr == 0 && tot_errs == 0, line, tot_secs - tot_bad_data, n);
      $sformat(line, "drive %0d's 400K: side 1 has no flux - RdAddr returns noNybErr ($BE)", w + 1);
      check(ok == 6, line, ok, 6);
    end

    // ---- 6. Daniel's Disk605.dsk (a smoke test), in drive 1
    fd = $fopen("C:/temp/Mac/SE30/Disk605.dsk", "rb");
    if (fd != 0) begin
      $display("---- 6. Disk605.dsk in drive 1: cylinders 0, 1, 40 and 79 against the file");
      fsize = $fread(file, fd, 0, MAXF); $fclose(fd);
      img_kind[0] = 2; img_off[0] = 0; img_tagoff[0] = -1;
      mount(0, fsize);
      tot_secs = 0; tot_bad_data = 0; tot_errs = 0; tot_bad_hdr = 0; n = 0;
      for (i = 0; i < 4; i = i + 1) begin
        c = (i == 0) ? 0 : (i == 1) ? 1 : (i == 2) ? 40 : 79;
        select(0); seek(c);
        for (s = 0; s < (img_ds ? 2 : 1); s = s + 1) begin
          read_side(c, s, img_ds, img_ds ? 8'h22 : 8'h02);
          n = n + spt(c); tot_secs = tot_secs + side_secs; tot_bad_data = tot_bad_data + side_bad_data;
          tot_errs = tot_errs + side_errs; tot_bad_hdr = tot_bad_hdr + side_bad_hdr;
        end
      end
      check(disk_in && tot_secs == n && tot_bad_data == 0 && tot_bad_hdr == 0 && tot_errs == 0,
            "Disk605.dsk: the sectors read back as the file holds them", tot_secs - tot_bad_data, n);
    end else $display("---- 6. (Disk605.dsk not present: skipped)");
    end

    // ---- 7. the machinery
    $display("---- 7. the port, the chip model, the bus");
    check(torn == 0 && moved == 0 && early == 0, "the disk port: no request torn, moved or raised over a stale acknowledge",
          torn + moved + early, 0);
`ifndef BEHAV_MEM
    check(chip.errors == 0, "the SDRAM model: no datasheet violation", chip.errors, 0);
`endif
    check(twice == 0, "no byte taken twice by the ROM's data-register reads", twice, 0);
    $display("     %0d valid reads re-armed a pending clear (the drive addressing's latch accesses: the chip's documented behaviour)", reread);
    check(unseen == 0, "every byte the ROM took was a valid read at the chip (its clear follows)", unseen, 0);
    check(swim_double == 0, "every SWIM bus cycle one chip access, the whole run", swim_double, 0);
    check(both_en == 0, "the two drives never enabled at once", both_en, 0);
    check(idle_rd == 0, "a drive not enabled never pulls RD low", idle_rd, 0);
    $display("     the port's words: drive 1's loader %0d, encoder %0d; drive 2's loader %0d, encoder %0d", dk_by[0], dk_by[1], dk_by[2], dk_by[3]);
    check(hung == 0 && bus_timeouts == 0, "no poll or bus cycle hung", hung + bus_timeouts, 0);
    $display("     %0d SWIM cycles, %0d disk-port words, %0t ns simulated", swim_cycles, dk_words, $time);

    $display("---- the shortest SWIM access gap %0d C16M, the shortest between valid data reads %0d (15 or more cannot re-read a byte)", hit_gap, vr_gap);
    if (fails == 0) $display("==== PASS: %0d checks", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    progress("done");
    $finish;
  end

endmodule
