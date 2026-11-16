# usage: vivado -mode batch -source ooc.tcl -tclargs <part> <period_ns> <outdir>
lassign $argv part period out
file mkdir $out
read_verilog [glob [file dirname [info script]]/../rtl/*.v]
synth_design -top gemv_axi -part $part -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name aclk -period $period [get_ports aclk]
opt_design; place_design; phys_opt_design; route_design
report_utilization -file $out/util.rpt
report_timing_summary -file $out/timing.rpt
