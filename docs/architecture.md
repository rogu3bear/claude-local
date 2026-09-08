# Architecture

## System overview

```mermaid
flowchart TD
    subgraph user["User"]
        U["claude-local<br/>launcher"]
    end

    subgraph claude["Claude Code CLI"]
        CC["Claude Code<br/>(Anthropic API client)"]
    end

    subgraph proxy["Usage Proxy"]
        P["proxy.py<br/>token logging +<br/>sampling override"]
    end

    subgraph backend["Model Server"]
        O["Ollama 0.33.3<br/>Vulkan / ROCm"]
        LS["llama.cpp<br/>llama-server"]
    end

    subgraph config["~/.claude-local/"]
        SP["system_prompt.md"]
        SE["env<br/>port/backend map"]
        SLOT["slots/<br/>prompt cache"]
    end

    U -->|"1. picks model, loads it"| O
    U -->|"2. starts proxy on free port"| P
    U -->|"3. launches Claude Code<br/>--model qwen3.6:35b<br/>--autocompact 120832<br/>--tools Bash,Read,...<br/>ANTHROPIC_BASE_URL=http://proxy"| CC

    CC -->|"4. /v1/messages<br/>streaming SSE"| P
    P -->|"5. forwards upstream<br/>logs usage to JSONL"| P
    P -->|"6. /v1/messages"| O

    O -->|"7. GGUF weights<br/>from ~/.claude-local/models/"| O

    SP -.->|"templated into session"| CC
    SE -.->|"port + backend config"| U
    SLOT -.->|"slot save/restore<br/>llama-server only"| LS
```

## Data flow per turn

```mermaid
sequenceDiagram
    participant User
    participant Claude as Claude Code
    participant Proxy as proxy.py
    participant Server as Model Server

    User->>Claude: type prompt + submit
    Claude->>Proxy: POST /v1/messages<br/>(system + tools + history + new prompt)
    Proxy->>Proxy: parse sampling params,<br/>apply PROXY_SAMPLING override
    Proxy->>Server: forward request upstream
    Server-->>Proxy: SSE stream (token by token)
    Proxy->>Proxy: extract usage from<br/>message_delta event
    Proxy->>Proxy: append JSONL row<br/>(tokens, latency, cache%, tok/s)
    Proxy-->>Claude: pass-through SSE stream
    Claude-->>User: streamed response
```

## Component map

| component | file | role |
|---|---|---|
| **Launcher** | `bin/claude-local` | Orchestrates the full lifecycle: server check, model picker, load, proxy, Claude launch, post-exit menu |
| **Usage Proxy** | `config/proxy.py` | Transparent reverse proxy; logs per-turn usage (cache hits, tok/s, latency) as JSONL for the statusline |
| **Statusline** | `config/statusline.sh` | Four-line cockpit showing uncached tokens, cache hit %, output throughput, and context gauge |
| **Model Picker** | `config/picker.py` | Interactive menu of available models; non-interactive via `CLAUDE_LOCAL_MODEL` |
| **Backend Adapter (Ollama)** | `config/backend-ollama.sh` | Ollama-specific: health check, model inventory, load/unload, context length probe |
| **Backend Adapter (llama-server)** | `config/backend-llamaserver.sh` | llama-server router mode: preset inventory with load state, `/models/load` + status polling, `/models/unload`, per-model props, slot save/restore (single-model layout still supported) |
| **Model presets (llama-server)** | `~/.claude-local/llama-models.ini` | One section per GGUF: alias, file, reasoning, speculation, sampling; `bin/llama-models-ini` appends new files; `?reload=1` re-reads it |
| **System Prompt** | `config/system_prompt.md` | Operator prompt templated with `{{MODEL}}`; appended to Claude's built-in prompt |
| **Config** | `~/.claude-local/env` | Persisted defaults: port, backend, model — written by bootstrap |

## Key design decisions

- **Isolated config directory** — `~/.claude-local/` is fully separate from `~/.claude/`. Your project-level Claude Code setup is never touched.
- **Offline by default** — `CLAUDE_LOCAL_OFFLINE=1` (default) points `HTTPS_PROXY` at a dead port with localhost bypassed. Project CLAUDE.md files still load; everything else needs explicit opt-in (`CLAUDE_LOCAL_OFFLINE=0`).
- **Autocompact fitted to server context** — Claude Code assumes 200K for unknown models. The launcher computes `autocompact = server_context - max_output(8192) - 2048` so prompt + generation always fit before compacting. Floor: 100K.
- **Attribution header disabled** — `CLAUDE_CODE_ATTRIBUTION_HEADER=0` keeps the system prompt byte-identical across turns, preserving the server's prefix cache.
- **Tool surface minimized** — default is `Bash,Read,Edit,Write,Grep,Glob`. The full tool list costs ~5K extra prompt tokens and wastes ~30% of turns on meta-tools (ReportFindings, TaskList, Skill).
