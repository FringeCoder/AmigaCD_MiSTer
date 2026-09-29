#!/usr/bin/env python3
"""Check that the benches can still fail.

A bench that cannot fail is worse than no bench, and it is not a hypothetical
problem here. tb_akiko_txrx_dma test D claimed to verify the post-write DMA
inhibit and asserted nothing: its floor sat below the TX engine's own two-cycle
latency, so deleting the inhibit from akiko.v outright left all 48 checks green.
It was found by mutating deliberately, not by reading. The same week, a unit test
of the Akiko framing had the same defect for the same reason -- it rejected
unknown opcodes by checksum rather than by the guard under test.

The mechanism that makes this happen is widening a window or relaxing a
threshold, which is routine maintenance: four benches in this suite had windows
sized for a 105 ns inhibit and needed raising when it became 192 us. Every one of
those edits is an opportunity to make a check vacuous.

So each entry below breaks one thing a bench claims to catch, and the bench must
go red. Add an entry whenever a bench is written to guard a specific mechanism,
and re-run this after widening any window.

Run from the repository root:  python3 rtl/sim/run-mutations.py
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

# Source lists mirror the CI steps. Kept here rather than derived from the
# workflow because a mutation run should not silently follow a workflow edit.
AKIKO = 'rtl/akiko.v rtl/akiko_nvram.v rtl/sim/cache/dpram_sim.v'
AKIKO_BR = ('rtl/akiko.v rtl/akiko_nvram.v rtl/akiko_hps_bridge.v '
            'rtl/sim/cache/dpram_sim.v')

# (label, bench, sources, file to mutate, find, replace, expected failing tests)
#
# "expected" is the substring that must appear in a FAIL line. It is there so a
# mutation that makes some OTHER check fail does not count as caught: a bench can
# collapse for the wrong reason and still look like it is doing its job.
MUTATIONS = [
    ('dma_arm ignored, so no engine is ever claimed',
     'rtl/sim/akiko/tb_akiko_txrx_dma.sv', AKIKO,
     'rtl/akiko.v',
     "\t\t\tif (dma_arm) begin", "\t\t\tif (1'b0) begin",
     'A.'),

    ('TX not gated by CDFLAG_ENABLE',
     'rtl/sim/akiko/tb_akiko_txrx_dma.sv', AKIKO,
     'rtl/akiko.v',
     "\t                  && !cdrom_flags[CDFLAG_ENABLE_BIT]",
     "\t                  && 1'b1",
     'E.'),

    ('TX not gated by receive_length',
     'rtl/sim/akiko/tb_akiko_txrx_dma.sv', AKIKO,
     'rtl/akiko.v',
     "\t                  && (cdrom_receive_length == 6'd0)",
     "\t                  && 1'b1",
     'F.'),

    ('no post-write TX inhibit -- the one that used to slip through',
     'rtl/sim/akiko/tb_akiko_txrx_dma.sv', AKIKO,
     'rtl/akiko.v',
     "\t\t\t\t\t\ttx_dma_delay <= 2'd3;", "\t\t\t\t\t\ttx_dma_delay <= 2'd0;",
     'D.'),

    ('RX writes the wrong byte',
     'rtl/sim/akiko/tb_akiko_txrx_dma.sv', AKIKO,
     'rtl/akiko.v',
     "\tassign cd_dma_wbyte = rx_busy  ? cdrom_result_buffer[cdrom_receive_offset] :",
     "\tassign cd_dma_wbyte = rx_busy  ? 8'hA5 :",
     'B.'),

    ('a command is consumed while none is pending',
     'rtl/sim/akiko/tb_akiko_cmd_phantom.sv', AKIKO_BR,
     'rtl/akiko.v',
     "\t\t\tif (hps_cmd_done && cmd_pending) begin",
     "\t\t\tif (hps_cmd_done && 1'b1) begin",
     'len_survives_phantom'),
]


def build_and_run(bench, sources, out):
    argv = (['iverilog', '-g2012', '-I.', '-o', out] +
            sources.split() + [bench])
    c = subprocess.run(argv, capture_output=True, text=True)
    if c.returncode != 0:
        return None, c.stderr.strip().splitlines()[:2]
    r = subprocess.run(['vvp', out], capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout.splitlines()


def main():
    if not os.path.isdir(os.path.join('rtl', 'sim')):
        print('run this from the repository root')
        return 1

    tmp = tempfile.mkdtemp(prefix='mut')
    rc = 0

    # Baselines first: a mutation result is meaningless against a red bench.
    seen = {}
    for _, bench, sources, _, _, _, _ in MUTATIONS:
        if bench in seen:
            continue
        code, out = build_and_run(bench, sources, os.path.join(tmp, 'base'))
        ok = code is not None and any('PASS' in l for l in (out or []))
        seen[bench] = ok
        print('baseline %-44s %s' % (os.path.basename(bench),
                                     'PASS' if ok else 'NOT PASSING'))
        if not ok:
            print('    cannot mutate against a bench that is not green')
            rc = 1
    if rc:
        return rc
    print()

    for label, bench, sources, src, find, repl, expect in MUTATIONS:
        backup = src + '.mutbak'
        shutil.copyfile(src, backup)
        try:
            s = io.open(src, encoding='utf-8', newline='').read()
            if find not in s:
                print('%-58s ANCHOR MISSING -- update this entry' % label[:58])
                rc = 1
                continue
            io.open(src, 'w', encoding='utf-8', newline='').write(
                s.replace(find, repl, 1))

            code, out = build_and_run(bench, sources, os.path.join(tmp, 'mut'))
            if code is None:
                print('%-58s compile error: %s' % (label[:58], out))
                rc = 1
                continue

            fails = [l for l in out if l.startswith('FAIL')]
            hit = [l for l in fails if expect in l]
            if not fails:
                print('%-58s NOT CAUGHT -- the check is vacuous' % label[:58])
                rc = 1
            elif not hit:
                print('%-58s caught, but not by the expected check (%s); '
                      'first: %s' % (label[:58], expect, fails[0][:50]))
                rc = 1
            else:
                print('%-58s caught (%d, incl. %s)'
                      % (label[:58], len(fails), expect))
        finally:
            shutil.copyfile(backup, src)
            os.remove(backup)

    print()
    if rc:
        print('A mutation was not caught by the check that claims to cover it.')
        print('Either the bench asserts less than it says, or the entry above is')
        print('stale. Do not relax the entry to make this pass.')
    else:
        print('%d mutation(s), each caught by the check that claims it'
              % len(MUTATIONS))
    return rc


if __name__ == '__main__':
    sys.exit(main())
