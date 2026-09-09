# Manage Models — claude-local

Switching models, loading/unloading from GPU memory, managing the model inventory, and understanding trade-offs between available models.

## Model inventory

Models are stored in two places:
- **~/.claude-local/models/** — GGUF files used directly by llama-server
- **~/.ollama/models/blobs/** — Ollama's internal storage (sha256-named blobs)

The launcher discovers available models via the backend adapter, which queries the running server:

```bash
# Ollama: returns installed model names and sizes
curl -sf http://localhost:$PORT/api/tags | jq '.models[].name'

# llama-server (router mode): every preset in ~/.claude-local/llama-models.ini with its load state
curl -sf http://localhost:$PORT/models | jq -r '.data[] | "\(.id) \(.status.value)"'
```

llama-server presets come from `~/.claude-local/llama-models.ini` (one section per GGUF; the section
name is the alias). After downloading a GGUF into `~/.claude-local/models/`, run `llama-models-ini`
to append a section and reload the router, then rename the section if you want a nicer alias.

## Model picker (picker.py)

The interactive picker reads the backend inventory and shows load state:

```bash
CLAUDE_LOCAL_MODEL="" MODELS_JSON_PATH=$(mktemp) \
  LOADED_MODELS="$(curl -sf http://localhost:$PORT/api/ps | jq -r '[.models[].name] | join(",")')" \
  python3 ~/.claude-local/picker.py      # the installed path: a symlink into the checkout's config/ directory
```

Output format: `[LOADED]` = in memory right now, `[idle]` = installed but not loaded.

The picker outputs one machine-readable line to stdout: `ACTION|model-name` where ACTION is:
- **LOAD** — model needs to be loaded into GPU memory first
- **USE** — model is already loaded; just connect to it

If `CLAUDE_LOCAL_MODEL` env var is set, the picker skips the menu (non-interactive mode) and does an exact match first, then substring match.

## Loading and unloading models

### Ollama

```bash
# Load (keep alive for 2 hours by default)
curl -sf --max-time 900 http://localhost:$PORT/api/generate \
  -d '{"model":"NAME","prompt":"","stream":false,"options":{"num_predict":0},"keep_alive":"2h"}'

# Unload (evict from memory)
curl -sf --max-time 600 http://localhost:$PORT/api/generate \
  -d '{"model":"NAME","prompt":"","stream":false,"options":{"num_predict":0},"keep_alive":0}'

# Check what's loaded
curl -sf http://localhost:$PORT/api/ps | jq '.models[].name'
```

### llama-server

llama-server runs in router mode: the unit starts without a model and loads presets on demand,
up to two resident (`LLAMA_ARG_MODELS_MAX=2`; a third load evicts the least recently used after the proxy has checkpointed it). The usage proxy also unloads a preset no session has used for 20 minutes (`CLAUDE_LOCAL_IDLE_UNLOAD`).
The launcher does all of this; by hand:

```bash
# Load (then poll /models until status.value == "loaded"; "failed": true means see the journal)
curl -sf -X POST http://localhost:$PORT/models/load -H 'content-type: application/json' -d '{"model":"qwen3.8-27b"}'

# Restore this model's saved prompt cache for a warm first turn (POST bodies carry "model")
curl -sf --max-time 300 -X POST http://localhost:$PORT/slots/0?action=restore \
  -H 'content-type: application/json' \
  -d '{"filename":"claude-local-qwen3.8-27b.bin","model":"qwen3.8-27b"}'

# Unload = save the prompt cache, then free the memory
curl -sf --max-time 600 -X POST http://localhost:$PORT/slots/0?action=save \
  -H 'content-type: application/json' \
  -d '{"filename":"claude-local-qwen3.8-27b.bin","model":"qwen3.8-27b"}'
curl -sf -X POST http://localhost:$PORT/models/unload -H 'content-type: application/json' -d '{"model":"qwen3.8-27b"}'

# GET endpoints name the model in the query string
curl -sf "http://localhost:$PORT/props?model=qwen3.8-27b" | jq '.default_generation_settings.n_ctx'

# Stop the router entirely
systemctl --user stop llama-server.service
```

## Memory footprint

On this machine's ~108GB GPU pool:

| preset | file | weights | decode (tok/s, 2.7K prompt) | load from page cache |
|---|---|---|---|---|
| `qwen3.6-35b` | Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL | 22.9GB | 66 ROCm / 69 Vulkan (MoE, 3B active, MTP n-max 2) | ~12s |
| `qwen3.8-27b` | Qwen3.8-27B-Q8_0 | 29.0GB | 19 ROCm with MTP n-max 4 (7.7 plain; dense, bandwidth-bound) | ~9s |
| `qwen3.8-27b-q6kxl` | Qwen3.8-27B-UD-Q6_K_XL | 25.3GB | 20 ROCm with MTP (8.6 plain) | ~9s |
| `qwen3.8-27b-q6k` | Qwen3.8-27B-UD-Q6_K | 22.0GB | 25 ROCm with MTP (9.4 plain); ~18 for every quant at 10K depth | ~9s |
| qwen3-coder:30b (Ollama) | Q4_K_M | 18GB | ~70 Vulkan | ~60s cold |

The router keeps up to two llama-server models resident (`LLAMA_ARG_MODELS_MAX=2`; Qwen3.6 + Qwen3.8 together
take 56GB of the 108GB pool). A dense 27B decodes roughly 8x slower than the 3B-active MoE on this iGPU
because decode is bound by weight bandwidth; MTP speculation (every Qwen3.8 quant carries the head) brings
it to 2.5x plain, which is why the presets ship with `spec-type = draft-mtp`.

## Slot cache (llama-server only)

Prompt caches are saved to `~/.claude-local/slots/` as `claude-local-<slug>.bin`. This enables warm session restores: a fresh launch starts with the previous conversation already in context.

```bash
# List saved slots
ls -la ~/.claude-local/slots/

# Slot files are named from the model alias (sanitized to ASCII)
# e.g., preset [qwen3.6-35b] -> claude-local-qwen3.6-35b.bin
```

If the model alias changes, old slot files become orphaned. Clean up stale slots:
```bash
# Current preset names
curl -sf http://localhost:$PORT/models | jq -r '.data[].id'

# Compare with saved slots — remove mismatches if needed
ls ~/.claude-local/slots/claude-local-*.bin
```

## Switching models mid-session

1. **Save current state** (llama-server only): unload to persist prompt cache
2. **Unload the current model**: frees ~26GB
3. **Load the new model**: cold load takes 10-90s depending on size
4. **Start a new session** or restore from slot if available

The post-exit menu in the launcher offers: unload, leave loaded, or load another model.

## Model selection strategy

| use case | recommended model | backend | why |
|---|---|---|---|
| General coding, speed | `qwen3.6-35b` | llama-server | MTP head embedded, draft-mtp speculation, 27/27 on the task bench at 12.3s mean |
| Dense thinking model (quality, LoRA target) | `qwen3.8-27b` (Q8) or `qwen3.8-27b-q6k` | llama-server | reasoning on, MTP speculation; 17-25 tok/s decode, so a 1K-token reply is about a minute |
| Quick iterations | qwen3-coder:30b | Ollama | Simpler stack, faster cold start, proven benchmark results |
| Draft model | Qwen3-0.6B (Q8) | llama-server only | Needed for draft-simple speculative decoding; standalone use not recommended |
| Low VRAM / CPU | Smaller model or quantized | either | CPU fallback is 10-50x slower than GPU decode |

## Quick model management script

```bash
PORT="${CLAUDE_LOCAL_PORT:-1234}"
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"

echo "=== Model Status ==="
if [ "$BACKEND" = ollama ]; then
  echo "Ollama loaded models:"
  curl -sf http://localhost:$PORT/api/ps | jq -r '.models[]?.name // empty' 2>/dev/null || echo "(server down)"
  echo ""
  echo "All Ollama models:"
  curl -sf http://localhost:$PORT/api/tags | jq -r '.models[].name' 2>/dev/null || echo "(server down)"
else
  echo "llama-server presets (router mode):"
  curl -sf http://localhost:$PORT/models | jq -r '.data[] | "\(.id) \(.status.value)"' 2>/dev/null || echo "(server down)"
  echo ""
  echo "Saved slots:"
  ls -lh ~/.claude-local/slots/claude-local-*.bin 2>/dev/null || echo "(none)"
fi

echo ""
echo "GPU VRAM usage:"
for f in /sys/class/drm/card*/device/mem_info_gtt_total; do
  [ -r "$f" ] && echo "  Total: $(cat $f) KB"
