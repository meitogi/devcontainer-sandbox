#!/bin/bash
# Orchestrator for vscode-ext-patchs/*.py
#
# Runs the SELECTED patch scripts against the given Claude Code extension
# directory, grouped by category and alphabetical within a group (_common.py
# excluded). Per-script exit status is captured and logged, so build logs make
# it trivial to see WHICH feature's regex broke after a Claude Code version
# bump.
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
#   CLAUDE_CODE_EXT_PATCHS=my-patch                one patcher by name (no .py)
#   CLAUDE_CODE_EXT_PATCHS=ux,my-patch             categories and names mix freely
#
# Categories and sentinels are read from each patcher's `# @patch-*` header,
# which is the registry — see AUTHORING.md for the header contract.
#
# Version bounds
# --------------
# A patcher may declare `# @patch-min-version:` / `# @patch-max-version:`
# (X.Y.Z, inclusive). Upstream sometimes fixes the defect a patcher worked
# around; the patcher is then bounded, never deleted, because the older
# versions in the matrix still need it — UPGRADING.md has the procedure.
#
# Out of range prints N/A and the patcher does NOT run. That is the whole
# value: a patcher that runs and fails can have written part of its work
# first, and if the file carrying its declared sentinel is among them,
# `restore-ext-patches --list` will call it applied afterwards.
#
# N/A is deliberately NOT the same bucket as SKIP, and it does not count in
# the summary's "X of Y": SKIP is "you deselected it", N/A is "it is not for
# this version of the extension".
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

# Where the patchers live. Defaults to this script's own directory — the shape
# an extending image gets when it drops a .py next to the orchestrator
# (EXTENDING.md). PATCH_DIR overrides it so the patchers can live anywhere:
# this image ships the toolkit WITHOUT patchers, and both restore-ext-patches
# and the 45-ext-patches.sh hook point it at a directory they assembled.
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${PATCH_DIR:-$TOOLKIT_DIR}"
EXT_DIR="${1:-}"
SELECTION="${CLAUDE_CODE_EXT_PATCHS:-all}"

CATEGORIES="ux fix notify"

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Reads a single-valued `# @patch-<field>:` header line from a patcher.
meta_field() { sed -n "s/^# @patch-$2: //p" "$1" | head -1; }

# X.Y.Z, digits only, exactly three fields. Stricter than it looks, on purpose:
# meta_field is sed with no validation, and build-manifest.py — which does
# validate — never runs here. A typo in a bound would otherwise read as "no
# bound at all" and the patcher would run anyway, silently. A version gate that
# fails open is worse than no gate.
is_version() {
    case "$1" in
        *[!0-9.]* | *.*.*.* ) return 1 ;;
        [0-9]*.[0-9]*.[0-9]*) return 0 ;;
        *)                    return 1 ;;
    esac
}

# A version as a zero-padded key. Comparing two of these as strings IS
# comparing the tuples of integers, which is the only correct order — "2.1.9"
# sorts above "2.1.258" the naive way. 10# forces base 10: bash arithmetic
# would read a leading zero as octal.
version_key() {
    local IFS=.
    set -- $1
    printf '%05d.%05d.%05d' "$((10#$1))" "$((10#$2))" "$((10#$3))"
}

