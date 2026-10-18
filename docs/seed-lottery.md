# The seed lottery, measured

Until 2026-10-17 a build of this core closed timing on one placement seed in
59 (seed 39, setup +0.005 ns). Every RTL change re-rolled placement, so every
change needed a fresh sweep and the result was luck. This records what was
measured, what was changed, and how to keep measuring.

## How to measure

`fit.yml`, dispatched with a seed list, fits each seed in its own job. Every
job runs `scripts/ci-sta-families.tcl`, which prints the worst setup slack of
each recurring path family on that seed -- passing seeds included -- and the
pick job prints the **panel**: how many seeds close, the median setup slack,
and per family the median, worst and number of seeds it fails in.

Judge a change by the panel on a fixed seed list, never by the best seed.
The list used throughout was `1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,39`.

The same family moves by up to 0.6 ns between panels from placement alone
(B.ss_ctrl read -0.26, +0.17 and -0.42 on three netlists that did not touch
it), so read a single family's shift of less than ~0.3 ns as noise. The panel
median is steadier.

The gate (`ci-fit.sh`) is the slow 100 C corner only, as in upstream
(`TIMEQUEST_MULTICORNER_ANALYSIS OFF`). The family report takes the minimum
over every corner, so a seed can close the gate with a family negative at the
slow -40 C corner -- ascal's polyphase filter, usually.

## What was found

Parsing the 58 failing seeds of the 59-seed sweep: one family -- clk_sys
chipset registers into `sdram_ctrl`'s `sd_addr` I/O registers, inside half a
7 MHz cycle -- was negative in 54 seeds and the worst path in 47. Its longest
form ran CIA-B timer -> port B -> Paula floppy DMA request -> Agnus -> blitter
pointer -> Gary -> `row_new` -> `sd_addr`, 16 logic levels, the last hop a
fixed ~5 ns route: the SDRAM address pins sit on three edges of the die
(X8/X32/X56/X62/X84 on the bottom, X89 on the right, X40 at the top), so no
placement is near all of them.

The two-cycle budget on that path is real: the chipset's registers update on
the same 28 MHz edge where `c1` rises, which the SDC already shows is exactly
two clk_114 cycles before the SDRAM samples the row.

## What was changed, and the panels

Every RTL change is cycle-exact, proven by an equivalence bench against a
frozen copy of the previous module and falsified by mutation.

| panel | change | median setup | close |
|---|---|---|---|
| 1 | baseline (885b8d51) | -0.854 | 1/20 (seed 39) |
| 2 | drive_sounds DDR3 data register; `MAX_FANOUT` on freeze / peek_scan | -0.990 | 0/20 |
| 3 | CIA-B port B lookahead register; false paths on reset-only config | -0.540 | 0/20 |
| 4 | (experiment) `MISTER_DISABLE_ADAPTIVE` -- reverted | -0.526 | 0/20 |
| 5 | `MAX_FANOUT` on sdram_ctrl's CPU activate select | -0.418 | 2/20 |
| 6 | save-state port claim as a lookahead register (`port_own`) | -0.280 | 2/20 (10, 14) |

- **drive_sounds** (`rtl/sim/dsnd`): the HPS read data is registered before
  the 4:1 sample select. One clock more per DDR3 read; the bench proves the
  module identical to the previous one behind a port one clock slower.
- **CIA-B port B** (`rtl/sim/ciab`): the pins (drive select, motor) come off
  a register loaded with their next value, computed from the next-state logic
  of DDRB, PRB, both timers and amiga_clk's eclk. Identical on every clock.
  This took the chipset family from -0.99 to +0.08 median.
- **USERIO config** (`AmigaCD.sdc`): `chipset_config` and `memory_config`
  (not bit 6) are latched only while reset is held, like `cpu_config`.
- **ss_ctrl port_own** (`rtl/sim/ssown`): `freeze | peek_scan` as a register
  loaded from both registers' next values. B.ss_ctrl went from -0.42 to +0.32.
- **Not kept:** dropping ascal's adaptive filter moved only ascal's own family
  and freed ~160 ALMs.
- **Not done:** registering CIA-B's pins plainly (one 7 MHz cycle late on
  drive select), a timing exception on the CIA timer outputs, and moving the
  SDRAM controller's chip slot later in its 16-state schedule (an upstream
  redesign).

## Where it stands

Seed 14 of panel 6: setup +0.130, hold +0.243, every corner positive. The
lottery is better odds, not gone: 2 seeds in 20 against 1 in 59, with two
more within 0.12 ns. The walls left are many and small -- ss_ctrl's own state
machine (L, -0.09 median), the residual chipset cone (USERIO host address and
external floppy map, Agnus BPLCON0), sdram_ctrl's CPU select, ddram_ctrl and
ascal at -40 C -- each between -0.6 and 0 ns in a minority of seeds.

## After the 2026-10-17 upstream sync

