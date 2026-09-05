#!/usr/bin/env bash
# claude-local bootstrap: one command from a fresh Linux user account to a
# working `claude-local`.
#
#   ./bootstrap.sh [--dry-run] [--no-smoke] [--model NAME] [--port N] [--no-rocm]
#
# Steps (each is idempotent; re-running is safe):
#   1. deps      git curl jq python3 systemd zstd; node+npm (via nvm if absent); claude CLI
#   2. ollama    user-local install into ~/.local/ollama (base + ROCm bundle) if missing
#   3. service   ~/.config/systemd/user/ollama.service from systemd/ollama.service
#                (AMD Vulkan profile), enabled + started, waits for /api/tags
#   4. model     ollama pull MODEL if not present
#   5. harness   ./install.sh (symlinks + server drop-in), restart server to apply
#   6. smoke     make check (one turn through launcher and proxy)
#
# Nothing here needs sudo. If an apt package is missing it prints the command
# and stops. Downloads: Ollama ~1.5GB (+ ~2GB ROCm bundle), model ~18GB.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL="qwen3-coder:30b"; PORT="1234"; DRY=0; SMOKE=1; ROCM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;; --no-smoke) SMOKE=0;; --no-rocm) ROCM=0;;
    --model) MODEL=$2; shift;; --port) PORT=$2; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
OLLAMA_DIR="$HOME/.local/ollama"; OLLAMA="$OLLAMA_DIR/bin/ollama"
UNIT_DIR="$HOME/.config/systemd/user"; UNIT="$UNIT_DIR/ollama.service"
BASE_URL="http://127.0.0.1:${PORT}"
export OLLAMA_HOST="127.0.0.1:${PORT}"

say()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[bootstrap] warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap] error:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "  would run: $*" >&2; else "$@"; fi; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*" >&2; }

# ---------------------------------------------------------------- 1. deps ----
step "1/6 dependencies"
missing=""
for d in git curl jq python3 systemctl tar zstd; do command -v "$d" >/dev/null || missing="$missing $d"; done
if [ -n "$missing" ]; then
  die "missing:$missing. Install with:  sudo apt install -y${missing/systemctl/systemd}"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "$HOME/.local/bin is not on PATH; add it to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"";; esac
if ! command -v node >/dev/null || ! command -v npm >/dev/null; then
  say "node/npm not found; installing nvm + Node LTS (user-local)"
  run bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  run nvm install --lts
fi
if ! command -v claude >/dev/null; then
  say "claude CLI not found; installing @anthropic-ai/claude-code"
  run npm install -g @anthropic-ai/claude-code
fi
say "deps ok: $(command -v claude || echo 'claude (pending)') / node $(node --version 2>/dev/null || echo pending)"

# Mirrors ollama.com/install.sh: current releases ship .tar.zst (needs zstd),
# older ones .tgz. Asset URLs redirect to the GitHub release for the latest version.
fetch_bundle() { # $1 = asset name without extension
  local base="https://ollama.com/download" name="$1"
  if curl --fail --silent --head --location "${base}/${name}.tar.zst" >/dev/null 2>&1; then
    command -v zstd >/dev/null || die "this Ollama release needs zstd:  sudo apt install -y zstd"
    run bash -c "curl -fL --progress-bar '${base}/${name}.tar.zst' | zstd -d | tar -xf - -C '$OLLAMA_DIR'"
  else
    run bash -c "curl -fL --progress-bar '${base}/${name}.tgz' | tar -xzf - -C '$OLLAMA_DIR'"
  fi
}

# -------------------------------------------------------------- 2. ollama ----
step "2/6 ollama (user-local, $OLLAMA_DIR)"
if [ -x "$OLLAMA" ]; then
  say "present: $($OLLAMA --version 2>/dev/null | head -1)"
else
  say "downloading Ollama for linux-amd64 into $OLLAMA_DIR"
  run mkdir -p "$OLLAMA_DIR"
  fetch_bundle ollama-linux-amd64
  if [ "$ROCM" = 1 ]; then
    say "downloading the ROCm bundle (AMD GPUs; skip with --no-rocm)"
    fetch_bundle ollama-linux-amd64-rocm
  fi
fi

# ------------------------------------------------------------- 3. service ----
step "3/6 systemd user service"
if [ -f "$UNIT" ]; then
  say "present: $UNIT (not overwritten)"
else
  say "installing $UNIT from systemd/ollama.service (AMD Vulkan profile; edit if not AMD)"
  run mkdir -p "$UNIT_DIR"
  if [ "$DRY" = 1 ]; then echo "  would write: $UNIT" >&2
  else sed "s|__HOME__|$HOME|g; s|__PORT__|$PORT|g" "$HERE/systemd/ollama.service" > "$UNIT"; fi
fi
if [ "$DRY" = 0 ]; then
  systemctl --user daemon-reload
  systemctl --user enable --now ollama.service >/dev/null 2>&1 || systemctl --user start ollama.service
  for _ in $(seq 1 60); do curl -s --max-time 2 -o /dev/null "$BASE_URL/api/tags" && break; sleep 1; done
  curl -s --max-time 2 -o /dev/null "$BASE_URL/api/tags" || die "server did not come up; see: journalctl --user -u ollama.service -e"
  say "server up at $BASE_URL"
  if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes; then
    warn "user services stop at logout; to keep the server across logouts:  loginctl enable-linger $USER"
  fi
else echo "  would: daemon-reload, enable --now ollama.service, wait for $BASE_URL/api/tags" >&2; fi

# --------------------------------------------------------------- 4. model ----
step "4/6 model $MODEL"
if [ "$DRY" = 0 ] && curl -s --max-time 5 "$BASE_URL/api/tags" | jq -e --arg m "$MODEL" '.models[]|select(.name==$m)' >/dev/null 2>&1; then
  say "present"
else
  say "pulling $MODEL (large download)"
  run "$OLLAMA" pull "$MODEL"
fi

# ------------------------------------------------------------- 5. harness ----
step "5/6 harness install (symlinks + server drop-in)"
run "$HERE/install.sh"
if [ "$DRY" = 0 ]; then
  say "restarting server to apply the drop-in"
  systemctl --user restart ollama.service
  for _ in $(seq 1 60); do curl -s --max-time 2 -o /dev/null "$BASE_URL/api/tags" && break; sleep 1; done
  env_now=$(systemctl --user show ollama.service -p Environment | tr ' ' '\n' | grep -E 'OLLAMA_(CONTEXT_LENGTH|KV_CACHE_TYPE|NUM_PARALLEL)=' | paste -sd' ')
  say "server env: ${env_now:-<drop-in not applied>}"
fi

# --------------------------------------------------------------- 6. smoke ----
step "6/6 smoke test"
if [ "$SMOKE" = 1 ] && [ "$DRY" = 0 ]; then
  CLAUDE_LOCAL_MODEL="$MODEL" CLAUDE_LOCAL_PORT="$PORT" "$HERE/test/smoke.sh" || die "smoke test failed"
else say "skipped"; fi

printf '\n\033[1;32m[bootstrap] ready.\033[0m  Run:  claude-local\n' >&2
