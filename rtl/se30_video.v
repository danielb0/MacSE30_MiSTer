// se30_video.v - the SE/30's pseudo-slot video: the six PALs, the two
// LS393 counters, the LS166 shifter, the 64KB VRAM and the 8KB declaration
// ROM of schematic sheet 5, as one module.
//
// WHAT IT IS
//   The SE/30 has no video controller chip.  Five PALs and a handful of
//   TTL make a fixed 512 x 342 one-bit display from a 64KB dual-port VRAM
//   that sits on the CPU bus as an 8-bit NuBus-style card in slot $E,
//   with an 8KB declaration ROM so the Slot Manager finds it (SE30_PLAN.md
//   2.6).  There are no registers: the only software-visible controls are
//   two VIA1 bits, page select (PA6) and retrace-interrupt enable (PB6),
//   which is exactly what the declaration ROM's driver touches (2.10).
//
// WHAT THE NUMBERS ARE, AND WHERE THEY COME FROM
//   Guide to the Macintosh Family Hardware 2e, ch. 12: 15.6672 MHz pixel
//   clock, 704 pixels per line (512 active), 370 lines per frame (342
//   active), 60.15 Hz, 1 = black, two pages, the alternate page selected
//   by VIA1 PA6.  Plan 2.9 and 2.12, from running the PAL equations
//   (scripts/se30_pals/palsim.py): counting pixel 0 as the clock after the
//   horizontal counter clears and line 0 as the first full line after the
//   frame clear, HSYNC* is low 288 pixels from pixel 535; lines 1-342 are
//   active; VSYNC* is low four lines from line 343; horizontal blanking is
//   the shifter clocking in ones.  Plan 2.10, from the driver: the first
//   visible row of a page is at offset $40, so line 1 shows VRAM row 1;
//   PA6 = 1 shows the upper 32KB (page 0); the declaration ROM is the
//   A16 = 1 half of the slot, mirrored every 8KB; the interrupt is set by
//   VSYNC* while PB6 = 0, held, and cleared by PB6 = 1.
//
//   One number is OPEN and is a parameter: V_TOTAL, 370 per the Guide;
//   Bolle's UG6 reads as 372 (plan 2.9).
//
// TIMING MODEL
//   Everything runs on C16M, one clock per pixel, as the PALs do: clk with
//   c16_en marking the C16M clocks (in the core clk is 2 x C16M and c16_en
//   is phi1, plan 3.2; the bench clocks it at C16M with c16_en high).  The
//   declaration ROM's write port (the boot1.rom download, plan 3.4) is the
//   one thing on clk alone.  "Clock" below means a C16M clock.
//   Pixel k of a line is on vidout during the clock in which the
//   horizontal count is k; hctrrst is high during the last clock of a line
//   (count 703) and lctrrst during the last clock of a frame.  A byte is
//   read from VRAM two clocks before its first pixel and loaded into the
//   shifter one clock before it, so the byte for pixel 0 is fetched at the
//   end of the previous line.  The shifter shifts in ones, so the 192
//   pixels after the last byte, and every line outside the active 342,
//   come out black without any gating - the LS166's pulled-up serial
//   input on the board (plan 2.9).
//
// THE SLOT PORT: UE7's STATE MACHINE (plan 2.12)
//   sel is GLUE's NUBUS* qualified by A31-A25 all ones and A24 = 0 (that
//   decode is GLUE's, not here).  UE7 is a five-bit machine on the pixel
//   clock whose behaviour, read by simulation, is:
//
//     idle      two states alternating every clock, IDLE_A and IDLE_B.
//     access    a request (sel with AS*) is taken only from IDLE_A: then
//               ACC1, ACC2, ACK, ACC4, ACC5, IDLE_B, IDLE_A.  DSACK0* is
//               low during ACK only - one clock, which the 68030 samples
//               at that clock's falling edge.  So an access is 5 clocks
//               (2 wait states) from IDLE_A or 6 from IDLE_B, and a
//               back-to-back access is 7 because the request has to wait
//               for IDLE_A to come round.  The VRAM is strobed during
//               ACC2..ACC4 (CAS), data is enabled on a read during ACC2
//               and ACK, written on a write during ACC2..ACC4.
//     transfer  once per line, at HSYNC* falling: from IDLE_B the machine
//               runs a 21-clock row-transfer sequence (the VRAMs' serial-
//               register load) during which requests wait; an access in
//               flight finishes first.  On exit a waiting request is
//               taken through one extra state (XFER_X), so DSACK0* for
//               anything requested during the window comes on a fixed
//               clock, 25 after the window opened.
//   The transfer is 21 clocks, odd, so the idle alternation's phase flips
//   every line; that is the real part's behaviour and is left as it is.
//   Read data is held through ACC4 (the board's DOE* releases one clock
//   earlier; the 68030 latches at the end of S4, inside ACK/ACC4 either
//   way).  Writes to the ROM half do nothing.  The VRAM is dual-ported
//   (as the board's 41264s are) so a CPU access never disturbs scan-out.
//
// INTERRUPT
//   irq6_n is UI6's latch (plan 2.9 item 3): set on the falling edge of
//   VSYNC* while vsyncen_n is low, held while it stays low, cleared when
//   it goes high.  Re-enabling during a VSYNC* that is already low does
//   not fire; the next falling edge does.  The driver's ISR acknowledges
//   by raising and lowering PB6 (2.10 item 1).

