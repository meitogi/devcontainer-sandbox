#!/usr/bin/env bash
# Tests for bin/creds-watch (the daemon that carries a refreshed token between
# ~/.claude and the shared creds volume while Claude runs), its launcher
# post-start.d/56-creds-watch.sh, the lock + atomic write of bin/sync-creds,
# and the StopFailure entry merged by post-start.d/85-merge-creds-hooks.sh.
# Standalone — no root, no network, no Docker.
# Usage: bash test/creds-watch.test.sh
#
# Everything runs against fake HOMEs in a tmp dir (LOCAL_DIR / SHARED_DIR); the
# real /home/node/.claude-creds volume is never read or written. Payloads are
# asserted exactly on the RECEIVING side (accessToken + expiresAt): a file that
# changed with the wrong token in it is the defect this daemon can cause.
#
# The inotify cases need inotifywait (baked from 1.10). Without it they are
# reported as skipped, not passed — the image replay of this suite runs them.
# Every daemon started here is killed by the EXIT trap.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS_DIR/.." && pwd)"
BIN="$REPO/bin"
CW="$BIN/creds-watch"
HOOK56="$REPO/assets/opt/hooks/post-start.d/56-creds-watch.sh"
HOOK85="$REPO/assets/opt/hooks/post-start.d/85-merge-creds-hooks.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  ❌ $1"; echo "      expected: $3"; echo "      actual:   $2"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || ko "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); echo "  ⊘ $1 (skipped: $2)"; }

# Under /tmp whatever TMPDIR says: run-all / release-check point TMPDIR into
# /workspace for the dind suites, and flock is a no-op there
# (knowledge/workspace-mount.md) — every lock case would pass or fail by
# accident. This suite mounts nothing into Docker, so it needs no TMPDIR.
TMP=$(mktemp -d /tmp/creds-watch-test.XXXXXX)
cleanup() {
  local f
  for f in "$TMP"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  pkill -f "$TMP" 2>/dev/null    # the inotifywait children, by the dirs they watch
  sleep 0.2
  rm -rf "$TMP"
}
trap cleanup EXIT
( flock -n 9 && ! flock -n "$TMP/.probe" true ) 9>"$TMP/.probe" \
  || { echo "❌ flock does not exclude under $TMP — the lock cases cannot be measured here"; exit 1; }

export TZ=UTC PATH="$BIN:$PATH"
unset LOCAL_CRED SHARED_CRED VERBOSE DEBUG CREDS_WATCH CREDS_WATCH_POLL CREDS_WATCH_TICK

HAS_INW=0; command -v inotifywait >/dev/null 2>&1 && HAS_INW=1

FUT=4070952000000            # 2099-01-01 12:00 UTC
H=3600000

jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1]))
except Exception:
    print('<unreadable>'); sys.exit()
for k in sys.argv[2].split('.'):
    if not isinstance(v, dict) or k not in v:
        print('<absent>'); sys.exit()
    v = v[k]
