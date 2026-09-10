#!/usr/bin/env bash
# @name claude-fallback-warn
# @phase post-start
# @required false
# @description Claude binary fallback sentinel (v2.1-2). /etc/claude-fallback-warn is touched by Dockerfile.base when Phase B (symlink to extension's embedded binary) was NOT used — either because the VSIX download failed at build, or because the extracted extension had no usable binary at the expected path. /etc/claude-source carries the human-readable detail.

set -eE

if [ -f /etc/claude-fallback-warn ]; then
  SRC=$(cat /etc/claude-source 2>/dev/null || echo unknown)
  printf '\033[1;33m'
  printf '╔════════════════════════════════════════════════════════════════╗\n'
  printf '║  ⚠  Claude binary: npm fallback active (Phase B failed)        ║\n'
  printf '║     source: %-51s║\n' "${SRC:0:51}"
  printf '║                                                                ║\n'
  printf '║  Image is ~224 MB heavier than Phase B target. Investigate at  ║\n'
  printf '║  next CLAUDE_CODE_VERSION bump :                               ║\n'
  printf '║    - cat /etc/claude-source        (which branch fired)        ║\n'
  printf '║    - ls /home/node/.vscode-server/extensions/anthropic.claude* ║\n'
  printf '║    - readlink -f /usr/local/bin/claude                         ║\n'
  printf '║  See LOG.md v2.1-2 "Failsafe troubleshooting" section.         ║\n'
  printf '╚════════════════════════════════════════════════════════════════╝\n'
  printf '\033[0m'
fi
