# Bootstrap New Machine — claude-local

Setting up claude-local from scratch on a new machine. Encodes the bootstrap process, decisions, and post-setup verification.

## What bootstrap does

```bash
cd ~/dev/claude-local && ./bootstrap.sh
```

This is a single command that goes from a fresh Linux user account to a working `claude-local` session. It's idempotent — re-running is safe and won't restart a healthy server.

### The 6 steps

1. **Dependencies** — git, curl, jq, python3, systemd, tar, zstd, node/npm (via nvm), claude CLI (via npm)
2. **Ollama** — user-local install into `~/.local/ollama` (~1.5GB download, ~2GB extra for ROCm bundle)
3. **Systemd service** — installs `ollama.service` with drop-ins for context/KV/slots/flash attention and GPU profile
4. **Model pull** — pulls the model (default: `qwen3-coder:30b`, ~18GB download)
5. **Harness setup** — symlinks, drop-ins, `~/.local/bin/ollama` wrapper; server restarted only if needed
6. **Smoke test** — one turn through launcher and proxy to verify the full stack works

## Required prerequisites

- **Linux with systemd user manager** — `systemctl --user show-environment` must work
  - If running from cron, container, or `env -i`, set `XDG_RUNTIME_DIR`:
    ```bash
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    ```
- **User linger enabled** (optional but recommended):
  ```bash
  loginctl enable-linger $USER
  ```
  Without this, systemd user services stop at logout and the server dies.

## GPU profile selection

```bash
./bootstrap.sh --gpu amd-vulkan    # AMD iGPU/APU via Vulkan/RADV (default)
./bootstrap.sh --gpu amd-rocm     # AMD discrete GPU via ROCm (needs ROCm bundle)
./bootstrap.sh --gpu nvidia       # NVIDIA via CUDA (bundled runner)
./bootstrap.sh --gpu cpu          # CPU only (very slow)
```

**This machine (Ryzen AI MAX+ 395, Strix Halo iGPU):** Use `amd-vulkan`. The Vulkan runner is faster than ROCm on this hardware at decode throughput. ROCm prefills faster but collapses at context depth.

## Backend selection

```bash
./bootstrap.sh --backend ollama        # default; simplest setup
./bootstrap.sh --backend llamaserver   # upstream llama.cpp; needs pre-built llama.cpp
```

**Ollama (default):** Simplest setup. One binary, one service, works out of the box. Benchmarked at 21.4s/task mean on this hardware with core tools.

**llama-server:** More features — HIP support, speculative decoding, prompt cache persistence across restarts. Requires a pre-built llama.cpp (`~/ai/llama.cpp`), which needs to be compiled from source (see README for build recipe).

## llama.cpp build recipe (for llamaserver backend)

If using `--backend llamaserver`, you need an upstream llama.cpp build:

```bash
git clone https://github.com/ggml-org/llama.cpp ~/ai/llama.cpp && cd ~/ai/llama.cpp

# ROCm build (for AMD GPUs, gfx1151 = Strix Halo)
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
  cmake -S . -B build-hip -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
cmake --build build-hip --config Release -j -t llama-server llama-bench

# Vulkan build (for AMD iGPU/APU)
cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan --config Release -j -t llama-server llama-bench
```

**Note:** `GGML_HIP_ROWMMA_FATTN` no longer exists upstream (removed July 2026). `-fa on` uses the native kernel. Ollama's bundled ROCm 7.2 runtime segfaults on Linux 7.0 kernel; the upstream build links the system ROCm 7.14 and works.

## Model selection

```bash
./bootstrap.sh --model qwen3-coder:30b    # default; proven benchmark results
./bootstrap.sh --model qwen3.6:35b        # Qwen3.6-35B-A3B-MTP (if GGUF is available)
```

The model is pulled from Ollama's registry. For llama-server, the GGUF is extracted from the Ollama manifest automatically.

## Draft model (speculative decoding)

```bash
./bootstrap.sh --draft default    # download Qwen3-0.6B-Q8_0 draft model (~639MB)
./bootstrap.sh --draft none       # no draft model (speculation disabled)
./bootstrap.sh --draft URL        # custom draft model URL
./bootstrap.sh --draft /path     # local draft model path
```

