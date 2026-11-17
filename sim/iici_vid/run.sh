#!/usr/bin/env bash
# The CPU beside the RBV's video bursts at a given depth: tb_iici_machine
# with a program in the ROM's place and vid_watch.v counting its cycles.
#   DEPTH  0-3 = 1, 2, 4, 8 bits a pixel (default 3)    SDRAM  1: through iici_sdram and the chip model
#   CACHE  1: the caches on and burst reads over 64 KB of bank A (2-5: see below)
#   XCARD  1 / 2: the RAM cache card fitted, 32 KB / 128 KB (CACHE=7 is its program; any other runs with it too)
#   CACHE=10: back-to-back RAM writes and a read after a write (S Figures 15-16), for TRACE=1
#   CACHE=9: CACHE=7 with RAM cache-inhibited by TT0 (CIOUT*): the card must not touch RAM's reads
#   OVER   1: the pace's credits set past its 511-clock count at 2 ms; the CPU must carry on
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl
DEPTH=${DEPTH:-3} CACHE=${CACHE:-0} python - <<'PY' || exit 1
import os
depth = int(os.environ['DEPTH'])
if os.environ.get('CACHE', '0') == '8':
    # everything in bank A, the CPU's caches off: a three-instruction loop copied to $2000 and run there -
    # fetches and writes that all compete with the video (the memory test's case)
    prog = bytes.fromhex(
      '00001000' '40800008'
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '41f900002000'                   # LEA $2000,A0
      '20fc52802280'                   # MOVE.L #$52802280,(A0)+     ADDQ.L #1,D0 ; MOVE.L D0,(A1)
      '30bc60fa'                       # MOVE.W #$60FA,(A0)          BRA.S the ADDQ
      '43f900003000'                   # LEA $3000,A1
      '4ef900002000' % depth)          # JMP $2000
elif os.environ.get('CACHE', '0') in ('7', '9'):
    # (CACHE=9: the same with TT0 marking $00xxxxxx cache-inhibited - CIOUT* on every RAM cycle: the card must
    # leave RAM's reads alone, answer the ROM's fetches, and D7 stay 0)
    # THE CACHE CARD (XCARD=1 / 2): enabled through the RBV, then for ever: 256 longs of bank A written,
    # read twice (a miss and a hit), a byte and a word written into each and read back (the card's
    # update), every difference counted in D7; the card flushed after the third pass; D6 counts passes.
    # The CPU's own caches stay off, so every fetch from the ROM is a cycle the card may answer too.
    def asm():
        b = bytearray()
        b += bytes.fromhex('00001000' '40800008')
        b += bytes.fromhex('41f950f26010' '10bc00%02x' % depth)        # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
        if os.environ.get('CACHE') == '9':
            b += bytes.fromhex('23fc0000850700007ff8')                 # MOVE.L #$00008507,$7FF8   TT0: $00xxxxxx, E, CI, RWM, any FC
            b += bytes.fromhex('41f900007ff8' 'f0100800')              # LEA $7FF8,A0 ; PMOVE (A0),TT0
        b += bytes.fromhex('13fc00fe50f26000')                         # MOVE.B #$FE,$50F26000    /CENABLE low
        b += bytes.fromhex('7c00' '7e00')                              # MOVEQ #0,D6 ; MOVEQ #0,D7
        loop = len(b)
        b += bytes.fromhex('41f900020000')                             # LEA $00020000,A0
        b += bytes.fromhex('323c00ff')                                 # MOVE.W #255,D1
        b += bytes.fromhex('2006' 'e198' 'd086')                       # MOVE.L D6,D0 ; ROL.L #8,D0 ; ADD.L D6,D0
        l1 = len(b)
        b += bytes.fromhex('2080')                                     # MOVE.L D0,(A0)
        b += bytes.fromhex('b090' '6702' '5287')                       # CMP.L (A0),D0 ; BEQ.S +2 ; ADDQ.L #1,D7
        b += bytes.fromhex('b090' '6702' '5287')                       # again: the hit
        b += bytes.fromhex('11410001')                                 # MOVE.B D1,1(A0)
        b += bytes.fromhex('2410' '2600' '4843' '1601' '4843')         # MOVE.L (A0),D2 ; MOVE.L D0,D3 ; SWAP D3 ; MOVE.B D1,D3 ; SWAP D3
        b += bytes.fromhex('b682' '6702' '5287')                       # CMP.L D2,D3 ; BEQ.S +2 ; ADDQ.L #1,D7
        b += bytes.fromhex('31410002' '3601')                          # MOVE.W D1,2(A0) ; MOVE.W D1,D3
        b += bytes.fromhex('b698' '6702' '5287')                       # CMP.L (A0)+,D3 ; BEQ.S +2 ; ADDQ.L #1,D7
        b += bytes.fromhex('d0bc01010101')                             # ADD.L #$01010101,D0
        d = (l1 - (len(b) + 2)) & 0xFFFF
        b += bytes.fromhex('51c9%04x' % d)                             # DBRA D1,l1
        b += bytes.fromhex('0c060002' '6610')                          # CMPI.B #2,D6 ; BNE.S +16
        b += bytes.fromhex('13fc00f650f26000')                         # MOVE.B #$F6,$50F26000    /CFLUSH low
        b += bytes.fromhex('13fc00fe50f26000')                         # MOVE.B #$FE,$50F26000
        b += bytes.fromhex('5286')                                     # ADDQ.L #1,D6
        d = (loop - (len(b) + 2)) & 0xFFFF
        b += bytes.fromhex('6000%04x' % d)                             # BRA loop
        return bytes(b)
    prog = asm()
