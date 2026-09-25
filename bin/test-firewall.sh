#!/usr/bin/env bash
# Connectivity tests — run *after* init-firewall.sh has set up iptables /
# ipset / dnsmasq / mitmproxy. Verifies that allowed domains are reachable
# through mitm and that blocked ones are dropped. Reads the probes cache
# persisted by init-firewall.sh (so subdomain discovery isn't redone).
#
# Invoked from post-create.sh (foreground, once at container creation).
# Requires root for `ipset test` — sudoers entry granted via Dockerfile.
# NOTE: connectivity tests are informational — a ❌ result highlights a real
# problem worth investigating, but should NOT fail post-create.sh (the actual
# security is enforced by ipset/iptables/mitmproxy, not by these probes). The
# script therefore exits 0 explicitly at the end ; failures are surfaced in red.
# Dropped `-e -E` + ERR trap : with backgrounded check_* jobs and `wait` the
# strict mode was triggering exit 1 even though no test explicitly failed.
set -uo pipefail
IFS=$'\n\t'

# ANSI for highlight — ❌ in bold red so real failures pop out visually.
RED=$'\033[1;31m'
RST=$'\033[0m'

# Two ways in, and the environment is the one that was broken: `DEBUG=false`
# was assigned unconditionally, so the image-wide switch (`DEBUG=1`, the form
# bin/devc-hook and compile-policy.py read) was overwritten before it could be
# honoured. Nothing noticed, because dbg() below is never called from anywhere
# in this file — it is pre-existing dead code, left alone deliberately.
case "${DEBUG:-0}" in 1|true) DEBUG=true ;; *) DEBUG=false ;; esac
[ "${1:-}" = "--debug" ] && { DEBUG=true; shift; }
dbg() { [ "$DEBUG" = "true" ] && echo "$@" || true; }

FIREWALL_CONFIG_DIR="${FIREWALL_CONFIG_DIR:-/etc/devcontainer-firewall}"
BLOCKED_TESTS="$FIREWALL_CONFIG_DIR/tests/blocked.txt"
PROBES_CACHE=/var/run/devcontainer-firewall/probes-cache.tsv

# Read mode from baked file (same source as init-firewall.sh post bake-only).
FIREWALL_MODE=$(cat /etc/devcontainer-firewall/default-mode 2>/dev/null | tr -d '[:space:]')
case "$FIREWALL_MODE" in
  paranoid)         FIREWALL_MODE=strict ;;
  okeish)           FIREWALL_MODE=basic  ;;
  strict|basic|off) ;;
  *)                FIREWALL_MODE=strict ;;
esac

# off mode = firewall disabled, no tests to run.
if [ "$FIREWALL_MODE" = "off" ]; then
  echo "ℹ FIREWALL_MODE=off — skipping connectivity tests."
  exit 0
fi

if [ ! -f "$PROBES_CACHE" ]; then
  echo "${RED}❌ $PROBES_CACHE missing — run init-firewall.sh first.${RST}"
  exit 1
fi

# Resolve via Docker's internal resolver (bypassing dnsmasq) — used for
# CLAUDE_CODE_FIREWALL_ALLOWED hostnames.
resolve_via_docker() {
  local host="$1"
  { dig +short +time=3 +tries=1 @127.0.0.11 A "$host" 2>/dev/null \
      | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1; } || true
}

DEVC_CONF_LIB="${DEVC_CONF_LIB:-/usr/local/bin/devc-conf.sh}"
if [ ! -r "$DEVC_CONF_LIB" ]; then
  echo "❌ $DEVC_CONF_LIB missing — cannot read the firewall config files" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$DEVC_CONF_LIB"

HOST_IP=$(resolve_via_docker host.docker.internal || true)
[ -z "$HOST_IP" ] && HOST_IP=$(ip route | awk '/^default/ {print $3}')

# Load ports.txt entries (baked) into a CSV string for downstream code.
# This used to re-implement the resolver AND the parser, and the parser copy
# was wrong: `tr -d '[:space:]'` over the stream deletes newlines too, so two
# entries came out as one glued token (`host:9222ollama:11434`) and the probes
# below tested a host that does not exist.
FIREWALL_ALLOWED=$(ports_entries "$(ports_file)" | paste -sd, -)

TEST_RESULTS=$(mktemp)
trap "rm -f '$TEST_RESULTS'" EXIT

