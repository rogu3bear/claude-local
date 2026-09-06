#!/usr/bin/env bash
# Overnight comparison chain, 2026-09-06 (approved). Touches NO default unit: fork server on 1245,
# Qwen3.6 server on 1246; llama-server.service (1244) and ollama (1234) stay as they are.
# Gates: GPU idle at start; model size+sha256 verified; smoke task must use tools before any long run.
set -u
CL=$HOME/dev/claude-local; RES=$CL/bench/results; MICRO=$RES/micro; mkdir -p "$MICRO"
CODER=$HOME/.ollama/models/blobs/sha256-1194192cf2a187eb02722edcc3f77b11d21f537048ce04b67ccf8ba78863006a
Q36=$HOME/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf
Q36_SIZE=22853663008; Q36_SHA=55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1
FORK=$HOME/ai/strix-fork/vulkan; UP=$HOME/ai/llama.cpp/build-vulkan/bin
STACK=$("$CL/bench/stack.sh" 2>/dev/null)
log(){ echo "[chain] $(date +%H:%M:%S) $*"; }
SRV_PID=""
COMMON=(-c 131072 -np 1 -fa on -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 --jinja --metrics --slots --cache-reuse 256 --no-webui --host 127.0.0.1 -dev Vulkan0)
CODER_SAMPLING=(--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --repeat-penalty 1.05)      # B's config
Q36_SAMPLING=(--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.5)       # Qwen3.6 non-thinking (card/Unsloth)
Q36_ARGS=(-m "$Q36" --alias qwen3.6:35b --chat-template-kwargs '{"enable_thinking":false}' "${COMMON[@]}" "${Q36_SAMPLING[@]}")
CLAUDE_FLAGS=(--append-system-prompt-file "$HOME/.claude-local/system_prompt.md" --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash,Read,Edit,Write,Grep,Glob)

start_server(){ local bin=$1 port=$2; shift 2
  "$bin" --port "$port" "$@" > "$RES/server-$port.log" 2>&1 & SRV_PID=$!
  local i; for i in $(seq 1 900); do
    curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:$port/health" && { log "server $port ready ($(basename "$bin") pid $SRV_PID)"; return 0; }
    kill -0 "$SRV_PID" 2>/dev/null || { log "CHAIN FAILED: server on $port died:"; tail -6 "$RES/server-$port.log"; return 1; }
    sleep 1; done
  log "CHAIN FAILED: server on $port not ready after 900 s"; return 1; }
stop_server(){ [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; }; SRV_PID=""; sleep 3; }
trap 'stop_server' EXIT
micro(){ local url=$1 label=$2 model=$3 out=$4 sizes=$5 nout=$6 reps=$7
  (cd "$CL" && python3 bench/microbench.py --backend llamacpp --url "$url" --calibrate-url "$url" --label "$label" --model "$model" \
     --sizes "$sizes" --nout "$nout" --reps "$reps" --warm --out "$out") 2>&1 | tail -4 | sed 's/^/   /'; }
fullbench(){ local label=$1 port=$2 model=$3 notes=$4
  (cd "$CL/bench" && CLAUDE_LOCAL_BACKEND=llamaserver ./run.sh --label "$label" --port "$port" --model "$model" --repeat 3 --timeout 600 \
     --notes "$notes" -- "${CLAUDE_FLAGS[@]}") 2>&1 | grep -E "^\[bench\]" | sed 's/^/   /'; }
gpu_busy(){ cat /sys/class/drm/card1/device/gpu_busy_percent; }

log "START stack: $STACK"
b=$(gpu_busy); [ "$b" -lt 20 ] || { log "CHAIN FAILED: GPU busy ${b}% at start"; exit 1; }

# ── 1. fork v0.7.4.1 on the Coder model (independent of the download) ──────────────────
log "STEP 1 fork+Coder microbench"
start_server "$FORK/llama-server" 1245 -m "$CODER" --alias qwen3-coder:30b "${COMMON[@]}" "${CODER_SAMPLING[@]}" || exit 1
micro http://127.0.0.1:1245 fork-vk qwen3-coder:30b "$MICRO/micro-fork.jsonl" 2700,10000,30000 128,512 3
micro http://127.0.0.1:1245 fork-vk qwen3-coder:30b "$MICRO/micro-fork.jsonl" 100000 128 2
stop_server; log "STEP 1 done"

# ── wait for the verified model ─────────────────────────────────────────────────────────
log "waiting for Qwen3.6 download ($(stat -c%s "$Q36" 2>/dev/null || echo 0)/$Q36_SIZE bytes)"
for i in $(seq 1 1080); do [ -f "$Q36" ] && [ "$(stat -c%s "$Q36")" = "$Q36_SIZE" ] && break; sleep 10; done
[ "$(stat -c%s "$Q36" 2>/dev/null)" = "$Q36_SIZE" ] || { log "CHAIN FAILED: download incomplete ($(stat -c%s "$Q36" 2>/dev/null || echo 0) bytes)"; exit 1; }
sleep 10; got=$(sha256sum "$Q36" | cut -d' ' -f1); [ "$got" = "$Q36_SHA" ] || { log "CHAIN FAILED: sha256 $got != $Q36_SHA"; exit 1; }
log "model verified (sha256 ok)"

