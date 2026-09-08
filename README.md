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
    make check-checkpoint   # kill an idle llama-server model instance, expect the proxy to resume it warm
    make check-idle         # load a throwaway preset, expect the proxy to checkpoint and unload it when idle
    make bench LABEL=x      # benchmark a configuration; make compare to read results
    make bench-shipped      # benchmark exactly what ships: default tool list, web search MCP, online

## Backends

Two servers can be installed side by side; `CLAUDE_LOCAL_BACKEND` picks one and
`~/.claude-local/env` maps it to its port (Ollama 1234, llama-server 1244).

| backend | server | why |
|---|---|---|
| `ollama` (default) | Ollama 0.33.3, Vulkan, user unit `ollama.service` | simplest; measured baseline below |
| `llamaserver` | upstream llama.cpp `llama-server` in router mode, user unit `llama-server.service` | every GGUF in the INI is selectable with its own settings, HIP (ROCm) or Vulkan from the same unit, speculative decoding (incl. MTP), on-disk prompt cache, dedicated Qwen tool-call parser |

    CLAUDE_LOCAL_BACKEND=llamaserver claude-local     # one session on llama-server
    make check-llama                                   # smoke turn against it
    ./bootstrap.sh --backend llamaserver               # install it (needs a llama.cpp build, see below)

Two files configure the unit. `~/.claude-local/llama-server.env` holds the device
(`LLAMA_DEVICE=ROCm0|Vulkan0`, which implies build-hip or build-vulkan) and the path of
`~/.claude-local/llama-models.ini`, the model presets: one section per GGUF, the section
name being the alias Claude sees, with that model's own sampling, `reasoning = on|off` and
speculation keys (llama-server long options without the dashes). The server runs in
llama.cpp's **router mode**: it starts without a model, `/models` lists every preset with
its load state, and the launcher loads the one you pick on demand (`/models/load`, then
polls the status). Up to two models stay resident (`LLAMA_ARG_MODELS_MAX=2`; two 27B-class models take
56GB of the 108GB pool and answer independently, leaving room for KV, the RAM prompt cache and the
desktop); beyond that, picking another saves the least recently used model's prompt cache and evicts it. Tuning that should not drift lives in
`systemd/llama-server/10-claude-local.conf` (128K context, q8_0 KV with flash attention, one
slot, Ollama-parity batch sizes, cache reuse) and is inherited by every model instance.

    llama-models-ini                                   # add every new GGUF under ~/.claude-local/models to the INI
    curl -s 'http://127.0.0.1:1244/models?reload=1'    # re-read the INI without a restart (editing a section)
    systemctl --user restart llama-server.service      # after changing the device or the drop-in

`/health` is 200 as soon as the router is up; a model's readiness is its status in `/models`
(the launcher waits on it and never restarts a loading server). "Unload" saves slot 0's prompt
cache to `~/.claude-local/slots/<alias>.bin` and frees the model's memory; the next load restores
the cache, so a fresh session starts warm even after a server restart. The pre-router layout
(`LLAMA_ARG_MODEL` + `LLAMA_ARG_ALIAS` in the env file, one model per server) still works.

### Models (llama-server presets, `config/llama-models.ini.example`)

| alias | file | what | per-model keys |
|---|---|---|---|
| `qwen3.6-35b` | Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL (22.9GB) | MoE, 3B active, MTP head embedded | `reasoning = off`, `spec-type = draft-mtp`, `spec-draft-n-max = 2` (the 2026-09-06 overnight winner) |
| `qwen3.8-27b` | Qwen3.8-27B-Q8_0 (29.0GB) | dense, thinking, MTP head embedded; reference quant | `reasoning = on`, `spec-type = draft-mtp`, `spec-draft-n-max = 4` |
| `qwen3.8-27b-q6kxl` | Qwen3.8-27B-UD-Q6_K_XL (25.3GB) | same model, Unsloth dynamic Q6 | same |
| `qwen3.8-27b-q6k` | Qwen3.8-27B-UD-Q6_K (22.0GB) | same model, smallest | same |

Qwen's recommended sampling (`temp 0.7, top-p 0.8, top-k 20, min-p 0, presence-penalty 1.5`)
sits in the INI's `[*]` section; `LLAMA_EXTRA_ARGS` is empty in router mode because CLI args
beat preset keys for every instance. Section names must not contain a colon: the preset parser
canonicalises whatever follows one as a quant tag (`qwen3.8:27b-q6k` would list as `qwen3.8:Q6K`).