print(v)
PY
}
creds() {  # creds <file> <token> <expiresAt-ms>
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"ref-%s","expiresAt":%s}}\n' "$2" "$2" "$3" > "$1"
}
creds_mv() {  # same, written the way a careful writer does: tmp then rename
  creds "$1.tmp-writer" "$2" "$3" && mv -f "$1.tmp-writer" "$1"
}
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# wait_tok <timeout-s> <file> <token> — prints the latency in ms, fails on timeout
wait_tok() {
  local t0 dl
  t0=$(now_ms); dl=$((t0 + $1 * 1000))
  while :; do
    if [ "$(jget "$2" claudeAiOauth.accessToken)" = "$3" ]; then echo $(( $(now_ms) - t0 )); return 0; fi
    [ "$(now_ms)" -ge "$dl" ] && { echo "timeout"; return 1; }
    sleep 0.05
  done
}
# wait_log <timeout-s> <log> <pattern> — until the daemon has logged it
wait_log() {
  local i
  for ((i = 0; i < $1 * 20; i++)); do grep -q "$3" "$2" 2>/dev/null && return 0; sleep 0.05; done
  return 1
}
# home <name> — a fresh pair of volumes, default's token on both sides
home() {
  L="$TMP/$1/local"; S="$TMP/$1/shared"; mkdir -p "$L" "$S"
  creds "$S/.credentials.json" tok-d1 "$FUT"; cp "$S/.credentials.json" "$L/.credentials.json"
  PIDF="$TMP/$1.pid"; LOGF="$TMP/$1.log"
}
# daemons_on <local-dir> — creds-watch processes started on that home
daemons_on() {
  local p n=0
  for p in $(pgrep -f "$CW"); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qxF "LOCAL_DIR=$1" && n=$((n + 1))
  done
  echo "$n"
}
# start_daemon [VAR=value …] — creds-watch on the current home, detached
start_daemon() {
  env LOCAL_DIR="$L" SHARED_DIR="$S" CREDS_WATCH_PIDFILE="$PIDF" "$@" setsid "$CW" </dev/null >>"$LOGF" 2>&1 &
  wait_log 5 "$LOGF" "watching\|polling" || echo "    (daemon did not report ready: $(cat "$LOGF"))"
}

echo "== sync-creds: atomic write, lock on the volume =="
home atomic
creds "$S/.credentials.json" tok-a2 "$((FUT + H))"
LOCAL_DIR="$L" SHARED_DIR="$S" sh "$BIN/sync-creds"; RC=$?
eq "sync-creds (sh) exits 0" "$RC" "0"
eq "local got the exact token" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-a2"
eq "local got the exact expiresAt" "$(jget "$L/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + H))"
eq "local creds are 600" "$(stat -c %a "$L/.credentials.json")" "600"
eq "no tmp file left on either side" "$(ls -A "$L" "$S" | grep -c '\.tmp\.')" "0"
eq "the lock sits at the volume root" "$([ -f "$S/.sync-creds.lock" ] && echo yes || echo no)" "yes"

# A sync arriving while another holds the lock waits for it, then decides on
# what the holder left — never on what it saw before.
( flock 9; sleep 1.5; creds "$S/.credentials.json" tok-a3 "$((FUT + 2 * H))" ) 9>>"$S/.sync-creds.lock" &
HOLDER=$!; sleep 0.3
T0=$(now_ms); LOCAL_DIR="$L" SHARED_DIR="$S" sh "$BIN/sync-creds"; T1=$(now_ms); wait "$HOLDER"
eq "a held lock makes sync-creds wait" "$([ $((T1 - T0)) -ge 1000 ] && echo waited || echo "no wait ($((T1 - T0)) ms)")" "waited"
eq "…then it syncs what the holder wrote" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-a3"

# What Claude Code 2.1.280 leaves on disk after a refresh it could not recover
# (measured: the StopFailure authentication_failed path empties the file). The
# StopFailure hook then runs sync-creds: the volume's token must come back,
# and the emptied file must never go to the volume.
home wiped
creds "$S/.credentials.json" tok-fresh "$((FUT + H))"
printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":["user:inference"],"subscriptionType":"max"}}\n' > "$L/.credentials.json"
LOCAL_DIR="$L" SHARED_DIR="$S" sh "$BIN/sync-creds"
eq "a file emptied by a failed refresh gets the volume's token back" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-fresh"
eq "…and the volume keeps it (the empty file is never pushed)" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-fresh"

