#!/usr/bin/env python3
"""claude-local usage proxy.

A transparent HTTP reverse proxy between Claude Code and the local
Anthropic-compatible server. Every byte is streamed through unchanged (chunk by
chunk, so time-to-first-token is unaffected); for /v1/messages responses the
token usage is parsed out of the final `message_delta` event (or the JSON body
for non-streaming calls) and appended as one JSON line to USAGE_LOG:

  {"ts":..., "model":..., "ms":..., "ttft_ms":..., "input":<uncached prompt tokens>,
   "cache_read":<cached prompt tokens>, "prompt":<input+cache_read>, "output":...,
   "out_tps":<output tokens / generation seconds>, "cache_pct":..., "msgs":<#messages in request>,
   "stop":<stop_reason>, "conv":<conversation id>, "div":<where the prefix diverged from the
   previous request of this conversation: first_turn | extension | system[i] | tools | messages[i]>}

Env: PROXY_PORT (first port to try, default 1235; PROXY_PORT_FILE receives the bound port), UPSTREAM_HOST/UPSTREAM_PORT (127.0.0.1/1234),
     USAGE_LOG (default ~/.claude-local/usage.jsonl),
     PROXY_DEBUG=1 adds the request's sampling params / tool count / system size to each row,
     PROXY_DEBUG=2 (or PROXY_DUMP=1) also writes every Messages request body to <session>/requests/,
     PROXY_SAMPLING='{...}' overrides temperature/top_p/top_k on every Messages request,
     PROXY_SESSION_MODEL (the launch model) is where a claude-* model name is sent until a turn has named a local model

Errors and anomalies (clog.py, events.jsonl in the session dir and in ~/.claude-local/logs):
  * every non-200 turn: turn_failed {status, err_class, err_msg, model, msgs, tools, prompt_est}
  * upstream_unreachable (502 returned to Claude Code), client_abort (Claude Code hung up
    mid-stream: Esc, timeout), stream_incomplete (200 but no final message_delta: the
    instance died mid-generation), proxy_exception
  * on successful turns: cache_miss (prompt >= PROXY_WARN_PROMPT and cache_pct < PROXY_WARN_CACHE_PCT,
    with `div` saying which part of the request changed since the previous turn of the same
    conversation), conv_switch (a different conversation used the slot: subagent or side
    request), output_truncated (stop_reason max_tokens), slow_prefill (ttft > PROXY_WARN_TTFT_S),
    slow_decode (out_tps < PROXY_WARN_TPS with >= 50 output tokens), empty_output
  * retry_storm: >= 3 failed turns inside 60 s (Claude Code is in its retry loop)

Two request rewrites are always on: any `role: system` entry inside `messages` is
moved into the top-level `system` blocks and Claude Code's per-turn <total_tokens>
counter is stripped wherever it appears (see fold_system_messages); a hosted model name
(claude-*: the auto-mode classifier, a subagent's model alias, context collapse) is
replaced by the session's current model, the last model a turn used, else
PROXY_SESSION_MODEL, and logged as model_rewritten. Any other name passes through, so
a removed preset still fails as model_not_found.

Checkpoint and resume (llama-server router mode, PROXY_BACKEND=llamaserver):
  * PROXY_CHECKPOINT_S seconds after a turn completes with nothing in flight, the
    model's slot (its prompt cache) is saved to <slot-save-path>/claude-local-<slug>.bin,
    the same file the launcher restores at load. Measured 2026-09-08: a 10K-token
    context is 180 MB and 250 ms each way. Pending checkpoints are flushed on SIGTERM.
  * Before each turn the proxy checks the preset's state. A preset that died or was
    unloaded is loaded again and its checkpoint restored; a preset whose child port
    changed (the server restarted) gets its checkpoint restored. So a crash costs one
    failed turn and the retry starts warm.
  * Hybrid models (every Qwen3.6/3.8 preset here: SSM layers + attention every 4th block)
    keep recurrent state only at the last position, and slot files carry no context
    checkpoints. A restored sequence can therefore be *extended* (the next Claude Code
    turn, or a retry of the failed one) at full cache hit, but not rewound: re-sending
    an identical or shorter prompt reprocesses everything. Measured 2026-09-08.
  * Idle unload: every turn's model and time go to PROXY_STATE_DIR/last_use.json, shared by
    all sessions' proxies. A resident preset that no session has used for PROXY_IDLE_UNLOAD_S
    seconds, and that is not this session's current model, is checkpointed and unloaded
    ("dehydrated"); whoever needs it next gets it back warm through ensure_warm.
  Env: PROXY_BACKEND (ollama|llamaserver), PROXY_CHECKPOINT_S (0 = off),
       PROXY_IDLE_UNLOAD_S (0 = off), PROXY_STATE_DIR (ledger + lock files),
       SLOTS_DIR (where the server writes slot files).
"""
import fcntl
import hashlib
import http.client
import json
import os
import re
import signal
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import clog  # noqa: E402  (installed next to this file)

