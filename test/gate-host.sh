#!/usr/bin/env bash
# gate-host.sh — the release gate, played the way a release is actually
# authorised: against an extension left EXACTLY AS PUBLISHED.
#
#   bash test/gate-host.sh            # on the Mac, with VS Code and Docker Desktop
#
# HOST-ONLY, AND WHY
# ------------------
# The verdict this gate exists to produce is unreachable anywhere else. Its
# step 6 is a real "Reopen in Container" of a scratch project, and check 0 —
# "does the Claude panel open at all" — is read with human eyes in that window.
# Inside a devcontainer, release-check.sh marks steps 5/6/9 ∅ and the ledger
# takes a different shape, on purpose: nobody should be able to paste a
# container's output as proof that a release was authorised (RELEASING.md).
#
# WHY IT COMMENTS OUT EXT_PATCHES_* FIRST
# ---------------------------------------
# The image ships NO patcher and names no repository. release-check.sh copies
# the EXT_PATCHES_* of THIS checkout into the scratch project, so on a dogfood
# machine that is configured for patchers the scratch project patches its own
# copy — and then check 0 is answered about a PATCHED extension, which is not
# what is being published. Commenting them out for the duration is what makes
# check 0 the question RELEASING.md says it is. The EXIT trap puts the file
# back, including after a Ctrl-C or a failure: it is your live .env.
#
# WHY IT IS NOT IN .devcontainer/pending/
# ---------------------------------------
# Its ancestor was, and .devcontainer/.gitignore says `pending/*`, so git was
# never allowed to track it. It was written, run once, and lost with two other
# benches. A script that plays the release gate belongs with the release gate.
#
# Written for bash 3.2 and BSD userland: macOS Terminal ships an ancient bash,
# and `sed -i` there is not the GNU one — hence write-to-temp-then-move.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$REPO/../.." && pwd)"
DC_ENV="$PROJECT_ROOT/.devcontainer/.env"

if [ -f /.dockerenv ]; then
  cat >&2 <<'EOF'
gate-host.sh refuses to run inside a container.

The sanctioned verdict is `tier=GREEN_PARTIEL exit=2 green=7 partial=2 red=0`
over a 9-row ledger, and it needs a real VS Code window on the machine that
owns the Docker daemon. In here, steps 5/6/9 are ∅ and check 0 is never asked,
so whatever came out would not authorise anything.

Run the container half instead:  bash test/run-all.sh
EOF
  exit 64
fi

command -v docker >/dev/null 2>&1 || { echo "docker not on PATH" >&2; exit 64; }
command -v code   >/dev/null 2>&1 || { echo "the VS Code 'code' CLI is not on PATH — step 6 cannot open anything" >&2; exit 64; }

# --- neutralise the patchers for the duration, and put them back no matter what
RESTORED=0
restore_env() {
  [ "$RESTORED" -eq 1 ] && return 0
  RESTORED=1
  if [ -f "$DC_ENV.gate-host.bak" ]; then
    mv "$DC_ENV.gate-host.bak" "$DC_ENV" \
      && echo "restored $DC_ENV" \
      || echo "!! COULD NOT RESTORE $DC_ENV — your backup is at $DC_ENV.gate-host.bak" >&2
  fi
}
trap restore_env EXIT INT TERM

if [ -f "$DC_ENV" ]; then
  if grep -qE '^[[:space:]]*EXT_PATCHES_' "$DC_ENV"; then
    cp -p "$DC_ENV" "$DC_ENV.gate-host.bak" || { echo "cannot back up $DC_ENV" >&2; exit 1; }
    sed -e 's/^[[:space:]]*\(EXT_PATCHES_\)/#\1/' "$DC_ENV.gate-host.bak" > "$DC_ENV"
    echo "EXT_PATCHES_* commented out for this run — the scratch project will run"
    echo "the extension as published, which is what check 0 is about."
  else
    echo "no active EXT_PATCHES_* in $DC_ENV — the scratch project already runs"
    echo "the extension as published. Nothing to neutralise."
  fi
else
  echo "note: no $DC_ENV — nothing to neutralise."
fi

