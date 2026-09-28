project_open AmigaCD
create_timing_netlist
read_sdc
update_timing_netlist
puts "=== worst setup paths to the SDRAM pins ==="
report_timing -setup -npaths 3 -detail summary -to [get_ports {SDRAM_A[*]}] -stdout
puts "=== launch/latch edges on one address pin ==="
report_timing -setup -npaths 1 -detail full_path -to [get_ports {SDRAM_A[0]}] -stdout
project_close
