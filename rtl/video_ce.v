// Pixel-clock enable for the video chain.
//
// This was four inline statements in AmigaCD.sv. It is a module so that it can
// be simulated, because it is the one place where getting the arithmetic wrong
// produces a picture of the right shape at the wrong rate -- which a fit
// report cannot see and a timing exception cannot cause.
//
// WHAT CHANGED AND WHY. CLK_VIDEO used to be clk_114, and the enable was a
// fractional divider sized for it: div is 4 bits, the pulse is div == 8, and an
// increment of 1 / 2 / 4 gives a period of 16 / 8 / 4 cycles, i.e. the Amiga's
// 7.09 / 14.19 / 28.375 MHz pixel rates out of 113.5 MHz.
//
// CLK_VIDEO is now clk_sys, 28.375 MHz, because carrying ascal's input side and
// the rest of the video front end on clk_114 cost the core's critical clock
// about 5 MHz of Fmax -- measured 115.53 MHz against 120.39 MHz with this moved
// across, at no change in ALMs, and clk_sys absorbed the work for nothing
// (34.63 MHz against 34.79 MHz). On three seeds that took the fit from one
// shipping build in three to three in three, and collapsed the spread of the
// worst-of-two slack from 0.78 ns to 0.061 ns.
//
// At 28.375 MHz the three rates need an enable of one cycle in four, one in
// two, and EVERY cycle. A fractional divider cannot produce the last of those:
// a modulus equal to the increment leaves div stuck where it started, so the
// enable would be stuck with it. So the divider covers the two slow rates and
// the full rate is a separate term. Keeping the same shape -- pulse at half the
// modulus, re-armed on the vs edge from the resolution seen during the frame --
// is deliberate: the arithmetic is what moved, not the behaviour.
//
// Checked against the old version in rtl/sim/videoce/tb_video_ce.sv: the two
// are run side by side on their respective clocks, from the same frames, and
// the enable counts per frame must agree for all three rates.

module video_ce
(
	// CLK_VIDEO, which is clk_sys: 28.375 MHz.
	input            clk,

	// The frame, as the old inline version saw it. vblank here is the composed
	// one from AmigaCD.sv (vbl | ~vs), not minimig's raw vertical blank.
	input            vs,
	input            hblank,
	input            vblank,

	// minimig's resolution bits, sampled over the active part of the frame:
	// [0] hires, [1] superhires.
	input      [1:0] res,

	// ~status[42] & ~scandoubler -- the OSD's "force 28 MHz" condition.
	input            force_28,

	output reg       ce_pix = 0
);

// Left uninitialised, exactly as the inline version left them: everything is
// armed by the first falling vs edge, and the bench waits for one before it
// counts anything.
reg [1:0] div;
reg [1:0] add;
reg [1:0] fs_res;
reg       full_rate;
reg       old_vs;

always @(posedge clk) begin
	div <= div + add;
	if (~hblank & ~vblank) fs_res <= fs_res | res;

	old_vs <= vs;
	if (old_vs & ~vs) begin
		fs_res    <= 2'b00;
		div       <= 2'b00;
		add       <= 2'd1;                       // 7.09 MHz,  one cycle in four
		full_rate <= 1'b0;
		if (fs_res[0]) add <= 2'd2;              // 14.19 MHz, one cycle in two
		if (fs_res[1] | force_28) full_rate <= 1'b1;   // 28.375 MHz, every cycle
	end

	ce_pix <= full_rate | (div[1] & ~div[0]);
end

endmodule
