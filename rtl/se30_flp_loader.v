// se30_flp_loader.v - the internal drive's image: the HPS's block device
// into SDRAM at mount, and what disk it is (SE30_PLAN.md 5.12.5).
//
// WHERE IT COMES FROM
//   MacLC's floppy_loader (rtl/floppy_sd.v at 045f896), itself MacPlus's
//   floppy_loader.v (FLOPPY_WRITE_PLAN phase 1) with the DiskCopy 4.2 strip
//   added; its comments are kept where the logic is.  Four changes, each
//   in plan 5.12.5 "Read for item 5": a request waits for the last
//   acknowledge to fall; a mount during a load is kept and takes effect
//   between sectors; the DC42 header's data and tag sizes are read; and
//   the outputs are what the SE/30's drive and encoder need.  Held to
//   sim/flpload/tb_se30_flp_loader.v.
//
// WHAT IT DOES
//   On img_mounted it streams the whole image in through sd_rd, sector by
//   sector, staging each in a small BRAM and draining it through the disk
//   port to SDRAM: word BASE + k holds payload bytes 2k (high) and 2k+1
//   (low) - the payload being the file, or a DC42's file without its
//   84-byte header, so a DC42's tags follow its data.  disk_in rises only
//   when the whole image is resident (MacPlus phase 1: the Mac must never
//   see a partial image) and falls at the next mount pulse, an unmount, or
//   the drive's eject.
//
// WHAT DISK IT IS (MacPlus phase 7's three ceilings)
//   img_800k  the file's data is 819,200 bytes (raw, or a DC42's $40)
//   img_ds    img_800k and the medium says double-sided: the MDB's
//             drNmAlBlks x drAlBlkSiz over 1200 blocks, or no MDB to say
//             (the SuperDrive, the first ceiling, is always double-sided)
//   img_tags  a DC42 whose tag size ($44) is 12 bytes a block
//   disk_in   also needs a GCR geometry: 400K or 800K.  720K and 1440K
//             images load but are not a disk on rung 2 (plan 5.13).

