// tb_denise_scroll_copy.sv -- where does the first pixel of a bitplane fetch
// leave Denise, against where the hardware's holding->shift copy puts it?
//
// Real Denise (and WinUAE, drawing.cpp: `dhv == bplcon1_shift_full`) does not
// load the shift registers when BPL1DAT is written. The write arms a copy, and
// the copy fires on the first pixel at or after it whose horizontal counter,
// masked to the fetch unit, equals the BPLCON1 scroll. BPLCON1 reaches that
// comparator the moment it is written (WinUAE expand_bplcon1(), every chipset).
//
// Minimig instead loads on the write and delays the output by
// scroll + extra_delay, where extra_delay rounds the load up to the next
// fetch-unit boundary. The two agree when the fetch is on the grid. Upstream
// c5ffbf9 ("Fix Absolute Inebriation") adds the comparator as a second path for
// OCS/ECS LORES FMODE=0 only; this bench measures what is left.
//
// Reference: copy tick = first clk7 tick t >= the tick `load` is high with
// (hpos & (G-1)) == scroll, G = 16 lores pixels for FMODE 0, 32 for 1/2, 64 for
// 3. That counter is exactly what the new OCS path compares against
// (ocs_hcmp == Denise's hpos), so it needs no calibration of its own.
//
// Measured: delta = (clk of the first set bpldata[1] bit) - (clk of the
// reference copy). A correct model gives one constant delta per mode -- the
// pipeline latency. A delta that differs from the mode's latency by a multiple
// of 4*G clocks is a whole fetch unit early or late.
//
// The on-grid rows are the model's own check: Minimig is right on the grid
// (every Kickstart and every on-grid scroller), so if the reference disagreed
// there the reference would be wrong, not the core. CHECK lines assert that.
// MEASURE lines are characterisation and do not fail the run.
//
// What it measured on 2026-10-11 (core at upstream c5ffbf9 + this fork):
//
//   * FMODE 0, single fetch, OCS and AGA: Minimig matches the comparator at
//     every off-grid phase. extra_delay plus the scroller's fetch-mode mask
//     wraps modulo the fetch unit, which is the comparator's own arithmetic.
//     The one exception is OCS phase 8, one lores pixel early at every scroll:
//     that is where c5ffbf9's new path takes over, and its pipeline is one
//     pixel shorter than the legacy shifters'. Which of the two is right needs
//     a pixel-exact reference.
//   * AGA FMODE 1/2 and 3: extra_delay_f12 / _f3 key on hpos[4:3] / hpos[5:4],
//     so the load phase is rounded to 8 / 16 lores pixels. A BPL1DAT landing
//     4, 8 or 12 pixels off that step comes out late by the remainder, or a
//     whole unit early when the scroll is below the phase: 128 of 224 and 768
//     of 960 off-grid cells. WinUAE starts the sequencer at the DDFSTRT match
//     without aligning it (custom.cpp bprun_start), and so does
//     agnus_bitplanedma (2-cck DDFSTRT steps on ECS/AGA), so these loads occur.
//   * Mid-line BPLCON1: OCS matches since 7f93ed1. AGA still waits for the next
//     load: +4, +8 and -8 pixels on the three cases below. Reverting 7f93ed1
//     moves the OCS rows to exactly those AGA numbers, so this is the same
//     defect c5ffbf9 fixed for OCS, still present on AGA.
//
// Not covered: what is copied when a later fetch lands between the BPL1DAT
// write and the copy. A single fetch cannot see that, and it is what c5ffbf9's
// pending/ownership logic exists for.
//
// Compile the bench FIRST. denise_bitplanes.v writes with `<= #1` and declares
// no timescale; listed first, the bench's `timescale reaches it. Listed after
// the RTL, Icarus gives it a 1 s unit and no register ever updates.

