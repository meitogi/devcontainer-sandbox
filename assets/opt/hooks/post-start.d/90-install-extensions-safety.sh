#!/usr/bin/env bash
# @name install-extensions-safety
# @phase post-start
# @required false
# @description Safety net: if vscode-server raced ahead of the firewall init and some extensions failed to download with ECONNREFUSED, re-install them now that mitmproxy is confirmed up. Idempotent — already-installed ones are skipped.

set -eE

INSTALL_EXTS=/workspace/.devcontainer/install-extensions.sh
# Workspace copy wins (v2 layout) ; the baked one reads the project's
# devcontainer.json all the same.
[ -x "$INSTALL_EXTS" ] || INSTALL_EXTS=/usr/local/bin/install-extensions
if [ -x "$INSTALL_EXTS" ]; then
  if ! command -v code >/dev/null 2>&1; then
    # vscode-server layouts vary by version and arch :
    #   /vscode/vscode-server/bin/<arch>/<hash>/bin/remote-cli/code   (recent)
    #   /vscode/vscode-server/bin/<hash>/bin/remote-cli/code          (older)
    #   $HOME/.vscode-server/bin/<hash>/bin/remote-cli/code           (legacy)
    CODE_BIN=$(find /vscode/vscode-server "$HOME/.vscode-server" \
               -maxdepth 6 -type f -name code -path '*remote-cli*' \
               2>/dev/null | head -1)
    [ -n "$CODE_BIN" ] && export PATH="$(dirname "$CODE_BIN"):$PATH"
  fi
  if command -v code >/dev/null 2>&1; then
    "$INSTALL_EXTS" || true
  else
    echo "ℹ 'code' CLI not yet available — skipping extension safety net"
  fi
fi
