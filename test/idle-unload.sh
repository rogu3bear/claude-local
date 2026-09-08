#!/usr/bin/env bash
# claude-local: idle-unload ("dehydrate") test for the usage proxy (llama-server router mode).
#
#   1. adds a throwaway preset [probe-idle] (same GGUF as a free loaded preset) and loads it
#   2. starts proxy.py standalone with a 5s idle threshold and a ledger that says probe-idle
#      was last used an hour ago
#   3. sends one turn on the free preset, so that one is the proxy's own model (protected)
#   4. expects, within 60s, probe-idle checkpointed to slots/ and unloaded, and the own model
#      still resident
#   5. removes the preset, its slot file and the INI section; reloads the router
# Skips (exit 0) when llama-server is not up, no free loaded preset exists, or loading one
# more model would evict a resident one (LLAMA_ARG_MODELS_MAX). ~60s.
set -uo pipefail
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG/env" ] && . "$CONFIG/env"
PORT="${CLAUDE_LOCAL_LLAMASERVER_PORT:-1244}"
BASE="http://127.0.0.1:${PORT}"
INI="${LLAMA_ARG_MODELS_PRESET:-$CONFIG/llama-models.ini}"
SLOTS="$CONFIG/slots"
PROBE=probe-idle
curl -sf --max-time 3 -o /dev/null "$BASE/health" || { echo "SKIP: llama-server not up on $PORT"; exit 0; }

inuse=$(for d in "$CONFIG"/run/*/; do p=$(basename "$d"); [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && cat "$d/session_model" 2>/dev/null && echo; done)
MODEL=$(curl -sf "$BASE/models" | jq -r --arg inuse "$inuse" '
  ($inuse | split("\n")) as $busy
  | [.data[] | select(.status.value == "loaded") | .id as $id | select(($busy | index($id)) == null)] | .[0].id // empty')
[ -n "$MODEL" ] || { echo "SKIP: no free loaded preset to run the session turn on"; exit 0; }
nload=$(curl -sf "$BASE/models" | jq '[.data[] | select(.status.value == "loaded")] | length')
maxm=$(systemctl --user show llama-server.service -p Environment 2>/dev/null | grep -oE 'LLAMA_ARG_MODELS_MAX=[0-9]+' | cut -d= -f2)
if [ "$nload" -ge "${maxm:-4}" ]; then echo "SKIP: $nload resident models = LLAMA_ARG_MODELS_MAX; a probe load would evict one"; exit 0; fi
GGUF=$(awk -v s="[$MODEL]" '$0==s{f=1;next} /^\[/{f=0} f && /^model[ \t]*=/{sub(/^model[ \t]*=[ \t]*/,""); print; exit}' "$INI")
[ -n "$GGUF" ] || { echo "SKIP: no model = line for $MODEL in $INI"; exit 0; }

tmp=$(mktemp -d); PP=""
cp "$INI" "$tmp/ini.bak"
cleanup() {
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  curl -s --max-time 60 -X POST "$BASE/models/unload" -H 'content-type: application/json' -d "{\"model\":\"$PROBE\"}" >/dev/null 2>&1
  cp "$tmp/ini.bak" "$INI"; curl -s --max-time 10 "$BASE/models?reload=1" >/dev/null 2>&1
  rm -f "$SLOTS/claude-local-$PROBE.bin"; rm -rf "$tmp"
}
trap cleanup EXIT

printf '\n[%s]\nmodel = %s\nreasoning = off\n' "$PROBE" "$GGUF" >> "$INI"
curl -sf --max-time 10 "$BASE/models?reload=1" >/dev/null
curl -sf --max-time 30 -X POST "$BASE/models/load" -H 'content-type: application/json' -d "{\"model\":\"$PROBE\"}" >/dev/null || { echo "FAIL: could not load $PROBE"; exit 1; }
for _ in $(seq 1 300); do curl -sf "$BASE/models" | jq -e --arg m "$PROBE" '.data[] | select(.id == $m) | .status.value == "loaded"' >/dev/null && break; sleep 1; done
curl -sf "$BASE/models" | jq -e --arg m "$PROBE" '.data[] | select(.id == $m) | .status.value == "loaded"' >/dev/null || { echo "FAIL: $PROBE did not load"; exit 1; }
echo "probe  : $PROBE loaded ($(basename "$GGUF"))"

printf '{"%s": %s}\n' "$PROBE" "$(( $(date +%s) - 3600 ))" > "$tmp/last_use.json"
PROXY_PORT=1250 PROXY_PORT_FILE="$tmp/port" UPSTREAM_PORT="$PORT" USAGE_LOG="$tmp/usage.jsonl" \
  PROXY_BACKEND=llamaserver PROXY_CHECKPOINT_S=0 PROXY_IDLE_UNLOAD_S=5 PROXY_STATE_DIR="$tmp" SLOTS_DIR="$SLOTS" \
  python3 "$CONFIG/proxy.py" 2> "$tmp/proxy.log" &
PP=$!
for _ in $(seq 1 25); do [ -s "$tmp/port" ] && break; sleep 0.2; done
PX=$(cat "$tmp/port" 2>/dev/null) || { echo "FAIL: proxy did not start"; cat "$tmp/proxy.log"; exit 1; }

body=$(jq -cn --arg m "$MODEL" '{model: $m, max_tokens: 4, messages: [{role: "user", content: "Reply with exactly: OK"}]}')
rc=$(curl -s --max-time 600 -X POST "http://127.0.0.1:${PX}/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$body" -o /dev/null -w '%{http_code}')
echo "turn   : HTTP $rc on $MODEL (this session's model)"

ok=1
for _ in $(seq 1 60); do
  st=$(curl -sf "$BASE/models" | jq -r --arg m "$PROBE" '.data[] | select(.id == $m) | .status.value')
  [ "$st" = unloaded ] && break; sleep 1
done
if [ "$st" = unloaded ] && [ -f "$SLOTS/claude-local-$PROBE.bin" ]; then
  echo "idle   : $(grep -o "$PROBE unused.*" "$tmp/proxy.log" | tail -1)"
  echo "saved  : $(grep -o "checkpoint $PROBE.*" "$tmp/proxy.log" | tail -1)"
else echo "FAIL   : $PROBE is '$st' after 60s, slot file $([ -f "$SLOTS/claude-local-$PROBE.bin" ] && echo present || echo missing)"; ok=0; fi
own=$(curl -sf "$BASE/models" | jq -r --arg m "$MODEL" '.data[] | select(.id == $m) | .status.value')
[ "$own" = loaded ] && echo "kept   : $MODEL still loaded" || { echo "FAIL   : own model $MODEL is $own"; ok=0; }
if [ "$ok" = 1 ]; then echo "IDLE-UNLOAD PASS"; else echo "IDLE-UNLOAD FAIL (proxy log follows)"; cat "$tmp/proxy.log"; exit 1; fi
