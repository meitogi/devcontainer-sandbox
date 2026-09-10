#!/usr/bin/env bash
# @name hide-vscode-settings
# @phase post-start
# @required false
# @description Hide bind-mounted .vscode/settings.json from git (the devcontainer overrides it via docker-compose volume mount).

set -eE

git -C /workspace update-index --skip-worktree .vscode/settings.json 2>/dev/null || true
