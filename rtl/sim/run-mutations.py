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
REGSHADOW = 'rtl/ss_regshadow.v rtl/sim/regshadow/ss_regshadow_ref.v'
AKIKO_BR = ('rtl/akiko.v rtl/akiko_nvram.v rtl/akiko_hps_bridge.v '
            'rtl/sim/cache/dpram_sim.v')
FMV = 'rtl/fmv/fmv_afifo.v rtl/fmv/fmv_bus.v rtl/fmv/fmv_ddr.v rtl/fmv/fmv_video.v rtl/fmv/fmv.v'
FMV_TB = 'rtl/sim/fmv/tb_fmv.sv'
FMVV = 'rtl/fmv/fmv_ddr.v rtl/fmv/fmv_video.v'
FMVV_TB = 'rtl/sim/fmv/tb_fmv_video.sv'

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

    # ss_regshadow's set/clear readback is registered; the bench compares it
    # with the combinational version wherever ss_ctrl could sample it.
    ('set/clear readback takes DMACON for every register',
     'rtl/sim/regshadow/tb_ss_regshadow_rd_equiv.sv', REGSHADOW,
     'rtl/ss_regshadow.v',
     "sc_val_q <= `SC_REG(rd_addr[7:0]);", "sc_val_q <= r_dmacon;",
     'rd_data at'),

    ('set/clear readback not selected',
     'rtl/sim/regshadow/tb_ss_regshadow_rd_equiv.sv', REGSHADOW,
     'rtl/ss_regshadow.v',
     "sc_sel_q   ? sc_val_q : mem_q;", "mem_q;",
     'rd_data at'),

    ('set/clear select from the replay walk\'s address',
     'rtl/sim/regshadow/tb_ss_regshadow_rd_equiv.sv', REGSHADOW,
     'rtl/ss_regshadow.v',
     "sc_sel_q <= setclear(rd_addr[7:0]);", "sc_sel_q <= setclear(mem_addr);",
     'rd_data at'),

    ('set/clear readback a clock later than the array',
     'rtl/sim/regshadow/tb_ss_regshadow_rd_equiv.sv', REGSHADOW,
     'rtl/ss_regshadow.v',
     "\tsc_val_q <= `SC_REG(rd_addr[7:0]);\nend",
     "\tsc_val_d <= `SC_REG(rd_addr[7:0]); sc_val_q <= sc_val_d;\nend\n"
     "reg [15:0] sc_val_d;",
     'rd_data at'),
    # The FMV front end against FringeCoder/AmigaCD docs/fmv-contract.md v4:
    # one entry per rule tb_fmv.sv claims. Two were not caught when first
    # written (a mask test that wrote 0, which an OR leaves unchanged, and an
    # off test whose bench-side decode already gated on fmv_on); both checks
    # were fixed rather than the entries dropped.
    ('FMV: 68k write ignores the write mask', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "(cpu_data_in & rf_q[31:16] & lanes)};", "(cpu_data_in & lanes)};",
     'B.masked write'),
    ('FMV: HMEM pointer does not step after a write', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "r44[3:0] <= r44[3:0] + 1'd1;", "r44[3:0] <= r44[3:0];",
     'C.HMEM'),
    ('FMV: event entry without SEQ', FMV_TB, FMV, 'rtl/fmv/fmv_ddr.v',
     "avl_writedata  <= {n[15:0], ev_data};", "avl_writedata  <= {16'd0, ev_data};",
     'D.event SEQ'),
    ('FMV: CL450 INT taken as HOST_control[7], not its inverse', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "wire cl_int = ~r48[7];", "wire cl_int = r48[7];",
     'E.'),
    ('FMV: L64111 status read does not deassert INTR', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\t\t\tl64_int     <= 1'b0;\n", "",
     'F.reading status 2'),
    ('FMV: guarded raise applied after the ack', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "wire        u_drop     = u_guard & l64_acked & ($signed(u_rdidx - l64_ack_idx) <= 0);",
     "wire        u_drop     = 1'b0;",
     'F.guard drops'),
    ('FMV: IO word without the interrupt mirrors', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\t\t\trd_val <= io_view(rf_q[15:0]);", "\t\t\t\t\trd_val <= rf_q[15:0];",
     'G.IO'),
    ('FMV: board bytes swapped on a ROM read', FMV_TB, FMV, 'rtl/fmv/fmv_ddr.v',
     "mrdata <= {rd_q[{k, 4'd0} +: 8], rd_q[{k, 4'd8} +: 8]};",
     "mrdata <= {rd_q[{k, 4'd8} +: 8], rd_q[{k, 4'd0} +: 8]};",
     'H.ROM: word'),
    ('FMV: a ROM write reaches DDR3', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\t\tif (is_rom & cpu_rw | is_ram) begin", "\t\t\t\tif (is_rom | is_ram) begin",
     'H.ROM: a write is dropped'),
    ('FMV: update applied before its SEQ has landed', FMV_TB, FMV, 'rtl/fmv/fmv_ddr.v',
     "\t\t\tif (w0[63:48] == uq_rd[15:0]) begin", "\t\t\tif (1'b1) begin",
     'J.not applied'),
    ('FMV: no back-pressure on a full event ring', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\twire        ring_full  = (backlog >= 16'd4095);", "\twire        ring_full  = 1'b0;",
     'I.the 68k is held'),
    ('FMV: Amiga reset not posted', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\trst_pend <= 1'b1;", "\t\t\trst_pend <= 1'b0;",
     'K.RESET'),
    ('FMV: status[64] does not gate the bus', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\twire        access  = sel & ~cpu_as_n & ds & fmv_on;", "\twire        access  = sel & ~cpu_as_n & ds;",
     'L.off'),
    # v4, after the 2026-11-02 hardware run: a session starts from zero. Not
    # covered: an update straggling into fmv_bus while off is dropped (the
    # bench cannot make one; it needs the off edge to land mid-transfer).
    ('FMV: queue counters kept across an off', FMV_TB, FMV, 'rtl/fmv/fmv_ddr.v',
     "\t\t\t\tn     <= 32'd0;\n\t\t\t\tuq_rd <= 32'd0;\n", "",
     'M.on: the queue is read from entry 0'),
    ('FMV: the DDR3 master polls while off', FMV_TB, FMV, 'rtl/fmv/fmv_ddr.v',
     "\t\t\tend else if (!on_s2) begin", "\t\t\tend else if (1'b0) begin",
     'M.off: no DDR3 traffic'),
    ('FMV: back-pressure count kept across an off', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\tev_count    <= 32'd0;\n", "",
     'M.on: back-pressure'),
    ('FMV: ALIVE kept across an off', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\talive       <= 1'b0;\n", "",
     'M.on: ALIVE does not survive'),
    # Gate 1 run v20 (2026-11-04): a held access must not block the update
    # that releases it. Applying updates only with no access pending, as
    # the first version did, brings the deadlock back.
    ('FMV: a held access blocks its own release', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "\t\t\tend else if (!up_empty) begin\n\t\t\t\t// (also while an access is held: see above)",
     "\t\t\tend else if (!up_empty && !access) begin\n\t\t\t\t// (also while an access is held: see above)",
     'I.released by the HOST_RDIDX update'),
    # The picture, contract v5 (tb_fmv_video.sv, and tb_fmv.sv's N).
    ('FMV: display registers not written by the queue', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "if (u_index[7:4] == 4'hE && u_index[3:0] < 4'd7)",
     "if (1'b0)",
     'N.display registers'),
    ('FMV: display register update ignores the mask', FMV_TB, FMV, 'rtl/fmv/fmv_bus.v',
     "(disp_r[{u_index[2:0], 4'd0} +: 16] & ~u_mask) | (u_value & u_mask);",
     "u_value;",
     'N.display registers'),
    ('FMV video: the set is taken at HSYNC, not VSYNC (tearing)', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "\t\tif (vs_fall) begin\n\t\t\ta_ctrl",
     "\t\tif (hs_fall) begin\n\t\t\ta_ctrl",
     'D.a BUF change waits for VSYNC'),
    ('FMV video: pixel lanes reversed', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "wire [15:0] p = q[{lane, 4'd0} +: 16];",
     "wire [15:0] p = q[{~lane, 4'd0} +: 16];",
     'A.window pixels'),
    ('FMV video: a line fetched into the half it is shown from', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "fhalf  <= line_nxt[0];",
     "fhalf  <= line_now[0];",
     'A.window pixels'),
    ('FMV video: BLANK ignored', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "(inwin & ~a_blank)",
     "(inwin)",
     'E.BLANK'),
    ('FMV video: border colour bytes swapped', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "a_border <= {disp[95:80], disp[103:96]};",
     "a_border <= {disp[103:96], disp[95:80]};",
     'A.outside the window'),
    ('FMV video: green widened from the wrong bits', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "p[10:5], p[10:9]",
     "p[10:5], p[6:5]",
     'A.window pixels'),
    ('FMV video: KEY_ALL never set', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "key_all <= on & a_on & a_ctrl[4];",
     "key_all <= 1'b0;",
     'F.KEY_ALL'),
    ('FMV video: status[64] does not stop the fetches', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "wire        fetch    = on & a_on &",
     "wire        fetch    = a_on &",
     'H.off: no fetch requested'),
    ('FMV video: one clock more of latency', FMVV_TB, FMVV, 'rtl/fmv/fmv_video.v',
     "wire [11:0] rel  = hcnt - x2;",
     "wire [11:0] rel  = hcnt - x2 - 12'd1;",
     'A.window pixels'),
    ('FMV ddr: bursts not split at 32 words', FMVV_TB, FMVV, 'rtl/fmv/fmv_ddr.v',
     "localparam [6:0] FBURST = 7'd32;",
     "localparam [6:0] FBURST = 7'd64;",
     'C.bursts of at most 32'),
    # The boundary register on the HPS read data (row 52's hold failures):
    # taking the data a clock before its valid would read the previous beat.
    ('FMV ddr: read data out of step with its valid', FMVV_TB, FMVV, 'rtl/fmv/fmv_ddr.v',
     "\t\trd_q  <= avl_readdata;\n\t\trdv_q <= avl_readdatavalid;",
     "\t\trd_q  <= avl_readdata;\n\t\trdv_q <= avl_readdatavalid & ~rdv_q;",
     'A.window pixels'),
    ('FMV ddr: one word short on each line', FMVV_TB, FMVV, 'rtl/fmv/fmv_ddr.v',
     "f_left    <= fwords;",
     "f_left    <= fwords - 1'd1;",
     'B.each window line fetched once'),
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

    # A missing toolchain is not a bench problem, and must not be reported as
    # one. The first version of this in CI ran before iverilog was installed:
    # every mutation printed a compile error and the baseline printed 'cannot
    # mutate against a bench that is not green', which sent the diagnosis
    # straight at the benches.
    for tool in ('iverilog', 'vvp'):
        if shutil.which(tool) is None:
            print('%s is not on PATH. This harness compiles and runs the'
                  ' benches, so it needs Icarus -- in CI it must come after the'
                  ' install step.' % tool)
            return 2

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
