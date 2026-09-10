#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "❌ ERROR on line $LINENO (exit code $?)"' ERR
IFS=$'\n\t'

# Prevent concurrent executions
LOCKFILE="/tmp/init-firewall.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  echo "⚠️ Firewall script already running — skipping."
  exit 0
fi
trap 'rmdir "$LOCKFILE" 2>/dev/null' EXIT

# Skip if firewall is already active (re-run would flush and kill network).
# Split mode (basic/strict) names its sets allowed-domains-{base,local} — the
# bare name only exists in the legacy single-set layout, so check both or the
# post-start re-init tears down the on-create run instead of skipping it.
if { ipset list allowed-domains || ipset list allowed-domains-base; } &>/dev/null \
   && iptables -L OUTPUT -n 2>/dev/null | grep -q "DROP"; then
  echo "✅ Firewall already active — skipping. To change rules: rebuild the container."
  exit 0
fi

DEBUG=false
[ "${1:-}" = "--debug" ] && { DEBUG=true; shift; }
dbg() { [ "$DEBUG" = "true" ] && echo "$@" || true; }

FIREWALL_CONFIG_DIR="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"
DOMAINS_FILE="$FIREWALL_CONFIG_DIR/domains.txt"
DOMAINS_LOCAL_FILE="$FIREWALL_CONFIG_DIR/domains.local.txt"
PROBES_FILE="$FIREWALL_CONFIG_DIR/tests/probes.txt"
BLOCKED_TESTS="$FIREWALL_CONFIG_DIR/tests/blocked.txt"
GENERATED_DNSMASQ_CONF="/var/run/devcontainer-firewall/dnsmasq-domains.conf"
GENERATED_DNSMASQ_BASE_CONF="/var/run/devcontainer-firewall/dnsmasq-domains-base.conf"
GENERATED_DNSMASQ_LOCAL_CONF="/var/run/devcontainer-firewall/dnsmasq-domains-local.conf"
# Injections conf — init-firewall writes ollama, claude-bridge, and
# ports.txt DNS forwarders here. Kept in its own file so
# reload-local.sh's recompile of {base,local}.conf doesn't wipe them.
GENERATED_DNSMASQ_INJECTIONS_CONF="/var/run/devcontainer-firewall/dnsmasq-injections.conf"
GENERATED_POLICY_COMPILED="/var/run/devcontainer-firewall/policy.compiled.yaml"

# -------------------------------
# Helpers
# -------------------------------
# conf_entries / ports_file / ports_entries live in the shared library, so
# test-firewall.sh reads the allowlist through the same code this script does.
# Overridable for the same reason FIREWALL_CONFIG_DIR is : firewall/tests/
# exercises the parser against a sandbox tree.
DEVC_CONF_LIB="${DEVC_CONF_LIB:-/usr/local/bin/devc-conf.sh}"
if [ ! -r "$DEVC_CONF_LIB" ]; then
  echo "❌ $DEVC_CONF_LIB missing — cannot read the firewall config files" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$DEVC_CONF_LIB"

# Resolved once: the compat warning belongs to the boot, not to each reader.
PORTS_FILE="$(ports_file)"

# Shim over /usr/local/bin/compile-policy.py — emits deduped bare hostnames
# after applying !disable from domains.local.txt. Single parser source for both
# dnsmasq config generation and §4/§7 connectivity probes.
list_hosts() {
  python3 /usr/local/bin/compile-policy.py --list-hosts "$@"
}

# Resolve via Docker's internal resolver (bypassing dnsmasq).
# Used to seed direct iptables ACCEPT rules for CLAUDE_CODE_FIREWALL_ALLOWED.
resolve_via_docker() {
  local host="$1"
  { dig +short +time=3 +tries=1 @127.0.0.11 A "$host" 2>/dev/null \
      | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1; } || true
}