Qwen3.8's chat template raises on a system message that is not first, and Claude Code sends the
Agent tool's type list as a mid-conversation `role: system` message; the usage proxy folds it
into the system prompt (`config/proxy.py`), which is why `CLAUDE_LOCAL_PROXY=0` breaks Qwen3.8
whenever Agent is in `--tools`.

### Switching models and searching the web

Three ways to change model: the menu at start (`CLAUDE_LOCAL_MODEL=<preset>` skips it), `/model <preset>`
inside the session (router mode loads an idle preset on the next request, up to `LLAMA_ARG_MODELS_MAX`
resident; the statusline follows Claude's choice and shows `(was <launch model>)`), or (a)nother in the
post-exit menu. Presets are the section names of `~/.claude-local/llama-models.ini`.

Claude Code's built-in `WebSearch` is executed by Anthropic's API, so against a local server every call
returns an empty result list (observed 2026-09-08). The launcher therefore leaves it out of `--tools` and
registers `config/mcp-websearch.py` via `--mcp-config` instead: a dependency-free stdio MCP server that
queries DuckDuckGo's HTML endpoint and shows up to the model as `mcp__websearch__web_search` (`--tools`
only limits the built-in set; MCP tools ride along). `WebFetch` is client-side and works as is.
`CLAUDE_LOCAL_WEBSEARCH=0` disables the server; `CLAUDE_LOCAL_OFFLINE=1` implies it.

### Checkpoints and resume (llama-server)

The usage proxy keeps the session warm across server trouble. Twenty seconds after a turn completes
with nothing in flight (`CLAUDE_LOCAL_CHECKPOINT`, 0 = off) it saves the model's prompt cache to
`~/.claude-local/slots/claude-local-<preset>.bin`, the file the launcher restores at load; measured
2026-09-08, a 10K-token context is 180 MB and 250 ms each way. Pending saves are flushed when the
session ends. Before every turn the proxy checks the preset: one that died (`kill -9`, OOM, a unit
restart) is loaded again and its checkpoint restored; one whose child port changed is restored too.
A crash therefore costs one failed turn and the retry starts warm instead of re-prefilling the
whole context. `make check-checkpoint` proves it by killing an idle instance.

One limit, measured 2026-09-08: every preset here is a hybrid model (`qwen35` / `qwen35moe`: SSM layers
with full attention every fourth block), whose recurrent state exists only at the last position, and
slot files carry no context checkpoints. A restored sequence can be extended, which is what the next
turn or a retry does, but not rewound: re-sending an identical or shorter prompt reprocesses everything.
The same applies to the launcher's restore at load.

The proxy also dehydrates what nobody is using. Every turn records its model in `run/last_use.json`,
shared by all sessions; a resident preset unused for 20 minutes (`CLAUDE_LOCAL_IDLE_UNLOAD`, 0 = off)
that is not the session's own model is checkpointed and unloaded, and comes back warm through the same
resume path when a session next needs it. `make check-idle` proves it with a throwaway preset. At start
the launcher also evicts whatever the *other* server holds (`CLAUDE_LOCAL_EXCLUSIVE`, default 1): Ollama
models via a zero keep-alive, llama-server presets after a checkpoint. Ollama and llama-server share
one memory pool, and two servers each holding a model is the realistic way to run it out.

A small model also invents URLs (five non-existent GitHub repos fetched in one session). The isolated
settings pre-allow `WebFetch` so browsing never prompts, and a PreToolUse hook (`config/hook-urlguard.py`)
denies any fetch whose URL, or a parent path of it, has not already appeared in a user message, a
search result or a tool output. The denial tells the model to search first. `CLAUDE_LOCAL_URLGUARD=0`
turns the guard off.

Measured 2026-09-07 (`bench/microbench.py`, cold prefill / decode at 2.7K, 10K and 30K prompt
tokens, n_out 128, medians of 2; `bench/results/micro/micro-q38-{rocm,vulkan}.jsonl`):