elif os.environ.get('CACHE', '0') == '6':
    # the ROM alone, caches off: fetches that never touch bank A.  On the IIci the ROM and bank B are not on
    # the video's bus, so the count in live video must match the count in vertical blanking
    prog = bytes.fromhex(
      '00001000' '40800008'
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '5280' '5280' '5280' '5280'      # ADDQ.L #1,D0 x 4
      '60f6' % depth)                  # BRA back to the first ADDQ
elif os.environ.get('CACHE', '0') == '5':
    # CACHE=3's blocks with the trace bit set: every instruction ends in a trace exception, so the pace sees
    # MOVEM.L (A7)+'s fifteen reads, the frame's writes, the vector's read and the handler's line fill (an RTE
    # at $20000, on the blocks' second cache line) as ONE instruction's credits - a budget past the pace's
    # 511-clock count
    head = bytes.fromhex(
      '00001000' '40800008'
      '203c00003919' '4e7b0002'        # MOVE.L #$3919,D0 ; MOVEC D0,CACR
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '23fc0002000000000024'           # MOVE.L #$00020000,$24      the trace vector
      '33fc4e7300020000'               # MOVE.W #$4E73,$00020000    RTE
      '43f9000100f0'                   # LEA $000100F0,A1
      '721f' % depth)                  # MOVEQ #31,D1
    loop = bytes.fromhex(
      '2449'
      '24fc4e714e71' '24fc4e714e71' '24fc4e714e71'
      '24fc48e7fffe'                   # MOVEM.L D0-D7/A0-A6,-(A7)
      '24fc4cdf7fff'                   # MOVEM.L (A7)+,D0-D7/A0-A6
      '34fc4ef9'
      '47e90100' '24cb'
      'd2fc0100')
    disp = (-(len(loop) + 2)) & 0xFFFF
    tail = bytes.fromhex('51c9%04x' % disp + '23fc000100f000012006' + '46fca700' + '4ef9000100f0')   # MOVE #$A700,SR
    prog = head + loop + tail
elif os.environ.get('CACHE', '0') == '10':
    # back-to-back RAM cycles (S Figures 15 and 16): the instruction cache on, the data cache off, so the
    # bus carries only a write to bank A, a second write straight after it, then a read - TRACE=1 shows
    # their lengths (S: write 4, write after a write 5, read after a write 6)
    prog = bytes.fromhex(
      '00001000' '40800008'
      '7001' '4e7b0002'                # MOVEQ #1,D0 ; MOVEC D0,CACR   (EI)
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '43f900002000'                   # LEA $2000,A1
      '2280' '23400004' '24290008'     # MOVE.L D0,(A1) ; MOVE.L D0,4(A1) ; MOVE.L 8(A1),D2
      '5280' '60f2' % depth)           # ADDQ.L #1,D0 ; BRA the first MOVE
