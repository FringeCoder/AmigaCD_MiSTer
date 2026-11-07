// tb_fmv_video.sv -- the FMV cartridge's picture (rtl/fmv/fmv_video.v and
// the line fetch in fmv_ddr.v) against FringeCoder/AmigaCD
// docs/fmv-contract.md v5, "The picture". Each check names the rule.
//
// The syncs are a short PAL-shaped raster (1816 clk_sys a line, as at 64 us,
// but 64 lines a frame to keep the run short). The DDR3 model has random
// waitrequest and read latency, and the two clocks are unrelated. The
// display registers are driven straight into fmv_video; that the update
// queue reaches them is tb_fmv.sv's check N.
//
// Run: iverilog -g2012 -o tbv ../../fmv/fmv_ddr.v ../../fmv/fmv_video.v
//      tb_fmv_video.sv && vvp -n tbv
`timescale 1ns/1ps

module tb_fmv_video;
	reg clk_sys = 0, clk_ddr = 0;
	always #17.6 clk_sys = ~clk_sys;    // ~28.4 MHz
	always #4.39 clk_ddr = ~clk_ddr;    // ~114 MHz

	// ---------------------------------------------------------- the raster
	localparam integer LINE = 1816, HS_LEN = 134, LINES = 64, VS_LINES = 3;
	reg     hsync_n = 1, vsync_n = 1;
	integer hc = 0, ln = 0;             // the bench's beam: clocks since hsync fell, line
	always @(posedge clk_sys) begin
		hc <= (hc == LINE - 1) ? 0 : hc + 1;
		if (hc == LINE - 1) ln <= (ln == LINES - 1) ? 0 : ln + 1;
		hsync_n <= !(hc == LINE - 1 || hc < HS_LEN - 1);
		if (hc == LINE - 1) vsync_n <= !(ln == LINES - 1 || ln < VS_LINES - 1);
	end
	// hsync_n falls on the edge that takes hc to 0, vsync_n with it on line 0:
	// so line 0 is the line that starts at the VSYNC edge, and the DUT's line
	// count is ln.

	// ---------------------------------------------------------- the DUT
	reg          on = 1;
	reg  [15:0] r_ctrl = 0, r_x = 0, r_y = 0, r_w = 0, r_h = 0, r_rg = 0, r_b = 0;
	wire [111:0] disp = {r_b, r_rg, r_h, r_w, r_y, r_x, r_ctrl};

	wire        freq_t, fhalf, lb_we;
	wire [28:0] faddr;
	wire  [6:0] fwords;
	wire  [7:0] lb_waddr;
	wire [63:0] lb_wdata;
	wire        show, key_all;
	wire [23:0] rgb;

	wire [28:0] m_address;
	wire  [7:0] m_burstcount, m_byteenable;
	wire        m_read, m_write;
	wire [63:0] m_writedata;
	reg  [63:0] m_readdata = 0;
	reg         m_readdatavalid = 0;
	reg         m_waitrequest = 1;

	fmv_video vid (
		.clk(clk_sys), .on(on), .disp(disp), .hsync_n(hsync_n), .vsync_n(vsync_n),
		.freq_t(freq_t), .faddr(faddr), .fwords(fwords), .fhalf(fhalf),
		.wclk(clk_ddr), .lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
		.show(show), .key_all(key_all), .rgb(rgb)
	);

	// fmv_ddr with nothing else to do: no events, no ROM/RAM, and an update
	// queue that reads empty (UQ_WPTR 0), so it polls between line fetches.
	fmv_ddr ddr (
		.clk(clk_ddr), .on(on),
		.ev_empty(1'b1), .ev_data(48'd0), .ev_rd(),
		.up_wr(), .up_data(), .up_full(1'b0),
		.mreq_t(1'b0), .maddr(19'd0), .mrw(1'b1), .mbe(2'b11), .mwdata(16'd0),
		.mack_t(), .mrdata(), .mfill(1'b0), .mline(),
		.freq_t(freq_t), .faddr(faddr), .fwords(fwords), .fhalf(fhalf),
		.lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
		.avl_address(m_address), .avl_burstcount(m_burstcount),
		.avl_read(m_read), .avl_write(m_write), .avl_writedata(m_writedata),
		.avl_byteenable(m_byteenable), .avl_readdata(m_readdata),
		.avl_readdatavalid(m_readdatavalid), .avl_waitrequest(m_waitrequest),
		.dbg_flags(), .dbg_polls(), .dbg_rvalid(), .dbg_dwell(),
		.dbg_uq_rd(), .dbg_uq_w(), .dbg_n()
	);

	// ------------------------------------------------------- DDR3 model
	// The frame area only (4 buffers x 512 KB), plus UQ_WPTR reading 0.
	localparam [28:0] FB = 29'h04E40000;
	function [15:0] pix(input integer b, input integer x, input integer y);
		pix = {b[1:0], y[6:0], x[6:0]} ^ 16'h5A5A;
	endfunction
	function [63:0] fbword(input [28:0] a);
		integer o, b, y, x;
		begin
			o = a - FB;
			b = o >> 16; y = (o >> 7) & 511; x = (o & 127) * 4;
			fbword = {pix(b, x + 3, y), pix(b, x + 2, y), pix(b, x + 1, y), pix(b, x, y)};
		end
	endfunction

	integer seed = 7;
	integer reqs = 0;                   // fetch requests made (toggles of freq_t)
	reg     freq_d = 0;
	always @(posedge clk_sys) begin
		freq_d <= freq_t;
		if (freq_t != freq_d) reqs = reqs + 1;
	end
	integer fb_beats = 0, fb_bursts = 0, max_burst = 0, bad_addr = 0;
	reg [28:0] rd_addr; reg [7:0] rd_left; integer rd_wait;
	reg        rd_busy = 0, rd_fb = 0;
	always @(posedge clk_ddr) begin
		m_waitrequest <= ($random(seed) & 3) == 0;
		m_readdatavalid <= 0;
		if (!m_waitrequest && m_read && !rd_busy) begin
			rd_busy <= 1; rd_addr <= m_address; rd_left <= m_burstcount;
			rd_fb <= (m_address >= FB);
			rd_wait <= 2 + ($random(seed) & 15);
			if (m_address >= FB) begin
				fb_bursts = fb_bursts + 1;
				if (m_burstcount > max_burst) max_burst = m_burstcount;
				if (m_address >= FB + 29'h10000) bad_addr = bad_addr + 1;
			end
		end
		if (rd_busy) begin
			if (rd_wait > 0) rd_wait <= rd_wait - 1;
			else begin
				m_readdatavalid <= 1;
				m_readdata <= rd_fb ? fbword(rd_addr) : 64'd0;
				if (rd_fb) fb_beats = fb_beats + 1;
				rd_addr <= rd_addr + 1;
				rd_left <= rd_left - 1;
				if (rd_left == 1) rd_busy <= 0;
				rd_wait <= $random(seed) & 1;
			end
		end
	end

	// ------------------------------------------------------------ checks
	integer fails = 0, checks = 0;
	task check(input ok, input [8*80-1:0] what);
		begin
			checks = checks + 1;
			if (!ok) begin fails = fails + 1; $display("FAIL %0s", what); end
		end
	endtask

	function [23:0] rgb888(input [15:0] p);
		rgb888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
	endfunction

	// The output lags the beam by LAG clocks (the fixed latency Main's
	// horizontal calibration takes up): display pixel d of a line is on rgb
	// from clock 2d + LAG to 2d + LAG + 1. Pinned here so a change to the
	// pipeline shows as a failure, not as a picture shifted on hardware.
	localparam integer LAG = 2;

	// Sample one frame: per line, every source pixel on all four of its
	// clocks, and the border on either side of the window.
	integer px_bad, px_n, bd_bad, bd_n, sh_bad, fr_beats;
	// Registers set before this are in the set displayed from once it
	// returns: a VSYNC edge has passed since.
	task latch;
		begin
			while (ln != LINES / 2) @(posedge clk_sys);
			while (!(ln == 1 && hc == 0)) @(posedge clk_sys);
		end
	endtask
	task sample_frame(input integer b, input integer blank);
		integer l, x, c, X, Y, W, H;
		reg [23:0] border, want;
		begin
			X = r_x; Y = r_y; W = r_w; H = r_h;
			border = {r_rg, r_b[7:0]};
			px_bad = 0; px_n = 0; bd_bad = 0; bd_n = 0; sh_bad = 0;
			// from the start of line 0; fetches counted over exactly this frame
			while (!(ln == 0 && hc == 0)) @(posedge clk_sys);
			fr_beats = fb_beats;
			for (l = 0; l < LINES; l = l + 1) begin
				for (c = 0; c < LINE; c = c + 1) begin
					@(negedge clk_sys);
					if (!show) sh_bad = sh_bad + 1;
					x = (c - LAG - 2 * X) / 4;
					if (l >= Y && l < Y + H && c >= 2 * X + LAG && c < 2 * X + LAG + 4 * W) begin
						// every one of the pixel's four clocks, so the lag is pinned
						begin
							want = blank ? border : rgb888(pix(b, x, l - Y));
							if (((c - LAG - 2 * X) % 4) == 1) px_n = px_n + 1;
							if (rgb !== want) begin
								if (px_bad < 4) $display("  line %0d px %0d: %h, want %h", l, x, rgb, want);
								px_bad = px_bad + 1;
							end
						end
					end else if (c > LAG + 2 && c < LINE - 2 &&
					             !(l >= Y && l < Y + H && c >= 2 * X + LAG - 1 && c < 2 * X + LAG + 4 * W + 1)) begin
						bd_n = bd_n + 1;
						if (rgb !== border) bd_bad = bd_bad + 1;
					end
					@(posedge clk_sys);
				end
			end
			fr_beats = fb_beats - fr_beats;
		end
	endtask

	integer b0, f0;
	initial begin
		r_x = 100; r_y = 10; r_w = 64; r_h = 20;
		r_rg = 16'h1234; r_b = 16'h0056;
		r_ctrl = 16'h0001;                   // ON, buffer 0
		// two frames to latch and fill
		repeat (2) begin
			while (!(ln == 1 && hc == 0)) @(posedge clk_sys);
			@(posedge clk_sys);
		end

		// A: the window shows its buffer's pixels, the rest the border
		b0 = fb_bursts; f0 = fb_beats;
		sample_frame(0, 0);
		check(px_n == 20 * 64 && px_bad == 0, "A.window pixels are the buffer's, RGB565 widened");
		check(bd_n > 0 && bd_bad == 0, "A.outside the window: the border colour");
		check(sh_bad == 0, "A.ON: the cartridge output is selected");
		// one fetch per window line, DISP_W/4 words, in bursts of at most 32
		check(fr_beats == 20 * 16, "B.each window line fetched once, DISP_W/4 words");
		check(bad_addr == 0, "B.buffer 0 is the only one read");

		// C: a full-width window (W = 352, 88 words, three bursts)
		r_w = 352; r_x = 60;
		latch;
		f0 = fb_beats;
		sample_frame(0, 0);
		check(px_n == 20 * 352 && px_bad == 0, "C.a 352-pixel window, fetched in three bursts");
		check(fr_beats == 20 * 88, "C.88 words a line");
		check(max_burst == 32, "C.bursts of at most 32 words");

		// D: BUF changes mid-frame; the frame being shown keeps buffer 0, the
		// next one shows buffer 1. No tearing.
		r_w = 64; r_x = 100;
		latch;
		fork
			sample_frame(0, 0);
			begin
				while (!(ln == 0 && hc == 0)) @(posedge clk_sys);
				while (!(ln == 15 && hc == 500)) @(posedge clk_sys);
				r_ctrl = 16'h0005;           // ON, buffer 1
			end
		join
		check(px_bad == 0, "D.a BUF change waits for VSYNC (this frame: buffer 0)");
		sample_frame(1, 0);
		check(px_n == 20 * 64 && px_bad == 0, "D.the next frame shows buffer 1");

		// E: BLANK fills the window with the border colour
		r_ctrl = 16'h0007;
		latch;
		sample_frame(1, 1);
		check(px_n > 0 && px_bad == 0, "E.BLANK: the window shows the border colour");

		// F: KEY_ALL
		r_ctrl = 16'h0015;
		latch;
		repeat (10) @(posedge clk_sys);
		check(key_all && show, "F.KEY_ALL selects the cartridge everywhere");

		// G: ON clear: not selected, nothing fetched
		r_ctrl = 16'h0004;
		latch;
		f0 = fb_bursts;
		latch;
		check(!show && !key_all, "G.ON clear: Denise's picture goes through");
		check(fb_bursts == f0, "G.ON clear: no fetches");

		// H: status[64] off overrides ON at once
		r_ctrl = 16'h0001;
		latch;
		repeat (10) @(posedge clk_sys);
		on = 0;
		repeat (3) @(posedge clk_sys);
		f0 = fb_bursts; b0 = reqs;
		check(!show, "H.off: not selected");
		while (!(ln == 30 && hc == 0)) @(posedge clk_sys);
		check(fb_bursts == f0, "H.off: no fetches");
		// and none requested either, or the first one would be served stale
		// the moment the board comes back on
		check(reqs == b0, "H.off: no fetch requested");

		$display("%0d checks, %0d failed", checks, fails);
		if (fails == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
		$finish;
	end

	initial begin
		#160_000_000;
		$display("FAIL timeout");
		$display("RUN: FAIL");
		$finish;
	end
endmodule
