// tb_iici_rotate.v - the bench for rtl/iici_rotate.v (the rotated Portrait
// Display, SE30_PLAN.md FUTURE ADDITIONS 18).
//
// The RBV's Portrait timing (832 x 918 clocks, 640 x 870 shown, vblank
// rising at hc 0 of line 870 and falling with line 0's first pixel, as
// iici_rbv.v makes it) drives the rotator with a picture that differs at
// every pixel and every frame.  A DDR model takes its writes with BUSY
// random (BUSYPCT percent of clocks, in runs).  At the end of each frame's
// blanking the buffer that frame went to is compared, pixel by pixel, with
// the frame turned the way it was asked:
//   clockwise      out(ox, oy) = in(x = oy,       y = H-1-ox)
//   anticlockwise  out(ox, oy) = in(x = W-1-oy,   y = ox)
// Also checked: every write inside its 8 MB slot and its out row's 880
// bytes; no overrun; the sender idle at the end of blanking; FB_EN only on
// a buffer holding a whole frame written with rotation on, and on by frame
// 3; at each scaler vblank (FB_VBL, its own period) the scaler given the
// newest finished frame, never the one being written.
// The direction changes between frames; enable drops and rises once.
//
// Parameters: BUSYPCT (0-75; at 90 a strip's 640 words no longer fit
// its 6,656 clocks - no sender can), CE_NUM/CE_DEN (pixel enable rate; 1/1 is the
// Portrait Display), VBLP (clocks a scaler frame), LL (FB_LL), PLANT
// (1 = a clockwise frame with the anticlockwise strip phase, 2 = one DDR
// write lost: each must FAIL).

