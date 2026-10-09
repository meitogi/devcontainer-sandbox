#!/usr/bin/env bash
# @name creds-watch
# @phase post-start
# @required false
# @description Start the creds-watch daemon (detached, one per container) so a token refreshed by another container reaches ~/.claude/.credentials.json within seconds, not at the next Stop / terminal / boot. Skipped when CREDS_WATCH=0, when the shared creds volume is absent, and in local Ollama mode (no subscription token to propagate). Log: /tmp/creds-watch.log.

set -eE

SHARED_DIR="${SHARED_DIR:-/home/node/.claude-creds}"
PIDFILE="${CREDS_WATCH_PIDFILE:-/tmp/creds-watch.pid}"
LOG="${CREDS_WATCH_LOG:-/tmp/creds-watch.log}"
ENV_FILE="${DEVC_ENV_FILE:-/workspace/.devcontainer/.env}"

if [ "${CREDS_WATCH:-1}" = 0 ]; then
  echo "creds-watch skipped (CREDS_WATCH=0)"; exit 0
fi
if [ ! -d "$SHARED_DIR" ]; then
  echo "creds-watch skipped (no shared creds volume at $SHARED_DIR)"; exit 0
fi
if grep -qE '^ANTHROPIC_BASE_URL=http://ollama\.(internal|local)' "$ENV_FILE" 2>/dev/null; then
  echo "creds-watch skipped (local Ollama mode)"; exit 0
fi
BIN=$(command -v creds-watch 2>/dev/null) || { echo "⚠ creds-watch not installed — skipping."; exit 0; }

# The daemon holds a flock on its pidfile for its whole life: a lock we can
# take here means nobody is running (a stale pidfile after a restart included).
if [ -f "$PIDFILE" ] && ! flock -n "$PIDFILE" true 2>/dev/null; then
  echo "✓ creds-watch already running (pid $(cat "$PIDFILE" 2>/dev/null))"; exit 0
fi

# Every fd redirected: devc-hook waits for EOF on this fragment's stdout, so a
# daemon still holding it would hang the post-start phase. 3 (devc-hook's saved
# terminal) and 19 (its xtrace under DEBUG=1) are closed too: no use to a daemon.
setsid nohup "$BIN" </dev/null >>"$LOG" 2>&1 3>&- 19>&- &
echo "✓ creds-watch started (pid $!, log $LOG)"
