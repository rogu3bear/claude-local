# Tune Performance — claude-local

When turns are slow, cache hit is low, TTFT is high, or the model uses too many turns per task. This skill teaches how to read performance data and tune the stack.

## Baseline numbers (reference)

These are measured on Ryzen AI MAX+ 395 (Strix Halo iGPU), Vulkan runner, qwen3-coder:30b Q4_K_M:

| configuration | mean wall/task | turns/task | cache% | prompt tok/task |
|---|---|---|---|---|
| **Shipped default (core tools)** | **21.4s** | **8.5** | **94%** | **50K** |
| Full tool list | 49.0s | 9.3 | 92% | 148K |
| Without `--exclude-dynamic-system-prompt-sections` | 69.0s | 12.0 | 90% | 217K |
| Compact prompt (replace mode) | 22.0s | — | 99% | — |

**Targets:** wall/task < 30s, turns/task < 10, cache% > 85%, prompt tok/task < 60K.

## Step 1: Read the usage proxy log

Every turn is logged to `~/.claude-local/run/*/usage.jsonl`. Read recent turns:

```bash
# Last 5 turns from current session
tail -5 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq '{ts, model, out_tps, cache_pct, ttft_ms, prompt, output}'
```

Key metrics and what they mean:

| metric | good | bad | cause of bad |
|---|---|---|---|
| `cache_pct` | > 85% | < 70% | System prompt changed between turns, context overflow, or tool schema bloat |
| `out_tps` | > 40 tok/s on Vulkan iGPU | < 15 tok/s | Context pressure (decode-bound at depth), CPU fallback, or wrong GPU build |
| `ttft_ms` | < 5000ms for warm turn | > 15000ms | Cold load, prefix cache miss, or context truncation from front |
| `prompt` (total) | < 60K tokens | > 100K tokens | Too many tools in schema, large system prompt, or accumulated history |

## Step 2: Check the statusline

The statusline shows live performance data. If it's running:

```bash
# The statusline reads Claude Code's JSON payload on stdin + session state
# You can trigger a read of the current session's usage line:
tail -1 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq -r '[.out_tps, .cache_pct, .prompt, .ms] | @tsv'
```

The statusline also shows context pressure (the gauge bar), thinking state, and per-core CPU. A full context gauge means autocompact is triggering — the prompt gets truncated from the front, which busts the prefix cache.

## Step 3: Diagnose slow turns

### Low cache hit (< 85%)

1. **Check for dynamic system prompt sections:**
   ```bash
   # The launcher should use --exclude-dynamic-system-prompt-sections
   # This prevents git status from changing the prompt each turn
   grep 'exclude-dynamic' ~/.local/bin/claude-local   # the launcher: a symlink into the checkout (bin/claude-local under ~/dev/claude-local)
   ```
   If missing, every turn gets a different system prompt (git dirty state changes), causing 100% cache miss.

2. **Check autocompact setting:**
   ```bash
   cat ~/.claude-local/run/*/context_max 2>/dev/null
   ```
   If autocompact is too small, the prompt gets truncated mid-session, busting cache. The launcher computes: `autocompact = server_context - max_output(16384) - 2048`. Floor is 100K.

3. **Check tool surface:**
   ```bash
   env | grep CLAUDE_LOCAL_TOOLS
   ```
   Full tool list adds ~5K tokens to the system prompt (tool schemas). Core tools (`Bash,Read,Edit,Write,Grep,Glob`) keeps it lean. More tools = more schema tokens = lower cache hit ratio.

### High TTFT (> 15s warm, > 30s cold)

1. **Cold load is expected** — first turn always misses the prefix cache (~15K system prompt + tool schemas). Subsequent turns should be < 5s.
2. **Check server context vs Claude's assumption:** Claude assumes 200K for unknown models. If the server has 128K, the launcher sets `--autocompact` to prevent silent truncation. Mismatch causes cache misses.
3. **Check GPU temperature/throttling:**
   ```bash
   for f in /sys/class/drm/card*/device/temp; do [ -r "$f" ] && echo "$(basename $(dirname $f)): $(cat $f) mC"; done
   ```
   Thermal throttling on the iGPU can reduce decode throughput significantly.

### High turns/task (> 10)

1. **Meta-tool sink:** The model wastes turns on ReportFindings, TaskList, or Skill when these are in the tool list. Benchmarked: ~30% of turns go to meta-tools with the full tool list.
   ```bash
   env | grep CLAUDE_LOCAL_TOOLS
   # If it includes Agent, ReportFindings, TaskCreate etc., that's the likely cause
   ```
2. **Verbose output:** The model is generating long explanations instead of focused edits. The system prompt should say "be direct and concise; do not pad or apologize."
3. **Check for retry loops:** If the same command fails twice and the model retries blindly, each retry is a wasted turn.

## Step 4: Tune settings

### Reduce tool surface (biggest single lever after cache flag)

Edit `~/.claude-local/env` or set `CLAUDE_LOCAL_TOOLS`:
```bash
# Benchmark allowlist (the shipped default until 2026-09-07) — removes the meta-tool sink
CLAUDE_LOCAL_TOOLS=Bash,Read,Edit,Write,Grep,Glob

# Shipped default since 2026-09-07 — capability over speed (Agent, WebFetch, task tools, ReportFindings)
CLAUDE_LOCAL_TOOLS=Bash,Read,Edit,Write,Grep,Glob,Agent,WebFetch,TodoWrite,TaskCreate,TaskList,TaskUpdate,TaskGet,TaskStop,TaskOutput,ProposeGoal,ReportFindings
```

