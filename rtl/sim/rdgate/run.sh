#!/usr/bin/env bash
# Build and run tb_cpu_rdgate under Icarus. Run from anywhere; it works in its
# own directory. Extra arguments go to iverilog.
set -euo pipefail
cd "$(dirname "$0")"
# sdram_ctrl drives an `inout reg` sd_data, which Icarus will not take as an
# l-value through a port; the sim copy makes it a net (rtl/sim/sdram).
python3 ../sdram/make_sim_sdram.py >/dev/null
iverilog -g2012 "$@" -o tb tb_cpu_rdgate.sv \
	../../cpu_rdgate.v ../../cpu_cache_new.v ../sdram/sdram_ctrl_sim.v ../../ddram_ctrl.v \
	../../ddr_cmd_pipe.v ../../A2065/a2065_ddram_arbiter.v ../cache/dpram_sim.v
vvp -n tb | tee out.log
grep -q "RUN: PASS" out.log