# Resolve from /etc/hosts only — no DNS, no NSS. glibc reads `files` before
# `dns` (/etc/nsswitch.conf), so an entry here is the address curl, node and
# every other client in this container will actually dial, whatever a resolver
# would answer. Docker writes such an entry for `--add-host` / compose
# `extra_hosts`, and the two sources CAN disagree — see the HOST_IP ladder.
#
# Not `getent`: it consults the full NSS stack, so its answer depends on
# dnsmasq's state at call time, and it can return an AAAA (measured:
# `getent hosts host.docker.internal` answers an IPv6 address while
# /etc/hosts carries an IPv4 one). This has to read the file, only the file.
resolve_via_hosts_file() {
  local host="$1"
  # `next` and not `exit` on a match : /etc/hosts may carry an AAAA line for the
  # same name BEFORE the A one, and stopping at the first match would emit the
  # v6 address, which the IPv4 filter then drops — an empty answer on a file
  # that does hold the address. Print every candidate, let the filter choose.
  { awk -v h="$host" '
      /^[[:space:]]*#/ { next }
      { for (i = 2; i <= NF; i++) if ($i == h) { print $1; next } }
    ' /etc/hosts 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1; } || true
}

# Common subdomain prefixes used for auto-discovery on wildcard parent hosts
# that have no A record on bare and no manual probe in tests/probes.txt.
DISCOVERY_PREFIXES=(www api cdn raw static objects avatars assets media files
                    app dev v1 v2 docs help mail)

# Try `<prefix>.<host>` for each prefix in parallel; returns those that resolve.
discover_subdomains() {
  local host="$1"
  local tmp; tmp=$(mktemp)
  local p
  for p in "${DISCOVERY_PREFIXES[@]}"; do
    (
      if { dig +short +time=1 +tries=1 @127.0.0.53 "${p}.${host}" A 2>/dev/null \
           | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }; then
        echo "${p}.${host}" >> "$tmp"
      fi
    ) &
  done
  wait
  sort -u "$tmp" 2>/dev/null
  rm -f "$tmp"
}

# Determine probe subdomain(s) for a host. Order:
#   1. Manual override in tests/probes.txt (comma-separated supported)
#   2. The host itself if it has an A record
#   3. Auto-discover via DISCOVERY_PREFIXES (returns ALL that resolve)
#   4. Fall back to the bare host (will trigger wildcard-parent warning)
# Outputs one probe per line.
get_probes() {
  local host="$1"

  # 1. Manual probes from probes.txt (comma-separated → newline)
  if [ -f "$PROBES_FILE" ]; then
    local manual
    manual=$({ grep -E "^[[:space:]]*${host}[[:space:]]*=" "$PROBES_FILE" \
               | head -1 | cut -d= -f2- | tr -d ' ' | tr ',' '\n'; } || true)
    if [ -n "$manual" ]; then
      printf '%s\n' "$manual"
      return
    fi
  fi

  # 2. Host itself has an A record?
  if { dig +short +time=1 +tries=1 @127.0.0.53 "$host" A 2>/dev/null \
       | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }; then
    printf '%s\n' "$host"
    return
  fi

  # 3. Auto-discover via dictionary
  local found
  found=$(discover_subdomains "$host")
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return
  fi

  # 4. Nothing found — return bare host (check_allowed will report ⚠️)
  printf '%s\n' "$host"
}

# -------------------------------
# Read mode from baked file. Was env var FIREWALL_MODE before the bake-only
# migration — workspace-modifiable was a runtime bypass surface (vector #12).
# Accepts legacy aliases (A4 rename) : paranoid → strict, okeish → basic.
# Default if file missing or value unknown : strict (safest).
# -------------------------------
# `|| true` : the file is written by the project's fw-bake stage, so a bare
# image (no project layer) does not have it. Under pipefail the failing `cat`
# would abort the boot at this line with an opaque ERR-trap message, before
# the "default to strict" fallback below could ever apply.
FIREWALL_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]' || true)
case "$FIREWALL_MODE" in
  paranoid)         FIREWALL_MODE=strict ;;
  okeish)           FIREWALL_MODE=basic  ;;
  strict|basic|off) ;;
  *)                FIREWALL_MODE=strict ;;
esac

# -------------------------------
# 0a. Early bail — MODE=off (kill-switch user-runnable via firewall-mode.sh)
# -------------------------------
# Write "off" to /workspace/.devcontainer/firewall/default-mode (via
# firewall-mode.sh off) + rebuild to disable the firewall entirely. Container
# boots with direct internet access (Docker default resolver, no iptables
# filter, no proxy). Restored at next mode change + rebuild.
if [ "$FIREWALL_MODE" = "off" ]; then
  echo "⚠️  FIREWALL_MODE=off — bypassing all firewall config (direct internet access)."

  # Capture Docker DNS NAT rules BEFORE the flush, so we can restore them
  # AFTER. /etc/resolv.conf points clients to 127.0.0.11 (Docker's embedded
  # resolver), which only works because the nat table DNATs that loopback
  # address to the actual resolver. Without restoring, every DNS query in
  # off mode times out — confirmed by diag-a2-off.log curl exit 6 on every
  # host (could not resolve).
  DOCKER_DNS_RULES=$(iptables-save -t nat 2>/dev/null | grep "127\.0\.0\.11" || true)

  # Best-effort cleanup of any prior firewall state
  iptables -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F 2>/dev/null || true
    ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
  fi
  ipset destroy allowed-domains 2>/dev/null || true
  ipset destroy allowed-domains-base 2>/dev/null || true
  ipset destroy allowed-domains-local 2>/dev/null || true
  pkill -x mitmdump 2>/dev/null || true
  pkill -x dnsmasq 2>/dev/null || true

  # Restore Docker DNS NAT rules (same logic as §0 normal flow).
  if [ -n "$DOCKER_DNS_RULES" ]; then
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L1 iptables -t nat
  fi

  # Reset /etc/resolv.conf to Docker default
  cat > /etc/resolv.conf <<EOF
