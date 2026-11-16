// VC707 firmware: interactive story generation over the UART.
// The model image and tokenizer are placed in DDR over JTAG by run.tcl.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../model.h"
#include "../tok_sampler.h"
#include "platform.h"

#ifdef QEMU
#define BACKEND ACCEL_REF
static uint64_t accel_fpga_cycles;
#else
#define BACKEND ACCEL_FPGA
extern uint64_t accel_fpga_cycles;
#endif
int uart_getc(void);
void uart_putc(char c);

// tokenizer.bin parsed from memory (same format as build_tokenizer in run.c)
static void build_tokenizer_mem(Tokenizer *t, const uint8_t *p, int vocab_size) {
    t->vocab_size = vocab_size;
    t->vocab = malloc(vocab_size * sizeof(char *));
    t->vocab_scores = malloc(vocab_size * sizeof(float));
    t->sorted_vocab = NULL;
    for (int i = 0; i < 256; i++) { t->byte_pieces[i * 2] = (unsigned char)i; t->byte_pieces[i * 2 + 1] = 0; }
    memcpy(&t->max_token_length, p, 4); p += 4;
    for (int i = 0; i < vocab_size; i++) {
        int len;
        memcpy(&t->vocab_scores[i], p, 4); p += 4;
        memcpy(&len, p, 4); p += 4;
        t->vocab[i] = malloc(len + 1);
        memcpy(t->vocab[i], p, len); p += len;
        t->vocab[i][len] = '\0';
    }
}

static int read_line(char *buf, int cap) {
    int n = 0;
    for (;;) {
        int c = uart_getc();
        if (c == '\r' || c == '\n') { printf("\n"); break; }
        if ((c == 0x7F || c == 0x08) && n > 0) { n--; printf("\b \b"); fflush(stdout); continue; }
        if (c >= 0x20 && c < 0x7F && n < cap - 1) { buf[n++] = (char)c; uart_putc((char)c); }
    }
    buf[n] = '\0';
    return n;
}

static void help(void) {
    printf("commands:  :t <temperature>  :p <top-p>  :n <steps>  :s <seed>  :v 0|1 (verify)  :h\n"
           "anything else is used as the story prompt (empty = unconditional)\n");
}

int main(void) {
    printf("\n\n== tinyllm_fpga: stories15M on VC707 (MicroBlaze V + int8 GEMV) ==\n");
    if (accel_init(BACKEND)) return 1;
    Model M;
    unsigned long t0 = rdcycle();
    if (model_load_image(&M, (const uint8_t *)IMG_ADDR)) {
        printf("no model image at 0x%08x; load it with run.tcl\n", (unsigned)IMG_ADDR);
        return 1;
    }
    Tokenizer tok;
    build_tokenizer_mem(&tok, (const uint8_t *)TOK_ADDR, M.c.vocab_size);
    printf("model: dim %d, hidden %d, %d layers, %d heads, vocab %d, seq %d (loaded in %lu ms)\n",
           M.c.dim, M.c.hidden_dim, M.c.n_layers, M.c.n_heads, M.c.vocab_size, M.c.seq_len,
           (rdcycle() - t0) / (CPU_HZ / 1000));

    float temp = 0.0f, topp = 0.9f;
    int steps = 256;
    unsigned long long seed = rdcycle();
    static char line[512];
    int *ptoks = malloc(sizeof(int) * (sizeof(line) + 3));
    help();

    for (;;) {
        printf("\nprompt> ");
        fflush(stdout);
        read_line(line, sizeof line);
        if (line[0] == ':') {
            char *a = line + 2;
            switch (line[1]) {
            case 't': temp = strtof(a, NULL); break;
            case 'p': topp = strtof(a, NULL); break;
            case 'n': steps = atoi(a); break;
            case 's': seed = strtoull(a, NULL, 10); break;
            case 'v': accel_verify = atoi(a); break;
            default: help(); break;
            }
            printf("temperature %.2f, top-p %.2f, steps %d, verify %d\n", (double)temp, (double)topp, steps, accel_verify);
            continue;
        }
        if (steps <= 0 || steps > M.c.seq_len) steps = M.c.seq_len;
        Sampler sampler;
        build_sampler(&sampler, M.c.vocab_size, temp, topp, seed++);
        int np = 0;
        encode(&tok, line, 1, 0, ptoks, &np);

        accel_fpga_cycles = 0; accel_calls = 0; accel_mismatches = 0;
        unsigned long long start = rdcycle64(), first = 0;
        int token = ptoks[0], next, pos = 0;
        while (pos < steps) {
            float *logits = model_forward(&M, token, pos);
            next = pos < np - 1 ? ptoks[pos + 1] : sample(&sampler, logits);
            pos++;
            if (next == 1) break;
            safe_printf(decode(&tok, token, next));
            fflush(stdout);
            token = next;
            if (!first) first = rdcycle64();
        }
        unsigned long long end = rdcycle64();
        double secs = (double)(end - first) / CPU_HZ;
        printf("\n[%d tokens, %.1f tok/s, accelerator busy %.0f%% of the time",
               pos, pos > 1 ? (pos - 1) / secs : 0.0,
               100.0 * (double)accel_fpga_cycles / (double)(end - start));
        if (accel_verify) printf(", verify: %lu calls, %lu mismatches", (unsigned long)accel_calls, (unsigned long)accel_mismatches);
        printf("]\n");
        free_sampler(&sampler);
    }
}
