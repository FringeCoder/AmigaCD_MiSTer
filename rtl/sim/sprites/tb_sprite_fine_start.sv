// AGA sprite fine horizontal start: SPRxCTL bit 4 (SH1, 70 ns) and bit 3
// (SH0, 35 ns) move the WHOLE sprite right by that much.
//
// 580bccd (upstream #260) delayed only the shift-register LOAD by those bits,
// while the shifter keeps stepping on its own fixed pixel grid. A load that
// lands on a shift step loses that step, so a lores sprite moved a whole
// 140 ns pixel instead of 35-105 ns, and its first pixel was cut short. A
// screen built from 64-pixel sprites side by side then shows a one-pixel
// transparent gap at every sprite edge -- the black columns on Flink's CD32
// title screen (hardware A/B 2026-10-18: reverting 580bccd removes them).
//
// The property: with SH = k (k clk28 steps of 35 ns), the serial output is
// the SH = 0 output delayed by exactly k clocks, cycle for cycle, in lores,
// hires and super hires sprite resolution, with SPRxCTL bit 0 clear and set.
// SH = 0 itself must not move, and OCS/ECS ignore the bits.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb_fine ../../amiga_clk.v ../../denise_sprites_shifter.v tb_sprite_fine_start.sv
//   vvp tb_fine

`timescale 1ns/1ps

module tb_sprite_fine_start;

	localparam [1:0] POS  = 2'b00;
	localparam [1:0] CTL  = 2'b01;
	localparam [1:0] DATA = 2'b10;
	localparam [1:0] DATB = 2'b11;

	localparam [7:0]  POS_VAL  = 8'h40;      // match column 0x80 | CTL bit 0
	localparam [15:0] PAT_A    = 16'hB5C3;   // no two neighbouring pixels alike
	localparam [15:0] PAT_B    = 16'h6E19;
	localparam integer LINE_LEN = 228;
	localparam integer WIN0     = 8'h7C;     // capture window, in hpos
	localparam integer NCAP     = 4 * 28;    // clk28 samples captured per line

	reg clk = 0;
	always #1 clk = ~clk;

	wire clk7_en, clk7n_en, c1, c3, cck;
	wire [9:0] eclk;
	amiga_clk clkgen (
		.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
		.c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .ce(1'b1), .reset_n(1'b1)
	);

	reg  [1:0] spres = 2'b00;
	reg        shift;
	always @(*) begin   // as denise_sprites.v
		case (spres)
			2'b11:   shift = 1'b1;
			2'b10:   shift = ~c1 ^ c3;
			default: shift = ~c1 & ~c3;
		endcase
	end

	reg [8:0] hpos = 0;
	always @(posedge clk) if (clk7_en) hpos <= (hpos == LINE_LEN - 1) ? 9'd0 : hpos + 9'd1;

	reg        aga = 1;
	reg        reset = 1;
	reg        aen = 0;
	reg  [1:0] address = 0;
	reg [15:0] data_in = 0;
	wire [1:0] sprdata;

	denise_sprites_shifter dut (
		.clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(reset),
		.aen(aen), .address(address), .hpos(hpos), .aga(aga),
		.fmode(16'h0000), .shift(shift), .chip48(48'h0),
		.data_in(data_in), .sprdata(sprdata), .attach()
	);

	// one register write, held across exactly one clk7_en edge
	task automatic wr(input [1:0] a, input [15:0] d);
		begin
			@(negedge clk); while (!clk7_en) @(negedge clk);
			aen = 1; address = a; data_in = d;
			@(negedge clk);
			aen = 0;
			repeat (4) @(negedge clk);
		end
	endtask

	reg [1:0] cap [0:3][0:NCAP-1];   // [SH][sample]

	// Program the sprite on line N, capture its output around the match on
	// line N+1, the same clk28 phase every time (counted from hpos == WIN0).
	task automatic run_line(input integer sh, input bit0);
		integer t;
		begin
			wait (hpos == 9'd2);
			wr(POS,  {8'h00, POS_VAL});
			wr(CTL,  {11'h000, sh[1:0], 2'b00, bit0});
			wr(DATB, PAT_B);
			wr(DATA, PAT_A);                 // arms the sprite
			wait (hpos == WIN0[8:0]);
			@(posedge clk); while (!clk7_en) @(posedge clk);
			for (t = 0; t < NCAP; t = t + 1) begin
				cap[sh][t] = sprdata;
				@(posedge clk);
			end
			wait (hpos == 9'd200);
		end
	endtask

	integer errors = 0, checks = 0;
	integer r, b, k, t, lit, a;
	reg [8*6-1:0] rname;

	initial begin
		repeat (20) @(posedge clk);
		reset = 0;
		for (a = 1; a >= 0; a = a - 1) begin
			aga = a;
			for (r = 0; r < 3; r = r + 1) begin
				spres = (r == 0) ? 2'b00 : (r == 1) ? 2'b10 : 2'b11;
				rname = (r == 0) ? "lores" : (r == 1) ? "hires" : "shres";
				for (b = 0; b < 2; b = b + 1) begin
					for (k = 0; k < 4; k = k + 1) run_line(k, b);

					lit = 0;
					for (t = 0; t < NCAP; t = t + 1) if (cap[0][t] != 2'b00) lit = lit + 1;
					checks = checks + 1;
					if (lit == 0) begin
						$display("FAIL %0s %0s bit0=%0d: SH=0 sprite never shows", a ? "AGA" : "ECS", rname, b);
						errors = errors + 1;
					end

					for (k = 1; k < 4; k = k + 1) begin : one_k
						integer bad, first, d;
						bad = 0; first = -1;
						d = a ? k : 0;           // OCS/ECS: the bits are ignored
						for (t = 3; t < NCAP; t = t + 1)
							if (cap[k][t] !== cap[0][t - d]) begin
								bad = bad + 1;
								if (first < 0) first = t;
							end
						checks = checks + 1;
						if (bad) begin
							$display("FAIL %0s %0s bit0=%0d SH=%0d: %0d samples differ from SH=0 delayed %0d clk (first at %0d)",
							         a ? "AGA" : "ECS", rname, b, k, bad, d, first);
							errors = errors + 1;
						end else
							$display("ok   %0s %0s bit0=%0d SH=%0d: SH=0 stream delayed %0d clk",
							         a ? "AGA" : "ECS", rname, b, k, d);
					end
				end
			end
		end
		$display("checks=%0d errors=%0d", checks, errors);
		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

endmodule
