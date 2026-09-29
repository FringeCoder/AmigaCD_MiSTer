# Testbench conventions

Every rule here exists because breaking it cost this project time. Nothing is
here on general principle.

## Wait for an event, not for a number of cycles

A bench that waits a fixed number of cycles for something to happen encodes a
magnitude of the design into the test. When that magnitude changes, the bench
fails for a reason that has nothing to do with what it checks.

Four benches in this directory had windows sized for a 105 ns post-write DMA
inhibit. When the inhibit was corrected to scanline rate -- 192 µs, because
WinUAE decrements that counter once per hsync and the port had been decrementing
it once per clock -- all four broke at once:

| bench | what it was |
|---|---|
| `tb_akiko_pbx_dma` | `wait_rx_done(2000, …)` in test F |
| `tb_akiko_txrx_dma` | a fixed `repeat (40)` waiting for four bytes |
| `tb_akiko_tx_write_race` | write landing 120 cycles after the announcement |
| `tb_akiko_cmd_phantom` | condition waits capped at 3000 and 6000 |

So:

* **For something that should happen**, loop on the condition with a cap chosen
  to be absurdly generous, and print how long it took. The printed figure is what
  lets the next person see the margin instead of guessing it. `tb_akiko_txrx_dma`
  reports `D.measured: dma_req 5 cycles after the $1D write`, which is how the
  vacuous floor below was spotted.
* **Never** `repeat (N)` for an event.
* **For something that should NOT happen**, a fixed window is the only option --
  you cannot wait for a non-event. The window must then outlast *every legitimate
  reason* for the non-event, or the bench passes for the wrong one. Tests E and F
  of `tb_akiko_txrx_dma` assert that TX does not start while `ENABLE` or
  `receive_length` hold it off; at 60 cycles against a scanline-rate inhibit the
  TX would not have started anyway, and the tests would have been claiming the
  gate held when nothing had been tried.

## A threshold must sit above the noise it is distinguishing from

`tb_akiko_txrx_dma` test D claimed to verify the post-write inhibit and asserted
nothing. The TX engine's own latency from the `$1D` write to `dma_req` is 2
cycles and the three-tick inhibit made it 5; the test failed only *below 2*,
which 2 does not trip. Deleting the inhibit from `akiko.v` outright left all 48
checks green.

Measure the mechanism off and on, then put the threshold between them with slack
both sides, and say so in a comment with both numbers.

## Re-run the mutations after widening anything

`rtl/sim/run-mutations.py` breaks one thing each bench claims to catch and
requires the bench to go red *by the check that claims it*. Widening a window or
relaxing a threshold is routine, and every such edit is a chance to make a check
vacuous — so the harness exists to be re-run, not admired. Add an entry whenever
a bench is written to guard a specific mechanism.

It checks the failing check's name, not just that something failed: a bench can
collapse for the wrong reason and still look like it is working.

## Icarus will not tell you the bench is wrong

Three behaviours, all of which have cost days here:

* **An omitted port is `z`, not an error.** `tb_akiko_txrx_dma` failed 36 of its
  48 checks for months because its `akiko` instance predated `dma_arm`; with that
  input floating no engine was ever claimed and every transfer stalled after one
  byte.
* **A width mismatch is padded with a warning.** `tb_ss_regbus_mux` was red
  across four PRs from an 8-bit signal on a 9-bit port, which put the window it
  tested out of reach. `rtl/sim/check-icarus-warnings.sh` now fails a compile that
  pads; route new benches through it.
* **`$finish(1)` does not set the exit status.** `vvp` returns 0 with any number
  of failures. The CI gate must be `grep -q "… PASS"` on the output, which is why
  every bench prints a PASS line.

## A bench nobody runs reads as coverage

`rtl/sim/check-benches-wired.py` fails when a `tb_*.sv` is neither named in a
workflow nor covered by a runner the workflow calls. Five benches are allowlisted
there as genuinely un-buildable by Icarus, each with the construct that stops it
and the `.do` that runs it. Add to that list only for a construct, never because
a bench fails.
