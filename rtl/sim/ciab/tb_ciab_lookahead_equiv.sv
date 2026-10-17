// ciab now drives its port B pins from a register, portb_q, loaded every clock
// with what the pins will be -- the port expression applied to the next-state
// values of DDRB, PRB and both timers, plus amiga_clk's next eclk. The claim is
// that this changes nothing: every output of the module, port B included, is
// the same on every clock as the previous version, frozen here as ciab_ref.v
// (with its own frozen timers, cia_timera_ref.v / cia_timerb_ref.v).
//
// The timebase is the real amiga_clk, so eclk is the level-shaped E clock the
// core gives the CIAs and eclk_n is amiga_clk's own lookahead. Its ce is
// dropped and raised at random, the way the save-state freeze holds it.
//
// The CPU side is driven at random every clock, biased to the registers that
// reach port B: PRB, DDRB, the timer latches and both control registers, with
// PBON and OUTMODE set often so the timer outputs actually drive PB6 and PB7 in
// pulse and toggle mode, one-shot and continuous, and timer B in cascade.
// Reset is pulsed (the CIA's own and amiga_clk's asynchronous one), and the
// save-state load (ss_ld) fires with random data. Outputs are compared on every
// clock, reset included.
//
// The bench counts timer-driven port B changes, PRB-driven changes and ss_ld
// loads, and fails on zero, so a run that never exercised the lookahead cannot
// pass.
`timescale 1ns/1ns
module tb_ciab_lookahead_equiv;

reg clk = 0;
always #2 clk = ~clk;

// amiga_clk timebase, as AmigaCD.sv wires the Amiga's own copy.
reg        ce = 1, reset_n = 0;
wire       clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk, eclk_n;
amiga_clk tbase (
	.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
	.cck(cck), .eclk(eclk), .eclk_n(eclk_n), .ce(ce), .reset_n(reset_n));

reg        aen = 0, rd = 0, wr = 0, reset = 1, tick = 0, flag = 1, ss_ld = 0;
reg  [3:0] rs = 0;
reg  [7:0] data_in = 0;
reg  [5:0] porta_in = 6'h3F;
reg  [202:0] ss_ld_data = 0;

wire [7:0]   dout_d, dout_r, pb_d, pb_r;
wire         irq_d, irq_r;
wire [7:6]   pa_d, pa_r;
wire [202:0] ss_d, ss_r;

ciab dut (
	.clk(clk), .clk7_en(clk7_en), .aen(aen), .rd(rd), .wr(wr), .reset(reset),
	.rs(rs), .data_in(data_in), .data_out(dout_d), .tick(tick),
	.eclk(eclk[8]), .eclk_n(eclk_n[8]), .flag(flag), .irq(irq_d),
	.porta_in(porta_in), .porta_out(pa_d),
	.ss_state(ss_d), .ss_ld(ss_ld), .ss_ld_data(ss_ld_data), .portb_out(pb_d));

ciab_ref ref_i (
	.clk(clk), .clk7_en(clk7_en), .aen(aen), .rd(rd), .wr(wr), .reset(reset),
	.rs(rs), .data_in(data_in), .data_out(dout_r), .tick(tick),
	.eclk(eclk[8]), .flag(flag), .irq(irq_r),
	.porta_in(porta_in), .porta_out(pa_r),
	.ss_state(ss_r), .ss_ld(ss_ld), .ss_ld_data(ss_ld_data), .portb_out(pb_r));

integer cyc = 0, mism = 0, tmr_changes = 0, prb_changes = 0, loads = 0, i, k;
reg [7:0] pb_q;

always @(negedge clk) begin
	cyc = cyc + 1;
	if (pb_r !== pb_q) begin
		// a change on a timer-driven pin with PBON set, or on any other pin
		if ((ref_i.ta_pb_on && pb_r[6] !== pb_q[6]) || (ref_i.tb_pb_on && pb_r[7] !== pb_q[7]))
			tmr_changes = tmr_changes + 1;
		else
			prb_changes = prb_changes + 1;
	end
	pb_q = pb_r;
	if ({dout_d, pb_d, irq_d, pa_d, ss_d} !== {dout_r, pb_r, irq_r, pa_r, ss_r}) begin
		if (mism < 10)
			$display("MISMATCH cyc %0d: portb %h/%h dout %h/%h irq %b/%b ss %0s",
				cyc, pb_d, pb_r, dout_d, dout_r, irq_d, irq_r, (ss_d === ss_r) ? "same" : "DIFF");
		mism = mism + 1;
	end
end

// Registers that reach port B: 1 PRB, 3 DDRB, 4/5 TA lo/hi, 6/7 TB lo/hi,
// E CRA, F CRB. The rest still get some traffic.
function [3:0] pick_rs;
	input dummy;
	case ($urandom % 12)
		0, 1: pick_rs = 4'h1;
		2:    pick_rs = 4'h3;
		3:    pick_rs = 4'h4;
		4:    pick_rs = 4'h5;
		5:    pick_rs = 4'h6;
		6:    pick_rs = 4'h7;
		7, 8: pick_rs = 4'hE;
		9:    pick_rs = 4'hF;
		default: pick_rs = $urandom;
	endcase
endfunction

initial begin
	repeat (5) @(posedge clk);
	#1 reset_n = 1;
	repeat (40) @(posedge clk);
	#1 reset = 0;
	for (i = 0; i < 2000000; i = i + 1) begin
		@(posedge clk); #1;
		aen = 0; rd = 0; wr = 0; ss_ld = 0;
		if ($urandom % 6 == 0) begin
			aen = 1;
			rs  = pick_rs(0);
			wr  = ($urandom % 3 != 0);
			rd  = !wr;
			data_in = $urandom;
			// control registers: set PBON / OUTMODE often, keep timers running
			if (wr && (rs == 4'hE || rs == 4'hF)) begin
				data_in[1] = ($urandom % 3 != 0);   // PBON
				data_in[0] = ($urandom % 4 != 0);   // START
				data_in[4] = ($urandom % 8 == 0);   // LOAD strobe
			end
			// short timer periods so underflows come often
			if (wr && (rs == 4'h5 || rs == 4'h7)) data_in = $urandom % 3;
			if (wr && (rs == 4'h4 || rs == 4'h6)) data_in = $urandom % 16;
		end
		tick     = ($urandom % 50 == 0);
		flag     = ($urandom % 100 != 0);
		porta_in = $urandom;
		if ($urandom % 20000 == 0) begin
			ss_ld = 1;
			for (k = 0; k < 203; k = k + 32) ss_ld_data[k +: 32] = $urandom;
			loads = loads + 1;
		end
		if ($urandom % 50000 == 0) reset = 1;
		else if (reset && $urandom % 50 == 0) reset = 0;
		// amiga_clk's reset is asynchronous; pulse it mid-run, since eclk_n has
		// to model it as a level
		if ($urandom % 100000 == 0) begin reset_n = 0; @(posedge clk); #1 reset_n = 1; end
		// the freeze: hold the timebase now and then
		if ($urandom % 5000 == 0) ce = 0;
		else if (!ce && $urandom % 200 == 0) ce = 1;
	end
	repeat (10) @(posedge clk);
	$display("cycles %0d, timer-driven port B changes %0d, other port B changes %0d, ss loads %0d, mismatches %0d",
		cyc, tmr_changes, prb_changes, loads, mism);
	if (tmr_changes == 0) $display("FAIL: a timer never drove port B");
	if (prb_changes == 0) $display("FAIL: port B never changed otherwise");
	if (loads == 0)       $display("FAIL: no save-state load");
	if (mism == 0 && tmr_changes > 0 && prb_changes > 0 && loads > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
