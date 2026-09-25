#!/usr/bin/env bash
# firewall-docker-setup.sh — bake the firewall at image build time.
#
# Runs from a project Dockerfile RUN step. Ingests the committed firewall
# sources (base-image content + project overlay), freezes the compiled result
# under <dest>/effective/, and stamps <dest>/baked-at. At boot,
# init-firewall.sh installs that frozen set instead of recompiling — bake is
# ingestion, boot is apply.
#
# Usage :
#   firewall-docker-setup.sh                                   # in-place (legacy)
#   firewall-docker-setup.sh --src /tmp/fw-src --dest /out      # staged
#
#   --base DIR   base-image firewall content   (default /etc/devcontainer-firewall)
#   --src  DIR   project overlay staging dir   (default = --dest)
#   --dest DIR   where the frozen result lands (default /etc/devcontainer-firewall)
#
# STAGED MODE IS THE SECURE ONE. In-place mode still applies the .local
# exclusion at runtime, but it cannot un-ship the file : a `RUN rm` removes
# nothing from the earlier `COPY firewall/` layer, so `docker save` still
# carries domains.local.txt. Only a multi-stage build — COPY into a throwaway
# stage, `COPY --from=` into the final image — keeps workspace-writable files
# out of the image entirely.
#
# .local opt-in, off by default. Enable per-developer with the build arg
# FIREWALL_ALLOW_LOCAL_AT_REBUILD=1, or team-wide with a committed
# `allow-local-at-rebuild` marker file next to domains.txt.
#
# Idempotent : the digest of every compiler input is recorded in
# effective/sources.sha256, so a re-run with unchanged inputs is a logged
# no-op and a repeated RUN step never perturbs the frozen set.
#
# Lives in the base image (/usr/local/bin/) — one source of truth, evolves per
# base-image bump without forcing a project-side re-install.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_DIR=/etc/devcontainer-firewall
DEST_DIR=""
SRC_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_DIR="$2"; shift 2 ;;
    --src)  SRC_DIR="$2";  shift 2 ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "firewall-docker-setup.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

DEST_DIR="${DEST_DIR:-/etc/devcontainer-firewall}"
SRC_DIR="${SRC_DIR:-$DEST_DIR}"
EFFECTIVE_DIR="$DEST_DIR/effective"

# Resolve the compiler and the digest library. Inside the image both sit in
# /usr/local/bin ; in the template tree they are two directories apart. The env
# vars let the test harness point at a sandbox.
FW_COMPILER="${FW_COMPILER:-}"
for c in "$FW_COMPILER" /usr/local/bin/compile-policy.py "$SELF_DIR/compile-policy.py"; do
  if [ -n "$c" ] && [ -f "$c" ]; then FW_COMPILER="$c"; break; fi
done
if [ ! -f "${FW_COMPILER:-/nonexistent}" ]; then
  echo "firewall-docker-setup.sh: compile-policy.py not found" >&2; exit 2
fi
export FW_COMPILER

FW_DIGEST_LIB="${FW_DIGEST_LIB:-}"
for c in "$FW_DIGEST_LIB" /usr/local/bin/firewall-digest.sh \
         "$SELF_DIR/firewall-digest.sh" "$SELF_DIR/../bin/firewall-digest.sh"; do
  if [ -n "$c" ] && [ -f "$c" ]; then FW_DIGEST_LIB="$c"; break; fi
done
if [ ! -f "${FW_DIGEST_LIB:-/nonexistent}" ]; then
  echo "firewall-docker-setup.sh: firewall-digest.sh not found" >&2; exit 2
fi
# shellcheck source=/dev/null
. "$FW_DIGEST_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "🧱 firewall bake — src=$SRC_DIR dest=$DEST_DIR"

