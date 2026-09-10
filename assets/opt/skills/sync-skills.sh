#!/bin/bash
# Sync skills from .devcontainer/skills/ to ~/.claude/commands/
# and merge hooks from hooks.json into settings.json
# Called from post-start.sh: bash /workspace/.devcontainer/skills/sync-skills.sh

SKILLS_DIR="/workspace/.devcontainer/skills"
LOCAL_CMD="/home/node/.claude/commands"
SETTINGS="/home/node/.claude/settings.json"
BAK_DIR="/workspace/.devcontainer/claude/settings-backups"

echo "=== sync-skills $(date) ==="

# --- 1. Install skills: find all *.skill.md, copy to ~/.claude/commands/ ---
# node_modules is pruned: a skill may carry its own deps (skills/diagram does),
# and a package shipping a *.skill.md would otherwise become a live slash command.
mkdir -p "$LOCAL_CMD"
find "$SKILLS_DIR" -name "*.skill.md" -not -path '*/node_modules/*' 2>/dev/null | while read -r file; do
  base=$(basename "$file")
  # Remove .skill and .local from name: hours.local.skill.md → hours.md
  dest_name=$(echo "$base" | sed 's/\.local\.skill\.md$/.md/' | sed 's/\.skill\.md$/.md/')
  cp "$file" "$LOCAL_CMD/$dest_name"
  echo "✓ skill $dest_name installed"
done

# --- 1bis. Remove stale commands for disabled skills ---
# A skill dir is disabled if it contains *.skill.disabled.md and no active *.skill.md.
# The install glob above already skips disabled files; this pass removes any command
# left over from a previous sync that was installed before the skill was disabled.
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  disabled=$(find "$d" -maxdepth 1 -name "*.skill.disabled.md" 2>/dev/null | head -1)
  active=$(find "$d" -maxdepth 1 -name "*.skill.md" ! -name "*.skill.disabled.md" 2>/dev/null | head -1)
  if [ -n "$disabled" ] && [ -z "$active" ]; then
    skill=$(basename "$d")
    if [ -f "$LOCAL_CMD/$skill.md" ]; then
      rm "$LOCAL_CMD/$skill.md"
      echo "✗ skill $skill.md removed (disabled)"
    fi
  fi
done

# --- 2. Merge hooks from all hooks.json files ---
# Create empty settings.json if missing (Claude CLI works without it, but we need it to merge hooks)
if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
  echo "✓ created empty $SETTINGS"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import json, glob, os, re
from datetime import datetime

settings_path = '$SETTINGS'
skills_dir = '$SKILLS_DIR'
bak_dir = '$BAK_DIR'

with open(settings_path) as f:
    settings = json.load(f)

merged_hooks = settings.get('hooks', {})
changed = False

# --- Detect disabled skills (dir has *.skill.disabled.md, no active *.skill.md) ---
disabled_skills = set()
for d in glob.glob(os.path.join(skills_dir, '*/')):
    if glob.glob(os.path.join(d, '*.skill.disabled.md')) and not glob.glob(os.path.join(d, '*.skill.md')):
        disabled_skills.add(os.path.basename(os.path.dirname(d)))

# --- Merge hooks.json from every skill (skip disabled) ---
for hf in glob.glob(os.path.join(skills_dir, '**/hooks.json'), recursive=True):
    # Same prune as the find above, and it matters more here: a dependency's
    # hooks.json would get its commands merged into settings.json, and one that
    # isn't hook-shaped raises on .items() — this script has no set -e, so every
    # real skill hook would silently go unmerged for that boot.
    if os.sep + 'node_modules' + os.sep in hf:
        continue
    if os.path.basename(os.path.dirname(hf)) in disabled_skills:
        continue
    with open(hf) as f:
        skill_hooks = json.load(f)
    for event, handlers in skill_hooks.items():
        if event not in merged_hooks:
            merged_hooks[event] = handlers
            changed = True
        else:
            existing_cmds = set()
            for entry in merged_hooks[event]:
                for h in entry.get('hooks', []):
                    if 'command' in h:
                        existing_cmds.add(h['command'])
            for handler in handlers:
                hooks_list = handler.get('hooks', [])
                if hooks_list:
                    cmd = hooks_list[0].get('command', '')
                    if cmd and cmd not in existing_cmds:
                        merged_hooks[event].append(handler)
                        changed = True

# --- Prune handlers: hook target missing OR skill marked disabled ---
# Claude Code crashes at session start when a hook 'command' points to a missing
# file. Disabled skills (*.skill.disabled.md) also get their hooks pruned even
# though the target still exists — so disable/enable is a one-mv-and-sync workflow.
_INTERPS = ('bash', 'sh', 'node', 'python', 'python3')

def extract_target_path(cmd):
    if not cmd:
        return None
    parts = cmd.split()
    if not parts:
        return None
    first = parts[0]
    if first in _INTERPS and len(parts) >= 2 and parts[1].startswith('/'):
        return parts[1]
    if first.startswith('/'):
        return first
    return None

_SKILL_PATH_RE = re.compile(r'/workspace/\.devcontainer/skills/([^/]+)/')

def skill_name_of(path):
    m = _SKILL_PATH_RE.match(path or '')
    if not m:
        return None
    return m.group(1).replace('.local', '')

pruned = []
for event in list(merged_hooks.keys()):
    kept_handlers = []
    for handler in merged_hooks[event]:
        drop_entry = None
        for h in handler.get('hooks', []):
            cmd = h.get('command', '')
            path = extract_target_path(cmd)
            skill = skill_name_of(path)
            reason = None
            if path and not os.path.exists(path):
                reason = 'missing'
            elif skill and skill in disabled_skills:
                reason = 'disabled'
            if reason:
                label = '[{}] '.format(skill) if skill else ''
                drop_entry = '{}: {}{} ({})'.format(event, label, path, reason)
                break
        if drop_entry:
            pruned.append(drop_entry)
            changed = True
        else:
            kept_handlers.append(handler)
    if kept_handlers:
        merged_hooks[event] = kept_handlers
    else:
        del merged_hooks[event]
        changed = True

if pruned:
    print('⚠ pruned {} hook(s):'.format(len(pruned)))
    for line in pruned:
        print('  - ' + line)

# --- Persist ---
if changed:
    os.makedirs(bak_dir, exist_ok=True)
    ts = datetime.now().strftime('%Y%m%d-%H%M%S')
    bak_path = os.path.join(bak_dir, 'settings.{}.bak'.format(ts))
    with open(settings_path) as f_in, open(bak_path, 'w') as f_out:
        f_out.write(f_in.read())
    print('✓ backup written to ' + bak_path)

    settings['hooks'] = merged_hooks
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
    if pruned:
        print('✓ settings.json updated (merged + pruned {})'.format(len(pruned)))
    else:
        print('✓ hooks merged into settings.json')
else:
    print('✓ hooks already up to date')
"
fi

echo "=== sync-skills done ==="
