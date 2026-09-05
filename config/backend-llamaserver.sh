# claude-local backend adapter: llama.cpp llama-server.
# STATUS: written against the llama.cpp server HTTP API docs; NOT yet exercised
# on this machine (no llama-server binary installed). Use with
# CLAUDE_LOCAL_BACKEND=llamaserver and CLAUDE_LOCAL_PORT=<llama-server port>.
#
# Why it exists: llama-server can persist its prompt cache to disk
# (--slot-save-path DIR, then POST /slots/0?action=save|restore), which removes
# the cold-start reprocessing on resume that Ollama cannot avoid. It also needs
# an Anthropic-compatible /v1/messages endpoint for Claude Code; check your
# llama.cpp build provides it (recent builds do) before switching.
#
# Suggested launch:
#   llama-server -m MODEL.gguf --port 1234 -c 131072 -fa on -ctk q8_0 -ctv q8_0 \
#       --slot-save-path ~/.claude-local/slots --cache-reuse 256
#
# llama-server serves one model per process (or several with --models router
# mode); load/unload are therefore no-ops here.

backend_up() { curl -s --max-time 3 -o /dev/null "${BASE_URL}/health"; }

backend_start() { :; }   # no service manager integration yet

backend_start_hint() {
  echo "  Start llama-server on port ${PORT}, e.g.:" >&2
  echo "    llama-server -m MODEL.gguf --port ${PORT} -c 131072 -fa on -ctk q8_0 -ctv q8_0 --slot-save-path ~/.claude-local/slots" >&2
}

# /v1/models -> {"data":[{"id":"..."}]}; normalise to the launcher's inventory shape.
backend_models_json() {
  curl -s --max-time 10 "${BASE_URL}/v1/models" \
    | jq '{models: [.data[] | {name: .id, details: {}}]}' > "$1" 2>/dev/null \
    || echo '{"models":[]}' > "$1"
}

backend_loaded_names() {
  curl -s --max-time 5 "${BASE_URL}/v1/models" | jq -r '[.data[].id] | join(",")' 2>/dev/null
}

# /props exposes the runtime context size.
backend_context_length() {
  curl -s --max-time 5 "${BASE_URL}/props" \
    | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null
}

# Single-model server: nothing to load. Warm the prompt cache slot from disk if
# a saved slot exists (best effort).
backend_load() {
  curl -s --max-time 60 -X POST "${BASE_URL}/slots/0?action=restore" \
    -H 'content-type: application/json' -d '{"filename":"claude-local.bin"}' >/dev/null 2>&1 || true
}

# Save the slot so the next session resumes warm, then leave the server up.
backend_unload() {
  curl -s --max-time 60 -X POST "${BASE_URL}/slots/0?action=save" \
    -H 'content-type: application/json' -d '{"filename":"claude-local.bin"}' >/dev/null 2>&1 || true
}