echo "== the switch race: a sync during claude-account use =="
# use holds the lock from writing .active-account to swapping the local creds.
# A sync that starts before the switch must resolve the slot AFTER it gets the
# lock: resolved before, it would compare perso's token with the root's and
# push it over default's.
home race
mkdir -p "$S/accounts/perso"; creds "$S/accounts/perso/.credentials.json" tok-p1 "$((FUT + H))"
(
  flock 9
  sleep 0.8                                   # the sync below starts meanwhile
  printf 'perso\n' > "$L/.active-account"
  cp "$S/accounts/perso/.credentials.json" "$L/.credentials.json"
) 9>>"$S/.sync-creds.lock" &
HOLDER=$!; sleep 0.3
LOCAL_DIR="$L" SHARED_DIR="$S" sh "$BIN/sync-creds"; wait "$HOLDER"
eq "perso's slot still holds perso's token" "$(jget "$S/accounts/perso/.credentials.json" claudeAiOauth.accessToken)" "tok-p1"
eq "root still holds default's token" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-d1"
# …and use really takes that lock: held elsewhere, use waits for it. A copy
# with no sync-creds beside it or on PATH, or its step 1 (which waits on the
# same lock) would hide whether use itself does.
home uselock
mkdir -p "$S/accounts/perso" "$TMP/solo"; creds "$S/accounts/perso/.credentials.json" tok-p1 "$FUT"
cp "$BIN/claude-account" "$TMP/solo/"
( flock 9; sleep 1.5 ) 9>>"$S/.sync-creds.lock" &
HOLDER=$!; sleep 0.3
T0=$(now_ms); PATH=/usr/bin:/bin LOCAL_DIR="$L" SHARED_DIR="$S" "$TMP/solo/claude-account" use perso --yes >/dev/null 2>&1; T1=$(now_ms); wait "$HOLDER"
eq "claude-account use waits for the sync lock" "$([ $((T1 - T0)) -ge 1000 ] && echo waited || echo "no wait ($((T1 - T0)) ms)")" "waited"
eq "…then switches" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-p1"
# A lock still busy after 10 s: use refuses rather than switch unlocked.
home usebusy
mkdir -p "$S/accounts/perso"; creds "$S/accounts/perso/.credentials.json" tok-p1 "$FUT"
( flock 9; sleep 12 ) 9>>"$S/.sync-creds.lock" &
HOLDER=$!; sleep 0.3
OUT=$(PATH=/usr/bin:/bin LOCAL_DIR="$L" SHARED_DIR="$S" "$TMP/solo/claude-account" use perso --yes 2>&1); RC=$?
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
eq "a lock busy past 10 s: use exits 1" "$RC" "1"
case "$OUT" in *"was not switched"*) ok "…and says it did not switch" ;; *) ko "…and says it did not switch" "$OUT" "…the account was not switched)" ;; esac
eq "….active-account untouched" "$([ -e "$L/.active-account" ] && echo present || echo absent)" "absent"
eq "…local creds untouched" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-d1"

