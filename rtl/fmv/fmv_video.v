// fmv_video.v -- the CD32 FMV cartridge's picture (FringeCoder/AmigaCD
// docs/fmv-plan.md phase 3; docs/fmv-contract.md v5, "The picture").
//
// The CL450 makes no syncs: it counts from the Amiga's HSYNC and VSYNC and
// puts out the decoded picture inside an output window, and the border
// colour everywhere else. This module does the same from the core's own
// _hsync/_vsync, with the picture taken from a frame buffer Main decodes
// into. The caller selects its output over Denise's where the genlock key
// (Denise's ZD) is asserted, or everywhere with KEY_ALL.
//
// In clk_sys (28 MHz, one super-hires pixel). A display pixel, the unit of
// DISP_X, is two clocks; a source pixel is shown for two display pixels.
// The output is two clocks behind the beam counter. That is a constant, and
// Main's horizontal calibration takes it up with the rest.
//
// Fetching: at each _HSYNC falling edge the next line's window row is
// requested from fmv_ddr (a toggle, with the fields held until the next
// one) into the half of the line buffer that line will read. A late fetch
// shows stale pixels; nothing here waits for DDR3.

module fmv_video (
	input  wire         clk,          // clk_sys
	input  wire         on,           // status[64]
	input  wire [111:0] disp,         // 0xE0-0xE6 from fmv_bus, 0xE0 in bits 15:0
	input  wire         hsync_n,
	input  wire         vsync_n,

	// line fetch requests, to fmv_ddr
	output reg          freq_t = 1'b0,
	output reg   [28:0] faddr  = 29'd0,
	output reg    [6:0] fwords = 7'd0,
	output reg          fhalf  = 1'b0,

	// line buffer writes, from fmv_ddr (its clock)
	input  wire         wclk,
	input  wire         lb_we,
	input  wire   [7:0] lb_waddr,     // {half, word}
	input  wire  [63:0] lb_wdata,

	output reg          show    = 1'b0,   // select this pixel where the key is asserted
	output reg          key_all = 1'b0,   // ... or everywhere
	output reg   [23:0] rgb     = 24'd0
);
	localparam [28:0] FB = 29'h04E40000;      // ARM 0x27200000 >> 3

	// ---- the set displayed from, latched at VSYNC (contract v5) ----
	reg [15:0] a_ctrl = 16'd0, a_x = 16'd0, a_y = 16'd0, a_w = 16'd0, a_h = 16'd0;
	reg [23:0] a_border = 24'd0;
	wire       a_on    = a_ctrl[0];
	wire       a_blank = a_ctrl[1];
	wire [1:0] a_buf   = a_ctrl[3:2];

	// ---- the beam, from the syncs ----
	reg        hs_d = 1'b1, vs_d = 1'b1;
	reg [11:0] hcnt = 12'd0;          // clk_sys since the _HSYNC falling edge
	reg  [9:0] line = 10'd0;          // _HSYNC falling edges since _VSYNC's
	wire       hs_fall = hs_d & ~hsync_n;
	wire       vs_fall = vs_d & ~vsync_n;

	// The line that starts now, and the one after it (fetched now).
	wire  [9:0] line_now = vs_fall ? 10'd0 : line + 1'd1;
	wire  [9:0] line_nxt = line_now + 1'd1;
	wire  [9:0] row_nxt  = line_nxt - a_y[9:0];
	wire        fetch    = on & a_on & (line_nxt >= a_y[9:0]) & (row_nxt < a_h[9:0]);

	always @(posedge clk) begin
		hs_d <= hsync_n;
		vs_d <= vsync_n;
		if (vs_fall) begin
			a_ctrl   <= disp[15:0];
			a_x      <= disp[31:16];
			a_y      <= disp[47:32];
			a_w      <= disp[63:48];
			a_h      <= disp[79:64];
			a_border <= {disp[95:80], disp[103:96]};
		end
		if (hs_fall) begin
			hcnt <= 12'd0;
			line <= line_now;
			if (fetch) begin
				faddr  <= FB + {11'd0, a_buf, 16'd0} + {12'd0, row_nxt, 7'd0};
				fwords <= a_w[8:2];
				fhalf  <= line_nxt[0];
				freq_t <= ~freq_t;
			end
		end else begin
			if (~&hcnt) hcnt <= hcnt + 1'd1;
			if (vs_fall) line <= 10'd0;   // mid-line, as in an interlaced field
		end
	end

	// ---- the line buffer: two rows of up to 96 words ----
	reg [63:0] lb [0:255];
	always @(posedge wclk)
		if (lb_we) lb[lb_waddr] <= lb_wdata;

	// ---- the pixel, two clocks after the beam ----
	wire [11:0] x2   = {a_x[10:0], 1'b0};             // window start, in clocks
	wire [11:0] rel  = hcnt - x2;                     // clocks into the window
	wire        in_h = (hcnt >= x2) & (rel < {a_w[9:0], 2'b00});
	wire        in_v = (line >= a_y[9:0]) & ((line - a_y[9:0]) < a_h[9:0]);

	reg  [63:0] q     = 64'd0;
	reg   [1:0] lane  = 2'd0;
	reg         inwin = 1'b0;
	always @(posedge clk) begin
		q     <= lb[{line[0], rel[10:4]}];
		lane  <= rel[3:2];
		inwin <= in_h & in_v;
	end

	wire [15:0] p = q[{lane, 4'd0} +: 16];
	always @(posedge clk) begin
		show    <= on & a_on;
		key_all <= on & a_on & a_ctrl[4];
		rgb     <= (inwin & ~a_blank) ? {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]}
		                              : a_border;
	end
endmodule
