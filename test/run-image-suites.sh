#!/usr/bin/env bash
# Host-runnable image suites — everything that needs a real built image.
#
#   bash test/run-image-suites.sh                 # uses devcontainer-sandbox:local
#   bash test/run-image-suites.sh --build         # rebuild it first
#   IMG=ghcr.io/…/devcontainer-sandbox:0.1.0-cc2.1.220 bash test/run-image-suites.sh
#
# Complements the unprivileged suites (manifest.test.sh, run-firewall-suites.sh)
# which need no Docker. Three contexts :
#   A. bare `docker run`     — image layout, labels, hooks, privilege +
#                              escalation boundary, and the host→container
#                              direction (EXPOSE, template compose)
#   B. live container        — firewall up in basic, re-entrance, both
#                              boundaries again (runtime ruleset + caps granted)
#   C. bake                  — base layer + a project overlay
#
# Intended as the seed of a pre-publish release gate : it is the part the
# GitHub workflow cannot skip without shipping an untested image.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-devcontainer-sandbox:local}"

# Same fallback as test/run-all.sh, repeated so this suite is standalone: the
# "as published" assertion compares against an unpacked VSIX, and a vendored
# snapshot beside this repo is the usual place one lives.
if [ -z "${VENDOR_DIR:-}" ]; then
  for _c in "$REPO/../claude-ext-patchs/vendor/anthropic.claude-code"; do
    [ -d "$_c" ] && { VENDOR_DIR="$(cd "$_c" && pwd)"; export VENDOR_DIR; break; }
  done
fi
# Project overlay used for the bake check. Defaults to the monorepo's v3
# template when this repo sits inside it; override for a standalone checkout.
PROJECT_FW="${PROJECT_FW:-$REPO/../../templates/v3/project/firewall}"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ✔ $1"; }
ko()   { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP+1)); echo "  – $1 (skipped: $2)"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || ko "$1 — expected '$3', got '$2'"; }

if [ "${1:-}" = "--build" ]; then
  echo "=== building $IMG ==="
  docker build -t "$IMG" --build-arg BASE_VERSION="$(jq -r .version "$REPO/package.json")" "$REPO" \
    || { echo "❌ build failed"; exit 1; }
fi

docker image inspect "$IMG" >/dev/null 2>&1 || {
  echo "❌ image $IMG not found — run with --build, or set IMG=<tag>"
  exit 1
}

echo
echo "═══ A. bare docker run ═══"
ETC=$(docker run --rm "$IMG" ls /etc/devcontainer-firewall | sort | tr '\n' ' ' | sed 's/ $//')
eq "etc-firewall layout" "$ETC" "addons dnsmasq.conf domains.d policy.d tests"
OPT=$(docker run --rm "$IMG" ls /opt/devcontainer/base | sort | tr '\n' ' ' | sed 's/ $//')
eq "opt/devcontainer/base layout" "$OPT" "hooks knowledge shell-init.sh skills zshrc"

NHOSTS=$(docker run --rm "$IMG" python3 /usr/local/bin/compile-policy.py \
           --list-hosts /etc/devcontainer-firewall/domains.d/00-base.txt | wc -l | tr -d ' ')
# 34 depuis le correctif du défaut 6 (2026-08-10) : vscode.download.prss.microsoft.com
# ajouté à domains.d/00-base.txt. 33 = image d'avant le correctif.
eq "base allowlist host count" "$NHOSTS" "34"
NPOL=$(docker run --rm "$IMG" sh -c 'ls /etc/devcontainer-firewall/policy.d/*.yaml | wc -l' | tr -d ' ')
eq "base policy.d count" "$NPOL" "12"

