#!/usr/bin/env python3
"""Chip RAM image for the DDFSTRT == DDFSTOP check (check_ddfdouble.py).

vAmigaTS Agnus/DDF/DDF/doublematch1 writes DDFSTRT and DDFSTOP to the same
value. Where that position is reached while bitplane DMA is idle, an A500
ECS and an A1200 (photographs in vAmigaTS) fetch from there to the hardware
stop; where it is reached while DMA is already running, the fetch stops
after the current unit. This list sets up both cases, lores 1 plane, ECS:

  line $50: DDFSTRT = DDFSTOP = $58, written at hpos $01 -- reached idle
  line $60: DDF $38-$B0 as normal, then at hpos ~$40 DDFSTRT = DDFSTOP = $70
            -- reached while running
  line $70: DDF $38-$B0, untouched -- the reference line

Copper list at word $1000 (byte $2000), bitplane 1 at byte $20000.
"""
import sys
BPL = 0x20000
w = []
def mv(r, v): w.extend([r & 0x1fe, v & 0xffff])
def wait(v, h): w.extend([((v & 0xff) << 8) | (h & 0xfe) | 1, 0xfffe])
mv(0x100, 0x1200); mv(0x106, 0); mv(0x1fc, 0)
mv(0x08e, 0x2c81); mv(0x090, 0x2cc1)
mv(0x108, 0); mv(0x10a, 0)
mv(0xe0, BPL >> 16); mv(0xe2, BPL & 0xffff)
mv(0x092, 0x0038); mv(0x094, 0x00b0)
# Every line re-points plane 1 so each line fetches from the same address.
def line_setup(v):
    wait(v - 1, 0xe0); mv(0xe0, BPL >> 16); mv(0xe2, BPL & 0xffff)
line_setup(0x4f)
wait(0x4f, 0xe0); mv(0x092, 0x0058); mv(0x094, 0x0058)   # line $50: reached idle
wait(0x51, 0xe0); mv(0x092, 0x0038); mv(0x094, 0x00b0)
wait(0x60, 0x40); mv(0x092, 0x0070); mv(0x094, 0x0070)   # line $60: reached running
wait(0x61, 0x01); mv(0x092, 0x0038); mv(0x094, 0x00b0)
w.extend([0xffff, 0xfffe])
out = sys.argv[1] if len(sys.argv) > 1 else "ddfdouble.memh"
with open(out, "w", newline="\n") as f:
    f.write("@1000\n")
    for x in w: f.write(f"{x:04x}\n")
