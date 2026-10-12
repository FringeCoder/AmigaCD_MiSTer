// Which AT bit attaches a sprite pair: the odd sprite's, and only that one.
//
// vAmigaTS Denise/Sprites/attached/attached5 sets AT in the EVEN sprite's
// SPRxCTL only, for one row of four pairs; attached2 does the same for single
// pairs. The A500 OCS photographs of both, and the A500 ECS photograph of
// attached2, show those pairs as two ordinary 3-colour sprites. The core had
// attached them on OCS/ECS since 2015 ("attach for both odd and even attach
// bit (ECS feature)"), drawing 15-colour sprites where the hardware does not.
// vAmiga agrees with the photographs.
//
// AT is set through real SPRxCTL writes; the per-sprite pixel data is forced
// on the shifter outputs, so only the attach decision and the colour mux are
// under test. A pair with sprite data 01 (even) and 10 (odd) reads colour
// index {osprm, 10, 01} = $29 attached (osprm = 2, esprm = 1), and the even sprite's own colour
// {esprm, nn, 01} otherwise.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../denise_sprites.v ../../denise_sprites_shifter.v tb_sprite_attach.sv
//   vvp tb

`timescale 1ns/1ps

module tb_sprite_attach;

	reg        clk = 0, clk7_en = 0, reset = 1;
	reg        aga = 0;
	reg  [8:1] reg_address_in = 8'hFF;
	reg [15:0] data_in = 0;
	wire [7:0] nsprite, sprdata;
	integer    errors = 0;

	always #1 clk = ~clk;
	reg [1:0] ph = 0;
	always @(posedge clk) begin ph <= ph + 2'd1; clk7_en <= (ph == 2'd0); end

	denise_sprites dut (
		.clk(clk), .clk7_en(clk7_en), .reset(reset), .c1(1'b0), .c3(1'b0), .aga(aga),
		.reg_address_in(reg_address_in), .hpos(9'd0), .data_in(data_in), .chip48(48'd0),
		.sprena(1'b1), .esprm(4'h1), .osprm(4'h2), .spres(2'b00),
		.nsprite(nsprite), .sprdata(sprdata)
	);

	task automatic wr(input [8:0] a, input [15:0] d);
		begin
			@(negedge clk); reg_address_in = a[8:1]; data_in = d;
			@(posedge clk); while (!clk7_en) @(posedge clk);
			@(negedge clk); reg_address_in = 8'hFF;
		end
	endtask

	// SPRxCTL is at $142 + 8*n; AT is bit 7.
	task automatic set_at(input integer n, input at);
		wr(9'h142 + 8 * n, at ? 16'h0080 : 16'h0000);
	endtask

	task automatic check_pair(input integer p, input even_at, input odd_at, input want_attached);
		reg [7:0] want;
		begin
			set_at(2 * p, even_at);
			set_at(2 * p + 1, odd_at);
			case (p)
				0: begin force dut.sprdat0 = 2'b01; force dut.sprdat1 = 2'b10; end
				1: begin force dut.sprdat2 = 2'b01; force dut.sprdat3 = 2'b10; end
				2: begin force dut.sprdat4 = 2'b01; force dut.sprdat5 = 2'b10; end
				3: begin force dut.sprdat6 = 2'b01; force dut.sprdat7 = 2'b10; end
			endcase
			#1;
			want = want_attached ? 8'h29 : {4'h1, p[1:0], 2'b01};
			if (sprdata !== want) begin
				$display("FAIL %s pair %0d even AT %0d odd AT %0d: colour %02x, want %02x",
				         aga ? "AGA" : "ECS", p, even_at, odd_at, sprdata, want);
				errors = errors + 1;
			end else
				$display("ok   %s pair %0d even AT %0d odd AT %0d: %02x",
				         aga ? "AGA" : "ECS", p, even_at, odd_at, sprdata);
			case (p)
				0: begin release dut.sprdat0; release dut.sprdat1; end
				1: begin release dut.sprdat2; release dut.sprdat3; end
				2: begin release dut.sprdat4; release dut.sprdat5; end
				3: begin release dut.sprdat6; release dut.sprdat7; end
			endcase
		end
	endtask

	integer p, m;
	initial begin
		repeat (8) @(posedge clk); reset = 0; repeat (8) @(posedge clk);
		for (m = 0; m < 2; m = m + 1) begin
			aga = m;
			for (p = 0; p < 4; p = p + 1) begin
				check_pair(p, 0, 0, 0);
				check_pair(p, 1, 0, 0);   // even only: NOT attached (attached5 row 3)
				check_pair(p, 0, 1, 1);
				check_pair(p, 1, 1, 1);
			end
		end
		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

endmodule
