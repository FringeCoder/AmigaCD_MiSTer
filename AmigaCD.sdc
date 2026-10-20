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

# No multicycle on init_done any more. It had a setup 2 here, added for the
# split sd_addr this fork used to carry, on the grounds that nothing needs
# init_done within a cycle of its 0->1 edge. Upstream 26eb46a's controller,
# which replaced that one, does: init_n arms st0_go on the very edge init_done
# rises, so the first state 0 issues its ACTIVATE regardless, and the same
# state 0 picks slot_type / cas_sd_cas / casaddr by `if(!init_done)`. Seen a
# cycle late, that frame would open a bank and never close it. Single cycle,
# as upstream constrains it.

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

# ---------------------------------------------------------------------------
# The save state vector's two crossings.
#
# ss_serdes shifts on clk_114. Everything it gathers and everything it hands
# back lives on clk_sys -- the CPU shadows, minimig's registers, ss_regshadow,
# ss_state_fanout. The two clocks are 4:1 out of one VCO and share a rising
# edge every fourth cycle, so TimeQuest pairs a launch on one with a latch on
# the other AT THE SAME INSTANT and HOLD-checks about two thousand bits against
# that pairing. A path of one LUT and 0.2 ns of routing cannot pass such a
# check, so whether it passes is how close the fitter happened to put the two
# ends, and nothing else.
#
# Measured, on four different netlists and in four different fields:
#
#     -0.578  ss_cpu_a4[19]             -> ss_serdes|shifter[1696]
#     -0.489  ss_cpu_a3[23]             -> ss_serdes|shifter[1732]
#     -0.470  ss_cpu_a7[4]              -> ss_serdes|shifter[1585]
#     -0.359  ss_serdes|state_out[1909] -> ss_state_out_q[1909]
#     -0.354  ss_serdes|state_out[1941] -> ss_state_out_q[1941]
#     -0.221  ss_serdes|state_out[1569] -> ss_fanout|cpu_wr_data[20]
#     -0.318  ss_serdes|state_out[324]  -> CIAA1's TOD read latch
#     -0.020  ss_ctrl|shadow_ld_data[10]-> ss_regshadow|written[138]
#
# A RETIMING FLOP DOES NOT FIX THIS, and the attempt is in the history: the
# clk_sys bank in front of ss_state_fanout (AmigaCD.sv, ss_state_out_q) moved
# where the violation is reported and removed nothing, because a new register
# in the destination domain inherits the very same coincident-edge pairing as
# the register it was added to protect. It measured +0.220 at seed 2 and -0.359
# at seed 4 on identical sources. Anyone tempted to add another flop here
# should read that as the experiment already having been run.
#
# WHY THESE CHECKS ARE MODELLING SOMETHING THAT CANNOT HAPPEN, which is the
# only argument that justifies switching them off:
#
#   capture   ss_ctrl serialises the vector INSIDE the freeze. ss_quiesce and
#             ss_freeze_phase stop the machine first, and a frozen Amiga has no
#             clk7_en, so no chipset register can change while the capture
#             runs. The CPU is parked on ss_arm, so its shadows cannot either.
#             This is the same argument AmigaCD.sv already makes in the comment
#             above its ss_cia_a / ss_cia_b capture registers.
#
#   restore   state_out is written once, when the serdes finishes loading a
#             file, and then held until the next load. ss_state_fanout does not
#             even look at it until the cycle after it accepts req, and then
#             sequences for 24 clk_sys cycles. There is no edge at which
#             state_out moves while a consumer is sampling it.
#
# So the data is static exactly when it is read, in both directions. That makes
# these the same case as the chipdma_arb handshake buses false-pathed above --
# "the data lines are stable by handshake" -- and the exceptions are scoped the
# same way: narrowly, by the node that is actually crossing.
#
# Note what is NOT excepted. The shifter's own clk_114 shifting stays timed;
# only arrivals from clk_sys are excused. state_out's clk_114 consumers stay
# timed; only its clk_sys consumers are excused. The shifter has no clk_sys
# input other than the state vector and state_out has no clk_sys consumer other
# than the restore fan-out, so neither exception can reach anything else.
#
# If the vector ever stops being static during a transfer -- a capture that
# runs with the machine live, or a fan-out that re-reads state_out while the
# serdes is still loading it -- these exceptions become wrong and the hold
# violations they hide become real. That is the property to re-check before
# changing when ss_ctrl captures or restores, not the slack numbers.
set ss_clk114 [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]
set ss_clksys [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"]

# Capture: clk_sys state sources into the serdes shift register.
set_false_path -from $ss_clksys -to {*ss_serdes*|shifter[*]}

# Restore: the held vector out to its clk_sys consumers -- the fan-out, the
# CIAs and Akiko directly since row 23 removed the clk_sys banks in between.
set_false_path -from {*ss_serdes*|state_out[*]} -to $ss_clksys

# Restore: ss_ctrl's chipset-shadow replay bus into ss_regshadow, which is
# clk_sys. Same vector, same freeze, carried on its own bus.
set_false_path -from {*ss_ctrl*|shadow_ld_data[*]} -to $ss_clksys

# The CIA and Akiko capture registers (ss_cia_a/b, ss_akiko) had their own
# false paths here. They were removed on 2026-10-20 (row 23, for area): the
# CIA and Akiko words now go into the shifter raw, under the shifter's false
# path above, which is what those registers' exceptions said anyway.

set_false_path -from {emu|cpu_wrapper|z3ram_*}
set_false_path -from {emu|cpu_wrapper|z2ram_*}
# Upstream 26eb46a: the SDRAM-backed Zorro III windows are set by autoconfig
# and the SDRAM size by the Main, both once per boot.
set_false_path -from {emu|cpu_wrapper|z3sdr_*}
set_false_path -from {emu|sdram_big*}
set_false_path -from {emu|sdram_dual*}

set_false_path -from {emu|minimig|USERIO1|cpu_config*}
# chipset_config and memory_config (all but bit 6) are latched only while
# minimig's reset is asserted -- userio.v, "configuration changes only while
# reset is active" -- the same reason cpu_config above is a false path. Note
# what that reset includes: the 68k's own RESET instruction (minimig.v,
# reset = sys_reset | ~_cpu_reset_in), which does not stop the CPU, and the OSD
# writes the pending values (t_*) while the machine runs. So a change the OSD
# made is taken on the next reset of any kind. Everything that reads these
# bits is itself held in reset or idle across that pulse (Agnus, Denise,
# Paula, the CIAs, Akiko, autoconfig, no chip request on the SDRAM address);
# the only live readers are cosmetic (ce_pix/res, cdda_gain). An OSD write
# landing in the last clock or two of a reset pulse is the one unchecked edge,
# and it is exactly upstream's exposure for cpu_config. Measured as a source into
# sdram_ctrl sd_addr at -0.64 ns on seed 8 of the 68030 netlist, through the
# chipset decodes (a1k / ecs / aga) and the memory map. memory_config[6] is
# copied every clock (userio.v, outside the reset branch) and stays timed, as
# do floppy_config and floppy_ext_drive, which the OSD writes while running.
set_false_path -from {emu|minimig|USERIO1|chipset_config[*]}
set_false_path -from {emu|minimig|USERIO1|memory_config[0] emu|minimig|USERIO1|memory_config[1] emu|minimig|USERIO1|memory_config[2] emu|minimig|USERIO1|memory_config[3] emu|minimig|USERIO1|memory_config[4] emu|minimig|USERIO1|memory_config[5] emu|minimig|USERIO1|memory_config[7]}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

# A2065: the card's 68k side (clk_sys) reaches its DDR3 mailbox (DDRAM_CLK,
# clk_114) over 2-FF level-detect CDC handshakes inside a2065_regfile and
# a2065_ddram. Those are self-timed and need no multicycle exception. This
# comment used to end by saying that if the fitter reported real violations
# across that boundary, add a targeted exception derived from report_timing and
# do not guess. It did report them, so here they are.
#
#     -0.614  a2065_regfile|cmd_data[12] -> a2065_ddr3_mailbox|cmd_data_s[12]
#     -0.505  a2065_regfile|cmd_rap[3]   -> a2065_ddr3_mailbox|cmd_rap_s[3]
#
# measured on the seed 2 netlist of 2026-10-01, where they were the two worst
# hold paths in the design. They are hold failures, so they are not a
# frequency problem and no seed or multicycle reaches them: the two clocks come
# off one VCO at 4:1 and share an edge, and a payload bus that crosses in one
# LUT is as fast as a path gets.
#
# DERIVED, NOT GUESSED, and deliberately wider than the two paths above.
# Every crossing between these three modules was enumerated with
# report_timing -from/-to and every one resolves to real registers; on the seed
# 2 netlist of fix/ss-vector-retime they measured, in nanoseconds of hold slack:
#
#     cmd_data        16 bits   +0.618      bram_req_addr   14 bits   +0.703
#     cmd_rap          7 bits   +0.688      bram_req_wdata  16 bits   +0.653
#     cmd_pending      1 bit    +0.944      bram_req_rw      1 bit    +2.222
#     cmd_clear (rev)  1 bit    +0.704      bram_req_be      2 bits   +1.678
#     bram_resp_data  16 bits   +0.455      bram_req_valid   1 bit    +1.459
#     bram_resp_valid  1 bit    +1.463
#
# Constraining only the two that happened to violate once would leave nine
# identical paths to take their turn on the next placement, which is the
# failure mode this file has been chasing all along.
#
# bram_req_ack is NOT in the list, and that is a finding rather than an
# oversight. a2065_ddram declares ack_sync0 / ack_sync1 for it and never reads
# either -- Quartus says so, "object ack_sync1 assigned a value but never
# read" -- so the chain is synthesised away and the signal crosses to nothing.
# An exception for it resolved to a collection of size zero, which an SDC
# accepts in silence. The dead chain in a2065_ddram is worth deleting on its
# own account; it is not a timing matter.
#
# WHY IT IS SAFE, checked on both sides rather than assumed:
#
#   the control bits   cmd_pending, bram_req_valid and the replies are LEVELS
#                      held until the far side withdraws, each landing in a
#                      2-FF synchroniser chain in the destination domain. That
#                      chain is what handles metastability; timing its first
#                      stage is meaningless. a2065_ddr3_mailbox's own comment
#                      explains why they are levels: a one-cycle pulse at 9 ns
#                      would be missed by a side sampling every 35 ns.
#
#   the payloads       are written in the same cycle as the control bit that
#                      announces them and then frozen. a2065_regfile writes
#                      cmd_rap / cmd_data only in W_IDLE and holds them through
#                      W_WAIT until cmd_clear has round-tripped; a2065_ddram
#                      writes the bram_req payload only when no request is
#                      outstanding and withdraws it on the response. The
#                      mailbox consumes each payload on the SECOND
#                      synchroniser stage, by which point it has been stable
#                      for at least two destination cycles.
#
# So these are the same case as the chipdma_arb handshake buses above: stable
# by handshake, and false-pathed for that reason and no other. If either side
# ever changes a payload while its request is still asserted, these exceptions
# become wrong -- that is the property to re-check, not the slack.

# clk_sys -> clk_ddr: the requesters into the mailbox's capture stage.
set_false_path -from {*a2065_regfile*|cmd_pending}     -to {*a2065_ddr3_mailbox*|cmd_pending_s}
set_false_path -from {*a2065_regfile*|cmd_rap[*]}      -to {*a2065_ddr3_mailbox*|cmd_rap_s[*]}
set_false_path -from {*a2065_regfile*|cmd_data[*]}     -to {*a2065_ddr3_mailbox*|cmd_data_s[*]}
set_false_path -from {*a2065_ddram*|bram_req_valid}    -to {*a2065_ddr3_mailbox*|bram_req_valid_s}
set_false_path -from {*a2065_ddram*|bram_req_addr[*]}  -to {*a2065_ddr3_mailbox*|bram_req_addr_s[*]}
set_false_path -from {*a2065_ddram*|bram_req_wdata[*]} -to {*a2065_ddr3_mailbox*|bram_req_wdata_s[*]}
set_false_path -from {*a2065_ddram*|bram_req_rw}       -to {*a2065_ddr3_mailbox*|bram_req_rw_s}
set_false_path -from {*a2065_ddram*|bram_req_be[*]}    -to {*a2065_ddr3_mailbox*|bram_req_be_s[*]}

# clk_ddr -> clk_sys: the mailbox's held replies into their requesters' chains.
set_false_path -from {*a2065_ddr3_mailbox*|cmd_clear}        -to {*a2065_regfile*|cmd_clear_s}
set_false_path -from {*a2065_ddr3_mailbox*|bram_resp_valid}  -to {*a2065_ddram*|rv_sync0}
set_false_path -from {*a2065_ddr3_mailbox*|bram_resp_data[*]} -to {*a2065_ddram*|rd_sync0[*]}

# clk_ddr -> clk_sys: the card's interrupt into a2065.v's 2-FF synchroniser.
# a2065_int2 is a registered level and int2_s1 exists to take it at any time;
# landing a clk_sys cycle early or late moves INT2 by 35 ns, which nothing can
# see. Timed, it failed hold on 1 of 60 panel fits (0.76 ns of clk_sys skew).
# Deliberately NOT here: csr0_out..csr3_out -> a2065_regfile csr_shadow. That
# is a 16-bit word sampled without a synchroniser; it is coherent only because
# it is timed as the synchronous 4:1 path it is. False-pathing it would let a
# 68k read of CSR0 mix old and new bits. Its two hold failures in 60 fits are
# rejected by the pick job, which is the correct outcome.
set_false_path -from {*a2065_ddr3_mailbox*|a2065_int2}       -to {*a2065_inst|int2_s1}

# The read data registers into the TG68K: two clk_114 periods, by construction.
# AmigaCD.sv's cpu_rdgate acks a read to the TG68K only once the controller's ack
# has been up for a clock, and ANDs the data with that same condition, so on any
# clk_sys edge either the TG68K's input is a constant zero or the data was
# loaded at least two clk_114 edges earlier (cpu_cache_new loads cpu_dat_r and
# cpu_dat_hi only on the edge its ack rises, and ack falls with the select).
# -start: the multiplier is in launch (clk_114) periods; the latch is clk_sys.
# Only the TG68K: fx68k sees the ungated path and is timed as before. Proven
# against the real controllers in rtl/sim/rdgate. These paths were families D
# and G, the worst after the 2026-10-17 sync (docs/seed-lottery.md, row 22).
set rd_launch {emu|ram1|cpu_cache|cpu_dat_r[*] emu|ram2|cpu_cache|cpu_dat_r[*] emu|ram2|cpu_cache|cpu_dat_hi[*]}
set_multicycle_path -start -setup 2 -from $rd_launch -to {emu|cpu_wrapper|cpu_inst_p|*}
set_multicycle_path -start -hold  1 -from $rd_launch -to {emu|cpu_wrapper|cpu_inst_p|*}

# ss_ctrl's shadow readback needs no exception. It carried a multicycle from
# shadow_rd_addr into ss_ctrl while ss_regshadow's set/clear select was
# combinational on the address (L's worst path, -2.960 on seed 35 of run
# 39186900101); ss_regshadow now registers that select with its array read, so
# shadow_rd_addr reaches only clk_sys registers there and rd_data comes only from
# registers. rtl/sim/regshadow proves the registered read equal at every point
# ss_ctrl could sample it.

# clk_114 -> clk_sys: the save-state diagnostics' 2-FF synchroniser in
# AmigaCD.sv. ss_dbg_meta is its first stage, taking a 64-bit vector of ss_ctrl
# state as one snapshot; the second stage (ss_dbg_sync) is what the HPS poller
# reads, and a torn or stale sample costs one log line (see AmigaCD.sv). Timed,
# it failed hold on seed 34 of run 39186900101 (pay_idx[0] -> ss_dbg_meta[28],
# -0.289).
set_false_path -to {emu|ss_dbg_meta[*]}

# yc_out: no exception. A multicycle from chroma_LUT_BURST to phase[*].u used
# to sit here, retained from the old bridge. It was never valid -- the burst LUT
# index is recomputed from the free-running phase accumulator every clk_114
# cycle -- and its source register is gone: sys/yc_out.sv now registers the
# sine values rather than the indices (local first, upstream since
# Template_MiSTer #120), which closes the path as a plain single-cycle one.

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

# Both directions carry a two-cycle relationship. sysclk runs at twice
# SDRAM_CLK, and SDRAM_CLK is a REGISTERED output of sdram_state[0]
# (sdram_ctrl.v:338) while the state that drives the address and captures read
# data is the internal one -- so the external side sits one sysclk behind.
#
# Measured on the seed 1 netlist, which is how each piece earned its place:
#
#   clock from the PLL pin, no multicycle     setup -17.273  hold -5.922
#   clock from the PLL pin, 2/1               setup  +0.344  hold -5.922
#   clock through sd_clk|q, no multicycle     setup -11.983  hold -1.756
#   clock through sd_clk|q, 2/1               setup  +0.337  hold -1.756
#   clock through sd_clk|q, 2/2               setup  +0.337  hold +0.243
#
# Deriving the clock through the register is what models its clock-to-out --
# that is the -5.9 to -1.8 step on hold. The multicycles are the rate and the
# offset, and they are still needed after it: a suggestion that the canonical
# derivation makes them unnecessary was tested and leaves setup at -11.983.
set_multicycle_path -setup 2 -from $sdram_launch -to [get_clocks SDRAM_CLK_out]
set_multicycle_path -hold  2 -from $sdram_launch -to [get_clocks SDRAM_CLK_out]
set_multicycle_path -setup 2 -from [get_clocks SDRAM_CLK_out] -to $sdram_launch
set_multicycle_path -hold  2 -from [get_clocks SDRAM_CLK_out] -to $sdram_launch

# Upstream 26eb46a: extra setup uncertainty for the FITTER only, on the clk_114
# domain, clk_sys -> clk_114 and the HDMI clock. It makes the fitter place
# those paths with margin; timing analysis (quartus_sta) does not see it, so
# the reported slack is still against the real constraints. Taken as upstream
# has it, with the SDRAM controller it was tuned for.
if {[string equal "quartus_fit" $::TimeQuestInfo(nameofexecutable)]} {
	set_clock_uncertainty -add -setup -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] 0.4
	set_clock_uncertainty -add -setup -from [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] 0.4
	set_clock_uncertainty -add -setup -from [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] -to [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}] 0.1
}
