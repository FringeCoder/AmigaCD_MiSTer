# The worst setup and hold paths of a fitted project, for every operating
# corner, appended to the file named by the third argument. Run by
# scripts/ci-fit.sh after the flow, so a fit that misses timing says WHERE in
# the job log -- the .rpt files travel as an artifact, but a failure should be
# readable without downloading anything.
#
#   quartus_sta -t scripts/ci-sta-paths.tcl <project> <npaths> <out.rpt>
set proj  [lindex $quartus(args) 0]
set npath [lindex $quartus(args) 1]
set out   [lindex $quartus(args) 2]

project_open $proj -revision $proj
create_timing_netlist
read_sdc
update_timing_netlist

foreach_in_collection oc [get_available_operating_conditions] {
	set_operating_conditions $oc
	update_timing_netlist
	set name [get_operating_conditions_info -display_name $oc]
	foreach kind {setup hold} {
		report_timing -$kind -npaths $npath -detail summary \
			-panel_name "$kind, $name" -file $out -append
	}
	# The single worst setup path, cell by cell. The summary says which path;
	# this says why -- a multiplier in ALM logic instead of a DSP block, or a
	# route that crosses the die, look the same in a summary row.
	report_timing -setup -npaths 1 -detail full_path \
		-panel_name "worst setup detail, $name" -file $out -append
}

delete_timing_netlist
project_close
