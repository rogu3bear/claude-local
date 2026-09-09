#!/usr/bin/env bash
# Install claude-local by symlinking this checkout into place.
#   ~/.local/bin/claude-local      -> bin/claude-local
#   ~/.local/bin/ollama            -> wrapper: sets OLLAMA_HOST from ~/.claude-local/env, execs ~/.local/ollama/bin/ollama
#   ~/.claude-local/<file>         -> config/<file>   (adapters, picker, proxy, web search MCP, statusline, prompts, settings)
#   ~/.local/bin/llama-server-run  -> bin/llama-server-run  (ExecStart of llama-server.service)
#   ~/.local/bin/llama-models-ini  -> bin/llama-models-ini  (append new GGUFs to the router INI)
#   ~/.local/bin/claude-local-doctor -> bin/claude-local-doctor (read-only diagnosis of the stack)
#   ~/.local/bin/claude-local-drain  -> bin/claude-local-drain  (unload models no session uses)
#   ~/.config/systemd/user/claude-local-drain.{service,timer}     (copied if changed; timer enabled)
#   git config core.hooksPath .githooks   (in this checkout: the commit-message contract, .githooks/commit-msg)
#   ~/.claude-local/bench          -> bench/
#   ~/.claude-local/skills         -> skills/   (Claude Code reads them only when Skill is in CLAUDE_LOCAL_TOOLS)
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
link "$HERE/bin/llama-models-ini" "$BIN/llama-models-ini"
link "$HERE/bin/claude-local-doctor" "$BIN/claude-local-doctor"
link "$HERE/bin/claude-local-drain" "$BIN/claude-local-drain"
link "$HERE/bin/claude-local-init" "$BIN/claude-local-init"
for f in backend-ollama.sh backend-llamaserver.sh picker.py proxy.py clog.py mcp-websearch.py hook-urlguard.py hook-audit.py hook-guard.py statusline.sh system_prompt.md system_prompt_compact.md settings.json; do
  link "$HERE/config/$f" "$CONFIG/$f"
done
link "$HERE/bench" "$CONFIG/bench"
link "$HERE/skills" "$CONFIG/skills"     # loaded by Claude Code only when Skill is in CLAUDE_LOCAL_TOOLS
if [ -x "$HOME/.local/ollama/bin/ollama" ] && [ ! -e "$BIN/ollama" -o -L "$BIN/ollama" -o -f "$BIN/ollama" ]; then
  # Rewrite our own wrapper (any vintage: the marker line, or the user-local binary path); never a foreign script.
  if [ ! -f "$BIN/ollama" ] || grep -qE 'claude-local ollama wrapper|\.local/ollama/bin/ollama' "$BIN/ollama" 2>/dev/null; then
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
# Drain timer: unload models no session uses (bin/claude-local-drain), every 2 minutes.
U="$HOME/.config/systemd/user"; mkdir -p "$U"; dchanged=0
for f in claude-local-drain.service claude-local-drain.timer; do
  if ! cmp -s "$HERE/systemd/drain/$f" "$U/$f"; then cp "$HERE/systemd/drain/$f" "$U/$f"; dchanged=1; echo "installed $U/$f" >&2; fi
done
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  [ "$dchanged" = 1 ] && systemctl --user daemon-reload
  systemctl --user is-active --quiet claude-local-drain.timer || { systemctl --user enable --now claude-local-drain.timer 2>/dev/null && echo "enabled claude-local-drain.timer (models unload when no session uses them)" >&2; }
fi
if [ "$CONFIG" != "$HOME/.claude-local" ]; then
  echo "note: set statusLine.command in $CONFIG/settings.json to $CONFIG/statusline.sh and the hook commands to $CONFIG/hook-urlguard.py / $CONFIG/hook-audit.py" >&2
fi
# The commit-message contract (.githooks/commit-msg) runs only in a clone that points git at it.
if git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1 && [ "$(git -C "$HERE" config --get core.hooksPath 2>/dev/null)" != .githooks ]; then
  git -C "$HERE" config core.hooksPath .githooks && echo "set core.hooksPath=.githooks (commit-message contract active in this checkout)" >&2
fi
[ "$changed" = 1 ] && echo "DROPIN_CHANGED"
echo "done. try: claude-local" >&2
