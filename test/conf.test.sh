#!/usr/bin/env bash
# Unit tests for the shared `.txt` config parser (conf_entries, defined in
# bin/devc-conf.sh). Standalone — no root, no network, no Docker.
# Usage: bash test/conf.test.sh
#
# This is the contract three families rely on: the firewall allowlists,
# hooks/disabled.txt and skills/disabled.txt. Every rule below used to be
# re-derived at each reader, and no two readers agreed.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for the repo layout (bin/devc-conf.sh); the default is the
# image location.
DEVC_CONF_LIB="${DEVC_CONF_LIB:-/usr/local/bin/devc-conf.sh}"
[ -f "$DEVC_CONF_LIB" ] || DEVC_CONF_LIB="$THIS_DIR/../bin/devc-conf.sh"

if [ ! -f "$DEVC_CONF_LIB" ]; then
  echo "❌ devc-conf.sh not found (set DEVC_CONF_LIB=)" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$DEVC_CONF_LIB"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== conf_entries — the line format ==="

cat > "$TMP/basic.txt" <<'EOF'
# a full-line comment
alpha
   # an indented comment

   bravo
charlie # an inline comment
	delta
EOF
eq "comments, blanks and edge whitespace are stripped" \
  "$(conf_entries "$TMP/basic.txt" | tr '\n' ' ')" \
  "alpha bravo charlie delta "

# Cut at the FIRST `#`, not the last: a comment can talk about `#`.
printf 'echo # why # and more\n' > "$TMP/twohash.txt"
eq "the cut is at the first # on the line" \
  "$(conf_entries "$TMP/twohash.txt")" "echo"

# The one deliberate difference with ports_entries. A hook key never contains
# a space, but the parser is shared, so the generic rule has to be the
# conservative one: only the edges belong to the format.
printf 'two words\n  spaced  out  \n' > "$TMP/interior.txt"
eq "interior whitespace is preserved" \
  "$(conf_entries "$TMP/interior.txt" | tr '\n' '|')" \
  "two words|spaced  out|"

printf 'a\r\nb\r\n' > "$TMP/crlf.txt"
eq "CRLF line endings do not leak into the entry" \
  "$(conf_entries "$TMP/crlf.txt" | tr '\n' ' ')" "a b "

printf 'x' > "$TMP/nonewline.txt"
eq "a last line without a trailing newline is not lost" \
  "$(conf_entries "$TMP/nonewline.txt")" "x"

printf '# only comments\n\n   \n' > "$TMP/empty.txt"
eq "a comment-only file yields nothing" "$(conf_entries "$TMP/empty.txt")" ""

# The read loop's last command is `[ -n "$line" ] && printf`, so a file ending
# on a blank line used to leave rc=1 behind — enough to kill a caller running
# under `set -e` on a config file that is simply well formatted.
printf 'a\n\n' > "$TMP/trailingblank.txt"
eq "a file ending on a blank line still succeeds" \
  "$(conf_entries "$TMP/trailingblank.txt" >/dev/null; echo $?)" "0"
printf 'a\n# tail comment\n' > "$TMP/trailingcomment.txt"
eq "and one ending on a comment too" \
  "$(conf_entries "$TMP/trailingcomment.txt" >/dev/null; echo $?)" "0"

# The `!` opt-in of devc-hook. The parser must not know what it means — it
# hands the token over untouched and lets disabled_mode() decide.
printf '!post-start.d/20-firewall-reinit.sh\n' > "$TMP/bang.txt"
eq "a leading ! is handed over verbatim" \
  "$(conf_entries "$TMP/bang.txt")" "!post-start.d/20-firewall-reinit.sh"

echo "=== conf_entries — absent input ==="

eq "a missing file yields nothing"       "$(conf_entries "$TMP/nope.txt")" ""
eq "and that is not an error"            "$(conf_entries "$TMP/nope.txt"; echo $?)" "0"
eq "no argument at all yields nothing"   "$(conf_entries)" ""
eq "and that is not an error either"     "$(conf_entries; echo $?)" "0"
eq "a directory is not a config file"    "$(conf_entries "$TMP"; echo $?)" "0"

echo "=== the counting spelling still agrees ==="

# Four readers only need "how many active lines" and use a single grep for it:
#   bin/reload-firewall, assets/opt/shell-init.sh,
#   post-start.d/30-firewall-local-banner.sh, post-start.d/22-firewall-bake-warn.sh
# They were left alone deliberately — shell-init.sh is sourced by every
# interactive shell, and a library source there buys nothing when the two
# spellings already agree. This assertion is what keeps "already agree" true:
# change the line format and it goes red, naming the sites to update.
printf 'a\n# c\n   # ic\n\n   \n  b  \nc # x\n\r\nd' > "$TMP/count.txt"
eq "grep -cE '^[[:space:]]*[^#[:space:]]' matches conf_entries" \
  "$(grep -cE '^[[:space:]]*[^#[:space:]]' "$TMP/count.txt")" \
  "$(conf_entries "$TMP/count.txt" | grep -c .)"

echo "=== ports_entries — the squeeze on top ==="

printf 'host : 9222\nollama:11434\n' > "$TMP/ports.txt"
eq "interior whitespace is squeezed out" \
  "$(ports_entries "$TMP/ports.txt" | tr '\n' ' ')" "host:9222 ollama:11434 "

# `tr -d '[:space:]'` over the stream deletes newlines too, which glues every
# entry into one token. test-firewall.sh shipped that for two versions.
eq "entries stay on separate lines" \
  "$(ports_entries "$TMP/ports.txt" | wc -l | tr -d ' ')" "2"

echo
echo "conf: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
