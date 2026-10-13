// tb_blit_line.sv -- how long a line-mode blit keeps the blitter busy, by
// BLTSIZE width and height.
//
// vAmigaTS Agnus/Blitter/irqtim/irqtim1l, irqtim11l1, irqtim15l1 and
// timing/timing11l1 run line blits with a BLTSIZE width of 1 instead of the
// usual 2. On a real A500 the busy bars are short; on the core the busy colour
// covered nearly the whole frame (tier 2 run, 2026-10-11). agnus_blitter
// advances the word counter twice per line pixel (states L2 and L4), so with
// width 1 BOTH steps end a row and the height counter falls twice per pixel --
// while `done` is only tested in L4. An odd height then passes 1 in L2, L4 never
// sees last_line, and the 15-bit counter wraps: ~32767 pixels instead of a few.
//
// The whole agnus.v runs (amiga_clk, chip RAM model, CPU writes on aen/hwr),
// as in rtl/sim/copper/tb_copper_slots.sv. Busy time is counted in colour
// clocks from the BLTSIZE write to blit_busy falling, capped at CAP.
//
// CHECKs: every blit finishes inside the cap; a width-1 line of height h takes
// no longer than the width-2 line of the same height (width 1 is half the
// words). Width 2 is the reference and is printed.

`timescale 1ns/1ps

module tb_blit_line;

reg clk = 0;
always #17.6 clk = ~clk;
reg reset_n = 0, reset = 1;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clkgen (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                  .cck(cck), .eclk(eclk), .ce(1'b1), .reset_n(reset_n));

reg  [15:0] mem [0:262143];
reg         aen = 0, hwr = 0, lwr = 0;
reg  [8:1]  cpu_addr = 8'hFF;
reg  [15:0] cpu_data = 0;
wire [20:1] address_out;
wire        dbr, dbwe, blit_busy;
wire [15:0] agnus_data_out;
wire [15:0] data_in = dbr ? mem[address_out[18:1]] : cpu_data;
always @(posedge clk) if (dbr && dbwe) mem[address_out[18:1]] <= agnus_data_out;

agnus dut (
  .clk(clk), .clk7_en(clk7_en), .cck(cck), .reset(reset),
  .aen(aen), .rd(1'b0), .hwr(hwr), .lwr(lwr),
  .data_in(data_in), .data_out(agnus_data_out), .address_in(cpu_addr),
  .ss_replay_we(1'b0), .ss_replay_addr(8'hFF),
  .address_out(address_out), .reg_address_out(),
  .cpu_custom(), .dbr(dbr), .dbwe(dbwe),
  ._hsync(), ._vsync(), ._csync(), .field1(), .lace(), .hblank(), .vblank(), .hde(),
  .sol(), .sof(), .vbl_int(), .strhor_denise(), .strhor_paula(), .htotal(),
  .harddis(), .varbeamen(), .int3(), .blit_busy(blit_busy),
  .audio_dmal(4'b0), .audio_dmas(4'b0), .disk_dmal(1'b0), .disk_dmas(1'b0), .bls(1'b0),
  .ntsc(1'b0), .a1k(1'b0), .ecs(1'b1), .aga(1'b0), .floppy_speed(1'b0),
  .lpen_vpos(11'd0), .lpen_hpos(9'd0), .ss_vpos_out(), .ss_hpos_out()
);

task automatic tick; begin @(posedge clk); while (!clk7_en) @(posedge clk); #1; end endtask
task automatic cpu_wr(input [8:0] a, input [15:0] d);
  begin
    while (dbr) tick;
    cpu_addr = a[8:1]; cpu_data = d; aen = 1; hwr = 1; lwr = 1;
    tick;
    aen = 0; hwr = 0; lwr = 0; cpu_addr = 8'hFF;
  end
endtask

localparam integer CAP = 200000;   // colour clocks; a sane line blit of 5 pixels is a few dozen
integer busy_cck;
task automatic line_blit(input integer w, input integer h);
  integer n;
  begin
    cpu_wr(9'h040, 16'hABCA);      // BLTCON0: ASH=$A, USE A C D, minterm $CA -- as irqtim.i
    cpu_wr(9'h042, 16'h0001);      // BLTCON1: line mode, octant 0
    cpu_wr(9'h044, 16'hFFFF);      // BLTAFWM
    cpu_wr(9'h046, 16'hFFFF);      // BLTALWM
    cpu_wr(9'h064, 16'hFF38);      // BLTAMOD = -200
    cpu_wr(9'h062, 16'h0000);      // BLTBMOD
    cpu_wr(9'h060, 16'd40);        // BLTCMOD
    cpu_wr(9'h066, 16'd40);        // BLTDMOD
    cpu_wr(9'h052, 16'hFF9C);      // BLTAPTL = -100
    cpu_wr(9'h048, 16'h0001); cpu_wr(9'h04A, 16'h0000);   // BLTCPT = $10000
    cpu_wr(9'h054, 16'h0001); cpu_wr(9'h056, 16'h0000);   // BLTDPT = $10000
    cpu_wr(9'h074, 16'h8000);      // BLTADAT
    cpu_wr(9'h072, 16'hFFFF);      // BLTBDAT
    cpu_wr(9'h058, (h << 6) | w);  // BLTSIZE: start
    n = 0;
    tick; tick;
    while (blit_busy && n < CAP * 2) begin tick; n = n + 1; end
    busy_cck = n / 2;              // two clk7 ticks per colour clock
  end
endtask

integer fails = 0, checks = 0, w2 [1:5], h, d;
initial begin
  for (h = 0; h < 262144; h = h + 1) mem[h] = 16'h0000;
  repeat (8) @(posedge clk);
  reset_n = 1;
  repeat (32) tick;
  reset = 0;
  repeat (16) tick;
  cpu_wr(9'h02A, 16'h0000); cpu_wr(9'h02C, 16'h0000);    // beam counters out of X
  cpu_wr(9'h096, 16'h8240);                              // DMACON: SET DMAEN BLTEN
  for (h = 1; h <= 5; h = h + 1) begin
    line_blit(2, h); w2[h] = busy_cck;
    $display("MEASURE width 2 height %0d: busy %0d cck", h, busy_cck);
  end
  for (h = 1; h <= 5; h = h + 1) begin
    line_blit(1, h); d = busy_cck;
    checks = checks + 1;
    if (d >= CAP || d > w2[h]) begin
      fails = fails + 1;
      $display("CHECK FAIL width 1 height %0d: busy %0d cck%s (width 2: %0d)", h, d,
               d >= CAP ? " -- RUNAWAY, hit the cap" : "", w2[h]);
    end else
      $display("CHECK ok   width 1 height %0d: busy %0d cck (width 2: %0d)", h, d, w2[h]);
  end
  $display("%0d checks, %0d failed", checks, fails);
  $display("RUN: %s", fails ? "FAIL" : "PASS");
  $finish;
end

endmodule
