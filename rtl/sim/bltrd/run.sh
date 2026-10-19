#!/usr/bin/env bash
# tb_bltrd_equiv in four configurations: OCS/ECS and AGA, two seeds each, in
# parallel. Run from this directory. Every one must print RUN: PASS. Compiles
# go through check-icarus-warnings.sh, which fails a padded or omitted port.
set -euo pipefail
SRC="tb_bltrd_equiv.sv ../../amiga_clk.v ../../agnus*.v agnus_ref.v agnus_blitter_ref.v agnus_blitter_adrgen_ref.v"
pids=()
for aga in 0 1; do
	for seed in 1 7; do
		bash ../check-icarus-warnings.sh -g2012 -Ptb_bltrd_equiv.AGA=$aga -Ptb_bltrd_equiv.SEED=$seed -o sim_$aga$seed $SRC
		(vvp -n sim_$aga$seed > out_$aga$seed.log) & pids+=($!)
	done
done
for p in "${pids[@]}"; do wait "$p"; done
fail=0
for aga in 0 1; do
	for seed in 1 7; do
		grep -E "^DMA slots|^AGA|MISMATCH|^X clk" out_$aga$seed.log | head -6
		grep -q "RUN: PASS" out_$aga$seed.log || fail=1
	done
done
[ "$fail" = 0 ] && echo "RUN: PASS" || { echo "RUN: FAIL"; exit 1; }
