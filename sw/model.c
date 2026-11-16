// Llama-2 (llama2.c checkpoint) inference where every matmul and both attention
// products run on the int8 GEMV accelerator (see accel.h). The CPU only does
// RMSNorm, RoPE, softmax, SiLU and per-row / per-vector rescaling.
//
// Quantization: weights int8 symmetric per output row; activations int8 symmetric
// per vector. K cache is int8 per (pos, head) row; V cache is stored transposed
// (head, dim, pos) so that softmax(att) @ V is also a plain GEMV.
#include "model.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int nbeats(int n) { return (n + LANES - 1) / LANES; }
static size_t align64(size_t n) { return (n + 63) & ~(size_t)63; }

static void *xmalloc(size_t n) {
    void *p = calloc(1, n);
    if (!p) { printf("out of memory (%u bytes)\n", (unsigned)n); exit(1); }
    return p;
}

// symmetric int8 quantization of x[0..n) into q[0..nb*LANES), zero padded; returns scale
static float quant_vec(const float *x, int n, int8_t *q, int nb) {
    float amax = 0.0f;
    for (int i = 0; i < n; i++) { float a = fabsf(x[i]); if (a > amax) amax = a; }
    float s = amax > 0.0f ? amax / 127.0f : 1.0f, inv = 1.0f / s;
    for (int i = 0; i < n; i++) {
        int v = (int)lrintf(x[i] * inv);
        q[i] = (int8_t)(v > 127 ? 127 : v < -127 ? -127 : v);
    }
    memset(q + n, 0, (size_t)nb * LANES - n);
    return s;
}

// out[i] = (W xq)[i] * sw[i] * sx
static void matmul_q(Model *M, float *out, const QMat *W, float sx, int reuse_x) {
    accel_gemv(W->q, M->xq, M->acc, W->m, W->nb, reuse_x);
    for (int i = 0; i < W->m; i++) out[i] = (float)M->acc[i] * W->s[i] * sx;
}

static void rmsnorm(float *o, const float *x, const float *w, int n) {
    float ss = 0.0f;
    for (int i = 0; i < n; i++) ss += x[i] * x[i];
    ss = 1.0f / sqrtf(ss / n + 1e-5f);
    for (int i = 0; i < n; i++) o[i] = w[i] * (ss * x[i]);
}

void softmax(float *x, int n) {
    float mx = x[0], sum = 0.0f;
    for (int i = 1; i < n; i++) if (x[i] > mx) mx = x[i];
    for (int i = 0; i < n; i++) { x[i] = expf(x[i] - mx); sum += x[i]; }
    for (int i = 0; i < n; i++) x[i] /= sum;
}

static void set_dims(Model *M) {
    Config *c = &M->c;
    M->hs = c->dim / c->n_heads;
    M->kv_dim = M->hs * c->n_kv_heads;
    M->hs_nb = nbeats(M->hs);
    M->seq_nb = nbeats(c->seq_len);
}

static void alloc_layers(Model *M) {
    QMat **mats[] = { &M->wq, &M->wk, &M->wv, &M->wo, &M->w1, &M->w2, &M->w3 };
    for (int i = 0; i < 7; i++) *mats[i] = xmalloc(sizeof(QMat) * M->c.n_layers);
}

static void alloc_state(Model *M) {
    Config *c = &M->c;
    int L = c->n_layers, dim = c->dim, hd = c->hidden_dim, kvh = c->n_kv_heads, S = c->seq_len;
    int maxd = hd > dim ? hd : dim;
    M->x = xmalloc(dim * 4); M->xb = xmalloc(dim * 4); M->xb2 = xmalloc(dim * 4);
    M->hb = xmalloc(hd * 4); M->hb2 = xmalloc(hd * 4);
    M->q = xmalloc(dim * 4); M->k = xmalloc(M->kv_dim * 4); M->v = xmalloc(M->kv_dim * 4);
    M->att = xmalloc(S * 4); M->logits = xmalloc((size_t)c->vocab_size * 4);
    M->rope = xmalloc(M->hs * 4);
    M->xq = accel_alloc_io((size_t)nbeats(maxd > S ? maxd : S) * LANES);
    M->hq = accel_alloc_io((size_t)M->hs_nb * LANES);
    M->acc = accel_alloc_io(4 * (size_t)(c->vocab_size > maxd ? c->vocab_size : maxd));
    M->kc = accel_alloc((size_t)L * kvh * S * M->hs_nb * LANES);
    M->ks = xmalloc((size_t)L * kvh * S * 4);
    M->vt = accel_alloc((size_t)L * kvh * M->hs * S);
    M->vs = xmalloc((size_t)L * kvh * S * 4);
}

