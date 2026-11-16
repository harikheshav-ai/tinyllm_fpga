// FPGA backend for Linux on Zynq UltraScale+ (KV260 / ZCU104), matching syn/bd_kv260.tcl:
//   gemv_axi registers  @ GEMV_BASE   (see rtl/gemv_axi.v)
//   AXI DMA (simple)    @ DMA_BASE    MM2S 256-bit -> gemv, gemv -> S2MM 32-bit
// Buffers come from a u-dma-buf device (https://github.com/ikwzm/udmabuf), e.g.
//   sudo insmod u-dma-buf.ko udmabuf0=67108864
// Control registers are mapped through /dev/mem, so run as root.
// Build: gcc -O3 -DACCEL_HAVE_FPGA -o runq8 runq8.c model.c accel.c accel_fpga.c -lm
//   (or: make build/runq8_fpga)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "accel.h"

#ifndef GEMV_BASE
#define GEMV_BASE 0xA0000000u
#endif
#ifndef DMA_BASE
#define DMA_BASE  0xA0010000u
#endif
#ifndef UDMABUF
#define UDMABUF "udmabuf0"
#endif

// gemv_axi registers
#define G_CTRL 0x00
#define G_STAT 0x04
#define G_M    0x08
#define G_NB   0x0C
#define G_CYC  0x10
#define G_INFO 0x14
// AXI DMA simple-mode registers
#define MM2S_CR 0x00
#define MM2S_SR 0x04
#define MM2S_SA 0x18
#define MM2S_SA_MSB 0x1C
#define MM2S_LEN 0x28
#define S2MM_CR 0x30
#define S2MM_SR 0x34
#define S2MM_DA 0x48
#define S2MM_DA_MSB 0x4C
#define S2MM_LEN 0x58
#define SR_HALTED 0x1
#define SR_IDLE   0x2
#define SR_ERR    0x770

static volatile uint32_t *gemv, *dma;
static uint8_t *pool;
static uint64_t pool_phys;
static size_t pool_size, pool_used;
uint64_t accel_fpga_cycles; // accumulated accelerator busy cycles

static inline void wr(volatile uint32_t *b, uint32_t off, uint32_t v) { b[off / 4] = v; }
static inline uint32_t rd(volatile uint32_t *b, uint32_t off) { return b[off / 4]; }

static long read_sysfs(const char *name) {
    char path[256], buf[64];
    snprintf(path, sizeof path, "/sys/class/u-dma-buf/%s/%s", UDMABUF, name);
    FILE *f = fopen(path, "r");
    if (!f || !fgets(buf, sizeof buf, f)) { perror(path); exit(1); }
    fclose(f);
    return strtol(buf, NULL, 0);
}

int accel_fpga_init(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return -1; }
    gemv = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GEMV_BASE);
    dma  = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_BASE);
    close(fd);
    if (gemv == MAP_FAILED || dma == MAP_FAILED) { perror("mmap regs"); return -1; }

    uint32_t info = rd(gemv, G_INFO);
    if ((info & 0xFFFF) != LANES) {
        fprintf(stderr, "gemv INFO=0x%08x: expected %d lanes (bitstream loaded?)\n", info, LANES);
        return -1;
    }
    pool_phys = read_sysfs("phys_addr");
    pool_size = read_sysfs("size");
    char dev[64]; snprintf(dev, sizeof dev, "/dev/%s", UDMABUF);
    fd = open(dev, O_RDWR | O_SYNC); // O_SYNC: uncached mapping, no cache maintenance needed
    if (fd < 0) { perror(dev); return -1; }
    pool = mmap(NULL, pool_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (pool == MAP_FAILED) { perror("mmap udmabuf"); return -1; }

    wr(dma, MM2S_CR, 4); wr(dma, S2MM_CR, 4); // soft reset
    while (rd(dma, MM2S_CR) & 4) ;
    wr(dma, MM2S_CR, 1); wr(dma, S2MM_CR, 1); // run, interrupts off (we poll)
    fprintf(stderr, "fpga: gemv %d lanes x %d beats, dma pool %zu MB @ 0x%llx\n",
            info & 0xFFFF, info >> 16, pool_size >> 20, (unsigned long long)pool_phys);
    return 0;
}

void *accel_fpga_alloc(size_t bytes) {
    size_t off = (pool_used + 63) & ~(size_t)63;
    if (off + bytes > pool_size) {
        fprintf(stderr, "udmabuf pool exhausted (%zu + %zu > %zu); load u-dma-buf with a larger size\n",
                off, bytes, pool_size);
        exit(1);
    }
    pool_used = off + bytes;
    memset(pool + off, 0, bytes);
    return pool + off;
}

void *accel_fpga_alloc_io(size_t bytes) { return accel_fpga_alloc(bytes); }

static uint64_t phys(const void *p) {
    size_t off = (const uint8_t *)p - pool;
    if (off >= pool_size) { fprintf(stderr, "buffer %p not from accel_alloc\n", p); exit(1); }
    return pool_phys + off;
}

static void dma_wait(uint32_t sr_off, const char *what) {
    uint32_t sr;
    while (!((sr = rd(dma, sr_off)) & (SR_IDLE | SR_HALTED))) ;
    if (sr & (SR_ERR | SR_HALTED)) { fprintf(stderr, "%s DMA error, SR=0x%08x\n", what, sr); exit(1); }
}

static void mm2s(const void *src, uint32_t len) {
    uint64_t a = phys(src);
    wr(dma, MM2S_SA, (uint32_t)a); wr(dma, MM2S_SA_MSB, (uint32_t)(a >> 32));
    wr(dma, MM2S_LEN, len); // writing LENGTH starts the transfer
    dma_wait(MM2S_SR, "MM2S");
}

void accel_fpga_gemv(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb, int reuse_x) {
    uint64_t ya = phys(y);
    wr(dma, S2MM_DA, (uint32_t)ya); wr(dma, S2MM_DA_MSB, (uint32_t)(ya >> 32));
    wr(dma, S2MM_LEN, (uint32_t)m * 4);
    wr(gemv, G_M, m);
    wr(gemv, G_NB, nb);
    wr(gemv, G_CTRL, reuse_x ? 1 : 3);
    if (!reuse_x) mm2s(x, (uint32_t)nb * LANES);
    mm2s(W, (uint32_t)m * nb * LANES);
    dma_wait(S2MM_SR, "S2MM");
    while (!(rd(gemv, G_STAT) & 2)) ;
    accel_fpga_cycles += rd(gemv, G_CYC);
}
