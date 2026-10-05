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
# Three regimes of failure, deliberately different
# ------------------------------------------------
# A COSMETIC patcher that FAILS (its regex no longer matches after a Claude
# Code bump) is reported and the orchestrator still exits 0: a broken cosmetic
# patch must not fail the container build.
#
# A CRITICAL patcher — `# @patch-critical: true`, one the extension does not
# activate without — that fails, or that reports success while leaving a step
# it declared unwritten, exits 1. `critical` used to be read in exactly one
# place, the de-selected branch, so a critical patcher that broke was filed
# beside the cosmetic ones under a line claiming all of them were cosmetic.
# Traced, not assumed: this cannot stop a container booting — see the note
# above the exit at the foot of this file.
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

# Every `# @patch-<field>:` line, in declaration order. meta_field's `head -1`
# is correct for a single-valued field and silently wrong for a repeated one —
# it returns the first and drops the rest. `@patch-step` is repeated by design,
# so it needs its own reader rather than a caller remembering the difference.
meta_list() { sed -n "s/^# @patch-$2: //p" "$1"; }

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
    # A patcher's own stdout is DETAIL; this summary is the fact. Indenting it
    # here is what files thirteen identical "Patching Claude Code extension at:
    # <100-character path>" lines and eleven "✓ … complete" under the phase log
    # instead of the screen — without a release of the patchers' own repo, which
    # is where those lines live. stderr is deliberately NOT indented: a
    # patcher's banner is an alarm and has to stay visible.
    #
    # A bash loop, not `sed 's/^/  /'`: sed block-buffers when its stdout is a
    # pipe, and the dispatcher's sink IS a pipe, so the detail would land in the
    # log out of order with the lines around it. An analysable log is ordered.
    local rc
    if [ -n "$EXT_DIR" ]; then
        PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 "$1" "$EXT_DIR" \
          | while IFS= read -r l || [ -n "$l" ]; do printf '  %s\n' "$l"; done
        rc=${PIPESTATUS[0]}
    else
        PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 "$1" \
          | while IFS= read -r l || [ -n "$l" ]; do printf '  %s\n' "$l"; done
        rc=${PIPESTATUS[0]}
    fi
    return "$rc"
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
crits=()
has_bounds=""
has_steps=""
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
    # Read here rather than at the point of use, for the reason the bounds are:
    # the registry is the one pass over every patcher's header, and a field read
    # lazily in the Run loop is a field that is re-sed'ed on every iteration.
    # `critical` was previously read only on the de-selected branch.
    [ -n "$(meta_list "$py" step)$(meta_list "$py" step-waived)" ] && has_steps=1
    names+=("$name")
    cats+=("$cat")
    mins+=("$min_v")
    maxs+=("$max_v")
    crits+=("$(meta_field "$py" critical)")
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
# The bundle to read the step markers back out of — resolved ONCE, and only if
# a patcher declares a step
# ---------------------------------------------------------------------------
# Same resolution as the version gate above, and the same fail-open regime: if
# the bundle cannot be located, verification turns OFF with a note instead of
# reporting sixteen absent markers. A checker nobody can evaluate must not
# start inventing failures — that is how a control becomes noise, and a noisy
# control is ignored, which makes it exactly as useful as a silent one.
VERIFY_DIR=""
if [ -n "$has_steps" ]; then
    RESOLVE_PY='
import sys
from _common import resolve_ext_dir
print(resolve_ext_dir(sys.argv))
'
    if [ -n "$EXT_DIR" ]; then
        VERIFY_DIR="$(PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -c "$RESOLVE_PY" "$EXT_DIR" 2>/dev/null)"
    else
        VERIFY_DIR="$(PYTHONPATH="$TOOLKIT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
            python3 -c "$RESOLVE_PY" 2>/dev/null)"
    fi
    if [ ! -d "$VERIFY_DIR" ]; then
        printf '%bstep verification off%b — no readable bundle in %s\n' \
            "$YELLOW" "$RESET" "${EXT_DIR:-the auto-discovered extension}" >&2
        printf '  patchers will run and report for themselves, unverified.\n' >&2
        VERIFY_DIR=""
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
# A fifth bucket, and deliberately not a sixth spelling of FAILED: FAILED means
# the patcher exited non-zero and said so. UNVERIFIED means it exited ZERO and
# left no trace of a step it declared — it reported success and lied. Merging
# the two loses the distinction that matters, and would change what
# claude-ext-patchs/test/apply.test.sh counts when it greps `^  FAILED`.
unverified=()
total=0
crit_failed=""

