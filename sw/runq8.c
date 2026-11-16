// Host driver for the int8 model (model.c): generation, RTL trace capture and
// model-image export for the bare-metal VC707 firmware.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "model.h"
#include "tok_sampler.h"

static long time_ms(void) {
    struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void usage(void) {
    fprintf(stderr,
        "usage: runq8 <checkpoint.bin | -I model.img> [options]\n"
        "  -z <path>  tokenizer (default tokenizer.bin)\n"
        "  -i <str>   prompt\n"
        "  -n <int>   steps (default 256)\n"
        "  -t <float> temperature (default 0 = greedy)\n"
        "  -p <float> top-p (default 0.9)\n"
        "  -s <int>   seed\n"
        "  -b ref|fpga  accelerator backend (default ref)\n"
        "  -T <file>  write GEMV trace for RTL co-simulation\n"
        "  -P <int>   only trace the forward pass at this position (default: all)\n"
        "  -o <file>  write generated token ids, one per line\n"
        "  -I <file>  load a model image (from -E) instead of a float checkpoint\n"
        "  -E <file>  write the quantized model image for the firmware and exit\n"
        "  -V 1       verify every accelerator result against the C model\n");
    exit(1);
}

int main(int argc, char **argv) {
    if (argc < 2) usage();
    char *ckpt = argv[1][0] == '-' ? NULL : argv[1], *img_path = NULL, *export_path = NULL, *tok_path = "tokenizer.bin", *prompt = "", *trace_path = NULL, *ids_path = NULL;
    int steps = 256, trace_pos = -1;
    float temp = 0.0f, topp = 0.9f;
    unsigned long long seed = (unsigned long long)time(NULL);
    accel_backend_t be = ACCEL_REF;
    for (int i = ckpt ? 2 : 1; i < argc; i += 2) {
        if (i + 1 >= argc || argv[i][0] != '-') usage();
        char *a = argv[i + 1];
        switch (argv[i][1]) {
        case 'z': tok_path = a; break;
        case 'i': prompt = a; break;
        case 'n': steps = atoi(a); break;
        case 't': temp = atof(a); break;
        case 'p': topp = atof(a); break;
        case 's': seed = atoll(a); break;
        case 'b': be = strcmp(a, "fpga") == 0 ? ACCEL_FPGA : ACCEL_REF; break;
        case 'T': trace_path = a; break;
        case 'P': trace_pos = atoi(a); break;
        case 'o': ids_path = a; break;
        case 'I': img_path = a; break;
        case 'E': export_path = a; break;
        case 'V': accel_verify = atoi(a); break;
        default: usage();
        }
    }
    if (accel_init(be)) return 1;

    Model M;
    if (img_path) {
        FILE *f = fopen(img_path, "rb");
        if (!f) { perror(img_path); return 1; }
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        uint8_t *img = accel_alloc(sz);
        if (fread(img, 1, sz, f) != (size_t)sz) return 1;
        fclose(f);
        if (model_load_image(&M, img)) return 1;
    } else if (ckpt) {
        model_load_float(&M, ckpt);
    } else usage();
    if (export_path) return model_write_image(&M, export_path) ? 1 : 0;
    if (steps <= 0 || steps > M.c.seq_len) steps = M.c.seq_len;
    Tokenizer tok; build_tokenizer(&tok, tok_path, M.c.vocab_size);
    Sampler sampler; build_sampler(&sampler, M.c.vocab_size, temp, topp, seed);

    int *ptoks = malloc(sizeof(int) * (strlen(prompt) + 3)), np = 0;
    encode(&tok, prompt, 1, 0, ptoks, &np);
    FILE *trace = trace_path ? fopen(trace_path, "wb") : NULL;
    FILE *ids = ids_path ? fopen(ids_path, "w") : NULL;

    long start = 0;
    int token = ptoks[0], next, pos = 0;
    while (pos < steps) {
        accel_trace = (trace && (trace_pos < 0 || trace_pos == pos)) ? trace : NULL;
        float *logits = model_forward(&M, token, pos);
        accel_trace = NULL;
        next = pos < np - 1 ? ptoks[pos + 1] : sample(&sampler, logits);
        pos++;
        if (next == 1) break;
        safe_printf(decode(&tok, token, next));
        fflush(stdout);
        if (ids) fprintf(ids, "%d\n", next);
        token = next;
        if (!start) start = time_ms();
    }
    printf("\n");
    if (pos > 1) fprintf(stderr, "achieved tok/s: %f\n", (pos - 1) / (double)(time_ms() - start) * 1000);
    if (accel_verify) fprintf(stderr, "verify: %llu accelerator calls, %llu mismatching results\n",
                              (unsigned long long)accel_calls, (unsigned long long)accel_mismatches);
    if (trace) { uint32_t d = TRACE_DONE; fwrite(&d, 4, 1, trace); fclose(trace); }
    if (ids) fclose(ids);
    return 0;
}
