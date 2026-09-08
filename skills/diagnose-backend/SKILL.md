# Diagnose Backend — claude-local

When the server is unreachable, a turn fails, the model won't load, or performance is degraded. This skill teaches how to diagnose and fix backend issues in the claude-local stack.

## Architecture overview

```
User → claude-local launcher → proxy.py (port PORT+1) → backend server (port PORT) → GPU
```

- **Ollama** listens on port 1234 by default (`CLAUDE_LOCAL_OLLAMA_PORT`)
- **llama-server** listens on port 1244 by default (`CLAUDE_LOCAL_LLAMASERVER_PORT`)
- The proxy sits on the next free port and logs usage to `~/.claude-local/usage.jsonl`
- Health checks: Ollama → `/api/tags`, llama-server → `/health` (returns 503 while loading)

## Step 1: Identify the backend

```bash
cat ~/.claude-local/env | grep BACKEND
# or: env | grep CLAUDE_LOCAL_BACKEND
```

This tells you whether to check Ollama or llama-server. If the env file doesn't set it, default is `ollama`.

## Step 2: Check if the server responds

**Ollama:**
```bash
curl -sf --max-time 3 http://localhost:$PORT/api/tags && echo "OK" || echo "DOWN"
```

**llama-server:**
```bash
curl -sf --max-time 3 http://localhost:$PORT/health && echo "OK" || echo "DOWN"
```

If the server returns 503 on `/health`, it is still loading — **do not restart**. Wait and retry. A cold load of a 17GB model can take several minutes.

## Step 3: Check systemd unit status

**Ollama:**
```bash
systemctl --user status ollama.service
journalctl --user -u ollama.service --since "5 min ago" -n 50
```

**llama-server:**
```bash
systemctl --user status llama-server.service
journalctl --user -u llama-server.service --since "5 min ago" -n 50
```

Look for: GPU initialization failures, OOM kills, model load errors, or port binding conflicts.

## Step 4: Check GPU state

```bash
# VRAM usage (Vulkan/RADV)
cat /sys/class/drm/card*/device/mem_info_gtt_total 2>/dev/null | head -1
nvidia-smi 2>/dev/null | head -20  # if NVIDIA

# GPU busy % (thinking indicator source)
for f in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r "$f" ] && echo "$f: $(cat $f)"; done

# Check for GPU resets (kernel ring buffer)
dmesg 2>/dev/null | grep -iE 'gpu|reset|amdgpu|radeon' | tail -10
```

If VRAM is exhausted, the server will fail or swap to CPU (extremely slow). The GPU pool on this machine is ~108GB; each model takes ~26GB at Q4, ~50GB at Q8.

## Step 5: Check for port conflicts

```bash
ss -tlnp | grep -E ':(1234|1244|1235|1245)\b'
```

If two processes bind the same port, the newer one fails silently. Kill the stale process:
```bash
fuser -k 1234/tcp  # or whichever port is conflicted
```

## Step 6: Read the usage proxy log

```bash
tail -5 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq '.'
```

Key diagnostic fields:
- `cache_pct`: below 80% suggests context window mismatch or changing system prompt
- `out_tps`: tokens/sec during generation. Below 10 tok/s on this iGPU indicates CPU fallback or extreme context pressure
- `ttft_ms`: time-to-first-token. Above 30s suggests cold load or context overflow
- `input` + `cache_read`: total prompt size. If this exceeds the server context, truncation occurs

## Step 7: Restart (only when safe)

**Ollama:**
```bash
systemctl --user restart ollama.service
sleep 3
curl -sf --max-time 3 http://localhost:$PORT/api/tags && echo "Server is up" || echo "Still starting..."
```

**llama-server:**
```bash
# Only restart if the server is NOT returning 503 (not loading)
health_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/health)
if [ "$health_code" != "503" ]; then
  systemctl --user restart llama-server.service
else
  echo "Server is still loading (503). Do not restart — wait for it."
fi
```

## Common failure modes

| symptom | likely cause | fix |
|---|---|---|
| `/health` returns 503 constantly | Single-model mode: model still loading, or GPU OOM killed it | Wait; check `dmesg` for OOM; ensure VRAM has ~26GB free per model |
| Router up but a preset stays `unloaded` with `failed: true` | The instance died on load (bad path, truncated GGUF, OOM) | `journalctl --user -u llama-server.service -e`; verify the `model =` path in `~/.claude-local/llama-models.ini`; `curl 'http://127.0.0.1:1244/models?reload=1'` after fixing |
| Picker shows no llama-server models | INI empty or unreadable, or the env file still points at a single model | `llama-models-ini`; check `LLAMA_ARG_MODELS_PRESET` in `~/.claude-local/llama-server.env` |
| Every Qwen3.8 turn fails with HTTP 500 `System message must be at the beginning` | Claude Code's mid-conversation `role: system` message (Agent tool) hits Qwen3.8's template | Run through the usage proxy (`CLAUDE_LOCAL_PROXY=1`, default), which folds it into the system prompt |
| Web search returns nothing, or the model says WebSearch is unavailable | The built-in WebSearch is executed by Anthropic's API and cannot work here; the MCP replacement is off or not reachable | The launcher banner must say `websearch=1` (`CLAUDE_LOCAL_OFFLINE=1` forces it off); check `$CLAUDE_LOCAL_SESSION_DIR/mcp.json` exists; test the server by hand with the recipe at the top of `config/mcp-websearch.py` |
| Very slow (30s+ per turn) | Context overflow, CPU fallback, or low cache hit | Check usage.jsonl for `cache_pct`; verify autocompact matches server context |
| Port already in use | Stale process from crashed session | `fuser -k PORT/tcp`; check for zombie `ollama` or `llama-server` processes |
| GPU resets in dmesg | Linux 7.0 kernel 2s job timeout on long submits | Reboot; this is a known issue under heavy context loads (>60K tokens) |
| Model won't load after picker says LOAD | Backend adapter failed silently | Check `journalctl --user -u <service>` for the actual error |
| Cache hit drops to near 0 | System prompt changed between turns (dynamic sections) | Verify `--exclude-dynamic-system-prompt-sections` flag is set in launcher |

## llama-server-specific: slot cache

llama-server saves/restores prompt caches to disk for warm session restores:

```bash
# List saved slots
ls -la ~/.claude-local/slots/

# Check if current server's alias matches a saved slot
curl -sf http://localhost:$PORT/props | jq '.model_alias'
```

If the slot filename doesn't match (alias changed), the restore silently fails. The slot files are named `claude-local-<slug>.bin`.

## Quick diagnostic script

For a one-shot diagnosis:

```bash
PORT="${CLAUDE_LOCAL_PORT:-1234}"
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"
echo "Backend: $BACKEND (port $PORT)"

# Health check
if [ "$BACKEND" = ollama ]; then
  curl -sf --max-time 3 "http://localhost:$PORT/api/tags" | jq -c '.' 2>/dev/null || echo "Ollama DOWN"
else
  curl -sf --max-time 3 "http://localhost:$PORT/health" && echo "llama-server OK (503=loading)" || echo "llama-server DOWN"
fi

# GPU
echo "--- GPU ---"
for f in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r "$f" ] && echo "$(basename $(dirname $f)): ${f##*=}%" ; done 2>/dev/null

# Usage log
echo "--- Last turn ---"
tail -1 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq -c '{ts, out_tps, cache_pct, ttft_ms}'

# Systemd
systemctl --user is-active "${BACKEND:-ollama}.service" 2>/dev/null || systemctl --user is-active llama-server.service 2>/dev/null || echo "No service found"
```