echo "== creds-watch with inotify =="
if [ "$HAS_INW" = 1 ]; then
  home inw
  start_daemon
  creds "$S/.credentials.json" tok-d2 "$((FUT + H))"
  MS=$(wait_tok 2 "$L/.credentials.json" tok-d2)
  eq "shared→local in < 2 s (direct write)" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  eq "…exact expiresAt" "$(jget "$L/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + H))"
  creds_mv "$S/.credentials.json" tok-d3 "$((FUT + 2 * H))"
  MS=$(wait_tok 2 "$L/.credentials.json" tok-d3)
  eq "shared→local in < 2 s (tmp + mv write)" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  eq "…exact expiresAt" "$(jget "$L/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + 2 * H))"
  creds "$L/.credentials.json" tok-d4 "$((FUT + 3 * H))"
  MS=$(wait_tok 2 "$S/.credentials.json" tok-d4)
  eq "local→shared in < 2 s" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  eq "…exact expiresAt" "$(jget "$S/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + 3 * H))"
  sleep 0.5
  eq "its own copies do not loop (one sync per write)" \
     "$(grep -c 'synced' "$LOGF")" "3"

  FIRST=$(cat "$PIDF")
  OUT=$(LOCAL_DIR="$L" SHARED_DIR="$S" CREDS_WATCH_PIDFILE="$PIDF" timeout 5 "$CW" 2>&1); RC=$?
  eq "a second start exits 0" "$RC" "0"
  case "$OUT" in *"already running (pid $FIRST)"*) ok "…and says already running" ;; *) ko "…and says already running" "$OUT" "…already running (pid $FIRST)" ;; esac
  eq "the first daemon is still the one" "$(cat "$PIDF"):$(kill -0 "$FIRST" 2>/dev/null && echo alive)" "$FIRST:alive"
  eq "…one daemon on that home" "$(daemons_on "$L")" "1"

  echo "== creds-watch follows claude-account use =="
  mkdir -p "$S/accounts/perso"; creds "$S/accounts/perso/.credentials.json" tok-p1 "$((FUT + 4 * H))"
  LOCAL_DIR="$L" SHARED_DIR="$S" claude-account use perso --yes >/dev/null 2>&1
  wait_log 3 "$LOGF" "account switched" && ok "the switch is seen" || ko "the switch is seen" "$(tail -3 "$LOGF")" "…account switched"
  wait_log 3 "$LOGF" "watching $L $S/accounts/perso" && ok "…and the new slot is watched" || ko "…and the new slot is watched" "$(tail -3 "$LOGF")" "watching $L $S/accounts/perso"
  creds_mv "$S/accounts/perso/.credentials.json" tok-p2 "$((FUT + 5 * H))"
  MS=$(wait_tok 2 "$L/.credentials.json" tok-p2)
  eq "a write in accounts/perso/ reaches local in < 2 s" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  eq "…exact expiresAt" "$(jget "$L/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + 5 * H))"
  creds_mv "$S/.credentials.json" tok-d9 "$((FUT + 9 * H))"
  sleep 2
  eq "a write in the root does NOT reach local" "$(jget "$L/.credentials.json" claudeAiOauth.accessToken)" "tok-p2"
  eq "…and the root keeps it (nothing pushed back over it)" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-d9"
  kill "$(cat "$PIDF")" 2>/dev/null

  echo "== a slot that appears after the first /login =="
  home login
  start_daemon CREDS_WATCH_TICK=1
  LOCAL_DIR="$L" SHARED_DIR="$S" claude-account use work --yes >/dev/null 2>&1
  wait_log 3 "$LOGF" "account switched" || true
  creds "$L/.credentials.json" tok-w1 "$FUT"      # what /login writes
  MS=$(wait_tok 3 "$S/accounts/work/.credentials.json" tok-w1)
  eq "the new login is filed into accounts/work/" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  wait_log 4 "$LOGF" "watching $L $S/accounts/work" && ok "the new slot dir gets watched on a tick" || ko "the new slot dir gets watched on a tick" "$(tail -3 "$LOGF")" "watching $L $S/accounts/work"
  creds_mv "$S/accounts/work/.credentials.json" tok-w2 "$((FUT + H))"
  MS=$(wait_tok 2 "$L/.credentials.json" tok-w2)
  eq "…and its next refresh reaches local in < 2 s" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
  eq "root untouched by the work account" "$(jget "$S/.credentials.json" claudeAiOauth.accessToken)" "tok-d1"
  kill "$(cat "$PIDF")" 2>/dev/null
else
  for t in "shared→local in < 2 s (direct, tmp + mv)" "local→shared in < 2 s" "no loop" \
           "a second start is refused" "follows claude-account use" "a slot that appears after /login"; do
    skip "$t" "inotifywait not installed — runs in the 1.10 image"
  done
fi

echo "== creds-watch, forced poll (CREDS_WATCH_POLL=1) =="
home poll
start_daemon CREDS_WATCH_POLL=1
creds "$S/.credentials.json" tok-d2 "$((FUT + H))"
MS=$(wait_tok 10 "$L/.credentials.json" tok-d2)
eq "shared→local in < 10 s by polling" "$( [ "$MS" != timeout ] && echo ok || echo timeout)" "ok"
eq "…exact expiresAt" "$(jget "$L/.credentials.json" claudeAiOauth.expiresAt)" "$((FUT + H))"
kill "$(cat "$PIDF")" 2>/dev/null