LISTEN_PORT = int(os.environ.get("PROXY_PORT", "1235"))
UP_HOST = os.environ.get("UPSTREAM_HOST", "127.0.0.1")
UP_PORT = int(os.environ.get("UPSTREAM_PORT", "1234"))
USAGE_LOG = os.environ.get("USAGE_LOG", os.path.expanduser("~/.claude-local/usage.jsonl"))
MAX_CAPTURE = 8_000_000  # bytes of response retained for usage parsing
# Optional sampling override for /v1/messages requests, e.g.
# PROXY_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'. Request params beat
# Modelfile params on the server, so this is the only place to pin them.
try:
    SAMPLING = json.loads(os.environ.get("PROXY_SAMPLING") or "{}")
except ValueError:
    SAMPLING = {}

HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailers", "transfer-encoding", "upgrade", "content-length"}

BACKEND = os.environ.get("PROXY_BACKEND", "ollama")
# The launch model, set by the launcher: where a hosted model name (claude-*) is sent until
# the first turn names a local model (see Handler._proxy).
SESSION_MODEL = os.environ.get("PROXY_SESSION_MODEL") or None
CHECKPOINT_S = float(os.environ.get("PROXY_CHECKPOINT_S") or 0)
IDLE_UNLOAD_S = float(os.environ.get("PROXY_IDLE_UNLOAD_S") or 0)
STATE_DIR = os.environ.get("PROXY_STATE_DIR") or os.path.dirname(os.path.abspath(USAGE_LOG))
SLOTS_DIR = os.environ.get("SLOTS_DIR") or os.path.expanduser("~/.claude-local/slots")
LOAD_WAIT_S = 900
DEBUG = os.environ.get("PROXY_DEBUG") or ""
DUMP = DEBUG == "2" or os.environ.get("PROXY_DUMP") == "1"
DUMP_DIR = os.path.join(os.path.dirname(os.path.abspath(USAGE_LOG)), "requests")
DUMP_MAX = 300
# anomaly thresholds
WARN_PROMPT = int(os.environ.get("PROXY_WARN_PROMPT") or 4000)      # below this a cold prompt is cheap anyway
WARN_CACHE_PCT = int(os.environ.get("PROXY_WARN_CACHE_PCT") or 50)
WARN_TTFT_S = float(os.environ.get("PROXY_WARN_TTFT_S") or 30)
WARN_TPS = float(os.environ.get("PROXY_WARN_TPS") or 8)


def log(msg):
    print(f"[proxy] {msg}", file=sys.stderr, flush=True)


def event(kind, level="info", hint=None, **fields):
    row = clog.event(kind, level, "proxy", hint, **fields)
    if level != "info":
        log(f"{level} {kind}: " + " ".join(f"{k}={v}" for k, v in fields.items() if k not in ("hint",)))
    return row


# ------------------------------------------------------------ checkpoint / resume ----
_state = threading.Lock()      # guards _inflight and _dirty
_warm = threading.Lock()       # one ensure_warm at a time (parallel subagents share a preset)
_inflight = 0
_dirty = {}                    # model -> time its last turn completed (checkpoint pending)
_instance = {}                 # model -> child port last seen (changes when the instance restarts)
_current = None                # model this session's last turn used: never idle-unloaded by us; where claude-* names go
_first_seen = {}               # model -> when we first saw it resident without a ledger entry
LEDGER = os.path.join(STATE_DIR, "last_use.json")


def ledger_update(model, ts):
    """Record a model's last use, shared across sessions (flock, atomic replace)."""
    try:
        with open(LEDGER + ".lock", "w") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            try:
                with open(LEDGER) as f:
                    d = json.load(f)
            except (OSError, ValueError):
                d = {}
            d[model] = ts
            tmp = LEDGER + ".tmp"
            with open(tmp, "w") as f:
                json.dump(d, f)
            os.replace(tmp, LEDGER)
    except OSError as e:
        event("ledger_failed", "warn", error=str(e), path=LEDGER,
              hint="idle-unload ledger not writable; other sessions may evict this model")


