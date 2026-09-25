#!/usr/bin/env bash
# Overlay contract — what a PROJECT may add, replace or switch off on top of
# the base image, and what stays baked whatever the project does.
#
#   bash test/overlay.test.sh            # auto-detects its context
#   bash test/overlay.test.sh --unit     # layer 1 only, never touches Docker
#   IMG=ghcr.io/…/devcontainer-sandbox:TAG bash test/overlay.test.sh
#
# Two layers, because half of this contract is pure resolution logic and the
# other half only exists once the image is built :
#
#   1. anywhere, no Docker — devc-hook and sync-skills driven against throwaway
#      trees through their DEVC_* overrides. Sub-second, runs in-container.
#   2. host only, needs Docker — the same contract against the REAL image,
#      plus the image-level guarantees (locale, baked patches).
#
# The script decides which layers it can run and says so. It never reports
# green for a layer it skipped.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IMG="${IMG:-devcontainer-sandbox:local}"
UNIT_ONLY=0
[ "${1:-}" = "--unit" ] && UNIT_ONLY=1

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  – %s (skipped: %s)\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
# Same as check but shows what was actually produced when it fails — used for
# the assertions where "it differs" is useless without the diff.
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; printf '      attendu : %s\n      obtenu  : %s\n' "$3" "$2" >&2; fi }

# --- Context -----------------------------------------------------------------

IN_CONTAINER=0; [ -f /.dockerenv ] && IN_CONTAINER=1
HAS_DOCKER=0
if [ "$UNIT_ONLY" -eq 0 ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  HAS_DOCKER=1
fi
# Layer 1 drives devc-hook, which uses `declare -A` and GNU coreutils. On a Mac
# host (bash 3.2, BSD stat) it would emit a wall of misleading failures — so we
# detect and skip loudly. That is not a gap : layer 1 is meant to run inside the
# container, layer 2 on the host, and together they cover the contract.
HAS_GNU=1
stat -c '%a' package.json >/dev/null 2>&1 || HAS_GNU=0
[ "${BASH_VERSINFO[0]}" -ge 4 ] || HAS_GNU=0
command -v python3 >/dev/null 2>&1 || HAS_GNU=0

echo "═══ context ═══"
if [ "$IN_CONTAINER" -eq 1 ]; then
  echo "  where  : INSIDE a container ($(uname -m))"
else
  echo "  where  : host ($(uname -s) $(uname -m))"
fi
if [ "$HAS_GNU" -eq 1 ]; then
  echo "  layer 1 : active (bash ${BASH_VERSINFO[0]}, GNU coreutils, python3)"
else
  echo "  layer 1 : skipped - needs bash 4+, GNU coreutils and python3 (so: in the container)"
fi
if [ "$UNIT_ONLY" -eq 1 ]; then
  echo "  layer 2 : ignored (--unit)"
elif [ "$HAS_DOCKER" -eq 1 ]; then
  echo "  layer 2 : active on $IMG"
else
  echo "  layer 2 : skipped - docker missing or unreachable (so: replay on the host)"
fi

# The local layer needs a filesystem that honours the exec bit; the docker
# layer needs a path the nested daemon can resolve as a -v source (see WS).
TMPROOT="$(TMPDIR=/tmp mktemp -d)"
WS=""
trap 'rm -rf "$TMPROOT" "$WS"' EXIT

# =============================================================================
echo
echo "═══ 1. hooks - add, replace, disable (no Docker) ═══"
# =============================================================================

if [ "$HAS_GNU" -eq 0 ]; then
  skip "layer 1 - hooks (36 assertions)"         "non-GNU environment"
  skip "layer 1 - skills (16 assertions)"        "non-GNU environment"
  skip "layer 1 - broken inputs (22 assertions)" "non-GNU environment"
else

# A fake base layer, so the assertions do not move every time a real fragment
# is added to the image.
FB="$TMPROOT/h/base/hooks/post-start.d"
FE="$TMPROOT/h/ext/hooks/post-start.d"
FO="$TMPROOT/h/ovl/hooks/post-start.d"
CFG="$TMPROOT/h/cfg"
mkdir -p "$FB" "$FE" "$FO" "$CFG"
frag() { printf '#!/usr/bin/env bash\n# @required %s\necho "MARK:%s"\n%s\n' "$2" "$3" "${4:-}" > "$1"; }
frag "$FB/10-alpha.sh"  false alpha-base
frag "$FB/20-bravo.sh"  false bravo-base
frag "$FB/90-zulu.sh"   false zulu-base

# DEVC_EXT_HOOKS is pinned to a throwaway dir, never left to its default: the
# assertions must not depend on whether the machine running them happens to
# have an /opt/devcontainer/ext.
#
# DEVC_HOOK_VERBOSE: since the two sinks, devc-hook routes fragment output to the
# phase log and only a curated view to the terminal. These assertions are about
# the DISPATCHER — which fragment ran, which was skipped, which warned — so they
# ask for the unrouted stream. The routing itself is pinned in its own section
# at the end of this file, which reads the log FILE.
#
# Not by reading the file here: the log name is `<phase>-$(date +%Y%m%d-%H%M%S)`
# and the writer appends, and `hook post-start` runs dozens of times back to
# back. Several land in the same second and therefore the same file, so every
# NEGATIVE assertion below (`! grep -q 'MARK:bravo-base'`) would be reading a
# previous run's bytes. An `rm -f` in this helper would silently change what all
# of them see at once.
hook() { DEVC_BASE_HOOKS="$TMPROOT/h/base/hooks" DEVC_EXT_HOOKS="$TMPROOT/h/ext/hooks" \
         DEVC_OVERLAY_HOOKS="$TMPROOT/h/ovl/hooks" \
         DEVC_CONFIG_DIR="$CFG" DEVC_HOOK_VERBOSE=1 bash bin/devc-hook "$@" 2>&1; }

N=$(hook post-start --dry-run | grep -c 'WOULD RUN')
checkeq "base alone: 3 fragments" "$N" "3"

# --- add ---
frag "$FO/30-charlie.sh" false charlie-ovl
N=$(hook post-start --dry-run | grep -c 'WOULD RUN')
checkeq "overlay adds a fragment: 4" "$N" "4"
ORDER=$(hook post-start --dry-run | grep 'WOULD RUN' | sed 's/.*post-start\.d\///;s/ .*//' | tr '\n' ' ')
checkeq "the addition lands at its numeric position" "$ORDER" "10-alpha.sh 20-bravo.sh 30-charlie.sh 90-zulu.sh "

# --- replace ---
frag "$FO/20-bravo.sh" false bravo-OVERLAY
N=$(hook post-start --dry-run | grep -c 'WOULD RUN')
checkeq "same-name replacement does not duplicate: 4" "$N" "4"
OUT=$(hook post-start)
check "the body that runs is the overlay one" "printf '%s' \"\$OUT\" | grep -q 'MARK:bravo-OVERLAY'"
check "the base body no longer runs"          "! printf '%s' \"\$OUT\" | grep -q 'MARK:bravo-base'"

# --- disable ---
cat > "$CFG/devcontainer.json" <<'JSON'
{
  // a comment, because devcontainer.json is JSONC and plain JSON parsers are not
  "customizations": {
    "stitchu-devc": { "disabledHooks": ["post-start.d/30-charlie.sh"] }
  }
}
JSON
OUT=$(hook post-start)
check "disabledHooks skips the fragment"        "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"
check "and its body does not run"             "! printf '%s' \"\$OUT\" | grep -q 'MARK:charlie-ovl'"
check "// comments do not break the JSONC reader" "! printf '%s' \"\$OUT\" | grep -qi 'parse error'"

# devcontainer.local.json adds to devcontainer.json (union, not replacement)
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["post-start.d/10-alpha.sh"]}}}\n' > "$CFG/devcontainer.local.json"
OUT=$(hook post-start)
check "local.json disables too"           "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/10-alpha.sh'"
check "without cancelling the team one"  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"

