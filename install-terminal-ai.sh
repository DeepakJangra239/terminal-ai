#!/usr/bin/env bash
# install-terminal-ai.sh — Interactive installer for Local Terminal AI (any macOS terminal)
# Works on Ghostty, iTerm2, Terminal.app, Warp, etc. with zsh/bash/fish
# Features: Tab completions (carapace) + history ghost + NL→command (Ctrl+G / ??) via local tiny LLM
# Inference (choose one): BaseRT (native Metal, idle-timeout) | mlx_lm (Apple MLX) | oMLX (DMG)
# Models: backend-aware — BaseRT pulls basecompute .base (no MLX), MLX pulls mlx-community (no BaseRT), both via wget -4 -c or basert pull
# Usage (A) curl one-liner (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/DeepakJangra239/terminal-ai/main/install-terminal-ai.sh -o /tmp/ta.sh
#   bash /tmp/ta.sh
#   (curl ... | bash works too, but the download-then-run form above lets you
#    inspect the script first and survives curl failures — recommended.)
# Usage (B) clone:  chmod +x install-terminal-ai.sh && ./install-terminal-ai.sh
# Test/dry-run knobs: HOME=/sandbox/path (full path isolation) and
#   TERMINAL_AI_TEST=1 (skip brew/basert installs, model downloads, server start)
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; exit 1; }
ask()   { local p="$1" d="$2" a; read -rp "$(echo -e "${BOLD}$p${NC} [$d]: ")" a; echo "${a:-$d}"; }
confirm() { local p="$1" a; read -rp "$(echo -e "${BOLD}$p${NC} [y/N]: ")" a; [[ "$a" =~ ^[Yy]$ ]]; }

# Paths honor env overrides (sandbox/dry-run: HOME or individual *_override).
CACHE_DIR="${TERMINAL_AI_CACHE_DIR_OVERRIDE:-$HOME/.cache/terminal-ai}"
MODEL_DIR="${TERMINAL_AI_MODEL_DIR_OVERRIDE:-$CACHE_DIR/models}"
BIN_DIR="${TERMINAL_AI_BIN_DIR_OVERRIDE:-$HOME/.local/bin}"
ZSHRC="${TERMINAL_AI_ZSHRC_OVERRIDE:-$HOME/.zshrc}"
BASHRC="${TERMINAL_AI_BASHRC_OVERRIDE:-$HOME/.bashrc}"
BASE_PORT=18789; QWEN35_PORT=18790; MLX_PORT=7821; OMLX_PORT=8000

# Legacy compat: if user already has ghostty-ai cache, reuse its models (no re-download)
if [[ -d "$HOME/.cache/ghostty-ai/models" && ! -d "$MODEL_DIR" ]]; then
  info "Migrating legacy ~/.cache/ghostty-ai/models → $MODEL_DIR"
  mkdir -p "$CACHE_DIR"; ln -sf "$HOME/.cache/ghostty-ai/models" "$MODEL_DIR" 2>/dev/null || cp -a "$HOME/.cache/ghostty-ai/models" "$MODEL_DIR"
fi

preflight() {
  info "Preflight..."
  [[ "$(uname -s)" == "Darwin" ]] || fail "macOS only"
  [[ "$(uname -m)" == "arm64" ]] || warn "Apple Silicon recommended (you are $(uname -m))"
  local mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}'); info "Memory: ${mem}GB"
  (( mem < 16 )) && warn "16GB+ recommended for Qwen3.5-4B (2.9GB MLX / 2.1GB BaseRT). For 8GB choose Phi-4-mini."
  local free=$(df -g / | awk 'NR==2{print $4}'); info "Disk free: ${free}GB"
  (( free < 10 )) && warn "10GB free recommended"
  command -v brew >/dev/null 2>&1 || fail "Homebrew required — https://brew.sh"
  command -v python3 >/dev/null 2>&1 || fail "python3 required"
  mkdir -p "$CACHE_DIR" "$MODEL_DIR" "$BIN_DIR" "$HOME/.config/zsh" "$HOME/.config/terminal-ai" "$CACHE_DIR/bench" "$CACHE_DIR/scripts"
  ok "Preflight ok"
}

choose_inference() {
  echo "" >&2; echo -e "${BOLD}Choose inference backend:${NC}" >&2
  echo "  1) BaseRT (recommended) — native Metal, no MLX, 34.8 tok/s, auto-unload after TTL without killing process" >&2
  echo "  2) mlx_lm (Apple MLX) — 28.5 tok/s, GPU auto" >&2
  echo "  3) oMLX (DMG) — tiered KV hot+cold SSD" >&2
  local c; c=$(ask "Backend [1/2/3]" "1")
  case "$c" in 2) echo "mlx";; 3) echo "omlx";; *) echo "basert";; esac
}
choose_model() {
  echo "" >&2; echo -e "${BOLD}Choose model (1,000-query eval v2: Qwen3.5-4B + new pipeline ~68% vs Qwen3-4B ~51%):${NC}" >&2
  echo "  1) Qwen3.5-4B (RECOMMENDED winner) — BaseRT port 18790 (HF download + basert convert)" >&2
  echo "  2) Qwen3-4B (baseline, preconverted) — BaseRT port 18789" >&2
  echo "  3) Phi-4-mini 3.8B (2.0GB, mlx/omlx only)" >&2
  echo "  4) Both Qwen3-4B + Qwen3.5-4B (A/B: 18789 + 18790)" >&2
  local c; c=$(ask "Model [1/2/3/4]" "1")
  case "$c" in 2) echo "qwen4";; 3) echo "phi";; 4) echo "both";; *) echo "qwen35";; esac
}
choose_completions() {
  echo ""; echo -e "${BOLD}Deterministic completions (Tab + ghost):${NC}"
  if confirm "Install carapace + zsh-autosuggestions + atuin?"; then echo "yes"; else echo "no"; fi
}

