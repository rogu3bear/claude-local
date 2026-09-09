#!/usr/bin/env bash
# claude-local bootstrap: one command from a fresh Linux user account to a
# working `claude-local`.
#
#   ./bootstrap.sh [--dry-run] [--no-smoke] [--model NAME] [--port N]
#                  [--gpu amd-vulkan|amd-rocm|nvidia|cpu]   (default amd-vulkan)
#                  [--backend ollama|llamaserver]           (default ollama)
#                  [--llama-cpp DIR] [--device auto|ROCm0|Vulkan0] [--llama-port N]
#                  [--hf URL|OWNER/REPO/FILE.gguf] [--sha256 HEX] [--model-gguf PATH]
#                  [--draft URL|PATH|none|default]  (default none)
#
# Recommended on Strix Halo (gfx1151): llama-server with the uncensored Genesis build of
# Qwen3.6-35B-A3B (jan1k, abliterated; NVFP4 with the MTP head), the preset this host runs:
#   ./bootstrap.sh --backend llamaserver \
#     --hf jan1k/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-NVFP4-GGUF/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-MTP-NVFP4.gguf \
#     --sha256 af80d3ef030268c46d56f6d7d2722de67fe81592708bac6c8fa381461adfbaad
#   URL, size (22170261312 bytes) and sha256 verified against huggingface.co on 2026-09-09. The
#   file keeps its remote name, which the [qwen3.6-35b-genesis] preset in
#   config/llama-models.ini.example (reasoning off, draft-mtp n-max 2) expects. The filtered
#   original, the 2026-09-06 overnight winner (27/27, 12.3 s/task vs 21.4 s for Ollama +
#   qwen3-coder:30b), is unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
#   (sha256 55983c5a75a1ab969824077b3bb3de4146e82a9234072b48ad4e8f92ad3fe9f1, 22853663008 bytes); pass it with
#   --model-gguf ~/.claude-local/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf, because the
#   [qwen3.6-35b] preset expects the -MTP name and unsloth's non-MTP repo ships a different
#   file under the remote name (22360456160 bytes).
#
# Steps (each idempotent; re-running is safe and does not restart a healthy server):
#   1. deps      git curl jq python3 systemd tar zstd; node+npm (nvm if absent); claude CLI
#   2. ollama    user-local install into ~/.local/ollama if missing
#                (ROCm bundle only for --gpu amd-rocm)
#   3. service   ~/.config/systemd/user/ollama.service (generic) + drop-ins
#                10-claude-local.conf (context/KV/slots/flash attention) and
#                20-gpu.conf (profile); an existing unit is adopted, not overwritten
#   4. model     pull MODEL if not present. With --backend llamaserver and a GGUF from
#                --hf (curl into ~/.claude-local/models: resumable .part file, "GGUF"
#                magic and --sha256 checked, skipped when the file is already there)
#                or --model-gguf, the Ollama pull is skipped and the Ollama manifest is
#                left alone; Ollama stays installed as the fallback backend
#   5. harness   ./install.sh (symlinks, drop-ins, ~/.local/bin/ollama wrapper);
#                server restarted only if the live process lacks the drop-in env
#   6. smoke     one turn through launcher and proxy
#   With --backend llamaserver an extra step 4b installs llama-server.service (port 1244)
#   from an existing upstream llama.cpp build (--llama-cpp DIR, default ~/ai/llama.cpp;
#   the build recipe is printed if the binary is missing). --device auto (the default)
#   takes ROCm0 when build-hip/bin/llama-server --list-devices shows it (ROCm prefills
#   1.3-1.6x faster than Vulkan at equal decode on gfx1151, measured 2026-09-07), else
#   Vulkan0 when build-vulkan exists; an explicit --device wins. The GGUF comes from --hf,
#   --model-gguf or, failing both, the Ollama manifest of MODEL (a plain Q4_K_M without
#   the MTP head). A draft model is optional (--draft default). llama-server.env and
#   llama-models.ini are written from config/*.example (adopted if present; a preset
#   section is appended for a GGUF the INI lacks) and the unit is started. Without
#   --model, MODEL becomes the INI alias of the GGUF (the section that names it, or the
#   lower-cased file stem of a new section), which is what the launcher expects.
#
# No sudo. Missing apt packages are reported with the command, and the script
# stops. Any failed step stops the script. Downloads: Ollama ~1.5GB
# (+ ~2GB for amd-rocm), model ~18GB (Ollama pull) or ~23GB (the recommended GGUF).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${CLAUDE_LOCAL_CONFIG:-$HOME/.claude-local}"
[ -r "$CONFIG/env" ] && . "$CONFIG/env"
MODEL="${CLAUDE_LOCAL_MODEL:-qwen3-coder:30b}"; PORT="${CLAUDE_LOCAL_PORT:-1234}"; PORT_EXPLICIT=0
MODEL_EXPLICIT=0; [ -n "${CLAUDE_LOCAL_MODEL:-}" ] && MODEL_EXPLICIT=1   # a chosen name is never replaced by the GGUF alias
GPU="amd-vulkan"; DRY=0; SMOKE=1
BACKEND="${CLAUDE_LOCAL_BACKEND:-ollama}"; LLAMA_CPP_DIR="$HOME/ai/llama.cpp"; LLAMA_DEVICE="auto"; LLAMA_PORT="${CLAUDE_LOCAL_LLAMASERVER_PORT:-1244}"
MODEL_GGUF=""; HF=""; HF_URL=""; SHA256=""; DRAFT="none"; DRAFT_SIZE=639446688   # speculative decoding measured slower on gfx1151; opt in with --draft URL
DRAFT_DEFAULT_URL="https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;; --no-smoke) SMOKE=0;;
    --model) MODEL=$2; MODEL_EXPLICIT=1; shift;; --port) PORT=$2; PORT_EXPLICIT=1; shift;; --gpu) GPU=$2; shift;;
    --backend) BACKEND=$2; shift;; --llama-cpp) LLAMA_CPP_DIR=$2; shift;; --device) LLAMA_DEVICE=$2; shift;;
    --llama-port) LLAMA_PORT=$2; shift;; --model-gguf) MODEL_GGUF=$2; shift;; --draft) DRAFT=$2; [ "$DRAFT" = default ] && DRAFT="$DRAFT_DEFAULT_URL"; shift;;
    --hf) HF=$2; shift;; --sha256) SHA256=$2; shift;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option $1" >&2; exit 2;;
  esac; shift
