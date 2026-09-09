#!/usr/bin/env python3
"""Offline test of bin/claude-local itself: what Claude Code is started with. No model, no GPU, no
Claude Code: test/stub_upstream.py plays the llama-server router (one loaded preset "stub"), a fake
`claude` on PATH records its argv and environment and exits, and the launcher runs end to end (server
check, picker via CLAUDE_LOCAL_MODEL, context probe, system prompt, MCP config, proxy, flags, post-exit
menu on a closed stdin, archive). Asserts: autocompact fitted to the server context, the tool list,
--permission-mode acceptEdits by default and the caller's own mode winning, the six model aliases pinned
to the session model with CLAUDE_CODE_SUBAGENT_MODEL left unset (subagents follow /model), a claude-*
model name sent by the fake claude rewritten to the session model by the launcher-started proxy
(model_rewritten), the proxy URL in --settings and the environment, the cache-hygiene env, the
session archive with its session_start event, and that a stale run dir left by a killed launcher is
archived (session_reaped) before it is reaped. ~5 s."""
import glob
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
tmp = tempfile.mkdtemp(prefix="claude-local-launchertest-")
cfg = os.path.join(tmp, "cfg"); os.makedirs(os.path.join(cfg, "run"))
logs = os.path.join(tmp, "logs")
fails = []


def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c:
        fails.append(what)


for f in os.listdir(os.path.join(REPO, "config")):
    if f.endswith((".sh", ".py", ".md", ".json")):
        os.symlink(os.path.join(REPO, "config", f), os.path.join(cfg, f))
pf = os.path.join(tmp, "stub.port")
stub = subprocess.Popen([sys.executable, os.path.join(HERE, "stub_upstream.py")], stderr=subprocess.DEVNULL,
                        env=dict(os.environ, STUB_PORT_FILE=pf, REQUESTS_LOG=os.path.join(tmp, "req.jsonl")))
for _ in range(200):
    try:
        port = int(open(pf).read()); break
    except (OSError, ValueError):
        time.sleep(0.05)
open(os.path.join(cfg, "env"), "w").write(f': "${{CLAUDE_LOCAL_OLLAMA_PORT:=1}}"\n: "${{CLAUDE_LOCAL_LLAMASERVER_PORT:={port}}}"\n: "${{CLAUDE_LOCAL_BACKEND:=llamaserver}}"\n'
                                          ': "${CLAUDE_LOCAL_PORT:=$CLAUDE_LOCAL_LLAMASERVER_PORT}"\n')
# a run dir left by a launcher that was killed before its exit path
stale = 4194200
while True:
    try:
        os.kill(stale, 0); stale -= 1
    except ProcessLookupError:
        break
    except PermissionError:
        stale -= 1
sd = os.path.join(cfg, "run", str(stale)); os.makedirs(sd)
open(os.path.join(sd, "session_start"), "w").write(str(int(time.time()) - 100))
open(os.path.join(sd, "session_model"), "w").write("stub")
open(os.path.join(sd, "usage.jsonl"), "w").write('{"ts": 1, "model": "stub", "prompt": 10}\n')
fake_bin = os.path.join(tmp, "bin"); os.makedirs(fake_bin)
out_dir = os.path.join(tmp, "fake"); os.makedirs(out_dir)
# The fake claude records its argv and environment, then sends one turn through the proxy asking for a
# hosted model name (what the auto-mode classifier did on 2026-09-08): the launcher-started proxy must
# run it on the session model.
open(os.path.join(fake_bin, "claude"), "w").write('''#!/usr/bin/env bash
printf "%s\\n" "$@" > "$FAKE_OUT/argv"
env > "$FAKE_OUT/env"
curl -s --max-time 30 -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \\
  -d '{"model":"claude-sonnet-5","max_tokens":8,"stream":false,"system":"fake","messages":[{"role":"user","content":"classify"}]}' \\
  "$ANTHROPIC_BASE_URL/v1/messages" > "$FAKE_OUT/turn_status" 2>/dev/null || true
echo '{"result":"FAKEOK"}'
''')
os.chmod(os.path.join(fake_bin, "claude"), 0o755)
launcher = open(os.path.join(REPO, "bin", "claude-local")).read()
tools = re.search(r'^TOOLS="\$\{CLAUDE_LOCAL_TOOLS-(.*)\}"$', launcher, re.M).group(1)


