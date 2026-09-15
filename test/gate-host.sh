#!/usr/bin/env bash
# gate-host.sh — the release gate, played against the extension the image
# actually ships: EXACTLY AS PUBLISHED, no patcher.
#
#   bash test/gate-host.sh                  # what authorises a release
#   bash test/gate-host.sh --with-patchers  # the patcher axis, authorises nothing
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
# TWO PASSES, AND ONLY ONE OF THEM IS THE GATE
# --------------------------------------------
# The image ships NO patcher and names no repository, so what gets published is
# the unpatched extension and "does its panel open at all" is the shippability
# question. That is the default run, and its verdict is what authorises a
# release. release-check.sh copies the EXT_PATCHES_* of this checkout into the
# scratch project, so on a machine configured for patchers the human would be
# answering check 0 about a PATCHED extension — not what is being published.
# Hence the trap that comments them out and puts the file back afterwards,
# including after a Ctrl-C: it is your live .env.
#
# --with-patchers leaves them alone and plays the same steps on the patched
# extension. That answers a different question — do the injections still render
# on this Claude Code — and it authorises nothing about the image. Use it when a
# patcher line carries a derogation; bare-check.sh and patched-check.sh cover
# that axis properly.
#
# WHY THE WHOLE BODY SITS IN ONE BRACE GROUP
# ------------------------------------------
# Same reason release-check.sh does it, and it is not theoretical: bash reads a
# script incrementally, BY BYTE OFFSET, while running it. Editing the file
# mid-run shifts those offsets and bash resumes mid-line — measured here on
# 2026-09-14, a run that had already reached its verdict died on
# "syntax error near unexpected token `('" in a file that is syntactically
# clean under bash 3.2 and bash 5 alike. A brace group is parsed in full before
# any of it executes, so the file can be edited under a running gate.
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

{

WITH_PATCHERS=0
case "${1:-}" in
  "")               ;;
  --with-patchers)  WITH_PATCHERS=1 ;;
  *) echo "usage: gate-host.sh [--with-patchers]" >&2; exit 64 ;;
esac

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

# macOS does not hand a non-login shell the same PATH as your terminal. VS
# Code's own "local machine" terminal is the sharp case: the editor is launched
# by launchd, inherits launchd's PATH, and never sources your shell rc — so the
# Docker Desktop CLI (~/.docker/bin since 4.19) is missing there while being
# right there in Terminal.app. `command -v` in bash also sees neither a zsh
# alias nor a zsh function. Resolve it, prepend what we found so release-check
# and docker compose inherit it, and if it is genuinely absent say what was
# looked at rather than "not on PATH". Measured 2026-09-14.
need() {
  _cmd="$1"; shift
  command -v "$_cmd" >/dev/null 2>&1 && return 0
  for _c in "$@"; do
    if [ -x "$_c" ]; then
      PATH="${_c%/*}:$PATH"; export PATH
      echo "note: $_cmd was not on PATH — using $_c"
      return 0
    fi
  done
  {
    echo "cannot find '$_cmd', neither on PATH nor where it usually lives."
    echo "  PATH was: $PATH"
    echo "  looked at:"
    for _c in "$@"; do echo "    $_c"; done
    echo "  A zsh alias or function does not count — this is bash."
  } >&2
  return 1
}

need docker /usr/local/bin/docker /opt/homebrew/bin/docker \
     "$HOME/.docker/bin/docker" /Applications/Docker.app/Contents/Resources/bin/docker \
  || exit 64
need code /usr/local/bin/code /opt/homebrew/bin/code \
     "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
     "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  || { echo "step 6 opens a scratch project in VS Code — without 'code' there is nothing to open." >&2; exit 64; }

# A previous run that died without its trap — SIGKILL, a closed terminal —
# leaves the rewritten .env in place and the backup beside it. Measured on
# 2026-09-14: a dogfood running Claude Code 2.1.258 was left pinned to the
# 2.1.270 patcher line, which is exactly the mismatched pairing the per-version
# resolution exists to prevent, and silent because nobody reads .env twice a
# day. The backup IS the pristine file, so put it back before anything else —
# otherwise the next run backs up an already-mangled .env and makes the wrong
# state the new baseline.
if [ -f "$DC_ENV.gate-host.bak" ]; then
  echo "a previous gate-host.sh run did not restore $DC_ENV — putting the backup back first:"
  diff "$DC_ENV.gate-host.bak" "$DC_ENV" | sed -e 's/TOKEN=.*/TOKEN=…/' -e 's/^/    /'
  mv "$DC_ENV.gate-host.bak" "$DC_ENV" || { echo "could not restore it — resolve by hand" >&2; exit 1; }
