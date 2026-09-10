#!/usr/bin/env bash
# Runs every unprivileged firewall suite against THIS repo's copies of
# the bake, boot and reload scripts. The suites live in
# assets/etc-firewall/tests/ (shipped into the image); their relative-path
# defaults assume the image layout, so the repo layout is injected through
# the env seams they already expose.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Container-side suites: they exercise the image's own compile-policy.py and
# assume GNU coreutils. On macOS they produce dozens of misleading FAILs.
if ! stat -c '%a' "$REPO/package.json" >/dev/null 2>&1; then
  echo "✗ $(basename "$0") needs GNU coreutils — run it INSIDE the devcontainer." >&2
  echo "  Host-side, the docker-dependent checks live in test/run-image-suites.sh." >&2
  exit 2
fi

export FW_BAKE="$REPO/bin/firewall-docker-setup.sh"
export FW_INIT="$REPO/bin/init-firewall.sh"
export FW_DIGEST_LIB="$REPO/bin/firewall-digest.sh"
export DEVC_CONF_LIB="$REPO/bin/devc-conf.sh"
export FW_RELOAD="$REPO/bin/reload-firewall"
export COMPILE_POLICY="$REPO/bin/compile-policy.py"

# The bake honors FIREWALL_ALLOW_LOCAL_AT_REBUILD from the environment; a
# container whose .env opts in would leak it here and flip the hardened-bake
# assertions (T2/T3). The suites set it explicitly where they test the opt-in.
unset FIREWALL_ALLOW_LOCAL_AT_REBUILD

# parse-domains, split-local and addons were written and then never called by
# any runner — the same defect this file exists to prevent. A suite nobody runs
# is a suite that rots: split-local had drifted to a compile-policy.py path that
# exists in neither layout, which only surfaced when it was finally wired.
for suite in parse-ports parse-domains split-local bake-idempotency \
             frozen-fastpath reload-firewall-guards addons; do
  echo "=== $suite ==="
  bash "$REPO/assets/etc-firewall/tests/$suite.sh"
done