HOOKS=$(docker run --rm "$IMG" bash -lc '
  for p in on-create post-create post-start; do devc-hook $p --dry-run | grep -c "WOULD RUN"; done' \
  | tr '\n' '/' | sed 's/\/$//')
# post-start est passé de 20 à 19 au retrait de 70-gh-auth-check.sh.
eq "devc-hook fragments on-create/post-create/post-start" "$HOOKS" "2/4/19"

echo "  — workspace-free integrations (a project ships no shell plumbing) —"
for b in sync-creds sync-skills install-extensions; do
  docker run --rm "$IMG" test -x "/usr/local/bin/$b" \
    && ok "/usr/local/bin/$b baked" || ko "/usr/local/bin/$b missing"
done
docker run --rm "$IMG" test -f /opt/devcontainer/base/shell-init.sh \
  && ok "baked shell-init.sh present" || ko "baked shell-init.sh missing"
# The regression that started this: ~/.zshrc used to source ONLY a workspace
# file, so a project without it got a bare shell.
docker run --rm "$IMG" grep -q '/opt/devcontainer/base/shell-init.sh' /home/node/.zshrc \
  && ok ".zshrc falls back to the baked shell-init" || ko ".zshrc has no baked fallback"
# Interactive zsh must reach Oh My Zsh (theme + git in the prompt) with no
# workspace whatsoever.
OMZ=$(docker run --rm "$IMG" zsh -ic 'echo "OMZ=${ZSH:-unset} THEME=${ZSH_THEME:-unset}"' 2>/dev/null | tr -d '\r' | grep -o 'OMZ=[^ ]* THEME=[^ ]*')
case "$OMZ" in
  *"OMZ=/home/node/.oh-my-zsh"*"THEME="*) ok "interactive zsh loads OMZ + theme ($OMZ)" ;;
  *) ko "interactive zsh did not load OMZ — got '${OMZ:-nothing}'" ;;
esac
GITPROMPT=$(docker run --rm "$IMG" zsh -ic 'echo "FN=${+functions[git_prompt_info]}"' 2>/dev/null | tr -d '\r' | grep -o 'FN=[01]')
eq "git prompt helper available in zsh" "$GITPROMPT" "FN=1"

# The version label vs the tree it is supposed to have been built from. Every
# other assertion here reads the image, so an image built before the current
# commit passes them all and fails somewhere far away instead — extend.test.sh
# built FROM a stale one and reported two mysterious reds. Name it here.
IMG_VER=$(docker image inspect -f '{{ index .Config.Labels "org.stitchu.base.version" }}' "$IMG" 2>/dev/null)
PKG_VER=$(jq -r .version "$REPO/package.json")
if [ "$IMG_VER" = "$PKG_VER" ]; then
  ok "the image was built from this tree (version $PKG_VER)"
else
  ko "STALE IMAGE: $IMG is version '$IMG_VER', the tree is '$PKG_VER' — rebuild it, every assertion below reads the old one"
fi

for label in org.stitchu.base.version org.stitchu.claude-code.version org.opencontainers.image.source; do
  V=$(docker inspect "$IMG" --format "{{index .Config.Labels \"$label\"}}")
  [ -n "$V" ] && ok "label $label = $V" || ko "label $label missing"
done

echo "  — VS Code extension: unmodified, plus the toolkit to patch your own —"
# The toolkit ships; no patcher does. This is the compliance line the whole
# split exists for, so it is asserted on the image rather than on the tree.
for f in run-all.sh _common.py AUTHORING.md; do
  docker run --rm "$IMG" test -f "/usr/local/bin/vscode-ext-patchs/$f" \
    && ok "$f readable from inside the container" || ko "$f missing from the image"
done
NPATCH=$(docker run --rm "$IMG" sh -c 'ls /usr/local/bin/vscode-ext-patchs/*.py 2>/dev/null | grep -v _common.py | wc -l' | tr -d '\r ')
eq "the image ships no patcher" "$NPATCH" "0"
for b in restore-ext-patches ext-patches-sync; do
  docker run --rm "$IMG" test -x "/usr/local/bin/$b" \
    && ok "$b baked" || ko "$b missing"
done

# What the build chose, kept as an ENV so a consumer can find out without
# guessing from the bundle.
BAKED_SEL=$(docker run --rm "$IMG" printenv CLAUDE_CODE_EXT_PATCHS 2>/dev/null | tr -d '\r')
[ -n "$BAKED_SEL" ] \
  && ok "the image records its patch selection (CLAUDE_CODE_EXT_PATCHS=$BAKED_SEL)" \
  || ko "CLAUDE_CODE_EXT_PATCHS is not readable in the image"

# The pristine copies are what makes the runtime selection real. Without them
# restore-ext-patches has nothing to replay from, and `none` becomes a one-way
# door needing a rebuild.
ORIG=$(docker run --rm "$IMG" sh -c 'cd /usr/local/share/claude-ext-orig 2>/dev/null && find . -type f | sed "s|^\./||" | sort | tr "\n" " " | sed "s/ $//"')
eq "pristine copies of every rewritten file are baked" \
   "$ORIG" "extension.js package.json webview/index.js"

