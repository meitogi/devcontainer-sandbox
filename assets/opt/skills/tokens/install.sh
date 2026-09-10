#!/usr/bin/env bash
# tokens skill — host installer.
#
# Turns the in-repo skill files into a globally-installed skill under
# `~/.claude/tokens/` (or `$CLAUDE_HOME/tokens/`). Merges a Stop hook into
# `~/.claude/settings.json` idempotently. Records every touched artefact
# to `~/.claude/tokens/install.log` (JSONL) so `uninstall.sh` can reverse.
#
# 100% standalone: no dependency on this repo's `sync-skills.sh` or on
# Claude runtime. Runs on any host where Claude Code is installed.
#
# Usage:
#   bash install.sh [--with-cli] [--no-refresh] [--dry-run]
#                   [--claude-home=<path>] [--help]

set -u

# -------- CLI parsing --------

WITH_CLI=0
NO_REFRESH=0
DRY_RUN=0
CLAUDE_HOME_ARG=""

for arg in "$@"; do
  case "$arg" in
    --with-cli)          WITH_CLI=1 ;;
    --no-refresh)        NO_REFRESH=1 ;;
    --dry-run)           DRY_RUN=1 ;;
    --claude-home=*)     CLAUDE_HOME_ARG="${arg#--claude-home=}" ;;
    -h|--help)
      cat <<'EOF'
tokens skill — installer.

