#!/usr/bin/env bash
# Unit tests for the inbound.txt parser (inbound_entries, defined in
# bin/devc-conf.sh). Standalone — no root, no network, no Docker.
# Usage: ./parse-inbound.sh
#
# inbound.txt is the one exception to `INPUT DROP`, so the parser is strict: a
# line that is not exactly `udp:<port>` or `tcp:<port>` is named on stderr and
# dropped. These tests pin both halves — the bad line never reaches the output,
# and it never disappears in silence.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"
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
. "$DEVC_CONF_LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== inbound.txt — good lines ==="

cat > "$TMP/good.txt" <<'EOT'
# a full-line comment
udp:50101

   tcp:8443
udp : 5353 # an inline comment, interior whitespace
	udp:65535
tcp:1
EOT
eq "comments, blanks and whitespace are stripped" \
  "$(inbound_entries "$TMP/good.txt" 2>/dev/null | tr '\n' ' ')" \
  "udp:50101 tcp:8443 udp:5353 udp:65535 tcp:1 "
eq "and a valid file says nothing on stderr" \
  "$(inbound_entries "$TMP/good.txt" 2>&1 >/dev/null)" ""

printf 'udp:1\r\ntcp:2\r\n' > "$TMP/crlf.txt"
eq "CRLF line endings do not leak into the entry" \
  "$(inbound_entries "$TMP/crlf.txt" | tr '\n' ' ')" "udp:1 tcp:2 "

printf 'udp:7' > "$TMP/nonewline.txt"
eq "a last line without a trailing newline is not lost" \
  "$(inbound_entries "$TMP/nonewline.txt")" "udp:7"

printf '# only comments\n\n' > "$TMP/empty.txt"
eq "a comment-only file yields nothing" "$(inbound_entries "$TMP/empty.txt" 2>&1)" ""

eq "a missing file yields nothing, says nothing, and succeeds" \
  "$(inbound_entries "$TMP/nope.txt" 2>&1; echo "rc=$?")" "rc=0"

echo "=== inbound.txt — malformed lines are rejected loudly ==="

# One bad line between two good ones, per case: the bad one must be dropped AND
# named, the good ones around it must survive.
reject() {  # reject <label> <bad line>
  printf 'udp:1000\n%s\ntcp:2000\n' "$2" > "$TMP/bad.txt"
  local out err
  out=$(inbound_entries "$TMP/bad.txt" 2>/dev/null | tr '\n' ' ')
  err=$(inbound_entries "$TMP/bad.txt" 2>&1 >/dev/null)
  eq "$1 — dropped, the good lines around it kept" "$out" "udp:1000 tcp:2000 "
  case "$err" in
    *rejected*"$(printf '%s' "$2" | tr -d '[:space:]')"*) ok "$1 — named on stderr" ;;
    *) ko "$1 — named on stderr" "$err" "…rejected '…$2…'…" ;;
  esac
}

reject "unknown protocol"         "sctp:5000"
reject "upper-case protocol"      "UDP:5000"
reject "port 0"                   "udp:0"
reject "port 65536"               "udp:65536"
reject "a six-digit port"         "tcp:100000"
reject "no port"                  "udp:"
reject "no protocol"              "5000"
reject "a range"                  "udp:50000-50019"
reject "a leading zero"           "udp:0080"
reject "a host:port (ports.txt)"  "host:9222"
reject "garbage"                  "open everything"
reject "a negative port"          "udp:-1"

printf 'nope\n' > "$TMP/allbad.txt"
eq "a file of only bad lines still succeeds (set -e callers live)" \
  "$(inbound_entries "$TMP/allbad.txt" 2>/dev/null; echo "rc=$?")" "rc=0"

echo
echo "parse-inbound: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
