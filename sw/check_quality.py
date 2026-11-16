"""Teacher-force a token sequence produced by runq8 (greedy, -o ids.txt) through the
float llama2.c model and report how often the float model's argmax agrees with the
int8 model's choice, plus the float model's perplexity on that sequence."""
import sys
import numpy as np

ckpt, ids_path = sys.argv[1], sys.argv[2]
raw = open(ckpt, "rb").read()
dim, hd, L, H, KVH, V, S = np.frombuffer(raw[:28], np.int32)
V = abs(V)
w = np.frombuffer(raw[28:], np.float32)
hs = dim // H
kvd = hs * KVH
o = 0
def take(*shape):
    global o
    n = int(np.prod(shape)); a = w[o:o + n].reshape(shape); o += n; return a
emb = take(V, dim); rms_att = take(L, dim); wq = take(L, dim, dim); wk = take(L, kvd, dim)
wv = take(L, kvd, dim); wo = take(L, dim, dim); rms_ffn = take(L, dim)
w1 = take(L, hd, dim); w2 = take(L, dim, hd); w3 = take(L, hd, dim); rms_f = take(dim)

def rms(x, g): return g * x / np.sqrt(np.mean(x * x) + 1e-5)
freqs = 1.0 / 10000 ** (np.arange(0, hs, 2) / hs)
def rope(v, pos):
    v = v.reshape(-1, hs // 2, 2); c, s = np.cos(pos * freqs), np.sin(pos * freqs)
    return np.stack([v[..., 0] * c - v[..., 1] * s, v[..., 0] * s + v[..., 1] * c], -1).reshape(-1)

ids = [1] + [int(t) for t in open(ids_path)]  # BOS + tokens printed by runq8
kc = np.zeros((L, S, kvd), np.float32); vc = np.zeros_like(kc)
agree, nll = 0, 0.0
for pos in range(len(ids) - 1):
    x = emb[ids[pos]].copy()
    for l in range(L):
        xb = rms(x, rms_att[l])
        q, k, v = rope(wq[l] @ xb, pos), rope(wk[l] @ xb, pos), wv[l] @ xb
        kc[l, pos], vc[l, pos] = k, v
        out = np.empty(dim, np.float32)
        for h in range(H):
            kh = kc[l, :pos + 1, h * hs:(h + 1) * hs]
            a = kh @ q[h * hs:(h + 1) * hs] / np.sqrt(hs); a = np.exp(a - a.max()); a /= a.sum()
            out[h * hs:(h + 1) * hs] = a @ vc[l, :pos + 1, h * hs:(h + 1) * hs]
        x = x + wo[l] @ out
        xb = rms(x, rms_ffn[l]); h1 = w1[l] @ xb
        x = x + w2[l] @ (h1 / (1 + np.exp(-h1)) * (w3[l] @ xb))
    logits = emb @ rms(x, rms_f)
    lp = logits - logits.max(); lp -= np.log(np.exp(lp).sum())
    agree += int(np.argmax(logits) == ids[pos + 1]); nll -= lp[ids[pos + 1]]
n = len(ids) - 1
print(f"tokens={n}  float/int8 top-1 agreement={agree / n:.3f}  float ppl on int8 text={np.exp(nll / n):.3f}")