# --- backend-aware deps ---
install_deps() {
  local backend="$1" comp="$2"
  [[ "${TERMINAL_AI_TEST:-0}" == "1" ]] && { warn "TERMINAL_AI_TEST=1 — skipping brew/pip (dry-run)"; return 0; }
  info "Installing deps for backend=$backend..."
  brew update >/dev/null 2>&1 || true
  local pkgs=()
  [[ "$comp" == "yes" ]] && pkgs+=(carapace atuin zsh-autosuggestions zsh-syntax-highlighting)
  pkgs+=(gum)
  for p in "${pkgs[@]}"; do brew list "$p" >/dev/null 2>&1 && ok "$p already" || brew install "$p" 2>&1 | tail -3; done
  case "$backend" in
    mlx|omlx) info "Upgrading MLX stack (mlx 0.32.2 / mlx-lm 0.31.3)..."; pip install -U "mlx>=0.31.2" "mlx-lm==0.31.3" "mlx-metal" 2>&1 | tail -3 || warn "pip upgrade failed";;
    basert) info "Skipping MLX pip (BaseRT uses native Metal, no mlx needed)";;
  esac
  ok "Deps done"
}
install_basert() {
  [[ "${TERMINAL_AI_TEST:-0}" == "1" ]] && { warn "TERMINAL_AI_TEST=1 — skipping BaseRT install (dry-run)"; return 0; }
  if [[ -x "$HOME/.basert/basert" ]]; then ok "BaseRT already at ~/.basert"; return; fi
  info "Installing BaseRT (native Metal)..."
  curl -LsSf https://basecompute.co/install.sh | sh 2>&1 | tail -10
  export PATH="$HOME/.basert:$PATH"
  ok "BaseRT installed"
}
install_omlx() {
  if [[ -d "/Applications/oMLX.app" ]]; then ok "oMLX already at /Applications/oMLX.app"; return; fi
  info "oMLX DMG — download from https://github.com/jundot/omlx/releases and drag to Applications"
  warn "Skipping auto-install (needs DMG), mlx will be used"
}

# --- backend-aware model download ---
download_model() {
  local backend="$1" key="$2"
  [[ "${TERMINAL_AI_TEST:-0}" == "1" ]] && { warn "TERMINAL_AI_TEST=1 — skipping model download (dry-run)"; return 0; }
  # helper for MLX via wget -4 -c (mlx-community first, Unsloth GGUF fallback if needed)
  fetch_mlx() {
    local repo="$1" dest="$2"
    info "Fetching $repo -> $dest (wget -4 -c)..."
    mkdir -p "$dest"
    local files; files=$(curl -s "https://huggingface.co/api/models/$repo" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join([s['rfilename'] for s in d['siblings']]))")
    for f in $files; do
      echo "  $f"
      wget -4 -c -q --show-progress -O "$dest/$f" "https://huggingface.co/$repo/resolve/main/$f" 2>&1 | tail -1 || wget -4 -c -O "$dest/$f" "https://huggingface.co/$repo/resolve/main/$f"
    done
    du -sh "$dest" | tail -1
  }
  case "$backend" in
    basert)
      info "BaseRT path — pulling .base (no MLX, no mlx-community)..."
      # Lesson: basert pull of Qwen/Qwen3.5-4B FAILS (shard download incomplete).
      #   1) if already cached → ok
      #   2) try basert pull (convert-on-pull)
      #   3) fallback: HF CLI download → basert convert --target base-q4
      if [[ "$key" == "phi" ]]; then
        warn "Phi-4-mini not in BaseRT catalog — use mlx/omlx backend instead"
      fi
      if [[ "$key" == "qwen4" || "$key" == "both" ]]; then
        if "$HOME/.basert/basert" list 2>&1 | grep -q "basecompute/Qwen3-4B"; then ok "basecompute/Qwen3-4B already cached"
        else "$HOME/.basert/basert" pull basecompute/Qwen3-4B 2>&1 | tail -20 || warn "BaseRT pull failed, will retry on serve"
        fi
      fi
      if [[ "$key" == "qwen35" || "$key" == "both" ]]; then
        if "$HOME/.basert/basert" list 2>&1 | grep -q "Qwen/Qwen3.5-4B"; then
          ok "Qwen/Qwen3.5-4B already cached"
        else
          warn "basert pull Qwen/Qwen3.5-4B is known to fail (shard download) — using HF download + basert convert"
          if "$HOME/.basert/basert" pull "Qwen/Qwen3.5-4B" --force 2>&1 | tail -20 && "$HOME/.basert/basert" list 2>&1 | grep -q "Qwen/Qwen3.5-4B"; then
            ok "basert pull succeeded after all"
          else
            info "Downloading official Qwen/Qwen3.5-4B via huggingface-cli..."
            local dl="$HOME/Downloads/qwen35"
            mkdir -p "$dl"
            if command -v huggingface-cli >/dev/null 2>&1; then
              huggingface-cli download "Qwen/Qwen3.5-4B" --local-dir "$dl" 2>&1 | tail -3
            else
              python3 -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen3.5-4B', local_dir='$dl')" 2>&1 | tail -3
            fi
            [[ -f "$dl/model.safetensors.index.json" ]] && ok "HF download done" || fail "HF download failed"
            info "Converting to .base (base-q4)..."
            "$HOME/.basert/basert" convert "$dl" -o "$HOME/Library/Caches/baseRT/models/Qwen/Qwen3.5-4B/default-q4/model.base" --target base-q4 2>&1 | tail -20
            "$HOME/.basert/basert" list 2>&1 | grep -q "Qwen/Qwen3.5-4B" && ok "Qwen3.5-4B .base ready" || fail "convert failed"
          fi
        fi
      fi
      ;;
    mlx|omlx)
      info "MLX path — mlx-community first, Unsloth GGUF fallback, wget -4 -c..."
      if [[ "$key" == "phi" || "$key" == "both" ]]; then
        [[ -f "$MODEL_DIR/phi4-mini-4bit/model.safetensors" ]] && ok "phi already cached" || fetch_mlx "mlx-community/Phi-4-mini-instruct-4bit" "$MODEL_DIR/phi4-mini-4bit"
      fi
      if [[ "$key" == "qwen35" || "$key" == "qwen4" || "$key" == "both" ]]; then
        [[ -f "$MODEL_DIR/qwen3.5-4b-mlx-4bit/model.safetensors" ]] && ok "qwen already cached" || fetch_mlx "mlx-community/Qwen3.5-4B-MLX-4bit" "$MODEL_DIR/qwen3.5-4b-mlx-4bit"
      fi
      ;;
  esac
}

