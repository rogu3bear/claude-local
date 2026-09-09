#!/usr/bin/env bash
# One non-interactive turn through the installed launcher and proxy.
# Checks: result text, proxy row written, autocompact/offline banner. ~30s warm.
set -uo pipefail
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG/env" ] && . "$CONFIG/env"
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"; PORT="${CLAUDE_LOCAL_PORT:-1234}"
MODEL="${1:-${CLAUDE_LOCAL_MODEL:-${CLAUDE_LOCAL_DEFAULT_MODEL:-}}}"   # the persisted default model, when the env file names one
# llama-server: the loaded model if any (router mode), else the first listed one.
if [ -z "$MODEL" ] && [ "$BACKEND" = llamaserver ]; then MODEL=$(curl -sf "http://127.0.0.1:${PORT}/models" | jq -r '([.data[] | select(.status.value == "loaded") | .id] + [.data[].id])[0] // empty'); fi
MODEL="${MODEL:-qwen3-coder:30b}"
export PATH="$HOME/.local/bin:$PATH"
tmp=$(mktemp -d); cd "$tmp"
out=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
         -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID \
         CLAUDE_LOCAL_MODEL="$MODEL" timeout 300 claude-local -p 'Reply with exactly the word SMOKEOK and nothing else.' \
         --output-format json --max-turns 2 < /dev/null 2> "$tmp/err")
rc=$?
banner=$(grep -o 'Starting Claude Code:.*' "$tmp/err" | head -1)
result=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)
sess=$(ls -dt "$CONFIG"/run/*/ 2>/dev/null | head -1)
rows=$(wc -l < "$sess/usage.jsonl" 2>/dev/null || echo 0)
port=$(cat "$sess/proxy_port" 2>/dev/null || echo none)
echo "backend: $BACKEND port=$PORT model=$MODEL"
echo "banner : ${banner:-<none>}"
echo "result : ${result:-<none>}  (exit $rc)"
echo "proxy  : port=$port usage_rows=$rows"
ok=1
[ "$rc" -eq 0 ] || ok=0
printf '%s' "$result" | grep -q SMOKEOK || ok=0
[ "$rows" -ge 1 ] || ok=0
printf '%s' "$banner" | grep -q 'autocompact=[0-9]' || ok=0
printf '%s' "$banner" | grep -q 'checkpoint=[0-9]' || ok=0
if [ "$ok" = 1 ]; then echo "SMOKE PASS"; rm -rf "$tmp"; else echo "SMOKE FAIL (stderr follows)"; cat "$tmp/err"; rm -rf "$tmp"; exit 1; fi
