#!/usr/bin/env bash
# Re-fit ONE named seed and assemble it. "Fit exactly this seed and give me the
# bitstream" is worth having as its own thing, so this survives where the two
# sweep scripts beside it did not.
#
# It used to print the setup slack and nothing else, which is how a build with a
# hold violation can look fine in the terminal. A hold violation is not a
# slower-clock problem -- it fails at every frequency -- so this now reports
# BOTH and exits non-zero if either is negative. The .rbf is still written
# either way; you may well want a failing build to test with, but you should
# have to notice that it fails.
set -u
Q=/c/intelFPGA_lite/17.0/quartus/bin64
OUT=seed_sweep
SEED=${1:?usage: refit_one.sh <seed>}
mkdir -p "$OUT"

# Never two fits in THIS tree: they share db/ and output_files/ and interleave
# silently, and nothing from such a window can be trusted.
#
# Scoped to the tree, which the earlier version was not. It waited on any
# quartus_* process anywhere on the machine, so a fit in a separate git
# worktree -- with its own db/ and its own output_files/ -- was blocked for no
# reason. That cost real time: a nineteen-fit search for a matched A/B pair ran
# strictly serially at about twenty-five minutes a fit.
#
# There is headroom to use. The project sets NUM_PARALLEL_PROCESSORS ALL, and a
# fit measured 30:55 elapsed against 2:13:50 of CPU -- 4.3x parallel on a
# sixteen-core machine. Resident peak is around 2.7 GB against 15.6 GB of RAM,
# so two or three concurrent fits in separate worktrees fit comfortably and
# nearly multiply throughput.
#
# A lock file rather than a process scan, because a process scan cannot tell
# which database a quartus_fit has open.
LOCK="$OUT/.fit.lock"
mkdir -p "$OUT"
while true; do
    if [ -f "$LOCK" ]; then
        other=$(cat "$LOCK" 2>/dev/null)
        # A lock left behind by a killed run must not block forever.
        if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
            echo "waiting for the fit already running in this tree (pid $other)..."
            sleep 30
            continue
        fi
        echo "clearing a stale lock from pid ${other:-unknown}"
        rm -f "$LOCK"
    fi
    echo $$ > "$LOCK"
    # Re-read: if two invocations raced, the loser sees the winner's pid here.
    [ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && break
done
trap 'rm -f "$LOCK"' EXIT INT TERM

"$Q/quartus_fit" --seed="$SEED" AmigaCD > "$OUT/one_fit_$SEED.log" 2>&1 || {
    echo "seed $SEED: FIT FAILED, see $OUT/one_fit_$SEED.log"; exit 1; }
"$Q/quartus_sta" AmigaCD > "$OUT/one_sta_$SEED.log" 2>&1

# Read both from THIS run's report.
su=$(grep -oE "Worst-case setup slack is [-0-9.]+" output_files/AmigaCD.sta.rpt | tail -1 | grep -oE "[-0-9.]+$")
ho=$(grep -oE "Worst-case hold slack is [-0-9.]+"  output_files/AmigaCD.sta.rpt | tail -1 | grep -oE "[-0-9.]+$")
su=${su:-0}; ho=${ho:-0}

# Dump the worst paths for BOTH corners while this build is still the one in
# db/. Learnt the hard way: a pair of arms was fitted back to back, the second
# overwrote the database, and the -0.495 ns hold path from the first was gone
# before it was read -- so the question it would have answered (whether the
# violation was the change or the placement) needed another twenty-five minute
# fit to ask again.
cat > "$OUT/paths_$SEED.tcl" <<'TCL'
project_open AmigaCD
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 3 -detail path_only -stdout
report_timing -hold  -npaths 3 -detail path_only -stdout
TCL
"$Q/quartus_sta" -t "$OUT/paths_$SEED.tcl" > "$OUT/paths_$SEED.log" 2>&1 || true

# The hash of everything that was actually synthesised.
#
# A recorded slack is comparable only to one built from the same sources, and
# assuming otherwise produced a retracted claim: +0.386 at seed 18 was compared
# against +0.050 at seed 18 and the 0.336 ns difference attributed to database
# state, when in fact rtl/akiko.v differed between the two commits. With this in
# the record the comparison is checkable instead of assumed.
# git ls-files gives the FILE LIST, respecting what is tracked; the hash is
# over the working tree, not the index. Hashing the index would miss an
# unstaged edit, which is precisely the case this is meant to catch.
src_hash=$(git ls-files -- 'rtl/*.v' 'rtl/*.sv' 'AmigaCD.sv' 'AmigaCD.sdc' 'AmigaCD.qsf' 2>/dev/null \
           | grep -vE 'rtl/sim/' | sort | xargs sha1sum 2>/dev/null \
           | sha1sum | cut -c1-12)

"$Q/quartus_asm" AmigaCD > "$OUT/one_asm_$SEED.log" 2>&1
cp output_files/AmigaCD.rbf "$OUT/AmigaCD_final_seed$SEED.rbf"

printf "seed %s  setup %s  hold %s  src %s  -- rbf saved to %s/AmigaCD_final_seed%s.rbf\n" \
       "$SEED" "$su" "$ho" "${src_hash:-unknown}" "$OUT" "$SEED"
echo "worst paths: $OUT/paths_$SEED.log"

bad=$(awk -v a="$su" -v b="$ho" 'BEGIN{print (a<=0 || b<=0) ? 1 : 0}')
if [ "$bad" = "1" ]; then
    echo "*** THIS BUILD DOES NOT MEET TIMING. Do not ship it. ***"
    exit 2
fi
