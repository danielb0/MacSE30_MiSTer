#!/usr/bin/env bash
# The rotator's bench matrix: every case must PASS, every plant must FAIL.
cd "$(dirname "$0")"
run() { TAG=$1; shift; TAG=$TAG bash run.sh "$@" > /dev/null 2>&1; echo "$TAG: $(tail -2 $TAG.log | head -1)"; }
run base &
run busy75  -Ptb_iici_rotate.BUSYPCT=75 -Ptb_iici_rotate.SEED=7 &
run cegap   -Ptb_iici_rotate.CE_NUM=189 -Ptb_iici_rotate.CE_DEN=358 -Ptb_iici_rotate.VBLP=1100000 &
run fastvbl -Ptb_iici_rotate.VBLP=400000 -Ptb_iici_rotate.SEED=3 &
wait
run slowvbl -Ptb_iici_rotate.VBLP=1700000 -Ptb_iici_rotate.SEED=5 &
run ll      -Ptb_iici_rotate.LL=1 &
run plant1  -Ptb_iici_rotate.PLANT=1 &
run plant2  -Ptb_iici_rotate.PLANT=2 &
wait
