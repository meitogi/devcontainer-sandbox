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
  # One fact, one line. This used to spend eight framed lines on it — six of
  # them telling an operator who has rebuilt this container many times how to
  # bump a version. A newer release is news, not an incident: the frame is the
  # boot panel's, and the repair leaves the banner entirely.
  printf '\033[1;33m⚠  Claude Code %s available (installed: %s)\033[0m\n' "$latest" "$installed"
}
check_claude_update
