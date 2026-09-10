#!/usr/bin/env bash
# @name symlink-claude-mode
# @phase post-create
# @required false
# @description Symlink /workspace/CLAUDE.md to the mode-appropriate variant. Two orthogonal signals feed the choice:
#   1. claude-switch mode in .env (ANTHROPIC_BASE_URL) — local / local-proxy use CLAUDE-local-dev.md
#   2. .configured-claude-mode marker — picks the cloud variant (CLAUDE-dev.md vs CLAUDE-reviewer.md)
# Without signal 1, every rebuild would clobber a claude-switch selection back to the cloud variant.

set -eE

MODE_FLAG="/workspace/.devcontainer/.configured-claude-mode"
ENV_FILE="/workspace/.devcontainer/.env"

if grep -qE '^ANTHROPIC_BASE_URL=http://(ollama\.internal:11434|claude-bridge)' "$ENV_FILE" 2>/dev/null; then
  CLAUDE_FILE="CLAUDE-local-dev.md"
elif [ -f "$MODE_FLAG" ]; then
  CLAUDE_FILE=$(cat "$MODE_FLAG")
else
  CLAUDE_FILE="CLAUDE-dev.md"
fi

ln -sf ".devcontainer/claude/$CLAUDE_FILE" /workspace/CLAUDE.md
echo "✓ CLAUDE.md → $CLAUDE_FILE"
