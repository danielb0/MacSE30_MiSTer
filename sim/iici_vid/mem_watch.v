// mem_watch.v - beside tb_iici_machine (another top): where a memory cycle's
// time goes (the IIxx's memory-latency work, SE30_PLAN.md "THE IIxx").
//   - every RAM / ROM cycle's AS* low, in clk_sys clocks (two a CPU clock),
//     by kind: RAM read, RAM burst, RAM write, ROM read
//   - the SDRAM's CPU ACTIVEs: how many name the row last opened in their
//     chip bank (a refresh closes them all) - the hits an open-row
//     controller would have - and how long requests waited for the chip
`timescale 1ns/1ps
module mem_watch;
  wire clk  = tb_iici_machine.clk_sys;
  wire as_n = tb_iici_machine.machine.cpu_as_n;
  reg  as_q = 1;
  reg  [1:0] kind = 0;                          // 0 RAM read, 1 burst, 2 write, 3 ROM
  reg        mem = 0;
  integer alow = 0, i, k;
  integer hn [0:3], hsum [0:3], hist [0:3][0:31];
  initial for (k = 0; k < 4; k = k + 1) begin hn[k] = 0; hsum[k] = 0; for (i = 0; i < 32; i = i + 1) hist[k][i] = 0; end
  always @(posedge clk) begin
    as_q <= as_n;
    if (!as_n) begin
      if (as_q) begin
        alow = 0;
        mem  = tb_iici_machine.machine.mdu.d_mem;
        kind = tb_iici_machine.machine.mdu.d_rom ? 2'd3 : !tb_iici_machine.machine.cpu_rw_n ? 2'd2 :
               tb_iici_machine.machine.mdu.burst_ok ? 2'd1 : 2'd0;
      end
      alow = alow + 1;
    end else if (!as_q && mem) begin
      hn[kind] = hn[kind] + 1; hsum[kind] = hsum[kind] + alow;
      hist[kind][(alow > 31) ? 31 : alow] = hist[kind][(alow > 31) ? 31 : alow] + 1;
    end
  end

  // the SDRAM: rows as an open-row controller would hold them (the CPU's and the video's ACTIVEs open,
  // a refresh closes all)
  wire sclk = tb_iici_machine.g_sd.sdram.clk;
  reg  [12:0] row [0:7];
  reg   [7:0] open_r = 0;
  integer act = 0, hit = 0, vact = 0, vhit = 0, wt = 0, wsum = 0, ref_n = 0, conf = 0;
  // the same with the chip banks interleaved by 1 KB page (long address bits 9-8; the ROM four banks of its own)
  reg  [14:0] row2 [0:7];
  reg   [7:0] open2 = 0;
  integer hit2 = 0, conf2 = 0, vhit2 = 0;
  wire [24:0] qa = tb_iici_machine.g_sd.sdram.q_addr;
  wire [24:0] va = tb_iici_machine.g_sd.sdram.xv_addr;
  wire [2:0] cb2 = {qa[24:21] == 4'b0011, qa[9:8]};
  wire [2:0] vb2 = {va[24:21] == 4'b0011, va[9:8]};
  wire [2:0] cb = {tb_iici_machine.g_sd.sdram.a_word[25], tb_iici_machine.g_sd.sdram.a_word[23:22]};
  wire [2:0] vbk = {tb_iici_machine.g_sd.sdram.o_chip, tb_iici_machine.g_sd.sdram.o_ba};
  always @(posedge sclk) begin
    if (tb_iici_machine.g_sd.sdram.m_pend && tb_iici_machine.g_sd.sdram.state == 4'd1) wsum = wsum + 1;
    if (tb_iici_machine.g_sd.sdram.state == 4'd1 && tb_iici_machine.g_sd.sdram.busy_z) begin
      if (tb_iici_machine.g_sd.sdram.c_go) begin
        act = act + 1;
        if (open_r[cb] && row[cb] == tb_iici_machine.g_sd.sdram.a_word[21:9]) hit = hit + 1;
        else if (open_r[cb]) conf = conf + 1;
        open_r[cb] <= 1; row[cb] <= tb_iici_machine.g_sd.sdram.a_word[21:9];
        if (open2[cb2] && row2[cb2] == qa[24:10]) hit2 = hit2 + 1; else if (open2[cb2]) conf2 = conf2 + 1;
        open2[cb2] <= 1; row2[cb2] <= qa[24:10];
      end else if (tb_iici_machine.g_sd.sdram.o_kind == 3'd1) begin
        ref_n = ref_n + 1; open_r <= 0; open2 <= 0;
      end else if (tb_iici_machine.g_sd.sdram.o_kind == 3'd2) begin
        vact = vact + 1;
        if (open_r[vbk] && row[vbk] == tb_iici_machine.g_sd.sdram.o_row) vhit = vhit + 1;
        open_r[vbk] <= 1; row[vbk] <= tb_iici_machine.g_sd.sdram.o_row;
        if (open2[vb2] && row2[vb2] == va[24:10]) vhit2 = vhit2 + 1;
        open2[vb2] <= 1; row2[vb2] <= va[24:10];
      end
    end
  end

  // two open-row policies, in CPU clocks against today's (a read hit -1, a conflict +1, a write hit 0):
  // P_A every CPU access leaves its row open; P_B only a burst does (singles and writes auto-precharge).
  // The video's ACTIVE closes the bank it opens (a conflict there is counted, its cost the video's); a refresh all.
  reg  [12:0] rowa [0:7], rowb [0:7];
  reg   [7:0] opa = 0, opb = 0;
  integer pa_save = 0, pa_cost = 0, pb_save = 0, pb_cost = 0, pa_v = 0, pb_v = 0;
  wire q_we = tb_iici_machine.g_sd.sdram.q_we, q_bu = tb_iici_machine.g_sd.sdram.q_burst;
  wire [12:0] q_row = tb_iici_machine.g_sd.sdram.a_word[21:9];
  always @(posedge sclk) if (tb_iici_machine.g_sd.sdram.state == 4'd1 && tb_iici_machine.g_sd.sdram.busy_z) begin
    if (tb_iici_machine.g_sd.sdram.c_go) begin
      if (opa[cb] && rowa[cb] == q_row) begin if (!q_we) pa_save = pa_save + 1; end
      else if (opa[cb]) pa_cost = pa_cost + 1;
      opa[cb] <= 1; rowa[cb] <= q_row;
      if (opb[cb] && rowb[cb] == q_row) begin if (!q_we) pb_save = pb_save + 1; end
      else if (opb[cb]) pb_cost = pb_cost + 1;
      opb[cb] <= !q_we && q_bu; rowb[cb] <= q_row;
    end else if (tb_iici_machine.g_sd.sdram.o_kind == 3'd1) begin opa <= 0; opb <= 0; end
    else if (tb_iici_machine.g_sd.sdram.o_kind == 3'd2) begin
      if (opa[vbk]) pa_v = pa_v + 1; if (opb[vbk]) pb_v = pb_v + 1;
      opa[vbk] <= 0; opb[vbk] <= 0;
    end
  end

  task report;
    begin
      $display("---- MEM: AS* low in clk_sys clocks (n, mean x10, histogram len:count)");
      for (k = 0; k < 4; k = k + 1) if (hn[k] != 0) begin
        $write("---- MEM %s n %0d mean10 %0d :", (k == 0) ? "RAM read " : (k == 1) ? "RAM burst" : (k == 2) ? "RAM write" : "ROM read ",
               hn[k], hsum[k] * 10 / hn[k]);
        for (i = 0; i < 32; i = i + 1) if (hist[k][i] != 0) $write(" %0d:%0d", i, hist[k][i]);
        $display("");
      end
      $display("---- MEM SDRAM: CPU ACTIVEs %0d, row hits %0d, other row open in the bank %0d; video ACTIVEs %0d (hits %0d); refreshes %0d; clocks a CPU request waited for the chip %0d",
               act, hit, conf, vact, vhit, ref_n, wsum);
      $display("---- MEM POLICY all-open: reads saved %0d CPU clocks, conflicts cost %0d; video precharges first %0d", pa_save, pa_cost, pa_v);
      $display("---- MEM POLICY bursts-open: reads saved %0d CPU clocks, conflicts cost %0d; video precharges first %0d", pb_save, pb_cost, pb_v);
      $display("---- MEM SDRAM interleaved by 1 KB: row hits %0d, other row open %0d; video hits %0d", hit2, conf2, vhit2);
    end
  endtask
  final report;
endmodule
