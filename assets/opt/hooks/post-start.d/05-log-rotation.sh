#!/usr/bin/env bash
# @name log-rotation
# @phase post-start
# @required false
# @description Age out the two flat non-phase hook logs under .devcontainer/tmp/logs/ after 7 days, and prune boot-id folders there to the KEEP_BOOTS most recent. Runs at every container start, gating disk usage of both the non-phase writers and the per-boot phase logs written by the dispatcher.

set -eE

CFG="${DEVC_CONFIG_DIR:-/workspace/.devcontainer}"
LOGDIR="$CFG/tmp/logs"
KEEP_BOOTS=20

mkdir -p "$LOGDIR" 2>/dev/null || true

# The two flat non-phase writers (proxy-audit-<ts>.log,
# claude-switch-validation.log) age out on their own schedule — they are
# not tied to a boot, so the folder-count retention below doesn't apply to
# them. -maxdepth 1 keeps this sweep off the boot-id folders entirely, and
# the name filter can't match .boot-id, host-os or the flat *.jsonl files.
find "$LOGDIR" -maxdepth 1 -type f \
    \( -name '*.log' -o -name '*.trace' \) -mtime +7 -delete 2>/dev/null || true

# Phase logs live one level down, grouped by boot: YYYYMMDDTHHMMSSZ is
# fixed-width and zero-padded, so a lexicographic sort on the name alone is
# a chronological sort (same enumeration test/overlay.test.sh's bootdirs()
# uses). Keep only the KEEP_BOOTS most recent; -type d can't match
# .boot-id, host-os or the flat *.jsonl files, so they're never at risk
# here regardless of age.
find "$LOGDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort \
    | head -n -"$KEEP_BOOTS" \
    | while IFS= read -r _boot; do
        rm -rf "$LOGDIR/$_boot" 2>/dev/null || true
    done
