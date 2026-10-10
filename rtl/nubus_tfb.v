// nubus_tfb.v - Apple's Macintosh II Video Card (630-0153, the "Toby" frame
// buffer, TFB-1) as a slot device (SE30_PLAN.md 14.2 items 5 and 7, 14.3).
//
// WHAT IT IS
//   The card the IIcx build carries in NuBus slot $9 (and, later, the SE/30's
//   colour option, FUTURE ADDITIONS 4).  Everything here is read from the
//   card's own declaration ROM (342-0008-A: PrimaryInit and the driver
//   .Display_Video_Apple_TFB) and from *Designing Cards and Drivers*, 2nd
//   ed., chapter 11; MAME's nubus_m2video.cpp is a cross-check only.
//
// THE CARD'S SPACE (20 address bits decoded: it mirrors every 1 MB)
//   $00000-$7FFFF  VRAM, 512 KB, held in two places (14.3 item 4, option A,
//                  with compaction).  A page is 480 rows of rowBytes =
//                  128 << depth, page 0 at $20, pages contiguous (8-bit 1,
//                  4-bit 2, 2-bit 3, 1-bit 5); of each row only the first
//                  80 << depth bytes are shown.  Those visible bytes of every
//                  displayable row - 192,000 to 307,200 bytes by depth - are
//                  block RAM, packed at row x (80 << depth) + column, and
//                  the scan-out reads them directly; every other byte (the
//                  invisible column tail of each row, the rows beyond the
//                  last page, the 32 bytes before page 0) is SDRAM at its
//                  own address, through the up_* port.  The packing follows
//                  the depth in register 15: bytes in block RAM are
//                  reinterpreted when the depth changes, as a real card's
//                  are (differently: either way garbage until QuickDraw
//                  repaints after the mode change).
//   $80000         the TFB's 16 write-only registers, one per longword,
//                  D31-D24; the bus is active-low, so a register holds the
//                  inverse of the byte written (the driver writes not.b of
//                  its tables).  Register 15 bits 5-4 = depth (0-3 = 1, 2,
//                  4, 8 bits); registers 2:3 = the base, in longwords.  The
//                  timing registers are not modelled: the driver only ever
//                  loads the four tables, all the book's 640 x 480 at 66.67
//                  Hz, which the scan-out generates.
//   $90000         the Bt453 RAMDAC on D31-D24: longword 3 (mod 4) the
//                  address, 2 the palette data (R, G, B, auto-increment),
//                  both inverted on the bus.
//   $A0000         write: the VBL interrupt - A2 = 1 off, A2 = 0 on and
//                  cleared (the driver's Open, handler and Close).
//   $D0000         read: the VBL status on D0 (WaitVBL polls it).
//   $F0000         the declaration ROM, byte lane 0 (D31-D24), 4 KB at the
//                  top of the space.
//
// INVERSION
//   NuBus data is active-low.  The VRAM stores bytes as the CPU sees them;
//   the CLUT is indexed with the inverted pixel and written at the inverted
//   address, which is exactly what the driver's arithmetic expects (14.2
//   item 7), so colours come out right with no inversion on the frame
//   buffer's path.  Register, CLUT and status bytes are inverted here.
//
// OPEN (14.4): the VBL status level - here 1 during vertical blanking, the
//   reading under which WaitVBL waits for blanking to begin; the CPU-side
//   NuBus timing (ack after a fixed latency here; step 3 tunes it).

