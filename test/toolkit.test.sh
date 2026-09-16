#!/usr/bin/env bash
# toolkit.test.sh — the patch toolkit's contract, with no patcher in the repo.
#
# This image ships run-all.sh, _common.py and AUTHORING.md, and deliberately no
# patcher: the VS Code extension is installed exactly as published. What still
# has to hold is the CONTRACT the toolkit offers to anyone who brings their own
# — an extending image dropping a .py next to the orchestrator (EXTENDING.md),
# or the 45-ext-patches.sh hook assembling a directory somewhere else entirely.
#
# So everything here is driven by probe patchers written into a throwaway
# directory, against a throwaway extension. Three questions:
#
#   1. Does PATCH_DIR really decouple the patchers from the toolkit — including
#      `from _common import ...`, which used to work only because the patchers
#      happened to sit next to _common.py?
#   2. Does a selection still select? all / none / category / name / the
#      additive combination / an unknown token.
#   3. Are the refusals still refusals? A patcher without a category stops the
#      run; an unknown token stops it before anything is applied.
#
# The registry half — headers agreeing with PATCHES.md, sentinels really in the
# code — moved out with the patchers, to the repository that holds them.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TOOLKIT="$REPO/assets/vscode-ext-patchs"
RUNNER="$TOOLKIT/run-all.sh"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
skip() { SKIP=$((SKIP+1)); printf '  – %s (skipped: %s)\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi }
checkeq(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1"; printf '      expected : %s\n      got      : %s\n' "$3" "$2" >&2; fi }

# run-all.sh uses arrays under `set -u`; bash 3.2 treats an empty array as
# unset and would abort before the first patcher. Same gate as the other
# suites: replay this one inside the container.
HAS_BASH4=1
[ "${BASH_VERSINFO[0]}" -ge 4 ] || HAS_BASH4=0

# ext-patches-sync reads EXT_PATCHES_* from the ENVIRONMENT first (compose
# injects .env at create), so a container whose own .devcontainer/.env
# configures patchers leaks its pin, repo and token into every fixture here and
# five assertions answer about that container instead of about the fixture.
# Measured 2026-09-16 : 69/0 on a host, 5 failures inside the dogfood, same
# code. Same precaution, same reason as run-firewall-suites.sh:26-29 — the
# tests that exercise these variables set them explicitly.
unset EXT_PATCHES_DIR EXT_PATCHES_REPO EXT_PATCHES_REF EXT_PATCHES_TOKEN \
      EXT_PATCHES_SELECT EXT_PATCHES_FORCE EXT_PATCHES_ALLOW_UNTESTED

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo "== the shipped toolkit is the toolkit, and nothing else =="
checkeq "assets/vscode-ext-patchs holds exactly the three toolkit files" \
  "$(ls "$TOOLKIT" | sort | tr '\n' ' ' | sed 's/ $//')" \
  "AUTHORING.md _common.py run-all.sh"
check "no patcher ships in this repository" \
  "[ -z \"\$(find \"\$TOOLKIT\" -name '*.py' ! -name '_common.py' -print -quit)\" ]"
# AUTHORING.md describes the header contract a patcher must honour. It must not
# describe how to find an anchor in a minified bundle — that is the technique,
# and it travels with the patchers.
check "AUTHORING.md still documents the header contract" \
  "grep -q '@patch-category' \"\$TOOLKIT/AUTHORING.md\" && grep -q 'PATCH_DIR' \"\$TOOLKIT/AUTHORING.md\""

# --------------------------------------------------------------------------
# A throwaway extension. The probes below rewrite it; what is asserted is which
# probe ran, not what the bundle ended up looking like.
# --------------------------------------------------------------------------
EXT="$TMPROOT/ext"
mkdir -p "$EXT/webview"
printf '{}\n'      > "$EXT/package.json"
printf '// stub\n' > "$EXT/extension.js"
printf '// stub\n' > "$EXT/webview/index.js"

# The probe: the shape AUTHORING.md documents and extend.test.sh installs — a
# header, a sentinel, an idempotent guard, and `from _common import ...` so the
# import path is exercised rather than assumed.
mk_probe() {
  local dir="$1" name="$2" cat="$3"
  mkdir -p "$dir"
  cat > "$dir/$name.py" <<PY
#!/usr/bin/env python3
# @patch-category: $cat
# @patch-files: extension.js
# @patch-sentinel: /*__PROBE_${name}__*/
# @patch-summary: Test probe: prepends an inert marker comment so the toolkit
#   contract can be exercised without shipping a real patcher.
"""Minimal patcher: prepends an inert sentinel comment to extension.js."""
import sys

from _common import GREEN, RESET, resolve_ext_dir, check_files

MARKER = "/*__PROBE_${name}__*/"


def main():
    ext_dir = resolve_ext_dir(sys.argv)
    check_files(ext_dir, ["extension.js"])
    path = ext_dir / "extension.js"
    content = path.read_text()
    if MARKER in content:
        print(f"{GREEN}[$name]{RESET} already patched")
        return 0
    path.write_text(MARKER + content)
    print(f"{GREEN}[$name]{RESET} applied")
    return 0


sys.exit(main())
PY
}

PROBES="$TMPROOT/patchers"
mk_probe "$PROBES" probe-ux-one   ux
mk_probe "$PROBES" probe-ux-two   ux
mk_probe "$PROBES" probe-fix-one  fix
mk_probe "$PROBES" probe-notify   notify

# Deliberately NOT copied next to _common.py: the point is that PATCH_DIR works
# when the two are apart, which is exactly how the hook and an image without
# patchers use it.
run_sel() {
  CLAUDE_CODE_EXT_PATCHS="$1" PATCH_DIR="$PROBES" PYTHONDONTWRITEBYTECODE=1 \
    bash "$RUNNER" "$EXT" 2>"$TMPROOT/err"
}
invoked() { run_sel "$1" | grep -cE '→ [A-Za-z0-9._-]+\.py'; }

if [ "$HAS_BASH4" -eq 0 ]; then
  for t in "PATCH_DIR runs patchers that live outside the toolkit" \
           "a patcher imports _common through PYTHONPATH" \
           "all runs every patcher" "none runs none of them" \
           "a category runs exactly its members" "a bare name runs exactly one" \
           "a name after a category adds to it" \
           "a name already covered by a category does not run twice" \
           "whitespace around a token is tolerated" \
           "an unknown token exits 2" "an unknown token applies nothing" \
           "an unknown token names itself in the error" \
           "a patcher without a category stops the run" \
           "an empty patch directory is not an error" \
           "an empty patch directory says so" \
           "the toolkit directory is still the default"; do
    skip "$t" "bash 3.2: run-all.sh needs bash 4 arrays"
  done
else

echo "== PATCH_DIR decouples the patchers from the toolkit =="
checkeq "PATCH_DIR runs patchers that live outside the toolkit" "$(invoked all)" "4"
# The import is the fragile half: sys.path[0] is the PATCHER's directory, which
# no longer holds _common.py. Only PYTHONPATH makes this work.
check "a patcher imports _common through PYTHONPATH" \
  "! grep -q 'ModuleNotFoundError' \"\$TMPROOT/err\""
check "the probe really reached the bundle" \
  "grep -q '__PROBE_probe-ux-one__' \"\$EXT/extension.js\""

echo "== a selection selects =="
checkeq "all runs every patcher" "$(invoked all)" "4"
checkeq "none runs none of them" "$(invoked none)" "0"
checkeq "a category runs exactly its members" "$(invoked ux)" "2"
checkeq "a bare name runs exactly one" "$(invoked probe-fix-one)" "1"
checkeq "a name after a category adds to it" "$(invoked ux,probe-notify)" "3"
checkeq "a name already covered by a category does not run twice" \
  "$(invoked ux,probe-ux-one)" "2"
checkeq "whitespace around a token is tolerated" "$(invoked ' ux , probe-notify ')" "3"

echo "== the refusals are still refusals =="
run_sel nope >/dev/null 2>&1; checkeq "an unknown token exits 2" "$?" "2"
checkeq "an unknown token applies nothing" "$(invoked nope)" "0"
check "an unknown token names itself in the error" "grep -q 'nope' \"\$TMPROOT/err\""

NOHDR="$TMPROOT/nohdr"
mk_probe "$NOHDR" probe-ok ux
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n' > "$NOHDR/zz-headerless.py"
CLAUDE_CODE_EXT_PATCHS=all PATCH_DIR="$NOHDR" PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >/dev/null 2>&1
checkeq "a patcher without a category stops the run" "$?" "2"

echo "== an image with no patcher is a normal image =="
EMPTY="$TMPROOT/empty"; mkdir -p "$EMPTY"
CLAUDE_CODE_EXT_PATCHS=all PATCH_DIR="$EMPTY" PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >"$TMPROOT/out" 2>"$TMPROOT/err"
checkeq "an empty patch directory is not an error" "$?" "0"
check "an empty patch directory says so" "grep -q 'no patchers found' \"\$TMPROOT/err\""
# Without PATCH_DIR the orchestrator falls back to its own directory, which in
# this repository holds no patcher — so the shipped default is the empty case.
CLAUDE_CODE_EXT_PATCHS=all PYTHONDONTWRITEBYTECODE=1 \
  bash "$RUNNER" "$EXT" >/dev/null 2>&1
checkeq "the toolkit directory is still the default" "$?" "0"

fi

# ==========================================================================
# The hook's brain, and the command that moves it between versions.
#
# Until now every suite could say `ext-patches-sync` EXISTS and none could say
# what it DOES — which is how `--status`, documented from the first version,
# shipped without ever being parsed: the flag whose whole promise is "change
# nothing" fell through to the apply path. Everything below drives the real
# scripts against a throwaway .env, a throwaway extension and a stubbed curl.
# ==========================================================================
SYNC_BIN="$REPO/bin/ext-patches-sync"
UPD_BIN="$REPO/bin/ext-patches-update"

UPD_NAMES=(
  "--status changes nothing"
  "--status reports the pinned ref"
  "--status never prints the token"
  "--status answers on an unconfigured checkout"
  "an unknown option is refused, not ignored"
  "a second run short-circuits on the sentinels"
  "--force replays the selection anyway"
  "--dir applies from a local checkout, with no token"
  "--check --dir changes nothing"
  "--check reports installed against available"
  "--check changes nothing"
  "--check leaves the pin alone"
  "latest prefers a published release"
  "latest falls back to the tag list"
  "tags are ordered numerically, not lexicographically"
  "a version with a tag line resolves to that line"
  "the -r number is compared as an integer"
  "a release does not override this container's line"
  "a repository without the convention keeps the newest-overall behaviour"
  "the newest-overall fallback says so"
  "no tag list falls back to the release, and says which"
  "an unreadable extension version falls back to newest-overall"
  "the unreadable version is named as the reason"
  "a version with no tag line refuses"
  "the refusal names the tested lines"
  "the refusal names the way out"
  "ALLOW_UNTESTED pins the commit, never the word HEAD"
  "ALLOW_UNTESTED still says the set is untested"
  "the HEAD cache is renamed to the commit it resolved to"
  "an explicit --ref outranks the refusal"
  "an explicit --ref asks no question at all"
  "the fetch records which commit the ref resolved to"
  "a ref never tested on this extension says so"
  "the note lists what the ref WAS tested on"
  "the untested note survives the restart short-circuit"
  "--status reports the tested versions"
  "a ref tested on this extension says nothing"
  "a successful update rewrites the pin"
  "the rewrite keeps the comments around it"
  "--no-write-env leaves the pin alone"
  "a download that fails leaves the pin alone"
  "--reapply refuses when nothing is cached"
  "a local patcher of the same name overrides the resolved one"
  "the override is announced by name"
  "editing a local patcher re-triggers the apply"
  "an untouched local directory still short-circuits"
  "local patchers alone are a configured project"
  "an unreachable repository with a cache warns and keeps the pin"
  "an unreachable repository with nothing cached is an error"
)

if [ "$HAS_BASH4" -eq 0 ]; then
  for t in "${UPD_NAMES[@]}"; do
    skip "$t" "bash 3.2: ext-patches-sync needs bash 4 arrays"
  done
else

# A throwaway devcontainer: its own .env, its own cache, its own extension.
#
# The second argument is the extension version, and it has NO DEFAULT on
# purpose. Every call that predates tag resolution leaves it out and keeps a
# package.json with no "version" field, which is what exercises the branch
# where the version is unreadable — the one that must keep resolving the newest
# tag overall rather than start refusing.
mk_conf() {
  CONF="$TMPROOT/conf$1"; rm -rf "$CONF"; mkdir -p "$CONF"
  UEXT="$TMPROOT/uext$1"; rm -rf "$UEXT"; mkdir -p "$UEXT/webview"
  if [ -n "${2:-}" ]; then
    printf '{"version":"%s"}\n' "$2" > "$UEXT/package.json"
  else
    printf '{}\n' > "$UEXT/package.json"
  fi
  printf '// stub\n' > "$UEXT/extension.js"
  printf '// stub\n' > "$UEXT/webview/index.js"
  BENV="$TMPROOT/buildenv$1"; printf 'EXT_DIR=%s\n' "$UEXT" > "$BENV"
  UENV="$CONF/.env"
  { echo '# a curated file, with comments that must survive'
    echo 'EXT_PATCHES_REPO=acme/patchers'
    echo 'EXT_PATCHES_REF=v1'
    echo 'EXT_PATCHES_TOKEN=tok-secret-value'
    echo '# trailing comment'; } > "$UENV"
}

# Stands in for restore-ext-patches: records the selection it was handed, then
# really runs the orchestrator so the sentinels actually land in the bundle.
RESTORE_STUB="$TMPROOT/restore-stub"
cat > "$RESTORE_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TMPROOT/restore.log"
# The real one resolves the extension itself; sync sets EXT_DIR without
# exporting it, so read it back the same way sync did.
. "\$BUILD_ENV"
CLAUDE_CODE_EXT_PATCHS="\$1" PATCH_DIR="\$PATCH_DIR" PYTHONDONTWRITEBYTECODE=1 \\
  bash "$RUNNER" "\$EXT_DIR" >/dev/null 2>&1
STUB
chmod +x "$RESTORE_STUB"

# Stands in for curl. Serves whatever fixture the test dropped in \$FAKE_DIR and
# fails like `curl -f` for anything else, so an unfixtured call is a red test
# rather than a silent reach for the real network.
STUBBIN="$TMPROOT/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""; out=""; hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; out="$1" ;;
    -D) shift; hdr="$1" ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$FAKE_LOG"
case "$url" in
  */releases/latest) [ -f "$FAKE_DIR/release.json" ] && { cat "$FAKE_DIR/release.json"; exit 0; } ;;
  */tags*)           [ -f "$FAKE_DIR/tags.json" ]    && { cat "$FAKE_DIR/tags.json"; exit 0; } ;;
  */tarball/*)       if [ -f "$FAKE_DIR/src.tar.gz" ]; then cp "$FAKE_DIR/src.tar.gz" "$out"; exit 0; fi ;;
esac
[ -n "$hdr" ] && printf 'HTTP/2 404\n' > "$hdr"
exit 22
STUB
chmod +x "$STUBBIN/curl"

FAKE_DIR="$TMPROOT/fake"; mkdir -p "$FAKE_DIR"
FAKE_LOG="$TMPROOT/curl.log"; : > "$FAKE_LOG"
export FAKE_DIR FAKE_LOG

# A tarball shaped like GitHub's: one <owner>-<repo>-<sha>/ wrapper directory.
TARSRC="$TMPROOT/tarsrc/acme-patchers-deadbee"
mkdir -p "$TARSRC"
mk_probe "$TARSRC/patchers" probe-tar ux
# A patcher repository ships the versions it was validated against next to its
# patchers; the fetch copies it into the cache so the boot path can read it.
printf '{"versions":["2.1.220","2.1.258"]}\n' > "$TARSRC/versions.json"
( cd "$TMPROOT/tarsrc" && tar -czf "$FAKE_DIR/src.tar.gz" acme-patchers-deadbee )

sync_run() {  # sync_run <conf-suffix> [args...]
  DEVC_CONFIG_DIR="$CONF" BUILD_ENV="$BENV" RESTORE_EXT_PATCHES="$RESTORE_STUB" \
  TOOLKIT_DIR="$TOOLKIT" PATH="$STUBBIN:$PATH" \
    bash "$SYNC_BIN" "$@" 2>&1
}
upd_run() {
  DEVC_CONFIG_DIR="$CONF" BUILD_ENV="$BENV" RESTORE_EXT_PATCHES="$RESTORE_STUB" \
  TOOLKIT_DIR="$TOOLKIT" EXT_PATCHES_SYNC="$SYNC_BIN" PATH="$STUBBIN:$PATH" \
    bash "$UPD_BIN" "$@" 2>&1
}
pin_of() { sed -n 's/^EXT_PATCHES_REF=//p' "$UENV" | tail -1; }

echo "== --status says what holds, and changes nothing =="
mk_conf a
BEFORE=$(cksum < "$UEXT/extension.js")
OUT=$(sync_run --status)
checkeq "--status changes nothing" "$(cksum < "$UEXT/extension.js")" "$BEFORE"
check "--status reports the pinned ref" "printf '%s' \"\$OUT\" | grep -q 'EXT_PATCHES_REF *v1'"
# The output lands in phase logs, which release-check collects into a bundle.
check "--status never prints the token" "! printf '%s' \"\$OUT\" | grep -q 'tok-secret-value'"
mk_conf b; : > "$UENV"
OUT=$(sync_run --status)
check "--status answers on an unconfigured checkout" \
  "printf '%s' \"\$OUT\" | grep -q 'nothing configured'"
sync_run --nonsense >/dev/null 2>&1
checkeq "an unknown option is refused, not ignored" "$?" "64"

echo "== the ref names its target version, and a mismatch is said out loud =="
# Measured 2026-09-16 : a pin left behind by a CC bump (cc2.1.258-r2) was
# applied to extension 2.1.272 — eight patchers failed and NINE applied, and
# nothing in the container said the set was for another version. The tag
# DECLARES its target; until now only the cache key and the fetch URL read it.
mk_conf m 2.1.272
mkdir -p "$CONF/cache/ext-patchs/cc2.1.258-r2/patchers"
mk_probe "$CONF/cache/ext-patchs/cc2.1.258-r2/patchers" probe-mismatch ux
OUT=$(EXT_PATCHES_REF=cc2.1.258-r2 sync_run)
check "a pin for another version is reported" \
  "printf '%s' \"\$OUT\" | grep -q 'targets extension 2.1.258'"
check "…and names the version actually installed" \
  "printf '%s' \"\$OUT\" | grep -q 'runs extension 2.1.272'"
check "…and names the command that moves the pin" \
  "printf '%s' \"\$OUT\" | grep -q 'ext-patches-update'"
# The patchers still land : this is a warning, not a gate. ext-patches-sync
# must never fail a boot, and a half-applied bundle would be worse than a
# fully-applied one that says it is suspect.
check "…while the patchers are still applied" \
  "printf '%s' \"\$OUT\" | grep -q \"applied selection\""
# The restart path exits at the sentinel short-circuit, long before the apply.
# That is the boot a mismatched pin lives in for ever, so the warning has to be
# reachable from there too — "already applied" must not stand alone.
OUT=$(EXT_PATCHES_REF=cc2.1.258-r2 sync_run)
check "already-applied restarts keep saying it" \
  "printf '%s' \"\$OUT\" | grep -q 'already applied' && printf '%s' \"\$OUT\" | grep -q 'targets extension 2.1.258'"

mk_conf n 2.1.272
mkdir -p "$CONF/cache/ext-patchs/cc2.1.272-r1/patchers"
mk_probe "$CONF/cache/ext-patchs/cc2.1.272-r1/patchers" probe-match ux
OUT=$(EXT_PATCHES_REF=cc2.1.272-r1 sync_run)
check "a pin for this very version says nothing" \
  "! printf '%s' \"\$OUT\" | grep -q 'targets extension'"

# A SHA or a branch declares no target, so there is no claim to contradict.
# Silence there is correctness, not an oversight.
mk_conf o 2.1.272
mkdir -p "$CONF/cache/ext-patchs/deadbeef/patchers"
mk_probe "$CONF/cache/ext-patchs/deadbeef/patchers" probe-sha ux
OUT=$(EXT_PATCHES_REF=deadbeef sync_run)
check "a ref that names no version is not second-guessed" \
  "! printf '%s' \"\$OUT\" | grep -q 'targets extension'"

mk_conf p 2.1.272
OUT=$(EXT_PATCHES_REF=cc2.1.258-r2 sync_run --status)
check "--status shows the installed version" \
  "printf '%s' \"\$OUT\" | grep -q 'extension version *2.1.272'"
check "--status shows what the ref targets" \
  "printf '%s' \"\$OUT\" | grep -q 'ref targets *2.1.258'"

echo "== the sentinel short-circuit, and the way past it =="
mk_conf c
mkdir -p "$CONF/cache/ext-patchs/v1/patchers"
mk_probe "$CONF/cache/ext-patchs/v1/patchers" probe-cached ux
: > "$TMPROOT/restore.log"
sync_run >/dev/null 2>&1                       # first run applies
OUT=$(sync_run)                                 # second finds the sentinel
check "a second run short-circuits on the sentinels" \
  "printf '%s' \"\$OUT\" | grep -q 'already applied'"
BEFORE=$(wc -l < "$TMPROOT/restore.log")
sync_run --force >/dev/null 2>&1
checkeq "--force replays the selection anyway" \
  "$(( $(wc -l < "$TMPROOT/restore.log") - BEFORE ))" "1"

echo "== ext-patches-update: the routes that need no network =="
mk_conf d
LOCAL="$TMPROOT/localpatchers"; mk_probe "$LOCAL" probe-local ux
: > "$TMPROOT/restore.log"
# No token in this .env at all: route D must not want one.
grep -v EXT_PATCHES_TOKEN "$UENV" > "$UENV.tmp" && mv "$UENV.tmp" "$UENV"
upd_run --dir "$LOCAL" >/dev/null 2>&1
check "--dir applies from a local checkout, with no token" \
  "grep -q '__PROBE_probe-local__' \"\$UEXT/extension.js\""
BEFORE=$(cksum < "$UEXT/extension.js")
upd_run --check --dir "$LOCAL" >/dev/null 2>&1
checkeq "--check --dir changes nothing" "$(cksum < "$UEXT/extension.js")" "$BEFORE"

echo "== ext-patches-update: resolving which ref is newest =="
mk_conf e
rm -f "$FAKE_DIR/release.json"
printf '[{"name":"v1"},{"name":"v2"}]\n' > "$FAKE_DIR/tags.json"
BEFORE=$(cksum < "$UEXT/extension.js")
OUT=$(upd_run --check)
check "--check reports installed against available" \
  "printf '%s' \"\$OUT\" | grep -q 'installed *v1' && printf '%s' \"\$OUT\" | grep -q 'available *v2'"
checkeq "--check changes nothing" "$(cksum < "$UEXT/extension.js")" "$BEFORE"
checkeq "--check leaves the pin alone" "$(pin_of)" "v1"

printf '{"tag_name":"v9"}\n' > "$FAKE_DIR/release.json"
OUT=$(upd_run --check)
check "latest prefers a published release" "printf '%s' \"\$OUT\" | grep -q 'available *v9'"
# The repository this was built for has git tags and NO releases, so the
# fallback is not a nicety — it is the branch that actually runs.
rm -f "$FAKE_DIR/release.json"
OUT=$(upd_run --check)
check "latest falls back to the tag list" "printf '%s' \"\$OUT\" | grep -q 'available *v2'"
# /tags comes back in ref order, which is lexicographic: cc2.1.99 sorts above
# cc2.1.258 as text and below it as a version.
printf '[{"name":"cc2.1.99-r1"},{"name":"cc2.1.258-r1"}]\n' > "$FAKE_DIR/tags.json"
OUT=$(upd_run --check)
check "tags are ordered numerically, not lexicographically" \
  "printf '%s' \"\$OUT\" | grep -q 'available *cc2.1.258-r1'"

echo "== ext-patches-update: one line of tags per Claude Code version =="
# The measured defect: with tags cc2.1.258-r2 and cc2.1.268-r1, a 2.1.220
# container resolved cc2.1.268-r1 — the newest overall, tested on something
# else. It worked only because the sets happened to be multi-version.
LINES='[{"name":"cc2.1.220-r3"},{"name":"cc2.1.258-r1"},{"name":"cc2.1.258-r2"},{"name":"cc2.1.268-r1"}]'
mk_conf l 2.1.258
printf '%s\n' "$LINES" > "$FAKE_DIR/tags.json"
rm -f "$FAKE_DIR/release.json"
OUT=$(upd_run --check)
check "a version with a tag line resolves to that line" \
  "printf '%s' \"\$OUT\" | grep -q 'available *cc2.1.258-r2' \
   && ! printf '%s' \"\$OUT\" | grep -q 'cc2.1.268-r1'"

# r10 over r9 is a string comparison away from being wrong, the same trap
# run-all.sh:90-93 names one field over.
printf '[{"name":"cc2.1.258-r9"},{"name":"cc2.1.258-r10"}]\n' > "$FAKE_DIR/tags.json"
OUT=$(upd_run --check)
check "the -r number is compared as an integer" \
  "printf '%s' \"\$OUT\" | grep -q 'available *cc2.1.258-r10'"

# A published release is the newest release whatever version this container
# runs, so it answers the wrong question and must not be consulted here.
printf '{"tag_name":"cc2.1.268-r1"}\n' > "$FAKE_DIR/release.json"
printf '%s\n' "$LINES" > "$FAKE_DIR/tags.json"
OUT=$(upd_run --check)
check "a release does not override this container's line" \
  "printf '%s' \"\$OUT\" | grep -q 'available *cc2.1.258-r2'"
rm -f "$FAKE_DIR/release.json"

# A third-party repository, the starter, anything tagging v1.2.3: no convention
# to key on, so keep the behaviour it has always had — and say which branch
# answered, because "why did it pick that?" is the whole question here.
mk_conf m 2.1.258
printf '[{"name":"v1"},{"name":"v2"}]\n' > "$FAKE_DIR/tags.json"
OUT=$(upd_run --check)
check "a repository without the convention keeps the newest-overall behaviour" \
  "printf '%s' \"\$OUT\" | grep -q 'available *v2'"
check "the newest-overall fallback says so" \
  "printf '%s' \"\$OUT\" | grep -q 'follows cc<version>-r<n>'"

# A tag list that never answered is not a repository ignoring the convention,
# and the message must not say it is — that sends someone reading tag names.
rm -f "$FAKE_DIR/tags.json"
printf '{"tag_name":"v9"}\n' > "$FAKE_DIR/release.json"
OUT=$(upd_run --check)
check "no tag list falls back to the release, and says which" \
  "printf '%s' \"\$OUT\" | grep -q 'available *v9' \
   && printf '%s' \"\$OUT\" | grep -q 'no tag list came back' \
   && ! printf '%s' \"\$OUT\" | grep -q 'follows cc<version>-r<n>'"
rm -f "$FAKE_DIR/release.json"

# A gate nobody can evaluate must not start hiding things — run-all.sh:219-223
# and ext-patches-sync:186-188 already degrade this way.
mk_conf n                                       # no version in package.json
printf '%s\n' "$LINES" > "$FAKE_DIR/tags.json"
OUT=$(upd_run --check)
check "an unreadable extension version falls back to newest-overall" \
  "printf '%s' \"\$OUT\" | grep -q 'available *cc2.1.268-r1'"
check "the unreadable version is named as the reason" \
  "printf '%s' \"\$OUT\" | grep -q 'version is unreadable'"

# The point of the whole exercise: a version nobody tested gets no guess.
mk_conf o 2.1.300
printf '%s\n' "$LINES" > "$FAKE_DIR/tags.json"
OUT=$(upd_run); RC=$?
check "a version with no tag line refuses" "[ $RC -ne 0 ] && [ \"\$(pin_of)\" = v1 ]"
check "the refusal names the tested lines" \
  "printf '%s' \"\$OUT\" | grep -q '2.1.220 2.1.258 2.1.268'"
check "the refusal names the way out" \
  "printf '%s' \"\$OUT\" | grep -q 'EXT_PATCHES_ALLOW_UNTESTED=1'"

# The escape hatch. HEAD is a question; what lands in the .env is the commit it
# resolved to, read from the tarball's <owner>-<repo>-<sha> wrapper — the only
# place this container can learn it, the firewall granting no contents API.
mk_conf p 2.1.300
OUT=$(EXT_PATCHES_ALLOW_UNTESTED=1 upd_run)
checkeq "ALLOW_UNTESTED pins the commit, never the word HEAD" "$(pin_of)" "deadbee"
check "ALLOW_UNTESTED still says the set is untested" \
  "printf '%s' \"\$OUT\" | grep -q 'never been tested on extension 2.1.300'"
check "the HEAD cache is renamed to the commit it resolved to" \
  "[ -d \"\$CONF/cache/ext-patchs/deadbee/patchers\" ] \
   && [ ! -d \"\$CONF/cache/ext-patchs/HEAD\" ]"

# The operator's override, and it has to outrank every branch above — including
# the refusal. Asserted on the wire, not on the outcome: no /tags is fetched.
mk_conf q 2.1.300
: > "$FAKE_LOG"
upd_run --ref cc2.1.220-r3 >/dev/null 2>&1
checkeq "an explicit --ref outranks the refusal" "$(pin_of)" "cc2.1.220-r3"
check "an explicit --ref asks no question at all" "! grep -q '/tags' \"\$FAKE_LOG\""

printf '[{"name":"v1"},{"name":"v2"}]\n' > "$FAKE_DIR/tags.json"   # restore the fixture

echo "== the tested-versions list travels with the patchers =="
# The repository knows which Claude Code versions it was validated against, and
# until now that knowledge stopped at its own test suite. It covers what tag
# resolution cannot see: a ref pinned by hand, or a .env copied from another
# project.
mk_conf r 2.1.999
OUT=$(sync_run 2>&1)
check "the fetch records which commit the ref resolved to" \
  "[ \"\$(cat \"\$CONF/cache/ext-patchs/v1/.resolved-sha\")\" = deadbee ]"
check "a ref never tested on this extension says so" \
  "printf '%s' \"\$OUT\" | grep -q 'never tested on extension 2.1.999'"
check "the note lists what the ref WAS tested on" \
  "printf '%s' \"\$OUT\" | grep -q '2.1.220 2.1.258'"
# A restart that finds every sentinel live exits before reaching the fetch, and
# that is exactly the boot that must keep saying it.
OUT=$(sync_run 2>&1)
check "the untested note survives the restart short-circuit" \
  "printf '%s' \"\$OUT\" | grep -q 'already applied' \
   && printf '%s' \"\$OUT\" | grep -q 'never tested on extension 2.1.999'"
OUT=$(sync_run --status 2>&1)
check "--status reports the tested versions" \
  "printf '%s' \"\$OUT\" | grep -q 'tested versions *2.1.220 2.1.258'"

mk_conf s 2.1.258
OUT=$(sync_run 2>&1)
check "a ref tested on this extension says nothing" \
  "! printf '%s' \"\$OUT\" | grep -q 'never tested'"

echo "== ext-patches-update: the pin only moves when the patchers did =="
mk_conf f
printf '[{"name":"v1"},{"name":"v2"}]\n' > "$FAKE_DIR/tags.json"
upd_run >/dev/null 2>&1
checkeq "a successful update rewrites the pin" "$(pin_of)" "v2"
check "the rewrite keeps the comments around it" "grep -q 'trailing comment' \"\$UENV\""

mk_conf g
upd_run --no-write-env >/dev/null 2>&1
checkeq "--no-write-env leaves the pin alone" "$(pin_of)" "v1"

# The one that matters: a pin naming a ref that never downloaded sends the next
# boot looking for a cache that is not there, and does it silently.
mk_conf h
mv "$FAKE_DIR/src.tar.gz" "$FAKE_DIR/src.tar.gz.off"
upd_run >/dev/null 2>&1
checkeq "a download that fails leaves the pin alone" "$(pin_of)" "v1"
mv "$FAKE_DIR/src.tar.gz.off" "$FAKE_DIR/src.tar.gz"

mk_conf i
upd_run --reapply >/dev/null 2>&1
checkeq "--reapply refuses when nothing is cached" "$?" "1"

echo "== resolving latest is a convenience, never a dependency =="
# Offline, firewalled, token expired, repo moved — none of that should be
# fatal to a container that already has patchers on disk.
mk_conf y
mkdir -p "$CONF/cache/ext-patchs/v1/patchers"
mk_probe "$CONF/cache/ext-patchs/v1/patchers" probe-cached ux
rm -f "$FAKE_DIR/tags.json" "$FAKE_DIR/release.json"      # nothing answers
OUT=$(upd_run); RC=$?
check "an unreachable repository with a cache warns and keeps the pin" \
  "[ $RC -eq 0 ] && printf '%s' \"\$OUT\" | grep -q 'keeping v1' && [ \"\$(pin_of)\" = v1 ]"

mk_conf z                                                  # no cache at all
upd_run >/dev/null 2>&1
checkeq "an unreachable repository with nothing cached is an error" "$?" "1"
printf '[{"name":"v1"},{"name":"v2"}]\n' > "$FAKE_DIR/tags.json"   # restore the fixture

echo "== base + override: the project's own patchers next to the resolved ones =="
# The contract the rest of the image already has for skills and hooks — a base
# layer, an override that wins, and the override said out loud.
mk_conf j
RESOLVED="$TMPROOT/resolved"; rm -rf "$RESOLVED"
mk_probe "$RESOLVED" probe-shared ux
mk_probe "$RESOLVED" probe-base-only ux
# Same FILENAME, different sentinel: that is what "override" has to mean.
LOCALD="$CONF/claude/vscode-ext-patchs"
mk_probe "$LOCALD" probe-shared ux
sed -i 's/__PROBE_probe-shared__/__PROBE_OVERRIDE__/g' "$LOCALD/probe-shared.py"

OUT=$(EXT_PATCHES_DIR="$RESOLVED" sync_run)
check "a local patcher of the same name overrides the resolved one" \
  "grep -q '__PROBE_OVERRIDE__' \"\$UEXT/extension.js\" \
   && ! grep -q '__PROBE_probe-shared__' \"\$UEXT/extension.js\""
# A local file silently shadowing a tagged one is how you debug the wrong file.
check "the override is announced by name" \
  "printf '%s' \"\$OUT\" | grep -q 'overriding:.*probe-shared'"

# The stamp only earns its keep when the SENTINELS CANNOT SEE THE EDIT. So the
# override is regenerated marker-identical to the resolved patcher: every
# declared sentinel is then live, the old `all_live $SRC` check was satisfied,
# and a short-circuit was the answer. Without this the sub-test passes with or
# without the stamp and proves nothing — which is exactly what the first
# version of it did.
mk_probe "$LOCALD" probe-shared ux
EXT_PATCHES_DIR="$RESOLVED" sync_run >/dev/null 2>&1      # apply + write the stamp
OUT=$(EXT_PATCHES_DIR="$RESOLVED" sync_run)
check "an untouched local directory still short-circuits" \
  "printf '%s' \"\$OUT\" | grep -q 'already applied'"
sleep 1                                   # mtime has one-second resolution
printf '\n# touched\n' >> "$LOCALD/probe-shared.py"
: > "$TMPROOT/restore.log"
OUT=$(EXT_PATCHES_DIR="$RESOLVED" sync_run)
check "editing a local patcher re-triggers the apply" \
  "printf '%s' \"\$OUT\" | grep -q 'changed since the last apply' \
   && [ -s \"\$TMPROOT/restore.log\" ]"

# Nothing resolved at all, no token, no repo — just a directory of .py the
# operator put there. That is a configured project, not a silent no-op.
mk_conf k
: > "$UENV"
mk_probe "$CONF/claude/vscode-ext-patchs" probe-solo ux
sync_run >/dev/null 2>&1
check "local patchers alone are a configured project" \
  "grep -q '__PROBE_probe-solo__' \"\$UEXT/extension.js\""

fi

printf '\ntoolkit: %d pass / %d fail' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ' / %d skipped' "$SKIP"
printf '\n'
[ "$FAIL" -eq 0 ]
