#!/usr/bin/env bash
# packages/devcontainer-sandbox/test/release-check.sh  ==  wtf image release-check
#
# The full pre-publish gate, replayed at every minor/major bump. One command,
# one pass, one verdict on three tiers: GREEN (every step ran and was
# verified, exit 0), GREEN PARTIEL (nothing failed, but at least one step was
# deliberately not played, exit 2), RED (a step failed, or could not be played
# because something upstream broke, exit 1). Exit 0 means exactly one thing:
# this image is publishable.
#
#   wtf image release-check [--no-purge]
#   bash packages/devcontainer-sandbox/test/release-check.sh [--no-purge]
#
# Absorbs plans/devcontainer-v3/scripts/arm-5bis.sh + collect-5bis.sh
# (gitignored under plans/**, never committed — this script is their
# committed, versioned replacement). Two corrections ported from there,
# do not relose them:
#   I1 - pick the Dev Containers trace log by the workspace-folder line it
#        prints, NEVER by mtime: background windows keep writing (pty
#        errors, tunnel retries) and always win an mtime race.
#   I2 - purge the shared `vscode` volume as -u 0:0: its content is
#        root-owned, the image runs as `node`, and masking a permission
#        error there once made a failed purge look like a success.
#
# Host only: macOS (or Linux) with Docker Desktop and the VS Code `code`
# CLI on PATH. Everything runs except the visual checks TEST-PLAN-4 section
# D calls irreducibly human (badge/picker/webview rendering, window title,
# extension count at a glance) — this script prepares, waits, verifies the
# wait was real (a trace newer than the wait, naming the right workspace —
# not a typed "ok" taken on faith), then collects.
#
# Written for bash 3.2 (no associative arrays, no mapfile, no ${var,,},
# no negative array indices) — same constraint as arm-5bis.sh, macOS
# Terminal.app ships an ancient bash by default.

# Everything below runs inside ONE brace group, on purpose. bash reads a script
# incrementally, by byte offset, WHILE it runs it: editing the file mid-run
# shifts those offsets and bash resumes at the wrong place — it re-read the
# step 2-3 block during a real run on 2026-08-17 and recorded that step twice.
# A brace group is parsed in full before any of it executes, so the file can be
# edited under a running gate without the run losing its place. This matters
# because the gate runs for minutes while an agent may be editing it.
{

set -uo pipefail

# The machine trailer — see step 11 for the full contract. Defined FIRST, ahead
# of everything, because three callers need it and two of them fire on paths
# that never reach step 11: `fatal` (a run that dies at step 0) and the exit
# trap (a run the operator interrupted). A run without a verdict must still be
# machine readable. The three counts are `-` for those two because neither can
# know them; the key set stays constant for parsers, tier= first and date= last.
trailer() {   # trailer <TIER> <exit-code> <green> <partial> <red>
  printf '## RELEASE-CHECK tier=%s exit=%s green=%s partial=%s red=%s date=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# ---------------------------------------------------------------------------
# EXIT / INT / TERM trap — salvage, then the watch-log sentinel.
#
# Two hard contracts:
#   - `__END__` is the LAST line printed on every exit path (watch-log greps
#     it). The trap prints two other things, and only on a path where step 11
#     never ran: the INTERRUPTED trailer, and the newline that keeps it off the
#     prompt line the operator interrupted — the four `read -r` prompts end
#     without one, so a sentinel printed there would share their line. On every
#     path that HAS a verdict the trap prints the sentinel alone, so step 11's
#     trailer keeps its "last line before __END__" rule.
#   - rc is captured first and re-raised last. The exit code now carries three
#     meanings (0 GREEN / 2 GREEN PARTIEL / 1 RED); a cleanup command's own
#     status must never leak into it. An interrupt adds a fourth, 130/143, and
#     it is set literally rather than read from $? — see $INTERRUPTED below.
#
# Salvage rule — keep what diagnoses, remove what poisons the next run:
#   kept     $TGZ         the deliverable.
#   kept     $BUNDLE/*    the evidence of a run that died before step 10. Step
#                         10 removes the directory itself, and only once the
#                         tarball exists. A trap that deletes the evidence of
#                         the failure it just reported is worse than no trap.
#   kept     $BUILD_LOG   diagnosis material, never a cleanup target.
#   kept     $SCRATCH + the $DC_PROJECT stack — step 4 does its own loud,
#                         verified table rase at the START of the next run, and
#                         a container left Up is exactly what steps 8/9 exec
#                         into to diagnose.
#   removed  $BUNDLE      only when EMPTY: rmdir, never rm -rf. That is the
#                         litter of a run that died before collecting
#                         anything, one directory per attempt in ~/tmp.
#
# Defined BEFORE the trap is armed, and reading ${VAR:-}: arming a trap whose
# function does not exist yet means an exit in between prints "command not
# found" and no sentinel at all; and BUNDLE is only assigned ~20 lines down,
# where a bare $BUNDLE would die under `set -u`.
#
# WHY INT AND TERM ARE ARMED, since an EXIT trap alone looks like it should be
# enough: it does run on an untrapped SIGINT — measured identically under
# 3.2.57 and 5.3.15, `__END__` printed, process status 130 — but that 128+signal
# is applied by bash AFTER the handler returns, by re-raising the signal. Inside
# the handler `$?` still holds whatever the last command left there (measured: 1
# and 0 on two different paths), so an EXIT trap cannot tell an interrupted run
# from any other, and `exit "$rc"` is overridden anyway. The interrupt therefore
# has to name itself on the way in, which is all $INTERRUPTED does. Arming these
# also stops a Ctrl-C mid-build from being swallowed while bash waits on the
# child and letting the run stumble on into its failure path.
INTERRUPTED=0
cleanup() {
  rc=$?
  # Second statement, before anything else can re-enter: `exit "$rc"` below
  # would otherwise re-trigger this same handler through the EXIT arm and print
  # a second sentinel — measured, two `__END__` lines.
  trap - EXIT INT TERM
  if [ "$INTERRUPTED" -ne 0 ]; then rc="$INTERRUPTED"; fi
  # A terminal Ctrl-C signals the whole foreground process GROUP, so the
  # self-transcript's `tee` takes the same SIGINT and may already be gone —
  # every write below would then land in a pipe with no reader and kill this
  # handler with SIGPIPE. Measured on the real gate before this line: exit 141,
  # neither trailer nor sentinel, and the transcript cut two lines short.
  trap '' PIPE
  if [ -n "${BUNDLE:-}" ]; then rmdir "${BUNDLE}" 2>/dev/null; fi
  if [ "$INTERRUPTED" -ne 0 ]; then printf '\n'; trailer INTERRUPTED "$rc" - - -; fi
  echo "__END__"
  # Close stdout so the self-transcript's `tee` sees EOF, then let it finish
  # writing before we go: exiting first can truncate the file mid-sentence,
  # and the trailer + __END__ are the two lines a reader needs most. Prints
  # nothing, so the "__END__ is the last line" contract is untouched.
  if [ -n "${TEE_PID:-}" ]; then exec 1>&- 2>&-; wait "$TEE_PID" 2>/dev/null; fi
  # Last resort: a `tee` killed by the group signal dies with its stdio buffer
  # unflushed, so the two lines above are exactly the ones that go missing from
  # the file watch-log greps. Append them straight to the transcript when they
  # did not make it. On every normal exit the sentinel is already the last line,
  # so this writes nothing and nothing is ever duplicated.
  if [ -n "${RUN_LOG:-}" ] && [ -f "$RUN_LOG" ] \
     && [ "$(tail -1 "$RUN_LOG" 2>/dev/null)" != "__END__" ]; then
    { printf '\n'
      if [ "$INTERRUPTED" -ne 0 ]; then trailer INTERRUPTED "$rc" - - -; fi
      printf '__END__\n'; } >>"$RUN_LOG"
  fi
  exit "$rc"
}
trap 'INTERRUPTED=130; cleanup' INT
trap 'INTERRUPTED=143; cleanup' TERM
trap cleanup EXIT

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"                     # packages/devcontainer-sandbox
PROJECT_ROOT="$(cd "$REPO/../.." && pwd)"
TEMPLATE="$PROJECT_ROOT/templates/v3/project"
IMG="devcontainer-sandbox:local"
DC_PROJECT="v3test2"
DISPLAY_NAME="V3 Test 2"
CONTAINER="${DC_PROJECT}-claude-code-app-1"
CDN_HOST="vscode.download.prss.microsoft.com"

# ---------------------------------------------------------------------------
# Which half is running — the same probe run-all.sh:44 uses, and for the same
# reason: one command, no flag to forget, no env var to get wrong. Anything
# derived from it is decided ONCE, here, so no step has to ask twice.
#
#   host       the human's Mac. VS Code, the shared `vscode` volume, the six
#              visual checks. This is the reference path: it alone can print
#              GREEN and exit 0.
#   container  the agent, headless, against the NESTED daemon only. It plays
#              everything that does not need VS Code and reports NA for the
#              rest, so its success path is GREEN PARTIEL / exit 2 — never 0.
#
# Two constants MUST move agent-side, and it is not a matter of taste:
# $HOME/tmp lies OUTSIDE the /workspace bind mount that this container and the
# dind sidecar share at an identical path. Under DOCKER_HOST=tcp://dind:2375
# the SOURCE of a -v is resolved by the nested daemon, so a scratch project
# under $HOME/tmp would be mounted from a path dind cannot see: docker would
# create an empty directory there and every "nothing leaked" assertion in the
# suites would pass vacuously. assert_nested_path exists to prove the move
# actually happened rather than assume it.
SIDE=$([ -f /.dockerenv ] && echo container || echo host)

TS="$(date +%Y%m%d-%H%M%S)"
if [ "$SIDE" = container ]; then
  AGENT_TMP="$PROJECT_ROOT/.tmp/release-check"
  SCRATCH="$PROJECT_ROOT/.tmp/v3-test-2"
  BUNDLE="$AGENT_TMP/bundle-${TS}"
  IMAGE_TAR="$AGENT_TMP/image.tar"
  # Recorded in the handshake RELATIVE to the project root: the two sides see
  # this repo at different absolute paths (/workspace here, ~/dev/… there), so
  # an absolute path would be unusable by the reader.
  IMAGE_TAR_REL=".tmp/release-check/image.tar"
  # mktemp honours TMPDIR, and the two sites that call it (overlay.test.sh:639,
  # extend.test.sh:231) hand the result to the daemon as a -v source. Same trap
  # as $SCRATCH above, except this one fails SILENTLY. Exported, because the
  # suites are separate processes.
  export TMPDIR="$PROJECT_ROOT/.tmp/rc-tmp"
  mkdir -p "$AGENT_TMP" "$TMPDIR"
else
  SCRATCH="$HOME/tmp/v3-test-2"
  BUNDLE="$HOME/tmp/release-check-${TS}"
fi
TGZ="${BUNDLE}.tgz"
BUILD_LOG="$REPO/test/results/release-check-build.log"
# One log per side, never one shared path: both halves write while the other
# may be reading, and section 0b reads the agent's log by name.
RUN_LOG="$REPO/test/results/release-check-${SIDE}.log"
AGENT_LOG="$REPO/test/results/release-check-container.log"

# ---------------------------------------------------------------------------
# Self-transcript — the run records itself, next to $BUILD_LOG.
#
# `| tee ~/rc.log` used to be the documented invocation. It cost two things
# every single run: the log landed in the operator's $HOME, outside the
# bind-mounted repo, so it had to be copied by hand before anyone could read
# it; and `echo $?` returned tee's status, not the gate's, silently breaking
# the three-tier exit code this script exists to produce. Writing it here
# fixes both — `wtf image release-check --no-purge` and nothing else.
#
# $BUILD_LOG is untouched by any of this: it keeps every byte of the build,
# and it is the first thing to read when a run goes wrong.
mkdir -p "$(dirname "$RUN_LOG")"
exec > >(tee "$RUN_LOG") 2>&1
TEE_PID=$!

ok()    { printf '  ✔ %s\n' "$1"; }
ko()    { printf '  ✘ %s\n' "$1"; }
omit()  { printf '  ⊘ %s\n' "$1"; }
na()    { printf '  ∅ %s\n' "$1"; }
info()  { printf '  ℹ %s\n' "$1"; }
step()  { printf '  ⏳ %s\n' "$1"; }
sect()  { printf '\n═══ %s ═══\n' "$1"; }

# ---------------------------------------------------------------------------
# Rolling build window — drawn by test/build-progress.py, same visual contract
# as `run_with_progress` in .devcontainer/initialize.sh:249 (reserved zone,
# \033[nF redraws, dim gray trailing lines, cleared on exit). It used to be
# reimplemented here in bash, with a background ticker, an end-of-stream
# sentinel and a pipefail toggle — all three existing solely to work around
# bash 3.2's `read -t`, which cannot tell "timed out" from "end of input"
# (LOG.md § 2). Python's select.select() has no such ambiguity, so none of
# that survives the port; build-progress.py writes only to /dev/tty and draws
# nothing at all when there isn't one (agent, CI, redirected output).
#
# python3 is a host-only prerequisite (step 0, for build_authority /
# open_scratch) — making it hard agent-side too just for this display would
# add a dependency the agent never otherwise needs. So the pipe is
# conditional: no python3 ⇒ same silent build as before, straight to
# $BUILD_LOG.
run_build() {
  if command -v python3 >/dev/null 2>&1; then
    docker build --no-cache --progress=plain -t "$IMG" \
      --build-arg BASE_VERSION="$BASE_VERSION" "$REPO" 2>&1 \
      | tee "$BUILD_LOG" | python3 "$HERE/build-progress.py"
    return "${PIPESTATUS[0]}"
  fi
  docker build --no-cache --progress=plain -t "$IMG" \
    --build-arg BASE_VERSION="$BASE_VERSION" "$REPO" >"$BUILD_LOG" 2>&1
}

fatal() { printf '\nFATAL — %s\n' "$1"; trailer RED 1 - - -; exit 1; }

# ---------------------------------------------------------------------------
# Arguments — the first and only option loop of this script. bash 3.2, no
# getopt. An unknown option is FATAL, never ignored: a typo'd flag that
# silently ran the full interactive gate is a 40-minute mistake.
# ---------------------------------------------------------------------------
NO_PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-purge) NO_PURGE=1 ;;
    *) fatal "unknown option: $1 (only accepted option: --no-purge)" ;;
  esac
  shift