setup_shell() {
  local comp="$1" backend="$2" model="$3"
  # Ports per eval v2: Qwen3.5-4B on 18790, Qwen3-4B baseline on 18789.
  local AI_URL="http://127.0.0.1:18789/v1/chat/completions" AI_MODEL="basecompute/Qwen3-4B"
  [[ "$model" == "qwen35" ]] && { AI_URL="http://127.0.0.1:18790/v1/chat/completions"; AI_MODEL="Qwen3.5-4B"; }
  info "Setting up shell (zsh primary, bash/fish best-effort)..."
  cp "$ZSHRC" "$ZSHRC.bak.$(date +%s)" 2>/dev/null || true
  if grep -q "Terminal AI" "$ZSHRC" 2>/dev/null; then
    python3 <<'PY'
import pathlib, re
p=pathlib.Path.home()/".zshrc"
t=p.read_text()
t=re.sub(r"# --- Terminal AI.*?export TERMINAL_AI_MODEL=.*\n","",t,flags=re.DOTALL)
p.write_text(t)
PY
  fi
  # also clean old ghostty block for migration
  if grep -q "Ghostty AI Native" "$ZSHRC" 2>/dev/null; then
    python3 -c "import pathlib,re; p=pathlib.Path.home()/'.zshrc'; t=p.read_text(); t=re.sub(r'# --- Ghostty AI Native.*?export GHOSTTY_AI_MODEL=.*\n','',t,flags=re.DOTALL); p.write_text(t)"
  fi
  cat >> "$ZSHRC" <<EOS

# --- Terminal AI (any terminal) — installed by install-terminal-ai.sh ---
export PATH="/opt/homebrew/bin:\$PATH"
autoload -Uz compinit && compinit
export CARAPACE_BRIDGES='zsh,fish,bash,inshellisense'
if command -v carapace >/dev/null 2>&1; then source <(carapace _carapace); fi
export ATUIN_NOBIND="true"
eval "\$(atuin init zsh)" 2>/dev/null
if [[ "\$ATUIN_NOBIND" == "true" ]]; then bindkey '^R' history-incremental-search-backward; fi
export ZSH_AUTOSUGGEST_STRATEGY=(history completion)
source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#666666"
source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
if [[ -f "\$HOME/.config/zsh/terminal-ai.zsh" ]]; then source "\$HOME/.config/zsh/terminal-ai.zsh"; fi
# Backend switch — uncomment one (BaseRT is default winner)
# mlx Qwen (7821): export TERMINAL_AI_URL="http://127.0.0.1:7821/v1/chat/completions"; export TERMINAL_AI_MODEL="$HOME/.cache/terminal-ai/models/qwen3.5-4b-mlx-4bit"
# oMLX Qwen (8000): export TERMINAL_AI_URL="http://127.0.0.1:8000/v1/chat/completions"; export TERMINAL_AI_MODEL="qwen3.5-4b-mlx-4bit"
export TERMINAL_AI_URL="$AI_URL"
export TERMINAL_AI_MODEL="$AI_MODEL"
# compat for old ghostty-ai env
export GHOSTTY_AI_URL="\$TERMINAL_AI_URL"
export GHOSTTY_AI_MODEL="\$TERMINAL_AI_MODEL"
EOS
  # fix $HOME placeholder (already expanded above, but keep)
  [[ ! -f "$ZSHRC" ]] || zsh -n "$ZSHRC" && ok "zshrc patched" || warn "zshrc syntax"
  if [[ -f "$BASHRC" ]] && ! grep -q "terminal-ai" "$BASHRC" 2>/dev/null; then
    echo '# terminal-ai (bash)' >> "$BASHRC"
    echo "export TERMINAL_AI_URL=\"$AI_URL\"; export TERMINAL_AI_MODEL=\"$AI_MODEL\"" >> "$BASHRC"
    echo 'alias "??"="~/.local/bin/terminal-ai"' >> "$BASHRC"
  fi
  ok "Shell done"
}