**On this iGPU:** Speculative decoding measured slower than no speculation. The separate draft model is kept for llama-server's MTP mode (which uses the embedded draft head). On a discrete GPU with higher decode latency, draft-simple may help.

## Port configuration

```bash
./bootstrap.sh --port 1234         # Ollama port (default)
./bootstrap.sh --llama-port 1244   # llama-server port (default)
```

The launcher and statusline read the port from `~/.claude-local/env`. If an existing systemd unit is found on a different port, it's adopted automatically (unless `--port` is explicitly given with a conflicting value).

## Full bootstrap command examples

**Default (AMD Vulkan iGPU, Ollama, qwen3-coder:30b):**
```bash
cd ~/dev/claude-local && ./bootstrap.sh
```

**With llama-server backend and draft model:**
```bash
cd ~/dev/claude-local && ./bootstrap.sh --backend llamaserver --draft default
```

**Dry run (shows what would happen without doing anything):**
```bash
./bootstrap.sh --dry-run
```

**Skip smoke test (faster, verify manually later):**
```bash
./bootstrap.sh --no-smoke
```

## Post-bootstrap verification

After bootstrap completes:

1. **Check the server is running:**
   ```bash
   systemctl --user status ollama.service    # or llama-server.service
   curl -sf http://localhost:$PORT/api/tags | jq '.models[].name'
   ```

2. **Run a smoke test through the launcher:**
   ```bash
   claude-local --no-smoke  # skip the interactive picker for automation
   ```

3. **Verify the statusline works:**
   The statusline should show in Claude Code's output — four lines with repo/git, server/model state, context gauge, and CPU/VRAM/RAM usage.

4. **Check model loading:**
   ```bash
   curl -sf http://localhost:$PORT/api/ps | jq '.models[].name'
   # Should show the model you just pulled
   ```

5. **Run the benchmark suite:**
   ```bash
   cd ~/dev/claude-local/bench && ./run.sh --label post-bootstrap --repeat 3 -- \
       --append-system-prompt-file ~/.claude-local/system_prompt.md \
       --exclude-dynamic-system-prompt-sections \
       --autocompact 120832 \
       --tools Bash,Read,Edit,Write,Grep,Glob
   ```
   Compare against shipped default (21.4s/task mean, 94% cache hit).

## Troubleshooting common bootstrap failures

| error | cause | fix |
|---|---|---|
| "no systemd user manager" | Running from cron, container, or `env -i` | Set `XDG_RUNTIME_DIR="/run/user/$(id -u)"` or run from a login shell |
| "npm global prefix not writable" | System Node.js installed, blocking user-local install | Remove system node from PATH: `export PATH="${PATH//$(npm config get prefix \/bin):}/"` then rerun |
| "server did not answer on port" | Port conflict or GPU OOM | Check `ss -tlnp` for conflicts; check `dmesg` for OOM kills |
| "no llama-server at build-hip/bin/llama-server" | llama.cpp not built yet | Build it first (see recipe above) |
| Model pull hangs | Network issues or registry timeout | Retry; the model is ~18GB and can take minutes on slow connections |

## What gets installed where

| path | role |
|---|---|
| `~/.local/ollama/` | Ollama binary + libraries (~3.5GB) |
| `~/.config/systemd/user/ollama.service` | Systemd user unit |
| `~/.config/systemd/user/ollama.service.d/10-claude-local.conf` | Context/KV/slots/flash attention drop-in |
| `~/.config/systemd/user/ollama.service.d/20-gpu-*.conf` | GPU profile drop-in (one active) |
| `~/.claude-local/env` | Persisted port + backend config |
| `~/.claude-local/models/` | GGUF models (llama-server mode) |
| `~/.claude-local/slots/` | Prompt cache slots (llama-server mode) |
| `~/.local/bin/claude-local` | Launcher script (symlink from repo) |
| `~/.local/bin/ollama` | Wrapper that targets the local port |

## After bootstrap: first session

```bash
claude-local
# → picks a model (or skips if CLAUDE_LOCAL_MODEL is set)
# → loads it into GPU memory
# → starts proxy on free port
# → launches Claude Code against the local backend
# → post-exit menu: unload / leave loaded / load another
```