# Strict mode → curl probes go through mitm. Basic mode → direct.
PROXY_ARG=()
[ "$FIREWALL_MODE" = "strict" ] && PROXY_ARG=(-x http://127.0.0.1:8080)

tcp_probe() {
  timeout 3 bash -c "echo >/dev/tcp/$1/$2" 2>/dev/null
}

needs_optin() {
  # Internal-style hostnames need iptables ACCEPT via CLAUDE_CODE_FIREWALL_ALLOWED
  # to be reachable at L4 — RFC1918 REJECT blocks them otherwise. Codebase convention :
  #   *.internal → host-gateway alias (CNAME to host.docker.internal)
  #   *.local    → bypass alias (NO_PROXY direct TCP, host-gateway OR Docker peer)
  #   single-label (no dot) → Docker compose peer container
  # Public TLDs (anthropic.com, etc.) route directly — no opt-in.
  case "$1" in
    *.internal|*.local) return 0 ;;
    *.*)                return 1 ;;
    *)                  return 0 ;;
  esac
}

optin_port() {
  # Echo the port matched in $FIREWALL_ALLOWED for $1, empty if not opted in.
  # Matching rule (mirrors init-firewall.sh iptables ACCEPT logic) :
  #   *.internal → entry "host:<port>" (host-gateway alias)
  #   *.local    → entry "<bare>:<port>" preferred (Docker peer .local bypass),
  #                fallback "host:<port>" (host-gateway .local bypass)
  #   single-label → entry "<probe>:<port>" (Docker peer)
  local probe="$1" entry e_host e_port bare _entries match=host
  [ -z "$FIREWALL_ALLOWED" ] && return 0
  IFS=',' read -ra _entries <<< "$FIREWALL_ALLOWED"
  case "$probe" in
    *.internal) match=host ;;
    *.local)
      bare="${probe%.local}"
      # First pass : prefer the more specific bare match (Docker peer alias).
      for entry in "${_entries[@]}"; do
        entry=$(echo "$entry" | tr -d ' ')
        e_host="${entry%%:*}"; e_port="${entry#*:}"
        [ "$e_host" = "$bare" ] && { echo "$e_port"; return 0; }
      done
      match=host ;;
    *) match="$probe" ;;
  esac
  for entry in "${_entries[@]}"; do
    entry=$(echo "$entry" | tr -d ' ')
    e_host="${entry%%:*}"; e_port="${entry#*:}"
    [ "$e_host" = "$match" ] && { echo "$e_port"; return 0; }
  done
  return 0
}

check_blocked() {
  local host="$1" label="$2"
  if curl "${PROXY_ARG[@]}" -sk -o /dev/null --max-time 3 \
       -w "%{http_code}" "https://$host/" 2>/dev/null \
       | grep -qE "^[1-5][0-9][0-9]$"; then
    echo "${RED}❌ $label (reached $host — firewall did NOT block)${RST}" >> "$TEST_RESULTS"
  else
    echo "✔ $label" >> "$TEST_RESULTS"
  fi
}

check_allowed() {
  local host="$1"
  local probe="${2:-$host}"
  local label="$host"
  [ "$probe" != "$host" ] && label="$host (via $probe)"
  local ips ip in_ipset=false ns

  ips=$({ dig +short +time=2 +tries=1 @127.0.0.53 "$probe" A 2>/dev/null \
          | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; } || true)
  if [ -z "$ips" ]; then
    ns=$({ dig +short +time=2 +tries=1 @127.0.0.53 "$probe" NS 2>/dev/null; } || true)
    if [ -n "$ns" ]; then
      echo "⚠️  $label (wildcard parent — no A on bare domain ; add probe in tests/probes.txt)" >> "$TEST_RESULTS"
    else
      echo "${RED}❌ $label (DNS resolution failed)${RST}" >> "$TEST_RESULTS"
    fi
    return
  fi
  for ip in $ips; do
    if ipset test allowed-domains "$ip" 2>/dev/null; then
      in_ipset=true
      break
    fi
  done

  if needs_optin "$probe"; then
    # Internal-style host : port comes from CLAUDE_CODE_FIREWALL_ALLOWED.
    if ! $in_ipset; then
      echo "${RED}❌ $label (no ipset match — DNS allowlist broken)${RST}" >> "$TEST_RESULTS"
      return
    fi
    local port; port=$(optin_port "$probe")
    if [ -z "$port" ]; then
      echo "ℹ️  $label — DNS-allowlisted but L4 not opted in (uncomment in firewall/ports.txt + Rebuild to enable)" >> "$TEST_RESULTS"
    elif tcp_probe "$ip" "$port"; then
      echo "✔ $label reachable (TCP :$port)" >> "$TEST_RESULTS"
    else
      echo "⚠️  $label opted in via ports.txt (:$port) but TCP unreachable — check service / sidecar" >> "$TEST_RESULTS"
    fi
    return
  fi

  if curl "${PROXY_ARG[@]}" -sk -o /dev/null --max-time 3 \
       -w "%{http_code}" "https://$probe/" 2>/dev/null \
       | grep -qE "^[1-5][0-9][0-9]$"; then
    echo "✔ $label reachable" >> "$TEST_RESULTS"
  elif $in_ipset; then
    echo "⚠️  $label allowlisted in ipset but unreachable" >> "$TEST_RESULTS"
  else
    echo "${RED}❌ $label (no ipset match AND unreachable)${RST}" >> "$TEST_RESULTS"
  fi
}

