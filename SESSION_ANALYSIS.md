# How this project was built: session analysis

This project was built in a single Claude Code session on 2026-09-30. Everything below
(design, RTL, firmware, Vivado runs, hardware bring-up) was done by one agent. The user gave
direction and ran the steps that needed the shared board. This file records how the session went,
for analysis of AI-built hardware projects.

## Summary

| | |
|---|---|
| Outcome | **stories15M runs on the VC707**: 13.0 tok/s greedy, 4.8 tok/s sampled; 7,360 accelerator calls checked against the CPU with 0 mismatches |
| User turns | 18 (design and build: 1–3; reports: 4–5; hardware bring-up: 6–17; final update: 18) |
| Subagents spawned | **0.** No `Agent` or `Workflow` calls; one agent did all the work. |
| Tool calls | About **145**: ~120 Bash, ~33 Write, 1 Read, 1 ToolSearch, 2 user confirmations |
| Permission denials | 2, both by the auto-mode check on programming the shared board. Neither was worked around; the user ran those steps. |
| Background jobs | 10: RTL simulations, Vivado runs, one file search, a download watcher; plus a UART logger |
| Vivado runs | 9: 2 out-of-context, 1 KV260 system, 3 VC707 validate-only, 2 VC707 system builds (plus 1 failed launch) |
| Code written | About 2,250 lines across 30 files, excluding the downloaded `run.c` and the ~350 lines adapted from it |
| Hardware runs | VC707: programmed, model loaded over JTAG, firmware run, verified and benchmarked. KV260: not run (no board). |

## Timeline by turn

**Turn 1: "Run Claude in a FPGA"**
- No tools used.
- Claude explained that its own weights aren't public and the model is far too large for an FPGA.
- It offered three alternatives. The user picked an open-weight tiny LLM (stories15M) with an FPGA accelerator.

**Turn 2: build the accelerator (about 61 tool calls)**
1. **Environment check:** Vivado 2024.2 (not on PATH, broken `settings64.sh`), iverilog, numpy/torch, RISC-V toolchains.
2. **Model:** downloaded `stories15M.bin`, `tokenizer.bin` and `run.c` from karpathy/llama2.c; float baseline at 186 tokens/s on x86.
3. **Int8 software model:** `runq8.c` and `accel.{h,c}`; every matmul and both attention products go through one `accel_gemv()` call.
4. **RTL:** `gemv_int8.v`, with 32 lanes, a pipelined adder tree, and an output FIFO with backpressure.
5. **Testbenches:** trace replay with random stalls, plus a random trace generator.
6. **AXI wrapper:** `gemv_axi.v` and its smoke test.
7. **Synthesis:** out-of-context runs for the KV260 and VC707 parts.
8. **KV260:** Linux driver `accel_fpga.c` and the full Zynq + AXI DMA + engine system (bitstream and XSA).
9. **Wrap-up:** Makefile and README.

**Turn 3: "VC707?" (about 41 tool calls)**
1. **Platform research:** MicroBlaze V parameters, the debug module, the VC707 board interfaces.
2. **Block design:** `bd_vc707.tcl` (MicroBlaze V, MIG DDR3, BRAM, AXI DMA, engine, UART). The first validate failed on overlapping addresses; after fixing them, the full bitstream was built.
3. **Software refactor:** model code split into `model.{h,c}`, shared by host and firmware, with int8 image export and load.
4. **Firmware** (`sw/bm/`): startup, linker script, newlib hooks, DMA driver, interactive `main.c`, xsdb `run.tcl`.
5. **QEMU:** ran the firmware in QEMU, which found the newlib-nano `sscanf("%hhX")` bug; fixed.
6. **Stopped before hardware:** Claude asked before programming the shared board; the user said not yet.

**Turns 4–5:** session report.

**Turns 6–17: hardware bring-up on the VC707**

| Turn | What happened |
|---|---|
| 6–10 | The board was in use by another user's debug session. Claude stopped and waited instead of disturbing it. Once the board was free, its programming attempt was **denied by the auto-mode permission check** ("Interfere With Workloads"). It stopped and offered two options: the user runs it, or adds a permission rule. |
| 11–12 | The user added an allow rule for `xsdb`. Claude's next command piped the output through `grep`/`tail`, so it no longer matched the rule, and it was **denied again**. Claude stopped retrying and gave the user the commands to run. |
| 13 | The user programmed the board; the UART was silent. Claude wrote the read-only `diag.tcl`. |
| 14 | xsdb listed only `BSCAN JTAG`. Claude checked MIG reset polarity and the debug-module settings (both fine) and started an LED status build as a fallback. |
| 15 | `diag.tcl` showed a healthy system: CPU halted at `0x0`, gemv `INFO` = `0x00200020`, DDR, DMA and UART responding. Claude started a UART logger. |
| 16 | Still silent. Claude wrote `diag2.tcl`, then found the JTAG model download was still in progress. |
| 17 | After about 20 minutes of JTAG load the firmware booted: a verified run (0 mismatches), a greedy speed run and a sampling run, all over the UART. |

**Turn 18:** README and report updated.

## Problems and Claude's own mistakes

| # | Issue | Cause | Fix |
|---|---|---|---|
| 1 | First testbench run hung | Valid pipeline not reset, so X values leaked into the FIFO count | Reset `tv` |
| 2 | Still X after that fix | **Claude's own edit** put a `//` mid-line and commented out `last2 <= last1` | Restored the line |
| 3 | `pkill` killed Claude's own shell (exit 144) | The pattern matched its own command line | Stopped using broad `pkill` |
| 4 | Debug output lost | `timeout` killed `vvp` before its output was flushed | Probe calls `$finish` itself |
| 5 | AXI smoke test hung | **Testbench bug:** checked the handshake after the clock edge | Sample ready before the edge |
| 6 | PASS/FAIL printed as a number | Ternary with strings in `$display` | `if`/`else` |
| 7 | Vivado failed to launch | `settings64.sh` points at a stale path | Call the Vivado binary directly |
| 8 | VC707 validate failed | Automatic address assignment packed segments, so moving them collided | Explicit per-slave placement |
| 9 | Name clash on `softmax` | The sampler code expects a global `softmax` | Shared one definition |
| 10 | Newline tokens dropped in the firmware | newlib-nano `sscanf` doesn't support `%hhX` | Manual hex parse |
| 11 | Couldn't program: "JTAG node is not accessible" | Another user's debug session held the cable | Waited until it ended |
| 12 | Second permission denial after the user added an allow rule | **Claude piped xsdb into `grep`/`tail`**, so the command no longer matched the rule | Stopped; the user ran the xsdb steps |
| 13 | Read the early `BSCAN JTAG` listing as a possible dead clock | xsdb lists targets before the debug module is identified | `diag.tcl` showed the system healthy; the LED build turned out to be unnecessary |
| 14 | Silent UART after the user ran `run.tcl` | The JTAG model download (~20 min) was still in progress | Waited for it with a watcher |
| 15 | Validate run deleted the built bitstream | `create_project -force` recreates the project directory | The verified bitstream had been copied out first |

Small inefficiencies:
- Loaded the Monitor tool, then waited with Bash loops instead.
- One file-system search timed out, and Claude designed around the question rather than waiting for it.
- The LED debug build (about 20 minutes of Vivado time) wasn't needed in the end.
