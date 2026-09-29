#!/usr/bin/env bash
#
# Fail on the Icarus warnings that mean a bench is silently testing the wrong
# thing.
#
# Icarus does not error on a port width mismatch or on an omitted port. It pads,
# prints a warning, and carries on. Both cost this project real time:
#
#   * tb_ss_regbus_mux was red across four PRs. An 8-bit sh_ld_addr against a
#     9-bit module port was padded, which put the window it tested out of reach.
#     The warning was there in every run.
#   * tb_akiko_txrx_dma failed 36 of its 48 checks because its akiko instance
#     OMITTED dma_arm. An omitted input is z, not an error, so no engine was ever
#     claimed and every transfer stalled after one byte.
#   * tb_akiko_pbx_dma still compiles with ss_ld_data padded from 1 bit to 1052.
#     Harmless while ss_ld is low, and it is the same class of bug, and its
#     warning would mask a real one.
#
# Usage: check-icarus-warnings.sh <iverilog args...>
#
# Compiles with the given arguments and exits non-zero if any padding or width
# warning appears. Anything genuinely intended -- a deliberately stubbed port --
# should be written as an explicit sized literal, not left to the padder.
set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# Deliberately not -Wall: Icarus's implicit-port and timescale warnings are noisy
# across this tree and are a separate cleanup. These two patterns are the ones
# that silently change what a bench tests.
if ! iverilog "$@" 2>&1 | tee "$log"; then
	echo "check-icarus-warnings: compilation failed"
	exit 1
fi

if grep -qE "Padding [0-9]+ (high|low) bits|expects [0-9]+ bits, got [0-9]+" "$log"; then
	echo
	echo "check-icarus-warnings: a port width was padded rather than matched."
	echo
	grep -nE "Padding [0-9]+ (high|low) bits|expects [0-9]+ bits, got [0-9]+" "$log" | sed 's/^/    /'
	echo
	echo "Icarus pads instead of erroring, so the bench still runs -- testing"
	echo "something other than what it says. Size the connection explicitly."
	exit 1
fi

echo "check-icarus-warnings: no padded ports"
