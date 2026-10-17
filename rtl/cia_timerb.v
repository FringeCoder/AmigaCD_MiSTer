// CIA Timer B Module
// 16-bit down counter similar to Timer A but with cascade mode capability
// Can count system clock pulses or Timer A underflows
module cia_timerb
(
  input   clk,            // System clock
  input clk7_en,          // 7MHz clock enable for synchronization
  input  wr,              // Write enable signal
  input   reset,          // Synchronous reset

  // Register select signals from address decoder
  input   tlo,            // Timer low byte select ($x6)
  input  thi,             // Timer high byte select ($x7)
  input  tcr,             // Timer control register select ($xF)

  input   [7:0] data_in,  // CPU data bus input
  output   [7:0] data_out, // CPU data bus output
  input  eclk,            // External clock input (usually E clock)
  input  tmra_ovf,        // Timer A underflow signal for cascade mode
  output  irq,            // Timer underflow interrupt request

  // PB7 output, CRB bits 1 and 2. Same meaning as timer A's PB6.
  output  pb_on,
  output  pb_val,
  // Lookahead, as in cia_timera: the values after this clock edge.
  input   eclk_n,
  input   tmra_ovf_n,
  output  pb_on_n,
  output  pb_val_n,

  // Save state, laid out exactly as timer A's: {tmr, tmlh, tmll, tmcr}.
  // See cia_timera.v for why these are exported rather than read back.
  output [38:0] ss_state,
  input         ss_ld,
  input  [38:0] ss_ld_data
);

// Internal registers - similar structure to Timer A
reg    [15:0] tmr;        // 16-bit timer counter (counts down)
reg    [7:0] tmlh;        // Timer latch high byte (reload value)
reg    [7:0] tmll;        // Timer latch low byte (reload value)
reg    [6:0] tmcr;        // Timer control register
reg    forceload;         // Force load strobe signal
wire  oneshot;            // One-shot mode flag
wire  start;              // Timer start/stop control
reg    thi_load;          // Load timer when high byte written
wire  reload;             // Reload timer from latch
wire  zero;               // Timer reached zero
wire  underflow;          // Timer underflow condition
wire  count;              // Count enable signal

// Timer B special feature: can count Timer A underflows
// Control register bit 6 selects count source:
// 0 = Count system clock pulses (eclk)
// 1 = Count Timer A underflows (cascade mode)
assign count = tmcr[6] ? tmra_ovf : (eclk & start_delay[1]);

// Start-up delay, from upstream 2bddf21 "Fix Risky Woods SFX" (#253): the
// 8520 does not begin counting E-clocks the moment START is set, but two
// E-clocks later, which WinUAE also models. Ported WITHOUT the rest of that
// commit, which restores the CNT-pin count source -- CNT is not wired here
// (minimig.v drives cnt_in high), so that source stops the timer dead; see
// the "CIA count source is eclk" step in rtl-sim.yml.
//
// Not part of ss_state: a restore with START set comes back already past
// the delay, as the running timer it was saved from, not as one just started.
reg   [1:0] start_delay;