# --- the gate itself
echo
bash "$REPO/test/release-check.sh" --no-purge
RC=$?

restore_env

# --- the three conditions of RELEASING.md, checked rather than remembered
LOG="$REPO/test/results/release-check-host.log"
echo
echo "═══ the three conditions that authorise a release ═══"
echo "    (RELEASING.md § The gate that authorises a release)"

TRAILER="$(grep -a '^## RELEASE-CHECK tier=' "$LOG" 2>/dev/null | tail -1)"
if [ -z "$TRAILER" ]; then
  echo "  ❌ no trailer in $LOG — the run did not reach a verdict"
  exit 1
fi
echo "    $TRAILER"
echo

BAD=0
say() { echo "  $1 $2"; [ "$1" = "❌" ] && BAD=$((BAD + 1)); return 0; }

# 1 — tier and red
case "$TRAILER" in
  *"tier=GREEN_PARTIEL"*) case "$TRAILER" in
      *"red=0"*) say "✔" "1. tier=GREEN_PARTIEL and red=0" ;;
      *)         say "❌" "1. red is not 0 — a step failed" ;;
    esac ;;
  *) say "❌" "1. tier is not GREEN_PARTIEL" ;;
esac

# 2 — exactly 9 ledger rows. A different count means the script was edited
#     mid-run and a step recorded itself twice. Counted off the trailer's own
#     three tallies rather than by counting glyphs in the log: record() prints
#     the SAME glyphs live, while each step happens, so a whole-log count sees
#     every row twice.
N_G="$(printf '%s' "$TRAILER" | sed -n 's/.*green=\([0-9][0-9]*\).*/\1/p')"
N_P="$(printf '%s' "$TRAILER" | sed -n 's/.*partial=\([0-9][0-9]*\).*/\1/p')"
N_R="$(printf '%s' "$TRAILER" | sed -n 's/.*red=\([0-9][0-9]*\).*/\1/p')"
if [ -n "$N_G" ] && [ -n "$N_P" ] && [ -n "$N_R" ]; then
  ROWS=$((N_G + N_P + N_R))
else
  ROWS=0   # a fatal/interrupted trailer carries '-' for the three counts
fi
[ "$ROWS" -eq 9 ] \
  && say "✔" "2. the ledger has 9 rows" \
  || say "❌" "2. the ledger has $ROWS rows, expected 9 — a step recorded twice?"

# 3 — the two ⊘ are the deliberate ones of --no-purge, on steps 5 and 9, and
#     nowhere else. A ⊘ elsewhere is a step omitted for an unrelated reason.
#     Read from the FINAL table only — everything after the step 11 banner —
#     for the same reason as above, and anchored on the SHAPE of a ledger row
#     ("  <glyph> <step id>."): the verdict prose right under that table says
#     "deliberately not played (⊘ above)" and "replay the ⊘ steps", so a plain
#     grep for the glyph picks up two sentences, yields two empty ids, and
#     reds a gate that is in fact green. Measured on the run of 2026-09-11.
OMITTED="$(awk '/^═══ 11\. verdict ═══$/{f=1;next} f' "$LOG" 2>/dev/null \
           | grep -a '^  ⊘ [0-9]' \
           | sed -e 's/^[^0-9]*//' -e 's/[^0-9].*$//' \
           | sort | tr '\n' ' ')"
[ "$OMITTED" = "5 9 " ] \
  && say "✔" "3. the two ⊘ are on steps 5 and 9, and no other" \
  || say "❌" "3. ⊘ on step(s) '${OMITTED:-none}' — expected exactly '5 9'"

echo
if [ "$BAD" -eq 0 ] && [ "$RC" -eq 2 ]; then
  echo "GATE: the three conditions hold, exit=$RC. This authorises the release."
  echo "Remaining, and it is yours: was check 0 answered honestly? The gate"
  echo "records one bit for six visual checks — a typed 'ok' over a dead Claude"
  echo "panel records step 6 as PASS and nothing here can tell."
  exit 0
fi
echo "GATE: NOT authorised — $BAD condition(s) unmet, release-check exit=$RC (want 2)."
exit 1
