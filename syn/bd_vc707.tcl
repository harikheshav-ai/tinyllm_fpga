# VC707 system: MicroBlaze V (RV32IMAFC) + DDR3 (MIG) + AXI DMA + gemv_axi + UART.
#   vivado -mode batch -source syn/bd_vc707.tcl -tclargs [validate|build]
#
# Memory map (CPU view)                         DMA / debug view
#   0x0000_0000 256K  LMB BRAM: code, stack,    0xC000_0000 (same BRAM, port B)
#                     I/O buffers @ 0x2_0000
#   0x4060_0000       UART Lite (115200 8N1)
#   0x41E0_0000       AXI DMA
#   0x44A0_0000       gemv_axi
#   0x8000_0000 1G    DDR3; D-cached only in 0x8000_0000-0x8FFF_FFFF (heap)
#                     0x9000_0000+ uncached: model image, tokenizer, KV cache
set root [file normalize [file dirname [info script]]/..]
set mode [expr {[llength $argv] ? [lindex $argv 0] : "build"}]
set out  $root/syn/vc707_proj
create_project -force vc707_gemv $out -part xc7vx485tffg1761-2
set_property board_part xilinx.com:vc707:part0:1.4 [current_project]
add_files [glob $root/rtl/*.v]
add_files -fileset constrs_1 $root/syn/vc707_leds.xdc
create_bd_design sys

# ---------------- DDR3 + clocks + resets ----------------
set mig [create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series mig]
apply_bd_automation -rule xilinx.com:bd_rule:mig_7series -config {Board_Interface "ddr3_sdram"} $mig
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface "reset"} [get_bd_pins mig/sys_rst]

set cw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk100]
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} CONFIG.USE_RESET {true} CONFIG.RESET_TYPE {ACTIVE_HIGH}] $cw
connect_bd_net [get_bd_pins mig/ui_clk] [get_bd_pins clk100/clk_in1]
connect_bd_net [get_bd_pins mig/ui_clk_sync_rst] [get_bd_pins clk100/reset]

set rst_mig [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_mig]
connect_bd_net [get_bd_pins mig/ui_clk] [get_bd_pins rst_mig/slowest_sync_clk]
connect_bd_net [get_bd_pins mig/mmcm_locked] [get_bd_pins rst_mig/dcm_locked]
connect_bd_net [get_bd_pins mig/ui_clk_sync_rst] [get_bd_pins rst_mig/ext_reset_in]
connect_bd_net [get_bd_pins rst_mig/peripheral_aresetn] [get_bd_pins mig/aresetn]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst]
set lk [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic locked_and]
set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] $lk
connect_bd_net [get_bd_pins clk100/locked] [get_bd_pins locked_and/Op1]
connect_bd_net [get_bd_pins mig/init_calib_complete] [get_bd_pins locked_and/Op2]
connect_bd_net [get_bd_pins locked_and/Res] [get_bd_pins rst/dcm_locked]
connect_bd_net [get_bd_pins mig/ui_clk_sync_rst] [get_bd_pins rst/ext_reset_in]

# ---------------- MicroBlaze V ----------------
set mb [create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze_riscv mb]
set_property -dict [list CONFIG.C_USE_FPU {1} CONFIG.C_USE_MULDIV {1} CONFIG.C_USE_ATOMIC {1} \
    CONFIG.C_USE_COMPRESSION {1} CONFIG.C_USE_COUNTERS {1} CONFIG.C_D_AXI {1} CONFIG.C_DEBUG_ENABLED {1} \
    CONFIG.C_USE_ICACHE {0} CONFIG.C_USE_DCACHE {1} CONFIG.C_DCACHE_BYTE_SIZE {32768} \
    CONFIG.C_DCACHE_BASEADDR {0x0000000080000000} CONFIG.C_DCACHE_HIGHADDR {0x000000008FFFFFFF}] $mb

set mdm [create_bd_cell -type ip -vlnv xilinx.com:ip:mdm_riscv mdm]
set_property -dict [list CONFIG.C_DBG_MEM_ACCESS {1}] $mdm
connect_bd_intf_net [get_bd_intf_pins mdm/MBDEBUG_0] [get_bd_intf_pins mb/DEBUG]
connect_bd_net [get_bd_pins mdm/Debug_SYS_Rst] [get_bd_pins rst/mb_debug_sys_rst]

# local memory: one controller serving both ILMB and DLMB on BRAM port A; port B -> AXI for DMA
set ilmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10 ilmb]
set dlmb [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10 dlmb]
set lmbc [create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr lmb_cntlr]
set_property -dict [list CONFIG.C_NUM_LMB {2}] $lmbc
set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen lmb_bram]
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM} CONFIG.use_bram_block {BRAM_Controller}] $bram
set bctl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl io_bram_axi]
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32} CONFIG.PROTOCOL {AXI4}] $bctl
connect_bd_intf_net [get_bd_intf_pins mb/ILMB] [get_bd_intf_pins ilmb/LMB_M]
connect_bd_intf_net [get_bd_intf_pins mb/DLMB] [get_bd_intf_pins dlmb/LMB_M]
connect_bd_intf_net [get_bd_intf_pins ilmb/LMB_Sl_0] [get_bd_intf_pins lmb_cntlr/SLMB]
connect_bd_intf_net [get_bd_intf_pins dlmb/LMB_Sl_0] [get_bd_intf_pins lmb_cntlr/SLMB1]
connect_bd_intf_net [get_bd_intf_pins lmb_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins io_bram_axi/BRAM_PORTA] [get_bd_intf_pins lmb_bram/BRAM_PORTB]

# ---------------- peripherals ----------------
set uart [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite uart]
apply_bd_automation -rule xilinx.com:bd_rule:board -config {Board_Interface "rs232_uart"} [get_bd_intf_pins uart/UART]
set_property -dict [list CONFIG.C_BAUDRATE {115200}] $uart

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list CONFIG.c_include_sg {0} CONFIG.c_sg_length_width {26} CONFIG.c_addr_width {32} \
    CONFIG.c_m_axi_mm2s_data_width {256} CONFIG.c_m_axis_mm2s_tdata_width {256} CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_m_axi_s2mm_data_width {32} CONFIG.c_s_axis_s2mm_tdata_width {32} CONFIG.c_s2mm_burst_size {64}] $dma
set g [create_bd_cell -type module -reference gemv_axi gemv]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins gemv/s_axis]
connect_bd_intf_net [get_bd_intf_pins gemv/m_axis] [get_bd_intf_pins dma/S_AXIS_S2MM]

# ---------------- interconnect ----------------
set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ic]
set_property -dict [list CONFIG.NUM_SI {5} CONFIG.NUM_MI {5} CONFIG.NUM_CLKS {2}] $ic
foreach {si m} {S00_AXI mb/M_AXI_DP S01_AXI mb/M_AXI_DC S02_AXI dma/M_AXI_MM2S S03_AXI dma/M_AXI_S2MM S04_AXI mdm/M_AXI} {
    connect_bd_intf_net [get_bd_intf_pins $m] [get_bd_intf_pins ic/$si]
}
foreach {mi s} {M00_AXI mig/S_AXI M01_AXI uart/S_AXI M02_AXI dma/S_AXI_LITE M03_AXI gemv/s_axi M04_AXI io_bram_axi/S_AXI} {
    connect_bd_intf_net [get_bd_intf_pins ic/$mi] [get_bd_intf_pins $s]
}

# ---------------- clock / reset nets ----------------
set clk [get_bd_pins clk100/clk_out1]
connect_bd_net $clk [get_bd_pins rst/slowest_sync_clk] [get_bd_pins mb/Clk] [get_bd_pins ilmb/LMB_Clk] \
    [get_bd_pins dlmb/LMB_Clk] [get_bd_pins lmb_cntlr/LMB_Clk] [get_bd_pins io_bram_axi/s_axi_aclk] \
    [get_bd_pins uart/s_axi_aclk] [get_bd_pins dma/s_axi_lite_aclk] [get_bd_pins dma/m_axi_mm2s_aclk] \
    [get_bd_pins dma/m_axi_s2mm_aclk] [get_bd_pins gemv/aclk] [get_bd_pins mdm/M_AXI_ACLK] [get_bd_pins ic/aclk]
connect_bd_net [get_bd_pins mig/ui_clk] [get_bd_pins ic/aclk1]
connect_bd_net [get_bd_pins rst/mb_reset] [get_bd_pins mb/Reset]
connect_bd_net [get_bd_pins rst/bus_struct_reset] [get_bd_pins ilmb/SYS_Rst] [get_bd_pins dlmb/SYS_Rst] \
    [get_bd_pins lmb_cntlr/LMB_Rst]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins io_bram_axi/s_axi_aresetn] \
    [get_bd_pins uart/s_axi_aresetn] [get_bd_pins dma/axi_resetn] [get_bd_pins gemv/aresetn] \
    [get_bd_pins mdm/M_AXI_ARESETN] [get_bd_pins ic/aresetn]

# ---------------- bring-up status LEDs (rtl/status_leds.v) ----------------
set st [create_bd_cell -type module -reference status_leds status]
foreach {pin net} {clk_ui mig/ui_clk clk_sys clk100/clk_out1 mig_locked mig/mmcm_locked \
                   calib_done mig/init_calib_complete sys_locked clk100/locked \
                   periph_aresetn rst/peripheral_aresetn mb_reset rst/mb_reset ui_rst mig/ui_clk_sync_rst} {
    connect_bd_net [get_bd_pins $net] [get_bd_pins status/$pin]
}
create_bd_port -dir O -from 7 -to 0 led
connect_bd_net [get_bd_pins status/led] [get_bd_ports led]

# ---------------- addresses ----------------
proc place {pins offset range} {
    foreach p $pins {
        set segs [get_bd_addr_segs -of_objects [get_bd_intf_pins $p]]
        if {![llength $segs]} { error "no slave segment on $p" }
        assign_bd_address -offset $offset -range $range $segs
    }
}
place {lmb_cntlr/SLMB lmb_cntlr/SLMB1} 0x00000000 256K
place uart/S_AXI                       0x40600000 64K
place dma/S_AXI_LITE                   0x41E00000 64K
place gemv/s_axi                       0x44A00000 64K
place mig/S_AXI                        0x80000000 1G
place io_bram_axi/S_AXI                0xC0000000 256K
validate_bd_design
save_bd_design
foreach s [lsort [get_bd_addr_segs -quiet */SEG_*]] {
    puts [format "ADDR %-45s 0x%08x %s" $s [get_property OFFSET $s] [get_property RANGE $s]]
}
puts "UI_CLK_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins mig/ui_clk]]"
if {$mode eq "validate"} { exit }

make_wrapper -files [get_files sys.bd] -top -import
set_property top sys_wrapper [current_fileset]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_timing_summary -file $out/timing.rpt
report_utilization -file $out/util.rpt
write_hw_platform -fixed -include_bit -force $out/gemv_vc707.xsa
file copy -force $out/vc707_gemv.runs/impl_1/sys_wrapper.bit $out/gemv_vc707.bit
