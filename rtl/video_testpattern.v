//////////////////////////////////////////////////////////////////////////////
// Screen calibration test pattern.
//
// A border, a centre crosshair and a grid, drawn from the core's own data
// enables so the border lands EXACTLY on the first and last active pixel and
// line. Adjust the screen position until all four border edges are visible on
// the display and the picture is both fully on screen and centred.
//
// WHY THIS HAS TO BE RTL. The obvious cheaper places were tried and do not
// work:
//
//   - The OSD or the info window is composited INSIDE the active area, so it
//     moves with the adjustment being made and can never show where the edges
//     are. (sys/osd.v also caps the info window at 504 pixels.)
//   - The HPS framebuffer REPLACES core video and is not subject to the core's
//     blanking at all, so a pattern drawn there says nothing about the window.
//
// Only something generated from hde/vde, in the video path, marks the real
// edges. That is this.
//
// It is muxed into r/g/b AHEAD of video_mixer rather than onto VGA_R/G/B after
// it, so the pattern travels the same scandoubler, hq2x and gamma path as real
// picture. A pattern that skipped that would be aligned to a geometry the
// actual picture does not have, which is worse than no pattern.
//////////////////////////////////////////////////////////////////////////////

module video_testpattern
(
	input        clk,       // CLK_VIDEO
	input        ce_pix,    // pixel enable, same one video_mixer is given
	input        hde,       // horizontal data enable, active high
	input        vde,       // vertical data enable, active high

	output [7:0] r,
	output [7:0] g,
	output [7:0] b
);

// Where we are inside the active area, and how big it was LAST time.
//
// The size has to come from the previous line and frame: the last active pixel
// is not knowable until hde falls, by which point it is too late to have drawn
// a border on it. Every line in a frame has the same width and every frame the
// same height, so a one-frame-old measurement is exact from the second frame
// on -- and the first frame after enabling draws no right or bottom edge, which
// is a flicker nobody will see at 50 Hz.
reg [11:0] hcnt  = 0;
reg [11:0] vcnt  = 0;
reg [11:0] hsize = 0;
reg [11:0] vsize = 0;

// At module scope rather than inside the block: that form needs SystemVerilog,
// and this file has no other reason to require it.
reg        old_hde = 0;
reg        old_vde = 0;

always @(posedge clk) begin
	if (ce_pix) begin
		if (hde) hcnt <= hcnt + 12'd1;

		// hde falling: the line just ended, so hcnt IS its active width. The
		// increment above does not fire on this cycle, so there is no race
		// between it and the reset.
		if (old_hde & ~hde) begin
			hsize <= hcnt;
			hcnt  <= 0;
			if (vde) vcnt <= vcnt + 12'd1;
		end

		// vde falling: same for the frame. When this coincides with an hde fall
		// the reset below wins over the increment above, so vsize can read one
		// line short. Left alone deliberately: one line at the bottom of a
		// border is not visible, and the alternative is an adder on this path
		// for nothing.
		if (old_vde & ~vde) begin
			vsize <= vcnt;
			vcnt  <= 0;
		end

		old_hde <= hde;
		old_vde <= vde;
	end
end

// Two pixels each side, guarded so a degenerate or not-yet-measured size cannot
// wrap the subtraction and light the whole line.
// hcnt takes 0 on the first active pixel (it increments after the compare) and
// hsize-1 on the last, so two pixels in from each edge is <=1 and >= hsize-2.
// This read hsize-3, which drew three on the right against two on the left --
// found by a bench check on the grid, not by looking at it.
wire left   = (hcnt <= 12'd1);
wire right  = (hsize >= 12'd4) && (hcnt  >= hsize - 12'd2);
wire top    = (vcnt <= 12'd1);
wire bottom = (vsize >= 12'd4) && (vcnt  >= vsize - 12'd2);

wire border = left | right | top | bottom;

// One pixel through the middle each way. Shifts, not division.
// Named crosshair, not cross: `cross` is a SystemVerilog keyword (covergroups)
// and this file is parsed with -g2012.
wire crosshair = (hcnt == (hsize >> 1)) | (vcnt == (vsize >> 1));

// Power-of-two spacing for the same reason. 32 across and 16 down is close to
// square on a PAL lores screen, which is what makes it useful for judging
// aspect as well as position.
wire grid   = (hcnt[4:0] == 5'd0) | (vcnt[3:0] == 4'd0);

// Registered, so the only thing this adds to video_mixer's input path is the
// selecting mux rather than the whole comparison tree.
//
// Greyscale on purpose: the question being asked is geometric, and a colour
// pattern invites reading it as a colour reference, which it is not -- it says
// nothing about levels, and the gamma stage downstream would make it lie if it
// did.
reg [7:0] v;
always @(posedge clk) if (ce_pix) begin
	v <= (border | crosshair) ? 8'hFF : grid ? 8'h40 : 8'h00;
end

assign r = v;
assign g = v;
assign b = v;

endmodule
