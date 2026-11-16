// Host-side interface to the int8 GEMV accelerator.
//
//   y[i] = sum_{j < nb*LANES} W[i*nb*LANES + j] * x[j]      (int8 x int8 -> int32)
//
// W is row-major, each row padded with zeros to nb*LANES bytes; x is padded the same.
// reuse_x != 0 tells the hardware that x is unchanged since the previous call, so it
// is not re-sent (used for Q/K/V and W1/W3 which share their input vector).
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>

#define LANES 32 // int8 elements per 256-bit beat; must match rtl P parameter

typedef enum { ACCEL_REF = 0, ACCEL_FPGA = 1 } accel_backend_t;

extern accel_backend_t accel_backend;
extern FILE *accel_trace; // if non-NULL, every call is recorded for RTL co-simulation

int  accel_init(accel_backend_t b);
// Zeroed buffer the accelerator can read/write (DMA-able on the FPGA backend).
// All W, x and y pointers passed to accel_gemv must come from here.
void *accel_alloc(size_t bytes);
// Small, frequently touched buffers (x vectors, results); on the VC707 these live in
// local BRAM that the CPU reads in one cycle.
void *accel_alloc_io(size_t bytes);

// if set, every result is also computed by the C model and compared
extern int accel_verify;
extern uint64_t accel_calls, accel_mismatches;
void accel_gemv(const int8_t *W, const int8_t *x, int32_t *y, int m, int nb, int reuse_x);

// Trace record format (little-endian), consumed by tb/tb_gemv.v:
//   u32 magic 'GEMV' (0x564D4547), u32 m, u32 nb, u32 reuse_x,
//   [nb*LANES bytes x]  (only if reuse_x == 0),
//   m*nb*LANES bytes W, m x i32 expected y.
// End of file is marked by a record with magic 'DONE' (0x454E4F44).
#define TRACE_MAGIC 0x564D4547u
#define TRACE_DONE  0x454E4F44u
