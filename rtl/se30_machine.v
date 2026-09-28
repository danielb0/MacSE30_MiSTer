// se30_machine.v - the SE/30's logic board: the CPU, GLUE, the video, the
// two VIAs, the SWIM with its internal drive, the ADB with its keyboard
// and mouse, and the clock chip today; the ASC, SCC and SCSI as their
// sections land (SE30_PLAN.md 3.5, 4.8, 5.8, 6.6).
//
// WHAT IT IS
//   Everything of the machine that is not the MiSTer framework's, behind
//   one seam: MacSE30.sv (the emu shell) gives it the clocks, the reset,
//   the memory port to the SDRAM controller and the declaration ROM's
//   load, and takes the video; the full-system bench (sim/machine/) gives
//   it the same things without the framework.  Nothing in here knows about
//   hps_io, the scaler or the SDRAM pins.
//
// CLOCKS
//   clk is 2 x C16M (31.3344 MHz, the board's own oscillator); phi1 and
//   phi2 mark C16M's edges, one clk each, alternating.  The CPU wrapper
//   runs the 68030's states on that grid; GLUE and the video take c16_en =
//   phi1.  Nothing runs on any other clock.
//
// THE MEMORY PORT
//   GLUE's RAM and ROM ports, multiplexed onto the SDRAM controller's one
//   32-bit port: mem_start is the 68030's ECS with a RAM or ROM address
//   (GLUE's decode without AS*), mem_req is GLUE's request, and the
//   acknowledge with its data is the cycle's (plan 3.2, 3.3).  The
//   address is a longword address in the 32 MB: RAM at 0 (8 MB, GLUE's
//   flat address truncated), the ROM's 64K longwords at $200000.
//
// THE VIAs (plan 4.5, 4.7)
//   A port pin is OR where DDR says output and the external driver
//   otherwise, and a line nothing drives reads 1 - the 65C22's level,
//   which is what makes OVERLAY, PA6 (the box ID) and RAMSIZ read as the
//   ROM expects before it writes them.  GLUE and the video take the pins.
//   The RESET instruction resets the VIAs, RESET* being shared on the
//   board (2.11.6).
//
// THE SWIM (plan 5.3, 5.8, 5.12) - the register sets, the IWM's read path
//   and the internal FDHD.  The drives' SEL is VIA1 PA5 (HDSEL), not the
//   SWIM's HEDSEL; SENSE is the internal drive's line, and the absent
//   external drive's reads 1.  The RESET instruction resets the SWIM as
//   it does the VIAs; the drive is not on RESET* and sees only power-up.
//   The disk itself is outside: the drive's disk interface (disk_in,
//   eject, the cylinder and the track buffers' read port) goes to the
//   loader and the encoder in MacSE30.sv, beside hps_io and the SDRAM
//   (plan 5.12.12 item 7).
//
// THE ADB (plan 6.2-6.4, 6.6) - the transceiver is a PIC1654S running
//   Apple's program (boot2.rom, adb_pm_*), clocked by GLUE's C3M and reset
//   by RESET*; its INT* is VIA1 PB3, SCLK CB1, DIO CB2 both ways, ST1-ST0
//   PB5-PB4.  The line is the wired-AND of the transceiver and the two
//   devices - the Apple Extended Keyboard at 2 and the Apple Standard Mouse
//   at 3, fed from the PS/2 ports.  The devices see no machine reset,
//   only the line: RESET* holds the transceiver's latches high, which
//   holds the line low, which is an ADB Global Reset when it lasts 3 ms.
//
// THE CLOCK CHIP (plan 6.5) - on VIA1 PB2-PB0 (CS*, clock, data) and CA2
//   (1 Hz); its data line is the pin while it drives and the port's
//   otherwise.  Battery-backed: no reset reaches it.  Its time is the HPS's
//   TIMESTAMP, taken once.
//
// THE ASC (plan Section 7) - a stub until its section: the version, the
//   registers read back, the FIFOs always empty, SNDINT* (VIA2 CB1) in FIFO
//   mode only, so a System waiting on the chip does not hang; no sound.
//
// NOT HERE YET - what the VIAs' inputs and the device bus hold until
//   their sections: the SCC's W/REQ*, the SCSI's interrupt and DRQ lines,
//   all at their idle levels (plan 4.7); every other I/O device answers
//   $00 and raises no interrupt.

