// tb_copper_slots.sv -- who owns each DMA slot on a copper-busy line, in every
// bitplane fetch mode, against Copperline's cycle trace of the same program.
//
// Why: the Turrican 2 AGA developer traced its glitches to the copper finishing
// a status-bar split late -- one scanline for 16 AGA colours plus the bitplane
// registers -- and reproduces the MiSTer picture on WinUAE by adding one copper
// instruction. A copper that loses one slot too many to bitplane DMA in some
// fetch mode would do exactly that. On 2026-10-11 a probe on hardware matched
// Copperline by screenshot (band widths); this pins it at the slot level, in
// simulation, so it cannot regress unnoticed.
//
// The whole agnus.v runs, with the real amiga_clk, so the priority mux, the
// bitplane sequencer, the copper and refresh are the core's own. Chip RAM is a
// word array behind address_out whenever Agnus has the bus; the CPU's only job
// is the three setup writes (COP1LC, DMACON) through the same aen/hwr path the
// 68020 uses. Everything else -- BPLCON0, FMODE, DDFSTRT/STOP, the bitplane
// pointers and the test lines -- is the copper list in copslots.memh, made by
// gen_copslots.py from the same table as the hardware probe.
//
// Output: one line per colour clock on the five test lines,
//   SLOT <vpos> <hpos_cck> <owner>
// with owner one of cop bpl ref spr dsk aud blt cpu. check_copslots.py
// compares that against copslots_copperline.txt (Copperline 1.x, A1200).
//
// Result 2026-10-11: every colour clock $00-$DF of all five lines -- 0 planes,
// 4 planes FMODE 0, 8 planes FMODE 0, 1 and 3 -- has the same owner as in
// Copperline, copper totals identical. The line wrap ($E0-$E2) differs by one
// copper slot's placement and is reported, not asserted (check_copslots.py says
// why). So the copper is NOT starved of slots relative to Copperline in any
// fetch mode, which rules plain slot allocation out for Turrican 2 AGA.
//
// Mutations, run by hand: copper given priority over bitplane DMA in the bus
// mux -> lines $68, $7c, $90 fail; lores FMODE 3 encoded as FMODE 1/2 (twice
// the bitplane slots) -> exactly line $90 fails, 40 slots. A mutation of
// ena_cop alone is NOT caught, and should not be: it changes what the copper
// thinks it read, not who owns the bus, and this bench measures ownership.
//
// Compile the bench first, for the same timescale reason as rtl/sim/denise.

