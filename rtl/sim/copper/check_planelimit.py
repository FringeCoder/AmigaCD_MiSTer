#!/usr/bin/env python3
"""Bitplane DMA must stop entirely when BPLCON0 asks for more planes than the
fetch mode and resolution carry (FMODE 0: lores 8, hires 4, shres 2; FMODE 1/2:
8, 8, 4; FMODE 3: 8). Real A1200: vAmigaTS Agnus/DDF/AGADDF/agaddf1-14.

Run from rtl/sim/copper after:  vvp tbs +memh=planelimit.memh +out=planelimit_sim.txt +all
"""
import collections, sys
bpl = collections.Counter()
for l in open("planelimit_sim.txt"):
    _, v, h, o = l.split()
    if o == "bpl": bpl[int(v, 16)] += 1
fails = 0
for l in open("planelimit_cases.txt"):
    v, exp, label = l.rstrip("\n").split("\t")
    v, exp = int(v, 16), exp == "1"
    n = bpl[v]
    ok = (n > 0) == exp
    fails += not ok
    print(f"{'CHECK ok  ' if ok else 'CHECK FAIL'} line {v:#x} {label:24s} bitplane slots {n:3d}, expected {'some' if exp else 'none'}")
print("RUN: PASS" if not fails else "RUN: FAIL")
sys.exit(1 if fails else 0)
