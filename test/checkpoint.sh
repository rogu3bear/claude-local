#!/usr/bin/env bash
# claude-local: checkpoint + resume test for the usage proxy (llama-server router mode).
#
#   1. picks a preset no live launcher is using (a loaded one if possible) and backs up its slot file
#   2. starts proxy.py standalone with a 3s checkpoint delay
#   3. sends one Messages request with a ~4K-token system prompt; expects a checkpoint within 10s
#   4. SIGKILLs that model's instance; the router reports it failed
#   5. sends the continuation (turn 1 + its reply + a new user message), which is what Claude Code
#      sends next; expects the proxy to reload + restore and the usage row to show a warm prefix
#      (cache_pct >= 80) instead of a cold prefill. The continuation matters: every preset here is
#      a hybrid (SSM + attention) model whose restored state can be extended but not rewound, so
#      re-sending an identical prompt would reprocess everything (see config/proxy.py).
#   6. puts the original slot file back and stops the proxy
# Skips (exit 0) when llama-server is not up or every preset is in use. ~40s.
set -uo pipefail
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG/env" ] && . "$CONFIG/env"
PORT="${CLAUDE_LOCAL_LLAMASERVER_PORT:-1244}"
BASE="http://127.0.0.1:${PORT}"
SLOTS="$CONFIG/slots"
curl -sf --max-time 3 -o /dev/null "$BASE/health" || { echo "SKIP: llama-server not up on $PORT"; exit 0; }

# presets some live claude-local session is on: never kill those
inuse=$(for d in "$CONFIG"/run/*/; do p=$(basename "$d"); [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null && cat "$d/session_model" 2>/dev/null && echo; done)
MODEL=$(curl -sf "$BASE/models" | jq -r --arg inuse "$inuse" '
  ($inuse | split("\n")) as $busy
  | [.data[] | select(.status != null) | .id as $id | select(($busy | index($id)) == null)]
  | (map(select(.status.value == "loaded")) + .) | .[0].id // empty')
[ -n "$MODEL" ] || { echo "SKIP: every preset is in use by a live session"; exit 0; }
slug=$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '_'); SLOT="$SLOTS/claude-local-$slug.bin"
tmp=$(mktemp -d); PP=""
[ -f "$SLOT" ] && cp "$SLOT" "$tmp/slot.bak"
cleanup() {
  [ -n "$PP" ] && kill "$PP" 2>/dev/null
  if [ -f "$tmp/slot.bak" ]; then mv "$tmp/slot.bak" "$SLOT"; else rm -f "$SLOT"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

PROXY_PORT=1250 PROXY_PORT_FILE="$tmp/port" UPSTREAM_PORT="$PORT" USAGE_LOG="$tmp/usage.jsonl" \
  PROXY_BACKEND=llamaserver PROXY_CHECKPOINT_S=3 PROXY_STATE_DIR="$tmp" SLOTS_DIR="$SLOTS" \
  python3 "$CONFIG/proxy.py" 2> "$tmp/proxy.log" &
PP=$!
for _ in $(seq 1 25); do [ -s "$tmp/port" ] && break; sleep 0.2; done
PX=$(cat "$tmp/port" 2>/dev/null) || { echo "FAIL: proxy did not start"; cat "$tmp/proxy.log"; exit 1; }

sys=$(python3 -c "print('The quick brown fox jumps over the lazy dog while the proxy keeps the cache warm. ' * 260)")
body=$(jq -cn --arg s "$sys" --arg m "$MODEL" \
  '{model: $m, max_tokens: 8, system: $s, messages: [{role: "user", content: "Reply with exactly: OK"}]}')
turn() { # $1 = name, $2 = body
  curl -s --max-time 900 -X POST "http://127.0.0.1:${PX}/v1/messages" -H 'content-type: application/json' \
       -H 'anthropic-version: 2023-06-01' -H 'x-api-key: local' -d "$2" -o "$tmp/resp.$1" -w '%{http_code}'; }
row() { tail -1 "$tmp/usage.jsonl" 2>/dev/null | jq -c '{prompt, cache_pct, ttft_ms}'; }
echo "model  : $MODEL via proxy :$PX"
ok=1
rc=$(turn 1 "$body"); echo "turn 1 : HTTP $rc $(row)"; [ "$rc" = 200 ] || ok=0
reply=$(jq -r '[.content[]? | select(.type == "text") | .text] | join("")' "$tmp/resp.1" 2>/dev/null)
body2=$(jq -cn --arg s "$sys" --arg m "$MODEL" --arg a "${reply:-OK}" \
  '{model: $m, max_tokens: 8, system: $s, messages: [{role: "user", content: "Reply with exactly: OK"}, {role: "assistant", content: $a}, {role: "user", content: "Reply with exactly: OK again"}]}')

for _ in $(seq 1 12); do grep -q "checkpoint $MODEL" "$tmp/proxy.log" && break; sleep 1; done
if grep -q "checkpoint $MODEL" "$tmp/proxy.log" && [ -f "$SLOT" ]; then
  echo "saved  : $(grep -o "checkpoint $MODEL.*" "$tmp/proxy.log" | tail -1)"
else echo "FAIL   : no checkpoint within 12s"; ok=0; fi

iport=$(curl -sf "$BASE/models" | jq -r --arg m "$MODEL" '.data[] | select(.id == $m) | .status.args | .[index("--port") + 1] // empty')
ipid=$(pgrep -f "llama-server --host .* --port ${iport} " | head -1)
if [ -n "$ipid" ]; then kill -9 "$ipid"; echo "killed : instance pid $ipid (port $iport)"; else echo "FAIL   : no instance for $MODEL"; ok=0; fi
for _ in $(seq 1 10); do
  st=$(curl -sf "$BASE/models" | jq -r --arg m "$MODEL" '.data[] | select(.id == $m) | .status.value')
  [ "$st" != loaded ] && break; sleep 1
done
echo "router : $MODEL is $st"

rc=$(turn 2 "$body2"); r2=$(row); echo "turn 2 : HTTP $rc $r2 (continuation)"
if grep -q "restored $MODEL" "$tmp/proxy.log"; then echo "resume : $(grep -o "restored $MODEL.*" "$tmp/proxy.log" | tail -1)"
else echo "FAIL   : proxy did not restore"; ok=0; fi
[ "$rc" = 200 ] || ok=0
[ "$(printf '%s' "$r2" | jq -r '.cache_pct // 0')" -ge 80 ] 2>/dev/null || { echo "FAIL   : retry was not warm (cache_pct < 80)"; ok=0; }
if [ "$ok" = 1 ]; then echo "CHECKPOINT PASS"; else echo "CHECKPOINT FAIL (proxy log follows)"; cat "$tmp/proxy.log"; exit 1; fi
