#!/usr/bin/env bash
# @name firewall-local-banner
# @phase post-start
# @required false
# @description One-line status for the workspace .local firewall layer. Says whether those overrides are actually in force or merely staged on disk — since the bake excludes them by default, "the file exists" and "the firewall allows it" are no longer the same thing.

set -eE

LOCAL_TXT=/workspace/.devcontainer/firewall/domains.local.txt
LOCAL_D=/workspace/.devcontainer/firewall/policy.local.d
LOCAL_INCLUDED_MARKER=/etc/devcontainer-firewall/effective/local-included

# grep -c prints "0" on no match but exits 1 — `|| true` allows that without
# re-emitting "0" (would give "0\n0" multi-line and break the -gt below).
LOCAL_HOSTS=$(grep -cE "^[[:space:]]*[^#[:space:]]" "$LOCAL_TXT" 2>/dev/null || true)
LOCAL_HOSTS="${LOCAL_HOSTS:-0}"
LOCAL_POLICY=0
[ -d "$LOCAL_D" ] && LOCAL_POLICY=$(find "$LOCAL_D" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null | wc -l | tr -d ' ')

[ "${LOCAL_HOSTS:-0}" -gt 0 ] || [ "${LOCAL_POLICY:-0}" -gt 0 ] || exit 0

# local-included records what the bake decided. Absent marker = unbaked image,
# where the boot recompile picks the overrides up as it always did.
INCLUDED=1
[ -r "$LOCAL_INCLUDED_MARKER" ] && INCLUDED=$(tr -d '[:space:]' < "$LOCAL_INCLUDED_MARKER")

if [ "$INCLUDED" = "1" ]; then
  printf '\033[1;36mℹ️  Firewall local overrides ACTIVE (baked in): %s host(s) + %s policy.local.d file(s)\033[0m\n' \
    "$LOCAL_HOSTS" "$LOCAL_POLICY"
else
  printf '\033[1;33mℹ️  Firewall local overrides STAGED, NOT ACTIVE: %s host(s) + %s policy.local.d file(s)\033[0m\n' \
    "$LOCAL_HOSTS" "$LOCAL_POLICY"
  printf '   Preview : reload-firewall --dry-run   ·   Apply (host terminal) : wtf firewall reload\n'
  printf '   Or bake them in permanently : FIREWALL_ALLOW_LOCAL_AT_REBUILD=1 in .devcontainer/.env + rebuild\n'
fi
