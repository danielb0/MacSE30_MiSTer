#!/usr/bin/env python3
"""Offline gate for the OSD's "Scale" (MacSE30.sv's video_freak): no integer
scaling mode may ask the HDMI scaler for a picture larger than the panel.

No simulation instantiates sys/video_freak.sv, so its integer maths is
checked here instead, with the model of video_scale_int from the MacIIvi
core's scripts/aspect_check.py (Daniel's; floor division, 12-bit results,
the RTL's cnt states in the comments) - sys/video_freak.sv is the same file
in both cores.  That core's history is the reason for the gate: a 256:171
"Original" on a 640x480 source asked V-Integer for 1437 px on a 1280x1024
panel and blanked the screen.  Here 256:171 is right - the SE/30's 512x342
has square pixels - and the IIcx's 640x480 is 4:3.

For every source, panel and mode: the size fits the panel, is an integer
multiple of the source, and keeps the source's aspect ratio exactly.

Run:  python tools/aspect_check.py      (exit 0 = all gates pass)
"""

import sys

M12 = 0xFFF  # sys_udiv/sys_umul results are consumed as [11:0]


def scale_int(W, H, SCALE, hsize, vsize, arx, ary):
    """Model of video_scale_int. Returns ('ratio', x, y) for pass-through
    or ('size', width, height) when integer scaling produced a size."""
    # !SCALE || (!ary_i && arx_i) -> pass the ratio through untouched
    if SCALE == 0 or (ary == 0 and arx != 0):
        return ('ratio', arx, ary)

    k = (H // vsize) & M12                      # cnt0
    if k == 0:                                  # cnt1: panel shorter than source
        return ('ratio', arx, ary)
    oheight = (vsize * k) & M12                 # cnt1/2

    htarget = None
    if ary == 0:                                # cnt2 -> width path (arx==0 too)
        div_num = W                             # cnt8 leaves div_num = W
        f2 = (W // hsize) & M12
        f2 = f2 if f2 else 1                    # cnt9/10: max(f2, 1)
        hinteger = (hsize * f2) & M12
        oheight = (vsize * f2) & M12            # cnt10/11
    else:
        htarget = ((oheight * arx) // ary) & M12  # cnt3/4/5
        div_num = htarget                       # cnt5 leaves div_num = htarget
        f = (htarget // hsize) & M12            # cnt5
        cand = (hsize * (f if f else 1)) & M12  # cnt6: max(f, 1)
        if cand <= W:                           # cnt7: fits -> jump to cnt12
            hinteger = cand
        else:                                   # falls through to cnt8..11
            div_num = W
            f2 = (W // hsize) & M12
            f2 = f2 if f2 else 1
            hinteger = (hsize * f2) & M12
            oheight = (vsize * f2) & M12

    wideres = hinteger + hsize                  # cnt12
    narrow = (htarget is not None
              and (htarget - hinteger) <= (wideres - htarget)) or wideres > W
    wres = hinteger if (htarget is not None and hinteger == htarget) else wideres

    if SCALE == 2:                              # cnt13: HV-Integer- (Narrower)
        aw = hinteger
    elif SCALE == 3:                            # HV-Integer+ (Wider)
        aw = hinteger if wres > W else wres
    elif SCALE == 4:                            # HV-Integer (closest) — not
        aw = hinteger if narrow else wres       # reachable from this core's
    else:                                       # 2-bit status[13:12], modeled
        aw = div_num                            # for completeness. SCALE==1:
    return ('size', aw, oheight)                # V-Integer -> div_num



SOURCES = [("SE/30 512x342", 512, 342, (256, 171)),
           ("IIcx 640x480", 640, 480, (4, 3))]
PANELS = [(640, 480), (720, 480), (720, 576), (800, 600), (1024, 768),
          (1280, 720), (1280, 800), (1280, 1024), (1366, 768), (1440, 900),
          (1600, 1200), (1680, 1050), (1920, 1080), (1920, 1200),
          (2560, 1080), (2560, 1440), (3840, 2160)]
MODES = [(1, "V-Integer"), (2, "Narrower HV-Int"), (3, "Wider HV-Int")]

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print("FAIL: " + msg)


for sname, hs, vs, (arx, ary) in SOURCES:
    print("== %s at %d:%d ==" % (sname, arx, ary))
    for W, H in PANELS:
        row = []
        for sc, mname in MODES:
            kind, w, h = scale_int(W, H, sc, hs, vs, arx, ary)
            if kind == 'ratio':
                check(H < vs and (w, h) == (arx, ary),
                      "%s %dx%d %s: ratio fallback %s:%s on a panel the source fits" % (sname, W, H, mname, w, h))
                row.append("%-16s ratio %d:%d" % (mname, w, h))
                continue
            row.append("%-16s %4dx%-4d" % (mname, w, h))
            check(w <= W and h <= H, "%s %dx%d %s: %dx%d overflows the panel" % (sname, W, H, mname, w, h))
            check(h % vs == 0, "%s %dx%d %s: height %d not a multiple of %d" % (sname, W, H, mname, h, vs))
            check(w * ary == h * arx, "%s %dx%d %s: %dx%d is not %d:%d" % (sname, W, H, mname, w, h, arx, ary))
            if sc != 1:
                check(w % hs == 0 and w // hs == h // vs,
                      "%s %dx%d %s: %dx%d not an integer multiple of %dx%d" % (sname, W, H, mname, w, h, hs, vs))
        print("  %4dx%-4d  %s" % (W, H, "   ".join(row)))

# the model against the documented bugs (the IIvi script's self-test)
kind, w, h = scale_int(1280, 1024, 1, 640, 480, 256, 171)
check((kind, w, h) == ('size', 1437, 960),
      "self-test: 256:171 V-Int at 1280x1024 on 640x480 should ask 1437x960 (got %s %sx%s)" % (kind, w, h))

if failures:
    print("\n%d FAILURE(S)" % len(failures))
    sys.exit(1)
print("\nPASS: every mode fits every panel, an integer multiple at the source's aspect")
