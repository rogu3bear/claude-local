#!/usr/bin/env python3
"""claude-local: a stdio MCP server that gives a local model a working web search.

Why: Claude Code's built-in WebSearch is a *server-side* tool -- the Anthropic API runs
the search and streams results back. Against llama-server/Ollama there is nobody to
run it, so every call returns an empty result list (observed 2026-09-08). WebFetch is
client-side and works. This server fills the gap with DuckDuckGo's HTML endpoint: no
API key, no dependencies beyond the Python standard library.

Registered by the launcher via --mcp-config (see bin/claude-local, CLAUDE_LOCAL_WEBSEARCH);
Claude Code exposes the tool as mcp__websearch__web_search.

Manual test:
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
                '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"web_search","arguments":{"query":"llama.cpp router mode"}}}' \
    | python3 config/mcp-websearch.py
"""
import html
import json
import sys
import urllib.parse
import urllib.request
from html.parser import HTMLParser

ENDPOINT = "https://html.duckduckgo.com/html/"
UA = "Mozilla/5.0 (X11; Linux x86_64) claude-local-websearch/1"
MAX_DEFAULT, MAX_CAP = 8, 20

TOOL = {
    "name": "web_search",
    "description": (
        "Search the web (DuckDuckGo) and return the top results as title, URL and snippet. "
        "Use this instead of the built-in WebSearch, which does not work on a local model server. "
        "Follow up with WebFetch on a returned URL to read a page."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Search query"},
            "max_results": {"type": "integer", "description": f"1-{MAX_CAP}, default {MAX_DEFAULT}"},
        },
        "required": ["query"],
    },
}


class _Results(HTMLParser):
    """Collect (title, url, snippet) from DuckDuckGo's HTML results page."""

    def __init__(self):
        super().__init__()
        self.results, self._cur, self._field = [], None, None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get("class") or ""
        if tag == "a" and "result__a" in cls:
            self._cur = {"title": "", "url": _unwrap(a.get("href") or ""), "snippet": ""}
            self._field = "title"
        elif tag == "a" and "result__snippet" in cls and self._cur is not None:
            self._field = "snippet"

    def handle_endtag(self, tag):
        if tag == "a" and self._field:
            if self._field == "snippet" and self._cur is not None:
                self.results.append(self._cur)
                self._cur = None
            self._field = None

    def handle_data(self, data):
        if self._cur is not None and self._field:
            self._cur[self._field] += data


def _unwrap(href: str) -> str:
    """DuckDuckGo wraps result links as //duckduckgo.com/l/?uddg=<url>&rut=..."""
    if href.startswith("//"):
        href = "https:" + href
    q = urllib.parse.urlparse(href)
    if q.netloc.endswith("duckduckgo.com") and q.path.startswith("/l/"):
        return urllib.parse.parse_qs(q.query).get("uddg", [href])[0]
    return href


def search(query: str, n: int):
    data = urllib.parse.urlencode({"q": query, "kl": "us-en"}).encode()
    req = urllib.request.Request(ENDPOINT, data=data, headers={"User-Agent": UA, "Accept": "text/html"})
    with urllib.request.urlopen(req, timeout=20) as r:
        page = r.read().decode("utf-8", "replace")
    p = _Results()
    p.feed(page)
    out = []
    for x in p.results:
        x = {k: html.unescape(" ".join(v.split())) for k, v in x.items()}
        if x["url"] and x["title"] and x["url"] not in {o["url"] for o in out}:
            out.append(x)
        if len(out) >= n:
            break
    return out


def format_results(query, results):
    if not results:
        return f"No results for: {query}"
    lines = [f"Web search results for: {query}", ""]
    for i, r in enumerate(results, 1):
        lines.append(f"{i}. {r['title']}\n   {r['url']}")
        if r["snippet"]:
            lines.append(f"   {r['snippet']}")
    return "\n".join(lines)


def call_tool(name, args):
    if name != "web_search":
        raise ValueError(f"unknown tool {name}")
    query = (args or {}).get("query") or ""
    if not query.strip():
        raise ValueError("query is required")
    n = int((args or {}).get("max_results") or MAX_DEFAULT)
    n = max(1, min(MAX_CAP, n))
    return format_results(query, search(query, n))


def reply(msg_id, result=None, error=None):
    m = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        m["error"] = error
    else:
        m["result"] = result
    sys.stdout.write(json.dumps(m) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        method, msg_id, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method == "initialize":
            reply(msg_id, {
                "protocolVersion": params.get("protocolVersion") or "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "websearch", "version": "1.0"},
            })
        elif method == "tools/list":
            reply(msg_id, {"tools": [TOOL]})
        elif method == "tools/call":
            try:
                text = call_tool(params.get("name"), params.get("arguments"))
                reply(msg_id, {"content": [{"type": "text", "text": text}], "isError": False})
            except Exception as e:  # noqa: BLE001 -- report every failure to the model, never crash the server
                reply(msg_id, {"content": [{"type": "text", "text": f"web_search failed: {e}"}], "isError": True})
        elif method == "ping":
            reply(msg_id, {})
        elif msg_id is not None:  # a request we do not implement (notifications carry no id and are ignored)
            reply(msg_id, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
