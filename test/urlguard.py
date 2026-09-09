#!/usr/bin/env python3
"""Offline test of config/hook-urlguard.py: seen URLs, descendants, roots, invented paths, the model's own
words, loopback hosts with ports, trailing punctuation. < 1 s."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(os.path.dirname(HERE), "config", "hook-urlguard.py")
tmp = tempfile.mkdtemp(prefix="claude-local-urlguardtest-")
transcript = os.path.join(tmp, "t.jsonl")
with open(transcript, "w") as f:
    for row in (
        {"type": "user", "message": {"role": "user", "content": "docs at https://example.com/docs/a, dev server http://localhost:3000/api and the api at 127.0.0.1:8080; "
                                                                  "repo https://github.com/org/repo/tree/main/src (see also www.Example.com/docs/b.)"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "I will fetch https://example.com/assistant-only and https://invented.dev/x"}]}},
        {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "1. Foo\n   https://pypi.org/project/foo/\n   a package"}]}},
    ):
        f.write(json.dumps(row) + "\n")
fails = []


def run(url, expect_deny, what, extra_env=None):
    payload = {"tool_name": "WebFetch", "tool_input": {"url": url}, "transcript_path": transcript}
    r = subprocess.run([sys.executable, HOOK], input=json.dumps(payload), capture_output=True, text=True, env={**os.environ, **(extra_env or {})})
    denied = '"deny"' in r.stdout
    ok = denied == expect_deny and r.returncode == 0
    print(("ok   " if ok else "FAIL ") + f"{what}: {url}" + ("" if ok else f"  (stdout={r.stdout.strip()[:160]!r} stderr={r.stderr.strip()[:160]!r})"))
    if not ok:
        fails.append(what)


run("https://example.com/docs/a", False, "seen URL")
run("https://example.com/docs/a/b", False, "descendant of a seen URL")
run("https://example.com/docs/b", False, "seen URL followed by punctuation")
run("https://example.com/", False, "root of a mentioned host")
run("https://example.com/other", True, "invented path on a mentioned host")
run("https://github.com/org/repo", False, "repo root from a deep link (ancestor with two segments)")
run("https://github.com/org", True, "org page (ancestor too shallow)")
run("https://github.com/org/other-repo", True, "invented sibling repo")
run("https://pypi.org/project/foo/", False, "URL from a tool result")
run("https://example.com/assistant-only", True, "URL only in the model's own words")
run("https://invented.dev/x", True, "host only in the model's own words")
run("http://localhost:3000/api", False, "loopback URL the user typed")
run("http://localhost:3000/api/users", False, "descendant of the loopback URL")
run("http://localhost:3000/", False, "root of the loopback host")
run("http://localhost:3000/admin", True, "invented path on the loopback host")
run("http://localhost:9999/", True, "another port is another host")
run("http://127.0.0.1:8080/", False, "bare ip:port mention licenses its root")
run("http://127.0.0.1:8080/health", True, "invented path under a bare ip:port mention")
run("https://example.com/other", False, "guard off with CLAUDE_LOCAL_URLGUARD=0", {"CLAUDE_LOCAL_URLGUARD": "0"})
subprocess.run(["rm", "-rf", tmp])
if fails:
    print(f"URLGUARD FAIL ({len(fails)}): {fails}")
    sys.exit(1)
print("URLGUARD PASS")
