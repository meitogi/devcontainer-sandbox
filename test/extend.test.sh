#!/usr/bin/env bash
# Extension contract, level 2 — what a Dockerfile that FROMs this image may
# add on top, and how it stacks with the project's own /workspace.
#
#   bash test/extend.test.sh
#   IMG=ghcr.io/…/devcontainer-base:TAG bash test/extend.test.sh
#
# The three levels are:
#
#   1. the naked image                          covered by run-image-suites.sh
#   2. a Dockerfile that FROMs it               THIS FILE
#   3. the project's /workspace                 covered by overlay.test.sh
#
# Level 2 has always been "it should work" — the paths existed, nobody had ever
# built an image on top and checked. This builds one, with a hook, a skill and
# a firewall layer at once, then asks what actually resolved.
#
# Needs Docker: it builds. There is no unit half — the whole point is that a
# real image layer, not a directory, is what an extender produces.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IMG="${IMG:-devcontainer-base:local}"
EXT_IMG="devcontainer-base-ext:test"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  – %s (skipped: %s)\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; printf '      attendu : %s\n      obtenu  : %s\n' "$3" "$2" >&2; fi }

# --- Context -----------------------------------------------------------------

HAS_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  HAS_DOCKER=1
fi

echo "═══ context ═══"
echo "  base image : $IMG"
echo "  test image : $EXT_IMG (built here, removed on exit)"

if [ "$HAS_DOCKER" -eq 0 ]; then
  for t in "the ext layer is enumerated" "an ext fragment lands at its numeric place" \
           "an ext fragment replaces a shipped one" "an ext skill installs and retargets" \
           "base < ext < workspace" "a project disables an ext fragment" \
           "an ext firewall layer is compiled in" "a @required fragment resists disabling" \
           "an ext image adds its own VS Code extension patch" \
           "a patch selection replayed at runtime"; do
    skip "$t" "needs Docker — run it on the host"
  done
  echo
  echo "extend: $PASS pass / $FAIL fail / $SKIP skipped"
  echo "-> nothing ran. Replay this on the host, with Docker up:"
  echo "     wtf image test"
  exit 0
fi

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  skip "the whole suite" "image $IMG missing — build it, or pass IMG=…"
  echo
  echo "extend: $PASS pass / $FAIL fail / $SKIP skipped"
  exit 0
fi

TMPROOT="$(mktemp -d)"
trap 'docker image rm -f "$EXT_IMG" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

# =============================================================================
echo
echo "═══ 1. build an extending image ═══"
# =============================================================================
# One image, all four seams at once — that is the shape a third party writes,
# and building them separately would not catch them interfering.

CTX="$TMPROOT/ctx"
mkdir -p "$CTX"

# The shipped fragment this image will deliberately shadow. Read from the image
# rather than hardcoded, so a rename in assets/ does not silently no-op this.
VICTIM=$(docker run --rm "$IMG" devc-hook post-start --dry-run \
         | grep 'WOULD RUN' | head -1 | sed 's/.*post-start\.d\///;s/ .*//')
if [ -z "$VICTIM" ]; then
  ko "could not read a shipped fragment name from $IMG"
  echo "extend: $PASS pass / $FAIL fail / $SKIP skipped"
  exit 1
fi

printf '#!/usr/bin/env bash\necho "MARK:ext-added"\n'          > "$CTX/50-ext-added.sh"
printf '#!/usr/bin/env bash\necho "MARK:ext-shadow"\n'         > "$CTX/ext-shadow.sh"
mkdir -p "$CTX/extskill"
printf 'EXT SKILL BODY\n'                                      > "$CTX/extskill/extskill.skill.md"
printf 'console.log("ext")\n'                                  > "$CTX/extskill/hook.js"
cat > "$CTX/extskill/hooks.json" <<'JSON'
{"SessionStart":[{"hooks":[{"type":"command","command":"node /opt/devcontainer/ext/skills/extskill/hook.js"}]}]}
JSON
printf '# an extending image widens the allowlist\nextend-probe.example\n' > "$CTX/50-ext-domains.txt"