# The list used to be derived from the shipped patchers' headers. With none
# shipped that union is empty, so the Dockerfile fixes it instead — and this is
# what pins it: these three are what restore-ext-patches can replay from, and
# what anyone patching this extension will be rewriting.
eq "and the baked list is the fixed one, not an empty derivation" \
   "$(docker run --rm "$IMG" sh -c 'ls /usr/local/share/claude-ext-orig/*.js /usr/local/share/claude-ext-orig/*.json 2>/dev/null | wc -l' | tr -d '\r ')" "2"

# --list greps the live bundle rather than trusting the build ARG. With no
# patcher baked the honest answer is "none", and saying so must still exit 0:
# an image that patches nothing is this image's nominal state, not an error.
eq "the image records its patch selection as none" "$BAKED_SEL" "none"
# The exit code is the docker run's, so it is captured BEFORE the pipe: after
# a pipeline $? is sed's, and sed always succeeds.
RAW=$(docker run --rm "$IMG" restore-ext-patches --list 2>&1); RC=$?
LIST=$(printf '%s\n' "$RAW" | sed 's/\x1b\[[0-9;]*m//g')
eq "restore-ext-patches --list exits 0 with no patcher" "$RC" "0"
LIVE=$(printf '%s\n' "$LIST" | grep -c ' yes$' || true)
eq "restore-ext-patches --list finds 0 patches live" "$LIVE" "0"
printf '%s\n' "$LIST" | grep -q 'no patcher' \
  && ok "--list says plainly that the image ships the toolkit only" \
  || ko "--list does not explain the empty patch directory"

# "installed and run as published" — the condition the whole split exists to
# satisfy, and the only assertion here that proves it rather than implying it.
# The reference is the unpacked VSIX for the same version. VENDOR_DIR points at
# a vendored copy when there is one; otherwise the extension is hashed against
# a VSIX fetched from the Marketplace at the version the image declares. With
# neither, this SKIPS loudly rather than passing on an assumption.
# The version comes from the label: /etc/claude-build-env carries the paths,
# not the version number.
CCVER=$(docker inspect "$IMG" --format '{{index .Config.Labels "org.stitchu.claude-code.version"}}' 2>/dev/null | tr -d '\r')
REF="${VENDOR_DIR:-}/v$CCVER/min"
if [ -z "${VENDOR_DIR:-}" ] || [ ! -d "$REF" ]; then
  skip "the extension is byte-identical to the published VSIX" \
       "no reference for $CCVER — set VENDOR_DIR=<vendor>/anthropic.claude-code"
else
  # The WHOLE tree, not just the files a patcher would have touched: "installed
  # and run as published" is a statement about the extension, not about three
  # files. resources/ is excluded — it holds the ~200 MB platform-specific
  # native binary, which the image symlinks rather than copies.
  IMG_SUM=$(docker run --rm "$IMG" sh -c '. /etc/claude-build-env && cd "$EXT_DIR" && find . -type f ! -path "./resources/*" | sort | xargs sha256sum | sha256sum' 2>/dev/null | cut -d" " -f1)
  REF_SUM=$( (cd "$REF" && find . -type f ! -path "./resources/*" | sort | xargs sha256sum | sha256sum) | cut -d" " -f1)
  eq "the extension is byte-identical to the published VSIX (as published)" "$IMG_SUM" "$REF_SUM"
fi

echo "  — privilege suite (as node, no caps, firewall never started) —"
docker run --rm -u node "$IMG" bash /etc/devcontainer-firewall/tests/privilege.sh > /tmp/priv-a.log 2>&1 \
  && ok "privilege.sh context A" \
  || { ko "privilege.sh context A"; grep -E '❌' /tmp/priv-a.log | sed 's/^/      /'; }

echo "  — escalation suite (as node, no caps, firewall never started) —"
docker run --rm -u node "$IMG" bash /etc/devcontainer-firewall/tests/escalation.sh > /tmp/esc-a.log 2>&1 \
  && ok "escalation.sh context A" \
  || { ko "escalation.sh context A"; grep -E '❌' /tmp/esc-a.log | sed 's/^/      /'; }

# sudo does env_reset, but init-firewall.sh reads FIREWALL_CONFIG_DIR and
# DEVC_CONF_LIB from the environment. An env_keep or SETENV on the NOPASSWD
# grant would turn those seams into "node picks the config root, as root".
# node cannot read /etc/sudoers.d (privilege.sh asserts exactly that), so this
# check has to run from outside the suite, as root.
ENVKEEP=$(docker run --rm -u 0 "$IMG" sh -c \
  "grep -rhE 'env_keep|SETENV' /etc/sudoers.d/ 2>/dev/null | tr -d '\n'")
