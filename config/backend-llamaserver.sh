# claude-local backend adapter: llama.cpp llama-server (upstream), run as the
# user unit llama-server.service (see systemd/llama-server/ and
# ~/.claude-local/llama-server.env). Sourced by the launcher; uses BASE_URL,
# PORT, CONFIG_DIR. Contract as in backend-ollama.sh.
#
# Differences from Ollama worth knowing:
#  * one model per server; the request's model field is ignored and the
#    server reports its --alias (LLAMA_ARG_ALIAS), so keep the alias equal to
#    the name Claude uses.
#  * /health answers 503 for the whole load: "not 200" means WAIT, never restart.
#  * "unload" saves the slot's prompt cache to disk and leaves the server up;
#    "load" restores it, so a fresh session starts warm even after a restart.
#    CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD=1 also stops the unit (frees ~26GB).

_ls_unit=llama-server.service
_ls_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
_ls_slotfile() { echo "claude-local-$(_ls_slug "$1").bin"; }

backend_probe_path() { echo /health; }

backend_up() { curl -sf --max-time 3 -o /dev/null "${BASE_URL}/health"; }

backend_wait_ready() { # $1 = seconds (default 600): a cold 17GB load takes a while
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
  echo "  Config:         ~/.claude-local/llama-server.env (device, model, draft), then restart the unit" >&2
}

# /v1/models -> {"data":[{"id":..,"meta":{size,n_params,...}}]} normalised to the launcher's inventory shape.
backend_models_json() {
  curl -sf --max-time 10 "${BASE_URL}/v1/models" | jq '{models: [.data[] | {
      name: .id, size: (.meta.size // 0),
      details: { parameter_size: (if .meta.n_params then ((.meta.n_params/1e9*10|round)/10|tostring)+"B" else "" end),
                 quantization_level: ((.meta.ftype // "") | tostring) } }]}' > "$1" 2>/dev/null \
    || echo '{"models":[]}' > "$1"
}

backend_loaded_names() {
  backend_up || return 0
  if curl -sf --max-time 3 "${BASE_URL}/props" | jq -e '.is_sleeping == true' >/dev/null 2>&1; then return 0; fi
  curl -sf --max-time 3 "${BASE_URL}/v1/models" | jq -r '[.data[].id] | join(",")' 2>/dev/null
}

backend_context_length() {
  curl -sf --max-time 5 "${BASE_URL}/props" | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null
}

# Restore the saved prompt cache for this model if one exists (warm first turn).
backend_load() {
  local alias f rc
  alias=$(curl -sf --max-time 5 "${BASE_URL}/props" | jq -r '.model_alias // empty' 2>/dev/null)
  [ -n "$alias" ] && [ "$alias" != "$1" ] && echo "[local] warn: server serves '$alias', not '$1' (single-model server; edit llama-server.env)" >&2
  f=$(_ls_slotfile "$1")
  if [ -f "$CONFIG_DIR/slots/$f" ]; then
    rc=$(curl -s --max-time 300 -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/slots/0?action=restore" \
           -H 'content-type: application/json' -d "{\"filename\":\"$f\"}")
    if [ "$rc" != "200" ]; then echo "[local] warn: stale prompt-cache file $f (HTTP $rc); removing" >&2; rm -f "$CONFIG_DIR/slots/$f"; fi
  fi
  return 0
}

# Persist the slot's prompt cache; the server stays up unless asked to stop.
backend_unload() {
  local f out; f=$(_ls_slotfile "$1")
  out=$(curl -s --max-time 600 -X POST "${BASE_URL}/slots/0?action=save" -H 'content-type: application/json' -d "{\"filename\":\"$f\"}" 2>/dev/null)
  printf '%s' "$out" | jq -r '"[local] prompt cache saved: \(.n_saved // .n_tokens // "?") tokens, \(((.n_written // 0)/1e6|floor)) MB, \(.timings.save_ms // .t_ms // "?") ms"' 2>/dev/null >&2 || true
  if [ "${CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD:-0}" = 1 ]; then systemctl --user stop "$_ls_unit" 2>/dev/null || true; fi
}

backend_unload_keeps_model() { [ "${CLAUDE_LOCAL_LLAMA_STOP_ON_UNLOAD:-0}" != 1 ]; }
