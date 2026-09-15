#!/usr/bin/env bash
# bench-matrix.sh — build ONE entry of the publish matrix and run every suite
# against it, then prove the suites measured the version you asked for.
#
#   bash test/bench-matrix.sh 2.1.270
#   bash test/bench-matrix.sh 2.1.220
#
# WHY BOTH BUILD ARGS, ALWAYS
# ---------------------------
# `run-image-suites.sh --build` passes only BASE_VERSION (see its build block).
# CLAUDE_CODE_VERSION then falls back to the Dockerfile default, so `--build`
# can never exercise a non-default matrix entry — it silently measures the
# default while printing the tag you named. CI does pass both
# (.github/workflows/publish.yml), which is exactly why a local pass that
# forgets one diverges from what ships.
#
# WHY THE THREE GREPS AT THE END ARE THE POINT
# --------------------------------------------
# The STALE IMAGE guard in run-image-suites.sh compares org.stitchu.base.version
# and nothing else. NOTHING in this repo compares org.stitchu.claude-code.version
# against anything. So an image built without --build-arg CLAUDE_CODE_VERSION on
# an up-to-date tree carries the Dockerfile default, finds the vendored VSIX for
# THAT version on disk, and the "as published" assertion passes — green, on the
# wrong Claude Code. A green exit code does not rule this out; the label line
# does. And "as published" SKIPS rather than fails when it has no reference to
# compare against, while SKIP does not touch the exit code — so "0 skipped" is
# part of the verdict, not decoration.
#
# WHY IT IS NOT IN .devcontainer/pending/
# ---------------------------------------
# Its ancestor was, and .devcontainer/.gitignore says `pending/*`. It was
# written, run, and gone — git was never allowed to track it. A bench that
# measures the shipped image belongs with the image.
#
# WHERE IT RUNS
# -------------
# Either side. Against the nested dind daemon it is a complete functional pass;
# against the Mac's daemon it is the same pass plus the suites that need real
# host networking. Neither builds more than ONE architecture — linux/arm64 and
# linux/amd64 only ever coexist in CI, under QEMU.
#
# Written for bash 3.2: macOS ships an ancient one.

set -uo pipefail

# One brace group, parsed in full before any of it runs, and every path exits
# INSIDE it — see gate-host.sh for why. Both halves matter: without the exit,
# bash returns to reading after `}` and a file edited mid-run resumes mid-line.
{

CCVER="${1:-}"
case "$CCVER" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: bench-matrix.sh <claude-code-version>   e.g. 2.1.270" >&2; exit 64 ;;
esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# macOS does not hand a non-login shell the same PATH as your terminal: the
# Docker Desktop CLI moved to ~/.docker/bin in 4.19, VS Code's `code` lives
# inside the app bundle, and `command -v` in bash sees neither a zsh alias nor
# a zsh function. Testing PATH alone therefore refuses to start on machines
# where the tool is right there. Resolve it instead, prepend what we found so
# the CHILD processes (release-check.sh, docker compose) inherit it, and when
# we genuinely cannot find it, say what was looked at rather than "not on PATH".
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
    echo "cannot find \`$_cmd\`, neither on PATH nor where it usually lives."
    echo "  PATH was: $PATH"
    echo "  looked at:"
    for _c in "$@"; do echo "    $_c"; done
    echo "  If it IS installed, run this script with its directory on PATH, e.g."
    echo "    PATH=\"\$(dirname \"\$(readlink -f \"\$(command -v $_cmd)\")\"):\$PATH\" bash $0"
    echo "  (a zsh alias or function does not count — this is bash.)"
  } >&2
  return 1
}

DOCKER_CANDIDATES="/usr/local/bin/docker /opt/homebrew/bin/docker $HOME/.docker/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker"

need docker $DOCKER_CANDIDATES || exit 64
need jq /usr/local/bin/jq /opt/homebrew/bin/jq || exit 64

BASE_VERSION="$(jq -r .version package.json)"
IMG="devcontainer-sandbox:cc${CCVER}"

# A version that is not in the matrix can still be benched — that is how you
# qualify one before adding it — but say so, because a green bench on a version
# CI does not build proves nothing about what ships.
jq -e --arg v "$CCVER" '.versions | index($v)' cc-versions.json >/dev/null 2>&1 \
  || echo "note: $CCVER is not in cc-versions.json — CI will not build it"

echo "═══ building $IMG (BASE_VERSION=$BASE_VERSION, CLAUDE_CODE_VERSION=$CCVER) ═══"
docker build -t "$IMG" \
  --build-arg BASE_VERSION="$BASE_VERSION" \
  --build-arg CLAUDE_CODE_VERSION="$CCVER" . \
  2>&1 | tee "test/results/bench-build-cc${CCVER}.log"
# ${PIPESTATUS[0]} — without it this reads tee's status and a failed build
# would walk straight into the suites against a stale image.
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "❌ build failed"; exit 1; }

# The Dockerfile swallows a failed VSIX download: it removes $EXT_DIR, prints to
# stderr and the build still succeeds, so the image ships WITHOUT the extension
# while looking healthy. Name it here, off the build log, before the suites.
if grep -qaE 'VSIX (download/extract failed|copy incomplete)' \
     "test/results/bench-build-cc${CCVER}.log"; then
  echo "❌ the VSIX failsafe branch fired — this image has no Claude Code extension"
  exit 1
fi

echo
echo "═══ suites against $IMG ═══"
LOG="test/results/bench-suites-cc${CCVER}.log"
IMG="$IMG" bash test/run-all.sh 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"

echo
echo "═══ did the suites measure $CCVER? ═══"
FAIL=0
want() {
  if grep -qa -- "$1" "$LOG"; then
    echo "  ✔ $2"
  else
    echo "  ❌ $2 — not found in $LOG"
    FAIL=$((FAIL + 1))
  fi
}
want "label org.stitchu.claude-code.version = $CCVER" "the image under test is Claude Code $CCVER"
want "built from this tree (version $BASE_VERSION)"   "…and was built from this tree ($BASE_VERSION)"
want "byte-identical to the published VSIX"           "the extension is byte-identical to the published VSIX"
want "– 0 skipped"                                    "nothing skipped — no assertion opted out in silence"

echo
if [ "$FAIL" -eq 0 ] && [ "$RC" -eq 0 ]; then
  echo "BENCH cc$CCVER: GREEN — suites exit $RC, 4/4 controls"
else
  echo "BENCH cc$CCVER: RED — suites exit $RC, $FAIL control(s) missing"
fi
if [ "$FAIL" -eq 0 ] && [ "$RC" -eq 0 ]; then exit 0; fi
exit 1

}
