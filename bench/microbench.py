#!/usr/bin/env python3
"""Backend microbenchmark: cold prefill, decode and warm-prefix cost.

Works against Ollama (/api/generate, raw prompt) and llama-server (/completion)
with byte-identical ChatML prompts so the two can be compared directly.

    microbench.py --backend ollama|llamacpp --url http://127.0.0.1:PORT --label NAME
                  [--model qwen3-coder:30b] [--sizes 2700,10000,30000] [--nout 128,512]
                  [--reps 3] [--warm] [--calibrate-url http://127.0.0.1:1244]
                  [--out micro.jsonl] [--summary micro.jsonl ...]

Cold reps salt the prompt so no prefix survives (llama-server additionally gets
cache_prompt=false). The warm case primes a prefix, then measures the same prefix
plus ~300 new tokens with n_out=128: the shape of one Claude Code turn.
Rows are appended to --out as JSON lines; --summary prints medians per
(label, size, nout, warm) for one or more JSONL files.
"""
import argparse, http.client, json, os, random, statistics, sys, time
from urllib.parse import urlparse

CHATML = "<|im_start|>user\n{salt}\n{code}\n\n{ask}<|im_end|>\n<|im_start|>assistant\n"
ASK = "Rewrite the module with detailed comments on every function, in full."
WARM_TAIL = ("\n\n<tool_response>\n" + "\n".join(f"line {i}: processed record {i*7 % 113} with status ok" for i in range(40))
             + "\n</tool_response>\nContinue.")

def synth_code(n_chars, seed=7):
    """Deterministic synthetic Python source of about n_chars characters."""
    rnd = random.Random(seed)
    nouns = ["order", "invoice", "ticket", "shipment", "account", "report", "batch", "record", "session", "device"]
    verbs = ["validate", "normalize", "merge", "archive", "score", "route", "expand", "compact", "audit", "replay"]
    out = ['"""Synthetic module for benchmarking."""', "import json", "import math", "from collections import defaultdict", ""]
    i = 0
    while sum(len(l) + 1 for l in out) < n_chars:
        n, v = rnd.choice(nouns), rnd.choice(verbs)
        k = rnd.randint(2, 6)
        out += [f"def {v}_{n}_{i}(items, limit={rnd.randint(3, 99)}):",
                f'    """{v.title()} each {n} in items and return a summary dict."""',
                "    totals = defaultdict(float)",
                "    for idx, item in enumerate(items):",
                f"        key = item.get('{n}_id', idx) % {k}",
                f"        totals[key] += math.sqrt(abs(item.get('value', 0)) + {rnd.randint(1, 9)})",
                "        if idx >= limit:",
                "            break",
                "    return {'count': len(items), 'totals': dict(totals)}", ""]
        i += 1
    return "\n".join(out)