# EXT_DIR is forwarded only when set: an empty string would reach
# resolve_ext_dir() as argv[1] and defeat its auto-discovery. Kept a function
# so the caller's `$?` is the patcher's exit code and not a test's.
# PYTHONPATH carries _common.py: a patcher does `from _common import ...`, which
# CPython resolves through sys.path[0] — the PATCHER's own directory. That is
# the toolkit directory only when the two coincide. With PATCH_DIR set they do
# not, so _common has to be reachable some other way, and PYTHONPATH is it.
run_patcher() {
    if [ -n "$EXT_DIR" ]; then
        PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 "$1" "$EXT_DIR"
    else
        PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 "$1"
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
mins=()
maxs=()
has_bounds=""
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
    # The category set is CLOSED — AUTHORING.md: "ux, fix or notify. Nothing
    # else is accepted." It was documented closed and never enforced, so a typo
    # registered fine, ran under `all`, and was invisible to a selection naming
    # the category it meant to declare: the patch silently stopped being
    # selectable while still looking applied. Same regime as a missing category.
    case " $CATEGORIES " in
        *" $cat "*) ;;
        *)
            banner "PATCHER WITH AN UNKNOWN CATEGORY" \
                "$base declares '# @patch-category: $cat'." \
                "The categories are: $CATEGORIES — nothing else is accepted." \
                "A category outside that set has no group to run in, and a" \
                "selection naming it would match nothing. See AUTHORING.md." \
                "Refusing to guess: nothing was applied."
            exit 2
            ;;
    esac
    # Bounds say which Claude Code versions a patcher is FOR. Optional, and
    # validated here rather than trusted: a malformed one exits 2 before
    # anything runs, the same regime as a missing category or an unknown
    # selection. See UPGRADING.md § "Bound, never delete".
    min_v="$(meta_field "$py" min-version)"
    max_v="$(meta_field "$py" max-version)"
    if [ -n "$min_v" ] && ! is_version "$min_v"; then
        banner "MALFORMED VERSION BOUND" \
            "$base declares '# @patch-min-version: $min_v'." \
            "A bound is X.Y.Z, digits only — see AUTHORING.md." \
            "Refusing to guess: nothing was applied."
        exit 2
    fi
    if [ -n "$max_v" ] && ! is_version "$max_v"; then
        banner "MALFORMED VERSION BOUND" \
            "$base declares '# @patch-max-version: $max_v'." \
            "A bound is X.Y.Z, digits only — see AUTHORING.md." \
            "Refusing to guess: nothing was applied."
        exit 2
    fi
    if [ -n "$min_v" ] && [ -n "$max_v" ] &&
       [ "$(version_key "$min_v")" \> "$(version_key "$max_v")" ]; then
        banner "IMPOSSIBLE VERSION RANGE" \
            "$base declares min-version $min_v > max-version $max_v." \
            "No extension version can ever satisfy it." \
            "Refusing to guess: nothing was applied."
        exit 2
    fi
    [ -n "$min_v$max_v" ] && has_bounds=1
    names+=("$name")
    cats+=("$cat")
    mins+=("$min_v")
    maxs+=("$max_v")
done

if [ "${#names[@]}" -eq 0 ]; then
    printf '%bno patchers found in %s%b\n' "$YELLOW" "$DIR" "$RESET" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# The extension's own version — resolved ONCE, and only if a bound needs it
# ---------------------------------------------------------------------------
# Same shape as model-badge-footer.py's ext_version(): the first three integer
# groups of package.json's "version", zero-filled. EXT_DIR is forwarded only
# when set, for the reason run_patcher states — an empty argv[1] would defeat
# resolve_ext_dir's auto-discovery.
#
# Unreadable version: the gate turns OFF rather than failing the run. That is
# what happens today, every patcher keeps reporting for itself, and the
# orchestrator's promise not to break a build survives. stderr is suppressed
# because resolve_ext_dir draws its own red banner, and one from the
# orchestrator here would be a second voice saying the same thing.
EXT_VERSION=""
if [ -n "$has_bounds" ]; then
    VERSION_PY='
import json, re, sys
from _common import resolve_ext_dir
raw = json.loads((resolve_ext_dir(sys.argv) / "package.json").read_text()).get("version", "")
parts = re.findall(r"\d+", raw)[:3]
print(".".join(parts + ["0"] * (3 - len(parts))) if parts else "")
'
    if [ -n "$EXT_DIR" ]; then
        EXT_VERSION="$(PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -c "$VERSION_PY" "$EXT_DIR" 2>/dev/null)"
    else
        EXT_VERSION="$(PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -c "$VERSION_PY" 2>/dev/null)"
    fi
    if ! is_version "$EXT_VERSION"; then
        printf '%bversion gate off%b — no readable extension version in %s\n' \
            "$YELLOW" "$RESET" "${EXT_DIR:-the auto-discovered extension}" >&2
        printf '  bounded patchers will run anyway and report for themselves.\n' >&2
        EXT_VERSION=""
    fi
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
            # it never replaces them, so `ux,my-patch` is every ux patcher
            # plus that one, not that one alone. `selected` is a membership set tested with a
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
na=()
total=0