# FIREWALL_MODE=off — Docker default resolver
nameserver 127.0.0.11
options ndots:0
EOF

  # Strip any proxy block from /etc/environment + remove profile script
  sed -i '/# devcontainer-firewall-proxy/,/^$/d' /etc/environment 2>/dev/null || true
  rm -f /etc/profile.d/devcontainer-proxy.sh 2>/dev/null || true

  echo "✅ Firewall disabled. Direct internet access on this container."
  echo "   To re-enable: .devcontainer/firewall-mode.sh strict   (or basic) + rebuild container"
  exit 0
fi

# -------------------------------
# 0. Reset netfilter state
# -------------------------------
echo "🔐 Resetting iptables & ipset..."
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
# All three set names : legacy single-set + the split pair, so a partial
# earlier run (sets created, DROP never installed) can't strand the boot on
# "set with the same name already exists" at the create below.
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy allowed-domains-base 2>/dev/null || true
ipset destroy allowed-domains-local 2>/dev/null || true

# IPv6 lockdown — belt+suspenders with sysctl disable. Even if IPv6 is
# accidentally re-enabled, default-DROP + only loopback ACCEPT prevents
# any outbound IPv6 bypass (DoH over v6, direct v6, etc.).
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F 2>/dev/null || true
  ip6tables -X 2>/dev/null || true
  ip6tables -P INPUT DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
fi

if [ -n "$DOCKER_DNS_RULES" ]; then
  dbg "Restoring Docker DNS NAT rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L1 iptables -t nat
fi

# -------------------------------
# 1. Compile firewall policy (dnsmasq conf + policy.compiled.yaml)
# -------------------------------
# compile-policy.py reads domains.txt + domains.local.txt + policy.d/ +
# policy.local.d/ and emits both artifacts atomically (.tmp + os.rename).
# See firewall/compile-policy.py for syntax + merge precedence.
echo "📝 Compiling firewall policy from $FIREWALL_CONFIG_DIR..."
mkdir -p "$(dirname "$GENERATED_DNSMASQ_CONF")"

# Frozen effective set — bake is ingestion, boot is apply.
# firewall-docker-setup.sh compiles the committed sources once at docker build
# time into $FIREWALL_CONFIG_DIR/effective/, alongside a digest of every input
# compile-policy.py reads. While that digest still matches, boot installs the
# frozen artifacts rather than recompiling. Any mismatch — a base-image bump
# that changed the compiler, a hand-edited /etc, a legacy image built before
# the bake existed — falls back to compiling in place, with the reason logged.
EFFECTIVE_DIR="$FIREWALL_CONFIG_DIR/effective"
# Overridable for the same reason FIREWALL_CONFIG_DIR is : firewall/tests/
# exercises this decision against a sandbox tree.
FW_DIGEST_LIB="${FW_DIGEST_LIB:-/usr/local/bin/firewall-digest.sh}"
USE_FROZEN=false
FROZEN_REASON="image has no baked effective/ set"
if [ -r "$FW_DIGEST_LIB" ] && [ -s "$EFFECTIVE_DIR/sources.sha256" ]; then
  # shellcheck source=/dev/null
  . "$FW_DIGEST_LIB"
  FROZEN_DIGEST=$(cat "$EFFECTIVE_DIR/sources.sha256")
  CURRENT_DIGEST=$(fw_sources_digest "$FIREWALL_CONFIG_DIR" \
                     "$(cat "$EFFECTIVE_DIR/local-included" 2>/dev/null || echo 0)")
  if [ "$FROZEN_DIGEST" != "$CURRENT_DIGEST" ]; then
    FROZEN_REASON="sources changed since bake (${FROZEN_DIGEST:0:12} → ${CURRENT_DIGEST:0:12})"
  elif [ ! -s "$EFFECTIVE_DIR/dnsmasq-domains-base.conf" ] \
    || [ ! -s "$EFFECTIVE_DIR/policy.compiled.yaml" ] \
    || [ ! -f "$EFFECTIVE_DIR/dnsmasq-domains-local.conf" ]; then
    FROZEN_REASON="baked effective/ set is incomplete"
  else
    USE_FROZEN=true
    # Without this, FROZEN_REASON keeps its initialisation value and a
    # POSITIVE decision reads "image has no baked effective/ set" - the exact
    # opposite of what was just decided.
    FROZEN_REASON="frozen set accepted (digest match, files complete)"
  fi
fi

# Rename rather than truncate in place : the mitmproxy addons re-read
# policy.compiled.yaml whenever its mtime moves, so they must never observe a
# half-written file.
install_frozen() {
  install -m 644 "$EFFECTIVE_DIR/$1" "$2.new" && mv -f "$2.new" "$2"
}