Minimig-AGA `26eb46a..0bf2ab1` (all ten commits) re-rolled the netlist and
made it worse: 1 of 60 seeds closes (56: setup +0.008, hold +0.246 at the gate
corner; -0.110 at slow -40 C in ddram_ctrl), median about -0.42 ns against
-0.28 before the sync. Seed 14 went from +0.130 to -0.346.

The new wall is upstream's TG68K work, mostly the 68030 bus error frame
(`3afc8170`) and the address-error PC (`15a9bce9`): cache read data
(`cpu_dat_r`, clk_114) through cpu_wrapper's `ramdat` / `cpu_din` muxes and the
kernel's `data_read` into a five-level `data_write_tmp` mux, and `write_ena`
into `ae_pc`, inside one 8.8 ns clk_114 -> clk_sys relationship. It is the
worst family (D/G) on about half the seeds. The families this document fixed
stay fixed. Taking that path off is the next piece of work.


### cpu_rdq (fb9559cc): the CPU input wall moves, the total does not improve

`rtl/cpu_rdq.v` registers the ram1/ram2 return mux at clk_114 from the ports'
next-state outputs, taking a level off the cache -> TG68K hop. Same panel
(seeds 21-38, 41, 42), before -> after:

| family | median before | median after | failing |
|---|---|---|---|
| D/G cache data into the CPU | -0.317 / -0.223 | S +0.079, G +0.933 | 18, 17 -> 6 |
| H.ddram_ctrl | -0.204 | -0.426 | 14 -> 20 |
| L.ss_ctrl_internal | -0.011 | -0.338 | 11 -> 19 |
| F.ddram_cache | +0.027 | -0.224 | 7 -> 15 |
| C.sdram_cache | +0.404 | +0.131 | 1 -> 8 |
| A_sys_to_sd_addr | +0.480 | -0.120 | 7 -> 14 |
| all_setup | -0.524 | -0.661 | 20 -> 20 |

0/20 close before and after. The family it was aimed at is fixed (D folds into
S, which now goes through cpu_rdq). C and F lost what the register's D input
added to the caches' output cones -- the expected cost. A and L moved by more
than the ~0.3 ns placement noise measured earlier, so this is not only
re-placement. Unless the next panel says otherwise, the change does not pay
for itself as it stands.

### Review fixes on top of cpu_rdq (20dd657c): worse again

Same panel. The review fixes (CIA-B reset lookahead, ss_ctrl fast_ena hold,
save-state refusals and halted restore) are behaviour fixes, small in logic,
yet the panel moved a long way:

| family | baseline | cpu_rdq | + review fixes |
|---|---|---|---|
| S / D+G (CPU input) | -0.317 | +0.079 (6/20) | -0.007 (10/20) |
| C.sdram_cache | +0.404 | +0.131 | -0.208 (18/20) |
| F.ddram_cache | +0.027 | -0.224 | -0.431 (19/20) |
| H.ddram_ctrl | -0.204 | -0.426 | -0.619 (20/20) |
| L.ss_ctrl_internal | -0.011 | -0.338 | -0.578 (18/20) |
| M.ascal | -0.073 | -0.086 | -0.272 (19/20) |
| all_setup | -0.524 | -0.661 | -1.069 |

Best seed 31 at -0.190; 0/20 close. Every family that is not the one
cpu_rdq targets drifts the same way at each step, which reads as the fitter
running out of room (83% ALMs before cpu_rdq) rather than as any one path.
cpu_rdq's own register is the change with a direct cost on C and F, and its
gain on S has already halved.

### cpu_rdq reverted (1a6aea8e): back to the baseline

Same panel, with the review fixes and SFC/DFC kept:

| family | baseline (04f7c750) | cpu_rdq | + review fixes | reverted |
|---|---|---|---|---|
| D sdram data into the CPU | -0.317 (18/20) | (S) +0.079 | (S) -0.007 | -0.198 (18/20) |
| G ddram data into the CPU | -0.223 (17/20) | +0.933 | +1.240 | -0.063 (15/20) |
| C.sdram_cache | +0.404 | +0.131 | -0.208 | +0.176 (7/20) |
| F.ddram_cache | +0.027 | -0.224 | -0.431 | +0.150 (6/20) |
| H.ddram_ctrl | -0.204 | -0.426 | -0.619 | -0.009 (10/20) |
| L.ss_ctrl_internal | -0.011 | -0.338 | -0.578 | -0.239 (13/20) |
| M.ascal | -0.073 | -0.086 | -0.272 | -0.079 (12/20) |
| A_sys_to_sd_addr | +0.480 | -0.120 | n/a | +0.328 (4/20) |
| all_setup median | -0.524 | -0.661 | -1.069 | **-0.465** |

0/20 close; best seeds 42 (-0.049) and 28 (-0.054). The revert recovers the
baseline and a little more, so the review fixes and SFC/DFC cost nothing
measurable on their own: the drift in the previous panel was cpu_rdq's.
D and G are the CPU input wall again, as before cpu_rdq.
