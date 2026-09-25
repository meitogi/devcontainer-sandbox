#!/usr/bin/env bash
# @name firewall-bake-warn
# @phase post-start
# @required false
# @description Red banner when the image carries no baked firewall, or when the baked ruleset no longer matches its sources. Both mean the frozen set was bypassed and boot fell back to compiling whatever /etc happened to hold — which is exactly the state the bake exists to make impossible.

set -eE

# Overridable so firewall/tests/ can render both banners against a sandbox —
# a red banner nobody has ever seen fire is a banner that fires wrong.
FW="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"
EFFECTIVE="$FW/effective"
DIGEST_LIB="${FW_DIGEST_LIB:-/usr/local/bin/firewall-digest.sh}"

# One fact on the coloured line, the repair on an uncoloured `↳` under it.
# These two are alarms, not news — a ruleset that was bypassed — so unlike the
# update probe they keep a repair. They just no longer each draw a box: the
# two fired independently and stacked, and the frame now belongs to the boot
# panel alone.
_repair() {   # the arrow marks the repair, once; the rest of it lines up under
  [ "$#" -gt 0 ] || return 0
  printf '   ↳ %s\n' "$1"; shift
  [ "$#" -gt 0 ] && printf '     %s\n' "$@"
  return 0
}
banner()      { printf '\033[1;31m%s\033[0m\n' "$1"; shift; _repair "$@"; }
warn_banner() { printf '\033[1;33m%s\033[0m\n' "$1"; shift; _repair "$@"; }

# Case 1 — no bake ran. In the 3-level model this is a SUPPORTED state, not
# an alarm : without a project fw-bake stage, /etc/devcontainer-firewall is
# pure image content (root-owned), so boot compiled the base allowlist and
# nothing else. Stay silent — UNLESS the project carries actual firewall
# rules (non-comment lines in its domains files, or any policy.d yaml) :
# those are then silently NOT applied, and that deserves a banner.
if [ ! -s "$FW/baked-at" ] || [ ! -s "$EFFECTIVE/sources.sha256" ]; then
  PROJ_FW="${PROJECT_FIREWALL_DIR:-/workspace/.devcontainer/firewall}"
  HAS_RULES=0
  if [ -d "$PROJ_FW" ]; then
    # Both port-file names: a project still on the old one carries rules just
    # the same, and a banner that misses them says "nothing to apply" wrongly.
    for f in "$PROJ_FW/domains.txt" "$PROJ_FW"/domains.d/*.txt \
             "$PROJ_FW/ports.txt" "$PROJ_FW/direct-tcp-allow.txt"; do
      [ -f "$f" ] || continue
      if grep -qE '^[[:space:]]*[^#[:space:]]' "$f"; then
        HAS_RULES=1
        break
      fi
    done
    if [ "$HAS_RULES" = "0" ] && ls "$PROJ_FW"/policy.d/*.yaml >/dev/null 2>&1; then
      HAS_RULES=1
    fi
  fi
  if [ "$HAS_RULES" = "1" ]; then
    warn_banner \
      '⚠  PROJECT FIREWALL RULES NOT APPLIED — this image has no bake stage, boot used the base allowlist only' \
      'add to your Dockerfile: COPY firewall/ /tmp/fw-src/' \
      '                        RUN firewall-docker-setup.sh --src /tmp/fw-src --dest /out' \
      'then Rebuild Container.'
  fi
  exit 0
fi

# Case 2 — baked, but the sources moved since. init-firewall.sh already logged
# the fallback and recompiled ; this surfaces it where someone will see it,
# because the recompile silently re-admits anything sitting in /etc.
if [ -r "$DIGEST_LIB" ]; then
  # shellcheck source=/dev/null
  . "$DIGEST_LIB"
  BAKED=$(cat "$EFFECTIVE/sources.sha256")
  CURRENT=$(fw_sources_digest "$FW" "$(cat "$EFFECTIVE/local-included" 2>/dev/null || echo 0)")
  if [ "$BAKED" != "$CURRENT" ]; then
    banner \
      '⚠  FIREWALL DRIFT — the baked ruleset no longer matches the sources in /etc/devcontainer-firewall' \
      'boot recompiled instead of using the frozen set — Rebuild Container to re-bake,' \
      'or inspect what changed: reload-firewall --dry-run'
    printf '   baked %s → current %s\n' "${BAKED:0:12}" "${CURRENT:0:12}"
    exit 0
  fi
fi

# Silence on the happy path — the safe state does not need a banner.
