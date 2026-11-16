// VC707 address map; must match syn/bd_vc707.tcl.
// -DQEMU selects the qemu-system-riscv32 "virt" machine instead (test build, C model backend).
#pragma once
#ifdef QEMU
#define UART16550    0x10000000u
#define HEAP_BASE    0x80100000u
#define HEAP_END     0x8F000000u
#define IMG_ADDR     0x90000000u
#define TOK_ADDR     0x91000000u
#define CPU_HZ       100000000u // nominal; qemu timing is meaningless
#else

#define UART_BASE    0x40600000u
#define DMA_BASE     0x41E00000u
#define GEMV_BASE    0x44A00000u

#define LMB_SIZE     0x00040000u // 256K: [0, 128K) program, [128K, 256K) accelerator I/O
#define IO_BASE      0x00020000u
#define IO_SIZE      0x00020000u
#define IO_DMA_BASE  0xC0020000u // same BRAM through its AXI port

#define HEAP_BASE    0x80000000u // D-cached DDR, CPU only
#define HEAP_END     0x90000000u
#define IMG_ADDR     0x90000000u // uncached DDR, written over JTAG (see run.tcl)
#define TOK_ADDR     0x91000000u
#define POOL_BASE    0x92000000u // uncached DDR for KV caches
#define POOL_END     0xC0000000u

#define CPU_HZ       100000000u
#endif

static inline unsigned long rdcycle(void) {
    unsigned long c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}
static inline unsigned long long rdcycle64(void) {
    unsigned long hi, lo, hi2;
    do {
        __asm__ volatile("rdcycleh %0" : "=r"(hi));
        __asm__ volatile("rdcycle %0" : "=r"(lo));
        __asm__ volatile("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((unsigned long long)hi << 32) | lo;
}
