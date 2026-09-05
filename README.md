# claude-local

Run Claude Code against a local model server (Ollama) from a fully isolated
config directory, with the harness fitted to a small model and every knob
backed by a benchmark number.

    git clone <this repo> ~/dev/claude-local && ~/dev/claude-local/bootstrap.sh
                            # fresh machine -> working claude-local: deps, user-local Ollama,
                            # systemd user service, model pull, symlinks, server drop-in, smoke turn.
                            # Idempotent (no server restart unless the drop-in env changed); --dry-run shows the plan; no sudo.
                            # The port is persisted in ~/.claude-local/env; `ollama` on PATH is a wrapper that targets it.
    make install            # symlinks only (already-bootstrapped machine)
    claude-local            # pick a model, go
    make check              # lint + one smoke turn through launcher and proxy
    make check-interactive  # pty-driven full session (picker, statusline, Ctrl-C, exit menu)
    make bench LABEL=x      # benchmark a configuration; make compare to read results

## Backends

Two servers can be installed side by side; `CLAUDE_LOCAL_BACKEND` picks one and
`~/.claude-local/env` maps it to its port (Ollama 1234, llama-server 1244).

| backend | server | why |
|---|---|---|
| `ollama` (default) | Ollama 0.33.3, Vulkan, user unit `ollama.service` | simplest; measured baseline below |
| `llamaserver` | upstream llama.cpp `llama-server`, user unit `llama-server.service` | HIP (ROCm) or Vulkan from the same unit, speculative decoding, on-disk prompt cache, dedicated Qwen3-Coder tool-call parser |

    CLAUDE_LOCAL_BACKEND=llamaserver claude-local     # one session on llama-server
    make check-llama                                   # smoke turn against it
    ./bootstrap.sh --backend llamaserver               # install it (needs a llama.cpp build, see below)