i=0
for name in "${names[@]}"; do
    cat="${cats[$i]}"
    min_v="${mins[$i]}"
    max_v="${maxs[$i]}"
    crit="${crits[$i]}"
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
    # Promoted, and counted. Indenting this was wrong: applying sixteen patchers
    # takes ~18s and it was the one stretch of the boot with nothing to look at,
    # which is worse than a few lines. The `→ <name>.py` substring is preserved
    # verbatim because toolkit.test.sh greps exactly that, unanchored.
    printf '  %b→ %s%b  (%d/%d)\n' "$BOLD" "$name.py" "$RESET" "$total" "${#names[@]}"
    if run_patcher "$DIR/$name.py"; then
        ok+=("$cat"$'\t'"$name")
    else
        rc=$?
        failed+=("$cat"$'\t'"$name (exit $rc)")
        # A patcher marked `# @patch-critical: true` is one the extension does
        # not survive without. Until now `critical` was read in exactly one
        # place — the de-selected branch — so a critical patcher that FAILED was
        # reported in the same breath as a cosmetic one, under a summary line
        # saying all of them were cosmetic. The banner goes here rather than in
        # the summary so it sits next to the patcher's own banner in the log,
        # where the two together say what broke and what it costs.
        if [ "$crit" = "true" ]; then
            crit_failed="$name"
            banner "A CRITICAL PATCH FAILED" \
                "$name exited $rc — see its own banner above." \
                "The Claude Code extension will NOT activate without it." \
                "See PATCHES.md, and recover with: restore-ext-patches <selection>"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Verification — did every step a patcher declared actually leave its mark?
# ---------------------------------------------------------------------------
# The defect this exists for: icon-fix-open-in-current-panel's step 4/6 had
# self-disabled from 2.1.268 on. It printed a yellow line, returned the content
# unchanged, and the patcher's main() exited 0 — so the orchestrator recorded a
# SUCCESS, there was no FAILED entry and nothing to shout about. A naive "every
# declared sentinel is present" check would not have caught it either: the
# patcher declared ONE marker, written by a DIFFERENT step, which stayed present
# the whole time. Nothing in the chain was lying. Nothing in it was looking.
#
# Hence per-step, and hence `@patch-step: <id> <file> <marker>`: a declaration a
# step cannot satisfy by accident, pinned to the file it writes. It is a new
# field rather than a richer @patch-sentinel because three readers already parse
# that one — restore-ext-patches, ext-patches-sync and the patchers' own
# registry suite — and a fourth column would break all three at once.
#
# Skew: an orchestrator ships in the image, the patchers ship on their own tag,
# and the two move independently. A patcher set that predates this field
# declares no step, so the loop body below runs zero times for it and the
# false-report count is ZERO BY CONSTRUCTION, not by measurement. That is the
# whole reason the gate is "absence of the field" and not a contract version
# number: a version number is one more thing that can be wrong, and it would
# buy nothing here.

# Prints one `<id>\t<file>\t<marker>` line per declared step whose marker is
# absent — and nothing at all for a patcher that declares none.
#
# AND across distinct ids, OR across the lines sharing one id. The alternation
# is load-bearing rather than a nicety: model-selection-fix applies a different
# flavour table per extension version and writes a different marker for the same
# step, so one required literal per step is unexpressible for it.
unsatisfied_steps() {   # unsatisfied_steps <name>
    local py="$DIR/$1.py" line id ids="" waived=" "
    local l_id l_file l_marker hit first_file first_marker
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        waived="$waived${line%%[[:space:]]*} "
    done < <(meta_list "$py" step-waived)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        id="${line%%[[:space:]]*}"
        case " $ids " in *" $id "*) continue ;; esac
        ids="$ids $id"
    done < <(meta_list "$py" step)
    for id in $ids; do
        # A waived step is one that CANNOT write an unconditional marker and
        # says so in its header — fix-style-pills' third step stripping a
        # predecessor's injection is the canonical one: on a clean bundle the
        # correct outcome is no bytes written. It counts toward the step total
        # and is never read. The waiver is a hole by design; what keeps it
        # honest is that it is declared, greppable and countable.
        case "$waived" in *" $id "*) continue ;; esac
        hit=""; first_file=""; first_marker=""
        while read -r l_id l_file l_marker; do
            [ "$l_id" = "$id" ] || continue
            [ -n "$l_marker" ] || continue
            [ -n "$first_file" ] || { first_file="$l_file"; first_marker="$l_marker"; }
            if [ -f "$VERIFY_DIR/$l_file" ] &&
               grep -qF -- "$l_marker" "$VERIFY_DIR/$l_file"; then
                hit=1
                break
            fi
        done < <(meta_list "$py" step)
        [ -n "$hit" ] && continue
        printf '%s\t%s\t%s\n' "$id" "${first_file:-?}" "${first_marker:-?}"
    done
}

