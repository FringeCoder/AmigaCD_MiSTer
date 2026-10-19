// tb_ss_load_equiv.sv -- ss_ctrl's restore refusals from registered flags,
// with ss_ctrl unchanged on every clock, through restores that succeed and
// restores refused at every gate.
//
// The worst paths of ss_ctrl's own family (L, docs/seed-lottery.md) were
// restore decisions: rd_data against SS_MAGIC / SS_VERSION / CORE_WORDS,
// hdr_length against MIN_LENGTH..MAX_LENGTH, kick_crc against file_kick_crc and
// crc_value against want_crc, each a 32-bit compare in front of the FSM's
// next-state logic and load_reject's fan-out. ss_ctrl now reads registered
// flags loaded with their operands (rd_*_bad, len_bad, kick_eq) and crc_eq
// from ss_crc32's next value.
//
// tb_ss_port_own drives ss_ctrl from random DDR3 data, so its restores stop at
// the magic word and never reach any of those decisions. This bench gives the
// DDR3 port a memory: what a save writes, a restore reads back. Each round is a
// save followed by a restore of that file, against the frozen previous version
// (ss_ctrl_ref.v, ss_crc32_ref.v) on identical inputs, every output compared on
// every clock. A round now and then damages the file between the two -- one
// payload bit (refused on the CRC), the magic, the version, the length (too
// short or too long) or core_words (each refused at its own gate) -- or changes
// the Kickstart image the scan reads (refused on the fingerprint). fast_ena
// moves between rounds, so both payload lengths are restored, and the DDR3 and
// SDRAM handshakes stall at random throughout.
//
// The bench also checks each flag against the compare it replaced:
// rd_magic_bad, rd_ver_bad and kick_eq on every clock once their operands have
// been written; the flags that follow CORE_WORDS in the states that read them;
// crc_eq on every CRC decision. It fails on zero completed restores with fast
// RAM on and off, and on zero refusals of any of the six kinds.
`timescale 1ns/1ns
module tb_ss_load_equiv;

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

// ---- comparison --------------------------------------------------------------
integer cyc = 0, mism = 0, flag_bad = 0, crc_decisions = 0, magic_checks = 0, len_checks = 0, kick_checks = 0;
always @(negedge clk) begin
	cyc = cyc + 1;
	if (outs_d !== outs_r) begin
		if (mism < 10) $display("MISMATCH cyc %0d: an output differs from ss_ctrl_ref (state %0d / %0d)", cyc, dut.state, ref_i.state);
		mism = mism + 1;
	end
	// rd_magic_bad and rd_ver_bad compare against constants, so they hold on
	// every clock once rd_data has been read. rd_cw_bad, rd_len_bad and
	// len_bad compare against CORE_WORDS / MIN_LENGTH, which follow fast_ena_q
	// and move in S_IDLE under a word read by an earlier restore, so they are
	// checked in the states that read them, S_L_LEN_CAP and S_L_LEN_CHK.
	// kick_eq holds on every clock once both fingerprints have been written,
	// crc_eq is checked where it is read.
	if (rst_n && ^dut.rd_data !== 1'bx &&
	    (dut.rd_magic_bad !== (dut.rd_data[31:0]  != dut.SS_MAGIC) ||
	     dut.rd_ver_bad   !== (dut.rd_data[63:32] != dut.SS_VERSION))) begin
		if (flag_bad < 10) $display("FLAG cyc %0d: rd_magic_bad / rd_ver_bad disagrees in state %0d", cyc, dut.state);
		flag_bad = flag_bad + 1;
	end
	if (dut.state == dut.S_L_LEN_CAP &&
	    dut.rd_len_bad !== ((dut.rd_data[63:32] < dut.MIN_LENGTH) || (dut.rd_data[63:32] > dut.MAX_LENGTH))) begin
		if (flag_bad < 10) $display("FLAG cyc %0d: rd_len_bad disagrees in S_L_LEN_CAP", cyc);
		flag_bad = flag_bad + 1;
	end
	if (dut.state == dut.S_L_LEN_CHK &&
	    (dut.len_bad   !== ((dut.hdr_length < dut.MIN_LENGTH) || (dut.hdr_length > dut.MAX_LENGTH)) ||
	     dut.rd_cw_bad !== (dut.rd_data[31:0] != dut.CORE_WORDS_32))) begin
		if (flag_bad < 10) $display("FLAG cyc %0d: len_bad / rd_cw_bad disagrees in S_L_LEN_CHK", cyc);
		flag_bad = flag_bad + 1;
	end
	if (rst_n && ^{dut.kick_crc, dut.file_kick_crc} !== 1'bx && dut.kick_eq !== (dut.kick_crc == dut.file_kick_crc)) begin
		if (flag_bad < 10) $display("FLAG cyc %0d: kick_eq disagrees with its compare in state %0d", cyc, dut.state);
		flag_bad = flag_bad + 1;
	end
	if (dut.state == dut.S_L_PAY_FETCH && dut.pay_idx == dut.CORE_WORDS_24 && !dut.crc_busy) begin
		crc_decisions = crc_decisions + 1;
		if (dut.crc_eq !== (dut.crc_value == dut.want_crc)) begin
			if (flag_bad < 10) $display("FLAG cyc %0d: crc_eq disagrees with its compare", cyc);
			flag_bad = flag_bad + 1;
		end
	end
	if (dut.state == dut.S_L_MAGIC)    magic_checks = magic_checks + 1;
	if (dut.state == dut.S_L_LEN_CHK)  len_checks   = len_checks + 1;
	if (dut.state == dut.S_L_KICK_CHK) kick_checks  = kick_checks + 1;
end

// ---- DDR3: a memory, with random stalls and read latency ---------------------
// The save touches two regions: its slot, and fast RAM's home in DDR3 at
// FAST_BASE, which it reads and a restore writes back. Anything else is an
// error the bench counts.
reg [63:0] slot_mem [0:4095];
reg [63:0] fast_mem [0:4095];
reg [28:0] rq [$];
integer    stray = 0;
localparam [28:0] FASTB = 29'h06000000;
function in_slot(input [28:0] a); in_slot = a >= slot_base && a < slot_base + 4096; endfunction
function in_fast(input [28:0] a); in_fast = a >= FASTB && a < FASTB + 4096; endfunction
reg        ddr_stall = 0;
integer    kseed = 1;
function [15:0] rom_word(input [24:1] a, input integer s);
	rom_word = (a[16:1] * 16'h9E37) ^ (a[24:17] * 8'h5B) ^ s[15:0];
endfunction

task automatic bus_cycle;
	reg [63:0] w;
	integer k;
	begin
		@(posedge clk); #1;
		// return a read accepted on an earlier edge (never the same one)
		ddr_readdatavalid = 0;
		if (rq.size() > 0 && ($urandom % 3 != 0)) begin
			ddr_readdatavalid = 1;
			ddr_readdata = in_slot(rq[0]) ? slot_mem[rq[0] - slot_base] :
			               in_fast(rq[0]) ? fast_mem[rq[0] - FASTB] : 64'd0;
			if (!in_slot(rq[0]) && !in_fast(rq[0])) stray = stray + 1;
			void'(rq.pop_front());
		end
		ddr_waitrequest = ddr_stall | ($urandom % 4 == 0);
		if (!ddr_waitrequest && r_ddr_write) begin
			w = in_slot(r_ddr_address) ? slot_mem[r_ddr_address - slot_base] :
			    in_fast(r_ddr_address) ? fast_mem[r_ddr_address - FASTB] : 64'd0;
			for (k = 0; k < 8; k = k + 1)
				if (r_ddr_byteenable[k]) w[8*k +: 8] = r_ddr_writedata[8*k +: 8];
			if (in_slot(r_ddr_address)) slot_mem[r_ddr_address - slot_base] = w;
			else if (in_fast(r_ddr_address)) fast_mem[r_ddr_address - FASTB] = w;
			else stray = stray + 1;
		end
		if (!ddr_waitrequest && r_ddr_read) rq.push_back(r_ddr_address);
		// SDRAM: the Kickstart image and chip RAM are a fixed function of the
		// address, so the save's fingerprint and the restore's agree unless
		// kseed moves between them
		sd_ready = ($urandom % 3 == 0);
		sd_rd    = rom_word(r_sd_addr, kseed);
		replay_done  = ($urandom % 50 == 0);
		frame_tick   = ($urandom % 400 == 0);
		clut_rd_data = $urandom; shadow_rd_data = $urandom;
		state_in     = {$urandom, $urandom};
		cpu_pc       = $urandom;
	end
endtask

// ---- rounds -----------------------------------------------------------------
integer rounds = 0, saves_ok = 0, loads_ok = 0, crc_fail = 0, kick_fail = 0, other_fail = 0;
integer magic_fail = 0, ver_fail = 0, len_fail = 0, len_short = 0, len_long = 0, cw_bad = 0;
integer dmg;
integer ok_fast = 0, ok_nofast = 0, n, hi;
reg     damage, rekick;
initial begin
	slot_base = 29'h0100000; chip_base = 0; kick_base = 24'h7C0000; peek_addr = 24'h000100;
	blit_busy = 0; disk_busy = 0; audio_busy = 0; cpu_boundary = 1;
	for (n = 0; n < 4096; n = n + 1) begin slot_mem[n] = 0; fast_mem[n] = {$urandom, $urandom}; end
	repeat (4) @(posedge clk);
	#1 rst_n = 1;
	for (rounds = 0; rounds < 120; rounds = rounds + 1) begin
		fast_ena = rounds % 3 == 1;
		kseed    = 1;
		repeat (20) bus_cycle;
		// save
		save_req = 1; bus_cycle; save_req = 0;
		n = 0;
		while (!r_save_busy && n < 100) begin bus_cycle; n = n + 1; end
		while (r_save_busy) bus_cycle;
		if (r_save_ok) saves_ok = saves_ok + 1;
		repeat (20) bus_cycle;
		// damage the file or the machine's ROM now and then. Slot beat 0 holds
		// words 0-1 (counter, length), beat 1 the magic and version, beat 2
		// core_words; the payload starts at beat 4.
		dmg    = $urandom % 12;
		damage = (dmg == 0 || dmg == 1);
		rekick = (dmg == 2 || dmg == 3);
		case (dmg)
		4: slot_mem[1][31:0]  = slot_mem[1][31:0]  ^ (32'd1 << ($urandom % 32));
		5: slot_mem[1][63:32] = slot_mem[1][63:32] ^ (32'd1 << ($urandom % 32));
		6: begin slot_mem[0][63:32] = slot_mem[0][63:32] - 32'd1 - ($urandom % 4); len_short = len_short + 1; end
		7: begin slot_mem[0][63:32] = 32'h300000 - 32'd1 + ($urandom % 3) * 32'h1000; len_long = len_long + 1; end
		8: begin slot_mem[2][31:0]  = slot_mem[2][31:0] ^ (32'd1 << ($urandom % 24)); cw_bad = cw_bad + 1; end
		default: ;
		endcase
		if (damage) begin
			// one bit of one payload word (the payload starts at slot word 4)
			hi = 4;
			for (n = 4; n < 4096; n = n + 1) if (slot_mem[n] !== 64'd0) hi = n;
			n = 4 + $urandom % (hi - 3);
			slot_mem[n] = slot_mem[n] ^ (64'd1 << ($urandom % 64));
		end
		if (rekick) kseed = 77;
		// restore it
		load_req = 1; bus_cycle; load_req = 0;
		n = 0;
		while (!r_load_busy && n < 100) begin bus_cycle; n = n + 1; end
		while (r_load_busy) bus_cycle;
		if (r_load_ok) begin
			loads_ok = loads_ok + 1;
			if (fast_ena) ok_fast = ok_fast + 1; else ok_nofast = ok_nofast + 1;
		end
		else if (r_load_fail && r_load_fail_code == 4'd4) crc_fail = crc_fail + 1;
		else if (r_load_fail && r_load_fail_code == 4'd5) kick_fail = kick_fail + 1;
		else if (r_load_fail && r_load_fail_code == 4'd1) magic_fail = magic_fail + 1;
		else if (r_load_fail && r_load_fail_code == 4'd2) ver_fail = ver_fail + 1;
		else if (r_load_fail && r_load_fail_code == 4'd3) len_fail = len_fail + 1;
		else other_fail = other_fail + 1;
		$display("round %0d fast %0d dmg %0d damage %0d rekick %0d: save_ok %0d load_ok %0d fail %0d code %0d",
			rounds, fast_ena, dmg, damage, rekick, r_save_ok, r_load_ok, r_load_fail, r_load_fail_code);
		if ($urandom % 20 == 0) begin rst_n = 0; bus_cycle; rst_n = 1; end
	end
	repeat (10) bus_cycle;
	$display("%0d rounds, %0d saves ok, %0d restores ok (%0d with fast RAM, %0d without); refusals: %0d magic, %0d version, %0d length (%0d short + %0d long + %0d core_words damaged), %0d CRC, %0d fingerprint, %0d other",
		rounds, saves_ok, loads_ok, ok_fast, ok_nofast, magic_fail, ver_fail, len_fail, len_short, len_long, cw_bad, crc_fail, kick_fail, other_fail);
	$display("%0d clocks, %0d output mismatches, %0d flag mismatches (%0d magic, %0d length, %0d fingerprint checks, %0d CRC decisions), %0d stray DDR3 accesses",
		cyc, mism, flag_bad, magic_checks, len_checks, kick_checks, crc_decisions, stray);
	if (mism == 0 && flag_bad == 0 && stray == 0 && crc_decisions > 0 && ok_fast > 0 && ok_nofast > 0 &&
	    crc_fail > 0 && kick_fail > 0 && magic_fail > 0 && ver_fail > 0 && len_short > 0 && len_long > 0 && cw_bad > 0 &&
	    len_fail >= len_short + len_long + cw_bad && other_fail == 0)
		$display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
