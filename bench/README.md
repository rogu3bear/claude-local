# claude-local benchmark

Fixed, checkable coding tasks run through `claude -p` against the local server,
so every configuration change gets a number instead of an impression.

    cd ~/.claude-local/bench
    ./run.sh --label NAME [--model M] [--port P] [--tasks a,b] [--repeat N] [--timeout S] \
             [--notes "..."] -- <extra claude flags>
    ./compare.py [label ...]

Each task in `tasks/<name>/` has `setup.sh` (creates the scratch repo),
`prompt.txt` (what the model is asked), and `check.sh` (exit 0 = success).
Every run starts from a fresh `git init` of the setup, so runs are independent.

Recorded per run (`results/<label>.jsonl`): pass/fail, wall seconds, turns,
uncached prompt tokens (`input`), cached prompt tokens (`cache_read`), cache
hit %, output tokens, model, server context length, server env, and the flags
used. Raw claude JSON and stderr are kept in `results/<label>/`.

Typical labels:

    # current launcher behaviour
    ./run.sh --label baseline -- --append-system-prompt-file ~/.claude-local/system_prompt.md
    # cache-friendly flags
    ./run.sh --label flags -- --append-system-prompt-file ~/.claude-local/system_prompt.md \
        --system-prompt-snapshot on --exclude-dynamic-system-prompt-sections --autocompact 131072
    # compact replacement prompt
    ./run.sh --label compact -- --system-prompt-file ~/.claude-local/system_prompt_compact.md ...
    # another model
    ./run.sh --label q8 --model qwen3-coder:30b-a3b-q8_0 -- ...

To benchmark through the usage proxy (per-turn cache/latency rows):

    PROXY_PORT=1235 USAGE_LOG=/tmp/usage.jsonl python3 ../proxy.py &
    ./run.sh --label via-proxy --port 1235 -- ...

Paths given to claude flags must be absolute (claude runs inside the scratch
repo). Caveats: wall time includes claude startup (~1-2s); the first turn of every run
is a full prompt-cache miss (system prompt + tool schemas, ~15K tokens), so
`cache%` measures within-session reuse. Run with `--repeat 3` for anything
where the difference is under ~20%.

## Results 2026-09-05 (qwen3-coder:30b unless noted)

```
label               n  pass  pass% wall_mean wall_med turns prompt_tok cache% out_tok     ctx
baseline            8     8   100%     89.8s    85.2s  11.8     193404    92%    1530  262144
flags               8     8   100%     41.9s    38.2s   9.9     159035    98%    1183  262144
server-noflags     16    16   100%     69.0s    68.2s   9.6     154615    90%    1206  131072
server             24    23    96%     31.2s    31.2s   9.8     156984    98%    1197  131072
server-compact     24    21    88%     22.0s    19.2s   7.2     104950    99%     692  131072
q8                  8     7    88%     35.9s    45.0s   8.8     141616    98%    1125  131072
```

- baseline: original launcher (append prompt, no snapshot), server 262K ctx / f16 KV.
- flags: same prompt + `--system-prompt-snapshot on --exclude-dynamic-system-prompt-sections --autocompact`. The biggest single win: uncached tokens/turn 1622 -> 267. A follow-up isolation run showed `--exclude-dynamic-system-prompt-sections` carries the whole effect (git status moves out of the system prompt, so editing files no longer re-renders it); `--system-prompt-snapshot` is a no-op in claude 2.1.261 (recording not enabled) and is kept only for forward compatibility.
- server-noflags vs server: identical new server (128K ctx, q8_0 KV, 1 slot); isolates the flag effect (69s -> 31s).
- server: the shipped default. 96% over 24 runs.
- server-compact: `--system-prompt-file system_prompt_compact.md` replacing the built-in prompt. 30% faster, 88% pass; loses edge-case verification. Opt in with CLAUDE_LOCAL_PROMPT=replace.
- q8: qwen3-coder:30b-a3b-q8_0. Slower on this iGPU (decode is bandwidth-bound), no accuracy gain at n=8. Q4 stays default.
- 2 of 81 runs emitted a malformed native XML tool call as text on turn 1 (model flake). Claude sends no temperature; try a Modelfile or CLAUDE_LOCAL_SAMPLING and measure.

- Resume: `claude-local --resume <id>` with the same prompt mode is warm (21 uncached tokens); switching CLAUDE_LOCAL_PROMPT on resume re-sends the full prompt once (~15K tokens).
- Interactive session verified through a pty (picker, trust dialog, statusline with proxy stats, double Ctrl-C, post-exit menu). Driver: scratchpad ptytest/drive.py (session-local).
