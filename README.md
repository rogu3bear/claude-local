# claude-local

Run Claude Code against a local model server (llama.cpp llama-server or Ollama) from a fully isolated
config directory, with the harness fitted to a small model and every knob
backed by a benchmark number.

    git clone <this repo> ~/dev/claude-local && ~/dev/claude-local/bootstrap.sh
                            # fresh machine -> working claude-local: deps, user-local Ollama,
                            # systemd user service, model pull, symlinks, server drop-in, smoke turn.
                            # Idempotent (no server restart unless the drop-in env changed); --dry-run shows the plan; no sudo.
                            # The port is persisted in ~/.claude-local/env; `ollama` on PATH is a wrapper that targets it.
    ./bootstrap.sh --backend llamaserver \
      --hf jan1k/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-NVFP4-GGUF/Qwen3.6-35B-A3B-Uncensored-Genesis-Final-MTP-NVFP4.gguf \
      --sha256 af80d3ef030268c46d56f6d7d2722de67fe81592708bac6c8fa381461adfbaad
                            # recommended on Strix Halo: llama-server with the uncensored Genesis build of Qwen3.6-35B-A3B
                            # (jan1k, abliterated; NVFP4 with the MTP head), the preset this host runs. --hf downloads the
                            # GGUF (22GB; resumable, size, magic and sha256 checked, skipped when present) and skips the
                            # Ollama pull; --device auto (default) takes ROCm0 when build-hip lists it, else Vulkan0. URL,
                            # size and hash verified against huggingface.co on 2026-09-09. The filtered unsloth original,
                            # the 2026-09-06 overnight winner, and its command are in docs/bootstrap.md.
    make install            # symlinks only (already-bootstrapped machine)
    claude-local            # pick a model, go
    make test               # offline tests: proxy events, hook and URL guards, drain, the launcher itself (fake claude); no server, ~15 s
    make doctor             # read-only diagnosis of install, server, GPU, sessions, drain, error logs
    make drain-status       # what is resident, who uses it, what the drain timer will unload
    make clean-transcripts  # delete the transcript dirs that bench scratch repos and /tmp test dirs left under ~/.claude-local/projects
    make check              # offline tests + one smoke turn through launcher and proxy
    make check-interactive  # pty-driven full session (picker, statusline, Ctrl-C, exit menu)
    make check-guard        # offline: a refused Bash command stays refused in every pinned permission mode
    make check-checkpoint   # kill an idle llama-server model instance, expect the proxy to resume it warm
    make check-idle         # load a throwaway preset, expect the proxy to checkpoint and unload it when idle
    make bench LABEL=x      # benchmark a configuration; make compare to read results
    make bench-shipped      # benchmark exactly what ships: default tool list, web search MCP, online

## Backends

Two servers can be installed side by side; `CLAUDE_LOCAL_BACKEND` picks one and
`~/.claude-local/env` maps it to its port (Ollama 1234, llama-server 1244).

| backend | server | why |
|---|---|---|
| `ollama` (default) | Ollama 0.33.3, Vulkan, user unit `ollama.service` | simplest; measured baseline below |
| `llamaserver` | upstream llama.cpp `llama-server` in router mode, user unit `llama-server.service` | every GGUF in the INI is selectable with its own settings, HIP (ROCm) or Vulkan from the same unit, speculative decoding (incl. MTP), on-disk prompt cache, dedicated Qwen tool-call parser |

    CLAUDE_LOCAL_BACKEND=llamaserver claude-local     # one session on llama-server
    make check-llama                                   # smoke turn against it
    ./bootstrap.sh --backend llamaserver               # install it (needs a llama.cpp build, see below). --device auto|ROCm0|Vulkan0
                                                       # (default auto: ROCm0 when build-hip lists it, else Vulkan0); --hf OWNER/REPO/FILE.gguf
                                                       # or a URL downloads the GGUF into ~/.claude-local/models (--sha256 HEX verifies it,
                                                       # --model-gguf PATH names it), skips the Ollama pull and appends a preset to the INI
                                                       # when none names the file; the Strix Halo command is at the top

Two files configure the unit. `~/.claude-local/llama-server.env` holds the device
(`LLAMA_DEVICE=ROCm0|Vulkan0`, which implies build-hip or build-vulkan) and the path of
`~/.claude-local/llama-models.ini`, the model presets: one section per GGUF, the section
name being the alias Claude sees, with that model's own sampling, `reasoning = on|off` and
speculation keys (llama-server long options without the dashes). The server runs in
llama.cpp's **router mode**: it starts without a model, `/models` lists every preset with
its load state, and the launcher loads the one you pick on demand (`/models/load`, then
polls the status). Up to two models stay resident (`LLAMA_ARG_MODELS_MAX=2`; two 27B-class models take
56GB of the 108GB pool and answer independently, leaving room for KV, the RAM prompt cache and the
desktop); beyond that, picking another saves the least recently used model's prompt cache and evicts it. Tuning that should not drift lives in
`systemd/llama-server/10-claude-local.conf` (128K context, q8_0 KV with flash attention, one
slot, Ollama-parity batch sizes, cache reuse, a 16 GB RAM prompt cache per instance) and is inherited
by every model instance. The cache is what brings a parent context back after a subagent or a WebFetch
summary took the single slot; measured 2026-09-08 at ~70 MB per 1K tokens on the Qwen3.6 presets, so
16 GB holds a full 112K-token parent plus several side contexts. It is per instance: at 32 GB with two
presets resident the unit peaked at 47 GB RAM plus 4.7 GB of swap, which is why the doctor now checks
`LLAMA_ARG_CACHE_RAM` x `LLAMA_ARG_MODELS_MAX` plus the largest weights against the host's RAM.

    llama-models-ini                                   # add every new GGUF under ~/.claude-local/models to the INI
    curl -s 'http://127.0.0.1:1244/models?reload=1'    # re-read the INI without a restart (editing a section)
    systemctl --user restart llama-server.service      # after changing the device or the drop-in

`/health` is 200 as soon as the router is up; a model's readiness is its status in `/models`
(the launcher waits on it and never restarts a loading server). "Unload" saves slot 0's prompt
cache to `~/.claude-local/slots/<alias>.bin` and frees the model's memory; the next load restores
the cache, so a fresh session starts warm even after a server restart. The pre-router layout
(`LLAMA_ARG_MODEL` + `LLAMA_ARG_ALIAS` in the env file, one model per server) still works.

### Models (llama-server presets, `config/llama-models.ini.example`)