done

# Without the purge, step 6 is not a cold boot and R2 traverses nothing. The
# labels of steps 5, 6 and 7 must stop claiming otherwise — a "cold boot"
# printed over a warm server cache is the exact failure mode this flag exists
# to prevent. One shared variable, because the label IS the ledger key and a
# step's several record() sites must produce a byte-identical name.
BOOT="cold boot"
[ "$NO_PURGE" -eq 1 ] && BOOT="warm boot"

# ---------------------------------------------------------------------------
# Ledger — parallel arrays, bash 3.2 has no associative arrays.
# ---------------------------------------------------------------------------
STEP_NAMES=()
STEP_STATUS=()
STEP_DETAIL=()
# Steps that actually PASSED, as a comma-separated list of step ids, for the
# handshake the other half reads back. `${1%%.*}` on the label is already the
# id ("1", "2-3", "4b", "10"), so this costs nothing and cannot drift from the
# ledger: the label IS the key. PASS only — inheritance must never be offered a
# step that was omitted, skipped, failed, or played by the other side.
STEPS_CSV=""
record() {   # record <name> <PASS|OMIT|NA|SKIP|FAIL> [detail]
  STEP_NAMES+=("$1"); STEP_STATUS+=("$2"); STEP_DETAIL+=("${3:-}")
  [ "$2" = PASS ] && STEPS_CSV="${STEPS_CSV:+$STEPS_CSV,}${1%%.*}"
  case "$2" in
    PASS) ok "$1" ;;
    OMIT) omit "$1 — deliberately not played: ${3:-}" ;;
    NA)   na "$1 — ${3:-}" ;;
    SKIP) info "$1 — skipped: ${3:-}" ;;
    *)    ko "$1 — ${3:-}" ;;
  esac
}

mkdir -p "$BUNDLE"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# --- The safety interlock --------------------------------------------------
# This gate does destructive things to a Docker daemon: step 1 retags
# devcontainer-sandbox:local, step 4 does a table rase of every container, volume
# and image whose name matches $DC_PROJECT. On the host that is the operator's
# own machine and their own decision. Agent-side it must be PROVEN to be the
# nested daemon and nothing else, before any of it runs — an agent that reaches
# the outer daemon by accident would tear down the human's work mid-run.
#
# `hostname` inside a container is its own short id. A daemon that can inspect
# it is, by construction, the one that created us — the outer one. That is the
# whole assertion, and it is exact rather than heuristic: it does not ask what
# the daemon is called, it asks whether it can see us.
#
# Both clauses matter. The DOCKER_HOST case arm alone would pass against any
# tcp:// daemon that happened to be named dind; the inspect alone would pass
# against a daemon so broken it cannot inspect anything. Neither is sufficient.
assert_nested_daemon() {
  case "${DOCKER_HOST:-}" in tcp://dind:*) ;; *) return 1 ;; esac
  ! docker inspect "$(hostname)" >/dev/null 2>&1
}

# assert_nested_path <dir> — prove the nested daemon can mount <dir>, by
# writing a FRESH nonce and reading it back THROUGH the daemon.
#
# `[ -d "$dir" ]` proves nothing at all here, and that is the point: when a -v
# source does not exist for the daemon, docker CREATES AN EMPTY DIRECTORY and
# mounts that. The suite then finds no fragment where it expected one — but
# every "nothing leaked", "no stray copy", "the file is absent" assertion
# passes, because an empty mount satisfies all of them. A vacuous green.
#
# A fresh nonce fails on a stale copy exactly as it fails on an absent mount,
# which neither -d nor a checksum of pre-existing content can do.
assert_nested_path() {
  local dir="$1" nonce seen
  nonce="rc-$$-$(date +%s)-${RANDOM}"
  printf '%s\n' "$nonce" > "$dir/.rc-nonce.log" 2>/dev/null || return 1
  seen="$(docker run --rm -v "$dir:/probe" --entrypoint sh "$IMG" -c \
            'cat /probe/.rc-nonce.log 2>/dev/null' 2>/dev/null | tr -d '\r')"
  rm -f "$dir/.rc-nonce.log"
  [ "$seen" = "$nonce" ]
}