# The fifth seam: an extending image's own VS Code extension patcher. Written
# the way AUTHORING.md documents it — installed into the patch directory with a
# valid header, so it is selectable and replayed like the shipped ones, rather
# than run once from /tmp and forgotten.
cat > "$CTX/ext-probe-patch.py" <<'PYPATCH'
#!/usr/bin/env python3
# @patch-category: ux
# @patch-files: extension.js
# @patch-sentinel: /*__EXTEND_TEST_PROBE_v1__*/
# @patch-summary: Test probe: proves an extending image can add a first-class
#   patcher through the documented seam.
"""Minimal patcher: prepends an inert sentinel comment to extension.js."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import GREEN, RESET, resolve_ext_dir, check_files

MARKER = "/*__EXTEND_TEST_PROBE_v1__*/"


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    path = ext_dir / "extension.js"
    content = path.read_text()
    if MARKER in content:
        print(f"{GREEN}[ext-probe]{RESET} already patched")
        return 0
    path.write_text(MARKER + content)
    print(f"{GREEN}[ext-probe]{RESET} applied")
    return 0


sys.exit(main())
PYPATCH

cat > "$CTX/Dockerfile" <<DOCKERFILE
FROM $IMG
USER root
# hooks + skills go to the ext layer, never into base/
COPY 50-ext-added.sh /opt/devcontainer/ext/hooks/post-start.d/50-ext-added.sh
COPY ext-shadow.sh   /opt/devcontainer/ext/hooks/post-start.d/$VICTIM
COPY extskill/       /opt/devcontainer/ext/skills/extskill/
# firewall widens through domains.d/, the same seam the base layer uses
COPY 50-ext-domains.txt /etc/devcontainer-firewall/domains.d/50-ext.txt
# a VS Code extension patch, through /etc/claude-build-env
COPY ext-probe-patch.py /usr/local/bin/vscode-ext-patchs/
RUN . /etc/claude-build-env \\
 && PYTHONDONTWRITEBYTECODE=1 python3 /usr/local/bin/vscode-ext-patchs/ext-probe-patch.py "\$EXT_DIR" \\
 && chown node:node "\$EXT_DIR/extension.js"
USER node
DOCKERFILE

if docker build -q -t "$EXT_IMG" "$CTX" >/dev/null 2>&1; then
  ok "an image FROM $IMG builds with a hook, a skill, a firewall layer and a patch"
else
  ko "the extending image failed to build"
  docker build -t "$EXT_IMG" "$CTX" 2>&1 | tail -20 >&2
  echo "extend: $PASS pass / $FAIL fail / $SKIP skipped"
  exit 1
fi

DR() { docker run --rm "$@"; }
DRY="devc-hook post-start --dry-run"

# =============================================================================
echo
echo "═══ 2. hooks — the ext layer resolves (D1.1, D1.2) ═══"
# =============================================================================

BASE_N=$(DR "$IMG" $DRY | grep -c 'WOULD RUN')
EXT_N=$(DR "$EXT_IMG" $DRY | grep -c 'WOULD RUN')
checkeq "a COPY'd fragment is enumerated: +1" "$EXT_N" "$((BASE_N + 1))"

check "and it is attributed to the ext layer" \
  "DR $EXT_IMG $DRY | grep -q 'post-start.d/50-ext-added.sh (ext,'"

# Numeric place, not appended at the end. Stated as "the emitted order is its
# own sorted order": that is the whole contract, and it stays true when the
# image gains or loses fragments.
ORDER=$(DR "$EXT_IMG" $DRY | grep 'WOULD RUN' | sed 's/.*post-start\.d\///;s/ .*//')
checkeq "the ext fragment lands at its numeric place, not at the end" \
  "$(printf '%s\n' "$ORDER" | tr '\n' ' ')" \
  "$(printf '%s\n' "$ORDER" | sort | tr '\n' ' ')"
check "and it really is in that list" \
  "printf '%s\n' \"\$ORDER\" | grep -qx '50-ext-added.sh'"

# Same name as a shipped fragment: one winner, and it is the ext one.
checkeq "shadowing a shipped fragment does not duplicate it" \
  "$(DR "$EXT_IMG" $DRY | grep -c "post-start.d/$VICTIM (")" "1"
check "and the winner is the ext copy" \
  "DR $EXT_IMG $DRY | grep -q 'post-start.d/$VICTIM (ext,'"

# =============================================================================
echo
echo "═══ 3. skills — installed and retargeted (D1.3) ═══"
# =============================================================================

SKILLS_OUT=$(DR -u node "$EXT_IMG" bash -c 'sync-skills 2>&1')
check "an ext skill becomes a command" \
  "DR -u node $EXT_IMG bash -c 'sync-skills >/dev/null 2>&1; test -f /home/node/.claude/commands/extskill.md'"
check "sync-skills reports no traceback" \
  "! printf '%s' \"\$SKILLS_OUT\" | grep -q 'Traceback'"

# The shipped hooks.json spells an absolute path; installed from an image the
# project does not have, an unretargeted command is MODULE_NOT_FOUND at every
# SessionStart. Here the path happens to be right — assert it stayed right.
CMD=$(DR -u node "$EXT_IMG" bash -c '
  sync-skills >/dev/null 2>&1
  python3 -c "
import json
for e in json.load(open(\"/home/node/.claude/settings.json\")).get(\"hooks\",{}).get(\"SessionStart\",[]):
    c = e[\"hooks\"][0].get(\"command\",\"\")
    if \"extskill\" in c: print(c)
"')
checkeq "and its hooks.json is retargeted to the ext dir" \
  "$CMD" "node /opt/devcontainer/ext/skills/extskill/hook.js"

# =============================================================================
echo
echo "═══ 4. the three levels stacked (D1.4) ═══"
# =============================================================================
# base < ext < workspace, on ONE basename. This is the ordering the extending
# image cannot decide for itself — it is the resolver's, written down here.

WS="$TMPROOT/ws"
mkdir -p "$WS/.devcontainer/hooks/post-start.d"
M=(-v "$WS:/workspace")

check "with no project, ext wins over base" \
  "DR $EXT_IMG $DRY | grep -q 'post-start.d/$VICTIM (ext,'"

printf '#!/usr/bin/env bash\necho "MARK:ws"\n' > "$WS/.devcontainer/hooks/post-start.d/$VICTIM"
check "the project wins over ext" \
  "DR ${M[*]} $EXT_IMG $DRY | grep -q 'post-start.d/$VICTIM (ovl,'"
checkeq "still exactly one winner" \
  "$(DR "${M[@]}" "$EXT_IMG" $DRY | grep -c "post-start.d/$VICTIM (")" "1"

# =============================================================================
echo
echo "═══ 5. a project switches off an ext fragment (D1.5) ═══"
# =============================================================================

rm -f "$WS/.devcontainer/hooks/post-start.d/$VICTIM"
cat > "$WS/.devcontainer/devcontainer.json" <<'JSON'
{ "customizations": { "stitchu-devc": { "disabledHooks": ["post-start.d/50-ext-added.sh"] } } }
JSON
check "disabledHooks reaches a fragment that came from the image, not the project" \
  "DR ${M[*]} $EXT_IMG $DRY | grep -q 'skip post-start.d/50-ext-added.sh'"
rm -f "$WS/.devcontainer/devcontainer.json"

# =============================================================================
echo
echo "═══ 5b. the ext layer switches things off (its own disabled.txt) ═══"
# =============================================================================
# An extending image cannot write the project's devcontainer.json, so before
# this its only way to remove a base fragment was to shadow the file — the one
# route that walks around the @required guard. Built as a thin layer of its
# own so the counts asserted above stay untouched.

# Pick real targets out of the image rather than hardcoding names that move.
FRAG=$(DR "$EXT_IMG" $DRY | grep 'required=false' | grep '(base,' \
       | head -1 | sed 's/.*post-start\.d\///;s/ .*//')
SKILL=$(DR "$EXT_IMG" bash -c 'ls /opt/devcontainer/base/skills' | head -1)

if [ -z "$FRAG" ] || [ -z "$SKILL" ]; then
  skip "the ext layer disables a base fragment" "no optional base fragment or skill found"
else
  CTX2=$(mktemp -d); EXT2_IMG="devcontainer-extend-off-test:local"
  printf '# the base probe is noise for our users\n%s\n' "post-start.d/$FRAG" > "$CTX2/hooks-disabled.txt"
  printf '%s  # we ship our own\n' "$SKILL" > "$CTX2/skills-disabled.txt"
  cat > "$CTX2/Dockerfile" <<DOCKERFILE
FROM $EXT_IMG
USER root
COPY hooks-disabled.txt  /opt/devcontainer/ext/hooks/disabled.txt
COPY skills-disabled.txt /opt/devcontainer/ext/skills/disabled.txt
USER node
DOCKERFILE
  if docker build -q -t "$EXT2_IMG" "$CTX2" >/dev/null 2>&1; then
    ok "an image FROM the extending one builds with the two disabled.txt"
    OUT=$(DR "$EXT2_IMG" $DRY 2>&1)
    check "ext/hooks/disabled.txt switches off a base fragment" \
      "printf '%s' \"\$OUT\" | grep -q 'skip post-start.d/$FRAG'"
    check "and the ext layer's own fragment still runs" \
      "printf '%s' \"\$OUT\" | grep -q 'WOULD RUN post-start.d/50-ext-added.sh'"

    CMDS=$(DR "$EXT2_IMG" bash -c 'sync-skills >/dev/null 2>&1; ls /home/node/.claude/commands 2>/dev/null')
    check "ext/skills/disabled.txt keeps a baked skill out of the commands" \
      "! printf '%s' \"\$CMDS\" | grep -qx '$SKILL.md'"
    check "and the other skills still install" \
      "[ \"\$(printf '%s' \"\$CMDS\" | grep -c .)\" -gt 0 ]"
  else
    ko "the second extending image failed to build"
    docker build -t "$EXT2_IMG" "$CTX2" 2>&1 | tail -20 >&2
  fi
  docker rmi -f "$EXT2_IMG" >/dev/null 2>&1 || true
  rm -rf "$CTX2"
fi

# =============================================================================
echo
echo "═══ 6. @required resists a project (C3) ═══"
# =============================================================================
# The firewall bring-up is @required. Switching it off used to boot the
# container wide open without a word.

REQ=$(DR "$EXT_IMG" devc-hook on-create --dry-run \
      | grep 'required=true' | head -1 | sed 's/.*on-create\.d\///;s/ .*//')
if [ -z "$REQ" ]; then
  skip "a @required fragment resists disabling" "no @required fragment in on-create"
else
  printf '{"customizations":{"stitchu-devc":{"disabledHooks":["on-create.d/%s"]}}}\n' "$REQ" \
    > "$WS/.devcontainer/devcontainer.json"
  OUT=$(DR "${M[@]}" "$EXT_IMG" devc-hook on-create --dry-run 2>&1)
  check "disabling $REQ is refused" \
    "printf '%s' \"\$OUT\" | grep -q 'REFUSED to disable on-create.d/$REQ'"
  check "and it is still scheduled to run" \
    "printf '%s' \"\$OUT\" | grep -q 'WOULD RUN on-create.d/$REQ'"

  printf '{"customizations":{"stitchu-devc":{"disabledHooks":["!on-create.d/%s"]}}}\n' "$REQ" \
    > "$WS/.devcontainer/devcontainer.json"
  OUT=$(DR "${M[@]}" "$EXT_IMG" devc-hook on-create --dry-run 2>&1)
  check "the explicit ! opt-in does switch it off" \
    "printf '%s' \"\$OUT\" | grep -q 'skip on-create.d/$REQ'"
fi
rm -f "$WS/.devcontainer/devcontainer.json"

# =============================================================================
echo
echo "═══ 7. firewall — the layer-2 allowlist (D1.6) ═══"
# =============================================================================
# domains.d/ is additive by design: the base ships 00-base.txt, an extender
# drops its own NN-*.txt beside it. Nothing merges, nothing overwrites.

BASE_H=$(DR "$IMG" python3 /usr/local/bin/compile-policy.py \
         --list-hosts /etc/devcontainer-firewall/domains.d/00-base.txt 2>/dev/null | wc -l | tr -d ' ')
EXT_H=$(DR "$EXT_IMG" sh -c 'python3 /usr/local/bin/compile-policy.py --list-hosts /etc/devcontainer-firewall/domains.d/*.txt' 2>/dev/null | wc -l | tr -d ' ')
checkeq "an ext domains.d file widens the allowlist: +1 host" "$EXT_H" "$((BASE_H + 1))"
check "and the added host is the one we declared" \
  "DR $EXT_IMG sh -c 'python3 /usr/local/bin/compile-policy.py --list-hosts /etc/devcontainer-firewall/domains.d/*.txt' | grep -q extend-probe.example"

check "the base layer is still there, not replaced" \
  "DR $EXT_IMG test -f /etc/devcontainer-firewall/domains.d/00-base.txt"

# =============================================================================
echo
echo "═══ 8. the base layer is untouched ═══"
# =============================================================================
# The whole reason ext/ is a directory of its own: an extender adds, it never
# overwrites what the image shipped.

checkeq "the shadowed fragment still exists in the base layer" \
  "$(DR "$EXT_IMG" sh -c "test -f /opt/devcontainer/base/hooks/post-start.d/$VICTIM && echo yes")" "yes"
check "and the base copy is not the ext body" \
  "! DR $EXT_IMG grep -q 'MARK:ext-shadow' /opt/devcontainer/base/hooks/post-start.d/$VICTIM"
checkeq "the naked image still resolves the base copy" \
  "$(DR "$IMG" $DRY | grep -c "post-start.d/$VICTIM (base,")" "1"

# =============================================================================
echo
echo "═══ 9. VS Code patches — an ext one, and selection at runtime ═══"
# =============================================================================
# The seam an extending image uses for the extension bundle, and the promise
# that a selection is still a real choice once the image is built and published.

EXT_SENT='/*__EXTEND_TEST_PROBE_v1__*/'
UX_SENT='/*mbf-open*/'                    # model-badge-footer, webview/index.js
NOTIFY_SENT='notify-queue-user-action-v3' # user-action-observer, extension.js

# Greps the LIVE bundle after replaying a selection, in one container. Each
# `docker run` starts from the image, so the runs cannot contaminate each other.
live_after() {  # live_after <selection> <sentinel> <file>
  docker run --rm "$EXT_IMG" bash -c \
    "restore-ext-patches $1 >/dev/null 2>&1; . /etc/claude-build-env; grep -qF '$2' \"\$EXT_DIR/$3\""
}

check "an ext image's own patcher reaches the bundle" \
  "DR $EXT_IMG bash -c '. /etc/claude-build-env; grep -qF \"$EXT_SENT\" \"\$EXT_DIR/extension.js\"'"
check "and --list reports it as live, next to the shipped ones" \
  "DR $EXT_IMG restore-ext-patches --list | grep -q 'ext-probe-patch'"

# The point of the pristine copies: a selection replayed at runtime really
# removes what it excludes, on an image someone pulled rather than built.
check "restoring with ux keeps a ux sentinel" \
  "live_after ux '$UX_SENT' webview/index.js"
check "and drops the notify one" \
  "! live_after ux '$NOTIFY_SENT' extension.js"
check "restoring with none leaves no sentinel at all" \
  "! live_after none '$UX_SENT' webview/index.js"
# An ext patcher installed in the patch directory is replayed with the rest —
# that is what "first-class" buys over running it once from /tmp.
check "and restoring with all brings the ext patch back too" \
  "live_after all '$EXT_SENT' extension.js"

echo
echo "extend: $PASS pass / $FAIL fail / $SKIP skipped"
[ "$FAIL" -eq 0 ]
