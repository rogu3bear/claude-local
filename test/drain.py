#!/usr/bin/env python3
"""Offline test of bin/claude-local-drain against test/stub_upstream.py (no GPU, no server). ~3 s.
Cases: a live session keeps its model; a request in flight keeps it; an idle model with no live
session is checkpointed and unloaded after the grace; the ollama side is skipped when unreachable."""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DRAIN = os.path.join(REPO, "bin", "claude-local-drain")
fails = []


def check(c, what):
    print(("ok   " if c else "FAIL ") + what)
    if not c:
        fails.append(what)


def stub(processing=False):
    tmp = tempfile.mkdtemp(prefix="claude-local-draintest-")
    pf = os.path.join(tmp, "port")
    p = subprocess.Popen([sys.executable, os.path.join(HERE, "stub_upstream.py")], stderr=subprocess.DEVNULL,
                         env=dict(os.environ, STUB_PORT_FILE=pf, REQUESTS_LOG=os.path.join(tmp, "req.jsonl"), STUB_PROCESSING="1" if processing else "0"))
    for _ in range(200):
        try:
            port = int(open(pf).read()); break
        except (OSError, ValueError):
            time.sleep(0.05)
    cfg = os.path.join(tmp, "cfg"); os.makedirs(os.path.join(cfg, "run"))
    open(os.path.join(cfg, "env"), "w").write(f': "${{CLAUDE_LOCAL_LLAMASERVER_PORT:={port}}}"\n: "${{CLAUDE_LOCAL_OLLAMA_PORT:=1}}"\n')
    os.symlink(os.path.join(REPO, "config", "clog.py"), os.path.join(cfg, "clog.py"))
    return tmp, p, cfg, port


def run(cfg, *args):
    r = subprocess.run([sys.executable, DRAIN, *args], capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if not k.startswith("CLAUDE_LOCAL")} | {"CLAUDE_LOCAL_CONFIG": cfg, "CLAUDE_LOCAL_LOG_DIR": os.path.join(cfg, "logs")})
    return r.returncode, r.stdout, r.stderr


def requests(tmp):
    return [json.loads(l) for l in open(os.path.join(tmp, "req.jsonl"))]


# 1. idle model, no session, past grace -> checkpoint + unload
tmp, p, cfg, port = stub()
json.dump({"stub": time.time() - 1000}, open(os.path.join(cfg, "run", "last_use.json"), "w"))
rc, out, err = run(cfg, "--status", "--json")
st = json.loads(out)
check(rc == 0 and st["models"][0]["verdict"] == "drain" and st["threshold_s"] == 300, f"status: verdict drain with no session ({st['models'][0]['verdict']})")
rc, out, err = run(cfg)
paths = [q["path"] for q in requests(tmp) if q["method"] == "POST"]
check(rc == 0 and "drained stub" in out and "/slots/0?action=save" in paths and "/models/unload" in paths, f"drain performed save then unload ({paths})")
ev = [json.loads(l) for l in open(os.path.join(cfg, "logs", "events.jsonl"))]
check(any(e["kind"] == "drain_unload" and e["checkpoint_tokens"] == 1234 for e in ev), "drain_unload event with checkpoint size")
rc, out, err = run(cfg, "--status")
check("nothing resident" in out, "after the unload nothing is resident")
p.terminate()

# 2. idle but within grace -> keep
tmp, p, cfg, port = stub()
json.dump({"stub": time.time() - 100}, open(os.path.join(cfg, "run", "last_use.json"), "w"))
rc, out, err = run(cfg)
check("keep: idle" in out and "/models/unload" not in [q["path"] for q in requests(tmp)], "within grace: kept")
# 3. a live session on the model -> keep, even when idle for long
os.makedirs(os.path.join(cfg, "run", str(os.getpid())))
open(os.path.join(cfg, "run", str(os.getpid()), "session_model"), "w").write("stub")
json.dump({"stub": time.time() - 99999}, open(os.path.join(cfg, "run", "last_use.json"), "w"))
rc, out, err = run(cfg)
check("keep: session" in out and "/models/unload" not in [q["path"] for q in requests(tmp)], "live session: kept")
# 4. live session on ANOTHER model: idle-unload threshold (1200) applies, 99999s idle -> drain
open(os.path.join(cfg, "run", str(os.getpid()), "session_model"), "w").write("other")
rc, out, err = run(cfg, "--dry-run")
check("drain" in out.splitlines()[-1] and "threshold 1200s" in out, "session on another model: idle-unload rule, drain")
p.terminate()

# 5. request in flight -> keep
tmp, p, cfg, port = stub(processing=True)
json.dump({"stub": time.time() - 99999}, open(os.path.join(cfg, "run", "last_use.json"), "w"))
rc, out, err = run(cfg)
check("keep: request in flight" in out and "/models/unload" not in [q["path"] for q in requests(tmp)], "request in flight: kept")
p.terminate()
# 6. no ledger entry: aged from first sight
tmp, p, cfg, port = stub()
rc, out, err = run(cfg, "--dry-run")
check("keep: idle 0s" in out and os.path.exists(os.path.join(cfg, "run", "drain_seen.json")), "unknown model aged from first sight")
p.terminate()

if fails:
    print(f"DRAIN FAIL ({len(fails)}): {fails}"); sys.exit(1)
print("DRAIN PASS")
