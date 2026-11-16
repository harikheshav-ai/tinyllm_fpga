# Tool paths default to the PATH. Override on the command line (make VIVADO=/path/to/vivado)
# or in an untracked local.mk next to this Makefile (also read by sw/bm/Makefile), e.g.
#   VIVADO := /opt/Xilinx/Vivado/2024.2/bin/vivado
#   XSDB   := /opt/Xilinx/Vivado/2024.2/bin/xsdb
#   CROSS  := /opt/riscv/bin/riscv32-unknown-elf-
-include local.mk
VIVADO ?= vivado
XSDB   ?= xsdb
MODEL  := model/stories15M.bin
TOK    := model/tokenizer.bin
RTL    := rtl/gemv_int8.v rtl/gemv_axi.v
CFLAGS := -O3 -Wall -Wno-unused-function

.PHONY: all run sim sim-rand sim-token sim-axi quality ooc kv260 vc707 fw qemu run-vc707 clean

all: build/runq8

build:
	mkdir -p $@

build/runq8: sw/runq8.c sw/model.c sw/model.h sw/accel.c sw/accel.h sw/tok_sampler.h | build
	gcc $(CFLAGS) -o $@ sw/runq8.c sw/model.c sw/accel.c -lm

# cross-compile or build natively on the board
build/runq8_fpga: sw/runq8.c sw/model.c sw/accel.c sw/accel_fpga.c sw/accel.h sw/tok_sampler.h | build
	$(CC) $(CFLAGS) -DACCEL_HAVE_FPGA -o $@ sw/runq8.c sw/model.c sw/accel.c sw/accel_fpga.c -lm

run: build/runq8
	./build/runq8 $(MODEL) -z $(TOK) -n 200 -i "Once upon a time"

quality: build/runq8
	./build/runq8 $(MODEL) -z $(TOK) -n 256 -i "Once upon a time" -o build/ids.txt > /dev/null
	python3 sw/check_quality.py $(MODEL) build/ids.txt

build/tb_gemv: tb/tb_gemv.v $(RTL) | build
	iverilog -g2005 -o $@ tb/tb_gemv.v rtl/gemv_int8.v

build/tb_axi: tb/tb_gemv_axi.v $(RTL) | build
	iverilog -g2005 -o $@ tb/tb_gemv_axi.v $(RTL)

# each sim target fails unless the testbench printed PASS (log in build/sim-*.log)
sim: sim-rand sim-axi sim-token

sim-rand: build/tb_gemv
	python3 tb/gen_rand_trace.py build/rand.trace 200 1
	vvp -n build/tb_gemv +trace=build/rand.trace +stall_in=30 +stall_out=30 > build/sim-rand.log
	tail -2 build/sim-rand.log
	grep -qx PASS build/sim-rand.log

sim-axi: build/tb_axi
	vvp -n build/tb_axi > build/sim-axi.log
	tail -1 build/sim-axi.log
	grep -qx PASS build/sim-axi.log

# replay every accelerator call of one real token (pos 20) through the RTL (~10 min)
sim-token: build/tb_gemv build/runq8
	./build/runq8 $(MODEL) -z $(TOK) -n 21 -i "Once upon a time" -T build/token20.trace -P 20 > /dev/null
	vvp -n build/tb_gemv +trace=build/token20.trace +stall_in=5 +stall_out=5 > build/sim-token.log
	tail -2 build/sim-token.log
	grep -qx PASS build/sim-token.log

ooc:
	cd syn && $(VIVADO) -mode batch -nojournal -log kv260.log -source ooc.tcl -tclargs xck26-sfvc784-2LV-c 3.333 kv260
	cd syn && $(VIVADO) -mode batch -nojournal -log vc707.log -source ooc.tcl -tclargs xc7vx485tffg1761-2 5.0 vc707

kv260:
	cd syn && $(VIVADO) -mode batch -nojournal -log bd_kv260.log -source bd_kv260.tcl

# ---- VC707: MicroBlaze V + DDR3 + DMA + gemv, bare metal ----
vc707:
	cd syn && $(VIVADO) -mode batch -nojournal -log bd_vc707.log -source bd_vc707.tcl -tclargs build

build/stories15M_q8.img: build/runq8 $(MODEL) | build
	./build/runq8 $(MODEL) -E $@

fw:
	$(MAKE) -C sw/bm fw.elf

qemu: build/stories15M_q8.img
	$(MAKE) -C sw/bm qemu

run-vc707: build/stories15M_q8.img fw
	$(XSDB) sw/bm/run.tcl

clean:
	rm -rf build/* syn/kv260 syn/vc707 syn/kv260_proj syn/vc707_proj syn/*.log syn/.Xil
	$(MAKE) -C sw/bm clean
