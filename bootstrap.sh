#!/usr/bin/env bash
# claude-local bootstrap: one command from a fresh Linux user account to a
# working `claude-local`.
#
#   ./bootstrap.sh [--dry-run] [--no-smoke] [--model NAME] [--port N]
#                  [--gpu amd-vulkan|amd-rocm|nvidia|cpu]   (default amd-vulkan)
#
# Steps (each idempotent; re-running is safe and does not restart a healthy server):
#   1. deps      git curl jq python3 systemd tar zstd; node+npm (nvm if absent); claude CLI
#   2. ollama    user-local install into ~/.local/ollama if missing
#                (ROCm bundle only for --gpu amd-rocm)
#   3. service   ~/.config/systemd/user/ollama.service (generic) + drop-ins
#                10-claude-local.conf (context/KV/slots/flash attention) and
#                20-gpu.conf (profile); an existing unit is adopted, not overwritten
#   4. model     pull MODEL if not present
#   5. harness   ./install.sh (symlinks, drop-ins, ~/.local/bin/ollama wrapper);
#                server restarted only if the live process lacks the drop-in env
#   6. smoke     one turn through launcher and proxy
#
# No sudo. Missing apt packages are reported with the command, and the script
# stops. Any failed step stops the script. Downloads: Ollama ~1.5GB
# (+ ~2GB for amd-rocm), model ~18GB.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG/env" ] && . "$CONFIG/env"
MODEL="${CLAUDE_LOCAL_MODEL:-qwen3-coder:30b}"; PORT="${CLAUDE_LOCAL_PORT:-1234}"; PORT_EXPLICIT=0
GPU="amd-vulkan"; DRY=0; SMOKE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;; --no-smoke) SMOKE=0;;
    --model) MODEL=$2; shift;; --port) PORT=$2; PORT_EXPLICIT=1; shift;; --gpu) GPU=$2; shift;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
