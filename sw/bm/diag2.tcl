# Follow-up bring-up diagnostics after run.tcl. Programs nothing, resets nothing.
# Halts the CPU briefly to sample its PC, and writes "U" + newline straight into the
# UART TX FIFO to test the TX path independently of the firmware.
#   xsdb sw/bm/diag2.tcl
proc try {label script} {
    if {[catch {uplevel 1 $script} r]} { puts "$label: ERROR $r" } else { puts "$label: $r" }
}
connect
after 1000
puts "== JTAG targets"; puts [targets]
targets -set -nocase -filter {name =~ "*hart*" || name =~ "*microblaze*"}
puts "== PC samples (firmware symbols: main 0x5fe, uart_putc 0xb56, _sbrk 0xbe6, printf 0x66be, _vfprintf_r 0x9062)"
for {set i 0} {$i < 5} {incr i} {
    try "sample $i" { stop; set p [rrd pc]; con; set p }
    after 200
}
try "stop" { stop }
try "registers" { rrd }
try "ra" { rrd ra }
try "sp" { rrd sp }
puts "== is fw.elf in BRAM? (expect 0x0000d197 0x2a818193 0x00020117 0xff810113)"
try "LMB 0x0" { mrd 0x0 4 }
puts "== did the model reach DDR?"
try "image magic @0x90000000 (expect 0x4D4C3851)" { mrd 0x90000000 1 }
try "tokenizer @0x91000000 (expect 0x0000001B)"   { mrd 0x91000000 1 }
try "image end  @0x90EB0000"                       { mrd 0x90EB0000 1 }
puts "== UART"
try "uart STAT before" { mrd 0x40600008 1 }
try "TX 'U'"  { mwr 0x40600004 0x55 }
try "TX '\\n'" { mwr 0x40600004 0x0A }
try "uart STAT after"  { mrd 0x40600008 1 }
try "con" { con }