`timescale 1ns/1ps

module se30_machine #(
  parameter DECLROM_HEX = "",          // the video's declaration ROM preload, for the benches
  parameter V_TOTAL     = 370
) (
  input         clk,
  input         phi1,
  input         phi2,
  input         reset_n,

  // the memory port, to se30_sdram
  output        mem_start,
  output        mem_req,
  output        mem_we,
  output [22:0] mem_addr,
  output  [3:0] mem_be,
  output [31:0] mem_wdata,
  input  [31:0] mem_rdata,
  input         mem_ack,

  // the declaration ROM's load (boot1.rom)
  input         declrom_we,
  input  [12:0] declrom_waddr,
  input   [7:0] declrom_wdata,

  // video, 1 = black
  output        vidout,
  output        hsync_n,
  output        vsync_n,
  output        hblank,
  output        vblank,

  // the programmer's switch
  input         nmi_n,

  // the keyboard, the mouse and the time, from hps_io
  input  [10:0] ps2_key,
  input  [24:0] ps2_mouse,
  input  [32:0] timestamp,

  // the ADB transceiver's program (boot2.rom)
  input         adb_pm_we,
  input   [8:0] adb_pm_waddr,
  input  [11:0] adb_pm_wdata,

  // the internal drive's disk (se30_fdhd's disk interface; plan 5.12.5b)
  input         disk_in,               // the loader: a whole image is in SDRAM
  output        disk_eject,            // the drive's eject command: one clock
  output  [6:0] disk_cyl,              // the head's cylinder
  input   [6:0] trk_cyl,               // the encoder: the cylinder its buffers hold
  input         trk_valid,
  output [16:0] trk_addr,              // the cell under the head
  output        trk_side,
  input         trk_bit,               // its bit, a clock after trk_addr

  // for the probe deck and the benches
  output [31:0] dbg_addr,
  output  [2:0] dbg_fc,
  output        dbg_as_n,
  output        dbg_rw_n,
  output  [1:0] dbg_dsack_n,
  output        dbg_berr,
  output        dbg_halted,
  output        reset_out_n,           // the RESET instruction: the peripherals' reset
  output [31:0] dbg_via,               // {overlay, ramsiz, vsyncen_n, VIA1 IER, IFR, VIA2 IER, IFR} (plan 4.8)
  output [63:0] dbg_regs,              // {D6, D7}: the test manager's failure code and flags (plan 3.8 item 23)
  output [24:0] dbg_exc,               // {an exception taken, its vector, the opcode}: PEXC and PTRP (plan 5.12.12 item 8)
  output [63:0] dbg_swim,              // {the SWIM's 48, the drive's 16} (plan 5.8)
  output        dbg_swim_vread,        // the SWIM's valid data reads (PFLP counts them)
  output [63:0] dbg_adb,               // PADB: the transceiver's PIC, the line, the devices (plan 6.6)
  output [31:0] dbg_rtc                // PRTC: the clock chip (plan 6.6)
);

  // ---------------------------------------------------------- the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        ecs, cpu_as_n, cpu_ds_n, cpu_rw_n, berr, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .ecs(ecs), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .reset_out_n(reset_out_n), .halted(halted),
    .dbg_d6(dbg_regs[63:32]), .dbg_d7(dbg_regs[31:0]), .dbg_exc(dbg_exc));

  assign dbg_addr = cpu_addr;  assign dbg_fc = cpu_fc;  assign dbg_as_n = cpu_as_n;
  assign dbg_rw_n = cpu_rw_n;  assign dbg_dsack_n = dsack_n;  assign dbg_berr = berr;
  assign dbg_halted = halted;

  // ------------------------------------------------------------- GLUE
  wire        mem_early, rom_early;
  wire        ram_req, ram_we, ram_ack, rom_req, rom_ack, ram_refresh;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  wire        vid_dsack0_n, irq6_n, vid_sel;
  wire  [7:0] vid_dout;

  wire        overlay, vid_page, vsyncen_n, via1_irq_n, via2_irq_n;   // the VIAs' pins, below
  wire  [1:0] ramsiz;
  wire  [7:0] dev_rdata;
  wire        scc_irq_n = 1'b1;        // the SCC's, until its section

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .mem_early(mem_early), .rom_early(rom_early),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(mem_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(mem_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(vid_sel ? vid_dsack0_n : 1'b1), .slot_rdata(vid_dout),
    .via1_irq_n(via1_irq_n), .via2_irq_n(via2_irq_n), .scc_irq_n(scc_irq_n), .nmi_n(nmi_n),
    .slot_irq_n({irq6_n, 5'b11111}), .slot_irq_or_n(slot_irq_or_n),
    .overlay(overlay), .ramsiz(ramsiz), .hsync_n(hsync_n));

  // ------------------------------------------------- the memory port
  // one access a cycle, RAM or ROM by GLUE's decode; the controller's
  // acknowledge is both ports' (GLUE consults the one it requested)
  assign mem_start = ecs && mem_early;
  assign mem_req   = ram_req || rom_req;
  // R/W must be valid at the start: the controller decides read or write
  // there (se30_sdram's a_we), and R/W is valid at S0 with ECS, while
  // ram_req comes only with AS*. Gated by ram_req until plan 3.8 item 23,
  // every RAM write reached the controller as a read and was lost - the
  // ROM's RAM tests failed into the serial test manager on the board, and
  // the bench hid it behind unwritten RAM reading X. A ROM write stays a
  // no-op (GLUE acknowledges it).
  assign mem_we    = !rom_early && ram_we;
  assign mem_addr  = rom_early ? {2'b01, 5'b00000, rom_addr} : {2'b00, ram_addr[20:0]};
  assign mem_be    = ram_be;
  assign mem_wdata = ram_wdata;
  assign ram_ack   = mem_ack;
  assign rom_ack   = mem_ack;

  // ------------------------------------------------------------- VIAs
  wire        via_reset_n = reset_n && reset_out_n;
  wire        adb_int_n, adb_sclk, adb_dio, via1_cb2_out, via1_cb2_oe;   // VIA1 and the ADB transceiver
  wire        rtc_d_out, rtc_d_oe, rtc_1hz, rtc_d;                       // VIA1 and the clock chip
  wire  [7:0] via1_rdata, via2_rdata, swim_rdata, asc_rdata;
  wire        asc_irq_n;
  wire  [7:0] via1_pa_out, via1_pa_oe, via1_pb_out, via1_pb_oe;
  wire  [7:0] via2_pa_out, via2_pa_oe, via2_pb_out, via2_pb_oe;
  wire  [6:0] via1_ifr, via1_ier, via2_ifr, via2_ier;
  wire  [7:0] via1_pa_ext = 8'hFF;                       // PA7 SCCWREQ* idle; PA6-0 undriven (ALTVID, HDSEL, OVERLAY, SYNC out; PDS straps)
  wire  [7:0] via1_pb_ext = {4'b1111, adb_int_n, 2'b11, rtc_d};   // PB3 ADB-INT*, PB0 the clock's data; the rest undriven or outputs
  wire  [7:0] via2_pa_ext = {2'b11, irq6_n, 5'b11111};   // RAMSIZ undriven; IRQ*6 the video's latch; IRQ*5-1 the empty PDS
  wire  [7:0] via2_pb_ext = 8'b1011_0111;                // PB6 SNDEXT* and PB3 tied low; TM0A*/TM1A* the empty PDS
  wire  [7:0] via1_pa_pin = (via1_pa_oe & via1_pa_out) | (~via1_pa_oe & via1_pa_ext);
  wire  [7:0] via1_pb_pin = (via1_pb_oe & via1_pb_out) | (~via1_pb_oe & via1_pb_ext);
  wire  [7:0] via2_pa_pin = (via2_pa_oe & via2_pa_out) | (~via2_pa_oe & via2_pa_ext);
  wire  [7:0] via2_pb_pin = (via2_pb_oe & via2_pb_out) | (~via2_pb_oe & via2_pb_ext);
  assign overlay   = via1_pa_pin[4];
  assign vid_page  = via1_pa_pin[6];
  assign vsyncen_n = via1_pb_pin[6];
  assign ramsiz    = via2_pa_pin[7:6];
  assign dev_rdata = via1_sel ? via1_rdata : via2_sel ? via2_rdata : swim_sel ? swim_rdata :
                     asc_sel ? asc_rdata : 8'h00;
  assign dbg_via   = {overlay, ramsiz, vsyncen_n, via1_ier, via1_ifr, via2_ier, via2_ifr};

  se30_via via1 (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n), .e_clk(e_clk),
    .sel(via1_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via1_rdata), .irq_n(via1_irq_n),
    .pa_in(via1_pa_pin), .pa_out(via1_pa_out), .pa_oe(via1_pa_oe),
    .pb_in(via1_pb_pin), .pb_out(via1_pb_out), .pb_oe(via1_pb_oe),
    .ca1(via2_pb_pin[7]),                                // VBLK*: VIA2's PB7, T1's output
    .ca2_in(rtc_1hz), .ca2_out(), .ca2_oe(),             // RTC-1HZ
    .cb1_in(adb_sclk), .cb1_out(), .cb1_oe(),            // ADB-SCLK: the transceiver clocks the shift register
    .cb2_in(adb_dio), .cb2_out(via1_cb2_out), .cb2_oe(via1_cb2_oe),   // ADB-DIO
    .dbg_ifr(via1_ifr), .dbg_ier(via1_ier));

  se30_via via2 (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n), .e_clk(e_clk),
    .sel(via2_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via2_rdata), .irq_n(via2_irq_n),
    .pa_in(via2_pa_pin), .pa_out(via2_pa_out), .pa_oe(via2_pa_oe),
    .pb_in(via2_pb_pin), .pb_out(via2_pb_out), .pb_oe(via2_pb_oe),
    .ca1(slot_irq_or_n),                                 // SLOTIRQ*: GLUE's OR of the slot lines
    .ca2_in(1'b0), .ca2_out(), .ca2_oe(),                // SCSIDRQ: none until the SCSI section
    .cb1_in(asc_irq_n), .cb1_out(), .cb1_oe(),           // SNDINT*: the ASC stub's (plan 7.3)
    .cb2_in(1'b0), .cb2_out(), .cb2_oe(),                // SCSIIRQ
    .dbg_ifr(via2_ifr), .dbg_ier(via2_ier));

  // ------------------------------------------------------------- ADB
  wire        xcvr_pull, kbd_pull, mouse_pull;
  wire        adb_line = !(xcvr_pull | kbd_pull | mouse_pull);   // R31's pull-up, and everyone's pull-down
  wire [63:0] xcvr_dbg;
  wire [15:0] kbd_dbg, mouse_dbg;
  // falling edges on the line: ADB traffic at a glance
  reg  [15:0] adb_falls = 0;
  reg         adb_line_q = 1;
  always @(posedge clk) begin
    adb_line_q <= adb_line;
    if (adb_line_q && !adb_line) adb_falls <= adb_falls + 1'b1;
  end
  // PADB: {PIC PC, W, the line, INT*, SCLK, DIO, ST1, ST0, who pulls
  // (transceiver, keyboard, mouse), the keyboard's and mouse's engine
  // states, the last command the keyboard heard, the falls, 6'b0}
  assign dbg_adb = {xcvr_dbg[63:55], xcvr_dbg[54:47],
                    adb_line, adb_int_n, adb_sclk, adb_dio, via1_pb_pin[5], via1_pb_pin[4],
                    xcvr_pull, kbd_pull, mouse_pull,
                    kbd_dbg[15:12], mouse_dbg[15:12], kbd_dbg[11:4], adb_falls, 6'd0};

  se30_adb_xcvr xcvr (
    .clk(clk), .c16_en(phi1), .c3m_en(c3m_en), .reset_n(via_reset_n),
    .pm_we(adb_pm_we), .pm_waddr(adb_pm_waddr), .pm_wdata(adb_pm_wdata),
    .st0(via1_pb_pin[4]), .st1(via1_pb_pin[5]), .int_n(adb_int_n), .sclk(adb_sclk),
    .via_cb2_out(via1_cb2_out), .via_cb2_oe(via1_cb2_oe), .dio(adb_dio),
    .line(adb_line), .pull(xcvr_pull), .dbg(xcvr_dbg));

  se30_adb_kbd kbd (
    .clk(clk), .reset(1'b0), .ps2_key(ps2_key), .line(adb_line), .pull(kbd_pull), .dbg(kbd_dbg));

  se30_adb_mouse mouse (
    .clk(clk), .reset(1'b0), .ps2_mouse(ps2_mouse), .line(adb_line), .pull(mouse_pull), .dbg(mouse_dbg));

  // ------------------------------------------------------------- RTC
  assign      rtc_d = rtc_d_oe ? rtc_d_out : 1'b1;

  se30_rtc rtc (
    .clk(clk), .timestamp(timestamp),
    .cs_n(via1_pb_pin[2]), .sck(via1_pb_pin[1]), .d_in(via1_pb_pin[0]),
    .d_out(rtc_d_out), .d_oe(rtc_d_oe), .one_hz(rtc_1hz), .dbg(dbg_rtc));

  // ------------------------------------------------------------- ASC
  // a stub until its section (plan Section 7): version $00, registers read
  // back, the FIFOs always empty, SNDINT* in FIFO mode only; no sound
  se30_asc_stub asc (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n),
    .sel(asc_sel), .strobe(dev_strobe), .rw(dev_rw), .addr(dev_addr[11:0]), .wdata(dev_wdata),
    .rdata(asc_rdata), .irq_n(asc_irq_n));

  // ------------------------------------------------------------ SWIM
  wire  [3:0] swim_ph, swim_ph_oe;
  wire        enbl1_n, enbl2_n, fdhd_sense;
  wire [47:0] swim_dbg;
  wire [15:0] fdhd_dbg;
  wire  [3:0] swim_ph_pin = (swim_ph_oe & swim_ph) | ~swim_ph_oe;   // a line the ISM makes an input reads its pull-up
  wire        swim_sense  = fdhd_sense & 1'b1;                      // the external drive is absent: its line reads 1
  assign dbg_swim = {swim_dbg, fdhd_dbg};

  se30_swim swim (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n),
    .sel(swim_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .wdata(dev_wdata), .rdata(swim_rdata),
    .ph_out(swim_ph), .ph_oe(swim_ph_oe), .ph_in(swim_ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(swim_sense),
    .wrdata(), .wrreq_n(), .hdsel(),                                // HEDSEL goes to TP3 only
    .dbg(swim_dbg), .dbg_vread(dbg_swim_vread));

  se30_fdhd fdhd_int (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
    .sense(fdhd_sense), .disk_in(disk_in), .eject(disk_eject),
    .cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .dbg(fdhd_dbg));

  // ------------------------------------------------------------ video
  // slot $E: GLUE's slot select at $FExxxxxx (plan 2.10 item 2: A23-A17
  // are not decoded by the card; A16 picks the declaration ROM)
  assign vid_sel = slot_sel && (cpu_addr[31:24] == 8'hFE);

  se30_video #(.DECLROM_HEX(DECLROM_HEX), .V_TOTAL(V_TOTAL)) video (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
    .sel(vid_sel), .as_n(cpu_as_n), .ds_n(cpu_ds_n), .rw(cpu_rw_n), .addr(cpu_addr[16:0]),
    .din(dev_wdata), .dout(vid_dout), .dsack0_n(vid_dsack0_n),
    .page(vid_page), .vsyncen_n(vsyncen_n),
    .vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
    .irq6_n(irq6_n));

endmodule
