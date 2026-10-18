// tb_bltrd_equiv.sv -- the blitter pointer bank's read select, off the DMA
// priority mux, with agnus unchanged on every clock.
//
// agnus_blitter_adrgen used to read its pointer bank at the same select it
// writes: ptrsel when enaptr, else Agnus's register bus. That bus is the output
// of Agnus's DMA priority mux, and enaptr follows dma_ack and enable, which are
// arbitration too, so every arbitration input -- disk select, beam compares,
// BPLCON0, the CPU address -- reached sdram_ctrl's sd_addr through the bank's
// read port, address_out, Gary and row_new (docs/seed-lottery.md, family A).
// The read is now at ptrsel, from blitter state alone (the argument is in
// agnus_blitter_adrgen.v).
//
// Two whole agnus instances, the new one and the frozen previous version
// (agnus_ref.v, agnus_blitter_ref.v, agnus_blitter_adrgen_ref.v), each with its
// own chip RAM filled with the same random words. They get the same random CPU
// register writes (blitter, DMACON, bitplane, sprite, copper, disk, audio
// pointers, FMODE), so blits -- line mode half of the time -- run against disk,
// audio, bitplane and sprite DMA. The copper is held off: over random RAM it
// executes random MOVEs to DMACON, which switch the blitter off for most of
// the run. Every agnus output and both pointer banks are compared on every
// clock.
//
// The checks only mean something if the change was exercised, so the bench
// also counts blitter grants, granted line-mode cycles, L3 cycles with
// first_line_pixel set (L3 never asks for the bus, so it is the one line state
// whose read only feeds a pointer update), cycles where the old read select
// and the new one differ, and the disk, audio, bitplane and sprite DMA slots
// that compete with the blitter, and fails if any of them is zero. It also
// fails on any X on a compared output once the registers have all been
// written: an X on both sides is a match to !==.
//
// Compile the bench first, for the timescale reason in rtl/sim/denise.

`timescale 1ns/1ps

module tb_bltrd_equiv;

parameter AGA = 0;
parameter SEED = 1;
parameter NCLK = 400000;   // 200000 is too short for bitplane DMA to start on seed 1

reg clk = 0;
always #17.6 clk = ~clk;
reg reset_n = 0, reset = 1;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clkgen (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                  .cck(cck), .eclk(eclk), .ce(1'b1), .reset_n(reset_n));

reg  [15:0] mem_n [0:262143];
reg  [15:0] mem_r [0:262143];
reg         aen = 0, hwr = 0, lwr = 0;
reg  [8:1]  cpu_addr = 8'hFF;
reg  [15:0] cpu_data = 0;
reg   [3:0] audio_dmal = 0, audio_dmas = 0;
reg         disk_dmal = 0, disk_dmas = 0;

`define AGNUS_PORTS(MEM, SFX) \
  wire [20:1] address_out``SFX; \
  wire  [8:1] reg_address_out``SFX; \
  wire        dbr``SFX, dbwe``SFX, cpu_custom``SFX, blit_busy``SFX, int3``SFX; \
  wire [15:0] data_out``SFX; \
  wire [15:0] data_in``SFX = dbr``SFX ? MEM[address_out``SFX[18:1]] : cpu_data; \
  always @(posedge clk) if (dbr``SFX && dbwe``SFX && clk7_en) MEM[address_out``SFX[18:1]] <= data_out``SFX;

`AGNUS_PORTS(mem_n, _n)
`AGNUS_PORTS(mem_r, _r)

