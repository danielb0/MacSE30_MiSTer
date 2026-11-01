// tb_via_race.v - class 9 (SE30_PLAN.md, 2026-11-01): the 6523's interrupt
// flags against a CPU access at every point around their events.
//
// WHAT THIS PROVES
//   An interrupt event is never lost to an access, the bug class the Quadra
//   core met on the board (its VIA's IFR write dropped every event of its
//   clock: the ROM's VBL acknowledge, move.b #$02,vIFR, erased a Time
//   Manager T2 time-out, and Day of the Tentacle, DOOM II and Dracula
//   Unleashed hung).  For each event - T1 one-shot, T1 free-run, T2
//   one-shot, the shift register's completion (shift in under E), CA1, CA2,
//   CB1, CB2 - and each access - every register read and written, the
//   values neutral (the ACR and PCR rewritten unchanged, IER and the ports
//   as they are) or an IFR write clearing every OTHER bit:
//     - the timers and the shift register: the access lands on each E fall
//       from 3 before the event's to 3 after (an access lands on E's last
//       high clock, two clocks before the fall the timers move on, so the
//       two never share a clock - GLUE's timing, 2.13/4.8);
//     - CA1/CA2/CB1/CB2: the edge on each clock from 6 before the access's
//       landing clock to 6 after (asynchronous inputs: they can share it);
//   the flag must be set afterwards.  The event's OWN clears (the IFR bit,
//   T1C-L/T2C-L read, T1L-H write, the port access for CA/CB, the SR access)
//   must leave it set when they land before the event and clear it when they
//   land after; on the event's own clock (edges only) the result is printed,
//   not judged (the data sheet does not say).  A restart (T1C-H, T2C-H)
//   anywhere around the event must give a fresh count: the flag N+1 E falls
//   after the restart (items 3 and 5 of tb_se30_via.v).
//
//   ./run_race.sh   (Icarus, ~1 min; RACE_PLANT=1: a planted lost event must FAIL)