fi

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

env_of() { grep -h "^$1=" "$DC_ENV" 2>/dev/null | tail -1 | cut -d= -f2-; }

PATCHED=0
if [ "$WITH_PATCHERS" -eq 1 ]; then
  # The token and the repository come from the environment first, so the PAT
  # never has to be typed into a file, and fall back to .env.
  EP_REPO="${EXT_PATCHES_REPO:-$(env_of EXT_PATCHES_REPO)}"
  EP_TOKEN="${EXT_PATCHES_TOKEN:-$(env_of EXT_PATCHES_TOKEN)}"
  [ -n "$EP_REPO" ] || { echo "--with-patchers: no EXT_PATCHES_REPO, in the environment or in $DC_ENV" >&2; exit 64; }
  [ -n "$EP_TOKEN" ] || { echo "--with-patchers: no EXT_PATCHES_TOKEN — the patcher repository is private, so the scratch project cannot fetch anything. Export it: EXT_PATCHES_TOKEN=ghp_… bash test/gate-host.sh --with-patchers" >&2; exit 64; }

  # THE REF MUST NAME THIS IMAGE'S CLAUDE CODE LINE, and the pin in .env almost
  # certainly does not. ext-patches-sync uses EXT_PATCHES_REF verbatim — it
  # fetches /tarball/$REF and never resolves — while release-check copies the
  # pin of THIS checkout into the scratch project. This machine is pinned for
  # the Claude Code it runs today; the image under test bakes whatever
  # Dockerfile ARG CLAUDE_CODE_VERSION says. Left alone, the pass would apply
  # one version's patcher set to another version's extension and render a
  # verdict about a pairing nobody ships. Resolve the right line instead, the
  # same way ext-patches-update does: the tags of this version, largest -r.
  CCVER="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=\([0-9][0-9.]*\).*/\1/p' "$REPO/Dockerfile" | head -1)"
  [ -n "$CCVER" ] || { echo "cannot read ARG CLAUDE_CODE_VERSION from $REPO/Dockerfile" >&2; exit 1; }

  echo "--with-patchers: the image under test bakes Claude Code $CCVER."
  echo "  asking $EP_REPO which cc$CCVER-r<n> line it publishes…"
  EP_REF="$(curl -fsSL -H "Authorization: Bearer $EP_TOKEN" \
              "https://api.github.com/repos/$EP_REPO/tags?per_page=100" 2>/dev/null \
            | python3 -c '
import json, re, sys
v = sys.argv[1]; best = None
try:    tags = json.load(sys.stdin)
except Exception: sys.exit(0)
for t in tags:
    m = re.match(r"^cc" + re.escape(v) + r"-r([0-9]+)$", t.get("name", ""))
    if m and (best is None or int(m.group(1)) > best[0]):
        best = (int(m.group(1)), t["name"])
print(best[1] if best else "")' "$CCVER")"

  if [ -z "$EP_REF" ]; then
    {
      echo "no cc$CCVER-r<n> tag is PUBLISHED on $EP_REPO."
      echo "A local tag does not count: the scratch project fetches over the network."
      echo "Push that line first, or play the pass without --with-patchers."
    } >&2
    exit 1
  fi
  echo "  using $EP_REF"

  cp -p "$DC_ENV" "$DC_ENV.gate-host.bak" || { echo "cannot back up $DC_ENV" >&2; exit 1; }
  {
    grep -v '^[[:space:]]*EXT_PATCHES_\(REF\|TOKEN\|REPO\)=' "$DC_ENV.gate-host.bak"
    printf 'EXT_PATCHES_REPO=%s\n'  "$EP_REPO"
    printf 'EXT_PATCHES_REF=%s\n'   "$EP_REF"
    printf 'EXT_PATCHES_TOKEN=%s\n' "$EP_TOKEN"
  } > "$DC_ENV"
  PATCHED=1

elif [ -f "$DC_ENV" ] && grep -qE '^[[:space:]]*EXT_PATCHES_' "$DC_ENV"; then
  cp -p "$DC_ENV" "$DC_ENV.gate-host.bak" || { echo "cannot back up $DC_ENV" >&2; exit 1; }
  sed -e 's/^[[:space:]]*\(EXT_PATCHES_\)/#\1/' "$DC_ENV.gate-host.bak" > "$DC_ENV"
  echo "EXT_PATCHES_* commented out for this run (restored on exit)."
fi

