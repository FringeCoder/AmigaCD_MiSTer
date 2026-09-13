# Copperline as a verification instrument

Written 2026-09-13. Everything below was run, not read about; where a claim is
someone else's it says whose, and where something is unexplained it says so.

[Copperline](https://github.com/CopperlineHQ/Copperline) is a cycle-driven Amiga
emulator in Rust, GPL-3.0-or-later — the same licence this core carries, so
nothing here raises a licence question. This document is about what it can do
for *this* core. The short version: it cannot contribute a line of RTL, but it
ships a 68k probe suite, a serial probe server, and 22 rows of timing measured
on real A1200 silicon, and `docs/core-accuracy-todo.md:12` opens with "How we
verify, given no reference Amiga".

Pinned revision: `0565bcca` (2026-09-13). `copperline_probes.sh` fetches exactly
that. Bump it deliberately and re-read the caveats below when you do.

## What is not usable

Copperline is Rust; this is Verilog synthesised by Quartus. There is no
translation path and no code to port. Two things *are* worth reading rather than
running:

- `src/akiko.rs`, `src/cdtv.rs`, `src/cd32_fmv.rs`, `src/cdrom.rs` and
  `src/cdrom/` — a second opinion on exactly the chips this fork is making
  native, covering ground `rtl/sim/akiko/akiko_legacy_ref.v` does not (it is a
  register-decode reference, not a CD subsystem). Note that
  `docs/internals/chipset.md` gives Agnus/Denise/Paula/Copper/Blitter systematic
  treatment but says nothing systematic about Akiko, CD32 or CDTV — the code
  exists, the documentation does not, so this means reading Rust.
- `HARDWARE-RIG-PLAN.md` — their plan for measuring against real silicon,
  written from the same position we are in ("a reference that is not another
  emulator"). Worth reading before we spend anything on a rig of our own.

## The instrument: a serial probe server  [SUITE]

This is the part that changes how we work, and it does not depend on any of the
reference numbers below being resolved.

`timing-test/probesrv.asm` is a resident serial-driven loader. Boot it once and
it relocates to `$70000` and serves the serial port forever on a line-oriented
ASCII protocol:

    -> ID                       <- BANNER ...
    -> PING                     <- READY
    -> LOAD <addr> <len> <crc>  <- LOADRDY, raw bytes, LOADOK|LOADERR
    -> RUN <addr>               <- BEGIN, then whatever the probe emits

The host side is `tools/hwrig/hwrig.py`, and it already speaks a UART as well as
TCP:

    hwrig.py --tcp  127.0.0.1:1234 run timing-test/test.bin   # an emulator
    hwrig.py --port /dev/ttyUSB0   run timing-test/test.bin   # a real machine

**This core is the second case.** `README.md` lists serial connection to Linux.
So: boot `probesrv.adf` on the MiSTer once, point `hwrig.py` at the serial
device at 19200 baud, and upload any of the ~50 committed probe binaries. Results
come back as ASCII hex in seconds — no SD-card round trip, no photographing a
CRT, no human reading digits. `--repeat N` samples a distribution.

That is what SUITE was always supposed to be, and it makes T7 (`:339`) —
"a measurement, not a change", ranked fifth and gating T9/T11/T12 — a scripted
job rather than a sitting.

Build the disks with `./copperline_probes.sh`. **vasm is not required**:
Copperline commits the assembled `.bin` for every probe and `make_adf.py` wraps
one into a bootable ADF with nothing but python3. vasm is only needed to modify
a probe's source.

Two things from the probe server's own header worth not rediscovering:

- It hands probes **unprivileged mode at IPL 0**, deliberately. An early version
  took supervisor mode at IPL 7 for its own convenience and `test.bin` rows
  19/20 silently read `0000` instead of `003D`/`0147`, because no interrupt can
  reach a CPU masked at level 7.
- `$70000-$7FFFF` is reserved. A probe that writes there destroys the server and
  the recovery is a hardware reset. That is expected, not exceptional.

## The reference columns

`timing-test/compare-a1200.py` carries two reference columns for the 32-row
timing probe. `REAL` is the one we cannot produce ourselves: a stock A1200
(68EC020 at 14.19 MHz, AGA, 2 MB chip, KS 3.2.3) booted the disk from floppy on
2026-08-01 and its on-screen table was read from CRT photos across two runs.
Their stated rule is that where real hardware and FS-UAE disagree, hardware
wins.

The `CL` column below is our own run, on Copperline's A1200 shape with the
bundled AROS ROM. Rows 0, 1, 9 and 13 probe slow RAM at `$C00000`; on a machine
without it the probe stores a `00000000` sentinel, so those four carry no
information and are excluded from every count in this document.

| row | probe | CL (AROS) | real A1200 | FS-UAE | Δ vs hw |
|----:|-------|-----------|------------|--------|---------|
|   2 | chipR        | `000019BB` | `000019BC` | `000019BB` | −1 |
|   3 | chipW        | `00000CE0` | — | `000011A2` | |
|   4 | move         | `00000E6A` | `00000E6A` | `00001004` | **0** |
|   5 | shift        | `0000119D` | `0000119D` | `00001337` | **0** |
|   6 | mul          | `00003804` | — | `00003803` | |
|   7 | dbra         | `00000B37` | `00000B38` | `00000CD0` | −1 |
|   8 | frame        | `00003782` | — | `0000377D` | |
|  10 | cw1024       | `0000019F` | `0000019F` | `00000237` | **0** |
|  11 | cw/6bpl      | `00000285` | `00000284` | `000002DD` | +1 |
|  12 | cw/8spr      | `000001A0` | `000001A0` | `0000023C` | **0** |
|  14 | dbraChip     | `00000B38` | `00000B3A` | `00000CD3` | −2 |
|  15 | cw/6bpl+8spr | `00000285` | `00000284` | `000002DD` | +1 |
|  16 | cw/f         | `00000FFB` | `000011A1` | `000011A6` | **−422** |
|  17 | cw/f+VB      | `00000FF9` | `000011A4` | `000011A4` | **−427** |
|  18 | cw/3bpl      | `000001A0` | `000001A2` | `00000248` | −2 |
|  19 | VBentry      | `0000001F` | — | `00000019` | raw beam |
|  20 | SOFTend      | `00000098` | — | `00000084` | raw beam |
|  21 | cw/chain     | `00000FF1` | `00001196` | `0000119D` | **−421** |
|  22 | VBraise      | `00000010` | — | `0000000D` | raw beam |
|  23 | blitClr      | `00002743` | — | `00002731` | |
|  24 | blitFill     | `000047FD` | — | `0000479D` | |
|  25 | blitLine     | `00000179` | — | `0000017F` | |
|  26 | fill+3bpl    | `00006242` | — | `0000622E` | |
|  27 | copperPoll   | `0000641B` | `0000641B` | `0000641B` | **0** raw beam |
|  28 | pair         | `0000119E` | `0000119F` | `00001338` | −1 |
|  29 | pairRAW      | `00001004` | `00001004` | `00001337` | **0** |
|  30 | dbraBC       | `00000B37` | `00000B36` | `00000CD0` | +1 |
|  31 | div/6bpl     | `0000035A` | `00000378` | `000004D2` | **−30** |

Eighteen rows carry a hardware reading. **Fourteen land within ±2 ticks and six
are exact**, including row 27 — the copper-vs-CPU interrupt phase, which is what
the 020 chase-the-beam effects depend on. FS-UAE is 9-20% out on the
branch-heavy rows (4, 5, 28, 29), which is the taken-branch over-billing
Copperline's README documents and the reason the `REAL` column is worth having
at all.

### Four rows are unresolved — do not calibrate against them

Rows 16, 17, 21 and 31 are outside anything that could be called agreement.
Rows 16/17/21 are all the same ratio (0.906), which is a consistent scaling
rather than phase noise, and they are precisely the per-frame VHPOSR-polling
loops that Copperline's own README says "expose the extra colour clock a CPU
custom-register read costs over a chip-RAM read". Row 31 also misses the figure
Copperline's README claims for itself (`0376`; we measure `035A`).

What was ruled out:

- **Not a settling artifact.** Capturing at 32 s instead of 16 s gives
  byte-identical values.
- **Not a machine mismatch.** Copperline's log line reports
  `cpu=M68EC020 cpu_clock=14.18MHz chip_ram=2048K fast_ram=0K slow_ram=0K
  chipset=Aga video=Pal` — the machine `tt-a1200.toml` describes, exactly.
- **Not our build.** `cargo test --release --test probe_golden
  golden_timing_test` passes here, pixel-for-pixel against Copperline's
  committed reference render.
- **Not boot-insert phase**, as far as we could perturb it: inserting the disk
  at 0.00/0.02/0.05/0.11 s changes nothing, because AROS boots on its own
  schedule regardless.

The one remaining difference is the ROM: their reference run uses KS 3.1
(`tt-a1200.toml` points at `../test-assets/`, which is not committed), ours uses
the bundled AROS. **Anyone with a KS 3.1 image can settle this in one run** —
drop it in `build/copperline/test-assets/` and run `compare-a1200.py` from
`timing-test/`. That is tracked as T23 in `core-accuracy-todo.md`, with the
exact commands and what each outcome would mean. Until then, rows 16, 17, 21
and 31 are not evidence about anything.

Related and separate: Copperline's CI deliberately excludes `timing-test` and
`bltprobe-pace` from pixel-exact golden comparison, because the E-clock and
DMA-cadence phase at bootblock handoff depends on how long the ROM took to boot.
Those are the two probes whose *numbers* we would compare against this core, so
a one-or-two-tick difference is inside the noise floor of the method and is not
a finding. The other 43 probes are pixel-exact and ROM-independent.

## What this does and does not settle

Copperline is another emulator, not silicon. Their hardware rig plan exists
precisely because vAmiga and FS-UAE disagree on AGA and CPU timing. So a
disagreement between this core and Copperline is a strong signal — especially
where Copperline agrees with the `REAL` column — but it is not proof.

Two limits that matter for the open items in `core-accuracy-todo.md`:

- The chipset is modelled at **colour-clock granularity**, with CIA resolved on
  the E-clock grid (one tick per five colour clocks). That is coarser than this
  RTL, and it **will not resolve the 35 ns AGA comparator items** in `TODO`.
- `docs/internals/chipset.md` lists its own residual gaps, and the runtime log
  repeats them: "AGA DDF fine granularity, live collisions on the 6-plane
  decode". Do not treat those areas as a reference.

## Reproducing the emulator side

Only needed if you want to run the probes under Copperline as well as on the
core. The disks themselves need none of this.

    rustup update stable                     # needs rustc >= 1.95
    apt-get install -y libasound2-dev libudev-dev
    cd build/copperline && cargo build --release --bin copperline

Roughly 19 minutes for the binary. Without the two dev packages the build dies
in `alsa-sys`'s build script, not in Copperline. It bundles the open-source AROS
boot ROM and boots with no Kickstart at all; the A1200/A500 configs under
`timing-test/` are the exception, since they name a real ROM in `test-assets/`.

Useful flags, from their `AGENTS.md`:

- `--screenshot-after SECS PATH`, `--dump-frames`, `--gif-after` — all in
  absolute *emulated* seconds, so runs are reproducible byte-for-byte.
- `--expect-screenshot SECS PATH [TOL]` — an assertion: writes
  `<stem>.actual.png` and `<stem>.diff.png` and exits 3 on mismatch.
- `--waveform out.vcd` with `--wave-trigger`/`--wave-duration` — beam, bus, cpu,
  copper, blitter, regs, irq and audio groups as a VCD, which is the obvious
  thing to diff against an Icarus bench from `rtl/sim/`.
- `--control :0 --control-info FILE` — JSON-RPC 2.0 over loopback TCP;
  `copperline-ctl --mcp` exposes it to an MCP client as tools.

Their determinism guarantee is explicit and worth knowing the edge of: enabling
any `COPPERLINE_DBG_*` diagnostic executes the same instructions at the same
colour clocks, "with the exception of `[cpu] jit`, which falls back to precise
timing and logs a warning".
