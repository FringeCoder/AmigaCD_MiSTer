project_open AmigaCD
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -hold -npaths 1 -detail full_path -to [get_keepers {*sdata_reg[2]*}] -stdout
puts "=== multicycles that matched ==="
report_exceptions -stdout
project_close
