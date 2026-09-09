#!/usr/bin/env bash
# Contract: no commit message in this repository credits an AI tool as an author.
#
# Commits are authored by the people accountable for them. An assistant may have helped write
# the change; that is a tool, not a co-author, and the claim does not belong in the permanent
# history or on the forge. .githooks/commit-msg calls this for the message being written, but a
# hook only runs in a clone that set core.hooksPath (this repo's were found uninstalled on a host
# that had already pushed 94 such commits, 2026-09-06), so `make lint` runs it over the whole
# history as well: a slip surfaces before the next push even where no hook is installed.
#
#   check_no_ai_attribution.sh --message-file FILE   # one message, as the hook passes it
#   check_no_ai_attribution.sh --log [RANGE]         # every commit message in RANGE (default HEAD, i.e. all of it)
#
# Offending lines go to stdout ("N:line" for a file, "<hash> line" for the log) and a summary to
# stderr; exit 1 on any hit, 0 when clean, 2 on usage.
set -euo pipefail

# Trailers and footers that assert authorship or link a tool session.
# .githooks/commit-msg carries a copy as its fallback for a checkout without scripts/: change both.
FORBIDDEN='^[[:space:]]*(Co-Authored-By:[[:space:]]*(Claude|GPT|Copilot|Gemini|Codex|Cursor|Devin|OpenAI|Anthropic)|Claude-Session:|Assistant-Session:|.*Generated with \[Claude Code\]|https://claude\.ai/code/session)'

case "${1:-}" in
  --message-file)
    file="${2:?usage: $0 --message-file FILE}"
    if hits=$(grep -inE "$FORBIDDEN" "$file"); then
      printf '%s\n' "$hits"
      echo "check_no_ai_attribution: $(printf '%s\n' "$hits" | wc -l) line(s) in $file credit an AI tool as an author" >&2
      exit 1
    fi
    exit 0
    ;;
  --log)
    range="${2:-HEAD}"
    # one record per commit: the hash, the raw body, "----". A "----" inside a body only delays
    # the next hash, it never hides a line. Fails (set -e) rather than passing on a bad range.
    log=$(git log --format='%H%n%B%n----' "$range")
    shopt -s nocasematch                   # grep -i in the hook; =~ here so 36 commits need no forks
    commits=0; hits=0; commit=""; want_hash=1
    while IFS= read -r line; do
      if [ "$want_hash" = 1 ] && [[ $line =~ ^[0-9a-f]{40}$ ]]; then
        commit=$line; want_hash=0; commits=$((commits + 1)); continue
      fi
      if [ "$line" = "----" ]; then want_hash=1; continue; fi
      if [[ $line =~ $FORBIDDEN ]]; then
        printf '%s %s\n' "${commit:0:12}" "$line"; hits=$((hits + 1))
      fi
    done <<< "$log"
    if [ "$hits" -gt 0 ]; then
      echo "check_no_ai_attribution: $hits line(s) in $range credit an AI tool as an author (git commit --amend / rebase them away)" >&2
      exit 1
    fi
    echo "check_no_ai_attribution: $commits commits in $range, none credit an AI tool as an author"
    exit 0
    ;;
  *)
    echo "usage: $0 --message-file FILE | --log [RANGE]" >&2
    exit 2
    ;;
esac