# Server commits cached in the host-global `vscode` volume, one per line.
server_cache() {
  docker volume inspect vscode >/dev/null 2>&1 || return 0
  docker run --rm -v vscode:/v --entrypoint sh "$IMG" -c \
    'find /v/vscode-server -mindepth 1 -maxdepth 3 -type d \
       \( -path "*/bin/*" -o -path "*/cli/servers/*" \) 2>/dev/null \
     | sed "s|.*/||" | sort -u' 2>/dev/null | tr -d '\r'
}

# purge_vscode_cache -> 0 on a verified-empty cache, 1 otherwise (declined
# or rm failed). Typed confirmation every time: this touches a volume
# shared by every devcontainer on the host, dogfood included.
purge_vscode_cache() {
  cat <<'EOF'
    ⚠ THIS VOLUME IS SHARED BY ALL YOUR DEVCONTAINERS, dogfood included.
    What the purge does: it empties the VS Code server binaries, nothing
    else — not your extensions, not your data, not any project.
    Every devcontainer will re-download its server on its next start.
EOF
  printf '\n    type "purge" to confirm, anything else to cancel: '
  read -r ANSWER
  [ "$ANSWER" = "purge" ] || return 1

  # -u 0 is mandatory (I2): the image runs as USER node and the `vscode`
  # volume's content is owned by root. Never mask stderr here — the sole
  # point of this block is to fail loudly.
  RM_ERR="$(docker run --rm -u 0:0 -v vscode:/v --entrypoint sh "$IMG" -c \
    'rm -rf /v/vscode-server/bin/* /v/vscode-server/cli/servers/*' 2>&1)"

  local after; after="$(server_cache)"
  if [ -z "$after" ]; then
    ok "server cache empty — the next (re)attach will download for real"
    return 0
  fi
  ko "entries remain:"
  printf '%s\n' "$after" | sed 's/^/      /'
  [ -n "$RM_ERR" ] && printf '%s\n' "$RM_ERR" | sed 's/^/    /'
  return 1
}

# find_trace <since_epoch> — sets TRACE / TRACE_WS / TRACE_MTIME to the
# freshest Dev Containers trace log naming $SCRATCH, newer than <since>.
# I1: selection is BY WORKSPACE FOLDER (the log's own
# "Setting up container for folder or workspace: <path>" line), never by
# mtime alone — mtime only breaks the tie among logs that already matched.
find_trace() {
  local since="$1"
  local scratch_real want root f ws m
  scratch_real="$(cd "$SCRATCH" 2>/dev/null && pwd -P || printf '%s' "$SCRATCH")"
  want="$(basename "$SCRATCH")"
  TRACE=""; TRACE_MTIME=0; TRACE_WS=""
  for root in "$HOME/Library/Application Support/Code/logs" \
              "$HOME/Library/Application Support/Code - Insiders/logs"; do
    [ -d "$root" ] || continue
    while IFS= read -r f; do
      [ -s "$f" ] || continue
      ws="$(grep -am1 'folder or workspace: ' "$f" 2>/dev/null \
            | sed -e 's/.*folder or workspace: //' -e 's/[[:space:]]*$//' | tr -d '\r')"
      [ -n "$ws" ] || continue
      case "$ws" in
        "$SCRATCH"|"$scratch_real"|*/"$want") ;;
        *) continue ;;
      esac
      m="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)"
      if [ "${m:-0}" -gt "$TRACE_MTIME" ]; then
        TRACE_MTIME="$m"; TRACE="$f"; TRACE_WS="$ws"
      fi
    done <<EOF
$(find "$root" -type f -name '*.log' \( -ipath '*remote-containers*' -o -iname '*container*' \) 2>/dev/null)
EOF
  done
  [ -n "$TRACE" ] || return 1
  [ "$TRACE_MTIME" -gt "$since" ] || return 1
  return 0
}

# wait_for_gesture <prompt-lines...> then read a typed "ok" and verify a
# fresh trace exists — never trust the typed answer on its own.
wait_for_gesture() {
  local since; since="$(date +%s)"
  printf '\n    type "ok" once done, to resume: '
  read -r _ANSWER
  if find_trace "$since"; then
    ok "gesture verified — fresh trace: $TRACE_WS"
    return 0
  fi
  ko "no Dev Containers trace newer than the wait, naming $SCRATCH"
  info "the typed \"ok\" is not enough here — redo the Reopen, or check that"
  info "the targeted window really is the one for $SCRATCH."
  return 1
}

# build_authority <folder> <docker-context> — the dev-container+<hex> remote
# authority. The shape is VS Code's, not this repo's: the same JSON payload the
# Dev Containers extension hex-encodes into the authority it reopens a folder
# with. Reconstructed here so the gate can drive a reopen without a running
# window to read one from.
build_authority() {
  python3 - "$1" "$2" <<'PY'
import json, sys
folder, context = sys.argv[1], sys.argv[2]
cfg = folder + "/.devcontainer/devcontainer.json"
o = {"hostPath": folder, "localDocker": False,
     "settings": {"context": context},
     "configFile": {"$mid": 1, "fsPath": cfg,
                    "external": "file://" + cfg, "path": cfg, "scheme": "file"}}
print("dev-container+" + json.dumps(o, separators=(",", ":")).encode().hex())
PY
}

# get_authority — prefer an authority already cached in the workspace, fall
# back to reconstructing it. The cache is written by a patcher some setups run
# (this image ships none, so normally there is none) and by the fresh open
# earlier in this same run, which is the reattach step's (R2) case.
get_authority() {
  local cache="$SCRATCH/.devcontainer/tmp/notify/.authority"
  if [ -s "$cache" ]; then
    cat "$cache"
  else
    local ctx; ctx="$(docker context show 2>/dev/null || echo desktop-linux)"
    build_authority "$SCRATCH" "$ctx"
  fi
}

open_scratch() {
  local authority; authority="$(get_authority)"
  [ -n "$authority" ] || fatal "could not build the dev-container authority for $SCRATCH"
  code --folder-uri "vscode-remote://${authority}/workspace"
}

# ===========================================================================
sect "0. prerequisites"
# ===========================================================================

info "half: ${SIDE}"

command -v docker >/dev/null 2>&1 || fatal "docker not found on PATH"
docker info >/dev/null 2>&1        || fatal "docker is not responding (Docker Desktop running? dind profile started?)"
docker compose version >/dev/null 2>&1 || fatal "docker compose (v2) unavailable"
command -v jq >/dev/null 2>&1      || fatal "jq not found — needed to read package.json"
[ -d "$TEMPLATE" ] || fatal "v3 template not found: $TEMPLATE"

if [ "$SIDE" = host ]; then
  # Host-only prerequisites, and only here: `code` and python3 exist for the
  # dev-container authority and the Reopen (build_authority -> open_scratch),
  # which only steps 6 and 9 use — both NA agent-side. Demanding them of the
  # agent would fail the run for a capability it is never asked to use.
  #
  # It also matters the other way round. `code` DOES resolve inside this
  # devcontainer when the shell inherits VS Code's terminal PATH (the
  # remote-cli shim), so a shared prerequisite would pass agent-side and let
  # open_scratch fire `code --folder-uri` — opening a window in the HUMAN's
  # VS Code from inside the agent's half. Side-gated, that cannot happen.
  command -v code >/dev/null 2>&1    || fatal "the VS Code \`code\` command is not on PATH"
  command -v python3 >/dev/null 2>&1 || fatal "python3 not found — needed for the dev-container authority"
  ok "docker + compose + code + jq + python3 present, template found"
else
  # THE SAFETY INTERLOCK, and it is placed here on purpose: after `docker info`
  # (the assertion needs a daemon that answers) and BEFORE the first docker
  # command that changes anything — step 1's build, which retags
  # devcontainer-sandbox:local, and step 4's table rase, which deletes every
  # container, volume and image matching $DC_PROJECT. Against the host daemon
  # those two would overwrite the operator's image and tear down the scratch
  # stack of a run they may be in the middle of.
  #
  # fatal, never a recorded FAIL: there is no honest way to continue. Every
  # docker command below this line assumes the answer.
  assert_nested_daemon || fatal "daemon NOT nested — DOCKER_HOST=${DOCKER_HOST:-<unset>} and/or this daemon can inspect $(hostname), so it is the host's. The agent half REFUSES to run there: it would destroy the human's work. Start the dind sidecar (dind profile, host command)."
  ok "nested daemon proven — ${DOCKER_HOST} cannot see $(hostname)"
  ok "docker + compose + jq present, template found"
fi

BASE_VERSION="$(jq -r .version "$REPO/package.json")"
info "base version: $BASE_VERSION"

BUILD_OK=0; SUITES_OK=0; SCRATCH_OK=0
REOPEN1_OK=0; COLLECT_OK=0; R1_HIT=0
CONTAINER_UP=0            # step 4b, agent-side: the headless stand-in for the Reopen
IMAGE_ID=""               # step 10b, agent-side: what the handshake publishes
HANDSHAKE_TAR=""          # step 10b, agent-side: set only once a tar is verified

