#!/usr/bin/env bash
# adapter-os canonical gates on the current platform (re-run of the chain-C step killed at 05:52).
set -u; R=$HOME/dev/claude-local/bench/results; log(){ echo "[gates] $(date +%T) $*"; }
cd "$HOME/dev/adapter-os" && export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
timeout 60 git fetch -q --prune 2>/dev/null; log "branch $(git branch --show-current) @ $(git rev-parse --short HEAD) dirty=$(git status --porcelain | wc -l) behind=$(git rev-list --count HEAD..origin/main 2>/dev/null)"
t0=$(date +%s); MLX_FORCE_STUB=1 timeout 2400 cargo clippy --workspace --lib --bins --exclude adapteros-lora-mlx-ffi --quiet -- -D warnings > "$R/adapter-os-clippy.log" 2>&1; rc=$?; log "clippy exit=$rc ($(( $(date +%s)-t0 )) s, errors=$(grep -cE '^error' "$R/adapter-os-clippy.log"))"
t0=$(date +%s); timeout 2400 cargo test -p adapteros-code-context -p adapteros-planner -p adapteros-cli > "$R/adapter-os-test.log" 2>&1; rc=$?; log "tests exit=$rc ($(( $(date +%s)-t0 )) s): $(grep -E '^test result' "$R/adapter-os-test.log" | awk '{p+=$4; f+=$6} END{print p" passed, "f" failed, "NR" suites"}')"
log "dirty after=$(git status --porcelain | wc -l)"; log "GATES DONE"
