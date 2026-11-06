// fmv_bus.v -- the CD32 FMV module, 68k side (clk_sys).
//
// Implements the FPGA half of FringeCoder/AmigaCD docs/fmv-contract.md (v3)
// as seen from the 68k bus: the register file both sides write, the 68k write
// masks, CL450 HMEM indirection, the INT line, the L64111 read acknowledge,
// the event stream to Main, back-pressure, autoconfig nibbles, and ROM/RAM
// requests to the DDR3 half. The DDR3 half (fmv_ddr.v) carries events out and
// updates in; fmv.v ties the two together.
//
// The reference this must match is FringeCoder/AmigaCD
// tests/fmv_fpga_ref.h; the bench is rtl/sim/fmv/tb_fmv.sv.
//
// Board offsets (cpu_addr[19:1], the board decodes 1 MB):
//   0x00000-0x3FFFF ROM      DDR3 image, read only
//   0x40000-0x4FFFF IO word  register file 0xA0
//   0x50000-0x5FFFF L64111   register file 0x80 + A[5:1]
//   0x60000-0x6FFFF CL450 data port (CMEM), write only: events
//   0x70000-0x7FFFF CL450    register file A[7:1]
//   0x80000-0xFFFFF RAM      DDR3 image
//
// The register file does NOT reset with the Amiga: ALIVE, the masks and the
// autoconfig nibbles must outlive it. An Amiga reset posts a RESET event and
// Main pushes the chips' reset values again.