| preset / device | prefill tok/s 2.7K / 10K / 30K | decode tok/s 2.7K / 10K / 30K | cold TTFT 10K / 30K | warm turn TTFT 10K / 30K |
|---|---|---|---|---|
| `qwen3.6-35b` ROCm0 | 1079 / 1050 / 826 | 66.2 / 61.1 / 54.5 | 9s / 34s | 2.5s / 3.7s |
| `qwen3.6-35b` Vulkan0 (2026-09-06, `micro-q36.jsonl`) | 821 / 762 / 666 | 68.8 / 65.7 / 53.9 | 13s / 45s | 3.0s / 3.8s |
| `qwen3.8-27b` (Q8_0) ROCm0 | 334 / 318 / 248 | 7.7 / 7.6 / 7.2 | 30s / 113s | 8.4s / 11.5s |
| `qwen3.8-27b-q6kxl` ROCm0 | 306 / 313 / 266 | 8.6 / 8.3 / 7.8 | 30s / 105s | 8.1s / 11.5s |
| `qwen3.8-27b-q6k` ROCm0 | 291 / 299 / 258 | 9.4 / 9.4 / 8.6 | 32s / 108s | 8.5s / 11.8s |
| `qwen3.8-27b` (Q8_0) Vulkan0 | 181 / 196 / 188 | 7.3 / 7.5 / 7.2 | 49s / 150s | 13.1s / 14.8s |
| `qwen3.8-27b-q6kxl` Vulkan0 | 180 / 193 / 183 | 8.6 / 8.5 / 8.3 | 50s / 154s | 13.6s / 15.3s |
| `qwen3.8-27b-q6k` Vulkan0 | 182 / 195 / 184 | 9.8 / 9.7 / 9.4 | 49s / 152s | 13.4s / 15.2s |

What the numbers say:

- **Dense 27B is bandwidth-bound on this iGPU: 7-10 tok/s plain decode, 8x slower than the 3B-active
  MoE.** Q6_K buys 22% over Q8_0 for 7GB less; Q6_K_XL sits in between. The plain rows are the floor
  the presets no longer run at: see the speculation table below.
- **MTP speculation is the dense-model fix, and the presets ship with it.** Every unsloth Qwen3.8
  quant carries the MTP head (`blk.64.nextn.*`), and a dense bandwidth-bound decode is exactly the
  regime where verifying a draft costs about one token's worth of weight reads (the 2026-09-05 "spec
  loses" result was an MoE, where a batch activates more experts). The on-disk Qwen3-0.6B draft is
  unusable here: Qwen3.8 has a 248K-token vocabulary (Qwen3: 152K), so `draft-simple` cannot pair them.
- **ROCm0 is the device for both families now**: 1.6x the Vulkan prefill for Qwen3.8 at equal
  decode, 1.3x for Qwen3.6 at equal decode (the 2026-09-05 Vulkan preference was measured on
  Qwen3-Coder). `LLAMA_DEVICE=ROCm0` on this host.
- **Hybrid attention costs ~2K tokens of re-prefill per turn.** Both Qwen3.5-family files are
  gated-deltanet + attention; llama-server logs `cache_reuse is not supported by this context`
  and prompt reuse snaps to a context checkpoint, so every warm turn re-prefills 2048-2610
  tokens where Qwen3-Coder re-prefilled 7-567 (`micro-2026-09-05.jsonl`). That is ~2s per turn
  on Qwen3.6 and 6-8s on Qwen3.8. `LLAMA_ARG_CHECKPOINT_MIN_SPACING_NT=1024` with 128
  checkpoints changed nothing (`micro-q38-ckpt.jsonl`), so the defaults stay.
- Warm-turn TTFT above already includes that re-prefill: it is the realistic per-turn floor for a
  Claude Code session at that context depth, before any output tokens.

Speculation on the dense model, ROCm0, cold prompt, n_out 128, one rep (`micro-q38-spec.jsonl`;
acceptance from the server log on the synthetic code-rewrite output):

