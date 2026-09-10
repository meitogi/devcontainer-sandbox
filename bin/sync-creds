#!/bin/bash
# Bidirectional sync of Claude Code .credentials.json between:
#   - local  /home/node/.claude/.credentials.json       (per-project volume)
#   - shared /home/node/.claude-creds/.credentials.json (external volume, shared across projects)
#
# Decision rule: copy from the side whose OAuth access token has the higher
# expiresAt (most recently refreshed token wins). Same-token => no-op.
# Both valid but different tokens => flag /tmp/.claude-creds-conflict for
# interactive resolution at next terminal open.
#
# Modes:
#   (default)         silent — used by Claude Code hooks (Stop / SessionEnd)
#   --verbose / VERBOSE=1   prints the usual "✓ Credentials synced..." line
#   DEBUG=1           prints decision details to stderr
#
# Always exits 0 so a hook failure never blocks Claude.

set +e

LOCAL_CRED="${LOCAL_CRED:-/home/node/.claude/.credentials.json}"
SHARED_CRED="${SHARED_CRED:-/home/node/.claude-creds/.credentials.json}"

if [ "${1:-}" = "--verbose" ] || [ "${VERBOSE:-0}" = "1" ]; then
  VERBOSE=1
else
  VERBOSE=0
fi

log()   { [ "$VERBOSE" = "1" ] && echo "$*"; return 0; }
debug() { [ "${DEBUG:-0}" = "1" ] && echo "[sync-creds] $*" >&2; return 0; }

# Bail silently if python3 is missing (nothing we can do — JSON parse required)
command -v python3 >/dev/null 2>&1 || { debug "python3 missing, skipping"; exit 0; }

# Decide action: same | local-newer | shared-newer | conflict | none
ACTION=$(python3 -c "
import json, os, sys, time

local, shared = sys.argv[1], sys.argv[2]
lx = os.path.isfile(local)
sx = os.path.isfile(shared)
if not lx and not sx:
    print('none'); sys.exit()
if lx and not sx:
    print('local-only'); sys.exit()
if sx and not lx:
    print('shared-only'); sys.exit()

try:
    with open(local) as f:  l = json.load(f).get('claudeAiOauth', {})
    with open(shared) as f: s = json.load(f).get('claudeAiOauth', {})
except Exception as e:
    print('same'); sys.exit()

lt = l.get('accessToken', '')
st = s.get('accessToken', '')
le = int(l.get('expiresAt', 0) or 0)
se = int(s.get('expiresAt', 0) or 0)
now = int(time.time() * 1000)
lv = le > now
sv = se > now

if lt and lt == st:
    print('same')
elif le > se and lv:
    print('local-newer')
elif se > le and sv:
    print('shared-newer')
elif lv and sv and lt != st:
    print('conflict')
else:
    print('same')
" "$LOCAL_CRED" "$SHARED_CRED" 2>/dev/null)

debug "action=$ACTION local=$LOCAL_CRED shared=$SHARED_CRED"

case "$ACTION" in
  same)
    log "✓ Credentials already in sync"
    ;;
  local-newer)
    cp "$LOCAL_CRED" "$SHARED_CRED" 2>/dev/null && \
      log "✓ Credentials synced to shared (token refreshed)"
    ;;
  shared-newer)
    cp "$SHARED_CRED" "$LOCAL_CRED" 2>/dev/null && \
      chmod 600 "$LOCAL_CRED" 2>/dev/null && \
      log "✓ Credentials synced from shared (newer token)"
    ;;
  local-only)
    cp "$LOCAL_CRED" "$SHARED_CRED" 2>/dev/null && \
      log "✓ Credentials saved to shared volume"
    ;;
  shared-only)
    mkdir -p "$(dirname "$LOCAL_CRED")" 2>/dev/null
    cp "$SHARED_CRED" "$LOCAL_CRED" 2>/dev/null && \
      chmod 600 "$LOCAL_CRED" 2>/dev/null && \
      log "✓ Credentials restored from shared volume"
    ;;
  conflict)
    echo "conflict" > /tmp/.claude-creds-conflict
    log "⚠️  Credentials conflict (both valid, different tokens). Open a terminal to resolve."
    ;;
  none|*)
    debug "no credentials present, nothing to sync"
    ;;
esac

exit 0