# ===========================================================================
# 0b — agent-half inheritance. HOST SIDE ONLY.
# ===========================================================================
# If the agent already ran its half against the same source tree, the human
# should not repay a --no-cache build and the full suite pass. Inheritance is
# PER STEP, not per verdict: an agent run is GREEN PARTIEL by construction (it
# cannot play the visual steps), yet its steps 1 and 2-3 are intact.
#
# Only 1 and 2-3 cross honestly. Step 4 scaffolds the HOST's own scratch, which
# step 6 then opens; 4b/7a/8 produced their evidence in a different container in
# a different daemon. An artifact is inheritable when the other side's run proves
# something about THIS side's next step — the built image, and the suites against
# it. Nothing else qualifies, so nothing else is offered.
#
# INHERITANCE IS AN OPTIMISATION, NEVER A DEPENDENCY. Four independent guards
# must all hold; anything less and we inherit nothing and replay everything,
# exactly as before this section existed. A stale tar costs time, never
# correctness — and a broken agent run must not be able to block the human.
inherits() {                       # bash 3.2 — no associative arrays
  [ -n "$INHERIT_STEPS" ] || return 1
  case ",$INHERIT_STEPS," in *",$1,"*) return 0 ;; esac
  return 1
}

INHERIT_STEPS=""
if [ "$SIDE" = host ]; then
  sect "0b. agent-half inheritance"

  if [ ! -f "$AGENT_LOG" ]; then
    info "no agent verdict (${AGENT_LOG#$PROJECT_ROOT/}) — replaying everything, as usual"
  else
    A_TIER="$(sed -n 's/^## RELEASE-CHECK tier=\([^ ]*\).*/\1/p' "$AGENT_LOG" | tail -1)"
    A_HAND="$(grep '^## RELEASE-CHECK-HANDSHAKE ' "$AGENT_LOG" | tail -1)"
    A_STEPS="$(printf '%s' "$A_HAND" | sed -n 's/.*steps=\([^ ]*\).*/\1/p')"
    A_IMGID="$(printf '%s' "$A_HAND" | sed -n 's/.*imageid=\([^ ]*\).*/\1/p')"
    A_TAR="$(printf '%s' "$A_HAND" | sed -n 's/.*tar=\([^ ]*\).*/\1/p')"
    A_DATE="$(printf '%s' "$A_HAND" | sed -n 's/.*date=//p')"

    # Guard 1 — the agent's own verdict. RED means a step failed or an upstream
    # broke; nothing from such a run is worth loading.
    case "$A_TIER" in
      GREEN|GREEN_PARTIEL) ;;
      *) A_TIER="" ;;
    esac

    # Guard 2 — freshness. Exactly run-all.sh:178-179, and the -prune is the
    # load-bearing part: without it the log this very run is writing into
    # test/results/ would make the other side look stale every time.
    A_STALE=fresh
    [ -n "$(find "$REPO/bin" "$REPO/assets" "$REPO/test" "$REPO/Dockerfile" \
            -name results -prune -o -newer "$AGENT_LOG" -print -quit 2>/dev/null)" ] \
      && A_STALE=stale

    # The tar path is refused here if it is absolute or climbs out of the
    # project root — and it has to be refused BEFORE the load. The identity
    # check further down is what catches a hand-edited log, but it can only
    # speak once `docker load` has already run against whatever the log named.
    # This field is only ever written as a path relative to $PROJECT_ROOT.
    A_TAR_OK=1
    case "$A_TAR" in /*|*..*) A_TAR_OK=0 ;; esac

    if [ -z "$A_TIER" ]; then
      info "agent verdict unusable (tier RED or trailer missing) — replaying everything"
    elif [ "$A_STALE" = stale ]; then
      info "agent half is stale: code has changed since ${A_DATE} — replaying everything"
    elif [ -z "$A_STEPS" ] || [ "$A_STEPS" = - ] \
      || [ -z "$A_IMGID" ] || [ "$A_IMGID" = - ] \
      || [ -z "$A_TAR" ] || [ "$A_TAR" = - ]; then
      # `-`, not the empty string, is what an incomplete run publishes: the
      # handshake printf substitutes it for every field it could not fill. A
      # guard testing only for emptiness therefore never fires while the
      # handshake line itself exists — which is every run that got as far as
      # step 11 with a failed `docker save`.
      info "agent handshake incomplete (steps/imageid/tar) — replaying everything"
    elif [ "$A_TAR_OK" -eq 0 ]; then
      info "tarball path refused, absolute or climbing: ${A_TAR} — replaying everything"
    elif [ ! -f "$PROJECT_ROOT/$A_TAR" ]; then
      info "image tarball announced but missing: ${A_TAR} — replaying everything"
    else
      step "docker load < ${A_TAR}…"
      if ! docker load -i "$PROJECT_ROOT/$A_TAR" >/dev/null 2>&1; then
        info "docker load failed (truncated archive?) — replaying everything"
      else
        # Guard 3 — identity. THE tar must be THE artifact the log describes.
        # Deliberately not an mtime comparison: these files cross a virtiofs bind
        # mount. This is what catches a stale tar, a truncated save that still
        # loaded, and a hand-edited log. A mismatch here is harmless: step 1's
        # --no-cache build retags $IMG immediately below.
        H_IMGID="$(docker image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)"
        if [ "$H_IMGID" != "$A_IMGID" ]; then
          info "image identity mismatch — expected ${A_IMGID}, loaded ${H_IMGID:-<none>}: replaying everything"
        else
          INHERIT_STEPS="$A_STEPS"
          ok "agent half accepted — tier ${A_TIER}, ${A_DATE}"
          ok "image loaded and identified: ${H_IMGID}"
          info "inheritable steps: ${INHERIT_STEPS} (only 1 and 2-3 are consumed here)"
        fi
      fi
    fi
  fi
fi

# ===========================================================================
sect "1. docker build --no-cache"
# ===========================================================================
# The Dockerfile's build-time self-checks (visudo -c on the firewall sudoers
# block, the devc-hook fragment-per-phase assertion) are &&-chained inside
# the same RUN — a failure there fails this build already, no separate grep
# needed.
#
# The VSIX fetch is the one exception, on purpose: `docker build` must never
# fail on a Claude-side problem, so a Marketplace outage only prints a marker
# and drops $EXT_DIR. The image then builds green while being unable to
# satisfy the suites — no baked extension means no pristine copies, no live
# patches, and an extending image that cannot find extension.js. Left
# undetected that surfaces at step 2-3 as four unexplained assertions, so
# grep for it here and let the first row of the ledger name the cause.
#
# These two markers only. The other failsafe messages (`claude-binary: version
# mismatch`, `claude-binary: extension extracted but …`) mean the extension
# IS baked and the suites still pass — only the CLI falls back to npm.
#
# The two markers name different causes on purpose: a download/extract
# failure means the Marketplace was unreachable, while a copy failure means
# the download succeeded but `cp -a` into $EXT_DIR did not finish (disk
# pressure, a stale mount) — attributing the second to "Marketplace
# unreachable" would send whoever reads a red step 1 looking in the wrong
# place. Both leave no extension baked, so both are FAIL here.
#
# The `^#<n> <secs> ` anchor is LOAD-BEARING on both, not decoration. buildkit
# echoes each RUN's own source before running it, and that source contains
# the literal `echo "VSIX download/extract failed …"` / `echo "VSIX copy
# incomplete …"` text of their own else branches — so an unanchored grep
# matches every build ever, healthy ones included, and step 1 can never pass.
# Only real output carries the `#<step> <elapsed>` prefix. If buildkit ever
# changes that prefix this stops matching and the check goes back to being
# blind, which is the pre-existing behaviour — the retry in the Dockerfile is
# the primary defence, this is the safety net.
VSIX_FAILED_RE='^#[0-9]+ +[0-9]+\.[0-9]+ VSIX download/extract failed'
VSIX_COPY_FAILED_RE='^#[0-9]+ +[0-9]+\.[0-9]+ VSIX copy incomplete'

mkdir -p "$(dirname "$BUILD_LOG")"

# An inherited step is a VERIFIED step, so it is recorded PASS and nothing else:
# sev 0 by construction rather than by assertion, no new ledger status, and the
# provenance printed in the detail column the verdict table already renders. A
# sixth status would have had to be defended as sev 0 in a table where every
# other non-PASS status is 1 or 2 — the one shape where forgetting an arm puts a
# wrong glyph on a GREEN row.
if inherits 1; then
  BUILD_OK=1
  record "1. build --no-cache" PASS \
    "↩ inherited from the agent half (test/results/release-check-container.log)"
else
step "docker build --no-cache -t $IMG --build-arg BASE_VERSION=$BASE_VERSION …"
# --progress=plain is explicit because the anchor above depends on its line
# prefix. It is already what buildkit picks when its output is not a tty, but
# relying on that would make the check hostage to how this command is invoked.
run_build
BUILD_RC=$?

if [ "$BUILD_RC" -eq 0 ]; then
  if grep -qE "$VSIX_FAILED_RE" "$BUILD_LOG"; then
    record "1. build --no-cache" FAIL \
      "degraded image: the Claude Code VSIX was not baked (Marketplace unreachable). The suites cannot pass — see ${BUILD_LOG}"
  elif grep -qE "$VSIX_COPY_FAILED_RE" "$BUILD_LOG"; then
    record "1. build --no-cache" FAIL \
      "degraded image: the Claude Code VSIX downloaded but the copy into \$EXT_DIR did not finish (disk pressure or a stale mount during the build). The suites cannot pass — see ${BUILD_LOG}"
  else
    BUILD_OK=1
    record "1. build --no-cache" PASS
  fi
else
  tail -60 "$BUILD_LOG" | sed 's/^/    /'
  record "1. build --no-cache" FAIL "voir $BUILD_LOG"
fi
fi

# ===========================================================================
sect "2-3. content checks + suites (run-all.sh, host)"
# ===========================================================================
# run-all.sh detects the host side itself, runs run-image-suites.sh (layout,
# labels, the 34-host allowlist count) + overlay.test.sh layer 2 (LANG,
# locale, 3 patch sentinels) + extend.test.sh, then replays the container
# half inside a throwaway container of the image under test. One call
# covers deliverable steps 2 AND 3 of the session table.

if inherits 2-3; then
  SUITES_OK=1
  record "2-3. run-all.sh (content + suites, both sides)" PASS \
    "↩ inherited from the agent half (test/results/release-check-container.log)"
elif [ "$BUILD_OK" -eq 1 ]; then
  # AGENT SIDE: prove the nested daemon can actually mount what the suites are
  # about to hand it, BEFORE they hand it. run-all.sh:137 mounts $REPO, and
  # overlay/extend hand it `mktemp -d` results, i.e. $TMPDIR. Under
  # DOCKER_HOST=tcp://dind:2375 those SOURCES are resolved by the nested daemon,
  # and an unresolvable source is not an error: docker mounts an empty directory
  # instead. The suites then fail their "the fragment was applied" assertions
  # while every "nothing leaked / no stray copy" assertion passes VACUOUSLY.
  #
  # FAIL, never SKIP — portgate-common.sh:51-57's doctrine: a dead bench is red,
  # never green. Placed here because it needs $IMG, which the build just made.
  PATHS_OK=1
  if [ "$SIDE" = container ]; then
    for d in "$REPO" "$TMPDIR"; do
      if assert_nested_path "$d"; then
        ok "nested mount proven (nonce read back through the daemon): ${d#$PROJECT_ROOT/}"
      else
        PATHS_OK=0
        ko "nested mount NOT proven: $d"
      fi
    done
  fi

  if [ "$PATHS_OK" -eq 0 ]; then
    record "2-3. run-all.sh (content + suites, both sides)" FAIL \
      "nested mount not proven — the suites would mount an empty directory and their \"nothing leaked\" assertions would pass vacuously"
  else
    cd "$PROJECT_ROOT" || fatal "cannot cd into $PROJECT_ROOT"
    if IMG="$IMG" bash "$REPO/test/run-all.sh"; then
      SUITES_OK=1
      record "2-3. run-all.sh (content + suites, both sides)" PASS
    else
      record "2-3. run-all.sh (content + suites, both sides)" FAIL \
        "see packages/devcontainer-sandbox/test/results/${SIDE}.log"
    fi
  fi
else
  record "2-3. run-all.sh (content + suites, both sides)" SKIP "build failed"
fi

# ===========================================================================
sect "4. clean sweep and scaffold ($SCRATCH)"
# ===========================================================================

if [ "$SUITES_OK" -eq 1 ]; then
  # Non-negotiable: without the fix in the image, this pass tests nothing.
  if docker run --rm --entrypoint sh "$IMG" -c \
       "grep -q '${CDN_HOST}' /etc/devcontainer-firewall/domains.d/00-base.txt" 2>/dev/null; then
    ok "$CDN_HOST is in the base allowlist"

    if [ -f "$SCRATCH/.devcontainer/docker-compose.yml" ]; then
      step "compose down -v --rmi local…"
      ( cd "$SCRATCH/.devcontainer" && docker compose down -v --remove-orphans --rmi local ) >/dev/null 2>&1
    fi
    LEFT_C="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i "$DC_PROJECT" || true)"
    [ -n "$LEFT_C" ] && printf '%s\n' "$LEFT_C" | while IFS= read -r c; do
      docker rm -f "$c" >/dev/null 2>&1 && info "container removed: $c"
    done
    LEFT_V="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -i "$DC_PROJECT" || true)"
    [ -n "$LEFT_V" ] && printf '%s\n' "$LEFT_V" | while IFS= read -r v; do
      docker volume rm "$v" >/dev/null 2>&1 && info "volume removed: $v"
    done
    LEFT_I="$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -i "$DC_PROJECT" || true)"
    [ -n "$LEFT_I" ] && printf '%s\n' "$LEFT_I" | while IFS= read -r i; do
      docker image rm -f "$i" >/dev/null 2>&1 && info "image removed: $i"
    done
    rm -rf "$SCRATCH"

    REST="$( { docker ps -a --format '{{.Names}}'; docker volume ls --format '{{.Name}}'; \
               docker image ls --format '{{.Repository}}:{{.Tag}}'; } 2>/dev/null \
             | grep -i "$DC_PROJECT" || true)"
    if [ -n "$REST" ]; then
      ko "this is still here, remove it by hand:"
      printf '%s\n' "$REST" | sed 's/^/      /'
      record "4. scratch scaffold" FAIL "leftover docker resources for $DC_PROJECT"
    else
      mkdir -p "$SCRATCH"
      cp -r "$TEMPLATE" "$SCRATCH/.devcontainer" || fatal "scaffold failed"
      ( cd "$SCRATCH/.devcontainer" && \
        grep -rl '{{PROJECT_' . --exclude=README.md 2>/dev/null | while IFS= read -r f; do
          sed -i.bak -e "s/{{PROJECT_ID}}/${DC_PROJECT}/g" -e "s/{{PROJECT_DISPLAY_NAME}}/${DISPLAY_NAME}/g" "$f"
          rm -f "$f.bak"
        done )
      LEFT="$(cd "$SCRATCH/.devcontainer" && grep -rl '{{PROJECT_' . --exclude=README.md 2>/dev/null | tr '\n' ' ')"
      if [ -n "$LEFT" ]; then
        record "4. scratch scaffold" FAIL "unsubstituted placeholders: $LEFT"
      else
        cp "$SCRATCH/.devcontainer/.env.example" "$SCRATCH/.devcontainer/.env"
        cat >> "$SCRATCH/.devcontainer/.env" <<EOF

# === wtf image release-check ==================================================
DC_PROJECT=${DC_PROJECT}
BASE_IMAGE=${IMG}
DEBUG=1
EOF
        # Point the scratch project at the SAME Claude credentials volume the
        # devcontainer running this repo uses, so step 6 opens on a real
        # signed-in session: visual checks 3 and 4 (model badge, /model picker)
        # have nothing to render otherwise.
        #
        # It also keeps the stack startable. The template declares this volume
        # `external: true` (templates/v3/project/docker-compose.yml), so compose
        # never creates it — it refuses to start when the name does not resolve
        # to an existing volume. Left alone the name would be
        # claude-creds-$DC_PROJECT, which step 4's own table rase above deletes
        # on every run, since it matches the $DC_PROJECT volume sweep.
        #
        # Resolved exactly the way that project's compose resolves it
        # (.devcontainer/docker-compose.yml, `claude-creds` volume):
        #   ${CLAUDE_CREDS_VOLUME:-claude-creds-${DC_PROJECT:-devcontainer-tools}}
        # so an operator who never set the variable still lands on the same
        # volume as their running container. Read, never hardcoded — both
        # values are personal to the checkout.
        DC_ENV="$PROJECT_ROOT/.devcontainer/.env"
        env_val() { grep -h "^$1=" "$DC_ENV" 2>/dev/null | tail -1 | cut -d= -f2-; }
        CREDS_VOL="$(env_val CLAUDE_CREDS_VOLUME)"
        if [ -z "${CREDS_VOL:-}" ]; then
          HOST_PROJECT="$(env_val DC_PROJECT)"
          CREDS_VOL="claude-creds-${HOST_PROJECT:-devcontainer-tools}"
        fi
        printf 'CLAUDE_CREDS_VOLUME=%s\n' "$CREDS_VOL" >> "$SCRATCH/.devcontainer/.env"
        if docker volume inspect "$CREDS_VOL" >/dev/null 2>&1; then
          info "Claude creds shared with this repo: ${CREDS_VOL}"
        else
          info "creds volume ${CREDS_VOL} not found — step 6 will open without a Claude session, checks 3 and 4 (model badge, /model picker) will prove nothing"
        fi

        # The patchers, same treatment and for the same reason: read from this
        # checkout, never hardcoded. The image ships none and names no
        # repository, so without these the scratch project runs an unmodified
        # extension — which is a legitimate thing to check, and is what checks
        # 0 and 2 below are for. But checks 3 and 4 are looking at a badge and
        # a picker CONTRIBUTED BY PATCHERS: on a bare extension they have
        # nothing to render, exactly like a missing creds volume.
        EXT_PATCHED=0
        for k in EXT_PATCHES_DIR EXT_PATCHES_REPO EXT_PATCHES_REF EXT_PATCHES_TOKEN EXT_PATCHES_SELECT; do
          v="$(env_val "$k")"
          [ -n "${v:-}" ] || continue
          printf '%s=%s\n' "$k" "$v" >> "$SCRATCH/.devcontainer/.env"
          case "$k" in EXT_PATCHES_DIR|EXT_PATCHES_REPO) EXT_PATCHED=1 ;; esac
        done
        if [ "$EXT_PATCHED" -eq 1 ]; then
          info "patchers configured — the scratch project will patch its own copy; checks 3 and 4 can render"
        else
          info "no EXT_PATCHES_* in this checkout — the scratch project runs the extension AS PUBLISHED; checks 3 and 4 have nothing to render, and check 0 is the one that matters"
        fi
        SCRATCH_OK=1
        record "4. scratch scaffold" PASS
      fi
    fi
  else
    record "4. scratch scaffold" FAIL "$CDN_HOST missing from the base allowlist — image predates the defect-6 fix"
  fi
else
  record "4. scratch scaffold" SKIP "suites failed or skipped"
fi

# ===========================================================================
# 4b — the headless stand-in for the Reopen. AGENT SIDE ONLY.
# ===========================================================================
# Steps 7a and 8 need a RUNNING container of the scratch project: 7a reads the
# lifecycle logs it writes, 8 execs into it to grep the mitmproxy log. On the
# host, step 6's Reopen provides it. Agent-side nothing does, so this step does.
#
# It is deliberately more than `compose up -d`. That alone would start a
# container whose only process is the image's `sleep infinity` CMD: no lifecycle
# logs (devc-hook is invoked by devcontainer.json, which compose never reads)
# and, decisively, NO FIREWALL — assets/opt/hooks/on-create.d/10-firewall-init.sh
# is init-firewall.sh's only caller. Step 8 would then grep a
# /var/log/mitmproxy.log that was never created and report the healthy "rien au
# boot" branch: a pass proving nothing. Replaying the three container-side
# phases is what makes 7a and 8 mean something.
#
# The three phases, and only three: `initialize` is a HOST hook
# (initializeCommand -> initialize.sh) and interactive. `-u node` matches how
# the orchestrator runs them — the hooks sudo for what needs root.
if [ "$SIDE" = container ]; then
  sect "4b. v3test2 stack without VS Code (compose + lifecycle)"

  if [ "$SCRATCH_OK" -eq 1 ]; then
    # The template declares claude-creds `external: true`, so compose REFUSES to
    # start when the name does not resolve — and it never resolves in the nested
    # daemon, which has none of the host's volumes. Created empty: the two visual
    # checks that need a signed-in session (model badge, /model picker) are step
    # 6's, which is NA here.
    CREDS_VOL="${CREDS_VOL:-claude-creds-${DC_PROJECT}}"
    docker volume create "$CREDS_VOL" >/dev/null 2>&1 \
      && info "creds volume created in the nested daemon: ${CREDS_VOL} (empty — the Claude session is the human half)"
    # docker-compose.yml binds ./vscode-settings.jsonc onto
    # /workspace/.vscode/settings.json, i.e. inside the $SCRATCH bind: create the
    # parent so the daemon does not have to invent it.
    mkdir -p "$SCRATCH/.vscode"

    step "docker compose up -d --build…"
    if ( cd "$SCRATCH/.devcontainer" && docker compose up -d --build ) >"$BUNDLE/compose-up.log" 2>&1; then
      HOOKS_OK=1
      for phase in on-create post-create post-start; do
        step "devc-hook ${phase}…"
        if ! docker exec -w /workspace -u node "$CONTAINER" devc-hook "$phase" \
               >"$BUNDLE/devc-hook-${phase}.log" 2>&1; then
          HOOKS_OK=0
          ko "devc-hook ${phase} failed — see ${BUNDLE}/devc-hook-${phase}.log"
          tail -20 "$BUNDLE/devc-hook-${phase}.log" | sed 's/^/      /'
          break
        fi
      done
      if [ "$HOOKS_OK" -eq 1 ]; then
        CONTAINER_UP=1
        record "4b. stack without VS Code" PASS \
          "compose up + on-create/post-create/post-start replayed — $CONTAINER"
      else
        record "4b. stack without VS Code" FAIL "a lifecycle hook failed (see above)"
      fi
    else
      tail -40 "$BUNDLE/compose-up.log" | sed 's/^/    /'
      record "4b. stack without VS Code" FAIL "compose up failed — see ${BUNDLE}/compose-up.log"
    fi
  else
    record "4b. stack without VS Code" SKIP "scaffold failed or skipped"
  fi
fi

# ===========================================================================
sect "5. VS Code server cache — pass 1 (${BOOT})"
# ===========================================================================
# --no-purge is tested first, before SCRATCH_OK: symmetrical with step 9,
# where it MUST come first to skip the interactive prompt.
#
# WHY THE AGENT DOES NOT PURGE, AND WHY THAT IS THE SAFER DESIGN.
# The obvious shape was to bypass the typed confirmation agent-side
# (`if [ "$SIDE" = container ]; then ANSWER=purge; fi`) so this step runs on
# both halves. It was rejected, and not only for the risk: it would have been
# a VACUOUS PASS. The `vscode` volume is the HOST's, shared by every
# devcontainer on the machine; the nested daemon has no such volume, so
# server_cache() returns empty at once, the purge would create an empty volume,
# delete nothing in it, find nothing left, and report success. Meanwhile the
# only thing this step exists to buy — a genuine cold boot for step 6's Reopen
# — is human-side by nature.
#
# So the bypass would have bought a green that proves nothing, in exchange for
# carrying the single most dangerous line of this whole change: one line whose
# weakening destroys the VS Code server cache of EVERY project on the Mac.
# NA is both honest and free, and the line does not exist anywhere in this
# file. purge_vscode_cache() and its correction I2 are untouched.

if [ "$SIDE" = container ]; then
  record "5. purge vscode cache (${BOOT})" NA \
    "the host's \`vscode\` volume, invisible to the nested daemon — the purge and the cold boot are the human half"
elif [ "$NO_PURGE" -eq 1 ]; then
  record "5. purge vscode cache (${BOOT})" OMIT \
    "--no-purge: server cache kept, step 6 will not be a cold boot"
elif [ "$SCRATCH_OK" -eq 1 ]; then
  if purge_vscode_cache; then
    record "5. purge vscode cache (${BOOT})" PASS
  else
    record "5. purge vscode cache (${BOOT})" SKIP \
      "declined or failed — pass 6 will prove nothing (to deliberately omit it: --no-purge)"
  fi
else
  record "5. purge vscode cache (${BOOT})" SKIP "scaffold failed or skipped"
fi

# ===========================================================================
sect "6. Reopen in Container — ${BOOT}"
# ===========================================================================
# The irreducibly human step, and the reason exit 0 is unreachable agent-side:
# the six visual checks of TEST-PLAN-4 section D are a rendering judgement (a
# badge, a picker's contents, a window title, an extension count at a glance).
# No headless stand-in can assert them, so the agent records NA rather than
# pretending. Step 4b starts a container without VS Code, which is what steps
# 7a and 8 need — it is NOT a substitute for this.

if [ "$SIDE" = container ]; then
  record "6. Reopen — ${BOOT}" NA \
    "VS Code visual checks (TEST-PLAN-4 §D) — human half, no headless equivalent"
elif [ "$SCRATCH_OK" -eq 1 ]; then
  # Braces are load-bearing: bash 3.2 folds the leading byte of the following
  # "…" into the variable name, and `set -u` then kills the run at step 6.
  step "opening ${SCRATCH}…"
  open_scratch
  cat <<EOF

    In the window that just opened/attached, check the six visual
    checks from TEST-PLAN-4 section D — note what you see, even
    (and especially) if it matches:

      0. THE CLAUDE PANEL OPENS AT ALL. On an extension left as published
         this is the check that decides whether the image is shippable:
         recent VS Code makes globalThis.navigator throw on any access,
         and the bundle reads it at load. If the icon flashes and dies,
         look at the output channel for PendingMigrationError — that is
         the known upstream interaction, documented in the README.
      1. the four Marketplace extensions install on Reopen
      2. the baked extension is loaded, exactly once
         (ls -d ~/.vscode-server/extensions/anthropic.claude-code-*  → 1 only)
      3. model badge at the foot of the composer, clickable
         [needs patchers — nothing renders on an unmodified extension]
      4. /model picker: Default + Fable 5 / Opus 5 / Opus 4.8 / Opus 4.7 + Sonnet
         [needs patchers — an unmodified picker shows the stock list]
      5. window title: "$DISPLAY_NAME [v3-test-2] - Claude Code Sandbox - …"
         and green remote badge bottom-left
      6. integrated terminal in zsh (echo \$0 → zsh)
EOF
  if wait_for_gesture; then
    REOPEN1_OK=1
    record "6. Reopen — ${BOOT}" PASS
  else
    record "6. Reopen — ${BOOT}" FAIL "gesture not verified (see above)"
  fi
else
  record "6. Reopen — ${BOOT}" SKIP "scaffold failed or skipped"
fi

# ===========================================================================
sect "7. collect — ${BOOT}"
# ===========================================================================
# This step is NOT purely human, and that is worth being precise about. Its real
# assertion is the lifecycle-log count, read from $SCRATCH/.devcontainer/tmp/logs —
# written by `devc-hook`, which is a container-side script. Only the Dev
# Containers TRACE copy and its error grep are VS-Code-specific. Hence the
# split: 7a (both sides) counts the lifecycle logs, 7b (host) keeps the trace.
#
# BUT the counts differ per side, and not by choice. `devc-hook` derives its
# phase from argv[1] and its only callers are devcontainer.json's
# onCreate/postCreate/postStart, run by the VS Code orchestrator; the fourth
# log, `initialize-*.log`, is written by templates/v3/project/initialize.sh
# from initializeCommand — HOST-side, and interactive. Step 4b replays the three
# container-side phases itself, so the agent can honestly assert 3, never 4.
# Claiming 4 agent-side would mean either a false red every run, or driving an
# interactive host bootstrap from inside the container for one log file.
if [ "$SIDE" = container ]; then
  COLLECT_LABEL="7a. collect (lifecycle logs)"
  COLLECT_READY="$CONTAINER_UP"
  WANT_LIFECYCLE=3           # on-create, post-create, post-start
  # The agent says which three, and why not four: a bare "3" in the ledger would
  # read as a truncated 4 to anyone who did not write this.
  COLLECT_DETAIL="3/3 (on-create, post-create, post-start) — initialize is written host-side by initialize.sh, interactive"
else
  COLLECT_LABEL="7. collect (${BOOT})"
  COLLECT_READY="$REOPEN1_OK"
  WANT_LIFECYCLE=4           # + initialize, written by initialize.sh
  COLLECT_DETAIL=""          # host ledger unchanged: this row has no detail
fi

if [ "$COLLECT_READY" -eq 1 ]; then
  # 7b — the Dev Containers trace. Host only: find_trace reads
  # ~/Library/Application Support/Code/logs and carries correction I1, and its
  # only producer is the Reopen of step 6.
  if [ "$SIDE" = host ]; then
    cp "$TRACE" "$BUNDLE/dev-containers-trace-cold.log" 2>/dev/null
    ERRS="$(grep -aniE 'error|failed|exit code|ENOENT|no such|denied|cannot|refus' "$TRACE" 2>/dev/null | head -60)"
    if [ -n "$ERRS" ]; then
      printf '%s\n' "$ERRS" | sed 's/^/    /'
    fi
  fi

  # step7-samples-too-early (STATUS row 13). Host step 6 hands back control
  # on the operator's typed "ok" — a plain `read -r`, with nothing tying it
  # to VS Code actually finishing the container's lifecycle, and if the
  # Reopen attach fails outright the lifecycle may never run at all.
  # Sampling $LOGDIR once, at that exact instant, was the bug: measured
  # 2026-08-24, a scratch container that lived 11.4s with a failed attach
  # came back 1/4 and RED, while a healthy run needs ~13s after container
  # start to write all four logs (STATUS.md row 13). So poll with a
  # ceiling — 30s, a bit more than 2x the measured healthy figure — instead
  # of one sample. On the healthy path the logs are already there on the
  # first check, so this returns immediately, no sleep taken.
  #
  # Container side is not racy and keeps the original single sample: step
  # 4b replays the three lifecycle hooks itself, synchronously
  # (`docker exec`), before ever setting CONTAINER_UP.
  LIFECYCLE_TIMEOUT=30
  LOGDIR="$SCRATCH/.devcontainer/tmp/logs"
  N_LIFECYCLE=0
  WAITED=0
  while :; do
    N_LIFECYCLE=0
    if [ -d "$LOGDIR" ]; then
      for phase in initialize on-create post-create post-start; do
        ls "$LOGDIR/${phase}"*.log >/dev/null 2>&1 && N_LIFECYCLE=$((N_LIFECYCLE + 1))
      done
    fi
    [ "$N_LIFECYCLE" -ge "$WANT_LIFECYCLE" ] && break
    [ "$SIDE" = host ] || break
    [ "$WAITED" -ge "$LIFECYCLE_TIMEOUT" ] && break
    sleep 1
    WAITED=$((WAITED + 1))
  done
  if [ -d "$LOGDIR" ]; then
    mkdir -p "$BUNDLE/project-logs"
    cp "$LOGDIR"/* "$BUNDLE/project-logs/" 2>/dev/null
  fi

  {
    docker ps -a 2>&1
    printf '\n---- volumes ----\n'
    docker volume ls 2>&1
  } > "$BUNDLE/docker-state-cold.txt" 2>&1

  if [ -f "$SCRATCH/.devcontainer/.env" ]; then
    sed -E 's/^([A-Z_]*(TOKEN|SECRET|KEY|WEBHOOK|PASSWORD)[A-Z_]*=).*/\1<redacted>/' \
      "$SCRATCH/.devcontainer/.env" > "$BUNDLE/env.redacted.txt" 2>/dev/null
  fi

  if [ "$N_LIFECYCLE" -ge "$WANT_LIFECYCLE" ]; then
    COLLECT_OK=1
    record "$COLLECT_LABEL" PASS "$COLLECT_DETAIL"
  elif [ "$SIDE" = host ] && ! grep -aq 'Running the onCreateCommand' "$TRACE" 2>/dev/null; then
    # (a) the lifecycle never started — decidable from the trace alone, no
    # extra probe needed (TRACE is already in hand from step 6's gesture).
    record "$COLLECT_LABEL" FAIL \
      "${N_LIFECYCLE}/${WANT_LIFECYCLE} lifecycle logs after ${WAITED}s — the container's lifecycle never started (no onCreateCommand in the trace; check the Reopen attach)"
  elif [ "$SIDE" = host ]; then
    # (b) the lifecycle ran and did not finish in time.
    record "$COLLECT_LABEL" FAIL \
      "${N_LIFECYCLE}/${WANT_LIFECYCLE} lifecycle logs after ${WAITED}s in $LOGDIR — the lifecycle started but did not finish"
  else
    record "$COLLECT_LABEL" FAIL \
      "${N_LIFECYCLE}/${WANT_LIFECYCLE} lifecycle logs found in $LOGDIR"
  fi
