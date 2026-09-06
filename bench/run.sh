#!/usr/bin/env bash
# claude-local benchmark runner.
#
#   run.sh --label NAME [options] [-- extra claude flags]
#
# Runs every task in bench/tasks (fresh git repo each time) through
# `claude -p --output-format json` against the LOCAL server, records wall time,
# token usage (incl. cache hits), turns, and whether the task's check.sh passes.
# One JSON line per run is appended to bench/results/<label>.jsonl; the raw
# claude output and stderr go to bench/results/<label>/<task>-<rep>.{json,err}.
#
# Options:
#   --label NAME          required; names this configuration
#   --model M             model tag (default: $CLAUDE_LOCAL_MODEL or qwen3-coder:30b)
#   --port P              server port (default: $CLAUDE_LOCAL_PORT or 1234)
#   --tasks a,b,c         subset of task dir names (default: all)
#   --repeat N            repetitions per task (default 1)
#   --timeout S           per-run wall timeout in seconds (default 420)
#   --max-turns N         claude --max-turns (default 30)
#   --notes "text"        free text stored in every row
#   --                    everything after is passed to claude verbatim
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG_DIR/env" ] && . "$CONFIG_DIR/env"
LABEL=""; MODEL="${CLAUDE_LOCAL_MODEL:-qwen3-coder:30b}"; PORT="${CLAUDE_LOCAL_PORT:-1234}"
TASKS=""; REPEAT=1; TIMEOUT=420; MAXTURNS=30; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL=$2; shift 2;; --model) MODEL=$2; shift 2;; --port) PORT=$2; shift 2;;
    --tasks) TASKS=$2; shift 2;; --repeat) REPEAT=$2; shift 2;; --timeout) TIMEOUT=$2; shift 2;;
    --max-turns) MAXTURNS=$2; shift 2;; --notes) NOTES=$2; shift 2;;
    --) shift; break;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac
done
EXTRA=("$@")
[ -n "$LABEL" ] || { echo "--label is required" >&2; exit 2; }
BASE_URL="http://localhost:${PORT}"
RES="$HERE/results"; OUT="$RES/$LABEL"; WORK="$HERE/work/$LABEL"
mkdir -p "$OUT" "$WORK"
ROWS="$RES/$LABEL.jsonl"

# Server-side snapshot so a row is self-describing.
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"
. "$CONFIG_DIR/backend-${BACKEND}.sh"
ctx_len=$(backend_context_length "$MODEL")
if [ "$BACKEND" = ollama ]; then
  server_env=$(systemctl --user show ollama.service -p Environment 2>/dev/null | sed 's/^Environment=//' | tr ' ' '\n' | grep -E '^OLLAMA_(CONTEXT_LENGTH|KV_CACHE_TYPE|NUM_PARALLEL|FLASH_ATTENTION)=' | paste -sd' ')
else
  server_env=$( { systemctl --user show llama-server.service -p Environment 2>/dev/null | sed 's/^Environment=//' | tr ' ' '\n' | grep -E '^LLAMA_ARG_(CTX_SIZE|CACHE_TYPE_K|UBATCH)='; grep -E '^LLAMA_(DEVICE|ARG_SPEC_TYPE|ARG_SPEC_DRAFT_N_MAX)=' "$CONFIG_DIR/llama-server.env" 2>/dev/null; } | paste -sd' ')
fi
flags_str=$(printf '%q ' "${EXTRA[@]}")
stack_str=$("$HERE/stack.sh" 2>/dev/null || echo "")

# Environment for the child claude: isolated config, local server, no nesting markers.
run_claude() { # cwd is the task dir; args: prompt
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID \
      CLAUDE_CONFIG_DIR="$CONFIG_DIR" ANTHROPIC_BASE_URL="$BASE_URL" ANTHROPIC_AUTH_TOKEN=local \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
      timeout --signal=INT --kill-after=15 "$TIMEOUT" \
      claude -p "$1" --model "$MODEL" --output-format json --max-turns "$MAXTURNS" \
             --settings "{\"env\":{\"ANTHROPIC_BASE_URL\":\"${BASE_URL}\",\"ANTHROPIC_AUTH_TOKEN\":\"local\"}}" \
             --dangerously-skip-permissions "${EXTRA[@]}" < /dev/null
}

