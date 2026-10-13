#!/usr/bin/env python3
"""Chip RAM image for the bitplane plane-limit check (tb_copper_slots +all).

One test line per case, eight lines apart; the copper sets BPLCON0 and FMODE
in the blanking two lines before each. Bitplane data is zero -- only whether
bitplane DMA happens is measured. Cases are each mode at its plane limit (DMA
expected) and one past it (none expected): vAmigaTS AGADDF on a real A1200.
Prints the case table check_planelimit.py reads.
"""
import sys
# (label, BPLCON0, FMODE, dma expected)
CASES = [
    ("lores FMODE0 8 planes",    0x0210, 0, True),
    ("lores FMODE0 7 planes",    0x7200, 0, True),
    ("hires FMODE0 4 planes",    0xC200, 0, True),
    ("hires FMODE0 5 planes",    0xD200, 0, False),
    ("shres FMODE0 2 planes",    0x2240, 0, True),
    ("shres FMODE0 3 planes",    0x3240, 0, False),
    ("hires FMODE1 8 planes",    0x8210, 1, True),
    ("shres FMODE1 4 planes",    0x4240, 1, True),
    ("shres FMODE1 5 planes",    0x5240, 1, False),
    ("shres FMODE3 8 planes",    0x0250, 3, True),
]
FIRST, STEP, BPL = 0x40, 8, 0x20000
words = []
def mv(r, v): words.extend([r & 0x1fe, v & 0xffff])
def wait(v, h): words.extend([((v & 0xff) << 8) | (h & 0xfe) | 1, 0xfffe])
mv(0x100, 0x0200); mv(0x106, 0); mv(0x1fc, 0)
mv(0x08e, 0x2c81); mv(0x090, 0x2cc1); mv(0x092, 0x0038); mv(0x094, 0x00d0)
mv(0x108, 0); mv(0x10a, 0)
for p in range(8):
    mv(0xe0 + 4 * p, BPL >> 16); mv(0xe2 + 4 * p, BPL & 0xffff)
line = FIRST
table = []
for label, b0, fm, exp in CASES:
    wait(line - 2, 0xe0); mv(0x1fc, fm); mv(0x100, b0)
    wait(line + 1, 0xe0); mv(0x100, 0x0200)        # off again after the line
    table.append((line, label, exp))
    line += STEP
words.extend([0xffff, 0xfffe])
with open(sys.argv[1] if len(sys.argv) > 1 else "planelimit.memh", "w", newline="\n") as f:
    f.write("@1000\n")
    for w in words: f.write(f"{w:04x}\n")
with open("planelimit_cases.txt", "w", newline="\n") as f:
    for v, label, exp in table: f.write(f"{v:x}\t{int(exp)}\t{label}\n")
