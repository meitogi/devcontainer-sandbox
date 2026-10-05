#!/usr/bin/env bash
# @name firewall-init
# @phase on-create
# @required true
# @description First lifecycle firewall bring-up. Must succeed before vscode-server downloads extensions.

set -eE

FW_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
FW_MODE="${FW_MODE:-strict}"
FW_DEBUG_ARG=""
[ "${CLAUDE_CODE_FIREWALL_DEBUG:-}" = "true" ] && FW_DEBUG_ARG="--debug"

# init-firewall.sh output flows through the dispatcher's tee → phase log.
#
# RC is captured and reprinted: this used to `exit 1` whatever happened, so
# every failure in the phase log read `rc=1` and the real code — 4 for an
# xtables lock, 141 for a SIGPIPE — was thrown away. One digit cost a whole
# diagnosis on 2026-10-05.
set +e
sudo /usr/local/bin/init-firewall.sh $FW_DEBUG_ARG 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  echo "  ✓ firewall up at onCreate (mode=$FW_MODE) — VS Code can DL extensions"
else
  echo "⚠ onCreate firewall init FAILED (rc=$RC) — postStartCommand will retry"
  exit "$RC"
fi
