#!/usr/bin/env bash
# Fit one placement seed of a Quartus project in CI, and say whether it met
# timing. Used by .github/workflows/fit.yml, one job per seed.
#
#   scripts/ci-fit.sh <project> <seed>
#
# Runs the whole flow (map, fit, asm, sta) in the Quartus 17.0.2 Lite image
# for Cyclone V -- the version the .qsf was last saved with -- and writes
# fit.json:
#
#   {"seed": 4, "setup": 0.123, "hold": 0.045, "ok": true}
#
# "ok" means BOTH worst-case slacks are positive. A hold violation fails at
# every clock, so a good setup number never excuses it; seed_sweep_both.sh
# records how ranking on setup alone nearly shipped a -0.346 hold build.
#
# A slack that cannot be read is a failure, not a zero. The local sweep scripts
# default a missing number to 0, which is "fine" to a reader; here it means the
# report was not produced and nothing about the build is known.
#
# The seed is changed in the .qsf of this checkout only. Each seed runs in its
# own job and checkout, so two fits never share db/ or output_files/ -- the one
# thing the local sweep has to wait to avoid.
set -euo pipefail
proj=${1:?project}; seed=${2:?seed}
IMAGE=${QUARTUS_IMAGE:-theypsilon/quartus-lite-c5:17.0.2.docker1}

case "$seed" in ''|*[!0-9]*) echo "seed must be a number: '$seed'" >&2; exit 2;; esac

sed -i -E "s/^(set_global_assignment -name SEED) .*/\1 $seed/" "$proj.qsf"
grep -q "^set_global_assignment -name SEED $seed\$" "$proj.qsf" || \
	echo "set_global_assignment -name SEED $seed" >> "$proj.qsf"

status=0
docker run --rm -v "$PWD":/project -w /project "$IMAGE" \
	quartus_sh --flow compile "$proj" -c "$proj" > "fit_$seed.log" 2>&1 || status=$?
tail -40 "fit_$seed.log"
# What the fit used. A path that slows by a nanosecond with no change to its
# own source usually means the fitter ran out of something -- DSP blocks most
# of all, which turns a hard multiplier into ALM logic -- and only this says so.
cat "output_files/$proj.fit.summary" 2>/dev/null || echo "no fit summary"

rpt="output_files/$proj.sta.rpt"
slack() {   # the worst of every corner's figure, so no corner hides a failure
	grep -hoE "Worst-case $1 slack is [-0-9.]+" "$rpt" 2>/dev/null \
		| grep -oE "[-0-9.]+$" | sort -g | head -1
}
setup=$(slack setup || true); hold=$(slack hold || true)

ok=false
if [ "$status" = 0 ] && [ -n "$setup" ] && [ -n "$hold" ] && [ -s "output_files/$proj.rbf" ] \
   && awk -v a="$setup" -v b="$hold" 'BEGIN{exit !(a>0 && b>0)}'; then
	ok=true
fi
# Where it failed, when it did. The slack figures above say how much; this
# says which paths, in the job log itself (scripts/ci-sta-paths.tcl). Seconds
# against a 40-minute fit, and it only runs when there is something to show.
if [ "$ok" != true ] && [ -d db ]; then
	rm -f "paths_$seed.rpt"
	docker run --rm -v "$PWD":/project -w /project "$IMAGE" \
		quartus_sta -t scripts/ci-sta-paths.tcl "$proj" 25 "paths_$seed.rpt" > "paths_$seed.log" 2>&1 || true
	if [ -s "paths_$seed.rpt" ]; then head -1500 "paths_$seed.rpt"
	else echo "no path report; quartus_sta said:"; tail -30 "paths_$seed.log"; fi
fi

printf '{"seed": %s, "setup": %s, "hold": %s, "ok": %s, "flow_status": %s}\n' \
	"$seed" "${setup:-null}" "${hold:-null}" "$ok" "$status" | tee fit.json

# The flow failing outright is this job's failure. Missing timing is reported
# in fit.json and judged by the caller, which knows whether it is a release.
[ "$status" = 0 ] && [ -s "output_files/$proj.rbf" ]