if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
  if [ "$USE_FROZEN" = "true" ]; then
    echo "  ⚡ installing the frozen ruleset baked at $(head -1 "$FIREWALL_CONFIG_DIR/baked-at" 2>/dev/null || echo 'unknown')"
    install_frozen dnsmasq-domains-base.conf  "$GENERATED_DNSMASQ_BASE_CONF"
    install_frozen dnsmasq-domains-local.conf "$GENERATED_DNSMASQ_LOCAL_CONF"
    install_frozen policy.compiled.yaml       "$GENERATED_POLICY_COMPILED"
  else
    echo "  ↻ recompiling — $FROZEN_REASON"
    # Split base/local so reload-firewall can flush only the local layer
    # without dropping baseline connections. In strict, the local flush
    # spares baseline mitmproxy connections; the addons pick up the new
    # policy.compiled.yaml via mtime check on their next request.
    python3 /usr/local/bin/compile-policy.py \
      --config-dir "$FIREWALL_CONFIG_DIR" \
      --split-local \
      --out-dnsmasq-base  "$GENERATED_DNSMASQ_BASE_CONF" \
      --out-dnsmasq-local "$GENERATED_DNSMASQ_LOCAL_CONF" \
      --out-policy        "$GENERATED_POLICY_COMPILED"
  fi
  chmod 644 "$GENERATED_DNSMASQ_BASE_CONF" "$GENERATED_DNSMASQ_LOCAL_CONF" "$GENERATED_POLICY_COMPILED"
  dbg "  generated $(grep -c '^server=' "$GENERATED_DNSMASQ_BASE_CONF") base + $(grep -c '^server=' "$GENERATED_DNSMASQ_LOCAL_CONF") local dnsmasq rules"
else
  python3 /usr/local/bin/compile-policy.py \
    --config-dir "$FIREWALL_CONFIG_DIR" \
    --out-dnsmasq "$GENERATED_DNSMASQ_CONF" \
    --out-policy  "$GENERATED_POLICY_COMPILED"
  chmod 644 "$GENERATED_DNSMASQ_CONF" "$GENERATED_POLICY_COMPILED"
  dbg "  generated $(grep -c '^server=' "$GENERATED_DNSMASQ_CONF") dnsmasq rules"
fi

# Route baseline dnsmasq injections (ollama alias, claude-bridge sibling,
# ports.txt) to the base conf in split-mode (basic + strict), or to
# the legacy combined conf in off. These injections are all infrastructure
# baseline (never user-managed local overrides), hence the base group.
if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
  INJECT_DNSMASQ_CONF="$GENERATED_DNSMASQ_BASE_CONF"
  # Same split as the conf: `allowed-domains` is the v2 single-set layout and
  # is never created in basic/strict, so a directive naming it would point
  # dnsmasq at a set that does not exist.
  INJECT_IPSET=allowed-domains-base
else
  INJECT_DNSMASQ_CONF="$GENERATED_DNSMASQ_CONF"
  INJECT_IPSET=allowed-domains
fi

# Dynamic CNAME injection for the local Ollama backend ----------------------
# host.docker.internal carries a runtime-assigned IP (192.168.65.254 on Docker
# Desktop, the default gateway on Linux). We resolve it via Docker's internal
# resolver (127.0.0.11) and emit a local host-record + CNAME chain so that
# ollama.internal flows through dnsmasq (and into ipset) like every other
# allowlisted host — no extra_hosts/IP-in-/etc/hosts shortcut needed.
# `server=/ollama.{internal,local}/8.8.8.8` lines emitted by compile-policy.py
# are stripped first : the cname directives handle resolution locally, so
# upstream forwarding would only race and return NXDOMAIN.
#
# All injection blocks below write to GENERATED_DNSMASQ_INJECTIONS_CONF (a
# separate file that reload-local.sh does NOT regenerate) rather than
# INJECT_DNSMASQ_CONF (which gets rewritten by every recompile). The sed
# strips still target INJECT_DNSMASQ_CONF because the compile-policy
# output lives there.
: > "$GENERATED_DNSMASQ_INJECTIONS_CONF"
chmod 644 "$GENERATED_DNSMASQ_INJECTIONS_CONF"

# `|| true` : under pipefail an unresolvable host (native Linux docker, bare
# `docker run`) exits the grep non-zero and would abort the whole boot — the
# empty-value case is already handled by the else branch below.
HOST_DOCKER_IP=$(dig +short +time=2 +tries=2 @127.0.0.11 host.docker.internal A 2>/dev/null \
                  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1 || true)
if [ -n "$HOST_DOCKER_IP" ]; then
  # Drop the auto-emitted `server=` lines for the two aliases — cname wins
  # locally but the duplicate forward rule clutters the conf.
  sed -i -E '/^server=\/ollama\.(internal|local)\//d' "$INJECT_DNSMASQ_CONF"
  cat >> "$GENERATED_DNSMASQ_INJECTIONS_CONF" <<EOF

# Injected by init-firewall.sh — Ollama local backend (see knowledge/ollama-local.md).
# local-ttl=3600 is REQUIRED for the ipset pipeline to work : without it,
# dnsmasq tags host-record/cname/address answers with TTL=0 (the default for
# locally-synthesized records), and the matching ipset entries are created
# with timeout=0 → expire immediately. Result : DNS resolves but iptables
# drops the packet ("no ipset match AND unreachable"). With local-ttl=3600,
# the ipset entry persists for an hour and the DNS-driven pipeline works
# end-to-end, with no manual ipset-add workaround needed.
# (No backticks in this heredoc: it is unquoted, so bash would run whatever
# they contain and splice the output into the generated dnsmasq conf.)
local-ttl=3600
host-record=host.docker.internal,$HOST_DOCKER_IP
cname=ollama.internal,host.docker.internal
cname=ollama.local,host.docker.internal
ipset=/host.docker.internal/$INJECT_IPSET
EOF
  dbg "  injected host.docker.internal=$HOST_DOCKER_IP + ollama.{internal,local} CNAMEs (local-ttl=3600)"
