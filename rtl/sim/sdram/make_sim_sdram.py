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

# The tristate SDRAM data pad used to be an `inout reg`, which ModelSim will
# not drive procedurally, so it was rewritten to a net here. Since upstream
# 26eb46a the real file already has it as a net (`assign sd_data = sd_oe ?
# ...`), and there is nothing left to convert.
assert c.count("\tinout      [15:0] sd_data," + NL) == 1, "sd_data is no longer the net this copy assumes"

block = (
    "// --- sim-only forward declarations (hoisted for ModelSim -sv) ---" + NL
    + NL.join(hoist) + NL
)
# insert AFTER the localparam block (slot_type's initializer references IDLE);
# REFRESH has closed it since upstream 26eb46a, CPU_WRITECACHE before that.
anchor = "\tREFRESH = 4;" + NL
assert c.count(anchor) == 1
c = c.replace(anchor, anchor + NL + block, 1)

open(DST, "w", newline="").write(c)
print(f"wrote {DST} ({len(hoist)} decls hoisted)")
