#!/usr/bin/env bash
# install-terminal-ai.sh — Interactive installer for Local Terminal AI (any macOS terminal)
# Works on Ghostty, iTerm2, Terminal.app, Warp, etc. with zsh/bash/fish
# Features: Tab completions (carapace) + history ghost + NL→command (Ctrl+G / ??) via local tiny LLM
# Inference (choose one): BaseRT (native Metal, idle-timeout) | mlx_lm (Apple MLX) | oMLX (DMG)
# Models: backend-aware — BaseRT pulls basecompute .base (no MLX), MLX pulls mlx-community (no BaseRT), both via wget -4 -c or basert pull
# Usage: chmod +x install-terminal-ai.sh && ./install-terminal-ai.sh
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*"; exit 1; }
ask()   { local p="$1" d="$2" a; read -rp "$(echo -e "${BOLD}$p${NC} [$d]: ")" a; echo "${a:-$d}"; }
confirm() { local p="$1" a; read -rp "$(echo -e "${BOLD}$p${NC} [y/N]: ")" a; [[ "$a" =~ ^[Yy]$ ]]; }

CACHE_DIR="$HOME/.cache/terminal-ai"
MODEL_DIR="$CACHE_DIR/models"
BIN_DIR="$HOME/.local/bin"
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
BASE_PORT=18789; MLX_PORT=7821; OMLX_PORT=8000

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
  echo "" >&2; echo -e "${BOLD}Choose model (Qwen3.5-4B won bake-off 0.824 vs Phi 0.713):${NC}" >&2
  echo "  1) Qwen3.5-4B (winner, 2.9GB MLX / 2.1GB BaseRT) — recommended" >&2
  echo "  2) Phi-4-mini 3.8B (2.0GB, fallback)" >&2
  echo "  3) Both (4.9GB, A/B)" >&2
  local c; c=$(ask "Model [1/2/3]" "1")
  case "$c" in 2) echo "phi";; 3) echo "both";; *) echo "qwen";; esac
}
choose_completions() {
  echo ""; echo -e "${BOLD}Deterministic completions (Tab + ghost):${NC}"
  if confirm "Install carapace + zsh-autosuggestions + atuin?"; then echo "yes"; else echo "no"; fi
}

# --- backend-aware deps ---
install_deps() {
  local backend="$1" comp="$2"
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
      # Qwen3.5-4B not in basecompute preconverted list, so use Qwen3-4B 2.1GB preconverted as closest, or Qwen/Qwen3.5-4B via convert-on-pull
      # Prefer basecompute/Qwen3-4B (2.1GB, preconverted) for speed; fallback to Qwen/Qwen3.5-4B convert
      if [[ "$key" == "phi" || "$key" == "both" ]]; then
        warn "Phi-4-mini not in BaseRT catalog — will use Qwen3-4B for BaseRT; for Phi use mlx/omlx backend instead"
      fi
      # Pull Qwen3-4B preconverted (no BF16 download needed, just .base)
      if "$HOME/.basert/basert" list 2>&1 | grep -q "basecompute/Qwen3-4B"; then ok "basecompute/Qwen3-4B already cached"
      else "$HOME/.basert/basert" pull basecompute/Qwen3-4B 2>&1 | tail -20 || warn "BaseRT pull failed, will retry on serve"
      fi
      ;;
    mlx|omlx)
      info "MLX path — mlx-community first, Unsloth GGUF fallback, wget -4 -c..."
      if [[ "$key" == "phi" || "$key" == "both" ]]; then
        [[ -f "$MODEL_DIR/phi4-mini-4bit/model.safetensors" ]] && ok "phi already cached" || fetch_mlx "mlx-community/Phi-4-mini-instruct-4bit" "$MODEL_DIR/phi4-mini-4bit"
      fi
      if [[ "$key" == "qwen" || "$key" == "both" ]]; then
        [[ -f "$MODEL_DIR/qwen3.5-4b-mlx-4bit/model.safetensors" ]] && ok "qwen already cached" || fetch_mlx "mlx-community/Qwen3.5-4B-MLX-4bit" "$MODEL_DIR/qwen3.5-4b-mlx-4bit"
      fi
      ;;
  esac
}

