#!/usr/bin/env bash
# Build and run tb_cpu_rdgate under Icarus. Run from anywhere; it works in its
# own directory. Extra arguments go to iverilog.
set -euo pipefail
cd "$(dirname "$0")"
iverilog -g2012 "$@" -o tb tb_cpu_rdgate.sv \
	../../cpu_rdgate.v ../../cpu_cache_new.v ../../sdram_ctrl.v ../../ddram_ctrl.v \
	../../ddr_cmd_pipe.v ../../A2065/a2065_ddram_arbiter.v ../cache/dpram_sim.v
vvp -n tb | tee out.log
grep -q "RUN: PASS" out.log
