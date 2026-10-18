# The seed lottery, measured

The ledger below lists every timing attempt and its result; check it before
trying something, and add a row for each new one.

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

## Ledger: every attempt, and what it did

Check here before trying something. One row per attempt, kept or not, with
the panel that judged it. "Median" is the panel's all_setup median on the
fixed seed list of its time (1-20,39 before the 10-17 sync; 21-38,41,42
after). Details are in the sections below. Add a row for every attempt,
including the ones that are reverted.

| # | target | change | commit | result | verdict |
|---|---|---|---|---|---|
| 1 | B, K | drive_sounds DDR3 data register; MAX_FANOUT on freeze / peek_scan | 4a57b79b | median -0.854 -> -0.990 | kept (part of the set that led to row 5) |
| 2 | A (CIA-B) | port B pins from a lookahead register; reset-only config false paths | 3805f67b | -0.990 -> -0.540; chipset family -0.99 -> +0.08 | kept |
| 3 | M | `MISTER_DISABLE_ADAPTIVE` (no ascal adaptive filter) | -- | -0.526; moved only ascal, freed ~160 ALMs | reverted: the filter is a feature |
| 4 | B | MAX_FANOUT on sdram_ctrl's CPU activate select | 47090495 | -0.540 -> -0.418 | kept |
| 5 | B (ss) | ss_ctrl port claim (`port_own`) as a lookahead register | e20bf7c4 | -0.418 -> -0.280, 2/20 close | kept |
| 6 | D, G | `cpu_rdq`: registered RAM return into the CPU | fb9559cc | -0.524 -> -0.661 (D/G improved, C/F/H/L worse); -1.069 with the review fixes on top | reverted (1a6aea8e): -0.465 |
| 7 | -- | review fixes + SFC/DFC in the save state | 20dd657c, fa22f9d7 | no measurable cost once cpu_rdq was out | kept (correctness) |
| 8 | -- | Template_MiSTer sys/ sync (YC #120/#114, audio pins #119) | 1219ec87 | alone: -0.465 -> -0.374; M worse (19/20) | kept |
| 9 | -- | Flink AGA sprite fine-start fix | f9399d6c | alone: A +0.328 -> -0.024; with row 8: -0.539 | kept (correctness, hardware-confirmed) |
| 10 | A | a lighter sprite fix | -- | not built: the fix is 5 regs + 5 LUTs per sprite, the minimum for a 0-3 clk delay | rejected; A's drop was placement, not size |
| 11 | hold | false path a2065 `int2` -> `int2_s1` (2-FF synchroniser) | 279cc64c | removes 1 of 3 hold failures in 60 fits | kept |
| 12 | hold | false path a2065 `csr*_out` -> `csr_shadow` | -- | not done: 16-bit word without a synchroniser; timing it is what keeps a CSR0 read coherent | rejected |
| 13 | A | blitter pointer bank read at `ptrsel`, off Agnus's DMA priority mux | e88e57ba | A -0.136 (15/20) -> +0.845 (0/20); median -0.539 -> -0.372 | kept |
| 14 | L | ss_ctrl restore decisions from registered compares (`pay_eq_*`, `crc_eq`) | da9174e6 | panel pending | -- |
| 15 | H | ddram_ctrl: the paths inside the controller, not its cache (F) | -- | path reports pending | -- |

Ideas recorded and not done, with the reason:
- Registering CIA-B's pins plainly. That makes drive select one 7 MHz cycle
  late, which is not cycle-exact; row 2 did it with a lookahead instead.
- A timing exception on the CIA timer outputs. They are real single-cycle
  paths.
- Moving sdram_ctrl's chip slot later in its 16-state schedule. That is an
  upstream redesign.
- Restructuring the restore request (`load_req_rise`) into ss_ctrl's FSM. It
  is the other source of seed 37's L path, and row 14 leaves it alone. It
  needs the request's next value from AmigaCD.sv. Try it if row 14 does not
  close L.

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

### YC sync + Flink sprite fix (f9399d6c)

Same panel (run 39140295506), on top of the revert. It adds the Template_MiSTer
sys/ sync (1219ec87) and the AGA sprite fine-start fix (f9399d6c). The fix is
three extra clk of serial pipeline per sprite, with a tap mux.

| family | reverted (1a6aea8e) | + YC sync + sprite fix |
|---|---|---|
| D sdram data into the CPU | -0.198 (18/20) | -0.174 (16/20) |
| G ddram data into the CPU | -0.063 (15/20) | -0.164 (16/20) |
| C.sdram_cache | +0.176 (7/20) | +0.324 (3/20) |
| F.ddram_cache | +0.150 (6/20) | -0.088 (12/20) |
| H.ddram_ctrl | -0.009 (10/20) | -0.188 (15/20) |
| L.ss_ctrl_internal | -0.239 (13/20) | -0.222 (15/20) |
| M.ascal | -0.079 (12/20) | -0.060 (12/20) |
| A_sys_to_sd_addr | +0.328 (4/20) | -0.136 (15/20) |
| all_setup median | -0.465 | **-0.539** |

0/20 close. The best seed is 27 at -0.014 (hold +0.167), which the pick job
took; next is 28 at -0.146. A_sys_to_sd_addr is the one family that moved
well beyond seed noise. Its subfamilies AGNUS (-0.035, 11/20) and USERIO
(+0.064, 10/20) carry it. Denise has no path in A itself, so the likely cause is
placement pressure from the sprite pipeline in the chipset region rather than a
new path. Not yet split: a panel of each change alone would say which.

Seed 22 fails hold at -0.355, from clk_114 to clk_sys, on a2065
`csr0_out` -> `csr_shadow`. That seed's clk_sys tree reaches the capture flop
0.75 ns late, and the fitter did not pad the path enough to cover it. No other
seed has a negative hold (worst otherwise +0.143). The pick job rejects any
seed with negative hold, so it cannot ship, but it is recorded here in case the
same path recurs.

### The split: sprite fix alone, sys sync alone

Same panel, each change applied on its own to the reverted head a53d83cd:
debug/split-sprite-only (bdd507bf, run 39146038697) and debug/split-sys-only
(1219ec87, run 39146041521).

| family | reverted | sprite fix only | sys sync only | both (f9399d6c) |
|---|---|---|---|---|
| A_sys_to_sd_addr | +0.328 (4/20) | -0.024 (11/20) | +0.171 (7/20) | -0.136 (15/20) |
| A.AGNUS | n/a | +0.062 (9/20) | +0.487 (4/20) | -0.035 (11/20) |
| A.USERIO | n/a | +0.199 (6/20) | +0.588 (4/20) | +0.064 (10/20) |
| D sdram data into the CPU | -0.198 | -0.287 | -0.093 | -0.174 |
| G ddram data into the CPU | -0.063 | -0.268 | -0.127 | -0.164 |
| H.ddram_ctrl | -0.009 | -0.157 | -0.150 | -0.188 |
| L.ss_ctrl_internal | -0.239 | -0.238 | -0.280 | -0.222 |
| M.ascal | -0.079 | -0.023 | -0.199 (19/20) | -0.060 |
| all_setup median | -0.465 | -0.4625 | **-0.3735** | -0.539 |
| best seed | 42 -0.049 | 32 -0.202 | 22 -0.124 | 27 -0.014 |

A follows the sprite fix. It is negative in both panels that carry the fix and
positive in both that don't. Agnus and user I/O move with it, though Denise has
no path in A, so this is placement pressure in the chipset region, not a new
path. The sys sync alone leaves A positive and is the best median of the four.
It costs ascal (M, 19/20 seeds negative), which sits next to the video
output it changes.

The two changes do not add. Together they are worse than either alone, by
more than the sum of their single-change shifts on the median. That reads as
placement interaction, not as a path either change creates. Per-change median
shifts of about 0.1 ns are within what one netlist change moves a panel, so
only A's sign flip, consistent across all four panels, is a finding.

Hold: 3 of the 60 fits fail hold, all on the same structure. Seed 22 of the
combined panel fails on a2065 `csr0_out` -> `csr_shadow`. Seeds 29 and 24 of the
sys-only panel fail on `a2065_int2` -> `int2_s1` and `csr0_out` -> `csr_shadow`. Each
is a clk_114 register in a2065_ddr3_mailbox captured on clk_sys, with
0.73-0.76 ns of clock skew. None is in AmigaCD.sdc's a2065 false-path list (the
cmd_* and bram_* handshakes are). `int2_s1` is the first flop of a 2-FF
synchronizer, and csr_shadow is a free-running sample of quasi-static status.
The sprite-only panel's worst hold is +0.013.

