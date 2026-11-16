# tinyllm_fpga — llama2.c stories15M on an FPGA int8 GEMV engine

> Code and documentation generated with Claude (Anthropic) in a single session. My role: idea,
> direction, review and running the hardware steps on the shared VC707. How the session went,
> including its mistakes, is in [`SESSION_ANALYSIS.md`](SESSION_ANALYSIS.md).

> **Reproduced from a fresh clone on 2026-11-16:** `make run`, `make quality` (top-1 0.973, perplexity 1.471),
> `make sim` (0 errors in all three tests), `make fw` and `make qemu`. Vivado builds and the board run are from 2026-09-30.

Every matmul, the attention scores (q·K) and softmax·V run on one int8 GEMV engine
(`rtl/gemv_int8.v`, 32 int8 lanes/cycle). The CPU does RMSNorm, RoPE, softmax, SiLU and rescaling.

| path | what |
|---|---|
| `rtl/gemv_int8.v` | GEMV core: stream x then W, int32 results out |
| `rtl/gemv_axi.v` | AXI-Lite regs + AXI-Stream wrapper (for AXI DMA) |
| `sw/runq8.c` | int8 inference (per-row weights, per-vector activations, int8 K / transposed V cache) |
| `sw/accel.c` | backend switch + bit-exact C model + trace recorder |
| `sw/accel_fpga.c` | Linux/Zynq backend: `/dev/mem` regs + AXI DMA + u-dma-buf |
| `tb/` | trace-replay testbench (random stalls), AXI smoke test |
| `sw/model.c` | model code shared by host tool and firmware; exports the int8 model image (`-E`) |
| `sw/bm/` | VC707 bare-metal firmware (MicroBlaze V), QEMU test build, xsdb `run.tcl` / `diag.tcl` / `diag2.tcl` |
| `rtl/status_leds.v` | VC707 bring-up status on the user LEDs |
| `syn/ooc.tcl`, `syn/bd_kv260.tcl`, `syn/bd_vc707.tcl` | OOC timing/util; full KV260 / VC707 systems → `.bit` + `.xsa` |

## Requirements

- gcc and GNU make
- Icarus Verilog (`iverilog`/`vvp`; tested with 11.0)
- python3 with numpy (`make quality`)
- Vivado 2024.2 (MicroBlaze V needs ≥ 2024.1) with the VC707 / KV260 board files (hardware builds only)
- `riscv32-unknown-elf-gcc` built for rv32imafc/ilp32f with newlib-nano (`make fw`, `make qemu`)
- `qemu-system-riscv32` (tested with 6.2)
- pyserial, for `python3 -m serial.tools.miniterm`

Tools are taken from the PATH by default. To use other locations, pass them on the command line
(`make vc707 VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado`, `make fw CROSS=/opt/riscv/bin/riscv32-unknown-elf-`)
or put them in an untracked `local.mk` next to the top-level `Makefile` (it is git-ignored and also
read by `sw/bm/Makefile`):

    VIVADO := /opt/Xilinx/Vivado/2024.2/bin/vivado
    XSDB   := /opt/Xilinx/Vivado/2024.2/bin/xsdb
    CROSS  := /opt/riscv/bin/riscv32-unknown-elf-

## Model files (not in the repository)

    mkdir -p model
    wget -P model https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin
    wget -P model https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin

## Host
    make run          # int8 model with the C reference backend
    make quality      # top-1 agreement vs float model (≈0.97)
    make sim          # random + AXI + full-token RTL co-simulation (bit-exact; ~10 min, fails unless all PASS)
    make kv260        # bitstream: syn/kv260_proj/gemv_kv260.{bit,xsa}

## On a KV260 (Ubuntu 22.04 image) — not yet tested on hardware
1. Load the bitstream (e.g. `fpgautil -b gemv_kv260.bit`, or package it as an xmutil app with an
   empty device-tree overlay). PL clock is 250 MHz. Map: gemv @ 0xA000_0000, DMA @ 0xA001_0000.
