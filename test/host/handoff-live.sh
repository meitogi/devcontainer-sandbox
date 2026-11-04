#!/usr/bin/env bash
# handoff-live.sh — the handoff, the keychain and headless parity on the real
# host browser, driven from the CONTAINER with this tree's agent-browser (the
# release is not out yet). The user's part happens in the window it opens, and
# the banner there says what to do.
#
# Before : on the Mac, from the workspace root, once —
#
#   bash packages/devcontainer-sandbox/assets/opt/skills/agent-browser/host/host-agent.sh install
#
# Then, in the container, from the workspace root :
#
#   bash packages/devcontainer-sandbox/test/host/handoff-live.sh [https://www.canva.com/]
#
# 1. up, headless : the user-agent and brands read in the page, no Headless ;
# 2. handoff : sign in in the window (the banner asks), Done ;
# 3. restart, headless : a capture of the page — signed in or not is read from it ;
# 4. headless-parity.mjs : the probe headless then windowed (a few seconds of
#    window, nothing to do), the reports diffed.
# Everything goes to .devcontainer/tmp/agent-browser-checks/handoff-live.log ;
# the capture beside it.
set -uo pipefail
TREE="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$TREE/bin:$PATH" DEVC_AGENT_BROWSER_KIT="$TREE/assets/opt/skills/agent-browser"
URL=${1:-https://www.canva.com/}
OUT=.devcontainer/tmp/agent-browser-checks; mkdir -p "$OUT"
LOG=$OUT/handoff-live.log; : >"$LOG"
CDP="$TREE/assets/opt/skills/visual-loop/scripts/cdp.mjs"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { say "FAIL — $*"; exit 1; }

say "== 1/4 up, headless, on $URL"
agent-browser up "$URL" >>"$LOG" 2>&1 || fail "agent-browser up (see $LOG) — is the tree's kit installed on the host ?"
ua=$(node "$CDP" eval 'JSON.stringify({ ua: navigator.userAgent, brands: navigator.userAgentData && navigator.userAgentData.brands })' 2>>"$LOG")
say "   $ua"
case $ua in *Headless*) fail "the page still sees Headless" ;; '') fail "no answer from the page (see $LOG)" ;; esac

say "== 2/4 handoff : sign in in the window, then Done"
agent-browser handoff --say "Sign in to Canva in this window (the course account), then click Done. If macOS asks for a keychain password, note it and click Cancel." 2>&1 | tee -a "$LOG"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "the handoff did not end cleanly"

say "== 3/4 restart, headless : is the session still there ?"
agent-browser restart >>"$LOG" 2>&1 || fail "restart"
node "$CDP" shot --url "$URL" --ready body --wait 30000 --out "$OUT/handoff-live-headless.png" >>"$LOG" 2>&1 || fail "the headless capture (see $LOG)"
say "   capture : $OUT/handoff-live-headless.png — signed in or not is read from it"

say "== 4/4 parity : headless against windowed"
node "$TREE/test/host/headless-parity.mjs" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
say "$([ "$rc" -eq 0 ] && echo PASS || echo 'FAIL (parity)') — log $LOG"
exit "$rc"
