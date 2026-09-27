derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -setup 2
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -hold 1

set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -hold 1

# CD32 Akiko PBX address path to SDRAM. pbx_byte_idx only advances on dma_ack,
# which fires at most once per 6+ emu-clk cycles (chipdma_arb's S_DRIVE takes 4
# cycles minimum). Address is stable for well over 2 launch-clk cycles before
# the next update, so a 2-cycle setup multicycle is safe. Mirrors the existing
# emu|minimig|* -> emu|ram1|* relaxation. Without this, pbx_seccnt -> sd_addr
# violates by ~2.5 ns.
set_multicycle_path -from {emu|fastchip|akiko|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|fastchip|akiko|*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|chipdma_arb|*}    -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|chipdma_arb|*}    -to {emu|ram1|*} -hold 1

# amiga_clk c1/c3 are the 7 MHz-rate phase regs in the 28 MHz (clk_28) domain
# (c1 <= ~c3). The chip-arming address path launches from c1, passes through
# chipdma_arb combinational logic, and lands on sdram_ctrl.sd_addr captured by
# the 113 MHz SDRAM clock. -from matches the LAUNCH register (c1), not the
# chipdma_arb pass-through nodes, so the chipdma_arb|* and cck* relaxations
# above do NOT cover it and sd_addr violates by -0.49 ns. clk_114:clk_28 is
# 4:1; sdram_ctrl edge-detects ~old_7m&c_7m (sdram_ctrl.v:237-243), so a c1
# launch at fast edge N is detected at N+1 and the state-0 RAS capture
# (sdram_ctrl.v:301-318) is at N+2 — exactly 2 clk_114 cycles, never the
# adjacent edge. setup 2 matches; setup >= 3 would NOT be safe.
set_multicycle_path -from {emu|amiga_clk|c1*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|c1*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|amiga_clk|c3*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|c3*} -to {emu|ram1|*} -hold 1

# init_done is a one-shot: set when initstate saturates at sdram_state == 15 and
# never cleared except by reset (sdram_ctrl.v:240-251). It is static for the
# entire life of the design either side of that single transition, and it only
# changes on state 15 of a 16-state machine, so anything downstream has many
# cycles before it matters. After the sd_addr split this became the sole binding
# path in the design (init_done -> sd_cas, -0.172 ns) with 0.34 ns of clear air
# to the next one, purely because a static configuration signal was being held
# to a single-cycle budget it never needs.
#
# setup 2 is deliberately conservative rather than a false path: the 0->1 edge
# does change downstream behaviour, and on a memory controller "it only glitches
# once, during init" is not an argument worth relying on.
set_multicycle_path -from {emu|ram1|init_done} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|ram1|init_done} -to {emu|ram1|*} -hold 1

# Bridge DMA write port on ram2 (DDR3) is a CDC handshake. chipdma_arb
# (clk_sys) registers dma_ddr_cs_r plus the entire DDR bus (addr / wr / l / u)
# on arm_now and holds them stable until S_ACK. ddram_ctrl (clk_114)
# synchronizes dmaCS through a 2-FF chain, edge-detects the rise, and latches
# data on that edge — by which point the data has been valid in chipdma_arb
# for many clk_114 cycles. dmaACK comes back as a level, synchronized by a
# 2-FF chain inside chipdma_arb.
#
# dmaCS is therefore the only cross-domain bit that needs timing, and its sync
# chain handles metastability. The data lines are stable by handshake, so
# set_false_path is correct.
set_false_path -from {*chipdma_arb*dma_ddr_addr_r*} -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_wr_r*}   -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_l_r*}    -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_u_r*}    -to {*ddram_ctrl*}
# Also false_path the two CDC sync first-stages. dma_ddr_cs_r -> dmaCS_sync1
# is the slow->fast (clk_sys -> clk_114) handshake; dmaACK_r ->
# ddr_in_ack_sync1 is the reverse. Both are absorbed by 2-FF synchronizer
# chains in their target domains. Without this, Quartus times them at a single
# cycle and reports -3.7 ns slack.
set_false_path -from {*chipdma_arb*dma_ddr_cs_r*}   -to {*ddram_ctrl*dmaCS_sync*}
set_false_path -from {*ddram_ctrl*dmaACK_r*}        -to {*chipdma_arb*ddr_in_ack_sync*}

set_false_path -from {emu|cpu_wrapper|z3ram_*}
set_false_path -from {emu|cpu_wrapper|z2ram_*}

set_false_path -from {emu|minimig|USERIO1|cpu_config*}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

# A2065: the card's 68k side (clk_sys) reaches its DDR3 mailbox (DDRAM_CLK,
# clk_114) over 2-FF level-detect CDC handshakes inside a2065_regfile and
# a2065_ddram. Those are self-timed and need no multicycle exception. If the
# fitter reports real violations across that boundary, add a targeted
# set_false_path/set_max_delay derived from report_timing — do not guess.

