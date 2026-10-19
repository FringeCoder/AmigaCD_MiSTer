#!/usr/bin/env bash
# Build and run tb_ss_regshadow_rd_equiv under Icarus. Run from anywhere; it
# works in its own directory. Extra arguments go to iverilog.
set -euo pipefail
cd "$(dirname "$0")"
iverilog -g2012 "$@" -o tb tb_ss_regshadow_rd_equiv.sv ../../ss_regshadow.v ss_regshadow_ref.v
vvp -n tb | tee out.log
grep -q "RUN: PASS" out.log
