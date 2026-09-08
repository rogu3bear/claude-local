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

## Step 0: Run the doctor and read the event log first

```bash
claude-local-doctor --since 2h          # read-only; PASS/WARN/FAIL per check with a hint for each finding
tail -n 30 ~/.claude-local/logs/events.jsonl | jq -c '{ts,level,kind,status,err_class,err_msg,div,hint}'
tail -n 5 "$CLAUDE_LOCAL_SESSION_DIR/events.jsonl" 2>/dev/null | jq -c '{kind,status,err_class,hint}'
```

The event log names the failure class of every failed turn (`turn_failed` with `err_class` template /
model_not_found / model_load / context / oom / busy / server) and carries a `hint` with the fix. A
`retry_storm` event is what "waiting for API" looks like from the inside. `cache_miss` events say where
the request diverged from the previous one (`div`: system[i], tools, messages[i], or extension when the
server itself lost the slot). Most diagnoses end here.

**Never restart, stop or kill the server or the proxy that is serving the session you are in**: the current
turn dies with it and the hook `config/hook-audit.py` refuses those commands anyway. Report the finding and
let the user decide; the launcher's post-exit menu unloads models cleanly.

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

## Step 7: Restart (only the user, only when no session is live)

A restart kills every session's turn and evicts every model; the proxy checkpoints slots so they come back
warm, but the running turn is lost. From inside a session the guard refuses these commands. Tell the user:

```bash
# when no claude-local session is running:
systemctl --user restart llama-server.service     # or ollama.service
claude-local-doctor --since 10m                   # confirm /health 200 and no failed presets
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
| Port already in use | Stale proxy from a crashed session | `claude-local-doctor` lists orphan proxies with their pids; ask the user to kill them (never a port the live session uses) |
| GPU resets in dmesg | Linux 7.0 kernel 2s job timeout on long submits | Reboot; this is a known issue under heavy context loads (>60K tokens) |
| Model won't load after picker says LOAD | Backend adapter failed silently | Check `journalctl --user -u <service>` for the actual error |
| Cache hit drops to near 0 | Something before the conversation tail changes every turn (Claude Code's `<total_tokens>` reminder did this on 2026-09-08), or a subagent shares the single slot | `cache_miss` events carry `div`; `make check-prefix` reproduces offline; `conv_switch` events show slot sharing |
| "waiting for API", "API Error" in the session | Claude Code retrying a failing turn (up to 11 attempts) | `events.jsonl`: the `turn_failed` / `upstream_unreachable` / `stream_incomplete` event says why; `retry_storm` marks the loop |

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
