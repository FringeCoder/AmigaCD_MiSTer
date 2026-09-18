// video_testpattern: the geometry.
//
// The whole value of this module is that its border lands on the FIRST and LAST
// active pixel and line -- that is what makes it a calibration target rather
// than decoration. So that is what this checks, against a known hde/vde
// geometry, by sampling the output at named coordinates.
//
// It cannot check what it looks like on a television. Nothing here can.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../video_testpattern.v tb_video_testpattern.sv
//   vvp tb

`timescale 1ns/1ps

module tb_video_testpattern;

// 60x30 rather than a power of two on purpose: with 64x32 the centre crosshair
// lands exactly on a grid line (32 and 16 are both grid multiples) and the two
// checks cannot tell each other apart. 60x30 puts the crosshair at 30 and 15,
// clear of the grid at 0/32 and 0/16.
localparam HACT = 60;   // active pixels per line
localparam HBL  = 16;   // blanked pixels per line
localparam VACT = 30;   // active lines per frame
localparam VBL  = 8;    // blanked lines per frame

reg clk = 0;
reg ce  = 1;            // every clk is a pixel here; the DUT gates on it anyway
reg hde = 0;
reg vde = 0;

wire [7:0] r, g, b;

video_testpattern dut (.clk(clk), .ce_pix(ce), .hde(hde), .vde(vde),
                       .r(r), .g(g), .b(b));

always #5 clk = ~clk;

integer fails = 0;

task check(input [255:0] name, input [7:0] got, input [7:0] want);
begin
	if (got === want) $display("ok:   %0s", name);
	else begin
		$display("FAIL: %0s -- got %02h want %02h", name, got, want);
		fails = fails + 1;
	end
end
endtask

// Sampled values, captured during the frame under test.
reg [7:0] s_topleft, s_topmid, s_leftmid, s_rightmid, s_botmid;
reg [7:0] s_interior, s_gridcol, s_gridrow, s_crossh, s_crossv;
reg [7:0] s_inside_r, s_inside_b, s_notgrid;

integer x, y, f;

initial begin
	// Three frames. The first measures, the second is the one with a complete
	// border -- hsize/vsize come from the previous line and frame by design --
	// and the third proves it is stable rather than a one-off.
	for (f = 0; f < 3; f = f + 1) begin
		vde = 1;
		for (y = 0; y < VACT; y = y + 1) begin
			hde = 1;
			for (x = 0; x < HACT; x = x + 1) begin
				@(posedge clk);
				#1;
				if (f == 2) begin
					// The DUT computes the pattern from the counter value BEFORE
					// this edge and registers it on the same edge, so after the
					// edge r holds the pattern for exactly (hcnt=x, vcnt=y).
					// There is no lag to compensate for. An earlier version of
					// this bench assumed one, and only the grid and crosshair
					// checks could tell -- the border checks pass either way,
					// which is what made the assumption survive.
					if (y == 1  && x == 5)              s_topleft  = r;
					if (y == 1  && x == HACT/2)         s_topmid   = r;
					if (y == 10 && x == 1)              s_leftmid  = r;
					if (y == 10 && x == HACT-1)         s_rightmid = r;
					if (y == VACT-1 && x == 5)          s_botmid   = r;
					// Interior: clear of border, grid and crosshair both ways.
					if (y == 10 && x == 5)              s_interior = r;
					if (y == 10 && x == 32)             s_gridcol  = r;  // hcnt[4:0]==0
					if (y == 16 && x == 5)              s_gridrow  = r;  // vcnt[3:0]==0
					if (y == 10 && x == HACT/2)         s_crossh   = r;  // hcnt==hsize>>1
					if (y == VACT/2 && x == 5)          s_crossv   = r;  // vcnt==vsize>>1
					// The borders are TWO pixels, so the third pixel in must be
					// dark. Without these the border could be any width from two
					// upwards and every other check would still pass -- which is
					// how a three-pixel right edge against a two-pixel left edge
					// survived the first version of this bench.
					if (y == 10 && x == HACT-3)         s_inside_r = r;
					if (y == VACT-3 && x == 5)          s_inside_b = r;
					// And the grid is every 32, not every 16. x==32 is a multiple
					// of both, so on its own it cannot tell the two apart.
					if (y == 10 && x == 16)             s_notgrid  = r;
				end
			end
			hde = 0;
			repeat (HBL) @(posedge clk);
		end
		vde = 0;
		repeat (VBL * (HACT + HBL)) @(posedge clk);
	end

	$display("");
	$display("measured hsize=%0d (expect %0d), vsize=%0d (expect %0d or %0d)",
	         dut.hsize, HACT, dut.vsize, VACT, VACT-1);
	if (dut.hsize !== HACT) begin
		$display("FAIL: active width mis-measured");
		fails = fails + 1;
	end
	// vsize may read one line short when vde falls on an hde fall; the module
	// documents that and the bench accepts either.
	if (dut.vsize !== VACT && dut.vsize !== VACT - 1) begin
		$display("FAIL: active height mis-measured");
		fails = fails + 1;
	end
	$display("");

	check("top edge lit",                s_topleft,  8'hFF);
	check("top edge lit at mid-line",    s_topmid,   8'hFF);
	check("left edge lit",               s_leftmid,  8'hFF);
	check("right edge lit",              s_rightmid, 8'hFF);
	check("bottom edge lit",             s_botmid,   8'hFF);
	check("interior is black",           s_interior, 8'h00);
	check("grid column is dim",          s_gridcol,  8'h40);
	check("grid row is dim",             s_gridrow,  8'h40);
	check("vertical crosshair is lit",   s_crossh,   8'hFF);
	check("horizontal crosshair is lit", s_crossv,   8'hFF);
	check("3rd pixel in from right dark", s_inside_r, 8'h00);
	check("3rd line in from bottom dark", s_inside_b, 8'h00);
	check("no grid line at 16",           s_notgrid,  8'h00);

	$display("");
	if (fails) begin
		$display("%0d FAILURE(S)", fails);
		$fatal(1);
	end
	$display("RUN: PASS");
	$finish;
end

endmodule
