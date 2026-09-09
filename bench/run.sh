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
#   --proxy auto|1|0      run config/proxy.py in front of the server (default auto: on for
#                         llamaserver, off for ollama). llama-server's chat templates for Qwen3.8
#                         and the Genesis build of Qwen3.6 raise "System message must be at the
#                         beginning" on the role:system message Claude Code puts inside the
#                         conversation, so a direct run fails every turn (2026-09-09, genesis-core:
#                         0/4, 180 s of retries per task); the proxy folds it away, strips the
#                         <total_tokens> counter, rewrites claude-* model names and writes per-turn
#                         usage rows to results/proxy/usage-<label>.jsonl. Its turns also keep the
#                         shared last-use ledger warm. Independently of the proxy, the runner
#                         registers itself as a live session (run/<pid>/session_model) for the
#                         whole run: claude-local-drain never touches a live session's model, and
#                         without that it unloaded the bench model every two minutes on 2026-09-09
#                         (the ledger is written only by the launcher and the proxy).
#   --                    everything after is passed to claude verbatim
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_DIR="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG_DIR/env" ] && . "$CONFIG_DIR/env"
LABEL=""; MODEL="${CLAUDE_LOCAL_MODEL:-qwen3-coder:30b}"; PORT="${CLAUDE_LOCAL_PORT:-1234}"
TASKS=""; REPEAT=1; TIMEOUT=420; MAXTURNS=30; NOTES=""; PROXY="${BENCH_PROXY:-auto}"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL=$2; shift 2;; --model) MODEL=$2; shift 2;; --port) PORT=$2; shift 2;;
    --tasks) TASKS=$2; shift 2;; --repeat) REPEAT=$2; shift 2;; --timeout) TIMEOUT=$2; shift 2;;
    --max-turns) MAXTURNS=$2; shift 2;; --notes) NOTES=$2; shift 2;; --proxy) PROXY=$2; shift 2;;
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

# A live session for the drain timer: run/<pid>/session_model names the model this run uses, so
# claude-local-drain leaves it resident until the runner exits (the launcher does the same for
# a session; a run dir whose pid is gone is reaped by the next launch).
mkdir -p "$CONFIG_DIR/run/$$"; printf '%s' "$MODEL" > "$CONFIG_DIR/run/$$/session_model"; date +%s > "$CONFIG_DIR/run/$$/session_start"
trap 'rm -rf "$CONFIG_DIR/run/$$"' EXIT
# The usage proxy in front of the server (see --proxy above). Claude Code talks to it exactly as
# a launcher session does; the ledger lives in the real run dir so a bench turn counts as use.
PROXY_PID=""
if [ "$PROXY" = 1 ] || { [ "$PROXY" = auto ] && [ "$BACKEND" = llamaserver ]; }; then
  mkdir -p "$RES/proxy" "$CONFIG_DIR/run"; rm -f "$WORK/proxy_port"
  PROXY_PORT=$((PORT + 100)) PROXY_PORT_FILE="$WORK/proxy_port" UPSTREAM_PORT="$PORT" \
    USAGE_LOG="$RES/proxy/usage-$LABEL.jsonl" PROXY_BACKEND="$BACKEND" PROXY_SESSION_MODEL="$MODEL" \
    PROXY_CHECKPOINT_S=0 PROXY_IDLE_UNLOAD_S=0 PROXY_STATE_DIR="$CONFIG_DIR/run" SLOTS_DIR="$CONFIG_DIR/slots" \
    CLAUDE_LOCAL_LOG_DIR="$RES/proxy" CLAUDE_LOCAL_SESSION_DIR="$WORK" \
    python3 "$CONFIG_DIR/proxy.py" 2>> "$RES/proxy/proxy-$LABEL.log" &
  PROXY_PID=$!
  for _ in $(seq 1 30); do [ -s "$WORK/proxy_port" ] && break; kill -0 "$PROXY_PID" 2>/dev/null || break; sleep 0.2; done
  pp=$(cat "$WORK/proxy_port" 2>/dev/null)
  if [ -n "$pp" ]; then
    BASE_URL="http://localhost:${pp}"
    echo "[bench] proxy :$pp -> :$PORT (usage rows results/proxy/usage-$LABEL.jsonl, log results/proxy/proxy-$LABEL.log)" >&2
  else
    echo "[bench] proxy did not start (results/proxy/proxy-$LABEL.log); connecting directly" >&2
    kill "$PROXY_PID" 2>/dev/null; PROXY_PID=""
  fi
  trap '[ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null; rm -rf "$CONFIG_DIR/run/$$"' EXIT
fi

# Environment for the child claude: isolated config, local server, no nesting markers.
run_claude() { # cwd is the task dir; args: prompt
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_BRIDGE_SESSION_ID \
      CLAUDE_CONFIG_DIR="$CONFIG_DIR" ANTHROPIC_BASE_URL="$BASE_URL" ANTHROPIC_AUTH_TOKEN=local \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
      CLAUDE_CODE_TOTAL_TOKENS_REMINDER="${CLAUDE_CODE_TOTAL_TOKENS_REMINDER:-off}" \
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
    # Ollama reports a context length only for a loaded model: a run that started cold sampled an
    # empty ctx_len above, so sample again once the first task has loaded it (every row carries it).
    [ -n "$ctx_len" ] || ctx_len=$(backend_context_length "$MODEL")
    t1=$(date +%s.%N)
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    timed_out=false; [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ] && timed_out=true
    ok=false; ( cd "$w" && bash "$tdir/check.sh" ) >/dev/null 2>&1 && ok=true
    # Claude Code keeps a transcript per working directory in $CONFIG_DIR/projects/<physical cwd with
    # every non-alphanumeric character turned into "-"> (verified 2026-09-08 against a symlinked cwd
    # with "." and "_" in its name). A scratch repo is never resumed, and 463 of these had
    # piled up from bench runs by then: drop this run's right away. Only ever deletes under projects/.
    tname=$(cd "$w" 2>/dev/null && pwd -P | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
    [ -n "$tname" ] && [ -d "$CONFIG_DIR/projects/$tname" ] && rm -rf "$CONFIG_DIR/projects/$tname"
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
