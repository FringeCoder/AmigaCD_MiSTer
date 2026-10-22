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
| 14 | L | ss_ctrl restore decisions from registered compares (`pay_eq_*`, `crc_eq`) | da9174e6 | L -0.247 (17/20) -> -0.163 (15/20), under the noise line; median -0.372 -> -0.549 (D -0.301, G -0.297) | reverted (c4e0507e); the DDR3-backed restore bench `rtl/sim/ssload` is in da9174e6 for reuse |
| 15 | H, F | cpu_cache_new `sdr_read_req` from its own expression, off the state machine's next-state decode | c496d5b1 | F -0.185 (14/20) -> +0.135 (4/20), H -0.254 -> -0.052 (11/20); median -0.372 -> -0.355; **1/20 close** (seed 35, +0.051) | kept |
| 16 | L | every restore refusal from a registered flag: magic, version, length, core_words (`rd_*_bad`, `len_bad`), fingerprint (`kick_eq`), payload CRC (`crc_eq`, row 14's) | 0a8fe3b7 | L -0.285 (19/20) -> -0.189 (17/20), under the noise line; median -0.355 -> -0.459, 1 -> 0 close (H -0.247, F -0.145, D -0.175, G -0.099) | reverted (5029a4a3); the 120-round restore bench with every refusal kind is in 0a8fe3b7 for reuse |
| 17 | H | MAX_FANOUT 16 on ddram_ctrl's `ss_port_own` (DDR3 port-0 grant, >100 loads) | 2b894af6 | took effect (8 copies), ss_port_own paths gone; H -0.052 -> -0.055 (11/20 both), median -0.355 -> -0.393, 1 -> 0 close | reverted (85328d13): it removed one seed's outlier, which the panel does not count |
| 18 | L | multicycle 2 from ss_ctrl's `shadow_rd_addr` into ss_ctrl (the shadow readback round trip; the address is held >= 6 clk_114 cycles at every read, checked in rtl/sim/ssown) | d6f02c61 | L -0.285 (19/20, worst -1.083) -> -0.159 (14/20, worst -0.696); vs the same RTL's 2b894af6 panel -0.316 (18/20, worst -2.960); median -0.355 -> -0.519 (D, G, M re-rolled) | kept: a proven constraint, its own family better on median, count and worst, the median drop in families it does not reach |
| 19 | hold | false path into `ss_dbg_meta` (first stage of the diagnostics' 2-FF synchroniser); same panel as row 18 | d6f02c61 | 0 hold failures in 20 (worst +0.174), against 2 on the panel before | kept |
| 20 | D, G | row 6 again: `cpu_rdq`, the RAM return registered at clk_114 with the port select applied (lookahead; equal to the old mux on every clk_sys edge), on the merged netlist | ad8aa2a7 | S (was D) -0.255 (20/20) -> +0.101 (6/20), G -0.211 -> +1.139 (0/20); but C +0.510 -> -0.129 (12/20), F -0.005 -> -0.399 (20/20), H -0.105 -> -0.596 (20/20), L -0.159 -> -0.323 (19/20); median -0.519 -> -0.728, 0/20 close either way | reverted (row 6's result again: the wall moves to the caches and ddram_ctrl, and the total gets worse) |
| 21 | L | the RTL answer to row 18: `ss_regshadow` registers its set/clear readback (DMACON/INTENA/ADKCON) on the array read's clk_sys edge, so nothing from `shadow_rd_addr` reaches ss_ctrl and row 18's multicycle is removed (proven in rtl/sim/regshadow) -- panelled on cf8f795c, i.e. without row 20 and with the 68030-no-MMU save state change (75772818: a 7-bit CACR restore mux and a reset term in the kernel), which is small and on the CPU side | 89e08f32 | L -0.159 (14/20) -> -0.275 (17/20), median -0.519 -> -0.582, 0/20 close either way; best seed 31 -0.290 (run 39341492928) | kept on the owner's call (2026-10-20): within noise, not an improvement by the rule, but an RTL fact in place of an SDC exception, proven equivalent in rtl/sim/regshadow |
| 22 | D, G | the TG68K takes a RAM read only when its data is two clk_114 old (cpu_rdgate: ready one clk_114 behind ack, data ANDed with it) and AmigaCD.sdc says so with a -start multicycle; the caches ack read hits from IDLE (fast_hit) so hits keep their latency. Costs a clk_sys on ~10% of TG68K reads (misses/fills ending on the tight edge), none on hits; fx68k untouched. Proven in rtl/sim/rdgate | d7823233 | median -0.556 -> -0.877, 0/20 close; D -0.344 -> -0.310, G -0.363 -> -0.233 (both still failing in 16-18/20); C +0.348 -> -0.335 (19/20), F -0.206 -> -0.520, H -0.275 -> -0.605, L -0.225 -> -0.448 (all 20/20) | reverted: the target barely moved and every cache family paid for it |
| 23 | all (area) | remove five save-state retiming banks that re-time crossings AmigaCD.sdc already false-paths: the restore vector bank ss_state_out_q (2346), the CIA capture regs (394) and restore regs (394), Akiko's capture (1052) and restore (1052) -- 5238 flops, ~10% of the design's registers. Not a path fix: the D/G split showed every seed still 0.34-0.54 ns short without D/G, each in a different family, at 84% ALMs | b80fca71 | median -0.556 -> -0.496, 0/20 close (best seed 27, -0.039); H -0.275 -> -0.177, L -0.225 -> -0.054, F -0.206 -> -0.100, G -0.363 -> -0.405, D, C, M unchanged; no hold failures; registers 52,321 -> 48,441 but ALMs only 35,075 -> 34,913 | kept: the median and three families better, none clearly worse -- though every shift is under the noise line |
| 24 | D, G | option 1: row 22's read gate and multicycle WITHOUT the fast hit, on row 23's netlist. Costs a clk_sys on every TG68K cache hit (44% of reads in rtl/sim/rdgate); fx68k untouched | 04926004 | median -0.496 -> -0.493, 0/20 close (best 38, -0.200); D -0.344 -> -0.100 (14/20), G -0.405 -> -0.026 (11/20); C +0.379 -> +0.100, H -0.177 -> -0.209, L -0.054 -> -0.096, F, M unchanged | reverted on the owner's call: the target moves a lot, the total does not, and every TG68K cache hit pays a clk_sys |
| 25 | D, G | option 2: row 24's gate plus a LEAN fast hit -- the tag compare drives only ack/state/tag write (data and tag-write words load in IDLE on every TG68K read select), no address comparator (a registered fast_hit-was-on guard instead; rtl/sim/rdgate check H proves the address never moves under a fast-hit select). Hits keep their latency; ~9.5% of TG68K reads (misses ending on the tight edge) a clk_sys later | 406e0a62 | median -0.496 -> -0.764, 0/20 close (best 36, -0.236); D -0.574, G -0.637 (19/20 each), L -0.231 (20/20), H -0.265 | reverted: worse than row 23 and row 24 on every count |
| 26 | all (tool) | `PLACEMENT_EFFORT_MULTIPLIER 4.0` and `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM` in AmigaCD.qsf on row 23's sources: no added logic, fit time only (raised by an external review) | 8312cd4a | 19 of 20 seeds (31 still queued at scoring): median -0.496 -> -0.740, 0/19 close (best 34, -0.320); D -0.344 -> -0.708 (19/19), G -0.405 -> -0.621 (19/19), H -0.177 -> -0.316 (18/19), F -0.100 -> -0.166, L -0.054 -> -0.105, C, M unchanged; hold clean (worst +0.184); fit 27-44 min per seed | reverted: worse on the median and in every failing family |

Ideas recorded and not done, with the reason:
- [Done as row 21, 2026-10-19, with no added latency: the set/clear select
  loads on the array read's edge rather than behind it.] Registering
  ss_regshadow's rd_data (its set/clear mux) on clk_sys: the RTL
  alternative to row 18's multicycle. ss_ctrl's 6-cycle wait would cover the
  extra stage, and the replay walk would not see it (it reads mem_q, not
  rd_data; d6f02c61's message wrongly says otherwise). Not done because the
  multicycle states the same fact without adding a register; try it if row 18
  is reverted for anything other than "no change".
- Checking a MAX_FANOUT assignment took effect: the map report's "Registers
  Duplicated to Honor Maximum Fanout Requirements" table lists the copies. On
  the 0a8fe3b7 netlist it lists only sdram_ctrl's write_req (3 copies): row 1's
  freeze and peek_scan and row 4's st0_cpu and sdr_read_req created none, so
  they are no longer doing anything (freeze's loads moved to port_own in
  e20bf7c4). Harmless, but not to be counted on. [Removed from AmigaCD.qsf
  2026-10-20 after the same table on run 39341492928 (row 21's netlist) still
  listed only write_req.]
- Registering CIA-B's pins plainly. That makes drive select one 7 MHz cycle
  late, which is not cycle-exact; row 2 did it with a lookahead instead.
- A timing exception on the CIA timer outputs. They are real single-cycle
  paths.
- Moving sdram_ctrl's chip slot later in its 16-state schedule. That is an
  upstream redesign.
- Restructuring the restore request (`load_req_rise`) into ss_ctrl's FSM.
  Rows 14 and 16 took every restore compare off load_reject's fan-out and
  bought 0.08 and 0.10 ns: L is not held down by the compares, so this one
  is not expected to help either. Before a third L attempt, read the paths
  left on a netlist that carries row 16's flags (0a8fe3b7): what remains
  after the compares -- load_reject's own fan-out (a dozen registers, the
  state register among them) or the placement of ss_ctrl against the DDR3
  read port -- is the thing to change, not another compare.

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

### Family L from registered compares (da9174e6) -- reverted

ss_ctrl's restore decisions (pay_idx against four constants, crc against
want_crc) became flags loaded with pay_idx and a registered crc_eq. Same
panel, run 39169155300:

| family | e88e57ba | + registered compares |
|---|---|---|
| L.ss_ctrl_internal | -0.247 (17/20) | -0.163 (15/20) |
| D sdram data into the CPU | -0.205 (15/20) | -0.301 (18/20) |
| F.ddram_cache | -0.185 (14/20) | -0.095 (12/20) |
| G ddram data into the CPU | -0.099 (12/20) | -0.297 (17/20) |
| H.ddram_ctrl | -0.254 (15/20) | -0.248 (17/20) |
| M.ascal | -0.017 (11/20) | -0.093 (15/20) |
| all_setup median | **-0.372** | -0.549 |

L moved 0.08 ns, under the noise line. The median fell by 0.18, carried by D
and G, which the change does not touch: a placement re-roll, but no gain to
set against it. Reverted in c4e0507e. Worst hold +0.199; best seed 22 at
-0.132.

### Cache read request off the state decode (c496d5b1)

The diagnostic fits of 3dbfa5a1 showed H's worst path was not inside
ddram_ctrl: on seeds 31 and 22 it was F's path, ram2's D-cache tag RAM -> the
18-bit tag compare -> the cache state machine's next-state decode ->
sdr_read_req (-0.331 on seed 31, where sdr_read_req ended 6 of the 10 worst
H paths). ddram_ctrl's own paths came second (wq_a -> sp_conf_r, -0.002 on
seed 35). sdr_read_req now has its own expression; rtl/sim/cachereq proves the
module identical on every clock. The module is shared with ram1. Same panel,
run 39175622637:

| family | e88e57ba | + cache request off the decode |
|---|---|---|
| A_sys_to_sd_addr | +0.845 (0/20) | +0.486 (2/20, A.cpu_wrapper) |
| B_114_to_sd_addr | +0.288 (3/20) | +0.173 (5/20) |
| C.sdram_cache | +0.267 (5/20) | +0.380 (1/20) |
| D sdram data into the CPU | -0.205 (15/20) | 0.000 (10/20) |
| F.ddram_cache | -0.185 (14/20) | **+0.135 (4/20)** |
| G ddram data into the CPU | -0.099 (12/20) | +0.062 (7/20) |
| H.ddram_ctrl | -0.254 (15/20) | -0.052 (11/20) |
| L.ss_ctrl_internal | -0.247 (17/20) | -0.285 (19/20) |
| M.ascal | -0.017 (11/20) | -0.063 (16/20) |
| all_setup median | -0.372 | **-0.355** |

Seed 35 closes (setup +0.051, hold +0.234): the first seed to close since the
10-17 sync. Worst hold +0.174. Kept. L is now the widest wall, failing in 19
of 20 seeds with a worst of -1.083.

### Family L from every refusal as a flag (0a8fe3b7) -- reverted

Every restore refusal gate (magic, version, length, core_words, fingerprint,
payload CRC) read a flag loaded with its operand, where c496d5b1's panel had
the compares in front of load_busy on seeds 29, 42, 37 and 31. Same panel,
run 39181718397:

| family | c496d5b1 | + refusals from flags |
|---|---|---|
| L.ss_ctrl_internal | -0.285 (19/20) | -0.189 (17/20) |
| D sdram data into the CPU | 0.000 (10/20) | -0.175 (16/20) |
| F.ddram_cache | +0.135 (4/20) | -0.145 (15/20) |
| G ddram data into the CPU | +0.062 (7/20) | -0.099 (14/20) |
| H.ddram_ctrl | -0.052 (11/20) | -0.247 (18/20) |
| M.ascal | -0.063 (16/20) | -0.023 (11/20) |
| all_setup median | **-0.355** | -0.459 |

L moved 0.10 ns, under the noise line, the families the change does not touch
re-rolled worse, and seed 35 no longer closes (best seed 24, -0.017).
Reverted in 5029a4a3. Worst hold +0.192.

F's swing between these two panels (+0.135 -> -0.145) on an unchanged cache
is the noise line at work: c496d5b1's gain on F and H is real only as far as
it holds on the next panel that does not touch them.

### MAX_FANOUT on ddram_ctrl's ss_port_own (2b894af6) -- reverted

Run 39186900101. The duplicates were made (8 per seed) and the ss_port_own ->
d_address paths that were seed 33's -1.386 are gone, but the panel did not
move: H -0.055 (11/20), median -0.393, 0/20 close (best seed 38, -0.093). One
seed's outlier is not what the panel measures. Reverted in 85328d13.

Two things this panel showed that the next attempts take up:

- Two hold failures, both 114 MHz -> clk_sys crossings: seed 30 a2065
  mailbox csr0_out -> regfile csr_shadow (-0.325; the crossing row 12 keeps
  timed on purpose) and seed 34 ss_ctrl pay_idx -> AmigaCD.sv's ss_dbg_meta
  (-0.289), the first stage of the diagnostics' 2-FF synchroniser, which is
  not constrained as one.
- L's worst path of the panel, seed 35, -2.960: ss_ctrl's shadow_rd_addr ->
  the shadow register file -> shadow_rd_data -> sh_low / crc_shift, a
  combinational round trip out of ss_ctrl and back in one clk_114 cycle. The
  same round trip was seed 32's L worst on the 0a8fe3b7 panel (-0.488).

### Shadow readback multicycle and the diagnostics synchroniser (d6f02c61) -- kept

Run 39192993535. Both exceptions matched: the fit log's only 332174 warnings
are the four of every run (AmigaCD.sdc 167 and 169, z3sdr_* and sdram_dual*,
from upstream 26eb46a; synthesis folds those registers, so the false paths have
nothing to attach to). No shadow_rd_addr path is left in L.

| family | c496d5b1 | 2b894af6 (same RTL) | + rows 18, 19 |
|---|---|---|---|
| L.ss_ctrl_internal | -0.285 (19/20), worst -1.083 | -0.316 (18/20), worst -2.960 | **-0.159 (14/20), worst -0.696** |
| D sdram data into the CPU | 0.000 (10/20) | -0.260 (15/20) | -0.255 (20/20) |
| F.ddram_cache | +0.135 (4/20) | +0.099 (8/20) | -0.005 (10/20) |
| G ddram data into the CPU | +0.062 (7/20) | -0.192 (17/20) | -0.211 (15/20) |
| H.ddram_ctrl | -0.052 (11/20) | -0.055 (11/20) | -0.105 (14/20) |
| M.ascal | -0.063 (16/20) | -0.110 (14/20) | -0.198 (16/20) |
| all_setup median | -0.355 | -0.393 | -0.519 |
| hold failures | 0 | 2 | 0 |

Kept, against the median. The rule exists to stop a placement re-roll being
read as a gain; here the change is two timing exceptions that state checked
facts, so keeping them cannot make the hardware worse, and removing them
would put false violations back in the gate. Their own family improved on
all three measures against both baselines. D, G and M, which they do not
reach, moved by the amounts rows 16 and 17 showed on unchanged RTL. Best
seed 37 at -0.075.

D (20/20) and G (15/20) -- the cache's data into TG68K -- are now the widest
walls.

### Where each family stands after row 19

What is left, and why each is or is not worth another attempt within the
rules (cycle-exact, nothing upstream changed):

- **D, G -- cache data into TG68K (20/20, 15/20).** A true single-cycle path:
  the cache loads cpu_dat_r on the edge it raises cpu_ack, cpu_ack is ramready,
  ramready opens the CPU's clock enable, and TG68K consumes the word on the
  next edge. The data cannot arrive earlier (the tag and data RAMs answer in
  READ), so no exception applies -- unlike the CPU -> RAM direction, which the
  SDC's first lines make multicycle. cpu_wrapper's own mux in front is two
  levels; the other 10-25 are inside TG68KdotC_Kernel, which is upstream. The
  only lever left is row 6's registered return (cpu_rdq). Row 6 was judged on a
  single panel before the noise line was measured (D/G better, C/F/H/L worse,
  median -0.524 -> -0.661).
  [Corrected 2026-10-19: an earlier version of this note said cpu_rdq costs a
  clk_114 cycle on every RAM read. It does not. It is a lookahead register --
  each port hands over the value its return registers take at the next clock
  -- and on every clk_sys edge, the only edges the CPU samples, it equals the
  mux it replaces, which its bench checks. It changes no CPU-visible timing.]
- **M -- ascal (16/20).** sys/ascal.vhd, the framework's scaler. Not ours to
  change; row 3 (disabling the adaptive filter) is the only lever and was
  rejected as a feature loss.
- **L -- ss_ctrl (14/20, -0.159).** After rows 14, 16 and 18 its paths are
  diffuse: the scan timeout counter into load_busy, the state register's own
  decode, shadow-free CLUT reads. No cone dominates.
- **H -- ddram_ctrl (14/20, -0.105).** Also diffuse: the request select chain
  into the speculative ram_addr register (wq_n, stg_v, sdr_read_req,
  dma_read_ack all appear), sp_n -> sp_conf_r, the tag RAM into cpu_dat_r.
  Each appears on one or two seeds.
- **F, C, B, K, N, E, A, P** median positive.

### Stopped here (2026-10-19)

The owner chose to stop after row 19. Row 6's registered RAM return (the only
lever left on D/G) was offered for a re-run under the noise-line rules and
first declined on the strength of that wrong cost note (corrected above); the
owner then asked for it anyway, which is row 20.

The one closing build since the 10-17 sync is seed 35 of c496d5b1's panel
(run 39175622637, setup +0.051, hold +0.234), the `core` artifact
AmigaCD_20261019.rbf. Its RTL is the current RTL: everything after c496d5b1
is either reverted or SDC/bench only (d6f02c61), so that bitstream is the
present design without rows 18 and 19's timing exceptions, which only change
what STA reports.

Copied into `releases/AmigaCD_20261019.rbf` (sha256 fe70569f904e8bdf28211aab3fa262e1835194a4e5dd6473bd7cb8f791cc5e8b),
since the CI artifact expires on 2026-11-02. Its fit.json reports all_setup
-0.101: the family report takes the minimum over every corner (the slow -40 C
one here), while the gate is the slow 100 C corner only, where it is +0.051.
Not yet run on hardware.

### cpu_rdq again (ad8aa2a7, row 20) -- reverted

Run 39335315169, seeds 21-38, 41, 42, against d6f02c61's panel (run
39192993535) on the same list:

| family | d6f02c61 | + cpu_rdq |
|---|---|---|
| D / S (sdram data into the CPU) | -0.255 (20/20) | S +0.101 (6/20) |
| G ddram data into the CPU | -0.211 (15/20) | +1.139 (0/20) |
| C.sdram_cache | +0.510 | -0.129 (12/20) |
| F.ddram_cache | -0.005 | -0.399 (20/20) |
| H.ddram_ctrl | -0.105 | -0.596 (20/20) |
| L.ss_ctrl_internal | -0.159 | -0.323 (19/20) |
| M.ascal | -0.198 | -0.127 (12/20) |
| all_setup median | -0.519 | **-0.728** |

0/20 close; best seed 35 at -0.366. This is row 6's panel again, nearly
family for family: the CPU input wall goes, and C, F and H -- the caches'
output cones, which now also feed cpu_rdq's D input, and the DDR3 controller
beside them -- each lose more than the 0.3 ns noise line. The median is worse
by 0.21. Reverted in cf8f795c. Two fits of the
same idea on two netlists agree, so this is not placement luck: do not try the
registered RAM return a third time without a change that also takes load off
the cache outputs.

### Registered shadow readback (89e08f32, row 21) -- kept on the owner's call

Run 39341492928 on 9bd03194 (row 20 reverted, with the 68030-no-MMU save
state change, which is small and on the CPU side), seeds 21-38, 41, 42,
against d6f02c61's panel:

| family | d6f02c61 | row 21 |
|---|---|---|
| L.ss_ctrl_internal | -0.159 (14/20) | -0.275 (17/20) |
| D sdram data into the CPU | -0.255 (20/20) | -0.243 (18/20) |
| G ddram data into the CPU | -0.211 (15/20) | -0.279 (16/20) |
| H.ddram_ctrl | -0.105 (14/20) | -0.292 (17/20) |
| F.ddram_cache | -0.005 (10/20) | -0.147 (13/20) |
| C.sdram_cache | +0.510 | +0.131 (6/20) |
| M.ascal | -0.198 (16/20) | -0.047 (11/20) |
| all_setup median | -0.519 | -0.582 |

0/20 close; best seed 31 at -0.290. Every move is inside the 0.3 ns noise
line, L's included, so by the rule this is "no change" and would be
reverted. Kept because it replaces row 18's multicycle with registers: the
readback no longer depends on a timing exception being right, and the
equivalence is a bench (rtl/sim/regshadow, falsified four ways) rather than
an argument in the SDC.

### 40-seed sweep on c8103f94 (item 1) -- no seed closes; row 22's baseline

Run 39375965435: the netlist with the 68030 MMU save state (format 1.5), row
21 kept and the dead MAX_FANOUT lines removed, seeds 21-38, 41-62. No seed
closes. Nearest: seed 47 at -0.009 (hold +0.155) and seed 61 at -0.072;
then 31 (-0.226), 33 (-0.269), 56 (-0.308). Seeds 24 and 55 also failed hold
(-0.559, -0.435), the first hold failures since row 19.

| family | median | worst | seeds < 0 (of 40) |
|---|---|---|---|
| D sdram data into the CPU | -0.344 | -1.422 | 38 |
| G ddram data into the CPU | -0.363 | -1.615 | 37 |
| H.ddram_ctrl | -0.275 | -0.784 | 37 |
| F.ddram_cache | -0.206 | -0.501 | 30 |
| L.ss_ctrl_internal | -0.225 | -0.763 | 30 |
| M.ascal | -0.025 | -0.502 | 22 |
| C.sdram_cache | +0.348 | -0.362 | 4 |
| all_setup | -0.518 | -1.615 | 40 |

On the fixed panel list alone (seeds 21-38, 41, 42) the all_setup median is
-0.556, 0/20 close: the figure row 22 is judged against. D and G are the
CPU input wall again and the target of row 22. No QSF seed was set from this
sweep, since row 22 changes the netlist.

### Read gate and fast cache hits (d7823233, row 22) -- reverted

Run 39383054413, seeds 21-38, 41, 42, against the same seeds of the c8103f94
sweep (run 39375965435):

| family | c8103f94 | row 22 |
|---|---|---|
| D sdram data into the CPU | -0.344 | -0.310 (16/20) |
| G ddram data into the CPU | -0.363 | -0.233 (18/20) |
| C.sdram_cache | +0.348 | -0.335 (19/20) |
| F.ddram_cache | -0.206 | -0.520 (20/20) |
| H.ddram_ctrl | -0.275 | -0.605 (20/20) |
| L.ss_ctrl_internal | -0.225 | -0.448 (20/20) |
| M.ascal | -0.025 | -0.345 (17/20) |
| all_setup median | -0.556 | **-0.877** |

0/20 close; best seed 23 at -0.450; seed 22 failed hold (-0.387). Reverted
in the commit after this section's: every RTL, SDC and CI file is
byte-identical to c8103f94 again.

[Corrected 2026-10-20, from the artifacts: the multicycle DID apply -- no new
332174 warnings, and on row 22's seed 34 the cpu_dat_r launches are gone from
D/G, leaving only cpu_ack / cpu_ack_l paths at -0.015 / -0.009. On c8103f94,
109 of the 120 worst D/G paths start at cpu_dat_r. So the gate worked; the
panel was lost to the fast hit's cost in C, F, H and to placement, and with
D/G set aside every c8103f94 seed is still 0.34-0.54 ns short in some other
family. The paragraph below is the guess this replaces.]

Two things went wrong. D and G hardly improved, which says the multicycle
took little of them: what remains of D and G on this netlist was not the
cpu_dat_r launches it names -- most likely the ack -> ready -> TG68K clock
enable paths, which stayed single-cycle by design -- and that was not
checked before building it (the family report puts every ram1/ram2 cache
register into D/G, not only the data). And the fast hit put the tag compare
into IDLE's next-state and cpu_dat_r's load enable, the same cache output
cones cpu_rdq loaded (rows 6, 20), and C, F and H paid as they did then.

Before trying the CPU input path again: split D and G by launch register
(cpu_dat_r vs cpu_ack vs the rest) on a fit's family_paths report, so the
change is aimed at what actually fails. The bench (rtl/sim/rdgate) and the
module are in d7823233 for reuse.

### Item 1 closed: SEED 47

The netlist is c8103f94's again, so its 40-seed sweep stands: no seed
closes, and seed 47 is the nearest at setup -0.009, hold +0.155. AmigaCD.qsf's
SEED goes from 56 (-0.308 on this netlist) to 47. A local build with it
misses timing by 9 ps at the slow 100 C corner -- not a closing build.
releases/AmigaCD_20261019.rbf (seed 35 of c496d5b1, +0.051) remains the only
closing bitstream; it predates the 68030 save states.

### 85 C measurement (policy, not a design change) -- not adopted

Run 39394305042: c8103f94's netlist with `MAX_CORE_JUNCTION_TEMP 85` instead
of the device's 100 (1093bb7d, reverted straight after), seeds 21-38, 41, 42,
against the same seeds at 100 C in run 39375965435:

| | 100 C | 85 C |
|---|---|---|
| all_setup median | -0.556 | -0.402 |
| best seed | 31, -0.226 | 21, -0.130 |
| close | 0/20 | 0/20 |
| D / G (CPU input) | -0.344 / -0.363 | -0.164 / -0.324 |
| H.ddram_ctrl | -0.275 | -0.273 |
| L.ss_ctrl_internal | -0.225 | -0.155 |

The cooler corner buys about 0.15 ns of median (the fit also re-places, so
family figures mix both effects), and no seed closes with it either. With
seed 47 at -0.009 on the 100 C sweep, an 85 C bar would very likely pass
that seed -- but adopting it means signing off on a junction never above
85 C on every board, which is the owner's call, and on its own it does not
make the design close. Left at 100 C.

### Five save-state retiming banks removed (b80fca71, row 23) -- kept

Run 39417638838, seeds 21-38, 41, 42, against the same seeds of the
c8103f94 sweep:

| family | c8103f94 | row 23 |
|---|---|---|
| D sdram data into the CPU | -0.344 (38/40) | -0.344 (19/20) |
| G ddram data into the CPU | -0.363 | -0.405 (18/20) |
| H.ddram_ctrl | -0.275 | -0.177 (17/20) |
| F.ddram_cache | -0.206 | -0.100 (15/20) |
| L.ss_ctrl_internal | -0.225 | -0.054 (11/20) |
| M.ascal | -0.025 | -0.017 (10/20) |
| C.sdram_cache | +0.348 | +0.379 (2/20) |
| all_setup median | -0.556 | **-0.496** |

0/20 close; best seed 27 at -0.039, then 22 (-0.185) and 41 (-0.259). No
hold failures (worst +0.115), so the existing false paths do cover the
crossings the banks used to re-time; the only 332174 warnings are the two
pre-existing ones. Seed 27's fit: 48,441 registers (was 52,321) but
34,913 ALMs (was 35,075, 83%) -- the flops were packed into ALMs that also
carry logic, so the logic footprint barely moved. Removing registers is not
the area lever this design needs; ALM-level logic is.

Kept by the rule (median and H, L, F better, nothing clearly worse), with
the caveat that each shift is inside the 0.3 ns placement noise. D and G
are the wall again and untouched: row 22's gate is the proven fix for them,
and its fast-hit half is what has to change.

### The read gate, two ways (rows 24 and 25) -- both reverted

Runs 39444091321 (row 24, 04926004) and 39445766384 (row 25, 406e0a62),
seeds 21-38, 41, 42, against row 23 (run 39417638838). Medians are over the
gate's per-seed setup figures.

| | row 23 | row 24: gate only | row 25: gate + lean fast hit |
|---|---|---|---|
| median | -0.496 | -0.493 | -0.764 |
| close | 0/20 | 0/20 | 0/20 |
| best seed | 27, -0.039 | 38, -0.200 | 36, -0.236 |
| D (sdram data into CPU) | -0.344 (19/20) | -0.100 (14/20) | -0.574 (19/20) |
| G (ddram data into CPU) | -0.405 (18/20) | -0.026 (11/20) | -0.637 (19/20) |
| C.sdram_cache | +0.379 | +0.100 | +0.176 |
| F.ddram_cache | -0.100 | -0.087 | -0.058 |
| H.ddram_ctrl | -0.177 | -0.209 | -0.265 |
| L.ss_ctrl_internal | -0.054 | -0.096 | -0.231 |
| TG68K reads a clk_sys later | -- | 44% (every hit) | ~9.5% |

Row 24 does what it was built for -- D and G move by +0.24 and +0.38 ns --
and the median does not move: with the CPU input wall down, each seed is held
by H, L, F or M at about the same depth, as the D/G split predicted. Row 25's
fast hit, even lean, puts D and G back behind where they started, so the
early ack itself (tag compare -> ack -> the CPU's clock enable) is on the
critical path, not only the loads row 22 gated. Neither closes a seed.

Both reverted on the owner's call (2026-10-20): every RTL, SDC, QSF and CI
file is byte-identical to row 23 (f8a30137) again. The gate (cpu_rdgate) and
its bench stay in 04926004 / 406e0a62 for reuse; it is the proven fix for
D and G, and worth bringing back only once the families behind them (H, L,
F, M) have moved, since on its own it buys D and G but not a closing seed.
