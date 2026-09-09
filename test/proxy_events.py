#!/usr/bin/env python3
"""Offline test of the usage proxy's error and anomaly logging (no model server, no GPU).

Runs test/stub_upstream.py, puts config/proxy.py in front of it, drives a scripted set of
Messages requests through the proxy and asserts the events that events.jsonl must contain:
turn_failed (template / model_not_found / context), retry_storm, stream_incomplete,
output_truncated, cache_miss with the right `div`, conv_switch, client_abort,
upstream_unreachable, plus a usage row per successful turn; and the request rewrites the
stub must see: role:system messages folded, the <total_tokens> counter stripped (as a system
message, a user text block, inline in a plain-string user message), a claude-* model name
replaced by the session model (model_rewritten) while an unknown local name ("nope") still
fails as model_not_found. ~5 s.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
tmp = tempfile.mkdtemp(prefix="claude-local-proxytest-")
sess = os.path.join(tmp, "run", "4242"); os.makedirs(sess)
logs = os.path.join(tmp, "logs"); os.makedirs(logs)
env = dict(os.environ, CLAUDE_LOCAL_SESSION_DIR=sess, CLAUDE_LOCAL_LOG_DIR=logs)
procs = []


def wait_port(pf, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            return int(open(pf).read())
        except (OSError, ValueError):
            time.sleep(0.05)
    raise SystemExit(f"no port file {pf}")


def start_stub(script=""):
    pf = os.path.join(tmp, f"stub{len(procs)}.port")
    p = subprocess.Popen([sys.executable, os.path.join(HERE, "stub_upstream.py")],
                         env=dict(env, STUB_PORT_FILE=pf, REQUESTS_LOG=os.path.join(tmp, "stub-requests.jsonl"),
                                  STUB_SCRIPT=script, STUB_HANG_S="3", STUB_DELAY_S="0"),
                         stderr=subprocess.DEVNULL)
    procs.append(p)
    return wait_port(pf)


def start_proxy(up_port, first=1290):
    pf = os.path.join(tmp, f"proxy{len(procs)}.port")
    log = open(os.path.join(tmp, f"proxy{len(procs)}.log"), "w")
    p = subprocess.Popen([sys.executable, os.path.join(REPO, "config", "proxy.py")],
                         env=dict(env, PROXY_PORT=str(first), PROXY_PORT_FILE=pf, UPSTREAM_PORT=str(up_port),
                                  USAGE_LOG=os.path.join(sess, "usage.jsonl"), PROXY_BACKEND="ollama",
                                  PROXY_CHECKPOINT_S="0", PROXY_IDLE_UNLOAD_S="0", PROXY_STATE_DIR=os.path.join(tmp, "run"),
                                  PROXY_WARN_PROMPT="100", PROXY_WARN_TTFT_S="2"),
                         stderr=log)
    procs.append(p)
    return wait_port(pf)


def turn(port, messages, model="stub", stream=True, system="You are a test.", tools=None, timeout=30):
    body = {"model": model, "max_tokens": 64, "stream": stream, "system": system, "messages": messages}
    if tools is not None:
        body["tools"] = tools
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    c.request("POST", "/v1/messages?beta=true", body=json.dumps(body), headers={"content-type": "application/json"})
    r = c.getresponse()
    data = r.read()
    c.close()
    time.sleep(0.3)          # the proxy records after the last byte reaches us
    return r.status, data


def events():
    out = []
    try:
        with open(os.path.join(sess, "events.jsonl")) as f:
            for line in f:
                out.append(json.loads(line))
    except OSError:
        pass
    return out


def kinds():
    return [e["kind"] for e in events()]


failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


try:
    big = "x " * 800                     # ~400 tokens by the stub's estimate; above PROXY_WARN_PROMPT=100
    stub = start_stub()
    px = start_proxy(stub)
    conv_a = [{"role": "user", "content": "hello " + big}]
    # 1. first turn: cold is fine (first_turn), no cache_miss
    st, _ = turn(px, conv_a); check(st == 200, "turn 1 ok")
    # 2. extension with cache: no anomaly
    conv_a2 = conv_a + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "more"}]
    st, _ = turn(px, conv_a2); check(st == 200, "turn 2 ok")
    check("cache_miss" not in kinds(), "no cache_miss for warm turns")
    # 3. extension but cold: cache_miss with div=extension
    conv_a3 = conv_a2 + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "again stub:cold"}]
    st, _ = turn(px, conv_a3); check(st == 200, "turn 3 ok (cold)")
    cm = [e for e in events() if e["kind"] == "cache_miss"]
    check(len(cm) == 1 and cm[0]["div"] == "extension", f"cache_miss div=extension ({cm[-1].get('div') if cm else None})")
    # 4. system prompt changed + cold: div=system[0]
    conv_a4 = conv_a3 + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "x stub:cold"}]
    st, _ = turn(px, conv_a4, system="You are a test. NOW"); check(st == 200, "turn 4 ok")
    cm = [e for e in events() if e["kind"] == "cache_miss"]
    check(cm[-1]["div"] == "system[0]", f"cache_miss div=system[0] ({cm[-1]['div']})")
    # 5. tools changed + cold: div=tools
    tools = [{"name": "Bash", "description": "run", "input_schema": {"type": "object"}}]
    conv_a5 = conv_a4 + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "y stub:cold"}]
    st, _ = turn(px, conv_a5, system="You are a test. NOW", tools=tools); check(st == 200, "turn 5 ok")
    check([e for e in events() if e["kind"] == "cache_miss"][-1]["div"] == "tools", "cache_miss div=tools")
    # 6. last user message modified + cold: div=messages[i]
    conv_a6 = conv_a5[:-1] + [{"role": "user", "content": "y stub:cold <system-reminder>now</system-reminder>"},
                              {"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "z stub:cold"}]
    st, _ = turn(px, conv_a6, system="You are a test. NOW", tools=tools); check(st == 200, "turn 6 ok")
    last = [e for e in events() if e["kind"] == "cache_miss"][-1]
    check(last["div"] == f"messages[{len(conv_a5) - 1}]" and "modified" in last["detail"], f"cache_miss div={last['div']} ({last['detail']})")
    # 7. a different conversation (subagent) takes the slot: conv_switch
    conv_b = [{"role": "user", "content": "subagent task " + big}]
    st, _ = turn(px, conv_b); check(st == 200, "side conversation ok")
    check("conv_switch" in kinds(), "conv_switch logged")
    # 8. back to A as a pure extension but cold -> cache_miss extension, switched=true
    conv_a7 = conv_a6 + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "back stub:cold"}]
    st, _ = turn(px, conv_a7, system="You are a test. NOW", tools=tools); check(st == 200, "turn 7 ok")
    last = [e for e in events() if e["kind"] == "cache_miss"][-1]
    check(last["div"] == "extension" and last.get("switched") is True, "cache_miss after a switch is flagged switched")
    # 8b. Claude Code's trailing role:system <total_tokens> message: folded and stripped, nothing volatile upstream
    conv_c = [{"role": "user", "content": "fold me " + big}, {"role": "system", "content": "Available agent types: x"},
              {"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "next"},
              {"role": "system", "content": "<total_tokens>123 tokens left</total_tokens>\n\n<total_tokens>99 tokens left</total_tokens>"}]
    st, _ = turn(px, conv_c); check(st == 200, "folded turn ok")
    sent = [json.loads(l)["body"] for l in open(os.path.join(tmp, "stub-requests.jsonl")) if '"/v1/messages' in l][-1]
    sysb = sent.get("system") or []
    check(all(m["role"] != "system" for m in sent["messages"]) and len(sysb) == 2 and "total_tokens" not in json.dumps(sent),
          f"role:system folded, total_tokens stripped (system blocks={len(sysb)}, roles={[m['role'] for m in sent['messages']]})")
    check("system_folded" in kinds() and "volatile_system_stripped" in kinds(), "fold + strip events logged")
    conv_d = [{"role": "user", "content": [{"type": "text", "text": "hello " + big}, {"type": "text", "text": "<total_tokens>5 tokens left</total_tokens>"}]}]
    st, _ = turn(px, conv_d); check(st == 200, "user-block variant ok")
    sent = [json.loads(l)["body"] for l in open(os.path.join(tmp, "stub-requests.jsonl")) if '"/v1/messages' in l][-1]
    check("total_tokens" not in json.dumps(sent) and len(sent["messages"][0]["content"]) == 1, "volatile user text block dropped")
    # 8c. a hosted model name (what the auto-mode classifier sent on 2026-09-08) on conversation A: run on the
    # session model, still conversation A (the conv id is hashed from the rewritten name), one model_rewritten event
    conv_a8 = conv_a7 + [{"role": "assistant", "content": "STUBOK"}, {"role": "user", "content": "classify this"}]
    st, _ = turn(px, conv_a8, model="claude-sonnet-5", system="You are a test. NOW", tools=tools); check(st == 200, "claude-* turn ok")
    sent = [json.loads(l)["body"] for l in open(os.path.join(tmp, "stub-requests.jsonl")) if '"/v1/messages' in l][-1]
    rw = [e for e in events() if e["kind"] == "model_rewritten"]
    check(sent.get("model") == "stub" and len(rw) == 1 and rw[0].get("from") == "claude-sonnet-5" and rw[0].get("to") == "stub" and bool(rw[0].get("hint")),
          f"claude-sonnet-5 rewritten to the session model (stub saw {sent.get('model')!r}; events {[(e.get('from'), e.get('to')) for e in rw]})")
    urows = [json.loads(l) for l in open(os.path.join(sess, "usage.jsonl"))]
    check(urows[-1]["model"] == "stub" and urows[-1]["conv"] == urows[0]["conv"],
          f"rewritten turn keeps conversation A's id (model {urows[-1]['model']}, conv {urows[-1]['conv']} vs {urows[0]['conv']})")
    # 8d. the counter inline in a plain-string user message: stripped, the message kept
    st, _ = turn(px, [{"role": "user", "content": "hello <total_tokens>5 tokens left</total_tokens> there"}]); check(st == 200, "plain-string variant ok")
    sent = [json.loads(l)["body"] for l in open(os.path.join(tmp, "stub-requests.jsonl")) if '"/v1/messages' in l][-1]
    c = sent["messages"][-1].get("content")
    check("total_tokens" not in json.dumps(sent) and isinstance(c, str) and c.split() == ["hello", "there"], f"volatile block stripped from a plain-string user message ({c!r})")
    # 9. max_tokens
    st, _ = turn(px, [{"role": "user", "content": "stub:maxtok"}]); check("output_truncated" in kinds(), "output_truncated logged")
    # 10. errors: 500 template, 404 model, 400 context -> 3 turn_failed + retry_storm
    st, body = turn(px, [{"role": "user", "content": "stub:500"}]); check(st == 500, "500 passed through")
    st, body = turn(px, [{"role": "user", "content": "stub:404"}], model="nope"); check(st == 404, "404 passed through")
    st, body = turn(px, [{"role": "user", "content": "stub:400"}]); check(st == 400, "400 passed through")
    tf = [e for e in events() if e["kind"] == "turn_failed"]
    check([e["err_class"] for e in tf] == ["template", "model_not_found", "context"], f"err classes {[e['err_class'] for e in tf]}")
    check(all(e.get("hint") for e in tf), "every turn_failed carries a hint")
    check("System message must be at the beginning" in tf[0]["err_msg"], "server message captured")
    check("retry_storm" in kinds(), "retry_storm after 3 failures in 60s")
    # 11. mid-stream death
    st, body = turn(px, [{"role": "user", "content": "stub:drop"}])
    check("stream_incomplete" in kinds(), "stream_incomplete logged when the stream dies")
    # 12. client abort: hang 3s, client gives up after 0.5s
    try:
        turn(px, [{"role": "user", "content": "stub:hang"}], timeout=0.5)
    except (socket.timeout, OSError):
        pass
    time.sleep(3.5)
    check("client_abort" in kinds(), "client_abort logged when Claude Code hangs up")
    # 13. dead upstream
    px2 = start_proxy(1, first=1300)
    st, body = turn(px2, [{"role": "user", "content": "hi"}]); check(st == 502, f"dead upstream -> 502 ({st})")
    check("upstream_unreachable" in kinds(), "upstream_unreachable logged")
    # usage rows + global mirror
    rows = [json.loads(l) for l in open(os.path.join(sess, "usage.jsonl"))]
    check(len(rows) >= 9 and all("conv" in r and "div" in r for r in rows), f"usage rows carry conv/div ({len(rows)} rows)")
    glob = sum(1 for _ in open(os.path.join(logs, "events.jsonl")))
    check(glob == len(events()), f"global log mirrors the session log ({glob} events)")
    check("proxy_exception" not in kinds(), "no proxy_exception")
except Exception as e:  # noqa: BLE001
    failures.append(f"exception: {e!r}")
finally:
    for p in procs:
        p.terminate()
    if failures:
        print(f"PROXY EVENTS FAIL ({len(failures)}): {failures}\nartifacts in {tmp}")
        try:
            print(open(os.path.join(tmp, 'proxy1.log')).read()[-2000:])
        except OSError:
            pass
        sys.exit(1)
    print("PROXY EVENTS PASS")
    subprocess.run(["rm", "-rf", tmp])
