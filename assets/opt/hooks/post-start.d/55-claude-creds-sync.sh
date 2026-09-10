#!/usr/bin/env bash
# @name claude-creds-sync
# @phase post-start
# @required true
# @description Sync Claude .credentials.json between the shared volume (/home/node/.claude-creds) and per-container config (/home/node/.claude). Workspace copy wins (v2 layout), else the baked /usr/local/bin/sync-creds. Required because Claude Code depends on .credentials.json for auth; without it, every terminal fails.

set -eE

WORKSPACE_SYNC="/workspace/.devcontainer/claude/sync-creds.sh"
BAKED_SYNC="/usr/local/bin/sync-creds"

if [ -x "$WORKSPACE_SYNC" ]; then
  VERBOSE=1 "$WORKSPACE_SYNC"
elif [ -x "$BAKED_SYNC" ]; then
  VERBOSE=1 "$BAKED_SYNC"
else
  echo "⚠️  no sync-creds available (neither $WORKSPACE_SYNC nor $BAKED_SYNC) — skipping."
fi
