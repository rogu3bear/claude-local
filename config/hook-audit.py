#!/usr/bin/env python3
"""claude-local: tool-call audit log and guard rails (PreToolUse / PostToolUse / PostToolUseFailure).

Wired in config/settings.json for every tool. Two jobs:

1. Audit. Every call is one line in $CLAUDE_LOCAL_SESSION_DIR/tools.jsonl:
     {"ts", "event": "pre|post|fail", "tool", "summary": <command / path / url / first arg>,
      "ok": true|false, "ms": <since the pre event>, "err": <first line of the error>}
   Failures and denials are also events (clog.py: tool_failed, tool_denied) in events.jsonl
   and ~/.claude-local/logs, so the doctor and the statusline see them.

2. Guards (PreToolUse deny with a reason the model can act on). Small local models do these
   things; each was seen or is one keystroke away in this setup:
     * Bash: destroying the tree or the box (rm -rf on /, ~, the cwd, .git; mkfs, dd to a disk),
       force-pushing, resetting/cleaning the working tree, killing everything (kill -9 -1),
       and, most relevant here, stopping or restarting the very server or proxy that is serving
       this session (systemctl restart llama-server/ollama, fuser -k <port>, pkill llama-server,
       kill <proxy pid>). The "diagnose" skill used to suggest exactly that.
     * Write/Edit: the mangled paths this harness has produced (a flattened
       "-home-user-dir" segment, invented /tmp/claude-* files), and anything under the real
       ~/.claude, /etc, /usr, /boot. Writes outside the working directory are allowed but
       logged as tool_outside_cwd so they can be reviewed.
   Fails open: any exception in this hook allows the call and logs hook_exception. Env:
   CLAUDE_LOCAL_BASHGUARD=0, CLAUDE_LOCAL_PATHGUARD=0 disable each; CLAUDE_LOCAL_AUDIT=0 logs nothing.

Manual test (see test/hook_audit.py for the full set):
  echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"systemctl --user restart llama-server.service"}}' | python3 config/hook-audit.py
"""
import json
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import clog
except ImportError:  # running from a copy without clog.py next to it
    clog = None

SESSION_DIR = os.environ.get("CLAUDE_LOCAL_SESSION_DIR") or ""
AUDIT = os.path.join(SESSION_DIR, "tools.jsonl") if SESSION_DIR else ""
PENDING = os.path.join(SESSION_DIR, "tools.pending.json") if SESSION_DIR else ""
HOME = os.path.expanduser("~")


def event(kind, level, hint=None, **f):
    if clog:
        try:
            clog.event(kind, level, "hook", hint, **f)
        except Exception:  # noqa: BLE001
            pass


