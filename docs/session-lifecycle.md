# Session lifecycle

The full flow from `claude-local` invocation to post-exit menu.

## Launch sequence

```mermaid
flowchart TD
    A["user runs<br/>claude-local"] --> B[Read ~/.claude-local/env]
    B --> C{Backend server<br/>reachable?}
    C -->|no| D[Start backend server<br/>backend_start()]
    D --> E{Server up now?}
    E -->|no| F["Wait for user to start it,<br/>then retry"]
    F --> E
    E -->|yes| G[Inventory models<br/>backend_models_json()]

    G --> H{"CLAUDE_LOCAL_MODEL<br/>set?"}
    H -->|yes| I[Use that model]
    H -->|no| J[Show picker menu<br/>picker.py]

    I --> K{Model loaded?}
    J --> K

    K -->|no| L[Load model<br/>with spinner + timer]
    K -->|yes| M["Already loaded"]

    L --> N[Start usage proxy<br/>proxy.py on free port]
    M --> N

    N --> O{Proxy bound?}
    O -->|no| P["Connect directly,<br/>skip proxy logging"]
    O -->|yes| Q["Route through proxy"]

    P --> R[Compute autocompact:<br/>ctx - max_output(8192) - 2048<br/>floor 100K]
    Q --> R

    R --> S[Render system prompt<br/>template {{MODEL}}]
    S --> T["Launch Claude Code:<br/>--model $MODEL<br/>--autocompact $AC<br/>--tools Bash,Read,...<br/>ANTHROPIC_BASE_URL=$URL"]

    style A fill:#e1f5fe
    style T fill:#fff3e0
```

## Per-turn cycle

Each user turn goes through the proxy which logs usage data:

```mermaid
flowchart LR
    U["User types<br/>+ submits"] --> CC["Claude Code"]
    CC -->|"POST /v1/messages"| P["proxy.py"]
    P -->|"forward upstream"| S["Model Server"]
    S -->|"SSE stream"| P
    P -->|"parse message_delta"| P
    P -->|"append JSONL row"| J["usage.jsonl"]
    P -->|"pass-through SSE"| CC
    CC --> U

    style P fill:#fff9c4
    style J fill:#e8f5e9
```

## Post-exit menu

After Claude Code exits (Ctrl-C or normal exit), the launcher offers:

```mermaid
flowchart TD
    A["Claude Code exits"] --> B{Other models<br/>still loaded?}
    B -->|no| C["No model loaded.<br/>Session complete."]
    B -->|yes| D["Prompt: (u)nload /<br/>load (a)nother / Enter=leave"]

    D -->|"u"| E[Unload all loaded models<br/>prompt cache saved to slots/]
    E --> F{"unload_keeps_model?"}
    F -->|yes| G["Server stays up,<br/>slot 0 cache restored next launch"]
    F -->|no| H["Memory freed.<br/>Server may stop."]

    D -->|"a"| I[Show picker again<br/>load selected model]
    I --> J["Now loaded: <models>"]

    D -->|Enter| K["Leave all loaded.<br/>Session complete."]

    style A fill:#f3e5f5
    style C fill:#c8e6c9
    style G fill:#c8e6c9
    style H fill:#c8e6c9
    style K fill:#c8e6c9
```

## Configuration layers

Each layer overrides the previous:

```mermaid
flowchart LR
    P["Process env vars<br/>CLAUDE_LOCAL_*"] --> S["settings.json<br/>env block"]
    S --> C["--settings CLI flag<br/>proxy URL + auth token"]

    P -.->|"lowest"| M["Model server config<br/>llama-server.env / ollama Modelfile"]
    S -.->|"overrides"| M

    style P fill:#e3f2fd
    style S fill:#fff3e0
    style C fill:#ffebee
    style M fill:#e8f5e9
```

## File layout during a session

```mermaid
flowchart TD
    subgraph session["Per-session state (~/.claude-local/run/$$/]"]
        R["session_start<br/>session_model<br/>context_max<br/>system_prompt.md (rendered)<br/>mcp.json"]
        U["usage.jsonl"]
        PP["proxy_port"]
        PL["proxy.log"]
    end

    subgraph config["~/.claude-local/"]
        E["env"]
        SP["system_prompt.md (template)"]
        M["models/<model>.gguf"]
        SL["slots/<slot0.bin>"]
    end

    subgraph launcher["~/dev/claude-local/"]
        LA["bin/claude-local"]
        PR["config/proxy.py"]
        PK["config/picker.py"]
        WS["config/mcp-websearch.py"]
    end

    LA --> E
    LA --> SP
    LA --> PR
    LA --> PK
    LA --> R
    LA --> U

    PR --> U
    PR --> PP

    style session fill:#f1f8e9
    style config fill:#e3f2fd
    style launcher fill:#fff3e0
```