`timescale 1ns/1ps

module tb_via_race;

  reg clk = 0;
  always #31.9149 clk = ~clk;
  reg reset_n = 0;
  reg [4:0] ecnt = 0;
  always @(posedge clk) ecnt <= (ecnt == 19) ? 0 : ecnt + 1;
  wire e_clk = (ecnt >= 10);
  integer e_falls = 0, cyc = 0;
  always @(posedge clk) begin cyc = cyc + 1; if (ecnt == 19) e_falls = e_falls + 1; end

  reg        sel = 0, strobe = 0, rw = 1;
  reg  [3:0] rs = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata;
  wire       irq_n;
  reg        ca1 = 1, ca2 = 1, cb1 = 1, cb2 = 1;
  wire [7:0] pa_out, pa_oe, pb_out, pb_oe;
  wire       ca2o, ca2oe, cb1o, cb1oe, cb2o, cb2oe;
  se30_via via (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n), .e_clk(e_clk),
    .sel(sel), .strobe(strobe), .rs(rs), .rw(rw), .wdata(wdata), .rdata(rdata), .irq_n(irq_n),
    .pa_in(8'hFF), .pa_out(pa_out), .pa_oe(pa_oe), .pb_in(8'hFF), .pb_out(pb_out), .pb_oe(pb_oe),
    .ca1(ca1), .ca2_in(ca2), .ca2_out(ca2o), .ca2_oe(ca2oe),
    .cb1_in(cb1), .cb1_out(cb1o), .cb1_oe(cb1oe), .cb2_in(cb2), .cb2_out(cb2o), .cb2_oe(cb2oe));

  integer checks = 0, fails = 0, notes = 0;
  reg plant = 0;
  initial plant = $test$plusargs("RACE_PLANT");

  // one access, landing on the E fall after the next (the bench's bus: strobe
  // in E's last high clock); land_cyc = the clock it lands on
  integer land_cyc, land_fall;
  task access(input [3:0] r, input w, input [7:0] d);
    begin
      while (ecnt != 7) @(posedge clk);
      #1 rs = r; rw = !w; wdata = d; sel = 1;
      while (ecnt != 18) @(posedge clk);
      #1 strobe = 1;
      @(posedge clk);
      land_cyc = cyc; land_fall = e_falls;
      #1 strobe = 0; sel = 0; rw = 1;
    end
  endtask
  // wait until an access started now lands on E fall f
  task to_fall(input integer f); begin while (!(e_falls == f - 1 && ecnt == 0)) @(posedge clk); end endtask

  // the events: 0 T1 one-shot, 1 T1 free-run, 2 T2, 3 SR, 4 CA1, 5 CA2, 6 CB1, 7 CB2
  localparam NEV = 8, N = 12;
  reg [8*12-1:0] evname [0:NEV-1];
  integer evbit [0:NEV-1];
  initial begin
    evname[0] = "T1 one-shot"; evbit[0] = 6;  evname[1] = "T1 free-run"; evbit[1] = 6;
    evname[2] = "T2 one-shot"; evbit[2] = 5;  evname[3] = "SR in (E)";   evbit[3] = 2;
    evname[4] = "CA1";         evbit[4] = 1;  evname[5] = "CA2";         evbit[5] = 0;
    evname[6] = "CB1";         evbit[6] = 4;  evname[7] = "CB2";         evbit[7] = 3;
  end
  reg [7:0] acr_v, pcr_v;
  // reset, configure, and (timers, SR) start the event: arm_fall = the start's landing fall
  integer arm_fall;
  task setup(input integer ev);
    begin
      reset_n = 0; ca1 = 1; ca2 = 1; cb1 = 1; cb2 = 1; repeat (4) @(posedge clk); reset_n = 1;
      acr_v = (ev == 1) ? 8'h40 : (ev == 3) ? 8'h08 : 8'h00;   // T1 free-run; SR mode 010 (in under E)
      pcr_v = 8'h00;                                           // all four edges negative, CA2/CB2 interrupt inputs
      access(4'd11, 1, acr_v); access(4'd12, 1, pcr_v);
      access(4'd14, 1, 8'hFF);                                 // every interrupt enabled
      case (ev)
        0, 1: begin access(4'd4, 1, N); access(4'd5, 1, 8'h00); end
        2:    begin access(4'd8, 1, N); access(4'd9, 1, 8'h00); end
        3:    begin access(4'd10, 1, 8'h00); end               // an SR read starts the shift in
        default: ;
      endcase
      arm_fall = land_fall;
    end
  endtask
  function flag(input integer b); begin flag = via.ifr[b]; end endfunction

  // the event's fall, from a run with no access
  integer evfall [0:3];
  task measure(input integer ev);
    integer f;
    begin
      setup(ev);
      while (!flag(evbit[ev]) && e_falls - arm_fall < 400) @(posedge clk);
      evfall[ev] = e_falls - arm_fall;
      $display("---- %0s: the flag at fall +%0d after the start", evname[ev], evfall[ev]);
    end
  endtask

  // the access under test: its kind for this event (0 neutral, 1 own clear, 2 restart)
  reg [7:0] adata;
  integer akind;
  task pick(input integer ev, input [3:0] r, input w);
    integer b;
    begin
      b = evbit[ev]; akind = 0;
      adata = 8'h00;
      if (w) case (r)
        4'd11: adata = acr_v;
        4'd12: adata = pcr_v;
        4'd13: adata = 8'h7F & ~(8'h01 << b);                  // the IFR: every OTHER flag cleared
        4'd14: adata = 8'h80 | (8'h01 << b);                   // the IER: its own enable set again
        4'd4, 4'd6: adata = N;
        4'd8: adata = N;
        4'd10: adata = 8'h00;
        default: adata = 8'h00;
      endcase
      // own clears (R6522: IFR table) and restarts
      if ((ev <= 1) && ((!w && r == 4) || (w && r == 7))) akind = 1;
      if ((ev <= 1) && w && r == 5) akind = 2;
      if (ev == 2 && !w && r == 8) akind = 1;
      if (ev == 2 && w && r == 9) akind = 2;
      if (ev == 3 && r == 10) akind = 3;                       // an SR access restarts the shift: noted
      if ((ev == 4 || ev == 5) && r == 1) akind = 1;           // a port A access (register 15 does not clear)
      if ((ev == 6 || ev == 7) && r == 0) akind = 1;           // a port B access
    end
  endtask

  task judge(input [8*120-1:0] what, input cond);
    begin
      checks = checks + 1;
      if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end
    end
  endtask

  integer ev, r, w, o, c, f0, got, ef;
  reg [8*120-1:0] desc;
  initial begin
    repeat (4) @(posedge clk);
    for (ev = 0; ev < 4; ev = ev + 1) measure(ev);
    // ---- the timers and the shift register: the access at E falls -3..+3 around the event
    for (ev = 0; ev < 4; ev = ev + 1)
      for (r = 0; r < 16; r = r + 1)
        for (w = 0; w < 2; w = w + 1)
          for (o = -3; o <= 3; o = o + 1) begin
            pick(ev, r, w);
            setup(ev);
            ef = arm_fall + evfall[ev];
            to_fall(ef + o);
            access(r, w, adata);
            while (e_falls < ef + 3 || e_falls < land_fall + 3) @(posedge clk);   // past both
            if (plant && ev == 2 && r == 13 && w == 1 && o == 0) via.ifr[5] = 0;   // RACE_PLANT: the event lost
            $sformat(desc, "%0s, %0s reg %0d at fall %0d of the event: flag %0d", evname[ev], w ? "write" : "read", r, o, flag(evbit[ev]));
            if (akind == 0) judge(desc, flag(evbit[ev]) == 1);
            else if (akind == 1) judge(desc, flag(evbit[ev]) == (o <= 0 ? 1 : 0));   // fall 0: the access lands two clocks before the fall's edge - before the event
            else begin notes = notes + 1; $display("NOTE %0s (a restart or the SR's own restart: judged below or not at all)", desc); end
          end
    // ---- the restarts measured exactly: T1C-H / T2C-H at E falls -3..+3 around the event
    for (ev = 0; ev < 3; ev = ev + 1)
      for (o = -3; o <= 3; o = o + 1) begin
        setup(ev);
        ef = arm_fall + evfall[ev];
        to_fall(ef + o);
        access(ev == 2 ? 4'd9 : 4'd5, 1, 8'h00);              // the restart: count N (the latch)
        f0 = land_fall;
        while (e_falls < ef + 3) @(posedge clk);             // past the old event
        // clear whatever is set, then the restart's own flag
        if (flag(evbit[ev])) begin to_fall(e_falls + 2); access(4'd13, 1, 8'h01 << evbit[ev]); end
        while (!flag(evbit[ev]) && e_falls - f0 < 200) @(posedge clk);
        got = e_falls - f0;
        $sformat(desc, "%0s restart at fall %0d of the event: its flag %0d falls after it, want %0d", evname[ev], o, got, evfall[ev]);
        judge(desc, got == evfall[ev]);
      end
    // ---- the edges: each at clocks -6..+6 around an access's landing clock
    for (ev = 4; ev < 8; ev = ev + 1)
      for (r = 0; r < 16; r = r + 1)
        for (w = 0; w < 2; w = w + 1)
          for (c = -6; c <= 6; c = c + 1) begin
            pick(ev, r, w);
            setup(ev);
            to_fall(e_falls + 3);
            // the access lands on the 19th edge from now (ecnt 18 -> 19); an input that
            // changes after edge k sets its flag on edge k+1, so 18 + c puts the set on edge 19 + c
            fork
              access(r, w, adata);
              begin
                repeat (18 + c) @(posedge clk);
                #2 case (ev) 4: ca1 = 0; 5: ca2 = 0; 6: cb1 = 0; 7: cb2 = 0; endcase
              end
            join
            repeat (12) @(posedge clk);
            $sformat(desc, "%0s edge at clock %0d of a %0s of reg %0d: flag %0d", evname[ev], c, w ? "write" : "read", r, flag(evbit[ev]));
            if (akind == 0) judge(desc, flag(evbit[ev]) == 1);
            else if (c < 0) judge(desc, flag(evbit[ev]) == 0);        // set, then cleared by the access
            else if (c > 0) judge(desc, flag(evbit[ev]) == 1);        // cleared, then set
            else begin notes = notes + 1; $display("NOTE %0s (the same clock: not judged)", desc); end
          end
    if (fails == 0) $display("==== PASS: %0d checks, %0d same-clock own clears noted", checks, notes);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end
endmodule
