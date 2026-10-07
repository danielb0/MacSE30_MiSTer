// se30_video.v - the built-in video: timing PALs, counters, shifter, VRAM and declaration ROM

`timescale 1ns/1ps

module se30_video #(
  parameter DECLROM_HEX = "",
  parameter V_TOTAL     = 370
) (
  input         clk,
  input         c16_en,
  input         reset_n,

  input         declrom_we,
  input  [12:0] declrom_waddr,
  input   [7:0] declrom_wdata,

  input         sel,
  input         as_n,
  input         ds_n,
  input         rw,
  input  [16:0] addr,
  input   [7:0] din,
  output  [7:0] dout,
  output        dsack0_n,

  input         page,
  input         vsyncen_n,

  output        vidout,
  output reg    hsync_n,
  output reg    vsync_n,
  output reg    hblank,
  output reg    vblank,
  output reg    irq6_n
);

  localparam H_TOTAL      = 704;
  localparam H_ACTIVE     = 512;
  localparam [8:0] FIRST_LINE = 9'd1;
  localparam LAST_LINE    = FIRST_LINE + 342 - 1;
  localparam HSYNC_START  = 535;
  localparam HSYNC_END    = (HSYNC_START + 288) - H_TOTAL;
  localparam VSYNC_START  = 343;
  localparam VSYNC_END    = VSYNC_START + 4;

  reg  [9:0] hcnt;
  reg  [8:0] vcnt;
  wire       hctrrst = (hcnt == H_TOTAL - 1);
  wire       lctrrst = hctrrst && (vcnt == V_TOTAL - 1);
  wire [9:0] hcnt_next = hctrrst ? 10'd0 : hcnt + 10'd1;
  wire [8:0] vcnt_next = !hctrrst ? vcnt : lctrrst ? 9'd0 : vcnt + 9'd1;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin hcnt <= 0; vcnt <= 0; end
    else if (c16_en) begin hcnt <= hcnt_next; vcnt <= vcnt_next; end

  wire line_active_next = (vcnt_next >= FIRST_LINE) && (vcnt_next <= LAST_LINE);

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      hsync_n <= 1; vsync_n <= 1; hblank <= 1; vblank <= 1;
    end else if (c16_en) begin
      hsync_n <= !((hcnt_next >= HSYNC_START) || (hcnt_next < HSYNC_END));
      vsync_n <= !((vcnt_next >= VSYNC_START) && (vcnt_next < VSYNC_END));
      hblank  <= (hcnt_next >= H_ACTIVE);
      vblank  <= !line_active_next;
    end

  wire       rd_wrap   = (hcnt == H_TOTAL - 2);
  wire [8:0] rd_line   = rd_wrap ? (vcnt == V_TOTAL - 1 ? 9'd0 : vcnt + 9'd1) : vcnt;
  wire       rd_active = (rd_line >= FIRST_LINE) && (rd_line <= LAST_LINE);
  wire [9:0] hcnt_p2   = hcnt + 10'd2;
  wire [6:0] rd_byte   = rd_wrap ? 7'd0 : hcnt_p2[9:3];
  wire       rd_ok     = (hcnt[2:0] == 3'd6) && rd_active && (rd_byte < 64);
  wire [8:0] rd_row    = rd_line - FIRST_LINE + 9'd1;
  wire [15:0] scan_addr = {page, rd_row, rd_byte[5:0]};

  reg  [7:0] vram [0:65535];
  reg  [7:0] scan_q;
  reg        fetch;
  reg  [7:0] shreg;

  always @(posedge clk) if (c16_en) begin
    scan_q <= vram[scan_addr];
    fetch  <= rd_ok;
  end

  always @(posedge clk or negedge reset_n)
    if (!reset_n) shreg <= 8'hFF;
    else if (c16_en) begin
      if (fetch) shreg <= scan_q;
      else shreg <= {shreg[6:0], 1'b1};
    end

  assign vidout = shreg[7];

  reg  [7:0] declrom [0:8191];
  initial if (DECLROM_HEX != "") $readmemh(DECLROM_HEX, declrom);
  always @(posedge clk) if (declrom_we) declrom[declrom_waddr] <= declrom_wdata;

  wire access = sel && !as_n;

  localparam [4:0] IDLE_A = 5'd0,  IDLE_B = 5'd1,
                   ACC1   = 5'd2,  ACC2   = 5'd3,  ACK  = 5'd4,  ACC4 = 5'd5,  ACC5 = 5'd6,
                   XFER0  = 5'd8,  XFER20 = 5'd28, XFER_X = 5'd29;
  reg  [4:0] st;
  reg        xfer_done;
  wire       xfer_due = !hsync_n && !xfer_done;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin st <= IDLE_A; xfer_done <= 0; end
    else if (c16_en) begin
      if (hsync_n) xfer_done <= 0;
      case (st)
        IDLE_A:  st <= access ? ACC1 : IDLE_B;
        IDLE_B:  st <= xfer_due ? XFER0 : IDLE_A;
        ACC1:    st <= ACC2;
        ACC2:    st <= ACK;
        ACK:     st <= ACC4;
        ACC4:    st <= ACC5;
        ACC5:    st <= IDLE_B;
        XFER20:  st <= access ? XFER_X : IDLE_A;
        XFER_X:  st <= ACC1;
        default: begin
          st <= st + 5'd1;
          if (st == XFER20 - 1) xfer_done <= 1;
        end
      endcase
    end

  wire strobe = access && (st == ACC2 || st == ACK || st == ACC4);
  wire wr_vram = strobe && !ds_n && !rw && !addr[16];

  reg  [7:0] cpu_q, rom_q;
  always @(posedge clk) if (c16_en) begin
    if (wr_vram) vram[addr[15:0]] <= din;
    cpu_q <= vram[addr[15:0]];
    rom_q <= declrom[addr[12:0]];
  end

  assign dout     = addr[16] ? rom_q : cpu_q;
  assign dsack0_n = !(access && st == ACK);

  reg vsync_q;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin irq6_n <= 1; vsync_q <= 1; end
    else if (c16_en) begin
      vsync_q <= vsync_n;
      if (vsyncen_n)                    irq6_n <= 1;
      else if (!vsync_n && vsync_q)     irq6_n <= 0;
    end

endmodule
