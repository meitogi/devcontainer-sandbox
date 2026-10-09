#!/usr/bin/env bash
# @name merge-creds-hooks
# @phase post-start
# @required false
# @description Merge creds-sync hooks (Stop + SessionEnd, plus StopFailure on authentication_failed) into ~/.claude/settings.json so the shared volume stays fresh whenever Claude Code refreshes the OAuth token during an active session, and a turn that fails on auth pulls the freshest token at once (StopFailure output is ignored by Claude Code: it syncs, it cannot retry). Idempotent — dedup by command, and any registered sync-creds command whose target no longer exists is pruned first (a tree that moved from the v2 workspace copy to the baked binary would otherwise keep both).

set -eE

LOCAL_DIR="${LOCAL_DIR:-/home/node/.claude}"
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
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
changed = False
pruned = 0
for event, matcher in (('Stop', ''), ('SessionEnd', ''),
                       ('StopFailure', 'authentication_failed')):
    entries = hooks.setdefault(event, [])
    # A sync-creds command registered by an earlier layout (the v2 workspace
    # copy) keeps firing after that file is gone: dedup by command string
    # never removes it. Drop every sync-creds entry whose target is missing
    # BEFORE merging, so the surviving set is exactly the commands that resolve.
    kept = []
    for entry in entries:
        hs = entry.get('hooks', [])
        live = [h for h in hs
                if not ('sync-creds' in h.get('command', '')
                        and not os.path.exists(h['command'].split()[-1]))]
        pruned += len(hs) - len(live)
        if live or not hs:
            entry['hooks'] = live if hs else hs
            kept.append(entry)
    if len(kept) != len(entries):
        entries[:] = kept
        changed = True
    seen = set()
    for entry in entries:
        for h in entry.get('hooks', []):
            if 'command' in h:
                seen.add(h['command'])
    if cmd not in seen:
        entries.append({'matcher': matcher, 'hooks': [{'type': 'command', 'command': cmd}]})
        changed = True
if changed:
    with open(path, 'w') as f:
        json.dump(s, f, indent=2)
    print('✓ creds-sync hooks merged into settings.json'
          + (' (pruned %d dead sync-creds entr%s)' % (pruned, 'y' if pruned == 1 else 'ies') if pruned else ''))
else:
    print('✓ creds-sync hooks already registered')
" "$SETTINGS" "$SYNC_CREDS_CMD"
fi