`~/.claude-local/llama-server.env` is the whole configuration of that unit: `LLAMA_DEVICE=ROCm0|Vulkan0`
(which implies build-hip or build-vulkan), the model GGUF (Ollama's blob is reused, no second copy),
the alias Claude sees, and the speculative settings (`LLAMA_ARG_SPEC_TYPE=draft-simple` with the
Qwen3-0.6B draft, `ngram-mod`/`ngram-cache` for draft-free, or commented out). Tuning that should not
drift lives in `systemd/llama-server/10-claude-local.conf` (128K context, q8_0 KV with flash attention,
one slot, Ollama-parity batch sizes, cache reuse). Switch device or speculation: edit one line, then
`systemctl --user restart llama-server.service`. `/health` answers 503 for the whole load, so every
claude-local path waits for it and never restarts a loading server.

"Unload" on this backend saves slot 0's prompt cache to `~/.claude-local/slots/` and leaves the server
up; the next launch restores it, so a fresh session starts warm even after a server restart
(`CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD=1` also stops the unit to free ~26GB).

### llama.cpp build recipe (ROCm 7.14 TheRock at /opt/rocm, gfx1151)

    git clone https://github.com/ggml-org/llama.cpp ~/ai/llama.cpp && cd ~/ai/llama.cpp
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
      cmake -S . -B build-hip -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
    cmake --build build-hip --config Release -j -t llama-server llama-bench
    cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build build-vulkan --config Release -j -t llama-server llama-bench

`GGML_HIP_ROCWMMA_FATTN` no longer exists upstream (removed July 2026); `-fa on` uses the native
kernel. Ollama's own bundled ROCm 7.2 runtime segfaults on this kernel (7.0); the upstream build links
the system ROCm and works.

Memory when everything is resident: Ollama ~26GB + llama-server ~26GB + draft ~8GB of the 108GB GPU pool.

## What is here

| path | role |
|---|---|
| `bin/claude-local` | launcher: server check, model picker, load, autocompact fit, prompt render, usage proxy, Claude launch, post-exit menu |
| `config/backend-ollama.sh` | backend adapter (the function contract is documented in the file) |
| `config/proxy.py` | streaming reverse proxy that logs per-turn usage (cache hit, tok/s, latency); optional sampling override |
| `config/statusline.sh` | four-line cockpit fed by the proxy log; per-session state |
| `config/picker.py` | model menu, or non-interactive via `CLAUDE_LOCAL_MODEL` |
| `config/system_prompt.md` | operator prompt appended to Claude's built-in prompt (`{{MODEL}}` templated) |
| `config/system_prompt_compact.md` | replacement prompt for `CLAUDE_LOCAL_PROMPT=replace`; faster, less careful |
| `bootstrap.sh` | single entry point for a fresh machine (see top). `--gpu amd-vulkan\|amd-rocm\|nvidia\|cpu` picks a profile; an existing user unit is adopted (its port and binary), never overwritten |
| `systemd/ollama.service` | generic unit template (no GPU or tuning env; those are drop-ins) |
| `systemd/10-claude-local.conf` | drop-in: flash attention, 128K context, q8_0 KV, one slot, 2h keep-alive. Flash attention lives here because q8_0 KV silently falls back to f16 without it |
| `systemd/20-gpu-*.conf` | GPU profile drop-ins; bootstrap installs the chosen one as `20-gpu.conf` |
| `systemd/llama-server/` | llama-server unit template and drop-in; `config/llama-server.env.example` is its per-machine config; `bin/llama-server-run` is the ExecStart wrapper (device -> build dir) |
| `config/backend-llamaserver.sh` | llama-server adapter: health with 503-while-loading semantics, models/props, slot save/restore |
| `bench/` | 9 fixed tasks (09 is a ~630-line module whose first Read is a 6K-token turn), runner, comparison, `microbench.py` (cold prefill / decode / warm-prefix for both APIs); results in `bench/results` |
| `test/` | smoke turn and pty-driven interactive session |

All env overrides are listed at the top of `bin/claude-local`.

## Measured claims (2026-09-05, qwen3-coder:30b Q4_K_M, Ryzen AI MAX+ 395, Vulkan iGPU)

| configuration | runs | pass | mean wall/task | cache hit |
|---|---|---|---|---|
| original launcher, 262K ctx, f16 KV | 8 | 100% | 89.8s | 92% |
| + `--exclude-dynamic-system-prompt-sections` | 8 | 100% | 41.9s | 98% |
| + server fit (128K ctx, q8_0 KV, 1 slot) = shipped default | 24 | 96% | 31.2s | 98% |
| control: server fit without the flag | 16 | 100% | 69.0s | 90% |
| compact replacement prompt | 24 | 88% | 22.0s | 99% |
| Q8 weights | 8 | 88% | 35.9s | 98% |

- `--exclude-dynamic-system-prompt-sections` is the single biggest win: git status leaves the
  system prompt, so editing files no longer re-renders it and busts the server's prefix cache
  (uncached tokens per turn 1622 -> 267). Isolated by running each flag alone.
- `--system-prompt-snapshot on` is a no-op in Claude Code 2.1.261 (prompt recording not enabled). Passed anyway.
- Server fit cut model memory 45.6GB -> 26.1GB and mean time 42s -> 31s at equal pass rate.
- Q8 decodes slower on this iGPU (bandwidth-bound on weight size) and showed no accuracy gain. Not default.
- Compact prompt is 30% faster and skips edge-case verification. Opt-in only.
- Claude assumes a 200K window for unknown models; the launcher sets autocompact to
  server context - max output (8192) - 2048 so prompt + generation always fit, and the statusline gauge uses that.
- settings.json `env` overrides the process environment, and `--settings` overrides settings.json;
  the proxy URL is passed via `--settings` for that reason.
- Same-mode `--resume` is warm (21 uncached tokens). Changing prompt mode on resume re-sends the prompt once.
- Isolation: `CLAUDE_LOCAL_OFFLINE=1` (default) points HTTPS_PROXY at a dead port with localhost bypassed.
  Project-level CLAUDE.md files still load, by design.

## Backend measurements (2026-09-05, upstream llama.cpp 6a1a922d2 vs Ollama 0.33.3, same GGUF, q8_0 KV, flash attention, -b/-ub 2048)

Microbench (`bench/microbench.py`, cold prompt, temperature 0, medians of 3; raw rows in `bench/results/micro/`):

| config | 2.7K prefill / decode | 10K prefill / decode | 30K prefill / decode | 100K prefill / decode | warm turn wall 10K / 30K |
|---|---|---|---|---|---|
| Ollama Vulkan (was default) | 1106 / 72.9 | 768 / 59.7 | 402 / 41.9 | 138 / 8.2 | 2.3s / 3.4s |
| upstream Vulkan | 1213 / 77.3 | 952 / 62.5 | 561 / 43.1 | 226 / 22.5 | 2.2s / 3.1s |
| upstream HIP (ROCm 7.14) | 1525 / 56.9 | 1289 / 41.3 | 762 / 22.6 | 302 / 7.6 | 3.2s / 7.0s |
| upstream Vulkan, f16 KV | 1217 / 77.1 | 719 / 57.9 | 281 / 32.4 | - | 2.3s / 5.1s |
| upstream Vulkan + draft speculation (n_max 3) | 747 / 24.7 | 699 / 26.5 | - | - | 7.1s / 14.2s |
| upstream Vulkan + ngram-cache | 1216 / 40.8 | 954 / 26.0 | - | - | 3.7s / 7.3s |

(prefill and decode in tok/s; "warm turn" = cached prefix plus a few new tokens and 128 output tokens, the shape of a Claude Code turn)

- **Upstream Vulkan beats Ollama's Vulkan everywhere**: +10% to +64% prefill, equal-or-better decode, and 22.5 vs 8.2 tok/s decode at 100K context. Newer kernels, same backend.
- **HIP prefills fastest but decodes slowest**, and its decode collapses with context (7.6 tok/s at 100K). Claude turns are decode-dominated, so Vulkan wins the per-turn cost at every depth; HIP is the choice only for prefill-bound work. Both backends lose ~90% of prefill throughput between depth 0 and 100K in llama-bench, so that cliff is the hardware's attention cost, not a HIP regression.
- **q8_0 KV cache is faster than f16 here** (30K: 2x prefill, +33% decode): attention is bandwidth-bound and the smaller cache wins. Keep q8_0.
- **Speculative decoding loses on this iGPU** despite 55% draft acceptance (2.6 tokens per verify step): the batched verify costs more than the tokens it saves. Draft n_max 8/16 and both ngram modes are worse still. Off by default; the env file documents how to re-try on other hardware.
- Ollama's bundled ROCm 7.2 segfaults on this Linux 7.0 kernel; the upstream HIP build links the system ROCm 7.14 and runs.

## Known unknowns

- 2 of 81 benchmark runs had the model emit a malformed native XML tool call as text on turn 1.
  Claude sends no temperature/top_p, so sampling can be pinned either in a Modelfile or with
  `CLAUDE_LOCAL_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'`. Unmeasured. To measure:
  start `config/proxy.py` with `PROXY_SAMPLING` set and run `bench/run.sh --label sampling --port 1235 --repeat 3 -- ...`.
- `backend-llamaserver.sh` needs a real llama-server run. It exists to keep the on-disk prompt-cache path open.
- Ollama truncates prompts from the front when they exceed the context; the headroom math above is the guard,
  but a session long enough to hit autocompact has not been observed end to end.