def http_json(url, path, body, stream=True, timeout=3600):
    """POST JSON; yield decoded stream chunks (dicts). Handles SSE 'data:' and NDJSON."""
    u = urlparse(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=timeout)
    conn.request("POST", path, body=json.dumps(body).encode(), headers={"content-type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"{path} -> HTTP {resp.status}: {resp.read()[:300]!r}")
    buf = b""
    while True:
        chunk = resp.read1(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            if line.startswith(b"data:"):
                line = line[5:].strip()
            if line in (b"[DONE]",):
                continue
            try:
                yield json.loads(line)
            except ValueError:
                continue
    conn.close()

def tokenize_len(cal_url, text):
    r = list(http_json(cal_url, "/tokenize", {"content": text}, stream=False))
    for obj in r:
        if "tokens" in obj:
            return len(obj["tokens"])
    raise RuntimeError("no tokens in /tokenize response")

def build_prompt(size_tokens, salt, cal_url, warm=False):
    """Calibrate code length so the prompt is ~size_tokens (±3%) using llama-server's tokenizer."""
    n_chars = int(size_tokens * 3.3)
    for _ in range(6):
        code = synth_code(n_chars)
        prompt = CHATML.format(salt=salt, code=code, ask=ASK)
        if not cal_url:
            break
        n = tokenize_len(cal_url, prompt)
        if abs(n - size_tokens) <= size_tokens * 0.03:
            break
        n_chars = int(n_chars * size_tokens / max(n, 1))
    return prompt

def run_one(backend, url, model, prompt, n_out, cache_prompt):
    t0 = time.time(); ttft = None; last = None; first_tok_seen = False
    if backend == "ollama":
        body = {"model": model, "prompt": prompt, "raw": True, "stream": True, "keep_alive": "2h",
                "options": {"temperature": 0, "seed": 1, "num_predict": n_out}}
        for obj in http_json(url, "/api/generate", body):
            if not first_tok_seen and obj.get("response"):
                ttft = time.time() - t0; first_tok_seen = True
            last = obj
        wall = time.time() - t0
        pn = last.get("prompt_eval_count", 0); pms = last.get("prompt_eval_duration", 0) / 1e6
        en = last.get("eval_count", 0); ems = last.get("eval_duration", 0) / 1e6
        cache_n = None
    else:
        body = {"prompt": prompt, "stream": True, "temperature": 0, "seed": 1, "n_predict": n_out,
                "ignore_eos": True, "cache_prompt": cache_prompt}
        for obj in http_json(url, "/completion", body):
            if not first_tok_seen and obj.get("content"):
                ttft = time.time() - t0; first_tok_seen = True
            last = obj
        wall = time.time() - t0
        t = last.get("timings", {})
        pn = t.get("prompt_n", 0); pms = t.get("prompt_ms", 0); en = t.get("predicted_n", 0); ems = t.get("predicted_ms", 0)
        cache_n = t.get("cache_n")
        draft = {k: t[k] for k in ("draft_n", "draft_n_accepted") if k in t}
    row = {"prompt_n": pn, "cache_n": cache_n, "predicted_n": en,
           "prefill_tps": round(pn / (pms / 1000), 1) if pms else None,
           "decode_tps": round(en / (ems / 1000), 1) if ems else None,
           "ttft_s": round(ttft, 3) if ttft else None, "wall_s": round(wall, 2)}
    if backend != "ollama" and draft:
        row.update(draft)
    return row

def summarize(paths):
    rows = []
    for p in paths:
        with open(p) as f:
            rows += [json.loads(l) for l in f if l.strip()]
    keys = sorted({(r["label"], r["size_target"], r["nout_target"], r["warm"]) for r in rows},
                  key=lambda k: (k[0], k[3], k[1], k[2]))
    print(f"{'label':<18}{'size':>7}{'nout':>6}{'warm':>6}{'prefill_tps':>13}{'decode_tps':>12}{'ttft_s':>8}{'wall_s':>8}{'prompt_n':>9}{'pred_n':>8}{'n':>3}")
    for k in keys:
        rs = [r for r in rows if (r["label"], r["size_target"], r["nout_target"], r["warm"]) == k]
        med = lambda f: statistics.median([r[f] for r in rs if r.get(f) is not None]) if any(r.get(f) is not None for r in rs) else float("nan")
        print(f"{k[0]:<18}{k[1]:>7}{k[2]:>6}{'yes' if k[3] else '-':>6}{med('prefill_tps'):>13.0f}{med('decode_tps'):>12.1f}"
              f"{med('ttft_s'):>8.2f}{med('wall_s'):>8.1f}{med('prompt_n'):>9.0f}{med('predicted_n'):>8.0f}{len(rs):>3}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["ollama", "llamacpp"])
    ap.add_argument("--url"); ap.add_argument("--label"); ap.add_argument("--model", default="qwen3-coder:30b")
    ap.add_argument("--sizes", default="2700,10000,30000"); ap.add_argument("--nout", default="128,512")
    ap.add_argument("--reps", type=int, default=3); ap.add_argument("--warm", action="store_true")
    ap.add_argument("--calibrate-url", default=None); ap.add_argument("--out", default="micro.jsonl")
    ap.add_argument("--summary", nargs="*")
    a = ap.parse_args()
    if a.summary is not None:
        summarize(a.summary or [a.out]); return
    if not (a.backend and a.url and a.label):
        ap.error("--backend, --url and --label are required unless --summary")
    sizes = [int(s) for s in a.sizes.split(",")]; nouts = [int(n) for n in a.nout.split(",")]
    with open(a.out, "a") as out:
        for size in sizes:
            for n_out in nouts:
                for rep in range(1, a.reps + 1):
                    salt = f"# run {a.label} {size} {n_out} rep{rep} {time.time_ns()}"
                    prompt = build_prompt(size, salt, a.calibrate_url)
                    r = run_one(a.backend, a.url, a.model, prompt, n_out, cache_prompt=False)
                    r.update(label=a.label, backend=a.backend, size_target=size, nout_target=n_out, rep=rep, warm=False, ts=time.time())
                    out.write(json.dumps(r) + "\n"); out.flush()
                    print(f"[{a.label}] size={size} nout={n_out} rep={rep} prefill={r['prefill_tps']} decode={r['decode_tps']} ttft={r['ttft_s']} wall={r['wall_s']}", flush=True)
            if a.warm:
                salt = f"# warm {a.label} {size} {time.time_ns()}"
                base = build_prompt(size, salt, a.calibrate_url)
                prime = base.replace(ASK, "Acknowledge with OK.")
                run_one(a.backend, a.url, a.model, prime, 1, cache_prompt=True)          # prime the prefix
                for rep in range(1, a.reps + 1):
                    # keep the primed prefix byte-identical up to the user turn's end, then append new content
                    prompt = prime[: prime.rfind("<|im_end|>")] + WARM_TAIL + f" (turn {rep})<|im_end|>\n<|im_start|>assistant\n"
                    r = run_one(a.backend, a.url, a.model, prompt, 128, cache_prompt=True)
                    r.update(label=a.label, backend=a.backend, size_target=size, nout_target=128, rep=rep, warm=True, ts=time.time())
                    out.write(json.dumps(r) + "\n"); out.flush()
                    print(f"[{a.label}] WARM size={size} rep={rep} new_prompt_n={r['prompt_n']} cache_n={r['cache_n']} ttft={r['ttft_s']} decode={r['decode_tps']}", flush=True)

if __name__ == "__main__":
    main()
