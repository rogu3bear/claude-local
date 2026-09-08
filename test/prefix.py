#!/usr/bin/env python3
"""Prefix-stability check: does Claude Code send a cache-friendly request sequence?

Offline (no model, no GPU): runs test/stub_upstream.py scripted to answer tool_use, tool_use,
end_turn, puts config/proxy.py in front of it, and runs `claude -p` with the launcher's exact
flags (system prompt file, snapshot, tool list, web search MCP, autocompact, max output). Then
diffs each request against the previous one the way the proxy's `div` field does, and prints
*what* changed: which system block, which tool schema, which message, with a text diff. A
sequence that is not "extension" on every turn after the first re-prefills the whole prompt on
a hybrid (SSM) model each turn, which is what cache_pct = 0 in the statusline means.

    test/prefix.py [--keep]        (~15 s; exit 1 when any turn after the first is not an extension)
"""
import difflib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CONFIG = os.environ.get("CLAUDE_LOCAL_CONFIG", os.path.expanduser("~/.claude-local"))
KEEP = "--keep" in sys.argv
tmp = tempfile.mkdtemp(prefix="claude-local-prefix-")
sess = os.path.join(tmp, "run", "1"); os.makedirs(sess)
procs = []


def wait_port(pf):
    for _ in range(200):
        try:
            return int(open(pf).read())
        except (OSError, ValueError):
            time.sleep(0.05)
    raise SystemExit(f"no port file {pf}")


reqlog = os.path.join(tmp, "requests.jsonl")
pf = os.path.join(tmp, "stub.port")
procs.append(subprocess.Popen([sys.executable, os.path.join(HERE, "stub_upstream.py")], stderr=subprocess.DEVNULL,
                              env=dict(os.environ, STUB_PORT_FILE=pf, REQUESTS_LOG=reqlog, STUB_SCRIPT="tool,tool,ok,ok,ok,ok")))
stub = wait_port(pf)
pf2 = os.path.join(tmp, "proxy.port")
procs.append(subprocess.Popen([sys.executable, os.path.join(REPO, "config", "proxy.py")], stderr=open(os.path.join(tmp, "proxy.log"), "w"),
                              env=dict(os.environ, PROXY_PORT="1310", PROXY_PORT_FILE=pf2, UPSTREAM_PORT=str(stub),
                                       USAGE_LOG=os.path.join(sess, "usage.jsonl"), PROXY_BACKEND="ollama", PROXY_CHECKPOINT_S="0",
                                       PROXY_IDLE_UNLOAD_S="0", PROXY_STATE_DIR=os.path.join(tmp, "run"),
                                       CLAUDE_LOCAL_SESSION_DIR=sess, CLAUDE_LOCAL_LOG_DIR=os.path.join(tmp, "logs"), PROXY_DEBUG="1")))
px = wait_port(pf2)

# the launcher's flags, verbatim from bin/claude-local
launcher = open(os.path.join(REPO, "bin", "claude-local")).read()
import re
tools = re.search(r'^TOOLS="\$\{CLAUDE_LOCAL_TOOLS-(.*)\}"$', launcher, re.M).group(1)
sp = os.path.join(tmp, "system_prompt.md")
open(sp, "w").write(open(os.path.join(REPO, "config", "system_prompt.md")).read().replace("{{MODEL}}", "stub"))
mcp = os.path.join(tmp, "mcp.json")
open(mcp, "w").write(json.dumps({"mcpServers": {"websearch": {"type": "stdio", "command": "python3", "args": [os.path.join(REPO, "config", "mcp-websearch.py")]}}}))
base = f"http://localhost:{px}"
flags = ["--model", "stub", "--autocompact", "112640", "--append-system-prompt-file", sp,
         "--system-prompt-snapshot", "on", "--exclude-dynamic-system-prompt-sections",
         "--tools", tools, "--mcp-config", mcp,
         "--settings", json.dumps({"env": {"ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": "local"}}),
         "--allowedTools", "Bash", "--max-turns", "3", "--output-format", "json",
         "-p", "Run `echo stub` twice using the Bash tool, then say done."]
env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE") and not k.startswith("CLAUDE_LOCAL") and not k.startswith("CLAUDE_CODE_TOTAL_TOKENS")) and k != "CLAUDE_PID"}
env.update(CLAUDE_CONFIG_DIR=CONFIG, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1",
           CLAUDE_CODE_MAX_OUTPUT_TOKENS="16384", CLAUDE_CODE_ATTRIBUTION_HEADER="0", ANTHROPIC_BASE_URL=base, ANTHROPIC_AUTH_TOKEN="local",
           CLAUDE_LOCAL_SESSION_DIR=sess, CLAUDE_LOCAL_BACKEND="stub", CLAUDE_LOCAL_TOOLS=tools)
