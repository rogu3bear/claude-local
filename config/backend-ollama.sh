# claude-local backend adapter: Ollama.
# Sourced by the launcher. Every backend must define these functions and may
# rely on BASE_URL being set. Swap backends with CLAUDE_LOCAL_BACKEND=<name>
# (file backend-<name>.sh next to this one).
#
#   backend_up                 -> exit 0 if the server answers
#   backend_start              -> best-effort (re)start
#   backend_start_hint         -> print manual start instructions (stderr)
#   backend_models_json FILE   -> write inventory JSON: {"models":[{"name":..,"details":{..}}]}
#   backend_loaded_names       -> print comma-separated names currently in memory
#   backend_context_length M   -> print the runtime context length for loaded model M
#   backend_load M             -> load/pin M (long keep-alive); blocks until loaded
#   backend_unload M           -> evict M from memory

backend_up() { curl -s --max-time 3 -o /dev/null "${BASE_URL}/api/tags"; }

backend_start() {
  if systemctl --user cat ollama.service >/dev/null 2>&1; then
    systemctl --user restart ollama.service >/dev/null 2>&1 || true
    sleep 3
  fi
}

backend_start_hint() {
  echo "  Start it with:  systemctl --user start ollama.service" >&2
  echo "  Or run:         OLLAMA_HOST=127.0.0.1:${PORT} ollama serve" >&2
}

backend_models_json() { curl -s --max-time 10 "${BASE_URL}/api/tags" > "$1"; }

backend_loaded_names() {
  curl -s --max-time 5 "${BASE_URL}/api/ps" | jq -r '[.models[].name] | join(",")' 2>/dev/null
}

backend_context_length() {
  curl -s --max-time 5 "${BASE_URL}/api/ps" \
    | jq -r --arg m "$1" '[.models[] | select(.name == $m)][0].context_length // empty' 2>/dev/null
}

backend_load() {
  curl -s --max-time 900 "${BASE_URL}/api/generate" \
    -d "{\"model\":\"$1\",\"prompt\":\"\",\"stream\":false,\"options\":{\"num_predict\":0},\"keep_alive\":\"2h\"}" \
    >/dev/null 2>&1
}

backend_unload() {
  curl -s --max-time 600 "${BASE_URL}/api/generate" \
    -d "{\"model\":\"$1\",\"prompt\":\"\",\"stream\":false,\"options\":{\"num_predict\":0},\"keep_alive\":0}" \
    >/dev/null 2>&1
}
