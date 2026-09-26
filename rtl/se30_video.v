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
//   by VIA1 PA6.  Plan 2.9, from the PAL reading: HSYNC* low 288 pixels
//   from pixel 536; active lines 2-343 of the frame; VSYNC* low four lines
//   from line 344; horizontal blanking is the shifter clocking in ones.
//   Plan 2.10, from the driver: the first visible row of a page is at
//   offset $40, so line 2 of the frame shows VRAM row 1; PA6 = 1 shows the
//   upper 32KB (page 0); the declaration ROM is the A16 = 1 half of the
//   slot, mirrored every 8KB; the interrupt is set by VSYNC* while PB6 = 0,
//   held, and cleared by PB6 = 1.
//
//   Two numbers are OPEN in the plan and are parameters here:
//     V_TOTAL   370 per the Guide; Bolle's UG6 reads as 372 (plan 2.9).
//     SLOT_ACK  clocks from the start of a slot access to DSACK0*.  UE7's
//               state machine has not been read (plan 2.11 row 15); the
//               bench measures what this gives and asserts only that it is
//               inside the bus-error window.
//
// TIMING MODEL
//   Everything runs on clk = C16M, one clock per pixel, as the PALs do.
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
//   The slot port is one 8-bit access at a time: sel (GLUE's NUBUS*
//   qualified by A31-A25 all ones and A24 = 0 - that decode is GLUE's,
//   not here) with AS* starts it; DSACK0* is driven low from clock
//   SLOT_ACK of the access and released with AS*.  Read data is valid from
//   the clock DSACK0* falls.  A write lands on the clock after the access
//   starts if DS* is asserted; writes to the ROM half do nothing.  The
//   VRAM is dual-ported (as the board's 41264s are) so a CPU access never
//   disturbs the scan-out.
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
  parameter V_TOTAL     = 370,         // lines per frame (Guide); 372 is plan 2.9's open item
  parameter SLOT_ACK    = 2            // clocks from access start to DSACK0* (open, plan 2.11 row 15)
) (
  input         clk,                   // C16M, 15.6672 MHz
  input         reset_n,

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
  localparam FIRST_LINE   = 2;                      // first active line of the frame
  localparam LAST_LINE    = FIRST_LINE + 342 - 1;   // 343
  localparam HSYNC_START  = 536;
  localparam HSYNC_END    = (HSYNC_START + 288) - H_TOTAL;   // 120, into the next line
  localparam VSYNC_START  = 344;
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
    else begin hcnt <= hcnt_next; vcnt <= vcnt_next; end

  wire line_active_next = (vcnt_next >= FIRST_LINE) && (vcnt_next <= LAST_LINE);

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      hsync_n <= 1; vsync_n <= 1; hblank <= 1; vblank <= 1;
    end else begin
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
  wire [8:0] rd_row    = rd_line - FIRST_LINE + 9'd1;       // line 2 shows VRAM row 1 (offset $40)
  wire [15:0] scan_addr = {page, rd_row, rd_byte[5:0]};

  reg  [7:0] vram [0:65535];
  reg  [7:0] scan_q;
  reg        fetch;                    // the shifter load strobe, one clock after the read
  reg  [7:0] shreg;

  always @(posedge clk) begin
    scan_q <= vram[scan_addr];
    fetch  <= rd_ok;
  end

  always @(posedge clk or negedge reset_n)
    if (!reset_n) shreg <= 8'hFF;
    else if (fetch) shreg <= scan_q;
    else shreg <= {shreg[6:0], 1'b1};

  assign vidout = shreg[7];

  // ------------------------------------------------------------ slot port
  reg  [7:0] declrom [0:8191];
  initial if (DECLROM_HEX != "") $readmemh(DECLROM_HEX, declrom);

  wire       access = sel && !as_n;
  reg  [3:0] acc;                      // clocks into the access, saturating
  reg  [7:0] cpu_q, rom_q;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) acc <= 0;
    else if (!access) acc <= 0;
    else if (acc != 4'hF) acc <= acc + 4'd1;

  wire wr_vram = access && (acc == 4'd1) && !ds_n && !rw && !addr[16];

  always @(posedge clk) begin
    if (wr_vram) vram[addr[15:0]] <= din;
    cpu_q <= vram[addr[15:0]];
    rom_q <= declrom[addr[12:0]];
  end

  assign dout     = addr[16] ? rom_q : cpu_q;
  assign dsack0_n = !(access && (acc >= SLOT_ACK));

  // ------------------------------------------------------------ interrupt
  reg vsync_q;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin irq6_n <= 1; vsync_q <= 1; end
    else begin
      vsync_q <= vsync_n;
      if (vsyncen_n)                    irq6_n <= 1;
      else if (!vsync_n && vsync_q)     irq6_n <= 0;
    end

endmodule
