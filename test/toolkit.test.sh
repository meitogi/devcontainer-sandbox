#!/usr/bin/env bash
# toolkit.test.sh — the patch toolkit's contract, with no patcher in the repo.
#
# This image ships run-all.sh, _common.py and AUTHORING.md, and deliberately no
# patcher: the VS Code extension is installed exactly as published. What still
# has to hold is the CONTRACT the toolkit offers to anyone who brings their own
# — an extending image dropping a .py next to the orchestrator (EXTENDING.md),
# or the 45-ext-patches.sh hook assembling a directory somewhere else entirely.
#
# So everything here is driven by probe patchers written into a throwaway
# directory, against a throwaway extension. Three questions:
#
#   1. Does PATCH_DIR really decouple the patchers from the toolkit — including
#      `from _common import ...`, which used to work only because the patchers
#      happened to sit next to _common.py?
#   2. Does a selection still select? all / none / category / name / the
#      additive combination / an unknown token.
#   3. Are the refusals still refusals? A patcher without a category stops the
#      run; an unknown token stops it before anything is applied.
#
# The registry half — headers agreeing with PATCHES.md, sentinels really in the
# code — moved out with the patchers, to the repository that holds them.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TOOLKIT="$REPO/assets/vscode-ext-patchs"
RUNNER="$TOOLKIT/run-all.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  – %s (skipped: %s)\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; printf '      expected : %s\n      got      : %s\n' "$3" "$2" >&2; fi }

# run-all.sh uses arrays under `set -u`; bash 3.2 treats an empty array as
# unset and would abort before the first patcher. Same gate as the other
# suites: replay this one inside the container.
HAS_BASH4=1
[ "${BASH_VERSINFO[0]}" -ge 4 ] || HAS_BASH4=0

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "== the shipped toolkit is the toolkit, and nothing else =="
checkeq "assets/vscode-ext-patchs holds exactly the three toolkit files" \
  "$(ls "$TOOLKIT" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "AUTHORING.md _common.py run-all.sh"
check "no patcher ships in this repository" \
  "[ -z \"\$(find \"\$TOOLKIT\" -name '*.py' ! -name '_common.py' -print -quit)\" ]"
# AUTHORING.md describes the header contract a patcher must honour. It must not
# describe how to find an anchor in a minified bundle — that is the technique,
# and it travels with the patchers.
check "AUTHORING.md still documents the header contract" \
  "grep -q '@patch-category' \"\$TOOLKIT/AUTHORING.md\" && grep -q 'PATCH_DIR' \"\$TOOLKIT/AUTHORING.md\""

# --------------------------------------------------------------------------
# A throwaway extension. The probes below rewrite it; what is asserted is which
# probe ran, not what the bundle ended up looking like.
# --------------------------------------------------------------------------
EXT="$TMPROOT/ext"
mkdir -p "$EXT/webview"
printf '{}\n'      > "$EXT/package.json"
printf '// stub\n' > "$EXT/extension.js"
printf '// stub\n' > "$EXT/webview/index.js"

# The probe: the shape AUTHORING.md documents and extend.test.sh installs — a
# header, a sentinel, an idempotent guard, and `from _common import ...` so the
# import path is exercised rather than assumed.
mk_probe() {
  local dir="$1" name="$2" cat="$3"
  mkdir -p "$dir"
  cat > "$dir/$name.py" <<PY
#!/usr/bin/env python3
# @patch-category: $cat
# @patch-files: extension.js
# @patch-sentinel: /*__PROBE_${name}__*/
# @patch-summary: Test probe: prepends an inert marker comment so the toolkit
#   contract can be exercised without shipping a real patcher.
"""Minimal patcher: prepends an inert sentinel comment to extension.js."""
import sys

from _common import GREEN, RESET, resolve_ext_dir, check_files

MARKER = "/*__PROBE_${name}__*/"


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    path = ext_dir / "extension.js"
    content = path.read_text()
    if MARKER in content:
        print(f"{GREEN}[$name]{RESET} already patched")
        return 0
    path.write_text(MARKER + content)
    print(f"{GREEN}[$name]{RESET} applied")
    return 0


sys.exit(main())
PY
}

