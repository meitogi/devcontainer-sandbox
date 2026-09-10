#!/usr/bin/env bash
# @name claude-onboarding
# @phase post-start
# @required false
# @description Pre-configure Claude CLI to skip onboarding wizard (theme + completed flag).

set -eE

CLAUDE_JSON="/home/node/.claude/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
changed = False
if not d.get('hasCompletedOnboarding'):
    d['hasCompletedOnboarding'] = True
    changed = True
if not d.get('theme'):
    d['theme'] = 'dark'
    changed = True
if changed:
    with open(sys.argv[1], 'w') as f:
        json.dump(d, f)
    print('✓ Claude CLI pre-configured (onboarding + theme).')
" "$CLAUDE_JSON"
fi
