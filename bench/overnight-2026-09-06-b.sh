#!/usr/bin/env bash
# Follow-up: stack the fork (depth kernels) under Qwen3.6-35B-A3B + MTP. Port 1247; no default unit touched.
set -u
CL=$HOME/dev/claude-local; RES=$CL/bench/results; MICRO=$RES/micro
Q36=$HOME/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf; FORK=$HOME/ai/strix-fork/vulkan
STACK=$("$CL/bench/stack.sh" 2>/dev/null); log(){ echo "[chainB] $(date +%H:%M:%S) $*"; }
COMMON=(-c 131072 -np 1 -fa on -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 --jinja --metrics --slots --cache-reuse 256 --no-webui --host 127.0.0.1 -dev Vulkan0)
Q36_SAMPLING=(--temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 --presence-penalty 1.5)
CLAUDE_FLAGS=(--append-system-prompt-file "$HOME/.claude-local/system_prompt.md" --exclude-dynamic-system-prompt-sections --autocompact 120832 --tools Bash,Read,Edit,Write,Grep,Glob)
b=$(cat /sys/class/drm/card1/device/gpu_busy_percent); [ "$b" -lt 20 ] || { log "CHAIN FAILED: GPU busy ${b}%"; exit 1; }
log "STEP B1 fork + Qwen3.6 + MTP: server"
"$FORK/llama-server" --port 1247 -m "$Q36" --alias qwen3.6:35b --chat-template-kwargs '{"enable_thinking":false}' "${COMMON[@]}" "${Q36_SAMPLING[@]}" --spec-type draft-mtp --spec-draft-n-max 2 > "$RES/server-1247.log" 2>&1 & P=$!
trap 'kill $P 2>/dev/null; wait $P 2>/dev/null' EXIT
for i in $(seq 1 900); do curl -sf --max-time 2 -o /dev/null http://127.0.0.1:1247/health && break; kill -0 $P 2>/dev/null || { log "CHAIN FAILED: fork server died (MTP or Qwen3.6 unsupported in fork base?)"; tail -8 "$RES/server-1247.log"; exit 1; }; sleep 1; done
curl -sf --max-time 2 -o /dev/null http://127.0.0.1:1247/health || { log "CHAIN FAILED: not ready"; exit 1; }
log "server up: $(curl -s http://127.0.0.1:1247/props | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("build_info"), "spec", d["default_generation_settings"]["params"].get("speculative.types"))')"
log "STEP B2 microbench q36-fork-mtp2"
(cd "$CL" && python3 bench/microbench.py --backend llamacpp --url http://127.0.0.1:1247 --calibrate-url http://127.0.0.1:1247 --label q36-fork-mtp2 --model qwen3.6:35b --sizes 2700,10000,30000 --nout 128,512 --reps 3 --warm --out "$MICRO/micro-q36.jsonl") 2>&1 | tail -2 | sed 's/^/   /'
(cd "$CL" && python3 bench/microbench.py --backend llamacpp --url http://127.0.0.1:1247 --calibrate-url http://127.0.0.1:1247 --label q36-fork-mtp2 --model qwen3.6:35b --sizes 100000 --nout 128 --reps 2 --warm --out "$MICRO/micro-q36.jsonl") 2>&1 | tail -2 | sed 's/^/   /'
log "STEP B3 full bench q36-fork-mtp2-core"
(cd "$CL/bench" && CLAUDE_LOCAL_BACKEND=llamaserver ./run.sh --label q36-fork-mtp2-core --port 1247 --model qwen3.6:35b --repeat 3 --timeout 600 --notes "Qwen3.6-35B-A3B UD-Q4_K_XL (MTP-embedded) on strix-halo-llamacpp v0.7.4.1 (b10659-5d8c07b4, bundled RADV 26.3-devel), non-thinking, draft-mtp n-max 2; $STACK" -- "${CLAUDE_FLAGS[@]}") 2>&1 | grep -E "^\[bench\]" | sed 's/^/   /'
kill $P 2>/dev/null; wait $P 2>/dev/null; trap - EXIT
S="$RES/OVERNIGHT-2026-09-06.md"
{ echo; echo "## Follow-up: fork + Qwen3.6 + MTP (chain B, $(date +%H:%M))"; echo '```'; (cd "$CL/bench" && ./compare.py fb-ollama-vk-core q36-vk-core q36-mtp2-core q36-fork-mtp2-core 2>&1 | head -8); echo '```'; echo '```'
  (cd "$CL" && python3 bench/microbench.py --summary "$MICRO/micro-q36.jsonl" 2>&1 | grep -E "^label|q36-"); echo '```'; } >> "$S"
log "CHAIN B DONE"