| preset (Q8_0 unless noted) | decode tok/s 2.7K / 10K | draft acceptance, mean accepted length |
|---|---|---|
| plain (from the table above) | 7.7 / 7.6 | - |
| `draft-mtp`, n-max 2 | 16.6 / 15.6 | 0.80, 2.6 |
| **`draft-mtp`, n-max 4** (shipped) | **19.2 / 17.8** | 0.61, 3.4 |
| `draft-mtp`, n-max 8 | 18.2 / 16.2 | 0.39, 4.0 |
| `ngram-mod` | 8.1 / 7.9 | 0.13 |
| UD-Q6_K + `draft-mtp` n-max 4 | 25.1 / 18.2 | 0.60, 3.3 |
| UD-Q6_K_XL + `draft-mtp` n-max 4 | 20.4 / 16.7 | 0.54, 3.1 |

At 10K prompt depth every quant lands at 17-18 tok/s: the hybrid-attention decode cost, not the
weight bytes, sets the speed there, so Q8_0 is the default and the Q6 files only pay off at shallow
context. A real launcher turn on `qwen3.8-27b` (MTP) logged 13.9 tok/s on an 84-token reply where
per-turn overhead dominates. Reasoning effort (`reasoning-effort = low|medium|xhigh`, a Qwen3.8
template feature) was sampled once per level on one coding prompt: xhigh 1887 output tokens in 103s,
medium 1415 in 67s, low 2043 in 90s; with temperature 0.7 one sample says nothing, so the knob is
documented, not set. The proper test is the task bench with `reasoning = off`, `reasoning-budget`
and each effort level.

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

Memory when everything is resident: Ollama ~26GB + one llama-server model (22-29GB, see the table) of the 108GB GPU pool.

## What is here

| path | role |
|---|---|
| `bin/claude-local` | launcher: server check, model picker, load, autocompact fit, prompt render, usage proxy, Claude launch, post-exit menu |
| `config/backend-ollama.sh` | backend adapter (the function contract is documented in the file) |
| `config/proxy.py` | streaming reverse proxy that logs per-turn usage (cache hit, tok/s, latency); optional sampling override; folds Claude Code's mid-conversation `role: system` message (Agent tool type list) into the system prompt, which Qwen3.8's chat template otherwise rejects with HTTP 500 |
| `config/statusline.sh` | four-line cockpit fed by the proxy log; per-session state; the model shown is the one Claude is using (follows `/model`) with its load state on the server |
| `config/mcp-websearch.py` | stdio MCP server: `web_search` over DuckDuckGo HTML, replacing the built-in WebSearch that cannot run against a local server |
| `config/hook-urlguard.py` | PreToolUse hook: denies WebFetch on a URL the conversation has never shown the model |
| `config/settings.json` | the isolated Claude Code settings: statusline, hook, pre-allowed WebFetch and web search, and an `env` block that keeps a bare `claude` run with this config dir on the local llama-server port instead of Anthropic's API |
| `config/picker.py` | model menu, or non-interactive via `CLAUDE_LOCAL_MODEL` |
| `config/system_prompt.md` | operator prompt appended to Claude's built-in prompt (`{{MODEL}}` templated) |
| `config/system_prompt_compact.md` | replacement prompt for `CLAUDE_LOCAL_PROMPT=replace`; faster, less careful |
| `bootstrap.sh` | single entry point for a fresh machine (see top). `--gpu amd-vulkan\|amd-rocm\|nvidia\|cpu` picks a profile; an existing user unit is adopted (its port and binary), never overwritten |
| `systemd/ollama.service` | generic unit template (no GPU or tuning env; those are drop-ins) |
| `systemd/10-claude-local.conf` | drop-in: flash attention, 128K context, q8_0 KV, one slot, 2h keep-alive. Flash attention lives here because q8_0 KV silently falls back to f16 without it |
| `systemd/20-gpu-*.conf` | GPU profile drop-ins; bootstrap installs the chosen one as `20-gpu.conf` |
| `systemd/llama-server/` | llama-server unit template and drop-in (incl. `LLAMA_ARG_MODELS_MAX=2`); `config/llama-server.env.example` (device, INI path) and `config/llama-models.ini.example` (one preset per model) are its per-machine config; `bin/llama-server-run` is the ExecStart wrapper (device -> build dir, router vs single-model mode); `bin/llama-models-ini` appends presets for new GGUFs and reloads the router |
| `config/backend-llamaserver.sh` | llama-server adapter: router inventory with load state, load/unload via `/models/*` with status polling, per-model props, slot save/restore (single-model mode still supported) |
| `bench/` | 9 fixed tasks (09 is a ~630-line module whose first Read is a 6K-token turn), runner, comparison, `microbench.py` (cold prefill / decode / warm-prefix for both APIs); results in `bench/results` |
| `skills/` | operator skills (configure/diagnose backend, manage models, tune, bench, bootstrap); linked into `~/.claude-local/skills` but only loaded when `Skill` is added to `CLAUDE_LOCAL_TOOLS`, which the 2026-09-05 measurements found to be a turn sink |
| `test/` | smoke turn, pty-driven interactive session, checkpoint/resume test |

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
  the proxy URL is passed via `--settings` for that reason. The `env` block pins the llama-server port
  (1244), so `CLAUDE_CONFIG_DIR=~/.claude-local claude` without the launcher talks to that server or
  fails with a connection error; it never reaches Anthropic's API. Ollama users go through the launcher.
