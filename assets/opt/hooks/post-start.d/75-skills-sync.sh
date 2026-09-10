#!/usr/bin/env bash
# @name skills-sync
# @phase post-start
# @required false
# @description Skills — install *.skill.md into ~/.claude/commands and merge their hooks.json. Workspace copy wins (v2 layout), else the baked sync-skills walks the image skills then the project overlay.

set -eE

if [ -f /workspace/.devcontainer/skills/sync-skills.sh ]; then
  bash /workspace/.devcontainer/skills/sync-skills.sh
elif [ -x /usr/local/bin/sync-skills ]; then
  /usr/local/bin/sync-skills
fi
