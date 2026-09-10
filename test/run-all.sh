#!/usr/bin/env bash
# Single entry point for every base-image suite. Figures out what this machine
# can run, runs exactly that, and names what it could not.
#
#   bash test/run-all.sh          # from anywhere, host or container
#   wtf image test                # same thing, from the monorepo
#   IMG=ghcr.io/…:TAG bash test/run-all.sh
#
# No suite runs in both contexts, and that is by design:
#
#   in the container: manifest, firewall, overlay layer 1 (need GNU coreutils,
#                      bash 4+, the image's own python3)
#   on the host:      overlay layer 2, image suites (need Docker)
#
# So a full pass is TWO runs of this script, one per side. The summary says
# which side you just did and what the other one still owes.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IMG="${IMG:-devcontainer-base:local}"
export IMG

# --no-inner: do not replay the container half inside a throwaway container.
# Set automatically by the nested call below - a human only needs it to run
# the host half in isolation.
INNER=1
[ "${1:-}" = "--no-inner" ] && INNER=0

HAS_GNU=1
stat -c '%a' package.json >/dev/null 2>&1 || HAS_GNU=0
[ "${BASH_VERSINFO[0]}" -ge 4 ] || HAS_GNU=0
HAS_DOCKER=0
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && HAS_DOCKER=1

# --- Capture ----------------------------------------------------------------
# The host half of this suite runs on the Mac, where nothing can read its
# output back. The repo is bind-mounted into the devcontainer, so the run
# writes itself into the tree at a DETERMINISTIC path - one file per side,
# overwritten each run. That is what makes "I ran it on the host" checkable
# instead of pasted. `*.log` is already gitignored here.
SIDE=$([ -f /.dockerenv ] && echo container || echo host)
RESULTS="$REPO/test/results"
LOG="$RESULTS/$SIDE.log"
# The nested call runs as `node` (the Dockerfile USER) on a host bind mount:
# Docker Desktop maps ownership, a Linux host would not. If the write is
# refused, fall back instead of dying on the exec.
if ! mkdir -p "$RESULTS" 2>/dev/null || ! : > "$LOG" 2>/dev/null; then
  LOG="$(mktemp -t run-all-XXXX)"
  echo "⚠ $RESULTS not writable - output redirected to $LOG" >&2
fi
exec > >(tee -a "$LOG") 2>&1
echo "# run-all.sh - $SIDE - $(date '+%Y-%m-%d %H:%M:%S %Z')"

RAN=(); SKIPPED=(); BROKEN=()

run() {                    # run <label> <condition> <why-not> <cmd...>
  local label="$1" cond="$2" why="$3"; shift 3
  if [ "$cond" -eq 0 ]; then
    SKIPPED+=("$label - $why")
    return 0
  fi
  echo
  echo "┌── $label"
  if "$@"; then
    RAN+=("$label")
  else
    BROKEN+=("$label")
  fi
  echo "└── $label"
}

echo "═══════════════════════════════════════════════════"
echo " base image - suites"
echo "   side   : $([ -f /.dockerenv ] && echo 'container' || echo 'host') / $(uname -s) $(uname -m)"
echo "   image  : $IMG"
echo "═══════════════════════════════════════════════════"

run "conf (the shared .txt line format)" "$HAS_GNU" \
    "needs bash 4 -> run it in the container" \
    bash test/conf.test.sh

run "manifest (tree = COPY manifest)" "$HAS_GNU" \
    "needs GNU coreutils + bash 4 -> run it in the container" \
    bash test/manifest.test.sh

run "firewall (parse, split, bake, fastpath, reload, addons)" "$HAS_GNU" \
    "needs GNU coreutils -> run it in the container" \
    bash test/run-firewall-suites.sh

# Static half of the patch registry + the selection driven against a throwaway
# extension dir. The baked half (sentinels in a real bundle, pristine copies)
# is in the image and extend suites.
run "patches (registry, PATCHES.md, selection)" "$HAS_GNU" \
    "needs bash 4 -> run it in the container" \
    bash test/patches.test.sh

# Self-dispatching: layer 1 here, layer 2 on the host. Always worth calling.
run "overlay (skills/hooks: add, replace, disable)" 1 "" \
    bash test/overlay.test.sh

run "image (layout, labels, live firewall, project bake)" "$HAS_DOCKER" \
    "needs Docker -> run it on the host" \
    bash test/run-image-suites.sh

# The packet-filter half of the firewall contract: opening a host port opens
# THAT PORT, not the host. Spawns a sibling container and two host mini-servers
# and measures all four endpoints through the live ruleset. Separate from the
# image suites because it builds its own network topology.
run "port-gate basic (E2E: reload + host/sibling port contract)" "$HAS_DOCKER" \
    "needs Docker -> run it on the host" \
    bash test/reload-basic-isolated.sh

# Same port contract, plus the L7 layer that only exists in strict. The packet
# filter is mode-independent by construction, so this is the measurement that
# turns that reading of the code into a fact.
run "port-gate strict (E2E: reload + L7 + host/sibling port contract)" "$HAS_DOCKER" \
    "needs Docker -> run it on the host" \
    bash test/reload-strict-isolated.sh