module fmv_bus #(
	// The perf window, in clk_sys cycles: a quarter second at the PAL clock,
	// short enough that the access count cannot saturate (v28: 17 bits over
	// a second read 131071 on every line). A bench sets it shorter.
	parameter integer PERF_WINDOW = 7093790,     // a quarter of a second
	// The hold counts' unit: 2^PERF_SHIFT clk_sys. A bench sets it to 0.
	parameter integer PERF_SHIFT = 8
) (
	input  wire        clk,
	input  wire        amiga_reset,     // active high
	input  wire        fmv_on,          // status[64]

	// 68k bus, as minimig hands it to the A2065
	input  wire [23:1] cpu_addr,
	input  wire [15:0] cpu_data_in,
	output wire [15:0] cpu_data_out,    // 0 unless this board is read
	input  wire        cpu_rw,          // 1 = read
	input  wire        cpu_as_n,
	input  wire        cpu_uds_n,
	input  wire        cpu_lds_n,
	input  wire        sel,             // the board's 1 MB, decoded by gary
	output wire        nrdy,
	output wire        int2,

	// autoconfig (cpu_wrapper)
	output wire        ac_present,      // join the chain at the next reset
	input  wire  [5:0] ac_nib_addr,     // chip_addr[6:1]
	output wire  [3:0] ac_nib,

	// events to the DDR3 half: {data, haddr, offset, reset, lds, uds, rw}
	output reg         ev_wr = 1'b0,
	output reg  [47:0] ev_data,
	input  wire        ev_full,

	// updates from the DDR3 half: {rdidx, mask, value, guard, maskfile, index}
	input  wire        up_empty,
	input  wire [74:0] up_data,
	output reg         up_rd = 1'b0,

	// ROM/RAM requests to the DDR3 half (toggle handshake)
	output reg         mreq_t = 1'b0,
	output reg  [19:1] maddr,
	output reg         mrw,             // 1 = read
	output reg   [1:0] mbe,             // {UDS, LDS}
	output reg  [15:0] mwdata,
	input  wire        mack_t,          // toggles when the access is done
	input  wire [15:0] mrdata,
	output reg         mfill = 1'b0,    // this read is a ROM line fill (fmv_ddr)
	input  wire [255:0] mline,          // the line, beat 0 in 63:0

	output wire  [6:0] dbg,            // {int2, l64_int, cl_int, st, alive}, for the diag window
	output wire [111:0] disp,          // 0xE0-0xE6, the display registers (contract v5), 0xE0 lowest
	// Where the 68k's time on the board goes, per PERF_WINDOW, latched at the
	// end of each: {ram, rom, ring, fifo, held, accesses}, accesses 17 bits,
	// the five hold counts 15 bits each in units of 256 clk_sys (9 us). For
	// the diag window only (fmv.v; FMV_DIAG). Run v28: 35 % of the 68k's
	// second held on ROM/RAM, the driver running from the FMV ROM in DDR3;
	// rom and ram are split since, and rom includes the cache's own cycles.
	output reg  [91:0] perf = 92'd0
);

	// ---------------------------------------------------------------- state

	// The register file proper: CL450 0x00-0x7F, L64111 0x80-0x9F, IO 0xA0,
	// HMEM 0xB0-0xBF, as {mask, value}. 0x44 HOST_raddr and 0x48
	// HOST_control live in flops (rf_44, rf_48), as do 0xC0-0xDF.
	reg [31:0] rf [0:191];
	integer i;
	initial for (i = 0; i < 192; i = i + 1) rf[i] = 32'd0;

	reg [15:0] r44 = 16'h0000, m44 = 16'h0000;    // HOST_raddr
	reg [15:0] r48 = 16'h0080, m48 = 16'h0000;    // HOST_control: Int=1, INT inactive
	reg        alive     = 1'b0;                   // 0xC0[0]
	reg        l64_int   = 1'b0;                   // 0xC1[0]
	reg [15:0] rdidx_lo  = 16'h0000;               // 0xC2
	reg [15:0] rdidx_hi  = 16'h0000;               // 0xC3
	reg [15:0] io_map_cl = 16'h0000;               // 0xC4
	reg [15:0] io_map_l64 = 16'h0000;              // 0xC5
	reg [15:0] io_pol    = 16'h0000;               // 0xC6
	// 0xD0-0xDF as one vector, not an array: register r is bits 16r+15:16r,
	// so nibble n is bits 4n+3:4n. Quartus 17 infers an array as RAM and then
	// fails to map the random reads below to a read port (an internal error in
	// its Verilog frontend), so this stays plain flops.
	reg [255:0] autocfg = 256'd0;
	// 0xE0-0xE6, written by Main only; fmv_video latches them at VSYNC.
	reg [111:0] disp_r = 112'd0;
	assign disp = disp_r;

	reg [31:0] ev_count    = 32'd0;   // events posted, ever

	// ---- the perf window (see the perf port) ----
	reg [24:0] pw_t = 25'd0;
	reg [16:0] pw_acc = 17'd0;
	reg [31:0] pw_held = 32'd0, pw_fifo = 32'd0, pw_ring = 32'd0, pw_rom = 32'd0, pw_ram = 32'd0;
	reg [31:0] l64_ack_idx = 32'd0;
	reg        l64_acked   = 1'b0;

	wire cl_int = ~r48[7];                         // [CL 8-12]
	assign int2       = fmv_on & alive & (cl_int | l64_int);
	assign ac_present = fmv_on & alive;
	assign ac_nib = autocfg[{ac_nib_addr, 2'b00} +: 4];

	// ---------------------------------------------------------- the access

	wire        ds      = ~cpu_uds_n | ~cpu_lds_n;
	wire        access  = sel & ~cpu_as_n & ds & fmv_on;
	wire [19:0] off     = {cpu_addr[19:1], 1'b0};
	wire        is_rom  = (off[19:18] == 2'b00);
	wire        is_ram  =  off[19];
	wire        is_l64  = (off[19:16] == 4'h5);
	wire        is_cmem = (off[19:16] == 4'h6);
	wire        is_cl   = (off[19:16] == 4'h7);
	wire  [6:0] cl_r    = cpu_addr[7:1];           // CL450 register, byte offset / 2
	wire  [4:0] l64_r   = cpu_addr[5:1];
	wire [15:0] lanes   = {{8{~cpu_uds_n}}, {8{~cpu_lds_n}}};

	wire [15:0] backlog    = ev_count[15:0] - rdidx_lo;
	wire        ring_full  = (backlog >= 16'd4095);   // contract: low half, mod 2^16

	localparam S_IDLE = 4'd0, S_RD1 = 4'd1, S_RD2 = 4'd2, S_MEM = 4'd3,
	           S_POST = 4'd4, S_DONE = 4'd5, S_UP1 = 4'd6, S_UP2 = 4'd7,
	           S_CL1 = 4'd8, S_CL2 = 4'd9, S_FILL = 4'd10;
	reg  [3:0] st = S_IDLE;
	assign dbg = {int2, l64_int, cl_int, st[2:0], alive};

	// ---- the ROM cache ----
	// The FMV driver runs from the board ROM, which lives in DDR3, and in
	// run v28 the 68k spent 35 % of its time held on ROM/RAM: every fetch
	// the 68020's own cache missed was a DDR3 round trip. 4 KB here, direct
	// mapped, 128 lines of 32 bytes, filled by one 4-beat burst. ROM only:
	// Main writes the ROM once, before ALIVE, and never during a session,
	// while the board RAM holds the CL450's DRAM variables, which Main writes
	// into DDR3 at any time (fmv-contract.md), so a cached copy of RAM could
	// be stale. Emptied whenever status[64] is clear, so a session starts
	// with nothing from the last one's ROM.
	reg  [63:0] c_data [0:511];       // {line, word}
	reg   [5:0] c_tag  [0:127];       // board offset 17:12
	reg [127:0] c_valid = 128'd0;
	reg  [63:0] c_q;
	reg   [5:0] c_tq;
	reg   [1:0] c_k = 2'd0;           // fill: the word being written
	// Written through these, from a block of their own, as the register
	// file is: inside the state machine Quartus would not infer the M10Ks.
	reg         c_we = 1'b0, c_twe = 1'b0;
	reg   [8:0] c_wa;
	reg   [6:0] c_twa;
	reg  [63:0] c_wd;
	reg   [5:0] c_twd;

	reg  [7:0] idx;           // register-file index of the access or update
	reg        use_ff;        // the index lives in a flop, not the RAM
	reg [31:0] rf_q;          // registered RAM read
	reg [15:0] rd_val;        // what a read returns
	reg  [3:0] ev_haddr;
	reg [74:0] upd;
	reg        rst_d = 1'b0, rst_pend = 1'b0;
	reg        mack_s1 = 1'b0, mack_s2 = 1'b0, mack_s3 = 1'b0;

	// nrdy from the moment the access is seen until it is served, so an
	// access that arrives while an update is being applied cannot slip by.
	assign nrdy = access & (st != S_DONE);
	assign cpu_data_out = (sel & fmv_on & cpu_rw & (st == S_DONE)) ? rd_val : 16'h0000;

	always @(posedge clk) begin
		c_q  <= c_data[cpu_addr[11:3]];
		c_tq <= c_tag[cpu_addr[11:5]];
		if (c_we)  c_data[c_wa] <= c_wd;
		if (c_twe) c_tag[c_twa] <= c_twd;
	end
	wire       c_hit = c_valid[cpu_addr[11:5]] && c_tq == cpu_addr[17:12];
	wire [1:0] c_lane = cpu_addr[2:1];

	wire [7:0] acc_idx = is_cl  ? {1'b0, cl_r} :
	                     is_l64 ? {3'b100, l64_r} :
	                              8'hA0;
	wire       is_rdata = is_cl & (cl_r == 7'h46);
	wire [7:0] hm_idx   = {4'hB, r44[3:0]};

	// The IO word with the interrupt mirrors applied (contract, register file)
	function [15:0] io_view(input [15:0] v);
		reg [15:0] a;
		begin
			a = (v & ~io_map_cl)  | ((cl_int  ? io_pol : ~io_pol) & io_map_cl);
			io_view = (a & ~io_map_l64) | ((l64_int ? io_pol : ~io_pol) & io_map_l64);
		end
	endfunction

	// The flop registers a 68k access can reach: HOST_raddr and HOST_control.
	// (0xC0-0xDF have no 68k address.)
	wire [15:0] ff_q = (idx == 8'h44) ? r44 : r48;

	// The register file RAM: one read port, one registered write port, so
	// Quartus maps it to block RAM. The read address is the access's index,
	// or the update's while one is being applied (S_UP1); the data is in
	// rf_q a clock later. A write is issued from S_RD2 or S_UP2 and lands on
	// the next clock, before anything can read that entry again.
	wire [7:0] rf_ra = (st == S_UP1) ? upd[7:0] : idx;
	reg        rf_we = 1'b0;
	reg  [7:0] rf_wa;
	reg [31:0] rf_wd;
	always @(posedge clk) begin
		rf_q <= rf[rf_ra];
		if (rf_we)
			rf[rf_wa] <= rf_wd;
	end

	// update fields
	wire  [7:0] u_index    = upd[7:0];
	wire        u_maskfile = upd[8];
	wire        u_guard    = upd[9];
	wire [15:0] u_value    = upd[25:10];
	wire [15:0] u_mask     = upd[41:26];
	wire [31:0] u_rdidx    = upd[73:42];
	wire        u_drop     = u_guard & l64_acked & ($signed(u_rdidx - l64_ack_idx) <= 0);
	wire        u_ff       = (u_index == 8'h44) | (u_index == 8'h48) | (u_index >= 8'hC0);

	always @(posedge clk) begin
		ev_wr <= 1'b0;
		up_rd <= 1'b0;
		rf_we <= 1'b0;
		c_we  <= 1'b0;
		c_twe <= 1'b0;

		mack_s1 <= mack_t;
		mack_s2 <= mack_s1;
		mack_s3 <= mack_s2;

		// An Amiga reset while the board is on is an event (contract: RESET)
		rst_d <= amiga_reset;
		if (amiga_reset & ~rst_d & fmv_on & alive)
			rst_pend <= 1'b1;

		// Off, a session's counters stand at zero (contract v4): Main sets
		// status[64] only once it has zeroed the window's pointers, so both
		// sides start a session from 0 whatever DDR3 held before. ALIVE
		// drops with it; Main raises it again in the new session.
		if (!fmv_on) begin
			ev_count    <= 32'd0;
			rdidx_lo    <= 16'h0000;
			rdidx_hi    <= 16'h0000;
			l64_acked   <= 1'b0;
			l64_ack_idx <= 32'd0;
			l64_int     <= 1'b0;
			alive       <= 1'b0;
			rst_pend    <= 1'b0;
			c_valid     <= 128'd0;
		end

		case (st)
		S_IDLE: begin
			// An access is served when it can be. One that is held for room
			// in the ring or the crossing does NOT stop updates from being
			// applied: the update that releases it (HOST_RDIDX, from Main)
			// comes through the update queue. The first version applied
			// updates only with no access pending, so a held access blocked
			// its own release and the 68k hung for good, its INTEN off around
			// the driver's command (gate 1 run v20, 2026-11-04: PC 203cfe,
			// the read of HOST_newcmd, this state machine IDLE, up_full 1).
			if (access && (is_rom & cpu_rw | is_ram | (!ev_full && !ring_full))) begin
				ev_haddr <= 4'd0;
				if (is_rom & cpu_rw) begin
					// ROM read: the cache first (above). The DDR3 request
					// fields are set now for a miss.
					maddr  <= cpu_addr[19:1];
					mrw    <= 1'b1;
					mbe    <= 2'b11;
					mfill  <= 1'b1;
					st     <= S_CL1;
				end else if (is_ram) begin
					// RAM: a DDR3 access, not an event, and never cached
					maddr  <= cpu_addr[19:1];
					mrw    <= cpu_rw;
					mbe    <= {~cpu_uds_n, ~cpu_lds_n};
					mwdata <= cpu_data_in;
					mfill  <= 1'b0;
					mreq_t <= ~mreq_t;
					st     <= S_MEM;
				end else begin                    // room in the ring (above)
					if (is_rom | is_cmem) begin
						// A write into the ROM is dropped; the data port is
						// write-only and reads return 0xFFFF. Both are posted.
						rd_val <= 16'hFFFF;
						st     <= S_POST;
					end else begin
						idx    <= is_rdata ? hm_idx : acc_idx;
						use_ff <= ~is_rdata & ((acc_idx == 8'h44) | (acc_idx == 8'h48));
						if (is_rdata)
							ev_haddr <= r44[3:0];
						st <= S_RD1;
					end
				end
			end else if (rst_pend && !ev_full) begin
				ev_data  <= 48'h8;          // RESET, every other field 0
				ev_wr    <= 1'b1;
				ev_count <= ev_count + 1'd1;
				rst_pend <= 1'b0;
			end else if (!up_empty) begin
				// (also while an access is held: see above)
				up_rd <= 1'b1;
				if (fmv_on) begin
					upd <= up_data;
					st  <= S_UP1;
				end
				// off: a straggler from the last session is dropped
			end
		end

		S_RD1: begin                          // RAM read in flight (rf_ra = idx)
			st   <= S_RD2;
		end

		S_RD2: begin
			// A read returns the register; a write merges under the mask.
			if (cpu_rw) begin
				if (use_ff)
					rd_val <= ff_q;
				else if (idx == 8'hA0)
					rd_val <= io_view(rf_q[15:0]);
				else
					rd_val <= rf_q[15:0];
				if (idx == 8'h84 || idx == 8'h85) begin
					// Reading either L64111 status register deasserts INTR
					// [L64 4-9]; the ack index is this event's index.
					l64_int     <= 1'b0;
					l64_ack_idx <= ev_count;
					l64_acked   <= 1'b1;
				end
			end else begin
				if (idx == 8'h44)
					r44 <= (r44 & ~(m44 & lanes)) | (cpu_data_in & m44 & lanes);
				else if (idx == 8'h48)
					r48 <= (r48 & ~(m48 & lanes)) | (cpu_data_in & m48 & lanes);
				else begin
					rf_we <= 1'b1;
					rf_wa <= idx;
					rf_wd <= {rf_q[31:16],
					          (rf_q[15:0] & ~(rf_q[31:16] & lanes)) |
					          (cpu_data_in & rf_q[31:16] & lanes)};
				end
				// HOST_rdata: HAddr steps on after a write [CL 8-13]
				if (idx[7:4] == 4'hB)
					r44[3:0] <= r44[3:0] + 1'd1;
				rd_val <= 16'h0000;
			end
			st <= S_POST;
		end

		S_POST: begin
			// The event carries what the read returned, or the write data.
			ev_data <= {cpu_rw ? rd_val : cpu_data_in, 4'd0, ev_haddr, off, 1'b0,
			            ~cpu_lds_n, ~cpu_uds_n, cpu_rw};
			ev_wr    <= 1'b1;
			ev_count <= ev_count + 1'd1;
			st       <= S_DONE;
		end

		S_CL1: st <= S_CL2;                // the cache RAM read is in flight

		S_CL2: begin
			if (c_hit) begin
				rd_val <= {c_q[{c_lane, 4'd0} +: 8], c_q[{c_lane, 4'd8} +: 8]};
				st     <= S_DONE;
			end else begin
				mreq_t <= ~mreq_t;            // a line fill (mfill is set)
				st     <= S_MEM;
			end
		end

		S_MEM: begin
			if (mack_s2 != mack_s3) begin
				c_k <= 2'd0;
				st  <= mfill ? S_FILL : S_DONE;
			end
		end

		S_FILL: begin
			// mline has been stable since before mack_t toggled
			c_we  <= 1'b1;
			c_wa  <= {cpu_addr[11:5], c_k};
			c_wd  <= mline[{c_k, 6'd0} +: 64];
			c_k   <= c_k + 1'd1;
			if (c_k == 2'd3) begin
				c_twe <= 1'b1;
				c_twa <= cpu_addr[11:5];
				c_twd <= cpu_addr[17:12];
				c_valid[cpu_addr[11:5]] <= 1'b1;
				st <= S_DONE;
			end
		end

		S_DONE: begin
			if (!access)
				st <= S_IDLE;
		end

		S_UP1: begin                          // RAM read in flight (rf_ra = u_index)
			st   <= S_UP2;
		end

		S_UP2: begin
			if (u_maskfile) begin
				if (u_index == 8'h44)      m44 <= u_value;
				else if (u_index == 8'h48) m48 <= u_value;
				else if (!u_ff) begin
					rf_we <= 1'b1;
					rf_wa <= u_index;
					rf_wd <= {u_value, rf_q[15:0]};
				end
			end else if (!u_drop) begin
				case (u_index)
				8'h44: r44 <= (r44 & ~u_mask) | (u_value & u_mask);
				8'h48: r48 <= (r48 & ~u_mask) | (u_value & u_mask);
				8'hC0: alive   <= (alive   & ~u_mask[0]) | (u_value[0] & u_mask[0]);
				8'hC1: l64_int <= (l64_int & ~u_mask[0]) | (u_value[0] & u_mask[0]);
				8'hC2: rdidx_lo   <= (rdidx_lo   & ~u_mask) | (u_value & u_mask);
				8'hC3: rdidx_hi   <= (rdidx_hi   & ~u_mask) | (u_value & u_mask);
				8'hC4: io_map_cl  <= (io_map_cl  & ~u_mask) | (u_value & u_mask);
				8'hC5: io_map_l64 <= (io_map_l64 & ~u_mask) | (u_value & u_mask);
				8'hC6: io_pol     <= (io_pol     & ~u_mask) | (u_value & u_mask);
				default:
					if (u_index[7:4] == 4'hE && u_index[3:0] < 4'd7)
						disp_r[{u_index[2:0], 4'd0} +: 16] <=
							(disp_r[{u_index[2:0], 4'd0} +: 16] & ~u_mask) | (u_value & u_mask);
					else if (u_index[7:4] == 4'hD)
						autocfg[{u_index[3:0], 4'd0} +: 16] <=
							(autocfg[{u_index[3:0], 4'd0} +: 16] & ~u_mask) | (u_value & u_mask);
					else if (u_index < 8'hC0) begin
						rf_we <= 1'b1;
						rf_wa <= u_index;
						rf_wd <= {rf_q[31:16], (rf_q[15:0] & ~u_mask) | (u_value & u_mask)};
					end
				endcase
			end
			st <= S_IDLE;
		end
		endcase

		// A ROM/RAM read's data is taken as the access completes. fmv_ddr
		// holds mrdata from before it toggles mack_t, so it has been stable
		// for the two synchroniser stages by the time the edge is seen here.
		if (st == S_MEM && (mack_s2 != mack_s3) && mrw)
			rd_val <= mrdata;
	end

	// Counted from the outside of the state machine, so it cannot change
	// what the 68k sees: held is nrdy; fifo and ring are the two reasons
	// S_IDLE holds a ring-bound access; rom is a ROM read's time, cache and
	// fills; ram is a RAM access's DDR3 trip.
	wire ringbound = ~(is_rom & cpu_rw | is_ram);
	always @(posedge clk) begin
		if (pw_t == PERF_WINDOW - 1) begin
			pw_t    <= 25'd0;
			perf    <= {pw_ram[PERF_SHIFT +: 15], pw_rom[PERF_SHIFT +: 15], pw_ring[PERF_SHIFT +: 15],
			            pw_fifo[PERF_SHIFT +: 15], pw_held[PERF_SHIFT +: 15], pw_acc};
			pw_acc  <= 17'd0;
			pw_held <= 32'd0;
			pw_fifo <= 32'd0;
			pw_ring <= 32'd0;
			pw_rom  <= 32'd0;
			pw_ram  <= 32'd0;
		end else begin
			pw_t <= pw_t + 1'd1;
			if (access && st == S_IDLE && (is_rom & cpu_rw | is_ram | (!ev_full && !ring_full)) &&
			    ~&pw_acc)
				pw_acc <= pw_acc + 1'd1;
			if (nrdy)
				pw_held <= pw_held + 1'd1;
			if (access && st == S_IDLE && ringbound && ev_full)
				pw_fifo <= pw_fifo + 1'd1;
			if (access && st == S_IDLE && ringbound && !ev_full && ring_full)
				pw_ring <= pw_ring + 1'd1;
			if (st == S_CL1 || st == S_CL2 || st == S_FILL || (st == S_MEM && mfill))
				pw_rom <= pw_rom + 1'd1;
			if (st == S_MEM && !mfill)
				pw_ram <= pw_ram + 1'd1;
		end
	end
endmodule
