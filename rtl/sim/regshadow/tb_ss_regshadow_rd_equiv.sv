// ss_regshadow's readback, registered end to end, against the version whose
// set/clear select was combinational on rd_addr (frozen as ss_regshadow_ref.v).
//
// Every output except rd_data is compared on every clock: the change must not
// touch the snoop, the load path or the replay. rd_data is compared on every
// clock where the registered read can be expected to agree -- rd_addr has not
// moved across the last edge and DMACON/INTENA/ADKCON did not change on it.
// That is the condition ss_ctrl's readback runs under: it holds the address for
// SS_HOLD_MAX+1 clk_114 cycles before it samples, and the machine is frozen, so
// nothing writes the three registers. Clocks where the read is NOT comparable
// are counted, so a bench that compares nothing cannot pass.
//
// Stimulus: random snoop writes biased to DMACON/INTENA/ADKCON and their
// neighbours, loads into the array and the WRITTEN mask, replays, and read
// addresses held 1-8 clocks, biased to the set/clear entries and the mask
// window.
`timescale 1ns/1ps
module tb_ss_regshadow_rd_equiv;

parameter CYCLES = 400000;

reg        clk = 0;
reg        clk7_en = 0;
reg        rst_n = 0;
reg  [8:1] reg_address_in = 0;
reg [15:0] data_in = 0;
reg  [8:0] rd_addr = 0;
reg        ld_we = 0;
reg  [8:0] ld_addr = 0;
reg [15:0] ld_data = 0;
reg        replay_start = 0;
reg [14:0] intreq_in = 0;

wire [15:0] d_rd_data,  r_rd_data;
wire        d_wr, r_wr, d_sc, r_sc;
wire        d_ra, r_ra, d_rwe, r_rwe, d_rdone, r_rdone;
wire  [8:1] d_raddr, r_raddr;
wire [15:0] d_rdata, r_rdata;

ss_regshadow dut (
	.clk(clk), .clk7_en(clk7_en), .rst_n(rst_n),
	.reg_address_in(reg_address_in), .data_in(data_in),
	.rd_addr(rd_addr), .rd_data(d_rd_data), .rd_writable(d_wr), .rd_setclear(d_sc),
	.ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
	.replay_start(replay_start), .intreq_in(intreq_in),
	.replay_active(d_ra), .replay_we(d_rwe), .replay_addr(d_raddr),
	.replay_data(d_rdata), .replay_done(d_rdone));

ss_regshadow_ref u_ref (
	.clk(clk), .clk7_en(clk7_en), .rst_n(rst_n),
	.reg_address_in(reg_address_in), .data_in(data_in),
	.rd_addr(rd_addr), .rd_data(r_rd_data), .rd_writable(r_wr), .rd_setclear(r_sc),
	.ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
	.replay_start(replay_start), .intreq_in(intreq_in),
	.replay_active(r_ra), .replay_we(r_rwe), .replay_addr(r_raddr),
	.replay_data(r_rdata), .replay_done(r_rdone));

always #5 clk = ~clk;

integer errors = 0;
integer cyc = 0;
integer n_sc = 0, n_sc_nz = 0, n_mask = 0, n_plain = 0, n_skip = 0, n_replay = 0;

function [7:0] pick_idx(input integer r);
	case (r % 8)
		0: pick_idx = 8'h4B;               // DMACON
		1: pick_idx = 8'h4D;               // INTENA
		2: pick_idx = 8'h4F;               // ADKCON
		3: pick_idx = 8'h4C;               // INTREQ, next door
		4: pick_idx = 8'h4E;
		default: pick_idx = $random;
	endcase
endfunction

// rd_addr and the three registers as the last edge saw them.
reg  [8:0] addr_at_edge;
reg [47:0] sc_at_edge;
wire [47:0] sc_now = {dut.r_dmacon, dut.r_intena, dut.r_adkcon};

integer hold = 0;
integer r;

initial begin
	repeat (4) @(posedge clk);
	#1 rst_n = 1;
	while (cyc < CYCLES) begin
		@(posedge clk);
		#1;
		cyc = cyc + 1;
		r = $random;

		clk7_en = ($random % 4) == 0;
		reg_address_in = pick_idx($random);
		data_in = $random;

		ld_we = ($random % 64) == 0;
		ld_addr = (($random % 4) == 0) ? {1'b1, 4'b0, 4'($random)} : {1'b0, pick_idx($random)};
		ld_data = $random;

		replay_start = !d_ra && (($random % 3000) == 0);
		intreq_in = $random;

		if (hold == 0) begin
			case ($urandom % 4)
				0, 1: rd_addr = {1'b0, pick_idx($random)};
				2:    rd_addr = {1'b1, 4'b0, 4'($random)};
				3:    rd_addr = $random;
			endcase
			hold = 1 + ($urandom % 8);
		end
		hold = hold - 1;

		// Occasional reset, to cover the registers' reset values too.
		if (($random % 20000) == 0) rst_n = 0;
		else rst_n = 1;
	end

	$display("compared: set/clear %0d (non-zero %0d), mask %0d, plain %0d; skipped %0d; replay clocks %0d",
	         n_sc, n_sc_nz, n_mask, n_plain, n_skip, n_replay);
	if (n_sc == 0 || n_sc_nz == 0 || n_mask == 0 || n_plain == 0 || n_skip == 0 || n_replay == 0) begin
		$display("FAIL: a coverage counter is zero");
		errors = errors + 1;
	end
	if (errors == 0) $display("RUN: PASS");
	else             $display("RUN: FAIL (%0d errors)", errors);
	$finish;
end

// Sample just before each edge: the values the edge is about to see.
always @(negedge clk) begin
	if ({d_wr, d_sc, d_ra, d_rwe, d_raddr, d_rdata, d_rdone} !==
	    {r_wr, r_sc, r_ra, r_rwe, r_raddr, r_rdata, r_rdone}) begin
		errors = errors + 1;
		if (errors < 10)
			$display("FAIL: cycle %0d: outputs other than rd_data differ", cyc);
	end
	if (d_ra) n_replay = n_replay + 1;

	if (rd_addr === addr_at_edge && sc_now === sc_at_edge) begin
		if (d_rd_data !== r_rd_data) begin
			errors = errors + 1;
			if (errors < 10)
				$display("FAIL: cycle %0d: rd_data at %03h dut %04h ref %04h",
				         cyc, rd_addr, d_rd_data, r_rd_data);
		end
		if (rd_addr[8])            n_mask = n_mask + 1;
		else if (r_sc) begin
			n_sc = n_sc + 1;
			if (r_rd_data != 0) n_sc_nz = n_sc_nz + 1;
		end
		else                       n_plain = n_plain + 1;
	end
	else n_skip = n_skip + 1;

	addr_at_edge = rd_addr;
	sc_at_edge   = sc_now;
end

endmodule
