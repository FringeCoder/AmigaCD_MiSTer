# Files in this directory that are copied elsewhere

Ten files here are built in this repository and **copied into
`FringeCoder/AmigaCD`**, the userspace repo, so that its testbenches
(`rtl/tb/*_tb.v` there) can compile against them. This repository owns them;
that one holds a stamped copy.

    rtl/snac_cd32.v        rtl/ss_dma.v           rtl/ss_regshadow.v
    rtl/ss_crc32.v         rtl/ss_freeze_phase.v  rtl/ss_serdes.v
    rtl/ss_ctrl.v          rtl/ss_quiesce.v       rtl/ss_state.vh
                                                  rtl/ss_state_fanout.sv

**Change one of these and the copy needs refreshing**, in the userspace repo:

```sh
./core_rtl_vendor_check.sh --stamp /path/to/this-checkout
```

then run its `rtl-sim` benches. Its CI fails at the stamp until you do, which is
the point — but it fails *there*, on the next push to that repository, not here,
so nothing stops you forgetting except this note.

## Why it matters, with the receipt

It had already gone wrong. Between `8cc3660` (register the DDR3 read return) and
`fb47b76` (drop the redundant `ss_rom_scan` term) this repository's `ss_ctrl.v`
moved twice and the copy did not. Both repositories' CI stayed green for the
whole window. `ss_ctrl_tb.v` — which `rtl/ss_ctrl.v:112` cites by name as the
proof that the `rom_scan` term is redundant — was running against a module this
repository had stopped building, so the citation was true of a file nobody
compiled.

Caught on 2026-09-15 by diffing the two trees, not by any check. That is the
whole argument for the stamp: nothing was going to surface it.

## The other direction

`rtl/snac_psx.v` goes the opposite way: `FringeCoder/AmigaCD` owns it and this
repository holds the copy, stamped in `rtl/snac_psx.vendor` and checked by
`./snac_vendor_check.sh` in CI. It is a device protocol shared by two cores and
belongs to neither.

So: **`snac_psx.v` in, everything in the list above out.** `rtl/README.md` in
the userspace repo has the same table from the other side.
