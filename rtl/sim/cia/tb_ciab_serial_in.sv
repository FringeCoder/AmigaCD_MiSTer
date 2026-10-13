// CIA-B serial input from the SP/CNT pins, which on the A500 are the parallel
// port's BUSY and POUT lines and also port A bits 0 and 1.
//
// vAmigaTS CIA/CIA/ser/ser1 makes PA0/PA1 outputs, puts CIA-B's serial port
// in input mode and writes a sequence of PRA values: PA1 is the clock (CNT),
// PA0 the data (SP). Eight rising edges of PA1 shift in $A5, MSB first, and an
// A500 reads $A5 back from SDR. The core never shifted in at all.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../ciab.v ../../cia_timera.v ../../cia_timerb.v //     ../../cia_int.v ../../cia_timerd.v tb_ciab_serial_in.sv
//   vvp tb

`timescale 1ns/1ps

module tb_ciab_serial_in;

	// CIA register selects.
	localparam [3:0] R_PRA  = 4'h0;
	localparam [3:0] R_PRB  = 4'h1;
	localparam [3:0] R_DDRB = 4'h3;
	localparam [3:0] R_TALO = 4'h4;
	localparam [3:0] R_TAHI = 4'h5;
	localparam [3:0] R_TBLO = 4'h6;
	localparam [3:0] R_TBHI = 4'h7;
	localparam [3:0] R_SDR  = 4'hC;
	localparam [3:0] R_ICR  = 4'hD;
	localparam [3:0] R_CRA  = 4'hE;
	localparam [3:0] R_CRB  = 4'hF;

	// Control register bits.
	localparam [7:0] CR_START   = 8'h01;
	localparam [7:0] CR_PBON    = 8'h02;
	localparam [7:0] CR_OUTMODE = 8'h04;
	localparam [7:0] CR_SPMODE  = 8'h40;

	reg        clk = 0;
	reg        clk7_en = 0;
	wire       eclk;
	reg        reset = 1;
	reg        aen_a = 0, aen_b = 0;
	reg        rd = 0, wr = 0;
	reg  [3:0] rs = 4'h0;
	reg  [7:0] data_in = 0;
	reg  [7:0] portb_in = 8'h00;
	reg  [5:0] porta_pins = 6'h3F;   // parallel port lines idle high

	wire [7:0] dout_a, dout_b;
	wire [7:0] portb_out_b;

	integer errors = 0;

	always #1 clk = ~clk;

	// clk7_en one in four; eclk one clk7_en in ten, which is the shape the
	// timers assume -- they decrement once per eclk under clk7_en.
	reg [1:0] phase = 0;
	reg [3:0] ediv  = 0;
	always @(posedge clk) begin
		phase   <= phase + 2'd1;
		clk7_en <= (phase == 2'd0);
	end
	// eclk must be high on the same cycle clk7_en is: the timers decrement
	// inside `if (clk7_en) ... else if (start && count)`, so an eclk that only
	// went high between clk7_en pulses would never be seen and no timer would
	// ever count.
	assign eclk = clk7_en && (ediv == 4'd9);
	always @(posedge clk)
		if (clk7_en) ediv <= (ediv == 4'd9) ? 4'd0 : ediv + 4'd1;


	ciab cb (
		.clk(clk), .clk7_en(clk7_en),
		.aen(aen_b), .rd(rd), .wr(wr), .reset(reset),
		.rs(rs), .data_in(data_in), .data_out(dout_b),
		.tick(1'b0), .eclk(eclk), .flag(1'b1), .irq(),
		.porta_in(porta_pins), .porta_out(),
		.ss_state(), .ss_ld(1'b0), .ss_ld_data(203'd0),
		.portb_out(portb_out_b)
	);

	// Bus access. Driven off the falling edge -- the CIAs sample on posedge with
	// clk7_en, and assigning at a posedge races the sampler.
	task wr_a(input [3:0] r, input [7:0] d);
		begin
			@(negedge clk);
			aen_a = 1; wr = 1; rd = 0; rs = r; data_in = d;
			@(posedge clk); while (!clk7_en) @(posedge clk);
			@(negedge clk);
			aen_a = 0; wr = 0; rs = 4'h0; data_in = 8'h00;
		end
	endtask

	task wr_b(input [3:0] r, input [7:0] d);
		begin
			@(negedge clk);
			aen_b = 1; wr = 1; rd = 0; rs = r; data_in = d;
			@(posedge clk); while (!clk7_en) @(posedge clk);
			@(negedge clk);
			aen_b = 0; wr = 0; rs = 4'h0; data_in = 8'h00;
		end
	endtask

	task rd_a(input [3:0] r, output [7:0] d);
		begin
			@(negedge clk);
			aen_a = 1; rd = 1; wr = 0; rs = r;
			@(posedge clk);
			#1;
			d = dout_a;
			@(negedge clk);
			aen_a = 0; rd = 0; rs = 4'h0;
		end
	endtask

task rd_b(input [3:0] r, output [7:0] d);
		begin
			// Hold the strobe across a clk7_en edge: that is when the CIA acts on
			// a read (an ICR read clears the flags then).
			repeat (8) @(posedge clk);           // let a flag raised by the last write land
			@(negedge clk);
			aen_b = 1; rd = 1; wr = 0; rs = r;
			@(negedge clk); while (!clk7_en) @(negedge clk);
			d = dout_b;                          // sampled before the edge acts on the read
			@(posedge clk);
			@(negedge clk);
			aen_b = 0; rd = 0; rs = 4'h0;
		end
	endtask

	task check(input [511:0] what, input [7:0] got, input [7:0] want);
		begin
			if (got !== want) begin
				$display("FAIL: %0s: got %02x want %02x", what, got, want);
				errors = errors + 1;
			end else begin
				$display("ok:   %0s = %02x", what, got);
			end
		end
	endtask


	localparam [3:0] R_DDRA = 4'h2;
	reg [7:0] v;
	integer i;

	// ser1's pulse train: PA1 = CNT, PA0 = SP. Rising PA1 edges latch PA0:
	// 1,0,1,0,0,1,0,1 = $A5.
	reg [7:0] ser1 [0:15];
	initial begin
		ser1[0]=8'h01; ser1[1]=8'h03; ser1[2]=8'h00; ser1[3]=8'h02;
		ser1[4]=8'h01; ser1[5]=8'h03; ser1[6]=8'h00; ser1[7]=8'h02;
		ser1[8]=8'h00; ser1[9]=8'h02; ser1[10]=8'h01; ser1[11]=8'h03;
		ser1[12]=8'h00; ser1[13]=8'h02; ser1[14]=8'h01; ser1[15]=8'h03;
	end

	initial begin
		repeat (20) @(posedge clk);
		reset = 0;
		repeat (20) @(posedge clk);

		// ---- 1. ser1: PA0/PA1 outputs, input mode ---------------------------
		wr_b(R_DDRA, 8'hFF);
		wr_b(R_CRA, 8'h40);
		wr_b(R_CRA, 8'h00);              // SP pin is input
		wr_b(R_SDR, 8'h00);
		wr_b(R_PRA, 8'h00);
		rd_b(R_ICR, v);                  // clear
		for (i = 0; i < 16; i = i + 1) wr_b(R_PRA, ser1[i]);
		rd_b(R_ICR, v);
		check("ser1: ICR SP flag after eight clocks", v & 8'h08, 8'h08);
		rd_b(R_SDR, v);
		check("ser1: SDR", v, 8'hA5);

		// ---- 2. seven clocks are not a byte ---------------------------------
		wr_b(R_SDR, 8'h00);
		rd_b(R_ICR, v);
		for (i = 0; i < 14; i = i + 1) wr_b(R_PRA, ser1[i]);
		rd_b(R_ICR, v);
		check("seven clocks: no SP flag", v & 8'h08, 8'h00);
		rd_b(R_SDR, v);
		check("seven clocks: SDR unchanged", v, 8'h00);
		wr_b(R_PRA, ser1[14]); wr_b(R_PRA, ser1[15]);   // eighth bit
		rd_b(R_SDR, v);
		check("eighth clock completes a byte", v, 8'hA5);

		// ---- 3. PA0/PA1 left as inputs: lines idle high, nothing shifts ------
		wr_b(R_DDRA, 8'h00);
		wr_b(R_SDR, 8'h00);
		rd_b(R_ICR, v);
		for (i = 0; i < 16; i = i + 1) wr_b(R_PRA, ser1[i]);
		rd_b(R_ICR, v);
		check("PA0/PA1 inputs: no SP flag", v & 8'h08, 8'h00);
		rd_b(R_SDR, v);
		check("PA0/PA1 inputs: SDR unchanged", v, 8'h00);

		// ---- 4. ...unless the parallel port itself clocks them ---------------
		for (i = 0; i < 16; i = i + 1) begin
			porta_pins = {4'hF, ser1[i][1:0]};
			repeat (12) @(posedge clk);
		end
		porta_pins = 6'h3F;
		rd_b(R_SDR, v);
		check("BUSY/POUT driven externally", v, 8'hA5);

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

endmodule
