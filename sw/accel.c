#include "accel.h"
#include <stdlib.h>

accel_backend_t accel_backend = ACCEL_REF;
FILE *accel_trace = NULL;
int accel_verify = 0;
uint64_t accel_calls = 0, accel_mismatches = 0;

#ifdef ACCEL_HAVE_FPGA
// provided by accel_fpga.c (Linux/Zynq) or bm/accel_bm.c (bare-metal VC707)
int  accel_fpga_init(void);
void accel_fpga_gemv(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb, int reuse_x);
void *accel_fpga_alloc(size_t bytes);
void *accel_fpga_alloc_io(size_t bytes);
#endif

static void *host_alloc(size_t bytes) {
    void *p = calloc(1, bytes);
    if (!p) { printf("accel_alloc(%u) failed\n", (unsigned)bytes); exit(1); }
    return p;
}

void *accel_alloc(size_t bytes) {
#ifdef ACCEL_HAVE_FPGA
    if (accel_backend == ACCEL_FPGA) return accel_fpga_alloc(bytes);
#endif
    return host_alloc(bytes);
}

void *accel_alloc_io(size_t bytes) {
#ifdef ACCEL_HAVE_FPGA
    if (accel_backend == ACCEL_FPGA) return accel_fpga_alloc_io(bytes);
#endif
    return host_alloc(bytes);
}

int accel_init(accel_backend_t b) {
    accel_backend = b;
#ifdef ACCEL_HAVE_FPGA
    if (b == ACCEL_FPGA) return accel_fpga_init();
#else
    if (b == ACCEL_FPGA) { printf("built without FPGA backend\n"); return -1; }
#endif
    return 0;
}

// Bit-exact golden model of rtl/gemv_int8.v
static void gemv_ref(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb) {
    int n = nb * LANES;
    for (int i = 0; i < m; i++) {
        const int8_t *w = W + (size_t)i * n;
        int32_t acc = 0;
        for (int j = 0; j < n; j++) acc += (int32_t)w[j] * (int32_t)x[j];
        y[i] = acc;
    }
}

#ifndef ACCEL_NO_TRACE
static void put_u32(uint32_t v) { fwrite(&v, 4, 1, accel_trace); }
#endif

void accel_gemv(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb, int reuse_x) {
    accel_calls++;
#ifdef ACCEL_HAVE_FPGA
    if (accel_backend == ACCEL_FPGA) {
        accel_fpga_gemv(W, x, y, m, nb, reuse_x);
        if (accel_verify) {
            int n = nb * LANES;
            for (int i = 0; i < m; i++) {
                const int8_t *w = W + (size_t)i * n;
                int32_t acc = 0;
                for (int j = 0; j < n; j++) acc += (int32_t)w[j] * (int32_t)x[j];
                if (acc != y[i] && accel_mismatches++ < 10)
                    printf("\nverify: call %u row %d: fpga %ld, ref %ld\n", (unsigned)accel_calls, i, (long)y[i], (long)acc);
            }
        }
    } else
#endif
    gemv_ref(W, x, y, m, nb);

#ifndef ACCEL_NO_TRACE
    if (accel_trace) {
        put_u32(TRACE_MAGIC); put_u32(m); put_u32(nb); put_u32(reuse_x);
        if (!reuse_x) fwrite(x, 1, (size_t)nb * LANES, accel_trace);
        fwrite(W, 1, (size_t)m * nb * LANES, accel_trace);
        fwrite(y, 4, m, accel_trace);
    }
#endif
}
