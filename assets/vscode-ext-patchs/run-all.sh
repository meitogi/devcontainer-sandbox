#!/bin/bash
# Orchestrator for vscode-ext-patchs/*.py
#
# Runs the SELECTED patch scripts (alphabetical order, _common.py excluded)
# against the given Claude Code extension directory. Per-script exit status is
# captured and logged, so build logs make it trivial to see WHICH feature's
# regex broke after a Claude Code version bump.
#
# Usage
# -----
#   run-all.sh [EXT_DIR]
#
# If EXT_DIR is omitted, each script auto-discovers via _common.resolve_ext_dir().
#
# Selection
# ---------
#   CLAUDE_CODE_EXT_PATCHS=all                     every patcher (default)
#   CLAUDE_CODE_EXT_PATCHS=none                    no patcher at all
#   CLAUDE_CODE_EXT_PATCHS=ux,fix                  every patcher in those categories
#   CLAUDE_CODE_EXT_PATCHS=model-badge-footer      one patcher by name (no .py)
#   CLAUDE_CODE_EXT_PATCHS=ux,handle-uri-workspace categories and names mix freely
#
# Categories and sentinels are read from each patcher's `# @patch-*` header,
# which is the registry — see PATCHES.md for the human-readable version and
# AUTHORING.md for the header contract.
#
# Two regimes of failure, deliberately different
# ----------------------------------------------
# A patcher that FAILS (its regex no longer matches after a Claude Code bump)
# is reported and the orchestrator still exits 0: a broken cosmetic patch must
# not fail the container build.
#
# A selection token that names nothing exits 2 BEFORE anything runs. A typo is
# a configuration error, not a patch regression — left silent it would read as
# "that patch does not exist, so it is not applied", which is exactly the kind
# of difference nobody notices until the feature is missing in production.

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
EXT_DIR="${1:-}"
SELECTION="${CLAUDE_CODE_EXT_PATCHS:-all}"

CATEGORIES="ux fix notify"

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
BOLD='\033[1m'
RESET='\033[0m'

# Reads a single-valued `# @patch-<field>:` header line from a patcher.
meta_field() { sed -n "s/^# @patch-$2: //p" "$1" | head -1; }

# EXT_DIR is forwarded only when set: an empty string would reach
# resolve_ext_dir() as argv[1] and defeat its auto-discovery. Kept a function
# so the caller's `$?` is the patcher's exit code and not a test's.
run_patcher() {
    if [ -n "$EXT_DIR" ]; then
        python3 "$1" "$EXT_DIR"
    else
        python3 "$1"
    fi
}

# The same red banner _common.banner draws on the Python side. Redrawn here
# rather than shelled out to, because reaching it would mean a `python3 -c`
# with a sys.path hack for pure presentation.
banner() {
    local bar; bar="$(printf '═%.0s' {1..78})"
    {
        printf '\n%b%b%s\n' "$RED" "$BOLD" "$bar"
        printf '  ⚠  %s\n' "$1"
        shift
        for line in "$@"; do printf '  %s\n' "$line"; done
        printf '%s%b\n\n' "$bar" "$RESET"
    } >&2
}

# ---------------------------------------------------------------------------
# Registry — every patcher present, with the category it declares
# ---------------------------------------------------------------------------
names=()
cats=()
shopt -s nullglob
for py in "$DIR"/*.py; do
    base="${py##*/}"
    [ "$base" = "_common.py" ] && continue
    name="${base%.py}"
    cat="$(meta_field "$py" category)"
    if [ -z "$cat" ]; then
        banner "PATCHER WITHOUT A CATEGORY" \
            "$base declares no '# @patch-category:' header." \
            "Every patcher must carry one — see AUTHORING.md." \
            "Refusing to guess: nothing was applied."
        exit 2
    fi
    names+=("$name")
    cats+=("$cat")
done

if [ "${#names[@]}" -eq 0 ]; then
    printf '%bno patchers found in %s%b\n' "$YELLOW" "$DIR" "$RESET" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Selection — resolved in full BEFORE the first patcher runs
# ---------------------------------------------------------------------------
selected=" "   # space-delimited set of names, always framed by spaces
unknown=()