def run(extra, tag):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") and not k.startswith("ANTHROPIC")}
    env.update(PATH=fake_bin + ":" + os.environ["PATH"], FAKE_OUT=out_dir, CLAUDE_LOCAL_CONFIG=cfg, CLAUDE_LOCAL_LOG_DIR=logs,
               CLAUDE_LOCAL_MODEL="stub", CLAUDE_LOCAL_EXCLUSIVE="0", CLAUDE_LOCAL_CHECKPOINT="0", CLAUDE_LOCAL_IDLE_UNLOAD="0",
               CLAUDE_LOCAL_PROXY_PORT="1330")
    r = subprocess.run([os.path.join(REPO, "bin", "claude-local")] + extra, env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    argv = open(os.path.join(out_dir, "argv")).read().splitlines() if os.path.exists(os.path.join(out_dir, "argv")) else []
    fenv = dict(l.split("=", 1) for l in open(os.path.join(out_dir, "env")).read().splitlines() if "=" in l) if os.path.exists(os.path.join(out_dir, "env")) else {}
    print(f"[{tag}] launcher exit {r.returncode}; banner: {next((l for l in r.stderr.splitlines() if 'Starting Claude Code' in l), '<none>')[:200]}")
    return r, argv, fenv


r, argv, fenv = run(["-p", "hi", "--output-format", "json"], "default")
check(r.returncode == 0 and "FAKEOK" in r.stdout, "launcher ran the fake claude and exited 0")
flag = lambda name: argv[argv.index(name) + 1] if name in argv else None  # noqa: E731
check(flag("--model") == "stub", "--model stub")
check(flag("--autocompact") == "112640", f"--autocompact fitted to n_ctx 131072 - 16384 - 2048 ({flag('--autocompact')})")
check(flag("--tools") == tools, "--tools is the launcher's default list")
check(flag("--permission-mode") == "acceptEdits", f"--permission-mode acceptEdits by default ({flag('--permission-mode')})")
check(argv[-3:] == ["-p", "hi", "--output-format"] or argv[-4:] == ["-p", "hi", "--output-format", "json"], "caller's own arguments passed through")
mcp = flag("--mcp-config")
check(bool(mcp) and os.path.exists(mcp) and "mcp-websearch.py" in open(mcp).read(), "--mcp-config file registers the web search server")
settings = json.loads(flag("--settings") or "{}")
proxy_url = (settings.get("env") or {}).get("ANTHROPIC_BASE_URL", "")
check(re.fullmatch(r"http://localhost:13[3-4][0-9]", proxy_url or "") is not None, f"--settings points at the proxy ({proxy_url})")
check(fenv.get("ANTHROPIC_BASE_URL") == proxy_url, "ANTHROPIC_BASE_URL in the environment is the proxy too")
aliases = ["ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
           "CLAUDE_CODE_AUTO_MODE_MODEL", "CLAUDE_CODE_BG_CLASSIFIER_MODEL", "CLAUDE_CONTEXT_COLLAPSE_MODEL"]
bad = [a for a in aliases if fenv.get(a) != "stub"]
check(not bad, f"every model alias pinned to the session model ({bad or 'all 6'})")
check("CLAUDE_CODE_SUBAGENT_MODEL" not in fenv, f"CLAUDE_CODE_SUBAGENT_MODEL left unset so subagents follow /model ({fenv.get('CLAUDE_CODE_SUBAGENT_MODEL', 'absent')})")
check(fenv.get("CLAUDE_CODE_TOTAL_TOKENS_REMINDER") == "off" and fenv.get("CLAUDE_CODE_ATTRIBUTION_HEADER") == "0", "cache hygiene env: total-tokens reminder off, attribution header off")
check(fenv.get("CLAUDE_CONFIG_DIR") == cfg and fenv.get("CLAUDE_CODE_MAX_OUTPUT_TOKENS") == "16384" and fenv.get("CLAUDE_LOCAL_PERMISSION_MODE") == "acceptEdits",
      "isolated config dir, max output and permission mode exported")
check("mode=acceptEdits" in r.stderr and "autocompact=112640" in r.stderr, "banner shows the mode and the fitted autocompact")
# archives: the stale dir was archived and reported before being reaped; this session archived itself at exit
check(not os.path.exists(sd) and glob.glob(os.path.join(logs, "sessions", f"*-{stale}")), "stale run dir archived, then reaped")
evs = [json.loads(l) for l in open(os.path.join(logs, "events.jsonl"))]
check(any(e["kind"] == "session_reaped" and e.get("pid") == stale for e in evs), "session_reaped event for the killed launcher")
# the fake claude's turn asked for claude-sonnet-5: the launcher-started proxy ran it on the session model
status = open(os.path.join(out_dir, "turn_status")).read() if os.path.exists(os.path.join(out_dir, "turn_status")) else ""
sent = [json.loads(l)["body"] for l in open(os.path.join(tmp, "req.jsonl")) if '"/v1/messages' in l]
rw = [e for e in evs if e["kind"] == "model_rewritten"]
check(status == "200" and bool(sent) and sent[-1].get("model") == "stub" and any(e.get("from") == "claude-sonnet-5" and e.get("to") == "stub" for e in rw),
      f"a claude-* model name is run on the session model by the launcher-started proxy (status {status!r}, stub saw {(sent[-1].get('model') if sent else None)!r}, model_rewritten events {len(rw)})")
live = [d for d in os.listdir(os.path.join(cfg, "run")) if d.isdigit()]
arch = glob.glob(os.path.join(logs, "sessions", f"*-{live[0]}")) if len(live) == 1 else []
check(bool(arch) and os.path.exists(os.path.join(arch[0], "events.jsonl")), "this session's files archived at exit")
sess_evs = [json.loads(l) for l in open(os.path.join(arch[0], "events.jsonl"))] if arch else []
check(any(e["kind"] == "session_start" and e.get("permission_mode") == "acceptEdits" for e in sess_evs)
      and any(e["kind"] == "claude_exit" and e.get("code") == 0 for e in sess_evs), "session_start (with permission_mode) and claude_exit events")
# the caller's own mode wins
r2, argv2, _ = run(["--permission-mode", "plan", "-p", "hi"], "caller mode")
check(argv2.count("--permission-mode") == 1 and argv2[argv2.index("--permission-mode") + 1] == "plan", "a caller-supplied --permission-mode is passed once, unchanged")
r3, argv3, _ = run(["--dangerously-skip-permissions", "-p", "hi"], "skip perms")
check("--permission-mode" not in argv3 and "--dangerously-skip-permissions" in argv3, "--dangerously-skip-permissions suppresses the launcher's mode")
# the picker's default: CLAUDE_LOCAL_DEFAULT_MODEL is listed first and Enter selects it
inv = os.path.join(tmp, "inv.json")
open(inv, "w").write(json.dumps({"models": [{"name": "alpha", "size": 1}, {"name": "beta-default", "size": 2}]}))
penv = dict(os.environ, MODELS_JSON_PATH=inv, LOADED_MODELS="alpha", CLAUDE_LOCAL_MODEL="", CLAUDE_LOCAL_DEFAULT_MODEL="beta-default")
r = subprocess.run([sys.executable, os.path.join(REPO, "config", "picker.py")], input="\n", capture_output=True, text=True, env=penv)
first = next((l for l in r.stderr.splitlines() if l.strip().startswith("1)")), "")
check(r.stdout.strip() == "LOAD|beta-default" and "beta-default" in first and "default" in first,
      f"picker lists the default model first and Enter picks it ({r.stdout.strip()!r}; line 1: {first.strip()[:70]!r})")
r = subprocess.run([sys.executable, os.path.join(REPO, "config", "picker.py")], input="2\n", capture_output=True, text=True, env=penv)
check(r.stdout.strip() == "USE|alpha", f"a number still picks by position after the reorder ({r.stdout.strip()!r})")
stub.terminate()
if fails:
    print(f"LAUNCHER FAIL ({len(fails)}): {fails}; artifacts in {tmp}"); sys.exit(1)
shutil.rmtree(tmp, ignore_errors=True)
print("LAUNCHER PASS")