2. Contiguous DMA memory: build/insert [u-dma-buf](https://github.com/ikwzm/udmabuf) with ≥ 48 MB
   (`sudo insmod u-dma-buf.ko udmabuf0=67108864`).
3. `make build/runq8_fpga` on the board, then
   `sudo ./build/runq8_fpga model/stories15M.bin -z model/tokenizer.bin -b fpga -i "Once upon a time"`.
   Output must match `-b ref` token-for-token (the hardware is bit-exact with the C model).

## On the VC707 (bare metal) — verified on hardware (2026-09-30)

| Test | Result |
|---|---|
| Firmware boot | banner printed; model image parsed from DDR in 745 ms |
| Correctness (`:v 1`, 64 tokens) | 7,360 accelerator calls, **0 mismatches** vs the CPU reference |
| Same output as simulation | text identical token-for-token to the QEMU run of the same firmware (C model) |
| Speed, greedy | **13.0 tok/s** (203-token story, ended at the model's end-of-story token) |
| Speed, temperature 0.8 + top-p 0.9 | **4.8 tok/s** |
| Accelerator utilization | 7% (greedy), 3% (sampling) |
| JTAG model load (`run.tcl`) | ~20 min for the 15.4 MB image |

Sample output from the board (greedy, prompt "Once upon a time"):
> Once upon a time, there was a little girl named Lily. She loved to play outside in the sunshine.
> One day, she saw a big, red ball in the sky. It was the sun! She thought it was so pretty.
> Lily's mommy came outside and said, "Lily, it's time to come inside. The sun is going down and it's
> getting dark." … "Don't worry, Lily. The dog is friendly. He won't hurt you."

Where the time goes: the accelerator needs ~5 ms per token; the rest of the ~77 ms is the 100 MHz
MicroBlaze V (logit rescaling over 32,000 entries, RMSNorm, RoPE, attention softmax; with sampling
also a softmax + top-p sort over the whole vocabulary).

Next steps, by payoff:
1. Store the model in the VC707's 128 MB BPI flash and copy it to DDR at boot (removes the 20-min JTAG load).
2. Avoid the full-vocabulary softmax when sampling (~2× sampling speed).
3. Raise the CPU clock (the engine already meets 200 MHz), or move logit rescaling into hardware.

Bring-up notes:
- `xsdb` may list only `BSCAN JTAG` right after programming; the MicroBlaze V hart appears a moment later.
- Read-only diagnostics: `sw/bm/diag.tcl` (targets, gemv `INFO`, DMA status, DDR/BRAM contents) and
  `sw/bm/diag2.tcl` (PC samples, firmware-in-BRAM check, direct UART TX test). Don't run them while
  `run.tcl` is still downloading.
- The board is shared: check that nobody else holds the JTAG cable (e.g. `pgrep -a openocd`) before programming.
- The bitstream verified on the board was built before the status LEDs were added; it is attached to the
  GitHub release [`vc707-verified`](https://github.com/harikheshav-ai/tinyllm_fpga/releases/tag/vc707-verified). `make vc707` now also drives the 8 user LEDs with bring-up status (MIG lock, DDR
  calibration, clock lock, resets, heartbeats; see `rtl/status_leds.v`). That build meets timing but
  hasn't been run on the board.

System (`syn/bd_vc707.tcl`, 100 MHz): MicroBlaze V RV32IMAFC, 256K LMB BRAM (code + DMA I/O buffers,
second port on AXI for the DMA), DDR3 via MIG, AXI DMA, gemv_axi, UART Lite 115200.
No CPU-cache/DMA sharing: the D-cache covers only the CPU heap (0x8000_0000–0x8FFF_FFFF);
the model image (0x9000_0000), tokenizer (0x9100_0000) and KV caches (0x9200_0000+) are uncached.

    make vc707                 # bitstream: syn/vc707_proj/gemv_vc707.bit (~20 min)
    make fw                    # sw/bm/fw.elf (riscv32-unknown-elf-gcc, rv32imafc/ilp32f)
    make qemu                  # same firmware on qemu-system-riscv32 (C model instead of the FPGA);
                               # interactive: type at `prompt>`, quit with Ctrl-A X
    make run-vc707             # xsdb: program FPGA, JTAG-load model + tokenizer into DDR, start
    python3 -m serial.tools.miniterm /dev/ttyUSB2 115200   # CP2103 UART; needs dialout group or a chmod

At the `prompt>` type a story start; `:t 0.8` sets temperature, `:n 128` steps,
`:v 1` checks every accelerator result against the CPU (reports mismatches).

## Verification

| Claim | Method | Result |
|---|---|---|
| Int8 quantization keeps quality | Greedy text compared with float `run.c`; numpy float model teacher-forced on the int8 output | Identical for about 40 tokens; **97.3%** top-1 agreement; float perplexity 1.47 |
| RTL is bit-exact | 200 random jobs (including −128 extremes, m=1, nb=1, max nb, x reuse) × 5 stall settings | 0 errors in all 5; 98.5% utilization with no stalls |
| RTL handles real workloads | Replayed all 115 accelerator calls of one real token | 52,340 results, **0 errors**, 96% utilization |
| AXI wrapper works | Register programming, x load, x reuse, STATUS/CYCLES/INFO readback | PASS |
| Timing closes | Vivado implementation | Engine: KV260 part at 300 MHz (+0.47 ns), VC707 part at 200 MHz (+0.08 ns). Systems: KV260 at 250 MHz (+0.49 ns), VC707 at 100 MHz (+0.15 ns; +0.14 ns with LEDs) |
| Firmware works on RV32 | `qemu-system-riscv32` with the real image and tokenizer | Coherent stories |
| **Hardware computes correctly** | Firmware `:v 1`: every FPGA GEMV result recomputed on the CPU | **7,360 calls, 0 mismatches** (64 tokens) |
| **End-to-end output matches** | Board output compared with the QEMU run of the same firmware | Identical text, token for token |

## Resources

| Design | Clock | LUTs | Registers | BRAM | DSP |
|---|---|---|---|---|---|
| Engine only, KV260 part (xck26) | 300 MHz | 3,147 | 2,121 | 0 | 0 |
| Engine only, VC707 part (xc7vx485t) | 200 MHz | 3,002 | 1,863 | 4 | 0 |
| KV260 full system | 250 MHz | 8,596 (7.3%) | 11,437 | 5.5 | 0 |
| VC707 full system | 100 MHz | 50,520 (16.6%) | 49,662 | 82.5 (8%) | 6 |

## Status

Not verified:
- The KV260 build and Linux driver (no board).
- The LED-version VC707 bitstream (built, not run).
- The 97.3% agreement figure includes the forced prompt tokens, so it's slightly optimistic.
- The RISC-V output drifts from the x86 output after about 40 tokens because libm and FMA rounding
  differ; the accelerator itself is bit-exact, as the hardware check confirms.

## Licence and credits

This project's own code (RTL, testbenches, firmware, host software and scripts) is under the MIT License; see
[`LICENSE`](LICENSE).
`sw/run.c` is [karpathy/llama2.c](https://github.com/karpathy/llama2.c)'s `run.c`, unmodified, and
`sw/tok_sampler.h` is adapted from it. Both are under the MIT License; see
[`LICENSE-llama2.c`](LICENSE-llama2.c). The stories15M model and tokenizer also come from llama2.c.