[ -f "$HERE/systemd/20-gpu-$GPU.conf" ] || { echo "unknown --gpu $GPU (amd-vulkan|amd-rocm|nvidia|cpu)" >&2; exit 2; }
USER_NAME="${USER:-$(id -un)}"
# systemctl --user needs the user manager's runtime dir; cron/containers/env -i lack it.
[ -n "${XDG_RUNTIME_DIR:-}" ] || { [ -d "/run/user/$(id -u)" ] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"; }
systemctl --user show-environment >/dev/null 2>&1 \
  || { printf '\033[1;31m[bootstrap] error:\033[0m no systemd user manager for %s (XDG_RUNTIME_DIR=%s); run from a login shell, or: loginctl enable-linger %s\n' "$USER_NAME" "${XDG_RUNTIME_DIR:-unset}" "$USER_NAME" >&2; exit 1; }
export PATH="$HOME/.local/bin:$PATH"       # where install.sh puts claude-local and the ollama wrapper
OLLAMA_DIR="$HOME/.local/ollama"; OLLAMA="$OLLAMA_DIR/bin/ollama"
UNIT_DIR="$HOME/.config/systemd/user"; UNIT="$UNIT_DIR/ollama.service"

say()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[bootstrap] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap] error:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*" >&2; }
run()  { if [ "$DRY" = 1 ]; then echo "  would run: $*" >&2; else "$@" || die "failed: $*"; fi; }
server_answers() { curl -s --max-time 2 -o /dev/null "http://127.0.0.1:${PORT}/api/tags"; }
wait_server() { # server must answer AND be our unit, not some other process on the port
  local i
  for i in $(seq 1 60); do server_answers && break; sleep 1; done
  server_answers || die "server did not answer on 127.0.0.1:${PORT} after 60s; see: journalctl --user -u ollama.service -e"
  systemctl --user is-active --quiet ollama.service \
    || die "something answers on port ${PORT} but ollama.service is not active (another Ollama on this port?); see: systemctl --user status ollama.service"
}
unit_env() { { systemctl --user show ollama.service -p Environment 2>/dev/null || true; } | sed 's/^Environment=//' | tr ' ' '\n'; }
live_env_missing() { # prints drop-in Environment= values the running server does not have
  local pid; pid=$(systemctl --user show ollama.service -p MainPID --value 2>/dev/null || echo 0)
  [ "${pid:-0}" -gt 0 ] || { echo "(server not running)"; return; }
  sed -n 's/^Environment=//p' "$UNIT_DIR"/ollama.service.d/*.conf 2>/dev/null | sort -u \
    | grep -vxF -f <(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || true
}

# ---------------------------------------------------------------- 1. deps ----
step "1/6 dependencies"
missing=""
for d in git curl jq python3 systemctl tar zstd; do command -v "$d" >/dev/null || missing="$missing $d"; done
[ -z "$missing" ] || die "missing:$missing. Install with:  sudo apt install -y${missing/systemctl/systemd}"
case ":${PATH_ORIG:-$PATH}:" in *":$HOME/.local/bin:"*) ;; *)
  grep -qs 'local/bin' "$HOME/.profile" "$HOME/.bashrc" 2>/dev/null \
    || warn "add to your shell profile so claude-local is found in new shells:  export PATH=\"\$HOME/.local/bin:\$PATH\"";; esac
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  say "node/npm not found; installing nvm + Node LTS (user-local)"
  run bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  run nvm install --lts
fi
if ! command -v claude >/dev/null; then
  say "claude CLI not found; installing @anthropic-ai/claude-code (user-level npm)"
  prefix=$(npm config get prefix 2>/dev/null || echo /usr)
  [ -w "$prefix/lib" ] 2>/dev/null || [ "$DRY" = 1 ] \
    || die "npm global prefix $prefix is not writable; use nvm (rerun after removing system node from PATH) or:  npm config set prefix ~/.local"
  run npm install -g @anthropic-ai/claude-code
fi
say "deps ok: claude=$(command -v claude || echo pending) node=$(node --version 2>/dev/null || echo pending)"

# ------------------------------------------------------------- 2. ollama ----
# Adopt an existing unit's binary/port when present, so we never download an
# Ollama nothing references or poll a port nothing serves.
step "2/6 ollama (user-local, $OLLAMA_DIR)"
UNIT_EXISTS=0; { [ -e "$UNIT" ] || [ -L "$UNIT" ]; } && UNIT_EXISTS=1
if [ "$UNIT_EXISTS" = 1 ]; then
  [ -f "$UNIT" ] || die "$UNIT exists but is not a regular file (dangling symlink or directory); remove it and rerun"
  exec_bin=$({ systemctl --user show ollama.service -p ExecStart --value 2>/dev/null || true; } | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1)
  unit_port=$(unit_env | sed -n 's/^OLLAMA_HOST=.*:\([0-9]*\)$/\1/p' | head -1)
  if [ -n "$exec_bin" ] && [ "$exec_bin" != "$OLLAMA" ]; then say "existing unit runs $exec_bin; using it"; OLLAMA="$exec_bin"; fi
  if [ -n "$unit_port" ] && [ "$unit_port" != "$PORT" ]; then
    [ "$PORT_EXPLICIT" = 1 ] && die "existing unit serves port $unit_port but --port $PORT was given; edit $UNIT or drop --port"
    say "existing unit serves port $unit_port; adopting it"; PORT="$unit_port"
  fi
fi
export OLLAMA_HOST="127.0.0.1:${PORT}"
fetch_bundle() { # mirrors ollama.com/install.sh: .tar.zst for current releases, .tgz fallback
  local base="https://ollama.com/download" name="$1"
  if [ "$DRY" = 1 ]; then echo "  would run: curl $base/$name.tar.zst (or .tgz) | extract -> $OLLAMA_DIR" >&2; return; fi
  if curl --fail --silent --head --location "${base}/${name}.tar.zst" >/dev/null 2>&1; then
    run bash -o pipefail -c "curl -fL --progress-bar '${base}/${name}.tar.zst' | zstd -d | tar -xf - -C '$OLLAMA_DIR'"
  else
    run bash -o pipefail -c "curl -fL --progress-bar '${base}/${name}.tgz' | tar -xzf - -C '$OLLAMA_DIR'"
  fi
}
if [ -x "$OLLAMA" ] && [ -d "$(dirname "$OLLAMA")/../lib/ollama" -o "$OLLAMA" != "$OLLAMA_DIR/bin/ollama" ]; then
  say "present: $("$OLLAMA" --version 2>/dev/null | head -1 || echo "$OLLAMA")"
else
  [ -e "$OLLAMA_DIR" ] && { warn "incomplete install at $OLLAMA_DIR; reinstalling"; run rm -rf "$OLLAMA_DIR"; }
  say "downloading Ollama for linux-amd64 into $OLLAMA_DIR"
  run mkdir -p "$OLLAMA_DIR"
  fetch_bundle ollama-linux-amd64
  if [ "$GPU" = amd-rocm ]; then say "downloading the ROCm bundle (--gpu amd-rocm)"; fetch_bundle ollama-linux-amd64-rocm; fi
fi

# ------------------------------------------------------------- 3. service ----
step "3/6 systemd user service (port $PORT, gpu profile $GPU)"
if [ "$UNIT_EXISTS" = 1 ]; then
  say "present: $UNIT (adopted, not overwritten)"
else
  say "installing $UNIT from systemd/ollama.service"
  run mkdir -p "$UNIT_DIR"
  if [ "$DRY" = 1 ]; then echo "  would write: $UNIT" >&2
  else sed "s|__PORT__|$PORT|g" "$HERE/systemd/ollama.service" > "$UNIT" || die "could not write $UNIT"; fi
fi
# Drop-ins go in BEFORE the first start so the server never runs without them.
if [ "$DRY" = 1 ]; then echo "  would install drop-ins 10-claude-local.conf + 20-gpu.conf ($GPU), daemon-reload, enable + start, wait" >&2
else
  D="$UNIT_DIR/ollama.service.d"; mkdir -p "$D"
  cmp -s "$HERE/systemd/10-claude-local.conf" "$D/10-claude-local.conf" || cp "$HERE/systemd/10-claude-local.conf" "$D/"
  cmp -s "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf" || cp "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf"
  systemctl --user daemon-reload
  systemctl --user enable ollama.service >/dev/null 2>&1 || warn "could not enable ollama.service (will not start at login)"
  systemctl --user is-active --quiet ollama.service || systemctl --user start ollama.service || die "ollama.service failed to start; see: journalctl --user -u ollama.service -e"
  wait_server
  say "server up at 127.0.0.1:$PORT (ollama.service active)"
  loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | grep -q yes \
    || warn "user services stop at logout; to keep the server across logouts:  loginctl enable-linger $USER_NAME"
fi
# Persist the port for the launcher, statusline, bench and the ollama wrapper (defaults only; env vars win).
run mkdir -p "$CONFIG"
if [ "$DRY" = 1 ]; then echo "  would write: $CONFIG/env (CLAUDE_LOCAL_PORT=$PORT)" >&2
else printf ': "${CLAUDE_LOCAL_PORT:=%s}"\n' "$PORT" > "$CONFIG/env"; fi
export CLAUDE_LOCAL_PORT="$PORT" OLLAMA_HOST="127.0.0.1:${PORT}"

# --------------------------------------------------------------- 4. model ----
step "4/6 model $MODEL"
if "$OLLAMA" show "$MODEL" >/dev/null 2>&1; then say "present"
else say "pulling $MODEL (large download)"; run "$OLLAMA" pull "$MODEL"; fi

# ------------------------------------------------------------- 5. harness ----
step "5/6 harness install (symlinks + drop-ins)"
if [ "$DRY" = 1 ]; then echo "  would run: $HERE/install.sh --gpu $GPU; restart server only if live env lacks the drop-in" >&2
else
  out=$("$HERE/install.sh" --gpu "$GPU") || die "install.sh failed"
  missing_env=$(live_env_missing)
  if printf '%s' "$out" | grep -q DROPIN_CHANGED || [ -n "$missing_env" ]; then
    say "restarting server to apply the drop-ins${missing_env:+ (live server lacks: $(echo "$missing_env" | paste -sd' '))}"
    systemctl --user restart ollama.service || die "restart failed; see: journalctl --user -u ollama.service -e"
    wait_server
  else say "server already running with the drop-in env; no restart"; fi
  live=$(systemctl --user show ollama.service -p MainPID --value); live=$(tr '\0' '\n' < "/proc/$live/environ" | grep -E '^OLLAMA_(FLASH_ATTENTION|CONTEXT_LENGTH|KV_CACHE_TYPE|NUM_PARALLEL)=' | paste -sd' ')
  say "live server env: ${live:-<none>}"
  [ -n "$live" ] || die "drop-in env not present in the running server"
fi

# --------------------------------------------------------------- 6. smoke ----
step "6/6 smoke test"
if [ "$SMOKE" = 1 ] && [ "$DRY" = 0 ]; then
  CLAUDE_LOCAL_MODEL="$MODEL" "$HERE/test/smoke.sh" || die "smoke test failed"
else say "skipped"; fi

printf '\n\033[1;32m[bootstrap] ready.\033[0m  Run:  claude-local\n' >&2