agnus dut (
  .clk(clk), .clk7_en(clk7_en), .cck(cck), .reset(reset),
  .aen(aen), .rd(1'b0), .hwr(hwr), .lwr(lwr),
  .data_in(data_in_n), .data_out(data_out_n), .address_in(cpu_addr),
  .ss_replay_we(1'b0), .ss_replay_addr(8'hFF),
  .address_out(address_out_n), .reg_address_out(reg_address_out_n),
  .cpu_custom(cpu_custom_n), .dbr(dbr_n), .dbwe(dbwe_n),
  ._hsync(), ._vsync(), ._csync(), .field1(), .lace(), .hblank(), .vblank(), .hde(),
  .sol(), .sof(), .vbl_int(), .strhor_denise(), .strhor_paula(), .htotal(),
  .harddis(), .varbeamen(), .int3(int3_n), .blit_busy(blit_busy_n),
  .audio_dmal(audio_dmal), .audio_dmas(audio_dmas), .disk_dmal(disk_dmal), .disk_dmas(disk_dmas), .bls(1'b0),
  .ntsc(1'b0), .a1k(1'b0), .ecs(1'b1), .aga(AGA[0]), .floppy_speed(1'b0),
  .lpen_vpos(11'd0), .lpen_hpos(9'd0), .ss_vpos_out(), .ss_hpos_out()
);

agnus_ref ref_i (
  .clk(clk), .clk7_en(clk7_en), .cck(cck), .reset(reset),
  .aen(aen), .rd(1'b0), .hwr(hwr), .lwr(lwr),
  .data_in(data_in_r), .data_out(data_out_r), .address_in(cpu_addr),
  .ss_replay_we(1'b0), .ss_replay_addr(8'hFF),
  .address_out(address_out_r), .reg_address_out(reg_address_out_r),
  .cpu_custom(cpu_custom_r), .dbr(dbr_r), .dbwe(dbwe_r),
  ._hsync(), ._vsync(), ._csync(), .field1(), .lace(), .hblank(), .vblank(), .hde(),
  .sol(), .sof(), .vbl_int(), .strhor_denise(), .strhor_paula(), .htotal(),
  .harddis(), .varbeamen(), .int3(int3_r), .blit_busy(blit_busy_r),
  .audio_dmal(audio_dmal), .audio_dmas(audio_dmas), .disk_dmal(disk_dmal), .disk_dmas(disk_dmas), .bls(1'b0),
  .ntsc(1'b0), .a1k(1'b0), .ecs(1'b1), .aga(AGA[0]), .floppy_speed(1'b0),
  .lpen_vpos(11'd0), .lpen_hpos(9'd0), .ss_vpos_out(), .ss_hpos_out()
);

// ---- comparison --------------------------------------------------------------
reg armed = 0;     // set once every register has been written
integer xout = 0, n_dsk = 0, n_aud = 0, n_bpl = 0, n_spr = 0;
always @(negedge clk) if (armed && clk7_en) begin
  n_dsk = n_dsk + ref_i.dma_dsk; n_aud = n_aud + ref_i.dma_aud;
  n_bpl = n_bpl + ref_i.dma_bpl; n_spr = n_spr + ref_i.dma_spr;
  if ((^{address_out_r, dbr_r, dbwe_r, data_out_r, reg_address_out_r}) === 1'bx) begin
    xout = xout + 1;
    if (xout <= 6) $display("X clk %0d: addr %h dbr %b we %b data %h reg %h | blt_state %b ack %b",
      cyc, address_out_r, dbr_r, dbwe_r, data_out_r, reg_address_out_r, ref_i.bl1.blt_state, ref_i.ack_blt);
  end
end

integer mism = 0, cyc = 0, grants = 0, line_grants = 0, l3_first = 0, sel_diff = 0;
integer k;
always @(negedge clk) if (!reset) begin
  cyc = cyc + 1;
  if ({address_out_n, reg_address_out_n, dbr_n, dbwe_n, cpu_custom_n, blit_busy_n, int3_n, data_out_n} !==
      {address_out_r, reg_address_out_r, dbr_r, dbwe_r, cpu_custom_r, blit_busy_r, int3_r, data_out_r}) begin
    mism = mism + 1;
    if (mism <= 10)
      $display("MISMATCH clk %0d: addr %h/%h reg %h/%h dbr %b/%b we %b/%b busy %b/%b data %h/%h",
        cyc, address_out_n, address_out_r, reg_address_out_n, reg_address_out_r, dbr_n, dbr_r,
        dbwe_n, dbwe_r, blit_busy_n, blit_busy_r, data_out_n, data_out_r);
  end
  for (k = 0; k < 4; k = k + 1)
    if ({dut.bl1.address_generator_1.bltpth[k], dut.bl1.address_generator_1.bltptl[k]} !==
        {ref_i.bl1.address_generator_1.bltpth[k], ref_i.bl1.address_generator_1.bltptl[k]}) begin
      mism = mism + 1;
      if (mism <= 10) $display("MISMATCH clk %0d: pointer %0d", cyc, k);
    end
  if (clk7_en && ref_i.bl1.blt_state == 5'b11010 && ref_i.bl1.first_line_pixel) l3_first = l3_first + 1;
  if (clk7_en && ref_i.ack_blt) begin
    grants = grants + 1;
    if (ref_i.bl1.blt_state[4]) line_grants = line_grants + 1;
  end
  if (dut.bl1.address_generator_1.ptrsel !== ref_i.bl1.address_generator_1.bltptr_sel)
    sel_diff = sel_diff + 1;
end

// ---- stimulus ---------------------------------------------------------------
task automatic tick; begin @(posedge clk); while (!clk7_en) @(posedge clk); #1; end endtask
task automatic cpu_wr(input [8:0] a, input [15:0] d);
  begin
    while (dbr_r) tick;
    cpu_addr = a[8:1]; cpu_data = d; aen = 1; hwr = 1; lwr = 1;
    tick;
    aen = 0; hwr = 0; lwr = 0; cpu_addr = 8'hFF;
  end
endtask

reg [8:0] regs [0:47];
initial begin
  // blitter
  regs[0]='h040; regs[1]='h042; regs[2]='h044; regs[3]='h046; regs[4]='h048; regs[5]='h04A;
  regs[6]='h04C; regs[7]='h04E; regs[8]='h050; regs[9]='h052; regs[10]='h054; regs[11]='h056;
  regs[12]='h060; regs[13]='h062; regs[14]='h064; regs[15]='h066; regs[16]='h070; regs[17]='h072;
  regs[18]='h074; regs[19]='h05A; regs[20]='h05C;
  // bitplanes, display window, data fetch
  regs[21]='h100; regs[22]='h092; regs[23]='h094; regs[24]='h08E; regs[25]='h090;
  regs[26]='h0E0; regs[27]='h0E2; regs[28]='h0E4; regs[29]='h0E6; regs[30]='h108; regs[31]='h10A;
  // sprites, copper, disk, audio
  regs[32]='h120; regs[33]='h122; regs[34]='h124; regs[35]='h126;
  regs[36]='h080; regs[37]='h082; regs[38]='h088; regs[39]='h02E;
  regs[40]='h020; regs[41]='h022; regs[42]='h024;
  regs[43]='h0A0; regs[44]='h0A2; regs[45]='h0B0; regs[46]='h0B2;
  regs[47]='h1FC;   // FMODE
end

integer i, seed, r, nblit = 0;
reg [15:0] d;
reg  [9:0] bh;
reg  [5:0] bw;
always @(posedge clk) if (clk7_en) begin
  // disk and audio DMA requests come and go on their own
  if (($random(seed) & 63) == 0) disk_dmal <= ~disk_dmal;
  if (($random(seed) & 63) == 0) disk_dmas <= ~disk_dmas;
  if (($random(seed) & 31) == 0) audio_dmal <= $random(seed);
  if (($random(seed) & 31) == 0) audio_dmas <= $random(seed);
end

// agnus_bitplanedma's fetch-window flags have no reset and are only set or
// cleared on a beam-position match; under random DDFSTRT/DDFSTOP that match may
// never come, and they stay X in simulation (on the chip they power up as
// something; FPGA registers start at 0). An X there reaches the blitter's
// enable through the DMA priority mux and makes both sides X together, which
// !== would call a match. Both instances start them at 0 instead, and
// agnus_audiodma's current pointers too: those load from AUDxLC only when a
// channel starts, and a fetch request before any start reads an unwritten
// pointer.
`define ZERO_BPL(I) \
  I.bpd1.hardena = 0; I.bpd1.softena = 0; I.bpd1.ddfena = 0; I.bpd1.ddfena_0 = 0; \
  I.bpd1.ddfrun = 0; I.bpd1.ddfend = 0; I.bpd1.ddfseq = 0; I.bpd1.dmaena_delayed = 0; \
  I.bpd1.soft_start = 0; I.bpd1.soft_stop = 0; I.bpd1.hard_start = 0; I.bpd1.hard_stop = 0; \
  I.bpd1.softena_off = 0; \
  I.aud1.audpt[0] = 0; I.aud1.audpt[1] = 0; I.aud1.audpt[2] = 0; I.aud1.audpt[3] = 0;
initial begin
  `ZERO_BPL(dut)
  `ZERO_BPL(ref_i)
end

initial begin
  seed = SEED;
  for (i = 0; i < 262144; i = i + 1) begin
    d = $random(seed);
    mem_n[i] = d; mem_r[i] = d;
  end
  repeat (8) @(posedge clk);
  reset_n = 1;
  repeat (32) tick;
  reset = 0;
  repeat (16) tick;
  // The beam counters have no reset either (0 at power-up on the FPGA, X here):
  // set them the way the CPU can, as tb_copper_slots.sv does. Without this no
  // slot-based DMA ever runs and there is nothing to arbitrate against.
  cpu_wr(9'h02A, 16'h0000);                         // VPOSW
  cpu_wr(9'h02C, 16'h0000);                         // VHPOSW
  // Every DMA pointer and location register, so no engine fetches from an X
  // address: audio 0-3 LCH/LCL, disk PTH/PTL, bitplanes 1-8, sprites 0-7.
  for (i = 'h0A0; i < 'h0E0; i = i + 'h10) begin cpu_wr(i, $random(seed)); cpu_wr(i + 2, $random(seed)); end
  cpu_wr(9'h020, $random(seed)); cpu_wr(9'h022, $random(seed));
  for (i = 'h0E0; i < 'h100; i = i + 2) cpu_wr(i, $random(seed));
  for (i = 'h120; i < 'h140; i = i + 2) cpu_wr(i, $random(seed));
  // Every register in the list once before any DMA: the pointer and modulo
  // banks have no reset, and an X pointer reads as X on both sides, which !==
  // would call a match. Any X on a compared output fails the run below.
  for (i = 0; i < 48; i = i + 1) cpu_wr(regs[i], (regs[i] == 9'h042) ? 16'h0000 : $random(seed));
  cpu_wr(9'h066, $random(seed)); cpu_wr(9'h064, $random(seed));
  cpu_wr(9'h02E, 16'h0002);                         // COPCON: copper may write the blitter
  cpu_wr(9'h096, 16'h877F);                         // DMACON: everything but the copper, BLTPRI
  armed = 1;
  while (cyc < NCLK) begin
    repeat ($unsigned($random(seed)) % 24) tick;
    r = $unsigned($random(seed)) % 64;
    d = $random(seed);
    if (r < 48)
      cpu_wr(regs[r], (regs[r] == 9'h042) ? {d[15:1], d[2]} :          // BLTCON1: line mode half the time
                      (regs[r] == 9'h100) ? {d[15:12] & 4'h7, d[11:0]} : // BPLCON0: up to 7 planes
                      d);
    else if (r < 58) begin
      bh = ($unsigned($random(seed)) % 16) + 1;     // height 1-16
      bw = ($unsigned($random(seed)) % 6) + 1;      // width 1-6 words
      cpu_wr(9'h058, {bh, bw});
      nblit = nblit + 1;
    end
    else if (r < 61)
      cpu_wr(9'h096, {1'b1, (d[14:0] | 15'h0260) & ~15'h0080});   // DMACON set, DMAEN, BLTEN, SPREN on, copper off
    else
      cpu_wr(9'h096, {1'b0, d[14:0] & ~15'h0260});    // DMACON clear, never DMAEN, BLTEN or SPREN
  end
  $display("DMA slots: disk %0d audio %0d bitplane %0d sprite %0d", n_dsk, n_aud, n_bpl, n_spr);
  $display("AGA %0d seed %0d: %0d clk, %0d BLTSIZE, %0d blitter grants, %0d in line mode, %0d L3 first-pixel, %0d select differs, %0d mismatches, %0d X",
    AGA, SEED, cyc, nblit, grants, line_grants, l3_first, sel_diff, mism, xout);
  if (mism == 0 && xout == 0 && n_dsk > 0 && n_aud > 0 && n_bpl > 0 && n_spr > 0 && grants > 0 &&
      line_grants > 0 && l3_first > 0 && sel_diff > 0) $display("RUN: PASS");
  else $display("RUN: FAIL");
  $finish;
end

endmodule