# an entry for ANOTHER phase must disable nothing here
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["on-create.d/10-alpha.sh"]}}}\n' > "$CFG/devcontainer.local.json"
OUT=$(hook post-start)
check "an on-create.d entry does not touch post-start" "! printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/10-alpha.sh'"
rm -f "$CFG/devcontainer.local.json" "$CFG/devcontainer.json"

# --- hooks/disabled.txt: the same list, in the format the rest of the config
# --- already uses. Same four rules as the firewall allowlists.
cat > "$TMPROOT/h/ovl/hooks/disabled.txt" <<'TXT'
# switch off the noisy one
post-start.d/30-charlie.sh   # inline comments work here too

TXT
OUT=$(hook post-start)
check "disabled.txt skips the fragment"    "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"
check "and its body does not run"        "! printf '%s' \"\$OUT\" | grep -q 'MARK:charlie-ovl'"

printf 'on-create.d/10-alpha.sh\n' >> "$TMPROOT/h/ovl/hooks/disabled.txt"
OUT=$(hook post-start)
check "an on-create.d line does not touch post-start" \
  "! printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/10-alpha.sh'"

# THE case this format exists for: a devcontainer.json the shell cannot parse
# no longer takes the .txt list down with it. Before, `disabledHooks` was the
# only channel, so one URL in the config disabled nothing at all.
printf '{ ceci nest pas du json\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "a broken devcontainer.json does not cancel disabled.txt" \
  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"
rm -f "$CFG/devcontainer.json"

# union with the JSON alias, both directions
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["post-start.d/20-bravo.sh"]}}}\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "the .txt and the JSON alias union"  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/20-bravo.sh'"
check "neither cancels the other"          "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"
rm -f "$CFG/devcontainer.json" "$TMPROOT/h/ovl/hooks/disabled.txt"

# --- flat overlay ---
printf '#!/usr/bin/env bash\necho "MARK:flat"\n' > "$TMPROOT/h/ovl/hooks/post-start.sh"
OUT=$(hook post-start)
check "a non-executable post-start.sh is ignored" "! printf '%s' \"\$OUT\" | grep -q 'MARK:flat'"
chmod +x "$TMPROOT/h/ovl/hooks/post-start.sh"
OUT=$(hook post-start)
check "an executable post-start.sh runs"           "printf '%s' \"\$OUT\" | grep -q 'MARK:flat'"
checkeq "and it runs last" \
  "$(printf '%s' "$OUT" | grep -n 'MARK:' | tail -1 | sed 's/.*MARK://')" "flat"
rm -f "$TMPROOT/h/ovl/hooks/post-start.sh"

# --- @required: the difference between a phase that stops and one that goes on
frag "$FO/40-delta.sh" false delta-ovl 'exit 3'
OUT=$(hook post-start)
check "an optional fragment that fails -> WARN"    "printf '%s' \"\$OUT\" | grep -q 'WARN post-start.d/40-delta.sh'"
check "and the phase runs to the end"              "printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
frag "$FO/40-delta.sh" true delta-ovl 'exit 3'
OUT=$(hook post-start) || true
check "a required fragment that fails -> FAIL"     "printf '%s' \"\$OUT\" | grep -q 'FAIL post-start.d/40-delta.sh'"
check "and the phase stops there"                  "! printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
check "the later fragments do not run"             "! printf '%s' \"\$OUT\" | grep -q 'MARK:zulu-base'"
rm -f "$FO/40-delta.sh"

