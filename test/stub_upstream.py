#!/usr/bin/env python3
"""claude-local: a scripted stand-in for the model server, for offline tests.

Speaks just enough of the Anthropic Messages API (streaming and not) and of llama-server's
router endpoints (/health, /models, /props) for proxy.py and Claude Code to talk to it, with
no GPU and no model. Every request is appended to REQUESTS_LOG (one JSON line: method, path,
headers, parsed body), which is how tests see what the client actually sent.

Behaviour is chosen per request by the *last user message text* (so a test drives it from the
prompt) or by the STUB_SCRIPT env (a comma list consumed one item per Messages request):
  ok            200, streams a short text reply, usage says the whole prompt was cached
  cold          200, like ok but cache_read_input_tokens = 0
  tool          200, answers with a Bash tool_use (STUB_TOOL_CMD, default `echo stub`) so the client sends a second turn
  500           500 {"error":{"code":500,"message":"Jinja Exception: System message must be at the beginning","type":"server_error"}}
  404           404 model not found (what Ollama answers for an unknown name)
  400           400 context length exceeded
  hang          accepts, sleeps STUB_HANG_S (default 5), then answers ok (client-timeout tests)
  drop          sends headers and half a stream, then closes (mid-stream server death)
  maxtok        200, stop_reason max_tokens
The default when nothing matches is ok. Non-Messages paths: /health -> 200 {"status":"ok"},
/models -> a router listing with one loaded preset ("stub"), /props -> n_ctx 131072.

  STUB_PORT (default 0 = pick free; the bound port is written to STUB_PORT_FILE if set)
  STUB_DELAY_S (default 0.3) seconds before every Messages answer; STUB_HANG_S for `hang`
  python3 test/stub_upstream.py            # foreground
"""
import json
import os
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REQUESTS_LOG = os.environ.get("REQUESTS_LOG") or "/dev/null"
SCRIPT = [s for s in (os.environ.get("STUB_SCRIPT") or "").split(",") if s]
HANG_S = float(os.environ.get("STUB_HANG_S") or 5)
DELAY_S = float(os.environ.get("STUB_DELAY_S") or 0.3)
TOOL_CMD = os.environ.get("STUB_TOOL_CMD") or "echo stub"
_lock = threading.Lock()
_calls = 0
_state = {"loaded": True, "processing": os.environ.get("STUB_PROCESSING") == "1"}   # router preset "stub"

MODES = ("ok", "cold", "tool", "500", "404", "400", "hang", "drop", "maxtok")


def last_user_text(req):
    for m in reversed(req.get("messages") or []):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, str):
            return c
        return " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def pick_mode(req):
    global _calls
    with _lock:
        i = _calls
        _calls += 1
    if i < len(SCRIPT):
        return SCRIPT[i]
    t = last_user_text(req)
    for m in MODES:
        if f"stub:{m}" in t:
            return m
    return "ok"


