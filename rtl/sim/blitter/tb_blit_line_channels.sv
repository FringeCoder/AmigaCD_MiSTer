// tb_blit_line_channels.sv -- which channel enables a line-mode blit honours.
//
// vAmigaTS Agnus/Blitter/line/channels1 and channels2 draw the same line under
// all sixteen combinations of BLTCON0's USEA-USED. An A500 shows one line per
// test; the core drew one for every combination with C enabled, because in line
// mode it ignored USEB. On the real chip (and in vAmiga's B-enabled line
// programs) an enabled B channel is fetched for every pixel, and that word --
// not what the CPU left in BLTBDAT -- is what the texture bit comes from. Over
// zeroed memory such a line comes out blank; over $FFFF it is solid.
//
// The whole agnus.v runs, as in tb_blit_line.sv. Each case clears the
// destination, draws a 6-pixel line from BLTCPT = BLTDPT = $10000, and counts
// the destination bits set and the words written. B points at $20000.
//
// CHECKs:
//   A C D,   BLTBDAT $FFFF                 -> 6 pixels      (texture register)
//   A B C D, BLTBDAT $FFFF, B memory $0000 -> 0 pixels      (texture fetched)
//   A B C D, BLTBDAT $0000, B memory $FFFF -> 6 pixels      (texture fetched)
//   A B C D, B memory $0000, BLTBMOD 2     -> BLTBPT advanced by 6 * BLTBMOD
//   A D (no C)                             -> nothing written at all
//
// Compile the bench first, for the timescale reason in rtl/sim/denise.

`timescale 1ns/1ps

module tb_blit_line_channels;

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

integer writes = 0;
always @(posedge clk) if (clk7_en && dbr && dbwe) writes = writes + 1;

task automatic clear;
  integer i;
  begin
    for (i = 'h8000 - 'h400; i < 'h8000 + 'h400; i = i + 1) mem[i] = 16'h0000;   // around $10000
  end
endtask

task automatic fill_b(input [15:0] v);
  integer i;
  begin
    for (i = 'h10000; i < 'h10000 + 'h40; i = i + 1) mem[i] = v;                 // $20000
  end
endtask

function automatic integer pixels;
  input dummy;
  integer i, b, n;
  begin
    n = 0;
    for (i = 'h8000 - 'h400; i < 'h8000 + 'h400; i = i + 1)
      for (b = 0; b < 16; b = b + 1) n = n + mem[i][b];
    pixels = n;
  end
endfunction

localparam integer H = 6;
task automatic line_blit(input [15:0] con0, input [15:0] bdat, input [15:0] bmod);
  integer n;
  begin
    cpu_wr(9'h040, con0);          // BLTCON0: ASH=$A, channels, minterm $CA
    cpu_wr(9'h042, 16'h0001);      // BLTCON1: line mode, octant 0
    cpu_wr(9'h044, 16'hFFFF);      // BLTAFWM
    cpu_wr(9'h046, 16'hFFFF);      // BLTALWM
    cpu_wr(9'h064, 16'hFF38);      // BLTAMOD = -200
    cpu_wr(9'h062, bmod);          // BLTBMOD
    cpu_wr(9'h060, 16'd40);        // BLTCMOD
    cpu_wr(9'h066, 16'd40);        // BLTDMOD
    cpu_wr(9'h052, 16'hFF9C);      // BLTAPTL = -100
    cpu_wr(9'h048, 16'h0001); cpu_wr(9'h04A, 16'h0000);   // BLTCPT = $10000
    cpu_wr(9'h054, 16'h0001); cpu_wr(9'h056, 16'h0000);   // BLTDPT = $10000
    cpu_wr(9'h04C, 16'h0002); cpu_wr(9'h04E, 16'h0000);   // BLTBPT = $20000
    cpu_wr(9'h074, 16'h8000);      // BLTADAT
    cpu_wr(9'h072, bdat);          // BLTBDAT
    writes = 0;
    cpu_wr(9'h058, (H << 6) | 2);  // BLTSIZE: start
    n = 0;
    tick; tick;
    while (blit_busy && n < 100000) begin tick; n = n + 1; end
  end
endtask

integer fails = 0, checks = 0;
task automatic check(input [511:0] what, input integer got, input integer want);
  begin
    checks = checks + 1;
    if (got !== want) begin fails = fails + 1; $display("CHECK FAIL %0s: %0d, want %0d", what, got, want); end
    else $display("CHECK ok   %0s: %0d", what, got);
  end
endtask

integer i;
initial begin
  for (i = 0; i < 262144; i = i + 1) mem[i] = 16'h0000;
  repeat (8) @(posedge clk);
  reset_n = 1;
  repeat (32) tick;
  reset = 0;
  repeat (16) tick;
  cpu_wr(9'h02A, 16'h0000); cpu_wr(9'h02C, 16'h0000);    // beam counters out of X
  cpu_wr(9'h096, 16'h8240);                              // DMACON: SET DMAEN BLTEN

  clear; fill_b(16'h0000);
  line_blit(16'hABCA, 16'hFFFF, 16'h0000);
  check("A C D, BLTBDAT $FFFF: pixels", pixels(0), H);

  clear; fill_b(16'h0000);
  line_blit(16'hAFCA, 16'hFFFF, 16'h0000);
  check("A B C D, B memory $0000: pixels", pixels(0), 0);

  clear; fill_b(16'hFFFF);
  line_blit(16'hAFCA, 16'h0000, 16'h0000);
  check("A B C D, B memory $FFFF: pixels", pixels(0), H);

  clear; fill_b(16'h0000);
  line_blit(16'hAFCA, 16'hFFFF, 16'h0002);
  check("A B C D, BLTBMOD 2: BLTBPT advance in words", dut.bl1.address_generator_1.bltptl[1], H);

  clear; fill_b(16'h0000);
  line_blit(16'hA9CA, 16'hFFFF, 16'h0000);
  check("A D only: words written", writes, 0);

  $display("%0d checks, %0d failed", checks, fails);
  $display("RUN: %s", fails ? "FAIL" : "PASS");
  $finish;
end

endmodule
