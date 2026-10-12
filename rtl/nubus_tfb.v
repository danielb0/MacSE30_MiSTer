// nubus_tfb.v - Apple's Macintosh II Video Card (the "Toby" frame buffer, TFB-1) as a NuBus slot
// device: 512 KB of VRAM, 640 x 480 at 1, 2, 4 or 8 bits, the Bt453 RAMDAC and the VBL interrupt.
//
// The card's space (20 address bits decoded; it mirrors every 1 MB):
//   $00000  VRAM; each row's visible bytes in block RAM, packed for the scan-out, the rest in SDRAM
//   $80000  the 16 write-only registers, one per longword (15 bits 5-4 the depth, 2:3 the base)
//   $90000  the RAMDAC: longword 3 (mod 4) the address, 2 the palette data (R, G, B)
//   $A0000  write: the VBL interrupt, A2 = 1 off, A2 = 0 on and cleared
//   $D0000  read: the VBL status on D0, 1 in vertical blanking
//   $F0000  the declaration ROM, 4 KB on byte lane 0
// NuBus data is active-low: the registers, the CLUT and the status hold the bus's inverse; the
// CLUT is indexed with the inverted pixel, so the VRAM keeps bytes as the CPU sees them.

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

  // debug: the last four bytes written to register 15, the register and RAMDAC write counts,
  // the last register written, the resets seen, the depth as written and as scanned
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

  // the packing: a page is 480 rows of 128 << depth bytes from $20, of which 80 << depth are
  // shown; the CPU's offset to its row and column, by the depth in register 15
  wire [18:0] rel     = addr[18:0] - 19'd32;
  wire [11:0] row_all = rel >> (7 + depth);                // up to 4,095 rows of 128 bytes
  wire  [9:0] col     = rel[9:0] & ((10'd128 << depth) - 1'b1);
  wire [11:0] rows_disp = (depth == 2'd0) ? 12'd2400 : (depth == 2'd1) ? 12'd1440 :
                          (depth == 2'd2) ? 12'd960  : 12'd480;      // 480 x pages (5, 3, 2, 1)
  wire        visible = (addr[18:0] >= 19'd32) && (col < (10'd80 << depth)) && (row_all < rows_disp);
  wire [18:0] pk_byte = (({7'd0, row_all} * 19'd80) << depth) + {9'd0, col};   // row x (80 << depth) + column
  // registered: the NuChip latches the address a clock or more before it raises sel
  reg  [16:0] blw;
  reg         in_bram;
  always @(posedge clk) begin blw <= pk_byte[18:2]; in_bram <= a_vram && visible; end

  // ------------------------------------------------- the VRAM, block RAM
  // four byte lanes, each a true dual-port RAM: the CPU's port on clk, the scan-out's on clk_pix
  wire [31:0] cpu_vq, pix_vq;
  wire [16:0] pix_lw;
  genvar ln;
  generate for (ln = 0; ln < 4; ln = ln + 1) begin : lane
    tfb_vram_lane #(.WORDS(VRAM_LW)) ram (
      .clk_a(clk), .addr_a(blw), .we_a(sel && !rw && in_bram && be[ln] && !ack), .d_a(wdata[8*ln +: 8]), .q_a(cpu_vq[8*ln +: 8]),
      .clk_b(clk_pix), .addr_b(pix_lw), .q_b(pix_vq[8*ln +: 8]));
  end endgenerate

  // ------------------------------------------------ the declaration ROM
  // boot3.rom is the lane's bytes reversed and inverted: file byte i is ROM byte 4095 - i, complemented
  (* ramstyle = "M10K" *) reg [7:0] rom [0:4095];
  reg [7:0] rom_q;
  always @(posedge clk) begin
    if (rom_we) rom[~rom_waddr] <= ~rom_wdata;
    rom_q <= rom[addr[13:2]];
  end

  // the byte for a byte-wide register: the lane the transfer names, D31-D24 for a word or long
  // (the ROM's driver writes the registers at byte 0, System 7's own driver at byte 3)
  wire [7:0] wbyte = be[3] ? wdata[31:24] : be[2] ? wdata[23:16] : be[1] ? wdata[15:8] : wdata[7:0];

  // ------------------------------------------------- the TFB's registers
  reg  [7:0] treg [0:15];
  integer i;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      for (i = 0; i < 16; i = i + 1) treg[i] <= 8'h00;
      depth <= 2'd0; base <= 16'd8;
    end else if (sel && !rw && a_reg && !ack) begin
      treg[addr[5:2]] <= ~wbyte;
      if (addr[5:2] == 4'd15) depth <= ~wbyte[5:4];
      if (addr[5:2] == 4'd2)  base[15:8] <= ~wbyte;
      if (addr[5:2] == 4'd3)  base[7:0]  <= ~wbyte;
    end

  // one access, one action: sel lasts a NuBus clock, so a side effect (the RAMDAC's
  // auto-increment) acts on its first clock only
  reg  sel_q;
  always @(posedge clk or negedge reset_n) if (!reset_n) sel_q <= 0; else sel_q <= sel;
  wire go = sel && !sel_q;

  // ------------------------------------------------- debug
  reg [31:0] dbg_r15 = 0;
  reg  [7:0] dbg_regw = 0, dbg_dacw = 0;
  reg  [3:0] dbg_lastreg = 0, dbg_rst = 0;
  reg        dbg_rst_q = 1;
  always @(posedge clk) begin
    dbg_rst_q <= reset_n;
    if (dbg_rst_q && !reset_n) dbg_rst <= dbg_rst + 1'b1;
    if (go && !rw && a_reg) begin
      dbg_regw <= dbg_regw + 1'b1; dbg_lastreg <= addr[5:2];
      if (addr[5:2] == 4'd15) dbg_r15 <= {dbg_r15[23:0], wbyte};
    end
    if (go && !rw && a_dac) dbg_dacw <= dbg_dacw + 1'b1;
  end

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
    else if (go && a_dac) begin
      if (addr[3:2] == 2'd1 || addr[3:2] == 2'd3) begin
        if (!rw) dac_addr <= ~wbyte;
        dac_step <= 0;
      end else if (addr[3:2] == 2'd2) begin
        dac_step <= (dac_step == 2'd2) ? 2'd0 : dac_step + 1'b1;
        if (dac_step == 2'd2) dac_addr <= dac_addr + 1'b1;
        if (!rw) begin
          if (dac_step == 2'd0) dac_rg[15:8] <= ~wbyte;
          if (dac_step == 2'd1) dac_rg[7:0]  <= ~wbyte;
        end
      end
    end
  always @(posedge clk) begin
    if (go && !rw && a_dac && addr[3:2] == 2'd2 && dac_step == 2'd2)
      clut[dac_addr] <= {dac_rg, ~wbyte};
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
  // two clocks: the block RAMs' registered reads land on the second; the upper VRAM waits for SDRAM
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
  // 864 x 525 at 30.24 MHz: active 640, front porch 64, sync 64, back porch 96; 480 lines, front
  // porch 3, sync 3, back porch 39.  The depth and the base cross once a frame.
  reg  [9:0] hc, vc;
  reg  [1:0] depth_p, depth_s;
  assign dbg = {dbg_r15, dbg_regw, dbg_dacw, dbg_lastreg, dbg_rst, 4'd0, depth, depth_p};
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

  // the pixel's longword in the packed block RAM: the line's start, a running sum from the
  // frame's first row (from the base), plus x >> (5 - depth)
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
  // the pixel's bits from the word (the leftmost pixel in the top bits), inverted, at the top of
  // the CLUT index
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
  // the word, the CLUT entry and the RGB a clock apart: the syncs take the delay lines' second taps
  reg [23:0] clut_pq;
  always @(posedge clk_pix) clut_pq <= clut[pix];
  always @(posedge clk_pix) begin
    {r, g, b} <= (hbd[1] || vbd[1]) ? 24'h0 : clut_pq;
    hs_n <= hsd[1]; vs_n <= vsd[1]; hblank <= hbd[1]; vblank <= vbd[1];
  end

endmodule

// tfb_vram_lane - one byte lane of the card's block-RAM VRAM: true dual-port, port A read/write on
// clk_a, port B read on clk_b, built from 4K-deep M10K slices (inference rounds up to 2^17 words)
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
