#!/usr/bin/env bash
# Build and run tb_yc_out_equiv with Verilator. Run from this directory.
set -euo pipefail
rm -rf obj_dir
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_yc_out_equiv \
	../../../sys/yc_out.sv yc_out_ref.sv tb_yc_out_equiv.sv -o tb >build.log 2>&1 \
	|| { tail -30 build.log; exit 1; }
./obj_dir/tb | tee out.log
grep -q "RUN: PASS" out.log
