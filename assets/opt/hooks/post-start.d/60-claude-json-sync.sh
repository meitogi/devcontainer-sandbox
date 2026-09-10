#!/usr/bin/env bash
# @name claude-json-sync
# @phase post-start
# @required false
# @description Sync .claude.json (settings/flags, no expiry) between shared volume and local — by file timestamp.

set -eE

SHARED_DIR="/home/node/.claude-creds"
LOCAL_DIR="/home/node/.claude"
CONF=".claude.json"

if [ -f "$SHARED_DIR/$CONF" ] && [ ! -f "$LOCAL_DIR/$CONF" ]; then
  cp "$SHARED_DIR/$CONF" "$LOCAL_DIR/$CONF"
  chmod 600 "$LOCAL_DIR/$CONF"
  echo "✓ $CONF restored from shared volume."
elif [ -f "$LOCAL_DIR/$CONF" ] && [ ! -f "$SHARED_DIR/$CONF" ]; then
  cp "$LOCAL_DIR/$CONF" "$SHARED_DIR/$CONF"
  echo "✓ $CONF saved to shared volume."
elif [ -f "$LOCAL_DIR/$CONF" ] && [ -f "$SHARED_DIR/$CONF" ]; then
  if [ "$LOCAL_DIR/$CONF" -nt "$SHARED_DIR/$CONF" ]; then
    cp "$LOCAL_DIR/$CONF" "$SHARED_DIR/$CONF"
    echo "✓ $CONF updated in shared volume."
  else
    cp "$SHARED_DIR/$CONF" "$LOCAL_DIR/$CONF"
    chmod 600 "$LOCAL_DIR/$CONF"
    echo "✓ $CONF restored from shared volume (newer)."
  fi
fi
