// se30_flp_sdwriter.v - the image's written blocks back to the SD card,
// write-through (SE30_PLAN.md 5.15.5 item 6).
//
// WHERE IT COMES FROM
//   MacLC's floppy_sd_writer (rtl/floppy_sd.v, the floppy-write branch,
//   Daniel's PR #7, gated on the board), which it follows state for state
//   where the logic is the same.  Three changes: the queue holds FILE
//   blocks, not sectors, so a sector's tag blocks can be queued beside its
//   data (the LC never wrote tags; this machine's ROM writes them and the
//   encoder reads them back); a commit pushes every block it touched in
//   one go, and the decoder waits until there is room (back-pressure, not
//   loss); the eject flush recomputes the DiskCopy tag checksum as well as
//   the data checksum.  Held to sim/flpwr/tb_se30_flp_sdwriter.v.
//
// WHAT IT DOES
//   The decoder commits image block n (cm_done, cm_blk).  The file blocks
//   it touched are queued: its data at file byte 512n (+ 84, a DiskCopy
//   4.2 header shifting every sector across a block boundary: blocks n and
//   n + 1), and, when the image has tags, its 12 tag bytes at 84 + the
//   data region + 12n (one block, or two).  A block equal to the one last
//   queued is not queued again while that one still waits in the queue
//   (once the writer has taken it, the new words must go out again).
//   Each block is then filled from SDRAM -
//   block 0's first 42 words from the loader's header store, the 84 bytes
//   the image in SDRAM does not hold - and handed to hps_io (sd_wr, the
//   block at sd_lba, the words on sd_buff_din by sd_buff_addr).
//
// THE RULES (the MacPlus phase 5 review and the LC's 6D)
//   - hps_io takes sd_lba with one command and raises sd_ack with a later
//     one, the gap unbounded: a timeout PRESENTS THE SAME BLOCK AGAIN and
//     never retires it.
//   - A block past the file's end is retired unwritten.  The file's last
//     block may be partial (every DC42 ends mid-block): it is written
//     whole, and Main clips the write to the file (user_io.cpp).
//   - Nothing moves while the loader owns the slot and the image region.
//   - A mount empties the queue: hps_io's slot names the new file now, so
//     what was queued for the old one is dropped (the LC's rule).
//   - On the drive's eject, a DiskCopy image that was written has its data
//     checksum (header bytes 72-75) and tag checksum (76-79) recomputed
//     from SDRAM and header block 0 rewritten.  DiskCopy's sum: add the
//     big-endian word, rotate the 32 bits right by one; the tag sum skips
//     the first 12 tag bytes (DiskCopy's own quirk - secondary sources,
//     5.15.12).

