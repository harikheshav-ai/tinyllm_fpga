# Program the VC707, load model + tokenizer into DDR over JTAG, start the firmware.
#   xsdb sw/bm/run.tcl [bitstream] [model.img] [tokenizer.bin] [fw.elf]
# Then talk to it on the board's USB-UART at 115200 8N1 (e.g. picocom -b 115200 /dev/ttyUSB0).
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/../..]
proc arg {i default} { global argv; expr {[llength $argv] > $i ? [lindex $argv $i] : $default} }
set bit [arg 0 $root/syn/vc707_proj/gemv_vc707.bit]
set img [arg 1 $root/build/stories15M_q8.img]
set tok [arg 2 $root/model/tokenizer.bin]
set elf [arg 3 $here/fw.elf]
foreach f [list $bit $img $tok $elf] { if {![file exists $f]} { error "missing $f" } }

connect
targets -set -nocase -filter {name =~ "xc7vx485t*"}
puts "programming $bit"
fpga -file $bit
after 2000 ;# MIG calibration

targets -set -nocase -filter {name =~ "*hart*" || name =~ "*microblaze*"}
catch {stop}
rst -processor

set t0 [clock milliseconds]
puts "loading [file size $img] byte model image to 0x90000000 ..."
dow -data $img 0x90000000
dow -data $tok 0x91000000
puts [format "... done in %.1f s" [expr {([clock milliseconds] - $t0) / 1000.0}]]

dow $elf
con
puts "firmware running; open the UART at 115200 baud"