# Only OK is verified. SKIPPED was never considered and N/A never ran, so both
# gates are excluded BY CONSTRUCTION rather than by a second spelling of them —
# the same argument the summary's grouping makes below. FAILED is excluded too:
# it has already been reported, and verifying it would double-report one defect.

# The critical flag by name: the registry's arrays are parallel to names[], and
# this pass walks ok[], which carries names rather than indices.
crit_of() {
    local n j=0
    for n in "${names[@]}"; do
        [ "$n" = "$1" ] && { printf '%s' "${crits[$j]}"; return 0; }
        j=$((j + 1))
    done
}

if [ -n "$VERIFY_DIR" ] && [ "${#ok[@]}" -gt 0 ]; then
    for e in "${ok[@]}"; do
        vcat="${e%%$'\t'*}"
        vname="${e#*$'\t'}"
        vbad=""
        while IFS=$'\t' read -r s_id s_file s_marker; do
            [ -n "$s_id" ] || continue
            vbad=1
            unverified+=("$vcat"$'\t'"$vname (step $s_id left no marker: $s_marker absent from $s_file)")
        done < <(unsatisfied_steps "$vname")
        # A critical patcher that reported success while leaving a declared step
        # unwritten is the same outcome as one that failed outright — the
        # extension is missing a piece it does not survive without — so it gets
        # the same policy. This is the only place verification touches the exit
        # status, and it does so through the critical flag, never on its own.
        if [ -n "$vbad" ] && [ "$(crit_of "$vname")" = "true" ]; then
            crit_failed="$vname"
            banner "A CRITICAL PATCH DID NOT FULLY APPLY" \
                "$vname exited 0 but left a declared step unwritten." \
                "The Claude Code extension will NOT activate without it." \
                "See the UNVERIFIED lines in the summary below."
        fi
    done
fi

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
# The existing line shapes are unchanged, deliberately:
# claude-ext-patchs/test/apply.test.sh greps this summary's header at :127 and
# counts `^  FAILED` — two leading spaces — at :131 and :165. SKIP no longer
# repeats the category it is filed under. UNVERIFIED is a NEW shape rather than
# a FAILED line with different wording, precisely so that count keeps meaning
# what it meant and the suite can assert the two independently.
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
    [ "${#unverified[@]}" -gt 0 ] && emit "$group" '  %bUNVERIFIED%b  %s\n' "$RED" "${unverified[@]}"
done

# The third regime, and the one the header block at the top of this file could
# not name until `critical` meant something at failure time. A cosmetic patch
# that breaks must not fail anything; a patch the extension does not ACTIVATE
# without is not a cosmetic patch, and saying "stays green" over it was the
# orchestrator describing a situation it had not looked at.
#
# What a non-zero exit costs, traced rather than assumed: restore-ext-patches
# propagates it verbatim; ext-patches-sync takes it as the `else` of an `if`,
# banners, withholds the stamp so the next boot retries, and exits 0 anyway;
# both lifecycle fragments are `|| true` and @required false. So this cannot
# stop a container from booting. On the build side Dockerfile's `|| exit $?`
# would fail an EXTENDING image that bakes its own critical patcher — which is
# the contract that Dockerfile already declares — while the published image
# bakes `CLAUDE_CODE_EXT_PATCHS=none`, under which every patcher is skipped and
# this flag cannot be set at all.
if [ -n "$crit_failed" ]; then
    printf '%bFAILED%b: critical patcher %s did not apply — exiting 1.\n' \
        "$RED" "$RESET" "$crit_failed"
    exit 1
fi

if [ "${#failed[@]}" -gt 0 ] || [ "${#unverified[@]}" -gt 0 ]; then
    printf '%bNote%b: orchestrator stays green — these are cosmetic patches.\n' \
        "$YELLOW" "$RESET"
fi

exit 0
