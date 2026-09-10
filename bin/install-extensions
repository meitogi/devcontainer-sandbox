#!/bin/bash
# Install / re-install the VS Code extensions declared in
# customizations.vscode.extensions of .devcontainer/devcontainer.json.
# Idempotent — already-installed extensions are skipped (use --force on a
# single id manually if you want to reinstall one specifically).
#
# Usage:
#   install-extensions.sh                          # reads /workspace/.devcontainer/devcontainer.json
#   install-extensions.sh path/to/devcontainer.json
set -u

DEVCONTAINER_JSON="${1:-/workspace/.devcontainer/devcontainer.json}"

if ! command -v code >/dev/null 2>&1; then
  echo "❌ 'code' CLI not in PATH — run this from a terminal inside the devcontainer (VS Code injects it)." >&2
  exit 1
fi
if [ ! -f "$DEVCONTAINER_JSON" ]; then
  echo "❌ $DEVCONTAINER_JSON not found." >&2
  exit 1
fi

# devcontainer.json is jsonc — strip // line and /* */ block comments before json.loads.
EXTENSIONS=$(python3 - "$DEVCONTAINER_JSON" <<'PY'
import json, re, sys
with open(sys.argv[1]) as f:
    data = f.read()
data = re.sub(r'//[^\n]*', '', data)
data = re.sub(r'/\*.*?\*/', '', data, flags=re.DOTALL)
d = json.loads(data)
for ext in d.get('customizations', {}).get('vscode', {}).get('extensions', []):
    print(ext)
PY
)

if [ -z "$EXTENSIONS" ]; then
  echo "ℹ no extensions declared in $DEVCONTAINER_JSON"
  exit 0
fi

INSTALLED=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')

rc=0
while IFS= read -r ext; do
  [ -z "$ext" ] && continue
  ext_id_lc=$(echo "${ext%@*}" | tr '[:upper:]' '[:lower:]')
  if grep -qFx "$ext_id_lc" <<<"$INSTALLED"; then
    echo "✓ $ext (already installed)"
  else
    echo "→ installing $ext..."
    if code --install-extension "$ext" --force >/dev/null; then
      echo "  ✓ $ext"
    else
      echo "  ⚠ failed: $ext"
      rc=1
    fi
  fi
done <<<"$EXTENSIONS"

exit "$rc"