`timescale 1ns/1ps

module se30_flp_loader #(
  parameter [23:0] BASE = 24'h800000
) (
  input             clk,
  input             reset_n,

  // HPS block device (this slot)
  input             img_mounted,       // one-shot mount pulse for this slot
  input      [63:0] img_size,          // valid at img_mounted; 0 = unmount
  input             img_readonly,      // valid at img_mounted

  output reg [31:0] sd_lba,
  output reg        sd_rd,
  input             sd_ack,
  input       [7:0] sd_buff_addr,      // the 512-byte block's word index
  input      [15:0] sd_buff_dout,
  input             sd_buff_wr,

  // the disk port (level request, level acknowledge)
  output reg        mem_req,
  output reg [23:0] mem_addr,
  output reg [15:0] mem_wdata,
  input             mem_ack,

  input             eject,             // the drive's eject: one clock

  output reg        disk_in,
  output reg        img_ds,
  output reg        img_800k,
  output reg        img_tags,
  output reg        readonly,
  output reg        loading,
  output     [15:0] dbg
);

  // sector staging RAM: load-then-drain rather than double-buffered, since
  // the SDRAM side is paced by the disk port
  reg [15:0] buf_ram [0:255];
  reg [15:0] buf_q;
  reg  [7:0] buf_idx;                  // the word buf_q was read from
  reg  [7:0] drain_idx;

  // Stored BYTE-SWAPPED: a block-device word packs exactly like a download
  // word (file byte 0 in the low half of hps_io's word), and the encoder
  // reads byte 2k in the high half.
  wire [15:0] sw_data = {sd_buff_dout[7:0], sd_buff_dout[15:8]};
  always @(posedge clk) begin
    if (sd_buff_wr && sd_ack) buf_ram[sd_buff_addr] <= sw_data;
    buf_q   <= buf_ram[drain_idx];
    buf_idx <= drain_idx;
  end

  localparam S_IDLE  = 3'd0;
  localparam S_RD    = 3'd1;           // sd_rd asserted, waiting for the sector
  localparam S_WAIT  = 3'd2;           // sd_ack fell: the sector is in buf_ram
  localparam S_DRAIN = 3'd3;           // push words to SDRAM
  localparam S_NEXT  = 3'd4;
  localparam S_DONE  = 3'd5;

  reg  [2:0] state;
  reg [31:0] sec_total;                // sectors to stream (the file size / 512, rounded up)
  reg [23:0] file_word;                // word index within the FILE
  reg [63:0] size_l;                   // the file's size, held from the pulse
  reg        dc42;                     // this image has a DiskCopy 4.2 header
  reg        dc42_name_ok;
  reg  [7:0] dc42_fmt;                 // $50: 0 400K, 1 800K, 2 720K, 3 1440K
  reg [31:0] dc42_dsize, dc42_tsize;   // $40, $44
  reg        old_ack;

  // a mount kept until it can take effect (MacPlus's mount_pending): at
  // once when idle, between sectors during a load
  reg        mount_pending;
  reg [63:0] pend_size;
  reg        pend_ro;

  // DC42 header words, sampled as sector 0 streams past. Tested on the RAW
  // delivered word, not the swapped one:
  //   word 0  byte 0  = d[7:0] : Pascal name length, 1..63
  //   words 32-35     = the data and tag sizes, big-endian ($40, $44)
  //   word 40 byte 80 = d[7:0] : disk-format byte (DC42 offset 0x50)
  //   word 41         = d      : the magic, 16'h0001
  localparam [23:0] DC42_HDR_WORDS = 24'd42;   // 84 bytes

  // medium sidedness sniff: 400K and 800K are the same medium, nothing on
  // the diskette records which it is, and the file's size cannot say (a
  // One-Sided erase of an 800K image leaves an 800K file). The Master
  // Directory Block is sector 2 on MFS and HFS alike, and its volume size
  // is drNmAlBlks * drAlBlkSiz. No usable MDB means double-sided, so an
  // unformatted or foreign medium is never capped.
  localparam [15:0] MDB_SIG_MFS = 16'hD2D7;
  localparam [15:0] MDB_SIG_HFS = 16'h4244;
  // volume size in 512-byte blocks, midway between 800 and 1600
  localparam [23:0] SIDEDNESS_THRESHOLD = 24'd1200;

  // word index within the SECTOR, not the file block: a DC42 header shifts
  // sector 2 down by 42 words. The wrap below 42 cannot alias 0/9/10/11.
  wire [8:0] mdb_idx = {1'b0, sd_buff_addr} - (dc42 ? 9'd42 : 9'd0);
  wire       mdb_wr  = (state == S_RD) && sd_buff_wr && sd_ack && (sd_lba == 32'd2);

  reg [15:0] mdb_sig;     // word 0:      drSigWord
  reg [15:0] mdb_nalbk;   // word 9:      drNmAlBlks
  reg [15:0] mdb_absz_h;  // words 10-11: drAlBlkSiz, big-endian
  reg [15:0] mdb_absz_l;
  reg        mdb_seen;    // sector 2 went by, so the four words are this image's

  // drAlBlkSiz is a non-zero multiple of 512, well under 64K on a floppy
  wire mdb_ok = mdb_seen &&
                ((mdb_sig == MDB_SIG_MFS) || (mdb_sig == MDB_SIG_HFS)) &&
                (mdb_absz_h == 16'd0) && (mdb_absz_l != 16'd0) &&
                (mdb_absz_l[8:0] == 9'd0) && (mdb_nalbk != 16'd0);

  // drNmAlBlks * (drAlBlkSiz / 512), shift-add over seven cycles
  reg [23:0] vol_blocks;
  reg [23:0] mul_cand;
  reg  [6:0] mul_mult;
  reg  [2:0] mul_step;
  reg        mul_busy;

  // what the file is, at S_DONE
  wire [31:0] data_size = dc42 ? dc42_dsize : size_l[31:0];
  wire        is800     = (data_size == 32'd819200) && (!dc42 || size_l[63:32] == 0);
  wire        is400     = (data_size == 32'd409600);
  wire        fits      = !dc42 || (size_l >= 64'd84 + data_size);          // the data is in the file
  wire        gcr       = (is800 || is400) && fits && (!dc42 || dc42_fmt < 8'd2) &&
                          (dc42 || size_l[63:32] == 0);
  wire [31:0] tags_want = is800 ? 32'd19200 : 32'd9600;                      // 12 bytes a block
  wire        tags_ok   = dc42 && dc42_tsize == tags_want && size_l >= 64'd84 + data_size + tags_want;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      state <= S_IDLE; sd_rd <= 0; sd_lba <= 0; mem_req <= 0; mem_addr <= 0; mem_wdata <= 0;
      loading <= 0; disk_in <= 0; img_ds <= 0; img_800k <= 0; img_tags <= 0; readonly <= 0;
      dc42 <= 0; dc42_name_ok <= 0; dc42_fmt <= 0; dc42_dsize <= 0; dc42_tsize <= 0;
      mount_pending <= 0; pend_size <= 0; pend_ro <= 0; size_l <= 0;
      sec_total <= 0; file_word <= 0; drain_idx <= 0; old_ack <= 0;
      mdb_seen <= 0; mdb_sig <= 0; mdb_nalbk <= 0; mdb_absz_h <= 0; mdb_absz_l <= 0;
      vol_blocks <= 0; mul_cand <= 0; mul_mult <= 0; mul_step <= 0; mul_busy <= 0;
    end else begin
      old_ack <= sd_ack;

      // a mount pulse is kept; the disk in goes out at once, and `loading`
      // (a load under way or waiting) rises with it, so it never dips
      // between an abandoned load and its successor
      if (img_mounted) begin
        mount_pending <= 1; pend_size <= img_size; pend_ro <= img_readonly;
        disk_in <= 0;
        if (img_size != 64'd0) loading <= 1;
      end
      if (eject) disk_in <= 0;

      // ── capture the DC42 signature and sizes as sector 0 streams in ──
      if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0) begin
        case (sd_buff_addr)
          8'd0:  dc42_name_ok <= (sd_buff_dout[7:0] >= 8'd1) && (sd_buff_dout[7:0] <= 8'd63);
          8'd32: dc42_dsize[31:16] <= sw_data;
          8'd33: dc42_dsize[15:0]  <= sw_data;
          8'd34: dc42_tsize[31:16] <= sw_data;
          8'd35: dc42_tsize[15:0]  <= sw_data;
          8'd40: dc42_fmt <= sd_buff_dout[7:0];      // DC42 byte 0x50
          8'd41: if (dc42_name_ok && sd_buff_dout == 16'h0001) dc42 <= 1;
          default: ;
        endcase
      end

      // ── the MDB's words as sector 2 streams in, and the multiply ──
      if (mdb_wr)
        case (mdb_idx)
          9'd0:  mdb_sig    <= sw_data;
          9'd9:  mdb_nalbk  <= sw_data;
          9'd10: mdb_absz_h <= sw_data;
          9'd11: begin mdb_absz_l <= sw_data; mdb_seen <= 1; end
          default: ;
        endcase
      if (mdb_wr && mdb_idx == 9'd11) begin
        vol_blocks <= 0; mul_cand <= {8'd0, mdb_nalbk}; mul_mult <= sw_data[15:9];
        mul_step <= 0; mul_busy <= 1;
      end else if (mul_busy) begin
        if (mul_mult[0]) vol_blocks <= vol_blocks + mul_cand;
        mul_cand <= {mul_cand[22:0], 1'b0};
        mul_mult <= {1'b0, mul_mult[6:1]};
        mul_step <= mul_step + 3'd1;
        if (mul_step == 3'd6) mul_busy <= 0;
      end

      case (state)

        S_IDLE:
          if (mount_pending && !img_mounted) begin
            mount_pending <= 0;
            readonly <= pend_ro;                     // latched at THIS slot's own pulse
            size_l   <= pend_size;
            dc42 <= 0; dc42_name_ok <= 0; dc42_fmt <= 0; dc42_dsize <= 0; dc42_tsize <= 0;
            mdb_seen <= 0; mul_busy <= 0; vol_blocks <= 0;
            img_ds <= 0; img_800k <= 0; img_tags <= 0;
            if (pend_size != 64'd0) begin
              // CEIL, not floor: a DC42 file is 84 + payload bytes and
              // never ends on a block boundary, so a floor drops the last
              // sector's tail. Main serves the partial block and the stale
              // remainder drains past the payload end, inside the floppy
              // region. Raw images are 512-multiples, so ceil == floor.
              sec_total <= pend_size[40:9] + {31'd0, |pend_size[8:0]};
              sd_lba    <= 32'd0;
              file_word <= 24'd0;
              loading   <= 1;
              sd_rd     <= 1;
              state     <= S_RD;
            end else loading <= 0;                   // unmount: the drive goes empty
          end

        S_RD: begin
          // hps_io raises sd_ack when it picks the transfer up and drops it
          // once the sector is delivered. Drop the request on the RISING
          // edge: held up for the whole transfer it is still asserted when
          // hps_io next samples it, and the same LBA re-issues.
          if (sd_ack) sd_rd <= 0;
          if (old_ack && !sd_ack) begin
            drain_idx <= 8'd0;
            state     <= S_WAIT;
          end
        end

        S_WAIT: state <= S_DRAIN;                    // one cycle for buf_ram's read port

        S_DRAIN: begin
          if (!mem_req) begin
            if (dc42 && file_word < DC42_HDR_WORDS) begin
              // Skip the DC42 header entirely: those words are not disk
              // data and must not shift the payload.
              file_word <= file_word + 24'd1;
              drain_idx <= drain_idx + 8'd1;
              if (drain_idx == 8'd255) state <= S_NEXT;
            end else if (!mem_ack && buf_idx == drain_idx) begin
              // the last acknowledge has fallen, and buf_q is this word's:
              // its read is registered, so a request on the clock after
              // drain_idx moved (the last header word skipped, or an
              // acknowledge that fell at once) would carry the one before
              mem_addr  <= BASE + (dc42 ? (file_word - DC42_HDR_WORDS) : file_word);
              mem_wdata <= buf_q;
              mem_req   <= 1;
            end
          end else if (mem_ack) begin
            mem_req   <= 0;
            file_word <= file_word + 24'd1;
            drain_idx <= drain_idx + 8'd1;
            if (drain_idx == 8'd255) state <= S_NEXT;
          end
        end

        S_NEXT: begin
          if (mount_pending) state <= S_IDLE;        // the newer mount wins
          else if (sd_lba + 32'd1 >= sec_total) state <= S_DONE;
          else begin
            sd_lba <= sd_lba + 32'd1;
            sd_rd  <= 1;
            state  <= S_RD;
          end
        end

        S_DONE:
          if (!mul_busy && !mem_req && !mem_ack) begin   // the verdict, and the last word acknowledged
            img_800k <= is800;
            img_ds   <= is800 && (!mdb_ok || vol_blocks > SIDEDNESS_THRESHOLD);
            img_tags <= tags_ok;
            // a mount pending, or arriving on this very clock (these
            // assignments come after the pulse's own and would undo them),
            // supersedes this image: not in, and still loading
            disk_in  <= gcr && !mount_pending && !img_mounted;
            if (!mount_pending && !img_mounted) loading <= 0;
            state    <= S_IDLE;
          end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign dbg = {disk_in, loading, img_ds, img_800k, img_tags, dc42, state, sd_lba[6:0]};

endmodule
