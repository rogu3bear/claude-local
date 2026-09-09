# Configure Backend — claude-local

Changing backend settings: GPU device, context window, speculative decoding, sampling params, flash attention. For when you're tuning the server itself.

## Configuration layers

Settings live in three places, applied in order (later overrides earlier):

```
systemd drop-ins          → 10-claude-local.conf (context, KV cache, batch)
                            20-gpu-*.conf     (GPU profile: Vulkan, ROCm, NVIDIA, CPU)
llama-server.env          → device, path of the model preset INI (router mode), extra args
llama-models.ini          → one section per model: file, reasoning, speculation, sampling
Ollama env vars           → OLLAMA_CONTEXT_LENGTH, OLLAMA_KV_CACHE_TYPE, etc.
```

### Systemd drop-ins (persistent tuning)

These are installed to `~/.config/systemd/user/ollama.service.d/` or `llama-server.service.d/`:

**10-claude-local.conf** — server fit settings:
```ini
Environment=LLAMA_ARG_CTX_SIZE=131072          # 128K context window
Environment=LLAMA_ARG_N_PARALLEL=1              # one slot (Claude Code is single-client)
Environment=LLAMA_ARG_FLASH_ATTN=on             # flash attention (required for q8_0 KV)
Environment=LLAMA_ARG_CACHE_TYPE_K=q8_0         # K cache quantized (faster on iGPU)
Environment=LLAMA_ARG_CACHE_TYPE_V=q8_0         # V cache quantized
Environment=LLAMA_ARG_CACHE_REUSE=256           # KV shift cache reuse distance
Environment=LLAMA_ARG_CACHE_RAM=16384           # RAM prompt cache, per model instance
Environment=LLAMA_ARG_BATCH=2048                # batch size (Ollama parity)
Environment=LLAMA_ARG_UBATCH=2048               # micro-batch size
```

**20-gpu-*.conf** — GPU profile (one is active, selected at bootstrap):
| file | hardware | key env vars |
|---|---|---|
| `20-gpu-amd-vulkan.conf` | AMD iGPU/APU via Vulkan/RADV | `VK_ICD_FILENAMES=...radeon_icd.json`, `AMD_VULKAN_ICD=RADV`, `HIP_VISIBLE_DEVICES=-1` |
| `20-gpu-amd-rocm.conf` | AMD discrete GPU via ROCm | `OLLAMA_VULKAN=0` |
| `20-gpu-nvidia.conf` | NVIDIA via CUDA | (nothing to set; bundled CUDA runner) |
| `20-gpu-cpu.conf` | CPU only | `CUDA_VISIBLE_DEVICES=-1`, `HIP_VISIBLE_DEVICES=-1`, `OLLAMA_VULKAN=0` |

### llama-server.env (per-machine config)

Located at `~/.claude-local/llama-server.env`:

```bash
LLAMA_DEVICE=ROCm0                # selects the build dir: ROCm0 -> build-hip, Vulkan0 -> build-vulkan; bootstrap --device auto (the default) picks ROCm0 when build-hip lists it, else Vulkan0
LLAMA_CPP_DIR=/home/mln-dev/ai/llama.cpp   # source directory
LLAMA_ARG_MODELS_PRESET=/home/mln-dev/.claude-local/llama-models.ini   # router mode: absolute path, systemd does not expand $HOME
LLAMA_EXTRA_ARGS=                 # CLI flags for every instance; they BEAT the INI, so keep sampling out of here
# single-model mode instead (pre-router layout): comment the preset line and set
#LLAMA_ARG_MODEL=/path/to/model.gguf
#LLAMA_ARG_ALIAS=qwen3.6-35b
```

### llama-models.ini (model presets, router mode)

Located at `~/.claude-local/llama-models.ini` (template: `config/llama-models.ini.example`). Each
section is one selectable model; the section name is the alias Claude, the picker and the smoke
test use. Keys are llama-server long options without dashes. No colons in section names (the
parser canonicalises the part after `:` as a quant tag).

```ini
version = 1
[*]                      ; shared by every preset
temp = 0.7
top-p = 0.8
top-k = 20
min-p = 0
presence-penalty = 1.5

[qwen3.8-27b]
model = /home/mln-dev/.claude-local/models/Qwen3.8-27B-Q8_0.gguf
reasoning = on           ; thinking model

[qwen3.6-35b]
model = /home/mln-dev/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf
reasoning = off
spec-type = draft-mtp
spec-draft-n-max = 2
```

Apply an edit without a restart: `curl -s 'http://127.0.0.1:1244/models?reload=1'` (a running
model whose section changed is unloaded). New GGUF under `~/.claude-local/models`: run
`llama-models-ini`, which appends a section per missing file and reloads the router. Precedence
per instance: CLI args (`LLAMA_EXTRA_ARGS`, wrapper flags) > model section > `[*]` > environment
(the unit drop-in). Server-wide tuning stays in the drop-in; `LLAMA_ARG_MODELS_MAX=2` there keeps
up to two models resident (a third load evicts the least recently used).