else
  echo "⚠️  Could not resolve host.docker.internal via 127.0.0.11 — ollama.internal alias skipped"
fi

# Unconditional sibling-resolve for `claude-bridge` (docker-compose service,
# always declared in docker-compose.yml regardless of mode ; always listed in
# domains.txt L133-134). compile-policy.py emits `server=/claude-bridge/
# 8.8.8.8` for it (8.8.8.8 doesn't know about Docker peers) — strip it and
# substitute Docker's embedded resolver (127.0.0.11) which DOES resolve the
# service name from the compose graph. The auto-emitted ipset directive stays.
sed -i -E '/^server=\/claude-bridge\//d' "$INJECT_DNSMASQ_CONF"
cat >> "$GENERATED_DNSMASQ_INJECTIONS_CONF" <<EOF

# Injected by init-firewall.sh — claude-bridge sidecar (UniClaudeProxy).
server=/claude-bridge/127.0.0.11
# Bypass alias : matches .local in NO_PROXY → direct TCP, no audit.
cname=claude-bridge.local,claude-bridge
EOF
dbg "  added claude-bridge → 127.0.0.11 forwarding + .local bypass alias"

# Dynamic sibling-resolve : for each entry of ports.txt, emit
# `server=/<host>/127.0.0.11` so the name resolves via Docker's embedded
# resolver. compile-policy.py auto-emits `server=/<host>/8.8.8.8` for hosts
# also listed in domains.txt — strip that defensively. The auto-emitted
# `ipset=/<host>/allowed-domains` directive stays, so the resolved IP
# populates the ipset transparently.
#
# Skip handled-above hosts :
# - `host` alias / `host.docker.internal` → ollama block above (host-record=)
# - `claude-bridge` → unconditional override block above (it's docker-compose-
#   always-declared and listed in baked domains.txt independent of mode)
while IFS= read -r line; do
  host="${line%%:*}"                     # split host:port
  [ "$host" = "host" ] && continue                  # ollama block handled
  [ "$host" = "host.docker.internal" ] && continue  # idem
  [ "$host" = "claude-bridge" ] && continue         # hardcoded above
  escaped="${host//./\\.}"               # escape dots for sed ERE
  sed -i -E "/^server=\\/${escaped}\\//d" "$INJECT_DNSMASQ_CONF"
  cat >> "$GENERATED_DNSMASQ_INJECTIONS_CONF" <<EOF

# Injected by init-firewall.sh — sibling-resolve from ports.txt.
server=/${host}/127.0.0.11
# Bypass alias : matches .local in NO_PROXY → direct TCP, no audit.
cname=${host}.local,${host}
EOF
  dbg "  added ${host} → 127.0.0.11 forwarding + .local bypass alias"
done < <(ports_entries "$PORTS_FILE")

# -------------------------------
# 2. Start dnsmasq + override resolv.conf
# -------------------------------
echo "🛰  Starting dnsmasq (local resolver on 127.0.0.53)..."

# Empty ipset first — dnsmasq populates it on each successful resolution.
# In split-mode (basic + strict) we split into base + local so
# reload-local.sh can flush only the local layer without touching baseline
# (see reload-local.sh). In strict, the base group also spares in-flight
# mitmproxy connections to baseline hosts during the flush.
if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
  ipset create allowed-domains-base  hash:ip family inet timeout 3600
  ipset create allowed-domains-local hash:ip family inet timeout 3600
else
  ipset create allowed-domains hash:ip family inet timeout 3600
fi

# Inject host-gateway IP into the ipset for the Ollama aliases.
#
# We tried the pure DNS-driven path first (cname=ollama.internal,host.docker.
# internal + host-record + local-ttl=3600 + ipset=/.../allowed-domains) but
# dnsmasq does NOT call the netfilter ipset notifier for A records synthesized
# from `host-record` / `cname` / `address` directives — the notifier only fires
# on UPSTREAM resolutions. Verified live : dnsmasq returns the right IP for
# ollama.internal queries, but `ipset test allowed-domains <IP>` reports "not
# in set" no matter how many times the host is queried.
#
# Workaround : resolve the host gateway once at init (via 127.0.0.11, Docker's
# internal resolver — which IS upstream from dnsmasq's POV) and inject the IP
# manually with timeout=0 (never expires within the container's lifetime).
# The IP isn't hardcoded — it's dynamically captured from Docker's resolver,
# so the entry stays correct if Docker re-assigns the gateway IP. The cname
# chain (in the generated dnsmasq.conf above) still routes client queries
# transparently ; this just ensures the firewall accepts the resulting packet.
if [ -n "$HOST_DOCKER_IP" ]; then
  if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
    # Host gateway is infrastructure baseline — always in the base group.
    ipset add allowed-domains-base "$HOST_DOCKER_IP" timeout 0 2>/dev/null || true
    dbg "  ipset add allowed-domains-base $HOST_DOCKER_IP timeout 0  (host gateway — dnsmasq doesn't notify on local synth)"
  else
    ipset add allowed-domains "$HOST_DOCKER_IP" timeout 0 2>/dev/null || true
    dbg "  ipset add allowed-domains $HOST_DOCKER_IP timeout 0  (host gateway — dnsmasq doesn't notify on local synth)"
  fi
