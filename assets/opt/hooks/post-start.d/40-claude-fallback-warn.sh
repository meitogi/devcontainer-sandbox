#!/usr/bin/env bash
# @name claude-fallback-warn
# @phase post-start
# @required false
# @description Claude binary fallback sentinel (v2.1-2). /etc/claude-fallback-warn is touched by Dockerfile.base when Phase B (symlink to extension's embedded binary) was NOT used — either because the VSIX download failed at build, or because the extracted extension had no usable binary at the expected path. /etc/claude-source carries the human-readable detail.

set -eE

if [ -f /etc/claude-fallback-warn ]; then
  # One fact, one repair line. The three commands that used to be framed are
  # a troubleshooting session, not a boot message — they live in LOG.md, which
  # the line names. The image being ~224 MB heavier is a consequence of the
  # fact, not a second fact.
  SRC=$(cat /etc/claude-source 2>/dev/null || echo unknown)
  printf '\033[1;33m⚠ Claude binary: npm fallback active (Phase B failed) — source: %s\033[0m\n' "${SRC:0:60}"
  printf '   ↳ investigate at the next CLAUDE_CODE_VERSION bump — LOG.md v2.1-2 "Failsafe troubleshooting"\n'
fi
