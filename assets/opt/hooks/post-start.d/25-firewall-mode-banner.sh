#!/usr/bin/env bash
# @name firewall-mode-banner
# @phase post-start
# @required false
# @description Loud banner when the user is running in basic mode (A4 default is strict). Strict mode = silent — the safe default doesn't need a banner.

set -eE

FW_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
FW_MODE="${FW_MODE:-strict}"

case "$FW_MODE" in
  basic|okeish)
    printf '\033[1;33m'
    cat <<'BANNER'
╔════════════════════════════════════════════════════════════════╗
║  ⚠  Firewall in BASIC mode (DNS allowlist only, no L7 filter)  ║
║                                                                ║
║  To re-enable strict :                                         ║
║     .devcontainer/firewall-mode.sh strict   [host or container]║
║     Rebuild the container in VS Code                           ║
╚════════════════════════════════════════════════════════════════╝
BANNER
    printf '\033[0m\n'
    ;;
esac
