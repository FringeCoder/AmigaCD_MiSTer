#!/usr/bin/env python3
"""Refuse a testbench that nothing runs.

Seven of thirty-three benches in this repository were unreferenced by CI on
2026-09-29, and two of them had been broken for months without anyone noticing:

  * tb_akiko_txrx_dma failed 36 of its 48 checks. Its akiko instance predated
    dma_arm, and an omitted input in Verilog is z rather than an error, so every
    transfer stalled after one byte. Nothing ran it, so nothing said so.
  * tb_ss_regbus_mux had been red since PR #22 -- an 8-bit signal against a
    9-bit port, which Icarus pads with a warning -- and was fixed in PR #26. It
    is STILL unreferenced by the workflow, so it is free to rot again.

A bench nobody runs is worse than no bench: it reads as coverage. This gate
fails when a tb_*.sv is neither named in a workflow nor covered by a runner
script, unless it is listed in the allowlist below with a reason.

Run from the repository root.
"""
import glob
import os
import re
import sys

# Benches Icarus genuinely cannot build, with the construct that stops it. These
# are ModelSim/Questa benches and are run by hand from their .do files; they are
# NOT covered by CI and this file is the record of that.
#
# To clear an entry: port the construct, wire the bench into rtl-sim.yml, and
# delete the line. Do not add an entry to silence a bench that merely fails.
ICARUS_CANNOT_BUILD = {
    'tb_akiko_regs.sv':
        'SystemVerilog explicit variable lifetime ("automatic"/"static" on a '
        'declaration inside a task); Icarus 12 answers "sorry: overriding the '
        'default variable lifetime is not yet supported". Run: rtl/sim/akiko/run.do',
    'tb_akiko_chipram_master.sv':
        'Same explicit-lifetime construct, three sites. Also leaves '
        'cpu_chip_slot_req and chip_in_rd_dma unconnected, so it needs work '
        'beyond the port. Run: rtl/sim/akiko/run_chipram.do',
    'tb_akiko_nvram.sv':
        'Assigns a whole array without a word index, which Icarus rejects as '
        '"Cannot assign to array". Run: rtl/sim/akiko/run_nvram.do',
    'tb_akiko_hps_bridge.sv':
        'Questa bench for the HPS bridge; fails 40 of 55 checks under Icarus '
        'from the same lifetime construct. Run: rtl/sim/akiko/run_bridge.do',
}


def workflow_text():
    parts = []
    for p in (glob.glob(os.path.join('.github', 'workflows', '*.yml')) +
              glob.glob(os.path.join('.github', 'workflows', '*.yaml'))):
        with open(p, encoding='utf-8') as fh:
            parts.append(fh.read())
    return '\n'.join(parts)


def runner_text():
    """Runner scripts a workflow may invoke instead of naming the bench."""
    parts = []
    for pat in ('rtl/sim/*/run*.sh', 'rtl/sim/*/*.do'):
        for p in glob.glob(pat):
            with open(p, encoding='utf-8', errors='ignore') as fh:
                parts.append((p, fh.read()))
    return parts


def main():
    benches = sorted(glob.glob(os.path.join('rtl', 'sim', '*', 'tb_*.sv')))
    if not benches:
        print('no benches found -- run this from the repository root')
        return 1

    wf = workflow_text()
    runners = runner_text()
    if not wf:
        print('no workflow files found -- run this from the repository root')
        return 1

    unwired, allowed, stale_allow = [], [], []

    for path in benches:
        name = os.path.basename(path)
        in_wf = name in wf
        # A runner counts only if the workflow calls THAT script. Matching on
        # basename would be wrong: there are two run.sh files, so a bench under
        # tg68k/ could be credited because ssmux/run.sh happens to be called.
        via_runner = any(name in body and rp.replace(os.sep, '/') in wf
                         for rp, body in runners)

        if in_wf or via_runner:
            if name in ICARUS_CANNOT_BUILD:
                stale_allow.append(name)
            continue

        if name in ICARUS_CANNOT_BUILD:
            allowed.append(name)
        else:
            unwired.append(path)

    for name in allowed:
        print('allowed  %-32s %s' % (name, ICARUS_CANNOT_BUILD[name].split(';')[0]))

    rc = 0

    if stale_allow:
        print()
        print('These are wired into CI AND listed in ICARUS_CANNOT_BUILD:')
        for n in stale_allow:
            print('    - %s' % n)
        print('Remove them from the allowlist -- a stale entry hides the next')
        print('bench that really cannot build.')
        rc = 1

    if unwired:
        print()
        print('These benches exist and nothing runs them:')
        for p in unwired:
            print('    - %s' % p)
        print()
        print('Wire each into .github/workflows/rtl-sim.yml, or into a runner')
        print('script the workflow calls. If Icarus genuinely cannot build one,')
        print('add it to ICARUS_CANNOT_BUILD in this file with the construct that')
        print('stops it -- not merely because it fails.')
        rc = 1

    if rc == 0:
        print()
        print('%d bench(es): %d wired, %d allowlisted as Icarus-incompatible'
              % (len(benches), len(benches) - len(allowed), len(allowed)))
    return rc


if __name__ == '__main__':
    sys.exit(main())
