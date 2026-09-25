#!/usr/bin/env bash
# @name boot-summary
# @phase post-start
# @required false
# @description Closing panel of the start sequence — the state this container actually booted with (versions, Claude mode and binary, firewall mode and allowlist size, patcher ref and sentinels, skills, notify daemon, this phase's log). Renders boot-summary last in the phase, and keeps the text under tmp/ so every shell can show it without measuring anything again.

set -uo pipefail

# Last on purpose: every row above it is produced by an earlier fragment
# (firewall at 20, patchers at 45, skills at 75), so measuring before them
# would report a container that does not exist yet.
command -v boot-summary >/dev/null 2>&1 || exit 0

CFG="${DEVC_CONFIG_DIR:-/workspace/.devcontainer}"
mkdir -p "$CFG/tmp" 2>/dev/null || true

# Written, not just printed. The phase output lands in the Dev Containers
# panel, which the user may well have stopped reading by now; the terminal is
# where they look. Caching the TEXT rather than re-running the probes at each
# shell is the whole point: this is the record of a boot, stamped with the
# instant it was taken, not a live readout that would quietly stop describing
# the start it claims to summarise.
boot-summary | tee "$CFG/tmp/boot-summary.txt" || true