elif os.environ.get('CACHE', '0') == '4':
    # CACHE=3's blocks with the PMMU on, as on the board (the stop's PC was logical): an identity map of 256
    # early-termination descriptors at $8000 (TC $80F08900: 32 KB pages, TIA 8, TIB 9), and a PFLUSHA at each
    # block's entry, so the MOVEM's stack write and the next line's fetch each need a table walk first
    head = bytes.fromhex(
      '00001000' '40800008'
      '203c00003919' '4e7b0002'        # MOVE.L #$3919,D0 ; MOVEC D0,CACR
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '41f900008000' '7000' '323c00ff' # LEA $8000,A0 ; MOVEQ #0,D0 ; MOVE.W #255,D1
      '2400' '5282' '20c2' 'd0bc01000000' '51c9fff2'   # D2 = D0 + 1 -> (A0)+ ; D0 += $01000000 ; DBRA
      '23fc7fff000200007ff0' '23fc0000800000007ff4'    # the CRP's two longs at $7FF0
      '41f900007ff0' 'f0104c00'        # LEA $7FF0,A0 ; PMOVE (A0),CRP
      '23fc80f0890000007ff8'           # the TC at $7FF8
      '41f900007ff8' 'f0104000'        # LEA $7FF8,A0 ; PMOVE (A0),TC
      '43f9000100f0'                   # LEA $000100F0,A1
      '721f' % depth)                  # MOVEQ #31,D1
    loop = bytes.fromhex(
      '2449'                           # MOVEA.L A1,A2
      '24fcf0002400' '24fc4e714e71' '24fc4e714e71'   # PFLUSHA, four NOPs
      '24fc48e7fffe'                   # MOVEM.L D0-D7/A0-A6,-(A7)
      '24fc4cdf7fff'                   # MOVEM.L (A7)+,D0-D7/A0-A6
      '34fc4ef9'                       # JMP abs.l
      '47e90100' '24cb'                # LEA $100(A1),A3 ; MOVE.L A3,(A2)+
      'd2fc0100')                      # ADDA.W #$100,A1
    disp = (-(len(loop) + 2)) & 0xFFFF
    tail = bytes.fromhex('51c9%04x' % disp + '23fc000100f000012006' + '4ef9000100f0')
    prog = head + loop + tail
elif os.environ.get('CACHE', '0') == '3':
    # the board's stop (PKRN: MOVEM.L regs,-(A7) at $xxxFC, the line just burst-filled): 32 blocks of code in
    # RAM, $100 apart so each lands on the SAME cache line with another tag - every visit a miss and a burst.
    # A block, entered at $F0: six NOPs, MOVEM.L D0-D7/A0-A6,-(A7) in the line's last long, then in the next
    # line MOVEM.L (A7)+,D0-D7/A0-A6 and a JMP to the next block.
    head = bytes.fromhex(
      '00001000' '40800008'
      '203c00003919' '4e7b0002'        # MOVE.L #$3919,D0 ; MOVEC D0,CACR
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '43f9000100f0'                   # LEA $000100F0,A1       the first block's entry
      '721f' % depth)                  # MOVEQ #31,D1
    loop = bytes.fromhex(
      '2449'                           # MOVEA.L A1,A2
      '24fc4e714e71' '24fc4e714e71' '24fc4e714e71'   # three longs of NOPs
      '24fc48e7fffe'                   # MOVEM.L D0-D7/A0-A6,-(A7)
      '24fc4cdf7fff'                   # MOVEM.L (A7)+,D0-D7/A0-A6
      '34fc4ef9'                       # JMP abs.l
      '47e90100' '24cb'                # LEA $100(A1),A3 ; MOVE.L A3,(A2)+   its target: the next block
      'd2fc0100')                      # ADDA.W #$100,A1
    disp = (-(len(loop) + 2)) & 0xFFFF
    tail = bytes.fromhex('51c9%04x' % disp +          # DBRA D1,loop
      '23fc000100f000012006'           # MOVE.L #$000100F0,$00012006   the last block jumps to the first
      '4ef9000100f0')                  # JMP $000100F0
    prog = head + loop + tail
