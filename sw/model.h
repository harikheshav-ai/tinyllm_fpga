// int8 Llama-2 model on the GEMV accelerator; shared by the host tool (runq8.c)
// and the VC707 firmware (bm/main.c).
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "accel.h"

typedef struct { int dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len; } Config;

typedef struct { int8_t *q; float *s; int m, nb; } QMat; // m rows of nb*LANES int8, per-row scale

typedef struct {
    Config c;
    int hs, kv_dim, hs_nb, seq_nb;
    float *rms_att, *rms_ffn, *rms_final;   // [L*dim], [L*dim], [dim]
    QMat *wq, *wk, *wv, *wo, *w1, *w2, *w3; // per layer
    QMat wcls;                              // also used as the (dequantized) embedding table
    // state
    float *x, *xb, *xb2, *hb, *hb2, *q, *k, *v, *att, *logits, *rope;
    int8_t *xq, *hq;
    int32_t *acc;
    int8_t *kc; float *ks; // [L][kvH][seq][hs_nb*LANES], [L][kvH][seq]
    int8_t *vt; float *vs; // [L][kvH][hs][seq],             [L][kvH][seq]
} Model;

// Model image: everything the firmware needs, weights already quantized and padded.
//   u32 magic, u32 version, u32 lanes, u32 0, Config (7 x i32), then 64-byte aligned
//   sections: rms_att, rms_ffn, rms_final (f32); per layer {wq wk wv wo w1 w2 w3} and
//   finally wcls, each as [m f32 scales][m*nb*LANES int8].
#define IMG_MAGIC   0x4D4C3851u /* "Q8LM" */
#define IMG_VERSION 1u

#ifndef MODEL_NO_FILE
void model_load_float(Model *M, const char *checkpoint);  // quantizes on load
int  model_write_image(const Model *M, const char *path);
#endif
// Weights are used in place (img must be accelerator-visible); scales/norms are copied.
int  model_load_image(Model *M, const uint8_t *img);
float *model_forward(Model *M, int token, int pos);
void softmax(float *x, int n);
