"""Random GEMV trace (sw/accel.h format) covering edge cases: m=1, nb=1, nb=XDEPTH,
x reuse, and full-range int8 including -128."""
import struct, sys
import numpy as np

P, XDEPTH = 32, 32
out, njobs, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 0
rng = np.random.default_rng(seed)
with open(out, "wb") as f:
    x = None
    for j in range(njobs):
        m = int(rng.choice([1, 2, 3, int(rng.integers(1, 300))]))
        nb = int(rng.choice([1, XDEPTH, int(rng.integers(1, XDEPTH + 1))]))
        reuse = x is not None and x.size == nb * P and rng.random() < 0.5
        if not reuse:
            x = rng.integers(-128, 128, nb * P, dtype=np.int8)
        if rng.random() < 0.1:  # worst-case magnitudes
            W = np.full((m, nb * P), -128, np.int8); x = np.full(nb * P, -128, np.int8); reuse = False
        else:
            W = rng.integers(-128, 128, (m, nb * P), dtype=np.int8)
        y = (W.astype(np.int64) @ x.astype(np.int64)).astype(np.int32)
        f.write(struct.pack("<4I", 0x564D4547, m, nb, int(reuse)))
        if not reuse:
            f.write(x.tobytes())
        f.write(W.tobytes()); f.write(y.astype("<i4").tobytes())
    f.write(struct.pack("<I", 0x454E4F44))
