// se30_fpu_fn.vh - shared FPU functions: exception accrual and the pending-exception vector

function [31:0] fpu_accrue;
  input [31:0] f;
  begin
    fpu_accrue = f | {24'd0,
                      f[15] | f[14] | f[13],
                      f[12],
                      f[11] & f[9],
                      f[10],
                      f[8] | f[9] | f[12],
                      3'd0};
  end
endfunction

function [7:0] fpu_trapvec;
  input [31:0] fpsr;
  input [31:0] fpcr;
  reg   [7:0]  x;
  begin
    x = fpsr[15:8] & fpcr[15:8];
    if      (x[7]) fpu_trapvec = 8'd48;
    else if (x[6]) fpu_trapvec = 8'd54;
    else if (x[5]) fpu_trapvec = 8'd52;
    else if (x[4]) fpu_trapvec = 8'd53;
    else if (x[3]) fpu_trapvec = 8'd51;
    else if (x[2]) fpu_trapvec = 8'd50;
    else if (((fpsr[12] | fpsr[9]) & fpcr[9]) | (fpsr[8] & fpcr[8]))
                   fpu_trapvec = 8'd49;
    else           fpu_trapvec = 8'd0;
  end
endfunction