done
[ -f "$HERE/systemd/20-gpu-$GPU.conf" ] || { echo "unknown --gpu $GPU (amd-vulkan|amd-rocm|nvidia|cpu)" >&2; exit 2; }
case "$BACKEND" in ollama|llamaserver) ;; *) echo "unknown --backend $BACKEND (ollama|llamaserver)" >&2; exit 2;; esac
case "$LLAMA_DEVICE" in auto|ROCm*|Vulkan*) ;; *) echo "unknown --device $LLAMA_DEVICE (auto|ROCm0|Vulkan0)" >&2; exit 2;; esac
if [ -n "$HF" ]; then
  [ "$BACKEND" = llamaserver ] || { echo "--hf downloads a GGUF for llama-server; add --backend llamaserver" >&2; exit 2; }
  case "$HF" in
    http://*|https://*) HF_URL="$HF";;
    */*/*) hf_rest=${HF#*/}; HF_URL="https://huggingface.co/${HF%%/*}/${hf_rest%%/*}/resolve/main/${hf_rest#*/}";;
    *) echo "--hf expects https://huggingface.co/OWNER/REPO/resolve/main/FILE.gguf or OWNER/REPO/FILE.gguf" >&2; exit 2;;
  esac
  [ -n "$MODEL_GGUF" ] || MODEL_GGUF="$CONFIG/models/$(basename "${HF_URL%%\?*}")"   # --model-gguf PATH names the download
