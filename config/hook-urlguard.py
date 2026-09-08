#!/usr/bin/env python3
"""claude-local: PreToolUse hook that refuses WebFetch on a URL the model made up.

A small local model will happily "fetch" repositories and pages it invented (five
non-existent GitHub repos in one session on 2026-09-08). This hook allows a WebFetch
only when the URL equals, lies under, or is a still-specific ancestor (host/a/b) of a
URL that already appeared in the conversation in something other than the model's own
words: a user message, a web_search result, a file it read, a command's output. A bare
host that was mentioned licenses only its root page, never invented paths beneath it.
Anything else is denied with a reason that tells the model to search first.

Wired in config/settings.json under hooks.PreToolUse (matcher WebFetch). Claude Code
pipes {"tool_name", "tool_input": {"url"}, "transcript_path", ...} on stdin; a JSON
permissionDecision on stdout decides. Fails open (allows) when the transcript cannot
be read, so a broken hook never locks a session. CLAUDE_LOCAL_URLGUARD=0 disables it.

Manual test:
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"see https://example.com/docs/a"}}' > /tmp/t.jsonl
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/docs/a/b"},"transcript_path":"/tmp/t.jsonl"}' \
    | python3 config/hook-urlguard.py            # allowed: under a seen URL (no output)
  echo '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/other"},"transcript_path":"/tmp/t.jsonl"}' \
    | python3 config/hook-urlguard.py            # denied: prints a permissionDecision
"""
import json
import os
import re
import sys
import urllib.parse


def _texts(node, out):
    """Collect every text-ish string from a message content tree (str, text blocks, tool_result blocks)."""
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, list):
        for x in node:
            _texts(x, out)
    elif isinstance(node, dict):
        if node.get("type") in ("text", "tool_result"):
            _texts(node.get("content", node.get("text", "")), out)
        elif "text" in node:
            _texts(node["text"], out)


def seen_text(transcript_path):
    """Everything the model has been *shown* (user turns, tool results); never its own output."""
    out = []
    with open(transcript_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") != "user":
                continue
            _texts((d.get("message") or {}).get("content"), out)
    return "\n".join(out).lower()


URL_RE = re.compile(r'(?:https?://)?(?:www\.)?([a-z0-9][a-z0-9.-]*\.[a-z]{2,})(/[^\s"\'<>)\]]*)?', re.I)


def _split(host, path):
    host = host.lower()
    if host.startswith("www."):
        host = host[4:]
    parts = [p for p in urllib.parse.urlsplit("//" + host + (path or "")).path.split("/") if p]
    return host, parts


def seen_urls(text):
    """Every URL-looking token in the seen text as (host, path segments)."""
    return {(h, tuple(p)) for h, p in (_split(m.group(1), m.group(2)) for m in URL_RE.finditer(text))}


def allowed(url, text):
    """Allow if the URL equals a seen URL, lies under one, or is an ancestor that still has at
    least two path segments (repo root from a deep link). A bare host is allowed only as a root
    fetch, so a seen org or host never licenses invented paths beneath it."""
    u = urllib.parse.urlsplit(url.strip())
    if not u.netloc:
        return False
    host, parts = _split(u.netloc, u.path)
    parts = tuple(parts)
    for sh, sp in seen_urls(text):
        if sh != host:
            continue
        if parts == sp:
            return True
        if sp and parts[:len(sp)] == sp:          # descendant of a seen URL
            return True
        if len(parts) >= 2 and sp[:len(parts)] == parts:   # ancestor, still specific (host/a/b)
            return True
        if not parts:                             # root fetch of a host that was mentioned
            return True
    return False


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def main():
    if os.environ.get("CLAUDE_LOCAL_URLGUARD", "1") == "0":
        return
    try:
        req = json.load(sys.stdin)
    except ValueError:
        return
    if req.get("tool_name") != "WebFetch":
        return
    url = str((req.get("tool_input") or {}).get("url") or "")
    path = req.get("transcript_path") or ""
    try:
        text = seen_text(path) if path else ""
    except OSError as e:
        print(f"[urlguard] cannot read transcript ({e}); allowing", file=sys.stderr)
        return
    if not url or allowed(url, text):
        return
    deny(f"URL guard: {url} has not appeared in any user message, search result or tool output in this "
         "session, so it is probably invented. Search first with mcp__websearch__web_search and fetch a URL "
         "from the results, or ask the user for the exact address.")


if __name__ == "__main__":
    main()