echo "== post-start.d/56 =="
home hook
h56() { env LOCAL_DIR="$L" SHARED_DIR="$S" CREDS_WATCH_PIDFILE="$PIDF" CREDS_WATCH_LOG="$LOGF" DEVC_ENV_FILE="$TMP/env" "$@" bash "$HOOK56" 2>&1; }
: > "$TMP/env"
eq "CREDS_WATCH=0: skipped" "$(h56 CREDS_WATCH=0)" "creds-watch skipped (CREDS_WATCH=0)"
eq "…no daemon" "$([ -f "$PIDF" ] && echo started || echo none)" "none"
eq "no creds volume: skipped" "$(h56 SHARED_DIR="$TMP/nope")" "creds-watch skipped (no shared creds volume at $TMP/nope)"
printf 'ANTHROPIC_BASE_URL=http://ollama.internal:11434\n' > "$TMP/env"
eq "local Ollama mode: skipped" "$(h56)" "creds-watch skipped (local Ollama mode)"
eq "…no daemon" "$([ -f "$PIDF" ] && echo started || echo none)" "none"
printf '# ANTHROPIC_BASE_URL=http://ollama.internal:11434\n' > "$TMP/env"
OUT=$(h56); RC=$?
case "$OUT" in "✓ creds-watch started (pid "*) ok "cloud mode: started" ;; *) ko "cloud mode: started" "$OUT" "✓ creds-watch started (pid …)" ;; esac
eq "…exit 0" "$RC" "0"
wait_log 5 "$LOGF" "watching\|polling" || true
eq "a second run starts nothing" "$(h56)" "✓ creds-watch already running (pid $(cat "$PIDF"))"
eq "…one daemon on that home" "$(daemons_on "$L")" "1"
kill "$(cat "$PIDF")" 2>/dev/null

echo "== post-start.d/85: the StopFailure entry =="
if [ -x /usr/local/bin/sync-creds ] || [ -x /workspace/.devcontainer/claude/sync-creds.sh ]; then
  D85="$TMP/h85"; mkdir -p "$D85"
  LOCAL_DIR="$D85" bash "$HOOK85" >/dev/null 2>&1
  hooks() {
    python3 - "$D85/settings.json" "$1" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))['hooks'].get(sys.argv[2], [])
print(';'.join('%s=%s' % (e.get('matcher'), ','.join(x['command'] for x in e['hooks'])) for e in h))
PY
  }
  CMD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"][0]["command"])' "$D85/settings.json")
  case "$CMD" in "sh "*sync-creds*) ok "the registered command is sh <sync-creds>" ;; *) ko "the registered command is sh <sync-creds>" "$CMD" "sh …sync-creds…" ;; esac
  eq "StopFailure: matcher authentication_failed, runs sync-creds" "$(hooks StopFailure)" "authentication_failed=$CMD"
  eq "Stop unchanged (matcher empty)" "$(hooks Stop)" "=$CMD"
  eq "SessionEnd unchanged (matcher empty)" "$(hooks SessionEnd)" "=$CMD"
  BEFORE=$(sha256sum < "$D85/settings.json")
  OUT=$(LOCAL_DIR="$D85" bash "$HOOK85" 2>&1)
  eq "a second run changes nothing" "$(sha256sum < "$D85/settings.json")" "$BEFORE"
  eq "…and says so" "$OUT" "✓ creds-sync hooks already registered"
else
  skip "post-start.d/85 StopFailure entry" "no sync-creds installed for the hook to register"
fi

echo
echo "creds-watch: $PASS pass / $FAIL fail / $SKIP skipped"
[ "$FAIL" -eq 0 ]
