# Bootstrap New Machine — claude-local

Setting up claude-local from scratch on a new machine. Encodes the bootstrap process, decisions, and post-setup verification.

## What bootstrap does

```bash
cd ~/dev/claude-local && ./bootstrap.sh
```

This is a single command that goes from a fresh Linux user account to a working `claude-local` session. It's idempotent: re-running is safe and won't restart a healthy server. `--dry-run` walks the same steps, prints `would ...` for every action and downloads or changes nothing.

### The 6 steps

1. **Dependencies**: git, curl, jq, python3, systemd, tar, zstd, node/npm (via nvm), claude CLI (via npm)
2. **Ollama**: user-local install into `~/.local/ollama` (~1.5GB download, ~2GB extra for ROCm bundle)
3. **Systemd service**: installs `ollama.service` with drop-ins for context/KV/slots/flash attention and GPU profile; writes `~/.claude-local/env` (ports, default backend)
4. **Model**: pulls the Ollama model (default: `qwen3-coder:30b`, ~18GB download). With `--backend llamaserver` and `--hf` or `--model-gguf` the GGUF is downloaded (resumable, `GGUF` magic and `--sha256` checked, ~23GB for the recommended file) or adopted instead, the Ollama pull is skipped and the Ollama manifest is left alone; Ollama stays installed as the fallback backend
   - **4b. llama-server** (`--backend llamaserver` only): picks the device (`--device auto`: ROCm0 if `build-hip` lists it, else Vulkan0), writes `~/.claude-local/llama-server.env` and `llama-models.ini` (adopted if present; a preset section is appended for a GGUF the INI lacks), installs and starts `llama-server.service` on port 1244
5. **Harness setup**: symlinks, drop-ins, `~/.local/bin/ollama` wrapper; server restarted only if needed
6. **Smoke test**: one turn through launcher and proxy to verify the full stack works

### Recommended on this machine (Strix Halo, gfx1151)

llama-server with the uncensored Genesis build of Qwen3.6-35B-A3B (jan1k, abliterated; NVFP4 with the MTP head) is the preset this host runs; the filtered unsloth original won the 2026-09-06 overnight bench (27/27 tasks, 12.3 s/task mean, against 21.4 s for Ollama with qwen3-coder:30b on the same core tool allowlist). Needs the llama.cpp build below.

```bash
cd ~/dev/claude-local && ./bootstrap.sh --backend llamaserver \
  --hf jan1k/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-NVFP4-GGUF/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-MTP-NVFP4.gguf \
  --sha256 af80d3ef030268c46d56f6d7d2722de67fe81592708bac6c8fa381461adfbaad
```

URL, size (22170261312 bytes) and sha256 verified against huggingface.co on 2026-09-09; the file keeps its remote name, which the `[qwen3.6-35b-genesis]` preset in `config/llama-models.ini.example` (reasoning off, `draft-mtp` n-max 2) expects. For the filtered original use `--hf unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf --sha256 55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1 --model-gguf ~/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf`: the `[qwen3.6-35b]` preset expects the `-MTP` name, and unsloth's non-MTP repo ships a different file under the same name (22360456160 bytes). The device resolves to ROCm0 here (auto-detected; `--device Vulkan0` overrides).

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

**This machine (Ryzen AI MAX+ 395, Strix Halo iGPU):** Use `amd-vulkan`. Ollama's Vulkan runner is faster than its ROCm runner on this hardware at decode throughput (and the bundled ROCm runtime segfaults on the 7.0 kernel). ROCm prefills faster but collapses at context depth.

`--gpu` only picks Ollama's runner drop-in. llama-server chooses its own device:

```bash
./bootstrap.sh --backend llamaserver                    # --device auto (default): ROCm0 if build-hip lists it, else Vulkan0
./bootstrap.sh --backend llamaserver --device Vulkan0   # explicit; always wins over auto
```

`auto` resolves to ROCm0 on this host: the HIP build prefills Qwen3.6-35B 1.3x and Qwen3.8-27B 1.6x faster than Vulkan at equal decode (2026-09-07). Bootstrap prints the choice and the reason; an existing `~/.claude-local/llama-server.env` is adopted and its `LLAMA_DEVICE` is what the unit runs.

## Backend selection

```bash
./bootstrap.sh --backend ollama        # default; simplest setup
./bootstrap.sh --backend llamaserver   # upstream llama.cpp; needs pre-built llama.cpp
```

