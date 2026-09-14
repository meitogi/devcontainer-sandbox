#!/usr/bin/env bash
# resolve-check.sh — what does each Claude Code version resolve to, against the
# REAL patcher repository? Read-only: --check never writes a pin, and every run
# uses a throwaway .devcontainer so this container's own .env is never touched.
#
#   bash resolve-check.sh 2.1.220 2.1.258 2.1.268 2.1.269 2.1.270
#
# Run it AFTER pushing the tags: it is the end-to-end proof that a container on
# version X is served the cc<X>-r<n> line and nothing else.
#
# It PRINTS a table and always exits 0 — read the VERDICT column, do not wire
# this to a CI gate. ENV_FILE overrides where EXT_PATCHES_REPO/_TOKEN are read
# from; the default is the monorepo dogfood beside this repo, the same fallback
# shape as VENDOR_DIR in run-image-suites.sh so a standalone checkout can still
# point at its own .env.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$REPO/bin"
SRC="${ENV_FILE:-$REPO/../../.devcontainer/.env}"
[ -r "$SRC" ] || { echo "no readable env file at $SRC — set ENV_FILE=<path to a .env carrying EXT_PATCHES_REPO and EXT_PATCHES_TOKEN>" >&2; exit 64; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

printf '%-10s %-18s %s\n' VERSION RÉSOUT VERDICT
printf '%-10s %-18s %s\n' ------- ------ -------
for V in "$@"; do
  mkdir -p "$S/conf" "$S/ext"
  printf '{"version":"%s"}\n' "$V" > "$S/ext/package.json"
  printf '// stub\n' > "$S/ext/extension.js"
  printf 'EXT_DIR=%s\n' "$S/ext" > "$S/buildenv"
  grep -E '^EXT_PATCHES_(REPO|TOKEN)=' "$SRC" > "$S/conf/.env"
  echo 'EXT_PATCHES_REF=none-yet' >> "$S/conf/.env"

  OUT=$(DEVC_CONFIG_DIR="$S/conf" BUILD_ENV="$S/buildenv" \
        RESTORE_EXT_PATCHES=/bin/true EXT_PATCHES_SYNC="$B/ext-patches-sync" \
        bash "$B/ext-patches-update" --check 2>&1)
  REF=$(printf '%s' "$OUT" | sed -n 's/^ *available *//p' | tr -d '\r')
  if printf '%s' "$OUT" | grep -q 'never been tested'; then
    printf '%-10s %-18s %s\n' "$V" "(refus)" "aucune ligne cc$V-r<n>"
  elif [ "$REF" = "cc$V-r${REF##*-r}" ]; then
    printf '%-10s %-18s %s\n' "$V" "$REF" "✔ sa propre ligne"
  else
    printf '%-10s %-18s %s\n' "$V" "${REF:-?}" "✘ PAS sa ligne"
  fi
  rm -rf "$S/conf" "$S/ext"
done
