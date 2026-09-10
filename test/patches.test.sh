#!/usr/bin/env bash
# patches.test.sh — the VS Code extension patch registry, and the selection
# built on top of it.
#
# Two questions, no Docker needed for either:
#
#   1. Does the registry describe reality? Each patcher carries a `# @patch-*`
#      header, and PATCHES.md carries a section per patcher. Both can drift
#      from the code they describe, and a drifted registry is worse than none —
#      the build reads it to decide which files to keep a pristine copy of, and
#      restore-ext-patches reads it to report what is live.
#
#   2. Does a selection select? run-all.sh is driven against a throwaway
#      extension directory, and what is asserted is WHICH patchers were
#      invoked, not what they did to the stubs.
#
# The image-side half — sentinels really present in a baked bundle, pristine
# copies really shipped — lives in run-image-suites.sh and extend.test.sh,
# because it needs an image.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PATCH_DIR="$REPO/assets/vscode-ext-patchs"
CATEGORIES="ux fix notify"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  – %s (skipped: %s)\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; printf '      attendu : %s\n      obtenu  : %s\n' "$3" "$2" >&2; fi }

# run-all.sh uses arrays under `set -u`; bash 3.2 treats an empty array as
# unset and would abort before the first patcher. Same gate as the other
# suites: replay this one inside the container.
HAS_BASH4=1
[ "${BASH_VERSINFO[0]}" -ge 4 ] || HAS_BASH4=0

meta() { sed -n "s/^# @patch-$2: //p" "$1"; }

PATCHERS=()
for py in "$PATCH_DIR"/*.py; do
  base="${py##*/}"
  [ "$base" = "_common.py" ] && continue
  PATCHERS+=("${base%.py}")
done

# =============================================================================
echo "═══ 1. the registry describes the code ═══"
# =============================================================================

checkeq "the patch directory holds the 16 patchers the registry is written for" \
  "${#PATCHERS[@]}" "16"

# A patcher with no category cannot be selected, so run-all.sh refuses to guess
# and stops the build. Guarding it here means the refusal never has to fire.
MISSING_CAT=""
for n in "${PATCHERS[@]}"; do
  [ -n "$(meta "$PATCH_DIR/$n.py" category)" ] || MISSING_CAT="$MISSING_CAT $n"
done
checkeq "every patcher declares a category" "${MISSING_CAT:-none}" "none"

BAD_CAT=""
for n in "${PATCHERS[@]}"; do
  c="$(meta "$PATCH_DIR/$n.py" category | head -1)"
  case " $CATEGORIES " in *" $c "*) ;; *) BAD_CAT="$BAD_CAT $n=$c" ;; esac
done
checkeq "every category is one of the three the selection knows" \
  "${BAD_CAT:-none}" "none"

MISSING_SUM=""
for n in "${PATCHERS[@]}"; do
  [ -n "$(meta "$PATCH_DIR/$n.py" summary)" ] || MISSING_SUM="$MISSING_SUM $n"
done
checkeq "every patcher declares a summary" "${MISSING_SUM:-none}" "none"