fi

# Stop any leftover dnsmasq (e.g. from a previous failed run)
pkill -x dnsmasq 2>/dev/null || true
sleep 0.2

# Launch dnsmasq under a dedicated user so iptables can UID-filter UDP/53.
# Debian's dnsmasq package creates this user. Fall back to "nobody" or root.
DNSMASQ_USER=dnsmasq
if ! id -u "$DNSMASQ_USER" >/dev/null 2>&1; then
  DNSMASQ_USER=nobody
  if ! id -u "$DNSMASQ_USER" >/dev/null 2>&1; then
    DNSMASQ_USER=""
  fi
fi

if [ -n "$DNSMASQ_USER" ]; then
  DNSMASQ_UID=$(id -u "$DNSMASQ_USER")
  if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
    dnsmasq \
      --conf-file="$FIREWALL_CONFIG_DIR/dnsmasq.conf" \
      --conf-file="$GENERATED_DNSMASQ_BASE_CONF" \
      --conf-file="$GENERATED_DNSMASQ_LOCAL_CONF" \
      --conf-file="$GENERATED_DNSMASQ_INJECTIONS_CONF" \
      --user="$DNSMASQ_USER"
  else
    dnsmasq \
      --conf-file="$FIREWALL_CONFIG_DIR/dnsmasq.conf" \
      --conf-file="$GENERATED_DNSMASQ_CONF" \
      --conf-file="$GENERATED_DNSMASQ_INJECTIONS_CONF" \
      --user="$DNSMASQ_USER"
  fi
else
  DNSMASQ_UID=""
  if [ "$FIREWALL_MODE" = "basic" ] || [ "$FIREWALL_MODE" = "strict" ]; then
    dnsmasq \
      --conf-file="$FIREWALL_CONFIG_DIR/dnsmasq.conf" \
      --conf-file="$GENERATED_DNSMASQ_BASE_CONF" \
      --conf-file="$GENERATED_DNSMASQ_LOCAL_CONF" \
      --conf-file="$GENERATED_DNSMASQ_INJECTIONS_CONF"
  else
    dnsmasq \
      --conf-file="$FIREWALL_CONFIG_DIR/dnsmasq.conf" \
      --conf-file="$GENERATED_DNSMASQ_CONF" \
      --conf-file="$GENERATED_DNSMASQ_INJECTIONS_CONF"
  fi
  echo "⚠️  No dnsmasq/nobody user available — UDP/53 UID filter disabled"
fi

# Override /etc/resolv.conf to point at our dnsmasq.
# Note: Docker bind-mounts /etc/resolv.conf, so we MUST write into the file
# (truncate + rewrite) — `mv`/`rm` would fail with "Device or resource busy".
cat > /etc/resolv.conf <<EOF
# Managed by /usr/local/bin/init-firewall.sh — do not edit
nameserver 127.0.0.53
options ndots:0
EOF

# Wait up to ~3s for dnsmasq to be ready
ready=false
for _ in 1 2 3 4 5 6; do
  if dig +short +time=1 +tries=1 @127.0.0.53 api.anthropic.com A >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.5
done
if ! $ready; then
  echo "❌ dnsmasq failed to start — aborting firewall init"
  exit 1
fi
dbg "  dnsmasq up on 127.0.0.53"

# -------------------------------
# 3. Base iptables rules (loopback, DNS, SSH)
# -------------------------------
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Outbound UDP/53 — only for the dnsmasq process, blocking direct DNS queries
# (e.g. `dig @8.8.8.8 evil.com`) from the user `node`. node user resolves via
# 127.0.0.53 (loopback, already allowed above) which goes through our dnsmasq
# which only forwards listed domains. Closes a Phase 1 DNS-tunneling bypass.
if [ -n "${DNSMASQ_UID:-}" ]; then
  iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner "$DNSMASQ_UID" -j ACCEPT
else
  # Fallback: keep UDP/53 open for any user (less secure but functional)
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
fi
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Note: SSH outbound (TCP/22) is NOT explicitly opened. SSH to a host listed
# in domains.txt works via the ipset match (which has no port restriction).
# SSH to non-listed hosts is blocked. INPUT/22 is unaffected — VS Code Remote
# / docker exec / etc. don't use port 22 to reach the container.

