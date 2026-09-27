project_open AmigaCD
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -hold -npaths 4 -detail summary -stdout
project_close