def audit(row):
    if not AUDIT or os.environ.get("CLAUDE_LOCAL_AUDIT", "1") == "0":
        return
    try:
        with open(AUDIT, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    except OSError:
        pass


def summary(tool, inp):
    inp = inp or {}
    for k in ("command", "file_path", "url", "pattern", "query", "prompt", "description", "path", "notebook_path", "subject"):
        v = inp.get(k)
        if isinstance(v, str) and v:
            return v[:200]
    return json.dumps(inp, ensure_ascii=False)[:200]


# --------------------------------------------------------------------- guards ------
def serving_ports():
    """Ports this session depends on: the backend and its proxy."""
    ports = set()
    for k in ("CLAUDE_LOCAL_PORT", "CLAUDE_LOCAL_OLLAMA_PORT", "CLAUDE_LOCAL_LLAMASERVER_PORT"):
        v = os.environ.get(k)
        if v and v.isdigit():
            ports.add(v)
    ports.update({"1234", "1244"})
    try:
        ports.add(open(os.path.join(SESSION_DIR, "proxy_port")).read().strip())
    except OSError:
        pass
    return ports


BASH_RULES = [
    # (regex on the whole command, reason)
    (r"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*|-r\s+-f|-f\s+-r)\s+(--\s+)?(/|~|\$HOME|\$\{HOME\}|/home/?|\.\.?|\*|\.git)(\s|$|/\*)",
     "recursive delete of the root, home, the working directory, its parent or .git"),
    (r"\bmkfs(\.\w+)?\b|\bdd\s+.*\bof=/dev/(sd|nvme|hd|vd|mmcblk)|\bwipefs\b|>\s*/dev/(sd|nvme|hd|vd|mmcblk)",
     "writes to a block device"),
    (r"\bgit\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b)", "force push rewrites shared history; ask the user"),
    (r"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*[fdx]|checkout\s+--\s+\.|restore\s+(--staged\s+)?\.)(\s|$)",
     "discards uncommitted work in the working tree; ask the user"),
    (r"\bkill\s+(-9\s+|-KILL\s+|-SIGKILL\s+)?-1\b|\bpkill\s+(-9\s+)?(-f\s+)?(\.|\*|'\.'|\"\.\")\s*$|\bkillall5\b",
     "kills every process of the user, including this session"),
    (r"\bchmod\s+(-R\s+)?[0-7]*777\s+/(\s|$)|\bchown\s+-R\s+.*\s+/(\s|$)", "recursive permission change on /"),
    (r"\bsystemctl\s+(--user\s+)?(stop|restart|kill|disable|mask)\s+.*(llama-server|ollama)",
     "stops or restarts the model server that is serving this very session; the turn would die. "
     "Ask the user, or use the post-exit menu of claude-local"),
    (r"\b(pkill|killall)\s+.*(llama-server|ollama|proxy\.py)\b", "kills the model server or the usage proxy serving this session"),
    (r"\b(shutdown|reboot|halt|poweroff)\b|\bsystemctl\s+(reboot|poweroff|halt|suspend|hibernate)\b", "reboots or powers off the machine"),
    (r":\(\)\s*\{\s*:\|:&\s*\};:", "fork bomb"),
    (r"\bcurl\b[^|]*\|\s*(sudo\s+)?(ba)?sh\b|\bwget\b[^|]*\|\s*(sudo\s+)?(ba)?sh\b", "pipes a download straight into a shell; download and read it first"),
]


def bash_denial(cmd):
    if os.environ.get("CLAUDE_LOCAL_BASHGUARD", "1") == "0":
        return None
    flat = " ".join(cmd.split())
    for rx, why in BASH_RULES:
        if re.search(rx, flat):
            return why
    ports = serving_ports()
    m = re.search(r"\bfuser\s+(-[a-zA-Z]*k[a-zA-Z]*)\s+(\d+)/tcp", flat)
    if m and m.group(2) in ports:
        return f"frees port {m.group(2)}, which is the server or proxy serving this session"
    m = re.search(r"\bkill\s+(-\w+\s+)?(\d+)", flat)
    if m:
        pid = m.group(2)
        try:
            proxy_pid = None
            if SESSION_DIR:
                launcher = os.path.basename(SESSION_DIR.rstrip("/"))
                if pid == launcher:
                    return "kills the claude-local launcher of this session"
            cmdline = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
            if "proxy.py" in cmdline or "llama-server" in cmdline or "ollama serve" in cmdline or "claude" in cmdline.split(" ")[0]:
                return f"kills pid {pid} ({cmdline.strip()[:60]}), part of the stack serving this session"
        except OSError:
            pass
    return None


def path_denial(path, cwd):
    if os.environ.get("CLAUDE_LOCAL_PATHGUARD", "1") == "0":
        return None, False
    if not path:
        return None, False
    p = os.path.abspath(os.path.join(cwd or os.getcwd(), os.path.expanduser(path)))
    parts = [s for s in p.split("/") if s]
    home_flat = "-" + HOME.strip("/").replace("/", "-")            # "-home-user"
    if any(s.startswith(home_flat) or re.fullmatch(r"-(home|tmp|usr|etc|var)(-[\w.]+)+", s) for s in parts):
        return "the path contains a flattened directory (slashes turned into dashes). Use the working directory verbatim and append the file name", False
    if re.match(r"^/tmp/claude-[^/]*/", p) and not os.path.isdir(os.path.dirname(p)):
        return "invented /tmp/claude-* location (its directory does not exist); write into the working directory instead", False
    real_claude = os.path.join(HOME, ".claude") + "/"
    if p.startswith(real_claude) or p == real_claude.rstrip("/"):
        return "this is the user's real ~/.claude configuration; the local session must never write there", False
    for root in ("/etc/", "/usr/", "/boot/", "/bin/", "/sbin/", "/lib/", "/proc/", "/sys/"):
        if p.startswith(root):
            return f"system path {root}; ask the user", False
    outside = bool(cwd) and not (p == cwd or p.startswith(cwd.rstrip("/") + "/")) and not p.startswith("/tmp/")
    return None, outside


def deny(reason, tool, detail):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                      "permissionDecisionReason": f"claude-local guard: {reason}. ({tool}: {detail[:120]})"}}))


