# snac_psx: the copy in the core repos

`rtl/snac_psx.v` is canonical here. Core repositories take a copy — today that
is Menu_MiSTer, at the same path. This document exists because a shared file
with no control on it is the same shape of problem as the CIA CNT revert (T1):
it works until someone forgets, and the forgetting is silent.

## Why it is copied rather than shared

MiSTer core repositories are self-contained Quartus projects. A core builds from
its own tree, there is no submodule or package step anywhere in the toolchain,
and adding one would be the only thing of its kind in either repository. Copying
is the convention the platform already has. The cost of that convention is drift,
which is what the controls below are for.

## The controls

**In this repository**, `.github/workflows/rtl-sim.yml` has a step
"SNAC module hash is stamped" that checks `rtl/snac_psx.v` against
`rtl/snac_psx.sha256`. Change the module and CI fails until you refresh the
stamp — which is the moment to re-vendor. That is the point of it: the failure
is not the problem, it is the reminder.

**In Menu_MiSTer**, `rtl/snac_psx.vendor` records where the copy came from
(repository, commit, and the canonical file's sha256) and a CI step asserts the
local copy still hashes to that value. That catches the copy being edited in
place, which is the other way the two diverge.

Both are stamps rather than a live cross-repository diff, and the reason is
plain: a CI job in Menu_MiSTer cannot read this repository without a token
configured for it, and a check that silently degrades to "skipped" when the
token is absent is worse than no check. If you do want the live diff, the
upgrade is small — add a second `actions/checkout` with `repository:` and a PAT
in `secrets`, and diff the two paths. `snac_vendor_check.sh` in Menu_MiSTer
already does exactly that comparison locally against a checkout you point it at.

## Changing the module

1. Edit `rtl/snac_psx.v` here and make the bench cover the change:
   `rtl/sim/snac_psx/tb_snac_psx.sv`. Run it —
   at every rate CI runs —

       cd rtl/sim/snac_psx
       for khz in 28375 50000 100000; do
         iverilog -g2012 -P tb_snac_psx.CLK_KHZ=$khz -o tb_snac ../../snac_psx.v tb_snac_psx.sv
         vvp tb_snac
       done

   — and confirm `RUN: PASS` from each. The bench is parameterised because
   every timing constant in the module is an integer division of `CLK_KHZ`,
   and the module's header claims the poll cadence is the same wall-clock
   interval at all of them. 28375 is this core's rate, 100000 is
   Menu_MiSTer's.
2. **Falsify the new coverage.** Mutate the DUT so the behaviour you just added
   is wrong, and confirm the bench fails on the check that names it. A bench
   that has never failed has not been shown to test anything. The three
   mutations used when the bench was written are recorded in the CI step's
   comment.
3. Refresh the stamp: `sha256sum rtl/snac_psx.v > rtl/snac_psx.sha256`.
4. Copy the module and the bench into Menu_MiSTer, update its
   `rtl/snac_psx.vendor` (commit and sha256), and push both repositories.

## What the bench covers

`rtl/sim/snac_psx/tb_snac_psx.sv`, eight checks against a pad model that answers
on the real schedule — ACK arriving ~10 us after a byte's last clock edge and
lasting 2 us, rather than instantly. That timing is the whole reason the bench
is worth having: a model that answers instantly is what the original
free-running reader passed against, and real hardware did not.

| # | Check | Pins |
|---|-------|------|
| 1 | ATT low to first clock edge is ~20 us | the 2 us that fell out of reusing `HALF` |
| 2 | Idle bus reports absent, sticks centred | `0xFF` is not a device ID |
| 3 | Digital pad, five-byte frame, ACK-terminated | `e9999dc` flow control |
| 4 | Port alternation keeps the two ports separate | shared bus, per-port ATT |
| 5 | DualShock `0x73` axes reach `axes0` | |
| 6 | GunCon `0x63` axes reach `axes0` | `797d1c3` |
| 7 | A 20 ns ACK spike is rejected | `fd54527` |
| 8 | Unplugging clears a held button | every `ST_DONE` branch assigns fresh |

Checks 1, 6 and 7 were each confirmed to fail under a matching DUT mutation on
2026-09-13 — check 6 at all three clk rates, checks 1 and 7 at the default.
Checks 2, 3, 4, 5 and 8 have not been falsified individually; treat them as
weaker until they have been. Menu_MiSTer's `docs/state-todo.md` M2 tracks that
debt.