# ── 2. Qwen3.6 baseline server + smoke gate ─────────────────────────────────────────────
log "STEP 2 Qwen3.6 baseline: smoke task"
start_server "$UP/llama-server" 1246 "${Q36_ARGS[@]}" || exit 1
rm -f "$RES/smoke-q36.jsonl"
(cd "$CL/bench" && CLAUDE_LOCAL_BACKEND=llamaserver ./run.sh --label smoke-q36 --port 1246 --model qwen3.6:35b --tasks 01-fix-bug --repeat 1 --timeout 600 --notes "smoke" -- "${CLAUDE_FLAGS[@]}") 2>&1 | grep -E "^\[bench\]" | sed 's/^/   /'
row=$(tail -1 "$RES/smoke-q36.jsonl" 2>/dev/null); rc=$(jq -r .rc <<<"$row"); turns=$(jq -r .num_turns <<<"$row"); ok=$(jq -r .ok <<<"$row"); to=$(jq -r .timed_out <<<"$row")
log "smoke: rc=$rc turns=$turns ok=$ok timed_out=$to"
if [ "$rc" != 0 ] || [ "${turns:-0}" -lt 2 ] || [ "$to" = true ]; then log "CHAIN FAILED: smoke gate (template/tool-calling) — see $RES/smoke-q36/01-fix-bug-1.err"; tail -15 "$RES/smoke-q36/01-fix-bug-1.err" | sed 's/^/   /'; exit 1; fi
log "smoke gate passed"

# ── 3. Qwen3.6 baseline microbench ──────────────────────────────────────────────────────
log "STEP 3 Qwen3.6 baseline microbench"
micro http://127.0.0.1:1246 q36-vk qwen3.6:35b "$MICRO/micro-q36.jsonl" 2700,10000,30000 128,512 3
micro http://127.0.0.1:1246 q36-vk qwen3.6:35b "$MICRO/micro-q36.jsonl" 100000 128 2
stop_server; log "STEP 3 done"

# ── 4. Qwen3.6 + MTP microbench, then the full bench on the same server ────────────────
log "STEP 4 Qwen3.6 + MTP (n-max 2) microbench"
start_server "$UP/llama-server" 1246 "${Q36_ARGS[@]}" --spec-type draft-mtp --spec-draft-n-max 2 || exit 1
micro http://127.0.0.1:1246 q36-mtp2 qwen3.6:35b "$MICRO/micro-q36.jsonl" 2700,10000,30000 128,512 3
micro http://127.0.0.1:1246 q36-mtp2 qwen3.6:35b "$MICRO/micro-q36.jsonl" 100000 128 2
log "STEP 5 full bench q36-mtp2-core"
fullbench q36-mtp2-core 1246 qwen3.6:35b "Qwen3.6-35B-A3B UD-Q4_K_XL (MTP-embedded), non-thinking, draft-mtp n-max 2; $STACK"
stop_server; log "STEP 5 done"

# ── 6. full bench, Qwen3.6 without MTP (isolates model quality from MTP speed) ──────────
log "STEP 6 full bench q36-vk-core"
start_server "$UP/llama-server" 1246 "${Q36_ARGS[@]}" || exit 1
fullbench q36-vk-core 1246 qwen3.6:35b "Qwen3.6-35B-A3B UD-Q4_K_XL, non-thinking, no speculation; $STACK"
stop_server; log "STEP 6 done"

# ── 7. summary ──────────────────────────────────────────────────────────────────────────
S="$RES/OVERNIGHT-2026-09-06.md"
{ echo "# Overnight comparison 2026-09-06"; echo; echo "Stack: $STACK"; echo; echo '## Full bench (bench/compare.py)'; echo '```'
  (cd "$CL/bench" && ./compare.py fb-ls-vk-core intdot-vk-core q36-mtp2-core q36-vk-core 2>&1); echo '```'; echo
  echo '## Microbench (tok/s; microbench.py --summary)'; echo '```'
  (cd "$CL" && python3 bench/microbench.py --summary "$MICRO/micro-2026-09-05.jsonl" "$MICRO/micro-intdot.jsonl" "$MICRO/micro-fork.jsonl" "$MICRO/micro-q36.jsonl" 2>&1); echo '```'
  echo; echo "Device-loss / ring-timeout lines this boot: $(journalctl -k -b --no-pager 2>/dev/null | grep -cE 'ring .* timeout|wedged')"
} > "$S"
log "summary written: $S"
log "CHAIN DONE"
