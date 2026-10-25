# The worst setup slack of each recurring path family, one line per family,
# for every fitted seed -- the ones that close timing included.
#
#   quartus_sta -t scripts/ci-sta-families.tcl <project> <out.txt> [detail.rpt]
#
# Written because the seed sweep was a lottery nobody could read: a seed that
# closed printed nothing about its margins, a seed that failed printed its 25
# worst rows, and in 47 of 58 failing seeds all 25 were the same family
# (chipset -> sdram_ctrl sd_addr), so the walls behind it were never visible.
# This reports every family on every seed, so an RTL change can be judged by
# how it moves each family across a fixed panel of seeds rather than by which
# seed happened to win.
#
# The families come from parsing those 58 failing seeds (run 38981136987 and
# 38985775946). The sd_addr family is also split by SOURCE module, which is the
# what-if the plan needs: it shows how far each block's cone is from closing on
# its own, so cutting one source shows what is left behind it.
#
# Output lines are "<family> <slack|none>", slack the minimum over every
# operating corner. "none" means the collection was empty -- a pattern that no
# longer matches anything, which is itself worth seeing.
set proj [lindex $quartus(args) 0]
set out  [lindex $quartus(args) 1]
set detail [lindex $quartus(args) 2]

project_open $proj -revision $proj
create_timing_netlist
read_sdc
update_timing_netlist

set clk114 [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set clksys [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}]

# name  from-spec  to-spec. A spec of "" is unrestricted; one starting "clk:" is
# a clock (-from_clock / -to_clock); anything else is a node pattern.
set families {
	{A_sys_to_sd_addr     clk:sys                          {emu|ram1|sd_addr*}}
	{A.CIAB               {emu|minimig|CIAB1|*}            {emu|ram1|sd_addr*}}
	{A.CIAA               {emu|minimig|CIAA1|*}            {emu|ram1|sd_addr*}}
	{A.PAULA              {emu|minimig|PAULA1|*}           {emu|ram1|sd_addr*}}
	{A.AGNUS              {emu|minimig|AGNUS1|*}           {emu|ram1|sd_addr*}}
	{A.DENISE             {emu|minimig|DENISE1|*}          {emu|ram1|sd_addr*}}
	{A.GARY               {emu|minimig|GARY1|*}            {emu|ram1|sd_addr*}}
	{A.USERIO             {emu|minimig|USERIO1|*}          {emu|ram1|sd_addr*}}
	{A.CPU1_bridge        {emu|minimig|CPU1|*}             {emu|ram1|sd_addr*}}
	{A.cpu_wrapper        {emu|cpu_wrapper|*}              {emu|ram1|sd_addr*}}
	{A.amiga_clk          {emu|amiga_clk|*}                {emu|ram1|sd_addr*}}
	{A.chipdma_arb        {emu|chipdma_arb|*}              {emu|ram1|sd_addr*}}
	{B_114_to_sd_addr     clk:114                          {emu|ram1|sd_addr*}}
	{B.ss_ctrl            {emu|savestate|*}                {emu|ram1|sd_addr*}}
	{B.sdram_ctrl         {emu|ram1|*}                     {emu|ram1|sd_addr*}}
	{E.ss_to_sdram_cache  {emu|savestate|*}                {emu|ram1|cpu_cache|*}}
	{C.sdram_cache        {emu|ram1|cpu_cache|*}           {emu|ram1|cpu_cache|*}}
	{D.sdram_dat_to_cpu   {emu|ram1|cpu_cache|*}           {emu|cpu_wrapper|*}}
	{F.ddram_cache        {emu|ram2|cpu_cache|*}           {emu|ram2|cpu_cache|*}}
	{G.ddram_dat_to_cpu   {emu|ram2|cpu_cache|*}           {emu|cpu_wrapper|*}}
	{H.ddram_ctrl         {emu|ram2|*}                     {emu|ram2|*}}
	{J.f2sdram_to_ddram   {sysmem|*}                       {emu|ram2|*}}
	{K.to_drive_sounds    ""                               {emu|drive_sounds|*}}
	{L.ss_ctrl_internal   {emu|savestate|*}                {emu|savestate|*}}
	{N.a2065_arb_to_ddram {emu|ram2|arbiter|*}             {emu|ram2|*}}
	{P.ascal_palette      {ascal|pal_*}                    {ascal|*}}
	{M.ascal              ""                               {ascal|*}}
	{Q.rdgate_to_cpu      {emu|ram_cs emu|cpu_rdgate|*}     {emu|cpu_wrapper|cpu_inst_p|*}}
	{R.sdram_refresh      {emu|ram1|rcnt*}                 {emu|ram1|sd_*}}
	{all_setup            ""                               ""}
}

proc spec_args {kind spec} {
	global clk114 clksys
	if {$spec eq ""} { return {} }
	if {$spec eq "clk:sys"} { return [list -${kind}_clock $clksys] }
	if {$spec eq "clk:114"} { return [list -${kind}_clock $clk114] }
	return [list -$kind $spec]
}

array set worst {}
foreach_in_collection oc [get_available_operating_conditions] {
	set_operating_conditions $oc
	update_timing_netlist
	foreach f $families {
		lassign $f name from to
		set args [concat [spec_args from $from] [spec_args to $to]]
		set paths [eval get_timing_paths -setup -npaths 1 $args]
		foreach_in_collection p $paths {
			set s [get_path_info $p -slack]
			if {![info exists worst($name)] || $s < $worst($name)} { set worst($name) $s }
		}
	}
}

# The paths behind a number. A family's slack says how far it is from closing;
# restructuring it needs its endpoints and the logic between, and the
# 25-row worst-path report only ever shows whichever family is worst. So for
# the families named here -- every one that still fails on some seed -- the
# ten worst paths each, at the slow 100 C corner
# the gate uses, with every node on the data path.
set detail_families {A_sys_to_sd_addr A.AGNUS A.USERIO A.CIAB L.ss_ctrl_internal H.ddram_ctrl F.ddram_cache
	D.sdram_dat_to_cpu G.ddram_dat_to_cpu C.sdram_cache M.ascal Q.rdgate_to_cpu R.sdram_refresh}
if {$detail ne ""} {
	file delete -force $detail
	foreach_in_collection oc [get_available_operating_conditions] {
		if {[string match -nocase {*slow*100C*} [get_operating_conditions_info -display_name $oc]]} {
			set_operating_conditions $oc
			update_timing_netlist
		}
	}
	foreach f $families {
		lassign $f name from to
		if {[lsearch -exact $detail_families $name] < 0} { continue }
		set args [concat [spec_args from $from] [spec_args to $to]]
		eval report_timing -setup -npaths 10 -detail path_only $args \
			-panel_name [list $name] -file [list $detail] -append
	}
}

set fh [open $out w]
foreach f $families {
	set name [lindex $f 0]
	if {[info exists worst($name)]} {
		puts $fh [format "%s %.3f" $name $worst($name)]
	} else {
		puts $fh "$name none"
	}
}
close $fh

delete_timing_netlist
project_close