# --- the ext layer (level 2: a Dockerfile that FROMs the image) -------------
# Same contract as the project overlay, one rank lower. It exists so an
# extending image never writes into the base layer.
frag "$FE/50-echo.sh" false echo-ext
N=$(hook post-start --dry-run | grep -c 'WOULD RUN')
checkeq "ext adds a fragment: 5" "$N" "5"
ORDER=$(hook post-start --dry-run | grep 'WOULD RUN' | sed 's/.*post-start\.d\///;s/ .*//' | tr '\n' ' ')
checkeq "the ext addition lands at its numeric position" "$ORDER" \
  "10-alpha.sh 20-bravo.sh 30-charlie.sh 50-echo.sh 90-zulu.sh "
check "and the log names the layer it came from" \
  "hook post-start --dry-run | grep -q 'post-start.d/50-echo.sh (ext,'"

# stacking: base < ext < overlay, on ONE basename
frag "$FE/10-alpha.sh" false alpha-EXT
OUT=$(hook post-start)
check "ext replaces the base fragment"  "printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-EXT'"
check "the base body no longer runs"  "! printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-base'"
frag "$FO/10-alpha.sh" false alpha-OVL
OUT=$(hook post-start)
check "the project wins over ext"       "printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-OVL'"
check "the ext body no longer runs"   "! printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-EXT'"
checkeq "one winner, not three" \
  "$(printf '%s' "$OUT" | grep -c 'post-start.d/10-alpha.sh (')" "1"
rm -f "$FO/10-alpha.sh" "$FE/10-alpha.sh"

# a project switches off a fragment that came from the extending image
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["post-start.d/50-echo.sh"]}}}\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "disabledHooks reaches an ext fragment too" "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/50-echo.sh'"
check "and its body does not run"               "! printf '%s' \"\$OUT\" | grep -q 'MARK:echo-ext'"
rm -f "$CFG/devcontainer.json"

# ... and the extending image gets its OWN list. It cannot write the project's
# devcontainer.json, so before this its only way to switch off a base fragment
# was to shadow the file — the one route that walks around the @required guard.
printf 'post-start.d/20-bravo.sh\n' > "$TMPROOT/h/ext/hooks/disabled.txt"
OUT=$(hook post-start)
check "ext/disabled.txt switches off a base fragment" \
  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/20-bravo.sh'"
check "and the ext layer's own fragment still runs" \
  "printf '%s' \"\$OUT\" | grep -q 'MARK:echo-ext'"
rm -f "$TMPROOT/h/ext/hooks/disabled.txt" "$FE/50-echo.sh"

# --- @required cannot be switched off by accident (C3) ---------------------
# The image's own firewall bring-up is @required. Nothing used to stop a
# project from listing it in disabledHooks and booting wide open in silence.
frag "$FB/70-golf.sh" true golf-base
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["post-start.d/70-golf.sh"]}}}\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "disabling a @required fragment is REFUSED" "printf '%s' \"\$OUT\" | grep -q 'REFUSED to disable post-start.d/70-golf.sh'"
check "and the fragment runs anyway"              "printf '%s' \"\$OUT\" | grep -q 'MARK:golf-base'"
printf '{"customizations":{"stitchu-devc":{"disabledHooks":["!post-start.d/70-golf.sh"]}}}\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "the ! opt-in does switch it off"           "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/70-golf.sh'"
check "and then its body does not run"          "! printf '%s' \"\$OUT\" | grep -q 'MARK:golf-base'"
check "the ! form is not itself refused"        "! printf '%s' \"\$OUT\" | grep -q 'REFUSED'"
rm -f "$CFG/devcontainer.json"

# the guard and its opt-in survive the format change, verbatim on both sides
printf 'post-start.d/70-golf.sh\n' > "$TMPROOT/h/ovl/hooks/disabled.txt"
OUT=$(hook post-start)
check "disabled.txt cannot switch off @required either" \
  "printf '%s' \"\$OUT\" | grep -q 'REFUSED to disable post-start.d/70-golf.sh'"
printf '!post-start.d/70-golf.sh\n' > "$TMPROOT/h/ovl/hooks/disabled.txt"
OUT=$(hook post-start)
check "and the ! opt-in works from the .txt too" \
  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/70-golf.sh'"
rm -f "$TMPROOT/h/ovl/hooks/disabled.txt"

# ... and shadowing is not a way around the guard: it gets named.
frag "$FE/70-golf.sh" false golf-ext
OUT=$(hook post-start)
check "shadowing a @required fragment is announced" \
  "printf '%s' \"\$OUT\" | grep -q \"70-golf.sh comes from 'ext' and shadows a 'base' fragment marked @required\""
rm -f "$FE/70-golf.sh" "$FB/70-golf.sh"

# =============================================================================
echo
echo "═══ 2. skills - add, replace, disable (no Docker) ═══"
# =============================================================================

SB="$TMPROOT/s/base"; SO="$TMPROOT/s/ovl"; SH="$TMPROOT/s/home"
mkdir -p "$SB/foo" "$SO" "$SH"
printf 'BASE BODY\n' > "$SB/foo/foo.skill.md"
printf 'console.log(1)\n' > "$SB/foo/hook.js"
# Written with the SHIPPED prefix on purpose : retargeting a command that
# points at a path this container does not have is the whole point.
cat > "$SB/foo/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/base/skills/foo/hook.js"}]}]}
JSON

SE="$TMPROOT/s/ext"; mkdir -p "$SE"
skills() { DEVC_BASE_SKILLS="$SB" DEVC_EXT_SKILLS="$SE" DEVC_OVERLAY_SKILLS="$SO" \
           DEVC_CLAUDE_HOME="$SH" bash bin/sync-skills "$@" 2>&1; }

