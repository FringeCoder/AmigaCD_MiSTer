#!/usr/bin/env python3
"""Compare tb_dpf_priority's dump with vAmiga's OCS/ECS translateDPF.

vAmiga (Core/Components/Denise/Denise.cpp, translateDPF): index1 is planes
1,3,5 and index2 planes 2,4,6; playfield 2's colour is index2 + 8 on OCS/ECS;
a playfield whose priority code is above 4 has its colour masked to 0 but is
still solid; PF2PRI picks the winner where both are solid.
"""
import sys
fails = n = 0
for l in open(sys.argv[1]):
    p = l.split()
    if not p or p[0] != "P": continue
    c, d, npf, got = map(int, p[1:])
    i1 = (d & 1) | ((d >> 1) & 2) | ((d >> 2) & 4)
    i2 = ((d >> 1) & 1) | ((d >> 2) & 2) | ((d >> 3) & 4)
    pf1p, pf2p, pri = c & 7, (c >> 3) & 7, (c >> 6) & 1
    c1 = 0 if pf1p > 4 else i1
    c2 = 0 if pf2p > 4 else i2 + 8
    if i1 and i2: want = c2 if pri else c1
    elif i1: want = c1
    elif i2: want = c2
    else: want = 0
    want_npf = (2 if i2 else 0) | (1 if i1 else 0)
    n += 1
    if got != want or npf != want_npf:
        fails += 1
        if fails <= 10:
            print(f"FAIL bplcon2 {c:02x} pixel {d:02x}: colour {got} want {want}, opaque {npf} want {want_npf}")
print(f"{n} cases, {fails} differ")
print("RUN: PASS" if n == 128 * 64 and fails == 0 else "RUN: FAIL")
sys.exit(1 if fails or n != 128 * 64 else 0)