// Every register the port B pins depend on is written as `X <= X_n`, with X_n
// its next-state logic -- unchanged, only spelled as a wire -- so the lookahead
// outputs below are computed from the very logic that loads the registers,
// not from a copy of it that could drift.
wire [1:0] start_delay_n =
  ss_ld                     ? {2{ss_ld_data[0]}} :
  !clk7_en                  ? start_delay :
  reset                     ? 2'b00 :
  !start                    ? 2'b00 :
  (thi_load && oneshot)     ? 2'b00 :
  (tcr && wr && !data_in[0])? 2'b00 :
  eclk                      ? {start_delay[0],1'b1} :
                              start_delay;
always @(posedge clk) start_delay <= start_delay_n;

// Timer Control Register (CRB) bit definitions:
// Bit 0: START - Start/stop timer (1=start, 0=stop)
// Bit 1: PBON - drive PB7 from the timer instead of the port register
// Bit 2: OUTMODE - 0=pulse for one count on underflow, 1=toggle on underflow
// Bit 3: RUNMODE - 0=continuous, 1=one-shot
// Bit 4: LOAD - Force load timer from latch (strobe, write-only)
// Bit 5-6: INMODE - Count source:
//          00,01 = System clock
//          10,11 = Timer A underflow (cascade mode)
// Bit 7: ALARM - TOD clock write select (0=TOD, 1=ALARM)

// Write to control register
wire [6:0] tmcr_n =
  ss_ld                  ? ss_ld_data[6:0] :
  !clk7_en               ? tmcr[6:0] :
  reset                  ? 7'd0 :
  (tcr && wr)            ? {data_in[6:5],1'b0,data_in[3:0]} :  // bit 4 (LOAD strobe) is not stored
  (thi_load && oneshot)  ? {tmcr[6:1],1'b1} :                   // one-shot: writing the high byte starts it
  (underflow && oneshot) ? {tmcr[6:1],1'b0} :                   // one-shot: underflow stops it
                           tmcr[6:0];
always @(posedge clk) tmcr[6:0] <= tmcr_n;

// Capture force load strobe
always @(posedge clk)
  if (clk7_en) begin
    forceload <= tcr & wr & data_in[4];
  end

// Control register bit aliases
assign oneshot = tmcr[3];    // One-shot mode enable
assign start = tmcr[0];      // Timer start/stop

// Timer latch registers - hold reload value
// Low byte latch
always @(posedge clk)
  if (ss_ld)
    tmll[7:0] <= ss_ld_data[14:7];
  else if (clk7_en) begin
    if (reset)
      tmll[7:0] <= 8'b1111_1111;  // Default to $FF
    else if (tlo && wr)
      tmll[7:0] <= data_in[7:0];
  end

// High byte latch
always @(posedge clk)
  if (ss_ld)
    tmlh[7:0] <= ss_ld_data[22:15];
  else if (clk7_en) begin
    if (reset)
      tmlh[7:0] <= 8'b1111_1111;  // Default to $FF
    else if (thi && wr)
      tmlh[7:0] <= data_in[7:0];
  end

reg thi_load_latched;
wire thi_load_eclk= thi_load_latched & eclk;

// Detect write to timer high byte
always @(posedge clk)
  if (clk7_en) begin
  	if(eclk)
		  thi_load_latched<=1'b0;
	  if (thi & wr & (~start | oneshot))
		  thi_load_latched <= 1'b1;
    thi_load <= thi & wr & (~start | oneshot);
  end

// Timer reload conditions (same as Timer A)
assign reload = thi_load_eclk | forceload | underflow;

// 16-bit down counter
wire [15:0] tmr_n =
  ss_ld            ? ss_ld_data[38:23] :
  !clk7_en         ? tmr[15:0] :
  reset            ? 16'hFF_FF :              // reset to maximum value
  reload           ? {tmlh[7:0],tmll[7:0]} :  // load from latches
  (start && count) ? tmr[15:0] - 16'd1 :      // count down
                     tmr[15:0];
always @(posedge clk) tmr[15:0] <= tmr_n;

// Timer state detection
assign zero = ~|tmr;                    // Timer equals zero
assign underflow = zero & start & count; // Underflow when counting through zero

// Output signals
assign irq = underflow;

// PB7, same shape as timer A's PB6. The toggle flop is deliberately not in
// ss_state -- see the note in rtl/ss_state.vh.
reg pb_tgl;
wire pb_tgl_n = !clk7_en ? pb_tgl : reset ? 1'b0 : underflow ? ~pb_tgl : pb_tgl;
always @(posedge clk) pb_tgl <= pb_tgl_n;

// The lookahead: underflow, pb_on and pb_val as they will be after this edge,
// from the next-state values above and the next eclk.
wire count_n     = tmcr_n[6] ? tmra_ovf_n : (eclk_n & start_delay_n[1]);
wire underflow_n = ~|tmr_n & tmcr_n[0] & count_n;
assign pb_on_n  = tmcr_n[1];
assign pb_val_n = tmcr_n[2] ? pb_tgl_n : underflow_n;

assign pb_on  = tmcr[1];
assign pb_val = tmcr[2] ? pb_tgl : underflow;  // Interrupt request on underflow

// CPU read data multiplexer
// Note: Bit 7 of CRB (ALARM bit) is handled by Timer D module
assign data_out[7:0] = ({8{~wr&tlo}} & tmr[7:0])        // Timer low byte
          | ({8{~wr&thi}} & tmr[15:8])                  // Timer high byte
          | ({8{~wr&tcr}} & {1'b0,tmcr[6:0]});         // Control register


assign ss_state = {tmr[15:0], tmlh[7:0], tmll[7:0], tmcr[6:0]};

endmodule