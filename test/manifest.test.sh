#!/usr/bin/env bash
# Tree invariants for the base-image repo. The directory layout IS the COPY
# manifest (assets/opt → /opt/devcontainer/base, assets/etc-firewall →
# /etc/devcontainer-firewall, bin → /usr/local/bin), so a stray file here
# fails a test instead of shipping.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Container-side suite. On macOS it would emit a wall of `stat: illegal
# option -- c` and `declare: -A: invalid option` instead of a verdict —
# refuse up front and name the working alternative.
require_gnu_env() {
  local why=""
  stat -c '%a' "$REPO/package.json" >/dev/null 2>&1 || why="GNU stat"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || why="${why:+$why + }bash 4+ (found $BASH_VERSION)"
  [ -z "$why" ] && return 0
  echo "✗ $(basename "$0") needs $why — run it INSIDE the devcontainer." >&2
  echo "  Host-side, the docker-dependent checks live in test/run-image-suites.sh." >&2
  exit 2
}
require_gnu_env

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  ✘ %s\n' "$1" >&2; }
check(){ if eval "$2"; then ok "$1"; else ko "$1"; fi }

echo "== top-level layout =="
EXPECTED_TOP=".dockerignore .github .gitignore Dockerfile EXTENDING.md LICENSE README.md RELEASING.md TESTING.md assets bin cc-versions.json package.json stacks test"
ACTUAL_TOP="$(ls -A | grep -v '^\.git$' | sort | tr '\n' ' ' | sed 's/ $//')"
check "top-level entries are exactly the manifest" \
  "[ \"\$ACTUAL_TOP\" = \"\$(printf '%s' \"\$EXPECTED_TOP\")\" ]" \
  || { echo "    expected: $EXPECTED_TOP"; echo "    actual:   $ACTUAL_TOP"; }