`timescale 1ns/1ps

module se30_flp_sdwriter #(
  parameter [23:0] BASE = 24'h800000,
  parameter ACK_TIMEOUT_BITS = 24,     // ~0.5 s at clk_sys; the bench narrows it
  parameter QDEPTH_BITS      = 10      // 1024 blocks queued
) (
  input             clk,
  input             reset_n,

  input             img_mounted,       // this slot's mount pulse: the queue emptied
  input             loading,           // the loader owns the slot and the region
  input             write_ok,          // the image may be written
  input             dc42,              // a DiskCopy 4.2 container (84-byte header)
  input             img_tags,          // it carries tags
  input             img_800k,          // its data region is 819,200 bytes (else 409,600)
  input      [12:0] file_blks,         // the file's blocks, the partial last one counted

  input             cm_done,           // the decoder committed image block cm_blk
  input      [11:0] cm_blk,           // (12 bits: a 1.44 MB image's 2,880 blocks)
  output            cm_ready,          // there is room for a commit's blocks

  input             flush_req,         // one clock: the drive's eject

  output reg  [5:0] hdr_addr,          // the loader's header store
  input      [15:0] hdr_data,          // (registered: valid two clocks after hdr_addr)

  output reg        mem_req,           // the disk port: reads
  output reg [23:0] mem_addr,
  input      [15:0] mem_rdata,
  input             mem_ack,

  output reg [31:0] sd_lba,            // hps_io's block device (writes only)
  output reg        sd_wr,
  input             sd_ack,
  input       [7:0] sd_buff_addr,
  output     [15:0] sd_buff_din,

  output            busy,
  output     [31:0] dbg
);

  // ------------------------------------------------------------ the queue
  reg  [12:0] q_mem [0:(1<<QDEPTH_BITS)-1];
  reg [QDEPTH_BITS:0] wr_ptr, rd_ptr;
  wire [QDEPTH_BITS:0] count = wr_ptr - rd_ptr;
  wire        empty = (count == 0);
  reg  [12:0] q_head;                  // q_mem[rd_ptr], registered
  reg         empty_d;
  reg         push;
  reg  [12:0] push_blk;
  always @(posedge clk) begin
    if (push) q_mem[wr_ptr[QDEPTH_BITS-1:0]] <= push_blk;
    q_head  <= q_mem[rd_ptr[QDEPTH_BITS-1:0]];
    empty_d <= empty;
  end

  // a commit's blocks, pushed one a clock: data, its spill, the tags, theirs
  reg   [2:0] ps;                      // 0 idle, 1-4 the four candidates
  reg  [11:0] pn;                      // the image block being pushed
  reg  [12:0] last_pushed;
  reg         any_pushed;
  wire [19:0] t_off  = (img_800k ? 20'd819200 : 20'd409600) + {pn, 3'b000} + {pn, 2'b00} + 20'd84;  // tags' file offset
  wire [19:0] t_end  = t_off + 20'd11;
  reg  [12:0] cand;
  reg         cand_ok;
  always @* begin
    case (ps)
      3'd1:    begin cand = {1'b0, pn};           cand_ok = 1'b1;     end
      3'd2:    begin cand = {1'b0, pn} + 13'd1;   cand_ok = dc42;     end
      3'd3:    begin cand = t_off[19:9];          cand_ok = img_tags; end
      default: begin cand = t_end[19:9];          cand_ok = img_tags; end
    endcase
  end
  assign cm_ready = (ps == 3'd0) && !cm_done && (count <= (1 << QDEPTH_BITS) - 4);

  // ------------------------------------------------------------ the block buffer
  reg  [15:0] blk [0:255];
  reg         blk_we;
  reg   [7:0] blk_wa;
  reg  [15:0] blk_wd;
  reg  [15:0] blk_do;
  always @(posedge clk) begin
    if (blk_we) blk[blk_wa] <= blk_wd;
    blk_do <= blk[sd_buff_addr];
  end
  assign sd_buff_din = {blk_do[7:0], blk_do[15:8]};   // even byte low, as hps_io's words are

  // ------------------------------------------------------------ the states
  localparam P_IDLE  = 4'd0, P_SKIP  = 4'd1, P_ADDR  = 4'd2, P_HWAIT = 4'd3, P_HDR   = 4'd4,
             P_REQ   = 4'd5, P_TURN  = 4'd6, P_WR    = 4'd7, P_ACK   = 4'd8, P_DONE  = 4'd9,
             F_SZ0   = 4'd10, F_SZ1  = 4'd11, F_SZ2  = 4'd12, F_SZ3  = 4'd13, F_SCAN = 4'd14,
             F_TURN  = 4'd15;
  reg   [3:0] pst;
  reg  [12:0] cur;                     // the file block being written
  reg   [8:0] w;                       // its word
  reg         hdr_wr;                  // the flush's block 0
  reg         dirty;                   // a block of ours reached the card this mount
  reg         flush_pending;
  reg         abort;                   // a mount came mid-block: drop it at the next quiet clock
  reg  [31:0] dsum, tsum;              // the checksums
  reg  [31:0] dsize, tsize;            // from the header
  reg  [20:0] sw;                      // the scan's word
  reg         s_tags;                  // the scan is in the tags
  reg  [ACK_TIMEOUT_BITS-1:0] ack_t;
  reg  [15:0] n_blocks;
  reg   [7:0] n_flush, n_retry;

  wire        hdr_src  = dc42 && (cur == 13'd0) && (w < 9'd42);
  wire [23:0] pay_word = {3'd0, cur, w[7:0]} - (dc42 ? 24'd42 : 24'd0);
  wire        head_ok  = (q_head < file_blks);
  wire [31:0] add      = (s_tags ? tsum : dsum) + {16'd0, mem_rdata};
  wire [20:0] d_words  = dsize[21:1];
  wire [20:0] t_words  = (tsize > 32'd12) ? tsize[21:1] - 21'd6 : 21'd0;   // the tags past the first 12 bytes

  assign busy = (pst != P_IDLE) || !empty || flush_pending || (ps != 3'd0);

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wr_ptr <= 0; rd_ptr <= 0; push <= 0; push_blk <= 0; ps <= 0; pn <= 0;
      last_pushed <= 0; any_pushed <= 0;
      pst <= P_IDLE; cur <= 0; w <= 0; hdr_wr <= 0; dirty <= 0; flush_pending <= 0; abort <= 0;
      dsum <= 0; tsum <= 0; dsize <= 0; tsize <= 0; sw <= 0; s_tags <= 0; ack_t <= 0;
      mem_req <= 0; mem_addr <= 0; hdr_addr <= 0; sd_lba <= 0; sd_wr <= 0;
      blk_we <= 0; blk_wa <= 0; blk_wd <= 0;
      n_blocks <= 0; n_flush <= 0; n_retry <= 0;
    end else begin
      blk_we <= 0;
      push   <= 0;

      // ── the commits' blocks into the queue ──
      if (push) wr_ptr <= wr_ptr + 1'b1;
      if (cm_done && ps == 3'd0 && write_ok) begin pn <= cm_blk; ps <= 3'd1; end
      else if (ps != 3'd0) begin
        // a block equal to the last one queued is skipped only while that
        // one still waits in the queue (it will be read from SDRAM after
        // this commit's words are there); once the writer has taken it,
        // it goes in again - adjacent DC42 sectors share a file block, and
        // MFM's 1:1 writes commit them ~11 ms apart (board gate 3,
        // 2026-10-06: the second sector's first 428 bytes were lost).  A
        // block taken by the writer is always read after this commit's
        // words reached SDRAM (the decoder writes them before cm_done), so
        // "still queued" is the whole condition; `push` covers an entry
        // whose push is still on its way (the writer never takes one then)
        if (cand_ok && !(any_pushed && cand == last_pushed && (count != 0 || push))) begin
          push <= 1; push_blk <= cand; last_pushed <= cand; any_pushed <= 1;
        end
        ps <= (ps == 3'd4) ? 3'd0 : ps + 1'b1;
      end

      if (flush_req && dc42 && (dirty || !empty || pst != P_IDLE || ps != 3'd0))
        flush_pending <= 1;

      case (pst)
        P_IDLE:
          if (flush_pending && empty && ps == 3'd0 && !push && !loading) begin
            if (dirty) begin hdr_addr <= 6'd32; pst <= F_SZ0; end
            else flush_pending <= 0;
          end else if (!empty && !empty_d && !loading && !push) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (!head_ok) pst <= P_SKIP;     // past the file: retired unwritten
            else begin cur <= q_head; hdr_wr <= 0; w <= 0; pst <= P_ADDR; end
          end

        P_SKIP: pst <= P_IDLE;               // q_head catches up with rd_ptr

        // ── fill the block buffer ──
        P_ADDR:
          if (hdr_src) begin hdr_addr <= w[5:0]; pst <= P_HWAIT; end
          else begin mem_addr <= BASE + pay_word; pst <= P_REQ; end
        P_HWAIT: pst <= P_HDR;               // the store's read is registered
        P_HDR: begin
          blk_wa <= w[7:0]; blk_we <= 1;
          blk_wd <= (hdr_wr && w == 9'd36) ? dsum[31:16] : (hdr_wr && w == 9'd37) ? dsum[15:0]
                  : (hdr_wr && w == 9'd38) ? tsum[31:16] : (hdr_wr && w == 9'd39) ? tsum[15:0]
                  : hdr_data;
          w <= w + 1'b1;
          pst <= (w == 9'd255) ? P_WR : P_ADDR;
        end
        P_REQ: begin
          if (!mem_ack) mem_req <= 1;        // never over a stale acknowledge
          if (mem_req && mem_ack) begin
            blk_wa <= w[7:0]; blk_wd <= mem_rdata; blk_we <= 1;
            mem_req <= 0; pst <= P_TURN;
          end
        end
        P_TURN: if (!mem_ack) begin
          w <= w + 1'b1;
          pst <= (w == 9'd255) ? P_WR : P_ADDR;
        end

        // ── hand the block to hps_io ──
        P_WR: begin sd_lba <= {19'd0, cur}; sd_wr <= 1; ack_t <= 0; pst <= P_ACK; end
        P_ACK:
          if (sd_ack) begin sd_wr <= 0; pst <= P_DONE; end
          else if (&ack_t) begin              // present the same block again; never retire it
            sd_wr <= 0; n_retry <= n_retry + 1'b1; pst <= P_WR;
          end else ack_t <= ack_t + 1'b1;
        P_DONE:
          if (!sd_ack) begin
            n_blocks <= n_blocks + 1'b1;
            if (abort) abort <= 0;            // the old file's: the new one is not dirty
            else if (hdr_wr) begin hdr_wr <= 0; flush_pending <= 0; dirty <= 0; n_flush <= n_flush + 1'b1; end
            else dirty <= 1;
            pst <= P_IDLE;
          end

        // ── the eject flush: the sizes from the header, the sums from SDRAM ──
        F_SZ0: begin hdr_addr <= 6'd33; pst <= F_SZ1; end
        F_SZ1: begin dsize[31:16] <= hdr_data; hdr_addr <= 6'd34; pst <= F_SZ2; end
        F_SZ2: begin dsize[15:0]  <= hdr_data; hdr_addr <= 6'd35; pst <= F_SZ3; end
        F_SZ3: begin
          tsize[31:16] <= hdr_data;          // word 34; word 35 arrives next clock
          dsum <= 0; tsum <= 0; sw <= 0; s_tags <= 0;
          pst <= F_SCAN;
        end
        F_SCAN: begin
          if (sw == 21'd0 && !s_tags) tsize[15:0] <= hdr_data;   // word 35
          if (!s_tags && sw == d_words) begin
            s_tags <= 1; sw <= 0;
          end else if (s_tags && sw >= t_words) begin
            cur <= 13'd0; w <= 0; hdr_wr <= 1; pst <= P_ADDR;    // block 0, the sums in
          end else begin
            if (!mem_ack) mem_req <= 1;
            mem_addr <= s_tags ? BASE + {3'd0, d_words} + 24'd6 + {3'd0, sw} : BASE + {3'd0, sw};
            if (mem_req && mem_ack) begin
              if (s_tags) tsum <= {add[0], add[31:1]};
              else        dsum <= {add[0], add[31:1]};
              mem_req <= 0; pst <= F_TURN;
            end
          end
        end
        F_TURN: if (!mem_ack) begin sw <= sw + 1'b1; pst <= F_SCAN; end

        default: pst <= P_IDLE;
      endcase

      // a mount: the queue and the flush belong to the old file.  A block
      // not yet picked up by hps_io is withdrawn (its slot names the new
      // file now; a read's sd_ack must not be taken for it), and a request
      // about to rise is cancelled - mem_req is low this clock, so nothing
      // is torn down.  A word in flight finishes first (`abort`, taken at
      // the next quiet clock); a block hps_io has already acknowledged runs
      // to its end without marking the new file written.
      if (abort && !mem_req && !mem_ack && pst != P_DONE && !(pst == P_ACK && sd_ack)) begin
        pst <= P_IDLE; sd_wr <= 0; abort <= 0;
      end
      if (img_mounted) begin
        rd_ptr <= wr_ptr + (push ? 1'b1 : 1'b0); flush_pending <= 0; dirty <= 0; any_pushed <= 0;
        ps <= 0; hdr_wr <= 0;
        if (pst != P_IDLE) abort <= 1;
        if (pst != P_IDLE && pst != P_DONE && !mem_req && !sd_ack) begin
          pst <= P_IDLE; mem_req <= 0; sd_wr <= 0; abort <= 0;
        end
      end
    end
  end

  assign dbg = {n_blocks, n_flush, n_retry[3:0], count[3:0]};

endmodule