skills >/dev/null
check "the baked skill installs"                  "[ -f '$SH/commands/foo.md' ]"
checkeq "its body is the base one" "$(cat "$SH/commands/foo.md" 2>/dev/null)" "BASE BODY"
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))" 2>/dev/null)
checkeq "its hook is registered once" "$NH" "1"
CMD=$(python3 -c "import json;print(json.load(open('$SH/settings.json'))['hooks']['SessionStart'][0]['hooks'][0]['command'])" 2>/dev/null)
checkeq "and retargeted to the directory actually read" "$CMD" "node $SB/foo/hook.js"

# --- add ---
mkdir -p "$SO/bar"
printf 'BAR\n' > "$SO/bar/bar.skill.md"
skills >/dev/null
check "a project skill is added" "[ -f '$SH/commands/bar.md' ]"

# --- replace ---
mkdir -p "$SO/foo"
printf 'OVERLAY BODY\n' > "$SO/foo/foo.skill.md"
printf 'console.log(2)\n' > "$SO/foo/hook.js"
cat > "$SO/foo/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /workspace/.devcontainer/skills/foo/hook.js"}]}]}
JSON
skills >/dev/null
checkeq "the project replaces the baked skill body" "$(cat "$SH/commands/foo.md")" "OVERLAY BODY"
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json'))['hooks']['SessionStart']))")
checkeq "its hook REPLACES instead of adding" "$NH" "1"
CMD=$(python3 -c "import json;print(json.load(open('$SH/settings.json'))['hooks']['SessionStart'][0]['hooks'][0]['command'])")
checkeq "and points at the project copy" "$CMD" "node $SO/foo/hook.js"

# --- the ext layer (level 2) ---
mkdir -p "$SE/qux"
printf 'QUX EXT\n' > "$SE/qux/qux.skill.md"
printf 'console.log(9)\n' > "$SE/qux/hook.js"
# Written with the SHIPPED ext prefix: retargeting a path this machine does not
# have is the point, exactly as for the base layer above.
cat > "$SE/qux/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/ext/skills/qux/hook.js"}]}]}
JSON
skills >/dev/null
check "an ext skill installs" "[ -f '$SH/commands/qux.md' ]"
CMD=$(python3 -c "
import json
for e in json.load(open('$SH/settings.json'))['hooks']['SessionStart']:
    c = e['hooks'][0]['command']
    if 'qux' in c: print(c)")
checkeq "and its hook is retargeted to the ext dir" "$CMD" "node $SE/qux/hook.js"
# and the project still outranks it on the same name
mkdir -p "$SE/foo"; printf 'EXT BODY\n' > "$SE/foo/foo.skill.md"
skills >/dev/null
checkeq "project > ext > base on one skill name" "$(cat "$SH/commands/foo.md")" "OVERLAY BODY"
# Hand the fixture back as it was found: the assertions below count entries,
# and a leftover ext hook would move every one of them.
rm -rf "$SE/foo" "$SE/qux"; skills >/dev/null

# --- replacing a BAKED skill, on its own fixture ----------------------------
# `pp` is shaped like a real shipped skill (prepare-plan): markdown + hooks.json
# + the script the hook runs. Its own fixture so the shared `foo` counts above
# and below are untouched.
mkdir -p "$SB/pp"
printf 'PP BASE\n'          > "$SB/pp/pp.skill.md"
printf 'console.log("b")\n' > "$SB/pp/run.js"
cat > "$SB/pp/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/base/skills/pp/run.js"}]}]}
JSON
pp_cmd() { python3 -c "
import json
for e in json.load(open('$SH/settings.json'))['hooks']['SessionStart']:
    c = e['hooks'][0]['command']
    if '/pp/' in c: print(c)"; }
skills >/dev/null
checkeq "the baked skill is in force" "$(cat "$SH/commands/pp.md")" "PP BASE"

# 1. an extending image replaces it, with NO project copy in the way. The
#    mirror of "ext replaces the base fragment" on the hooks side, which was
#    asserted; on the skills side only ADDING from ext ever was.
mkdir -p "$SE/pp"
printf 'PP EXT\n'           > "$SE/pp/pp.skill.md"
printf 'console.log("e")\n' > "$SE/pp/run.js"
cat > "$SE/pp/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/ext/skills/pp/run.js"}]}]}
JSON
skills >/dev/null
checkeq "with no project, ext replaces the baked body" "$(cat "$SH/commands/pp.md")" "PP EXT"
checkeq "one hook, not two"                            "$(pp_cmd | grep -c .)" "1"
checkeq "and it points at the ext copy"                "$(pp_cmd)" "node $SE/pp/run.js"

# 2. the shape most overrides actually take: the project ships the markdown
#    and nothing else. The body must swap; the baked hooks.json is still the
#    one in force, and its script must not be pruned as stale.
rm -rf "$SE/pp"
mkdir -p "$SO/pp"; printf 'PP PROJECT\n' > "$SO/pp/pp.skill.md"
skills >/dev/null
checkeq "a markdown-only override swaps the body" "$(cat "$SH/commands/pp.md")" "PP PROJECT"
checkeq "the baked hook stays in force"           "$(pp_cmd)" "node $SB/pp/run.js"
checkeq "and is still registered once"            "$(pp_cmd | grep -c .)" "1"

rm -rf "$SB/pp" "$SO/pp"; rm -f "$SH/commands/pp.md"; skills >/dev/null
checkeq "removing it retracts its hook" "$(pp_cmd | grep -c .)" "0"

# --- idempotence ---
skills >/dev/null; skills >/dev/null
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json'))['hooks']['SessionStart']))")
checkeq "three syncs in a row stack nothing" "$NH" "1"

