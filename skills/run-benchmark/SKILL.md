# Run Benchmark — claude-local

Setting up and running benchmarks, interpreting results, and comparing configurations. Encodes everything from the benchmark harness, docs, and measured claims.

## Overview

Benchmarks run 9 fixed coding tasks through `claude -p` against the local server, recording wall time, token usage (including cache hits), turns, and pass/fail. Every configuration change gets a number instead of an impression.

```
tasks/<name>/setup.sh    → creates scratch git repo with initial code
tasks/<name>/prompt.txt  → what the model is asked to do
tasks/<name>/check.sh    → validates result (exit 0 = success)
```

## The 9 benchmark tasks

| # | name | description |
|---|---|---|
| 01 | fix-bug | Find and fix a bug in existing code |
| 02 | add-function | Add a new function to a module |
| 03 | rename-symbol | Rename a symbol across the codebase |
| 04 | write-script | Write a standalone script |
| 05 | find-answer | Answer a question from code analysis |
| 06 | json-edit | Edit JSON structure |
| 07 | diagnose | Diagnose a problem from logs/output |
| 08 | cli-flag | Add a CLI flag to an existing tool |
| 09 | large-module | Modify a ~630-line module (first Read is a 6K-token turn) |

Task 09 is the hardest — it requires reading a large file in one turn (~6K tokens), making it a stress test for context handling.

## Running a benchmark

```bash
cd ~/dev/claude-local/bench && ./run.sh --label my-config -- \
    --append-system-prompt-file ~/.claude-local/system_prompt.md \
    --exclude-dynamic-system-prompt-sections \
    --autocompact 120832 \
    --tools Bash,Read,Edit,Write,Grep,Glob
```

### Options

| flag | purpose | default |
|---|---|---|
| `--label NAME` | names this configuration (output: `results/NAME.jsonl`) | required |
| `--model M` | model tag | `$CLAUDE_LOCAL_MODEL` or `qwen3-coder:30b` |
| `--port P` | server port | `$CLAUDE_LOCAL_PORT` or 1234 |
| `--tasks a,b,c` | subset of tasks to run | all 9 |
| `--repeat N` | repetitions per task | 1 (use 3+ for statistical significance) |
| `--timeout S` | per-run wall timeout | 420 seconds |
| `--max-turns N` | Claude `--max-turns` limit | 30 |
| `--notes "text"` | free text stored in every row | none |
| `--` then extra flags | passed verbatim to `claude` | none |

## Running through the proxy (with usage logging)

Since 2026-09-09 `run.sh` starts the proxy itself for llama-server (`--proxy auto|1|0`, default auto): the Qwen3.8 and Genesis chat templates reject the `role: system` reminder Claude Code puts inside the conversation, the proxy folds it, and the rows land in `results/proxy/usage-<label>.jsonl`. The steps below are for an Ollama run or an external proxy (add `--proxy 0`).

```bash
# Start proxy in background
PROXY_PORT=1235 USAGE_LOG=/tmp/usage.jsonl python3 ../config/proxy.py &

# Run benchmark through it
./run.sh --label via-proxy --port 1235 -- \
    --append-system-prompt-file ~/.claude-local/system_prompt.md \
    --exclude-dynamic-system-prompt-sections --autocompact 120832 \
    --tools Bash,Read,Edit,Write,Grep,Glob
```

The proxy logs per-turn data (cache hits, tok/s, latency) to the USAGE_LOG file.

## Comparing results

```bash
# Compare multiple configurations side by side
./compare.py baseline tuned-config new-flag

# Output: summary table + per-task pass matrix + config notes
```

Summary columns: label, n (runs), pass count, pass%, wall_mean, wall_med, turns, prompt_tok, cache%, out_tok, ctx.

Per-task matrix shows pass count and mean wall time for each task across all compared labels. `*` indicates at least one run hit the timeout.

## Recorded metrics explained

| metric | what it tells you |
|---|---|
| `wall_s` | wall seconds per task (includes Claude startup ~1-2s) |
| `num_turns` | model round-trips (lower = more efficient prompting) |
| `prompt_tokens` | system prompt + tool schema cost (input + cache_read) |
| `cache_hit_pct` | prefix cache effectiveness within the session |
| `output` | output tokens generated |
| `is_error` / `subtype` | failure mode (timeout, max_turns, check.sh fail, no_json) |