# -------------------------------------------------------------------------
# 1. .local opt-in
# -------------------------------------------------------------------------
LOCAL_INCLUDED=0
LOCAL_REASON="hardened default"
if [ "${FIREWALL_ALLOW_LOCAL_AT_REBUILD:-0}" = "1" ]; then
  LOCAL_INCLUDED=1
  LOCAL_REASON="FIREWALL_ALLOW_LOCAL_AT_REBUILD=1"
elif [ -f "$SRC_DIR/allow-local-at-rebuild" ]; then
  LOCAL_INCLUDED=1
  LOCAL_REASON="allow-local-at-rebuild marker"
fi

# -------------------------------------------------------------------------
# 2. Assemble dest = base image content, overlaid by the project sources
# -------------------------------------------------------------------------
# Boot recomputes the digest over the merged /etc/devcontainer-firewall/. If
# the bake only saw the project overlay, every boot would find extra
# base-layer policy files, miss the digest and recompile — the frozen set
# would never be used. So dest mirrors what /etc will look like.
mkdir -p "$DEST_DIR"

# effective/ and baked-at are OUR output. They must never arrive from a source
# tree : both live under the workspace firewall/ dir a project COPYs in, which
# is developer- (and postinstall-) writable. A forged effective/ carrying a
# sources.sha256 that matches the legitimate sources would short-circuit the
# bake below and ship the attacker's ruleset. tar's --exclude keeps them out of
# the overlay while preserving perms and ownership the way cp -a would.
_overlay_into() {
  local from="$1" to="$2"
  [ -d "$from" ] || return 0
  ( cd "$from" && tar -cf - --exclude=./effective --exclude=./baked-at . ) \
    | ( cd "$to" && tar -xf - )
}

if [ "$SRC_DIR" != "$DEST_DIR" ]; then
  _overlay_into "$BASE_DIR" "$DEST_DIR"
  _overlay_into "$SRC_DIR"  "$DEST_DIR"
else
  # In-place mode : dest IS the COPY target, so there is no seam between "what
  # a source provided" and "what a previous run wrote". Drop both, for the
  # reason above. The cost is that a repeated in-place RUN always recompiles ;
  # staged mode (--src/--dest) gets the no-op short-circuit and the layer
  # guarantee at once.
  rm -rf "$EFFECTIVE_DIR" "$DEST_DIR/baked-at"
fi

if [ "$LOCAL_INCLUDED" = "0" ]; then
  rm -f  "$DEST_DIR/domains.local.txt"
  rm -rf "$DEST_DIR/policy.local.d"
fi
# Both must exist whether or not they carry anything — init-firewall.sh and
# reload-firewall address them unconditionally.
[ -f "$DEST_DIR/domains.local.txt" ] || : > "$DEST_DIR/domains.local.txt"
mkdir -p "$DEST_DIR/policy.local.d"

# -------------------------------------------------------------------------
# 3. Digest — skip the whole bake when nothing feeding the compiler moved
# -------------------------------------------------------------------------
DIGEST="$(fw_sources_digest "$DEST_DIR" "$LOCAL_INCLUDED")"

frozen_is_current() {
  [ -f "$EFFECTIVE_DIR/sources.sha256" ] || return 1
  [ "$(cat "$EFFECTIVE_DIR/sources.sha256")" = "$DIGEST" ] || return 1
  [ -s "$EFFECTIVE_DIR/dnsmasq-domains-base.conf" ] || return 1
  [ -s "$EFFECTIVE_DIR/policy.compiled.yaml" ] || return 1
  [ -s "$EFFECTIVE_DIR/hosts.txt" ] || return 1
  return 0
}

if frozen_is_current; then
  echo "   ✓ already baked (digest ${DIGEST:0:12}) — no-op"
  exit 0
fi

# -------------------------------------------------------------------------
# 4. Compile via the real compiler
# -------------------------------------------------------------------------
# Never reimplement the merge in bash : !disable overrides, method unions and
# the policy.d deep-merge all live in compile-policy.py.
#
# Always --split-local. The flat single-conf layout is unreachable here — it
# only applies to mode=off, and init-firewall.sh exits long before its compile
# step in that mode.
mkdir -p "$EFFECTIVE_DIR"