elif [ "$SIDE" = container ]; then
  record "$COLLECT_LABEL" SKIP "v3test2 stack not started (step 4b failed or skipped)"
else
  record "$COLLECT_LABEL" SKIP "Reopen failed or skipped"
fi

# ===========================================================================
sect "8. R1 — has the server tarball already gone through the filter?"
# ===========================================================================
# TEST-PLAN-4's timeline shows the initial download precedes the firewall
# going up — R1 is a cheap check before forcing R2; finding nothing here
# is normal.

if [ "$COLLECT_OK" -eq 1 ]; then
  if docker exec -u 0 "$CONTAINER" grep -aiE 'dbazure/download' /var/log/mitmproxy.log \
       >"$BUNDLE/mitmproxy-cold.txt" 2>/dev/null; then
    R1_HIT=1
    record "8. R1 (log already present at boot)" PASS
  else
    info "nothing at boot — expected, the download precedes the firewall. R2 will force the real path."
    # PASS, not OMIT: the probe RAN and its expected outcome occurred — the
    # section header above says finding nothing here is normal, and R1's job
    # is to decide cheaply whether R2 is needed, not to find the download.
    # This branch fires on every healthy run, so OMIT would put GREEN/exit 0
    # permanently out of reach and collapse the tier ladder to two rungs.
    record "8. R1 (log already present at boot)" PASS \
      "nothing at boot — normal timeline, R2 proves the real path"
  fi
