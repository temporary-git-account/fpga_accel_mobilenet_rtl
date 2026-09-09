# Board-free full PS7 + accelerator implementation. Keeps each clock candidate
# in its own build directory. PS GP0/HP0 stay at 100 MHz; SmartConnect crosses
# to the selected core FCLK1 clock. No timing exceptions are added here.
set soc [file dirname [file normalize [info script]]]
set root [file normalize [file join $soc ..]]
set mhz [expr {[llength $argv] ? [lindex $argv 0] : 166.667}]
set phase [expr {[llength $argv]>1 ? [lindex $argv 1] : "implement"}]
# An explicit output directory allows a corrected implementation to preserve
# the previously programmed image and all of its timing/source evidence.
set build [expr {[llength $argv]>2 ? [file normalize [lindex $argv 2]] : [file join $soc build_$mhz]}]
file mkdir $build
file mkdir [file join $build source]
create_project accelerator_soc $build -part xc7z010clg400-1 -force
foreach name {vector_mac requantize layer_engine axi_memory accelerator_top} {
 file copy -force [file join $root rtl ${name}.sv] [file join $build source ${name}.sv]
 add_files -norecurse [file join $build source ${name}.sv]
}
file copy -force [file join $soc accelerator_top_v.v] [file join $build source accelerator_top_v.v]
add_files -norecurse [file join $build source accelerator_top_v.v]
update_compile_order -fileset sources_1
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
source [file normalize [file join $soc z-turn-lite.tcl]]
set cfg [apply_preset 0]
dict for {k v} $cfg {if {[catch {set_property $k $v $ps} why]} {puts "PRESET_SKIP $k: $why"}}
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_USE_S_AXI_HP0 {1} \
 CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} CONFIG.PCW_EN_CLK0_PORT {1} CONFIG.PCW_EN_CLK1_PORT {1} \
 CONFIG.PCW_EN_RST0_PORT {1} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
 CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $mhz] $ps
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
 -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps
set acc [create_bd_cell -type module -reference accelerator_top_v accelerator]
puts "ACC_INTERFACES [get_bd_intf_pins accelerator/*]"
foreach name {rst_bus rst_core} {
 create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 $name
 set_property CONFIG.C_EXT_RESET_HIGH 0 [get_bd_cells $name]
 connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins $name/ext_reset_in]
}
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_ctl
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_hp
foreach name {sc_ctl sc_hp} {set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1 CONFIG.NUM_CLKS 2] [get_bd_cells $name]}
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins sc_ctl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M00_AXI] [get_bd_intf_pins accelerator/s_axi]
connect_bd_intf_net [get_bd_intf_pins accelerator/m_axi] [get_bd_intf_pins sc_hp/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_hp/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
foreach p {ps7/M_AXI_GP0_ACLK ps7/S_AXI_HP0_ACLK sc_ctl/aclk sc_hp/aclk1 rst_bus/slowest_sync_clk} {
 connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins $p]
}
foreach p {accelerator/clk sc_ctl/aclk1 sc_hp/aclk rst_core/slowest_sync_clk} {
 connect_bd_net [get_bd_pins ps7/FCLK_CLK1] [get_bd_pins $p]
}
foreach p {sc_ctl/aresetn sc_hp/aresetn} {connect_bd_net [get_bd_pins rst_bus/peripheral_aresetn] [get_bd_pins $p]}
connect_bd_net [get_bd_pins rst_core/peripheral_aresetn] [get_bd_pins accelerator/resetn]
assign_bd_address
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]] {
 puts "CONTROL_SEG $seg";set_property offset 0x43C00000 $seg;set_property range 4K $seg
}
validate_bd_design
save_bd_design
if {$phase eq "validate"} {puts "SOC_VALIDATE_PASS mhz=$mhz";exit 0}
set bdfile [get_files system.bd]
generate_target all $bdfile
make_wrapper -files $bdfile -top
add_files -norecurse [file join $build accelerator_soc.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "synthesis failed"}
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
# Export while the project/BD context still identifies the PS processors.
# Opening a standalone checkpoint creates a separate project and loses that
# software metadata. The programming bitstream is a separate artifact.
write_hw_platform -fixed -force -file [file join $build accelerator.xsa]
open_checkpoint [file join $build accelerator_soc.runs impl_1 system_wrapper_routed.dcp]
phys_opt_design -directive Explore
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0} {phys_opt_design -directive AggressiveExplore}
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $build timing.rpt]
report_timing -delay_type max -max_paths 30 -file [file join $build critical.rpt]
report_utilization -hierarchical -file [file join $build utilization.rpt]
report_drc -file [file join $build drc.rpt]
report_cdc -details -file [file join $build cdc.rpt]
check_timing -verbose -file [file join $build check_timing.rpt]
write_checkpoint -force [file join $build routed.dcp]
# Export a programming image only when full routed setup and hold pass.
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[get_property SLACK $setup] >= 0 && [get_property SLACK $hold] >= 0} {
 write_bitstream -force [file join $build accelerator.bit]

}
puts "SOC_IMPLEMENTED mhz=$mhz (inspect all reports before timing signoff)"
exit 0