# --- disable ---
mkdir -p "$SO/baz"
printf 'BAZ\n' > "$SO/baz/baz.skill.disabled.md"
printf 'console.log(3)\n' > "$SO/baz/hook.js"
cat > "$SO/baz/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /workspace/.devcontainer/skills/baz/hook.js"}]}]}
JSON
skills >/dev/null
check "a .skill.disabled.md skill does not become a command" "[ ! -f '$SH/commands/baz.md' ]"
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json'))['hooks']['SessionStart']))")
checkeq "and its hooks are not registered" "$NH" "1"

# --- skills/disabled.txt ---------------------------------------------------
# Renaming the markdown shelves a skill you OWN. A project cannot rename a file
# inside the image, so removing a baked skill needed a list of its own.
printf 'console.log(4)\n' > "$SB/foo/hook.js"
skills >/dev/null                     # baseline: foo is live, 1 hook registered
check "before disabling, the command is there" "[ -f '$SH/commands/foo.md' ]"

printf '# not this one\nfoo\n' > "$SO/disabled.txt"
OUT=$(skills)
check "a listed skill does not install its command" "[ ! -f '$SH/commands/foo.md' ]"
check "and the run says so"  "printf '%s' \"\$OUT\" | grep -q 'foo.md disabled'"
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))")
checkeq "and the hook it had registered is retracted" "$NH" "0"

# The command file survives in a Docker volume across an image bump, so listing
# a skill has to REMOVE what an earlier boot installed, not merely skip it.
printf 'STALE\n' > "$SH/commands/foo.md"
skills >/dev/null
check "a command left by an earlier boot is removed" "[ ! -f '$SH/commands/foo.md' ]"

# The key is the directory, so a hooks-only skill — no *.skill.md anywhere,
# which is the shape of notify-queue and session-gap — can be switched off too.
rm -f "$SO/disabled.txt"; mkdir -p "$SO/quiet"
printf 'console.log(5)\n' > "$SO/quiet/hook.js"
cat > "$SO/quiet/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /workspace/.devcontainer/skills/quiet/hook.js"}]}]}
JSON
skills >/dev/null
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))")
checkeq "a hooks-only skill registers its hook" "$NH" "2"
printf 'quiet\n' > "$SO/disabled.txt"
OUT=$(skills)
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))")
checkeq "and listing its directory retracts it" "$NH" "1"
check "even with no command to speak of" "printf '%s' \"\$OUT\" | grep -q 'skipped disabled skill: quiet'"

# The list is unioned across layers, like the hooks one: the base image can
# ship a skill switched off by default, an ext image can retract one.
rm -f "$SO/disabled.txt"; printf 'quiet\n' > "$SE/disabled.txt"
skills >/dev/null
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))")
checkeq "a list in the ext layer counts too" "$NH" "1"
rm -rf "$SE/disabled.txt" "$SO/quiet"
skills >/dev/null

# --- guard rails ---
mkdir -p "$SO/dep/node_modules/evil"
printf 'EVIL\n' > "$SO/dep/node_modules/evil/evil.skill.md"
skills >/dev/null
check "a *.skill.md under node_modules is not installed" "[ ! -f '$SH/commands/evil.md' ]"

# a skill that disappears must have its hook withdrawn, not keep failing at boot
rm -rf "$SO/foo" "$SB/foo"
skills >/dev/null
NH=$(python3 -c "import json;print(len(json.load(open('$SH/settings.json')).get('hooks',{}).get('SessionStart',[])))")
checkeq "the hook of a removed skill is pruned" "$NH" "0"

# --- a hook inherited from an older image -----------------------------------
# The shape this actually takes in the wild: ~/.claude/ lives in a volume that
# outlives the image, so entries written by a PREVIOUS boot are already in
# settings.json before sync-skills runs — with the absolute paths THAT image
# shipped, not this one's. A skill retired since, or a hook file renamed
# inside a skill that still exists, leaves a command pointing at nothing, and
# Claude Code reports it at every SessionStart.
#
# Distinct from the assertion above, where the entry was written by this same
# run and already carried a path under the test's own tree.
SB3="$TMPROOT/s3/base"; SO3="$TMPROOT/s3/ovl"; SE3="$TMPROOT/s3/ext"; SH3="$TMPROOT/s3/home"
mkdir -p "$SB3/live" "$SO3" "$SE3" "$SH3"
printf 'LIVE\n'                 > "$SB3/live/live.skill.md"
printf 'console.log("live")\n'  > "$SB3/live/hook.js"
cat > "$SB3/live/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/base/skills/live/hook.js"}]}]}
JSON
# Three entries as an old image would have left them: a skill that no longer
# ships, a file gone from a skill that survives, and one hook of the user's own.
cat > "$SH3/settings.json" <<'JSON'
{"hooks":{"SessionStart":[
  {"hooks":[{"type":"command","command":"node /opt/devcontainer/base/skills/retired/hook.js"}]},
  {"hooks":[{"type":"command","command":"node /workspace/.devcontainer/skills/live/renamed.js"}]},
  {"hooks":[{"type":"command","command":"node /home/node/my-own-hook.js"}]}
]}}
JSON
skills3() { DEVC_BASE_SKILLS="$SB3" DEVC_EXT_SKILLS="$SE3" DEVC_OVERLAY_SKILLS="$SO3" \
            DEVC_CLAUDE_HOME="$SH3" bash bin/sync-skills "$@" 2>&1; }