else
  record "8. R1 (log already present at boot)" SKIP "collect failed or skipped"
fi

# ===========================================================================
sect "9. R2 — reattach to an already-running container"
# ===========================================================================
# The only path where defect 6 can bite: firewall already active, VS Code
# reattaching and discovering it is missing the server commit.

if [ "$SIDE" = container ]; then
  # R2 is a VS Code REATTACH: close the window, reopen it, and prove the server
  # binary was re-downloaded THROUGH the live filter. The gesture is the test.
  # And the dev-container authority this would need names a HOST filesystem
  # path and a HOST docker context (see build_authority), so a container living
  # in a nested daemon is not attachable from the host's VS Code at all.
  record "9. R2 (reattach)" NA \
    "VS Code reattach — human half (the dev-container authority names a host filesystem path and docker context)"
elif [ "$NO_PURGE" -eq 1 ]; then
  # Without the purge the server binary is still cached, so the reattach
  # re-downloads nothing and R2 traverses no filter. Not played on purpose —
  # and the human is not asked to close the window for nothing either.
  record "9. R2 (reattach)" OMIT \
    "--no-purge: without a purge the reattach re-downloads nothing"
elif [ "$R1_HIT" -eq 1 ]; then
  record "9. R2 (reattach)" OMIT "R1 already found the proof — R2 superfluous"
