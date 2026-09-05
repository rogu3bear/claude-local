#!/usr/bin/env bash
# Install claude-local by symlinking this checkout into place.
#   ~/.local/bin/claude-local      -> bin/claude-local
#   ~/.claude-local/<file>         -> config/<file>   (adapters, picker, proxy, statusline, prompts, settings)
#   ~/.claude-local/bench          -> bench/
#   ~/.config/systemd/user/ollama.service.d/10-claude-local.conf  (copied, then daemon-reload)
# Existing regular files are moved aside as <name>.pre-install. Re-runnable.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
BIN="$HOME/.local/bin"
link() { # $1 = target, $2 = link path
  if [ -e "$2" ] && [ ! -L "$2" ]; then mv "$2" "$2.pre-install"; echo "moved aside $2"; fi
  ln -sfn "$1" "$2"; echo "linked $2 -> $1"
}
mkdir -p "$BIN" "$CONFIG"
link "$HERE/bin/claude-local" "$BIN/claude-local"
for f in backend-ollama.sh backend-llamaserver.sh picker.py proxy.py statusline.sh system_prompt.md system_prompt_compact.md settings.json; do
  link "$HERE/config/$f" "$CONFIG/$f"
done
link "$HERE/bench" "$CONFIG/bench"
if systemctl --user cat ollama.service >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/systemd/user/ollama.service.d"
  if ! cmp -s "$HERE/systemd/10-claude-local.conf" "$HOME/.config/systemd/user/ollama.service.d/10-claude-local.conf"; then
    cp "$HERE/systemd/10-claude-local.conf" "$HOME/.config/systemd/user/ollama.service.d/"
    systemctl --user daemon-reload
    echo "installed systemd drop-in; restart the server to apply: systemctl --user restart ollama.service"
  fi
fi
# settings.json points the statusline at $CONFIG/statusline.sh; patch the path if the config dir is not the default.
if [ "$CONFIG" != "$HOME/.claude-local" ]; then
  echo "note: set statusLine.command in $CONFIG/settings.json to $CONFIG/statusline.sh"
fi
echo "done. try: claude-local"
