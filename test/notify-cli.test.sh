#!/usr/bin/env bash
# Tests for bin/notify — `notify send`, the container's manual entry into the
# notify queue. Standalone — no root, no network, no Docker; needs node.
# Usage: bash test/notify-cli.test.sh
#
# The real binary is spawned against a throwaway queue directory, through
# --queue-dir and NOTIFY_QUEUE_DIR: never the live queue under /workspace.
# Each case asserts the exact JSON line written (key order included) with
# `ts` normalised, or the exit code and the reason for a refusal.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
BIN="$REPO/bin/notify"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }

TMP=$(mktemp -d) && [ -d "$TMP" ] || { echo "$(basename "$0"): mktemp failed — refusing to run on an empty path" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# The default queue of every case : a case that loses its --queue-dir (an
# option swallowed after `--`) lands here, never in the live queue.
export NOTIFY_QUEUE_DIR="$TMP/default"

# the single line of <file> with its ts replaced by TS
line_of() { node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);if(l.length!==1)throw new Error(l.length+" lines");const o=JSON.parse(l[0]);if(!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(o.ts))throw new Error("ts "+o.ts);o.ts="TS";process.stdout.write(JSON.stringify(o))' "$1"; }

echo "== notify send =="
node --check "$BIN" 2>/dev/null && ok "bin/notify parses" || ko "bin/notify parses" "node --check failed" "ok"

out=$(node "$BIN" send "Nightly build finished — 3 failures" --title CI --sid abc-1 --queue-dir "$TMP/q1"); rc=$?
eq "exit 0, prints the file it appended to" "$rc $out" "0 $TMP/q1/abc-1.jsonl"
eq "exact line, contract key order" "$(line_of "$TMP/q1/abc-1.jsonl")" \
  '{"v":1,"ts":"TS","sid":"abc-1","event":"send","producer":"notify-cli","message":"Nightly build finished — 3 failures","title":"CI"}'

node "$BIN" send second --sid abc-2 --queue-dir="$TMP/q1" >/dev/null
node "$BIN" send third --sid=abc-2 --queue-dir "$TMP/q1" >/dev/null
eq "appends, never truncates (two sends, two lines)" "$(wc -l < "$TMP/q1/abc-2.jsonl" | tr -d ' ')" "2"

NOTIFY_QUEUE_DIR="$TMP/q2" node "$BIN" send "  several   words " words >/dev/null
f=$(ls "$TMP/q2")
eq "no --sid: a fresh UUID names the file" "$(echo "$f" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.jsonl$')" "1"
eq "NOTIFY_QUEUE_DIR honoured, words joined, message trimmed, no title" "$(line_of "$TMP/q2/$f" | sed -E 's/"sid":"[^"]+"/"sid":"S"/')" \
  '{"v":1,"ts":"TS","sid":"S","event":"send","producer":"notify-cli","message":"several   words  words"}'

long=$(printf '🔔%.0s' $(seq 250)); title=$(printf 't%.0s' $(seq 70))
node "$BIN" send "$long" --title "$title" --sid caps --queue-dir "$TMP/q3" >/dev/null
eq "message capped at 200 code points, title at 64, … when cut" \
  "$(node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write([...o.message].length+" "+[...o.title].length+" "+o.message.slice(-1)+o.title.slice(-1)+" "+o.message.startsWith("🔔".repeat(199)))' "$TMP/q3/caps.jsonl")" \
  "200 64 …… true"

node "$BIN" send --sid dash --queue-dir "$TMP/q4" -- "-starts with a dash" >/dev/null
eq "-- ends the options" "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).message)' "$TMP/q4/dash.jsonl")" "-starts with a dash"

echo "== refusals =="
refuse() { # <label> <expected rc> <stderr fragment> <args…>
  local label=$1 want=$2 frag=$3; shift 3
  node "$BIN" "$@" >/dev/null 2>"$TMP/err"; local rc=$?
  if [ "$rc" = "$want" ] && grep -qF -- "$frag" "$TMP/err"; then ok "$label"; else ko "$label" "rc=$rc $(head -1 "$TMP/err")" "rc=$want, stderr names: $frag"; fi
}
refuse "no message → 2"            2 "a message is required"        send --queue-dir "$TMP/r"
refuse "blank message → 2"         2 "a message is required"        send "   " --queue-dir "$TMP/r"
refuse "unknown option → 2"        2 'unknown option "--body"'      send hi --body x --queue-dir "$TMP/r"
refuse "unknown command → 2"       2 'unknown command "push"'       push hi
refuse "path in --sid → 2"         2 "--sid must match"             send hi --sid ../x --queue-dir "$TMP/r"
refuse "dotfile --sid → 2"         2 "--sid must match"             send hi --sid .daemon --queue-dir "$TMP/r"
refuse "flag without value → 2"    2 "--title requires a value"     send hi --title
eq "no case fell back to the default queue" "$([ -e "$TMP/default" ] && ls "$TMP/default" || echo none)" "none"
eq "nothing written by a refusal" "$([ -e "$TMP/r" ] && echo exists || echo absent)" "absent"
: > "$TMP/file"
refuse "unwritable queue → 1"      1 "could not append to"          send hi --queue-dir "$TMP/file/q"
out=$(node "$BIN" --help); rc=$?
eq "--help → 0, usage on stdout" "$rc $(echo "$out" | head -1)" "0 notify send <message> [--title <text>] [--sid <id>] [--queue-dir <path>]"

echo
echo "notify-cli: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
