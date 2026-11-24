# sim/oddstack/gen.py - exception frames on a stack at every alignment (2026-11-24).
# Prince of Persia on the IIci: a level-2 interrupt while the game ran with an odd A7;
# the ROM handler's RTE latched the format word from the last of its two beats (the
# vector offset's low byte, $68 -> format 6) and took a false format error (vector 14).
# Batch 000: TRAP #0 (format 0), TRAPV, DIVU by zero, CHK (format 2) at SP mod 4 =
# 0..3, through a MOVEM push / clobber / MOVEM pop / RTE handler: A7 and D0-D3/A0-A3
# back.  Batches 001-: a genuine format error (a format $8 frame) after MOVEM (A7)+,
# MOVEA, NOP, ADDQ at every alignment: the vector 14 frame stacks below the RTE's A7
# (rte_saved_a7 once took A7 before MOVEM's update: 32 bytes low).
# Programs for sim/cputest_int's tb_cpu_int (its run.sh).   python gen.py <out dir>
import os
import sys
OUT=sys.argv[1]
def L(v): return [(v>>16)&0xFFFF, v&0xFFFF]
REGS=[0x11111111,0x22222222,0x33333333,0x44444444,0x0055AA01,0x0066AA02,0x0077AA03,0x0088AA04]
OPS=[0x203C,0x223C,0x243C,0x263C,0x207C,0x227C,0x247C,0x267C]
CLOB=[0x7000,0x7200,0x7400,0x7600,0x91C8,0x93C9,0x95CA,0x97CB]
def load():
    c=[]
    for o,v in zip(OPS,REGS): c+=[o]+L(v)
    return c
# raising instructions; the D4/D5 set-up comes before the register loads
EXC={'trap0':([],[0x4E40]),                              # fmt 0, vector 32
     'trapv':([0x44FC,0x0002],[0x4E76]),                 # move #2,ccr (V); trapv: fmt 2, vector 7
     'div0':([0x7A00],[0x8AC5]),                          # moveq #0,d5; divu d5,d5: fmt 2, vector 5 (D5 not checked)
     'chk':([0x787F, 0x7A05],[0x4985])}                   # d4=$7F (>d5=5): chk d5,d4: fmt 2, vector 6
def build(name, cases, fmterr, seq='movem'):
    code=[0x41F9]+L(0x8000)+[0x4E7B,0x8801]
    exp=[]; res=0x18000
    for sp in cases:
        for e,(pre,ins) in EXC.items():
            code+=[0x2E7C]+L(sp)+pre+load()+ins
            code+=[0x23CF]+L(res+4)+[0x48F9,0x0F0F]+L(res+0x10)
            exp.append((res+4,sp,0xFFFFFFFF))
            for i,v in enumerate(REGS): exp.append((res+0x10+4*i,v,0xFFFFFFFF))
            res+=0x40
    img=[0]*65536
    def put(a,ws):
        for i,x in enumerate(ws): img[a//2+i]=x&0xFFFF
    def putb(a,bs):
        for i,b in enumerate(bs):
            w=img[(a+i)//2]
            img[(a+i)//2]= (w&0x00FF)|(b<<8) if (a+i)%2==0 else (w&0xFF00)|b
    if fmterr is not None:
        X=fmterr                                          # fake frame at X: SR $2700, PC $A000, format $8 (invalid)
        putb(X,[0x27,0x00,0x00,0x00,0xA0,0x00,0x80,0x00])
        if seq=='movem': code+=[0x2E7C]+L(X-32)+[0x4CDF,0x0F0F,0x4E73]            # movem.l (a7)+; rte
        elif seq=='movea': code+=[0x2E7C]+L(X)+[0x4E73]                            # movea.l #X,a7; rte
        elif seq=='nop': code+=[0x2E7C]+L(X-32)+[0x4CDF,0x0F0F,0x4E71,0x4E73]      # movem; nop; rte
        elif seq=='addq': code+=[0x2E7C]+L(X-4)+[0x588F,0x4E73]                    # addq.l #4,a7; rte
        exp.append((0x18F00,X-8,0xFFFFFFFF))              # the format error frame stacks below the RTE's A7
        exp.append((0x18F04,0x600D0001,0xFFFFFFFF))
    else:
        code+=[0x23FC]+L(0x600D0001)+L(0x9FF0)+[0x4E72,0x2700]
    put(0,L(0x9E00)+L(0xA000))
    for v in range(256):
        put(0x8000+4*v,L(0x8400+16*v)); put(0x8400+16*v,[0x23FC]+L(0xDEAD0000|v)+L(0x9FF0)+[0x4E72,0x2700])
    for v in (5,6,7,32): put(0x8000+4*v,L(0x9500))
    put(0x9500,[0x48E7,0xF0F0]+CLOB+[0x4CDF,0x0F0F,0x4E73])
    put(0x8000+4*14,L(0x9600))                            # format error: A7 and a marker, then the end
    put(0x9600,[0x23CF]+L(0x18F00)+[0x23FC]+L(0x600D0001)+L(0x18F04)+[0x23FC]+L(0x600D0001)+L(0x9FF0)+[0x4E72,0x2700])
    put(0xA000,code)
    os.makedirs(OUT,exist_ok=True)
    open(OUT+'/prog_%s.hex'%name,'w',newline='\n').write(''.join('%04x\n'%x for x in img))
    open(OUT+'/expect_%s.txt'%name,'w',newline='\n').write(''.join('%08x %08x %08x\n'%e for e in exp))
    print(name,len(exp),'checks')
build('000',[0x9D00,0x9D01,0x9D02,0x9D03,0x7F01],None)
k=1
for X in (0x9D00,0x9D01,0x9D02,0x9D03):
    for q in ('movem','movea','nop','addq'):
        build('%03d'%k,[],X,q); k+=1