echo "== bin/ (→ /usr/local/bin) =="
EXPECTED_BIN="compile-policy.py devc-conf.sh devc-hook firewall-blocks firewall-digest.sh firewall-docker-setup.sh init-firewall.sh install-extensions mitm-init.sh reload-firewall restore-ext-patches sync-creds sync-skills test-firewall.sh"
ACTUAL_BIN="$(ls bin | sort | tr '\n' ' ' | sed 's/ $//')"
check "bin/ holds exactly the 14 shipped binaries" "[ \"\$ACTUAL_BIN\" = \"\$EXPECTED_BIN\" ]"
# Mode bits via stat, not `test -x` — /workspace can be a Docker Desktop
# `fakeowner` mount where access(2) reports every file executable. git and
# docker COPY both honour the real mode, which is what ships.
has_exec() { local m; m="$(stat -c '%a' "$1")"; [ $(( 8#$m & 8#111 )) -ne 0 ]; }
for f in bin/*; do
  base="$(basename "$f")"
  if [ "$base" = "firewall-digest.sh" ] || [ "$base" = "devc-conf.sh" ]; then
    check "$base is NOT executable (sourced library)" "! has_exec '$f'"
  else
    check "$base is executable" "has_exec '$f'"
  fi
done

echo "== assets/opt (→ /opt/devcontainer/base) =="
EXPECTED_OPT="hooks knowledge shell-init.sh skills zshrc"
ACTUAL_OPT="$(ls assets/opt | sort | tr '\n' ' ' | sed 's/ $//')"
check "assets/opt holds exactly hooks knowledge shell-init.sh skills zshrc" "[ \"\$ACTUAL_OPT\" = \"\$EXPECTED_OPT\" ]"
check "on-create.d has 1 fragment"    "[ \"\$(ls assets/opt/hooks/on-create.d/*.sh | wc -l)\" -eq 1 ]"
check "post-create.d has 4 fragments" "[ \"\$(ls assets/opt/hooks/post-create.d/*.sh | wc -l)\" -eq 4 ]"
check "post-start.d has 18 fragments" "[ \"\$(ls assets/opt/hooks/post-start.d/*.sh | wc -l)\" -eq 18 ]"
check "skills/ has 9 dirs + sync-skills.sh" \
  "[ \"\$(find assets/opt/skills -mindepth 1 -maxdepth 1 -type d | wc -l)\" -eq 9 ] && [ -f assets/opt/skills/sync-skills.sh ]"
# floating-perms is deliberately NOT shipped: it drives the VS Code extension
# patches, so its hooks only make sense in the dogfood that carries them.
check "floating-perms does not ship in the image" "[ ! -d assets/opt/skills/floating-perms ]"
check "knowledge/ has 7 files" "[ \"\$(find assets/opt/knowledge -type f | wc -l)\" -eq 7 ]"

echo "== forbidden content =="
check "no .local overlay anywhere under assets/" "[ -z \"\$(find assets -name '*.local' -o -name '*.local.*' -not -name '*.local.txt.example' -not -name '*.example' | head -1)\" ]"
check "no .DS_Store anywhere" "[ -z \"\$(find . -name .DS_Store -not -path './.git/*' | head -1)\" ]"
# A directory COPY takes what is on disk, tracked or not, so debris under a
# COPY source ships in the image. .dockerignore is the guard; this asserts the
# guard covers the one that actually appeared — __pycache__ from the patchers.
check ".dockerignore excludes __pycache__ from the build context" \
  "grep -q '__pycache__' .dockerignore"
# 3-level model : the image's own allowlist lives in domains.d/00-base.txt.
# domains.txt stays a PROJECT-layer filename — the bake overlays the project
# copy into /etc, so shipping one here would shadow-merge with every project.
check "no project-layer domains.txt ships in the image" "[ ! -f assets/etc-firewall/domains.txt ]"
check "base allowlist domains.d/00-base.txt ships in the image" "[ -s assets/etc-firewall/domains.d/00-base.txt ]"

echo "== assets/etc-firewall (→ /etc/devcontainer-firewall) =="
EXPECTED_ETC="addons dnsmasq.conf domains.d policy.d tests"
ACTUAL_ETC="$(ls assets/etc-firewall | sort | tr '\n' ' ' | sed 's/ $//')"
check "etc-firewall holds exactly addons dnsmasq.conf domains.d policy.d tests" "[ \"\$ACTUAL_ETC\" = \"\$EXPECTED_ETC\" ]"

echo "== no unguarded workspace dependency =="
# The regression this catches: a hook whose only implementation lives at a
# /workspace/.devcontainer/... path is dead on a project that ships nothing
# but the compose files — silently, because the hooks warn and exit 0. Every
# workspace reference must therefore be paired with a baked fallback (an
# /opt/devcontainer/base or /usr/local/bin path) in the same file.
WS_FAIL=""
while IFS= read -r -d '' f; do
  grep -q '/workspace/\.devcontainer/' "$f" || continue
  # Reading project *data* is fine (firewall overlay, .env, flags, logs,
  # hooks dir); it is delegating *behaviour* that must have a fallback.
  grep -qE '/(opt/devcontainer/base|usr/local/bin)/' "$f" && continue
  grep -qE '/workspace/\.devcontainer/(firewall|logs|hooks|pending|\.env|\.configured)' "$f" && continue
  # Explicit opt-out for a hook whose fallback is inlined rather than baked.
  grep -q '# workspace-optional:' "$f" && continue
  WS_FAIL="$WS_FAIL ${f#assets/opt/hooks/}"
done < <(find assets/opt/hooks -name '*.sh' -print0)
check "every hook delegating to a workspace script has a baked fallback" "[ -z \"\$WS_FAIL\" ]" \
  || echo "    offending: $WS_FAIL"

echo "== syntax sweeps =="
BASHN_FAIL=0
while IFS= read -r -d '' f; do
  bash -n "$f" || { BASHN_FAIL=1; echo "    bash -n failed: $f" >&2; }
# test/ is swept too: the host-side suites there are never syntax-checked by
# running them (this half has no Docker), so without this a typo in one would
# only surface on the host, mid-run, after minutes of setup.
done < <(find bin assets/opt/hooks assets/etc-firewall/tests test -name '*.sh' -print0; printf '%s\0' bin/devc-hook bin/reload-firewall bin/firewall-blocks)
check "bash -n on every shipped shell script" "[ \$BASHN_FAIL -eq 0 ]"
check "compile-policy.py parses" "python3 -c \"import ast; ast.parse(open('bin/compile-policy.py').read())\""
PYADDON_FAIL=0
for f in assets/etc-firewall/addons/*.py; do
  python3 -c "import ast; ast.parse(open('$f').read())" || PYADDON_FAIL=1
done
check "every firewall addon parses" "[ \$PYADDON_FAIL -eq 0 ]"

echo "== Dockerfile COPY sources exist =="
COPY_FAIL=0
while IFS= read -r src; do
  [ -e "$src" ] || { COPY_FAIL=1; echo "    missing COPY source: $src" >&2; }
done < <(grep -E '^COPY ' Dockerfile | grep -v -- '--from=' | awk '{print $2}' | sed 's:/$::')
check "every Dockerfile COPY source exists in the tree" "[ \$COPY_FAIL -eq 0 ]"

echo "== dispatcher resolves the image layout =="
EMPTY="$(mktemp -d)"
for phase in on-create post-create post-start; do
  out="$(DEVC_BASE_HOOKS="$REPO/assets/opt/hooks" DEVC_OVERLAY_HOOKS="$EMPTY/hooks" DEVC_CONFIG_DIR="$EMPTY" bash bin/devc-hook "$phase" --dry-run)"
  case "$phase" in
    on-create)   want=1 ;;
    post-create) want=4 ;;
    post-start)  want=18 ;;
  esac
  n="$(printf '%s\n' "$out" | grep -c 'WOULD RUN' || true)"
  check "devc-hook $phase --dry-run enumerates $want fragment(s)" "[ \"$n\" -eq $want ]"
done
# Ordering: post-start must enumerate 05 before 10 before 90.
out="$(DEVC_BASE_HOOKS="$REPO/assets/opt/hooks" DEVC_OVERLAY_HOOKS="$EMPTY/hooks" DEVC_CONFIG_DIR="$EMPTY" bash bin/devc-hook post-start --dry-run | grep 'WOULD RUN' )"
check "post-start fragments enumerate in numeric order" \
  "[ \"\$(printf '%s\n' \"$out\" | sed 's/.*post-start.d\///;s/ .*//')\" = \"\$(printf '%s\n' \"$out\" | sed 's/.*post-start.d\///;s/ .*//' | sort)\" ]"
rm -rf "$EMPTY"

echo "== metadata =="
check "package.json parses and has a semver version" \
  "node -e \"const v=require('$REPO/package.json').version; if(!/^\d+\.\d+\.\d+$/.test(v)) process.exit(1)\""
check "cc-versions.json parses, non-empty, default listed" \
  "node -e \"const c=require('$REPO/cc-versions.json'); if(!Array.isArray(c.versions)||c.versions.length<1||!c.versions.includes(c.default)) process.exit(1)\""
check "publish.yml parses as YAML" \
  "python3 -c \"import yaml; yaml.safe_load(open('$REPO/.github/workflows/publish.yml'))\""

echo
echo "manifest: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