### Ollama env vars (set in systemd drop-in or environment)

```bash
OLLAMA_HOST=127.0.0.1:1234
OLLAMA_CONTEXT_LENGTH=131072
OLLAMA_KV_CACHE_TYPE=q8_0
OLLAMA_NUM_PARALLEL=1
OLLAMA_FLASH_ATTENTION=1
```

## Changing GPU device

**To switch between Vulkan and ROCm:**

1. Edit `~/.claude-local/llama-server.env` (llama-server) or change the GPU profile drop-in (Ollama):
   ```bash
   # For llama-server: change LLAMA_DEVICE
   sed -i 's/^LLAMA_DEVICE=.*/LLAMA_DEVICE=ROCm0/' ~/.claude-local/llama-server.env
   systemctl --user restart llama-server.service

   # For Ollama: swap the GPU drop-in. The profiles live in the checkout's systemd/ directory
   # (~/dev/claude-local, or "$(dirname "$(readlink -f ~/.local/bin/claude-local)")/../systemd"), not under ~/.claude-local
   cp ~/dev/claude-local/systemd/20-gpu-amd-rocm.conf \
      ~/.config/systemd/user/ollama.service.d/20-gpu.conf
   systemctl --user daemon-reload && systemctl --user restart ollama.service
   ```

2. Verify the device is recognized:
   ```bash
   # llama-server
   ~/ai/llama.cpp/build-hip/bin/llama-server --list-devices | grep ROCm0
   ~/ai/llama.cpp/build-vulkan/bin/llama-server --list-devices | grep Vulkan0

   # Ollama
   curl -sf http://localhost:$PORT/api/tags && echo "OK" || echo "DOWN"
   ```

**Note:** Each device requires its own build of llama.cpp (`build-hip` or `build-vulkan`). The ROCm Vulkan runner on Linux 7.0 kernel has known issues (GPU resets under heavy context loads). ROCm HIP prefills fastest but decode collapses at depth.

## Tuning context window

**llama-server:**
```ini
# In systemd/llama-server/10-claude-local.conf
Environment=LLAMA_ARG_CTX_SIZE=262144    # increase to 256K (needs more VRAM)
```
Then: `systemctl --user daemon-reload && systemctl --user restart llama-server.service`

**Ollama:**
```ini
# In systemd/ollama.service.d/10-claude-local.conf
Environment=OLLAMA_CONTEXT_LENGTH=262144
```
Then: `systemctl --user restart ollama.service`

**Trade-offs:**
- Larger context = more VRAM for KV cache (q8_0 at 256K ≈ +1.3GB over 128K)
- Decode throughput drops with context depth (bandwidth-bound attention)
- Claude's autocompact floor is 100K — server context must be >= 100K + max_output(16384) + 2048 = ~118K minimum

## Speculative decoding

Speculative decoding can speed up generation by drafting tokens with a smaller model, then verifying them in batch. Whether it helps depends on hardware:

**Modes (set `spec-type = ...` in the model's section of llama-models.ini; single-model mode: `LLAMA_ARG_SPEC_TYPE` in llama-server.env):**

| mode | needs draft model | when to use |
|---|---|---|
| `draft-simple` | Yes (separate GGUF) | General purpose; needs Qwen3-0.6B draft |
| `draft-mtp` | No (embedded head) | Qwen3.6 models with MTP head; uses the 0.6B draft inside the main GGUF |
| `ngram-mod` / `ngram-cache` | No | Draft-free; relies on n-gram matching in context |
| *(commented out)* | N/A | Disabled |

**Measured on Ryzen AI MAX+ 395 iGPU:** on the MoE (Qwen3-Coder-30B-A3B) speculative decoding **loses** despite 55% draft acceptance, because a batched verify activates more experts. On the dense Qwen3.8-27B it **wins 2.5x** (`draft-mtp`, n-max 4: 7.7 -> 19.2 tok/s), because a bandwidth-bound dense decode reads the weights once per verify. Rule: speculate on dense models, measure on MoE.

```ini
; Disable speculation for one preset: comment its key, then reload the router
;spec-type = draft-mtp
```
Exception measured 2026-09-06: Qwen3.6-35B-A3B with its embedded MTP head and `spec-draft-n-max = 2`
wins the task bench (27/27, 12.3s mean), so that preset keeps `spec-type = draft-mtp`.

**Draft model management:**
```bash
# Download the default draft model
curl -fL -o ~/.claude-local/models/Qwen3-0.6B-Q8_0.gguf \
  https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf

# Verify size (should be ~639MB)
stat -c %s ~/.claude-local/models/Qwen3-0.6B-Q8_0.gguf
```

## Sampling parameters

Claude Code sends no sampling params by default. They must be pinned either in the server config or via the proxy:

**Via llama-models.ini (server-side, per model or `[*]`):**
```ini
[*]
temp = 0.7
top-p = 0.8
top-k = 20
min-p = 0
presence-penalty = 1.5
```
These match Qwen's recommended settings (3.6 and 3.8) from the model card and Unsloth. Do not put
them in `LLAMA_EXTRA_ARGS` in router mode: CLI args override every preset.

**Via proxy (client-side override):**
```bash
# In the launcher or proxy environment
PROXY_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'
```
The proxy applies this to every `/v1/messages` request, overriding both server and Claude's defaults.

**Known settings:**
- `temp=0.7, top_p=0.8, top_k=20` — Qwen3.6 non-thinking default
- `presence_penalty=1.5` — reduces repetition; specific to Qwen3.6
- `min_p=0` — no min_p filtering (Qwen doesn't use it)
- `reasoning = off|on` per preset — thinking increases output tokens significantly; Qwen3.6 runs non-thinking (bench winner), Qwen3.8 presets run thinking on. `--chat-template-kwargs enable_thinking` is deprecated in llama.cpp.

## KV cache tuning

**q8_0 vs f16:** On this iGPU, q8_0 KV is faster than f16 (2x prefill, +33% decode at 30K context). The smaller cache wins because attention is bandwidth-bound. Keep q8_0.

Flash attention **must** be enabled with q8_0 KV — without it, the server silently falls back to f16:
```ini
Environment=LLAMA_ARG_FLASH_ATTN=on    # required for q8_0 KV
```

**Cache reuse and RAM:**
```ini
Environment=LLAMA_ARG_CACHE_REUSE=256   # KV shift cache reuse distance
Environment=LLAMA_ARG_CACHE_RAM=16384   # RAM prompt cache, per model instance
```
Higher `CACHE_RAM` (MiB) keeps more evicted contexts in RAM: measured 2026-09-08 at ~70 MB per 1K tokens on the Qwen3.6 presets, so a full 112K-token parent is ~8 GB. 16384 is the default since 2026-09-08 (it was 32768 for a day): the cache is **per model instance**, and with `LLAMA_ARG_MODELS_MAX=2` two 32 GB caches on top of ~52 GB of GTT for two sets of weights and KV pushed the 125 GB host into swap (unit peak 47 GB RAM + 4.7 GB swap). `claude-local-doctor` checks `CACHE_RAM x MODELS_MAX + largest weights` against RAM and the unit's swap peak.

## Batch size tuning

```ini
Environment=LLAMA_ARG_BATCH=2048       # batch size
Environment=LLAMA_ARG_UBATCH=2048      # micro-batch size
```
These are set to Ollama parity values. Increasing them may improve throughput for batched workloads but uses more VRAM. For Claude Code's single-client pattern, 2048 is optimal.

## Quick configuration reference

| setting | llama-server location | Ollama location | effect |
|---|---|---|---|
| Context window | `10-claude-local.conf`: `LLAMA_ARG_CTX_SIZE` | `10-claude-local.conf`: `OLLAMA_CONTEXT_LENGTH` | Max prompt + generation tokens |
| KV cache type | `10-claude-local.conf`: `LLAMA_ARG_CACHE_TYPE_K/V` | Same pattern | q8_0 faster on iGPU, f16 uses more VRAM |
| Flash attention | `10-claude-local.conf`: `LLAMA_ARG_FLASH_ATTN` | `OLLAMA_FLASH_ATTENTION=1` | Required for q8_0 KV; speeds up long context |
| GPU device | `llama-server.env`: `LLAMA_DEVICE` | `20-gpu-*.conf` env vars | Vulkan0 vs ROCm0 vs NVIDIA |
| Models | `llama-models.ini`: one section per GGUF | `ollama pull` | Alias, file, per-model options |
| Speculation | `llama-models.ini`: `spec-type` | N/A (Ollama doesn't support) | Draft-based token prediction |
| Reasoning | `llama-models.ini`: `reasoning` | Modelfile | Thinking on/off per model |
| Sampling | `llama-models.ini`: `[*]` or per section | Modelfile or proxy | Temperature, top_p, top_k, penalties |

## Restart after changes

```bash
# llama-server
systemctl --user daemon-reload
systemctl --user restart llama-server.service

# Ollama
systemctl --user daemon-reload
systemctl --user restart ollama.service

# Verify
curl -sf http://localhost:$PORT/health && echo "OK" || curl -sf http://localhost:$PORT/api/tags && echo "OK"
```

**Important:** Never restart a server that's returning 503 from `/health` — it's still loading. Wait for it to respond with 200.
