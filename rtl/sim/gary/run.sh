#!/usr/bin/env bash
# Build and run tb_gary_strobe under Icarus. Run from anywhere; it works in its
# own directory. Extra arguments go to iverilog.
set -euo pipefail
cd "$(dirname "$0")"
iverilog -g2012 "$@" -o tb tb_gary_strobe.sv ../../gary.v
vvp -n tb | tee out.log
grep -q "RUN: PASS" out.log