`timescale 1ns/1ps

module nubus_tfb #(
  parameter VRAM_LW = 76800            // the visible VRAM in block RAM, longwords (307,200 bytes: 8-bit's page, 4-bit's two)
) (
  input             clk,               // clk_sys
  input             reset_n,

  // the CPU side: one access, sel held until ack
  input             sel,
  input             rw,                // 1 = read
  input      [19:0] addr,              // byte address in the card's 1 MB
  input       [3:0] be,                // byte lanes, be[3] = D31-D24
  input      [31:0] wdata,
  output reg [31:0] rdata,
  output reg        ack,
  output            irq_n,             // the slot's interrupt line

  // the declaration ROM's load (boot3.rom, as stored: byte-reversed, inverted)
  input             rom_we,
  input      [11:0] rom_waddr,
  input       [7:0] rom_wdata,

  // the VRAM above the block RAM, in SDRAM
  output reg        up_req,
  output reg        up_we,
  output reg [16:0] up_addr,           // longword address in the card's 512 KB
  output reg  [3:0] up_be,
  output reg [31:0] up_wdata,
  input      [31:0] up_rdata,
  input             up_ack,

  // the board instrument (plan 14.3 step 6; MacSE30.sv's PCRD): the last
  // four bytes written to register 15 as the bus carried them (newest in
  // the low byte), the register and RAMDAC write counts, the last register
  // written, the resets seen, the depth as written and as scanned
  output     [63:0] dbg,

  // video, on the dot clock
  input             clk_pix,
  output reg  [7:0] r, g, b,
  output reg        hs_n, vs_n, hblank, vblank
);

  // ---------------------------------------------------------- decode
  wire a_vram = (addr[19] == 1'b0);
  wire a_reg  = (addr[19:16] == 4'h8);
  wire a_dac  = (addr[19:16] == 4'h9) && (addr[15:5] == 0);
  wire a_vbl  = (addr[19:16] == 4'hA);
  wire a_stat = (addr[19:16] == 4'hD);
  wire a_rom  = (addr[19:16] == 4'hF);
  reg  [1:0] depth;                    // register 15 bits 5-4 (below)
  reg [15:0] base;                     // registers 2:3, longwords
  wire [16:0] lw = addr[18:2];

  // the compaction (THE CARD'S SPACE above): the CPU's byte offset to its
  // row across the pages and its column, by the depth in register 15
  wire [18:0] rel     = addr[18:0] - 19'd32;
  wire [11:0] row_all = rel >> (7 + depth);                // up to 4,095 rows of 128 bytes
  wire  [9:0] col     = rel[9:0] & ((10'd128 << depth) - 1'b1);
  wire [11:0] rows_disp = (depth == 2'd0) ? 12'd2400 : (depth == 2'd1) ? 12'd1440 :
                          (depth == 2'd2) ? 12'd960  : 12'd480;      // 480 x pages (5, 3, 2, 1)
  wire        visible = (addr[18:0] >= 19'd32) && (col < (10'd80 << depth)) && (row_all < rows_disp);
  wire [18:0] pk_byte = (({7'd0, row_all} * 19'd80) << depth) + {9'd0, col};   // row x (80 << depth) + column
  // registered: the NuChip latches the address a clock or more before it
  // raises sel (iicx_nuchip.v), so these are settled by then, and the
  // arithmetic above never sits between a register and 300 M10K
  reg  [16:0] blw;
  reg         in_bram;
  always @(posedge clk) begin blw <= pk_byte[18:2]; in_bram <= a_vram && visible; end

  // ------------------------------------------------- the VRAM, block RAM
  // Four byte lanes, each one true dual-port RAM (tfb_vram_lane, below):
  // the CPU's read/write port on clk, the scan-out's read port on clk_pix.
  wire [31:0] cpu_vq, pix_vq;
  wire [16:0] pix_lw;
  genvar ln;
  generate for (ln = 0; ln < 4; ln = ln + 1) begin : lane
    tfb_vram_lane #(.WORDS(VRAM_LW)) ram (
      .clk_a(clk), .addr_a(blw), .we_a(sel && !rw && in_bram && be[ln] && !ack), .d_a(wdata[8*ln +: 8]), .q_a(cpu_vq[8*ln +: 8]),
      .clk_b(clk_pix), .addr_b(pix_lw), .q_b(pix_vq[8*ln +: 8]));
  end endgenerate

  // ------------------------------------------------ the declaration ROM
  // boot3.rom is the lane's bytes reversed and inverted (14.2 item 5): file
  // byte i is ROM byte 4095 - i, complemented.
  (* ramstyle = "M10K" *) reg [7:0] rom [0:4095];
  reg [7:0] rom_q;
  always @(posedge clk) begin
    if (rom_we) rom[~rom_waddr] <= ~rom_wdata;
    rom_q <= rom[addr[13:2]];
  end

  // ------------------------------------------------- the TFB's registers
  reg  [7:0] treg [0:15];
  integer i;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      for (i = 0; i < 16; i = i + 1) treg[i] <= 8'h00;
      depth <= 2'd0; base <= 16'd8;
    end else if (sel && !rw && a_reg && be[3] && !ack) begin
      treg[addr[5:2]] <= ~wdata[31:24];
      if (addr[5:2] == 4'd15) depth <= ~wdata[29:28];
      if (addr[5:2] == 4'd2)  base[15:8] <= ~wdata[31:24];
      if (addr[5:2] == 4'd3)  base[7:0]  <= ~wdata[31:24];
    end

  // one access, one action: the NuChip holds sel for a NuBus clock (two
  // or more of ours), so anything with a side effect - the RAMDAC's
  // auto-increment above all - acts on the first clock only
  reg  sel_q;
  always @(posedge clk or negedge reset_n) if (!reset_n) sel_q <= 0; else sel_q <= sel;
  wire go = sel && !sel_q;

  // ------------------------------------------------- the instrument
  reg [31:0] dbg_r15 = 0;
  reg  [7:0] dbg_regw = 0, dbg_dacw = 0;
  reg  [3:0] dbg_lastreg = 0, dbg_rst = 0;
  reg        dbg_rst_q = 1;
  always @(posedge clk) begin
    dbg_rst_q <= reset_n;
    if (dbg_rst_q && !reset_n) dbg_rst <= dbg_rst + 1'b1;
    if (go && !rw && a_reg && be[3]) begin
      dbg_regw <= dbg_regw + 1'b1; dbg_lastreg <= addr[5:2];
      if (addr[5:2] == 4'd15) dbg_r15 <= {dbg_r15[23:0], wdata[31:24]};
    end
    if (go && !rw && a_dac && be[3]) dbg_dacw <= dbg_dacw + 1'b1;
  end
  // (dbg is assigned below depth_p's declaration)

  // ------------------------------------------------------ the Bt453
  // address register, a three-step colour pointer (R, G, B), the 256 x 24
  // colour RAM: written on the CPU's clock, read on the dot clock
  reg  [7:0] dac_addr;
  reg  [1:0] dac_step;
  reg [15:0] dac_rg;                   // R and G held until B completes the entry
  (* ramstyle = "M10K" *) reg [23:0] clut [0:255];
  reg [23:0] clut_cq;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin dac_addr <= 0; dac_step <= 0; dac_rg <= 0; end
    else if (go && a_dac && be[3]) begin
      if (addr[3:2] == 2'd1 || addr[3:2] == 2'd3) begin
        if (!rw) dac_addr <= ~wdata[31:24];
        dac_step <= 0;
      end else if (addr[3:2] == 2'd2) begin
        dac_step <= (dac_step == 2'd2) ? 2'd0 : dac_step + 1'b1;
        if (dac_step == 2'd2) dac_addr <= dac_addr + 1'b1;
        if (!rw) begin
          if (dac_step == 2'd0) dac_rg[15:8] <= ~wdata[31:24];
          if (dac_step == 2'd1) dac_rg[7:0]  <= ~wdata[31:24];
        end
      end
    end
  always @(posedge clk) begin
    if (go && !rw && a_dac && be[3] && addr[3:2] == 2'd2 && dac_step == 2'd2)
      clut[dac_addr] <= {dac_rg, ~wdata[31:24]};
    clut_cq <= clut[dac_addr];
  end
  wire [7:0] dac_rd = (addr[3:2] == 2'd2) ? ~clut_cq[23 - 8*dac_step -: 8] : ~dac_addr;
  reg  [7:0] dac_q;                    // the byte read, as it was when the access began
  always @(posedge clk) if (go && a_dac) dac_q <= dac_rd;

  // ------------------------------------------------ the VBL interrupt
  reg  vbl_en, vbl_pend;
  reg  [2:0] vbl_sync;                 // the dot clock's frame-start toggle, into clk
  reg  vbl_tog;                        // toggles at each vertical blanking start (clk_pix)
  reg  [1:0] vblank_s;                 // the blanking level, into clk
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin vbl_en <= 0; vbl_pend <= 0; vbl_sync <= 0; vblank_s <= 0; end
    else begin
      vbl_sync <= {vbl_sync[1:0], vbl_tog};
      vblank_s <= {vblank_s[0], vblank};
      if (vbl_sync[2] != vbl_sync[1] && vbl_en) vbl_pend <= 1;
      if (sel && !rw && a_vbl && !ack) begin
        vbl_en <= !addr[2];
        vbl_pend <= 0;
      end
    end
  assign irq_n = !vbl_pend;

  // ------------------------------------------------ the CPU's cycle
  // Two clocks: the block RAMs' registered reads land on the second.  The
  // upper VRAM waits for SDRAM.  NuBus's real timing comes in step 3.
  reg  [1:0] cyc;
  reg        up_busy;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      cyc <= 0; ack <= 0; rdata <= 0; up_req <= 0; up_we <= 0; up_addr <= 0;
      up_be <= 0; up_wdata <= 0; up_busy <= 0;
    end else begin
      if (!sel) begin cyc <= 0; ack <= 0; up_req <= 0; up_busy <= 0; end
      else if (!ack) begin
        if (a_vram && !in_bram) begin
          if (!up_busy && !up_ack) begin               // the previous longword's acknowledge has fallen
            up_req <= 1; up_we <= !rw; up_addr <= lw; up_be <= be; up_wdata <= wdata;
            up_busy <= 1;
          end else if (up_ack) begin
            up_req <= 0; ack <= 1; rdata <= up_rdata;
          end
        end else begin
          cyc <= cyc + 1'b1;
          if (cyc == 2'd1) begin
            ack <= 1;
            rdata <= in_bram ? cpu_vq :
                     a_rom   ? {rom_q, 24'h0} :
                     a_dac   ? {dac_q, 24'h0} :
                     a_stat  ? {31'h0, vblank_s[1]} : 32'h0;
          end
        end
      end
    end

  // ------------------------------------------------------- scan-out
  // 864 x 525 at 30.24 MHz (the book's Figure 11-3): active 640, front
  // porch 64, sync 64, back porch 96; active 480 lines, front porch 3,
  // sync 3, back porch 39.  Depth and base cross once a frame.
  reg  [9:0] hc, vc;
  reg  [1:0] depth_p, depth_s;
  assign dbg = {dbg_r15, dbg_regw, dbg_dacw, dbg_lastreg, dbg_rst, 4'd0, depth, depth_p};   // the instrument's output (above)
  reg [15:0] base_p, base_s;
  always @(posedge clk_pix) begin
    depth_s <= depth; base_s <= base;  // quasi-static: written by the driver after WaitVBL
    hc <= (hc == 10'd863) ? 10'd0 : hc + 1'b1;
    if (hc == 10'd863) begin
      vc <= (vc == 10'd524) ? 10'd0 : vc + 1'b1;
      if (vc == 10'd524) begin depth_p <= depth_s; base_p <= base_s; end
      if (vc == 10'd479) vbl_tog <= ~vbl_tog;
    end
  end
  initial begin hc = 0; vc = 0; vbl_tog = 0; depth_p = 0; base_p = 16'd8; end

  // the longword holding this pixel, in the packed block RAM: the page's
  // first row (from the base) plus the line, times the visible width
  // (20 << depth longwords), plus x >> (5 - depth).  The line's start is
  // kept as a running sum - set at the top of the frame, a visible width
  // added at each line's end.
  // the frame's first line, from the depth and base it takes at its top
  // (depth_s, base_s: the values depth_p and base_p take on that clock)
  wire [17:0] base_rel = {base_s, 2'b00} - 18'd32;
  wire [11:0] base_row = base_rel >> (7 + depth_s);
  wire [16:0] top_lw   = ({5'd0, base_row} * 17'd20) << depth_s;
  wire  [7:0] vis_lw   = 8'd20 << depth_p;               // 20, 40, 80, 160 longwords
  reg  [16:0] line_lw;
  always @(posedge clk_pix)
    if (hc == 10'd863) line_lw <= (vc == 10'd524) ? top_lw : line_lw + {9'd0, vis_lw};
  wire  [9:0] x = hc;
  wire [16:0] col_lw = {7'd0, x} >> (5 - depth_p);
  assign pix_lw = line_lw + col_lw;

  // the pipeline: address (0), VRAM word (1), CLUT read (2), RGB out (3)
  reg  [9:0] x1;
  reg  [1:0] d1;
  reg  [1:0] hsd, vsd, hbd, vbd;
  reg  [7:0] pix;
  always @(posedge clk_pix) begin
    x1 <= x; d1 <= depth_p;
    hsd <= {hsd[0], !((hc >= 10'd704) && (hc < 10'd768))};
    vsd <= {vsd[0], !((vc >= 10'd483) && (vc < 10'd486))};
    hbd <= {hbd[0], hc >= 10'd640};
    vbd <= {vbd[0], vc >= 10'd480};
  end
  // the pixel's bits from the word (big-endian: the leftmost pixel in the
  // top bits), placed in the top of the CLUT index, inverted (INVERSION)
  wire [4:0] bitpos = x1[4:0] << d1;             // the pixel's first bit, counted from the word's top
  wire [31:0] sh = pix_vq << bitpos;
  always @(*) begin
    case (d1)
      2'd0: pix = {~sh[31],    7'h00};
      2'd1: pix = {~sh[31:30], 6'h00};
      2'd2: pix = {~sh[31:28], 4'h0};
      default: pix = ~sh[31:24];
    endcase
  end
  // hc = h in a cycle: its word at the end of it, its CLUT entry at the end
  // of the next, its RGB registered at the end of the one after - so the
  // outputs take the delay lines' two-clock taps
  reg [23:0] clut_pq;
  always @(posedge clk_pix) clut_pq <= clut[pix];
  always @(posedge clk_pix) begin
    {r, g, b} <= (hbd[1] || vbd[1]) ? 24'h0 : clut_pq;
    hs_n <= hsd[1]; vs_n <= vsd[1]; hblank <= hbd[1]; vblank <= vbd[1];
  end

endmodule

// One byte lane of the card's block-RAM VRAM: WORDS bytes, true dual-port -
// port A read/write on clk_a, port B read on clk_b, both outputs registered
// once (a read is ready the clock after its address).  Instantiated rather
// than inferred: inference rounded the depth up to 2^17 and built two
// memories per lane, one per read clock (plan 14.3 step 1).  Built from
// 4K-deep M10K slices (4K x 2): ceil(WORDS / 4096) x 4 blocks with a 19-way
// read mux per bit for 76,808 words, where 1K x 8 slices would need a
// 76-way one.
module tfb_vram_lane #(
  parameter WORDS = 76808
) (
  input         clk_a,
  input  [16:0] addr_a,
  input         we_a,
  input   [7:0] d_a,
  output  [7:0] q_a,
  input         clk_b,
  input  [16:0] addr_b,
  output  [7:0] q_b
);
`ifdef SIMULATION
  reg [7:0] mem [0:WORDS-1];
  reg [7:0] qa, qb;
  always @(posedge clk_a) begin
    if (we_a && addr_a < WORDS) mem[addr_a] <= d_a;
    qa <= (addr_a < WORDS) ? mem[addr_a] : 8'hxx;
  end
  always @(posedge clk_b) qb <= (addr_b < WORDS) ? mem[addr_b] : 8'hxx;
  assign q_a = qa;
  assign q_b = qb;
`else
  altsyncram #(
    .operation_mode("BIDIR_DUAL_PORT"), .intended_device_family("Cyclone V"),
    .ram_block_type("M10K"), .maximum_depth(4096),
    .width_a(8), .widthad_a(17), .numwords_a(WORDS),
    .width_b(8), .widthad_b(17), .numwords_b(WORDS),
    .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
    .address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
    .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
    .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
    .power_up_uninitialized("FALSE"), .lpm_type("altsyncram")
  ) ram (
    .clock0(clk_a), .address_a(addr_a), .wren_a(we_a), .data_a(d_a), .q_a(q_a),
    .clock1(clk_b), .address_b(addr_b), .wren_b(1'b0), .data_b(8'h00), .q_b(q_b),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus());
`endif
endmodule