elif [ "$COLLECT_OK" -eq 1 ]; then
  STARTED_BEFORE="$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
  if [ -z "$STARTED_BEFORE" ]; then
    record "9. R2 (reattach)" FAIL "container $CONTAINER not found — was it left Up?"
  else
    cat <<EOF

    Close the VS Code window for $SCRATCH now — Cmd-W, NEVER Cmd-Q.
    This is necessary: without closing it, a second \`code\` call only
    focuses the already-attached window and replays nothing.
EOF
    printf '    type "ok" once the window is closed: '
    read -r _CLOSED

    if purge_vscode_cache; then
      step "reopening $SCRATCH (reattach expected, no recreation)…"
      open_scratch
      cat <<EOF

    VS Code must REATTACH to the container that is already running — no
    creation, no restart. Wait for the attach to finish (the server
    re-downloads through the active filter, which can take up to ~2 min).
EOF
      if wait_for_gesture; then
        STARTED_AFTER="$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
        if [ "$STARTED_AFTER" != "$STARTED_BEFORE" ]; then
          record "9. R2 (reattach)" FAIL "the container restarted ($STARTED_BEFORE → $STARTED_AFTER) — R2 is not testing what it claims"
        elif docker exec -u 0 "$CONTAINER" grep -aiE 'dbazure/download' /var/log/mitmproxy.log \
               >"$BUNDLE/mitmproxy-reattach.txt" 2>/dev/null; then
          cp "$TRACE" "$BUNDLE/dev-containers-trace-reattach.log" 2>/dev/null
          record "9. R2 (reattach)" PASS
        else
          record "9. R2 (reattach)" FAIL "no /dbazure/download request in /var/log/mitmproxy.log after reattach — defect 6 reproduced"
        fi
      else
        record "9. R2 (reattach)" FAIL "gesture not verified (see above)"
      fi
    else
      record "9. R2 (reattach)" SKIP "purge declined or failed"
    fi
  fi
else
  record "9. R2 (reattach)" SKIP "cold pass failed or skipped"
fi

# ===========================================================================
sect "10. tarball"
# ===========================================================================

{
  docker ps -a 2>&1
  printf '\n---- volumes ----\n'
  docker volume ls 2>&1
} > "$BUNDLE/docker-state-final.txt" 2>&1

if tar -czf "$TGZ" -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")" 2>/dev/null; then
  rm -rf "$BUNDLE"
  record "10. tarball" PASS "$TGZ"
else
  record "10. tarball" FAIL "tar failed — content left in $BUNDLE/"
fi

# ===========================================================================
# 10b — `docker save` of the image. AGENT SIDE ONLY.
# ===========================================================================
# The image the agent built lives in the nested daemon's store, which the host
# cannot see. This is what lets the human's run inherit steps 1 and 2-3 instead
# of repaying a --no-cache build: section 0b loads this tar and checks its id
# against the handshake.
#
# It lives under $PROJECT_ROOT/.tmp/ and NEVER under $REPO. $REPO is step 1's
# build context and there is no .dockerignore, so a ~1.1 GB tar left there would
# be streamed to the daemon on every subsequent build. .tmp/ is gitignored.
#
# The df preflight is not ceremony: `docker save` needs room in three places at
# once (dind's own volume, this tar on the bind mount, the host daemon after the
# load). A truncated tar is the bad outcome — it looks like an artifact, and only
# 0b's identity check would catch it, one run later. A recorded FAIL now is
# cheaper. `docker save` streams, so it can fill a disk without warning.
if [ "$SIDE" = container ]; then
  sect "10b. docker save (artifact for the human half)"

  if [ "$BUILD_OK" -eq 1 ]; then
    IMG_BYTES="$(docker image inspect -f '{{.Size}}' "$IMG" 2>/dev/null || echo 0)"
    # +25%: `docker save` writes uncompressed layers, so the tar runs slightly
    # over the reported image size, and a disk filled to the last byte is its own
    # failure mode.
    NEED_KB=$(( IMG_BYTES / 1024 * 5 / 4 ))
    FREE_KB="$(df -Pk "$AGENT_TMP" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "${FREE_KB:-}" in ''|*[!0-9]*) FREE_KB=0 ;; esac

    if [ "$FREE_KB" -lt "$NEED_KB" ]; then
      record "10b. docker save" FAIL \
        "insufficient space under ${AGENT_TMP}: $((FREE_KB / 1024)) MB free, $((NEED_KB / 1024)) MB needed — a truncated tar would be worse than a red here"
    elif docker save "$IMG" -o "$IMAGE_TAR" 2>"$AGENT_TMP/save-err.log" ; then
      # Readability is the proof the stream completed. `docker save` can exit 0
      # having written a short file if the disk fills under it.
      if tar -tf "$IMAGE_TAR" >/dev/null 2>&1; then
        IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)"
        # Published ONLY here, on the one path where a verified tar exists. The
        # path is a constant, so announcing it unconditionally would advertise a
        # stale tar from an earlier run as this run's artifact — 0b's identity
        # check would reject it, but only after loading 1.1 GB to find out.
        HANDSHAKE_TAR="$IMAGE_TAR_REL"
        TAR_MB=$(( $(wc -c <"$IMAGE_TAR") / 1024 / 1024 ))
        record "10b. docker save" PASS "${IMAGE_TAR_REL} — ${TAR_MB} MB, ${IMAGE_ID}"
      else
        record "10b. docker save" FAIL \
          "${IMAGE_TAR_REL} unreadable by tar — truncated archive, inheritance would refuse it"
      fi
    else
      record "10b. docker save" FAIL "docker save failed: $(tr '\n' ' ' <"$AGENT_TMP/save-err.log" 2>/dev/null)"
    fi
    rm -f "$AGENT_TMP/save-err.log"
  else
    record "10b. docker save" SKIP "build failed — nothing to export"
  fi
fi

# ===========================================================================
sect "11. verdict"
# ===========================================================================

# Status -> tier. Adding a status costs exactly three edits and nothing else:
# one arm in record() (the LIVE print, during the run), one arm below (glyph +
# severity, the FINAL table), and one row in this comment. Miss record() and
# the step prints ✘ while it happens and ⊘/∅ afterwards — a glyph mismatch
# that reads as a failure.
# The arm below carries only a glyph and a severity, and both the counters and
# the tier are driven by the severity — a closed set of three, because a new
# status always joins an existing family.
#
#   status | glyph | meaning                                       | sev | tier
#   -------+-------+-----------------------------------------------+-----+--------------
#   PASS   |   ✔   | ran and verified                              |  0  | GREEN
#   OMIT   |   ⊘   | not played, deliberately, no defect           |  1  | GREEN PARTIEL
#   NA     |   ∅   | the OTHER half plays this step                |  1  | GREEN PARTIEL
#   SKIP   |   –   | not playable, an upstream step broke          |  2  | RED
#   *      |   ✘   | played and failed (FAIL, or unknown status)   |  2  | RED
#
# NA and SKIP must never be confused, and the difference is not cosmetic. NA
# asserts that the other half CAN play this step, so the pair of runs is still
# complete; SKIP says nobody played it because something upstream broke, which
# is why it stays RED. Routing an upstream break to NA would launder it into
# GREEN PARTIEL — the one mistake the four-status split was built to prevent.
#
# `sev` is a SEVERITY RANK, not an exit code: GREEN 0 < GREEN PARTIEL 1 < RED
# 2. The exit codes (0 / 2 / 1) are mapped once, at the bottom. An unknown
# status falls in the catch-all and is RED at both ends (here and in
# record()), so a status added on one side and forgotten on the other can
# never produce a false green.
WORST=0; N_GREEN=0; N_PARTIAL=0; N_RED=0
i=0
while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
  name="${STEP_NAMES[$i]}"; status="${STEP_STATUS[$i]}"; detail="${STEP_DETAIL[$i]}"
  case "$status" in
    PASS) glyph='✔'; sev=0 ;;
    OMIT) glyph='⊘'; sev=1 ;;
    NA)   glyph='∅'; sev=1 ;;
    SKIP) glyph='–'; sev=2 ;;
    *)    glyph='✘'; sev=2 ;;
  esac
  if [ -n "$detail" ]; then
    printf '  %s %-45s (%s)\n' "$glyph" "$name" "$detail"
  else
    printf '  %s %-45s\n' "$glyph" "$name"
  fi
  [ "$sev" -gt "$WORST" ] && WORST="$sev"
  case "$sev" in
    0) N_GREEN=$((N_GREEN + 1)) ;;
    1) N_PARTIAL=$((N_PARTIAL + 1)) ;;
    *) N_RED=$((N_RED + 1)) ;;
  esac
  i=$((i + 1))
done

echo
case "$WORST" in
  0) TIER=GREEN; RC=0
     echo "-> GREEN: every step actually ran and was verified."
     echo "   This image is publishable." ;;
  1) TIER=GREEN_PARTIEL; RC=2
     echo "-> GREEN PARTIEL: nothing failed, but at least one step was"
     echo "   deliberately not played (⊘ above). On this basis alone,"
     echo "   the image is not publishable — replay the ⊘ steps." ;;
  *) TIER=RED; RC=1
     echo "-> RED: at least one step failed, or could not be played because"
     echo "   an upstream step broke. Refuse to call this green until it is"
     echo "   fixed — see the detail above." ;;
esac

# The handshake — what the OTHER half needs, and it gets its own line.
#
# It was tempting to widen the trailer instead. Refused: the trailer answers
# "how did this run end", is emitted on every path including fatal(), and its
# key set was deliberately frozen so a new ledger status folds into `partial=`
# without reshaping it. The handshake answers a different question — "here is
# the artifact, and which steps it covers" — exists only agent-side, and only on
# a run that got far enough to have one. Two questions, two lines, each with its
# own reason to change.
#
# Same parse contract as the trailer: a `## ` prefix, whitespace-free tokens,
# and date= LAST (sed -n 's/.*date=//p'). `tar=` is RELATIVE to the project root
# because the reader mounts this repo at a different absolute path. `steps=`
# lists PASS steps only, so 0b can never inherit something that was omitted,
# skipped or played by the human.
if [ "$SIDE" = container ]; then
  printf '## RELEASE-CHECK-HANDSHAKE steps=%s imageid=%s tar=%s date=%s\n' \
    "${STEPS_CSV:--}" "${IMAGE_ID:--}" "${HANDSHAKE_TAR:--}" \
    "$(date '+%Y-%m-%d %H:%M:%S')"
fi

# The machine trailer — LAST line before the trap's __END__ (which is why the
# trap prints nothing else). The prefix is deliberately NOT `## VERDICT`:
# run-all.sh greps that one out of test/results/*.log to reconcile the two
# halves, and this script's output landing there some day would poison it.
# tier= first, date= last — the project parse idiom is sed -n 's/.*date=//p'.
trailer "$TIER" "$RC" "$N_GREEN" "$N_PARTIAL" "$N_RED"
exit "$RC"

}   # end of the single brace group — see the note at the top