| alias | file | what | per-model keys |
|---|---|---|---|
| `qwen3.6-35b` | Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL (22.9GB) | MoE, 3B active, MTP head embedded | `reasoning = off`, `spec-type = draft-mtp`, `spec-draft-n-max = 2` (the 2026-09-06 overnight winner) |
| `qwen3.6-35b-genesis` | Qwen3.6-35B-A3B-Uncensored-Genesis-Final-MTP-NVFP4 (22.2GB) | the same MoE with refusals removed (jan1k, abliterated), NVFP4, MTP head; the preset this host runs and bootstrap's recommended download | same keys as `qwen3.6-35b`; task bench `genesis-core` 2026-09-09: 9/9, 12.3 s/task, 6.4 turns, cache 89%, the same numbers as the filtered file (Measured claims) |
| `qwen3.8-27b` | Qwen3.8-27B-Q8_0 (29.0GB) | dense, thinking, MTP head embedded; reference quant | `reasoning = on`, `spec-type = draft-mtp`, `spec-draft-n-max = 4` |
| `qwen3.8-27b-q6kxl` | Qwen3.8-27B-UD-Q6_K_XL (25.3GB) | same model, Unsloth dynamic Q6 | same |
| `qwen3.8-27b-q6k` | Qwen3.8-27B-UD-Q6_K (22.0GB) | same model, smallest | same |

Qwen's recommended sampling (`temp 0.7, top-p 0.8, top-k 20, min-p 0, presence-penalty 1.5`)
sits in the INI's `[*]` section; `LLAMA_EXTRA_ARGS` is empty in router mode because CLI args
beat preset keys for every instance. Section names must not contain a colon: the preset parser
canonicalises whatever follows one as a quant tag (`qwen3.8:27b-q6k` would list as `qwen3.8:Q6K`).

Qwen3.8's chat template raises on a system message that is not first, and so does the Genesis build of
Qwen3.6 (an older Qwen3.6 template; the unsloth file merges leading system messages and ignores the rest).
Claude Code sends the Agent tool's type list as a mid-conversation `role: system` message and, unless
`CLAUDE_CODE_TOTAL_TOKENS_REMINDER=off`, its `<total_tokens>` reminder; the usage proxy folds them
into the system prompt (`config/proxy.py`), which is why `CLAUDE_LOCAL_PROXY=0` breaks Qwen3.8 whenever Agent is
in `--tools` and breaks Genesis on every turn (the bench runner starts its own proxy for llama-server since 2026-09-09).

### Switching models and searching the web

Three ways to change model: the menu at start (`CLAUDE_LOCAL_MODEL=<preset>` skips it; the model named by
`CLAUDE_LOCAL_DEFAULT_MODEL` in `~/.claude-local/env`, written by bootstrap, is listed first and Enter picks it:
`qwen3.6-35b-genesis` on this host), `/model <preset>`
inside the session (router mode loads an idle preset on the next request, up to `LLAMA_ARG_MODELS_MAX`
resident; the statusline follows Claude's choice and shows `(was <launch model>)`), or (a)nother in the
post-exit menu. Presets are the section names of `~/.claude-local/llama-models.ini`.

Claude Code's built-in `WebSearch` is executed by Anthropic's API, so against a local server every call
returns an empty result list (observed 2026-09-08). The launcher therefore leaves it out of `--tools` and
registers `config/mcp-websearch.py` via `--mcp-config` instead: a dependency-free stdio MCP server that
queries DuckDuckGo's HTML endpoint and shows up to the model as `mcp__websearch__web_search` (`--tools`
only limits the built-in set; MCP tools ride along). `WebFetch` is client-side and works as is.
`CLAUDE_LOCAL_WEBSEARCH=0` disables the server; `CLAUDE_LOCAL_OFFLINE=1` implies it.

### Errors and diagnostics

Every failure the stack can see is one JSON line in two places: the session's `run/<pid>/events.jsonl`
and `~/.claude-local/logs/events.jsonl` (rotated at 20 MB; the session dir is reaped by the next launcher,
the global log is not). `config/clog.py` writes them; the proxy, the launcher, the hooks and the doctor
all use it. At exit the launcher archives the session's small files (usage rows, events, tool audit, proxy
log, Claude Code's own debug log) to `logs/sessions/<start>-<pid>/`, keeping the last 40. A launcher that
was killed before its exit path (a closed terminal, a logout) is archived by the next launch before its run
dir is reaped, with a `session_reaped` event.

    claude-local-doctor            # read-only diagnosis, safe next to a live session (make doctor)
    claude-local-doctor --since 2h --quiet
    make test                      # offline: proxy error/anomaly events, hook guards, URL guard, drain, launcher flags; no model server (~15s)
    make check-prefix              # offline: real `claude -p` through proxy+stub, every follow-up request must extend the previous one
    make check-guard               # offline: real `claude -p` through the stub in acceptEdits and bypassPermissions; the guard must still refuse
    tail -f ~/.claude-local/logs/events.jsonl | jq -c '{level,kind,hint}'

What the proxy records (`config/proxy.py`), each with a `hint` saying what to do:

| kind | level | when |
|---|---|---|
| `turn_failed` | error | any non-200 Messages response: `status`, `err_class` (template, model_not_found, model_load, context, oom, busy, server, request), the server's `err_msg`, request shape |
| `upstream_unreachable` | error | the backend did not answer (502 to Claude Code), with `server_up` from a health probe |
| `stream_incomplete` | error | 200 but the stream ended without its final `message_delta`: the instance died mid-generation |
| `retry_storm` | error | three failed turns inside 60 s, which is what "waiting for API" is on the screen |
| `client_abort` | warn | Claude Code hung up mid-response (Esc, Ctrl-C, its own timeout) |
| `cache_miss` | warn | prompt >= 4K and cache hit < 50%; `div` says where the request diverged from the previous one of the same conversation: `extension` (server-side loss), `system[i]`, `tools`, `messages[i]` |
| `conv_switch` | info | a different conversation (subagent, side request) took the single slot |
| `output_truncated`, `empty_output`, `slow_prefill`, `slow_decode` | warn | stop_reason max_tokens; no tokens; ttft > 30 s; < 8 tok/s |
| `model_resume`, `model_restarted`, `restored`, `checkpoint*`, `idle_unload` | info/warn | the checkpoint layer's decisions |
| `volatile_system_stripped` | info | see below |
| `model_rewritten` | info | a request named a hosted model (`claude-*`: the auto-mode classifier, a subagent's model alias, context collapse) and the proxy ran it on the session's current model instead; `from`, `to`, `msgs`. The launcher pins the aliases, so this should be rare |

`CLAUDE_LOCAL_PROXY_DEBUG=2` also dumps every request body to `run/<pid>/requests/` for a post-mortem.
Every usage row now carries `conv` (conversation id) and `div`, so `usage.jsonl` alone shows a subagent
interleaving with its parent or a prefix that changed.

**The 0% cache of 2026-09-08, and its fix.** Claude Code (2.1.265) appends a `role: system` message
`<total_tokens>N tokens left</total_tokens>` to every request after the first, with a new number each turn and
the old ones kept (in print mode, `claude -p`, it is in the first request too: verified 2026-09-09 against the stub). The proxy's fold moved it into the system prompt, so on a hybrid model every turn
re-prefilled the tool schemas and the whole conversation (12K-30K tokens, 15-40 s; the server log shows
`selected slot by LCP similarity, f_sim_best = 0.45`). The proxy now drops that block wherever it appears
(`strip_volatile`: in a `role: system` entry, a user text block or a plain-string user message alike), the launcher sets `CLAUDE_CODE_TOTAL_TOKENS_REMINDER=off` so it is not sent at all, and
`make check-prefix` fails if any follow-up request is not a pure extension of the previous one. The moving
`cache_control` breakpoint that Claude Code also sends is not rendered by the server and is ignored.

Claude Code's own view goes to `run/<pid>/claude-debug.log` (`--debug-file`, `CLAUDE_LOCAL_CLAUDE_DEBUG=0`
turns it off): every API attempt (`API error (attempt 3/11)`), MCP and hook traffic. The debug file changes
nothing on screen. The doctor also reads the `API Error:` lines Claude Code wrote into its transcripts.

**Tool audit and guard rails** (`config/hook-audit.py`, wired for every tool in `config/settings.json`).
Every tool call is a line in `run/<pid>/tools.jsonl` (pre, post, failure, duration, first error line), and
failures are `tool_failed` events. Before a call runs, the guard refuses, with a reason the model can act on:
Bash commands that would destroy the tree or the machine (`rm -rf` on /, ~, ., .git; `mkfs`, `dd` to a disk;
force push; `reset --hard`, `clean -f`; `kill -9 -1`; reboot; `curl | sh`) and, most relevant here, anything
that stops or restarts the server or proxy serving the current session (`systemctl restart llama-server`,
`fuser -k 1244/tcp`, `pkill llama-server`, `kill <proxy pid>`), which the old diagnose skill used to suggest;
Write/Edit to a flattened path (`-home-user-...`, seen from small models), an invented `/tmp/claude-*`
directory, the real `~/.claude`, or a system root (`/etc`, `/usr`, `/boot`, `/bin`, `/sbin`, `/lib`, `/proc`, `/sys` and,
since 2026-09-08, `/opt`, `/root`, `/srv` and `/var`; `/var/tmp` stays allowed as scratch). Refusals are `tool_denied` events and show on the
statusline. `CLAUDE_LOCAL_BASHGUARD=0`, `CLAUDE_LOCAL_PATHGUARD=0`, `CLAUDE_LOCAL_AUDIT=0` switch the parts off.