def approx_tokens(req):
    return max(1, len(json.dumps(req)) // 4)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _log(self, body):
        try:
            with open(REQUESTS_LOG, "a") as f:
                f.write(json.dumps({"ts": time.time(), "method": self.command, "path": self.path,
                                    "headers": dict(self.headers), "body": body}) + "\n")
        except OSError:
            pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._log(None)
        if self.path.startswith("/health"):
            return self._json(200, {"status": "ok"})
        if self.path.startswith("/models"):
            return self._json(200, {"data": [{"id": "stub", "object": "model", "status": {"value": "loaded" if _state["loaded"] else "unloaded", "args": ["--port", "1"]}}]})
        if self.path.startswith("/slots"):
            return self._json(200, [{"id": 0, "is_processing": _state["processing"], "n_ctx": 131072}])
        if self.path.startswith("/api/ps"):
            return self._json(200, {"models": []})
        if self.path.startswith("/props"):
            return self._json(200, {"default_generation_settings": {"n_ctx": 131072}, "model_alias": "stub"})
        if self.path.startswith("/api/tags"):
            return self._json(200, {"models": [{"name": "stub", "size": 1, "details": {}}]})
        return self._json(404, {"error": "no such path"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            req = json.loads(raw or b"{}")
        except ValueError:
            req = {}
        self._log(req)
        if self.path.startswith("/models/unload"):
            _state["loaded"] = False
            return self._json(200, {"success": True})
        if self.path.startswith("/models/load"):
            _state["loaded"] = True
            return self._json(200, {"success": True})
        if self.path.startswith("/slots/"):
            return self._json(200, {"id_slot": 0, "filename": req.get("filename"), "n_saved": 1234, "n_written": 5_000_000, "timings": {"save_ms": 12}})
        if not self.path.startswith("/v1/messages"):
            return self._json(200, {"ok": True})
        mode = pick_mode(req)
        time.sleep(DELAY_S)          # a real model takes seconds; sub-100ms answers make Claude Code batch tool rounds
        if mode == "500":
            return self._json(500, {"error": {"code": 500, "message": "Jinja Exception: System message must be at the beginning", "type": "server_error"}})
        if mode == "404":
            return self._json(404, {"error": {"message": f"model '{req.get('model')}' not found", "type": "not_found_error"}})
        if mode == "400":
            return self._json(400, {"error": {"code": 400, "message": "the request exceeds the available context size, try increasing it", "type": "invalid_request_error"}})
        if mode == "hang":
            time.sleep(HANG_S)
            mode = "ok"
        prompt = approx_tokens(req)
        cached = 0 if mode == "cold" else prompt
        stop = "max_tokens" if mode == "maxtok" else ("tool_use" if mode == "tool" else "end_turn")
        if mode == "tool":
            content = [{"type": "tool_use", "id": f"toolu_stub_{int(time.time() * 1000) % 100000000}", "name": "Bash", "input": {"command": TOOL_CMD, "description": "stub tool call"}}]
            deltas = [("input_json_delta", {"partial_json": json.dumps(content[0]["input"])})]
        else:
            content = [{"type": "text", "text": "STUBOK"}]
            deltas = [("text_delta", {"text": "STUB"}), ("text_delta", {"text": "OK"})]
        usage_start = {"input_tokens": prompt - cached, "cache_read_input_tokens": cached, "cache_creation_input_tokens": 0, "output_tokens": 1}
        usage_end = {"input_tokens": prompt - cached, "cache_read_input_tokens": cached, "output_tokens": 6}
        msg = {"id": f"msg_stub_{int(time.time() * 1000) % 100000000}", "type": "message", "role": "assistant", "model": req.get("model") or "stub",
               "content": content, "stop_reason": stop, "stop_sequence": None,
               "usage": {**usage_start, "output_tokens": 6}}
        if not req.get("stream"):
            return self._json(200, msg)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def ev(t, d):
            d = {"type": t, **d}
            chunk = f"event: {t}\ndata: {json.dumps(d)}\n\n".encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()

        start = dict(msg)
        start["content"] = []
        start["stop_reason"] = None
        start["usage"] = usage_start
        ev("message_start", {"message": start})
        cb = dict(content[0])
        if cb["type"] == "tool_use":
            cb["input"] = {}
        else:
            cb["text"] = ""
        ev("content_block_start", {"index": 0, "content_block": cb})
        for i, (dt, d) in enumerate(deltas):
            ev("content_block_delta", {"index": 0, "delta": {"type": dt, **d}})
            if mode == "drop" and i == 0:
                self.wfile.flush()
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)   # server dies mid-stream, for real
                except OSError:
                    pass
                return
        ev("content_block_stop", {"index": 0})
        ev("message_delta", {"delta": {"stop_reason": stop, "stop_sequence": None}, "usage": usage_end})
        ev("message_stop", {})
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


def main():
    port = int(os.environ.get("STUB_PORT") or 0)
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    bound = srv.server_address[1]
    pf = os.environ.get("STUB_PORT_FILE")
    if pf:
        with open(pf, "w") as f:
            f.write(str(bound))
    print(f"[stub] listening on 127.0.0.1:{bound}; requests -> {REQUESTS_LOG}", file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