Copies hook.sh, recap.js, refresh-pricing.sh, lib/*, and tokens.skill.md
into $CLAUDE_HOME/tokens/ + $CLAUDE_HOME/commands/. Idempotent.

Flags:
  --with-cli           symlink ~/.local/bin/tokens-recap → recap.js
  --no-refresh         skip refresh-pricing.sh seed (use hardcoded prices)
  --dry-run            print what would be done, touch nothing
  --claude-home=<dir>  override CLAUDE_HOME (default: $CLAUDE_HOME or ~/.claude)
  -h, --help           this text

Output: $CLAUDE_HOME/tokens/install.log (JSONL, one entry per touched
artefact) — read by uninstall.sh to reverse the install.
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
info()    { printf "${C_INFO}[install]${C_END} %s\n" "$*"; }
success() { printf "${C_OK}[install]${C_END} %s\n" "$*"; }
warn()    { printf "${C_WARN}[install]${C_END} %s\n" "$*" >&2; }
error()   { printf "${C_ERR}[install]${C_END} %s\n" "$*" >&2; }

# -------- Dep checks --------

need_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "missing required binary: $1 ($2)"
    return 1
  fi
}

missing=0
need_bin bash    "shell interpreter"   || missing=1
need_bin python3 "hook + install merge" || missing=1
need_bin node    "recap CLI"           || missing=1
need_bin curl    "refresh-pricing.sh"  || missing=1
if [ "$missing" -eq 1 ]; then
  error "install docker separately if you want cross-container aggregation."
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  warn "docker not found — cross-container aggregation will be disabled."
  warn "install docker on host if you use devcontainers for token tracking."
fi

# -------- Resolve CLAUDE_HOME --------

if [ -n "$CLAUDE_HOME_ARG" ]; then
  CLAUDE_HOME="$CLAUDE_HOME_ARG"
elif [ -n "${CLAUDE_HOME:-}" ]; then
  :
else
  CLAUDE_HOME="$HOME/.claude"
fi
if [ ! -d "$CLAUDE_HOME" ]; then
  error "CLAUDE_HOME does not exist: $CLAUDE_HOME"
  error "install Claude Code first: https://docs.claude.com/en/docs/claude-code"
  exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DST_DIR="$CLAUDE_HOME/tokens"
DST_LIB="$DST_DIR/lib"
CMD_DIR="$CLAUDE_HOME/commands"
CMD_FILE="$CMD_DIR/tokens.md"
SETTINGS="$CLAUDE_HOME/settings.json"
INSTALL_LOG="$DST_DIR/install.log"

HOOK_CMD="bash $DST_DIR/hook.sh stop"

info "source     : $SRC_DIR"
info "target     : $DST_DIR"
info "commands   : $CMD_DIR"
info "settings   : $SETTINGS"
info "install.log: $INSTALL_LOG"

# -------- Install-log helpers --------

# Buffer log lines in memory until the final commit, so a dry-run rehearses
# without writing anything and a real run writes atomically at the end.
LOG_BUFFER=""

log_entry() {
  local type="$1" path="$2" extra="${3:-}"
  local line
  if [ -n "$extra" ]; then
    line=$(printf '{"type":"%s","path":"%s",%s}' "$type" "$path" "$extra")
  else
    line=$(printf '{"type":"%s","path":"%s"}' "$type" "$path")
  fi
  LOG_BUFFER="${LOG_BUFFER}${line}
"
}

# -------- File-copy operations --------

copy_file() {
  local src="$1" dst="$2"
  if [ ! -f "$src" ]; then
    error "source missing: $src"
    exit 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "would copy: $src → $dst"
  else
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
  fi
  log_entry file "$dst"
}

# Files to copy: (src-rel, dst-rel-under-DST_DIR)
copy_file "$SRC_DIR/hook.sh"                    "$DST_DIR/hook.sh"
copy_file "$SRC_DIR/recap.js"                   "$DST_DIR/recap.js"
copy_file "$SRC_DIR/refresh-pricing.sh"         "$DST_DIR/refresh-pricing.sh"
copy_file "$SRC_DIR/lib/project-id.sh"          "$DST_LIB/project-id.sh"
copy_file "$SRC_DIR/lib/capture.py"             "$DST_LIB/capture.py"
copy_file "$SRC_DIR/lib/docker-scan.sh"         "$DST_LIB/docker-scan.sh"
copy_file "$SRC_DIR/lib/projects-ops.js"        "$DST_LIB/projects-ops.js"
copy_file "$SRC_DIR/lib/pricing.js"             "$DST_LIB/pricing.js"
copy_file "$SRC_DIR/lib/format.js"              "$DST_LIB/format.js"
copy_file "$SRC_DIR/lib/window.js"              "$DST_LIB/window.js"
copy_file "$SRC_DIR/lib/logs.js"                "$DST_LIB/logs.js"
copy_file "$SRC_DIR/lib/pricing-sources.json"   "$DST_LIB/pricing-sources.json"
copy_file "$SRC_DIR/tokens.skill.md"            "$CMD_FILE"
# The command md gets a different filename convention; log it as `file`.

# Ensure executables.
if [ "$DRY_RUN" -eq 0 ]; then
  chmod +x "$DST_DIR/hook.sh" "$DST_DIR/recap.js" "$DST_DIR/refresh-pricing.sh" \
           "$DST_LIB/project-id.sh" "$DST_LIB/docker-scan.sh" 2>/dev/null || true
fi

# -------- Hook merge (Python-embedded, idempotent) --------

BACKUP_CANDIDATE=""
if [ "$DRY_RUN" -eq 0 ] && [ -f "$SETTINGS" ]; then
  BACKUP_CANDIDATE="$SETTINGS.bak.$(date +%s)"
fi

HOOK_STATUS=$(python3 - "$SETTINGS" "$HOOK_CMD" "$DRY_RUN" "$BACKUP_CANDIDATE" <<'PY'
import json, os, shutil, sys
settings_path, cmd, dry, backup = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4]

if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except Exception as e:
        print(f'ERR:settings.json unparseable: {e}', file=sys.stderr)
        sys.exit(1)
else:
    settings = {}

stop_list = settings.setdefault('hooks', {}).setdefault('Stop', [])
already = any(
    h.get('command') == cmd
    for entry in stop_list
    for h in entry.get('hooks', [])
)

if already:
    print('SKIP')
    sys.exit(0)

stop_list.append({'matcher': '', 'hooks': [{'type': 'command', 'command': cmd}]})

if dry:
    print('WOULD_WRITE')
    sys.exit(0)

if os.path.exists(settings_path) and backup:
    shutil.copy2(settings_path, backup)

os.makedirs(os.path.dirname(settings_path) or '.', exist_ok=True)
tmp = settings_path + '.new'
with open(tmp, 'w') as f:
    json.dump(settings, f, indent=2)
os.replace(tmp, settings_path)
print(f'WROTE:{backup}')
PY
)

case "$HOOK_STATUS" in
  SKIP)
    info "hook already registered: $HOOK_CMD"
    ;;
  WOULD_WRITE)
    info "would register Stop hook: $HOOK_CMD"
    ;;
  WROTE:*)
    success "registered Stop hook: $HOOK_CMD"
    b="${HOOK_STATUS#WROTE:}"
    [ -n "$b" ] && log_entry backup "$b"
    ;;
  *)
    error "hook merge failed: $HOOK_STATUS"
    exit 1
    ;;
esac

log_entry hook "$SETTINGS" "\"event\":\"Stop\",\"command\":\"$HOOK_CMD\""

# -------- Pricing seed --------

if [ "$NO_REFRESH" -eq 0 ]; then
  info "seeding pricing.json via refresh-pricing.sh --non-interactive"
  if [ "$DRY_RUN" -eq 0 ]; then
    if CLAUDE_HOME="$CLAUDE_HOME" bash "$DST_DIR/refresh-pricing.sh" --non-interactive >/dev/null 2>&1; then
      success "pricing.json seeded from live sources"
    else
      warn "refresh-pricing failed (offline?) — falling back to hardcoded prices"
    fi
  fi
else
  info "skipping refresh-pricing.sh (--no-refresh)"
fi

# If pricing.json still missing, seed from hardcoded.
if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$CLAUDE_HOME/tokens/pricing.json" ]; then
  info "seeding hardcoded pricing.json"
  mkdir -p "$CLAUDE_HOME/tokens"
  cat >"$CLAUDE_HOME/tokens/pricing.json" <<'JSON'
{
  "fetched_at": "hardcoded-fallback",
  "source_url": "hardcoded-fallback",
  "prices": {
    "claude-opus-4-7":   {"in": 5.00, "cache_read": 0.50, "cache_create": 10.00, "out": 25.00},
    "claude-sonnet-4-6": {"in": 3.00, "cache_read": 0.30, "cache_create": 6.00,  "out": 15.00},
    "claude-haiku-4-5":  {"in": 1.00, "cache_read": 0.10, "cache_create": 2.00,  "out": 5.00}
  }
}
JSON
fi

# -------- --with-cli symlink --------

if [ "$WITH_CLI" -eq 1 ]; then
  LOCAL_BIN="$HOME/.local/bin"
  LINK="$LOCAL_BIN/tokens-recap"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$LOCAL_BIN"
    ln -sf "$DST_DIR/recap.js" "$LINK"
    log_entry symlink "$LINK"
    success "symlink: $LINK → $DST_DIR/recap.js"
  else
    info "would symlink: $LINK → $DST_DIR/recap.js"
    log_entry symlink "$LINK"
  fi
fi

# -------- Write install.log --------

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$DST_DIR"
  printf '%s' "$LOG_BUFFER" >"$INSTALL_LOG"
  success "install.log written: $INSTALL_LOG ($(wc -l <"$INSTALL_LOG" | tr -d ' ') entries)"
else
  info "dry-run: would write $INSTALL_LOG"
  printf '%s' "$LOG_BUFFER" | sed 's/^/[install.log] /'
fi

success "done. Run: node $DST_DIR/recap.js --list-projects"
