# claude-local backend adapter: llama.cpp llama-server (upstream), run as the user
# unit llama-server.service (see systemd/llama-server/, ~/.claude-local/llama-server.env
# and ~/.claude-local/llama-models.ini). Sourced by the launcher; uses BASE_URL,
# PORT, CONFIG_DIR. Contract as in backend-ollama.sh.
#
# Router mode (default since 2026-09-07): the server starts without a model and every
# INI section is a model it loads on demand. /models lists them with a status
# (unloaded | loading | loaded, plus failed:true), /models/load and /models/unload
# switch, and up to LLAMA_ARG_MODELS_MAX models stay resident (3 in the drop-in;
# one more load evicts the least recently used). POST requests name the model in
# the JSON body, GET endpoints in ?model=. The pre-router single-model layout
# (LLAMA_ARG_MODEL in the env file) still works: /models has no status field there
# and the request's model field is ignored.
#
# Either way:
#  * /health is 503 for the whole load in single-model mode ("not 200" means WAIT,
#    never restart); in router mode it is 200 as soon as the router is up and a
#    model's readiness is its status in /models.
#  * "unload" saves the slot's prompt cache to disk first and "load" restores it, so
#    a fresh session starts warm even after an unload or a server restart. Router
#    mode then frees the memory; single-model mode leaves the model resident unless
#    CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD=1 stops the unit.

_ls_unit=llama-server.service
_ls_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
_ls_slotfile() { echo "claude-local-$(_ls_slug "$1").bin"; }
_ls_uri() { jq -rn --arg m "$1" '$m|@uri'; }
_ls_models() { curl -sf --max-time 10 "${BASE_URL}/models"; }
_ls_is_router_json() { printf '%s' "$1" | jq -e '.data[0].status != null' >/dev/null 2>&1; }
_ls_router() { _ls_is_router_json "$(_ls_models)"; }
# status of one preset: "loaded" | "loading" | "unloaded" | "unloaded failed" | "" (unknown name)
_ls_status() { _ls_models | jq -r --arg m "$1" '.data[] | select(.id==$m) | (.status.value // "unloaded") + (if .status.failed then " failed" else "" end)' 2>/dev/null; }
_ls_ini() { echo "${LLAMA_ARG_MODELS_PRESET:-$CONFIG_DIR/llama-models.ini}"; }
_ls_ini_model_path() { # $1 = preset name -> its model = line (an unloaded preset reports no path)
  awk -v s="[$1]" '$0==s{f=1;next} /^\[/{f=0} f && /^model[ \t]*=/{sub(/^model[ \t]*=[ \t]*/,""); print; exit}' "$(_ls_ini)" 2>/dev/null
}

backend_probe_path() { echo /health; }

backend_up() { curl -sf --max-time 3 -o /dev/null "${BASE_URL}/health"; }

backend_wait_ready() { # $1 = seconds (default 600): a cold single-model load takes a while
  local i; for i in $(seq 1 "${1:-600}"); do backend_up && return 0; sleep 1; done; return 1
}

backend_start() {
  if systemctl --user cat "$_ls_unit" >/dev/null 2>&1; then
    systemctl --user is-active --quiet "$_ls_unit" || systemctl --user start "$_ls_unit" 2>/dev/null || true
    backend_wait_ready 600
  else
    return 1
  fi
}

backend_start_hint() {
  echo "  Start it with:  systemctl --user start llama-server.service" >&2
  echo "  Logs:           journalctl --user -u llama-server.service -e" >&2
  echo "  Config:         ~/.claude-local/llama-server.env (device, INI path), ~/.claude-local/llama-models.ini (models), then restart the unit" >&2
}