done
```

## Known model behaviors

- **Qwen3.6 sampling**: The model card and Unsloth recommend temp=0.7, top_p=0.8, top_k=20, min_p=0, presence_penalty=1.5. These sit in the `[*]` section of `~/.claude-local/llama-models.ini` since Claude Code sends no sampling params by default; `LLAMA_EXTRA_ARGS` stays empty in router mode because CLI args beat preset keys for every instance.
- **Thinking mode**: per preset, `reasoning = off` (Qwen3.6, bench winner) or `reasoning = on` (Qwen3.8 presets). Thinking increases output tokens significantly and slows turns. The old `LLAMA_ARG_CHAT_TEMPLATE_KWARGS='{"enable_thinking":...}'` form is deprecated in llama.cpp.
- **MTP (multi-token prediction)**: The Qwen3.6 GGUF and every unsloth Qwen3.8 quant carry an embedded draft head (`nextn` tensors). `spec-type = draft-mtp` uses it without a separate draft file; on the dense Qwen3.8 it is worth 2.5x decode (n-max 4). The Qwen3-0.6B draft cannot pair with Qwen3.8 (248K vs 152K vocabulary).
- **Qwen3.8 chat template**: raises "System message must be at the beginning" on a mid-conversation system message. Claude Code sends one (the Agent tool's type list) whenever Agent is in `--tools`; the usage proxy folds it into the system prompt, so keep `CLAUDE_LOCAL_PROXY=1` with Qwen3.8.
- **Q8 vs Q4 on iGPU**: Q8 weights are bandwidth-bound — larger weight footprint means slower decode. Q4 is faster on this hardware with no measurable accuracy difference in benchmarks.
