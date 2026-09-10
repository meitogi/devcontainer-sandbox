#!/usr/bin/env bash
# @name wipe-claude-ext-jsonl
# @phase post-start
# @required false
# @description Wipe the Claude Code VS Code extension observation/control JSONLs
# at every container start. Observation/audit + control-channel data — no value
# retaining across boots. The JS appendFile in the user-action-observer patch
# creates inbound.jsonl on the first event; outbound-action-injector's watcher
# creates outbound.jsonl + pending-perms.jsonl at ext startup.

set -eE

rm -f /workspace/.devcontainer/logs/claude-code-vscode-ext-inbound.jsonl \
      /workspace/.devcontainer/logs/claude-code-vscode-ext-outbound.jsonl \
      /workspace/.devcontainer/logs/claude-code-vscode-ext-pending-perms.jsonl
