#!/usr/bin/env bash
# @name test-firewall
# @phase post-create
# @required false
# @description Connectivity validation via test-firewall.sh. Runs after VS Code has already kicked off the extension install in parallel, so blocking here doesn't delay anything the user sees. ipset test requires root.

set -eE

if [ -x /usr/local/bin/test-firewall.sh ]; then
  sudo /usr/local/bin/test-firewall.sh
fi