// iterate over every quantized matrix in image order
#define FOR_EACH_QMAT(M, body) do { \
    for (int l_ = 0; l_ < (M)->c.n_layers; l_++) { \
        QMat *ms_[] = { &(M)->wq[l_], &(M)->wk[l_], &(M)->wv[l_], &(M)->wo[l_], \
                        &(M)->w1[l_], &(M)->w2[l_], &(M)->w3[l_] }; \
        for (int j_ = 0; j_ < 7; j_++) { QMat *W = ms_[j_]; body; } \
    } \
    { QMat *W = &(M)->wcls; body; } \
} while (0)

int model_load_image(Model *M, const uint8_t *img) {
    const uint32_t *h = (const uint32_t *)img;
    if (h[0] != IMG_MAGIC || h[1] != IMG_VERSION || h[2] != LANES) {
        printf("bad model image: magic 0x%08x version %u lanes %u\n", (unsigned)h[0], (unsigned)h[1], (unsigned)h[2]);
        return -1;
    }
    memcpy(&M->c, img + 16, sizeof(Config));
    set_dims(M);
    Config *c = &M->c;
    int L = c->n_layers, dim = c->dim, hd = c->hidden_dim;
    size_t off = align64(16 + sizeof(Config));
    float **norms[] = { &M->rms_att, &M->rms_ffn, &M->rms_final };
    size_t nlen[] = { (size_t)L * dim, (size_t)L * dim, (size_t)dim };
    for (int i = 0; i < 3; i++) {
        *norms[i] = xmalloc(nlen[i] * 4);
        memcpy(*norms[i], img + off, nlen[i] * 4);
        off = align64(off + nlen[i] * 4);
    }
    alloc_layers(M);
    int kvd = M->kv_dim;
    int shapes[7][2] = { {dim, dim}, {kvd, dim}, {kvd, dim}, {dim, dim}, {hd, dim}, {dim, hd}, {hd, dim} };
    int idx = 0;
    FOR_EACH_QMAT(M, {
        int m = idx < 7 * L ? shapes[idx % 7][0] : c->vocab_size;
        int n = idx < 7 * L ? shapes[idx % 7][1] : dim;
        W->m = m; W->nb = nbeats(n);
        W->s = xmalloc((size_t)m * 4);
        memcpy(W->s, img + off, (size_t)m * 4);
        off = align64(off + (size_t)m * 4);
        W->q = (int8_t *)(img + off);
        off = align64(off + (size_t)m * W->nb * LANES);
        idx++;
    });
    alloc_state(M);
    return 0;
}

#ifndef MODEL_NO_FILE
static QMat quant_mat(const float *w, int m, int n) {
    QMat r = { .m = m, .nb = nbeats(n) };
    r.q = accel_alloc((size_t)m * r.nb * LANES);
    r.s = xmalloc(sizeof(float) * m);
    for (int i = 0; i < m; i++) r.s[i] = quant_vec(w + (size_t)i * n, n, r.q + (size_t)i * r.nb * LANES, r.nb);
    return r;
}

