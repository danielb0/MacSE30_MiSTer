// se30_asc.v - the Apple Sound Chip (344S0063): a 2 KB buffer as two 1 KB FIFOs or four 512-byte
// wavetables, $804's latched FIFO events (SNDINT*), playback at 22,254.5 Hz to signed 16-bit PCM.

`timescale 1ns/1ps

module se30_asc (
  input             clk,
  input             c16_en,              // C16M
  input             reset_n,             // RESET*
  input             sel,
  input             strobe,
  input             rw,                  // 1 = read
  input      [11:0] addr,                // A11-A0
  input       [7:0] wdata,
  output      [7:0] rdata,
  output            irq_n,               // SNDINT*, to VIA2 CB1
  output reg [15:0] audio_l,             // signed PCM, after the volume
  output reg [15:0] audio_r,
  output     [31:0] dbg                  // PASC: {mode, $804, count A, count B, interrupts raised}
);

  // ------------------------------------------------------------ registers
  reg  [1:0] mode;                       // $801
  reg  [7:0] r802, r803, r805, r806, r807, r80x [8:15];   // $808-$80F
  reg  [3:0] st;                         // $804
  reg [31:0] ph [0:3], inc [0:3];        // $810+8n, $814+8n
  reg  [7:0] lvl [0:7];                  // $830-$837
  wire       stereo = r802[1];

  // ------------------------------------------------------------ the buffer
  reg  [7:0] ram [0:2047];
  reg [10:0] a_addr;
  reg        a_we;
  reg  [7:0] a_q, b_q;
  reg [10:0] b_addr;
  always @(posedge clk) begin
    if (a_we) ram[a_addr] <= wdata;
    a_q <= ram[a_addr];
  end
  always @(posedge clk) b_q <= ram[b_addr];

  // ------------------------------------------------------------ the FIFOs
  reg  [9:0] wp [0:1], rp [0:1];
  reg [10:0] cnt [0:1];

  wire acc   = c16_en && sel && strobe;
  wire wr    = acc && !rw;
  wire rd    = acc &&  rw;
  wire isbuf = (addr[11] == 1'b0);
  wire fch   = addr[10];                 // which FIFO a buffer access names
  wire push  = wr && isbuf && mode == 2'd1;

  // port A: the CPU (FIFO mode: the FIFO's write pointer; otherwise the address)
  always @* begin
    a_addr = (mode == 2'd1 && !rw) ? {fch, wp[fch]} : addr[10:0];
    a_we   = wr && isbuf && (mode != 2'd1 || cnt[fch] != 11'd1024);
  end

  // ------------------------------------------------------------ the sample tick
  reg  [9:0] div  = 10'd0;
  reg [23:0] facc = 24'd0;
  reg        tick = 1'b0;
  wire [23:0] fstep = (r807[1:0] == 2'd3) ? 24'd44100 : 24'd22050;
  always @(posedge clk) begin
    tick <= 1'b0;
    if (c16_en) begin
      if (r807[1:0] == 2'd3 || r807[1:0] == 2'd2) begin
        if (facc + fstep >= 24'd15667200) begin facc <= facc + fstep - 24'd15667200; tick <= 1'b1; end
        else facc <= facc + fstep;
      end else begin
        if (div == 10'd703) begin div <= 10'd0; tick <= 1'b1; end
        else div <= div + 10'd1;
      end
    end
  end

  // ------------------------------------------------------------ the sequencer
  // each sample tick reads the FIFOs or steps the four voices through port B, then mixes
  reg  [2:0] step;
  reg  [7:0] out_l, out_r, last_a, last_b;
  reg  [9:0] sum_l, sum_r;
  reg        pop_a, pop_b;
  reg  [1:0] v;                          // the next voice to step
  wire [1:0] vs  = (step == 3'd0) ? 2'd0 : v;
  wire [23:0] nph = ph[vs][23:0] + inc[vs][23:0];   // the one adder

  function [7:0] sat (input [9:0] s); sat = (s > 10'd255) ? 8'hFF : s[7:0]; endfunction

  // ------------------------------------------------------------ the one process
  reg  [3:0] st_n;
  reg [10:0] c0, c1;
  reg  [3:0] events;                     // interrupts raised (PASC), wrapping
  reg        irq_q;
  integer    i;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      mode <= 2'd0; r802 <= 8'h00; r803 <= 8'h00; r805 <= 8'h00; r806 <= 8'h00; r807 <= 8'h00;
      for (i = 8; i < 16; i = i + 1) r80x[i] <= 8'h00;
      st <= 4'h0;
      for (i = 0; i < 4; i = i + 1) begin ph[i] <= 32'd0; inc[i] <= 32'd0; end
      for (i = 0; i < 8; i = i + 1) lvl[i] <= 8'h00;
      wp[0] <= 10'd0; wp[1] <= 10'd0; rp[0] <= 10'd0; rp[1] <= 10'd0;
      cnt[0] <= 11'd0; cnt[1] <= 11'd0;
      step <= 3'd0; out_l <= 8'h80; out_r <= 8'h80; last_a <= 8'h80; last_b <= 8'h80;
      sum_l <= 10'd0; sum_r <= 10'd0; v <= 2'd0; b_addr <= 11'd0;
      events <= 4'd0; irq_q <= 1'b0;
    end else begin
      st_n = st;
      c0 = cnt[0]; c1 = cnt[1];
      pop_a = 1'b0; pop_b = 1'b0;

      // ---- playback
      if (tick && mode != 2'd0 && step == 3'd0) begin
        step <= 3'd1; sum_l <= 10'd0; sum_r <= 10'd0;
        if (mode == 2'd1) b_addr <= {1'b0, rp[0]};
        else begin                                                 // voice 0: step, then read at the new phase
          b_addr <= {2'd0, nph[23:15]}; ph[0][23:0] <= nph; v <= 2'd1;
        end
      end else if (step != 3'd0) begin
        if (mode == 2'd1) begin
          case (step)
            3'd1: begin b_addr <= {1'b1, rp[1]}; step <= 3'd2; end
            3'd2: begin                                            // A's byte
                    if (cnt[0] != 11'd0) begin last_a <= b_q; out_l <= b_q; pop_a = 1'b1; end
                    else out_l <= last_a;
                    step <= 3'd3;
                  end
            default: begin                                         // B's byte; mono plays A on both
                    if (stereo) begin
                      if (cnt[1] != 11'd0) begin last_b <= b_q; out_r <= b_q; pop_b = 1'b1; end
                      else out_r <= last_b;
                    end else out_r <= out_l;
                    step <= 3'd0;
                  end
          endcase
        end else if (mode == 2'd2) begin
          if (step >= 3'd2 && step <= 3'd5) begin                  // voice step-2's byte
            if (!stereo || step <= 3'd3) sum_l <= sum_l + {2'b00, b_q};
            else                         sum_r <= sum_r + {2'b00, b_q};
          end
          if (step <= 3'd3) begin                                  // voices 1-3
            b_addr <= {v, nph[23:15]}; ph[v][23:0] <= nph; v <= v + 2'd1;
          end
          if (step == 3'd6) begin
            out_l <= sat(sum_l);
            out_r <= stereo ? sat(sum_r) : sat(sum_l);
            step <= 3'd0;
          end else step <= step + 3'd1;
        end else step <= 3'd0;
      end

      // ---- the FIFOs: a pop, then the status it makes
      if (pop_a) begin rp[0] <= rp[0] + 10'd1; if (c0 == 11'd511) st_n[0] = 1'b1; c0 = c0 - 11'd1; end
      if (pop_b) begin rp[1] <= rp[1] + 10'd1; if (c1 == 11'd511) st_n[2] = 1'b1; c1 = c1 - 11'd1; end

      // ---- the CPU
      if (rd && !isbuf && addr[11:0] == 12'h804) st_n = 4'h0;     // read: hand over, then clear
      // (the drop is decided on the registered count, as port A's write is)
      if (push) begin
        if (!fch) begin
          if (cnt[0] == 11'd1024) st_n[1] = 1'b1;                  // full: dropped, flagged again
          else begin
            wp[0] <= wp[0] + 10'd1; c0 = c0 + 11'd1;
            if (c0 >= 11'd512) st_n[0] = 1'b0;
            if (c0 >= 11'd1023) st_n[1] = 1'b1;
          end
        end else begin
          if (cnt[1] == 11'd1024) st_n[3] = 1'b1;
          else begin
            wp[1] <= wp[1] + 10'd1; c1 = c1 + 11'd1;
            if (c1 >= 11'd512) st_n[2] = 1'b0;
            if (c1 >= 11'd1023) st_n[3] = 1'b1;
          end
        end
      end
      if (wr && !isbuf) begin
        casez (addr[11:0])
          12'h801: begin
                     if (wdata[1:0] != mode) begin                 // a change of mode empties the FIFOs
                       wp[0] <= 10'd0; wp[1] <= 10'd0; rp[0] <= 10'd0; rp[1] <= 10'd0;
                       c0 = 11'd0; c1 = 11'd0;
                     end
                     mode <= wdata[1:0];
                   end
          12'h802: r802 <= wdata;
          12'h803: begin
                     r803 <= wdata;
                     if (wdata[7]) begin                           // clear (M: sets the full bits)
                       wp[0] <= 10'd0; wp[1] <= 10'd0; rp[0] <= 10'd0; rp[1] <= 10'd0;
                       c0 = 11'd0; c1 = 11'd0; st_n = st_n | 4'b1010;
                     end
                   end
          12'h804: st_n = st_n | wdata[3:0];
          12'h805: r805 <= wdata;
          12'h806: r806 <= wdata;
          12'h807: r807 <= wdata;
          12'b1000_0000_1???: r80x[addr[3:0]] <= wdata;
          12'b1000_0001_????, 12'b1000_0010_????: begin                // $810-$82F
                     case (addr[1:0])
                       2'd0: if (addr[2]) inc[addr[4:3] ^ 2'd2][31:24] <= wdata; else ph[addr[4:3] ^ 2'd2][31:24] <= wdata;
                       2'd1: if (addr[2]) inc[addr[4:3] ^ 2'd2][23:16] <= wdata; else ph[addr[4:3] ^ 2'd2][23:16] <= wdata;
                       2'd2: if (addr[2]) inc[addr[4:3] ^ 2'd2][15:8]  <= wdata; else ph[addr[4:3] ^ 2'd2][15:8]  <= wdata;
                       default: if (addr[2]) inc[addr[4:3] ^ 2'd2][7:0] <= wdata; else ph[addr[4:3] ^ 2'd2][7:0] <= wdata;
                     endcase
                   end
          12'b1000_0011_0???: lvl[addr[2:0]] <= wdata;                 // $830-$837
          default: ;
        endcase
      end

      cnt[0] <= c0; cnt[1] <= c1;
      st <= st_n;
      irq_q <= (st_n != 4'h0);
      if (st_n != 4'h0 && st == 4'h0) events <= events + 4'd1;
    end
  end

  // the voice registers' index: $810 is voice 0 - addr[4:3] counts 2,3,0,1
  // over $810-$82F (addr[5:3] = 010..101), so voice = addr[5:3] - 2
  function [7:0] vreg (input [11:0] a);
    reg [1:0] n; reg [31:0] w;
    begin
      n = a[5:3] - 3'd2;
      w = a[2] ? inc[n] : ph[n];
      case (a[1:0]) 2'd0: vreg = w[31:24]; 2'd1: vreg = w[23:16]; 2'd2: vreg = w[15:8]; default: vreg = w[7:0]; endcase
    end
  endfunction

  assign rdata = isbuf               ? a_q :
                 addr == 12'h800     ? 8'h00 :
                 addr == 12'h801     ? {6'd0, mode} :
                 addr == 12'h802     ? {1'b0, r802[6:0]} :
                 addr == 12'h803     ? r803 :
                 addr == 12'h804     ? {4'd0, st} :
                 addr == 12'h805     ? r805 :
                 addr == 12'h806     ? r806 :
                 addr == 12'h807     ? r807 :
                 addr[11:3] == 9'h101 ? r80x[addr[3:0]] :
                 (addr >= 12'h810 && addr <= 12'h82F) ? vreg(addr) :
                 addr[11:3] == 9'h106 ? lvl[addr[2:0]] : 8'h00;
  assign irq_n = !irq_q;

  // ------------------------------------------------------------ out: (sample - $80) x volume
  wire signed [8:0]  sl = {1'b0, out_l} - 9'sd128;
  wire signed [8:0]  sr = {1'b0, out_r} - 9'sd128;
  wire        [8:0]  k  = {6'd0, r806[7:5]} * 9'd36;              // 0..252: 127 x 252 = 32,004 at full volume
  wire signed [18:0] pl = sl * $signed({1'b0, k});
  wire signed [18:0] pr = sr * $signed({1'b0, k});
  always @(posedge clk) begin
    audio_l <= pl[15:0];
    audio_r <= pr[15:0];
  end

  assign dbg = {mode, st, cnt[0], cnt[1], events};

endmodule