**Ollama (default):** Simplest setup. One binary, one service, works out of the box. Benchmarked at 21.4s/task mean on this hardware with core tools. Note: `config/settings.json` pins `ANTHROPIC_BASE_URL` to the llama-server port (1244), so a bare `claude` with this config dir fails to connect by design (it never reaches Anthropic's API); `claude-local` sets the Ollama port itself. Bootstrap prints this warning after writing `~/.claude-local/env`.

**llama-server:** More features: HIP support, speculative decoding (incl. the MTP head), prompt cache persistence across restarts, router mode with one preset per GGUF. With the Qwen3.6-35B-A3B MTP quant it is the fastest measured setup on this machine (12.3 s/task, see above). Requires a pre-built llama.cpp (`~/ai/llama.cpp`), which needs to be compiled from source (see the recipe below).

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

**Note:** `GGML_HIP_ROCWMMA_FATTN` no longer exists upstream (removed July 2026). `-fa on` uses the native kernel. Ollama's bundled ROCm 7.2 runtime segfaults on Linux 7.0 kernel; the upstream build links the system ROCm 7.14 and works.

## Model selection

```bash
./bootstrap.sh --model qwen3-coder:30b                                        # default; Ollama pull
./bootstrap.sh --backend llamaserver --hf OWNER/REPO/FILE.gguf [--sha256 HEX]  # download a GGUF into ~/.claude-local/models
./bootstrap.sh --backend llamaserver --hf https://huggingface.co/OWNER/REPO/resolve/main/FILE.gguf
./bootstrap.sh --backend llamaserver --model-gguf PATH                        # serve a GGUF already on disk (with --hf: save the download there)
```

With Ollama the model is pulled from Ollama's registry. With llama-server the GGUF comes from `--hf`, from `--model-gguf`, or, when neither is given, from the Ollama manifest of the pulled model (the Ollama blob of qwen3.6 is a plain Q4_K_M without the MTP head, so it is not the benchmark winner).

`--hf` accepts a full `resolve/main` URL or `OWNER/REPO/FILE.gguf` (turned into that URL). The download is `curl -fL -C - --progress-bar` into `FILE.gguf.part`; the file is renamed only after its size matches the server's content-length, its first four bytes read `GGUF` and the `--sha256` (when given) matches. Rerun to resume after a network drop; the download is skipped when the file is already there with the right size and hash. Single-file GGUFs only (split `-00001-of-0000N` files are not joined). `--sha256` also verifies a `--model-gguf` file. `--dry-run` prints `would download URL (N GB) to PATH` and never downloads.

Without `--model`, the name becomes the INI alias of the GGUF: the section of `~/.claude-local/llama-models.ini` whose `model =` names the file (`qwen3.6-35b` for the recommended file, with its tuned keys), or a new bare section named after the lower-cased file stem (the `llama-models-ini` rule). Bootstrap prints it on its last line; it is the `CLAUDE_LOCAL_MODEL` the launcher and the smoke test use. `--model NAME` overrides the alias.

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

**Recommended here (llama-server, the uncensored Genesis build of Qwen3.6-35B-A3B, device auto-detected):**
```bash
cd ~/dev/claude-local && ./bootstrap.sh --backend llamaserver \
  --hf jan1k/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-NVFP4-GGUF/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-MTP-NVFP4.gguf \
  --sha256 af80d3ef030268c46d56f6d7d2722de67fe81592708bac6c8fa381461adfbaad
```

**With llama-server backend, GGUF from the Ollama manifest, and a draft model:**
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
   curl -sf http://localhost:1234/api/tags | jq '.models[].name'                       # Ollama
   curl -sf http://localhost:1244/models | jq -r '.data[] | "\(.id) \(.status.value)"'  # llama-server router: presets + load state
   ```

2. **Run one non-interactive turn through the launcher** (no picker):
   ```bash
   CLAUDE_LOCAL_MODEL=<name> claude-local -p 'Reply with OK'
   # <name>: the Ollama tag (qwen3-coder:30b) or the llama-server preset alias (qwen3.6-35b);
   # bootstrap prints it on its last line
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
   Compare against the 2026-09-05 baseline with the same core allowlist (21.4s/task mean, 94% cache hit).

## Troubleshooting common bootstrap failures

| error | cause | fix |
|---|---|---|
| "no systemd user manager" | Running from cron, container, or `env -i` | Set `XDG_RUNTIME_DIR="/run/user/$(id -u)"` or run from a login shell |
| "npm global prefix not writable" | System Node.js installed, blocking user-local install | Remove system node from PATH: `export PATH="${PATH//$(npm config get prefix \/bin):}/"` then rerun |
| "server did not answer on port" | Port conflict or GPU OOM | Check `ss -tlnp` for conflicts; check `dmesg` for OOM kills |
| "no llama-server at build-hip/bin/llama-server" | llama.cpp not built yet | Build it first (see recipe above) |
| Model pull hangs | Network issues or registry timeout | Retry; the model is ~18GB and can take minutes on slow connections |
| "download failed; rerun to resume from ...part" | Network drop during `--hf` | Rerun the same command; `curl -C -` continues the `.part` file |
| "exists with N bytes, expected M" | A different file already has the download's name (e.g. the non-MTP quant) | Remove it, or pass `--model-gguf PATH` to save the download elsewhere |
| "sha256 mismatch" / "not a GGUF file" | Corrupt or wrong download | Remove the file and rerun |
| "--hf downloads a GGUF for llama-server" | `--hf` without `--backend llamaserver` | Add `--backend llamaserver` |

## What gets installed where

| path | role |
|---|---|
| `~/.local/ollama/` | Ollama binary + libraries (~3.5GB) |
| `~/.config/systemd/user/ollama.service` | Systemd user unit |
| `~/.config/systemd/user/ollama.service.d/10-claude-local.conf` | Context/KV/slots/flash attention drop-in |
| `~/.config/systemd/user/ollama.service.d/20-gpu-*.conf` | GPU profile drop-in (one active) |
| `~/.claude-local/env` | Persisted port + backend config |
| `~/.claude-local/llama-server.env` | llama-server device (`LLAMA_DEVICE`) and INI path (llama-server mode) |
| `~/.claude-local/llama-models.ini` | Router presets, one section per GGUF; the section name is the model alias (llama-server mode) |
| `~/.config/systemd/user/llama-server.service` | llama-server user unit on port 1244 + drop-in (llama-server mode) |
| `~/.claude-local/models/` | GGUF models (llama-server mode; `--hf` downloads land here) |
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