case "$SELECTION" in
    all)
        for n in "${names[@]}"; do selected="$selected$n "; done
        ;;
    none)
        ;;
    *)
        # Trim each token: a human-written list is `ux, fix` as often as `ux,fix`.
        IFS=',' read -r -a tokens <<< "$SELECTION"
        for tok in "${tokens[@]}"; do
            tok="${tok#"${tok%%[![:space:]]*}"}"
            tok="${tok%"${tok##*[![:space:]]}"}"
            [ -z "$tok" ] && continue
            hit=0
            # A category selects every patcher that declares it.
            case " $CATEGORIES " in
                *" $tok "*)
                    hit=1
                    i=0
                    for n in "${names[@]}"; do
                        [ "${cats[$i]}" = "$tok" ] && selected="$selected$n "
                        i=$((i + 1))
                    done
                    ;;
            esac
            # A bare name adds itself to whatever the tokens before it selected;
            # it never replaces them, so `ux,handle-uri-workspace` is eight
            # patchers and not one. `selected` is a membership set tested with a
            # substring match, and the run loop below walks the patchers rather
            # than this string — so naming one twice is harmless by
            # construction, and needs no guard.
            if [ "$hit" -eq 0 ]; then
                for n in "${names[@]}"; do
                    if [ "$n" = "$tok" ]; then
                        hit=1
                        selected="$selected$n "
                        break
                    fi
                done
            fi
            [ "$hit" -eq 0 ] && unknown+=("$tok")
        done
        ;;
esac

if [ "${#unknown[@]}" -gt 0 ]; then
    # The patch list is what the reader actually needs here, so it is folded
    # onto readable lines rather than emitted as one 500-column string.
    catalogue=()
    # `|| [ -n "$line" ]` — fold's last line carries no trailing newline, and
    # a bare `read` would drop it. Same rule as conf_entries in devc-conf.sh.
    while IFS= read -r line || [ -n "$line" ]; do catalogue+=("  $line"); done < <(
        printf '%s ' "${names[@]}" | fold -s -w 68 | sed 's/[[:space:]]*$//'
    )
    banner "UNKNOWN PATCH SELECTION" \
        "CLAUDE_CODE_EXT_PATCHS=$SELECTION" \
        "Not a patch name nor a category: ${unknown[*]}" \
        "" \
        "Valid keywords   : all none" \
        "Valid categories : $CATEGORIES" \
        "Valid patches    :" \
        "${catalogue[@]}" \
        "" \
        "Nothing was applied. A typo here would silently drop a patch."
    exit 2
fi

# A patcher marked `# @patch-critical: true` is one the extension does not
# survive without. Excluding it is allowed — `none` means none — but it is
# never silent.
for n in "${names[@]}"; do
    case "$selected" in
        *" $n "*) ;;
        *)
            if [ "$(meta_field "$DIR/$n.py" critical)" = "true" ]; then
                banner "A CRITICAL PATCH IS BEING SKIPPED" \
                    "$n is excluded by CLAUDE_CODE_EXT_PATCHS=$SELECTION" \
                    "The Claude Code extension will NOT activate without it." \
                    "See PATCHES.md — this is expected only if you meant it." \
                    "Recover at runtime with: restore-ext-patches <selection>"
            fi
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
failed=()
ok=()
skipped=()
total=0

i=0
for name in "${names[@]}"; do
    cat="${cats[$i]}"
    i=$((i + 1))
    case "$selected" in
        *" $name "*) ;;
        *) skipped+=("$name ($cat)"); continue ;;
    esac
    total=$((total + 1))
    echo ""
    printf '%b→ %s%b\n' "$BOLD" "$name.py" "$RESET"
    if run_patcher "$DIR/$name.py"; then
        ok+=("$name")
    else
        rc=$?
        failed+=("$name (exit $rc)")
    fi
done

echo ""
printf '%b═══ vscode-ext-patchs summary (%d of %d script%s, selection: %s) ═══%b\n' \
    "$BOLD" "$total" "${#names[@]}" \
    "$([ "${#names[@]}" -eq 1 ] && echo '' || echo 's')" "$SELECTION" "$RESET"
if [ "${#ok[@]}" -gt 0 ]; then
    for n in "${ok[@]}"; do
        printf '  %bOK%b      %s\n' "$GREEN" "$RESET" "$n"
    done
fi
if [ "${#skipped[@]}" -gt 0 ]; then
    for n in "${skipped[@]}"; do
        printf '  %bSKIP%b    %s\n' "$YELLOW" "$RESET" "$n"
    done
fi
if [ "${#failed[@]}" -gt 0 ]; then
    for n in "${failed[@]}"; do
        printf '  %bFAILED%b  %s\n' "$RED" "$RESET" "$n"
    done
    printf '%bNote%b: orchestrator stays green — these are cosmetic patches.\n' \
        "$YELLOW" "$RESET"
fi

exit 0
