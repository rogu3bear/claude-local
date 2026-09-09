#!/usr/bin/env python3
"""Guard-under-permission-mode check: in every permission mode the launcher can pin, a Bash command the
guard refuses must still be refused. Offline (no model, no GPU): test/stub_upstream.py answers the first
turn with a Bash tool_use for `git push --force origin main` (harmless in a scratch repo with no remote,
should it ever run); a real `claude -p` runs with the isolated config (so the hooks in config/settings.json
fire), --allowedTools Bash (the permission system itself says yes) and the mode under test. The second
request the stub receives must carry the guard's denial as the tool_result, and run/<pid>/tools.jsonl must
hold the denied row. ~15 s per mode.

    test/guard_mode.py [mode ...]        (default: acceptEdits bypassPermissions; exit 1 on any failure)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CONFIG = os.environ.get("CLAUDE_LOCAL_CONFIG", os.path.expanduser("~/.claude-local"))
MODES = sys.argv[1:] or ["acceptEdits", "bypassPermissions"]
CMD = "git push --force origin main"
fails = []


def wait_port(pf):
    for _ in range(200):
        try:
            return int(open(pf).read())
        except (OSError, ValueError):
            time.sleep(0.05)
    raise SystemExit(f"no port file {pf}")


def check(mode):
    tmp = tempfile.mkdtemp(prefix=f"claude-local-guard-{mode}-")
    sess = os.path.join(tmp, "run", "1"); os.makedirs(sess)
    reqlog = os.path.join(tmp, "requests.jsonl"); pf = os.path.join(tmp, "stub.port")
    stub = subprocess.Popen([sys.executable, os.path.join(HERE, "stub_upstream.py")], stderr=subprocess.DEVNULL,
                            env=dict(os.environ, STUB_PORT_FILE=pf, REQUESTS_LOG=reqlog, STUB_SCRIPT="tool,ok,ok", STUB_TOOL_CMD=CMD))
    try:
        port = wait_port(pf)
        base = f"http://localhost:{port}"
        env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE") and not k.startswith("CLAUDE_LOCAL")) and k != "CLAUDE_PID"}
        env.update(CLAUDE_CONFIG_DIR=CONFIG, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1",
                   CLAUDE_CODE_ATTRIBUTION_HEADER="0", ANTHROPIC_BASE_URL=base, ANTHROPIC_AUTH_TOKEN="local",
                   CLAUDE_LOCAL_SESSION_DIR=sess, CLAUDE_LOCAL_LOG_DIR=os.path.join(tmp, "logs"), CLAUDE_LOCAL_BACKEND="stub")
        work = os.path.join(tmp, "work"); os.makedirs(work)
        subprocess.run("git init -q && echo a > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init", shell=True, cwd=work, check=True)
        flags = ["--model", "stub", "--permission-mode", mode, "--allowedTools", "Bash", "--max-turns", "3", "--output-format", "json",
                 "--settings", json.dumps({"env": {"ANTHROPIC_BASE_URL": base, "ANTHROPIC_AUTH_TOKEN": "local"}}),
                 "-p", f"Run `{CMD}` using the Bash tool, then say done."]
        t0 = time.time()
        r = subprocess.run(["claude"] + flags, cwd=work, env=env, capture_output=True, text=True, timeout=180, stdin=subprocess.DEVNULL)
        time.sleep(0.5)
        turns = [json.loads(l)["body"] for l in open(reqlog) if '"/v1/messages' in l]
        results = []
        for t in turns[1:]:
            for m in t.get("messages") or []:
                for b in (m.get("content") if isinstance(m.get("content"), list) else []):
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        c = b.get("content")
                        results.append(c if isinstance(c, str) else " ".join(x.get("text", "") for x in c if isinstance(x, dict)))
        text = "\n".join(results)
        rows = [json.loads(l) for l in open(os.path.join(sess, "tools.jsonl"))] if os.path.exists(os.path.join(sess, "tools.jsonl")) else []
        denied_rows = [x for x in rows if x.get("denied") and CMD in x.get("summary", "")]
        ran = "does not appear to be a git repository" in text or "fatal:" in text
        ok = (r.returncode == 0 and len(turns) >= 2 and "claude-local guard" in text and not ran and denied_rows)
        print(f"{'PASS' if ok else 'FAIL'}  {mode}: claude exit {r.returncode} in {time.time() - t0:.1f}s, {len(turns)} requests, "
              f"guard text {'present' if 'claude-local guard' in text else 'MISSING'}, command {'RAN' if ran else 'did not run'}, "
              f"{len(denied_rows)} denied audit row(s)")
        if not ok:
            print(f"      stderr: {r.stderr.strip()[:400]!r}\n      tool_result: {text[:400]!r}")
            fails.append(mode)
    finally:
        stub.terminate()
        # Claude Code's transcript of this run: projects/<physical work dir with every non-alphanumeric
        # character turned into "-"> in the isolated config (same rule in test/prefix.py and bench/run.sh)
        transcript = os.path.join(CONFIG, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(os.path.join(tmp, "work"))))
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(transcript, ignore_errors=True)


for mode in MODES:
    check(mode)
if fails:
    print(f"GUARD-MODE FAIL: {fails}"); sys.exit(1)
print("GUARD-MODE PASS")
