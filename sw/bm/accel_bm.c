// Bare-metal backend for the VC707 system (syn/bd_vc707.tcl): gemv_axi + AXI DMA
// in simple mode, polled. x vectors and results live in LMB BRAM (1-cycle CPU access,
// DMA reaches it at IO_DMA_BASE); weights and KV caches are in uncached DDR.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../accel.h"
#include "platform.h"

#define REG(base, off) (*(volatile uint32_t *)((base) + (off)))
// gemv_axi
#define G_CTRL 0x00
#define G_STAT 0x04
#define G_M    0x08
#define G_NB   0x0C
#define G_CYC  0x10
#define G_INFO 0x14
// AXI DMA, simple mode
#define MM2S_CR  0x00
#define MM2S_SR  0x04
#define MM2S_SA  0x18
#define MM2S_LEN 0x28
#define S2MM_CR  0x30
#define S2MM_SR  0x34
#define S2MM_DA  0x48
#define S2MM_LEN 0x58
#define SR_HALTED 0x1
#define SR_IDLE   0x2
#define SR_ERR    0x770

uint64_t accel_fpga_cycles; // accelerator busy cycles (100 MHz)

static uintptr_t io_next = IO_BASE, pool_next = POOL_BASE;

static void *bump(uintptr_t *next, uintptr_t end, size_t bytes, const char *what) {
    uintptr_t p = (*next + 63) & ~(uintptr_t)63;
    if (p + bytes > end) { printf("%s region exhausted (%u bytes)\n", what, (unsigned)bytes); exit(1); }
    *next = p + bytes;
    memset((void *)p, 0, bytes);
    return (void *)p;
}
void *accel_fpga_alloc(size_t bytes)    { return bump(&pool_next, POOL_END, bytes, "DDR pool"); }
void *accel_fpga_alloc_io(size_t bytes) { return bump(&io_next, IO_BASE + IO_SIZE, bytes, "LMB I/O"); }

static uint32_t dma_addr(const void *p) {
    uintptr_t a = (uintptr_t)p;
    if (a >= IO_BASE && a < IO_BASE + IO_SIZE) return a - IO_BASE + IO_DMA_BASE;
    if (a >= 0x90000000u && a < POOL_END) return a; // uncached DDR, identity mapped
    printf("buffer %p is not DMA-visible (cached or unmapped)\n", p);
    exit(1);
}

static void dma_wait(uint32_t sr, const char *what) {
    uint32_t s;
    while (!((s = REG(DMA_BASE, sr)) & (SR_IDLE | SR_HALTED))) ;
    if (s & (SR_ERR | SR_HALTED)) { printf("%s DMA error, SR=0x%08x\n", what, (unsigned)s); exit(1); }
}

int accel_fpga_init(void) {
    uint32_t info = REG(GEMV_BASE, G_INFO);
    if ((info & 0xFFFF) != LANES) {
        printf("gemv INFO=0x%08x, expected %d lanes\n", (unsigned)info, LANES);
        return -1;
    }
    REG(DMA_BASE, MM2S_CR) = 4; // soft reset (resets both channels)
    while (REG(DMA_BASE, MM2S_CR) & 4) ;
    REG(DMA_BASE, MM2S_CR) = 1;
    REG(DMA_BASE, S2MM_CR) = 1;
    return 0;
}

void accel_fpga_gemv(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb, int reuse_x) {
    __asm__ volatile("fence" ::: "memory"); // uncached KV-cache stores before the DMA reads them
    REG(DMA_BASE, S2MM_DA) = dma_addr(y);
    REG(DMA_BASE, S2MM_LEN) = (uint32_t)m * 4;
    REG(GEMV_BASE, G_M) = m;
    REG(GEMV_BASE, G_NB) = nb;
    REG(GEMV_BASE, G_CTRL) = reuse_x ? 1 : 3;
    if (!reuse_x) {
        REG(DMA_BASE, MM2S_SA) = dma_addr(x);
        REG(DMA_BASE, MM2S_LEN) = (uint32_t)nb * LANES;
        dma_wait(MM2S_SR, "MM2S(x)");
    }
    REG(DMA_BASE, MM2S_SA) = dma_addr(W);
    REG(DMA_BASE, MM2S_LEN) = (uint32_t)m * nb * LANES;
    dma_wait(MM2S_SR, "MM2S(W)");
    dma_wait(S2MM_SR, "S2MM");
    while (!(REG(GEMV_BASE, G_STAT) & 2)) ;
    accel_fpga_cycles += REG(GEMV_BASE, G_CYC);
}
