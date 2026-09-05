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
"""
import http.client
import json
import os
import sys
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
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if SAMPLING and self.command == "POST" and self.path.startswith("/v1/messages"):
            try:
                req = json.loads(body)
                req.update(SAMPLING)
                body = json.dumps(req).encode()
            except ValueError:
                pass
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
        if want and captured:
            record(body, bytes(captured), time.time() - t0, ttft)


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
    print(f"[proxy] listening on 127.0.0.1:{bound} -> {UP_HOST}:{UP_PORT}; usage -> {USAGE_LOG}",
          file=sys.stderr, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