- Same-mode `--resume` is warm (21 uncached tokens). Changing prompt mode on resume re-sends the prompt once.
- Isolation: `CLAUDE_LOCAL_OFFLINE=1` points HTTPS_PROXY at a dead port with localhost bypassed.
  Project-level CLAUDE.md files still load, by design. Default 0 since 2026-09-07 (WebFetch and the
  web search MCP server need the internet); the 2026-09-05 measurements were taken offline.

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

Stack identity for every 2026-09-05 row (`bench/stack.sh`): kernel 7.0.0-31, firmware pfp/mec/mes 0x31/0x22/0x86, Mesa 25.2.8 (RADV), glslc 2023.8, llama.cpp 6a1a922d2, Ollama 0.33.3, ROCm 7.14. The upstream Vulkan build used Ubuntu's glslc 2023.8 (20 q8_1 shader variants vs 513 in Ollama's bundle). A rebuild with LunarG glslc 2026.3 (892 variants, label `intdot-vk`, `bench/results/micro/micro-intdot.jsonl`) measured within noise of it at every size for this Q4_K_M model (prefill 1246/998/571/225 vs 1213/952/561/226 tok/s at 2.7K/10K/30K/100K; decode 74/64/46/21 vs 77/63/43/22), so the rows above stand. No GPU resets occurred during these runs (the previous boot had 9, all on Sep 3-4 under Ollama's Vulkan runner at 60-87K tokens in flight; kernel 7.0's 2s GPU job timeout is the suspected cause).

- **Upstream Vulkan beats Ollama's Vulkan everywhere**: +10% to +64% prefill, equal-or-better decode, and 22.5 vs 8.2 tok/s decode at 100K context. Newer kernels, same backend.
- **HIP prefills fastest but decodes slowest**, and its decode collapses with context (7.6 tok/s at 100K). Claude turns are decode-dominated, so Vulkan wins the per-turn cost at every depth; HIP is the choice only for prefill-bound work. Both backends lose ~90% of prefill throughput between depth 0 and 100K in llama-bench, so that cliff is the hardware's attention cost, not a HIP regression.
- **q8_0 KV cache is faster than f16 here** (30K: 2x prefill, +33% decode): attention is bandwidth-bound and the smaller cache wins. Keep q8_0.
- **Speculative decoding loses on this iGPU** despite 55% draft acceptance (2.6 tokens per verify step): the batched verify costs more than the tokens it saves. Draft n_max 8/16 and both ngram modes are worse still. Off by default; the env file documents how to re-try on other hardware.
- Ollama's bundled ROCm 7.2 segfaults on this Linux 7.0 kernel; the upstream HIP build links the system ROCm 7.14 and runs.

## Full-bench decision, 2026-09-05 evening (9 tasks x 3 reps, through the proxy, GPU 62-95C throttled, back to back)

| label | tools | pass | mean | median | turns/task | prompt tok/task |
|---|---|---|---|---|---|---|
| Ollama Vulkan, full tool list minus Agent | all minus Agent | 27/27 | 49.0s | 42.4s | 9.3 | 148K |
| upstream Vulkan, same | all minus Agent | 27/27 | 65.6s | 55.2s | 12.0 | 217K |
| upstream HIP, same | all minus Agent | 27/27 | 154.3s | 75.6s | 12.8 | 230K |
| Ollama Vulkan, 9 meta-tools denylisted | minus 9 | 27/27 | 26.1s | 23.8s | 7.9 | 98K |
| upstream Vulkan, same | minus 9 | 26/27 | 187.7s | 107.9s | 15.2 | 347K |
| **Ollama Vulkan, core allowlist (benchmark default; shipped default until 2026-09-07)** | Bash,Read,Edit,Write,Grep,Glob | 27/27 | **21.4s** | 20.8s | 8.5 | 50K |
| upstream Vulkan, core allowlist | same | 27/27 | 39.5s | 36.4s | 13.9 | 99K |
| upstream Vulkan rebuilt with LunarG glslc, core allowlist | same | 27/27 | 40.3s | 33.4s | 14.4 | 102K |