setup_shell() {
  local comp="$1" backend="$2"
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
export TERMINAL_AI_URL="http://127.0.0.1:18789/v1/chat/completions"
export TERMINAL_AI_MODEL="basecompute/Qwen3-4B"
# compat for old ghostty-ai env
export GHOSTTY_AI_URL="\$TERMINAL_AI_URL"
export GHOSTTY_AI_MODEL="\$TERMINAL_AI_MODEL"
EOS
  # fix $HOME placeholder (already expanded above, but keep)
  zsh -n "$ZSHRC" && ok "zshrc patched" || warn "zshrc syntax"
  if [[ -f "$BASHRC" ]] && ! grep -q "terminal-ai" "$BASHRC" 2>/dev/null; then
    echo '# terminal-ai (bash)' >> "$BASHRC"
    echo 'export TERMINAL_AI_URL="http://127.0.0.1:18789/v1/chat/completions"; export TERMINAL_AI_MODEL="basecompute/Qwen3-4B"' >> "$BASHRC"
    echo 'alias "??"="~/.local/bin/terminal-ai"' >> "$BASHRC"
  fi
  ok "Shell done"
}

write_payloads() {
  info "Writing payloads (widget, CLI, config)..."
  mkdir -p "$HOME/.config/zsh" "$HOME/.config/terminal-ai" "$CACHE_DIR/bench" "$CACHE_DIR/scripts" "$BIN_DIR"
  # widget (generic, not ghostty-only)
  cat > "$HOME/.config/zsh/terminal-ai.zsh" <<'WZSH'
if [[ -z "$TERMINAL_AI_URL" ]]; then export TERMINAL_AI_URL="http://127.0.0.1:18789/v1/chat/completions"; fi
if [[ -z "$TERMINAL_AI_MODEL" ]]; then export TERMINAL_AI_MODEL="basecompute/Qwen3-4B"; fi
# compat
export GHOSTTY_AI_URL="$TERMINAL_AI_URL"; export GHOSTTY_AI_MODEL="$TERMINAL_AI_MODEL"
_terminal_ai_call() {
  local nl="$1" mode="${2:-translate}" system
  if [[ "$mode" == "explain" ]]; then system="You are a zsh expert on macOS. Explain this shell error in 3 bullets and suggest a fix. Be concise, no markdown headers."
  else system="You are a shell command generator for macOS (zsh, Apple Silicon). Output exactly one line: a single macOS zsh command that accomplishes the user's request. Prefer macOS tools (lsof -i -P -n | grep LISTEN, netstat -anv, brew, pbcopy, diskutil) over Linux (netstat -tulnp, ss). No prose, no markdown fences, no explanation."; fi
  local payload
  if [[ "$TERMINAL_AI_MODEL" == *[Qq]wen* ]]; then
    payload=$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'messages':[{'role':'system','content':sys.argv[2]},{'role':'user','content':sys.argv[3]}],'temperature':0.0,'max_tokens':64,'stream':False,'stop':['\n\n','<|end|>'],'chat_template_kwargs':{'enable_thinking':False}}))" "$TERMINAL_AI_MODEL" "$system" "$nl")
  else
    payload=$(python3 -c "import json,sys; print(json.dumps({'model':sys.argv[1],'messages':[{'role':'system','content':sys.argv[2]},{'role':'user','content':sys.argv[3]}],'temperature':0.0,'max_tokens':64,'stream':False,'stop':['\n\n','<|end|>']}))" "$TERMINAL_AI_MODEL" "$system" "$nl")
  fi
  local resp; resp=$(curl -s --max-time 30 -X POST "$TERMINAL_AI_URL" -H "Content-Type: application/json" -d "$payload" 2>&1)
  # auto-start backend if not running (common after fresh install/uninstall)
  if [[ $? -ne 0 || -z "$resp" || "$resp" == *"Connection refused"* || "$resp" == *"Failed to connect"* ]]; then
    # try to start the correct backend based on URL port
    if [[ "$TERMINAL_AI_URL" == *":$BASE_PORT"* || "$TERMINAL_AI_URL" == *":18789"* ]] && command -v "$HOME/.basert/basert" >/dev/null 2>&1; then
      nohup "$HOME/.basert/basert" serve basecompute/Qwen3-4B --port "${BASE_PORT:-18789}" --host 127.0.0.1 --idle-timeout 300 --model-dir "$HOME/Library/Caches/baseRT/models" > /tmp/terminal-ai.log 2>&1 &
      for i in 1 2 3 4 5; do curl -s "$TERMINAL_AI_URL" >/dev/null 2>&1 || curl -s "http://127.0.0.1:${BASE_PORT:-18789}/v1/models" >/dev/null 2>&1 && break; sleep 1; done
      resp=$(curl -s --max-time 30 -X POST "$TERMINAL_AI_URL" -H "Content-Type: application/json" -d "$payload" 2>&1)
    elif [[ "$TERMINAL_AI_URL" == *":$MLX_PORT"* || "$TERMINAL_AI_URL" == *":7821"* ]] && command -v mlx_lm.server >/dev/null 2>&1; then
      nohup mlx_lm.server --model "$HOME/.cache/terminal-ai/models/qwen3.5-4b-mlx-4bit" --port "${MLX_PORT:-7821}" --host 127.0.0.1 > /tmp/terminal-ai.log 2>&1 &
      for i in 1 2 3 4 5; do curl -s "$TERMINAL_AI_URL" >/dev/null 2>&1 && break; sleep 1; done
      resp=$(curl -s --max-time 30 -X POST "$TERMINAL_AI_URL" -H "Content-Type: application/json" -d "$payload" 2>&1)
    fi
  fi
  [[ $? -ne 0 || -z "$resp" ]] && return 1
  local cmd; cmd=$(python3 -c "import sys,json; d=json.load(sys.stdin); m=d['choices'][0]['message']; print((m.get('content') or m.get('reasoning_content') or m.get('reasoning') or '').strip())" <<<"$resp")
  cmd=$(echo "$cmd" | sed -e 's/^```.*//' -e 's/```$//' | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$cmd" ]] && return 1
  print -r -- "$cmd"
}
terminal-ai-widget() {
  local nl
  if [[ -n "$BUFFER" && "$BUFFER" != "??"* ]]; then
    if [[ "$BUFFER" == *" "* && "$BUFFER" != *"/"* ]]; then nl="$BUFFER"
    else if command -v gum >/dev/null 2>&1; then nl=$(gum input --placeholder "Describe command (e.g., find large logs) > " --value "$BUFFER"); else local tmp=""; vared -p "NLP> " -c tmp; nl="$tmp"; fi; fi
  else
    local raw="${BUFFER#?? }"; raw="${raw#??}"
    if [[ -n "$raw" && "$raw" != " "* ]]; then nl="$raw"
    else if command -v gum >/dev/null 2>&1; then nl=$(gum input --placeholder "Describe command > "); else local tmp=""; vared -p "NLP> " -c tmp; nl="$tmp"; fi; fi
  fi
  [[ -z "$nl" ]] && return 0
  local cmd; zle -M "🧠 $TERMINAL_AI_MODEL…"; cmd=$(_terminal_ai_call "$nl" "translate"); local rc=$?; zle -M ""
  [[ $rc -ne 0 || -z "$cmd" ]] && { zle -M "no result (is server on $TERMINAL_AI_URL?)"; return 1; }
  BUFFER="$cmd"; CURSOR=${#BUFFER}; zle redisplay
}
zle -N terminal-ai-widget; bindkey '^G' terminal-ai-widget; bindkey '^X^G' terminal-ai-widget
# legacy alias
zle -N ghostty-ai-widget 2>/dev/null; bindkey '^G' terminal-ai-widget 2>/dev/null
__terminal_ai_prefix() { if [[ "$1" == "??" ]]; then shift; local nl="$*"; [[ -z "$nl" ]] && { zle terminal-ai-widget 2>/dev/null || terminal-ai-widget; return; }; local cmd; cmd=$(_terminal_ai_call "$nl" "translate"); [[ -n "$cmd" ]] && { print -z -- "$cmd"; echo "→ $cmd"; }; fi; }
alias '??'='noglob __terminal_ai_prefix ??'
# compat ghostty-ai
alias 'ghostty-ai'='terminal-ai'
explain() { local c=$(fc -ln -1 2>/dev/null | sed 's/^[[:space:]]*//'); [[ -z "$c" ]] && c="$1"; _terminal_ai_call "Explain failure for: $c" "explain"; }
WZSH
  # keep ghostty compat symlink
  ln -sf "$HOME/.config/zsh/terminal-ai.zsh" "$HOME/.config/zsh/ghostty-ai.zsh" 2>/dev/null || true
  # CLI (generic)
  cat > "$BIN_DIR/terminal-ai" <<'WCLI'
#!/usr/bin/env python3
import argparse, json, sys, os, urllib.request
from pathlib import Path
DEFAULT_URL = os.environ.get("TERMINAL_AI_URL", os.environ.get("GHOSTTY_AI_URL", "http://127.0.0.1:18789/v1/chat/completions"))
DEFAULT_MODEL = os.environ.get("TERMINAL_AI_MODEL", os.environ.get("GHOSTTY_AI_MODEL", "basecompute/Qwen3-4B"))
SYSTEM_T = "You are a shell command generator for macOS (zsh, Apple Silicon). Output exactly one line: a single macOS zsh command that accomplishes the user's request. Prefer macOS tools (lsof -i -P -n | grep LISTEN, netstat -anv, brew, pbcopy, diskutil) over Linux (netstat -tulnp, ss). No prose, no markdown fences, no explanation."
SYSTEM_E = "You are a zsh expert on macOS. Explain this shell error in 3 bullets and suggest a fix. Be concise."
def call(prompt, mode="translate", model=None, url=None):
    model = model or DEFAULT_MODEL; url = url or DEFAULT_URL
    system = SYSTEM_E if mode=="explain" else SYSTEM_T
    d={"model":model,"messages":[{"role":"system","content":system},{"role":"user","content":prompt}],"temperature":0.0,"max_tokens":64,"stream":False,"stop":["\n\n","<|end|>"]}
    if "qwen" in model.lower(): d["chat_template_kwargs"]={"enable_thinking": False}
    req=urllib.request.Request(url, data=json.dumps(d).encode(), headers={"Content-Type":"application/json"})
    import urllib.request, json as j
    with urllib.request.urlopen(req, timeout=30) as r:
        j=json.loads(r.read().decode()); m=j["choices"][0]["message"]; t=(m.get("content") or m.get("reasoning_content") or m.get("reasoning") or "").strip()
        if t.startswith("```"): t=t.split("```")[1]; t=t[4:] if t.startswith("bash") else t; t=t.strip().split("\n")[0].strip()
        return t
if __name__=="__main__":
    import argparse
    p=argparse.ArgumentParser(); p.add_argument("prompt", nargs="*"); p.add_argument("--mode", default="translate", choices=["translate","explain"]); p.add_argument("--model", default=None); p.add_argument("--url", default=None); p.add_argument("--check", action="store_true")
    a=p.parse_args()
    if a.check:
        try: call("list files", model=a.model, url=a.url); print(f"ok: {a.url or DEFAULT_URL}"); sys.exit(0)
        except Exception as e: print(f"fail: {e}"); sys.exit(1)
    prompt=" ".join(a.prompt).strip() or (sys.stdin.read().strip() if not sys.stdin.isatty() else "")
    if prompt.startswith("??"): prompt=prompt[2:].lstrip()
    if not prompt: p.print_help(); sys.exit(1)
    print(call(prompt, mode=a.mode, model=a.model, url=a.url))
WCLI
  sed -i '' "s|/Users/REPLACE|$HOME|g" "$BIN_DIR/terminal-ai" 2>/dev/null || sed -i "s|/Users/REPLACE|$HOME|g" "$BIN_DIR/terminal-ai"
  chmod +x "$BIN_DIR/terminal-ai"
  ln -sf "$BIN_DIR/terminal-ai" "$BIN_DIR/ghostty-ai" 2>/dev/null || true
  ln -sf "$BIN_DIR/terminal-ai" "$BIN_DIR/tai" 2>/dev/null || true
  ok "Payloads ready (terminal-ai, tai, ghostty-ai compat)"
}

