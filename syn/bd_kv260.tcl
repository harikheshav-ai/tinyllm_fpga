# KV260 (Zynq UltraScale+ K26) system: PS -> AXI DMA -> gemv_axi, bitstream + XSA.
#   vivado -mode batch -source syn/bd_kv260.tcl
# Address map (HPM0_FPD): gemv_axi @ 0xA000_0000, axi_dma @ 0xA001_0000
set root [file normalize [file dirname [info script]]/..]
set out  $root/syn/kv260_proj
set fclk 250
create_project -force kv260_gemv $out -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
add_files [glob $root/rtl/*.v]
create_bd_design gemv_bd

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} $ps
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $fclk] $ps

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_sg_length_width {26} \
    CONFIG.c_m_axi_mm2s_data_width {256} CONFIG.c_m_axis_mm2s_tdata_width {256} CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_m_axi_s2mm_data_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_addr_width {40}] $dma

set g [create_bd_cell -type module -reference gemv_axi gemv]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst]
set ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ctl_ic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctl
set mem [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect mem_ic]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem

set clk [get_bd_pins ps/pl_clk0]
connect_bd_net $clk [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins ps/saxihp0_fpd_aclk] \
    [get_bd_pins dma/s_axi_lite_aclk] [get_bd_pins dma/m_axi_mm2s_aclk] [get_bd_pins dma/m_axi_s2mm_aclk] \
    [get_bd_pins gemv/aclk] [get_bd_pins rst/slowest_sync_clk] [get_bd_pins ctl_ic/aclk] [get_bd_pins mem_ic/aclk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins dma/axi_resetn] [get_bd_pins gemv/aresetn] \
    [get_bd_pins ctl_ic/aresetn] [get_bd_pins mem_ic/aresetn]

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ctl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctl_ic/M00_AXI] [get_bd_intf_pins gemv/s_axi]
connect_bd_intf_net [get_bd_intf_pins ctl_ic/M01_AXI] [get_bd_intf_pins dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S] [get_bd_intf_pins mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] [get_bd_intf_pins mem_ic/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_ic/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP0_FPD]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins gemv/s_axis]
connect_bd_intf_net [get_bd_intf_pins gemv/m_axis] [get_bd_intf_pins dma/S_AXIS_S2MM]

assign_bd_address
set_property offset 0xA0000000 [get_bd_addr_segs ps/Data/SEG_gemv_reg0]
set_property range 64K         [get_bd_addr_segs ps/Data/SEG_gemv_reg0]
set_property offset 0xA0010000 [get_bd_addr_segs ps/Data/SEG_dma_Reg]
validate_bd_design
save_bd_design

make_wrapper -files [get_files gemv_bd.bd] -top -import
set_property top gemv_bd_wrapper [current_fileset]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_hw_platform -fixed -include_bit -force $out/gemv_kv260.xsa
file copy -force $out/kv260_gemv.runs/impl_1/gemv_bd_wrapper.bit $out/gemv_kv260.bit