PROBES="$TMPROOT/patchers"
mk_probe "$PROBES" probe-ux-one   ux
mk_probe "$PROBES" probe-ux-two   ux
mk_probe "$PROBES" probe-fix-one  fix
mk_probe "$PROBES" probe-notify   notify

# Deliberately NOT copied next to _common.py: the point is that PATCH_DIR works
# when the two are apart, which is exactly how the hook and an image without
# patchers use it.
run_sel() {
  CLAUDE_CODE_EXT_PATCHS="$1" PATCH_DIR="$PROBES" PYTHONDONTWRITEBYTECODE=1 \
    bash "$RUNNER" "$EXT" 2>"$TMPROOT/err"
}
invoked() { run_sel "$1" | grep -cE '→ [A-Za-z0-9._-]+\.py'; }

if [ "$HAS_BASH4" -eq 0 ]; then
  for t in "PATCH_DIR runs patchers that live outside the toolkit" \
           "a patcher imports _common through PYTHONPATH" \
           "all runs every patcher" "none runs none of them" \
           "a category runs exactly its members" "a bare name runs exactly one" \
           "a name after a category adds to it" \
           "a name already covered by a category does not run twice" \
           "whitespace around a token is tolerated" \
           "an unknown token exits 2" "an unknown token applies nothing" \
           "an unknown token names itself in the error" \
           "a patcher without a category stops the run" \
           "an empty patch directory is not an error" \
           "an empty patch directory says so" \
           "the toolkit directory is still the default"; do
    skip "$t" "bash 3.2: run-all.sh needs bash 4 arrays"
  done
else

echo "== PATCH_DIR decouples the patchers from the toolkit =="
checkeq "PATCH_DIR runs patchers that live outside the toolkit" "$(invoked all)" "4"
# The import is the fragile half: sys.path[0] is the PATCHER's directory, which
# no longer holds _common.py. Only PYTHONPATH makes this work.
check "a patcher imports _common through PYTHONPATH" \
  "! grep -q 'ModuleNotFoundError' \"\$TMPROOT/err\""
check "the probe really reached the bundle" \
  "grep -q '__PROBE_probe-ux-one__' \"\$EXT/extension.js\""

echo "== a selection selects =="
checkeq "all runs every patcher" "$(invoked all)" "4"
checkeq "none runs none of them" "$(invoked none)" "0"
checkeq "a category runs exactly its members" "$(invoked ux)" "2"
checkeq "a bare name runs exactly one" "$(invoked probe-fix-one)" "1"
checkeq "a name after a category adds to it" "$(invoked ux,probe-notify)" "3"
checkeq "a name already covered by a category does not run twice" \
  "$(invoked ux,probe-ux-one)" "2"
checkeq "whitespace around a token is tolerated" "$(invoked ' ux , probe-notify ')" "3"

echo "== the refusals are still refusals =="
run_sel nope >/dev/null 2>&1; checkeq "an unknown token exits 2" "$?" "2"
checkeq "an unknown token applies nothing" "$(invoked nope)" "0"
check "an unknown token names itself in the error" "grep -q 'nope' \"\$TMPROOT/err\""

NOHDR="$TMPROOT/nohdr"
mk_probe "$NOHDR" probe-ok ux
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$NOHDR/zz-headerless.py"
CLAUDE_CODE_EXT_PATCHS=all PATCH_DIR="$NOHDR" PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >/dev/null 2>&1
checkeq "a patcher without a category stops the run" "$?" "2"

echo "== an image with no patcher is a normal image =="
EMPTY="$TMPROOT/empty"; mkdir -p "$EMPTY"
CLAUDE_CODE_EXT_PATCHS=all PATCH_DIR="$EMPTY" PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >"$TMPROOT/out" 2>"$TMPROOT/err"
checkeq "an empty patch directory is not an error" "$?" "0"
check "an empty patch directory says so" "grep -q 'no patchers found' \"\$TMPROOT/err\""
# Without PATCH_DIR the orchestrator falls back to its own directory, which in
# this repository holds no patcher — so the shipped default is the empty case.
CLAUDE_CODE_EXT_PATCHS=all PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >/dev/null 2>&1
checkeq "the toolkit directory is still the default" "$?" "0"

fi

printf '\ntoolkit: %d pass / %d fail' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ' / %d skipped' "$SKIP"
printf '\n'
[ "$FAIL" -eq 0 ]