# yc_out chroma LUT: multicycle retained from the old bridge, where boardram BRAM
# placement congestion pushed this path to -0.471ns. The flat-DDR3 design removes
# that BRAM, so this exception may now be UNNECESSARY. Re-validate against the
# merged fitter run (R3); keep only if report_timing still shows the path marginal.
set_multicycle_path -from {yc_out|chroma_LUT_BURST[*]} \
                    -to   {yc_out|phase[*].u[*]} -setup 2
set_multicycle_path -from {yc_out|chroma_LUT_BURST[*]} \
                    -to   {yc_out|phase[*].u[*]} -hold 1

# emu PLL cross-clock: counter[1]→counter[0] marginal path
set_multicycle_path -setup 2 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]
set_multicycle_path -hold 1 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1

# ---------------------------------------------------------------------------
# The external SDRAM interface.
#
# Until this was written nothing timed it: report_ucp on the seed 1 netlist of
# 2026-09-27 counted 92 unconstrained output ports over 258 paths and 26
# unconstrained input ports over 171, and all 39 SDRAM_* pins were in there.
# The fitter was free to route the thirteen address lines however it liked and
# STA had no opinion, so skew across them was a property of the placement seed.
#
# That is not theoretical. Seed 16 of the CLUT netlist fit with all five
# worst-case slacks positive and zero critical warnings, and produced a machine
# that never reached Kickstart; seed 18 of the same netlist booted. The 68020
# fetches its reset vectors through this bus. See
# ../../docs/sdram-timing-headroom.md.
#
# SDRAM_CLK is sd_clk (sdram_ctrl.v:338), which toggles on every sysclk, so the
# bus runs at half the 113.5 MHz core clock: 56.75 MHz, 17.616 ns.
#
# The module fitted to this board (a Retro Remake SuperStation) has not been
# identified, so each figure below is the worst across the three parts these
# boards are built with -- Alliance AS4C32M16SB-6, Winbond W9825G6KH-6, ISSI
# IS42S16320F-6. If the part is ever read off the chip, only these four numbers
# change.
set sdram_tIS   1.5     ;# input setup at the SDRAM, worst of the three
set sdram_tIH   0.8     ;# input hold
set sdram_tAC   6.0     ;# access time from clock, worst of the three
set sdram_tOH   2.0     ;# output data hold, worst (smallest) of the three
set sdram_trace_max 0.4 ;# PCB flight time, 30-50 mm
set sdram_trace_min 0.2

create_generated_clock -name SDRAM_CLK_out -divide_by 2 \
    -source [get_pins {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
    [get_ports {SDRAM_CLK}]

set sdram_out_ports [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                                SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE \
                                SDRAM_CKE SDRAM_DQML SDRAM_DQMH}]

set_output_delay -clock SDRAM_CLK_out -max [expr {$sdram_tIS + $sdram_trace_max}] $sdram_out_ports
set_output_delay -clock SDRAM_CLK_out -min [expr {-$sdram_tIH - $sdram_trace_min}] $sdram_out_ports

set_input_delay  -clock SDRAM_CLK_out -max [expr {$sdram_tAC + $sdram_trace_max}] [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK_out -min [expr {$sdram_tOH + $sdram_trace_min}] [get_ports {SDRAM_DQ[*]}]

# The address and command are set up a whole SDRAM cycle before the edge that
# samples them: sysclk runs at twice SDRAM_CLK, and sdram_ctrl advances its
# state machine on sysclk while the SDRAM only ever looks on its own rising
# edge. Without this, TimeQuest pairs the launch with the nearest SDRAM_CLK
# edge -- 8.809 ns instead of 17.616 -- and reports a violation the design
# never had.
set sdram_launch [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set_multicycle_path -setup 2 -from $sdram_launch -to [get_clocks SDRAM_CLK_out]
set_multicycle_path -hold  1 -from $sdram_launch -to [get_clocks SDRAM_CLK_out]

# Read data comes back a cycle after the SDRAM launches it. sdram_ctrl captures
# SDRAM_DQ into sdata_reg on the sysclk edges where sdram_state[0] is high
# (sdram_ctrl.v:348), while SDRAM_CLK is the REGISTERED version of that same bit
# (sdram_ctrl.v:338) -- so the clock the SDRAM sees, and everything it launches
# in reply, sits one sysclk behind the internal state that captures it. Both
# directions of this interface carry that offset, which is what the 2 encodes.
#
# Found empirically first -- 1 gives -5.9 ns and 0 gives -14.7 -- and only then
# traced back to the registered clock output. Anyone changing how SDRAM_CLK is
# generated has to revisit these. The cleaner statement of the same thing would
# be to derive the generated clock through sd_clk|q so TimeQuest computes the
# offset itself; that has not been tried.
set_multicycle_path -setup 2 -from [get_clocks SDRAM_CLK_out] -to $sdram_launch
set_multicycle_path -hold  2 -from [get_clocks SDRAM_CLK_out] -to $sdram_launch
