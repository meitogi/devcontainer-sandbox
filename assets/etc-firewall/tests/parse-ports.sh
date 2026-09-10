#!/usr/bin/env bash
# Unit tests for the ports.txt resolver + parser (ports_file / ports_entries,
# defined in bin/devc-conf.sh). Standalone — no root, no network, no Docker.
# Usage: ./parse-ports.sh
#
# The file was called direct-tcp-allow.txt until 2026-08-10. Both names are
# read for one version; these tests pin which one wins, and that the old one
# is never applied in silence.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
# Overridable for the repo layout (bin/devc-conf.sh); the default is the image
# location. The pair used to be lifted out of init-firewall.sh with `sed`,
# because sourcing that script would take a lock and touch iptables. Now that
# they live in a library that is sourced and nothing else, that trick is gone.
DEVC_CONF_LIB="${DEVC_CONF_LIB:-/usr/local/bin/devc-conf.sh}"
[ -f "$DEVC_CONF_LIB" ] || DEVC_CONF_LIB="$THIS_DIR/../../../bin/devc-conf.sh"

if [ ! -f "$DEVC_CONF_LIB" ]; then
  echo "❌ devc-conf.sh not found (set DEVC_CONF_LIB=)" >&2
  exit 1
fi

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }

# shellcheck disable=SC1090
FIREWALL_CONFIG_DIR=/nonexistent . "$DEVC_CONF_LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== ports.txt — resolution ==="

D="$TMP/only-new"; mkdir -p "$D"; : > "$D/ports.txt"
eq "the new name is picked up" "$(ports_file "$D" 2>/dev/null)" "$D/ports.txt"
eq "and says nothing about it"  "$(ports_file "$D" 2>&1 >/dev/null)" ""

D="$TMP/only-old"; mkdir -p "$D"; : > "$D/direct-tcp-allow.txt"
eq "the old name is still read" "$(ports_file "$D" 2>/dev/null)" "$D/direct-tcp-allow.txt"
WARN=$(ports_file "$D" 2>&1 >/dev/null)
case "$WARN" in
  *deprecated*) ok "and warns that it is deprecated" ;;
  *)            ko "and warns that it is deprecated" "$WARN" "…deprecated…" ;;
esac

D="$TMP/both"; mkdir -p "$D"; : > "$D/ports.txt"; : > "$D/direct-tcp-allow.txt"
eq "with both present, the new name wins" "$(ports_file "$D" 2>/dev/null)" "$D/ports.txt"
WARN=$(ports_file "$D" 2>&1 >/dev/null)
case "$WARN" in
  *ignoring*) ok "and the old one is named as ignored, not applied silently" ;;
  *)          ko "and the old one is named as ignored, not applied silently" "$WARN" "…ignoring…" ;;
esac

D="$TMP/neither"; mkdir -p "$D"
eq "no file at all resolves to nothing" "$(ports_file "$D" 2>/dev/null)" ""
eq "and that is not an error"           "$(ports_file "$D" >/dev/null 2>&1; echo $?)" "0"

echo "=== ports.txt — parsing ==="

D="$TMP/parse"; mkdir -p "$D"
cat > "$D/ports.txt" <<'EOF'
# a full-line comment
host:9222

   ollama:11434
peer:5432 # an inline comment
	tabbed:1234
EOF
eq "comments, blanks and whitespace are stripped" \
  "$(ports_entries "$D/ports.txt" | tr '\n' ' ')" \
  "host:9222 ollama:11434 peer:5432 tabbed:1234 "

printf 'a:1\r\nb:2\r\n' > "$D/crlf.txt"
eq "CRLF line endings do not leak into the entry" \
  "$(ports_entries "$D/crlf.txt" | tr '\n' ' ')" "a:1 b:2 "

printf '# only comments\n\n' > "$D/empty.txt"
eq "a comment-only file yields nothing" "$(ports_entries "$D/empty.txt")" ""

printf 'x:1' > "$D/nonewline.txt"
eq "a last line without a trailing newline is not lost" \
  "$(ports_entries "$D/nonewline.txt")" "x:1"

eq "a missing file yields nothing, without failing" \
  "$(ports_entries "$D/nope.txt"; echo $?)" "0"

echo
echo "parse-ports: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