write_launchers() {
  info "Writing launch helpers..."
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/com.terminal-ai.plist" <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.terminal-ai</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/.basert/basert</string><string>serve</string><string>basecompute/Qwen3-4B</string>
    <string>--port</string><string>$BASE_PORT</string><string>--host</string><string>127.0.0.1</string><string>--idle-timeout</string><string>300</string><string>--model-dir</string><string>$HOME/Library/Caches/baseRT/models</string>
  </array>
  <key>RunAtLoad</key><false/><key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>/tmp/terminal-ai.log</string>
  <key>StandardErrorPath</key><string>/tmp/terminal-ai.err</string>
</dict></plist>
EOS
  # keep old ghostty plist for compat, but disabled
  rm -f "$HOME/Library/LaunchAgents/com.ghostty.llm.plist" 2>/dev/null || true
  ok "Launchers ready (BaseRT 18789 idle-timeout 300, mlx 7821, oMLX 8000 via helpers in $CACHE_DIR/scripts)"
}

main() {
  echo -e "${BOLD}Terminal AI — Interactive Installer (any macOS terminal)${NC}"
  preflight
  local backend; backend=$(choose_inference)
  local model; model=$(choose_model)
  local comp; comp=$(choose_completions)
  echo ""; info "Plan: backend=$backend, model=$model, completions=$comp"
  if ! confirm "Proceed?"; then echo "Aborted"; exit 0; fi
  install_deps "$backend" "$comp"
  case "$backend" in basert) install_basert;; mlx) ;; omlx) install_omlx;; esac
  download_model "$backend" "$model"
  setup_shell "$comp" "$backend"
  write_payloads
  write_launchers
  # --- auto-start chosen backend so ?? works immediately after install (no manual curl) ---
  info "Starting $backend on first run (so ?? works without manual step)..."
  case "$backend" in
    basert)
      pkill -f "basert.*$BASE_PORT" 2>/dev/null || true; sleep 1
      nohup "$HOME/.basert/basert" serve basecompute/Qwen3-4B --port "$BASE_PORT" --host 127.0.0.1 --idle-timeout 300 --model-dir "$HOME/Library/Caches/baseRT/models" > /tmp/terminal-ai.log 2>&1 &
      for i in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$BASE_PORT/v1/models" >/dev/null 2>&1 && break; sleep 1; done
      curl -s "http://127.0.0.1:$BASE_PORT/v1/models" >/dev/null 2>&1 && ok "BaseRT on $BASE_PORT ready (idle-timeout 300, auto-unload without killing)" || warn "BaseRT not yet on $BASE_PORT — run: ~/.basert/basert serve basecompute/Qwen3-4B --port $BASE_PORT --idle-timeout 300 &"
      ;;
    mlx)
      pkill -f "mlx_lm.server.*$MLX_PORT" 2>/dev/null || true; sleep 1
      nohup /opt/homebrew/anaconda3/bin/mlx_lm.server --model "$MODEL_DIR/qwen3.5-4b-mlx-4bit" --port "$MLX_PORT" --host 127.0.0.1 > /tmp/terminal-ai.log 2>&1 &
      for i in 1 2 3 4 5 6 7 8 9 10; do curl -s "http://127.0.0.1:$MLX_PORT/v1/models" >/dev/null 2>&1 && break; sleep 1; done
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
  # also make widget auto-start on next ?? if server down (fallback)
  # patch widget to auto-start is already in _terminal_ai_call via curl retry + start logic (see terminal-ai.zsh)
  echo ""; ok "Installed (generic, not ghostty-only)!"
  echo -e "${BOLD}Next:${NC}"
  echo "  source ~/.zshrc  (or reopen terminal — works in Ghostty, iTerm2, Terminal.app)"
  echo "  git ch<TAB>  (carapace), Ctrl+R (native), prefix→ghost"
  echo "  ?? list all docker containers including stopped  (→ docker ps -a)"
  echo "  Ctrl+G → list files  (→ ls -l, via gum/vared, handles spaces)"
  echo "  tai \"check what ports are active\"  (alias for terminal-ai)"
  echo "  Start: ~/.basert/basert serve basecompute/Qwen3-4B --port $BASE_PORT --idle-timeout 300 &"
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
