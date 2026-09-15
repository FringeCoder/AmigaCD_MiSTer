#!/usr/bin/env python3
"""Turn one Copperline beam sample into a reference-table row.

Its own file rather than a heredoc inside copperline-beamtable.sh: the shell
script already nests one heredoc, and a second one sharing a delimiter is how
that script silently stopped being the script anyone read.

Reads three JSON-RPC replies on the command line -- beam.get, VPOSR, VHPOSR --
all taken at the same stopped instant, and writes one tab-separated row.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: copperline-beamrow.py <beam.get> <vposr> <vhposr>",
              file=sys.stderr)
        return 2

    beam = json.loads(sys.argv[1])["result"]
    vposr = json.loads(sys.argv[2])["result"]["value"]
    vhposr = json.loads(sys.argv[3])["result"]["value"]

    vpos = beam["vpos"]
    hpos = beam["hpos"]

    # Signed and wrapped into the 8-bit field the register actually carries, so
    # a sample straddling the line end reads as a small delta instead of -227.
    dhpos = ((vhposr & 0xFF) - hpos + 128) % 256 - 128

    # The origin-independent columns. The two implementations need not share an
    # hpos zero point for these to be comparable: they ask only whether the
    # readback describes the beam position it was taken at. vhposr[15:8] is the
    # low byte of vpos; vposr[0] is vpos[8].
    vok = int((vhposr >> 8) == (vpos & 0xFF))
    pok = int((vposr & 1) == ((vpos >> 8) & 1))

    print("%d\t%d\t0x%04X\t0x%04X\t%d\t%d\t%d"
          % (vpos, hpos, vposr, vhposr, dhpos, vok, pok))
    return 0


if __name__ == "__main__":
    sys.exit(main())
