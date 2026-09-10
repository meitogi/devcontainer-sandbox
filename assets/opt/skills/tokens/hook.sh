#!/bin/bash
# tokens skill — Stop hook entry point.
# Reads stdin JSON payload from Claude Code, extracts session_id + transcript_path,
# resolves project identity, invokes lib/capture.py.
# Must never crash a Claude session: swallow all errors.

set -u

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT=$(cat)
SID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
TRANSCRIPT=$(echo "$INPUT" | grep -o '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$SID" ] || [ -z "$TRANSCRIPT" ]; then
  exit 0
fi

# Anchor project resolution on the SESSION's launch cwd — not $(pwd), not the payload's
# current cwd. The CLI tracks its own cwd across Bash `cd` calls and spawns hooks with
# that shifted cwd (so both $(pwd) and payload cwd drift). The transcript's FIRST `cwd`
# entry is the launch dir and stays stable for the session's lifetime.
TOKENS_START_DIR=""
if [ -f "$TRANSCRIPT" ]; then
  TOKENS_START_DIR=$(grep -m1 -o '"cwd":"[^"]*"' "$TRANSCRIPT" | head -1 | cut -d'"' -f4)
fi
if [ -z "$TOKENS_START_DIR" ]; then
  TOKENS_START_DIR=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
export TOKENS_START_DIR

# shellcheck disable=SC1091
. "$SKILL_DIR/lib/project-id.sh"

if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

python3 "$SKILL_DIR/lib/capture.py" \
  --session "$SID" \
  --transcript "$TRANSCRIPT" \
  --project-root "$PROJECT_ROOT" \
  --project-id "$PROJECT_ID" \
  --host-workspace "${HOST_WORKSPACE_PATH:-}" 2>/dev/null || true

exit 0
