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
   "stop":<stop_reason>}

Env: PROXY_PORT (first port to try, default 1235; PROXY_PORT_FILE receives the bound port), UPSTREAM_HOST/UPSTREAM_PORT (127.0.0.1/1234),
     USAGE_LOG (default ~/.claude-local/usage.jsonl),
     PROXY_DEBUG=1 adds the request's sampling params / tool count / system size to each row,
     PROXY_SAMPLING='{...}' overrides temperature/top_p/top_k on every Messages request

One request rewrite is always on: any `role: system` entry inside `messages` is
moved into the top-level `system` blocks (see fold_system_messages).

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
  Env: PROXY_BACKEND (ollama|llamaserver), PROXY_CHECKPOINT_S (0 = off),
       PROXY_STATE_DIR (lock file dir), SLOTS_DIR (where the server writes slot files).
"""
import fcntl
import http.client
import json
import os
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
CHECKPOINT_S = float(os.environ.get("PROXY_CHECKPOINT_S") or 0)
STATE_DIR = os.environ.get("PROXY_STATE_DIR") or os.path.dirname(os.path.abspath(USAGE_LOG))
SLOTS_DIR = os.environ.get("SLOTS_DIR") or os.path.expanduser("~/.claude-local/slots")
LOAD_WAIT_S = 900


def log(msg):
    print(f"[proxy] {msg}", file=sys.stderr, flush=True)


# ------------------------------------------------------------ checkpoint / resume ----
_state = threading.Lock()      # guards _inflight and _dirty
_warm = threading.Lock()       # one ensure_warm at a time (parallel subagents share a preset)
_inflight = 0
_dirty = {}                    # model -> time its last turn completed (checkpoint pending)
_instance = {}                 # model -> child port last seen (changes when the instance restarts)


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
        else:
            log(f"checkpoint {model} failed: HTTP {st} {json.dumps(d)[:160]}")
    except OSError as e:
        log(f"checkpoint {model} failed: {e}")


def restore(model):
    f = slot_file(model)
    path = os.path.join(SLOTS_DIR, f)
    if not os.path.exists(path):
        log(f"no checkpoint on disk for {model}; first turn will be cold")
        return
    try:
        st, d = upstream_json("POST", "/slots/0?action=restore", {"filename": f, "model": model}, timeout=300)
    except OSError as e:
        log(f"restore {model} failed: {e}")
        return
    if st == 200:
        log(f"restored {model}: {d.get('n_restored', '?')} tokens, "
            f"{int((d.get('timings') or {}).get('restore_ms') or 0)} ms")
    else:
        log(f"restore {model} failed: HTTP {st}; removing stale checkpoint {f}")
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
                log(f"{model} is {v}; loading it")
                upstream_json("POST", "/models/load", {"model": model}, timeout=30)
                v, port = wait_loaded(model)
                if v != "loaded":
                    log(f"{model} did not load ({v}); forwarding anyway")
                    return
                restore(model)
                _instance[model] = port
                return
            if v == "loading":
                v, port = wait_loaded(model)
                if v != "loaded":
                    return
            prev = _instance.get(model)
            if prev is not None and prev != port:
                log(f"{model} restarted (port {prev} -> {port}); restoring checkpoint")
                restore(model)
            _instance[model] = port
        except Exception as e:  # noqa: BLE001 -- the turn must go through regardless
            log(f"ensure_warm {model}: {e}")


def keeper():
    """Checkpoint every model whose last turn is older than CHECKPOINT_S while nothing is in flight."""
    while True:
        time.sleep(2)
        if CHECKPOINT_S <= 0:
            continue
        now = time.time()
        with _state:
            if _inflight:
                continue
            due = [m for m, ts in _dirty.items() if now - ts >= CHECKPOINT_S]
            for m in due:
                del _dirty[m]
        for m in due:
            checkpoint(m, "idle")


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
    if not isinstance(msgs, list) or not any(isinstance(m, dict) and m.get("role") == "system" for m in msgs):
        return False
    system = req.get("system")
    blocks = [{"type": "text", "text": system}] if isinstance(system, str) else list(system or [])
    kept = []
    for m in msgs:
        if isinstance(m, dict) and m.get("role") == "system":
            c = m.get("content")
            if isinstance(c, str):
                blocks.append({"type": "text", "text": c})
            elif isinstance(c, list):
                blocks.extend(b for b in c if isinstance(b, dict) and b.get("type") == "text")
        else:
            kept.append(m)
    req["messages"] = kept
    req["system"] = blocks
    return True


def parse_usage(req_body: bytes, resp_body: bytes):
    """Return the usage dict from a Messages response (streaming or not)."""
    usage, stop, model = {}, None, None
    text = resp_body.decode("utf-8", "replace")
    if text.lstrip().startswith("{"):                      # non-streaming
        obj = json.loads(text)
        usage = obj.get("usage") or {}
        stop = obj.get("stop_reason"); model = obj.get("model")
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
    return usage, stop, model


def record(req_body: bytes, resp_body: bytes, total_s: float, ttft_s):
    try:
        req = json.loads(req_body or b"{}")
        usage, stop, model = parse_usage(req_body, resp_body)
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
        if os.environ.get("PROXY_DEBUG"):      # request shape minus the messages
            row["req"] = {k: v for k, v in req.items() if k not in ("messages", "system", "tools")}
            row["tools"] = len(req.get("tools") or [])
            sysb = req.get("system")
            row["system_chars"] = len(json.dumps(sysb)) if sysb is not None else 0
        with open(USAGE_LOG, "a") as f:
            f.write(json.dumps(row) + "\n")
    except Exception as e:  # never let bookkeeping break the proxy
        print(f"[proxy] usage parse failed: {e}", file=sys.stderr)


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
        global _inflight
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        is_turn = self.command == "POST" and self.path.startswith("/v1/messages")
        req_model = None
        if is_turn:
            try:
                req = json.loads(body)
                if isinstance(req, dict):
                    req_model = req.get("model")
                changed = isinstance(req, dict) and fold_system_messages(req)
                if SAMPLING and isinstance(req, dict):
                    req.update(SAMPLING)
                    changed = True
                if changed:
                    body = json.dumps(req).encode()
            except ValueError:
                pass
            ensure_warm(req_model)
            with _state:
                _inflight += 1
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
        want = self.path.startswith("/v1/messages") and resp.status == 200
        ttft = None
        try:
            while True:
                chunk = resp.read1(65536)   # at most one upstream read: no buffering delay
                if not chunk:
                    break
                if ttft is None:
                    ttft = time.time() - t0
                if chunked:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                else:
                    self.wfile.write(chunk)
                self.wfile.flush()
                if want and len(captured) < MAX_CAPTURE:
                    captured += chunk
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        finally:
            conn.close()
            if is_turn:
                with _state:
                    _inflight -= 1
        if want and captured:
            record(body, bytes(captured), time.time() - t0, ttft)
            if req_model and CHECKPOINT_S > 0:
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
        print(f"[proxy] no free port in {LISTEN_PORT}-{LISTEN_PORT + 19}", file=sys.stderr, flush=True)
        sys.exit(1)
    bound = srv.server_address[1]
    srv.daemon_threads = True
    port_file = os.environ.get("PROXY_PORT_FILE")
    if port_file:
        with open(port_file, "w") as f:
            f.write(str(bound))
    print(f"[proxy] listening on 127.0.0.1:{bound} -> {UP_HOST}:{UP_PORT}; usage -> {USAGE_LOG}; "
          f"backend {BACKEND}; checkpoint {'off' if CHECKPOINT_S <= 0 else f'{CHECKPOINT_S:g}s idle'}",
          file=sys.stderr, flush=True)
    threading.Thread(target=keeper, daemon=True).start()
    signal.signal(signal.SIGTERM, flush_and_exit)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
