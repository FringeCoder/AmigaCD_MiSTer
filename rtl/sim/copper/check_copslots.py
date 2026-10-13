#!/usr/bin/env python3
"""Compare tb_copper_slots' slot log against Copperline's trace of the same list.

Copperline numbers colour clocks from a different origin than agnus_beamcounter.
The offset is found, not assumed: refresh owns four fixed slots per line on every
Amiga, so the offset is the shift that puts our refresh slots on Copperline's.
Then every one of the 227 colour clocks of each test line must have the same
owner. A slot past the end of our line is read from the next line, which the
bench logs for that reason.

The three colour clocks at the end of the line, $E0-$E2 in Copperline's
numbering, are reported but not asserted. There the two disagree by one slot on
copper-busy lines, measured 2026-10-11: Copperline leaves $E1 free and gives the
copper $E2; the core gives the copper $E1 and refresh $E2. The copper's total per
line is the same either way. That wrap is exactly where emulators are known to
differ, and vAmigaTS Agnus/Copper/CopDma/cycleE0 has a real-hardware photo of
it -- settle it from that, not from either emulator, then assert it here.

Run from rtl/sim/copper after the bench:  python3 check_copslots.py
"""
import collections, sys
OWN = {'cop': 'C', 'bpl': 'B', 'ref': 'R', 'cpu': '-'}
sim = collections.defaultdict(dict)
for l in open('copslots_sim.txt'):
    _, v, h, o = l.split()
    sim[int(v, 16)][int(h)] = OWN.get(o, o)
ref = {}
for l in open('copslots_copperline.txt'):
    if l.startswith('#') or not l.strip(): continue
    v, s = l.split()
    ref[int(v, 16)] = s
LINE = 227
ASSERTED = range(0, 0xE0)        # $E0-$E2: reported only, see above
def at(v, h):
    return sim[v + h // LINE].get(h % LINE, '?')
v0 = min(ref)
cl_r = [h for h, c in enumerate(ref[v0]) if c == 'R']
offset = next((o for o in range(-16, 17) if all(at(v0, h + o) == 'R' for h in cl_r)), None)
fails = 0
if offset is None:
    print('CHECK FAIL refresh slots do not line up at any offset -- the bench is not running the list')
    fails += 1
else:
    print(f'offset {offset} colour clocks (refresh aligned: {cl_r})')
    for v, s in sorted(ref.items()):
        got = ''.join(at(v, h + offset) for h in range(LINE))
        bad = [h for h in ASSERTED if got[h] != s[h]]
        wrap = [h for h in range(0xE0, LINE) if got[h] != s[h]]
        print(f"{'CHECK ok  ' if not bad else 'CHECK FAIL'} line {v:#x}: copper {got.count('C')}/{s.count('C')} "
              f"bitplane {got.count('B')}/{s.count('B')} slots, {len(bad)} differ in $00-$DF"
              + (f"; MEASURE $E0-$E2 copperline {s[0xE0:]} core {got[0xE0:]}" if wrap else ""))
        if bad:
            fails += 1
            print('   copperline', s); print('   core      ', got)
            print('              ' + ''.join('^' if h in bad else ' ' for h in range(LINE)))
print('RUN: PASS' if not fails else 'RUN: FAIL')
sys.exit(1 if fails else 0)