fi
if [ -n "$SHA256" ]; then
  [ -n "$MODEL_GGUF" ] || { echo "--sha256 verifies a GGUF from --hf or --model-gguf" >&2; exit 2; }
  printf '%s' "$SHA256" | grep -qiE '^[0-9a-f]{64}$' || { echo "--sha256 expects 64 hex characters" >&2; exit 2; }
  SHA256=$(printf '%s' "$SHA256" | tr 'A-F' 'a-f')
fi
case "$MODEL_GGUF" in ""|/*) ;; *) MODEL_GGUF="$PWD/$MODEL_GGUF";; esac   # the INI and the unit need an absolute path
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
  cmp -s "$HERE/systemd/10-claude-local.conf" "$D/10-claude-local.conf" \
    || { cp "$HERE/systemd/10-claude-local.conf" "$D/"; say "updated drop-in $D/10-claude-local.conf"; }
  cmp -s "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf" \
    || { cp "$HERE/systemd/20-gpu-$GPU.conf" "$D/20-gpu.conf"; say "updated drop-in $D/20-gpu.conf ($GPU)"; }
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
write_env_file() { # defaults only; explicit environment variables always win. MODEL is final only after step 4/4b, hence the second call.
  cat > "$CONFIG/env" <<EOF2
: "\${CLAUDE_LOCAL_OLLAMA_PORT:=$PORT}"
: "\${CLAUDE_LOCAL_LLAMASERVER_PORT:=$LLAMA_PORT}"
: "\${CLAUDE_LOCAL_BACKEND:=$BACKEND}"
: "\${CLAUDE_LOCAL_DEFAULT_MODEL:=$MODEL}"   # listed first in the picker, Enter picks it; the smoke test uses it
case "\$CLAUDE_LOCAL_BACKEND" in
  llamaserver) : "\${CLAUDE_LOCAL_PORT:=\$CLAUDE_LOCAL_LLAMASERVER_PORT}" ;;
  *)           : "\${CLAUDE_LOCAL_PORT:=\$CLAUDE_LOCAL_OLLAMA_PORT}" ;;
esac
EOF2
}
if [ "$DRY" = 1 ]; then echo "  would write: $CONFIG/env (ollama=$PORT llamaserver=$LLAMA_PORT default backend=$BACKEND)" >&2
else write_env_file; fi
[ "$BACKEND" = llamaserver ] || warn "config/settings.json pins ANTHROPIC_BASE_URL to the llama-server port ($LLAMA_PORT), so a bare 'claude' with this config dir fails to connect by design (it never reaches Anthropic's API); start sessions with claude-local, which sets the Ollama port itself"
export OLLAMA_HOST="127.0.0.1:${PORT}"

# --------------------------------------------------------------- 4. model ----
# A GGUF named on the command line (--hf, --model-gguf) is what llama-server serves, so
# the Ollama pull is skipped: the Ollama blob of qwen3.6 is a plain Q4_K_M without the
# MTP head, not the file the 2026-09-06 bench won with. Ollama stays installed as the
# fallback backend. Downloads go through a .part file so a partial file is never served.
gb() { awk -v b="$1" 'BEGIN{printf "%.1f GB", b/1e9}'; }
remote_size() { curl -sIL --max-time 30 "$1" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{s=$2} END{print s}'; }
check_gguf() { # "GGUF" magic always; sha256 when --sha256 was given (real runs only: 22GB hashes in about a minute)
  [ "$(head -c 4 "$1" 2>/dev/null)" = GGUF ] || die "not a GGUF file (first bytes are not GGUF): $1; remove it and rerun"
  [ -n "$SHA256" ] || return 0
  if [ "$DRY" = 1 ]; then echo "  would verify sha256 of $1" >&2; return 0; fi
  say "verifying sha256 of $(basename "$1") ($(gb "$(stat -c %s "$1")"))"
  local got; got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$SHA256" ] || die "sha256 mismatch for $1: got $got, expected $SHA256; remove the file and rerun"
}
fetch_gguf() { # $HF_URL -> $MODEL_GGUF; resumable (curl -C - on the .part file), skipped when the file is already there
  local dest="$MODEL_GGUF" part="$MODEL_GGUF.part" want have size_str resume=""
  want=$(remote_size "$HF_URL")
  if [ -n "$want" ]; then size_str=$(gb "$want"); else size_str="size unknown"; warn "could not read the size of $HF_URL (offline?); the size check is skipped"; fi
  if [ -f "$dest" ]; then
    have=$(stat -c %s "$dest")
    [ -z "$want" ] || [ "$have" = "$want" ] || die "$dest exists with $have bytes, expected $want; remove it or pass --model-gguf PATH to save the download elsewhere"
    say "present: $dest ($(gb "$have"))"; check_gguf "$dest"; return 0
  fi
  [ ! -f "$part" ] || resume=" (resuming $part, $(gb "$(stat -c %s "$part")") so far)"
  if [ "$DRY" = 1 ]; then echo "  would download $HF_URL ($size_str) to $dest${SHA256:+, then verify sha256}$resume" >&2; return 0; fi
  mkdir -p "$(dirname "$dest")"
  say "downloading $HF_URL ($size_str) to $dest$resume"
  if [ -f "$part" ] && [ -n "$want" ] && [ "$(stat -c %s "$part")" = "$want" ]; then say "download already complete: $part"
  else curl -fL -C - --progress-bar -o "$part" "$HF_URL" || die "download failed; rerun to resume from $part"; fi
  have=$(stat -c %s "$part")
  [ -z "$want" ] || [ "$have" = "$want" ] || die "$part has $have bytes, expected $want; rerun to resume"
  check_gguf "$part"
  mv "$part" "$dest"; say "downloaded $dest ($(gb "$have"))"
}
GGUF_FROM_FLAG=0; [ "$BACKEND" = llamaserver ] && [ -n "$MODEL_GGUF" ] && GGUF_FROM_FLAG=1
if [ "$GGUF_FROM_FLAG" = 1 ]; then
  step "4/6 model $(basename "$MODEL_GGUF") (GGUF for llama-server; Ollama pull skipped)"
  if [ -n "$HF_URL" ]; then fetch_gguf
  else [ -r "$MODEL_GGUF" ] || die "model GGUF not readable: $MODEL_GGUF"; say "present: $MODEL_GGUF ($(gb "$(stat -c %s "$MODEL_GGUF")"))"; check_gguf "$MODEL_GGUF"; fi
  say "Ollama pull skipped: llama-server serves this GGUF; Ollama stays installed as the fallback backend (CLAUDE_LOCAL_BACKEND=ollama claude-local)"
else
  step "4/6 model $MODEL"
  if "$OLLAMA" show "$MODEL" >/dev/null 2>&1; then say "present"
  else say "pulling $MODEL (large download)"; run "$OLLAMA" pull "$MODEL"; fi
fi

# -------------------------------------------------------- 4b. llama-server ----
if [ "$BACKEND" = llamaserver ]; then
  device_why=""
  if [ "$LLAMA_DEVICE" = auto ]; then
    # ROCm first: on gfx1151 the HIP build prefills Qwen3.8-27B 1.6x and Qwen3.6-35B 1.3x
    # faster than Vulkan at equal decode (2026-09-07, bench/results/micro/micro-q38-*.jsonl).
    if [ -x "$LLAMA_CPP_DIR/build-hip/bin/llama-server" ] && "$LLAMA_CPP_DIR/build-hip/bin/llama-server" --list-devices 2>/dev/null | grep -q '^ *ROCm0:'; then
      LLAMA_DEVICE=ROCm0; device_why="auto: build-hip lists ROCm0, which prefills 1.3-1.6x faster than Vulkan at equal decode on gfx1151 (2026-09-07)"
    elif [ -x "$LLAMA_CPP_DIR/build-vulkan/bin/llama-server" ]; then
      LLAMA_DEVICE=Vulkan0; device_why="auto: build-hip lists no ROCm0, build-vulkan is present"
    else
      LLAMA_DEVICE=Vulkan0; device_why="auto: no build under $LLAMA_CPP_DIR yet"
    fi
  fi
  step "4b/6 llama-server (upstream llama.cpp, device $LLAMA_DEVICE, port $LLAMA_PORT)"
  [ -z "$device_why" ] || say "device $LLAMA_DEVICE ($device_why); an explicit --device overrides"
  case "$LLAMA_DEVICE" in ROCm*) lbuild=build-hip;; Vulkan*) lbuild=build-vulkan;; *) die "--device must be auto, ROCm0 or Vulkan0";; esac
  LBIN="$LLAMA_CPP_DIR/$lbuild/bin/llama-server"
  if [ ! -x "$LBIN" ]; then
    cat >&2 <<EOF2
[bootstrap] error: no llama-server at $LBIN. Build upstream llama.cpp first (README "llama.cpp build recipe"):
  git clone https://github.com/ggml-org/llama.cpp $LLAMA_CPP_DIR && cd $LLAMA_CPP_DIR
  HIPCXX="\$(hipconfig -l)/clang" HIP_PATH="\$(hipconfig -R)" cmake -S . -B build-hip -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
  cmake --build build-hip --config Release -j -t llama-server llama-bench
  cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build-vulkan --config Release -j -t llama-server llama-bench
EOF2
    exit 1
  fi
  "$LBIN" --list-devices 2>/dev/null | grep -q "$LLAMA_DEVICE" || die "$LBIN does not list device $LLAMA_DEVICE (run: $LBIN --list-devices)"
  if [ -z "$MODEL_GGUF" ]; then
    mf="$HOME/.ollama/models/manifests/registry.ollama.ai/library/${MODEL%%:*}/${MODEL#*:}"
    [ -f "$mf" ] || die "no Ollama manifest for $MODEL at $mf; pass --model-gguf PATH"
    MODEL_GGUF="$HOME/.ollama/models/blobs/$(jq -r '.layers[]|select(.mediaType=="application/vnd.ollama.image.model").digest' "$mf" | sed 's/:/-/')"
  fi
  if [ ! -r "$MODEL_GGUF" ]; then { [ "$DRY" = 1 ] && [ -n "$HF_URL" ]; } || die "model GGUF not readable: $MODEL_GGUF"; fi
  say "model gguf: $MODEL_GGUF"
  spec_type="draft-simple"; draft_path=""
  case "$DRAFT" in
    none) spec_type="";;
    http*) draft_path="$CONFIG/models/$(basename "$DRAFT")"
      if [ -f "$draft_path" ] && [ "$(stat -c %s "$draft_path")" = "$DRAFT_SIZE" ]; then say "draft model present: $draft_path"
      else say "downloading draft model $(basename "$DRAFT") (~$((DRAFT_SIZE/1000000)) MB)"; run mkdir -p "$CONFIG/models"
        if [ "$DRY" = 0 ]; then
          if ! curl -fL -C - --progress-bar -o "$draft_path" "$DRAFT" || [ "$(stat -c %s "$draft_path" 2>/dev/null)" != "$DRAFT_SIZE" ]; then
            warn "draft download failed or size mismatch; speculative decoding disabled (rerun with --draft URL|PATH to retry)"; spec_type=""; draft_path=""
          fi
        fi
      fi;;
    *) draft_path="$DRAFT"; [ -r "$draft_path" ] || die "draft model not readable: $draft_path";;
  esac
  run mkdir -p "$CONFIG/slots" "$CONFIG/models"
  if [ -f "$CONFIG/llama-server.env" ]; then
    env_dev=$(sed -n 's/^LLAMA_DEVICE=//p' "$CONFIG/llama-server.env" | head -1)
    say "present: $CONFIG/llama-server.env (adopted, not overwritten${env_dev:+; its LLAMA_DEVICE=$env_dev is what the unit runs})"
  elif [ "$DRY" = 1 ]; then echo "  would write: $CONFIG/llama-server.env (device=$LLAMA_DEVICE model=$MODEL_GGUF spec=${spec_type:-off})" >&2
  else
    sed "s|__HOME__|$HOME|g; s|__MODEL_GGUF__|$MODEL_GGUF|g; s|^LLAMA_CPP_DIR=.*|LLAMA_CPP_DIR=$LLAMA_CPP_DIR|; s|^LLAMA_DEVICE=.*|LLAMA_DEVICE=$LLAMA_DEVICE|" "$HERE/config/llama-server.env.example" > "$CONFIG/llama-server.env"
    if [ -z "$spec_type" ]; then sed -i 's|^LLAMA_ARG_SPEC_TYPE=|#LLAMA_ARG_SPEC_TYPE=|' "$CONFIG/llama-server.env"
    elif [ -n "$draft_path" ]; then sed -i "s|^LLAMA_ARG_SPEC_DRAFT_MODEL=.*|LLAMA_ARG_SPEC_DRAFT_MODEL=$draft_path|" "$CONFIG/llama-server.env"; fi
    say "wrote $CONFIG/llama-server.env"
  fi
  # Presets: the section that names the GGUF is the alias the router, the launcher and the
  # smoke test use. A GGUF the INI lacks gets a bare section (alias = file stem, lower-cased,
  # as llama-models-ini does); it then samples from [*] only, so tune it in the INI.
  INI="$CONFIG/llama-models.ini"; ini_appended=0
  ini_alias() { awk -v want="model = $1" '/^\[/{s=$0; sub(/^\[/,"",s); sub(/\].*$/,"",s)} {l=$0; sub(/[ \t]+$/,"",l); sub(/^model[ \t]*=[ \t]*/,"model = ",l)} l==want{print s; exit}'; }
  if [ -f "$INI" ]; then say "present: $INI (adopted; run llama-models-ini to add other GGUFs)"; ini_text=$(cat "$INI")
  else
    ini_text=$(sed "s|__HOME__|$HOME|g" "$HERE/config/llama-models.ini.example")
    if [ "$DRY" = 1 ]; then echo "  would write: $INI (router presets from config/llama-models.ini.example)" >&2
    else sed "s|__HOME__|$HOME|g" "$HERE/config/llama-models.ini.example" > "$INI"; say "wrote $INI"; fi
  fi
  alias=$(printf '%s\n' "$ini_text" | ini_alias "$MODEL_GGUF")
  if [ -n "$alias" ]; then say "preset [$alias] serves $(basename "$MODEL_GGUF")"
  else
    if [ "$GGUF_FROM_FLAG" = 1 ]; then alias=$(basename "$MODEL_GGUF" .gguf | tr 'A-Z' 'a-z'); else alias=$(printf '%s' "$MODEL" | tr ':' '-'); fi
    if [ "$DRY" = 1 ]; then echo "  would append preset [$alias] (model = $MODEL_GGUF) to $INI" >&2
    else printf '\n; appended by bootstrap.sh on %s: bare preset (samples from [*] only), tune or remove\n[%s]\nmodel = %s\n' "$(date +%F)" "$alias" "$MODEL_GGUF" >> "$INI"; ini_appended=1; say "appended preset [$alias] -> $MODEL_GGUF (no per-model keys; see config/llama-models.ini.example)"; fi
  fi
  if [ "$GGUF_FROM_FLAG" = 1 ] && [ "$MODEL_EXPLICIT" = 0 ]; then MODEL="$alias"; say "model alias: $MODEL (what the launcher's CLAUDE_LOCAL_MODEL and the smoke test use)"; fi
  LUNIT="$UNIT_DIR/llama-server.service"
  if [ -e "$LUNIT" ] || [ -L "$LUNIT" ]; then
    [ -f "$LUNIT" ] || die "$LUNIT exists but is not a regular file"
    lp=$( { systemctl --user show llama-server.service -p Environment 2>/dev/null || true; } | tr ' ' '\n' | sed -n 's/^LLAMA_ARG_PORT=\([0-9]*\)$/\1/p' | head -1)
    [ -n "$lp" ] && [ "$lp" != "$LLAMA_PORT" ] && { say "existing llama-server unit serves port $lp; adopting it"; LLAMA_PORT="$lp"; }
    say "present: $LUNIT (adopted)"
  elif [ "$DRY" = 1 ]; then echo "  would write: $LUNIT (port $LLAMA_PORT) + drop-in, enable, start, wait for /health" >&2
  else
    run mkdir -p "$UNIT_DIR"; sed "s|__PORT__|$LLAMA_PORT|g" "$HERE/systemd/llama-server/llama-server.service" > "$LUNIT" || die "could not write $LUNIT"
  fi
  if [ "$DRY" = 0 ]; then
    D="$UNIT_DIR/llama-server.service.d"; mkdir -p "$D"
    cmp -s "$HERE/systemd/llama-server/10-claude-local.conf" "$D/10-claude-local.conf" || { cp "$HERE/systemd/llama-server/10-claude-local.conf" "$D/"; say "updated drop-in $D/10-claude-local.conf"; }
    systemctl --user daemon-reload
    owner=$(ss -ltnp 2>/dev/null | awk -v p=":${LLAMA_PORT}" '$4 ~ p"$" {print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    mp=$(systemctl --user show llama-server.service -p MainPID --value 2>/dev/null || echo 0)
    if [ -n "$owner" ] && [ "$owner" != "$mp" ] && ! pgrep -P "$mp" 2>/dev/null | grep -qx "$owner"; then die "port $LLAMA_PORT is owned by pid $owner, not llama-server.service"; fi
    systemctl --user enable llama-server.service >/dev/null 2>&1 || warn "could not enable llama-server.service"
    systemctl --user is-active --quiet llama-server.service || systemctl --user start llama-server.service || die "llama-server.service failed to start; see: journalctl --user -u llama-server.service -e"
    for i in $(seq 1 600); do curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:${LLAMA_PORT}/health" && break; sleep 1; done
    curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:${LLAMA_PORT}/health" || die "llama-server did not become healthy in 600s; see: journalctl --user -u llama-server.service -e"
    systemctl --user is-active --quiet llama-server.service || die "something answers on port $LLAMA_PORT but llama-server.service is not active"
    if curl -sf "http://127.0.0.1:${LLAMA_PORT}/models" | jq -e '.data[0].status != null' >/dev/null 2>&1; then
      say "llama-server up (router): models=$(curl -sf "http://127.0.0.1:${LLAMA_PORT}/models" | jq -r '[.data[].id] | join(",")')"
    else
      say "llama-server up: $(curl -sf "http://127.0.0.1:${LLAMA_PORT}/props" | jq -r '"alias=\(.model_alias) n_ctx=\(.default_generation_settings.n_ctx)"')"
    fi
    if [ "$ini_appended" = 1 ]; then   # an adopted, already running router reads the INI only on reload (what llama-models-ini does)
      curl -sf --max-time 10 "http://127.0.0.1:${LLAMA_PORT}/models?reload=1" >/dev/null 2>&1 && say "router reloaded the INI" \
        || warn "router did not reload the INI; run llama-models-ini or restart llama-server.service"
    fi
    spec_line=$(journalctl --user -u llama-server.service -n 300 --no-pager 2>/dev/null | grep -iE 'speculative|draft' | grep -viE 'n_ctx_train|control-looking' | tail -1 | sed 's/.*llama-server-run\[[0-9]*\]: //')
    say "speculative: ${spec_line:-<no draft configured>}"
  fi
fi

# The env file again, now that MODEL is the alias the launcher will use (unchanged for Ollama).
if [ "$DRY" = 1 ]; then echo "  would write: $CONFIG/env (default model $MODEL)" >&2; else write_env_file; fi

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
  CLAUDE_LOCAL_BACKEND="$BACKEND" CLAUDE_LOCAL_MODEL="$MODEL" "$HERE/test/smoke.sh" || die "smoke test failed"
else say "skipped"; fi

printf '\n\033[1;32m[bootstrap] ready.\033[0m  Run:  claude-local   (backend %s, model %s)\n' "$BACKEND" "$MODEL" >&2
