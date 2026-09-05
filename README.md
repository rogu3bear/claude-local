# claude-local

Run Claude Code against a local model server (Ollama) from a fully isolated
config directory, with the harness fitted to a small model and every knob
backed by a benchmark number.

    git clone <this repo> ~/dev/claude-local && ~/dev/claude-local/bootstrap.sh
                            # fresh machine -> working claude-local: deps, user-local Ollama,
                            # systemd user service, model pull, symlinks, server drop-in, smoke turn.
                            # Idempotent; --dry-run shows the plan; no sudo.
    make install            # symlinks only (already-bootstrapped machine)
    claude-local            # pick a model, go
    make check              # lint + one smoke turn through launcher and proxy
    make check-interactive  # pty-driven full session (picker, statusline, Ctrl-C, exit menu)
    make bench LABEL=x      # benchmark a configuration; make compare to read results

## What is here

| path | role |
|---|---|
| `bin/claude-local` | launcher: server check, model picker, load, autocompact fit, prompt render, usage proxy, Claude launch, post-exit menu |
| `config/backend-ollama.sh` | backend adapter (the function contract is documented in the file) |
| `config/backend-llamaserver.sh` | llama.cpp adapter with slot save/restore. **Untested**: no binary on this machine |
| `config/proxy.py` | streaming reverse proxy that logs per-turn usage (cache hit, tok/s, latency); optional sampling override |
| `config/statusline.sh` | four-line cockpit fed by the proxy log; per-session state |
| `config/picker.py` | model menu, or non-interactive via `CLAUDE_LOCAL_MODEL` |
| `config/system_prompt.md` | operator prompt appended to Claude's built-in prompt (`{{MODEL}}` templated) |
| `config/system_prompt_compact.md` | replacement prompt for `CLAUDE_LOCAL_PROMPT=replace`; faster, less careful |
| `bootstrap.sh` | single entry point for a fresh machine (see top); `systemd/ollama.service` is the unit template it installs (AMD Vulkan profile) |
| `systemd/10-claude-local.conf` | Ollama drop-in: 128K context, q8_0 KV, one slot, 2h keep-alive |
| `bench/` | 8 fixed tasks, runner, comparison; results from 2026-09-05 in `bench/results` |
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

## Known unknowns

- 2 of 81 benchmark runs had the model emit a malformed native XML tool call as text on turn 1.
  Claude sends no temperature/top_p, so sampling can be pinned either in a Modelfile or with
  `CLAUDE_LOCAL_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'`. Unmeasured. To measure:
  start `config/proxy.py` with `PROXY_SAMPLING` set and run `bench/run.sh --label sampling --port 1235 --repeat 3 -- ...`.
- `backend-llamaserver.sh` needs a real llama-server run. It exists to keep the on-disk prompt-cache path open.
- Ollama truncates prompts from the front when they exceed the context; the headroom math above is the guard,
  but a session long enough to hit autocompact has not been observed end to end.
