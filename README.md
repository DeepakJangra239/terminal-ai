# Terminal AI — Local AI Assistant for Any macOS Terminal

Turn any macOS terminal (Ghostty, iTerm2, Terminal.app, Warp, etc.) into an AI-powered command line with natural language → command translation, smart completions, and history search — all running locally on Apple Silicon.

## Features

| Feature             | Description                                                                                                |
| ------------------- | ---------------------------------------------------------------------------------------------------------- |
| **NL → Command**    | Press `Ctrl+G` or type `??` to convert natural language to shell commands                                  |
| **Explain Errors**  | Run `explain` after a failed command to get a 3-bullet diagnosis + fix                                     |
| **Tab Completions** | Carapace-powered completions for git, docker, kubectl, brew, and 300+ tools                                |
| **History Ghost**   | Atuin-powered sync + Ctrl+R fuzzy search across sessions                                                   |
| **Local Inference** | Three backends: **BaseRT** (native Metal, auto-unload), **mlx_lm** (Apple MLX), **oMLX** (tiered KV cache) |
| **Any Terminal**    | `terminal-ai` CLI works in zsh/bash/fish; the `??`/`Ctrl+G` widget is zsh-based (confirmed on zsh)         |

## Quick Start

```bash
# 1. Run the installer
# (A) One-liner — no clone needed (download-then-run lets you inspect it first;
#     `curl ... | bash` works too):
#   curl -fsSL https://raw.githubusercontent.com/DeepakJangra239/terminal-ai/main/install-terminal-ai.sh -o /tmp/ta.sh
#   bash /tmp/ta.sh
# (B) Clone first:
chmod +x install-terminal-ai.sh
./install-terminal-ai.sh

# 2. Reload shell
source ~/.zshrc
# (or just reopen your terminal)

# 3. Try it
?? list all docker containers including stopped
# → docker ps -a

# Press Ctrl+G, type: "find large log files"
# → find /var/log -name "*.log" -size +100M
```

## Installation Walkthrough

The script is interactive and will prompt you for three choices:

### 1. Choose Inference Backend

| Option | Backend                  | Speed     | Notes                                                                       |
| ------ | ------------------------ | --------- | --------------------------------------------------------------------------- |
| **1**  | **BaseRT** (recommended) | ~35 tok/s | Native Metal, no MLX, auto-unloads after 5 min idle without killing process |
| 2      | mlx_lm                   | ~28 tok/s | Apple MLX, requires Python + pip packages                                   |
| 3      | oMLX                     | varies    | DMG app with tiered hot+cold KV cache (manual DMG install)                  |

**Default: BaseRT** — best balance of speed, memory efficiency, and zero-config.

### 2. Choose Model

| Option | Model                 | Size (BaseRT) | Size (MLX) | Notes                                                            |
| ------ | --------------------- | ------------- | ---------- | ---------------------------------------------------------------- |
| **1**  | **Qwen3.5-4B** (recommended winner) | 2.4 GB (.base) | 2.9 GB (MLX) | Eval v2: ~68% accuracy, 1/1000 wrong, CJK-clean on BaseRT + oMLX |
| 2      | Qwen3-4B (baseline)  | 2.1 GB        | 2.9 GB     | Preconverted BaseRT catalog entry (port 18789)                  |
| 3      | Phi-4-mini 3.8B      | 2.0 GB        | 2.0 GB     | Fallback for 8 GB RAM                                           |
| 4      | Both Qwen3-4B + Qwen3.5-4B | 4.5 GB | 4.9 GB     | A/B comparison (18789 + 18790)                                  |

**Default: Qwen3.5-4B** — clean IPs (no CJK digit corruption), best instruction-following.