### Family A off the blitter pointer read (e88e57ba)

The diagnostic fits of 088710e5 (family_paths_<seed>.rpt) showed every family A
path ending in one structure: Agnus's DMA arbitration -> the blitter pointer
bank's read select -> the bank -> address_out -> Gary -> row_new -> sd_addr.
The bank is now read at ptrsel (rtl/sim/bltrd proves agnus identical on every
clock). Same panel, run 39160702587:

| family | both (f9399d6c) | + pointer read at ptrsel |
|---|---|---|
| A_sys_to_sd_addr | -0.136 (15/20) | **+0.845 (0/20)** |
| A.AGNUS | -0.035 (11/20) | +1.214 (0/20) |
| A.USERIO | +0.064 (10/20) | +1.232 (0/20) |
| A.CIAB | +0.258 (6/20) | +1.289 (0/20) |
| A.cpu_wrapper | +0.186 (4/20) | +0.891 (0/20) |
| B_114_to_sd_addr | +0.326 (4/20) | +0.288 (3/20) |
| C.sdram_cache | +0.324 (3/20) | +0.267 (5/20) |
| D sdram data into the CPU | -0.174 (16/20) | -0.205 (15/20) |
| F.ddram_cache | -0.088 (12/20) | -0.185 (14/20) |
| G ddram data into the CPU | -0.164 (16/20) | -0.099 (12/20) |
| H.ddram_ctrl | -0.188 (15/20) | -0.254 (15/20) |
| L.ss_ctrl_internal | -0.222 (15/20) | -0.247 (17/20) |
| M.ascal | -0.060 (12/20) | -0.017 (11/20) |
| all_setup median | -0.539 | **-0.372** |

Family A is closed on every seed. Its worst case over 20 seeds is +0.230, and
no sub-family fails anywhere. That includes the CPU address path through
cpu_wrapper, which shared the Gary/row_new tail. The panel median is the best
measured since the 10-17 upstream sync. Worst hold is +0.132, so no hold
failures in 20 fits.

Still 0/20 close. Best seed 25 at -0.243, then 41 (-0.259) and 26 (-0.271): a
tighter spread, with no lucky near-miss like the previous panel's 27
(-0.014). The walls left are the four that predate this work, each failing in
three quarters of the seeds:
- L, ss_ctrl's own state machine;
- H, ddram_ctrl;
- D and F/G, the cache data into the CPU.