void model_load_float(Model *M, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    Config *c = &M->c;
    if (fread(c, sizeof(Config), 1, f) != 1) exit(1);
    int shared = c->vocab_size > 0;
    c->vocab_size = abs(c->vocab_size);
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, sizeof(Config), SEEK_SET);
    float *all = xmalloc(sz); // whole float checkpoint; freed after quantization
    if (fread(all, 1, sz - sizeof(Config), f) != (size_t)(sz - sizeof(Config))) exit(1);
    fclose(f);

    set_dims(M);
    int L = c->n_layers, dim = c->dim, hd = c->hidden_dim;
    if (c->seq_len % LANES) { fprintf(stderr, "seq_len must be a multiple of %d\n", LANES); exit(1); }

    float *p = all, *emb = p;              p += (size_t)c->vocab_size * dim;
    float *rms_att = p;                    p += (size_t)L * dim;
    float *wq = p;                         p += (size_t)L * dim * dim;
    float *wk = p;                         p += (size_t)L * dim * M->kv_dim;
    float *wv = p;                         p += (size_t)L * dim * M->kv_dim;
    float *wo = p;                         p += (size_t)L * dim * dim;
    float *rms_ffn = p;                    p += (size_t)L * dim;
    float *w1 = p;                         p += (size_t)L * dim * hd;
    float *w2 = p;                         p += (size_t)L * hd * dim;
    float *w3 = p;                         p += (size_t)L * dim * hd;
    float *rms_final = p;                  p += dim;
    p += (size_t)c->seq_len * M->hs;       // legacy freq_cis_real/imag
    float *wcls = shared ? emb : p;

    M->rms_att = xmalloc(sizeof(float) * L * dim);   memcpy(M->rms_att, rms_att, sizeof(float) * L * dim);
    M->rms_ffn = xmalloc(sizeof(float) * L * dim);   memcpy(M->rms_ffn, rms_ffn, sizeof(float) * L * dim);
    M->rms_final = xmalloc(sizeof(float) * dim);     memcpy(M->rms_final, rms_final, sizeof(float) * dim);
    alloc_layers(M);
    for (int l = 0; l < L; l++) {
        M->wq[l] = quant_mat(wq + (size_t)l * dim * dim, dim, dim);
        M->wk[l] = quant_mat(wk + (size_t)l * dim * M->kv_dim, M->kv_dim, dim);
        M->wv[l] = quant_mat(wv + (size_t)l * dim * M->kv_dim, M->kv_dim, dim);
        M->wo[l] = quant_mat(wo + (size_t)l * dim * dim, dim, dim);
        M->w1[l] = quant_mat(w1 + (size_t)l * dim * hd, hd, dim);
        M->w2[l] = quant_mat(w2 + (size_t)l * hd * dim, dim, hd);
        M->w3[l] = quant_mat(w3 + (size_t)l * dim * hd, hd, dim);
    }
    M->wcls = quant_mat(wcls, c->vocab_size, dim);
    if (!shared) fprintf(stderr, "note: unshared classifier; embedding taken from dequantized wcls is wrong\n");
    free(all);
    alloc_state(M);
}

static void put_pad(FILE *f, size_t *off) {
    static const uint8_t z[64];
    size_t a = align64(*off);
    fwrite(z, 1, a - *off, f);
    *off = a;
}

int model_write_image(const Model *M, const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    uint32_t h[4] = { IMG_MAGIC, IMG_VERSION, LANES, 0 };
    size_t off = 0;
    fwrite(h, 4, 4, f); fwrite(&M->c, sizeof(Config), 1, f); off = 16 + sizeof(Config);
    put_pad(f, &off);
    int L = M->c.n_layers, dim = M->c.dim;
    const float *norms[] = { M->rms_att, M->rms_ffn, M->rms_final };
    size_t nlen[] = { (size_t)L * dim, (size_t)L * dim, (size_t)dim };
    for (int i = 0; i < 3; i++) { fwrite(norms[i], 4, nlen[i], f); off += nlen[i] * 4; put_pad(f, &off); }
    Model *Mw = (Model *)M; // FOR_EACH_QMAT takes non-const pointers; nothing is modified
    FOR_EACH_QMAT(Mw, {
        fwrite(W->s, 4, W->m, f); off += (size_t)W->m * 4; put_pad(f, &off);
        size_t qb = (size_t)W->m * W->nb * LANES;
        fwrite(W->q, 1, qb, f); off += qb; put_pad(f, &off);
    });
    fclose(f);
    fprintf(stderr, "wrote %s (%zu bytes)\n", path, off);
    return 0;
}
#endif