# --------------------------------------------------------------------- main --------
def error_of(resp):
    """(is_error, first line) from a PostToolUse tool_response of any shape."""
    if resp is None:
        return False, ""
    if isinstance(resp, str):
        s = resp.strip()
        bad = s.lower().startswith(("error", "exit code", "command failed", "enoent", "permission denied"))
        return bad, s.splitlines()[0][:200] if s else ""
    if isinstance(resp, dict):
        if resp.get("is_error") or resp.get("isError") or resp.get("error"):
            msg = resp.get("error") or resp.get("message") or resp.get("stderr") or json.dumps(resp)
            return True, str(msg).splitlines()[0][:200]
        if "interrupted" in resp and resp.get("interrupted"):
            return True, "interrupted"
        if resp.get("stderr") and not resp.get("stdout"):
            return False, str(resp["stderr"]).splitlines()[0][:200]
    if isinstance(resp, list):
        for b in resp:
            if isinstance(b, dict) and b.get("is_error"):
                return True, str(b.get("content") or b.get("text") or "")[:200]
    return False, ""


def main():
    try:
        req = json.load(sys.stdin)
    except ValueError:
        return
    try:
        ev = req.get("hook_event_name") or ""
        tool = req.get("tool_name") or "?"
        inp = req.get("tool_input") or {}
        cwd = req.get("cwd") or os.getcwd()
        summ = summary(tool, inp)
        now = time.time()
        if ev == "PreToolUse":
            reason = None
            outside = False
            if tool == "Bash":
                reason = bash_denial(str(inp.get("command") or ""))
            elif tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
                reason, outside = path_denial(str(inp.get("file_path") or inp.get("notebook_path") or ""), cwd)
            row = {"ts": round(now, 3), "event": "pre", "tool": tool, "summary": summ}
            if reason:
                row["denied"] = reason
                audit(row)
                event("tool_denied", "warn", tool=tool, summary=summ, reason=reason,
                      hint="the guard in hook-audit.py refused this call; CLAUDE_LOCAL_BASHGUARD=0 / CLAUDE_LOCAL_PATHGUARD=0 disable it")
                deny(reason, tool, summ)
                return
            if outside:
                row["outside_cwd"] = True
                event("tool_outside_cwd", "info", tool=tool, path=summ, cwd=cwd)
            audit(row)
            if PENDING:
                try:
                    with open(PENDING, "w") as f:
                        json.dump({"tool": tool, "ts": now, "id": req.get("tool_use_id")}, f)
                except OSError:
                    pass
        elif ev in ("PostToolUse", "PostToolUseFailure"):
            ms = None
            try:
                pend = json.load(open(PENDING))
                if pend.get("tool") == tool:
                    ms = int((now - pend["ts"]) * 1000)
            except (OSError, ValueError, KeyError, TypeError):
                pass
            if ev == "PostToolUseFailure":
                bad, err = True, str(req.get("error") or req.get("tool_response") or "")[:200].splitlines()[0] if (req.get("error") or req.get("tool_response")) else "failed"
            else:
                bad, err = error_of(req.get("tool_response"))
            row = {"ts": round(now, 3), "event": "fail" if ev == "PostToolUseFailure" else "post", "tool": tool,
                   "summary": summ, "ok": not bad}
            if ms is not None:
                row["ms"] = ms
            if err:
                row["err"] = err
            audit(row)
            if bad:
                event("tool_failed", "warn", tool=tool, summary=summ, err=err, ms=ms)
    except Exception as e:  # noqa: BLE001  never block a tool call because of the audit
        event("hook_exception", "error", where="hook-audit", error=repr(e))


if __name__ == "__main__":
    main()
