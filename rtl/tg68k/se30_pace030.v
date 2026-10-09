// se30_pace030.v - the paced kernel's instruction timing, generated from the MC68030 User's
// Manual's Section 11.6 tables: for an opcode word, the EA and operation parts of UM Equation
// 11-2 as head, tail and I-cache-case clocks.

`timescale 1ns/1ps

module se30_pace030 (
  input  [15:0] op,
  output reg        ea_on,
  output reg        ea_ophead,
  output reg  [4:0] ea_h,
  output reg  [1:0] ea_t,
  output reg  [5:0] ea_cc,
  output reg  [4:0] op_h,
  output reg  [1:0] op_t,
  output reg  [6:0] op_cc,
  output reg  [6:0] op_cc_t,
  output reg  [1:0] br,
  output reg  [1:0] mvm,
  output reg  [7:0] row        // the pattern that matched (gen_pace030.py's order, 255 none): the profile's
);

  function [13:0] f_fea;   // {ophead, h[4:0], t[1:0], cc[5:0]}
    input [2:0] mode; input [2:0] rg; input lsz;
    begin
      case (mode)
        3'd0: f_fea = {1'b0, 5'd0, 2'd0, 6'd0};
        3'd1: f_fea = {1'b0, 5'd0, 2'd0, 6'd0};
        3'd2: f_fea = {1'b0, 5'd1, 2'd1, 6'd3};
        3'd3: f_fea = {1'b0, 5'd0, 2'd1, 6'd3};
        3'd4: f_fea = {1'b0, 5'd2, 2'd2, 6'd4};
        3'd5: f_fea = {1'b0, 5'd2, 2'd2, 6'd4};
        3'd6: f_fea = {1'b0, 5'd4, 2'd2, 6'd6};
        3'd7: case (rg)
          3'd0: f_fea = {1'b0, 5'd2, 2'd2, 6'd4};
          3'd1: f_fea = {1'b0, 5'd1, 2'd0, 6'd4};
          3'd2: f_fea = {1'b0, 5'd2, 2'd2, 6'd4};
          3'd3: f_fea = {1'b0, 5'd4, 2'd2, 6'd6};
          3'd4: f_fea = lsz ? {1'b0, 5'd4, 2'd0, 6'd4} : {1'b0, 5'd2, 2'd0, 6'd2};
          default: f_fea = 14'd0;
        endcase
        default: f_fea = 14'd0;
      endcase
    end
  endfunction

  function [13:0] f_fiea;   // {ophead, h[4:0], t[1:0], cc[5:0]}
    input [2:0] mode; input [2:0] rg; input lsz;
    begin
      case (mode)
        3'd0: f_fiea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd1: f_fiea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd2: f_fiea = lsz ? {1'b0, 5'd1, 2'd0, 6'd4} : {1'b0, 5'd1, 2'd1, 6'd3};
        3'd3: f_fiea = lsz ? {1'b0, 5'd4, 2'd1, 6'd7} : {1'b0, 5'd2, 2'd1, 6'd5};
        3'd4: f_fiea = lsz ? {1'b0, 5'd2, 2'd0, 6'd4} : {1'b0, 5'd2, 2'd2, 6'd4};
        3'd5: f_fiea = lsz ? {1'b0, 5'd4, 2'd0, 6'd6} : {1'b0, 5'd2, 2'd0, 6'd4};
        3'd6: f_fiea = lsz ? {1'b0, 5'd8, 2'd2, 6'd10} : {1'b0, 5'd6, 2'd2, 6'd8};
        3'd7: case (rg)
          3'd0: f_fiea = lsz ? {1'b0, 5'd6, 2'd2, 6'd8} : {1'b0, 5'd4, 2'd2, 6'd6};
          3'd1: f_fiea = lsz ? {1'b0, 5'd5, 2'd0, 6'd8} : {1'b0, 5'd3, 2'd0, 6'd6};
          3'd2: f_fiea = lsz ? {1'b0, 5'd4, 2'd0, 6'd6} : {1'b0, 5'd2, 2'd0, 6'd4};
          3'd3: f_fiea = lsz ? {1'b0, 5'd8, 2'd2, 6'd10} : {1'b0, 5'd6, 2'd2, 6'd8};
          3'd4: f_fiea = {1'b1, 5'd6, 2'd0, 6'd6};
          default: f_fiea = 14'd0;
        endcase
        default: f_fiea = 14'd0;
      endcase
    end
  endfunction

  function [13:0] f_cea;   // {ophead, h[4:0], t[1:0], cc[5:0]}
    input [2:0] mode; input [2:0] rg; input lsz;
    begin
      case (mode)
        3'd0: f_cea = {1'b0, 5'd0, 2'd0, 6'd0};
        3'd1: f_cea = {1'b0, 5'd0, 2'd0, 6'd0};
        3'd2: f_cea = {1'b1, 5'd2, 2'd0, 6'd2};
        3'd3: f_cea = {1'b0, 5'd0, 2'd0, 6'd2};
        3'd4: f_cea = {1'b1, 5'd2, 2'd0, 6'd2};
        3'd5: f_cea = {1'b1, 5'd2, 2'd0, 6'd2};
        3'd6: f_cea = {1'b1, 5'd4, 2'd0, 6'd4};
        3'd7: case (rg)
          3'd0: f_cea = {1'b1, 5'd2, 2'd0, 6'd2};
          3'd1: f_cea = {1'b1, 5'd4, 2'd0, 6'd4};
          3'd2: f_cea = {1'b1, 5'd2, 2'd0, 6'd2};
          3'd3: f_cea = {1'b1, 5'd4, 2'd0, 6'd4};
          default: f_cea = 14'd0;
        endcase
        default: f_cea = 14'd0;
      endcase
    end
  endfunction

  function [13:0] f_ciea;   // {ophead, h[4:0], t[1:0], cc[5:0]}
    input [2:0] mode; input [2:0] rg; input lsz;
    begin
      case (mode)
        3'd0: f_ciea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd1: f_ciea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd2: f_ciea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd3: f_ciea = lsz ? {1'b0, 5'd4, 2'd0, 6'd6} : {1'b0, 5'd2, 2'd0, 6'd4};
        3'd4: f_ciea = lsz ? {1'b1, 5'd4, 2'd0, 6'd4} : {1'b1, 5'd2, 2'd0, 6'd2};
        3'd5: f_ciea = lsz ? {1'b1, 5'd6, 2'd0, 6'd6} : {1'b1, 5'd4, 2'd0, 6'd4};
        3'd6: f_ciea = lsz ? {1'b1, 5'd8, 2'd0, 6'd8} : {1'b1, 5'd6, 2'd0, 6'd6};
        3'd7: case (rg)
          3'd0: f_ciea = lsz ? {1'b1, 5'd6, 2'd0, 6'd6} : {1'b1, 5'd4, 2'd0, 6'd4};
          3'd1: f_ciea = lsz ? {1'b1, 5'd8, 2'd0, 6'd8} : {1'b1, 5'd6, 2'd0, 6'd6};
          3'd2: f_ciea = lsz ? {1'b1, 5'd6, 2'd0, 6'd6} : {1'b1, 5'd4, 2'd0, 6'd4};
          3'd3: f_ciea = lsz ? {1'b1, 5'd8, 2'd0, 6'd8} : {1'b1, 5'd6, 2'd0, 6'd6};
          default: f_ciea = 14'd0;
        endcase
        default: f_ciea = 14'd0;
      endcase
    end
  endfunction

  function [13:0] f_jea;   // {ophead, h[4:0], t[1:0], cc[5:0]}
    input [2:0] mode; input [2:0] rg; input lsz;
    begin
      case (mode)
        3'd2: f_jea = {1'b1, 5'd2, 2'd0, 6'd2};
        3'd5: f_jea = {1'b1, 5'd4, 2'd0, 6'd4};
        3'd6: f_jea = {1'b1, 5'd6, 2'd0, 6'd6};
        3'd7: case (rg)
          3'd0: f_jea = {1'b1, 5'd2, 2'd0, 6'd2};
          3'd1: f_jea = {1'b1, 5'd2, 2'd0, 6'd2};
          3'd2: f_jea = {1'b1, 5'd4, 2'd0, 6'd4};
          3'd3: f_jea = {1'b1, 5'd6, 2'd0, 6'd6};
          default: f_jea = 14'd0;
        endcase
        default: f_jea = 14'd0;
      endcase
    end
  endfunction

  reg  [2:0] tbl;      // 0 none, 1 fea, 2 fiea, 3 cea, 4 ciea, 5 jea
  reg  [2:0] szs;      // the immediate's size: 0 from op[7:6], 1 .B, 2 .W, 3 .L, 4 MOVE's op[13:12]
  wire       lsz = (szs == 3'd0) ? (op[7:6] == 2'b10) : (szs == 3'd4) ? (op[13:12] == 2'b10) : (szs == 3'd3);
  reg [13:0] ea;

  always @* begin
    tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd0; op_cc_t = 7'd0; br = 2'd0; mvm = 2'd0; row = 8'd255;
    casez (op)
      16'b0000000000111100: begin row = 8'd0; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ORI to CCR
      16'b0000000001111100: begin row = 8'd1; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ORI to SR
      16'b0000001000111100: begin row = 8'd2; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ANDI to CCR
      16'b0000001001111100: begin row = 8'd3; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ANDI to SR
      16'b0000101000111100: begin row = 8'd4; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // EORI to CCR
      16'b0000101001111100: begin row = 8'd5; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // EORI to SR
      16'b0000100000000???: begin row = 8'd6; tbl = 3'd2; szs = 3'd2; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // BTST #,Dn
      16'b0000100000??????: begin row = 8'd7; tbl = 3'd2; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // BTST #,Mem
      16'b0000100001000???: begin row = 8'd8; tbl = 3'd2; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCHG #,Dn
      16'b0000100001??????: begin row = 8'd9; tbl = 3'd2; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCHG #,Mem
      16'b0000100010000???: begin row = 8'd10; tbl = 3'd2; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCLR #,Dn
      16'b0000100010??????: begin row = 8'd11; tbl = 3'd2; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCLR #,Mem
      16'b0000100011000???: begin row = 8'd12; tbl = 3'd2; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BSET #,Dn
      16'b0000100011??????: begin row = 8'd13; tbl = 3'd2; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BSET #,Mem
      16'b00001110????????: begin row = 8'd14; tbl = 3'd4; szs = 3'd2; op_h = 5'd3; op_t = 2'd0; op_cc = 7'd7; op_cc_t = 7'd7; end   // MOVES EA,Rn
      16'b00001??011111100: begin row = 8'd15; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd24; op_cc_t = 7'd24; end   // CAS2 success
      16'b00001??011??????: begin row = 8'd16; tbl = 3'd4; szs = 3'd2; op_h = 5'd1; op_t = 2'd0; op_cc = 7'd13; op_cc_t = 7'd13; end   // CAS success
      16'b00000??011??????: begin row = 8'd17; tbl = 3'd2; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd20; op_cc_t = 7'd20; end   // CMP2 EA,Rn
      16'b00000000??000???: begin row = 8'd18; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ORI #,Dn
      16'b00000000????????: begin row = 8'd19; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // ORI #,Mem
      16'b00000010??000???: begin row = 8'd20; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ANDI #,Dn
      16'b00000010????????: begin row = 8'd21; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // ANDI #,Mem
      16'b00000100??000???: begin row = 8'd22; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUBI #,Dn
      16'b00000100????????: begin row = 8'd23; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // SUBI #,Mem
      16'b00000110??000???: begin row = 8'd24; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADDI #,Dn
      16'b00000110????????: begin row = 8'd25; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // ADDI #,Mem
      16'b00001010??000???: begin row = 8'd26; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // EORI #,Dn
      16'b00001010????????: begin row = 8'd27; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // EORI #,Mem
      16'b00001100??000???: begin row = 8'd28; tbl = 3'd2; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // CMPI #,Dn
      16'b00001100????????: begin row = 8'd29; tbl = 3'd2; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // CMPI #,Mem
      16'b0000???10?001???: begin row = 8'd30; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // MOVEP.W (d16,An),Dn
      16'b0000???11?001???: begin row = 8'd31; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // MOVEP.W Dn,(d16,An)
      16'b0000???100000???: begin row = 8'd32; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // BTST Dn,Dn
      16'b0000???100??????: begin row = 8'd33; tbl = 3'd1; szs = 3'd1; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // BTST Dn,Mem
      16'b0000???101000???: begin row = 8'd34; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCHG Dn,Dn
      16'b0000???101??????: begin row = 8'd35; tbl = 3'd1; szs = 3'd1; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCHG Dn,Mem
      16'b0000???110000???: begin row = 8'd36; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCLR Dn,Dn
      16'b0000???110??????: begin row = 8'd37; tbl = 3'd1; szs = 3'd1; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BCLR Dn,Mem
      16'b0000???111000???: begin row = 8'd38; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BSET Dn,Dn
      16'b0000???111??????: begin row = 8'd39; tbl = 3'd1; szs = 3'd1; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BSET Dn,Mem
      16'b0001???000??????: begin row = 8'd40; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,Dn
      16'b0001???001??????: begin row = 8'd41; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,An
      16'b0001???01000????: begin row = 8'd42; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)
      16'b0001???010??????: begin row = 8'd43; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)
      16'b0001???01100????: begin row = 8'd44; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)+
      16'b0001???011??????: begin row = 8'd45; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)+
      16'b0001???10000????: begin row = 8'd46; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd2; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE Rn,-(An)
      16'b0001???100??????: begin row = 8'd47; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,-(An)
      16'b0001???101??????: begin row = 8'd48; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(d16,An)
      16'b0001???110??????: begin row = 8'd49; tbl = 3'd1; szs = 3'd4; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(d8,An,Xn)
      16'b0001000111??????: begin row = 8'd50; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(xxx).W
      16'b0001001111??????: begin row = 8'd51; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(xxx).L
      16'b0011???000??????: begin row = 8'd52; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,Dn
      16'b0011???001??????: begin row = 8'd53; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,An
      16'b0011???01000????: begin row = 8'd54; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)
      16'b0011???010??????: begin row = 8'd55; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)
      16'b0011???01100????: begin row = 8'd56; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)+
      16'b0011???011??????: begin row = 8'd57; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)+
      16'b0011???10000????: begin row = 8'd58; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd2; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE Rn,-(An)
      16'b0011???100??????: begin row = 8'd59; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,-(An)
      16'b0011???101??????: begin row = 8'd60; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(d16,An)
      16'b0011???110??????: begin row = 8'd61; tbl = 3'd1; szs = 3'd4; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(d8,An,Xn)
      16'b0011000111??????: begin row = 8'd62; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(xxx).W
      16'b0011001111??????: begin row = 8'd63; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(xxx).L
      16'b0010???000??????: begin row = 8'd64; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,Dn
      16'b0010???001??????: begin row = 8'd65; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVE EA,An
      16'b0010???01000????: begin row = 8'd66; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)
      16'b0010???010??????: begin row = 8'd67; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)
      16'b0010???01100????: begin row = 8'd68; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // MOVE Rn,(An)+
      16'b0010???011??????: begin row = 8'd69; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,(An)+
      16'b0010???10000????: begin row = 8'd70; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd2; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE Rn,-(An)
      16'b0010???100??????: begin row = 8'd71; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SOURCE,-(An)
      16'b0010???101??????: begin row = 8'd72; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(d16,An)
      16'b0010???110??????: begin row = 8'd73; tbl = 3'd1; szs = 3'd4; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(d8,An,Xn)
      16'b0010000111??????: begin row = 8'd74; tbl = 3'd1; szs = 3'd4; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,(xxx).W
      16'b0010001111??????: begin row = 8'd75; tbl = 3'd1; szs = 3'd4; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVE EA,(xxx).L
      16'b0100101011111100: begin row = 8'd76; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd18; op_cc_t = 7'd18; end   // Illegal instruction
      16'b0100000011000???: begin row = 8'd77; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SR,Dn
      16'b0100000011??????: begin row = 8'd78; tbl = 3'd3; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE SR,Mem
      16'b0100001011000???: begin row = 8'd79; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE CCR,Dn
      16'b0100001011??????: begin row = 8'd80; tbl = 3'd3; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE CCR,Mem
      16'b0100010011000???: begin row = 8'd81; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE Dn,CCR
      16'b0100010011??????: begin row = 8'd82; tbl = 3'd3; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE EA,CCR
      16'b0100011011??????: begin row = 8'd83; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // MOVE EA,SR
      16'b01000000??000???: begin row = 8'd84; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // NEGX Dn
      16'b01000000????????: begin row = 8'd85; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // NEGX Mem
      16'b01000010??000???: begin row = 8'd86; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // CLR Dn
      16'b01000010????????: begin row = 8'd87; tbl = 3'd3; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // CLR Mem
      16'b01000100??000???: begin row = 8'd88; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // NEG Dn
      16'b01000100????????: begin row = 8'd89; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // NEG Mem
      16'b01000110??000???: begin row = 8'd90; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // NOT Dn
      16'b01000110????????: begin row = 8'd91; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // NOT Mem
      16'b0100100000001???: begin row = 8'd92; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // LINK.L
      16'b0100100000000???: begin row = 8'd93; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // NBCD Dn
      16'b0100100000??????: begin row = 8'd94; tbl = 3'd1; szs = 3'd1; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // NBCD Dn
      16'b0100100001000???: begin row = 8'd95; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // SWAP Dn
      16'b0100100001001???: begin row = 8'd96; tbl = 3'd0; szs = 3'd0; op_h = 5'd1; op_t = 2'd0; op_cc = 7'd9; op_cc_t = 7'd9; end   // BKPT
      16'b0100100001??????: begin row = 8'd97; tbl = 3'd3; szs = 3'd0; op_h = 5'd0; op_t = 2'd2; op_cc = 7'd4; op_cc_t = 7'd4; end   // PEA
      16'b010010001?000???: begin row = 8'd98; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // EXT Dn
      16'b0100100111000???: begin row = 8'd99; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // EXT Dn
      16'b010010001???????: begin row = 8'd100; tbl = 3'd4; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; mvm = 2'd0; end   // MOVEM RL,EA
      16'b010011001???????: begin row = 8'd101; tbl = 3'd4; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; mvm = 2'd2; end   // MOVEM EA,RL
      16'b0100101011000???: begin row = 8'd102; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // TAS Dn
      16'b0100101011??????: begin row = 8'd103; tbl = 3'd3; szs = 3'd0; op_h = 5'd3; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // TAS Mem
      16'b01001010??000???: begin row = 8'd104; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // TST Dn
      16'b01001010????????: begin row = 8'd105; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // TST Mem
      16'b0100110000??????: begin row = 8'd106; tbl = 3'd2; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd44; op_cc_t = 7'd44; end   // MULS.L EA,Dn
      16'b0100110001??????: begin row = 8'd107; tbl = 3'd2; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd78; op_cc_t = 7'd78; end   // DIVU.L EA,Dn
      16'b010011100100????: begin row = 8'd108; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd18; op_cc_t = 7'd18; end   // TRAP #n
      16'b0100111001010???: begin row = 8'd109; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // LINK.W
      16'b0100111001011???: begin row = 8'd110; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd5; op_cc_t = 7'd5; end   // UNLK
      16'b0100111001100???: begin row = 8'd111; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE An,USP
      16'b0100111001101???: begin row = 8'd112; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // MOVE USP,An
      16'b0100111001110000: begin row = 8'd113; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd127; op_cc_t = 7'd127; end   // RESET instruction
      16'b0100111001110001: begin row = 8'd114; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // NOP
      16'b0100111001110010: begin row = 8'd115; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // STOP
      16'b0100111001110011: begin row = 8'd116; tbl = 3'd0; szs = 3'd0; op_h = 5'd1; op_t = 2'd0; op_cc = 7'd18; op_cc_t = 7'd18; end   // RTE four word
      16'b0100111001110100: begin row = 8'd117; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // RTD
      16'b0100111001110101: begin row = 8'd118; tbl = 3'd0; szs = 3'd0; op_h = 5'd1; op_t = 2'd0; op_cc = 7'd9; op_cc_t = 7'd9; end   // RTS
      16'b0100111001110110: begin row = 8'd119; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // TRAPV no trap
      16'b0100111001110111: begin row = 8'd120; tbl = 3'd0; szs = 3'd0; op_h = 5'd1; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // RTR
      16'b0100111001111010: begin row = 8'd121; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVEC Cr,Rn
      16'b0100111001111011: begin row = 8'd122; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // MOVEC Rn,Cr-A
      16'b0100111010??????: begin row = 8'd123; tbl = 3'd5; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // JSR
      16'b0100111011??????: begin row = 8'd124; tbl = 3'd5; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // JMP
      16'b0100???111??????: begin row = 8'd125; tbl = 3'd3; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // LEA
      16'b0100???1?0000???: begin row = 8'd126; tbl = 3'd0; szs = 3'd0; op_h = 5'd8; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // CHK Dn,Dn
      16'b0100???1?0??????: begin row = 8'd127; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // CHK EA,Dn
      16'b0101000111001???: begin row = 8'd128; tbl = 3'd0; szs = 3'd0; op_h = 5'd10; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd6; br = 2'd2; end   // DBcc expired
      16'b0101????11001???: begin row = 8'd129; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; br = 2'd2; end   // DBcc true
      16'b0101????11111010: begin row = 8'd130; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // TRAPcc.W no trap
      16'b0101????11111011: begin row = 8'd131; tbl = 3'd0; szs = 3'd0; op_h = 5'd8; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // TRAPcc.L no trap
      16'b0101????11111100: begin row = 8'd132; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // TRAPcc no trap
      16'b0101????11000???: begin row = 8'd133; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // Scc Dn
      16'b0101????11??????: begin row = 8'd134; tbl = 3'd3; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd5; op_cc_t = 7'd5; end   // Scc Mem
      16'b0101???0??00????: begin row = 8'd135; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADDQ #,Rn
      16'b0101???0????????: begin row = 8'd136; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // ADDQ #,Mem
      16'b0101???1??00????: begin row = 8'd137; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUBQ #,Rn
      16'b0101???1????????: begin row = 8'd138; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // SUBQ #,Mem
      16'b01100001????????: begin row = 8'd139; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // BSR
      16'b0110????00000000: begin row = 8'd140; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; br = 2'd1; end   // Bcc.W not taken
      16'b0110????11111111: begin row = 8'd141; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; br = 2'd1; end   // Bcc.L not taken
      16'b0110????????????: begin row = 8'd142; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd6; br = 2'd1; end   // Bcc.B not taken
      16'b0111???0????????: begin row = 8'd143; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // MOVEQ #,Dn
      16'b1000???011000???: begin row = 8'd144; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd44; op_cc_t = 7'd44; end   // DIVU.W Dn,Dn
      16'b1000???011??????: begin row = 8'd145; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd44; op_cc_t = 7'd44; end   // DIVU.W EA,Dn
      16'b1000???111000???: begin row = 8'd146; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd56; op_cc_t = 7'd56; end   // DIVS.W Dn,Dn
      16'b1000???111??????: begin row = 8'd147; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd56; op_cc_t = 7'd56; end   // DIVS.W EA,Dn
      16'b1000???100000???: begin row = 8'd148; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // SBCD Dn,Dn
      16'b1000???100001???: begin row = 8'd149; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd13; op_cc_t = 7'd13; end   // SBCD -(An),-(An)
      16'b1000???101000???: begin row = 8'd150; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // PACK Dn,Dn,#
      16'b1000???101001???: begin row = 8'd151; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd11; op_cc_t = 7'd11; end   // PACK -(An),-(An),#
      16'b1000???110000???: begin row = 8'd152; tbl = 3'd0; szs = 3'd0; op_h = 5'd8; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // UNPK Dn,Dn,#
      16'b1000???110001???: begin row = 8'd153; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd11; op_cc_t = 7'd11; end   // UNPK -(An),-(An),#
      16'b1000???0??000???: begin row = 8'd154; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // OR Dn,Dn
      16'b1000???0????????: begin row = 8'd155; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // OR EA,Dn
      16'b1000???1????????: begin row = 8'd156; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // OR Dn,EA
      16'b1001???01100????: begin row = 8'd157; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // SUBA.W Rn,An
      16'b1001???011??????: begin row = 8'd158; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // SUBA.W EA,An
      16'b1001???11100????: begin row = 8'd159; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUBA.L Rn,An
      16'b1001???111??????: begin row = 8'd160; tbl = 3'd1; szs = 3'd3; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUBA.L EA,An
      16'b1001???1??000???: begin row = 8'd161; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUBX Dn,Dn
      16'b1001???1??001???: begin row = 8'd162; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd9; op_cc_t = 7'd9; end   // SUBX -(An),-(An)
      16'b1001???0??00????: begin row = 8'd163; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUB Rn,Dn
      16'b1001???0????????: begin row = 8'd164; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // SUB EA,Dn
      16'b1001???1????????: begin row = 8'd165; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // SUB Dn,EA
      16'b1010????????????: begin row = 8'd166; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd18; op_cc_t = 7'd18; end   // A-line trap
      16'b1011???01100????: begin row = 8'd167; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // CMPA Rn,An
      16'b1011???011??????: begin row = 8'd168; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // CMPA EA,An
      16'b1011???11100????: begin row = 8'd169; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // CMPA Rn,An
      16'b1011???111??????: begin row = 8'd170; tbl = 3'd1; szs = 3'd3; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // CMPA EA,An
      16'b1011???1??001???: begin row = 8'd171; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // CMPM (An)+,(An)+
      16'b1011???1??000???: begin row = 8'd172; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // EOR Dn,Dn
      16'b1011???1????????: begin row = 8'd173; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // EOR Dn,EA
      16'b1011???0??00????: begin row = 8'd174; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // CMP Rn,Dn
      16'b1011???0????????: begin row = 8'd175; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // CMP EA,Dn
      16'b1100???011??????: begin row = 8'd176; tbl = 3'd1; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd28; op_cc_t = 7'd28; end   // MULU.W EA,Dn
      16'b1100???111??????: begin row = 8'd177; tbl = 3'd1; szs = 3'd2; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd28; op_cc_t = 7'd28; end   // MULS.W EA,Dn
      16'b1100???100000???: begin row = 8'd178; tbl = 3'd0; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ABCD Dn,Dn
      16'b1100???100001???: begin row = 8'd179; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd13; op_cc_t = 7'd13; end   // ABCD -(An),-(An)
      16'b1100???101000???: begin row = 8'd180; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // EXG Ry,Rx
      16'b1100???101001???: begin row = 8'd181; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // EXG Ry,Rx
      16'b1100???110001???: begin row = 8'd182; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // EXG Ry,Rx
      16'b1100???0??000???: begin row = 8'd183; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // AND Dn,Dn
      16'b1100???0????????: begin row = 8'd184; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // AND EA,Dn
      16'b1100???1????????: begin row = 8'd185; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // AND Dn,EA
      16'b1101???01100????: begin row = 8'd186; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ADDA.W Rn,An
      16'b1101???011??????: begin row = 8'd187; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ADDA.W EA,An
      16'b1101???11100????: begin row = 8'd188; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADDA.L Rn,An
      16'b1101???111??????: begin row = 8'd189; tbl = 3'd1; szs = 3'd3; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADDA.L EA,An
      16'b1101???1??000???: begin row = 8'd190; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADDX Dn,Dn
      16'b1101???1??001???: begin row = 8'd191; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd1; op_cc = 7'd9; op_cc_t = 7'd9; end   // ADDX -(An),-(An)
      16'b1101???0??00????: begin row = 8'd192; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADD Rn,Dn
      16'b1101???0????????: begin row = 8'd193; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd2; op_cc_t = 7'd2; end   // ADD EA,Dn
      16'b1101???1????????: begin row = 8'd194; tbl = 3'd1; szs = 3'd0; op_h = 5'd0; op_t = 2'd1; op_cc = 7'd3; op_cc_t = 7'd3; end   // ADD Dn,EA
      16'b1110100011000???: begin row = 8'd195; tbl = 3'd0; szs = 3'd0; op_h = 5'd8; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // BFTST Dn
      16'b1110100011??????: begin row = 8'd196; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // BFTST Mem<5
      16'b1110100111000???: begin row = 8'd197; tbl = 3'd0; szs = 3'd0; op_h = 5'd10; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // BFEXTU Dn
      16'b1110100111??????: begin row = 8'd198; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // BFEXTU Mem<5
      16'b1110101011000???: begin row = 8'd199; tbl = 3'd0; szs = 3'd0; op_h = 5'd14; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFCHG Dn
      16'b1110101011??????: begin row = 8'd200; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFCHG Mem<5
      16'b1110101111000???: begin row = 8'd201; tbl = 3'd0; szs = 3'd0; op_h = 5'd10; op_t = 2'd0; op_cc = 7'd10; op_cc_t = 7'd10; end   // BFEXTS Dn
      16'b1110101111??????: begin row = 8'd202; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // BFEXTS Mem<5
      16'b1110110011000???: begin row = 8'd203; tbl = 3'd0; szs = 3'd0; op_h = 5'd14; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFCLR Dn
      16'b1110110011??????: begin row = 8'd204; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFCLR Mem<5
      16'b1110110111000???: begin row = 8'd205; tbl = 3'd0; szs = 3'd0; op_h = 5'd20; op_t = 2'd0; op_cc = 7'd20; op_cc_t = 7'd20; end   // BFFFO Dn
      16'b1110110111??????: begin row = 8'd206; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd22; op_cc_t = 7'd22; end   // BFFFO Mem<5
      16'b1110111011000???: begin row = 8'd207; tbl = 3'd0; szs = 3'd0; op_h = 5'd14; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFSET Dn
      16'b1110111011??????: begin row = 8'd208; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd14; op_cc_t = 7'd14; end   // BFSET Mem<5
      16'b1110111111000???: begin row = 8'd209; tbl = 3'd0; szs = 3'd0; op_h = 5'd12; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // BFINS Dn
      16'b1110111111??????: begin row = 8'd210; tbl = 3'd4; szs = 3'd2; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // BFINS Mem<5
      16'b1110000011??????: begin row = 8'd211; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ASR Mem
      16'b1110000111??????: begin row = 8'd212; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // ASL Mem
      16'b1110001?11??????: begin row = 8'd213; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // LSd Mem
      16'b1110010?11??????: begin row = 8'd214; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ROXd Mem
      16'b1110011?11??????: begin row = 8'd215; tbl = 3'd1; szs = 3'd2; op_h = 5'd0; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // ROd Mem
      16'b1110???0??000???: begin row = 8'd216; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // ASR #,Dy
      16'b1110???1??000???: begin row = 8'd217; tbl = 3'd0; szs = 3'd0; op_h = 5'd2; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // ASL #,Dy
      16'b1110???0??100???: begin row = 8'd218; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // ASR Dx,Dy
      16'b1110???1??100???: begin row = 8'd219; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // ASL Dx,Dy
      16'b1110??????001???: begin row = 8'd220; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd4; op_cc_t = 7'd4; end   // LSd #,Dy
      16'b1110??????101???: begin row = 8'd221; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // LSd Dx,Dy
      16'b1110??????010???: begin row = 8'd222; tbl = 3'd0; szs = 3'd0; op_h = 5'd10; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ROXd Dn
      16'b1110??????110???: begin row = 8'd223; tbl = 3'd0; szs = 3'd0; op_h = 5'd10; op_t = 2'd0; op_cc = 7'd12; op_cc_t = 7'd12; end   // ROXd Dn
      16'b1110??????011???: begin row = 8'd224; tbl = 3'd0; szs = 3'd0; op_h = 5'd4; op_t = 2'd0; op_cc = 7'd6; op_cc_t = 7'd6; end   // ROd #,Dy
      16'b1110??????111???: begin row = 8'd225; tbl = 3'd0; szs = 3'd0; op_h = 5'd6; op_t = 2'd0; op_cc = 7'd8; op_cc_t = 7'd8; end   // ROd Dx,Dy
      16'b1111????????????: row = 8'd226;   // the coprocessors: unpaced
      default: ;
    endcase
    case (tbl)
      3'd1: ea = f_fea(op[5:3], op[2:0], lsz);
      3'd2: ea = f_fiea(op[5:3], op[2:0], lsz);
      3'd3: ea = f_cea(op[5:3], op[2:0], lsz);
      3'd4: ea = f_ciea(op[5:3], op[2:0], lsz);
      3'd5: ea = f_jea(op[5:3], op[2:0], lsz);
      default: ea = 14'd0;
    endcase
    ea_on = (tbl != 3'd0);
    {ea_ophead, ea_h, ea_t, ea_cc} = ea;
  end

endmodule