write_payloads() {
  info "Writing payloads (widget, CLI, config)..."
  mkdir -p "$HOME/.config/zsh" "$HOME/.config/terminal-ai" "$CACHE_DIR/bench" "$CACHE_DIR/scripts" "$BIN_DIR"
  # Fully standalone: the complete Terminal-AI CLI + widget are embedded below
  # (byte-identical to the payloads/ dev copies, which are NOT read at install
  # time); this writes a fresh copy into the installing user's home directory.
  # widget (any macOS terminal; delegates generation to the CLI binary)
  cat > "$HOME/.config/zsh/terminal-ai.zsh" <<'WZSH'
# payloads/terminal-ai.zsh — Canonical Terminal-AI zsh widget.
# A byte-identical copy of this file is embedded inside install-terminal-ai.sh
# (fully standalone installer) and written to ~/.config/zsh/terminal-ai.zsh on
# install; payloads/ is the dev/editable reference — keep the two in sync.
# Thin UI wrapper: all NL→command logic (prompt, value-injection, validation+retry,
# router, official config) lives in the CLI (~/.local/bin/terminal-ai).
if [[ -z "$TERMINAL_AI_URL" ]]; then export TERMINAL_AI_URL="http://127.0.0.1:18790/v1/chat/completions"; fi
if [[ -z "$TERMINAL_AI_MODEL" ]]; then export TERMINAL_AI_MODEL="Qwen3.5-4B"; fi
# compat
export GHOSTTY_AI_URL="$TERMINAL_AI_URL"; export GHOSTTY_AI_MODEL="$TERMINAL_AI_MODEL"

_terminal_ai_call() {
  local nl="$1" mode="${2:-translate}" cmd err
  # resolve the canonical CLI (installed at ~/.local/bin/terminal-ai)
  local cli
  if command -v terminal-ai >/dev/null 2>&1; then cli="terminal-ai"
  elif [[ -x "$HOME/.local/bin/terminal-ai" ]]; then cli="$HOME/.local/bin/terminal-ai"
  else print -r -- "terminal-ai error: CLI not found at ~/.local/bin/terminal-ai (re-run install-terminal-ai.sh)" >&2; return 1; fi
  if [[ "$mode" == "explain" ]]; then
    err=$($cli --mode explain "$nl" 2>&1); [[ -z "$err" ]] && { print -r -- "terminal-ai error: empty result (is server on $TERMINAL_AI_URL?)" >&2; return 1; }
    # CLI prints errors as "error: ..." on stdout-with-nonzero or stderr-captured text
    if [[ "$err" == "error:"* || "$err" == "fail:"* ]]; then print -r -- "terminal-ai error: $err (server $TERMINAL_AI_URL?)" >&2; return 1; fi
    print -r -- "$err"; return 0
  fi
  # translate / reason -> delegate to canonical CLI (does value-injection, validation, retry, router)
  local cfg="general"; [[ "$mode" == "reason" ]] && cfg="coding"
  cmd=$($cli --mode translate --config "$cfg" "$nl" 2>&1); local rc=$?
  if [[ $rc -ne 0 || -z "$cmd" ]]; then
    [[ -z "$cmd" ]] && cmd="(no output)"
    print -r -- "terminal-ai error: $cmd (is server on $TERMINAL_AI_URL? try: ~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790 &)" >&2
    return 1
  fi
  if [[ "$cmd" == "error:"* ]]; then print -r -- "terminal-ai error: $cmd (server $TERMINAL_AI_URL?)" >&2; return 1; fi
  print -r -- "$cmd"
}

terminal-ai-widget() {
  local nl mode="translate"
  if [[ -n "$BUFFER" && "$BUFFER" == "??!"* ]]; then
    local raw="${BUFFER#??! }"; raw="${raw#??!}"
    if [[ -n "$raw" && "$raw" != " "* ]]; then nl="$raw"; mode="reason"
    else if command -v gum >/dev/null 2>&1; then nl=$(gum input --placeholder "Describe command (hard) > "); else local tmp=""; vared -p "NLP(hard)> " -c tmp; nl="$tmp"; fi; fi
  elif [[ -n "$BUFFER" && "$BUFFER" != "??"* ]]; then
    if [[ "$BUFFER" == *" "* && "$BUFFER" != *"/"* ]]; then nl="$BUFFER"
    else if command -v gum >/dev/null 2>&1; then nl=$(gum input --placeholder "Describe command (e.g., find large logs) > " --value "$BUFFER"); else local tmp=""; vared -p "NLP> " -c tmp; nl="$tmp"; fi; fi
  else
    local raw="${BUFFER#?? }"; raw="${raw#??}"
    if [[ -n "$raw" && "$raw" != " "* ]]; then nl="$raw"
    else if command -v gum >/dev/null 2>&1; then nl=$(gum input --placeholder "Describe command > "); else local tmp=""; vared -p "NLP> " -c tmp; nl="$tmp"; fi; fi
  fi
  [[ -z "$nl" ]] && return 0
  local cmd; zle -M "🧠 $TERMINAL_AI_MODEL…"; cmd=$(_terminal_ai_call "$nl" "$mode"); local rc=$?; zle -M ""
  [[ $rc -ne 0 || -z "$cmd" ]] && { zle -M "no result (is server on $TERMINAL_AI_URL?)"; return 1; }
  BUFFER="$cmd"; CURSOR=${#BUFFER}; zle redisplay
}
zle -N terminal-ai-widget; bindkey '^G' terminal-ai-widget; bindkey '^X^G' terminal-ai-widget
zle -N ghostty-ai-widget 2>/dev/null; bindkey '^G' terminal-ai-widget 2>/dev/null
__terminal_ai_prefix() {
  if [[ "$1" == "??" ]]; then shift; local nl="$*"; [[ -z "$nl" ]] && { zle terminal-ai-widget 2>/dev/null || terminal-ai-widget; return; }
    local cmd; cmd=$(_terminal_ai_call "$nl" "translate")
    if [[ -n "$cmd" ]]; then print -z -- "$cmd"; echo "→ $cmd"; else echo "terminal-ai: no result (is server on $TERMINAL_AI_URL?) — run: ~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790 &" >&2; return 1; fi; fi
}
alias '??'='noglob __terminal_ai_prefix ??'
alias 'ghostty-ai'='terminal-ai'
explain() { local c=$(fc -ln -1 2>/dev/null | sed 's/^[[:space:]]*//'); [[ -z "$c" ]] && c="$1"; _terminal_ai_call "Explain failure for: $c" "explain"; }
WZSH
  # keep ghostty compat symlink
  ln -sf "$HOME/.config/zsh/terminal-ai.zsh" "$HOME/.config/zsh/ghostty-ai.zsh" 2>/dev/null || true
  # CLI (canonical implementation)
  cat > "$BIN_DIR/terminal-ai" <<'WCLI'
#!/usr/bin/env python3
"""
terminal-ai — Canonical Terminal-AI CLI implementation.

A byte-identical copy of this file is embedded inside install-terminal-ai.sh
(fully standalone installer) and written fresh to ~/.local/bin/terminal-ai on
install; payloads/terminal-ai is the dev/editable reference — keep the two in sync.

It implements:
  1. Official Qwen3.5-4B sampling config (instruct/non-thinking).
  2. Improved system prompt + few-shot examples.
  3. Deterministic value-injection pre-pass (extracts host/IP/port/file/process).
  4. Post-generation validation + retry self-correction loop (model never executes).
  5. Deterministic router for high-frequency intents.

The model only ever GENERATES text; all validation/execution happens here (the
wrapper), and the final command is merely PRINTED for the user to run.
"""
import argparse, json, sys, os, re, subprocess, urllib.request, time
from pathlib import Path

DEFAULT_URL = os.environ.get("TERMINAL_AI_URL", "http://127.0.0.1:18790/v1/chat/completions")
DEFAULT_MODEL = os.environ.get("TERMINAL_AI_MODEL", "Qwen3.5-4B")

# --- Official Qwen3.5-4B sampling config (instruct / non-thinking) ----------
# Recommended: temperature=0.7, top_p=0.8, top_k=20, min_p=0.0,
#              presence_penalty=1.5, repetition_penalty=1.0
# Precise coding-style alternative: temperature=0.6, top_p=0.95, top_k=20.
CONFIG_GENERAL = {"temperature": 0.7, "top_p": 0.8, "top_k": 20, "min_p": 0.0,
                  "presence_penalty": 1.5, "repetition_penalty": 1.0, "max_tokens": 512}
CONFIG_CODING = {"temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0.0,
                 "presence_penalty": 0.0, "repetition_penalty": 1.0, "max_tokens": 512}

SYSTEM_T = """You are a shell command generator for macOS (zsh, Apple Silicon).
Rules — follow ALL of them:
1. Output exactly ONE line: a single macOS zsh command. No prose, no markdown fences, no explanation.
2. Prefer macOS tools: lsof -i -P -n | grep LISTEN, netstat -anv, brew, pbcopy, diskutil, launchctl, pmset, ipconfig. Never use Linux tools (systemctl, ss, netstat -tulnp, sort -h).
3. Use the EXACT values from the user's request. If the user gives a host/IP, port, file, process, or session name, put it verbatim in the command. NEVER emit generic placeholders like user@host, file.txt, mysession, /path/to/, or remote_server.
4. Only use `lsof -i -P -n | grep LISTEN` when the user asks about LISTENING ports. Do not use it for ssh tunnels, screen, or unrelated intents.
5. `screen -S <name>` for screen sessions; `tmux` for tmux sessions. Never substitute one for the other.
6. For `find`, ALWAYS include a path argument (e.g. `find . ...`), never `find -type f`.
7. `ssh` connects: `ssh [opts] user@host` (or `ssh -l user host`). Tunnels: `ssh -L/-R/-D`. Copy: `scp`. Never answer ssh/screen intent with `lsof`.

Examples (gold):
- list tmux sessions -> tmux list-sessions
- create tmux session dev -> tmux new-session -s dev
- screen session build -> screen -S build
- show listening ports -> lsof -i -P -n | grep LISTEN
- process on port 3000 -> lsof -i :3000
- kill process on port 3000 -> lsof -ti :3000 | xargs -r kill -9
- ssh as root@192.168.1.10 -> ssh root@192.168.1.10
- ssh to host on port 2222 -> ssh -p 2222 user@host
- forward local 8080 to remote 80 -> ssh -L 8080:localhost:80 user@host
- find files larger than 100MB -> find . -type f -size +100M
- show disk usage sorted -> du -sh * | sort -rh
- show git log last 5 -> git log -5
- show last lines -> tail -n 50 file"""

SYSTEM_E = ("You are a zsh expert on macOS. Explain this shell error in 3 bullets and "
            "suggest a fix. Be concise, no markdown headers.")

# --- Value extraction (regex, no model) --------------------------------------
IP_RE = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b")
PORT_RE = re.compile(r"\bport[s]?[:\s]*(\d{2,5})\b|\bon\s+port\s+(\d{2,5})\b")
USER_RE = re.compile(r"\bas\s+(\w+)\b|user(?:name)?\s+(\w+)")
HOST_RE = re.compile(r"\b(server|host|hostname|ip)[a-z]*\s+([\w.\-]+)")
FILE_RE = re.compile(r"\b([\w.\-]+\.(?:log|txt|py|md|js|json|yaml|csv|html|css|pdf|tar\.gz|conf|yml))\b")
PROC_RE = re.compile(r"\b(?:kill|process|procs|service)\s+(\w+)")
NAME_RE = re.compile(r"\b(?:session|window|pane)\s+(?:named\s+)?(\w+)")

def extract_values(prompt):
    """Return a dict of KNOWN VALUES found in the query, for prompt injection."""
    known = {}
    m = IP_RE.search(prompt)
    if m: known["ip"] = m.group(1)
    m = PORT_RE.search(prompt)
    if m: known["port"] = m.group(1) or m.group(2)
    m = USER_RE.search(prompt)
    if m: known["user"] = m.group(1) or m.group(2)
    if not known.get("user"):
        # ssh user@host or user@ip patterns
        um = re.search(r"@([\w.]+)", prompt)
        if um: known["user"] = um.group(1)
    m = FILE_RE.search(prompt)
    if m: known["file"] = m.group(1)
    m = PROC_RE.search(prompt)
    if m: known["proc"] = m.group(1)
    m = NAME_RE.search(prompt)
    if m: known["name"] = m.group(1)
    return {k: v for k, v in known.items() if v}

def build_prompt(prompt):
    """Inject extracted values so the model can't drop them."""
    known = extract_values(prompt)
    if not known:
        return prompt
    parts = [prompt, ""]
    parts.append("KNOWN VALUES (use these verbatim, do not substitute):")
    parts.append("  " + ", ".join(f"{k}={v}" for k, v in known.items()))
    return "\n".join(parts)

# --- Deterministic router (high-frequency intents) ---------------------------
def router(query):
    """Return a deterministic command for common intents, or None for the LLM."""
    q = query.lower().strip()
    if "tmux" in q and ("list" in q or "show" in q or "session" in q) and "create" not in q and "new" not in q:
        return "tmux list-sessions" if "session" in q else "tmux list-sessions"
    if "tmux" in q and ("kill all" in q):
        return "tmux kill-server"
    m = re.search(r"tmux session named (\w+)", q)
    if m and ("create" in q or "new" in q or "start" in q):
        return f"tmux new-session -s {m.group(1)}"
    m = re.search(r"kill the tmux session named (\w+)", q)
    if m: return f"tmux kill-session -t {m.group(1)}"
    if "screen" in q and ("list" in q or "show" in q) and "create" not in q:
        return "screen -ls"
    m = re.search(r"screen session named (\w+)", q)
    if m and ("create" in q or "start" in q or "new" in q):
        return f"screen -S {m.group(1)}"
    if ("listening" in q or "listening port" in q) and ("kill" not in q):
        return "lsof -i -P -n | grep LISTEN"
    m = re.search(r"port (\d+)", q)
    if m:
        port = m.group(1)
        if "kill" in q or "kill the process" in q:
            return f"lsof -ti :{port} | xargs -r kill -9"
        if "in use" in q or "using" in q or "who" in q or "what" in q or "check" in q or "usage" in q:
            return f"lsof -i :{port}"
    m = re.search(r"ssh into my server at ([\d.]+) as (\w+)", q)
    if m: return f"ssh {m.group(2)}@{m.group(1)}"
    m = re.search(r"ssh (?:into )?to (?:my )?server ([\w.\-]+) as (\w+)", q)
    if m: return f"ssh {m.group(2)}@{m.group(1)}"
    if "kill all" in q:
        m = re.search(r"kill all (\w+) processes", q)
        if m: return f"pkill -f {m.group(1)}"
    if "git status" in q: return "git status"
    if "list all docker containers" in q: return "docker ps -a"
    if "show free disk" in q or "free disk space" in q: return "df -h"
    return None

# --- Validation (model never executes; checks are parse-only) ---------------
CJK_RE = re.compile(r"[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]")
# Generic placeholder tokens that indicate the model substituted a value instead
# of using the query's actual value.
GENERIC_RE = re.compile(r"user@(remote_)?host|user@remote_server|file\.txt|mysession|/path/to/|/path/on/remote|remote_host")

def syntax_ok(cmd):
    try:
        p = subprocess.run(["bash", "-n"], input=cmd, capture_output=True, text=True, timeout=5)
        return p.returncode == 0
    except Exception:
        return False

def value_drop(cmd, query):
    """Return list of query-provided values that the command dropped/ignored."""
    vals = extract_values(query)
    missing = []
    for k in ("ip", "user", "file", "name", "port"):
        v = vals.get(k)
        if v and v not in cmd:
            missing.append(f"{k}={v}")
    return missing

def validate(cmd, query):
    """Return (ok, reason)."""
    if not cmd or not cmd.strip():
        return False, "empty output"
    if CJK_RE.search(cmd):
        return False, "non-ASCII/CJK character detected (possible digit corruption)"
    if "\n" in cmd or "\r" in cmd:
        return False, "multi-line output (must be one line)"
    q = query.lower()
    # tool mismatch
    if "screen" in q and "tmux" in cmd and "screen" not in cmd:
        return False, "used tmux for a screen request"
    if "tmux" in q and "screen" in cmd and "tmux" not in cmd:
        return False, "used screen for a tmux request"
    if ("ssh tunnel" in q or "forward" in q or "tunnel" in q or "jump host" in q) and "lsof" in cmd and "ssh" not in cmd:
        return False, "used lsof for an ssh/tunnel request"
    if "find" in cmd and re.search(r"\bfind\s+(?!\.)", cmd) and not re.search(r"\bfind\s+\.", cmd):
        return False, "find is missing a path argument"
    # value-drop: only when the query gave a value the model ignored
    missing = value_drop(cmd, query)
    if missing:
        return False, "dropped value(s): " + ", ".join(missing)
    if GENERIC_RE.search(cmd):
        return False, "generic placeholder used instead of the query's value"
    if not syntax_ok(cmd):
        return False, "shell syntax error"
    return True, "ok"

# --- Core call with validation + retry ---------------------------------------
def _http(url, payload, timeout=60):
    """POST once; on a transient transport error (idle-unload window, refused/503)
    wait briefly and retry a single time."""
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                j = json.loads(r.read().decode())
            break
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(1.5)
    m = j["choices"][0]["message"]
    t = (m.get("content") or m.get("reasoning_content") or m.get("reasoning") or "").strip()
    if t.startswith("```"):
        t = t.split("```")[1]
        if t.startswith("bash"):
            t = t[4:]
        t = t.strip().split("\n")[0].strip()
    return t

def call(prompt, mode="translate", model=None, url=None, config=None, retries=2, use_router=True):
    model = model or DEFAULT_MODEL
    url = url or DEFAULT_URL
    # Deterministic fast-path: answer common intents without any network,
    # so ?? keeps working (instantly) even when the LLM server is down.
    if use_router and mode == "translate":
        try:
            hit = router(prompt)
        except Exception:
            hit = None
        if hit:
            ok, _reason = validate(hit, prompt)
            if ok:
                return hit
            # router miss on validation falls through to the LLM below
    system = SYSTEM_E if mode == "explain" else SYSTEM_T
    cfg = dict(config or (CONFIG_CODING if mode == "explain" else CONFIG_GENERAL))
    user_prompt = build_prompt(prompt)
    messages = [{"role": "system", "content": system}, {"role": "user", "content": user_prompt}]
    d = {"model": model, "messages": messages, "stream": False,
         "stop": ["\n\n", "<|end|>"], "chat_template_kwargs": {"enable_thinking": False}}
    for k, v in cfg.items():
        d[k] = v
    cmd = _http(url, d)
    if mode != "translate":
        return cmd
    # validation + retry (only for translate/command generation)
    ok, reason = validate(cmd, prompt)
    attempt = 0
    while not ok and attempt < retries:
        attempt += 1
        feedback = (f"Your previous output was invalid: {reason}. "
                    f"Here is the original request again: {prompt}. "
                    f"Output exactly one corrected macOS zsh command.")
        messages = [{"role": "system", "content": system},
                    {"role": "user", "content": user_prompt},
                    {"role": "assistant", "content": cmd},
                    {"role": "user", "content": feedback}]
        d["messages"] = messages
        cmd = _http(url, d)
        ok, reason = validate(cmd, prompt)
    return cmd

# --- auto-start fallback (fresh installs) ------------------------------------
def ensure_server(url, model=None, wait_secs=60):
    """Best-effort: start BaseRT serving the configured model if it is down.

    Ports follow the live layout: Qwen3.5-4B on 18790, Qwen3-4B baseline on 18789.
    (Lesson: basert pull Qwen3.5-4B fails — the installer does HF download +
    `basert convert`; here we only start the server, no downloads.)
    Returns True if the server responds, False otherwise (caller surfaces it)."""
    probe = url.replace("/v1/chat/completions", "/v1/models")
    try:
        urllib.request.urlopen(probe, timeout=2).read()
        return True
    except Exception:
        pass
    # Only auto-start known BaseRT ports; custom/unknown ports fail fast
    # so router fast-paths and error messages don't stall for 60s.
    if "18789" not in url and "18790" not in url:
        return False
    basert = os.path.expanduser("~/.basert/basert")
    if not os.path.exists(basert):
        return False
    model = model or DEFAULT_MODEL
    if "18790" in url:
        port = "18790"
        serve_model = model if not model.startswith("basecompute/") else "Qwen/Qwen3.5-4B"
    else:
        port = "18789"
        serve_model = model if model.startswith("basecompute/") else "basecompute/Qwen3-4B"
    log_path = "/tmp/terminal-ai.log"
    try:
        with open(log_path, "a") as log:
            log.write(f"\n--- ensure_server {time.strftime('%Y-%m-%d %H:%M:%S')} : {basert} serve {serve_model} --port {port} --idle-timeout 300 ---\n")
            log.flush()
            proc = subprocess.Popen([basert, "serve", serve_model,
                              "--port", port, "--host", "127.0.0.1", "--idle-timeout", "300",
                              "--model-dir", os.path.expanduser("~/Library/Caches/baseRT/models")],
                             stdout=log, stderr=subprocess.STDOUT)
            log.write(f"pid={proc.pid}\n")
    except Exception:
        return False
    for _ in range(max(1, wait_secs)):
        time.sleep(1)
        try:
            urllib.request.urlopen(probe, timeout=2).read()
            return True
        except Exception:
            pass
    return False

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("prompt", nargs="*")
    p.add_argument("--mode", default="translate", choices=["translate", "explain", "reason"])
    p.add_argument("--model", default=None)
    p.add_argument("--url", default=None)
    p.add_argument("--config", default=None, choices=["general", "coding"])
    p.add_argument("--no-retry", action="store_true")
    p.add_argument("--no-router", action="store_true",
                   help="skip the deterministic router (for eval A/B)")
    p.add_argument("--check", action="store_true")
    a = p.parse_args()
    if a.check:
        # self-healing: prod the server first (triggers autoload after idle-unload)
        ensure_server(a.url or DEFAULT_URL)
        try:
            call("list files", model=a.model, url=a.url)
            print(f"ok: {a.url or DEFAULT_URL}")
            sys.exit(0)
        except Exception as e:
            print(f"fail: {e} (server {a.url or DEFAULT_URL}? start: ~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790 --idle-timeout 300 &)")
            sys.exit(1)
    prompt = " ".join(a.prompt).strip() or (sys.stdin.read().strip() if not sys.stdin.isatty() else "")
    if prompt.startswith("??"):
        prompt = prompt[2:].lstrip()
    if not prompt:
        p.print_help()
        sys.exit(1)
    # Fast-path: deterministic router answers without touching the network,
    # so common queries stay instant even when the server is down/starting.
    if not a.no_router and a.mode == "translate":
        try:
            _hit = router(prompt)
        except Exception:
            _hit = None
        if _hit:
            _ok, _ = validate(_hit, prompt)
            if _ok:
                print(_hit)
                sys.exit(0)
    alive = ensure_server(a.url or DEFAULT_URL)
    cfg = CONFIG_CODING if a.config == "coding" else CONFIG_GENERAL
    retries = 0 if a.no_retry else 2
    try:
        print(call(prompt, mode=a.mode, model=a.model, url=a.url, config=cfg, retries=retries,
                   use_router=not a.no_router))
    except Exception as e:
        hint = ""
        if not alive:
            hint = (f" (server {a.url or DEFAULT_URL} did not respond after auto-start;"
                    f" start manually: ~/.basert/basert serve Qwen/Qwen3.5-4B --port 18790"
                    f" --idle-timeout 300 &; log: /tmp/terminal-ai.log)")
        print(f"error: {e}{hint}", file=sys.stderr)
        sys.exit(1)
WCLI
  chmod +x "$BIN_DIR/terminal-ai"
  ln -sf "$BIN_DIR/terminal-ai" "$BIN_DIR/ghostty-ai" 2>/dev/null || true
  ln -sf "$BIN_DIR/terminal-ai" "$BIN_DIR/tai" 2>/dev/null || true
  ok "Payloads ready (standalone: fresh CLI + widget written to the user's home)"

}

write_launchers() {
  local model="$1"
  local PL_PORT="${BASE_PORT}" PL_MODEL="basecompute/Qwen3-4B"
  [[ "$model" == "qwen35" ]] && { PL_PORT="$QWEN35_PORT"; PL_MODEL="Qwen/Qwen3.5-4B"; }
  info "Writing launch helpers..."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/com.terminal-ai.plist" <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.terminal-ai</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/.basert/basert</string><string>serve</string><string>$PL_MODEL</string>
    <string>--port</string><string>$PL_PORT</string><string>--host</string><string>127.0.0.1</string><string>--idle-timeout</string><string>300</string><string>--model-dir</string><string>$HOME/Library/Caches/baseRT/models</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>/tmp/terminal-ai.log</string>
  <key>StandardErrorPath</key><string>/tmp/terminal-ai.err</string>
</dict></plist>
EOS
  # keep old ghostty plist for compat, but disabled
  rm -f "$HOME/Library/LaunchAgents/com.ghostty.llm.plist" 2>/dev/null || true
  ok "Launchers ready (BaseRT 18789/18790 idle-timeout 300, mlx 7821, oMLX 8000 via helpers in $CACHE_DIR/scripts)"
}

main() {
  echo -e "${BOLD}Terminal AI — Interactive Installer (any macOS terminal)${NC}"
  preflight
  local backend; backend=$(choose_inference)
  local model; model=$(choose_model)
  local comp; comp=$(choose_completions)
  echo ""; info "Plan: backend=$backend, model=$model, completions=$comp"
  if ! confirm "Proceed?"; then echo "Aborted"; exit 0; fi
  # Live layout per eval v2: Qwen3.5-4B on 18790, Qwen3-4B baseline on 18789.
  local AI_PORT="${BASE_PORT}" AI_SERVE="basecompute/Qwen3-4B"
  [[ "$model" == "qwen35" ]] && { AI_PORT="$QWEN35_PORT"; AI_SERVE="Qwen/Qwen3.5-4B"; }
  install_deps "$backend" "$comp"
  case "$backend" in basert) install_basert;; mlx) ;; omlx) install_omlx;; esac
  download_model "$backend" "$model"
  setup_shell "$comp" "$backend" "$model"
  write_payloads
  write_launchers "$model"
  # --- auto-start chosen backend so ?? works immediately after install (no manual curl) ---
  if [[ "${TERMINAL_AI_TEST:-0}" == "1" ]]; then info "TERMINAL_AI_TEST=1 — skipping backend auto-start (dry-run)"; else
  info "Starting $backend on first run (so ?? works without manual step)..."
  case "$backend" in
    basert)
      pkill -f "basert.*$AI_PORT" 2>/dev/null || true; sleep 1
      nohup "$HOME/.basert/basert" serve "$AI_SERVE" --port "$AI_PORT" --host 127.0.0.1 --idle-timeout 300 --model-dir "$HOME/Library/Caches/baseRT/models" > /tmp/terminal-ai.log 2>&1 &
      for i in $(seq 1 60); do curl -s "http://127.0.0.1:$AI_PORT/v1/models" >/dev/null 2>&1 && break; sleep 1; done
      curl -s "http://127.0.0.1:$AI_PORT/v1/models" >/dev/null 2>&1 && ok "BaseRT on $AI_PORT ready ($AI_SERVE, idle-timeout 300, auto-unload without killing)" || warn "BaseRT not yet on $AI_PORT — run: ~/.basert/basert serve $AI_SERVE --port $AI_PORT --idle-timeout 300 &"
      ;;
    mlx)
      pkill -f "mlx_lm.server.*$MLX_PORT" 2>/dev/null || true; sleep 1
      nohup /opt/homebrew/anaconda3/bin/mlx_lm.server --model "$MODEL_DIR/qwen3.5-4b-mlx-4bit" --port "$MLX_PORT" --host 127.0.0.1 > /tmp/terminal-ai.log 2>&1 &
      for i in $(seq 1 60); do curl -s "http://127.0.0.1:$MLX_PORT/v1/models" >/dev/null 2>&1 && break; sleep 1; done
      curl -s "http://127.0.0.1:$MLX_PORT/v1/models" >/dev/null 2>&1 && ok "mlx_lm on $MLX_PORT ready" || warn "mlx_lm not yet — run: ~/.cache/terminal-ai/scripts/serve_mlx.sh qwen &"
      ;;
    omlx)
      # oMLX DMG already handles its own launch; try CLI if available
      if [[ -x "/Applications/oMLX.app/Contents/MacOS/omlx-cli" ]]; then
        /Applications/oMLX.app/Contents/MacOS/omlx-cli start 2>&1 | tail -3 || true
        sleep 3
        curl -s "http://127.0.0.1:$OMLX_PORT/v1/models" >/dev/null 2>&1 && ok "oMLX on $OMLX_PORT ready" || warn "oMLX not yet — open /Applications/oMLX.app"
      else
        warn "oMLX not found at /Applications/oMLX.app — install DMG first"
      fi
      ;;
  esac
  fi   # TERMINAL_AI_TEST guard (backend auto-start)
  # also make widget auto-start on next ?? if server down (fallback)
  # patch widget to auto-start is already in _terminal_ai_call via curl retry + start logic (see terminal-ai.zsh)
  echo ""; ok "Installed (generic, not ghostty-only)!"
  echo -e "${BOLD}Next:${NC}"
  echo "  source ~/.zshrc  (or reopen terminal — works in Ghostty, iTerm2, Terminal.app)"
  echo "  git ch<TAB>  (carapace), Ctrl+R (native), prefix→ghost"
  echo "  ?? list all docker containers including stopped  (→ docker ps -a)"
  echo "  Ctrl+G → list files  (→ ls -l, via gum/vared, handles spaces)"
  echo "  tai \"check what ports are active\"  (alias for terminal-ai)"
  echo "  Start: ~/.basert/basert serve "$AI_SERVE" --port "$AI_PORT" --idle-timeout 300 &  (Qwen3.5-4B→18790, Qwen3-4B→18789)"
}
if [[ "${1:-}" == "--uninstall" ]]; then
  info "Uninstalling Terminal AI block..."
  cp "$ZSHRC" "$ZSHRC.bak.uninstall.$(date +%s)" 2>/dev/null || true
  python3 -c "import pathlib,re; p=pathlib.Path.home()/'.zshrc'; t=p.read_text(); t=re.sub(r'# --- Terminal AI.*?export TERMINAL_AI_MODEL=.*\n','',t,flags=re.DOTALL); t=re.sub(r'# --- Ghostty AI Native.*?export GHOSTTY_AI_MODEL=.*\n','',t,flags=re.DOTALL); p.write_text(t); print('cleaned')"
  launchctl unload "$HOME/Library/LaunchAgents/com.terminal-ai.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.terminal-ai.plist" "$HOME/Library/LaunchAgents/com.ghostty.llm.plist"
  ok "Uninstalled (models kept at $MODEL_DIR and ~/Library/Caches/baseRT)"
  exit 0
fi
main "$@"
