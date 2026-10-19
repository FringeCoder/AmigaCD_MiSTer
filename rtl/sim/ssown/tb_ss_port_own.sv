// ss_ctrl now hands AmigaCD.sv the SDRAM CPU port claim as a register of its
// own, port_own, loaded with freeze_n | peek_scan_d -- the next values of
// ss_quiesce's freeze and of peek_scan. To make those the registers' own logic
// rather than copies, freeze is loaded from freeze_n, and every assignment to
// peek_scan in the FSM now goes through peek_scan_d, with peek_scan <=
// peek_scan_d at the end of the block.
//
// Two claims, both checked on every clock:
//   1. ss_ctrl is otherwise unchanged: every output equals the previous
//      version's (ss_ctrl_ref.v / ss_quiesce_ref.v, frozen copies).
//   2. port_own equals freeze | peek_scan, the OR it replaces in AmigaCD.sv.
//
// Stimulus is random on every input, shaped so the controller actually moves:
// save, load and peek requests now and then, the machine mostly quiet so the
// freeze is granted, sometimes busy so it is refused or times out (the frame
// limits are shrunk), DDR3 and SDRAM handshakes toggling at random, and resets.
// Long busy phases make the freeze time out and long SDRAM stalls make a peek
// scan time out. The bench counts freezes, peek scans, saves begun and both
// timeouts, and fails on zero.
//
// A third check backs the multicycle exception in AmigaCD.sdc from
// shadow_rd_addr into ss_ctrl: shadow_rd_data is combinational on that address
// (through ss_regshadow, on clk_sys), and ss_ctrl reads it in exactly two
// places, S_SHADOW_LOW's last hold cycle and S_SHADOW_Q. At every such read the
// address must have been stable for at least SH_MC clk_114 cycles, the
// multicycle the SDC grants. The bench reports the shortest it saw and fails if
// it is below SH_MC or if no read happened.
//
// The port lists were generated from ss_ctrl.v's header; a port added there
// breaks this build, which is the point.
`timescale 1ns/1ns
module tb_ss_port_own;

reg clk = 0, rst_n = 0;
always #4 clk = ~clk;

reg [28:0] slot_base = 0;
reg  save_req = 0;
wire  d_save_busy, r_save_busy;
wire  d_save_ok, r_save_ok;
wire  d_save_fail, r_save_fail;
reg  load_req = 0;
wire  d_load_busy, r_load_busy;
wire  d_load_ok, r_load_ok;
wire  d_load_fail, r_load_fail;
wire [3:0] d_load_fail_code, r_load_fail_code;
reg [64-1:0] state_in = 0;
wire [64-1:0] d_state_out, r_state_out;
wire  d_state_we, r_state_we;
reg  blit_busy = 0;
reg  disk_busy = 0;
reg  audio_busy = 0;
reg  cpu_boundary = 0;
reg  frame_tick = 0;
wire  d_freeze, r_freeze;
reg [24:1] chip_base = 0;
reg  fast_ena = 0;
reg [24:1] kick_base = 0;
wire  d_rom_scan, r_rom_scan;
wire  d_cache_flush, r_cache_flush;
wire  d_clut_active, r_clut_active;
wire [7:0] d_clut_addr, r_clut_addr;
reg [31:0] clut_rd_data = 0;
wire  d_clut_wr_en, r_clut_wr_en;
wire [31:0] d_clut_wr_data, r_clut_wr_data;
wire [8:0] d_shadow_rd_addr, r_shadow_rd_addr;
reg [15:0] shadow_rd_data = 0;
wire  d_shadow_ld_we, r_shadow_ld_we;
wire [8:0] d_shadow_ld_addr, r_shadow_ld_addr;
wire [15:0] d_shadow_ld_data, r_shadow_ld_data;
wire  d_replay_start, r_replay_start;
reg  replay_done = 0;
wire [24:1] d_sd_addr, r_sd_addr;
wire  d_sd_cs, r_sd_cs;
wire [1:0] d_sd_state, r_sd_state;
wire  d_sd_uds_n, r_sd_uds_n;
wire  d_sd_lds_n, r_sd_lds_n;
wire  d_sd_cache_inhibit, r_sd_cache_inhibit;
wire [15:0] d_sd_wr, r_sd_wr;
reg [15:0] sd_rd = 0;
reg  sd_ready = 0;
wire [28:0] d_ddr_address, r_ddr_address;
wire [63:0] d_ddr_writedata, r_ddr_writedata;
wire [7:0] d_ddr_byteenable, r_ddr_byteenable;
wire  d_ddr_write, r_ddr_write;
wire  d_ddr_read, r_ddr_read;
reg [63:0] ddr_readdata = 0;
reg  ddr_readdatavalid = 0;
reg  ddr_waitrequest = 0;
wire [5:0] d_dbg_state, r_dbg_state;
wire [23:0] d_dbg_idx, r_dbg_idx;
wire  d_dbg_kick_warn, r_dbg_kick_warn;
wire  d_dbg_kick_unstable, r_dbg_kick_unstable;
reg  peek_req = 0;
reg [24:1] peek_addr = 0;
wire [127:0] d_peek_data, r_peek_data;
wire  d_peek_valid, r_peek_valid;
wire  d_peek_busy, r_peek_busy;
wire  d_peek_scan, r_peek_scan;
wire  d_port_own;
reg [31:0] cpu_pc = 0;
wire [127:0] d_pc_snapshot, r_pc_snapshot;
wire [63:0] d_kick_pair, r_kick_pair;
wire [7:0] d_peek_acks, r_peek_acks;
wire  d_peek_timeout, r_peek_timeout;

localparam [7:0] FR = 8'd3;

ss_ctrl #(.SAVE_FRAMES(FR), .LOAD_FRAMES(FR), .SCAN_TIMEOUT(24'd300),
          .CHIP_WORDS(24'h40), .SLOW_WORDS(24'h20), .FAST_BEATS(24'h10),
          .KICK_WORDS(24'h40), .SHADOW_ENTRIES(9'd8)) dut (
	.clk(clk),
	.rst_n(rst_n),
	.slot_base(slot_base),
	.save_req(save_req),
	.save_busy(d_save_busy),
	.save_ok(d_save_ok),
	.save_fail(d_save_fail),
	.load_req(load_req),
	.load_busy(d_load_busy),
	.load_ok(d_load_ok),
	.load_fail(d_load_fail),
	.load_fail_code(d_load_fail_code),
	.state_in(state_in),
	.state_out(d_state_out),
	.state_we(d_state_we),
	.blit_busy(blit_busy),
	.disk_busy(disk_busy),
	.audio_busy(audio_busy),
	.cpu_boundary(cpu_boundary),
	.frame_tick(frame_tick),
	.freeze(d_freeze),
	.chip_base(chip_base),
	.fast_ena(fast_ena),
	.kick_base(kick_base),
	.rom_scan(d_rom_scan),
	.cache_flush(d_cache_flush),
	.clut_active(d_clut_active),
	.clut_addr(d_clut_addr),
	.clut_rd_data(clut_rd_data),
	.clut_wr_en(d_clut_wr_en),
	.clut_wr_data(d_clut_wr_data),
	.shadow_rd_addr(d_shadow_rd_addr),
	.shadow_rd_data(shadow_rd_data),
	.shadow_ld_we(d_shadow_ld_we),
	.shadow_ld_addr(d_shadow_ld_addr),
	.shadow_ld_data(d_shadow_ld_data),
	.replay_start(d_replay_start),
	.replay_done(replay_done),
	.sd_addr(d_sd_addr),
	.sd_cs(d_sd_cs),
	.sd_state(d_sd_state),
	.sd_uds_n(d_sd_uds_n),
	.sd_lds_n(d_sd_lds_n),
	.sd_cache_inhibit(d_sd_cache_inhibit),
	.sd_wr(d_sd_wr),
	.sd_rd(sd_rd),
	.sd_ready(sd_ready),
	.ddr_address(d_ddr_address),
	.ddr_writedata(d_ddr_writedata),
	.ddr_byteenable(d_ddr_byteenable),
	.ddr_write(d_ddr_write),
	.ddr_read(d_ddr_read),
	.ddr_readdata(ddr_readdata),
	.ddr_readdatavalid(ddr_readdatavalid),
	.ddr_waitrequest(ddr_waitrequest),
	.dbg_state(d_dbg_state),
	.dbg_idx(d_dbg_idx),
	.dbg_kick_warn(d_dbg_kick_warn),
	.dbg_kick_unstable(d_dbg_kick_unstable),
	.peek_req(peek_req),
	.peek_addr(peek_addr),
	.peek_data(d_peek_data),
	.peek_valid(d_peek_valid),
	.peek_busy(d_peek_busy),
	.peek_scan(d_peek_scan),
	.port_own(d_port_own),
	.cpu_pc(cpu_pc),
	.pc_snapshot(d_pc_snapshot),
	.kick_pair(d_kick_pair),
	.peek_acks(d_peek_acks),
	.peek_timeout(d_peek_timeout)
);

ss_ctrl_ref #(.SAVE_FRAMES(FR), .LOAD_FRAMES(FR), .SCAN_TIMEOUT(24'd300),
          .CHIP_WORDS(24'h40), .SLOW_WORDS(24'h20), .FAST_BEATS(24'h10),
          .KICK_WORDS(24'h40), .SHADOW_ENTRIES(9'd8)) ref_i (
	.clk(clk),
	.rst_n(rst_n),
	.slot_base(slot_base),
	.save_req(save_req),
	.save_busy(r_save_busy),
	.save_ok(r_save_ok),
	.save_fail(r_save_fail),
	.load_req(load_req),
	.load_busy(r_load_busy),
	.load_ok(r_load_ok),
	.load_fail(r_load_fail),
	.load_fail_code(r_load_fail_code),
	.state_in(state_in),
	.state_out(r_state_out),
	.state_we(r_state_we),
	.blit_busy(blit_busy),
	.disk_busy(disk_busy),
	.audio_busy(audio_busy),
	.cpu_boundary(cpu_boundary),
	.frame_tick(frame_tick),
	.freeze(r_freeze),
	.chip_base(chip_base),
	.fast_ena(fast_ena),
	.kick_base(kick_base),
	.rom_scan(r_rom_scan),
	.cache_flush(r_cache_flush),
	.clut_active(r_clut_active),
	.clut_addr(r_clut_addr),
	.clut_rd_data(clut_rd_data),
	.clut_wr_en(r_clut_wr_en),
	.clut_wr_data(r_clut_wr_data),
	.shadow_rd_addr(r_shadow_rd_addr),
	.shadow_rd_data(shadow_rd_data),
	.shadow_ld_we(r_shadow_ld_we),
	.shadow_ld_addr(r_shadow_ld_addr),
	.shadow_ld_data(r_shadow_ld_data),
	.replay_start(r_replay_start),
	.replay_done(replay_done),
	.sd_addr(r_sd_addr),
	.sd_cs(r_sd_cs),
	.sd_state(r_sd_state),
	.sd_uds_n(r_sd_uds_n),
	.sd_lds_n(r_sd_lds_n),
	.sd_cache_inhibit(r_sd_cache_inhibit),
	.sd_wr(r_sd_wr),
	.sd_rd(sd_rd),
	.sd_ready(sd_ready),
	.ddr_address(r_ddr_address),
	.ddr_writedata(r_ddr_writedata),
	.ddr_byteenable(r_ddr_byteenable),
	.ddr_write(r_ddr_write),
	.ddr_read(r_ddr_read),
	.ddr_readdata(ddr_readdata),
	.ddr_readdatavalid(ddr_readdatavalid),
	.ddr_waitrequest(ddr_waitrequest),
	.dbg_state(r_dbg_state),
	.dbg_idx(r_dbg_idx),
	.dbg_kick_warn(r_dbg_kick_warn),
	.dbg_kick_unstable(r_dbg_kick_unstable),
	.peek_req(peek_req),
	.peek_addr(peek_addr),
	.peek_data(r_peek_data),
	.peek_valid(r_peek_valid),
	.peek_busy(r_peek_busy),
	.peek_scan(r_peek_scan),
	.cpu_pc(cpu_pc),
	.pc_snapshot(r_pc_snapshot),
	.kick_pair(r_kick_pair),
	.peek_acks(r_peek_acks),
	.peek_timeout(r_peek_timeout)
);

wire [8191:0] outs_d = {d_save_busy, d_save_ok, d_save_fail, d_load_busy, d_load_ok, d_load_fail, d_load_fail_code, d_state_out, d_state_we, d_freeze, d_rom_scan, d_cache_flush, d_clut_active, d_clut_addr, d_clut_wr_en, d_clut_wr_data, d_shadow_rd_addr, d_shadow_ld_we, d_shadow_ld_addr, d_shadow_ld_data, d_replay_start, d_sd_addr, d_sd_cs, d_sd_state, d_sd_uds_n, d_sd_lds_n, d_sd_cache_inhibit, d_sd_wr, d_ddr_address, d_ddr_writedata, d_ddr_byteenable, d_ddr_write, d_ddr_read, d_dbg_state, d_dbg_idx, d_dbg_kick_warn, d_dbg_kick_unstable, d_peek_data, d_peek_valid, d_peek_busy, d_peek_scan, d_pc_snapshot, d_kick_pair, d_peek_acks, d_peek_timeout};
wire [8191:0] outs_r = {r_save_busy, r_save_ok, r_save_fail, r_load_busy, r_load_ok, r_load_fail, r_load_fail_code, r_state_out, r_state_we, r_freeze, r_rom_scan, r_cache_flush, r_clut_active, r_clut_addr, r_clut_wr_en, r_clut_wr_data, r_shadow_rd_addr, r_shadow_ld_we, r_shadow_ld_addr, r_shadow_ld_data, r_replay_start, r_sd_addr, r_sd_cs, r_sd_state, r_sd_uds_n, r_sd_lds_n, r_sd_cache_inhibit, r_sd_wr, r_ddr_address, r_ddr_writedata, r_ddr_byteenable, r_ddr_write, r_ddr_read, r_dbg_state, r_dbg_idx, r_dbg_kick_warn, r_dbg_kick_unstable, r_peek_data, r_peek_valid, r_peek_busy, r_peek_scan, r_pc_snapshot, r_kick_pair, r_peek_acks, r_peek_timeout};

integer cyc = 0, mism = 0, own_bad = 0, freezes = 0, scans = 0, saves = 0, qtimeouts = 0, ptimeouts = 0, i;
reg fz_q = 0, sc_q = 0, sb_q = 0, qt_q = 0, pt_q = 0;
// Phases: the machine busy for a long stretch (so the freeze times out) and the
// SDRAM port stalled (so a peek scan times out). Without them neither timeout
// is reached and the logic behind each goes untested.
reg busy_phase = 0, stall_phase = 0;
// Phase B (after the main loop): fast_ena moves on every clock, transfers
// included, the way an OSD ApplyConfiguration can move it under a running
// save. ss_ctrl now holds it for a whole transfer and the frozen copy does
// not, so the two are not compared there; instead the payload length must not
// change while a transfer is in progress.
reg phase_b = 0;
// the shadow readback's address age at each read, for the multicycle check
localparam integer SH_MC = 2;
integer sh_age = 0, sh_reads = 0, sh_min = 1000000, sh_bad = 0;
reg [8:0] sh_addr_q = 0;
integer len_bad = 0, len_moves = 0, b_xfers = 0;
reg [23:0] cw_q = 0;
reg        busy_q = 0;

always @(negedge clk) begin
	cyc = cyc + 1;
	if (ref_i.freeze & ~fz_q) freezes = freezes + 1;
	if (r_peek_scan & ~sc_q)  scans   = scans + 1;
	if (r_save_busy & ~sb_q)  saves   = saves + 1;
	if (ref_i.quiesce.timeout & ~qt_q) qtimeouts = qtimeouts + 1;
	if (r_peek_timeout & ~pt_q)        ptimeouts = ptimeouts + 1;
	fz_q = ref_i.freeze; sc_q = r_peek_scan; sb_q = r_save_busy;
	qt_q = ref_i.quiesce.timeout; pt_q = r_peek_timeout;
	// age counts the clocks the current shadow_rd_addr has been on the port,
	// including the one being sampled now
	if (dut.shadow_rd_addr !== sh_addr_q) sh_age = 1; else sh_age = sh_age + 1;
	sh_addr_q = dut.shadow_rd_addr;
	if ((dut.state == dut.S_SHADOW_LOW && dut.ss_hold == dut.SS_HOLD_MAX) ||
	    (dut.state == dut.S_SHADOW_Q && !dut.word_busy)) begin
		sh_reads = sh_reads + 1;
		if (sh_age < sh_min) sh_min = sh_age;
		if (sh_age < SH_MC) begin
			if (sh_bad < 10) $display("SHADOW cyc %0d: shadow_rd_data read %0d clock(s) after its address changed, under the SDC's multicycle of %0d", cyc, sh_age, SH_MC);
			sh_bad = sh_bad + 1;
		end
	end
	if (phase_b) begin
		if (dut.state != 0 && busy_q && dut.core_words !== cw_q) len_bad = len_bad + 1;
		if (dut.state != 0 && !busy_q) b_xfers = b_xfers + 1;
		if (dut.state != 0 && fast_ena !== dut.fast_ena_q) len_moves = len_moves + 1;
		busy_q = (dut.state != 0);
		cw_q   = dut.core_words;
	end
	else if (outs_d !== outs_r) begin
		if (mism < 10) $display("MISMATCH cyc %0d: an output differs from ss_ctrl_ref", cyc);
		mism = mism + 1;
	end
	if (!phase_b && d_port_own !== (ref_i.freeze | r_peek_scan)) begin
		if (own_bad < 10) $display("PORT_OWN cyc %0d: port_own %b, freeze|peek_scan %b", cyc, d_port_own, ref_i.freeze | r_peek_scan);
		own_bad = own_bad + 1;
	end
end

initial begin
	slot_base = 29'h0100000; chip_base = 0; kick_base = 24'h7C0000; peek_addr = 24'h000100;
	repeat (4) @(posedge clk);
	#1 rst_n = 1;
	for (i = 0; i < 1500000; i = i + 1) begin
		@(posedge clk); #1;
		save_req  = ($urandom % 3000 == 0);
		load_req  = ($urandom % 3000 == 0);
		peek_req  = ($urandom % 1500 == 0);
		if ($urandom % 20000 == 0) busy_phase = ~busy_phase;
		// end the busy stretch on the very clock a timeout lands now and then, so
		// the machine goes quiet while the request is still up
		if (ref_i.quiesce.timeout && ($urandom % 2)) busy_phase = 0;
		if ($urandom % 20000 == 0) stall_phase = ~stall_phase;
		blit_busy  = busy_phase | ($urandom % 8 == 0);
		disk_busy  = ($urandom % 16 == 0);
		audio_busy = ($urandom % 8 == 0);
		cpu_boundary = ($urandom % 4 != 0);
		frame_tick = ($urandom % 400 == 0);
		// only between transfers, and never on a clock a request is made, so
		// that ss_ctrl's held copy and the frozen copy's live one agree
		if (dut.state == 0 && !save_req && !load_req && !peek_req && $urandom % 50 == 0)
			fast_ena = ~fast_ena;
		sd_ready   = !stall_phase && ($urandom % 3 == 0);
		sd_rd      = $urandom;
		ddr_waitrequest   = ($urandom % 3 == 0);
		ddr_readdatavalid = ($urandom % 2 == 0);
		ddr_readdata      = {$urandom, $urandom};
		replay_done = ($urandom % 50 == 0);
		clut_rd_data = $urandom; shadow_rd_data = $urandom;
		state_in = {$urandom, $urandom};
		cpu_pc = $urandom;
		if ($urandom % 100 == 0) peek_addr = $urandom;
		if ($urandom % 200000 == 0) begin rst_n = 0; @(posedge clk); #1 rst_n = 1; end
	end
	repeat (10) @(posedge clk);
	#1 phase_b = 1;
	busy_phase = 0; stall_phase = 0;
	for (i = 0; i < 300000; i = i + 1) begin
		@(posedge clk); #1;
		save_req  = ($urandom % 3000 == 0);
		load_req  = ($urandom % 3000 == 0);
		blit_busy = 0; disk_busy = 0; audio_busy = 0;
		cpu_boundary = 1;
		frame_tick = ($urandom % 400 == 0);
		sd_ready  = ($urandom % 3 == 0);
		ddr_waitrequest   = ($urandom % 3 == 0);
		ddr_readdatavalid = ($urandom % 2 == 0);
		ddr_readdata      = {$urandom, $urandom};
		replay_done = ($urandom % 50 == 0);
		fast_ena  = ($urandom % 2);
	end
	repeat (10) @(posedge clk);
	$display("cycles %0d, freezes %0d, peek scans %0d, saves begun %0d, freeze timeouts %0d, peek timeouts %0d, output mismatches %0d, port_own mismatches %0d",
		cyc, freezes, scans, saves, qtimeouts, ptimeouts, mism, own_bad);
	$display("phase B: transfers %0d, clocks fast_ena differed from the held copy mid-transfer %0d, payload length changes mid-transfer %0d",
		b_xfers, len_moves, len_bad);
	$display("shadow readback: %0d reads, shortest address age %0d clocks (multicycle %0d), %0d under it", sh_reads, sh_min, SH_MC, sh_bad);
	if (sh_reads == 0) $display("FAIL: no save reached the shadow readback");
	if (b_xfers == 0 || len_moves == 0) $display("FAIL: phase B never moved fast_ena under a transfer");
	if (freezes == 0) $display("FAIL: never froze");
	if (scans == 0)   $display("FAIL: never scanned for a peek");
	if (saves == 0)   $display("FAIL: never began a save");
	if (qtimeouts == 0) $display("FAIL: the freeze never timed out");
	if (ptimeouts == 0) $display("FAIL: a peek scan never timed out");
	if (mism == 0 && own_bad == 0 && len_bad == 0 && sh_reads > 0 && sh_bad == 0 && b_xfers > 0 && len_moves > 0 &&
	    freezes > 0 && scans > 0 && saves > 0 && qtimeouts > 0 && ptimeouts > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