Leave `WebSearch` out of any list: it is executed by Anthropic's API and returns nothing here. The
launcher registers `config/mcp-websearch.py` as an MCP server instead (`mcp__websearch__web_search`,
`CLAUDE_LOCAL_WEBSEARCH=1`), and `--tools` does not filter MCP tools.

Measured impact: 49s → 21.4s mean wall/task on this hardware. The tool schemas cost ~5K prompt tokens and waste ~30% of turns.

### Fit context window to server

If the server has a smaller context than Claude's 200K assumption, set autocompact explicitly:
```bash
# In ~/.claude-local/env or as env override
CLAUDE_LOCAL_AUTOCOMPACT=112640
```

The formula: `server_context - CLAUDE_LOCAL_MAX_OUTPUT(16384) - 2048`. Must be >= 100K (Claude's floor).

### Adjust sampling via proxy

If the model is being too verbose or not following instructions:
```bash
# Set in the launcher or proxy environment
PROXY_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'
```

The proxy applies this to every `/v1/messages` request, overriding whatever Claude sends (which is nothing by default).

### KV cache type (llama-server only)

In `systemd/llama-server/10-claude-local.conf`:
```
# q8_0 KV is faster than f16 on this iGPU (bandwidth-bound): 2x prefill, +33% decode
LLAMA_ARG_CACHE_TYPE_K=q8_0
LLAMA_ARG_CACHE_TYPE_V=q8_0
```

Keep q8_0 unless moving to different hardware where memory bandwidth isn't the bottleneck.

### Disable speculative decoding on iGPU

On this Ryzen AI MAX+ iGPU, speculative decoding **loses on the MoE** (Qwen3-Coder-30B-A3B, 2026-09-05) despite 55% draft acceptance: a batched verify activates more experts, so it costs more than the tokens it saves. On a **dense** model it is the opposite: decode is bound by weight bandwidth and a verify of 4 tokens reads the weights once, so Qwen3.8-27B goes 7.7 -> 19.2 tok/s with `spec-type = draft-mtp`, `spec-draft-n-max = 4` (2026-09-07). Speculation is the `spec-type` key of the preset's section in `~/.claude-local/llama-models.ini` (not an env var: `LLAMA_EXTRA_ARGS` would override every preset). To disable it for one preset, comment the key out there and reload the router:
```ini
[qwen3.8-27b]
model = /home/mln-dev/.claude-local/models/Qwen3.8-27B-Q8_0.gguf
reasoning = on
;spec-type = draft-mtp
;spec-draft-n-max = 4
```
```bash
curl -s 'http://127.0.0.1:1244/models?reload=1' >/dev/null   # re-read the INI; a loaded model whose section changed is unloaded
```

## Step 5: Run a benchmark to compare

After making changes, run the benchmark harness:

```bash
cd ~/dev/claude-local/bench && ./run.sh --label tuned-config -- \
    --append-system-prompt-file ~/.claude-local/system_prompt.md \
    --exclude-dynamic-system-prompt-sections \
    --autocompact 120832 \
    --tools Bash,Read,Edit,Write,Grep,Glob
```

Compare against baseline:
```bash
./compare.py baseline tuned-config
```

Key comparison metrics: mean wall/task (lower is better), turns/task (lower = more efficient), cache% (higher = better cache utilization).

## Quick tuning checklist

```bash
echo "=== Performance Diagnostics ==="
PORT="${CLAUDE_LOCAL_PORT:-1234}"

# 1. Tool surface
echo "--- Tools ---"
env | grep CLAUDE_LOCAL_TOOLS || echo "(not set — using default)"

# 2. Cache hit (last 10 turns)
echo "--- Cache hit (last 10) ---"
tail -10 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq -r '.cache_pct' | awk '{s+=$1;n++} END {if(n) printf "avg: %.0f%%\n", s/n; else print "(no data)"}'

# 3. Throughput
echo "--- Output throughput ---"
tail -10 ~/.claude-local/run/*/usage.jsonl 2>/dev/null | jq -r '.out_tps' | awk '{s+=$1;n++} END {if(n) printf "avg: %.1f tok/s\n", s/n; else print "(no data)"}'

# 4. Context pressure
echo "--- Context max ---"
cat ~/.claude-local/run/*/context_max 2>/dev/null || echo "(not set)"

# 5. GPU temp
echo "--- GPU temp ---"
for f in /sys/class/drm/card*/device/temp; do [ -r "$f" ] && echo "$(basename $(dirname $f)): $(cat $f) mC"; done 2>/dev/null || echo "(N/A)"
```

## Performance decision matrix (from benchmarks)

| change | effect on wall/task | effect on cache% | notes |
|---|---|---|---|
| `--exclude-dynamic-system-prompt-sections` | 42s → 31s | 90% → 98% | Biggest single win after tool surface |
| Core tools (vs full list) | 49s → 21.4s | 92% → 94% | Removes ~5K token schema overhead |
| Server fit (128K, q8_0 KV) | 42s → 31s | 90% → 98% | Reduces model memory 45.6GB → 26.1GB |
| Compact prompt (replace mode) | ~22s | 99% | Slightly lower pass rate (88% vs 100%) |
| Q8 weights | 31s → 35.9s | 98% → 98% | No accuracy gain, slower decode on iGPU |
| Speculative decoding (iGPU) | MoE: worse (Qwen3-Coder, 2026-09-05); dense Qwen3.8-27B: 7.7 -> 19.2 tok/s decode with `draft-mtp` n-max 4 (2026-09-07) | N/A | Per preset (`spec-type` in `llama-models.ini`); speculate on dense models, measure on MoE |