# -------------------------------
# 4. Build probes cache (used by warming + test-firewall.sh) + warm ipset
# -------------------------------
# Compute probes for each host once and cache in a TSV file at a fixed path
# so test-firewall.sh can reuse it (post-create.sh runs the test phase
# separately from this init script). Avoids duplicating subdomain discovery.
PROBES_CACHE=/var/run/devcontainer-firewall/probes-cache.tsv
mkdir -p "$(dirname "$PROBES_CACHE")"
: > "$PROBES_CACHE"

echo "🔎 Computing probes (subdomain discovery for wildcard parents)..."
# F2: include every .txt under domains.d/ (per-ecosystem allowlists generated
# per-ecosystem allowlists, committed by the project). They merge additively with the
# baseline domains.txt.
DOMAINS_D_FILES=()
for f in "$FIREWALL_CONFIG_DIR"/domains.d/*.txt; do
  [ -f "$f" ] && DOMAINS_D_FILES+=("$f")
done
list_hosts "$DOMAINS_FILE" "${DOMAINS_D_FILES[@]}" "$DOMAINS_LOCAL_FILE" \
  | sort -u \
  | while IFS= read -r host; do
      get_probes "$host" | while IFS= read -r probe; do
        [ -z "$probe" ] && continue
        printf '%s\t%s\n' "$host" "$probe" >> "$PROBES_CACHE"
      done
    done

echo "📍 Warming ipset (resolving probes)..."
while IFS=$'\t' read -r host probe; do
  dbg "  warming: $host → $probe"
  dig +short +time=2 +tries=1 @127.0.0.53 "$probe" A >/dev/null 2>&1 &
done < "$PROBES_CACHE"
wait
# Count the sets that actually exist. Reading the v2 `allowed-domains` here
# reported 0 in every split-mode boot, and `grep -c … || echo 0` printed the
# count AND the fallback (grep exits 1 on no match), yielding a two-line "0".
WARMED=$({ ipset list allowed-domains; ipset list allowed-domains-base; ipset list allowed-domains-local; } 2>/dev/null \
           | grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
echo "📍 Warming ipset...ok (${WARMED:-0} IPs)"

# -------------------------------
# 5. ports.txt — direct ACCEPT for non-HTTP TCP services
# -------------------------------
# Was env var CLAUDE_CODE_FIREWALL_ALLOWED (in .env, workspace-modifiable)
# before the bake-only migration — adding arbitrary host:port to iptables
# ACCEPT was a runtime bypass surface (vector #13).
#
# Format and compat rules live in ports_file/ports_entries at the top of this
# file. Special keyword : "host" → host.docker.internal (Docker gateway IP).
# This block used to hardcode the absolute path while the sibling-resolve block
# above honoured $FIREWALL_CONFIG_DIR — the two now read the same file.
#
# The ACCEPT below must name the address the confined process will DIAL, which
# is not always the one a resolver answers. Three sources, measured inside one
# container on a dedicated bridge network with `--add-host=…:host-gateway` :
#
#   /etc/hosts     172.17.0.1        ← what curl uses (NSS: files before dns)
#   ip route       172.21.0.1        ← this network's gateway, a third answer
#   @127.0.0.11    192.168.65.254    ← leaks to the OUTER resolver under dind
#
# Hence the order. /etc/hosts first because it is authoritative for every
# client in the container; where it says nothing — which is every container
# whose compose declares no extra_hosts, i.e. the normal case — this falls
# through to the resolver exactly as before. The route probe stays LAST: on a
# non-default bridge network it names a gateway that host.docker.internal does
# not resolve to, so promoting it would punch the wrong rule.
#
# The priority is the POINT, not an accident of today's composes : the rule has
# to name whatever this container resolves the name to. So a project that does
# declare extra_hosts on its own service is served correctly by construction —
# it dials that address, and that address is what gets the ACCEPT. Nothing here
# depends on `app` staying without extra_hosts.
HOST_IP=$(resolve_via_hosts_file host.docker.internal)
[ -z "$HOST_IP" ] && HOST_IP=$(resolve_via_docker host.docker.internal || true)
[ -z "$HOST_IP" ] && HOST_IP=$(ip route | awk '/^default/ {print $3}')

while IFS= read -r entry; do
  host="${entry%%:*}"
  port="${entry##*:}"

  if [ "$host" = "host" ]; then
    ip="$HOST_IP"
  else
    ip=$(resolve_via_docker "$host")
  fi

  if [ -n "$ip" ]; then
    iptables -A OUTPUT -d "$ip" -p tcp --dport "$port" -j ACCEPT
    echo "📦 Direct TCP allow: $host ($ip):$port"
  else
    echo "⚠️  $host not resolvable — skipped"
  fi
done < <(ports_entries "$PORTS_FILE")

# Block all private/local networks (host + Docker subnets) by default.
iptables -A OUTPUT -d 10.0.0.0/8 -j REJECT
iptables -A OUTPUT -d 172.16.0.0/12 -j REJECT
iptables -A OUTPUT -d 192.168.0.0/16 -j REJECT

# -------------------------------
# 5b. MITM (strict mode) — install + start mitmproxy as forward proxy
# -------------------------------
# Mode "force-proxy" : mitmproxy runs as an explicit HTTP forward proxy on
# 127.0.0.1:8080. Apps reach it via HTTPS_PROXY env var (set by post-start.sh
# into /etc/environment + shell-init.sh). The filter chain below restricts the
# ipset ACCEPT to mitmproxy's UID — apps that bypass HTTPS_PROXY can't reach
# external IPs at all (only loopback to mitmproxy + Docker-internal allowlist).
# A3 baked the mitmproxy binary in the image — no first-boot install window.
MODE="${FIREWALL_MODE:-strict}"
MITMPROXY_UID=""
if [ "$MODE" = "strict" ]; then
  echo "🛡  Mode strict — starting mitmproxy (forward proxy on 127.0.0.1:8080)"
  FIREWALL_MODE="$MODE" /usr/local/bin/mitm-init.sh
  MITMPROXY_UID=$(id -u mitmproxy)
fi

# -------------------------------
# 6. Default policy
# -------------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ "$MODE" = "strict" ] && [ -n "$MITMPROXY_UID" ]; then
  # Force-proxy : only mitmproxy can reach allowlisted hosts directly. Other
  # UIDs (node) must go through 127.0.0.1:8080 (loopback ACCEPTed above) where
  # mitmproxy proxies the request and re-emits it from its own UID. Split
  # into base + local so reload-local.sh can flush only the local group
  # without dropping in-flight mitmproxy connections to baseline hosts.
  iptables -A OUTPUT -m owner --uid-owner "$MITMPROXY_UID" -m set --match-set allowed-domains-base  dst -j ACCEPT
  iptables -A OUTPUT -m owner --uid-owner "$MITMPROXY_UID" -m set --match-set allowed-domains-local dst -j ACCEPT
elif [ "$MODE" = "basic" ]; then
  # Basic mode : any UID can reach allowlisted hosts directly. Split into
  # base + local so reload-local.sh can flush only the local group.
  iptables -A OUTPUT -m set --match-set allowed-domains-base  dst -j ACCEPT
  iptables -A OUTPUT -m set --match-set allowed-domains-local dst -j ACCEPT
else
  # Fallback (strict without mitmproxy UID captured — shouldn't happen).
  iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
fi
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "🔥 Firewall rules applied"

# Connectivity tests moved out of init-firewall.sh — see test-firewall.sh,
# invoked from post-create.sh after the extension install has kicked off.
# init's job here ends with the firewall rules applied + the probes cache
# persisted at /var/run/devcontainer-firewall/probes-cache.tsv.

# HTTPS_PROXY propagation — belt + suspenders
# Path 1: initialize.sh writes .env → docker-compose env_file → container PID 1
# Path 2: this section writes /etc/environment + /etc/profile.d → PAM-based
#         sessions (VS Code Server) + login shells. Idempotent + cleans up.
PROXY_ENV_FILE=/etc/environment
PROXY_PROFILE=/etc/profile.d/devcontainer-proxy.sh
PROXY_MARKER="# devcontainer-firewall-proxy"

# Always strip any previous proxy block (cleanup on mode switch)
if [ -f "$PROXY_ENV_FILE" ]; then
  sed -i "/$PROXY_MARKER/,/^$/d" "$PROXY_ENV_FILE" 2>/dev/null || true
fi
rm -f "$PROXY_PROFILE"

if [ "$MODE" = "strict" ]; then
  cat >> "$PROXY_ENV_FILE" <<EOF
$PROXY_MARKER
HTTP_PROXY=http://127.0.0.1:8080
HTTPS_PROXY=http://127.0.0.1:8080
NO_PROXY=localhost,127.0.0.0/8,host.docker.internal,.local

EOF
  cat > "$PROXY_PROFILE" <<EOF
$PROXY_MARKER
export HTTP_PROXY=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export NO_PROXY=localhost,127.0.0.0/8,host.docker.internal,.local
EOF
  chmod 644 "$PROXY_PROFILE"
fi

if [ "$MODE" = "strict" ]; then
  echo "✅ Firewall ready (strict — dnsmasq + ipset + mitmproxy force-proxy + A2 addons)."
else
  echo "✅ Firewall ready (basic — dnsmasq + ipset dynamic allowlist)."
fi

# Debug dump — readable by user node (no sudo needed to inspect rules)
{
  echo "=== filter ==="
  iptables -L -n -v --line-numbers
  echo
  echo "=== nat ==="
  iptables -t nat -L -n -v --line-numbers
  echo
  if [ "$MODE" = "basic" ] || [ "$MODE" = "strict" ]; then
    echo "=== ipset allowed-domains-base ==="
    ipset list allowed-domains-base 2>/dev/null | head -30
    echo
    echo "=== ipset allowed-domains-local ==="
    ipset list allowed-domains-local 2>/dev/null | head -30
  else
    echo "=== ipset allowed-domains ==="
    ipset list allowed-domains 2>/dev/null | head -30
  fi
} > /tmp/iptables-dump.txt 2>&1
chmod 644 /tmp/iptables-dump.txt
