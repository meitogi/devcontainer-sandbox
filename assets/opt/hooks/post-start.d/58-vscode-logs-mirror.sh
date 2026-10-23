#!/usr/bin/env bash
# @name vscode-logs-mirror
# @phase post-start
# @required false
# @description Start the vscode-logs-mirror daemon (detached, one per container) so ~/.vscode-server/data/logs/ is copied every 30 s into .devcontainer/tmp/vscode-logs/container/ and survives a Rebuild — the half of the VS Code logs the host's notify daemon cannot see. Opt-in : runs only with VSCODE_LOGS_MIRROR=1 in .devcontainer/.env (read from the file, so a Reopen is enough). Log: /tmp/vscode-logs-mirror.log.

set -eE

PIDFILE="${VSCODE_LOGS_PIDFILE:-/tmp/vscode-logs-mirror.pid}"
LOG="${VSCODE_LOGS_LOG:-/tmp/vscode-logs-mirror.log}"
ENV_FILE="${DEVC_ENV_FILE:-/workspace/.devcontainer/.env}"

# From the file, not the environment : compose's env_file is read at container
# create only, and this key is flipped between Reopens.
if ! grep -qE '^VSCODE_LOGS_MIRROR=1\s*$' "$ENV_FILE" 2>/dev/null; then
  echo "vscode-logs-mirror skipped (VSCODE_LOGS_MIRROR=1 not in .env)"; exit 0
fi
BIN=$(command -v vscode-logs-mirror 2>/dev/null) || { echo "⚠ vscode-logs-mirror not installed — skipping."; exit 0; }
command -v rsync >/dev/null 2>&1 || { echo "⚠ rsync not installed — vscode-logs-mirror skipped."; exit 0; }

# The daemon holds a flock on its pidfile for its whole life: a lock we can
# take here means nobody is running (a stale pidfile after a restart included).
if [ -f "$PIDFILE" ] && ! flock -n "$PIDFILE" true 2>/dev/null; then
  echo "✓ vscode-logs-mirror already running (pid $(cat "$PIDFILE" 2>/dev/null))"; exit 0
fi

# Every fd redirected: devc-hook waits for EOF on this fragment's stdout, so a
# daemon still holding it would hang the post-start phase. 3 (devc-hook's saved
# terminal) and 19 (its xtrace under DEBUG=1) are closed too: no use to a daemon.
setsid nohup "$BIN" </dev/null >>"$LOG" 2>&1 3>&- 19>&- &
echo "✓ vscode-logs-mirror started (pid $!, log $LOG)"
