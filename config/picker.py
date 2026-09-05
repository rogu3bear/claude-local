#!/usr/bin/env python3
"""Interactive model picker for claude-local.

Reads the backend inventory ({"models":[{"name":..., "size":..., "details":{...}}]}
from MODELS_JSON_PATH) and the currently-loaded model names (comma-separated
in LOADED_MODELS), lists every model with its load state:

    [LOADED] model is in memory right now
    [idle]   model is installed but not loaded

When CLAUDE_LOCAL_MODEL is set, skips the menu (exact match first, then
substring) and returns non-interactively.

Prints exactly one machine-readable line to stdout:  <ACTION>|<model-name>
    ACTION = LOAD -> launcher should load/pin the model first
    ACTION = USE  -> model is already loaded
Everything human-facing goes to stderr.
"""
import json
import os
import sys


def main() -> None:
    models_path = os.environ["MODELS_JSON_PATH"]
    pre = os.environ.get("CLAUDE_LOCAL_MODEL") or ""
    loaded = {n.strip().lower() for n in (os.environ.get("LOADED_MODELS") or "").split(",") if n.strip()}

    try:
        with open(models_path) as f:
            models = json.load(f).get("models", [])
    except Exception as e:  # noqa: BLE001
        print(f"ERR:could not parse model inventory: {e}")
        sys.exit(2)

    def name(m):
        return str(m.get("name") or "")

    def info(m):
        d = m.get("details") or {}
        size = m.get("size") or 0
        gb = f"{size / 1e9:.0f}GB" if size else ""
        return " ".join(x for x in (d.get("parameter_size"), d.get("quantization_level"), gb) if x)

    def result(n):
        print(f"{'USE' if n.lower() in loaded else 'LOAD'}|{n}")

    if not models:
        print("No models available. Ollama: `ollama pull <model>`; llama-server: set LLAMA_ARG_MODEL in ~/.claude-local/llama-server.env", file=sys.stderr)
        print("ERR:no models found")
        sys.exit(2)

    if pre:
        exact = [name(m) for m in models if name(m) == pre]
        fuzzy = [name(m) for m in models if pre.lower() in name(m).lower()]
        pick = (exact or fuzzy or [None])[0]
        if not pick:
            print(f"ERR:model '{pre}' not found")
            sys.exit(2)
        result(pick)
        return

    print("\nINSTALLED MODELS (an idle one is loaded on selection):", file=sys.stderr)
    for i, m in enumerate(models, 1):
        state = "LOADED" if name(m).lower() in loaded else "idle"
        print(f"  {i:2d}) [{state:6s}] {name(m):<36s} {info(m)}", file=sys.stderr)

    while True:
        sys.stderr.write("\nPick a model number (or 'q' to quit): ")
        sys.stderr.flush()
        try:
            sel = input().strip()
        except (EOFError, KeyboardInterrupt):
            print("\nAborted.", file=sys.stderr)
            print("ERR:aborted")
            sys.exit(130)
        if sel.lower() in ("q", "quit", "exit"):
            print("ERR:aborted")
            sys.exit(1)
        if sel.isdigit() and 1 <= int(sel) <= len(models):
            break
        print("  invalid choice", file=sys.stderr)
    result(name(models[int(sel) - 1]))


if __name__ == "__main__":
    main()