elif os.environ.get('CACHE', '0') == '2':
    # the driver's grey fill: the caches on, MOVE.L D3,(A0)+ / DBRA over the screen buffer's 256 KB again and
    # again - posted writes back to back, from the instruction cache, against the video's bursts
    prog = bytes.fromhex(
      '00001000' '40800008'
      '203c00003919' '4e7b0002'        # MOVE.L #$3919,D0 ; MOVEC D0,CACR
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '263caaaaaaaa'                   # MOVE.L #$AAAAAAAA,D3
      '41f900000000'                   # LEA $0,A0            (the screen buffer, bank A's start)
      '343cffff'                       # MOVE.W #$FFFF,D2
      '20c3'                           # MOVE.L D3,(A0)+
      '51cafffc'                       # DBRA D2,*-2
      '4683'                           # NOT.L D3
      '60ee' % depth)                  # BRA back to the LEA
elif os.environ.get('CACHE', '0') == '1':
    # the caches and their bursts on (CACR $3919, the ROM's), then sums over 64 KB of bank A: a line fill
    # (a 5-2-2-2 burst read) every four longs, between the video's bursts
    prog = bytes.fromhex(
      '00001000' '40800008'
      '203c00003919' '4e7b0002'        # MOVE.L #$3919,D0 ; MOVEC D0,CACR
      '41f950f26010' '10bc00%02x'      # LEA $50F26010,A0 ; MOVE.B #depth,(A0)
      '43f900002000'                   # LEA $2000,A1
      '323c3fff'                       # MOVE.W #$3FFF,D1
      'd099'                           # ADD.L (A1)+,D0
      '51c9fffc'                       # DBRA D1,*-2
      '23c000001ff0'                   # MOVE.L D0,$1FF0
      '60e8' % depth)                  # BRA back to the LEA $2000,A1
else:
    prog = bytes.fromhex(
      '00001000' '40800008'            # SSP, PC
      '41f950f26010'                   # LEA $50F26010,A0
      '10bc00%02x'                     # MOVE.B #depth,(A0)
      '43f900002000'                   # LEA $2000,A1
      '7000'                           # MOVEQ #0,D0
      '5280'                           # ADDQ.L #1,D0
      '2280'                           # MOVE.L D0,(A1)
      '60fa' % depth)                  # BRA *-4
rom = bytearray(524288); rom[:len(prog)] = prog
open('rom.hex', 'w').write(''.join('%02x%02x\n' % (rom[i], rom[i+1]) for i in range(0, len(rom), 2)))
PY
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -sv +define+SIMULATION -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
  "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
  "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/iici_mdu.v" "$RTL/iici_rbv.v" "$RTL/iici_machine.v" \
  "$RTL/se30_via.v" "$RTL/se30_swim.v" "$RTL/se30_fdhd.v" "$RTL/iicx_nuchip.v" "$RTL/se30_pic1654.v" "$RTL/se30_adb_xcvr.v" \
  "$RTL/se30_adb_dev.v" "$RTL/se30_rtc.v" "$RTL/se30_asc.v" "$RTL/se30_ncr53c80.v" "$RTL/se30_scsi.v" "$RTL/se30_scc.v" \
  "$RTL/se30_scc_chan.v" ../machine/scsi_idle.v "$RTL/iici_sdram.v" ../sdram/sdram_model.v ../iici/tb_iici_machine.v vid_watch.v > vlog.log 2>&1 || { cat vlog.log; exit 1; }
"$MODELSIM/vsim.exe" -c -quiet -gSDRAM=${SDRAM:-0} -gXCARD=${XCARD:-0} -g/tb_iici_machine/machine/rbv/EARLY=${EARLY:-1} -gvid_watch/STOP_NS=${STOP_NS:-4000000} +CYCLES=100000000 ${OVER:+"+OVER"} ${XON:+"+XON"} ${TRACE:+"+TRACE"} $( [ "${CACHE:-0}" = 9 ] && echo +CICHK ) -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_iici_machine work.vid_watch > run.log 2>&1
grep -E '^# (      [0-9]+\.[0-9] ms|      long|      writes|      [0-9]+: |---- |==== VID)' run.log | sed 's/^# //'
grep -q '^# ==== VID PASS' run.log
