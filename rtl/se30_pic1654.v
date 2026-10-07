// se30_pic1654.v - the PIC1654S microcontroller inside the ADB transceiver

`timescale 1ns/1ps

module se30_pic1654 #(
  parameter [8:0] RESET_PC = 9'o777
) (
  input             clk,
  input             osc_en,
  input             mclr_n,
  output      [8:0] pm_addr,
  input      [11:0] pm_data,
  output reg  [3:0] ra_latch,
  input       [3:0] ra_pin,
  output reg  [7:0] rb_latch,
  input       [7:0] rb_pin,
  input             rtcc_pin,
  output     [63:0] dbg
);

  reg  [2:0] ph;
  reg  [8:0] pc;
  reg [11:0] ir;
  reg  [7:0] w;
  reg  [2:0] st;
  reg  [4:0] fsr;
  reg  [7:0] rtcc;
  reg  [8:0] stk1, stk2;
  reg  [7:0] ram [0:31];

  integer i;
  initial begin
    for (i = 0; i < 32; i = i + 1) ram[i] = 8'h00;
    ph = 0; pc = RESET_PC; ir = 0; w = 0; st = 0; fsr = 0; rtcc = 0;
    stk1 = 0; stk2 = 0; ra_latch = 4'hF; rb_latch = 8'hFF;
  end

  assign pm_addr = pc;

  wire tick = osc_en && ph == 3'd7;

  wire [4:0] f      = ir[4:0];
  wire       d      = ir[5];
  wire [3:0] op     = ir[9:6];
  wire [2:0] b      = ir[7:5];
  wire [7:0] k      = ir[7:0];
  wire       is_byte = ir[11:10] == 2'b00;
  wire       is_bit  = ir[11:10] == 2'b01;

  wire [4:0] ea = (f == 5'd0) ? fsr : f;

  reg [7:0] fv;
  always @* begin
    case (ea)
      5'd0:    fv = 8'h00;
      5'd1:    fv = rtcc;
      5'd2:    fv = pc[7:0];
      5'd3:    fv = {5'b11111, st};
      5'd4:    fv = {3'b111, fsr};
      5'd5:    fv = {4'h0, ra_pin};
      5'd6:    fv = rb_pin;
      default: fv = ram[ea];
    endcase
  end

  wire [8:0] add9  = {1'b0, fv} + {1'b0, w};
  wire [4:0] add5  = {1'b0, fv[3:0]} + {1'b0, w[3:0]};
  wire [8:0] sub9  = {1'b0, fv} + {1'b0, ~w} + 9'd1;
  wire [4:0] sub5  = {1'b0, fv[3:0]} + {1'b0, ~w[3:0]} + 5'd1;

  reg  [7:0] res;
  reg        wr_f;
  reg        wr_w;
  reg  [2:0] st_new;
  reg  [2:0] fmask;
  reg        skip;
  always @* begin
    res = fv; wr_f = 0; wr_w = 0; st_new = st; fmask = 3'b000; skip = 0;
    if (is_byte) begin
      wr_f = d; wr_w = !d;
      case (op)
        4'b0000: begin
          res = w; wr_f = d; wr_w = 0;
        end
        4'b0001: begin
          res = 8'h00; st_new[2] = 1; fmask = 3'b100;
        end
        4'b0010: begin
          res = sub9[7:0];
          st_new[0] = sub9[8]; st_new[1] = sub5[4]; st_new[2] = sub9[7:0] == 0;
          fmask = 3'b111;
        end
        4'b0011: begin res = fv - 8'd1;  st_new[2] = res == 0; fmask = 3'b100; end
        4'b0100: begin res = fv | w;     st_new[2] = res == 0; fmask = 3'b100; end
        4'b0101: begin res = fv & w;     st_new[2] = res == 0; fmask = 3'b100; end
        4'b0110: begin res = fv ^ w;     st_new[2] = res == 0; fmask = 3'b100; end
        4'b0111: begin
          res = add9[7:0];
          st_new[0] = add9[8]; st_new[1] = add5[4]; st_new[2] = add9[7:0] == 0;
          fmask = 3'b111;
        end
        4'b1000: begin res = fv;         st_new[2] = res == 0; fmask = 3'b100; end
        4'b1001: begin res = ~fv;        st_new[2] = res == 0; fmask = 3'b100; end
        4'b1010: begin res = fv + 8'd1;  st_new[2] = res == 0; fmask = 3'b100; end
        4'b1011: begin res = fv - 8'd1;  skip = res == 0; end
        4'b1100: begin res = {st[0], fv[7:1]}; st_new[0] = fv[0]; fmask = 3'b001; end
        4'b1101: begin res = {fv[6:0], st[0]}; st_new[0] = fv[7]; fmask = 3'b001; end
        4'b1110: begin res = {fv[3:0], fv[7:4]}; end
        4'b1111: begin res = fv + 8'd1;  skip = res == 0; end
      endcase
    end else if (is_bit) begin
      case (ir[9:8])
        2'b00: begin res = fv & ~(8'd1 << b); wr_f = 1; end
        2'b01: begin res = fv |  (8'd1 << b); wr_f = 1; end
        2'b10: skip = !fv[b];
        2'b11: skip =  fv[b];
      endcase
    end
  end

  reg rt_q = 1'b1;
  always @(posedge clk) rt_q <= rtcc_pin;
  wire rt_fall = rt_q && !rtcc_pin;

  wire rtcc_write = tick && (is_byte || is_bit) && wr_f && ea == 5'd1;

  always @(posedge clk) begin
    if (!mclr_n) begin
      ph <= 0; pc <= RESET_PC; ir <= 12'o0000;
      ra_latch <= 4'hF; rb_latch <= 8'hFF;
    end else begin
      if (osc_en) ph <= ph + 1'b1;
      if (tick) begin
        ir <= pm_data;
        pc <= pc + 1'b1;

        if (is_byte || is_bit) begin
          if (wr_w) w <= res;
          st <= st_new;
          if (wr_f) begin
            case (ea)
              5'd0: ;
              5'd1: ;
              5'd2: begin pc <= {1'b0, res}; ir <= 12'o0000; end
              5'd3: st <= (res[2:0] & ~fmask) | (st_new & fmask);
              5'd4: fsr <= res[4:0];
              5'd5: ra_latch <= res[3:0];
              5'd6: rb_latch <= res;
              default: ram[ea] <= res;
            endcase
          end
          if (skip) begin ir <= 12'o0000; pc <= pc + 1'b1; end
        end else begin
          case (ir[11:8])
            4'b1000: begin
              w <= k; pc <= stk1; stk1 <= stk2; ir <= 12'o0000;
            end
            4'b1001: begin
              stk2 <= stk1; stk1 <= pc; pc <= {1'b0, k}; ir <= 12'o0000;
            end
            4'b1010, 4'b1011: begin
              pc <= ir[8:0]; ir <= 12'o0000;
            end
            4'b1100: w <= k;
            4'b1101: begin w <= w | k; st[2] <= (w | k) == 0; end
            4'b1110: begin w <= w & k; st[2] <= (w & k) == 0; end
            4'b1111: begin w <= w ^ k; st[2] <= (w ^ k) == 0; end
          endcase
        end
      end
    end

    if (rtcc_write) rtcc <= res;
    else if (rt_fall) rtcc <= rtcc + 1'b1;
  end

  assign dbg = {pc, w, 5'b11111, st, 3'b111, fsr, rtcc, stk1, stk2, 5'd0};

endmodule
