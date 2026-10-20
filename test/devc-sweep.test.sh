#!/usr/bin/env bash
# Tests for bin/devc-sweep. Standalone — no root, no network, no Docker.
# Usage: bash test/devc-sweep.test.sh
#
# Everything runs against a scratch tree (TMP_ROOT / CLAUDE_TMP / LOCAL_DIR):
# the real /tmp and ~/.claude are never read or written here. Every "kept"
# case is the defect this command could cause — deleting something in use —
# so each one is asserted by the path still being there, not by the report.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
SWEEP="${SWEEP:-$REPO/bin/devc-sweep}"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko() { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
gone() { [ ! -e "$2" ] && ok "$1" || ko "$1" "still there" "removed"; }
kept() { [ -e "$2" ] && ok "$1" || ko "$1" "removed" "kept"; }

# An empty W would aim TMP_ROOT at the real /tmp and setup()'s rm -rf at /tmp.
W=$(mktemp -d) && [ -d "$W" ] || { echo "$(basename "$0"): mktemp failed (disk full?) — refusing to run on an empty path" >&2; exit 2; }
BG=""
trap 'for p in $BG; do kill "$p" 2>/dev/null; done; rm -rf "$W"' EXIT

T="$W/tmp"; C="$W/tmp/claude-1000"; L="$W/local"
export TMP_ROOT="$T" CLAUDE_TMP="$C" LOCAL_DIR="$L"

old() { find "$1" -exec touch -h -d '3 days ago' {} +; }      # idle for 3 days
ancient() { find "$1" -exec touch -h -d '40 days ago' {} +; } # past --archive-days
U1=11111111-1111-1111-1111-111111111111
U2=22222222-2222-2222-2222-222222222222
U3=33333333-3333-3333-3333-333333333333

# A live claude session as the CLI registers it: its pid, and that pid's start
# time read the same way the script reads it.
live_session() {  # <sessionId> → pid of a sleeping stand-in
  sleep 600 & local pid=$!; BG="$BG $pid"
  local start; start=$(python3 -c 'import sys;s=open("/proc/%s/stat"%sys.argv[1]).read();print(s[s.rindex(")")+2:].split()[19])' "$pid")
  mkdir -p "$L/sessions"
  printf '{"pid":%s,"sessionId":"%s","procStart":"%s","cwd":"/workspace"}\n' "$pid" "$1" "$start" > "$L/sessions/$pid.json"
}

setup() {
  rm -rf "$T" "$L"; mkdir -p "$T" "$C/-workspace" "$L/projects/-workspace"
  # tmp: mkdtemp-shaped and idle → candidate
  mkdir -p "$T/bot-exos-AbC123/deep"; echo x > "$T/bot-exos-AbC123/deep/f"; old "$T/bot-exos-AbC123"
  mkdir -p "$T/tmp.AbCdEf1234"; old "$T/tmp.AbCdEf1234"
  # tmp: idle dir with ONE recent file deep inside → kept
  mkdir -p "$T/recent-XyZ789/a/b"; old "$T/recent-XyZ789"; echo y > "$T/recent-XyZ789/a/b/new"
  # tmp: not mkdtemp-shaped → kept whatever its age
  mkdir -p "$T/node-compile-cache" "$T/vscode-git-4ed88fbb87"; old "$T/node-compile-cache"; old "$T/vscode-git-4ed88fbb87"
  # tmp: a FILE with a mkdtemp-shaped name → kept (directories only)
  echo z > "$T/notadir-QwE456"; touch -d '3 days ago' "$T/notadir-QwE456"
  # tmp: idle but a process sits in it → kept
  mkdir -p "$T/busy-Busy01"; old "$T/busy-Busy01"
  (cd "$T/busy-Busy01" && exec sleep 600) & BG="$BG $!"
  # scratch: ended session, idle → candidate ; live session, idle → kept
  mkdir -p "$C/-workspace/$U1/scratchpad"; echo s > "$C/-workspace/$U1/scratchpad/s"; old "$C/-workspace/$U1"
  mkdir -p "$C/-workspace/$U2/scratchpad"; old "$C/-workspace/$U2"
  live_session "$U2"
  # scratch: a non-session neighbour → kept
  mkdir -p "$C/bash-edit-diff"; old "$C/bash-edit-diff"
  # transcripts: ancient + side dir → archived ; ancient but live → kept ; recent → kept
  P="$L/projects/-workspace"
  printf '{"a":1}\n{"b":2}\n' > "$P/$U1.jsonl"; mkdir -p "$P/$U1/subagents"; echo sub > "$P/$U1/subagents/x.jsonl"
  ancient "$P/$U1.jsonl"; ancient "$P/$U1"
  echo '{}' > "$P/$U2.jsonl"; ancient "$P/$U2.jsonl"
  echo '{}' > "$P/$U3.jsonl"
  sleep 0.3  # let the busy sleeper chdir before the scan
}

echo "devc-sweep"
bash -n "$SWEEP" && ok "parses" || ko "parses" "syntax error" "parses"

echo "-- report only"
setup
OUT=$("$SWEEP" 2>&1); RC=$?
[ "$RC" = 0 ] && ok "exits 0" || ko "exits 0" "$RC" "0"
kept "report touches nothing: tmp candidate"        "$T/bot-exos-AbC123"
kept "report touches nothing: scratch candidate"    "$C/-workspace/$U1"
kept "report touches nothing: transcript"           "$L/projects/-workspace/$U1.jsonl"
echo "$OUT" | grep -q "bot-exos-AbC123" && ok "report lists the tmp candidate" || ko "report lists the tmp candidate" "$OUT" "bot-exos-AbC123"
echo "$OUT" | grep -q "$U2" && ko "report never lists the live session" "$U2 listed" "absent" || ok "report never lists the live session"
echo "$OUT" | grep -qF 'run `devc-sweep --apply`' && ok "the hint names devc-sweep by default" || ko "the hint names devc-sweep by default" "$OUT" 'run `devc-sweep --apply`'
OUT=$(DEVC_SWEEP_APPLY_HINT="wtf cleanup --apply" DEVC_SWEEP_SUMMARY=1 "$SWEEP" 2>&1)
echo "$OUT" | grep -qF 'run `wtf cleanup --apply`' && ok "a wrapper can name its own command" || ko "a wrapper can name its own command" "$OUT" 'run `wtf cleanup --apply`'
got=$(echo "$OUT" | tail -1 | sed -E 's/=([0-9]+):[0-9]+/=\1/g')
[ "$got" = "@@devc-sweep tmp=2 scratch=1 archive=1" ] && ok "the wrapper summary line counts each kind" || ko "the wrapper summary line counts each kind" "$got" "@@devc-sweep tmp=2 scratch=1 archive=1"

echo "-- apply"
OUT=$("$SWEEP" --apply 2>&1); RC=$?
[ "$RC" = 0 ] && ok "exits 0" || ko "exits 0" "$RC — $OUT" "0"
gone "idle mkdtemp dir removed"                     "$T/bot-exos-AbC123"
gone "idle tmp.XXXXXXXXXX dir removed"              "$T/tmp.AbCdEf1234"
kept "one recent file deep inside keeps the dir"    "$T/recent-XyZ789/a/b/new"
kept "a name without mkdtemp's shape is kept"       "$T/node-compile-cache"
kept "a vscode socket dir is kept"                  "$T/vscode-git-4ed88fbb87"
kept "a FILE with a mkdtemp name is kept"           "$T/notadir-QwE456"
kept "a dir a process sits in is kept"              "$T/busy-Busy01"
kept "the CLAUDE_TMP root itself is kept"           "$C"
gone "ended session's scratch dir removed"          "$C/-workspace/$U1"
kept "live session's scratch dir is kept"           "$C/-workspace/$U2"
kept "a non-session dir in CLAUDE_TMP is kept"      "$C/bash-edit-diff"
P="$L/projects/-workspace"; A="$L/archive/projects/-workspace"
gone "ancient transcript moved out of /resume"      "$P/$U1.jsonl"
gone "…with its side dir"                           "$P/$U1"
kept "…into an archive"                             "$A/$U1.tar.gz"
kept "ancient but live transcript is kept"          "$P/$U2.jsonl"
kept "recent transcript is kept"                    "$P/$U3.jsonl"

echo "-- restore"
OUT=$("$SWEEP" list-archived 2>&1)
echo "$OUT" | grep -q "$U1" && ok "list-archived names it" || ko "list-archived names it" "$OUT" "$U1"
OUT=$("$SWEEP" restore 1111 2>&1); RC=$?
[ "$RC" = 0 ] && ok "restore by id prefix exits 0" || ko "restore by id prefix exits 0" "$RC — $OUT" "0"
got=$(cat "$P/$U1.jsonl" 2>/dev/null)
[ "$got" = "$(printf '{"a":1}\n{"b":2}')" ] && ok "transcript is byte-identical" || ko "transcript is byte-identical" "$got" '{"a":1} {"b":2}'
[ "$(cat "$P/$U1/subagents/x.jsonl" 2>/dev/null)" = sub ] && ok "side dir restored" || ko "side dir restored" "missing" "sub"
gone "the archive is consumed"                      "$A/$U1.tar.gz"

echo "-- refusals"
"$SWEEP" --apply >/dev/null 2>&1        # archive U1 again
echo '{"new":1}' > "$P/$U1.jsonl"       # a transcript reappears under the same id
OUT=$("$SWEEP" restore "$U1" 2>&1); RC=$?
[ "$RC" != 0 ] && ok "restore refuses to overwrite" || ko "restore refuses to overwrite" "rc 0" "non-zero"
[ "$(cat "$P/$U1.jsonl")" = '{"new":1}' ] && ok "…and the existing transcript is untouched" || ko "…and the existing transcript is untouched" "$(cat "$P/$U1.jsonl")" '{"new":1}'
OUT=$("$SWEEP" restore 9999 2>&1); RC=$?
[ "$RC" != 0 ] && ok "unknown id is refused" || ko "unknown id is refused" "rc 0" "non-zero"

# A failed archive must leave the originals where they were.
setup
mkdir -p "$L/archive/projects/-workspace"; chmod 500 "$L/archive/projects/-workspace"
OUT=$("$SWEEP" --apply 2>&1); RC=$?
chmod 700 "$L/archive/projects/-workspace"
[ "$RC" != 0 ] && ok "a failed archive exits non-zero" || ko "a failed archive exits non-zero" "rc 0" "non-zero"
kept "a failed archive keeps the transcript"        "$L/projects/-workspace/$U1.jsonl"
kept "…and its side dir"                            "$L/projects/-workspace/$U1/subagents/x.jsonl"

echo "-- arguments"
"$SWEEP" --bogus >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option → usage (2)" || ko "unknown option → usage (2)" "$?" "2"
"$SWEEP" --tmp-hours -1 >/dev/null 2>&1; [ $? = 2 ] && ok "negative hours → usage (2)" || ko "negative hours → usage (2)" "$?" "2"

echo
echo "devc-sweep: $PASS pass / $FAIL fail"
[ "$FAIL" = 0 ]
