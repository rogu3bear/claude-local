#!/usr/bin/env python3
"""claude-local universal safety guard (PreToolUse).

Project-agnostic footgun protection for a small local model working in ANY
repo under this harness. It blocks a few classes of self-harm and asks before a
couple of hard-to-undo, outward-facing actions. It is NOT an adversarial
sandbox — it stops a confused model from wrecking a working tree, not a
determined bypass.

Per-project configs add language-specific rules on top (build artifacts, DB
files, etc.); this layer is the universal baseline every session inherits.

Reads the Claude Code hook JSON on stdin, writes a PreToolUse decision on
stdout (permissionDecision: allow | deny | ask). Fail-OPEN on any internal
error; fail-CLOSED on a matched destructive/protected pattern.
"""

import json
import os
import re
import sys

# ------------------------------ CONFIG ---------------------------------------

_GIT = "git"

# Destructive shell/git -> DENY.
DESTRUCTIVE_RES = [
    (re.compile(r"\brm\b[^|;&]*\s-[a-zA-Z]*[rf][a-zA-Z]*\b[^|;&]*(\s|=|/)(\.(\s|/|$)|~|/\s|/$|\*)"),
     "recursive/forced rm reaching the working tree, home, root, or *"),
    (re.compile(_GIT + r"\s+reset\s+--hard\b"),
     "hard reset (discards uncommitted work)"),
    (re.compile(_GIT + r"\s+checkout\s+(--\s+)?\.(\s|$)"),
     "checkout of '.' (discards uncommitted changes)"),
    (re.compile(_GIT + r"\s+checkout\s+--\s+\S"),
     "checkout of a path (discards uncommitted changes to it)"),
    (re.compile(_GIT + r"\s+clean\s+-[a-zA-Z]*f"),
     "clean -f (deletes untracked files)"),
    (re.compile(_GIT + r"\s+push\b[^|;&]*(--force\b|--force-with-lease\b|\s-f\b|\s-\w*f\w*\b|:\S)"),
     "force push / ref delete (rewrites or removes remote history)"),
    (re.compile(_GIT + r"\s+(branch\s+-D|push\b[^|;&]*--delete)\b"),
     "deleting a branch"),
    (re.compile(_GIT + r"\s+commit\b[^|;&]*(--no-verify\b|\s-\w*n\w*\b)"),
     "commit with --no-verify (skips pre-commit checks)"),
    (re.compile(_GIT + r"\s+add\b[^|;&]*(-f\b|--force\b)"),
     "add -f (force-adds gitignored files)"),
]

# Files no coding task should write, via Write/Edit OR a shell redirect.
PROTECTED_PATH_RES = [
    (re.compile(r"(^|/)\.env(\.|$)"), "an environment/secrets file"),
    (re.compile(r"(^|/)\.git/"), "the git internals (.git/)"),
    (re.compile(r"(^|/)\.claude/hooks/"), "a project guard hook"),
    (re.compile(r"(^|/)\.claude/scripts/"), "a project heal/recovery script"),
    (re.compile(r"(^|/)\.claude/settings(\.local)?\.json$"), "the project settings"),
    (re.compile(r"(^|/)\.ssh/"), "an SSH key/config"),
    (re.compile(r"(^|/)(id_rsa|id_ed25519|id_ecdsa)(\.pub)?$"), "a private key"),
    (re.compile(r"(^|/)\.aws/credentials$"), "AWS credentials"),
    (re.compile(r"(^|/)\.(npmrc|pypirc)$"), "a package-registry credential file"),
    (re.compile(r"(^|/)\.mcp\.json$"), "the MCP server config"),
]

# Outward-facing / hard-to-undo -> ASK a human.
PUBLISH_CMD_RE = re.compile(
    r"\b(npm\s+publish|yarn\s+publish|pnpm\s+publish|cargo\s+publish|cargo\s+yank"
    r"|twine\s+upload|gem\s+push|docker\s+push|gh\s+release\s+create)\b"
)
PROTECTED_BRANCHES = ("main", "master")
_PUSH_SEG_RE = re.compile(r"\bgit\s+push\b([^|;&\n]*)")
REDIRECT_RE = re.compile(r"(?:^|[^0-9])>>?\s*([^\s;|&<>]+)")

# Heredoc opener: `<<MARK`, `<<-MARK`, `<<'MARK'`, `<<"MARK"`.
_HEREDOC_RE = re.compile(r"<<-?\s*([\"']?)([A-Za-z_][A-Za-z0-9_]*)\1")

# ------------------------------ HELPERS --------------------------------------

def emit(decision, reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def allow():
    sys.exit(0)


def project_dir():
    return os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def structural(cmd):
    """Copy of *cmd* with quoted string literals and heredoc bodies blanked, so
    the destructive/redirect/publish/push checks match command STRUCTURE, never a
    trigger phrase that appears only inside quoted data or a heredoc body."""
    lines = cmd.split("\n")
    out, i, n = [], 0, len(lines)
    while i < n:
        line = lines[i]
        markers = [m.group(2) for m in _HEREDOC_RE.finditer(line)]
        out.append(line)
        i += 1
        for mark in markers:
            while i < n:
                if lines[i].strip() == mark:
                    out.append(" ")
                    i += 1
                    break
                out.append(" ")
                i += 1
    cmd = "\n".join(out)
    cmd = re.sub(r"'[^']*'", " ", cmd)
    cmd = re.sub(r'"[^"]*"', " ", cmd)
    return cmd


def protected(path):
    norm = path.replace("\\", "/").strip().strip('"').strip("'")
    for rx, what in PROTECTED_PATH_RES:
        if rx.search(norm):
            return what
    return None


def current_branch():
    import subprocess
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=project_dir(), capture_output=True, text=True, timeout=3)
        return out.stdout.strip() or None
    except Exception:
        return None


def push_needs_confirm(scmd):
    m = _PUSH_SEG_RE.search(scmd)
    if not m:
        return False
    seg = m.group(1)
    if re.search(r"--force|(?:^|\s)-f\b|--delete|:\S", seg):
        return False  # already denied
    if re.search(r"\b(main|master)\b", seg):
        return True
    args = [t for t in seg.split() if not t.startswith("-")]
    if len(args) >= 2:
        return False  # explicit non-main branch
    return current_branch() in PROTECTED_BRANCHES

# ------------------------------ MAIN -----------------------------------------

def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        allow()

    tool = payload.get("tool_name", "")
    ti = payload.get("tool_input", {}) or {}

    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        what = protected(path)
        if what:
            emit("deny",
                 f"Blocked: writing {what} ({os.path.basename(path)}). "
                 "This file is human-owned; edit it yourself if you mean to.")
        allow()

    if tool != "Bash":
        allow()

    cmd = ti.get("command", "") or ""
    if not cmd.strip():
        allow()

    scmd = structural(cmd)

    for rx, why in DESTRUCTIVE_RES:
        if rx.search(scmd):
            emit("deny",
                 f"Blocked destructive command: {why}. If you really mean it, "
                 "run it in a terminal yourself.")

    for mm in REDIRECT_RE.finditer(scmd):
        what = protected(mm.group(1))
        if what:
            emit("deny", f"Blocked: shell redirect into {what} ({mm.group(1)}).")

    if PUBLISH_CMD_RE.search(scmd):
        emit("ask", "This publishes/releases outward. Confirm before it goes out.")

    if push_needs_confirm(scmd):
        emit("ask", "This pushes to main/master. Confirm before publishing to the "
                    "shared branch (or push a feature branch).")

    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        allow()