float *model_forward(Model *M, int token, int pos) {
    Config *c = &M->c;
    int dim = c->dim, hd = c->hidden_dim, hs = M->hs, S = c->seq_len;
    int kv_mul = c->n_heads / c->n_kv_heads, rowb = M->hs_nb * LANES;

    // embedding = dequantized classifier row (shared weights)
    const int8_t *er = M->wcls.q + (size_t)token * M->wcls.nb * LANES;
    for (int i = 0; i < dim; i++) M->x[i] = er[i] * M->wcls.s[token];

    // RoPE rotation for this position, per (even) head dimension
    for (int i = 0; i < hs; i += 2) {
        float val = pos * (1.0f / powf(10000.0f, i / (float)hs));
        M->rope[i] = cosf(val); M->rope[i + 1] = sinf(val);
    }

    for (int l = 0; l < c->n_layers; l++) {
        rmsnorm(M->xb, M->x, M->rms_att + l * dim, dim);
        float sx = quant_vec(M->xb, dim, M->xq, nbeats(dim));
        matmul_q(M, M->q, &M->wq[l], sx, 0);
        matmul_q(M, M->k, &M->wk[l], sx, 1);
        matmul_q(M, M->v, &M->wv[l], sx, 1);

        for (int i = 0; i < dim; i += 2) { // RoPE
            float fcr = M->rope[i % hs], fci = M->rope[i % hs + 1];
            int rotn = i < M->kv_dim ? 2 : 1;
            for (int r = 0; r < rotn; r++) {
                float *vec = r == 0 ? M->q : M->k;
                float v0 = vec[i], v1 = vec[i + 1];
                vec[i] = v0 * fcr - v1 * fci;
                vec[i + 1] = v0 * fci + v1 * fcr;
            }
        }

        // write K (row per pos) and V (transposed) into the int8 caches
        for (int h = 0; h < c->n_kv_heads; h++) {
            size_t lh = (size_t)l * c->n_kv_heads + h;
            M->ks[lh * S + pos] = quant_vec(M->k + h * hs, hs, M->kc + (lh * S + pos) * rowb, M->hs_nb);
            int8_t vrow[LANES * 8];
            M->vs[lh * S + pos] = quant_vec(M->v + h * hs, hs, vrow, M->hs_nb);
            for (int d = 0; d < hs; d++) M->vt[(lh * hs + d) * S + pos] = vrow[d];
        }

        for (int h = 0; h < c->n_heads; h++) {
            size_t lh = (size_t)l * c->n_kv_heads + h / kv_mul;
            // scores = K[0..pos] . q
            float sq = quant_vec(M->q + h * hs, hs, M->hq, M->hs_nb);
            accel_gemv(M->kc + lh * S * rowb, M->hq, M->acc, pos + 1, M->hs_nb, 0);
            float k = sq / sqrtf((float)hs);
            for (int t = 0; t <= pos; t++) M->att[t] = M->acc[t] * M->ks[lh * S + t] * k;
            softmax(M->att, pos + 1);
            // out = Vt . (att * sv); positions > pos are zero in the vector
            for (int t = 0; t <= pos; t++) M->att[t] *= M->vs[lh * S + t];
            float sa = quant_vec(M->att, pos + 1, M->xq, M->seq_nb);
            accel_gemv(M->vt + lh * hs * S, M->xq, M->acc, hs, M->seq_nb, 0);
            for (int d = 0; d < hs; d++) M->xb[h * hs + d] = M->acc[d] * sa;
        }

        sx = quant_vec(M->xb, dim, M->xq, nbeats(dim));
        matmul_q(M, M->xb2, &M->wo[l], sx, 0);
        for (int i = 0; i < dim; i++) M->x[i] += M->xb2[i];

        rmsnorm(M->xb, M->x, M->rms_ffn + l * dim, dim);
        sx = quant_vec(M->xb, dim, M->xq, nbeats(dim));
        matmul_q(M, M->hb, &M->w1[l], sx, 0);
        matmul_q(M, M->hb2, &M->w3[l], sx, 1);
        for (int i = 0; i < hd; i++) {
            float v = M->hb[i];
            M->hb[i] = v * (1.0f / (1.0f + expf(-v))) * M->hb2[i];
        }
        sx = quant_vec(M->hb, hd, M->xq, nbeats(hd));
        matmul_q(M, M->xb, &M->w2[l], sx, 0);
        for (int i = 0; i < dim; i++) M->x[i] += M->xb[i];
    }

    rmsnorm(M->x, M->x, M->rms_final, dim);
    float sx = quant_vec(M->x, dim, M->xq, nbeats(dim));
    matmul_q(M, M->logits, &M->wcls, sx, 0);
    return M->logits;
}
