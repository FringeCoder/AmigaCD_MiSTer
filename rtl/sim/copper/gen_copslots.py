#!/usr/bin/env python3
"""Chip RAM image for tb_copper_slots: the copper-throughput probe's copper list.

The same list as the hardware probe that was run on the MiSTer and in
Copperline on 2026-10-11 (bitplane regions only): five regions of four test
lines, each test line a WAIT at hpos $07 and fifty back-to-back MOVEs to
COLOR00. Written as 16-bit words for $readmemh, copper list at word $1000
(byte $2000), all eight bitplane pointers at byte $20000 (zeroed RAM).
"""
import sys
NMOVES = 50
COLS = [0x0f00, 0x00f0, 0x000f, 0x0ff0]
REGIONS = [  # label, BPLCON0, FMODE
    ("0 planes",        0x0200, 0),
    ("4 planes FMODE0", 0x4200, 0),
    ("8 planes FMODE0", 0x0210, 0),
    ("8 planes FMODE1", 0x0210, 1),
    ("8 planes FMODE3", 0x0210, 3),
]
FIRST, LINES_PER_REGION, STRIDE, WAIT_H = 0x40, 4, 4, 0x07
BPL = 0x20000

words = []
def mv(reg, val): words.extend([reg & 0x1fe, val & 0xffff])
def wait(v, h): words.extend([((v & 0xff) << 8) | (h & 0xfe) | 1, 0xfffe])

mv(0x100, 0x0200); mv(0x106, 0x0000); mv(0x1fc, 0x0000)
mv(0x08e, 0x2c81); mv(0x090, 0x2cc1)
mv(0x092, 0x0038); mv(0x094, 0x00d0)
mv(0x108, 0); mv(0x10a, 0)
for p in range(8):
    mv(0xe0 + 4 * p, BPL >> 16); mv(0xe2 + 4 * p, BPL & 0xffff)
mv(0x180, 0)
line = FIRST
test_lines = []
for label, bplcon0, fmode in REGIONS:
    wait(line - 2, 0xe0)
    mv(0x1fc, fmode); mv(0x100, bplcon0)
    for k in range(LINES_PER_REGION):
        if k == 0: test_lines.append((line, label))
        wait(line, WAIT_H)
        for i in range(NMOVES):
            mv(0x180, COLS[i % 4])
        mv(0x180, 0)
        line += STRIDE
    line += 4
mv(0x100, 0x0200)
words.extend([0xffff, 0xfffe])

out = sys.argv[1] if len(sys.argv) > 1 else "copslots.memh"
with open(out, "w", newline="\n") as f:
    f.write("@1000\n")
    for w in words: f.write(f"{w:04x}\n")
for v, label in test_lines: print(f"{v:#x} {label}")