# --- what the human will and will not be able to see, said HERE.
# release-check.sh prints its six visual checks in one block at step 6, and
# checks 3 and 4 are rendered BY PATCHERS. Its own "nothing to render" note is
# ~300 lines earlier, at step 4, which in practice nobody reads next to the
# checklist. Asking someone to look for a badge that cannot exist is how a
# bench gets answered on faith. So say it immediately before handing over.
echo
echo "═══════════════════════════════════════════════════════════════════"
if [ "$PATCHED" -eq 1 ]; then
  cat <<'EOF'
  PASS: WITH PATCHERS — this authorises NOTHING about the image.

  The image ships no patcher; this pass measures YOUR patched copy. Its
  verdict is about the patchers on this Claude Code version, not about what
  gets published. The release is authorised by the default run.

  All six visual checks of step 6 can render. Checks 3 and 4 (the model
  badge, the /model picker) are the reason to play this pass at all.
EOF
else
  cat <<'EOF'
  PASS: AS PUBLISHED — this is the one that authorises a release.

  NO PATCHER IS APPLIED, because none ships in the image. So when step 6
  lists its six visual checks, further down:

    CHECK 0 is the whole question. DOES THE CLAUDE PANEL OPEN AT ALL?
            If the icon flashes and dies, look in the output channel for
            PendingMigrationError and answer NO — by Ctrl-C, which is the
            only way to record a failure here.

    CHECKS 3 AND 4 (model badge, /model picker) CANNOT RENDER. They are
            contributed by patchers and no patcher is applied. Their
            absence is the expected result, not a defect. Do not go
            looking for them, and do not fail the run over them.

  The gate records ONE bit for all six checks, so a typed "ok" over a dead
  panel is recorded as PASS and nothing downstream can tell.
EOF
fi
echo "═══════════════════════════════════════════════════════════════════"
echo
printf '  press return to start the gate, or Ctrl-C to stop here: '
read -r _

bash "$REPO/test/release-check.sh" --no-purge
RC=$?

restore_env

if [ "$PATCHED" -eq 1 ]; then
  echo
  echo "This was the --with-patchers pass. Whatever it says, it does not"
  echo "authorise a release: replay without the flag for that."
  exit "$RC"
fi

# --- the three conditions of RELEASING.md, checked rather than remembered
LOG="$REPO/test/results/release-check-host.log"
echo
echo "═══ the three conditions that authorise a release ═══"
echo "    RELEASING.md, section: The gate that authorises a release"

TRAILER="$(grep -a '^## RELEASE-CHECK tier=' "$LOG" 2>/dev/null | tail -1)"
if [ -z "$TRAILER" ]; then
  echo "  ❌ no trailer in $LOG — the run did not reach a verdict"
  exit 1
fi
echo "    $TRAILER"
echo

BAD=0
say() { echo "  $1 $2"; [ "$1" = "❌" ] && BAD=$((BAD + 1)); return 0; }

case "$TRAILER" in
  *"tier=GREEN_PARTIEL"*) case "$TRAILER" in
      *"red=0"*) say "✔" "1. tier=GREEN_PARTIEL and red=0" ;;
      *)         say "❌" "1. red is not 0 — a step failed" ;;
    esac ;;
  *) say "❌" "1. tier is not GREEN_PARTIEL" ;;
esac

# Row count off the trailer's own tallies, not by counting glyphs in the log:
# record() prints the SAME glyphs live while each step happens, so a whole-log
# count sees every row twice.
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

# Omitted steps read from the FINAL table only, anchored on the SHAPE of a
# ledger row: the verdict prose right under that table says "deliberately not
# played (⊘ above)" and "replay the ⊘ steps", so a plain grep for the glyph
# picks up two sentences, yields two empty ids, and reds a green gate.
OMITTED="$(awk '/^═══ 11\. verdict ═══$/{f=1;next} f' "$LOG" 2>/dev/null \
           | grep -a '^  ⊘ [0-9]' \
           | sed -e 's/^[^0-9]*//' -e 's/[^0-9].*$//' \
           | sort | tr '\n' ' ')"
[ "$OMITTED" = "5 9 " ] \
  && say "✔" "3. the two omitted steps are 5 and 9, and no other" \
  || say "❌" "3. omitted step(s) '${OMITTED:-none}' — expected exactly '5 9'"

echo
if [ "$BAD" -eq 0 ] && [ "$RC" -eq 2 ]; then
  echo "GATE: the three conditions hold, exit=$RC. This authorises the release."
  exit 0
fi
echo "GATE: NOT authorised — $BAD condition(s) unmet, release-check exit=$RC (want 2)."
exit 1

}
