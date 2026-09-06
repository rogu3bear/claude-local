# Bootstrap flow

One command from a fresh Linux user account to a working `claude-local`:

```bash
git clone https://github.com/rogu3bear/claude-local ~/dev/claude-local && \
~/dev/claude-local/bootstrap.sh --gpu amd-vulkan --backend ollama
```

## Steps

```mermaid
flowchart TD
    A["bootstrap.sh"] --> B{"--dry-run?"}
    B -->|yes| Z["Print plan, exit"]
    B -->|no| C["1. Check deps:<br/>git curl jq python3<br/>systemd tar zstd<br/>node+npm (via nvm)"]

    C --> D["2. Install Ollama<br/>~/.local/ollama/<br/>~1.5GB download"]
    D --> E["3. Configure systemd<br/>user service + drop-ins:<br/>10-claude-local.conf<br/>20-gpu-<profile>.conf"]
    E --> F["4. Pull model<br/>qwen3-coder:30b<br/>~18GB download"]

    F --> G["5. Install harness<br/>./install.sh:<br/>symlinks, ollama wrapper,<br/>drop-ins into ~/.claude-local/"]
    G --> H["6. Smoke turn<br/>through launcher + proxy"]
    H --> I["✅ claude-local ready"]

    C -.->|"any missing"| M["Report package + command,<br/>stop — user installs, re-runs"]

    style A fill:#e1f5fe
    style I fill:#c8e6c9
    style M fill:#ffebee
```

## Idempotency

Every step checks before acting:

| step | guard |
|---|---|
| deps | `which <pkg>` for each dependency |
| Ollama | `ollama --version` — skip if already installed |
| systemd unit | existing unit is **adopted** (port, binary), never overwritten |
| model pull | `ollama list | grep <model>` — skip if present |
| harness install | symlinks use `-f`, drop-ins check for env changes before restarting server |

## GPU profiles (`--gpu`)

```mermaid
flowchart LR
    P["--gpu PROFILE"] --> V["amd-vulkan<br/>Vulkan iGPU (default)"]
    P --> R["amd-rocm<br/>ROCm discrete GPU"]
    P --> N["nvidia<br/>NVIDIA CUDA"]
    P --> C["cpu<br/>CPU-only fallback"]

    V --> D1["20-gpu-amd-vulkan.conf"]
    R --> D2["20-gpu-amd-rocm.conf"]
    N --> D3["20-gpu-nvidia.conf"]
    C --> D4["20-gpu-cpu.conf"]

    style P fill:#f3e5f5
    style D1 fill:#e8f5e9
    style D2 fill:#e8f5e9
    style D3 fill:#e8f5e9
    style D4 fill:#e8f5e9
```

## Backend options (`--backend`)

| backend | port | extra step |
|---|---|---|
| `ollama` (default) | 1234 | None — pulls model via Ollama API |
| `llamaserver` | 1244 | Needs upstream llama.cpp build (`--llama-cpp DIR`), resolves GGUF from Ollama manifest, optional draft model download |

## Key flags

```bash
./bootstrap.sh --dry-run              # show plan without acting
./bootstrap.sh --no-smoke             # skip the smoke turn at the end
./bootstrap.sh --model qwen3.6:35b    # use a different model
./bootstrap.sh --port 1235            # custom port (default 1234)
```