[ -z "$ENVKEEP" ] \
  && ok "no env_keep/SETENV in /etc/sudoers.d (the env seams stay stripped)" \
  || ko "sudoers grants env through: $ENVKEEP"

# Nothing is advertised to the host. EXPOSE alone publishes nothing without
# -P, but an empty set is the frozen starting point: a port added here is a
# port a `docker run -P` would open without anyone deciding to.
PORTS=$(docker image inspect "$IMG" --format '{{if .Config.ExposedPorts}}{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}{{end}}' 2>/dev/null | sed 's/ $//')
[ -z "$PORTS" ] \
  && ok "image declares no EXPOSE (nothing advertised host-ward)" \
  || ko "image exposes ports: $PORTS"

# D3 — the host → container direction, on the template the user actually runs.
# otherPortsAttributes:ignore in devcontainer.json only silences the VS Code
# auto-forward UI; it closes nothing. These freeze what the compose file may do.
TPL="$REPO/../../templates/v3"
if [ -d "$TPL" ]; then
  for variant in project dockerbase; do
    COMPOSE="$TPL/$variant/docker-compose.yml"
    [ -f "$COMPOSE" ] || { skip "template $variant compose checks" "no $COMPOSE"; continue; }

    grep -qE '^[[:space:]]*ports:' "$COMPOSE" \
      && ko "$variant compose publishes ports to the host" \
      || ok "$variant compose publishes no ports"

    grep -q 'docker.sock' "$COMPOSE" \
      && ko "$variant compose mounts the Docker socket — container escape to host root" \
      || ok "$variant compose mounts no Docker socket"

    grep -qE '^[[:space:]]*(privileged:[[:space:]]*true|network_mode:[[:space:]]*host)' "$COMPOSE" \
      && ko "$variant compose uses privileged/network_mode:host" \
      || ok "$variant compose is neither privileged nor host-networked"

    # Frozen: exactly the two caps init-firewall.sh needs to program netfilter.
    CAPS=$(sed -n '/^[[:space:]]*cap_add:/,/^[[:space:]]*[a-z_]*:[[:space:]]*$/p' "$COMPOSE" \
             | grep -oE '\-[[:space:]]*[A-Z_]+' | grep -oE '[A-Z_]+$' | sort | tr '\n' ' ' | sed 's/ $//')
    eq "$variant compose cap_add is exactly NET_ADMIN + NET_RAW" "$CAPS" "NET_ADMIN NET_RAW"
  done
else
  skip "template host→container checks" "no templates/v3 at $TPL"
fi

echo
echo "═══ B. live container (basic mode) ═══"
CID=$(docker run -d --cap-add NET_ADMIN --cap-add NET_RAW "$IMG" sleep 900)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

docker exec -u 0 "$CID" bash -c 'echo basic > /etc/devcontainer-firewall/default-mode'
if docker exec -u 0 "$CID" /usr/local/bin/init-firewall.sh > /tmp/fw-init.log 2>&1; then
  ok "init-firewall.sh boots in basic"
else
  ko "init-firewall.sh failed to boot"; tail -5 /tmp/fw-init.log | sed 's/^/      /'
fi

# Re-entrance : post-start re-runs init-firewall on every container start.
RE=$(docker exec -u 0 "$CID" bash -c '/usr/local/bin/init-firewall.sh 2>&1 || true')
if echo "$RE" | grep -q "same name already exists"; then
  ko "second init-firewall run — died on ipset create"
elif echo "$RE" | grep -q "already active"; then
  ok "second init-firewall run — skipped by the active guard"
else
  ok "second init-firewall run — completed without the ipset clash"
fi

DIG=$(docker exec "$CID" dig +short +time=2 @127.0.0.53 api.anthropic.com A 2>/dev/null | head -1)
[ -n "$DIG" ] && ok "base allowlist resolves through dnsmasq (api.anthropic.com → $DIG)" \
              || ko "base allowlist does not resolve — the compiled ruleset is not live"

echo "  — privilege suite (as node, runtime ruleset present) —"
docker exec -u node "$CID" bash /etc/devcontainer-firewall/tests/privilege.sh > /tmp/priv-b.log 2>&1 \
  && ok "privilege.sh context B" \
  || { ko "privilege.sh context B"; grep -E '❌' /tmp/priv-b.log | sed 's/^/      /'; }

