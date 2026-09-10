#!/usr/bin/env bash
# tokens skill — host uninstaller.
#
# Reverses `install.sh` by reading `~/.claude/tokens/install.log` (JSONL)
# and undoing each entry :
#   file / symlink → rm -f
#   dir            → rmdir (only if empty)
#   hook           → Python-embedded reverse merge (filter out matching command)
#   backup         → preserve (user's backups are never deleted)
#
# User data is preserved : `<project>/.claude/tokens/logs/` and every
# runtime artefact under `~/.claude/tokens/{pricing.json, projects.jsonl,
# model-aliases.json, capture-errors.log, pricing.json.bak.*}` (they're
# not in install.log, so they naturally survive).

set -u

# -------- CLI parsing --------

DRY_RUN=0
CLAUDE_HOME_ARG=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY_RUN=1 ;;
    --claude-home=*)   CLAUDE_HOME_ARG="${arg#--claude-home=}" ;;
    -h|--help)
      cat <<'EOF'
tokens skill — uninstaller.

Flags:
  --dry-run            print what would be undone, touch nothing
  --claude-home=<dir>  override CLAUDE_HOME (default: $CLAUDE_HOME or ~/.claude)
  -h, --help           this text

Reads install.log at $CLAUDE_HOME/tokens/install.log and reverses each
entry. User data (logs, pricing snapshot, project registry) is preserved.
EOF
      exit 0
      ;;
    *)
      printf 'unknown flag: %s (use --help)\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# -------- Colour helpers --------

if [ -t 1 ]; then
  C_INFO='\033[36m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_END='\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_END=''
fi
info()    { printf "${C_INFO}[uninstall]${C_END} %s\n" "$*"; }
success() { printf "${C_OK}[uninstall]${C_END} %s\n" "$*"; }
warn()    { printf "${C_WARN}[uninstall]${C_END} %s\n" "$*" >&2; }
error()   { printf "${C_ERR}[uninstall]${C_END} %s\n" "$*" >&2; }

# -------- Resolve CLAUDE_HOME + install.log --------

if [ -n "$CLAUDE_HOME_ARG" ]; then
  CLAUDE_HOME="$CLAUDE_HOME_ARG"
elif [ -n "${CLAUDE_HOME:-}" ]; then
  :
else
  CLAUDE_HOME="$HOME/.claude"
fi
INSTALL_LOG="$CLAUDE_HOME/tokens/install.log"
SETTINGS="$CLAUDE_HOME/settings.json"

if [ ! -f "$INSTALL_LOG" ]; then
  error "install.log not found: $INSTALL_LOG"
  error "did you install with a different CLAUDE_HOME? try --claude-home=<path>"
  exit 1
fi

info "install.log : $INSTALL_LOG"
info "settings    : $SETTINGS"

# -------- Reverse the log (in reverse order) --------

# Emit lines in reverse. `tac` isn't POSIX; use awk portable form.
REVERSED=$(awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }' "$INSTALL_LOG")

while IFS= read -r entry; do
  [ -z "$entry" ] && continue

  # Parse type + path minimally via python3 for correctness.
  parsed=$(python3 - "$entry" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print(f'ERR:{e}')
    sys.exit(0)
t = d.get('type', '')
p = d.get('path', '')
cmd = d.get('command', '')
print(f'{t}\t{p}\t{cmd}')
PY
)
  type=$(printf '%s' "$parsed" | cut -f1)
  path=$(printf '%s' "$parsed" | cut -f2)
  cmd=$(printf '%s' "$parsed" | cut -f3)

  case "$type" in
    file|symlink)
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        info "already gone: $path"
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        info "would rm: $path"
      else
        rm -f "$path"
      fi
      ;;
    dir)
      if [ ! -d "$path" ]; then
        info "already gone: $path"
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        info "would rmdir: $path (if empty)"
      else
        rmdir "$path" 2>/dev/null || warn "not empty, keeping: $path"
      fi
      ;;
    backup)
      info "preserving backup: $path"
      ;;
    hook)
      if [ ! -f "$path" ]; then
        info "settings.json gone: $path — skip hook reverse"
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        info "would remove hook from $path : $cmd"
        continue
      fi
      # Backup then reverse-merge.
      cp "$path" "$path.bak.$(date +%s).uninstall"
      python3 - "$path" "$cmd" <<'PY'
import json, os, sys
settings_path, cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
for event, entries in list(hooks.items()):
    kept = []
    for entry in entries:
        remaining = [h for h in entry.get('hooks', []) if h.get('command') != cmd]
        if remaining:
            new = dict(entry)
            new['hooks'] = remaining
            kept.append(new)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if hooks:
    settings['hooks'] = hooks
else:
    settings.pop('hooks', None)
tmp = settings_path + '.new'
with open(tmp, 'w') as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, settings_path)
print(f'[uninstall] removed Stop hook: {cmd}')
PY
      ;;
    ERR:*)
      warn "bad install.log line: $entry"
      ;;
    *)
      warn "unknown entry type '$type' — skipping"
      ;;
  esac
done <<EOF
$REVERSED
EOF

# -------- Cleanup empty tokens/lib and tokens/ dirs --------

if [ "$DRY_RUN" -eq 0 ]; then
  rmdir "$CLAUDE_HOME/tokens/lib" 2>/dev/null && info "removed empty $CLAUDE_HOME/tokens/lib"
  # `tokens/` may still hold pricing.json, projects.jsonl, etc. — leave intact.
  # Also remove install.log itself (last remaining install artefact).
  rm -f "$INSTALL_LOG"
  info "removed $INSTALL_LOG"
fi

success "done."
info "preserved: user logs at <project>/.claude/tokens/logs/"
info "preserved: runtime data at $CLAUDE_HOME/tokens/{pricing.json,projects.jsonl,model-aliases.json,capture-errors.log}"
info "preserved: settings.json backups at $SETTINGS.bak.*"
