#!/usr/bin/env bash
# Build and run tb_proxy_minimig under Icarus, from the repository root:
#     bash rtl/sim/armcpu/run_proxy_minimig.sh
# The file list is rtl/sim/ssmux's (the whole minimig.v) plus proxy68k.
set -euo pipefail
R=rtl
H=rtl/sim/ssmux
python3 "$H/gen_minimig_pins.py" --check
iverilog -g2012 -o /tmp/tb_pm -I"$H" -s tb_proxy_minimig rtl/sim/armcpu/tb_proxy_minimig.sv "$H/sim_stubs.v" \
  "$R/sim/cache/dpram_sim.v" "$R/amiga_clk.v" "$R/ss_regshadow.v" "$R/ss_freeze_phase.v" "$R/minimig.v" \
  "$R"/agnus*.v "$R"/paula*.v "$R"/denise*.v "$R"/cia*.v "$R/gary.v" "$R/gayle.v" "$R/ide.v" "$R/cart.v" \
  "$R/userio.v" "$R/minimig_bankmapper.v" "$R/minimig_m68k_bridge.v" "$R/minimig_sram_bridge.v" \
  "$R/minimig_syscontrol.v" "$R"/MiSTerFloppy*.v "$R/cdtv_bridge.v" "$R/cdtv_nvram.v" "$R"/A2065/a2065*.v \
  "$R/proxy68k.v"
vvp -n /tmp/tb_pm
