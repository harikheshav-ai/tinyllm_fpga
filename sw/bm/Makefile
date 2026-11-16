# toolchain prefix: on PATH by default; override with make CROSS=... or in ../../local.mk
-include ../../local.mk
CROSS  ?= riscv32-unknown-elf-
CC     := $(CROSS)gcc
CFLAGS := -march=rv32imafc -mabi=ilp32f -O2 -g -Wall -Wno-unused-function \
          -fno-math-errno -ffunction-sections -fdata-sections \
          -DACCEL_HAVE_FPGA -DMODEL_NO_FILE -DACCEL_NO_TRACE
LDFLAGS := -T link.ld -nostartfiles --specs=nano.specs -u _printf_float -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map=fw.map
SRCS   := start.S main.c syscalls.c accel_bm.c ../model.c ../accel.c

fw.elf: $(SRCS) link.ld platform.h ../model.h ../accel.h ../tok_sampler.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) -lm
	$(CROSS)size $@

# same firmware for qemu-system-riscv32 -machine virt, accelerator replaced by the C model
QEMU_SRCS := start.S main.c syscalls.c ../model.c ../accel.c
link_qemu.ld: link.ld
	sed 's/ORIGIN = 0x00000000, LENGTH = 128K/ORIGIN = 0x80000000, LENGTH = 1M/' link.ld > $@
fw_qemu.elf: $(QEMU_SRCS) link_qemu.ld platform.h ../model.h ../accel.h ../tok_sampler.h
	$(CC) $(filter-out -DACCEL_HAVE_FPGA,$(CFLAGS)) -DQEMU -T link_qemu.ld -nostartfiles --specs=nano.specs \
	    -u _printf_float -Wl,--gc-sections -Wl,--no-warn-rwx-segments -o $@ $(QEMU_SRCS) -lm

IMG ?= ../../build/stories15M_q8.img
TOK ?= ../../model/tokenizer.bin
qemu: fw_qemu.elf
	qemu-system-riscv32 -machine virt -cpu rv32 -m 1G -nographic -bios none -kernel fw_qemu.elf \
	    -device loader,file=$(IMG),addr=0x90000000,force-raw=on \
	    -device loader,file=$(TOK),addr=0x91000000,force-raw=on

clean:
	rm -f fw.elf fw.map fw_qemu.elf link_qemu.ld
