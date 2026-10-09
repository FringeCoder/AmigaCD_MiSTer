// CD audio sample FIFO, fed by the HPS one 2352-byte sector at a time and
// drained at 44.1 kHz.
//
// A real CD32 has no buffer here: the drive clocks audio straight off the disc.
// This FIFO exists only to absorb the jitter of a software feeder, and every
// sample it holds is audio the guest hears later than a real drive would play
// it. So the default depth is the one the core has always had, and the deeper
// one is opt-in (the OSD's "CD32 audio buffer" row, via CTL_WR):
//
//   BIG=0  NORMAL  the HPS is asked for a sector while the FIFO holds at most
//                  1459 frames, so it never holds more than 2047 (~46 ms).
//   BIG=1  LARGE   asked while it holds at most 7603, never more than 8191
//                  (~186 ms). Rides out a much longer stall in the HPS main
//                  loop, at the cost of position reports running that much
//                  further ahead of what is audible.
//
// The storage is the large size in both modes; NORMAL only stops asking for
// data sooner.
//
// The 44.1 kHz enable is derived from clk_sys, and clk_sys is NOT one clock:
// pll_cfg in AmigaCD.sv retunes it to 28.37516 MHz for PAL and 28.63636 MHz
// for NTSC. With a single CLK_RATE an NTSC machine played CD audio 0.92% fast
// (about a sixth of a semitone sharp). NTSC selects the matching rate.
//
// Underrun handling. When the FIFO runs dry the output used to drop straight
// to zero, which turns even a one-sample starvation into a click. It now
// decays towards zero over a few milliseconds instead. A real drive never
// starves mid-track, so neither behaviour is "the hardware's"; the decay is
// simply the less audible artefact, and it is also what the end of every play
// does now (the last sample fades rather than steps).
//
// Diagnostics for the HPS, read through hps_ext's cdda class:
//   UNDERRUNS  sample periods spent starved after data had been flowing (wraps)
//   STARVES    times the FIFO went from holding data to empty (wraps). The end
//              of every play counts one; a gap mid-play counts one more.
//   FILL       frames currently held
module cdda #(parameter CLK_RATE_PAL = 28375160, parameter CLK_RATE_NTSC = 28636360)
(
	input             CLK,
	input             nRESET,

	input             NTSC,

	// Control word from the HPS: bit 0 = BIG (latched), bit 1 = FLUSH (one-shot:
	// discard everything buffered, e.g. on STOP).
	input             CTL_WR,
	input      [15:0] CTL_DIN,

	output reg        WRITE_REQ,
	input             WRITE,
	input      [15:0] DIN,

	output reg        AUDIO_CE,
	output reg [15:0] AUDIO_L,
	output reg [15:0] AUDIO_R,

	output reg        BIG,
	output reg [15:0] UNDERRUNS,
	output reg [15:0] STARVES,
	output     [13:0] FILL
);

localparam SECTOR_SIZE  = 2352*8/32;                // 588 stereo frames
localparam BUFFER_WIDTH = 13;
localparam BUFFER_SIZE  = 2**BUFFER_WIDTH;          // 8192 frames
// Highest fill at which one more sector still fits. One slot is always left
// empty (WRITE_ADDR+1 == READ_ADDR means full), hence the -1.
localparam REQ_FILL_LARGE  = BUFFER_SIZE - 1 - SECTOR_SIZE;  // 7603
localparam REQ_FILL_NORMAL = 2048        - 1 - SECTOR_SIZE;  // 1459

reg         cen_44100;
reg  [31:0] cen_44100_cnt;
wire [31:0] clk_rate = NTSC ? CLK_RATE_NTSC : CLK_RATE_PAL;
wire [31:0] cen_44100_cnt_next = cen_44100_cnt + 44100;

