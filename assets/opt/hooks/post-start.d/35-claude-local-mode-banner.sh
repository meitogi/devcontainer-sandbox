#!/usr/bin/env bash
# @name claude-local-mode-banner
# @phase post-start
# @required false
# @description Claude Code local mode banner + ~/.claude-local isolation init.
# Anchored regex matches ONLY the uncommented active line — so the banner
# disappears automatically when host-helpers/claude-switch cloud re-comments
# the var. When local mode is active, ensure ~/.claude-local/ exists with the
# right symlinks (shared skills/commands/memory, isolated creds/projects/todos)
# before any shell runs `claude`. Doing the init here rather than in
# shell-init.sh keeps it a one-shot per container start instead of every shell.
# See .devcontainer/knowledge/ollama-local.md.

set -eE

CLAUDE_LOCAL_DIR=/home/node/.claude-local
_init_claude_local_dir() {
  [ -d "$CLAUDE_LOCAL_DIR" ] && return 0
  mkdir -p "$CLAUDE_LOCAL_DIR" && chmod 700 "$CLAUDE_LOCAL_DIR"
  if [ -d "$HOME/.claude" ]; then
    for path in commands skills memory plugins settings.json .claude.json; do
      if [ -e "$HOME/.claude/$path" ]; then
        ln -sfn "$HOME/.claude/$path" "$CLAUDE_LOCAL_DIR/$path"
      fi
    done
  fi
  printf '\033[1;36mℹ️  Initialized %s (shared skills/commands/memory, isolated creds)\033[0m\n' "$CLAUDE_LOCAL_DIR"
}

if grep -qE '^ANTHROPIC_BASE_URL=http://ollama\.internal' /workspace/.devcontainer/.env 2>/dev/null; then
  printf '\033[1;33m🦙 Claude mode: LOCAL (ollama.internal:11434 — via mitmproxy audit)\033[0m\n'
  _init_claude_local_dir
elif grep -qE '^ANTHROPIC_BASE_URL=http://ollama\.local' /workspace/.devcontainer/.env 2>/dev/null; then
  printf '\033[1;31m🦙 Claude mode: LOCAL BYPASS (ollama.local:11434 — NO audit, debug only)\033[0m\n'
  _init_claude_local_dir
fi
