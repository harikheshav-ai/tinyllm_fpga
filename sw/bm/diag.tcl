# Read-only bring-up diagnostics for the VC707 system. Programs nothing, resets nothing.
#   xsdb sw/bm/diag.tcl
proc try {label script} {
    if {[catch {uplevel 1 $script} r]} { puts "$label: ERROR $r" } else { puts "$label: $r" }
}
connect
puts "== JTAG targets"; puts [targets]
targets -set -nocase -filter {name =~ "*hart*" || name =~ "*microblaze*"}
puts "== CPU state (halting briefly to read it)"
try "stop"            { stop }
try "pc"              { rrd pc }
try "mcause"          { rrd mcause }
try "mepc"            { rrd mepc }
try "mtval"           { rrd mtval }
puts "== accelerator / DMA registers"
try "gemv INFO   (expect 0x00200020)" { mrd -value 0x44A00014 }
try "gemv STATUS"                      { mrd -value 0x44A00004 }
try "dma MM2S_SR"                      { mrd -value 0x41E00004 }
try "dma S2MM_SR"                      { mrd -value 0x41E00034 }
puts "== memory contents"
try "image magic @0x90000000 (expect 0x4d4c3851)" { mrd -value 0x90000000 }
try "tokenizer max_len @0x91000000 (expect 0x1b)"  { mrd -value 0x91000000 }
try "LMB word 0 (_start)"                          { mrd -value 0x00000000 }
try "uart STAT"                                    { mrd -value 0x40600008 }
try "con" { con }
