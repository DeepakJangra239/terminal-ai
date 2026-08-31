# Terminal AI — Local AI Assistant for Any macOS Terminal

Turn any macOS terminal (Ghostty, iTerm2, Terminal.app, Warp, etc.) into an AI-powered command line with natural language → command translation, smart completions, and history search — all running locally on Apple Silicon.

## Features

| Feature | Description |
|---------|-------------|
| **NL → Command** | Press `Ctrl+G` or type `??` to convert natural language to shell commands |
| **Explain Errors** | Run `explain` after a failed command to get a 3-bullet diagnosis + fix |
| **Tab Completions** | Carapace-powered completions for git, docker, kubectl, brew, and 300+ tools |
| **History Ghost** | Atuin-powered sync + Ctrl+R fuzzy search across sessions |
| **Local Inference** | Three backends: **BaseRT** (native Metal, auto-unload), **mlx_lm** (Apple MLX), **oMLX** (tiered KV cache) |
| **Any Terminal** | Works in zsh/bash/fish across Ghostty, iTerm2, Terminal.app, Warp, Alacritty, etc. |

## Quick Start

```bash
# 1. Make executable and run
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

| Option | Backend | Speed | Notes |
|--------|---------|-------|-------|
| **1** | **BaseRT** (recommended) | ~35 tok/s | Native Metal, no MLX, auto-unloads after 5 min idle without killing process |
| 2 | mlx_lm | ~28 tok/s | Apple MLX, requires Python + pip packages |
| 3 | oMLX | varies | DMG app with tiered hot+cold KV cache (manual DMG install) |

**Default: BaseRT** — best balance of speed, memory efficiency, and zero-config.

### 2. Choose Model

| Option | Model | Size (BaseRT) | Size (MLX) | Notes |
|--------|-------|---------------|------------|-------|
| **1** | **Qwen3.5-4B** (winner) | 2.1 GB | 2.9 GB | Won bake-off (0.824 vs Phi 0.713) |
| 2 | Phi-4-mini 3.8B | 2.0 GB | 2.0 GB | Fallback for 8 GB RAM |
| 3 | Both | 4.1 GB | 4.9 GB | A/B comparison |

**Default: Qwen3.5-4B** — best quality/size ratio.

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

| Keys | Action |
|------|--------|
| `Ctrl+G` | Open NL→command widget (gum input or inline vared) |
| `?? <prompt>` | Inline NL→command (e.g., `?? kill process on port 3000`) |
| `tai <prompt>` | CLI alias for `terminal-ai` |
| `Ctrl+R` | Atuin history search (if completions enabled) |
| `Tab` | Carapace completions (git, docker, kubectl, brew, etc.) |

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
# BaseRT (default, port 18789)
~/.basert/basert serve basecompute/Qwen3-4B --port 18789 --idle-timeout 300 &

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
export TERMINAL_AI_URL="http://127.0.0.1:18789/v1/chat/completions"
export TERMINAL_AI_MODEL="basecompute/Qwen3-4B"

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

| Path | Purpose |
|------|---------|
| `~/.cache/terminal-ai/models/` | MLX models (Qwen/Phi safetensors) |
| `~/Library/Caches/baseRT/models/` | BaseRT .base models |
| `~/.config/zsh/terminal-ai.zsh` | Zsh widget + aliases |
| `~/.local/bin/terminal-ai` | Python CLI (`tai`, `ghostty-ai` symlinks) |
| `~/Library/LaunchAgents/com.terminal-ai.plist` | BaseRT launch agent (disabled by default) |
| `~/.zshrc` | Shell integration (backed up before modification) |

## Troubleshooting

### "Connection refused" on `??` or `Ctrl+G`

The server isn't running. Start it manually:

```bash
# BaseRT
~/.basert/basert serve basecompute/Qwen3-4B --port 18789 --idle-timeout 300 &

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
set -x TERMINAL_AI_URL "http://127.0.0.1:18789/v1/chat/completions"
set -x TERMINAL_AI_MODEL "basecompute/Qwen3-4B"
# carapace for fish:
carapace _carapace fish | source
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      User Terminal                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Ctrl+G / ??  │  │   Tab / ^R   │  │  terminal-ai CLI │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
│         │                 │                    │            │
│         ▼                 ▼                    ▼            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           ~/.config/zsh/terminal-ai.zsh              │   │
│  │  _terminal_ai_call() → JSON payload → HTTP POST      │   │
│  └────────────────────────────┬─────────────────────────┘   │
│                               │                              │
│                    ┌──────────┴──────────┐                   │
│                    ▼                     ▼                   │
│           ┌───────────────┐      ┌───────────────┐          │
│           │   BaseRT      │      │   mlx_lm      │          │
│           │  :18789       │      │  :7821        │          │
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
