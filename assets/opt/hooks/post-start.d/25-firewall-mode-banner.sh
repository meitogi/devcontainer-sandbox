#!/usr/bin/env bash
# @name firewall-mode-banner
# @phase post-start
# @required false
# @description One yellow line when the user is running in basic mode (A4 default is strict). Strict mode is not silent any more — it is reported by the boot panel.

set -eE

FW_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
FW_MODE="${FW_MODE:-strict}"

# "Strict mode = silent, the safe default doesn't need a banner" was this
# fragment's founding rule, and it still holds — but it has changed REASON, not
# verdict. It was true while saying anything at all cost a seven-line box, so
# the only way not to drown the useful warnings was to say nothing on the happy
# path. The boot panel now states `Firewall: strict` for one line, inside a
# frame that is its own, so the safe default IS reported — just not here.
# What is left here is the warning, and a warning is one line too.
#
# The line names the FILE, not firewall-mode.sh: that script is v2 workspace
# tooling a project on the published image does not carry, so no -x test can
# guard it the way shell-init.sh guards its own copy of the same advice.
case "$FW_MODE" in
  basic|okeish)
    printf '\033[1;33m⚠  Firewall: BASIC mode (DNS allowlist only, no L7 filter)\033[0m\n'
    printf '   ↳ re-enable: echo strict > .devcontainer/firewall/default-mode, then rebuild\n'
    ;;
esac
