#!/usr/bin/env bash
# @name merge-creds-hooks
# @phase post-start
# @required false
# @description Merge creds-sync hooks (Stop + SessionEnd) into ~/.claude/settings.json so the shared volume stays fresh whenever Claude Code refreshes the OAuth token during an active session. Idempotent — dedup by command.

set -eE

LOCAL_DIR="/home/node/.claude"
SETTINGS="$LOCAL_DIR/settings.json"
# The command registered in settings.json must be the one that will still
# resolve at Stop/SessionEnd time. Workspace copy wins (v2 layout), else the
# baked binary — otherwise a project on the published image registers a hook
# pointing at a file it does not have, and the token silently stops syncing.
SYNC_CREDS="/workspace/.devcontainer/claude/sync-creds.sh"
[ -x "$SYNC_CREDS" ] || SYNC_CREDS="/usr/local/bin/sync-creds"
SYNC_CREDS_CMD="sh $SYNC_CREDS"

if [ -x "$SYNC_CREDS" ] && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  python3 -c "
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
changed = False
for event in ('Stop', 'SessionEnd'):
    entries = hooks.setdefault(event, [])
    seen = set()
    for entry in entries:
        for h in entry.get('hooks', []):
            if 'command' in h:
                seen.add(h['command'])
    if cmd not in seen:
        entries.append({'matcher': '', 'hooks': [{'type': 'command', 'command': cmd}]})
        changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(s, f, indent=2)
    print('✓ creds-sync hooks merged into settings.json')
else:
    print('✓ creds-sync hooks already registered')
" "$SETTINGS" "$SYNC_CREDS_CMD"
fi
