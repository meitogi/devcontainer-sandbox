#!/usr/bin/env bash
# @name skills-sync
# @phase post-start
# @required false
# @description Skills — the baked sync-skills installs *.skill.md from the image, an extending image and the project overlay into ~/.claude/commands and merges their hooks.json.

set -eE

# A v2 project's own loader under skills/ is not consulted. Until 1.3.0 this
# hook preferred it when present; it was a single-layer script that installed
# the project's skills only and silently dropped base + ext. No v2 tree runs
# this hook (its own post-start.sh ran that loader), so only a half-migrated
# tree ever hit the branch — and there it was the trap.
if [ -x /usr/local/bin/sync-skills ]; then
  /usr/local/bin/sync-skills
fi
