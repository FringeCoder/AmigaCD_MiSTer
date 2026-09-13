# AGENTS.md

Guidance for agents working on the AmigaCD core — a Minimig-AGA_MiSTer fork with
native CD32/CDTV and Akiko. `CLAUDE.md` is a symlink to this file.

Read `docs/core-accuracy-todo.md` before proposing chipset work. It is the live
list, it is ranked, and every item cites a file and line or an upstream commit.

## The one rule that matters most

**There is no reference Amiga here.** Nothing on the accuracy list may be
justified by behaviour alone. Every claim needs a file and line, an upstream
commit, a simulation, or a published reference value — and an item with no
verification route says so and is ranked accordingly.

The four routes, and the vocabulary the TODO uses:

- **SIM** — an Icarus bench in `rtl/sim/`, run in CI. The primary instrument and
  the one that actually catches things.
- **SUITE** — a test program run on the core, scored against the suite's own
  published reference values. vAmigaTS, and since 2026-09-13 Copperline's probe
  suite over the serial link (`docs/copperline-verification.md`,
  `./copperline_probes.sh`).
- **TITLE** — regression observation against known-good software. Flink,
  Castlevania AGA, Cannon Fodder, Jim Power, save/restore, physical disc.
- **FIT** — Quartus slacks. **Both edges, always.** A hold violation fails at
  every clock frequency.

## Things that will bite you

**The CIA CNT revert is permanent.** Upstream `b013ce3` added the Timer A/B
INMODE count-source selects but not the wiring — `minimig.v` drives both CIAs
with `.cnt_in(1'b1)`, so `cnt_rise` never pulses and selecting a CNT source
stops the timer dead. It broke Flink. It has been reverted twice, and forgotten
once between two syncs five days apart. CI guards it. **Do not delete that step
to get a green build**; it means a merge re-applied `b013ce3`.

**Fits are seed-dependent and margins are thin.** The design has been shipped on
+0.117 ns of setup, found by a sweep in which another seed was rejected at
−0.495 hold. `seed_sweep_both.sh` requires *both* slacks positive; the older
scripts delegate to it because they once ranked on setup alone and would have
called a negative-hold netlist good. Every HOT item needs its own fit before it
can be believed, and `refit_one.sh` exits non-zero when either slack is negative.
Do not rank work by how much slack it buys — `docs/core-accuracy-todo.md:33`
(T0) records why that framing was wrong.

**Area is not what this design is short of.** 70% ALMs, 50% BRAM, 62% DSP. Do
not propose anything on the basis that MiSTer has a bigger FPGA.

**`rtl/sim/chipset` is ModelSim-only** and is deliberately outside CI. It is a
known holdout (T3), not an oversight to fix in passing.

**`rtl/snac_psx.v` is copied into core repositories.** Changing it here means
re-vendoring. CI stamps its hash to force the question; see
`docs/snac-psx-vendoring.md`.

## Working here

```sh
bash syntax_check.sh           # parse every synthesisable source, seconds
```

Run it before proposing anything. Most of `rtl/` and all of `Minimig.sv` is
otherwise parsed by nothing until Quartus, 18 seconds into a 35-minute fit.

Benches live in `rtl/sim/<area>/`, compile with `iverilog -g2012`, and print
`RUN: PASS` on success — CI greps for exactly that. To add one, copy the shape
of an existing bench and add a step to `.github/workflows/rtl-sim.yml` with a
comment saying **why it exists and what it would catch**, which every step there
has.

**Falsify a bench before trusting it.** Mutate the DUT so the behaviour is
wrong, and confirm the bench fails on the check that names it. A bench that has
never failed has not been shown to test anything. Where coverage has been
falsified, say so and say which checks — see the SNAC step's comment and the
table in `docs/snac-psx-vendoring.md` for the form.

## Conventions

- Commit subjects are lowercase, scoped where there is an obvious scope
  (`agnus:`, `paula:`, `perf(sdram):`, `ci:`, `docs:`, `quartus:`). The body
  explains why, and records what was ruled out.
- Document a decision where it will be looked for, not only in the commit. The
  TODO items carry their own "ruled out" lists for this reason.
- Never commit ROMs, disk images or Kickstarts. `build/` is gitignored and is
  where fetched third-party trees land.
- Reverts that are permanent get a CI control, not a note. "Remember to check"
  is not a control.