# The declared file list is what the build backs up. A file rewritten but not
# declared is a file restore-ext-patches can never bring back — so it has to
# agree with the check_files() call the patcher actually makes.
FILE_DRIFT=""
for n in "${PATCHERS[@]}"; do
  declared="$(meta "$PATCH_DIR/$n.py" files | sort | tr '\n' ' ')"
  actual="$(grep -o 'check_files(ext_dir, \[[^]]*\]' "$PATCH_DIR/$n.py" \
            | grep -o '"[^"]*"' | tr -d '"' | sort | tr '\n' ' ')"
  [ "$declared" = "$actual" ] || FILE_DRIFT="$FILE_DRIFT $n"
done
checkeq "every @patch-files list matches the patcher's own check_files call" \
  "${FILE_DRIFT:-none}" "none"

# A sentinel that is not a literal in its own patcher can never appear in a
# bundle, which would make --list report a live patch as missing forever.
SENT_DRIFT=""
for n in "${PATCHERS[@]}"; do
  cnt="$(meta "$PATCH_DIR/$n.py" sentinel | wc -l)"
  [ "$cnt" -ge 1 ] || { SENT_DRIFT="$SENT_DRIFT $n(none)"; continue; }
  while IFS= read -r s || [ -n "$s" ]; do
    [ -z "$s" ] && continue
    # The header block is stripped before searching: grepping the whole file
    # would find the `# @patch-sentinel:` line itself and call any declaration
    # true, which is exactly the drift this assertion exists to catch.
    sed '/^# @patch-/d' "$PATCH_DIR/$n.py" | grep -qF -- "$s" \
      || SENT_DRIFT="$SENT_DRIFT $n:$s"
  done < <(meta "$PATCH_DIR/$n.py" sentinel)
done
checkeq "every declared sentinel is a literal the patcher really writes" \
  "${SENT_DRIFT:-none}" "none"

# `critical` is what makes excluding a patch loud. Two of them, or none, and
# the warning stops meaning what PATCHES.md says it means.
NCRIT=0
for n in "${PATCHERS[@]}"; do
  [ "$(meta "$PATCH_DIR/$n.py" critical | head -1)" = "true" ] && NCRIT=$((NCRIT+1))
done
checkeq "exactly one patcher is marked critical" "$NCRIT" "1"
checkeq "and it is the one the extension does not activate without" \
  "$(meta "$PATCH_DIR/navigator-pending-migration-fix.py" critical | head -1)" "true"

# =============================================================================
echo "═══ 2. PATCHES.md describes the registry ═══"
# =============================================================================

DOC="$PATCH_DIR/PATCHES.md"
check "PATCHES.md ships next to the patchers" "[ -f '$DOC' ]"
check "AUTHORING.md ships next to the patchers" "[ -f '$PATCH_DIR/AUTHORING.md' ]"

UNDOCUMENTED=""
for n in "${PATCHERS[@]}"; do
  grep -q "^## $n\$" "$DOC" || UNDOCUMENTED="$UNDOCUMENTED $n"
done
checkeq "every patcher has its own section in PATCHES.md" \
  "${UNDOCUMENTED:-none}" "none"

# The reverse direction: a section whose heading is a bare slug must name a
# patcher that exists, or a removed patch keeps its page forever. Prose
# headings contain spaces and are left alone.
ORPHAN_SECTION=""
while IFS= read -r h; do
  [ -f "$PATCH_DIR/$h.py" ] || ORPHAN_SECTION="$ORPHAN_SECTION $h"
done < <(grep '^## ' "$DOC" | sed 's/^## //' | grep -v ' ')
checkeq "no section in PATCHES.md describes a patch that no longer exists" \
  "${ORPHAN_SECTION:-none}" "none"

TABLE_DRIFT=""
while IFS= read -r row; do
  n="$(printf '%s' "$row" | sed 's/^| `\([^`]*\)`.*/\1/')"
  c="$(printf '%s' "$row" | awk -F'|' '{print $3}' | tr -d ' ')"
  d="$(meta "$PATCH_DIR/$n.py" category | head -1)"
  [ "$c" = "$d" ] || TABLE_DRIFT="$TABLE_DRIFT $n(table=$c,header=$d)"
done < <(grep '^| `' "$DOC")
checkeq "the overview table agrees with the headers on every category" \
  "${TABLE_DRIFT:-none}" "none"

checkeq "the overview table lists every patcher exactly once" \
  "$(grep -c '^| `' "$DOC")" "${#PATCHERS[@]}"

# =============================================================================
echo "═══ 3. a selection selects ═══"
# =============================================================================

if [ "$HAS_BASH4" -eq 0 ]; then
  for t in "all runs every patcher" "none runs none of them" \
           "none says out loud that a critical patch is being skipped" \
           "a category runs exactly its members" \
           "a bare name runs only that patcher" \
           "a category and a name union without running anything twice" \
           "whitespace around a token is tolerated" \
           "an unknown token exits 2" \
           "an unknown token runs nothing at all" \
           "an unknown token is named in the error" \
           "a patcher without a category stops the run"; do
    skip "$t" "needs bash 4 - run it in the container"
  done
else

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# A throwaway extension: the patchers all fail against these stubs, which is
# irrelevant here — a FAILED patcher is still an invoked one, and invocation is
# what selection decides.
EXT="$TMPROOT/ext"
mkdir -p "$EXT/webview"
printf '{}\n'      > "$EXT/package.json"
printf '// stub\n' > "$EXT/extension.js"
printf '// stub\n' > "$EXT/webview/index.js"

RUNNER="$PATCH_DIR/run-all.sh"
# Invoked patchers announce themselves with `→ <name>.py`. Counting a bare
# arrow would also count the patchers' own prose — two of them print an
# `extension x.y.z → mode` line on stdout before they fail against the stubs —
# so the `.py` filename is what makes the announcement recognisable.
# PYTHONDONTWRITEBYTECODE keeps the suite from dropping a __pycache__ into the
# tracked tree.
invoked() {
  CLAUDE_CODE_EXT_PATCHS="$1" PYTHONDONTWRITEBYTECODE=1 \
    bash "$RUNNER" "$EXT" 2>/dev/null | grep -cE '→ [A-Za-z0-9._-]+\.py'
}

members_of() {
  local c="$1" n cnt=0
  for n in "${PATCHERS[@]}"; do
    [ "$(meta "$PATCH_DIR/$n.py" category | head -1)" = "$c" ] && cnt=$((cnt+1))
  done
  printf '%s' "$cnt"
}

checkeq "all runs every patcher" "$(invoked all)" "${#PATCHERS[@]}"
checkeq "none runs none of them" "$(invoked none)" "0"

check "none says out loud that a critical patch is being skipped" \
  "CLAUDE_CODE_EXT_PATCHS=none PYTHONDONTWRITEBYTECODE=1 bash '$RUNNER' '$EXT' 2>&1 >/dev/null | grep -q 'CRITICAL PATCH IS BEING SKIPPED'"

for c in $CATEGORIES; do
  checkeq "a category runs exactly its members ($c)" "$(invoked "$c")" "$(members_of "$c")"
done

checkeq "a bare name runs only that patcher" "$(invoked model-badge-footer)" "1"

# handle-uri-workspace is notify, so a category followed by a name has to grow
# the selection: a token must add to what came before, never replace it.
checkeq "a name after a category adds to it instead of replacing it" \
  "$(invoked 'ux,handle-uri-workspace')" "$(( $(members_of ux) + 1 ))"

# model-badge-footer is already in ux: naming it again changes nothing.
checkeq "a name already covered by a category does not inflate the selection" \
  "$(invoked 'ux,model-badge-footer')" "$(members_of ux)"

checkeq "whitespace around a token is tolerated" \
  "$(invoked 'ux, fix')" "$(( $(members_of ux) + $(members_of fix) ))"

CLAUDE_CODE_EXT_PATCHS='ux,model-badge-footr' PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >/dev/null 2>&1
checkeq "an unknown token exits 2" "$?" "2"

checkeq "an unknown token runs nothing at all" "$(invoked 'ux,model-badge-footr')" "0"

check "an unknown token is named in the error" \
  "CLAUDE_CODE_EXT_PATCHS='ux,model-badge-footr' PYTHONDONTWRITEBYTECODE=1 bash '$RUNNER' '$EXT' 2>&1 >/dev/null | grep -q 'model-badge-footr'"

# An extending image can drop a .py into the patch dir. Without a header it is
# unselectable, and running it anyway would mean applying something no registry
# describes — so the run stops instead.
NOHDR="$TMPROOT/patchdir"
cp -r "$PATCH_DIR" "$NOHDR"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$NOHDR/zz-headerless.py"
CLAUDE_CODE_EXT_PATCHS=all PYTHONDONTWRITEBYTECODE=1 \
  bash "$NOHDR/run-all.sh" "$EXT" >/dev/null 2>&1
checkeq "a patcher without a category stops the run" "$?" "2"

fi

# =============================================================================
echo
printf 'patches: %d pass / %d fail' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ' / %d skipped' "$SKIP"
printf '\n'
[ "$FAIL" -eq 0 ]
