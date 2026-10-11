// When the CIA's TOD alarm fires: on every change that makes TOD equal the
// alarm, whether a count, a TOD write or an alarm write made it -- once per
// match, not once per register write.
//
// Why: vAmigaTS CIA/TOD/todvice/0alarm and 1alarm (ported from the VICE TOD
// tests) photograph green on a real A500 and ran red on this core. Each pass
// sets TOD to 0:0:0 with the alarm already at 0:0:0, then lets TOD count, and
// expects two alarms per pass: one when the TODLO write makes TOD equal the
// alarm, and one from the 8520's carry bug, when the low 12 bits wrap from
// $FFF to $000 a count before the upper 12 bits catch up and TOD reads $000000
// for that one count. The core only compared on a count, so the first of the
// two never fired. vAmiga's TOD::checkIrq() and VICE do the same edge test on
// every write and every increment.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../cia_timerd.v tb_cia_tod_alarm.sv
//   vvp tb

`timescale 1ns/1ps

module tb_cia_tod_alarm;

	reg        clk = 0;
	reg        clk7_en = 0;
	reg        reset = 1;
	reg        wr = 0;
	reg        tlo = 0, tme = 0, thi = 0, tcr = 0;
	reg  [7:0] data_in = 0;
	reg        count = 0;
	wire [7:0] data_out;
	wire       irq;

	integer errors = 0;
	integer alarms = 0;

	always #1 clk = ~clk;

	reg [1:0] phase = 0;
	always @(posedge clk) begin
		phase   <= phase + 2'd1;
		clk7_en <= (phase == 2'd0);
	end

	cia_timerd dut (
		.clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
		.tlo(tlo), .tme(tme), .thi(thi), .tcr(tcr),
		.data_in(data_in), .data_out(data_out),
		.count(count), .irq(irq),
		.ss_state(), .ss_ld(1'b0), .ss_ld_data(75'd0)
	);

	// cia_int ORs irq into the ICR once per clk7_en, so that is what counts as
	// one alarm here too.
	always @(posedge clk) if (clk7_en && irq) alarms = alarms + 1;

	task automatic tick; begin @(posedge clk); while (!clk7_en) @(posedge clk); #0.1; end endtask

	task automatic write_reg(input integer which, input [7:0] d);
		begin
			tick;
			wr = 1; data_in = d;
			tlo = (which == 0); tme = (which == 1); thi = (which == 2); tcr = (which == 3);
			tick;
			wr = 0; tlo = 0; tme = 0; thi = 0; tcr = 0;
			tick;
		end
	endtask

	localparam LO = 0, MID = 1, HI = 2, CRB = 3;

	// One TOD count, the way ciab.v delivers it: a single clk7_en wide pulse,
	// with idle clocks after it so the delayed upper-byte carry lands.
	task automatic pulse;
		begin
			tick; count = 1; tick; count = 0; tick; tick;
		end
	endtask

	task automatic set_tod(input [23:0] v);
		begin
			write_reg(CRB, 8'h00);
			write_reg(HI,  v[23:16]);
			write_reg(MID, v[15:8]);
			write_reg(LO,  v[7:0]);
		end
	endtask

	task automatic check(input string what, input integer got, input integer want);
		begin
			if (got !== want) begin
				$display("FAIL %0s: %0d alarms, want %0d", what, got, want);
				errors = errors + 1;
			end else
				$display("ok   %0s: %0d alarms", what, got);
		end
	endtask

	integer pass, i, prev;

	initial begin
		repeat (8) tick;
		reset = 0;
		repeat (4) tick;

		// 1. A count that reaches the alarm fires once.
		set_tod(24'h000000);
		write_reg(CRB, 8'h80);
		write_reg(HI, 8'h00); write_reg(MID, 8'h01); write_reg(LO, 8'h23);
		write_reg(CRB, 8'h00);
		alarms = 0;
		for (i = 0; i < 'h200; i = i + 1) pulse;
		check("count reaches alarm $000123", alarms, 1);

		// 2. Writing an alarm equal to a stopped TOD fires once; writing the
		//    same value again does not fire again.
		write_reg(CRB, 8'h00);
		write_reg(HI, 8'h00);                      // stops the count
		write_reg(MID, 8'h05);
		alarms = 0;
		write_reg(CRB, 8'h80);
		write_reg(HI, 8'h00); write_reg(MID, 8'h05);
		prev = alarms;
		write_reg(LO, dut.tod[7:0]);               // now equal
		check("alarm write makes a match", alarms - prev, 1);
		prev = alarms;
		write_reg(LO, dut.tod[7:0]);
		check("same alarm written again", alarms - prev, 0);
		write_reg(CRB, 8'h00);
		write_reg(LO, 8'h00);                      // restart the count

		// 3. An alarm write that does not match does not fire.
		write_reg(CRB, 8'h80);
		alarms = 0;
		write_reg(HI, 8'h7f); write_reg(MID, 8'h00); write_reg(LO, 8'h00);
		check("non-matching alarm write", alarms, 0);

		// 4. 0alarm: TOD := 0 with the alarm at 0, then HI of the alarm
		//    rewritten, then $1E84 counts (25 frames of lines). Two alarms per
		//    pass: the TODLO write, and the carry bug at $000FFF -> $001000.
		write_reg(CRB, 8'h80);
		write_reg(HI, 8'h00); write_reg(MID, 8'h00); write_reg(LO, 8'h00);
		for (pass = 0; pass < 3; pass = pass + 1) begin
			alarms = 0;
			set_tod(24'h000000);
			write_reg(CRB, 8'h80);
			write_reg(HI, 8'h00);
			for (i = 0; i < 'h1E84; i = i + 1) pulse;
			check($sformatf("0alarm pass %0d", pass), alarms, 2);
		end

		// 5. 1alarm: the same with the whole alarm rewritten each pass.
		for (pass = 0; pass < 2; pass = pass + 1) begin
			alarms = 0;
			set_tod(24'h000000);
			write_reg(CRB, 8'h80);
			write_reg(HI, 8'h00); write_reg(MID, 8'h00); write_reg(LO, 8'h00);
			for (i = 0; i < 'h1E84; i = i + 1) pulse;
			check($sformatf("1alarm pass %0d", pass), alarms, 2);
		end

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

endmodule
