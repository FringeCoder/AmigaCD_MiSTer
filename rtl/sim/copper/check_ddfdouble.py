#!/usr/bin/env python3
"""Check tb_copper_slots run on gen_ddfdouble.py's list (+all).

DDFSTRT == DDFSTOP on ECS/AGA, vAmigaTS Agnus/DDF/DDF/doublematch1:
  line $50  reached while idle    -> fetch from $58 to the hardware stop
  line $60  reached while running -> stops one fetch unit after the match
  line $70  reference, DDF $38-$B0
Bitplane slot positions are colour clocks, decimal, as the bench logs them.
"""
import sys
slots = {}
for l in open(sys.argv[1]):
    p = l.split()
    if p and p[0] == "SLOT" and p[3] == "bpl":
        slots.setdefault(int(p[1], 16), []).append(int(p[2]))
fails = 0
def check(what, ok, got):
    global fails
    print(("ok   " if ok else "FAIL ") + what + f": {got}")
    fails += not ok
l50, l60, l70 = slots.get(0x50, []), slots.get(0x60, []), slots.get(0x70, [])
check("line $50 (idle double match) starts at the match", bool(l50) and l50[0] == 100, l50[:1])
check("line $50 runs to the hardware stop", 220 in l50, len(l50))
check("line $60 (running double match) stops one unit after it", bool(l60) and max(l60) == 132, max(l60) if l60 else None)
check("line $70 reference, 16 slots $44-$BC", l70 == list(range(68, 189, 8)), len(l70))
print("RUN: PASS" if fails == 0 else f"RUN: FAIL ({fails})")
sys.exit(1 if fails else 0)