`timescale 1ns/1ps

module tb_denise_scroll_copy;

localparam [7:0] A_BPLCON1 = 9'h102 >> 1;
localparam [7:0] A_BPL1DAT = 9'h110 >> 1;
localparam [7:0] A_FMODE   = 9'h1fc >> 1;
localparam [7:0] A_IDLE    = 8'hFF;
localparam integer LINE    = 454;          // clk7 ticks per PAL line

reg clk = 0;
always #17.6 clk = ~clk;                   // 28.375 MHz

reg reset_n = 0;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;

amiga_clk clkgen (
  .clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
  .c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .ce(1'b1), .reset_n(reset_n)
);

reg        aga = 0;
reg  [7:0] reg_addr = A_IDLE;
reg [15:0] data = 0;
reg  [8:0] hpos = 2;
reg        strhor = 0;
reg        bitplane_dma = 0;
reg        reset = 1;
wire [8:1] bpldata;

denise_bitplanes dut (
  .clk(clk), .clk7_en(clk7_en), .reset(reset), .c1(c1), .c3(c3), .aga(aga),
  .reg_address_in(reg_addr), .data_in(data), .chip48(48'd0),
  .hires(1'b0), .shres(1'b0), .hpos(hpos), .strhor(strhor),
  .bitplane_dma(bitplane_dma),
  .bitplane_fetch_phase(1'b0), .bitplane_fetch_phase_valid(1'b0),
  .bitplane_fetch_unit_start(1'b0),
  .blank(1'b0), .hdiw(1'b1), .planes(4'd1),
  .bpldata(bpldata)
);

// ---- beam: Denise's own hpos, as denise.v drives it -------------------------
integer line_tick = 0;
always @(posedge clk) if (clk7_en) begin
  line_tick <= (line_tick == LINE-1) ? 0 : line_tick + 1;
  strhor    <= (line_tick == LINE-2);
  hpos      <= strhor ? 9'd2 : hpos + 9'd1;
end

integer now = 0;
always @(posedge clk) now <= now + 1;

// ---- reference comparator and measurement -----------------------------------
integer G = 16;                 // fetch unit in lores pixels for the mode under test
integer scroll_live = 0;        // BPLCON1 as the comparator sees it (immediate)
reg     armed = 0;
integer load_clk, load_hpos, copy_clk, out_clk;

always @(posedge clk) begin
  if (clk7_en && reg_addr == A_BPLCON1)
    scroll_live <= aga ? ((data[11:10] << 4) | data[3:0]) : data[3:0];
  if (clk7_en && dut.load && copy_clk < 0) begin
    load_clk  <= now;
    load_hpos <= hpos;
    armed     <= 1;
  end
  // Same tick as load counts: the new OCS path's snapshot_event fires on it.
  if (clk7_en && (armed || (dut.load && copy_clk < 0)) && copy_clk < 0 &&
      ((hpos & (G-1)) == (scroll_live & (G-1)))) begin
    copy_clk <= now;
    armed    <= 0;
  end
  if (bpldata[1] && out_clk < 0 && load_clk >= 0)
    out_clk <= now;
end

// ---- bus ---------------------------------------------------------------------
task automatic tick;            // to just after the next clk7_en edge
  begin @(posedge clk); while (!clk7_en) @(posedge clk); #1; end
endtask

task automatic wr(input [7:0] a, input [15:0] d, input dma);
  begin
    reg_addr = a; data = d; bitplane_dma = dma;
    tick;
    reg_addr = A_IDLE; bitplane_dma = 0;
  end
endtask

task automatic wait_hpos(input integer h);  // drive the next write so it samples at hpos h
  begin while (hpos != h - 1) tick; end
endtask

function automatic [15:0] bplcon1_for(input integer s1, input integer s2);
  // s in lores pixels, both playfields; AGA puts bits 5:4 in 11:10 / 15:14
  bplcon1_for = aga ? {s2[5:4], 2'b00, s1[5:4], 2'b00, s2[3:0], s1[3:0]}
                    : {8'h00, s2[3:0], s1[3:0]};
endfunction

// ---- one trial ---------------------------------------------------------------
// Load at hpos = base + phase with scroll s; optionally rewrite BPLCON1 to s_mid
// `mid_after` ticks after the BPL1DAT write. Sets delta in clk (negative = Minimig's pixel leaves before the copy)
// and measured; a trial that captures nothing fails the run.
integer delta;
reg     measured;
integer fails = 0, checks = 0;
task automatic trial(input integer phase, input integer s, input integer s_mid,
                     input integer mid_after);
  integer base;
  begin
    base = 192;                                   // a multiple of 64, mid-line
    wait_hpos(40);                                // a fresh line, well clear
    wr(A_BPLCON1, bplcon1_for(s, s), 0);
    copy_clk = -1; out_clk = -1; load_clk = -1; armed = 0;
    wait_hpos(base + phase);
    wr(A_BPL1DAT, 16'h8000, 1);
    if (mid_after > 0) begin
      repeat (mid_after - 1) tick;
      wr(A_BPLCON1, bplcon1_for(s_mid, s_mid), 0);
    end
    // Event wait with a generous cap: the latest legitimate copy is G-1 ticks
    // after the load, plus pipeline. Two units is far beyond either.
    begin : w
      integer n; n = 0;
      while ((copy_clk < 0 || out_clk < 0) && n < 4*G + 64) begin tick; n = n + 1; end
    end
    wr(A_BPL1DAT, 16'h0000, 0);                   // flush so the next trial starts dark
    measured = (copy_clk >= 0 && out_clk >= 0);
    delta = measured ? out_clk - copy_clk : 0;
    if (!measured) begin
      fails = fails + 1;
      $display("CHECK FAIL nothing measured: phase %0d scroll %0d load %0d copy %0d out %0d",
               phase, s, load_clk, copy_clk, out_clk);
    end
  end
endtask

// FMODE is written only in AGA mode and cleared only by reset, so a mode
// switch from AGA back to OCS would otherwise keep the last AGA fetch mode.
task automatic set_mode(input integer is_aga, input [1:0] fm);
  begin
    aga = 1; wr(A_FMODE, {14'd0, is_aga ? fm : 2'd0}, 0);
    aga = is_aga;
  end
endtask

// ---- sweep -------------------------------------------------------------------
integer mismatches;
integer lat;                                      // the mode's latency, from phase 0 scroll 0

task automatic sweep(input string name, input integer is_aga, input [1:0] fm,
                     input integer unit);
  integer ph, s, d;
  begin
    set_mode(is_aga, fm); G = unit;
    mismatches = 0;
    trial(0, 0, 0, 0); lat = delta;
    $display("%s: latency %0d clk (phase 0, scroll 0)", name, lat);
    for (ph = 0; ph < unit; ph = ph + 4) begin
      for (s = 0; s < unit; s = s + 1) begin
        trial(ph, s, 0, 0); d = delta;
        if (ph == 0) begin
          checks = checks + 1;
          if (d != lat) begin
            fails = fails + 1;
            $display("CHECK FAIL %s on-grid scroll %0d: delta %0d, latency %0d -- reference model wrong",
                     name, s, d, lat);
          end
        end else if (d != lat) begin
          mismatches = mismatches + 1;
          $display("MEASURE %s phase %2d scroll %2d: %0d lores px %s (load hpos %0d)",
                   name, ph, s, (d - lat) / 4, (d > lat) ? "late" : "early", load_hpos);
        end
      end
    end
    $display("MEASURE %s off-grid: %0d of %0d cells differ from the comparator",
             name, mismatches, (unit/4 - 1) * unit);
  end
endtask

task automatic midline(input string name, input integer is_aga, input integer s1,
                       input integer s2, input integer after);
  begin
    set_mode(is_aga, 2'd0); G = 16;
    trial(0, 0, 0, 0); lat = delta;
    trial(0, s1, s2, after);
    $display("MEASURE %s mid-line BPLCON1 %0d -> %0d at +%0d ticks: %s%0d lores px",
             name, s1, s2, after, (delta == lat) ? "matches, " : "off by ",
             (delta - lat) / 4);
  end
endtask

initial begin
  repeat (8) @(posedge clk);
  reset_n = 1;
  repeat (16) tick;
  reset = 0;
  // The shifters, scrollers and pf1h/pf2h have no reset: on hardware they
  // settle, in simulation they are X until zeros are loaded through them. Flush
  // with zero loads in both chipset modes before measuring anything.
  begin : flush
    integer i;
    for (i = 0; i < 8; i = i + 1) begin
      aga = i[0];
      wr(A_BPLCON1, 16'h0000, 0);
      wr(A_BPL1DAT, 16'h0000, 1);
      repeat (100) tick;
    end
    aga = 0;
  end
  repeat (2*LINE) tick;
  if (bpldata[1] !== 1'b0) begin
    fails = fails + 1;
    $display("CHECK FAIL bpldata[1] is %b after the flush, not 0", bpldata[1]);
  end

  sweep("OCS  FMODE0", 0, 2'd0, 16);
  sweep("AGA  FMODE0", 1, 2'd0, 16);
  sweep("AGA  FMODE1", 1, 2'd1, 32);
  sweep("AGA  FMODE3", 1, 2'd3, 64);

  midline("OCS ", 0, 12, 8, 4);
  midline("OCS ", 0, 12, 4, 2);
  midline("OCS ", 0, 4, 12, 2);
  midline("AGA ", 1, 12, 8, 4);
  midline("AGA ", 1, 12, 4, 2);
  midline("AGA ", 1, 4, 12, 2);

  $display("%0d checks, %0d failed", checks, fails);
  $display("RUN: %s", fails ? "FAIL" : "PASS");
  $finish;
end

endmodule