`timescale 1ns/1ps

module tb_copper_slots;

reg clk = 0;
always #17.6 clk = ~clk;

reg reset_n = 0, reset = 1;
wire clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk;
amiga_clk clkgen (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                  .cck(cck), .eclk(eclk), .ce(1'b1), .reset_n(reset_n));

reg  [15:0] mem [0:262143];          // 512 KB of chip RAM, word addressed
reg         aen = 0, hwr = 0, lwr = 0;
reg  [8:1]  cpu_addr = 8'hFF;
reg  [15:0] cpu_data = 0;
wire [20:1] address_out;
wire        dbr, dbwe;
wire [15:0] agnus_data_out;
wire [15:0] data_in = dbr ? mem[address_out[18:1]] : cpu_data;

agnus dut (
  .clk(clk), .clk7_en(clk7_en), .cck(cck), .reset(reset),
  .aen(aen), .rd(1'b0), .hwr(hwr), .lwr(lwr),
  .data_in(data_in), .data_out(agnus_data_out), .address_in(cpu_addr),
  .ss_replay_we(1'b0), .ss_replay_addr(8'hFF),
  .address_out(address_out), .reg_address_out(),
  // (bitplane_dma and the fetch-phase outputs, which upstream c5ffbf9 adds, are
  // left out so the bench builds with or without them)
  .cpu_custom(), .dbr(dbr), .dbwe(dbwe),
  ._hsync(), ._vsync(), ._csync(), .field1(), .lace(), .hblank(), .vblank(), .hde(),
  .sol(), .sof(), .vbl_int(), .strhor_denise(), .strhor_paula(), .htotal(),
  .harddis(), .varbeamen(), .int3(), .blit_busy(),
  .audio_dmal(4'b0), .audio_dmas(4'b0), .disk_dmal(1'b0), .disk_dmas(1'b0), .bls(1'b0),
  .ntsc(1'b0), .a1k(1'b0), .ecs(1'b1), .aga(1'b1), .floppy_speed(1'b0),
  .lpen_vpos(11'd0), .lpen_hpos(9'd0), .ss_vpos_out(), .ss_hpos_out()
);

// Owner of the bus this clock, in the priority order of agnus.v's mux.
function automatic [23:0] owner;
  input dummy;
  begin
    if      (dut.dma_dsk) owner = "dsk";
    else if (dut.dma_ref) owner = "ref";
    else if (dut.dma_aud) owner = "aud";
    else if (dut.dma_bpl) owner = "bpl";
    else if (dut.dma_spr) owner = "spr";
    else if (dut.dma_cop) owner = "cop";
    else if (dut.dma_blt) owner = "blt";
    else                  owner = "cpu";
  end
endfunction

task automatic tick; begin @(posedge clk); while (!clk7_en) @(posedge clk); #1; end endtask

task automatic cpu_wr(input [8:0] reg_byte_addr, input [15:0] d);
  begin
    // only while Agnus leaves the bus alone, as the 68020's access would
    while (dbr) tick;
    cpu_addr = reg_byte_addr[8:1]; cpu_data = d; aen = 1; hwr = 1; lwr = 1;
    tick;
    aen = 0; hwr = 0; lwr = 0; cpu_addr = 8'hFF;
  end
endtask

integer i, f, frames = 0;
reg logging = 0;
reg [10:0] prev_vpos = 0;
always @(posedge clk) if (clk7_en) begin
  if (dut.sof) frames <= frames + 1;
  // One record per colour clock: the chipset slot is decided on odd hpos.
  if (logging && dut.hpos[0])
    // each test line and the one after it: Copperline's hpos is offset from
    // ours, so the end of a test line in its numbering is the start of the
    // next line in ours.
    if (dut.vpos == 11'h40 || dut.vpos == 11'h54 || dut.vpos == 11'h68 ||
        dut.vpos == 11'h7c || dut.vpos == 11'h90 ||
        dut.vpos == 11'h41 || dut.vpos == 11'h55 || dut.vpos == 11'h69 ||
        dut.vpos == 11'h7d || dut.vpos == 11'h91)
      $fdisplay(f, "SLOT %0h %0d %0s", dut.vpos, dut.hpos[8:1], owner(0));
end

initial begin
  for (i = 0; i < 262144; i = i + 1) mem[i] = 16'h0000;
  $readmemh("copslots.memh", mem);
  f = $fopen("copslots_sim.txt", "w");
  repeat (8) @(posedge clk);
  reset_n = 1;
  repeat (32) tick;
  reset = 0;
  repeat (16) tick;
  // The beam counters have no reset: on the FPGA they power up at 0, in
  // simulation they are X until written. Set them the way the CPU can.
  cpu_wr(9'h02A, 16'h0000);          // VPOSW
  cpu_wr(9'h02C, 16'h0000);          // VHPOSW
  cpu_wr(9'h080, 16'h0000);          // COP1LCH
  cpu_wr(9'h082, 16'h2000);          // COP1LCL  (byte $2000 = word $1000)
  cpu_wr(9'h096, 16'h8380);          // DMACON: SET DMAEN BPLEN COPEN
  // The copper restarts at COP1LC on every start of frame. Let one whole frame
  // go by, then log the next one.
  while (frames < 2) tick;
  logging = 1;
  while (frames < 3) tick;
  logging = 0;
  $fclose(f);
  $display("logged frame 3 to copslots_sim.txt");
  $finish;
end

endmodule
