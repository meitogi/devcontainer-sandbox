#!/usr/bin/env bash
# @name claude-update-probe
# @phase post-start
# @required false
# @description Claude Code update probe (v2.1-1). registry.npmjs.org/@anthropic-ai/claude-code is GET-allowed by policy.d/registry.npmjs.org.yaml — same channel npm itself uses. Silent if registry unreachable (off/basic-without-domain, network down) or already up to date.

set -eE

check_claude_update() {
  command -v claude >/dev/null 2>&1 || return 0
  command -v curl   >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local installed latest
  installed=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -z "$installed" ] && return 0
  latest=$(curl -fsSL --max-time 5 \
    https://registry.npmjs.org/@anthropic-ai/claude-code 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['dist-tags']['latest'])" 2>/dev/null)
  [ -z "$latest" ] && return 0
  [ "$installed" = "$latest" ] && return 0
  printf '\033[1;33m'
  printf '╔════════════════════════════════════════════════════════════════╗\n'
  printf '║  ⚠  Claude Code update available                               ║\n'
  printf '║     installed: %-48s║\n' "$installed"
  printf '║     latest:    %-48s║\n' "$latest"
  printf '║                                                                ║\n'
  printf '║  Bump CLAUDE_CODE_VERSION in .devcontainer/.env then           ║\n'
  printf '║  "Dev Containers: Rebuild Container" in VS Code.               ║\n'
  printf '╚════════════════════════════════════════════════════════════════╝\n'
  printf '\033[0m'
}
check_claude_update
