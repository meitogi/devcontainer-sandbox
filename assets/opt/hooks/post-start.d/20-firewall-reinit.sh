#!/usr/bin/env bash
# @name firewall-reinit
# @phase post-start
# @required true
# @description Re-invoke init-firewall.sh at every start. init-firewall.sh has its own kernel-state guard (skips when firewall is already up). Self-healing on restart (netns wiped → re-init). Also handles HTTPS_PROXY propagation.

set -eE

FW_DEBUG_ARG=""
[ "${CLAUDE_CODE_FIREWALL_DEBUG:-}" = "true" ] && FW_DEBUG_ARG="--debug"
sudo /usr/local/bin/init-firewall.sh $FW_DEBUG_ARG