**Permission mode and model names stay local.** The launcher passes `--permission-mode` (`CLAUDE_LOCAL_PERMISSION_MODE`,
default `acceptEdits`; `manual`, `plan`, `dontAsk`, `bypassPermissions` and `auto` are the other values, and a mode
or `--dangerously-skip-permissions` on the command line wins) and never starts in auto mode by itself: auto mode's
classifier sends a ~35K-token prompt to a hosted model for every tool call it evaluates, which against this router is
an HTTP 400 for `claude-sonnet-5` followed by the same prompt on the single local slot as a fallback (seen 2026-09-08,
the "issue with the selected model" API error). The isolated settings also set `permissions.disableAutoMode`, so auto
mode is hidden from the Shift+Tab cycle mid-session (Claude Code 2.1.266; with it set, `--permission-mode auto` is accepted but ignored: the debug log says
"auto mode disabled: disableAutoMode in settings" and the session starts without it, verified 2026-09-09). The guard above is the gate in every mode; `make check-guard` runs a real `claude -p`
against the stub in `acceptEdits` and `bypassPermissions` and requires the refused command to stay refused. For the same
reason the launcher pins six internal model choices to the session model unless the variable is already set:
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`, `CLAUDE_CODE_AUTO_MODE_MODEL`, `CLAUDE_CODE_BG_CLASSIFIER_MODEL` and
`CLAUDE_CONTEXT_COLLAPSE_MODEL`, so a classifier asked for "sonnet" never reaches the router with a name it does not know.
`CLAUDE_CODE_SUBAGENT_MODEL` is left unset on purpose: Claude Code gives a subagent the parent's current model unless it
is set, so subagents follow a mid-session `/model` switch. Any `claude-*` name that still reaches the proxy is rewritten
to the session's current model (the last local model a turn used, else the launch model, which the launcher passes as
`PROXY_SESSION_MODEL`) and logged as `model_rewritten`; the rewrite precedes fingerprinting, so the turn keeps its
conversation id, and any other unknown name still fails loudly as `model_not_found`. `test/launcher.py` proves both with a
fake `claude` (a `claude-sonnet-5` turn through the launcher-started proxy runs on the session model). The doctor flags any
`claude-*` name that still gets through, which now takes a session without the proxy (`CLAUDE_LOCAL_PROXY=0`) or without
the launcher.

The statusline's second line shows the session's last error or warning for ten minutes
(`!! turn_failed 500 template (1 err)`), so a retry loop is visible without opening any log.

**What the doctor checks:** symlinks and hook paths resolve, settings.json parses, every script parses,
`claude` present; the env file and adapter; unit state and restart count, the server's own error lines in
the window, `/health`, router presets and their `failed` flag, the INI against the GGUF files (missing,
truncated, bad magic, colons, duplicates) and against what the server has loaded (INI edited but not
reloaded), the drop-in against the running unit's environment (changed but not restarted), context vs
autocompact, the RAM budget (`LLAMA_ARG_CACHE_RAM` x `LLAMA_ARG_MODELS_MAX` plus the largest weights against RAM)
and the unit's memory and swap peaks since it started, orphan slot files; memory, swap, GPU memory, kernel GPU
resets and OOM kills, disk; live launchers, stale session dirs (and which of them a killed launcher left
unarchived), orphan proxies, ports, the idle-unload ledger, the transcript dirs under `~/.claude-local/projects` (how many
the bench scratch repos and `/tmp` test dirs left behind, WARN above 200 with the hint `make clean-transcripts`; 623 of 628,
37 MB, on 2026-09-08); the event log by kind with
the last occurrence's hint, tool denials and failures, Claude Code's API-error lines, and the median cache
hit of live sessions. It never restarts, kills or edits anything.

**Draining: models leave memory when nobody uses them.** The proxy's idle-unload runs only inside a live
session, and only between that session's turns; with the last session gone, or a busy session that is
always mid-turn, nothing unloaded anything (2026-09-08: a preset sat resident for 54 minutes next to a
live session on another preset). `claude-local-drain`, run every two minutes by the user timer
`claude-local-drain.timer` (installed and enabled by `make install`), applies the rules from outside:

- a model a live session was started on is never touched; a model with a request in flight is never touched
- no live session at all: every resident model idle for `CLAUDE_LOCAL_DRAIN_GRACE` seconds (default 300) is
  checkpointed and unloaded
- sessions live: a model none of them uses goes after `CLAUDE_LOCAL_IDLE_UNLOAD` seconds (default 1200)
- Ollama models get `keep_alive 0` under the same rules

Idle time comes from the shared ledger `run/last_use.json`. `make drain-status` (or `claude-local-drain
--status`) prints what is resident, who uses it, and the verdict; `journalctl --user -u
claude-local-drain.service` shows every unload; the doctor checks the timer is active, nothing is overdue,
and counts `drain_unload` / `drain_failed` events. A drained preset comes back warm through the slot file.

**Subagents on one slot.** `LLAMA_ARG_N_PARALLEL=1` means a parent and its subagents take turns in the same
slot. Hybrid models cannot rewind, so each hand-over re-prefills the resumed side (a 20K-token parent is
~25 s at 800 tok/s here); parallel subagents are serialised on the slot. The proxy marks every hand-over as
`conv_switch`, so `usage.jsonl` shows what a session with Agents costs. Use Agent for work whose result is
small and whose reading is large; run subagents sequentially rather than in parallel; or raise
`LLAMA_ARG_N_PARALLEL` in the drop-in at the cost of splitting the 128K context between slots (and lowering
autocompact to match). Since 2026-09-08 the operator prompt (`config/system_prompt.md`, and the compact one) says
exactly this to the model: agents share its one slot and run one at a time, every hand-over re-prefills the resumed
side at about a second per thousand tokens of its context, use an Agent when the reading is large and the result
small, and run agents one after another, never several at once (the old text promised parallel agents for more than
10 files). The evidence behind it: in a 60-turn session measured 2026-09-08, 18 side calls (subagents, WebFetch
summaries) took 191 of 589 GPU seconds.

### Checkpoints and resume (llama-server)

The usage proxy keeps the session warm across server trouble. Twenty seconds after a turn completes
with nothing in flight (`CLAUDE_LOCAL_CHECKPOINT`, 0 = off) it saves the model's prompt cache to
`~/.claude-local/slots/claude-local-<preset>.bin`, the file the launcher restores at load; measured
2026-09-08, a 10K-token context is 180 MB and 250 ms each way. Pending saves are flushed when the
session ends. Before every turn the proxy checks the preset: one that died (`kill -9`, OOM, a unit
restart) is loaded again and its checkpoint restored; one whose child port changed is restored too.
A crash therefore costs one failed turn and the retry starts warm instead of re-prefilling the
whole context. `make check-checkpoint` proves it by killing an idle instance.

One limit, measured 2026-09-08: every preset here is a hybrid model (`qwen35` / `qwen35moe`: SSM layers
with full attention every fourth block), whose recurrent state exists only at the last position, and
slot files carry no context checkpoints. A restored sequence can be extended, which is what the next
turn or a retry does, but not rewound: re-sending an identical or shorter prompt reprocesses everything.
The same applies to the launcher's restore at load.

The proxy also dehydrates what nobody is using. Every turn records its model in `run/last_use.json`,
shared by all sessions; a resident preset unused for 20 minutes (`CLAUDE_LOCAL_IDLE_UNLOAD`, 0 = off)
that is not the session's own model is checkpointed and unloaded, and comes back warm through the same
resume path when a session next needs it. `make check-idle` proves it with a throwaway preset. At start
the launcher also evicts whatever the *other* server holds (`CLAUDE_LOCAL_EXCLUSIVE`, default 1): Ollama
models via a zero keep-alive, llama-server presets after a checkpoint. Ollama and llama-server share
one memory pool, and two servers each holding a model is the realistic way to run it out.

A small model also invents URLs (five non-existent GitHub repos fetched in one session). The isolated
settings pre-allow `WebFetch` so browsing never prompts, and a PreToolUse hook (`config/hook-urlguard.py`)
denies any fetch whose URL, or a parent path of it, has not already appeared in a user message, a
search result or a tool output. The denial tells the model to search first. `CLAUDE_LOCAL_URLGUARD=0`
turns the guard off.

Raw benchmark rows are kept locally under `bench/results` and are mostly not in the repository: since the
2026-09-06 prune ("README has numbers as text tables") `.gitignore` keeps out every `bench/results/*.jsonl`,
per-run directory, proxy log and metrics snapshot, and only the microbench files under `bench/results/micro/`
plus the core-allowlist full-bench files `fb-ollama-vk-core.jsonl` and `proxy/usage-fb-*.jsonl` are tracked,
so the tables here are the record.

Measured 2026-09-07 (`bench/microbench.py`, cold prefill / decode at 2.7K, 10K and 30K prompt
tokens, n_out 128, medians of 2; `bench/results/micro/micro-q38-{rocm,vulkan}.jsonl`):

| preset / device | prefill tok/s 2.7K / 10K / 30K | decode tok/s 2.7K / 10K / 30K | cold TTFT 10K / 30K | warm turn TTFT 10K / 30K |
|---|---|---|---|---|
| `qwen3.6-35b` ROCm0 | 1079 / 1050 / 826 | 66.2 / 61.1 / 54.5 | 9s / 34s | 2.5s / 3.7s |
| `qwen3.6-35b` Vulkan0 (2026-09-06, `micro-q36.jsonl`) | 821 / 762 / 666 | 68.8 / 65.7 / 53.9 | 13s / 45s | 3.0s / 3.8s |
| `qwen3.8-27b` (Q8_0) ROCm0 | 334 / 318 / 248 | 7.7 / 7.6 / 7.2 | 30s / 113s | 8.4s / 11.5s |
| `qwen3.8-27b-q6kxl` ROCm0 | 306 / 313 / 266 | 8.6 / 8.3 / 7.8 | 30s / 105s | 8.1s / 11.5s |
| `qwen3.8-27b-q6k` ROCm0 | 291 / 299 / 258 | 9.4 / 9.4 / 8.6 | 32s / 108s | 8.5s / 11.8s |
| `qwen3.8-27b` (Q8_0) Vulkan0 | 181 / 196 / 188 | 7.3 / 7.5 / 7.2 | 49s / 150s | 13.1s / 14.8s |
| `qwen3.8-27b-q6kxl` Vulkan0 | 180 / 193 / 183 | 8.6 / 8.5 / 8.3 | 50s / 154s | 13.6s / 15.3s |
| `qwen3.8-27b-q6k` Vulkan0 | 182 / 195 / 184 | 9.8 / 9.7 / 9.4 | 49s / 152s | 13.4s / 15.2s |

What the numbers say:

- **Dense 27B is bandwidth-bound on this iGPU: 7-10 tok/s plain decode, 8x slower than the 3B-active
  MoE.** Q6_K buys 22% over Q8_0 for 7GB less; Q6_K_XL sits in between. The plain rows are the floor
  the presets no longer run at: see the speculation table below.
- **MTP speculation is the dense-model fix, and the presets ship with it.** Every unsloth Qwen3.8
  quant carries the MTP head (`blk.64.nextn.*`), and a dense bandwidth-bound decode is exactly the
  regime where verifying a draft costs about one token's worth of weight reads (the 2026-09-05 "spec
  loses" result was an MoE, where a batch activates more experts). The on-disk Qwen3-0.6B draft is
  unusable here: Qwen3.8 has a 248K-token vocabulary (Qwen3: 152K), so `draft-simple` cannot pair them.
- **ROCm0 is the device for both families now**: 1.6x the Vulkan prefill for Qwen3.8 at equal
  decode, 1.3x for Qwen3.6 at equal decode (the 2026-09-05 Vulkan preference was measured on
  Qwen3-Coder). `LLAMA_DEVICE=ROCm0` on this host.
- **Hybrid attention costs ~2K tokens of re-prefill per turn.** Both Qwen3.5-family files are
  gated-deltanet + attention; llama-server logs `cache_reuse is not supported by this context`
  and prompt reuse snaps to a context checkpoint, so every warm turn re-prefills 2048-2610
  tokens where Qwen3-Coder re-prefilled 7-567 (`micro-2026-09-05.jsonl`). That is ~2s per turn
  on Qwen3.6 and 6-8s on Qwen3.8. `LLAMA_ARG_CHECKPOINT_MIN_SPACING_NT=1024` with 128
  checkpoints changed nothing (`micro-q38-ckpt.jsonl`), so the defaults stay.
- Warm-turn TTFT above already includes that re-prefill: it is the realistic per-turn floor for a
  Claude Code session at that context depth, before any output tokens.

Speculation on the dense model, ROCm0, cold prompt, n_out 128, one rep (`micro-q38-spec.jsonl`;
acceptance from the server log on the synthetic code-rewrite output):

| preset (Q8_0 unless noted) | decode tok/s 2.7K / 10K | draft acceptance, mean accepted length |
|---|---|---|
| plain (from the table above) | 7.7 / 7.6 | - |
| `draft-mtp`, n-max 2 | 16.6 / 15.6 | 0.80, 2.6 |
| **`draft-mtp`, n-max 4** (shipped) | **19.2 / 17.8** | 0.61, 3.4 |
| `draft-mtp`, n-max 8 | 18.2 / 16.2 | 0.39, 4.0 |
| `ngram-mod` | 8.1 / 7.9 | 0.13 |
| UD-Q6_K + `draft-mtp` n-max 4 | 25.1 / 18.2 | 0.60, 3.3 |
| UD-Q6_K_XL + `draft-mtp` n-max 4 | 20.4 / 16.7 | 0.54, 3.1 |

At 10K prompt depth every quant lands at 17-18 tok/s: the hybrid-attention decode cost, not the
weight bytes, sets the speed there, so Q8_0 is the default and the Q6 files only pay off at shallow
context. A real launcher turn on `qwen3.8-27b` (MTP) logged 13.9 tok/s on an 84-token reply where
per-turn overhead dominates. Reasoning effort (`reasoning-effort = low|medium|xhigh`, a Qwen3.8
template feature) was sampled once per level on one coding prompt: xhigh 1887 output tokens in 103s,
medium 1415 in 67s, low 2043 in 90s; with temperature 0.7 one sample says nothing, so the knob is
documented, not set. The proper test is the task bench with `reasoning = off`, `reasoning-budget`
and each effort level.

### llama.cpp build recipe (ROCm 7.14 TheRock at /opt/rocm, gfx1151)

    git clone https://github.com/ggml-org/llama.cpp ~/ai/llama.cpp && cd ~/ai/llama.cpp
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
      cmake -S . -B build-hip -DGGML_HIP=ON -DGPU_TARGETS=gfx1151 -DCMAKE_BUILD_TYPE=Release
    cmake --build build-hip --config Release -j -t llama-server llama-bench
    cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build build-vulkan --config Release -j -t llama-server llama-bench

`GGML_HIP_ROCWMMA_FATTN` no longer exists upstream (removed July 2026); `-fa on` uses the native
kernel. Ollama's own bundled ROCm 7.2 runtime segfaults on this kernel (7.0); the upstream build links
the system ROCm and works.

Memory when everything is resident: Ollama ~26GB + one llama-server model (22-29GB, see the table) of the 108GB GPU pool.

## What is here

| path | role |
|---|---|
| `bin/claude-local` | launcher: server check, model picker, load, autocompact fit, prompt render, usage proxy, Claude launch, post-exit menu |
| `config/backend-ollama.sh` | backend adapter (the function contract is documented in the file) |
| `config/proxy.py` | streaming reverse proxy that logs per-turn usage (cache hit, tok/s, latency); optional sampling override; folds Claude Code's mid-conversation `role: system` message (Agent tool type list) into the system prompt, which Qwen3.8's chat template otherwise rejects with HTTP 500, and strips the `<total_tokens>` counter; rewrites a `claude-*` model name to the session's current model (`model_rewritten`); checkpoint/resume and idle unload of presets; every error and anomaly event |
| `config/statusline.sh` | four-line cockpit fed by the proxy log; per-session state; the model shown is the one Claude is using (follows `/model`) with its load state on the server |
| `config/mcp-websearch.py` | stdio MCP server: `web_search` over DuckDuckGo HTML, replacing the built-in WebSearch that cannot run against a local server |
| `config/hook-urlguard.py` | PreToolUse hook: denies WebFetch on a URL the conversation has never shown the model |
| `config/settings.json` | the isolated Claude Code settings: statusline, hook, pre-allowed WebFetch and web search, `permissions.disableAutoMode` (auto mode hidden from the Shift+Tab cycle), and an `env` block that keeps a bare `claude` run with this config dir on the local llama-server port instead of Anthropic's API |
| `config/picker.py` | model menu, or non-interactive via `CLAUDE_LOCAL_MODEL` |
| `config/system_prompt.md` | operator prompt appended to Claude's built-in prompt (`{{MODEL}}` templated); tells the model that Agents share its one slot and run one after another |
| `config/system_prompt_compact.md` | replacement prompt for `CLAUDE_LOCAL_PROMPT=replace`; faster, less careful |
| `bootstrap.sh` | single entry point for a fresh machine (see top). `--gpu amd-vulkan\|amd-rocm\|nvidia\|cpu` picks the Ollama profile; `--backend llamaserver` adds step 4b (`--device auto\|ROCm0\|Vulkan0`, default auto; `--hf URL\|OWNER/REPO/FILE.gguf` with `--sha256 HEX` downloads the GGUF, `--model-gguf PATH` names it, the Ollama pull is skipped, a preset is appended to the INI when none names the file and the alias becomes the model); an existing user unit, env file or INI is adopted, never overwritten |
| `systemd/ollama.service` | generic unit template (no GPU or tuning env; those are drop-ins) |
| `systemd/10-claude-local.conf` | drop-in: flash attention, 128K context, q8_0 KV, one slot, 2h keep-alive. Flash attention lives here because q8_0 KV silently falls back to f16 without it |
| `systemd/20-gpu-*.conf` | GPU profile drop-ins; bootstrap installs the chosen one as `20-gpu.conf` |
| `systemd/llama-server/` | llama-server unit template and drop-in (incl. `LLAMA_ARG_MODELS_MAX=2` and a 16 GB RAM prompt cache per instance); `config/llama-server.env.example` (device, INI path) and `config/llama-models.ini.example` (one preset per model) are its per-machine config; `bin/llama-server-run` is the ExecStart wrapper (device -> build dir, router vs single-model mode); `bin/llama-models-ini` appends presets for new GGUFs and reloads the router |
| `config/backend-llamaserver.sh` | llama-server adapter: router inventory with load state, load/unload via `/models/*` with status polling, per-model props, slot save/restore (single-model mode still supported) |
| `bench/` | 9 fixed tasks (09 is a ~630-line module whose first Read is a 6K-token turn), runner (`run.sh`: behind the usage proxy for llama-server, registered as a live session for the drain timer, deletes its scratch repo's transcript dir after each run), comparison, `microbench.py` (cold prefill / decode / warm-prefix for both APIs), `stack.sh` (one-line stack identity per row: kernel, firmware, Mesa, the glslc that built the Vulkan backend, `_q8_1` shader count, llama.cpp, Ollama, ROCm); results in `bench/results`, mostly local only (see above) |
| `skills/` | operator skills (configure/diagnose backend, manage models, tune, bench, bootstrap); linked into `~/.claude-local/skills` but only loaded when `Skill` is added to `CLAUDE_LOCAL_TOOLS`, which the 2026-09-05 measurements found to be a turn sink |
| `test/` | smoke turn, pty-driven interactive session, checkpoint/resume and idle-unload tests; offline: proxy events, hook and URL guards, drain, prefix stability, guard under each permission mode, and the launcher itself (`test/launcher.py`: a fake `claude` on PATH records what it is started with and sends one `claude-*` turn through the launcher-started proxy), all against `test/stub_upstream.py`; the tests delete the transcript dirs they leave |
| `scripts/contracts/check_no_ai_attribution.sh` | commit-message contract: no commit may credit an AI tool as an author (`Co-Authored-By: Claude\|GPT\|Copilot\|...`, `Claude-Session:`, `Generated with [Claude Code]`, session links). `--message-file FILE` is what `.githooks/commit-msg` runs (active only in a clone that set `git config core.hooksPath .githooks`); `--log [RANGE]` walks the history (default all of it) and is part of `make lint`, hence of `make test` and every `make check*`; exit 1 on a hit, 2 on usage |
| `Makefile` | the targets at the top; `make lint` syntax-checks every script and runs the attribution contract; `make clean-transcripts` deletes only `projects/-tmp-*` and `*-claude-local-bench-work-*` under `~/.claude-local` (Claude Code keeps one transcript dir per working directory, named from the physical cwd with every non-alphanumeric character turned into `-`) and prints how many dirs and MB it freed |

All env overrides are listed at the top of `bin/claude-local`.

## Measured claims (2026-09-05, qwen3-coder:30b Q4_K_M, Ryzen AI MAX+ 395, Vulkan iGPU)

| configuration | runs | pass | mean wall/task | cache hit |
|---|---|---|---|---|
| original launcher, 262K ctx, f16 KV | 8 | 100% | 89.8s | 92% |
| + `--exclude-dynamic-system-prompt-sections` | 8 | 100% | 41.9s | 98% |
| + server fit (128K ctx, q8_0 KV, 1 slot) = shipped default | 24 | 96% | 31.2s | 98% |
| control: server fit without the flag | 16 | 100% | 69.0s | 90% |
| compact replacement prompt | 24 | 88% | 22.0s | 99% |
| Q8 weights | 8 | 88% | 35.9s | 98% |

Mesa 26.2.2 gate (2026-09-08, label mesa262-ollama, 9 tasks x 1): 9/9, mean wall 27.8s, cache 96% versus fb-ollama-vk-core's 27/27, 21.4s, 95% on Mesa 25.2.8 (27 runs, the operator prompt also changed on 2026-09-08). Pass and cache rates are unchanged; the 6s higher mean comes from the first task, which included the model load (58s vs 23s), and one 18-turn run of 08-cli-flag (43s vs 18s) under a longer prompt (74K vs 50K prompt tokens per run), while the other seven tasks landed within 4s of the reference. Nothing here points at the driver, but a single repetition cannot separate Mesa from the prompt change.

Genesis, the uncensored build this host runs (2026-09-09, label `genesis-core`, 9 tasks x 1, ROCm0, through the runner's
proxy): 9/9, mean wall 12.3s, 6.4 turns/task, cache 89%, the same numbers as the filtered `q36-mtp2-core` winner (12.3s,
6.4, 88% over 27 runs); the abliteration costs nothing on this bench. The first attempt ran direct to the router and
scored 0/4 at 180s per task: the Genesis GGUF carries an older Qwen3.6 template that raises "System message must be at
the beginning" on the `<total_tokens>` reminder Claude Code 2.1.266 puts inside `messages`, and in print mode it does so
on the very first request. The bench runner now runs behind the usage proxy for llama-server (`--proxy`, the fold), sets
`CLAUDE_CODE_TOTAL_TOKENS_REMINDER=off` like the launcher, and registers itself as a live session so the drain timer,
which was unloading the model every two minutes during that attempt, leaves it alone.

- `--exclude-dynamic-system-prompt-sections` is the single biggest win: git status leaves the
  system prompt, so editing files no longer re-renders it and busts the server's prefix cache
  (uncached tokens per turn 1622 -> 267). Isolated by running each flag alone.
- `--system-prompt-snapshot on` is a no-op in Claude Code 2.1.261 (prompt recording not enabled). Passed anyway.
- Server fit cut model memory 45.6GB -> 26.1GB and mean time 42s -> 31s at equal pass rate.
- Q8 decodes slower on this iGPU (bandwidth-bound on weight size) and showed no accuracy gain. Not default.
- Compact prompt is 30% faster and skips edge-case verification. Opt-in only.
- Claude assumes a 200K window for unknown models; the launcher sets autocompact to
  server context - max output (16384) - 2048 so prompt + generation always fit, and the statusline gauge uses that.
- settings.json `env` overrides the process environment, and `--settings` overrides settings.json;
  the proxy URL is passed via `--settings` for that reason. The `env` block pins the llama-server port
  (1244), so `CLAUDE_CONFIG_DIR=~/.claude-local claude` without the launcher talks to that server or
  fails with a connection error; it never reaches Anthropic's API. Ollama users go through the launcher.
- Same-mode `--resume` is warm (21 uncached tokens). Changing prompt mode on resume re-sends the prompt once.
- Isolation: `CLAUDE_LOCAL_OFFLINE=1` points HTTPS_PROXY at a dead port with localhost bypassed.
  Project-level CLAUDE.md files still load, by design. Default 0 since 2026-09-07 (WebFetch and the
  web search MCP server need the internet); the 2026-09-05 measurements were taken offline.

## Backend measurements (2026-09-05, upstream llama.cpp 6a1a922d2 vs Ollama 0.33.3, same GGUF, q8_0 KV, flash attention, -b/-ub 2048)

Microbench (`bench/microbench.py`, cold prompt, temperature 0, medians of 3; raw rows in `bench/results/micro/`):

| config | 2.7K prefill / decode | 10K prefill / decode | 30K prefill / decode | 100K prefill / decode | warm turn wall 10K / 30K |
|---|---|---|---|---|---|
| Ollama Vulkan (was default) | 1106 / 72.9 | 768 / 59.7 | 402 / 41.9 | 138 / 8.2 | 2.3s / 3.4s |
| upstream Vulkan | 1213 / 77.3 | 952 / 62.5 | 561 / 43.1 | 226 / 22.5 | 2.2s / 3.1s |
| upstream HIP (ROCm 7.14) | 1525 / 56.9 | 1289 / 41.3 | 762 / 22.6 | 302 / 7.6 | 3.2s / 7.0s |
| upstream Vulkan, f16 KV | 1217 / 77.1 | 719 / 57.9 | 281 / 32.4 | - | 2.3s / 5.1s |
| upstream Vulkan + draft speculation (n_max 3) | 747 / 24.7 | 699 / 26.5 | - | - | 7.1s / 14.2s |
| upstream Vulkan + ngram-cache | 1216 / 40.8 | 954 / 26.0 | - | - | 3.7s / 7.3s |

(prefill and decode in tok/s; "warm turn" = cached prefix plus a few new tokens and 128 output tokens, the shape of a Claude Code turn)

Stack identity for every 2026-09-05 row (`bench/stack.sh`): kernel 7.0.0-31, firmware pfp/mec/mes 0x31/0x22/0x86, Mesa 25.2.8 (RADV), glslc 2023.8, llama.cpp 6a1a922d2, Ollama 0.33.3, ROCm 7.14. The upstream Vulkan build used Ubuntu's glslc 2023.8 (20 q8_1 shader variants vs 513 in Ollama's bundle). A rebuild with LunarG glslc 2026.3 (892 variants, label `intdot-vk`, `bench/results/micro/micro-intdot.jsonl`) measured within noise of it at every size for this Q4_K_M model (prefill 1246/998/571/225 vs 1213/952/561/226 tok/s at 2.7K/10K/30K/100K; decode 74/64/46/21 vs 77/63/43/22), so the rows above stand. Two corrections to the recorded stack strings, 2026-09-08: `bench/stack.sh` read `glslc --version` from PATH, so every row recorded after that rebuild carries `glslc 2023.8` although the backend was built with 2026.3; it now reports the compiler that built the Vulkan backend (the `Vulkan_GLSLC_EXECUTABLE` of `build-vulkan/CMakeCache.txt`, printed as `glslc=2026.3(build)`, or `(path)` when it has to fall back to PATH) and the `_q8_1` shader count of `libggml-vulkan.so` (`vkshaders=892` today; the 2023.8 build had 20). And Mesa moved from 25.2.8 to 26.2.2 (kisak PPA) on 2026-09-06 at 11:53 (dpkg log), after the 2026-09-05/06 rows and before the 2026-09-07 Qwen3.8 rows, so those tables sit on different Mesa builds; today's host line is kernel 7.0.0-31-generic, fw pfp/mec/mes 35/24/91, Mesa 26.2.2, glslc 2026.3(build), vkshaders 892, llama.cpp 6a1a922d2, Ollama 0.33.3, ROCm 7.14. The Ollama baseline on the new Mesa was recorded on 2026-09-08 under the label `mesa262-ollama` (the Phase 4 gate; `bench/compare.py mesa262-ollama fb-ollama-vk-core` reads it against the 2026-09-05 core-allowlist run): 9/9, mean wall 27.8s, cache 96% against 21.4s and 95% on Mesa 25.2.8, with the first task carrying the model load; the Mesa 26.2.2 gate paragraph under Measured claims has the reading. No GPU resets occurred during these runs (the previous boot had 9, all on Sep 3-4 under Ollama's Vulkan runner at 60-87K tokens in flight; kernel 7.0's 2s GPU job timeout is the suspected cause).

- **Upstream Vulkan beats Ollama's Vulkan everywhere**: +10% to +64% prefill, equal-or-better decode, and 22.5 vs 8.2 tok/s decode at 100K context. Newer kernels, same backend.
- **HIP prefills fastest but decodes slowest**, and its decode collapses with context (7.6 tok/s at 100K). Claude turns are decode-dominated, so Vulkan wins the per-turn cost at every depth; HIP is the choice only for prefill-bound work. Both backends lose ~90% of prefill throughput between depth 0 and 100K in llama-bench, so that cliff is the hardware's attention cost, not a HIP regression.
- **q8_0 KV cache is faster than f16 here** (30K: 2x prefill, +33% decode): attention is bandwidth-bound and the smaller cache wins. Keep q8_0.
- **Speculative decoding loses on this iGPU** despite 55% draft acceptance (2.6 tokens per verify step): the batched verify costs more than the tokens it saves. Draft n_max 8/16 and both ngram modes are worse still. Off by default; the env file documents how to re-try on other hardware.
- Ollama's bundled ROCm 7.2 segfaults on this Linux 7.0 kernel; the upstream HIP build links the system ROCm 7.14 and runs.

## Full-bench decision, 2026-09-05 evening (9 tasks x 3 reps, through the proxy, GPU 62-95C throttled, back to back)

| label | tools | pass | mean | median | turns/task | prompt tok/task |
|---|---|---|---|---|---|---|
| Ollama Vulkan, full tool list minus Agent | all minus Agent | 27/27 | 49.0s | 42.4s | 9.3 | 148K |
| upstream Vulkan, same | all minus Agent | 27/27 | 65.6s | 55.2s | 12.0 | 217K |
| upstream HIP, same | all minus Agent | 27/27 | 154.3s | 75.6s | 12.8 | 230K |
| Ollama Vulkan, 9 meta-tools denylisted | minus 9 | 27/27 | 26.1s | 23.8s | 7.9 | 98K |
| upstream Vulkan, same | minus 9 | 26/27 | 187.7s | 107.9s | 15.2 | 347K |
| **Ollama Vulkan, core allowlist (benchmark default; shipped default until 2026-09-07)** | Bash,Read,Edit,Write,Grep,Glob | 27/27 | **21.4s** | 20.8s | 8.5 | 50K |
| upstream Vulkan, core allowlist | same | 27/27 | 39.5s | 36.4s | 13.9 | 99K |
| upstream Vulkan rebuilt with LunarG glslc, core allowlist | same | 27/27 | 40.3s | 33.4s | 14.4 | 102K |

- **The tool surface is the second biggest lever after the cache flag.** With the full tool list the model spends ~30% of its turns on meta-tools (ReportFindings, TaskList/Create/Update, Skill, subagents); denylisting some just routes it to the next sink (74 Skill calls through llama-server, 3x task time). `--tools Bash,Read,Edit,Write,Grep,Glob` removes the sinks and shrinks the system prompt from ~15K to ~4.3K tokens. Ollama went 49s -> 21.4s on the same evening; the morning baseline on a cool GPU was 31s.
- **Default backend stays Ollama.** With identical tools, sampling and GGUF, the model takes 64% more turns and emits 2x the output tokens through llama-server's chat template, so task time is 1.8x worse even though the engine is equal or faster per turn (decode 69 vs 69 tok/s; large-prefill TTFT 9.1s vs 12.9s). Gate 2 fails; gates 1, 3, 4 and 5 pass (27/27, zero flakes in 108 llama-server runs, interactive 9/9, warm resume and slot restore verified).
- llama-server stays installed and verified as the alternative (`CLAUDE_LOCAL_BACKEND=llamaserver claude-local`): it wins at long context (22.5 vs 8.2 tok/s decode at 100K), persists the prompt cache across restarts (12.4K tokens saved in 123ms / restored in 42ms; next turn 2.9s TTFT vs 13.8s cold), and parses Qwen3-Coder tool calls natively. HIP is prefill-fast but collapses at depth (154s mean here); use it only for prefill-bound work.
- Stack for every row: kernel 7.0.0-31, fw pfp/mec/mes 31/22/86, Mesa 25.2.8 (RADV), glslc 2023.8 (the compiler on PATH, which is what `stack.sh` reported until 2026-09-08; the LunarG row was built with 2026.3, see the stack note above), llama.cpp 6a1a922d2, Ollama 0.33.3, ROCm 7.14 (`bench/stack.sh`; recorded per row from now on, since 2026-09-08 with the build compiler tagged `(build)`/`(path)` and the `vkshaders` count). Raw rows: `bench/results/fb-*.jsonl`, per-turn proxy logs `bench/results/proxy/`, metrics snapshots alongside; local only except `fb-ollama-vk-core.jsonl` and the two `proxy/usage-fb-*.jsonl`, the table is the record.

## Known unknowns

- **Why the model behaves differently through llama-server's template** (same GGUF, sampling, tools: +64% turns, 2x output). Suspects: the GGUF's jinja template (tool rendering, system placement) vs Ollama's chatml template, and tool-call parsing leniency. Experiment: `--chat-template-file` with a template rendering like Ollama's, then `bench/run.sh --label ls-vk-tmpl --port 1244 ... --tools Bash,Read,Edit,Write,Grep,Glob` vs `fb-ollama-vk-core`. If turns equalise, llama-server should win outright on its per-turn numbers.
- Resolved: the LunarG-glslc rebuild of the Vulkan backend (892 q8_1 variants) performs the same as the 2023.8 build for this Q4_K_M model; the shader-extension gap was not holding it back.
- Kernel 7.0's 2s GPU job timeout vs ggml-vulkan's 100-node submits: ring timeouts on Sep 3-4 under Ollama's Vulkan runner at 60-87K tokens; none during today's runs. `GGML_VK_MAX_NODES_PER_SUBMIT` test pending.
- 2 of 81 morning runs (full tool list, Ollama) had the model emit a malformed native XML tool call as text on turn 1; zero in the 216 evening runs.
  Claude sends no temperature/top_p, so sampling can be pinned either in a Modelfile or with
  `CLAUDE_LOCAL_SAMPLING='{"temperature":0.7,"top_p":0.8,"top_k":20}'`. Unmeasured. To measure:
  start `config/proxy.py` with `PROXY_SAMPLING` set and run `bench/run.sh --label sampling --port 1235 --repeat 3 -- ...`.
- `backend-llamaserver.sh` needs a real llama-server run. It exists to keep the on-disk prompt-cache path open.
- Ollama truncates prompts from the front when they exceed the context; the headroom math above is the guard,
  but a session long enough to hit autocompact has not been observed end to end.
