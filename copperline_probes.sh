#!/usr/bin/env bash
#
# Fetch Copperline and build its 68k probe disks, so the probes can be run on
# this core.
#
# Why this exists: docs/core-accuracy-todo.md opens with "How we verify, given
# no reference Amiga", and SUITE -- a test program run on the core, scored
# against published reference values -- is the only route there that needs
# neither a reference Amiga nor a simulator. Until now the only SUITE instrument
# was vAmigaTS. Copperline ships a second one: ~50 bootblock probes with
# committed reference values, including 22 rows measured on a stock A1200.
#
# What this builds:
#
#   probesrv.adf    A resident serial-driven loader. Boot it once and it serves
#                   the serial port forever: upload a probe binary, run it, read
#                   the probe's output back. This is the one that matters -- it
#                   turns "run a probe on the core" into seconds over a wire
#                   instead of an SD-card round trip and a photograph.
#   timing-test.adf The 32-row CPU and chip-bus timing probe, standalone.
#   accelprobe.adf  The same shape for 020/030/040/060.
#   <probe>.adf     Any other committed probe, by name (see --list).
#
# vasm is NOT required. Copperline commits the assembled .bin for every probe,
# and make_adf.py wraps a .bin into a bootable ADF with nothing but python3.
# You only need vasm (vasmm68k_mot) if you modify a probe's source.
#
# Nothing here is vendored into this repository: Copperline is GPL-3.0-or-later,
# same as this core, but its probe binaries are build artifacts of another
# project and are better fetched than copied. The clone lands in build/ which is
# gitignored.
#
# Usage:
#   ./copperline_probes.sh                 # fetch + build the three disks above
#   ./copperline_probes.sh --list          # list every available probe
#   ./copperline_probes.sh ddfprobe-cc     # build one named probe's ADF
#   ./copperline_probes.sh --update        # re-fetch at PIN below
#
# See docs/copperline-verification.md for what to do with the disks, the
# real-hardware reference column, and what is and is not trustworthy in it.

set -euo pipefail
cd "$(dirname "$0")"

# The revision this was validated against on 2026-09-13. Its golden-render test
# (cargo test --release --test probe_golden) passed here, which is what makes
# the reference values in docs/copperline-verification.md quotable. Bump
# deliberately, and re-read that doc's caveats when you do.
PIN="0565bcca9676c9e8835d64d5a94f71063973db94"
REPO="https://github.com/CopperlineHQ/Copperline.git"
WORK="build/copperline"
OUT="build/probes"

need() {
	command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required but not on PATH" >&2; exit 1; }
}
need git
need python3

fetch() {
	if [ ! -d "$WORK/.git" ]; then
		mkdir -p "$(dirname "$WORK")"
		echo "fetching Copperline into $WORK ..."
		git clone --quiet --filter=blob:none "$REPO" "$WORK"
	fi
	git -C "$WORK" fetch --quiet origin "$PIN" 2>/dev/null || git -C "$WORK" fetch --quiet origin
	git -C "$WORK" checkout --quiet "$PIN"
	echo "Copperline at $(git -C "$WORK" log -1 --format='%h %ad' --date=short) (pinned)"
}

build_one() {
	local name="$1" bin="$WORK/timing-test/$1.bin"
	if [ ! -f "$bin" ]; then
		echo "error: no committed binary for probe '$name'" >&2
		echo "       run '$0 --list' to see what is available" >&2
		return 1
	fi
	mkdir -p "$OUT"
	( cd "$WORK/timing-test" && python3 make_adf.py boot.bin "$name.bin" \
		"$OLDPWD/$OUT/$name.adf" ) >/dev/null
	echo "  $OUT/$name.adf"
}

case "${1:-}" in
--list)
	fetch
	echo "probes with a committed binary:"
	( cd "$WORK/timing-test" && ls *.bin | sed 's/\.bin$//' | grep -v '^boot$' | sed 's/^/  /' )
	exit 0
	;;
--update)
	rm -rf "$WORK"
	fetch
	exit 0
	;;
"")
	fetch
	echo "building:"
	# test.bin is the timing test; every other probe's ADF is named after it.
	mkdir -p "$OUT"
	( cd "$WORK/timing-test" && python3 make_adf.py boot.bin test.bin \
		"$OLDPWD/$OUT/timing-test.adf" ) >/dev/null
	echo "  $OUT/timing-test.adf"
	build_one probesrv
	build_one accelprobe
	echo
	echo "Boot $OUT/probesrv.adf on the core, then drive it with Copperline's"
	echo "host harness over the core's serial link:"
	echo
	echo "  $WORK/tools/hwrig/hwrig.py --port /dev/ttyUSB0 run \\"
	echo "      $WORK/timing-test/test.bin"
	echo
	echo "See docs/copperline-verification.md."
	;;
--*)
	echo "error: unknown option $1" >&2
	exit 1
	;;
*)
	fetch
	echo "building:"
	build_one "$1"
	;;
esac