`timescale 1ns/1ps

module se30_video #(
  parameter DECLROM_HEX = "",          // $readmemh image of the 8KB declaration ROM
  parameter V_TOTAL     = 370          // lines per frame (Guide); 372 is plan 2.9's open item
) (
  input         clk,
  input         c16_en,                // one clk per C16M period (15.6672 MHz)
  input         reset_n,

  // the declaration ROM's load (boot1.rom), on clk
  input         declrom_we,
  input  [12:0] declrom_waddr,
  input   [7:0] declrom_wdata,

  // slot $E, 8-bit port on D31-D24
  input         sel,
  input         as_n,
  input         ds_n,
  input         rw,                    // 1 = read
  input  [16:0] addr,                  // A16 = 1 declaration ROM, 0 VRAM; A15-A0
  input   [7:0] din,
  output  [7:0] dout,
  output        dsack0_n,

  // VIA1
  input         page,                  // PA6: 1 = page 0 (VRAM $8000-$FFFF), 0 = page 1
  input         vsyncen_n,             // PB6: 0 = retrace interrupt enabled

  // video
  output        vidout,                // 1 = black
  output reg    hsync_n,
  output reg    vsync_n,
  output reg    hblank,
  output reg    vblank,
  output reg    irq6_n
);

  localparam H_TOTAL      = 704;
  localparam H_ACTIVE     = 512;
  localparam FIRST_LINE   = 1;                      // first active line of the frame
  localparam LAST_LINE    = FIRST_LINE + 342 - 1;   // 342
  localparam HSYNC_START  = 535;
  localparam HSYNC_END    = (HSYNC_START + 288) - H_TOTAL;   // 119, into the next line
  localparam VSYNC_START  = 343;
  localparam VSYNC_END    = VSYNC_START + 4;

  // ------------------------------------------------------------ counters
  reg  [9:0] hcnt;                     // 0..703
  reg  [8:0] vcnt;                     // 0..V_TOTAL-1
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

  // ------------------------------------------------------------ scan-out
  // Byte b of a line covers pixels 8b..8b+7.  Its VRAM read is issued in
  // the clock with count 8b-2 (count 702 of the previous line for b = 0),
  // the data is registered during 8b-1 and loaded into the shifter at the
  // end of that clock.  The line being displayed is the next one when the
  // read is for b = 0.
  wire       rd_wrap   = (hcnt == H_TOTAL - 2);
  wire [8:0] rd_line   = rd_wrap ? (vcnt == V_TOTAL - 1 ? 9'd0 : vcnt + 9'd1) : vcnt;
  wire       rd_active = (rd_line >= FIRST_LINE) && (rd_line <= LAST_LINE);
  wire [6:0] rd_byte   = rd_wrap ? 7'd0 : ((hcnt + 10'd2) >> 3);
  wire       rd_ok     = (hcnt[2:0] == 3'd6) && rd_active && (rd_byte < 64);
  wire [8:0] rd_row    = rd_line - FIRST_LINE + 9'd1;       // line 1 shows VRAM row 1 (offset $40)
  wire [15:0] scan_addr = {page, rd_row, rd_byte[5:0]};

  reg  [7:0] vram [0:65535];
  reg  [7:0] scan_q;
  reg        fetch;                    // the shifter load strobe, one clock after the read
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

  // ------------------------------------------------------------ slot port
  reg  [7:0] declrom [0:8191];
  initial if (DECLROM_HEX != "") $readmemh(DECLROM_HEX, declrom);
  always @(posedge clk) if (declrom_we) declrom[declrom_waddr] <= declrom_wdata;

  wire access = sel && !as_n;

  // UE7 as read in plan 2.12.  XFER states are numbered along the
  // 21-clock transfer sequence; the constants after them are the CPU
  // access path.
  localparam [4:0] IDLE_A = 5'd0,  IDLE_B = 5'd1,
                   ACC1   = 5'd2,  ACC2   = 5'd3,  ACK  = 5'd4,  ACC4 = 5'd5,  ACC5 = 5'd6,
                   XFER0  = 5'd8,  XFER20 = 5'd28, XFER_X = 5'd29;
  reg  [4:0] st;
  reg        xfer_done;                // this line's transfer has run; cleared when HSYNC* rises
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
        default: begin                 // XFER0..XFER19
          st <= st + 5'd1;
          if (st == XFER20 - 1) xfer_done <= 1;
        end
      endcase
    end

  wire strobe = access && (st == ACC2 || st == ACK || st == ACC4);   // the board's VC* (CAS)
  wire wr_vram = strobe && !ds_n && !rw && !addr[16];

  reg  [7:0] cpu_q, rom_q;
  always @(posedge clk) if (c16_en) begin
    if (wr_vram) vram[addr[15:0]] <= din;
    cpu_q <= vram[addr[15:0]];
    rom_q <= declrom[addr[12:0]];
  end

  assign dout     = addr[16] ? rom_q : cpu_q;
  assign dsack0_n = !(access && st == ACK);

  // ------------------------------------------------------------ interrupt
  reg vsync_q;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin irq6_n <= 1; vsync_q <= 1; end
    else if (c16_en) begin
      vsync_q <= vsync_n;
      if (vsyncen_n)                    irq6_n <= 1;
      else if (!vsync_n && vsync_q)     irq6_n <= 0;
    end

endmodule
