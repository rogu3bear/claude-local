#!/usr/bin/env python3
"""Summarise claude-local benchmark results.

    compare.py [label ...]        (default: every results/*.jsonl)

Prints one row per label (pass rate, wall time, turns, prompt tokens, cache
hit rate, output tokens) and a per-task pass matrix.
"""
import glob, json, os, statistics as st, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "results")

def load(label):
    rows = []
    with open(os.path.join(RES, label + ".jsonl")) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows

labels = sys.argv[1:] or sorted(
    os.path.basename(p)[:-6] for p in glob.glob(os.path.join(RES, "*.jsonl")))
if not labels:
    sys.exit("no results yet")

def mean(xs): return st.mean(xs) if xs else 0.0
def med(xs): return st.median(xs) if xs else 0.0

print(f"{'label':<18}{'n':>3}{'pass':>6}{'pass%':>7}{'wall_mean':>10}{'wall_med':>9}"
      f"{'turns':>6}{'prompt_tok':>11}{'cache%':>7}{'out_tok':>8}{'ctx':>8}")
data = {}
for lb in labels:
    rows = load(lb); data[lb] = rows
    n = len(rows); p = sum(r["ok"] for r in rows)
    walls = [r["wall_s"] for r in rows]
    turns = [r["num_turns"] for r in rows]
    ptok = [r["prompt_tokens"] for r in rows]
    cr = sum(r["cache_read"] for r in rows); pt = sum(ptok)
    out = [r["output"] for r in rows]
    ctx = rows[-1].get("ctx_len") or "?"
    print(f"{lb:<18}{n:>3}{p:>6}{100*p/n if n else 0:>6.0f}%{mean(walls):>9.1f}s{med(walls):>8.1f}s"
          f"{mean(turns):>6.1f}{mean(ptok):>11.0f}{100*cr/pt if pt else 0:>6.0f}%{mean(out):>8.0f}{ctx:>8}")

tasks = sorted({r["task"] for rows in data.values() for r in rows})
print()
print(f"{'task':<18}" + "".join(f"{lb[:14]:>16}" for lb in labels))
for t in tasks:
    cells = []
    for lb in labels:
        rs = [r for r in data[lb] if r["task"] == t]
        if not rs:
            cells.append(f"{'-':>16}"); continue
        p = sum(r["ok"] for r in rs)
        w = mean([r["wall_s"] for r in rs])
        to = any(r.get("timed_out") for r in rs)
        cells.append(f"{p}/{len(rs)} {w:5.0f}s{'*' if to else ' '}".rjust(16))
    print(f"{t:<18}" + "".join(cells))
print("\n(* = at least one run hit the timeout)")
for lb in labels:
    notes = {r.get("notes","") for r in data[lb]} - {""}
    flags = {r.get("flags","") for r in data[lb]} - {""}
    srv = {r.get("server","") for r in data[lb]} - {""}
    print(f"\n{lb}: flags={' | '.join(flags) or '(none)'}\n  server={' | '.join(srv) or '(defaults)'}"
          + (f"\n  notes={' | '.join(notes)}" if notes else ""))