OUT=$(skills3)
CMDS=$(python3 -c "
import json
print('|'.join(e['hooks'][0]['command']
                for e in json.load(open('$SH3/settings.json'))['hooks']['SessionStart']))")
check "a hook whose skill no longer ships is pruned"  "! printf '%s' \"\$CMDS\" | grep -q retired"
check "a hook whose file vanished is pruned too"      "! printf '%s' \"\$CMDS\" | grep -q renamed.js"
check "and the run names what it retracted" \
  "printf '%s' \"\$OUT\" | grep -q 'pruned stale skill hook: retired/hook.js'"
# The other half of the contract: sync-skills has no business deleting a hook
# it did not write. Only <SKILLS>-shaped commands are candidates.
check "a hook of the user's own is left alone"        "printf '%s' \"\$CMDS\" | grep -q my-own-hook.js"
check "even though its target does not exist either"  "[ ! -f /home/node/my-own-hook.js ]"
check "and the live skill is registered"              "printf '%s' \"\$CMDS\" | grep -q '$SB3/live/hook.js'"
NH=$(python3 -c "import json;print(len(json.load(open('$SH3/settings.json'))['hooks']['SessionStart']))")
checkeq "2 of the 4 entries survive" "$NH" "2"

# =============================================================================
echo
echo "═══ 3. broken inputs - ignored, never fatal ═══"
# =============================================================================
# A third-party project adds files; some of them will be broken. The rule:
# a bad file costs that file, never the boot, and it is NAMED.

# --- hooks side ---
ln -s /nulle/part/parti.sh "$FO/50-lien-mort.sh"
printf 'ceci nest pas du bash <<<>>>\n' > "$FO/60-charabia.sh"
OUT=$(hook post-start)
check "a fragment whose target vanished -> WARN, not a crash" "printf '%s' \"\$OUT\" | grep -q 'WARN post-start.d/50-lien-mort.sh'"
check "an unreadable fragment -> WARN"                        "printf '%s' \"\$OUT\" | grep -q 'WARN post-start.d/60-charabia.sh'"
check "and the phase still completes"                         "printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
check "the healthy fragments ran"                             "printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-base'"
printf '{ ceci nest pas du json\n' > "$CFG/devcontainer.json"
OUT=$(hook post-start)
check "an unreadable devcontainer.json stops nothing"         "printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
check "and it says so instead of emptying the list in silence" \
  "printf '%s' \"\$OUT\" | grep -q 'devcontainer.json could not be parsed'"
rm -f "$FO/50-lien-mort.sh" "$FO/60-charabia.sh" "$CFG/devcontainer.json"

# A URL in the config used to be fatal: the line-wise `//` stripper cut inside
# the string too, handed jq invalid JSON, and the WHOLE list vanished — first
# in silence, then (4.1b) with a warning naming the file. The strip is
# string-aware now, so this is simply a valid config. Same fixture, opposite
# expectation: it is the assertion that motivated the format change.
cat > "$CFG/devcontainer.json" <<'JSON'
{
  // a line comment
  "documentation": "https://example.dev/guide",  // and a trailing one
  /* a block comment, with a "quoted" // inside */
  "customizations": {
    "stitchu-devc": { "disabledHooks": ["post-start.d/30-charlie.sh"], },
  },
}
JSON
OUT=$(hook post-start)
check "a URL in devcontainer.json is no longer a parse error" \
  "! printf '%s' \"\$OUT\" | grep -q 'devcontainer.json could not be parsed'"
check "and the list it carries actually applies" \
  "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/30-charlie.sh'"
check "block comments and trailing commas are tolerated" \
  "! printf '%s' \"\$OUT\" | grep -qi 'expecting'"
check "and the phase still completes" "printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
rm -f "$CFG/devcontainer.json"

# --- the shapes that look fatal and are not ---------------------------------
# Fragments are run with `bash "$frag"`, never `./frag`. So no exec bit, no
# shebang and CRLF line endings cost at most a WARN. Frozen here because the
# brief listed all three as boot-killers.
printf '#!/usr/bin/env bash\r\necho "MARK:crlf"\r\n' > "$FO/62-crlf.sh"
printf 'echo "MARK:noshebang"\n'                     > "$FO/64-nosb.sh"
printf '#!/usr/bin/env bash\necho "MARK:noexec"\n'   > "$FO/66-noexec.sh"
chmod 644 "$FO/62-crlf.sh" "$FO/64-nosb.sh" "$FO/66-noexec.sh"
OUT=$(hook post-start)
check "a CRLF fragment does not stop the phase"      "printf '%s' \"\$OUT\" | grep -q '=== post-start done ==='"
check "a fragment without shebang still runs"        "printf '%s' \"\$OUT\" | grep -q 'MARK:noshebang'"
check "a fragment without the exec bit still runs"   "printf '%s' \"\$OUT\" | grep -q 'MARK:noexec'"
rm -f "$FO/62-crlf.sh" "$FO/64-nosb.sh" "$FO/66-noexec.sh"

# --- skills side ---
# Regression 2026-08-10: a single unreadable hooks.json brought down the whole
# merge, so EVERY skill lost its hooks for that boot while the phase kept
# reporting "done".
SB2="$TMPROOT/s2/base"; SO2="$TMPROOT/s2/ovl"; SH2="$TMPROOT/s2/home"
mkdir -p "$SB2/sain" "$SO2/json-casse" "$SO2/mauvaise-forme" "$SH2"
printf 'SAIN\n' > "$SB2/sain/sain.skill.md"; printf 'x\n' > "$SB2/sain/hook.js"
printf '{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/base/skills/sain/hook.js"}]}]}\n' > "$SB2/sain/hooks.json"
printf 'A\n' > "$SO2/json-casse/a.skill.md";     printf '{ pas du json,,,\n'  > "$SO2/json-casse/hooks.json"
printf 'B\n' > "$SO2/mauvaise-forme/b.skill.md"; printf '["pas","un","objet"]\n' > "$SO2/mauvaise-forme/hooks.json"
# A handler that is a string reaches .get() in the merge loop, which runs
# OUTSIDE the guarded parse — it used to raise there and take every skill down.
mkdir -p "$SO2/handler-string"
printf 'C\n' > "$SO2/handler-string/c.skill.md"; printf '{"SessionStart":["oups"]}\n' > "$SO2/handler-string/hooks.json"
skills2() { DEVC_BASE_SKILLS="$SB2" DEVC_EXT_SKILLS="$TMPROOT/s2/ext" \
            DEVC_OVERLAY_SKILLS="$SO2" DEVC_CLAUDE_HOME="$SH2" bash bin/sync-skills 2>&1; }
OUT=$(skills2)
check "an unreadable hooks.json is skipped and named"     "printf '%s' \"\$OUT\" | grep -q 'hooks.json skipped (json-casse'"
check "a malformed hooks.json is skipped and named"       "printf '%s' \"\$OUT\" | grep -q 'hooks.json skipped (mauvaise-forme'"
check "a non-object handler is skipped and named"         "printf '%s' \"\$OUT\" | grep -q 'hooks.json skipped (handler-string'"
check "no Python traceback surfaces"                      "! printf '%s' \"\$OUT\" | grep -q 'Traceback'"
NH=$(python3 -c "import json;print(len(json.load(open('$SH2/settings.json')).get('hooks',{}).get('SessionStart',[])))" 2>/dev/null)
checkeq "and the HEALTHY skill hook survives" "$NH" "1"
check "their commands are installed anyway" "[ -f '$SH2/commands/a.md' ] && [ -f '$SH2/commands/b.md' ]"

# settings.json lives in a Docker volume that outlives the image, so it can be
# corrupt for reasons no skill controls. It must not cost the boot, and it must
# not be overwritten either — whatever the user had is still theirs.
printf 'pas du json {{{\n' > "$SH2/settings.json"
OUT=$(skills2)
check "a corrupt settings.json is named"        "printf '%s' \"\$OUT\" | grep -q 'settings.json unreadable'"
check "no traceback"                          "! printf '%s' \"\$OUT\" | grep -q 'Traceback'"
check "the skills still install"                "printf '%s' \"\$OUT\" | grep -q 'skill sain.md installed'"
check "and the corrupt file is left untouched"  "grep -q 'pas du json' '$SH2/settings.json'"
# `=== … ===` framing is the dispatcher's now: sync-skills reports under it,
# indented, so the line is in the phase log and not on the terminal.
check "sync-skills still reports done"          "printf '%s' \"\$OUT\" | grep -q '^  sync-skills done$'"

fi   # HAS_GNU

# =============================================================================
echo
echo "═══ 4. the real image (host + Docker) ═══"
# =============================================================================

if [ "$HAS_DOCKER" -eq 0 ]; then
  for t in "LANG=C.UTF-8 in the image" "effective UTF-8 locale" \
           "overlay hooks against the image" "replacing a shipped fragment" \
           "disabledHooks against the image" "overlay skills against the image" \
           "extension patches applied"; do
    skip "$t" "$([ "$UNIT_ONLY" -eq 1 ] && echo '--unit' || echo 'no docker here')"
  done
elif ! docker image inspect "$IMG" >/dev/null 2>&1; then
  skip "the whole of layer 2" "image $IMG missing - build it or pass IMG=…"
else
  DR() { docker run --rm "$@"; }

  checkeq "LANG=C.UTF-8 in the image" "$(DR "$IMG" printenv LANG 2>/dev/null)" "C.UTF-8"
  checkeq "effective UTF-8 locale"    "$(DR "$IMG" bash -lc 'locale charmap' 2>/dev/null | tr -d '\r')" "UTF-8"

  # A fake /workspace, mounted the way a project would — its own root, so it
  # stays resolvable to the daemon regardless of where TMPROOT landed.
  WS="$(mktemp -d)"
  mkdir -p "$WS/.devcontainer/hooks/post-start.d" "$WS/.devcontainer/skills/proj"
  M=(-v "$WS:/workspace")

  BASE_N=$(DR "$IMG" devc-hook post-start --dry-run | grep -c 'WOULD RUN')
  printf '#!/usr/bin/env bash\n# @required false\necho ok\n' > "$WS/.devcontainer/hooks/post-start.d/99-projet.sh"
  N=$(DR "${M[@]}" "$IMG" devc-hook post-start --dry-run | grep -c 'WOULD RUN')
  checkeq "overlay hooks against the image: +1 fragment" "$N" "$((BASE_N + 1))"

  # Replacement: reuse the name of a shipped fragment with @required flipped.
  VICTIM=$(DR "$IMG" devc-hook post-start --dry-run | grep 'WOULD RUN' | head -1 | sed 's/.*post-start\.d\///;s/ .*//')
  WAS=$(DR "$IMG" devc-hook post-start --dry-run | grep "$VICTIM" | sed 's/.*required=//;s/)//')
  FLIP=$([ "$WAS" = "true" ] && echo false || echo true)
  printf '#!/usr/bin/env bash\n# @required %s\necho ok\n' "$FLIP" > "$WS/.devcontainer/hooks/post-start.d/$VICTIM"
  GOT=$(DR "${M[@]}" "$IMG" devc-hook post-start --dry-run | grep "$VICTIM" | sed 's/.*required=//;s/)//')
  checkeq "replacing a shipped fragment ($VICTIM): the overlay wins" "$GOT" "$FLIP"
  rm -f "$WS/.devcontainer/hooks/post-start.d/$VICTIM"

  cat > "$WS/.devcontainer/devcontainer.json" <<'JSON'
{ "customizations": { "stitchu-devc": { "disabledHooks": ["post-start.d/99-projet.sh"] } } }
JSON
  check "disabledHooks against the image" \
    "DR ${M[*]} $IMG devc-hook post-start --dry-run | grep -q 'skip post-start.d/99-projet.sh'"

  printf 'PROJET\n' > "$WS/.devcontainer/skills/proj/proj.skill.md"
  check "overlay skills against the image" \
    "DR ${M[*]} -u node $IMG bash -c 'sync-skills >/dev/null 2>&1; test -f /home/node/.claude/commands/proj.md'"

  # No patch is baked in, and that is the point: the image installs the
  # extension as published. These three sentinels are the ones the image used
  # to carry — asserting their ABSENCE is what would catch a patcher creeping
  # back into the build, which is the regression that matters now.
  EXT='/home/node/.vscode-server/extensions'
  for s in '/*mbf-open*/:model badge (UX)' \
           'notify-queue-user-action-v3:user-action observer (notify)' \
           '__NOTIFY_QUEUE_AUTHORITY_WRITER_v1__:authority writer (notify)'; do
    SENT="${s%%:*}"; LABEL="${s#*:}"
    check "no patch baked in - $LABEL" \
      "! DR $IMG bash -c \"grep -rqlF '$SENT' $EXT/anthropic.claude-code-*/ 2>/dev/null\""
  done
fi

# =============================================================================
echo; echo "═══ 8. two sinks — the terminal is curated, the log is complete ═══"
# =============================================================================
# Everything above asks for DEVC_HOOK_VERBOSE=1 and asserts on the stream. This
# section asserts on the DEFAULT path and reads the log FILE, because that is
# the sink whose contract is completeness.
#
# The log is wiped per call on purpose: the name has second granularity and the
# writer appends, so without this a second call in the same second would be
# asserting a previous run's bytes. Harmless in production — one run per phase.
if [ "$HAS_GNU" -eq 1 ]; then
  routed() { rm -rf "$CFG/tmp/logs"
             DEVC_BASE_HOOKS="$TMPROOT/h/base/hooks" DEVC_EXT_HOOKS="$TMPROOT/h/ext/hooks" \
             DEVC_OVERLAY_HOOKS="$TMPROOT/h/ovl/hooks" \
             DEVC_CONFIG_DIR="$CFG" bash bin/devc-hook "$@" 2>&1; }
  plog() { cat "$CFG"/tmp/logs/post-start-*.log 2>/dev/null; }

  frag "$FO/70-warn.sh" false warn-ovl 'echo "⚠ something is off"; echo "  ↳ fix it like this"'
  OUT="$(routed post-start)"; LOGGED="$(plog)"

  check "a silent fragment says nothing on the terminal" \
    "! printf '%s' \"\$OUT\" | grep -q 'MARK:alpha-base'"
  check "…and the log kept every word of it" \
    "printf '%s' \"\$LOGGED\" | grep -q 'MARK:alpha-base'"
  check "the run line is log-only" \
    "! printf '%s' \"\$OUT\" | grep -q 'run post-start.d/10-alpha.sh'"
  check "…and the log kept it as the phase's index" \
    "printf '%s' \"\$LOGGED\" | grep -q 'run post-start.d/10-alpha.sh'"
  check "a warning always reaches the terminal" \
    "printf '%s' \"\$OUT\" | grep -q 'something is off'"
  check "…carrying its repair line with it" \
    "printf '%s' \"\$OUT\" | grep -q 'fix it like this'"
  check "the log carries no ANSI, so grep anchors work on it" \
    "! printf '%s' \"\$LOGGED\" | grep -q \$'\033'"

  # The regression test for a bug this dispatcher shipped with: the sink was a
  # process substitution nobody waited on, so the tail could be lost — and the
  # footer is both the last line and an asserted one. release-check.sh:1187
  # would not have caught it: it only globs that the file exists.
  check "the phase footer is the log's LAST line" \
    "[ \"\$(plog | tail -1)\" = '=== post-start done ===' ]"
  rm -f "$FO/70-warn.sh"

  # 500 lines then a required failure: the bytes most worth having are the ones
  # written last, under the most pressure to be dropped.
  frag "$FO/80-boom.sh" true boom-ovl 'for i in $(seq 1 500); do echo "  detail $i"; done; exit 3'
  OUT="$(routed post-start)" || true
  check "a required failure reaches the terminal" \
    "printf '%s' \"\$OUT\" | grep -q 'FAIL post-start.d/80-boom.sh'"
  check "…with the command that reads its detail" \
    "printf '%s' \"\$OUT\" | grep -q 'what it printed'"
  check "500 lines of detail survived into the log" \
    "[ \"\$(plog | grep -c 'detail ')\" -ge 500 ]"
  check "and the failure is the log's last fact, not a truncation" \
    "plog | grep -q '^✗ FAIL post-start.d/80-boom.sh'"
  check "grep -c '^✗' answers on the file" \
    "[ \"\$(plog | grep -c '^✗')\" -ge 1 ]"
  rm -f "$FO/80-boom.sh"
fi

# =============================================================================
echo
printf 'overlay: %d pass / %d fail' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ' / %d skipped' "$SKIP"
printf '\n'
if [ "$HAS_GNU" -eq 0 ]; then
  echo "-> layer 1 did not run. Replay this script INSIDE the devcontainer:"
  echo "   bash packages/devcontainer-sandbox/test/overlay.test.sh"
fi
if [ "$HAS_DOCKER" -eq 0 ] && [ "$UNIT_ONLY" -eq 0 ]; then
  echo "-> layer 2 did not run. Replay this script on the HOST, Docker running:"
  echo "   bash packages/devcontainer-sandbox/test/overlay.test.sh"
fi
[ "$FAIL" -eq 0 ]
