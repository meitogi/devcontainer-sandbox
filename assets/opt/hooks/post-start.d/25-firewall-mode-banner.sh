#!/usr/bin/env bash
# @name firewall-mode-banner
# @phase post-start
# @required false
# @description Loud banner when the user is running in basic mode (A4 default is strict). Strict mode = silent — the safe default doesn't need a banner.

set -eE

FW_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
FW_MODE="${FW_MODE:-strict}"

# The banner names the FILE, not firewall-mode.sh: that script is v2
# workspace tooling a project on the published image does not carry, and
# this literal sits in a quoted heredoc, so no -x test can guard it the
# way shell-init.sh:215 guards its own copy of the same advice.
case "$FW_MODE" in
  basic|okeish)
    printf '\033[1;33m'
    cat <<'BANNER'
╔════════════════════════════════════════════════════════════════╗
║  ⚠  Firewall in BASIC mode (DNS allowlist only, no L7 filter)  ║
║                                                                ║
║  To re-enable strict :                                         ║
║     echo strict > .devcontainer/firewall/default-mode          ║
║     Rebuild the container in VS Code                           ║
╚════════════════════════════════════════════════════════════════╝
BANNER
    printf '\033[0m\n'
    ;;
esac
