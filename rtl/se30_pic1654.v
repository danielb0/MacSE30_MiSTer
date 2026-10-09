// se30_pic1654.v - the PIC1654S, the CPU inside the ADB transceiver, to its data sheet: a 512 x 12
// program store (outside), a 32-byte register file, W, a two-level stack, RTCC and two ports.

`timescale 1ns/1ps

module se30_pic1654 #(
  parameter [8:0] RESET_PC = 9'o777
) (
  input             clk,
  input             osc_en,           // one clk per OSC1 period
  input             mclr_n,
  // the program store: pm_data is the word at pm_addr one clk later
  output      [8:0] pm_addr,
  input      [11:0] pm_data,
  // the ports
  output reg  [3:0] ra_latch,
  input       [3:0] ra_pin,
  output reg  [7:0] rb_latch,
  input       [7:0] rb_pin,
  input             rtcc_pin,
  // debug: {pc, w, status, fsr as read, rtcc, stack 1, stack 2}
  output     [63:0] dbg
);

  reg  [2:0] ph;                        // OSC1 period within the machine cycle
  reg  [8:0] pc;                        // the fetch address: the next instruction
  reg [11:0] ir;                        // the word executing this cycle
  reg  [7:0] w;
  reg  [2:0] st;                        // Z DC C
  reg  [4:0] fsr;
  reg  [7:0] rtcc;
  reg  [8:0] stk1, stk2;
  reg  [7:0] ram [0:31];                // 7-31 used; 0-6 are the special registers

  integer i;
  initial begin
    for (i = 0; i < 32; i = i + 1) ram[i] = 8'h00;
    ph = 0; pc = RESET_PC; ir = 0; w = 0; st = 0; fsr = 0; rtcc = 0;
    stk1 = 0; stk2 = 0; ra_latch = 4'hF; rb_latch = 8'hFF;
  end

  assign pm_addr = pc;

  wire tick = osc_en && ph == 3'd7;     // the end of a machine cycle

  // ---------------------------------------------------------- decode
  wire [4:0] f      = ir[4:0];
  wire       d      = ir[5];
  wire [3:0] op     = ir[9:6];          // byte-oriented operations
  wire [2:0] b      = ir[7:5];          // bit number
  wire [7:0] k      = ir[7:0];
  wire       is_byte = ir[11:10] == 2'b00;
  wire       is_bit  = ir[11:10] == 2'b01;

  // the effective file address: F0 goes through the FSR
  wire [4:0] ea = (f == 5'd0) ? fsr : f;

  // what a read of the file returns
  reg [7:0] fv;
  always @* begin
    case (ea)
      5'd0:    fv = 8'h00;              // F0 through an FSR of 0
      5'd1:    fv = rtcc;
      5'd2:    fv = pc[7:0];            // already the next instruction's address
      5'd3:    fv = {5'b11111, st};
      5'd4:    fv = {3'b111, fsr};
      5'd5:    fv = {4'h0, ra_pin};
      5'd6:    fv = rb_pin;
      default: fv = ram[ea];
    endcase
  end

  // ---------------------------------------------------------- the ALU
  wire [8:0] add9  = {1'b0, fv} + {1'b0, w};
  wire [4:0] add5  = {1'b0, fv[3:0]} + {1'b0, w[3:0]};
  wire [8:0] sub9  = {1'b0, fv} + {1'b0, ~w} + 9'd1;       // f + /W + 1 (p. 52)
  wire [4:0] sub5  = {1'b0, fv[3:0]} + {1'b0, ~w[3:0]} + 5'd1;

  reg  [7:0] res;                       // the result of a byte or bit operation
  reg        wr_f;                      // it goes to the file (else W, or nowhere)
  reg        wr_w;
  reg  [2:0] st_new;                    // the flags this operation sets, in place
  reg  [2:0] fmask;                     // which flags it sets: Z DC C
  reg        skip;                      // a conditional skip is taken
  always @* begin
    res = fv; wr_f = 0; wr_w = 0; st_new = st; fmask = 3'b000; skip = 0;
    if (is_byte) begin
      wr_f = d; wr_w = !d;
      case (op)
        4'b0000: begin                  // NOP (and 0001-0037) / MOVWF
          res = w; wr_f = d; wr_w = 0;
        end
        4'b0001: begin                  // CLRW / CLRF
          res = 8'h00; st_new[2] = 1; fmask = 3'b100;
        end
        4'b0010: begin                  // SUBWF
          res = sub9[7:0];
          st_new[0] = sub9[8]; st_new[1] = sub5[4]; st_new[2] = sub9[7:0] == 0;
          fmask = 3'b111;
        end
        4'b0011: begin res = fv - 8'd1;  st_new[2] = res == 0; fmask = 3'b100; end   // DECF
        4'b0100: begin res = fv | w;     st_new[2] = res == 0; fmask = 3'b100; end   // IORWF
        4'b0101: begin res = fv & w;     st_new[2] = res == 0; fmask = 3'b100; end   // ANDWF
        4'b0110: begin res = fv ^ w;     st_new[2] = res == 0; fmask = 3'b100; end   // XORWF
        4'b0111: begin                  // ADDWF
          res = add9[7:0];
          st_new[0] = add9[8]; st_new[1] = add5[4]; st_new[2] = add9[7:0] == 0;
          fmask = 3'b111;
        end
        4'b1000: begin res = fv;         st_new[2] = res == 0; fmask = 3'b100; end   // MOVF
        4'b1001: begin res = ~fv;        st_new[2] = res == 0; fmask = 3'b100; end   // COMF
        4'b1010: begin res = fv + 8'd1;  st_new[2] = res == 0; fmask = 3'b100; end   // INCF
        4'b1011: begin res = fv - 8'd1;  skip = res == 0; end        // DECFSZ
        4'b1100: begin res = {st[0], fv[7:1]}; st_new[0] = fv[0]; fmask = 3'b001; end // RRF
        4'b1101: begin res = {fv[6:0], st[0]}; st_new[0] = fv[7]; fmask = 3'b001; end // RLF
        4'b1110: begin res = {fv[3:0], fv[7:4]}; end                // SWAPF
        4'b1111: begin res = fv + 8'd1;  skip = res == 0; end        // INCFSZ
      endcase
    end else if (is_bit) begin
      case (ir[9:8])
        2'b00: begin res = fv & ~(8'd1 << b); wr_f = 1; end          // BCF
        2'b01: begin res = fv |  (8'd1 << b); wr_f = 1; end          // BSF
        2'b10: skip = !fv[b];                                        // BTFSC
        2'b11: skip =  fv[b];                                        // BTFSS
      endcase
    end
  end

  // ---------------------------------------------------------- the RTCC pin
  reg rt_q = 1'b1;
  always @(posedge clk) rt_q <= rtcc_pin;
  wire rt_fall = rt_q && !rtcc_pin;

  // ---------------------------------------------------------- execute
  wire rtcc_write = tick && (is_byte || is_bit) && wr_f && ea == 5'd1;

  always @(posedge clk) begin
    if (!mclr_n) begin
      ph <= 0; pc <= RESET_PC; ir <= 12'o0000;
      ra_latch <= 4'hF; rb_latch <= 8'hFF;
    end else begin
      if (osc_en) ph <= ph + 1'b1;
      if (tick) begin
        // the default: the fetched word executes next
        ir <= pm_data;
        pc <= pc + 1'b1;

        if (is_byte || is_bit) begin
          if (wr_w) w <= res;
          st <= st_new;                                           // unaffected flags are st's own
          if (wr_f) begin
            case (ea)
              5'd0: ;                                             // FSR 0: nowhere
              5'd1: ;                                             // RTCC: below
              5'd2: begin pc <= {1'b0, res}; ir <= 12'o0000; end  // a jump, bit 8 cleared
              5'd3: st <= (res[2:0] & ~fmask) | (st_new & fmask); // the op's own flags win
              5'd4: fsr <= res[4:0];
              5'd5: ra_latch <= res[3:0];
              5'd6: rb_latch <= res;
              default: ram[ea] <= res;
            endcase
          end
          if (skip) begin ir <= 12'o0000; pc <= pc + 1'b1; end
        end else begin
          case (ir[11:8])
            4'b1000: begin                                        // RETLW
              w <= k; pc <= stk1; stk1 <= stk2; ir <= 12'o0000;
            end
            4'b1001: begin                                        // CALL
              stk2 <= stk1; stk1 <= pc; pc <= {1'b0, k}; ir <= 12'o0000;
            end
            4'b1010, 4'b1011: begin                               // GOTO
              pc <= ir[8:0]; ir <= 12'o0000;
            end
            4'b1100: w <= k;                                      // MOVLW
            4'b1101: begin w <= w | k; st[2] <= (w | k) == 0; end // IORLW
            4'b1110: begin w <= w & k; st[2] <= (w & k) == 0; end // ANDLW
            4'b1111: begin w <= w ^ k; st[2] <= (w ^ k) == 0; end // XORLW
          endcase
        end
      end
    end

    // the RTCC counts its pin whether or not the chip runs; a write wins
    if (rtcc_write) rtcc <= res;
    else if (rt_fall) rtcc <= rtcc + 1'b1;
  end

  assign dbg = {pc, w, 5'b11111, st, 3'b111, fsr, rtcc, stk1, stk2, 5'd0};

endmodule