if ! python3 "$FW_COMPILER" \
      --config-dir "$DEST_DIR" \
      --split-local \
      --out-dnsmasq-base  "$EFFECTIVE_DIR/dnsmasq-domains-base.conf.new" \
      --out-dnsmasq-local "$EFFECTIVE_DIR/dnsmasq-domains-local.conf.new" \
      --out-policy        "$EFFECTIVE_DIR/policy.compiled.yaml.new" \
      2> "$TMP/compile.err"; then
  echo "✗ firewall bake FAILED — compile-policy.py rejected the sources :" >&2
  cat "$TMP/compile.err" >&2
  rm -f "$EFFECTIVE_DIR"/*.new
  exit 1
fi

# compile-policy.py stamps `# Generated-at: <now>` into every artifact. Left in
# place, no two bakes of identical sources are byte-identical and the no-op
# short-circuit above could never fire. Nothing consumes the line — the
# mitmproxy addons watch st_mtime_ns, init-firewall.sh greps ^server=, dnsmasq
# ignores comments.
sed -i '/^# Generated-at:/d' \
  "$EFFECTIVE_DIR/dnsmasq-domains-base.conf.new" \
  "$EFFECTIVE_DIR/dnsmasq-domains-local.conf.new" \
  "$EFFECTIVE_DIR/policy.compiled.yaml.new"

# hosts.txt — the flat allowlist, consumed by the boot warning and by
# reload-firewall's host delta.
DOMAIN_FILES=("$DEST_DIR/domains.txt")
while IFS= read -r f; do
  [ -n "$f" ] && DOMAIN_FILES+=("$f")
done < <(find "$DEST_DIR/domains.d" -maxdepth 1 -type f -name '*.txt' -print 2>/dev/null | LC_ALL=C sort)
DOMAIN_FILES+=("$DEST_DIR/domains.local.txt")

python3 "$FW_COMPILER" --list-hosts "${DOMAIN_FILES[@]}" \
  | grep -v '^[[:space:]]*$' \
  | LC_ALL=C sort -u > "$EFFECTIVE_DIR/hosts.txt.new"

# -------------------------------------------------------------------------
# 5. Refuse to promote an empty ruleset
# -------------------------------------------------------------------------
# compile-policy.py returns 0 and emits a header-only file when domains.txt is
# missing — it has no host-count check of its own. Shipping that would produce
# a container that resolves nothing, diagnosed as "the network is broken".
HOST_COUNT=$(wc -l < "$EFFECTIVE_DIR/hosts.txt.new" | tr -d ' ')
SERVERS_BASE=$(grep -c '^server=' "$EFFECTIVE_DIR/dnsmasq-domains-base.conf.new" || true)
SERVERS_LOCAL=$(grep -c '^server=' "$EFFECTIVE_DIR/dnsmasq-domains-local.conf.new" || true)
if [ "$HOST_COUNT" -eq 0 ] || [ "$(( SERVERS_BASE + SERVERS_LOCAL ))" -eq 0 ]; then
  echo "✗ firewall bake REFUSED — the effective ruleset is empty." >&2
  echo "   hosts=$HOST_COUNT server-lines=$(( SERVERS_BASE + SERVERS_LOCAL )) src=$SRC_DIR" >&2
  echo "   Check that $DEST_DIR/domains.txt exists and is non-empty." >&2
  rm -f "$EFFECTIVE_DIR"/*.new
  exit 1
fi

# -------------------------------------------------------------------------
# 6. Promote atomically + stamp the markers
# -------------------------------------------------------------------------
for f in dnsmasq-domains-base.conf dnsmasq-domains-local.conf policy.compiled.yaml hosts.txt; do
  mv -f "$EFFECTIVE_DIR/$f.new" "$EFFECTIVE_DIR/$f"
done

printf '%s\n' "$LOCAL_INCLUDED" > "$EFFECTIVE_DIR/local-included.new"
mv -f "$EFFECTIVE_DIR/local-included.new" "$EFFECTIVE_DIR/local-included"
printf '%s\n' "$DIGEST" > "$EFFECTIVE_DIR/sources.sha256.new"
mv -f "$EFFECTIVE_DIR/sources.sha256.new" "$EFFECTIVE_DIR/sources.sha256"

# baked-at lives OUTSIDE effective/ on purpose : it changes on every bake and
# must never perturb a digest computed over the config tree.
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  echo "digest=$DIGEST"
  echo "local-included=$LOCAL_INCLUDED"
  echo "hosts=$HOST_COUNT"
} > "$DEST_DIR/baked-at.new"
mv -f "$DEST_DIR/baked-at.new" "$DEST_DIR/baked-at"

# -------------------------------------------------------------------------
# 7. Ownership — root-owned, world-readable
# -------------------------------------------------------------------------
# capital-X in chmod = "x only if dir or already +x" — 755 on dirs and 644 on
# files in a single pass, no per-path enumeration.
if [ "$(id -u)" -eq 0 ]; then
  chown -R root:root "$DEST_DIR"
  chmod -R u=rwX,go=rX "$DEST_DIR"
else
  echo "   ⚠ not root — skipped chown/chmod (expected only in a test sandbox)"
fi

# -------------------------------------------------------------------------
# 8. Build log
# -------------------------------------------------------------------------
MODE=$(tr -d '[:space:]' < "$DEST_DIR/default-mode" 2>/dev/null || true)
POLICY_COUNT=$(find "$DEST_DIR/policy.d" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')
POLICY_LOCAL_COUNT=$(find "$DEST_DIR/policy.local.d" -maxdepth 1 -type f -name '*.yaml' 2>/dev/null | wc -l | tr -d ' ')

echo "   mode           : ${MODE:-strict (default)}"
echo "   hosts          : $HOST_COUNT  ($SERVERS_BASE base + $SERVERS_LOCAL local server lines)"
echo "   policies       : $POLICY_COUNT in policy.d/, $POLICY_LOCAL_COUNT in policy.local.d/"
echo "   local included : $LOCAL_INCLUDED  ($LOCAL_REASON)"
echo "   digest         : $DIGEST"

# compile-policy.py's non-fatal warnings (a policy.d file naming a host absent
# from domains.txt, an endpoint with no matching path) go to stderr and would
# otherwise disappear into build output nobody reads.
if [ -s "$TMP/compile.err" ]; then
  echo "   compiler warnings :"
  sed 's/^/     /' "$TMP/compile.err"
fi

# The loud one. Skipping .local can remove most of what a developer's container
# could reach, and the symptom (npm install fails) looks nothing like the cause.
if [ "$LOCAL_INCLUDED" = "0" ] && [ -s "$SRC_DIR/domains.local.txt" ]; then
  COMMITTED_FILES=("${DOMAIN_FILES[@]:0:$(( ${#DOMAIN_FILES[@]} - 1 ))}")
  WITH_LOCAL=$(python3 "$FW_COMPILER" --list-hosts \
                 "${COMMITTED_FILES[@]}" "$SRC_DIR/domains.local.txt" 2>/dev/null \
               | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u | wc -l | tr -d ' ')
  if [ "$WITH_LOCAL" -gt "$HOST_COUNT" ]; then
    echo "   ⚠ domains.local.txt NOT baked : $WITH_LOCAL → $HOST_COUNT hosts."
    echo "     Apply it to the running container with : wtf firewall reload"
    echo "     Bake it in instead with : FIREWALL_ALLOW_LOCAL_AT_REBUILD=1"
  fi
fi

echo "   ✓ frozen ruleset at $EFFECTIVE_DIR"
