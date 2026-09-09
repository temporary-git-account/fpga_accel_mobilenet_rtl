# args: RTL file, output directory. Synthesis equivalence gate, not timing proof.
set src [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
create_project -in_memory -part xc7z010clg400-1
read_verilog -sv $src
synth_design -top requantize -part xc7z010clg400-1 -mode out_of_context
write_verilog -force -mode funcsim [file join $out requantize_netlist.v]
write_checkpoint -force [file join $out quant.dcp]
report_utilization -file [file join $out utilization.rpt]
exit