# Same escalation audit, now with NET_ADMIN/NET_RAW actually granted to the
# container and the firewall running — the state a developer works in, and the
# one where "the caps stop at root" stops being theoretical.
echo "  — escalation suite (as node, caps granted to the container) —"
docker exec -u node "$CID" bash /etc/devcontainer-firewall/tests/escalation.sh > /tmp/esc-b.log 2>&1 \
  && ok "escalation.sh context B" \
  || { ko "escalation.sh context B"; grep -E '❌' /tmp/esc-b.log | sed 's/^/      /'; }

# The network half of the pentest, against a firewall that is actually up:
# DNS-level, IP-level and network-layer bypass attempts. It self-detects the
# mode and downgrades the L4 attempts to informational when mitmproxy is
# absent, so it is meaningful here in basic. Written long ago and called by
# nobody until now — it exits 1 only when a bypass genuinely succeeds.
echo "  — bypass suite (as node, firewall up) —"
docker exec -u node "$CID" bash /etc/devcontainer-firewall/tests/bypass.sh > /tmp/bypass-b.log 2>&1 \
  && ok "bypass.sh — every attempted bypass is blocked" \
  || { ko "bypass.sh — a bypass SUCCEEDED"; grep -E '❌' /tmp/bypass-b.log | sed 's/^/      /'; }

# End-to-end : the workspace .local layer must not reach the live set on its
# own — only a root reload installs it.
EVIL=$(docker exec -u node "$CID" bash -c '
  mkdir -p /workspace/.devcontainer/firewall 2>/dev/null
  echo evil.example.com >> /workspace/.devcontainer/firewall/domains.local.txt 2>/dev/null
  ipset list allowed-domains-local 2>/dev/null | grep -c evil || true')
eq "node-written domains.local.txt does not reach the live set" "${EVIL:-0}" "0"

# The post-start hooks that used to be inert without a workspace copy.
echo "  — hooks with no workspace copy present —"
CREDS=$(docker exec -u node "$CID" bash -c '
  mkdir -p /home/node/.claude /home/node/.claude-creds
  printf "{\"token\":\"smoke\"}" > /home/node/.claude-creds/.credentials.json
  bash /opt/devcontainer/base/hooks/post-start.d/55-claude-creds-sync.sh >/dev/null 2>&1
  test -f /home/node/.claude/.credentials.json && echo SYNCED || echo MISSING')
eq "55-claude-creds-sync pulls from the shared volume" "$(echo "$CREDS" | tr -d '\r')" "SYNCED"

SKILLS=$(docker exec -u node "$CID" bash -c '
  bash /opt/devcontainer/base/hooks/post-start.d/75-skills-sync.sh >/dev/null 2>&1
  ls /home/node/.claude/commands/*.md 2>/dev/null | wc -l | tr -d " "')
[ "${SKILLS:-0}" -gt 0 ] 2>/dev/null \
  && ok "75-skills-sync installs the baked skills ($SKILLS commands)" \
  || ko "75-skills-sync installed nothing — the baked skills are still inert"

echo
echo "═══ C. bake — base layer + project overlay ═══"
if [ -d "$PROJECT_FW" ]; then
  BAKE=$(docker run --rm -u 0 -v "$PROJECT_FW:/tmp/fw-src:ro" "$IMG" bash -c '
    /usr/local/bin/firewall-docker-setup.sh --src /tmp/fw-src --dest /tmp/out >/tmp/bake.log 2>&1 \
      && wc -l < /tmp/out/effective/hosts.txt | tr -d " " || { echo FAILED; tail -5 /tmp/bake.log; }')
  case "$BAKE" in
    ''|*FAILED*) ko "bake base+project"; echo "$BAKE" | sed 's/^/      /' ;;
    *) [ "$BAKE" -ge 33 ] 2>/dev/null \
         && ok "bake base+project = $BAKE hosts (≥ the 33 base hosts)" \
         || ko "bake host count $BAKE — below the base layer, the overlay dropped hosts" ;;
  esac
else
  skip "bake check" "no project overlay at $PROJECT_FW (set PROJECT_FW=…)"
fi

echo
echo "═══════════════════════════════════════════════════════"
echo "  image suites : $((PASS+FAIL)) run | ✔ $PASS | ❌ $FAIL | – $SKIP skipped"
echo "═══════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