def ledger_read():
    try:
        with open(LEDGER) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _slug(model):
    """Same mapping as the adapter's _ls_slug: tr -c 'A-Za-z0-9._-' '_'."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", model)


def slot_file(model):
    return f"claude-local-{_slug(model)}.bin"


def upstream_json(method, path, body=None, timeout=30):
    conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=timeout)
    try:
        hdrs = {"content-type": "application/json"} if body is not None else {}
        conn.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=hdrs)
        r = conn.getresponse()
        data = r.read()
        try:
            return r.status, json.loads(data or b"{}")
        except ValueError:
            return r.status, {}
    finally:
        conn.close()


def server_up():
    """Cheap reachability probe for error events (never raises)."""
    try:
        st, _ = upstream_json("GET", "/health" if BACKEND == "llamaserver" else "/api/tags", timeout=2)
        return st < 500
    except OSError:
        return False


def model_state(model):
    """(status, child port) of a router preset: loaded | loading | unloaded | failed.
    (None, None) when the server is unreachable, not a router, or the name is unknown."""
    try:
        _, d = upstream_json("GET", "/models", timeout=10)
    except OSError:
        return None, None
    for e in d.get("data") or []:
        if e.get("id") != model:
            continue
        s = e.get("status") or {}
        if not s:
            return None, None
        args = s.get("args") or []
        port = args[args.index("--port") + 1] if "--port" in args else None
        v = "failed" if s.get("failed") else (s.get("value") or "unloaded")
        return v, port
    return None, None


def wait_loaded(model):
    for _ in range(LOAD_WAIT_S):
        v, port = model_state(model)
        if v in ("loaded", "failed", None):
            return v, port
        time.sleep(1)
    return "timeout", None


def checkpoint(model, why):
    if BACKEND != "llamaserver":
        return
    try:
        with open(os.path.join(STATE_DIR, "checkpoint.lock"), "w") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            t0 = time.time()
            st, d = upstream_json("POST", "/slots/0?action=save",
                                  {"filename": slot_file(model), "model": model}, timeout=600)
        if st == 200:
            log(f"checkpoint {model} ({why}): {d.get('n_saved', '?')} tokens, "
                f"{int((d.get('n_written') or 0) / 1e6)} MB, {int((time.time() - t0) * 1000)} ms")
            event("checkpoint", model=model, why=why, tokens=d.get("n_saved"),
                  mb=int((d.get("n_written") or 0) / 1e6), ms=int((time.time() - t0) * 1000))
        else:
            event("checkpoint_failed", "warn", model=model, why=why, status=st, error=json.dumps(d)[:160],
                  hint="slot save refused; the next resume will be cold. Is --slot-save-path writable and the model loaded?")
    except OSError as e:
        event("checkpoint_failed", "warn", model=model, why=why, error=str(e),
              hint="server unreachable during slot save")


def restore(model):
    f = slot_file(model)
    path = os.path.join(SLOTS_DIR, f)
    if not os.path.exists(path):
        event("restore_skipped", model=model, hint="no checkpoint on disk; first turn will be cold")
        return
    try:
        st, d = upstream_json("POST", "/slots/0?action=restore", {"filename": f, "model": model}, timeout=300)
    except OSError as e:
        event("restore_failed", "warn", model=model, error=str(e))
        return
    if st == 200:
        log(f"restored {model}: {d.get('n_restored', '?')} tokens, "
            f"{int((d.get('timings') or {}).get('restore_ms') or 0)} ms")
        event("restored", model=model, tokens=d.get("n_restored"),
              ms=int((d.get("timings") or {}).get("restore_ms") or 0))
    else:
        event("restore_failed", "warn", model=model, status=st, file=f,
              hint="stale checkpoint removed (model or context changed since it was saved); next turn is cold")
        try:
            os.remove(path)
        except OSError:
            pass


def ensure_warm(model):
    """Called before a turn is forwarded: bring a dead or unloaded preset back and restore
    its checkpoint; restore after a server restart. Never raises; on doubt, just forward."""
    if BACKEND != "llamaserver" or not model:
        return
    with _warm:
        try:
            v, port = model_state(model)
            if v is None:
                return
            if v in ("unloaded", "failed"):
                event("model_resume", "warn", model=model, state=v,
                      hint="the preset was not resident before this turn (crash, unload, eviction); reloading it")
                t0 = time.time()
                upstream_json("POST", "/models/load", {"model": model}, timeout=30)
                v, port = wait_loaded(model)
                if v != "loaded":
                    event("model_load_failed", "error", model=model, state=v, hint=clog.HINTS["model_load"])
                    return
                event("model_loaded", model=model, s=int(time.time() - t0))
                restore(model)
                _instance[model] = port
                return
            if v == "loading":
                v, port = wait_loaded(model)
                if v != "loaded":
                    return
            prev = _instance.get(model)
            if prev is not None and prev != port:
                event("model_restarted", "warn", model=model, old_port=prev, new_port=port,
                      hint="the model instance restarted under us (unit restart or crash); restoring its checkpoint")
                restore(model)
            _instance[model] = port
        except Exception as e:  # noqa: BLE001 -- the turn must go through regardless
            event("proxy_exception", "error", where="ensure_warm", model=model, error=str(e))


def loaded_presets():
    try:
        _, d = upstream_json("GET", "/models", timeout=10)
    except OSError:
        return []
    return [e["id"] for e in d.get("data") or [] if (e.get("status") or {}).get("value") == "loaded"]


def idle_unload_pass():
    """Dehydrate resident presets nobody has used for IDLE_UNLOAD_S (never this session's model)."""
    now = time.time()
    led = ledger_read()
    for m in loaded_presets():
        if m == _current:
            continue
        last = led.get(m)
        if last is None:                      # loaded outside any session: age it from first sight
            last = _first_seen.setdefault(m, now)
        if now - last < IDLE_UNLOAD_S:
            continue
        with _state:
            if _inflight:
                return
            _dirty.pop(m, None)
        event("idle_unload", model=m, idle_min=int((now - last) / 60))
        checkpoint(m, "idle-unload")
        try:
            st, _ = upstream_json("POST", "/models/unload", {"model": m}, timeout=60)
            if st != 200:
                event("unload_failed", "warn", model=m, status=st)
        except OSError as e:
            event("unload_failed", "warn", model=m, error=str(e))
        _instance.pop(m, None)
        _first_seen.pop(m, None)


def keeper():
    """Checkpoint every model whose last turn is older than CHECKPOINT_S while nothing is in
    flight; every 30 s, dehydrate presets idle for IDLE_UNLOAD_S."""
    last_idle_pass = time.time()
    while True:
        time.sleep(2)
        now = time.time()
        if CHECKPOINT_S > 0:
            with _state:
                due = [] if _inflight else [m for m, ts in _dirty.items() if now - ts >= CHECKPOINT_S]
                for m in due:
                    del _dirty[m]
            for m in due:
                checkpoint(m, "idle")
        if IDLE_UNLOAD_S > 0 and BACKEND == "llamaserver" and now - last_idle_pass >= 30:
            last_idle_pass = now
            try:
                idle_unload_pass()
            except Exception as e:  # noqa: BLE001
                event("proxy_exception", "error", where="idle_unload_pass", error=str(e))


def flush_and_exit(*_):
    with _state:
        due = list(_dirty)
        _dirty.clear()
    for m in due:
        checkpoint(m, "exit")
    os._exit(0)


def fold_system_messages(req: dict) -> bool:
    """Move `role: system` entries out of `messages` into the top-level `system` blocks.

    Claude Code sends the Agent tool's type list as a system-role message inside the
    conversation (after the first user turn) whenever Agent is in --tools. llama-server
    passes it to the chat template as a mid-conversation system message; Qwen3.6's
    template tolerated that, Qwen3.8's raises "System message must be at the beginning"
    and the whole turn fails with HTTP 500. Folding the text into the system prompt is
    equivalent for the model and keeps it in the cached prefix. Returns True if changed.
    """
    msgs = req.get("messages")
    if not isinstance(msgs, list):
        return False
    changed = False
    for m in msgs:                      # a volatile counter as a text block of a user message
        c = m.get("content") if isinstance(m, dict) else None
        if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "text" and VOLATILE_ONLY_RE.match(b.get("text") or "") for b in c):
            kept_blocks = [b for b in c if not (isinstance(b, dict) and b.get("type") == "text" and VOLATILE_ONLY_RE.match(b.get("text") or ""))]
            if kept_blocks:
                m["content"] = kept_blocks
                changed = True
                strip_volatile("<total_tokens>")   # counts and logs once
        elif isinstance(c, str) and "<total_tokens>" in c:     # inline in a plain-string message
            m["content"] = strip_volatile(c)                     # the text around it stays; never drop the message
            changed = True
    if not any(isinstance(m, dict) and m.get("role") == "system" for m in msgs):
        return changed
    system = req.get("system")
    blocks = [{"type": "text", "text": system}] if isinstance(system, str) else list(system or [])
    kept = []
    for m in msgs:
        if isinstance(m, dict) and m.get("role") == "system":
            c = m.get("content")
            texts = [c] if isinstance(c, str) else [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"] if isinstance(c, list) else []
            for t in texts:
                t = strip_volatile(t)
                if t.strip():
                    blocks.append({"type": "text", "text": t})
        else:
            kept.append(m)
    req["messages"] = kept
    req["system"] = blocks
    return True


VOLATILE_RE = re.compile(r"\s*<total_tokens>[^<]*</total_tokens>\s*")
VOLATILE_ONLY_RE = re.compile(r"^(\s*<total_tokens>[^<]*</total_tokens>\s*)+$")
_volatile_seen = 0


def strip_volatile(text):
    """Remove per-turn counters Claude Code injects as system text. The only one seen so far is
    `<total_tokens>N tokens left</total_tokens>` (a role:system message appended after every user
    turn, with a fresh number each time; CLAUDE_CODE_TOTAL_TOKENS_REMINDER=0 turns it off at the
    source and the launcher does that too). Folded into the system prompt it would change the
    cached prefix every turn; a small local model gains nothing from a 15M-token budget notice."""
    global _volatile_seen
    if "<total_tokens>" not in text:
        return text
    out = VOLATILE_RE.sub("\n", text)
    _volatile_seen += 1
    if _volatile_seen == 1:
        event("volatile_system_stripped", "info", tag="total_tokens",
              hint="Claude Code sent its per-turn <total_tokens> reminder; stripped so the prefix cache survives. "
                   "Set CLAUDE_CODE_TOTAL_TOKENS_REMINDER=0 (the launcher does) to stop it at the source.")
    return out


def hosted(name):
    """True for an Anthropic model name (claude-*): only a Claude Code feature asks for one here."""
    return isinstance(name, str) and name.lower().startswith("claude-")


# ------------------------------------------------------------ request fingerprints ----
# Why a turn missed the prefix cache is only knowable by comparing the request with the
# previous one of the same conversation: which part changed first (system blocks, tool
# schemas, or message i). Each component is hashed; the fingerprints of the last request per
# conversation are kept in memory. A conversation is identified by its first user message
# (subagents and Claude Code's side calls have their own), so parent/child interleaving on
# the single slot shows up as conv_switch, not as a rewritten history.
_fp_lock = threading.Lock()
_prev_fp = {}        # conv id -> fingerprint dict
_last_conv = None
_fail_times = []     # recent failed-turn timestamps (retry storm detection)
_dump_n = 0


def _scrub(obj):
    """Drop keys the server never renders (cache_control breakpoints move every turn)."""
    if isinstance(obj, dict):
        return {k: _scrub(v) for k, v in obj.items() if k != "cache_control"}
    if isinstance(obj, list):
        return [_scrub(x) for x in obj]
    return obj


def _h(obj):
    return hashlib.sha1(json.dumps(_scrub(obj), sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:12]


def _block_text(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return json.dumps(c, sort_keys=True)


def fingerprint(req):
    system = req.get("system")
    blocks = [system] if isinstance(system, str) else list(system or [])
    tools = req.get("tools") or []
    msgs = req.get("messages") or []
    first_user = next((m for m in msgs if isinstance(m, dict) and m.get("role") == "user"), None)
    # a conversation is its first user message minus injected system-reminder blocks
    root_text = re.sub(r"<system-reminder>.*?</system-reminder>", "", _block_text((first_user or {}).get("content")), flags=re.S)
    return {
        "conv": hashlib.sha1((str(req.get("model")) + "\x00" + root_text.strip()).encode()).hexdigest()[:8],
        "system": [_h(b) for b in blocks],
        "system_chars": sum(len(_block_text(b if isinstance(b, str) else b.get("text", json.dumps(b)))) for b in blocks),
        "tools": [(t.get("name", "?"), _h(t)) for t in tools if isinstance(t, dict)],
        "messages": [_h(m) for m in msgs],
        "roles": [(m.get("role"), (m.get("content")[0].get("type") if isinstance(m.get("content"), list) and m.get("content") and isinstance(m["content"][0], dict) else "text"))
                  for m in msgs if isinstance(m, dict)],
        "msgs": len(msgs),
        "ntools": len(tools),
        "est_tokens": len(json.dumps(req)) // 4,
    }


def diverge(prev, cur):
    """(where, detail): first component of `cur` that differs from `prev`."""
    if prev is None:
        return "first_turn", ""
    if prev["system"] != cur["system"]:
        i = next((k for k, (a, b) in enumerate(zip(prev["system"], cur["system"])) if a != b), min(len(prev["system"]), len(cur["system"])))
        return f"system[{i}]", f"{len(prev['system'])} -> {len(cur['system'])} blocks, {prev['system_chars']} -> {cur['system_chars']} chars"
    if prev["tools"] != cur["tools"]:
        pn = {n for n, _ in prev["tools"]}; cn = {n for n, _ in cur["tools"]}
        changed = sorted(n for n, h in cur["tools"] if (n, h) not in set(prev["tools"]) and n in pn)
        return "tools", f"added={sorted(cn - pn)} removed={sorted(pn - cn)} changed={changed}"
    pm, cm = prev["messages"], cur["messages"]
    common = 0
    for a, b in zip(pm, cm):
        if a != b:
            break
        common += 1
    if common == len(pm) and len(cm) >= len(pm):
        return "extension", f"+{len(cm) - len(pm)} messages"
    if common == 0:
        return "messages[0]", "different conversation root"
    role = cur["roles"][common] if common < len(cur["roles"]) else ("?", "?")
    if common == len(pm) - 1 and len(cm) > common:
        return f"messages[{common}]", f"last {role[0]}/{role[1]} message of the previous request was modified (history {len(pm)} -> {len(cm)})"
    return f"messages[{common}]", f"history rewritten at {role[0]}/{role[1]} ({len(pm)} -> {len(cm)} messages; compaction or edited history)"


CACHE_HINTS = {
    "extension": "the request is a pure extension of the previous one, yet the server reused nothing: the slot "
                 "was evicted in between (another conversation on the single slot, a restart) or the backend does "
                 "not report cache reads. Check journalctl for 'selected slot by' and 'prompt cache' lines.",
    "system": "the system blocks changed between turns, so the cached prefix is invalid from the first system "
              "block on. A dynamic system section defeats the cache: check --system-prompt-snapshot on and "
              "--exclude-dynamic-system-prompt-sections, and the folded role:system messages (Agent type list).",
    "tools": "the tool schemas changed between turns (a tool added, removed or with a dynamic description); "
             "everything after the system prompt is re-prefilled. Compare tool lists with CLAUDE_LOCAL_PROXY_DEBUG=2.",
    "messages": "the conversation history itself changed (Claude Code rewrote an earlier message, compacted, or a "
                "system-reminder was appended to the previous user message), so the prefix cache ends there.",
    "first_turn": "first request of this conversation: a cold prefill is expected unless a checkpoint was restored.",
}


def analyze_success(fp, row):
    """Anomaly events for a completed turn; sets row['div'] and row['conv']."""
    global _last_conv
    with _fp_lock:
        prev = _prev_fp.get(fp["conv"])
        where, detail = diverge(prev, fp)
        switched = _last_conv is not None and _last_conv != fp["conv"]
        _prev_fp[fp["conv"]] = fp
        _last_conv = fp["conv"]
    row["conv"] = fp["conv"]
    row["div"] = where
    if switched:
        event("conv_switch", "info", conv=fp["conv"], msgs=fp["msgs"], prompt=row["prompt"], model=row["model"],
              hint="a different conversation (subagent or side request) took the slot; with one slot the two "
                   "evict each other and the parent re-prefills when it resumes")
    if row["prompt"] >= WARN_PROMPT and row["cache_pct"] < WARN_CACHE_PCT and where != "first_turn":
        key = where.split("[")[0]
        event("cache_miss", "warn", model=row["model"], prompt=row["prompt"], cache_pct=row["cache_pct"],
              ttft_ms=row["ttft_ms"], div=where, detail=detail, conv=fp["conv"], switched=switched or None,
              hint=CACHE_HINTS.get(key, ""))
    if row["stop"] == "max_tokens":
        event("output_truncated", "warn", model=row["model"], output=row["output"],
              hint="the reply hit the max_tokens cap (CLAUDE_LOCAL_MAX_OUTPUT); a cut-off Write/Edit fails the turn. "
                   "Raise it or ask for smaller files.")
    if row["output"] == 0:
        event("empty_output", "warn", model=row["model"], stop=row["stop"],
              hint="the model returned no tokens; Claude Code will show an empty turn or retry")
    if row["ttft_ms"] >= WARN_TTFT_S * 1000 and where != "first_turn":   # a cold first prefill is expected
        event("slow_prefill", "warn", model=row["model"], ttft_ms=row["ttft_ms"], prompt=row["prompt"],
              cache_pct=row["cache_pct"], hint="time to first token above threshold: a cold prefill of a large prompt "
              "(see cache_miss), a competing request on the GPU, or CPU fallback")
    if row["output"] >= 50 and 0 < row["out_tps"] < WARN_TPS:
        event("slow_decode", "warn", model=row["model"], out_tps=row["out_tps"], output=row["output"],
              hint="decode speed far below the model's norm: another process on the GPU, memory pressure "
                   "(swap), or the model partly on CPU")


def note_failure(status, err_class):
    now = time.time()
    with _fp_lock:
        _fail_times.append(now)
        while _fail_times and now - _fail_times[0] > 60:
            _fail_times.pop(0)
        n = len(_fail_times)
    if n == 3:
        event("retry_storm", "error", failures_60s=n, status=status, err_class=err_class,
              hint="Claude Code is in its retry loop ('waiting for API'): every attempt is failing the same way; "
                   "fix the cause above rather than waiting it out")


def dump_request(body, tag):
    global _dump_n
    if not DUMP:
        return
    try:
        os.makedirs(DUMP_DIR, exist_ok=True)
        with _fp_lock:
            _dump_n += 1
            n = _dump_n
        if n > DUMP_MAX:
            return
        with open(os.path.join(DUMP_DIR, f"{n:04d}-{tag}.json"), "wb") as f:
            f.write(body)
    except OSError:
        pass


def parse_usage(req_body: bytes, resp_body: bytes):
    """Return (usage, stop_reason, model, complete) from a Messages response (streaming or not).
    `complete` is False for a stream that never delivered its final message_delta."""
    usage, stop, model, complete = {}, None, None, False
    text = resp_body.decode("utf-8", "replace")
    if text.lstrip().startswith("{"):                      # non-streaming
        obj = json.loads(text)
        usage = obj.get("usage") or {}
        stop = obj.get("stop_reason"); model = obj.get("model")
        complete = True
    else:                                                  # SSE stream
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            try:
                ev = json.loads(line[5:].strip())
            except ValueError:
                continue
            t = ev.get("type")
            if t == "message_start":
                m = ev.get("message") or {}
                model = m.get("model")
                usage.update(m.get("usage") or {})
            elif t == "message_delta":
                usage.update(ev.get("usage") or {})       # final, authoritative
                stop = (ev.get("delta") or {}).get("stop_reason") or stop
                complete = True
            elif t == "error":
                return usage, "error", model, False
    return usage, stop, model, complete


def record(req, req_body: bytes, resp_body: bytes, total_s: float, ttft_s, fp):
    try:
        usage, stop, model, complete = parse_usage(req_body, resp_body)
        inp = int(usage.get("input_tokens") or 0)
        cr = int(usage.get("cache_read_input_tokens") or 0)
        cc = int(usage.get("cache_creation_input_tokens") or 0)
        out = int(usage.get("output_tokens") or 0)
        gen_s = max(total_s - (ttft_s or 0.0), 1e-3)
        row = {
            "ts": round(time.time(), 3),
            "model": model or req.get("model"),
            "ms": int(total_s * 1000),
            "ttft_ms": int((ttft_s or 0) * 1000),
            "input": inp, "cache_read": cr, "cache_creation": cc,
            "prompt": inp + cr, "output": out,
            "out_tps": round(out / gen_s, 1) if out else 0.0,
            "cache_pct": int(100 * cr / (inp + cr)) if (inp + cr) else 0,
            "msgs": len(req.get("messages") or []),
            "stop": stop,
        }
        if DEBUG:      # request shape minus the messages
            row["req"] = {k: v for k, v in req.items() if k not in ("messages", "system", "tools")}
            row["tools"] = fp["ntools"]
            row["system_chars"] = fp["system_chars"]
        if not complete:
            event("stream_incomplete", "error", model=row["model"], ms=row["ms"], bytes=len(resp_body),
                  msgs=row["msgs"], prompt_est=fp["est_tokens"],
                  hint="the response stream ended without a final message_delta: the model instance died "
                       "mid-generation (OOM, GPU reset, kill) or the server closed the connection. Claude Code "
                       "shows this as an API error; journalctl --user -u llama-server.service -e, dmesg for amdgpu.")
            note_failure(200, "stream_incomplete")
        else:
            analyze_success(fp, row)
        with open(USAGE_LOG, "a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception as e:  # never let bookkeeping break the proxy
        event("proxy_exception", "error", where="record", error=str(e), trace=traceback.format_exc()[-600:])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def do_GET(self): self.proxy()
    def do_POST(self): self.proxy()
    def do_PUT(self): self.proxy()
    def do_DELETE(self): self.proxy()
    def do_HEAD(self): self.proxy()

    def proxy(self):
        try:
            self._proxy()
        except Exception as e:  # noqa: BLE001
            event("proxy_exception", "error", where="handler", path=self.path, error=str(e),
                  trace=traceback.format_exc()[-800:])
            try:
                self.send_error(502, f"proxy error: {e}")
            except Exception:  # noqa: BLE001
                pass

    def _proxy(self):
        global _inflight, _current
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        is_turn = self.command == "POST" and self.path.startswith("/v1/messages")
        req, req_model, fp = {}, None, None
        if is_turn:
            try:
                req = json.loads(body)
                if isinstance(req, dict):
                    req_model = req.get("model")
                changed = isinstance(req, dict) and fold_system_messages(req)
                if changed:
                    event("system_folded", model=req_model, msgs=len(req.get("messages") or []))
                if SAMPLING and isinstance(req, dict):
                    req.update(SAMPLING)
                    changed = True
                if hosted(req_model):
                    # Only a Claude Code feature asks for a hosted model: the auto-mode classifier
                    # (2026-09-08: "claude-sonnet-5" with a 35K-token prompt, HTTP 400 from the router,
                    # then the same prompt retried on the local slot), a subagent's model alias, context
                    # collapse. Run it on the session's current model: the last local model a turn used
                    # (follows /model), else the launch model. Any other unknown name is left alone so a
                    # removed preset still fails loudly as model_not_found. Before fingerprint(), so the
                    # turn keeps its conversation id and the usage row names the model that ran it.
                    target = _current if _current and not hosted(_current) else SESSION_MODEL
                    if target:
                        event("model_rewritten", "info", **{"from": req_model}, to=target,
                              msgs=len(req.get("messages") or []),
                              hint="a Claude Code feature (auto-mode classifier, a subagent's model alias, "
                                   "context collapse) asked for a hosted model; the proxy ran it on the session "
                                   "model instead. The launcher pins the aliases so this should be rare; "
                                   "CLAUDE_LOCAL_PROXY_DEBUG=2 dumps the request")
                        req["model"] = req_model = target
                        changed = True
                if changed:
                    body = json.dumps(req).encode()
            except ValueError:
                req = {}
            if not isinstance(req, dict):
                req = {}
            fp = fingerprint(req)
            ensure_warm(req_model)
            with _state:
                _inflight += 1
                if req_model:
                    _current = req_model
        t0 = time.time()
        hdrs = {k: v for k, v in self.headers.items()
                if k.lower() not in ("host", "connection", "content-length")}
        hdrs["Host"] = f"{UP_HOST}:{UP_PORT}"
        if body:
            hdrs["Content-Length"] = str(len(body))
        conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=3600)
        try:
            conn.request(self.command, self.path, body=body, headers=hdrs)
            resp = conn.getresponse()
        except Exception as e:
            self.send_error(502, f"upstream error: {e}")
            conn.close()
            if is_turn:
                with _state:
                    _inflight -= 1
                event("upstream_unreachable", "error", model=req_model, error=str(e), server_up=server_up(),
                      msgs=fp["msgs"], prompt_est=fp["est_tokens"], hint=clog.HINTS["unreachable"])
                note_failure(502, "unreachable")
                dump_request(body, "502")
            return
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        cl = resp.getheader("Content-Length")
        chunked = cl is None
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", cl)
        self.end_headers()

        captured = bytearray()
        want = is_turn and resp.status == 200
        keep = is_turn                      # error bodies are small: keep them for the event
        ttft = None
        aborted = False                     # Claude Code hung up on us
        upstream_err = None                 # the server died on us mid-response
        try:
            while True:
                try:
                    chunk = resp.read1(65536)   # at most one upstream read: no buffering delay
                except Exception as e:  # noqa: BLE001  IncompleteRead, reset, timeout
                    upstream_err = e
                    break
                if not chunk:
                    break
                if ttft is None:
                    ttft = time.time() - t0
                try:
                    if chunked:
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                    else:
                        self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    self.close_connection = True
                    aborted = True
                    break
                if keep and len(captured) < MAX_CAPTURE:
                    captured += chunk
            if chunked and not aborted:
                try:                        # always terminate the stream so the client does not hang
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    aborted = True
            if upstream_err is not None:
                self.close_connection = True
        finally:
            conn.close()
            if is_turn:
                with _state:
                    _inflight -= 1
        if not is_turn:
            return
        total = time.time() - t0
        if upstream_err is not None and not aborted:
            event("stream_incomplete", "error", model=req_model, status=resp.status, ms=int(total * 1000),
                  bytes=len(captured), msgs=fp["msgs"], prompt_est=fp["est_tokens"], error=repr(upstream_err),
                  hint="the server closed the connection mid-response: the model instance died (OOM, GPU reset, "
                       "kill) or the unit restarted. Claude Code shows this as an API error and retries; "
                       "journalctl --user -u llama-server.service -e, dmesg for amdgpu.")
            note_failure(resp.status, "stream_incomplete")
            dump_request(body, "died")
            return
        if aborted:
            event("client_abort", "warn", model=req_model, status=resp.status, ms=int(total * 1000),
                  bytes=len(captured), msgs=fp["msgs"],
                  hint="Claude Code closed the connection mid-response (Esc/Ctrl-C, or its request timeout "
                       "after a long prefill); the server keeps generating until it notices")
            return
        if resp.status != 200:
            msg = clog.error_message(bytes(captured))
            cls = clog.classify_error(resp.status, msg)
            event("turn_failed", "error", status=resp.status, err_class=cls, err_msg=msg, model=req_model,
                  msgs=fp["msgs"], tools=fp["ntools"], system_chars=fp["system_chars"], prompt_est=fp["est_tokens"],
                  ms=int(total * 1000), hint=clog.HINTS.get(cls))
            note_failure(resp.status, cls)
            dump_request(body, str(resp.status))
            return
        dump_request(body, "200")
        if want and captured:
            record(req, body, bytes(captured), total, ttft, fp)
            if req_model:
                ledger_update(req_model, time.time())
                if CHECKPOINT_S > 0:
                    with _state:
                        _dirty[req_model] = time.time()


def main():
    # Bind the first free port in [LISTEN_PORT, LISTEN_PORT+20). Binding is the
    # claim, so concurrent launchers cannot pick the same port. The bound port
    # is written to PROXY_PORT_FILE (if set) for the launcher to read.
    srv = None
    for port in range(LISTEN_PORT, LISTEN_PORT + 20):
        try:
            srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            break
        except OSError:
            continue
    if srv is None:
        event("proxy_bind_failed", "error", first=LISTEN_PORT, last=LISTEN_PORT + 19,
              hint="20 ports in use: stale proxies from crashed sessions? pgrep -af proxy.py")
        print(f"[proxy] no free port in {LISTEN_PORT}-{LISTEN_PORT + 19}", file=sys.stderr, flush=True)
        sys.exit(1)
    bound = srv.server_address[1]
    srv.daemon_threads = True
    port_file = os.environ.get("PROXY_PORT_FILE")
    if port_file:
        with open(port_file, "w") as f:
            f.write(str(bound))
    print(f"[proxy] listening on 127.0.0.1:{bound} -> {UP_HOST}:{UP_PORT}; usage -> {USAGE_LOG}; "
          f"backend {BACKEND}; checkpoint {'off' if CHECKPOINT_S <= 0 else f'{CHECKPOINT_S:g}s idle'}; "
          f"idle unload {'off' if IDLE_UNLOAD_S <= 0 else f'{IDLE_UNLOAD_S:g}s'}"
          f"{'; dumping requests to ' + DUMP_DIR if DUMP else ''}",
          file=sys.stderr, flush=True)
    threading.Thread(target=keeper, daemon=True).start()
    signal.signal(signal.SIGTERM, flush_and_exit)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