- **The tool surface is the second biggest lever after the cache flag.** With the full tool list the model spends ~30% of its turns on meta-tools (ReportFindings, TaskList/Create/Update, Skill, subagents); denylisting some just routes it to the next sink (74 Skill calls through llama-server, 3x task time). `--tools Bash,Read,Edit,Write,Grep,Glob` removes the sinks and shrinks the system prompt from ~15K to ~4.3K tokens. Ollama went 49s -> 21.4s on the same evening; the morning baseline on a cool GPU was 31s.
- **Default backend stays Ollama.** With identical tools, sampling and GGUF, the model takes 64% more turns and emits 2x the output tokens through llama-server's chat template, so task time is 1.8x worse even though the engine is equal or faster per turn (decode 69 vs 69 tok/s; large-prefill TTFT 9.1s vs 12.9s). Gate 2 fails; gates 1, 3, 4 and 5 pass (27/27, zero flakes in 108 llama-server runs, interactive 9/9, warm resume and slot restore verified).
- llama-server stays installed and verified as the alternative (`CLAUDE_LOCAL_BACKEND=llamaserver claude-local`): it wins at long context (22.5 vs 8.2 tok/s decode at 100K), persists the prompt cache across restarts (12.4K tokens saved in 123ms / restored in 42ms; next turn 2.9s TTFT vs 13.8s cold), and parses Qwen3-Coder tool calls natively. HIP is prefill-fast but collapses at depth (154s mean here); use it only for prefill-bound work.
- Stack for every row: kernel 7.0.0-31, fw pfp/mec/mes 31/22/86, Mesa 25.2.8 (RADV), glslc 2023.8, llama.cpp 6a1a922d2, Ollama 0.33.3, ROCm 7.14 (`bench/stack.sh`; recorded per row from now on). Raw rows: `bench/results/fb-*.jsonl`, per-turn proxy logs `bench/results/proxy/`, metrics snapshots alongside.

## Known unknowns

- **Why the model behaves differently through llama-server's template** (same GGUF, sampling, tools: +64% turns, 2x output). Suspects: the GGUF's jinja template (tool rendering, system placement) vs Ollama's chatml template, and tool-call parsing leniency. Experiment: `--chat-template-file` with a template rendering like Ollama's, then `bench/run.sh --label ls-vk-tmpl --port 1244 ... --tools Bash,Read,Edit,Write,Grep,Glob` vs `fb-ollama-vk-core`. If turns equalise, llama-server should win outright on its per-turn numbers.
- Resolved: the LunarG-glslc rebuild of the Vulkan backend (892 q8_1 variants) performs the same as the 2023.8 build for this Q4_K_M model; the shader-extension gap was not holding it back.
- Kernel 7.0's 2s GPU job timeout vs ggml-vulkan's 100-node submits: ring timeouts on Sep 3-4 under Ollama's Vulkan runner at 60-87K tokens; none during today's runs. `GGML_VK_MAX_NODES_PER_SUBMIT` test pending.
- 2 of 81 morning runs (full tool list, Ollama) had the model emit a malformed native XML tool call as text on turn 1; zero in the 216 evening runs.
  Claude sends no temperature/top_p, so sampling can be pinned either in a Modelfile or with
  `CLAUDE_LOCAL_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'`. Unmeasured. To measure:
  start `config/proxy.py` with `PROXY_SAMPLING` set and run `bench/run.sh --label sampling --port 1235 --repeat 3 -- ...`.
- `backend-llamaserver.sh` needs a real llama-server run. It exists to keep the on-disk prompt-cache path open.
- Ollama truncates prompts from the front when they exceed the context; the headroom math above is the guard,
  but a session long enough to hit autocompact has not been observed end to end.
