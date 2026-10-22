#!/usr/bin/env python3
# Generate sdram_ctrl_sim.v from the real rtl/sdram_ctrl.v for ModelSim ASE.
# Quartus elaborates module-scope signals order-independently; ModelSim -sv
# requires declaration-before-use. We hoist exactly the forward-referenced
# declarations to just after the port list. Behavior-identical -- this copy is
# ONLY for the tb_sdram_fwd sim; the real file is never reordered.
import os

SRC = os.path.join(os.path.dirname(__file__), "..", "..", "sdram_ctrl.v")
DST = os.path.join(os.path.dirname(__file__), "sdram_ctrl_sim.v")

c = open(SRC, "r", newline="").read()

# Take the line ending from the file rather than assuming CRLF. Git checks this
# file out with LF on Linux, so a hard-coded "\r\n" makes every hoist anchor
# miss and the script dies on its own assertion -- which is exactly what CI hit.
NL = "\r\n" if "\r\n" in c else "\n"

# the exact declaration lines that are used before their point of declaration
hoist = [
    "reg cache_fill;",
    "reg       init_done;",
    "reg [3:0] sdram_state;",
    "reg  [2:0] slot_type = IDLE;",
    "reg [15:0] sdata_reg;",
    "reg        chipWE;",
]
for d in hoist:
    n = c.count(d + NL)
    assert n == 1, f"hoist anchor {d!r} count {n} != 1"
    c = c.replace(d + NL, "", 1)   # remove original declaration

# ModelSim won't accept procedural assignment to an `inout reg`; convert the
# tristate SDRAM data pad to a net driven by an internal reg (sd_data_o sits at
# Z for our read-only test, so the bench's read pattern always wins). Upstream
# 26eb46a made it a net in the real file, and its 2026-10-20 re-landing
# (ec1353dc) went back to the `inout reg`, so this conversion is back too --
# now for every procedural driver, since that controller writes it from three
# places (Z, datawr, and datawr2 for the second half of a 32-bit chip write).
import re
def sub1(old, new):
    global c
    assert c.count(old) == 1, f"sd_data anchor {old!r} count {c.count(old)} != 1"
    c = c.replace(old, new, 1)

sub1("\tinout  reg [15:0] sd_data," + NL, "\tinout      [15:0] sd_data," + NL)
c, n = re.subn(r"\bsd_data(\s*<=)", r"sd_data_o\1", c)
assert n >= 3, f"expected the three procedural sd_data drivers, found {n}"

block = (
    "// --- sim-only forward declarations (hoisted for ModelSim -sv) ---" + NL
    + "reg [15:0] sd_data_o = 16'hzzzz;" + NL
    + "assign sd_data = sd_data_o;" + NL
    + NL.join(hoist) + NL
)
# insert AFTER the localparam block (slot_type's initializer references IDLE);
# CPU_WRITECACHE closes it (REFRESH did while upstream 26eb46a's controller
# was in, until ec1353dc took it back out).
anchor = "\tCPU_WRITECACHE = 3;" + NL
assert c.count(anchor) == 1
c = c.replace(anchor, anchor + NL + block, 1)

open(DST, "w", newline="").write(c)
print(f"wrote {DST} ({len(hoist)} decls hoisted)")
