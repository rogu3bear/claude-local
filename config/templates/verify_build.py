#!/usr/bin/env python3
"""Generic verify-gate Stop hook (scaffolded by claude-local-init).

On stop, runs .claude/scripts/verify.sh ("green" = exit 0). If red, blocks the
stop and feeds the errors back, up to MAX_ATTEMPTS; after that it calls
.claude/scripts/heal.sh recover to restore the last green commit. Skips entirely
when the working tree has no changes at all (nothing to verify).
"""
import json, os, subprocess, sys

MAX_ATTEMPTS = 3


def root():
    return os.environ.get("CLAUDE_PROJECT_DIR") or _git_root() or os.getcwd()


def _git_root():
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() or None
    except Exception:
        return None


def counter_path(sid):
    sid = "".join(c for c in (sid or "n") if c.isalnum() or c in "-_")
    return os.path.join("/tmp", f"claude-verify-{sid}.count")


def read_count(p):
    try:
        return int(open(p).read().strip())
    except Exception:
        return 0


def tree_dirty(cwd):
    try:
        r = subprocess.run(["git", "status", "--porcelain"], cwd=cwd,
                           capture_output=True, text=True, timeout=10)
        return bool(r.stdout.strip())
    except Exception:
        return True  # can't tell -> verify anyway


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    cwd = root()
    if not tree_dirty(cwd):
        print(json.dumps({"systemMessage": "verify-gate: no changes; skipped."}))
        sys.exit(0)

    try:
        proc = subprocess.run(["bash", ".claude/scripts/verify.sh"], cwd=cwd,
                              capture_output=True, text=True, timeout=600)
    except Exception as e:
        print(json.dumps({"systemMessage": f"verify-gate: could not run verify.sh ({e}); skipping."}))
        sys.exit(0)

    if proc.returncode == 0:
        try:
            os.remove(counter_path(payload.get("session_id", "")))
        except Exception:
            pass
        sys.exit(0)

    detail = "\n".join(
        l for l in (proc.stderr + "\n" + proc.stdout).splitlines() if l.strip()
    )[-1800:]

    cp = counter_path(payload.get("session_id", ""))
    n = read_count(cp) + 1
    try:
        open(cp, "w").write(str(n))
    except Exception:
        pass

    if n < MAX_ATTEMPTS:
        print(json.dumps({
            "decision": "block",
            "reason": (f"verify.sh is FAILING — do not finish on a red tree. "
                       f"Fix these, then re-check (attempt {n}/{MAX_ATTEMPTS}):\n\n{detail}"),
        }))
    else:
        try:
            os.remove(cp)
        except Exception:
            pass
        rec = subprocess.run(["bash", ".claude/scripts/heal.sh", "recover"], cwd=cwd,
                             capture_output=True, text=True, timeout=120)
        print(json.dumps({
            "systemMessage": ("verify-gate: still red after "
                              f"{MAX_ATTEMPTS} attempts; auto-recovered to the last green "
                              "commit (broken state preserved on a branch + stash).\n"
                              + (rec.stdout or rec.stderr).strip()),
        }))
    sys.exit(0)


if __name__ == "__main__":
    main()
