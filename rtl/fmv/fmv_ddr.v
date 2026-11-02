// fmv_ddr.v -- the CD32 FMV module, DDR3 side (DDRAM_CLK).
//
// The DDR3 half of FringeCoder/AmigaCD docs/fmv-contract.md (v3). One Avalon
// master, fixed priority:
//   1. ROM/RAM accesses from the 68k (it is waiting): a single beat in the
//      board image;
//   2. events from fmv_bus: the entry with SEQ at EV + (n & 4095), then
//      EV_WPTR = n + 1;
//   3. the update queue: poll UQ_WPTR; for each new entry read both words as
//      one burst, apply it only once its SEQ matches (a cross-port write can
//      land late), hand it to fmv_bus, and write UQ_RDPTR.
// Word addresses are 64-bit (DDRAM_ADDR); the window is ARM 0x27000000.
//
// Off (status[64] clear) there are no events and no queue polls, and both
// counters stand at 0 (contract v4): a session starts from zero on both
// sides, whatever the window held from before -- DDR3 is not cleared
// between core loads, and on 2026-11-02 the core and Main disagreed on
// where the queue was and the board never came alive.

module fmv_ddr (
	input  wire        clk,
	input  wire        on,          // status[64], from the 68k clock domain

	// events from fmv_bus (show-ahead FIFO read side)
	input  wire        ev_empty,
	input  wire [47:0] ev_data,
	output reg         ev_rd = 1'b0,

	// updates to fmv_bus (FIFO write side)
	output reg         up_wr = 1'b0,
	output reg  [74:0] up_data,
	input  wire        up_full,

	// ROM/RAM requests (toggle handshake from fmv_bus)
	input  wire        mreq_t,
	input  wire [19:1] maddr,
	input  wire        mrw,
	input  wire  [1:0] mbe,
	input  wire [15:0] mwdata,
	output reg         mack_t = 1'b0,
	output reg  [15:0] mrdata = 16'h0000,

	// Avalon master
	output reg  [28:0] avl_address,
	output reg   [7:0] avl_burstcount,
	output reg         avl_read  = 1'b0,
	output reg         avl_write = 1'b0,
	output reg  [63:0] avl_writedata,
	output reg   [7:0] avl_byteenable,
	input  wire [63:0] avl_readdata,
	input  wire        avl_readdatavalid,
	input  wire        avl_waitrequest,

	// For the diag window (fmv.v): what this side is doing, without DDR3.
	output wire [15:0] dbg_flags,     // {st, on, up_full, ev_empty, poll==0, read, write, waitrequest}
	output reg  [15:0] dbg_polls = 16'd0,   // UQ_WPTR reads accepted
	output reg  [15:0] dbg_rvalid = 16'd0,  // readdatavalid beats seen
	output reg  [15:0] dbg_dwell = 16'd0,   // clocks in the current state, saturating
	output wire [15:0] dbg_uq_rd,
	output wire [15:0] dbg_uq_w,
	output wire [15:0] dbg_n
);
	localparam [28:0] BASE     = 29'h04E00000;      // ARM 0x27000000 >> 3
	localparam [28:0] EV_WPTR  = BASE + 29'h20000;  // byte 0x100000
	localparam [28:0] UQ_RDPTR = BASE + 29'h20001;  // byte 0x100008
	localparam [28:0] UQ_WPTR  = BASE + 29'h20008;  // byte 0x100040
	localparam [28:0] UQ       = BASE + 29'h20200;  // byte 0x101000
	localparam [28:0] EV       = BASE + 29'h22000;  // byte 0x110000

	localparam POLL = 8'd127;    // ~1.1 us at 114 MHz between idle queue polls

	reg [31:0] n     = 32'd0;    // events written, ever
	reg [31:0] uq_rd = 32'd0;    // update entries applied, ever
	reg [31:0] uq_w  = 32'd0;    // UQ_WPTR as last read
	reg  [7:0] poll  = 8'd0;
	reg        mreq_s1 = 1'b0, mreq_s2 = 1'b0, mreq_seen = 1'b0;
	reg        on_s1 = 1'b0, on_s2 = 1'b0;
	reg [63:0] w0;
	reg  [1:0] k;                // 16-bit lane of a ROM/RAM access

	localparam S_IDLE = 4'd0, S_MRD = 4'd1, S_MRD_D = 4'd2, S_MWR = 4'd3,
	           S_EV = 4'd4, S_EVP = 4'd5, S_QW = 4'd6, S_QW_D = 4'd7,
	           S_QE = 4'd8, S_QE_D0 = 4'd9, S_QE_D1 = 4'd10, S_QP = 4'd11;
	reg  [3:0] st = S_IDLE;
	reg  [3:0] st_d = S_IDLE;

	assign dbg_flags = {4'd0, st, on_s2, up_full, ev_empty, poll == 8'd0,
	                    avl_read, avl_write, avl_waitrequest, 1'b0};
	assign dbg_uq_rd = uq_rd[15:0];
	assign dbg_uq_w  = uq_w[15:0];
	assign dbg_n     = n[15:0];
	always @(posedge clk) begin
		st_d <= st;
		if (st != st_d)            dbg_dwell <= 16'd0;
		else if (~&dbg_dwell)      dbg_dwell <= dbg_dwell + 1'd1;
		if (st == S_QW && !avl_waitrequest) dbg_polls <= dbg_polls + 1'd1;
		if (avl_readdatavalid)              dbg_rvalid <= dbg_rvalid + 1'd1;
	end

	always @(posedge clk) begin
		ev_rd <= 1'b0;
		up_wr <= 1'b0;
		mreq_s1 <= mreq_t;
		mreq_s2 <= mreq_s1;
		on_s1   <= on;
		on_s2   <= on_s1;
		if (poll != 8'd0)
			poll <= poll - 1'd1;

		case (st)
		S_IDLE: begin
			if (mreq_s2 != mreq_seen) begin
				mreq_seen      <= mreq_s2;
				k              <= maddr[2:1];
				avl_address    <= BASE + {10'd0, maddr[19:3]};
				avl_burstcount <= 8'd1;
				if (mrw) begin
					avl_read <= 1'b1;
					st       <= S_MRD;
				end else begin
					// Board byte o is DDR3 byte o; a 68k word is {o, o+1}
					avl_writedata  <= {4{mwdata[7:0], mwdata[15:8]}};
					avl_byteenable <= {mbe[0], mbe[1]} << {maddr[2:1], 1'b0};
					avl_write      <= 1'b1;
					st             <= S_MWR;
				end
			end else if (!on_s2) begin
				n     <= 32'd0;
				uq_rd <= 32'd0;
				uq_w  <= 32'd0;
				poll  <= 8'd0;
				ev_rd <= ~ev_empty;     // a straggler from the last session
			end else if (!ev_empty) begin
				avl_address    <= EV + {17'd0, n[11:0]};
				avl_burstcount <= 8'd1;
				avl_writedata  <= {n[15:0], ev_data};
				avl_byteenable <= 8'hFF;
				avl_write      <= 1'b1;
				st             <= S_EV;
			end else if (poll == 8'd0 && !up_full) begin
				avl_address    <= UQ_WPTR;
				avl_burstcount <= 8'd1;
				avl_read       <= 1'b1;
				st             <= S_QW;
			end
		end

		// ---- ROM/RAM ----
		S_MRD: if (!avl_waitrequest) begin avl_read <= 1'b0; st <= S_MRD_D; end
		S_MRD_D: if (avl_readdatavalid) begin
			mrdata <= {avl_readdata[{k, 4'd0} +: 8], avl_readdata[{k, 4'd8} +: 8]};
			mack_t <= ~mack_t;      // mrdata is set first; the toggle follows
			st     <= S_IDLE;
		end
		S_MWR: if (!avl_waitrequest) begin
			avl_write <= 1'b0;
			mack_t    <= ~mack_t;
			st        <= S_IDLE;
		end

		// ---- events ----
		S_EV: if (!avl_waitrequest) begin
			ev_rd          <= 1'b1;               // pop: the entry is written
			n              <= n + 1'd1;
			avl_address    <= EV_WPTR;
			avl_writedata  <= {32'd0, n + 1'd1};  // WPTR after the entry
			st             <= S_EVP;
		end
		S_EVP: if (!avl_waitrequest) begin
			avl_write <= 1'b0;
			st        <= S_IDLE;
		end

		// ---- the update queue ----
		S_QW: if (!avl_waitrequest) begin avl_read <= 1'b0; st <= S_QW_D; end
		S_QW_D: if (avl_readdatavalid) begin
			uq_w <= avl_readdata[31:0];
			if (avl_readdata[31:0] != uq_rd) begin
				avl_address    <= UQ + {18'd0, uq_rd[9:0], 1'b0};
				avl_burstcount <= 8'd2;
				avl_read       <= 1'b1;
				st             <= S_QE;
			end else begin
				poll <= POLL;
				st   <= S_IDLE;
			end
		end
		S_QE: if (!avl_waitrequest) begin avl_read <= 1'b0; st <= S_QE_D0; end
		S_QE_D0: if (avl_readdatavalid) begin w0 <= avl_readdata; st <= S_QE_D1; end
		S_QE_D1: if (avl_readdatavalid) begin
			if (w0[63:48] == uq_rd[15:0]) begin
				// {rdidx, mask, value, guard, maskfile, index}
				up_data <= {1'b0, avl_readdata[63:32], avl_readdata[31:16], avl_readdata[15:0],
				            w0[9], w0[8], w0[7:0]};
				up_wr   <= 1'b1;
				uq_rd   <= uq_rd + 1'd1;
				avl_address    <= UQ_RDPTR;
				avl_burstcount <= 8'd1;
				avl_writedata  <= {32'd0, uq_rd + 1'd1};
				avl_byteenable <= 8'hFF;
				avl_write      <= 1'b1;
				st             <= S_QP;
			end else begin
				// Not landed yet: try again at the next poll, never skip.
				poll <= POLL;
				st   <= S_IDLE;
			end
		end
		S_QP: if (!avl_waitrequest) begin
			avl_write <= 1'b0;
			st        <= S_IDLE;     // more entries: picked up at once (poll is 0)
		end
		default: st <= S_IDLE;
		endcase
	end
endmodule