# Level 2 of the extension contract. Builds an image FROM the one under test,
# so it has no unit half: a directory is not a layer.
run "extend (level 2: hook, skill, firewall from an extending Dockerfile)" "$HAS_DOCKER" \
    "needs Docker -> run it on the host" \
    bash test/extend.test.sh

# --- The container half, driven from the host -------------------------------
# It needs bash 4 and GNU coreutils, which the Mac does not have - but the
# image under test does. So replay it INSIDE a throwaway container of that
# image, and never in the dogfood devcontainer: that one runs a DIFFERENT
# image and would test the wrong binary. Result: on the host, a single
# command covers both halves and nothing needs to be started first.
if [ "$HAS_DOCKER" -eq 1 ] && [ "$INNER" -eq 1 ]; then
  run "container half (run INSIDE $IMG)" 1 "" \
      docker run --rm -v "$REPO:/repo" -w /repo "$IMG" bash test/run-all.sh --no-inner
fi

echo
echo "═══════════════════════════════════════════════════"
for l in "${RAN[@]:-}";     do [ -n "$l" ] && echo "  ✔ $l"; done
for l in "${BROKEN[@]:-}";  do [ -n "$l" ] && echo "  ✘ $l"; done
for l in "${SKIPPED[@]:-}"; do [ -n "$l" ] && echo "  – $l"; done
echo "═══════════════════════════════════════════════════"

# Machine-readable trailer - this is what the other half reads back.
echo "## VERDICT side=$SIDE ran=${#RAN[@]} broken=${#BROKEN[@]} skipped=${#SKIPPED[@]} date=$(date '+%Y-%m-%d %H:%M:%S')"

# --- Consolidated report ----------------------------------------------------
# A green half says nothing about the other one. This block reads the other
# side's file back and refuses to claim full coverage until both have run
# ON THE SAME version of the code.
OTHER_SIDE=$([ "$SIDE" = "host" ] && echo container || echo host)
OTHER="$RESULTS/$OTHER_SIDE.log"

verdict_line() {   # verdict_line <side> <ran> <broken> <date> <stale>
  local mark="✔"
  [ "$3" -gt 0 ] && mark="✘"
  [ "$5" = "stale" ] && mark="⚠"
  printf '  %s %-10s half  %s suite(s) ok, %s failed - %s%s\n' \
    "$mark" "$1" "$2" "$3" "$4" \
    "$([ "$5" = "stale" ] && echo '  <- STALE: the code changed since' || echo '')"
}

echo
echo "═══ coverage of both halves ═══"
verdict_line "$SIDE" "${#RAN[@]}" "${#BROKEN[@]}" "just now" fresh
COMPLETE=0
if [ -f "$OTHER" ] && grep -q '^## VERDICT' "$OTHER" 2>/dev/null; then
  V=$(grep '^## VERDICT' "$OTHER" | tail -1)
  O_RAN=$(printf '%s' "$V" | sed -n 's/.*ran=\([0-9]*\).*/\1/p')
  O_BROKEN=$(printf '%s' "$V" | sed -n 's/.*broken=\([0-9]*\).*/\1/p')
  O_DATE=$(printf '%s' "$V" | sed -n 's/.*date=//p')
  # Stale = some source file is newer than this result. `results` is pruned,
  # or the log we just wrote would always make the other side look stale.
  STALE=fresh
  [ -n "$(find "$REPO/bin" "$REPO/assets" "$REPO/test" "$REPO/Dockerfile" \
          -name results -prune -o -newer "$OTHER" -print -quit 2>/dev/null)" ] && STALE=stale
  verdict_line "$OTHER_SIDE" "${O_RAN:-0}" "${O_BROKEN:-0}" "$O_DATE" "$STALE"
  [ "${O_BROKEN:-1}" -eq 0 ] && [ "$STALE" = fresh ] && [ "${#BROKEN[@]}" -eq 0 ] && COMPLETE=1
else
  printf '  ✘ %-10s half  never run\n' "$OTHER_SIDE"
fi

echo
if [ "$COMPLETE" -eq 1 ]; then
  echo "-> FULL COVERAGE: both halves are green on this version."
else
  echo "-> INCOMPLETE COVERAGE. The $OTHER_SIDE half is missing:"
  if [ "$OTHER_SIDE" = "host" ]; then
    echo "     on the Mac, Docker running:  wtf image test"
  else
    echo "     in the devcontainer:        wtf image test"
    echo "     (or from the host: it replays itself inside the image)"
  fi
fi
echo
echo "Output written to: packages/devcontainer-base/test/results/$SIDE.log"
echo "  -> the workspace is bind-mounted: Claude reads it from the container,"
echo "     just ask it to read the $SIDE result."

# The tee subprocess must flush before the shell exits, or the last lines
# reach the terminal but not the file - precisely the lines that carry the
# verdict.
exec 1>&- 2>&-
wait
[ "${#BROKEN[@]}" -eq 0 ]
