#!/usr/bin/env python3
"""claude-local structured event log, shared by proxy.py, hook-audit.py, claude-local-doctor.

One JSON object per line, appended to two places:
  * the session's   $CLAUDE_LOCAL_SESSION_DIR/events.jsonl   (reaped with the session dir)
  * the global      $CLAUDE_LOCAL_LOG_DIR/events.jsonl        (default ~/.claude-local/logs;
    rotated to events.jsonl.1 at 20 MB, so failures survive the session dir being reaped)

  {"ts": <epoch>, "level": "info|warn|error", "src": "proxy|launcher|hook|doctor",
   "kind": "<snake_case event name>", "session": "<launcher pid>", "hint": "<what to do>", ...fields}

Event kinds and what they mean are listed in README "Errors and diagnostics"; the doctor
summarises them. Logging never raises: a broken log path must not cost a turn.
"""
import json
import os
import re
import sys
import time

ROTATE_BYTES = 20 * 1024 * 1024


def _config_dir():
    return os.environ.get("CLAUDE_LOCAL_CONFIG") or os.path.expanduser("~/.claude-local")


def log_dir():
    return os.environ.get("CLAUDE_LOCAL_LOG_DIR") or os.path.join(_config_dir(), "logs")


def session_dir():
    return os.environ.get("CLAUDE_LOCAL_SESSION_DIR") or ""


def _paths():
    out = []
    sd = session_dir()
    if sd and os.path.isdir(sd):
        out.append(os.path.join(sd, "events.jsonl"))
    ld = log_dir()
    try:
        os.makedirs(ld, exist_ok=True)
        out.append(os.path.join(ld, "events.jsonl"))
    except OSError:
        pass
    return out


def _rotate(path):
    try:
        if os.path.getsize(path) > ROTATE_BYTES:
            os.replace(path, path + ".1")
    except OSError:
        pass


def event(kind, level="info", src="proxy", hint=None, **fields):
    """Append one event everywhere; returns the dict (handy for tests and stderr mirrors)."""
    row = {"ts": round(time.time(), 3), "level": level, "src": src, "kind": kind}
    sd = session_dir()
    if sd:
        row["session"] = os.path.basename(sd.rstrip("/"))
    if hint:
        row["hint"] = hint
    for k, v in fields.items():
        if v is not None:
            row[k] = v
    line = json.dumps(row, ensure_ascii=False) + "\n"
    for p in _paths():
        try:
            if p.endswith("logs/events.jsonl"):
                _rotate(p)
            with open(p, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass
    return row


def read_events(path=None, since=None):
    """Yield events from a file (default: the global log, plus its .1 rotation), oldest first."""
    paths = [path] if path else [os.path.join(log_dir(), "events.jsonl.1"), os.path.join(log_dir(), "events.jsonl")]
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if since is None or d.get("ts", 0) >= since:
                        yield d
        except OSError:
            continue


# Failure classes for a failed Messages turn, with what to do about each. Keyed by the
# class name classify_error() returns; the hint is what the proxy writes into the event.
HINTS = {
    "template": "the chat template rejected the request (usually a role:system message that is not first). "
                "Run through the proxy (CLAUDE_LOCAL_PROXY=1 folds it); if it still fails, dump requests with "
                "CLAUDE_LOCAL_PROXY_DEBUG=2 and look at the offending message.",
    "model_not_found": "the backend does not know this model name. The session is probably talking to the wrong "
                       "server (CLAUDE_LOCAL_BACKEND vs the preset name), or the preset was removed from "
                       "llama-models.ini; check `curl :PORT/models` and the launcher banner. A claude-* name means "
                       "a Claude Code feature asked for a hosted model (auto-mode classifier, a subagent's model "
                       "alias); the launcher pins those to the session model since 2026-09-08, so this came from a "
                       "session started before that or without the launcher.",
    "model_load": "the model failed to load: bad path, truncated GGUF, or out of device memory. "
                  "journalctl --user -u llama-server.service -e; claude-local-doctor checks the GGUF files.",
    "context": "the prompt no longer fits the server context. Autocompact should have fired first: compare the "
               "launcher's autocompact= banner with LLAMA_ARG_CTX_SIZE/OLLAMA_CONTEXT_LENGTH; /compact by hand.",
    "oom": "the server ran out of memory. Two resident models plus KV plus the RAM prompt cache exceed the pool: "
           "unload one (post-exit menu), lower LLAMA_ARG_CACHE_RAM, or check for a foreign process on the GPU.",
    "busy": "the server refused because every slot is busy (one slot: a subagent or another session holds it). "
            "Claude Code retries by itself; if this repeats, run one session at a time or raise LLAMA_ARG_N_PARALLEL.",
    "auth": "the backend rejected the auth token; local servers ignore it, so this is not the local server.",
    "rate_limit": "429 from a local server means it is overloaded or an upstream proxy is in the path.",
    "server": "5xx from the backend with no recognisable message; see journalctl --user -u <backend>.service -e.",
    "request": "4xx: the request itself was rejected; dump it with CLAUDE_LOCAL_PROXY_DEBUG=2 and check the body.",
    "unreachable": "the backend did not answer at all: unit down, still loading, or the port moved. "
                   "systemctl --user status llama-server.service ollama.service; claude-local-doctor.",
}


def classify_error(status, msg):
    m = (msg or "").lower()
    if "jinja" in m or "system message" in m or "template" in m:
        return "template"
    if status == 404 or "not found" in m or "does not exist" in m or "unknown model" in m:
        return "model_not_found"
    if "failed to load" in m or "is loading" in m or "loading model" in m:
        return "model_load"
    if "context" in m or "exceed" in m or "too long" in m or "n_ctx" in m or "too many tokens" in m:
        return "context"
    if "out of memory" in m or "oom" in m or "alloc" in m or "memory" in m:
        return "oom"
    if status == 503 or "slot" in m or "busy" in m or "unavailable" in m:
        return "busy"
    if status in (401, 403):
        return "auth"
    if status == 429:
        return "rate_limit"
    return "server" if (status or 0) >= 500 else "request"


def error_message(body):
    """Best-effort human message out of an error body (llama-server / Ollama / Anthropic shapes)."""
    text = body.decode("utf-8", "replace") if isinstance(body, (bytes, bytearray)) else str(body or "")
    try:
        d = json.loads(text)
        e = d.get("error") if isinstance(d, dict) else None
        if isinstance(e, dict):
            return str(e.get("message") or e.get("type") or e)[:400]
        if isinstance(e, str):
            return e[:400]
        if isinstance(d, dict) and d.get("message"):
            return str(d["message"])[:400]
    except ValueError:
        pass
    return " ".join(text.split())[:400]


if __name__ == "__main__":   # `python3 clog.py kind level key=value ...` for shell callers without jq
    kind = sys.argv[1] if len(sys.argv) > 1 else "note"
    level = sys.argv[2] if len(sys.argv) > 2 else "info"
    kv = dict(a.split("=", 1) for a in sys.argv[3:] if "=" in a)
    for k, v in list(kv.items()):
        if re.fullmatch(r"-?\d+", v):
            kv[k] = int(v)
        elif re.fullmatch(r"-?\d+\.\d+", v):
            kv[k] = float(v)
    src = kv.pop("src", "shell")
    hint = kv.pop("hint", None)
    print(json.dumps(event(kind, level, src, hint, **kv)))