`timescale 1ns/1ps

module tb_iici_rotate;
  parameter BUSYPCT = 50;
  parameter CE_NUM  = 1;
  parameter CE_DEN  = 1;
  parameter VBLP    = 617000;
  parameter LL      = 0;
  parameter NFRAMES = 9;
  parameter SEED    = 1;
  parameter PLANT   = 0;

  localparam W = 640, H = 870, HT = 832, VT = 918, STRIDE_W = 110;

  reg clk = 0;
  always #8.75 clk = ~clk;

  // ---------------------------------------------------- the RBV's timing
  reg  [31:0] cacc = 0;
  reg         ce = 0;
  always @(posedge clk) begin
    if (cacc + CE_NUM >= CE_DEN) begin cacc <= cacc + CE_NUM - CE_DEN; ce <= 1; end
    else begin cacc <= cacc + CE_NUM; ce <= 0; end
  end

  reg [9:0] hc = 0, vc = 10'd871;
  reg       hblank = 1, vblank = 1;
  reg [7:0] grey = 0;
  integer   frame = -1;                  // the frame being shown (from its first pixel)
  function [7:0] pixf; input integer f, x, y;
    pixf = (x * 7 + y * 13 + f * 29) ^ (y >> 3) ^ (x << 5);
  endfunction
  always @(posedge clk) if (ce) begin
    if (hc == HT - 1) begin hc <= 0; vc <= (vc == VT - 1) ? 0 : vc + 1; end
    else hc <= hc + 1;
    hblank <= !(hc < W);
    vblank <= !(vc < H);
    grey   <= (hc < W && vc < H) ? pixf(frame + ((hc == 0 && vc == 0) ? 1 : 0), hc, vc) : 8'h00;
    if (hc == 0 && vc == 0) frame <= frame + 1;
  end
  wire de = ~(hblank | vblank);

  // ---------------------------------------------------- the rotator
  reg  enable = 1, cw = 1;
  reg  fb_vbl = 0;
  wire FB_EN; wire [4:0] FB_FORMAT; wire [11:0] FB_WIDTH, FB_HEIGHT; wire [31:0] FB_BASE; wire [13:0] FB_STRIDE;
  wire FB_PAL_CLK, FB_PAL_WR; wire [7:0] FB_PAL_ADDR; wire [23:0] FB_PAL_DOUT;
  wire DDRAM_CLK, DDRAM_WE, DDRAM_RD; wire [7:0] DDRAM_BURSTCNT, DDRAM_BE; wire [28:0] DDRAM_ADDR; wire [63:0] DDRAM_DIN;
  reg  busy = 0;
  wire overrun;

  iici_rotate #(.W(W), .H(H), .STRIDE_W(STRIDE_W)) dut (
    .clk(clk), .ce(ce), .de(de), .vblank(vblank), .grey(grey),
    .enable_in(enable), .cw_in(cw),
    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT), .FB_BASE(FB_BASE),
    .FB_STRIDE(FB_STRIDE), .FB_VBL(fb_vbl), .FB_LL(LL[0]),
    .FB_PAL_CLK(FB_PAL_CLK), .FB_PAL_ADDR(FB_PAL_ADDR), .FB_PAL_DOUT(FB_PAL_DOUT), .FB_PAL_WR(FB_PAL_WR),
    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(busy), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD),
    .overrun(overrun)
  );

  // ---------------------------------------------------- DDR
  reg [63:0] mem [0:4*131072-1];
  integer errors = 0, writes = 0, seed = SEED, lost = 0;
  integer brun = 0;
  always @(posedge clk) begin
    // BUSY in runs: a new run every so often, BUSYPCT percent of the time
    if (brun > 0) brun <= brun - 1;
    else begin
      busy <= (($random(seed) & 32'h7fffffff) % 100) < BUSYPCT;
      brun <= ($random(seed) & 32'h7fffffff) % 40;
    end
    if (DDRAM_WE && !busy) begin
      writes = writes + 1;
      if (DDRAM_ADDR[28:22] != 7'b0010010 || DDRAM_ADDR[21:20] == 2'd3 || DDRAM_ADDR[19:17] != 0) begin
        if (errors < 20) $display("ERROR: write outside the buffers: addr %h", DDRAM_ADDR);
        errors = errors + 1;
      end else if ((DDRAM_ADDR[16:0] / STRIDE_W) >= W) begin
        if (errors < 20) $display("ERROR: write below the last out row: word %0d", DDRAM_ADDR[16:0]);
        errors = errors + 1;
      end else if (PLANT == 2 && frame == 4 && lost == 0 && writes > 1000) lost = 1;
      else
        mem[{DDRAM_ADDR[21:20], DDRAM_ADDR[16:0]}] <= DDRAM_DIN;
      if (DDRAM_BE != 8'hFF || DDRAM_BURSTCNT != 1) begin
        if (errors < 20) $display("ERROR: BE %h burst %0d", DDRAM_BE, DDRAM_BURSTCNT);
        errors = errors + 1;
      end
    end
    if (DDRAM_RD) begin $display("ERROR: a DDR read"); errors = errors + 1; end
  end

  // ---------------------------------------------------- the scaler's vblank
  integer vcnt = 0;
  always @(posedge clk) begin
    vcnt <= (vcnt == VBLP - 1) ? 0 : vcnt + 1;
    fb_vbl <= (vcnt < 2000);
  end

  // ---------------------------------------------------- bookkeeping
  // per frame: its buffer (taken at its first pixel) and its direction
  integer f_fb [0:63];
  integer f_cw [0:63];
  integer f_en [0:63];
  integer newest = -1;                   // the newest frame whose buffer is complete
  reg old_vbl_tb = 0;
  integer x, y, ox, oy, wd, ln, fbchk, en_frames = 0, checked = 0;
  reg [7:0] got, want;
  // the direction each frame was asked for, by the script below
  function want_cw; input integer f; want_cw = !(f == 3 || f == 4 || f >= 7); endfunction

  // the buffer a frame writes: i_fb has moved by its third pixel
  always @(posedge clk) if (ce && hc == 3 && vc == 0) begin
    f_fb[frame] = dut.i_fb;
    f_cw[frame] = dut.f_cw;
    f_en[frame] = enable;
    if (frame >= 1 && dut.f_cw !== want_cw(frame)) begin
      $display("ERROR: frame %0d runs %s", frame, dut.f_cw ? "clockwise" : "anticlockwise");
      errors = errors + 1;
    end
  end

  // plants: 1 = frame 2 (clockwise) started with the anticlockwise strip phase;
  //         2 = one DDR write of frame 4 lost

  always @(posedge clk) begin
    if (PLANT == 1 && frame == 1 && ce && vc == H && hc == 3) dut.r = 3'd0;
  end

  // at the end of each frame's blanking: compare
  always @(posedge clk) if (ce && vc == VT - 1 && hc == HT - 20 && frame >= 1) begin
    if (dut.active) begin $display("ERROR: frame %0d: the sender still busy at the end of blanking", frame); errors = errors + 1; end
    if (f_en[frame]) begin
      fbchk = f_fb[frame];
      for (oy = 0; oy < W; oy = oy + 1)
        for (ox = 0; ox < H; ox = ox + 1) begin
          wd  = oy * STRIDE_W + (ox >> 3);
          got = mem[{fbchk[1:0], wd[16:0]}][(ox & 7) * 8 +: 8];
          if (f_cw[frame]) want = pixf(frame, oy, H - 1 - ox);
          else             want = pixf(frame, W - 1 - oy, ox);
          if (got !== want) begin
            if (errors < 20) $display("ERROR: frame %0d (%s, buffer %0d) out(%0d,%0d) = %h, want %h",
                                      frame, f_cw[frame] ? "cw" : "ccw", fbchk, ox, oy, got, want);
            errors = errors + 1;
          end
        end
      checked = checked + 1;
      $display("frame %0d: %s into buffer %0d checked (%0d writes so far, errors %0d)",
               frame, f_cw[frame] ? "clockwise" : "anticlockwise", fbchk, writes, errors);
    end else
      $display("frame %0d: rotation off", frame);
    newest = frame;
  end

  // the scaler's buffer: the newest finished frame's, never the one being written
  always @(posedge clk) begin
    old_vbl_tb <= fb_vbl;
    if (FB_EN && dut.o_fb == dut.i_fb && !LL) begin
      if (errors < 20) $display("ERROR: the scaler reads the buffer being written (%0d)", dut.i_fb);
      errors = errors + 1;
    end
    if (!old_vbl_tb && fb_vbl && FB_EN && !LL && newest >= 0) begin
      #1;
      if (dut.o_fb != f_fb[newest] && !(vc == 0 && hc < 2)) begin
        $display("ERROR: scaler vblank: o_fb %0d, the newest finished frame %0d is in %0d", dut.o_fb, newest, f_fb[newest]);
        errors = errors + 1;
      end
    end
  end

  // FB_EN only on a buffer holding a whole frame written with rotation on
  integer buf_ok [0:3];
  integer en_seen = 0;
  initial begin buf_ok[0] = 0; buf_ok[1] = 0; buf_ok[2] = 0; buf_ok[3] = 0; end
  always @(posedge clk) begin
    if (ce && vc == 0 && hc == 3) buf_ok[dut.i_fb] = 0;                 // being written again
    if (ce && vc == VT - 1 && hc == HT - 21) buf_ok[f_fb[frame]] = f_en[frame] && frame >= 0;
    if (FB_EN) en_seen = en_seen + 1;
    if (FB_EN && !buf_ok[dut.o_fb] && !LL) begin
      if (errors < 20) $display("ERROR: FB_EN on buffer %0d, which holds no whole frame", dut.o_fb);
      errors = errors + 1;
    end
  end

  // ---------------------------------------------------- the script
  initial begin
    if (FB_FORMAT != 5'b00011 || FB_WIDTH != H || FB_HEIGHT != W || FB_STRIDE != 880) begin
      $display("ERROR: FB_FORMAT %b WIDTH %0d HEIGHT %0d STRIDE %0d", FB_FORMAT, FB_WIDTH, FB_HEIGHT, FB_STRIDE);
      errors = errors + 1;
    end
    wait (frame == 2); @(posedge clk); cw = 0;           // anticlockwise from frame 3
    wait (frame == 3); @(posedge clk);
    if (!FB_EN) begin $display("ERROR: FB_EN still off at frame 3"); errors = errors + 1; end
    wait (frame == 4); @(posedge clk); cw = 1;           // clockwise from frame 5
    wait (frame == 5); @(posedge clk); enable = 0;       // off for frame 5
    wait (frame == 6); @(posedge clk); enable = 1; cw = 0; // on from frame 6 (clockwise), anticlockwise from 7
    wait (frame == NFRAMES); @(posedge clk);
    if (!FB_EN) begin $display("ERROR: FB_EN off at the end"); errors = errors + 1; end
    if (overrun) begin $display("ERROR: overrun"); errors = errors + 1; end
    if (FB_PAL_ADDR !== FB_PAL_DOUT[7:0] || FB_PAL_DOUT[23:16] !== FB_PAL_DOUT[7:0] || !FB_PAL_WR) begin
      $display("ERROR: the palette is not a grey ramp"); errors = errors + 1;
    end
    $display("%0d frames checked, %0d DDR writes, BUSYPCT %0d, CE %0d/%0d, LL %0d", checked, writes, BUSYPCT, CE_NUM, CE_DEN, LL);
    if (errors == 0 && checked >= 6) $display("==== PASS");
    else $display("==== FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
