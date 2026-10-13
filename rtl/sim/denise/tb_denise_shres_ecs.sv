// ECS super hires colour (denise_shres_ecs.v): every pixel value against the
// index rule, and every nibble against the sub-pixel average, as measured on an
// A500+ by vAmigaTS Denise/Modes/shres (shindex, sh1bpl, shramp, shsplit).
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../denise_shres_ecs.v tb_denise_shres_ecs.sv
//   vvp tb

`timescale 1ns/1ps

module tb_denise_shres_ecs;

	reg  [ 1:0] v;
	wire [ 7:0] index;
	reg  [23:0] rgb_in;
	wire [23:0] rgb_out;
	integer errors = 0, n, want, got;

	denise_shres_ecs dut (.v(v), .index(index), .rgb_in(rgb_in), .rgb_out(rgb_out));

	initial begin
		// Index: register 5 * v (shindex1-5); one plane is v1 = 0 (sh1bpl1-5).
		for (n = 0; n < 4; n = n + 1) begin
			v = n; #1;
			if (index !== 5 * n) begin
				$display("FAIL index v=%0d: %0d, want %0d", n, index, 5 * n); errors = errors + 1;
			end
		end
		// Value: nibble n shows at ((n>>2) + (n&3)) / 6 of full scale, on each
		// component independently. Checked against the real numbers, rounded.
		for (n = 0; n < 16; n = n + 1) begin
			rgb_in = {8'(n * 17), 8'((15 - n) * 17), 8'(n * 17)}; #1;
			want = ((n >> 2) + (n & 3)) * 255 / 6;
			got = rgb_out[23:16];
			if (got < want - 1 || got > want + 1 ||
			    rgb_out[7:0] !== rgb_out[23:16]) begin
				$display("FAIL nibble %0h: %0d, want ~%0d", n, rgb_out[23:16], want); errors = errors + 1;
			end
		end
		// The measured inversions: $3 brighter than $4, $7 than $8, $B than $C,
		// and $2, $5, $8 equal (shramp).
		rgb_in = {8'h33, 8'h44, 8'h00}; #1;
		if (!(rgb_out[23:16] > rgb_out[15:8])) begin $display("FAIL $3 > $4"); errors = errors + 1; end
		rgb_in = {8'h22, 8'h55, 8'h88}; #1;
		if (!(rgb_out[23:16] == rgb_out[15:8] && rgb_out[15:8] == rgb_out[7:0])) begin
			$display("FAIL $2 = $5 = $8"); errors = errors + 1;
		end
		// shsplit1: $C00 and $300 come out the same mid red.
		rgb_in = {8'hCC, 8'h00, 8'h00}; #1; want = rgb_out[23:16];
		rgb_in = {8'h33, 8'h00, 8'h00}; #1;
		if (rgb_out[23:16] !== want) begin $display("FAIL $C00 = $300"); errors = errors + 1; end
		// The anchors are untouched.
		rgb_in = 24'hFF0000; #1;
		if (rgb_out !== 24'hFF0000) begin $display("FAIL $F00 anchor"); errors = errors + 1; end

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

endmodule
