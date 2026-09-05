#!/usr/bin/env python3
"""Interactive model picker for claude-local against an Ollama backend.

Reads Ollama's /api/tags response (path passed via MODELS_JSON_PATH) and the
currently-loaded models (comma-separated names via LOADED_MODELS) and lists
every installed model with its load state:

    [LOADED] model is pinned in VRAM right now
    [idle]   model is installed but not currently loaded

When CLAUDE_LOCAL_MODEL is set, skips the menu and returns non-interactively.

Prints one line to stdout:  <ACTION>|<model-key>|<context-length>
    ACTION = LOAD  -> launcher should explicitly pin the model (keep_alive)
    ACTION = USE   -> model is already loaded; launcher can skip the load
"""

import json
import os
import sys

DEFAULT_CTX = 32768


def main() -> None:
    models_path = os.environ["MODELS_JSON_PATH"]
    pre = os.environ.get("CLAUDE_LOCAL_MODEL") or ""
    loaded_raw = os.environ.get("LOADED_MODELS") or ""
    loaded = {name.strip().lower() for name in loaded_raw.split(",") if name.strip()}

    try:
        with open(models_path) as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"ERR:could not parse model inventory: {e}", file=sys.stderr)
        sys.exit(2)

    models = data.get("models", [])
    llms = [m for m in models if m.get("type", "llm") != "embedding"]

    def key(m):
        return m.get("key") or m.get("name")

    def is_loaded(m):
        return str(key(m)).lower() in loaded

    def params(m):
        d = m.get("details") or {}
        return f"{d.get('parameter_size') or d.get('parameters') or ''} {d.get('quantization_level') or m.get('quantization') or ''}".strip()

    if not llms:
        print("No models found. Pull one with:  ollama pull <model>", file=sys.stderr)
        if pre:
            print(f"ERR:model '{pre}' not found in Ollama", file=sys.stderr)
            sys.exit(2)
        print("ERR:no models found", file=sys.stderr)
        sys.exit(2)

    if pre:
        low = pre.lower()
        candidates = [key(m) for m in llms if str(key(m)) == pre] or [
            key(m) for m in llms if low in str(key(m)).lower()
        ]
        if not candidates:
            print(f"ERR:model '{pre}' not found in Ollama", file=sys.stderr)
            sys.exit(2)
        ckey = candidates[0]
        action = "USE" if ckey.lower() in loaded else "LOAD"
        print(f"{action}|{ckey}|{DEFAULT_CTX}")
        sys.exit(0)

    # All human-facing output goes to stderr; stdout carries exactly one
    # machine-readable result line so the launcher can capture it.
    print("\nINSTALLED MODELS (an unused one is loaded on selection):", file=sys.stderr)
    for i, m in enumerate(llms, 1):
        state = "LOADED" if is_loaded(m) else "idle"
        print(f"  {i:2d}) [{state:6s}] {str(key(m)):<36s} {params(m)}", file=sys.stderr)

    def ask(prompt):
        sys.stderr.write(prompt)
        sys.stderr.flush()
        return input()

    while True:
        try:
            sel = ask("\nPick a model number (or 'q' to quit): ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.", file=sys.stderr)
            sys.exit(130)
        if sel.lower() in ("q", "quit", "exit"):
            print("ERR:aborted", file=sys.stderr)
            sys.exit(1)
        if not sel.isdigit() or not (1 <= int(sel) <= len(llms)):
            print("  invalid choice", file=sys.stderr)
            continue
        break

    chosen = llms[int(sel) - 1]
    ckey = key(chosen)
    action = "USE" if ckey.lower() in loaded else "LOAD"
    print(f"{action}|{ckey}|{DEFAULT_CTX}")


if __name__ == "__main__":
    main()
