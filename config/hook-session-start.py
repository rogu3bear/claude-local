#!/usr/bin/env python3
"""SessionStart hook: if this repo has no per-project safety net, suggest one."""
import json, os, subprocess, sys

try:
    json.load(sys.stdin)
except Exception:
    pass

def in_git():
    try:
        r = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() == "true"
    except Exception:
        return False

cwd = os.getcwd()
if in_git() and not os.path.exists(os.path.join(cwd, ".claude", "scripts", "verify.sh")):
    print(json.dumps({"systemMessage":
        "This repo has no verify-gate/heal safety net. Run `claude-local-init` "
        "here to add one (a green build/test check, a heal loop, and a Stop "
        "gate that refuses to finish on a red tree)."}))
sys.exit(0)