i=0
for name in "${names[@]}"; do
    cat="${cats[$i]}"
    min_v="${mins[$i]}"
    max_v="${maxs[$i]}"
    i=$((i + 1))
    case "$selected" in
        *" $name "*) ;;
        *) skipped+=("$cat"$'\t'"$name"); continue ;;
    esac
    # Out of range is NOT a skip. SKIP means you deselected it and nothing was
    # ever considered; N/A means the patcher is not FOR this version of the
    # extension. Selection is tested first for exactly that reason. An N/A
    # patcher does not run at all, which is the point: a half-applied patcher
    # can leave its declared sentinel behind and read as live afterwards.
    if [ -n "$EXT_VERSION" ]; then
        reason=""
        if [ -n "$min_v" ] && [ "$(version_key "$EXT_VERSION")" \< "$(version_key "$min_v")" ]; then
            reason="needs ≥ $min_v"
        elif [ -n "$max_v" ] && [ "$(version_key "$EXT_VERSION")" \> "$(version_key "$max_v")" ]; then
            reason="needs ≤ $max_v"
        fi
        if [ -n "$reason" ]; then
            na+=("$cat"$'\t'"$name ($reason, extension is $EXT_VERSION)")
            continue
        fi
    fi
    total=$((total + 1))
    echo ""
    printf '%b→ %s%b\n' "$BOLD" "$name.py" "$RESET"
    if run_patcher "$DIR/$name.py"; then
        ok+=("$cat"$'\t'"$name")
    else
        rc=$?
        failed+=("$cat"$'\t'"$name (exit $rc)")
    fi
done

echo ""
printf '%b═══ vscode-ext-patchs summary (%d of %d script%s, selection: %s) ═══%b\n' \
    "$BOLD" "$total" "${#names[@]}" \
    "$([ "${#names[@]}" -eq 1 ] && echo '' || echo 's')" "$SELECTION" "$RESET"
# Grouped by the category each patcher declares. The category has been read and
# validated at registry build since 4.1c and shown nowhere since, so a run of
# sixteen patchers reported sixteen undifferentiated lines.
#
# The RUN order is deliberately NOT grouped. Grouping the run reorders patch
# application, and that order is load-bearing: webview-login-retry-button (ux)
# and user-action-observer (notify) rewrite the same onDidReceiveMessage
# chokepoint in extension.js, and only the one that gets there first still
# finds it. Measured, not feared — 8 red assertions in claude-ext-patchs on
# both tested versions. Presentation may group; application may not, until
# something declares that dependency.
#
# A group prints iff a registered patcher declares it. Every patcher lands in
# exactly one of the four buckets, so that rule cannot print an empty group,
# and it needs no second spelling of the selection and version gates.
#
# Line shapes are unchanged, deliberately: claude-ext-patchs/test/apply.test.sh
# greps this summary's header at :127 and counts `^  FAILED` — two leading
# spaces — at :131 and :165. SKIP no longer repeats the category it is filed
# under.
emit() {   # emit <group> <fmt> <colour> <entry...>
    local group="$1" fmt="$2" colour="$3"; shift 3
    local e
    for e in "$@"; do
        [ "${e%%$'\t'*}" = "$group" ] || continue
        # shellcheck disable=SC2059  # the format is a literal from the caller
        printf "$fmt" "$colour" "$RESET" "${e#*$'\t'}"
    done
}

for group in $CATEGORIES; do
    case " ${cats[*]} " in *" $group "*) ;; *) continue ;; esac
    printf '  %b── %s ──%b\n' "$DIM" "$group" "$RESET"
    [ "${#ok[@]}"      -gt 0 ] && emit "$group" '  %bOK%b      %s\n' "$GREEN"  "${ok[@]}"
    [ "${#skipped[@]}" -gt 0 ] && emit "$group" '  %bSKIP%b    %s\n' "$YELLOW" "${skipped[@]}"
    [ "${#na[@]}"      -gt 0 ] && emit "$group" '  %bN/A%b     %s\n' "$DIM"    "${na[@]}"
    [ "${#failed[@]}"  -gt 0 ] && emit "$group" '  %bFAILED%b  %s\n' "$RED"    "${failed[@]}"
done

if [ "${#failed[@]}" -gt 0 ]; then
    printf '%bNote%b: orchestrator stays green — these are cosmetic patches.\n' \
        "$YELLOW" "$RESET"
fi

exit 0
