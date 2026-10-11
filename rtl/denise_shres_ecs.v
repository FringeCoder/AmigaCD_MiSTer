// ECS Denise super hires colour: which register a pixel reaches, and what the
// register's value looks like on screen.
//
// Measured on a real A500+ (8373 Denise) by the vAmigaTS Denise/Modes/shres
// families, photographs in that repository:
//
//   Index. A super hires pixel's two bit value v reaches register 5 * v --
//   COLOR00, 05, 10 or 15, the value replicated into a four bit index. shindex1
//   to shindex5 read the index out one bit per test (sixteen sections, every
//   pairing of two alternating values) and every section fits {v1,v0,v1,v0};
//   sh1bpl1 to sh1bpl5 repeat it with one bitplane and fit the same rule with
//   v1 = 0, so a set pixel reaches COLOR05, not COLOR01.
//
//   Value. Denise sends the high bit pair of each RGB nibble to one sub-pixel
//   and the low pair to the other, each pair replicated over the component
//   (0,1,2,3 -> $0,$5,$A,$F). A monitor cannot resolve the two and shows their
//   average, in signal space: nibble n displays at ((n>>2) + (n&3)) / 6 of full
//   scale (shramp1 to shramp7 sweep all fourteen nibbles; shsplit1 shows $C00
//   and $300 coming out equal). The sub-pixels are finer than the 28 MHz pixel
//   clock this core outputs at, so the average is what is output.
//
// AGA (Lisa) super hires is a full-depth mode and is not affected; neither are
// sprites, which this module is never asked about.

module denise_shres_ecs
(
  input  wire [ 2-1:0] v,       // playfield pixel: {bitplane 2, bitplane 1}
  output wire [ 8-1:0] index,   // colour register it reaches
  input  wire [24-1:0] rgb_in,  // that register, as the colour table expands it
  output wire [24-1:0] rgb_out  // what the screen shows
);

assign index = {4'b0000, v, v};

// One component: the table holds a 4 bit value expanded to 8 (n * 17), so the
// nibble is the top four bits.
function [7:0] level;
  input [7:0] c;
  reg   [2:0] s;
  begin
    s = {1'b0, c[7:6]} + {1'b0, c[5:4]};
    case (s)
      3'd0:    level = 8'd0;
      3'd1:    level = 8'd43;
      3'd2:    level = 8'd85;
      3'd3:    level = 8'd128;
      3'd4:    level = 8'd170;
      3'd5:    level = 8'd213;
      default: level = 8'd255;
    endcase
  end
endfunction

assign rgb_out = {level(rgb_in[23:16]), level(rgb_in[15:8]), level(rgb_in[7:0])};

endmodule