## Interpreting results

**Pass rate:** Should be 100% for stable configs. Drops below 95% suggest regressions or flakiness. With 3 reps per task, < 2/3 pass on any task is a red flag.

**Wall time:** On Ryzen AI MAX+ 395 iGPU with shipped defaults:
- Good: < 25s/task mean
- Acceptable: 25-40s/task
- Poor: > 40s/task (investigate turns/task and cache%)

**Turns per task:** Lower is better. The model wasting turns on meta-tools (ReportFindings, TaskList) or retrying failed commands inflates this number. Benchmarked: core tools ~8.5 turns/task vs full tool list ~9.3 turns/task.

**Cache hit %:** Higher is better. Below 85% suggests the system prompt is changing between turns (dynamic sections not excluded), context overflow, or tool schema bloat. The shipped default achieves ~94%.

**Prompt tokens:** Lower means less system prompt overhead. Core tools ~50K vs full tool list ~148K. If this number is growing across a session, autocompact may be too aggressive or history isn't being managed.

## Benchmark results (reference: 2026-09-05, qwen3-coder:30b Q4_K_M, Ryzen AI MAX+ 395)

| configuration | runs | pass | mean wall/task | cache% |
|---|---|---|---|---|
| Original launcher, 262K ctx, f16 KV | 8 | 100% | 89.8s | 92% |
| + `--exclude-dynamic-system-prompt-sections` | 8 | 100% | 41.9s | 98% |
| + server fit (128K, q8_0 KV) = shipped default | 24 | 96% | 31.2s | 98% |
| Control: server fit without the flag | 16 | 100% | 69.0s | 90% |
| Compact prompt (replace mode) | 24 | 88% | 22.0s | 99% |
| Q8 weights | 8 | 88% | 35.9s | 98% |
| **Shipped default: core tools + all flags** | **27** | **100%** | **21.4s** | **94%** |

Key findings:
- `--exclude-dynamic-system-prompt-sections` is the single biggest lever after tool surface: git status leaves the system prompt, so editing files no longer re-renders it and busts the prefix cache (uncached tokens per turn 1622 → 267).
- Server fit cut model memory 45.6GB → 26.1GB and mean time 42s → 31s at equal pass rate.
- Compact prompt is 30% faster but has lower pass rate (88% vs 100%). Opt-in only.
- With the full tool list, the model spends ~30% of turns on meta-tools. `--tools Bash,Read,Edit,Write,Grep,Glob` removes the sink and shrinks the system prompt from ~15K to ~4.3K tokens.

## Microbenchmarks

For low-level server performance (cold prefill, decode throughput, warm-prefix):

```bash
# Run through proxy
PROXY_PORT=1235 USAGE_LOG=/tmp/micro.jsonl python3 ../config/proxy.py &
./microbench.py --port 1235

# Results in bench/results/micro/
```

Measures:
- **Cold prefill** — first token throughput at various context sizes (2.7K, 10K, 30K, 100K)
- **Decode** — tokens/second during generation
- **Warm prefix** — TTFT when a large cached prefix is already in the KV cache

## Caveats

- Wall time includes Claude startup (~1-2s), so first-turn comparisons are biased
- The first turn of every run is a full prefix-cache miss (~15K system prompt + tool schemas)
- `cache%` measures within-session reuse only, not cross-session
- Run with `--repeat 3` for anything where the difference is under ~20%
- Paths given to Claude flags must be absolute (Claude runs inside the scratch repo)
- GPU temperature affects decode throughput — results from a hot GPU will be slower
- Task 09's first Read is a 6K-token turn, making it a stress test for context handling

## Quick benchmark script

```bash
cd ~/dev/claude-local/bench && ./run.sh --label quick-check --repeat 3 -- \
    --append-system-prompt-file ~/.claude-local/system_prompt.md \
    --exclude-dynamic-system-prompt-sections \
    --autocompact 120832 \
    --tools Bash,Read,Edit,Write,Grep,Glob

# Then compare:
./compare.py quick-check fb-ollama-vk-core
```
