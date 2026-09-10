#!/usr/bin/env bash
# @name claude-ext-pin-warn
# @phase post-start
# @required false
# @description Claude extension consistency sentinel. The base image bakes a
# PATCHED anthropic.claude-code into ~/.vscode-server/extensions and registers
# it in extensions.json — VS Code loads it from that registry, no Marketplace
# pin needed. A pin in devcontainer.json is therefore the one path by which an
# UNPATCHED copy can arrive (it fires whenever the pin and the baked version
# diverge, or the bake failed). This fragment runs at every container start
# and banners on three inconsistencies :
#   1. no baked extension present            (image bake failed — red ; a pin,
#      if present, is then acting as the fallback and is named, not warned)
#   2. more than one installed copy          (a downloaded, unpatched copy
#      may shadow the patched one — red)
#   3. a pin that DIFFERS from the baked version, or carries no version at
#      all (floating) — yellow. A pin equal to the baked version is inert
#      (VS Code sees the extension installed, downloads nothing) and stays
#      silent on purpose.

set -eE

EXT_ROOT="${HOME}/.vscode-server/extensions"
CONFIG_DIR="${DEVC_CONFIG_DIR:-/workspace/.devcontainer}"

banner() { # banner <color> <lines...>
  local color="$1"; shift
  printf '%b' "$color"
  printf '╔════════════════════════════════════════════════════════════════╗\n'
  local line
  for line in "$@"; do
    printf '║  %-62s║\n' "$line"
  done
  printf '╚════════════════════════════════════════════════════════════════╝\n'
  printf '\033[0m'
}

# --- Pin lookup (shared by the checks below) --------------------------------
PIN=""
if command -v jq >/dev/null 2>&1; then
  for CONF in "$CONFIG_DIR/devcontainer.local.json" "$CONFIG_DIR/devcontainer.json"; do
    [ -f "$CONF" ] || continue
    # devcontainer.json carries // comments — strip them before jq, same
    # trade-off as devc-hook (a literal // inside a string would be eaten,
    # acceptable for this config).
    P=$(sed -E 's://.*$::' "$CONF" | jq -r \
      '(.customizations.vscode.extensions // []) | .[] | select(type == "string" and startswith("anthropic.claude-code"))' \
      2>/dev/null | head -1 || true)
    if [ -n "$P" ]; then PIN="$P"; PIN_CONF="${CONF##*/}"; break; fi
  done
fi
PIN_VERSION="${PIN##*@}"
[ "$PIN_VERSION" = "$PIN" ] && PIN_VERSION=""   # no @version → floating

# --- Installed copies -------------------------------------------------------
mapfile -t COPIES < <(ls -d "$EXT_ROOT"/anthropic.claude-code-* 2>/dev/null || true)

if [ "${#COPIES[@]}" -eq 0 ]; then
  if [ -n "$PIN" ]; then
    FALLBACK_LINE="A pin exists (${PIN:0:40}) and is acting as the"
    FALLBACK_LINE2='fallback — that copy is UNPATCHED. Investigate the image'
  else
    FALLBACK_LINE='Fix : install manually from the Marketplace (firewall'
    FALLBACK_LINE2='allows it), or re-add a pin temporarily (UNPATCHED copy).'
  fi
  banner '\033[1;31m' \
    '✖  NO Claude Code extension baked in this image' \
    '' \
    'The image build normally bakes a patched extension ; none is' \
    'present.' \
    "$FALLBACK_LINE" \
    "$FALLBACK_LINE2" \
    'Investigate the image build (cat /etc/claude-source).'
elif [ "${#COPIES[@]}" -gt 1 ]; then
  banner '\033[1;31m' \
    '✖  MULTIPLE Claude Code extension copies installed' \
    '' \
    'A second copy (Marketplace download) sits next to the baked' \
    'patched one — the active one may be UNPATCHED :' \
    "$(printf '%s' "${COPIES[0]##*/}")" \
    "$(printf '%s' "${COPIES[1]##*/}")" \
    'Fix : remove any anthropic.claude-code pin from' \
    'devcontainer.json, delete the non-baked copy under' \
    '~/.vscode-server/extensions/, then Reload Window.'
fi

# --- Pin vs baked version ---------------------------------------------------
# A pin equal to the baked version is inert (nothing downloads) — silent.
# A pin that differs, or has no version, is the drift that installs an
# unpatched Marketplace copy over the patched one.
if [ -n "$PIN" ] && [ "${#COPIES[@]}" -ge 1 ]; then
  BAKED_VERSION=$(printf '%s' "${COPIES[0]##*/}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -z "$PIN_VERSION" ]; then
    banner '\033[1;33m' \
      '⚠  UNVERSIONED anthropic.claude-code pin in devcontainer' \
      '' \
      "   ${PIN_CONF:-devcontainer.json} : ${PIN:0:44}" \
      '' \
      'A floating pin can install the LATEST Marketplace build over' \
      'the patched baked one at any container start. Remove the pin' \
      '— the image is the single source of the extension.'
  elif [ "$PIN_VERSION" != "$BAKED_VERSION" ]; then
    banner '\033[1;33m' \
      '⚠  anthropic.claude-code pin DIFFERS from the baked version' \
      '' \
      "   pinned : ${PIN_VERSION:0:20}   baked : ${BAKED_VERSION:0:20}" \
      "   (${PIN_CONF:-devcontainer.json})" \
      '' \
      'VS Code will install the pinned Marketplace copy, which is' \
      'NOT patched, and it can shadow the baked one. Remove the pin' \
      'or align it — the image is the single source of the extension.'
  fi
fi

exit 0