if [ -n "$TASKS" ]; then task_list=${TASKS//,/ }; else task_list=$(ls "$HERE/tasks"); fi
echo "[bench] label=$LABEL backend=$BACKEND model=$MODEL ctx=${ctx_len:-?} server[$server_env] flags[$flags_str]" >&2
total=0; passed=0
for task in $task_list; do
  tdir="$HERE/tasks/$task"; [ -d "$tdir" ] || { echo "no such task $task" >&2; continue; }
  for rep in $(seq 1 "$REPEAT"); do
    w="$WORK/$task-$rep"; rm -rf "$w"; mkdir -p "$w"
    ( cd "$w" && bash "$tdir/setup.sh" && git init -q && git add -A \
        && git -c user.email=bench@local -c user.name=bench commit -qm init ) || { echo "setup failed: $task" >&2; continue; }
    prompt=$(cat "$tdir/prompt.txt")
    t0=$(date +%s.%N)
    ( cd "$w" && run_claude "$prompt" ) > "$OUT/$task-$rep.json" 2> "$OUT/$task-$rep.err"
    rc=$?
    t1=$(date +%s.%N)
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    timed_out=false; [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && timed_out=true
    ok=false; ( cd "$w" && bash "$tdir/check.sh" ) >/dev/null 2>&1 && ok=true
    row=$(jq -c --arg label "$LABEL" --arg task "$task" --argjson rep "$rep" --argjson ok "$ok" \
             --argjson wall "$wall" --argjson rc "$rc" --argjson timed_out "$timed_out" \
             --arg model "$MODEL" --arg ctx "${ctx_len:-}" --arg server "$server_env" --arg flags "$flags_str" \
             --arg notes "$NOTES" --arg ts "$(date -Is)" --arg backend "$BACKEND" --arg stack "$stack_str" '
      def n(x): (x // 0);
      {label:$label, backend:$backend, task:$task, rep:$rep, ok:$ok, wall_s:$wall, rc:$rc, timed_out:$timed_out,
       num_turns:n(.num_turns), duration_ms:n(.duration_ms), duration_api_ms:n(.duration_api_ms),
       input:n(.usage.input_tokens), cache_read:n(.usage.cache_read_input_tokens),
       cache_creation:n(.usage.cache_creation_input_tokens), output:n(.usage.output_tokens),
       is_error:(.is_error // ($rc!=0)), subtype:(.subtype // "none"),
       model:$model, ctx_len:$ctx, server:$server, flags:$flags, notes:$notes, stack:$stack, ts:$ts}
      | .prompt_tokens = (.input + .cache_read)
      | .cache_hit_pct = (if .prompt_tokens>0 then (100*.cache_read/.prompt_tokens|floor) else 0 end)' \
          "$OUT/$task-$rep.json" 2>/dev/null)
    if [ -z "$row" ]; then  # claude produced no JSON (crash/timeout)
      row=$(jq -nc --arg label "$LABEL" --arg task "$task" --argjson rep "$rep" --argjson ok "$ok" --argjson wall "$wall" \
              --argjson rc "$rc" --argjson timed_out "$timed_out" --arg model "$MODEL" --arg ctx "${ctx_len:-}" \
              --arg server "$server_env" --arg flags "$flags_str" --arg notes "$NOTES" --arg ts "$(date -Is)" \
              '{label:$label,task:$task,rep:$rep,ok:$ok,wall_s:$wall,rc:$rc,timed_out:$timed_out,num_turns:0,duration_ms:0,duration_api_ms:0,input:0,cache_read:0,cache_creation:0,output:0,is_error:true,subtype:"no_json",model:$model,ctx_len:$ctx,server:$server,flags:$flags,notes:$notes,ts:$ts,prompt_tokens:0,cache_hit_pct:0}')
    fi
    echo "$row" >> "$ROWS"
    total=$((total+1)); [ "$ok" = true ] && passed=$((passed+1))
    printf '[bench] %-18s rep%d  %s  %6ss  turns=%-3s prompt=%-7s cache=%3s%%  out=%s\n' "$task" "$rep" \
      "$([ "$ok" = true ] && echo PASS || echo FAIL)" "$wall" "$(jq -r .num_turns <<<"$row")" \
      "$(jq -r .prompt_tokens <<<"$row")" "$(jq -r .cache_hit_pct <<<"$row")" "$(jq -r .output <<<"$row")" >&2
  done
done
echo "[bench] $LABEL: $passed/$total passed" >&2
