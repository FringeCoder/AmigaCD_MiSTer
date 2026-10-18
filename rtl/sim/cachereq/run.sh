#!/usr/bin/env bash
# tb_cache_req_equiv in four configurations: LINE_TAKE 0 (ram1, sdram_ctrl)
# and 1 (ram2, ddram_ctrl), two seeds each, in parallel. Run from this
# directory. Every one must print RUN: PASS. Compiles go through
# check-icarus-warnings.sh, which fails a padded or omitted port.
set -euo pipefail
SRC="../../cpu_cache_new.v cpu_cache_new_ref.v ../cache/dpram_sim.v tb_cache_req_equiv.sv"
pids=()
for lt in 0 1; do
	for seed in 1 7; do
		bash ../check-icarus-warnings.sh -g2012 -DLT=$lt -DSEED=$seed -o sim_$lt$seed $SRC
		(vvp -n sim_$lt$seed > out_$lt$seed.log) & pids+=($!)
	done
done
for p in "${pids[@]}"; do wait "$p"; done
fail=0
for lt in 0 1; do
	for seed in 1 7; do
		grep -E "^LINE_TAKE|MISMATCH|^X at" out_$lt$seed.log | head -6
		grep -q "RUN: PASS" out_$lt$seed.log || fail=1
	done
done
[ "$fail" = 0 ] && echo "RUN: PASS" || { echo "RUN: FAIL"; exit 1; }