always @(posedge CLK) begin
	cen_44100 <= 0;
	cen_44100_cnt <= cen_44100_cnt_next;
	if (cen_44100_cnt_next >= clk_rate) begin
		cen_44100 <= 1;
		cen_44100_cnt <= cen_44100_cnt_next - clk_rate;
	end
	AUDIO_CE <= cen_44100;
end

reg OLD_WRITE, LRCK, WR_REQ;

reg [15:0] DATA;

reg [BUFFER_WIDTH-1:0] READ_ADDR, WRITE_ADDR;

reg [31:0] BUFFER[BUFFER_SIZE];
reg [31:0] BUFFER_Q;

// Set once a sample has been played, cleared by the first starved period
// after it: marks the data -> empty edge that STARVES counts.
reg FLOWING;
// A starved run continues until data flows again or the HPS flushes. The run
// that ends a play keeps counting until then, which the HPS ignores because it
// re-baselines both counters at the start of every play.
reg UNDERRUNS_RUN;

assign FILL = {1'b0, WRITE_ADDR - READ_ADDR};

// One decay step towards zero: x - x/32, and straight to zero once |x| < 32
// (where x/32 rounds to nothing and the step would stall).
function [15:0] decay;
	input [15:0] x;
	begin
		if (&x[15:5] || ~|x[15:5]) decay = 16'd0;
		else                        decay = x - {{5{x[15]}}, x[15:5]};
	end
endfunction

always @(posedge CLK) begin
	if (~nRESET) begin
		OLD_WRITE  <= 0;
		LRCK       <= 0;
		READ_ADDR  <= 0;
		WRITE_ADDR <= 0;
		WR_REQ     <= 0;
		WRITE_REQ  <= 0;
		FLOWING    <= 0;
		AUDIO_L    <= 0;
		AUDIO_R    <= 0;
		UNDERRUNS  <= 0;
		STARVES    <= 0;
		UNDERRUNS_RUN <= 0;
		// The HPS rewrites BIG at every PLAY, so a reset in between costs
		// nothing.
		BIG        <= 0;
	end else begin

		WR_REQ <= 0;
		if(WR_REQ) WRITE_ADDR <= WRITE_ADDR + 1'b1;

		OLD_WRITE <= WRITE;
		if (~OLD_WRITE & WRITE) begin
			LRCK <= ~LRCK;
			if (~LRCK) DATA <= DIN;
			else if((WRITE_ADDR+1'd1) != READ_ADDR) WR_REQ <= 1;
		end

		if (cen_44100) begin
			if (READ_ADDR == WRITE_ADDR) begin
				AUDIO_L <= decay(AUDIO_L);
				AUDIO_R <= decay(AUDIO_R);
				if (FLOWING) STARVES <= STARVES + 1'd1;
				FLOWING <= 0;
				// Counted only within a run that followed data: an idle drive
				// is not underrunning.
				if (FLOWING || UNDERRUNS_RUN) UNDERRUNS <= UNDERRUNS + 1'd1;
				UNDERRUNS_RUN <= FLOWING || UNDERRUNS_RUN;
			end
			else begin
				AUDIO_L <= BUFFER_Q[15:0];
				AUDIO_R <= BUFFER_Q[31:16];
				READ_ADDR <= READ_ADDR + 1'd1;
				FLOWING <= 1;
				UNDERRUNS_RUN <= 0;
			end
		end

		if (CTL_WR) begin
			BIG <= CTL_DIN[0];
			if (CTL_DIN[1]) begin
				READ_ADDR <= WRITE_ADDR;
				LRCK      <= 0;
				FLOWING   <= 0;
				UNDERRUNS_RUN <= 0;
			end
		end

		WRITE_REQ <= (FILL <= (BIG ? REQ_FILL_LARGE : REQ_FILL_NORMAL));
	end
end

always @(posedge CLK) begin
	BUFFER_Q <= BUFFER[READ_ADDR];
	if (WR_REQ) BUFFER[WRITE_ADDR] <= {DIN,DATA};
end

endmodule
