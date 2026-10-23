#!/usr/bin/env bash
# Tests for bin/vscode-logs-mirror (the loop that copies ~/.vscode-server/data/logs
# into .devcontainer/tmp/vscode-logs/container/ so a Rebuild does not take the
# crashed session's logs with it) and its launcher post-start.d/58.
# Standalone — no root, no network, no Docker. Needs rsync and flock.
# Usage: bash test/vscode-logs-mirror.test.sh
#
# Everything runs against a fake SRC / DST under a tmp dir ; the real
# ~/.vscode-server is never read. The defect this daemon can cause is a stale
# or missing copy, so every case reads the destination bytes back.
# Every daemon started here is killed by the EXIT trap.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
BIN="$REPO/bin"
MIRROR="$BIN/vscode-logs-mirror"
HOOK58="$REPO/assets/opt/hooks/post-start.d/58-vscode-logs-mirror.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }

# Under /tmp whatever TMPDIR says : flock is a no-op on the workspace mount
# (knowledge/workspace-mount.md), and the singleton cases need a real lock.
TMP=$(mktemp -d /tmp/vscode-logs-mirror-test.XXXXXX)
cleanup() {
  local f
  for f in "$TMP"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  sleep 0.2
  rm -rf "$TMP"
}
trap cleanup EXIT
( flock -n 9 && ! flock -n "$TMP/.probe" true ) 9>"$TMP/.probe" \
  || { echo "❌ flock does not exclude under $TMP — the singleton cases cannot be measured here"; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "❌ rsync not installed — this suite needs it"; exit 1; }

export TZ=UTC PATH="$BIN:$PATH"
unset VSCODE_LOGS_MIRROR VSCODE_LOGS_TICK VSCODE_LOGS_KEEP DEBUG

SRC="$TMP/src"; DST="$TMP/dst"
export VSCODE_LOGS_SRC="$SRC" VSCODE_LOGS_DST="$DST" VSCODE_LOGS_PIDFILE="$TMP/mirror.pid" VSCODE_LOGS_LOG="$TMP/mirror.log"

session() {   # session <name> <body>
  mkdir -p "$SRC/$1/exthost1"
  printf '%s remoteagent\n' "$2" > "$SRC/$1/remoteagent.log"
  printf '%s exthost\n' "$2" > "$SRC/$1/exthost1/remoteexthost.log"
}

echo "== --once : copy, update, prune =="
session 20260101T000000 one
session 20260102T000000 two
touch "$SRC/20260102T000000/vscode.sock"
out=$("$MIRROR" --once 2>&1)
eq "first pass copies every session, bytes identical" \
   "$(cat "$DST/20260101T000000/remoteagent.log" "$DST/20260102T000000/exthost1/remoteexthost.log")" \
   "one remoteagent
two exthost"
eq "a socket is not mirrored" "$([ -e "$DST/20260102T000000/vscode.sock" ] && echo present || echo absent)" absent
eq "the pass says what it changed" "$(echo "$out" | grep -c 'path(s) updated')" 1

out=$("$MIRROR" --once 2>&1)
eq "an unchanged tree is a silent pass" "$out" ""

sleep 1.1   # past the 1 s modify-window, so the grown file differs by mtime too
printf 'two remoteagent again\n' >> "$SRC/20260102T000000/remoteagent.log"
"$MIRROR" --once >/dev/null 2>&1
eq "a grown log is recopied" "$(cat "$DST/20260102T000000/remoteagent.log")" "two remoteagent
two remoteagent again"

session 20260103T000000 three
session 20260104T000000 four
out=$(VSCODE_LOGS_KEEP=2 "$MIRROR" --once 2>&1)
eq "KEEP prunes the destination to the newest sessions" "$(ls "$DST" | tr '\n' ' ')" "20260103T000000 20260104T000000 "
eq "…and says so" "$(echo "$out" | grep -c 'pruned 2 session(s)')" 1
eq "the source is never touched by the prune" "$(ls "$SRC" | wc -l)" 4

echo "== the loop : singleton, ticks =="
VSCODE_LOGS_TICK=1 "$MIRROR" >"$TMP/loop.out" 2>&1 &
LOOP=$!
sleep 0.5
eq "the daemon claims the pidfile" "$(cat "$TMP/mirror.pid")" "$LOOP"
out=$("$MIRROR" 2>&1); rc=$?
eq "a second start exits 0 with already running" "$rc $(echo "$out" | grep -o 'already running (pid [0-9]*)')" "0 already running (pid $LOOP)"
session 20260105T000000 five
sleep 2.5
eq "a session created while it runs is mirrored within a tick" "$(cat "$DST/20260105T000000/remoteagent.log" 2>/dev/null)" "five remoteagent"
kill "$(cat "$TMP/mirror.pid")"; sleep 0.3

echo "== post-start.d/58 =="
ENV_FILE="$TMP/env"; export DEVC_ENV_FILE="$ENV_FILE"
: > "$ENV_FILE"
out=$(bash "$HOOK58" 2>&1); rc=$?
eq "skips without the key" "$rc $out" "0 vscode-logs-mirror skipped (VSCODE_LOGS_MIRROR=1 not in .env)"
printf '#VSCODE_LOGS_MIRROR=1\n' > "$ENV_FILE"
out=$(bash "$HOOK58" 2>&1)
eq "a commented key is still off" "$out" "vscode-logs-mirror skipped (VSCODE_LOGS_MIRROR=1 not in .env)"
printf 'OTHER=1\nVSCODE_LOGS_MIRROR=1\n' > "$ENV_FILE"
out=$(bash "$HOOK58" 2>&1); rc=$?
eq "starts the daemon with the key" "$rc $(echo "$out" | sed -E 's/pid [0-9]+/pid N/')" "0 ✓ vscode-logs-mirror started (pid N, log $TMP/mirror.log)"
sleep 0.5
pid=$(cat "$TMP/mirror.pid")
eq "the daemon it started is alive and logging" "$(kill -0 "$pid" 2>/dev/null && echo alive) $(grep -c 'mirroring' "$TMP/mirror.log")" "alive 1"
out=$(bash "$HOOK58" 2>&1)
eq "a second run starts nothing" "$out" "✓ vscode-logs-mirror already running (pid $pid)"
eq "one daemon on that pidfile" "$(pgrep -f "vscode-logs-mirror" | grep -c "^$pid\$")" 1

echo
echo "vscode-logs-mirror: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
