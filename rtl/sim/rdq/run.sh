#!/usr/bin/env bash
# Build and run tb_cpu_rdq_equiv under Icarus. Run from anywhere; it works in
# its own directory. Extra arguments go to iverilog, e.g. a longer run:
#     rtl/sim/rdq/run.sh -P tb_cpu_rdq_equiv.CYCLES=400000
set -euo pipefail
cd "$(dirname "$0")"
python3 gen_pairs.py > pairs.v
iverilog -g2012 "$@" -o tb tb_cpu_rdq_equiv.sv pairs.v \
	cpu_cache_new_ref.v sdram_ctrl_ref.v ddram_ctrl_ref.v \
	../../cpu_rdq.v ../../cpu_cache_new.v ../../sdram_ctrl.v ../../ddram_ctrl.v \
	../../ddr_cmd_pipe.v ../../A2065/a2065_ddram_arbiter.v ../cache/dpram_sim.v
vvp -n tb | tee out.log
grep -q "RUN: PASS" out.log
