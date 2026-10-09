#!/usr/bin/env bash
# @name claude-json-sync
# @phase post-start
# @required false
# @description Sync .claude.json (settings/flags, no expiry) between shared volume and local — by file timestamp. On a non-default claude-account, the identity keys (oauthAccount, userID) stay out of the sync both ways.

set -eE

SHARED_DIR="${SHARED_DIR:-/home/node/.claude-creds}"
LOCAL_DIR="${LOCAL_DIR:-/home/node/.claude}"
CONF=".claude.json"

# The root .claude.json carries account "default"'s identity — the one 1.9.x
# containers read. When this container is on another account (claude-account),
# everything else still syncs, but each side keeps its own oauthAccount/userID.
KEEP_IDENTITY=0
ACTIVE_CRED=$(SHARED_DIR="$SHARED_DIR" LOCAL_DIR="$LOCAL_DIR" claude-account path 2>/dev/null || true)
if [ -n "$ACTIVE_CRED" ] && [ "$ACTIVE_CRED" != "$SHARED_DIR/.credentials.json" ]; then
  KEEP_IDENTITY=1
fi

copy_conf() {
  if [ "$KEEP_IDENTITY" = 1 ]; then
    python3 - "$1" "$2" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
KEYS = ('oauthAccount', 'userID')
try:
    with open(src) as f:
        s = json.load(f)
    d = {}
    if os.path.exists(dst):
        with open(dst) as f:
            d = json.load(f)
except ValueError as e:
    # Never spread a corrupt file, never guess an identity: leave both sides.
    print('⚠ .claude.json not valid JSON (%s) — sync skipped' % e)
    sys.exit(3)
out = {k: v for k, v in s.items() if k not in KEYS}
for k in KEYS:
    if k in d:
        out[k] = d[k]
with open(dst, 'w') as f:
    json.dump(out, f, indent=2)
PY
  else
    cp "$1" "$2"
  fi
}

if [ -f "$SHARED_DIR/$CONF" ] && [ ! -f "$LOCAL_DIR/$CONF" ]; then
  copy_conf "$SHARED_DIR/$CONF" "$LOCAL_DIR/$CONF" && \
    chmod 600 "$LOCAL_DIR/$CONF" && \
    echo "✓ $CONF restored from shared volume."
elif [ -f "$LOCAL_DIR/$CONF" ] && [ ! -f "$SHARED_DIR/$CONF" ]; then
  copy_conf "$LOCAL_DIR/$CONF" "$SHARED_DIR/$CONF" && \
    echo "✓ $CONF saved to shared volume."
elif [ -f "$LOCAL_DIR/$CONF" ] && [ -f "$SHARED_DIR/$CONF" ]; then
  if [ "$LOCAL_DIR/$CONF" -nt "$SHARED_DIR/$CONF" ]; then
    copy_conf "$LOCAL_DIR/$CONF" "$SHARED_DIR/$CONF" && \
      echo "✓ $CONF updated in shared volume."
  else
    copy_conf "$SHARED_DIR/$CONF" "$LOCAL_DIR/$CONF" && \
      chmod 600 "$LOCAL_DIR/$CONF" && \
      echo "✓ $CONF restored from shared volume (newer)."
  fi
fi

# A skipped merge (corrupt JSON) has said so above; it never fails the boot.
exit 0
