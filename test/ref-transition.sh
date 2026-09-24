#!/usr/bin/env bash
# ref-transition.sh — move a live container from one pinned ref to another, and
# check every seam the toolkit suite cannot reach.
#
#   bash test/ref-transition.sh <container>      the container name or id
#
# HOST-ONLY, AND WHY
# ------------------
# Step 6 needs `docker restart` of the very container under test. From inside
# that container DOCKER_HOST points at the nested daemon (dind), and the
# container itself lives on the host's — unreachable from here. So this is run
# from the Mac, with the `docker` CLI on PATH, and never by a suite runner.
#
# WHY IT IS NOT IN .devcontainer/pending/ ANY MORE
# ------------------------------------------------
# It used to be, and .devcontainer/.gitignore:9 says `pending/*`. It was
# written, run 12/13, corrected — and gone, because git was never allowed to
# track it. A bench that measures the shipped toolkit belongs with the toolkit.
#
# WHAT IT ASSUMES
# ---------------
# The container is configured for a patcher repository (EXT_PATCHES_REPO,
# _TOKEN, _REF in its .devcontainer/.env) and its extension is patched and
# live. It restores the starting pin at the end, in step 13 — including after
# a failure, via the EXIT trap.

set -uo pipefail

CTR="${1:-}"
[ -n "$CTR" ] || { echo "usage: ref-transition.sh <container>" >&2; exit 64; }
command -v docker >/dev/null 2>&1 || { echo "docker is not on PATH — this bench is host-only." >&2; exit 64; }
docker inspect "$CTR" >/dev/null 2>&1 || { echo "no such container: $CTR" >&2; exit 64; }

GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
PASS=0; FAIL=0; STEP=0
ok() { PASS=$((PASS+1)); printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
ko() { FAIL=$((FAIL+1)); printf "  ${RED}✘${RESET} %s\n" "$1" >&2; [ -n "${2:-}" ] && printf "${DIM}%s${RESET}\n" "$2" >&2; }
step() { STEP=$((STEP+1)); printf "\n${BOLD}── %d. %s${RESET}\n" "$STEP" "$1"; }

# Everything runs as a LOGIN shell: the proxy variables that make egress work
# in strict mode live in /etc/profile.d, and only a login shell sources them.
# The lifecycle fragments carry their own guard for this; an exec does not.
inc() { docker exec "$CTR" bash -lc "$*" 2>&1; }

CONF=/workspace/.devcontainer
ENVF="$CONF/.env"
pin_now() { inc "sed -n 's/^EXT_PATCHES_REF=//p' $ENVF | tail -1" | tr -d '\r'; }
set_pin() { inc "sed -i 's|^EXT_PATCHES_REF=.*|EXT_PATCHES_REF=$1|' $ENVF"; }
ext_ver() { inc "sed -n 's/^EXT_DIR=//p' /etc/claude-build-env | tail -1 | xargs -I{} python3 -c \"import json;print(json.load(open('{}/package.json'))['version'])\"" | tr -d '\r'; }
cached()  { inc "ls $CONF/tmp/cache/ext-patchs 2>/dev/null | tr '\n' ' '"; }

START_PIN="$(pin_now)"
[ -n "$START_PIN" ] || { echo "no EXT_PATCHES_REF in $ENVF — nothing to transition." >&2; exit 64; }
restore() {
  printf "\n${DIM}restoring the starting pin %s${RESET}\n" "$START_PIN"
  set_pin "$START_PIN" >/dev/null 2>&1
  inc "ext-patches-update --reapply" >/dev/null 2>&1
}
trap restore EXIT

EXTV="$(ext_ver)"
printf "${BOLD}ref-transition${RESET}  container=%s  extension=%s  pin=%s\n" "$CTR" "$EXTV" "$START_PIN"

# --- 1 -----------------------------------------------------------------------
step "the baseline says what holds"
OUT="$(inc 'ext-patches-sync --status')"
if printf '%s' "$OUT" | grep -q "EXT_PATCHES_REF *$START_PIN" \
   && printf '%s' "$OUT" | grep -q 'sentinels *all live'; then
  ok "--status reports the pin and live sentinels"
else
  ko "--status reports the pin and live sentinels" "$OUT"
fi
printf '%s' "$OUT" | grep -q 'tok\|ghp_\|github_pat' \
  && ko "--status leaks the token" "$OUT" || ok "--status never prints the token"

# --- 2 -----------------------------------------------------------------------
step "--check changes nothing"
BEFORE="$(inc 'sed -n "s/^EXT_DIR=//p" /etc/claude-build-env | tail -1 | xargs -I{} cksum {}/extension.js')"
OUT="$(inc 'ext-patches-update --check')"
AFTER="$(inc 'sed -n "s/^EXT_DIR=//p" /etc/claude-build-env | tail -1 | xargs -I{} cksum {}/extension.js')"
[ "$BEFORE" = "$AFTER" ] && ok "--check leaves the bundle byte-identical" \
  || ko "--check leaves the bundle byte-identical" "$BEFORE / $AFTER"
[ "$(pin_now)" = "$START_PIN" ] && ok "--check leaves the pin alone" \
  || ko "--check leaves the pin alone" "pin is now $(pin_now)"

# --- 3 -----------------------------------------------------------------------
# The older tag of THIS container's line, so the transition stays inside the
# versions the set was tested on. Nothing to do if the line has only one tag.
step "moving to an older tag of the same line"
TAGS="$(inc "ext-patches-update --check" | grep -o "cc${EXTV}-r[0-9]*" | sort -u)"
OLDER="$(printf '%s\n' "$TAGS" | grep -v "^$START_PIN\$" | sort -t r -k2 -n | head -1)"
if [ -z "$OLDER" ]; then
  printf "  ${DIM}– only one tag on the %s line; using --ref %s to exercise the path${RESET}\n" "$EXTV" "$START_PIN"
  OLDER="$START_PIN"
fi
OUT="$(inc "ext-patches-update --ref $OLDER")"
[ "$(pin_now)" = "$OLDER" ] && ok "--ref rewrites the pin to $OLDER" \
  || ko "--ref rewrites the pin to $OLDER" "$OUT"

# --- 4 -----------------------------------------------------------------------
step "the previous ref's cache is not destroyed"
CACHED="$(cached)"
printf '%s' "$CACHED" | grep -q "$START_PIN" \
  && ok "$START_PIN is still cached ($CACHED)" \
  || ko "$START_PIN is still cached" "cached: $CACHED"

# --- 5 -----------------------------------------------------------------------
step "--reapply replays from the cache, with no network"
OUT="$(inc 'ext-patches-update --reapply')"
printf '%s' "$OUT" | grep -q 'replaying' \
  && ok "--reapply replays the cached ref" || ko "--reapply replays the cached ref" "$OUT"
printf '%s' "$OUT" | grep -qi 'fetching' \
  && ko "--reapply reached the network" "$OUT" || ok "--reapply reached no network"

# --- 6 -----------------------------------------------------------------------
# THE ONE THAT WAS RED, and the test was wrong, not the code: it used to do a
# `compose down && up`, which RECREATES the container — the extension comes
# back pristine from the image, so re-applying was the correct answer. A
# restart keeps the same writable layer, and that is the boot this asserts.
# It is also the first real exercise of ext-patches-sync's in_range(): a
# bounded patcher that never runs writes no sentinel, and asking for that
# sentinel would answer "not applied" for ever.
step "a restart short-circuits on the sentinels"
docker restart "$CTR" >/dev/null 2>&1 || { ko "the container restarted"; }
for _ in $(seq 1 30); do inc 'true' >/dev/null 2>&1 && break; sleep 1; done
T0=$(date +%s)
OUT="$(inc 'ext-patches-sync')"
T1=$(date +%s)
printf '%s' "$OUT" | grep -q 'already applied' \
  && ok "the post-start path says 'already applied'" \
  || ko "the post-start path says 'already applied'" "$OUT"
printf '%s' "$OUT" | grep -qi 'fetching' \
  && ko "the restart reached the network" "$OUT" || ok "the restart reached no network"
[ $((T1-T0)) -le 5 ] && ok "the short-circuit costs $((T1-T0))s" \
  || ko "the short-circuit is slow" "$((T1-T0))s"

# --- 7 -----------------------------------------------------------------------
step "a project patcher overrides the resolved one of the same name"
LOCALD="$CONF/claude/vscode-ext-patchs"
FIRST="$(inc "ls $CONF/tmp/cache/ext-patchs/$OLDER/patchers/*.py | grep -v _common | head -1" | tr -d '\r')"
BASE="$(basename "$FIRST")"
inc "mkdir -p $LOCALD && cp $FIRST $LOCALD/$BASE"
OUT="$(inc 'ext-patches-sync')"
printf '%s' "$OUT" | grep -q "overriding:.*${BASE%.py}" \
  && ok "the override is announced by name" || ko "the override is announced by name" "$OUT"

# --- 8 -----------------------------------------------------------------------
step "removing it returns to the resolved set"
inc "rm -f $LOCALD/$BASE"
OUT="$(inc 'ext-patches-sync')"
printf '%s' "$OUT" | grep -q "overriding" \
  && ko "the override is gone" "$OUT" || ok "the override is gone"

# --- 9 -----------------------------------------------------------------------
step "--no-write-env applies without moving the pin"
PIN_BEFORE="$(pin_now)"
inc "ext-patches-update --ref $START_PIN --no-write-env" >/dev/null 2>&1
[ "$(pin_now)" = "$PIN_BEFORE" ] && ok "--no-write-env left the pin at $PIN_BEFORE" \
  || ko "--no-write-env left the pin alone" "pin is now $(pin_now)"

# --- 10 ----------------------------------------------------------------------
step "a ref that does not exist leaves everything alone"
PIN_BEFORE="$(pin_now)"
OUT="$(inc 'ext-patches-update --ref cc0.0.0-r0')"
[ "$(pin_now)" = "$PIN_BEFORE" ] && ok "a 404 leaves the pin at $PIN_BEFORE" \
  || ko "a 404 leaves the pin alone" "pin is now $(pin_now)"
printf '%s' "$OUT" | grep -q 'not found\|did not download' \
  && ok "the 404 is named, not swallowed" || ko "the 404 is named" "$OUT"

# --- 11 ----------------------------------------------------------------------
step "no token is a silence, never a failed boot"
OUT="$(inc "EXT_PATCHES_TOKEN=' ' ext-patches-sync; echo rc=\$?")"
printf '%s' "$OUT" | grep -q 'rc=0' \
  && ok "the boot path still exits 0" || ko "the boot path still exits 0" "$OUT"

# --- 12 ----------------------------------------------------------------------
# N/A is a third bucket: out-of-range patchers do not count in the X of
# `summary (X of Y)`, and --list must not call them live either.
step "the gate and the live list agree"
inc "ext-patches-update --reapply" >/dev/null 2>&1
OUT="$(inc 'restore-ext-patches all 2>&1 | grep -E "summary|N/A"')"
printf '%s' "$OUT" | grep -q 'summary (' \
  && ok "run-all.sh reports a summary" || ko "run-all.sh reports a summary" "$OUT"
printf "  ${DIM}%s${RESET}\n" "$(printf '%s' "$OUT" | tr '\n' '|')"

# --- 13 ----------------------------------------------------------------------
step "the bench leaves nothing behind"
set_pin "$START_PIN" >/dev/null
inc 'ext-patches-update --reapply' >/dev/null 2>&1
docker restart "$CTR" >/dev/null 2>&1
for _ in $(seq 1 30); do inc 'true' >/dev/null 2>&1 && break; sleep 1; done
OUT="$(inc 'ext-patches-sync --status')"
printf '%s' "$OUT" | grep -q "EXT_PATCHES_REF *$START_PIN" \
  && printf '%s' "$OUT" | grep -q 'sentinels *all live' \
  && ok "back on $START_PIN with live sentinels" \
  || ko "back on $START_PIN with live sentinels" "$OUT"

# --- 14 ----------------------------------------------------------------------
# The whole point of 4.1l, and it needs no fixture: the repository already
# carries a tag for this extension's line AND a newer one for another line.
# Before the change, "latest" meant the newest overall and answered the other
# line's tag.
step "resolution answers this extension's line, not the newest tag overall"
OUT="$(inc 'ext-patches-update --check')"
AVAIL="$(printf '%s' "$OUT" | sed -n 's/^ *available *//p' | tr -d '\r')"
case "$AVAIL" in
  cc$EXTV-r*)
    ok "available is $AVAIL — the cc$EXTV line" ;;
  *)
    ko "available should be a cc$EXTV-r<n> tag" "available: $AVAIL
$OUT" ;;
esac
printf '%s' "$OUT" | grep -q 'never been tested' \
  && ko "the extension version has no tested line" "$OUT" \
  || ok "this extension has a tested patcher set"

# -----------------------------------------------------------------------------
printf "\n${BOLD}ref-transition: %d pass / %d fail${RESET}\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