> **Eval v2 (see `eval/RESULTS_v2.md`):** a 1,000-query harness (tmux/screen/ssh/ports/general)
> shows **Qwen3.5-4B + the new pipeline is the best choice** (~68% accuracy, only 1/1000
> wrong, no CJK digit corruption). The `1`→`题` corruption is **Qwen3-4B-checkpoint-specific**;
> Qwen3.5-4B is clean on both BaseRT and oMLX. Prefer **Qwen3.5-4B** and the **official Qwen
> sampling config** (`temperature=0.7, top_p=0.8, top_k=20, presence_penalty=1.5`,
> `enable_thinking=False`). The installer is **fully standalone**: the canonical CLI/widget
> live embedded in `install-terminal-ai.sh` (byte-identical copies are written fresh into the
> installing user's home), so the curl one-liner above needs no clone. A `payloads/` dir in
> the repo root is a **local dev copy only — gitignored**, not read at install time.

### 3. Deterministic Completions

- **Yes** — Installs carapace, atuin, zsh-autosuggestions, zsh-syntax-highlighting
- **No** — Skip (you can add later)

**Default: Yes** — highly recommended for the full experience.

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- 16 GB RAM recommended (8 GB works with Phi-4-mini)
- 10 GB free disk space
- Homebrew (`brew install` from https://brew.sh)
- Python 3 (built-in on macOS)

## Post-Installation Usage

### Key Bindings

| Keys           | Action                                                   |
| -------------- | -------------------------------------------------------- |
| `Ctrl+G`       | Open NL→command widget (gum input or inline vared)       |
| `?? <prompt>`  | Inline NL→command (e.g., `?? kill process on port 3000`) |
| `tai <prompt>` | CLI alias for `terminal-ai`                              |
| `Ctrl+R`       | Atuin history search (if completions enabled)            |
| `Tab`          | Carapace completions (git, docker, kubectl, brew, etc.)  |

### Commands

```bash
# Natural language to command
?? find files modified in last hour larger than 100MB
?? show me all listening ports with process names
?? create a tar.gz of this folder excluding node_modules
?? restart docker desktop

# Direct CLI usage
terminal-ai "list all kubernetes pods in namespace production"
tai "list all kubernetes pods in namespace production"
```

### Managing the Inference Server

The installer auto-starts your chosen backend on first run. If it stops:

```bash
# BaseRT (default, port 18790)
~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790 --idle-timeout 300 &

# mlx_lm (port 7821)
mlx_lm.server --model ~/.cache/terminal-ai/models/qwen3.5-4b-mlx-4bit --port 7821 &

# oMLX (port 8000)
open /Applications/oMLX.app
# or if CLI available:
/Applications/oMLX.app/Contents/MacOS/omlx-cli start
```

**BaseRT auto-unloads** the model after 5 minutes of inactivity (idle-timeout 300) without killing the process — next request reloads automatically.

### Switching Backends/Models

Edit `~/.zshrc` and change the export block:

```bash
# BaseRT Qwen (default)
export TERMINAL_AI_URL="http://127.0.0.1:18790/v1/chat/completions"
export TERMINAL_AI_MODEL="Qwen3.5-4B"

# mlx_lm Qwen
# export TERMINAL_AI_URL="http://127.0.0.1:7821/v1/chat/completions"
# export TERMINAL_AI_MODEL="$HOME/.cache/terminal-ai/models/qwen3.5-4b-mlx-4bit"

# oMLX Qwen
# export TERMINAL_AI_URL="http://127.0.0.1:8000/v1/chat/completions"
# export TERMINAL_AI_MODEL="qwen3.5-4b-mlx-4bit"
```

Then `source ~/.zshrc` and restart the corresponding server.

### Uninstall

```bash
./install-terminal-ai.sh --uninstall
```

This removes shell config, launch agents, and CLI wrappers — **keeps downloaded models** in `~/.cache/terminal-ai/models` and `~/Library/Caches/baseRT`.

## File Locations

| Path                                           | Purpose                                           |
| ---------------------------------------------- | ------------------------------------------------- |
| `~/.cache/terminal-ai/models/`                 | MLX models (Qwen/Phi safetensors)                 |
| `~/Library/Caches/baseRT/models/`              | BaseRT .base models                               |
| `~/.config/zsh/terminal-ai.zsh`                | Zsh widget + aliases                              |
| `~/.local/bin/terminal-ai`                     | Python CLI (`tai`, `ghostty-ai` symlinks)         |
| `~/Library/LaunchAgents/com.terminal-ai.plist` | BaseRT launch agent (disabled by default)         |
| `~/.zshrc`                                     | Shell integration (backed up before modification) |

## Troubleshooting

### "Connection refused" on `??` or `Ctrl+G`

The server isn't running. Start it manually:

```bash
# BaseRT
~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790 --idle-timeout 300 &

# mlx_lm
mlx_lm.server --model ~/.cache/terminal-ai/models/qwen3.5-4b-mlx-4bit --port 7821 &
```

The widget has auto-retry logic but manual start is more reliable.

### Model not found / download failed

Re-run the installer — it skips already-cached models:

```bash
./install-terminal-ai.sh
```

### Completions not working

```bash
# Reload completions
exec zsh
# or
source ~/.zshrc
compinit
```

### Want to use bash/fish?

The installer adds minimal bash config to `~/.bashrc`. For fish:

```fish
# Add to ~/.config/fish/config.fish
set -x TERMINAL_AI_URL "http://127.0.0.1:18790/v1/chat/completions"
set -x TERMINAL_AI_MODEL "Qwen3.5-4B"
# carapace for fish:
carapace _carapace fish | source
```

> The `??`/`Ctrl+G` NL→command widget is zsh-based and confirmed working on zsh. In bash/fish, use the `terminal-ai` CLI directly (e.g. `terminal-ai "list pods in production"`) — the widget hasn't been tested there.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Terminal                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Ctrl+G / ??  │  │   Tab / ^R   │  │  terminal-ai CLI │   │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │
│         │                 │                   │             │
│         ▼                 ▼                   ▼             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           ~/.config/zsh/terminal-ai.zsh              │   │
│  │  _terminal_ai_call() → JSON payload → HTTP POST      │   │
│  └────────────────────────────┬─────────────────────────┘   │
│                               │                             │
│                    ┌──────────┴──────────┐                  │
│                    ▼                     ▼                  │
│           ┌───────────────┐      ┌───────────────┐          │
│           │   BaseRT      │      │   mlx_lm      │          │
│           │  :18790       │      │  :7821        │          │
│           │  (Metal)      │      │  (MLX)        │          │
│           └───────────────┘      └───────────────┘          │
└─────────────────────────────────────────────────────────────┘
```

- **Zero cloud** — everything runs locally on your Mac
- **OpenAI-compatible API** — `/v1/chat/completions` endpoint
- **Backend-aware models** — BaseRT uses `.base` format, MLX uses `safetensors`
- **Auto-start fallback** — widget attempts to launch server if down

## License

MIT — use freely, modify, distribute.