work = os.path.join(tmp, "work"); os.makedirs(work)
subprocess.run("git init -q && echo a > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init", shell=True, cwd=work, check=True)
t0 = time.time()
r = subprocess.run(["claude"] + flags, cwd=work, env=env, capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL)
print(f"claude -p exit {r.returncode} in {time.time() - t0:.1f}s; stderr: {r.stderr.strip()[:300]!r}")
time.sleep(0.5)

reqs = [json.loads(l) for l in open(reqlog)]
turns = [q["body"] for q in reqs if q["path"].startswith("/v1/messages") and q["method"] == "POST"]
print(f"{len(turns)} Messages requests captured")


def scrub(o):
    """cache_control breakpoints move every turn and are never rendered by the server: ignore them."""
    if isinstance(o, dict):
        return {k: scrub(v) for k, v in o.items() if k != "cache_control"}
    if isinstance(o, list):
        return [scrub(x) for x in o]
    return o


def blocks(sysv):
    return [sysv] if isinstance(sysv, str) else [(b.get("text") if isinstance(b, dict) else json.dumps(b)) for b in (sysv or [])]


def text(m):
    c = m.get("content")
    if isinstance(c, str):
        return c
    return "\n".join((b.get("text") or json.dumps(b, sort_keys=True))[:2000] if isinstance(b, dict) else str(b) for b in (c or []))


def show_diff(a, b, label, n=30):
    d = list(difflib.unified_diff(a.splitlines(), b.splitlines(), "previous", "current", lineterm="", n=1))
    print(f"    --- {label}: {len(a)} -> {len(b)} chars; diff ({len(d)} lines, first {n}):")
    for line in d[:n]:
        print("      " + line[:160])


bad = 0
for i, cur in enumerate(turns):
    sb = blocks(cur.get("system")); tl = cur.get("tools") or []; ms = cur.get("messages") or []
    roles = ",".join(m.get("role", "?")[0] for m in ms)
    print(f"\nrequest {i + 1}: system {len(sb)} blocks/{sum(map(len, sb))} chars, {len(tl)} tools/{len(json.dumps(tl))} chars, {len(ms)} messages [{roles}], ~{len(json.dumps(cur)) // 4} tokens")
    if i == 0:
        print("  (first request: baseline)")
        continue
    prev = turns[i - 1]
    pb = blocks(prev.get("system")); ptl = prev.get("tools") or []; pms = scrub(prev.get("messages") or [])
    ms = scrub(ms)
    where = "extension"
    if pb != sb:
        where = "system"
        k = next((j for j, (x, y) in enumerate(zip(pb, sb)) if x != y), min(len(pb), len(sb)))
        print(f"  DIVERGES at system block {k} ({len(pb)} -> {len(sb)} blocks)")
        if k < len(pb) and k < len(sb):
            show_diff(pb[k], sb[k], f"system[{k}]")
        elif k < len(sb):
            print(f"    added block: {sb[k][:300]!r}")
    elif ptl != tl:
        where = "tools"
        pn = {t["name"]: t for t in ptl}; cn = {t["name"]: t for t in tl}
        print(f"  DIVERGES at tools: added={sorted(set(cn) - set(pn))} removed={sorted(set(pn) - set(cn))} "
              f"reordered={[t['name'] for t in ptl] != [t['name'] for t in tl]}")
        for name in cn:
            if name in pn and pn[name] != cn[name]:
                show_diff(json.dumps(pn[name], indent=1, sort_keys=True), json.dumps(cn[name], indent=1, sort_keys=True), f"tool {name}")
    else:
        common = 0
        for a, b in zip(pms, ms):
            if json.dumps(a, sort_keys=True) != json.dumps(b, sort_keys=True):
                break
            common += 1
        if common == len(pms):
            print(f"  extension: +{len(ms) - len(pms)} messages (cache-friendly)")
        else:
            where = f"messages[{common}]"
            print(f"  DIVERGES at message {common} ({pms[common].get('role')}); history {len(pms)} -> {len(ms)}")
            show_diff(text(pms[common]), text(ms[common]), f"messages[{common}]")
    if where != "extension":
        bad += 1

rows = [json.loads(l) for l in open(os.path.join(sess, "usage.jsonl"))] if os.path.exists(os.path.join(sess, "usage.jsonl")) else []
print("\nproxy usage rows (div):", [(r.get("msgs"), r.get("div")) for r in rows])
for p in procs:
    p.terminate()
if KEEP:
    print(f"artifacts kept in {tmp}")
else:
    shutil.rmtree(tmp, ignore_errors=True)
print("PREFIX PASS" if bad == 0 and len(turns) >= 2 else f"PREFIX FAIL: {bad} of {len(turns) - 1} follow-up requests are not pure extensions")
sys.exit(0 if bad == 0 and len(turns) >= 2 else 1)
