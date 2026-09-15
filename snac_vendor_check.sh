#!/usr/bin/env bash
#
# Check rtl/snac_psx.v against the canonical copy, or refresh the stamp.
#
# rtl/snac_psx.v is copied from FringeCoder/AmigaCD, the userspace repo, which
# owns it -- see rtl/README.md there and the module's own header. MiSTer core
# repositories are self-contained Quartus projects with no submodule or package
# step anywhere in the toolchain, so copying is the platform's convention; the
# cost of that convention is drift, and this is the control for it.
#
# This is the same script FringeCoder/Menu_MiSTer runs, on the same module, so
# the two copies are held to the same stamp rather than to each other. That
# matters: a check that compared the two CORES would pass while both drifted
# away from the file they were taken from.
#
# Two modes:
#
#   ./snac_vendor_check.sh                      Verify the local copy still
#                                               hashes to what rtl/snac_psx.vendor
#                                               records. This is what CI runs:
#                                               it needs no second checkout and
#                                               catches the copy being edited
#                                               here, which is the common case.
#
#   ./snac_vendor_check.sh /path/to/amigacd     Also diff against a real
#                                               checkout of the canonical repo,
#                                               which is the only way to catch
#                                               the canonical side having moved.
#
#   ./snac_vendor_check.sh --stamp /path/...    Re-vendor: copy the module
#                                               across and rewrite the stamp.
#
# CI deliberately runs only the first mode. A job here cannot read the other
# repository without a token configured for it, and a check that silently
# degrades to "skipped" when the token is absent is worse than no check at all.

set -euo pipefail
cd "$(dirname "$0")"

VENDOR="rtl/snac_psx.vendor"
MODULE="rtl/snac_psx.v"

[ -f "$VENDOR" ] || { echo "error: $VENDOR is missing" >&2; exit 1; }

stamp_field() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$VENDOR" | head -1; }

WANT_SHA=$(stamp_field sha256)
WANT_REPO=$(stamp_field repo)
CANON_PATH=$(stamp_field path)

STAMP=0
if [ "${1:-}" = "--stamp" ]; then STAMP=1; shift; fi
CANON="${1:-}"

if [ "$STAMP" = 1 ]; then
	[ -n "$CANON" ] || { echo "error: --stamp needs a path to a $WANT_REPO checkout" >&2; exit 1; }
	[ -f "$CANON/$CANON_PATH" ] || { echo "error: $CANON/$CANON_PATH not found" >&2; exit 1; }

	# Refuse a checkout that is not the repo the stamp names. --stamp writes
	# whatever HEAD it is pointed at, with no check on WHERE that HEAD is, and
	# that is not hypothetical: the Menu core's stamp recorded a commit in this
	# repository for months because someone ran it against a core checkout. The
	# sha256 matched throughout, so nothing ever failed -- the stamp simply
	# named a repo that would have been re-vendored FROM rather than the one a
	# fix lands in.
	# Matched on the TAIL of the URL, not as a substring. A substring test looks
	# right and is not: FringeCoder/AmigaCD is a prefix of
	# FringeCoder/AmigaCD_MiSTer, so `case $ORIGIN in *$WANT_REPO*)` would wave
	# through a checkout of the core -- which is precisely the repository this
	# guard exists to reject.
	ORIGIN=$(git -C "$CANON" remote get-url origin 2>/dev/null || echo "")
	ORIGIN_SLUG=${ORIGIN%.git}; ORIGIN_SLUG=${ORIGIN_SLUG%/}
	ORIGIN_SLUG=$(printf '%s' "$ORIGIN_SLUG" | sed -e 's#^.*[:/]\([^:/][^:/]*/[^/][^/]*\)$#\1#')
	if [ -z "$ORIGIN" ]; then
		echo "warning: $CANON has no origin remote; cannot confirm it is $WANT_REPO" >&2
	elif [ "${ORIGIN_SLUG,,}" != "${WANT_REPO,,}" ]; then
		echo "error: $CANON is not a $WANT_REPO checkout (origin: $ORIGIN)." >&2
		echo "       Point --stamp at the repo that OWNS the module, not at another copy." >&2
		exit 1
	fi

	cp "$CANON/$CANON_PATH" "$MODULE"
	NEW_SHA=$(sha256sum "$MODULE" | cut -d' ' -f1)
	# The commit that last touched THE FILE, not the checkout's HEAD. HEAD is
	# whatever the canonical repo happened to be on that day -- usually a commit
	# that did not touch this module at all -- and the one question the stamp
	# has to answer during a drift investigation is "which change am I diffing
	# against". The sha256 pins the bytes; this pins the change that produced
	# them.
	NEW_COMMIT=$(git -C "$CANON" log -1 --format=%H -- "$CANON_PATH" 2>/dev/null || echo "")
	[ -n "$NEW_COMMIT" ] || NEW_COMMIT=$(git -C "$CANON" rev-parse HEAD 2>/dev/null || echo "unknown")
	sed -i "s/^sha256 .*/sha256 = $NEW_SHA/; s/^commit .*/commit = $NEW_COMMIT/; s/^vendored .*/vendored = $(date -u +%Y-%m-%d)/" "$VENDOR"
	echo "re-vendored from $CANON"
	echo "  commit $NEW_COMMIT"
	echo "  sha256 $NEW_SHA"
	echo
	echo "Now run syntax_check.sh, and the bench in FringeCoder/Menu_MiSTer"
	echo "(rtl/sim/snac_psx/) -- this repository has no bench for the module."
	exit 0
fi

GOT_SHA=$(sha256sum "$MODULE" | cut -d' ' -f1)
if [ "$GOT_SHA" != "$WANT_SHA" ]; then
	echo "FAIL $MODULE does not match the vendor stamp."
	echo "  recorded $WANT_SHA"
	echo "  actual   $GOT_SHA"
	echo
	echo "Either this copy was edited in place -- don't; it is not canonical, fix"
	echo "it in $WANT_REPO and re-vendor -- or a re-vendor updated the file and"
	echo "left $VENDOR behind. Refresh with:"
	echo "  ./snac_vendor_check.sh --stamp /path/to/amigacd-checkout"
	exit 1
fi
echo "OK   $MODULE matches the vendor stamp ($GOT_SHA)"

if [ -n "$CANON" ]; then
	[ -f "$CANON/$CANON_PATH" ] || { echo "error: $CANON/$CANON_PATH not found" >&2; exit 1; }
	if diff -u "$CANON/$CANON_PATH" "$MODULE"; then
		echo "OK   identical to the canonical copy in $CANON"
	else
		echo
		echo "FAIL the canonical copy has moved. Re-vendor:"
		echo "  ./snac_vendor_check.sh --stamp $CANON"
		exit 1
	fi
fi
