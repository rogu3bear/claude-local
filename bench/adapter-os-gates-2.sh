#!/usr/bin/env bash
# Re-run the adapter-os test gate after clearing adapteros-cli build artifacts (rustc ICE at 11:26 followed a cargo kill at 05:52).
set -u; R=$HOME/dev/claude-local/bench/results; log(){ echo "[gates2] $(date +%T) $*"; }
cd "$HOME/dev/adapter-os" && export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
log "branch $(git branch --show-current) @ $(git rev-parse --short HEAD) dirty=$(git status --porcelain | wc -l)"
timeout 300 cargo clean -p adapteros-cli >/dev/null 2>&1; log "cleaned adapteros-cli artifacts"
t0=$(date +%s); timeout 2400 cargo test -p adapteros-code-context -p adapteros-planner -p adapteros-cli > "$R/adapter-os-test-2.log" 2>&1; rc=$?
log "tests exit=$rc ($(( $(date +%s)-t0 )) s): $(grep -E '^test result' "$R/adapter-os-test-2.log" | awk '{p+=$4; f+=$6} END{print p" passed, "f" failed, "NR" suites"}')  ICE=$(grep -c 'compiler unexpectedly panicked' "$R/adapter-os-test-2.log")"
log "dirty after=$(git status --porcelain | wc -l)"; log "GATES2 DONE"