echo "🔍 Running connectivity tests..."

# Bounded parallelism — launching 50+ curl probes through mitmproxy at once
# saturates the proxy (single-threaded request handling) and causes random
# 3-second timeouts on a few hosts each run, producing flaky "⚠ allowlisted
# but unreachable" warnings on hosts that ARE actually reachable. Cap at
# MAX_JOBS concurrent probes so mitmproxy keeps up. bash 4+ `wait -n`
# waits for any single background job to finish.
MAX_JOBS=8
running=0
_throttle() {
  if [ "$running" -ge "$MAX_JOBS" ]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi
}

# Allowed: each (host, probe) pair from the cache built by init-firewall.sh
while IFS=$'\t' read -r host probe; do
  _throttle
  check_allowed "$host" "$probe" &
  running=$((running + 1))
done < "$PROBES_CACHE"

# Blocked: each host listed in tests/blocked.txt — must NOT be reachable
while IFS= read -r line; do
  _throttle
  check_blocked "$line" "$line blocked" &
  running=$((running + 1))
done < <(conf_entries "$BLOCKED_TESTS")

# ports.txt entries — TCP probe (may have no listener, OK)
if [ -n "$FIREWALL_ALLOWED" ]; then
  IFS=',' read -ra TEST_ENTRIES <<< "$FIREWALL_ALLOWED"
  for entry in "${TEST_ENTRIES[@]}"; do
    entry=$(echo "$entry" | tr -d ' ')
    host=$(echo "$entry" | cut -d: -f1)
    port=$(echo "$entry" | cut -d: -f2)
    if [ "$host" = "host" ]; then
      label="host ($HOST_IP):$port"
      ip="$HOST_IP"
    else
      ip=$(resolve_via_docker "$host")
      label="$host ($ip):$port"
    fi
    if [ -n "$ip" ]; then
      (
        if tcp_probe "$ip" "$port"; then
          echo "✔ $label reachable" >> "$TEST_RESULTS"
        else
          echo "⚠️  $label allowed but no service listening" >> "$TEST_RESULTS"
        fi
      ) &
    else
      echo "⚠️  $host not resolvable — skipped" >> "$TEST_RESULTS"
    fi
  done
fi
wait

# One line for what worked, one line each for what did not.
#
# Measured on a real boot: 77 lines here, 36 of them subdomain probes of two
# wildcard parents — after the patcher pass, the largest block of the whole
# start sequence, for a fact that fits in a sentence. Nothing reads these
# lines: the security is enforced by ipset / iptables / mitmproxy, and the
# header of this file says so already.
#
# What never collapses is a line that is not a ✔. A ❌, a ⚠️ or a ℹ️ is the
# reason anyone reads this output at all, so each keeps its own line, under
# the count — the same shape as the boot panel, whose explanations sit under
# the frame. DEBUG=1 brings the ✔ back, the same switch devc-hook and
# compile-policy use, so there is one way to ask this image for more output.
N_OK=$(grep -c '^✔ ' "$TEST_RESULTS" || true)
N_WARN=$(grep -c '^⚠️' "$TEST_RESULTS" || true)
N_INFO=$(grep -c '^ℹ️' "$TEST_RESULTS" || true)
N_FAIL=$(grep -c '❌' "$TEST_RESULTS" || true)

SUFFIX=""
if [ "$N_FAIL" -gt 0 ]; then
  SUFFIX=" — informational: the filter is ipset/iptables/mitmproxy, not these probes"
elif [ "$DEBUG" != "true" ]; then
  SUFFIX=" — DEBUG=1 to list the ✔"
fi
# Built first, coloured after: `${N_FAIL:+…}` would fire on the string "0",
# which is set and non-empty, and paint every clean run red.
LINE="$(printf 'connectivity: %s reachable/blocked as configured, %s warning(s), %s notice(s), %s failure(s)%s' \
  "$N_OK" "$N_WARN" "$N_INFO" "$N_FAIL" "$SUFFIX")"
if [ "$N_FAIL" -gt 0 ]; then
  printf '%s%s%s\n' "$RED" "$LINE" "$RST"
else
  printf '%s\n' "$LINE"
fi

if [ "$DEBUG" = "true" ]; then
  cat "$TEST_RESULTS"
else
  grep -v '^✔ ' "$TEST_RESULTS" || true
fi
exit 0