# Inventory in the launcher's shape: {models:[{name,size,details:{parameter_size,quantization_level}}]}.
# Router: one entry per preset, size from the GGUF on disk (runtime meta exists only while loaded).
backend_models_json() {
  local raw; raw=$(_ls_models) || { echo '{"models":[]}' > "$1"; return; }
  if _ls_is_router_json "$raw"; then
    printf '%s' "$raw" | jq -r '.data[].id' | while IFS= read -r n; do
      p=$(_ls_ini_model_path "$n"); s=$(stat -c %s "$p" 2>/dev/null || echo 0)
      jq -cn --arg n "$n" --arg p "$p" --argjson s "$s" '{name:$n, path:$p, size:$s}'
    done | jq -s '{models: [.[] | {name, size, details: {
        parameter_size: ((.path | try capture("(?<p>[0-9]+(\\.[0-9]+)?B)(?![A-Za-z])") | .p) // ""),
        quantization_level: ((.path | split("/") | last | try capture("(?<q>(UD-)?(I?Q[0-9](_[A-Z0-9]+)*|BF16|F16|F32))") | .q) // "") }}]}' > "$1" 2>/dev/null \
      || echo '{"models":[]}' > "$1"
  else
    printf '%s' "$raw" | jq '{models: [.data[] | {
        name: .id, size: (.meta.size // 0),
        details: { parameter_size: (if .meta.n_params then ((.meta.n_params/1e9*10|round)/10|tostring)+"B" else "" end),
                   quantization_level: ((.meta.ftype // "") | tostring) } }]}' > "$1" 2>/dev/null \
      || echo '{"models":[]}' > "$1"
  fi
}

backend_loaded_names() {
  backend_up || return 0
  local raw; raw=$(_ls_models) || return 0
  if _ls_is_router_json "$raw"; then
    printf '%s' "$raw" | jq -r '[.data[] | select(.status.value == "loaded") | .id] | join(",")' 2>/dev/null
  else
    if curl -sf --max-time 3 "${BASE_URL}/props" | jq -e '.is_sleeping == true' >/dev/null 2>&1; then return 0; fi
    printf '%s' "$raw" | jq -r '[.data[].id] | join(",")' 2>/dev/null
  fi
}

backend_context_length() { # $1 = model
  curl -sf --max-time 5 "${BASE_URL}/props?model=$(_ls_uri "$1")" | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null
}

_ls_slot_save() { # $1 = model: persist slot 0's prompt cache under the model's slot file
  local f out; f=$(_ls_slotfile "$1")
  out=$(curl -s --max-time 600 -X POST "${BASE_URL}/slots/0?action=save" -H 'content-type: application/json' -d "{\"filename\":\"$f\",\"model\":\"$1\"}" 2>/dev/null)
  printf '%s' "$out" | jq -r '"[local] prompt cache saved for '"$1"': \(.n_saved // .n_tokens // "?") tokens, \(((.n_written // 0)/1e6|floor)) MB, \(.timings.save_ms // .t_ms // "?") ms"' 2>/dev/null >&2 || true
}

# Load (router: via /models/load, waiting for status=loaded; every other resident model
# has its prompt cache saved first, so whichever one the router evicts once
# LLAMA_ARG_MODELS_MAX is reached restarts warm) and restore this model's saved prompt
# cache if one exists (warm first turn).
backend_load() {
  local m=$1 st i f rc other alias
  if _ls_router; then
    st=$(_ls_status "$m")
    [ -n "$st" ] || { echo "[local] error: '$m' is not a preset in $(_ls_ini) (run llama-models-ini, or check ${BASE_URL}/models)" >&2; return 1; }
    if [ "$st" != loaded ]; then
      for other in $(backend_loaded_names | tr ',' ' '); do [ "$other" != "$m" ] && _ls_slot_save "$other"; done
      curl -sf --max-time 30 -o /dev/null -X POST "${BASE_URL}/models/load" -H 'content-type: application/json' -d "{\"model\":\"$m\"}" \
        || { echo "[local] error: /models/load refused '$m'" >&2; return 1; }
      for i in $(seq 1 900); do
        st=$(_ls_status "$m")
        case "$st" in
          loaded) break ;;
          *failed*) echo "[local] error: '$m' failed to load; see: journalctl --user -u $_ls_unit -e" >&2; return 1 ;;
        esac
        sleep 1
      done
      [ "$st" = loaded ] || { echo "[local] error: '$m' not loaded after 900s (status: $st)" >&2; return 1; }
    fi
  else
    alias=$(curl -sf --max-time 5 "${BASE_URL}/props" | jq -r '.model_alias // empty' 2>/dev/null)
    [ -n "$alias" ] && [ "$alias" != "$m" ] && echo "[local] warn: server serves '$alias', not '$m' (single-model server; edit llama-server.env)" >&2
  fi
  f=$(_ls_slotfile "$m")
  if [ -f "$CONFIG_DIR/slots/$f" ]; then
    rc=$(curl -s --max-time 300 -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/slots/0?action=restore" \
           -H 'content-type: application/json' -d "{\"filename\":\"$f\",\"model\":\"$m\"}")
    if [ "$rc" != "200" ]; then echo "[local] warn: stale prompt-cache file $f (HTTP $rc); removing" >&2; rm -f "$CONFIG_DIR/slots/$f"; fi
  fi
  return 0
}

# Persist the prompt cache, then (router) free the model's memory. The unit stays up
# unless CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD=1.
backend_unload() {
  local m=$1 i
  _ls_slot_save "$m"
  if _ls_router; then
    curl -sf --max-time 60 -o /dev/null -X POST "${BASE_URL}/models/unload" -H 'content-type: application/json' -d "{\"model\":\"$m\"}" \
      || echo "[local] warn: /models/unload failed for $m" >&2
    for i in $(seq 1 60); do [ "$(_ls_status "$m")" = unloaded ] && break; sleep 1; done
  fi
  if [ "${CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD:-0}" = 1 ]; then systemctl --user stop "$_ls_unit" 2>/dev/null || true; fi
}

backend_unload_keeps_model() { [ "${CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD:-0}" != 1 ] && ! _ls_router; }
