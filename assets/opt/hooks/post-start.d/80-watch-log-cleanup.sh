#!/usr/bin/env bash
# @name watch-log-cleanup
# @phase post-start
# @required false
# @description Watch-log cleanup — drop pending/* > 60 min stale (skill /watch-log, C).

set -eE

# workspace-optional: the fallback is inlined below, not a baked script.
CLEANUP=/workspace/.devcontainer/host-helpers/watch-log-cleanup
PENDING=/workspace/.devcontainer/pending
if [ -x "$CLEANUP" ]; then
  "$CLEANUP"
elif [ -d "$PENDING" ]; then
  # No workspace helper (project on the published image) — the cleanup is
  # three lines, inline it rather than ship a script for it.
  find "$PENDING" -type f \( -name '*.sh' -o -name '*.log' -o -name '*.meta' \) \
    -mmin +60 -delete 2>/dev/null || true
fi
