#!/usr/bin/env bash
# Overnight chain C (2026-09-06, approved "make it productive"): serving-config A/Bs on the NEW default
# (Qwen3.6-35B-A3B + MTP), adapter-os gates, Ollama fallback pull, results commit. Scratch port 1246 only;
# llama-server.service (1244) and ollama (1234) are never restarted. Each step logs FAILED and continues.
set -u
CL=$HOME/dev/claude-local; RES=$CL/bench/results; MICRO=$RES/micro; OUT=$MICRO/micro-q36-cfg.jsonl
Q36=$HOME/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf; UP=$HOME/ai/llama.cpp/build-vulkan/bin; HIP=$HOME/ai/llama.cpp/build-hip/bin
STACK=$("$CL/bench/stack.sh" 2>/dev/null); log(){ echo "[chainC] $(date +%H:%M:%S) $*"; }
BASE=(-m "$Q36" --alias qwen3.6:35b --chat-template-kwargs '{"enable_thinking":false}' -c 131072 -np 1 -fa on --jinja --metrics --slots --cache-reuse 256 --no-webui --host 127.0.0.1 --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.5 --spec-type draft-mtp)
CLAUDE_FLAGS=(--append-system-prompt-file "$HOME/.claude-local/system_prompt.md" --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash,Read,Edit,Write,Grep,Glob)
P=""; stop(){ [ -n "$P" ] && { kill "$P" 2>/dev/null; wait "$P" 2>/dev/null; }; P=""; sleep 3; }; trap stop EXIT
up(){ # $1 bin, rest args → starts on 1246, waits; returns 1 on failure
  local bin=$1; shift; local t0=$(date +%s)
  "$bin" --port 1246 "$@" > "$RES/server-1246-chainC.log" 2>&1 & P=$!
  local i; for i in $(seq 1 900); do curl -sf --max-time 2 -o /dev/null http://127.0.0.1:1246/health && { log "  server ready in $(( $(date +%s)-t0 )) s"; return 0; }; kill -0 "$P" 2>/dev/null || { log "  FAILED: server died: $(tail -3 "$RES/server-1246-chainC.log" | tr '\n' ' ' | cut -c1-200)"; P=""; return 1; }; sleep 1; done; log "  FAILED: not ready"; return 1; }
mb(){ local label=$1 sizes=$2 nout=$3 reps=$4; (cd "$CL" && python3 bench/microbench.py --backend llamacpp --url http://127.0.0.1:1246 --calibrate-url http://127.0.0.1:1246 --label "$label" --model qwen3.6:35b --sizes "$sizes" --nout "$nout" --reps "$reps" --warm --out "$OUT") 2>&1 | tail -1 | sed 's/^/   /'; }
variant(){ # $1 label $2 bin $3.. server args ; runs the standard microbench set
  local label=$1 bin=$2; shift 2; log "STEP $label"
  up "$bin" "$@" || return 1
  mb "$label" 2700,10000,30000 128,512 3; mb "$label" 100000 128 2; stop; log "  $label done"; }
b=$(cat /sys/class/drm/card1/device/gpu_busy_percent); [ "$b" -lt 20 ] || { log "CHAIN FAILED: GPU busy ${b}%"; exit 1; }
log "START $STACK"

# background: Ollama fallback pull (network only; skipped if the library lacks the tag)
( OLLAMA_HOST=127.0.0.1:1234 timeout 5400 "$HOME/.local/ollama/bin/ollama" pull qwen3.6:35b > "$RES/ollama-pull-qwen36.log" 2>&1; echo "exit=$?" >> "$RES/ollama-pull-qwen36.log" ) &
PULL=$!

# ── A/Bs on the new default (reference: q36-mtp2 rows already in micro-q36.jsonl: ub2048, q8 KV, mmap, n-max 2)
variant q36-nmax3      "$UP/llama-server" "${BASE[@]}" --spec-draft-n-max 3 -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048
variant q36-ub512      "$UP/llama-server" "${BASE[@]}" --spec-draft-n-max 2 -ctk q8_0 -ctv q8_0 -b 2048 -ub 512
variant q36-kvq4       "$UP/llama-server" "${BASE[@]}" --spec-draft-n-max 2 -ctk q4_0 -ctv q4_0 -b 2048 -ub 2048
variant q36-nomap      "$UP/llama-server" "${BASE[@]}" --spec-draft-n-max 2 -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 --no-mmap
log "  kernel KFD/eviction warnings so far this boot: $(journalctl -k -b --no-pager | grep -c 'hogged CPU')"
variant q36-hip-mtp2   "$HIP/llama-server" "${BASE[@]}" --spec-draft-n-max 2 -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 -dev ROCm0

# ── full bench of the n-max 3 variant (the one most likely to move task time) ──────────────
log "STEP fullbench q36-mtp3-core"
if up "$UP/llama-server" "${BASE[@]}" --spec-draft-n-max 3 -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 -dev Vulkan0; then
  (cd "$CL/bench" && CLAUDE_LOCAL_BACKEND=llamaserver ./run.sh --label q36-mtp3-core --port 1246 --model qwen3.6:35b --repeat 3 --timeout 600 --notes "Qwen3.6 MTP n-max 3, otherwise the new default; $STACK" -- "${CLAUDE_FLAGS[@]}") 2>&1 | grep -E "passed$" | sed 's/^/   /'
  stop
fi

# ── adapter-os gates on the new firmware (CPU; GPU only via the crate tests) ──────────────
log "STEP adapter-os gates"
( cd "$HOME/dev/adapter-os" && export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" && git fetch -q --prune 2>/dev/null; echo "branch $(git branch --show-current) @ $(git rev-parse --short HEAD); dirty=$(git status --porcelain | wc -l); behind=$(git rev-list --count HEAD..origin/main 2>/dev/null)"
  t0=$(date +%s); MLX_FORCE_STUB=1 timeout 2400 cargo clippy --workspace --lib --bins --exclude adapteros-lora-mlx-ffi --quiet -- -D warnings > "$RES/adapter-os-clippy.log" 2>&1; echo "clippy exit=$? ($(( $(date +%s)-t0 )) s, errors=$(grep -cE '^error' "$RES/adapter-os-clippy.log"))"
  t0=$(date +%s); timeout 2400 cargo test -p adapteros-code-context -p adapteros-planner -p adapteros-cli > "$RES/adapter-os-test.log" 2>&1; echo "tests exit=$? ($(( $(date +%s)-t0 )) s): $(grep -E '^test result' "$RES/adapter-os-test.log" | awk '{p+=$4; f+=$6} END{print p" passed, "f" failed"}')"
  echo "dirty after=$(git status --porcelain | wc -l)" ) 2>&1 | sed 's/^/   /'

# ── Ollama pull result ──────────────────────────────────────────────────────────────────
wait $PULL 2>/dev/null; log "ollama pull: $(tail -2 "$RES/ollama-pull-qwen36.log" | tr '\n' ' ' | cut -c1-160)"

# ── summary + commit of tonight's results (results + chain scripts only; no README edits) ──
S="$RES/OVERNIGHT-2026-09-06-c.md"
{ echo "# Overnight chain C — serving-config A/Bs on the new default (Qwen3.6 + MTP), $(date +%F)"; echo; echo "Stack: $STACK"; echo
  echo '## Microbench (reference row q36-mtp2 = new default: n-max 2, ub 2048, q8 KV, mmap, Vulkan)'; echo '```'
  (cd "$CL" && python3 bench/microbench.py --summary "$MICRO/micro-q36.jsonl" "$OUT" 2>&1 | grep -E "^label|q36-(mtp2|nmax3|ub512|kvq4|nomap|hip-mtp2) "); echo '```'; echo
  echo '## Full bench'; echo '```'; (cd "$CL/bench" && ./compare.py fb-ollama-vk-core q36-mtp2-core q36-mtp3-core 2>&1 | head -6); echo '```'; echo
  echo "## adapter-os gates"; echo '```'; grep -E "branch|clippy exit|tests exit|dirty after" "$RES/overnight-2026-09-06.log" | tail -4; echo '```'; echo
  echo "Ollama pull qwen3.6:35b: $(tail -1 "$RES/ollama-pull-qwen36.log")"; echo "GPU resets this boot: $(journalctl -k -b --no-pager | grep -cE 'ring .* timeout|wedged')"
} > "$S"
log "summary written: $S"
( cd "$CL" && git add bench/overnight-2026-09-06.sh bench/overnight-2026-09-06-b.sh bench/overnight-2026-09-06-c.sh bench/results/OVERNIGHT-2026-09-06.md bench/results/OVERNIGHT-2026-09-06-c.md bench/results/micro/micro-fork.jsonl bench/results/micro/micro-q36.jsonl bench/results/micro/micro-q36-cfg.jsonl bench/results/q36-*.jsonl bench/results/q36-*/ bench/results/switch-smoke.jsonl bench/results/switch-smoke/ bench/results/smoke-q36.jsonl bench/results/smoke-q36/ 2>/dev/null
  git -c user.email=founders@mlnavigator.com -c user.name=mln-dev commit -q -m "bench: overnight 2026-09-06 — Qwen3.6-35B-A3B + MTP vs Coder; fork depth kernels; serving-config A/Bs

Qwen3.6-35B-A3B UD-Q4_K_XL (MTP-embedded) + draft-mtp n=2 on upstream llama-server: 12.3 s/task
vs 21.4 s Ollama+Coder default, 27/27 both; fork v0.7.4.1 stacks to 10.4 s but its server drops
Write-tool content (05-find-answer 5/9 empty ANSWER.txt; 0/6 upstream). Chain C: n-max, ubatch,
KV type, mmap, HIP A/Bs on the new default. Results + chain scripts only; README not touched.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CgoQo6oiK2Ra19F2Ryp8Zb" && echo "   committed $(git rev-parse --short HEAD)" || echo "   commit skipped/failed" ) 2>&1 | sed 's/^/   /'
log "CHAIN C DONE"
