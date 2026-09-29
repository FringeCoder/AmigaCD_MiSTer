# What STA knows about the external SDRAM interface, and what it does not.
#
# Run against an existing fit -- no re-fit needed:
#
#     quartus_sta -t seed_sweep/report_io.tcl AmigaCD
#
# Prints the clocks the design actually has (names matter for writing
# set_output_delay against the right one), then every unconstrained path
# endpoint. The SDRAM pins are expected in that second list: neither
# AmigaCD.sdc nor sys/sys_top.sdc carries a set_input_delay or
# set_output_delay, so nothing times the bus the 68020 fetches its reset
# vectors through.

project_open AmigaCD
create_timing_netlist
read_sdc
update_timing_netlist

puts "=== clocks ==="
foreach_in_collection c [all_clocks] {
    puts [format "  %-28s period %-10s source %s" \
        [get_clock_info -name $c] \
        [get_clock_info -period $c] \
        [get_clock_info -targets $c]]
}

puts "\n=== what drives SDRAM_CLK ==="
if {[llength [query_collection -report [get_ports -nowarn SDRAM_CLK]]] > 0} {
    foreach_in_collection p [get_ports SDRAM_CLK] {
        puts "  port: [get_port_info -name $p]"
    }
} else {
    puts "  (no SDRAM_CLK port in this netlist)"
}

puts "\n=== unconstrained path endpoints ==="
# report_ucp writes its own panels; the summary line is what we want in the log.
report_ucp -stdout

puts "\n=== SDRAM ports seen by the netlist ==="
set n 0
foreach_in_collection p [get_ports -nowarn SDRAM_*] {
    incr n
}
puts "  $n ports matching SDRAM_*"

project_close
