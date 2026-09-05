#!/usr/bin/env bash
# Install claude-local by symlinking this checkout into place.
#   ~/.local/bin/claude-local      -> bin/claude-local
#   ~/.local/bin/ollama            -> wrapper: sets OLLAMA_HOST from ~/.claude-local/env, execs ~/.local/ollama/bin/ollama
#   ~/.claude-local/<file>         -> config/<file>   (adapters, picker, proxy, statusline, prompts, settings)
#   ~/.local/bin/llama-server-run  -> bin/llama-server-run  (ExecStart of llama-server.service)
#   ~/.claude-local/bench          -> bench/
#   ~/.config/systemd/user/ollama.service.d/10-claude-local.conf   (copied if changed)
#   ~/.config/systemd/user/ollama.service.d/20-gpu.conf            (copied from systemd/20-gpu-$GPU.conf if GPU given)
# Existing regular files are moved aside as <name>.pre-install. Re-runnable.
# Prints "DROPIN_CHANGED" on stdout when a drop-in was (re)written, so callers
# know a server restart is needed.
#   install.sh [--gpu amd-vulkan|amd-rocm|nvidia|cpu]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
BIN="$HOME/.local/bin"
GPU=""
while [ $# -gt 0 ]; do case "$1" in --gpu) GPU=$2; shift 2;; *) echo "unknown option $1" >&2; exit 2;; esac; done
link() { # $1 = target, $2 = link path
  if [ -e "$2" ] && [ ! -L "$2" ]; then mv "$2" "$2.pre-install"; echo "moved aside $2" >&2; fi
  ln -sfn "$1" "$2"; echo "linked $2 -> $1" >&2
}
mkdir -p "$BIN" "$CONFIG"
link "$HERE/bin/claude-local" "$BIN/claude-local"
link "$HERE/bin/llama-server-run" "$BIN/llama-server-run"
for f in backend-ollama.sh backend-llamaserver.sh picker.py proxy.py statusline.sh system_prompt.md system_prompt_compact.md settings.json; do
  link "$HERE/config/$f" "$CONFIG/$f"
done
link "$HERE/bench" "$CONFIG/bench"
if [ -x "$HOME/.local/ollama/bin/ollama" ] && [ ! -e "$BIN/ollama" -o -L "$BIN/ollama" -o -f "$BIN/ollama" ]; then
  if [ ! -f "$BIN/ollama" ] || grep -q 'claude-local ollama wrapper' "$BIN/ollama" 2>/dev/null; then
    cat > "$BIN/ollama" <<'WRAP'
#!/usr/bin/env bash
# claude-local ollama wrapper: talk to the user-local server on its configured port.
[ -r "${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}/env" ] && . "${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}/env"
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:${CLAUDE_LOCAL_OLLAMA_PORT:-${CLAUDE_LOCAL_PORT:-1234}}}"
exec "$HOME/.local/ollama/bin/ollama" "$@"
WRAP
    chmod +x "$BIN/ollama"; echo "wrote $BIN/ollama (wrapper)" >&2
  fi
fi
changed=0
if systemctl --user cat ollama.service >/dev/null 2>&1; then
  D="$HOME/.config/systemd/user/ollama.service.d"; mkdir -p "$D"
  if ! cmp -s "$HERE/systemd/10-claude-local.conf" "$D/10-claude-local.conf"; then
    cp "$HERE/systemd/10-claude-local.conf" "$D/"; changed=1; echo "installed $D/10-claude-local.conf" >&2
  fi
  if [ -n "$GPU" ]; then
    [ -f "$HERE/systemd/20-gpu-$GPU.conf" ] || { echo "unknown GPU profile $GPU" >&2; exit 2; }
    if ! cmp -s "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf"; then
      cp "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf"; changed=1; echo "installed $D/20-gpu.conf ($GPU)" >&2
    fi
  fi
  [ "$changed" = 1 ] && systemctl --user daemon-reload
fi
if systemctl --user cat llama-server.service >/dev/null 2>&1; then
  D="$HOME/.config/systemd/user/llama-server.service.d"; mkdir -p "$D"
  if ! cmp -s "$HERE/systemd/llama-server/10-claude-local.conf" "$D/10-claude-local.conf"; then
    cp "$HERE/systemd/llama-server/10-claude-local.conf" "$D/"; systemctl --user daemon-reload; echo "installed $D/10-claude-local.conf" >&2; echo "LLAMA_DROPIN_CHANGED"
  fi
fi
if [ "$CONFIG" != "$HOME/.claude-local" ]; then
  echo "note: set statusLine.command in $CONFIG/settings.json to $CONFIG/statusline.sh" >&2
fi
[ "$changed" = 1 ] && echo "DROPIN_CHANGED"
echo "done. try: claude-local" >&2
