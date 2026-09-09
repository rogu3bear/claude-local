#!/bin/bash
# Generic codebase healer + git safety net (scaffolded by claude-local-init).
# "green" = .claude/scripts/verify.sh exits 0 (that file is language-specific).
# Subcommands: status | mark-green | checkpoint | recover | prune
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$ROOT" || exit 2
GREEN_TAG="heal-green"

green()    { bash "$ROOT/.claude/scripts/verify.sh" >/dev/null 2>&1; }
is_dirty() { [ -n "$(git status --porcelain 2>/dev/null)" ]; }
green_sha(){ git rev-parse -q --verify "refs/tags/${GREEN_TAG}" 2>/dev/null; }

prune() {
  git for-each-ref --sort=-refname --format='%(refname:short)' refs/heads/broken/ 2>/dev/null \
    | tail -n +6 | while read -r br; do [ -n "$br" ] && git branch -D "$br" >/dev/null 2>&1; done
  local idxs; idxs=$(git stash list 2>/dev/null | grep -n 'heal-broken-' | sed 's/:.*//')
  local count=0
  for ln in $idxs; do
    count=$((count+1))
    if [ "$count" -gt 5 ]; then
      local i=$((ln-1)); git stash drop "stash@{$i}" >/dev/null 2>&1 || true
    fi
  done
}

case "${1:-status}" in
  status)
    g=ok; green || g=fail
    tree=clean; is_dirty && tree=dirty
    if [ "$g" = ok ] && [ -z "$(green_sha || true)" ]; then git tag -f "$GREEN_TAG" HEAD >/dev/null 2>&1; fi
    gs="$(green_sha || true)"; [ -n "$gs" ] && gs="${gs:0:12}" || gs=none
    echo "GREEN=$g TREE=$tree LAST_GREEN=$gs"
    [ "$g" = ok ] && exit 0 || exit 1 ;;
  mark-green)
    if green; then git tag -f "$GREEN_TAG" HEAD >/dev/null; echo "marked $(git rev-parse --short HEAD) green"; else echo "refusing: not green"; exit 1; fi ;;
  checkpoint)
    if ! green; then echo "refusing checkpoint: not green"; exit 1; fi
    if is_dirty; then git add -A; git commit -q -m "heal: green checkpoint" || true; echo "checkpointed $(git rev-parse --short HEAD)"; else echo "clean; nothing to checkpoint"; fi
    git tag -f "$GREEN_TAG" HEAD >/dev/null; echo "last-green -> $(git rev-parse --short HEAD)" ;;
  recover)
    g="$(green_sha || true)"
    if [ -z "$g" ]; then echo "no ${GREEN_TAG} tag yet; fix by hand then: heal.sh mark-green"; exit 1; fi
    ts="$(date +%Y%m%d-%H%M%S)"
    git branch "broken/$ts" >/dev/null 2>&1 || true
    git stash push -u -m "heal-broken-$ts" >/dev/null 2>&1 || true
    git reset --hard "$g" >/dev/null
    echo "recovered to last-green $(git rev-parse --short HEAD); broken state on branch broken/$ts and/or stash heal-broken-$ts"
    prune ;;
  prune) prune; echo "pruned old broken/* branches and heal-broken-* stashes (kept 5)" ;;
  *) echo "usage: heal.sh {status|mark-green|checkpoint|recover|prune}"; exit 2 ;;
esac
